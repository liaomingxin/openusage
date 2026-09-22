import Foundation

/// OpenCode rows that bill an official provider login other than the zero-cost ChatGPT OAuth path.
/// That path stays in `OpenCodeCodexUsageScanner`. Positive-cost `openai` rows are API-key traffic
/// and are priced with Codex rates, not the recorded cost. Gateway provider ids never match the
/// allowlist, so they stay out of every card.
struct OpenCodeSubscriptionUsageScanner: Sendable {
    struct Result: Sendable {
        var localSpend: [String: LogUsageScan]
        var thisMac: [String: LogUsageScan]
    }

    private let authStore: OpenCodeAuthStore
    private let sqlite: SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths
    ) {
        self.authStore = authStore
        self.sqlite = sqlite
        self.databasePaths = databasePaths
    }

    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> Result {
        let paths = (try? databasePaths()) ?? []
        guard !paths.isEmpty else { return Result(localSpend: [:], thisMac: [:]) }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(since.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        for path in paths {
            for sql in [Self.dataSQL(cutoffMs: cutoffMs, table: "message", role: "json_extract(data,'$.role') = 'assistant'"),
                        Self.dataSQL(cutoffMs: cutoffMs, table: "session_message", role: "type = 'assistant'")] {
                guard let json = try? sqlite.queryValue(path: path, sql: sql) else { continue }
                rows.append(contentsOf: Self.parseRows(json))
            }
        }
        var accepted: [String: String] = [:]
        var buckets: [String: (SubscriptionSpendMode, DailyUsageAccumulator)] = [:]
        for row in Self.deduplicated(rows) where row.timestamp >= since {
            guard let attribution = SubscriptionAttributionRules.attribution(providerID: row.providerID) else { continue }
            if row.providerID == "openai" {
                guard row.recordedCost > 0 else { continue }
            } else if accepted[row.providerID] == nil {
                let kind = (try? authStore.credentialKind(providerID: row.providerID)) ?? ""
                guard kind == "oauth" || kind == "api" else { continue }
                accepted[row.providerID] = kind
            }
            let cost = pricedCost(row: row, pricing: pricing)
            guard let cost else { continue }
            let key = "\(attribution.cardID)|\(attribution.mode == .addToLocalSpend ? "local" : "mac")"
            if buckets[key] == nil {
                buckets[key] = (attribution.mode, DailyUsageAccumulator())
            }
            buckets[key]?.1.add(
                day: DailyUsageAccumulator.dayKey(from: row.timestamp),
                tokens: row.reportedTotalTokens,
                cost: cost,
                model: row.model,
                buckets: row.tokens
            )
        }
        var local: [String: LogUsageScan] = [:]
        var thisMac: [String: LogUsageScan] = [:]
        for (key, value) in buckets {
            let cardID = String(key.split(separator: "|").first ?? "")
            let scan = value.1.build()
            if value.0 == .addToLocalSpend { local[cardID] = scan } else { thisMac[cardID] = scan }
        }
        return Result(localSpend: local, thisMac: thisMac)
    }

    private func pricedCost(row: Row, pricing: ModelPricing) -> Double? {
        if row.providerID == "openai" {
            return CodexUsagePricing.estimatedCost(pricing: pricing, model: row.model, tokens: row.tokens)
        }
        if row.recordedCost > 0 { return row.recordedCost }
        return pricing.estimatedCostDollars(model: row.model, tokens: row.tokens)
    }

    struct Row: Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var recordedCost: Double
        var model: String
        var providerID: String
        var tokens: TokenBreakdown
        var reportedTotalTokens: Int
    }

    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return payload.compactMap { element in
            guard let values = element as? [Any], values.count >= 10,
                  let milliseconds = ProviderParse.number(values[0]),
                  let recordedCost = ProviderParse.number(values[1]),
                  let providerID = (values[4] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { return nil }
            let input = clamped(values[5])
            let cacheRead = clamped(values[6])
            let cacheWrite = clamped(values[7])
            let output = clamped(values[8])
            let tokens = TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output)
            return Row(
                id: (values[9] as? String)?.nilIfEmpty,
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
                recordedCost: recordedCost,
                model: ((values[3] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                providerID: providerID,
                tokens: tokens,
                reportedTotalTokens: tokens.totalTokens > 0 ? tokens.totalTokens : clamped(values[2])
            )
        }
    }

    static func deduplicated(_ rows: [Row]) -> [Row] {
        var seen: Set<String> = []
        return rows.filter { row in
            guard let id = row.id else { return true }
            return seen.insert(id).inserted
        }
    }

    private static func clamped(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }

    static func dataSQL(cutoffMs: Int, table: String, role: String) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 COALESCE(json_extract(data,'$.modelID'), json_extract(data,'$.model.id')),
                 COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID')),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 id))
        FROM \(table)
        WHERE time_created >= \(cutoffMs)
          AND \(role)
        """
    }
}
