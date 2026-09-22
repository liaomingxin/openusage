import Foundation

/// Reads per-model usage rows from Hermes Agent's local state database, porting tokscale's queries:
/// `~/.hermes/state.db` (or `$HERMES_HOME/state.db`). The per-model `session_model_usage` rows are
/// preferred; sessions on builds without that table fall back to the session-level `sessions`
/// totals. Cost is Hermes' reported actual (else its estimated) value when non-zero; otherwise the
/// tokens price through the shared engine — the same "carried cost, else price" rule the Claude,
/// Codex, and pi scanners use.
///
/// A `Sendable` struct (like the OpenCode scanner), `async` and nonisolated, so the SQLite reads run
/// off the main actor. Hermes' SQLite is only ever read; no database is created.
struct HermesUsageScanner: Sendable {
    var sqlite: SQLiteAccessing
    var databasePath: @Sendable () -> String?

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePath: @escaping @Sendable () -> String? = HermesUsageScanner.defaultDatabasePath
    ) {
        self.sqlite = sqlite
        self.databasePath = databasePath
    }

    static let defaultDatabasePath: @Sendable () -> String? = {
        let environment = ProcessEnvironmentReader()
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let override = environment.value(for: "HERMES_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(override))
                .appendingPathComponent("state.db").path
        }
        return home.appendingPathComponent(".hermes/state.db").path
    }

    /// Scan the last `daysBack` days. Returns `nil` when there is no Hermes database at all; a
    /// present-but-unreadable database logs once and yields whatever the fallback query could read.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        guard let path = databasePath(),
              FileManager.default.fileExists(atPath: path)
        else { return nil }

        // The per-model query needs `session_model_usage`; when the table is missing (an older
        // build) SQLite fails to prepare, which is the signal to use the session-totals fallback.
        var rows: [Row] = []
        do {
            if let json = try sqlite.queryValue(path: path, sql: Self.perModelSQL) {
                rows = Self.parseRows(json)
            }
        } catch {
            AppLog.warn(LogTag.plugin("hermes"), "per-model query failed, falling back to session totals: \(error.localizedDescription)")
        }
        if rows.isEmpty {
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.sessionTotalsSQL) {
                    rows = Self.parseRows(json)
                }
            } catch {
                AppLog.warn(LogTag.plugin("hermes"), "usage query failed for \(path): \(error.localizedDescription)")
                return nil
            }
        }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= since else { continue }

            let trimmedModel = row.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName
            if let carried = row.cost, carried > 0 {
                accumulator.add(day: DailyUsageAccumulator.dayKey(from: date), tokens: row.tokens, cost: carried, model: modelName)
            } else if let model = trimmedModel,
                      let estimated = pricing.estimatedCostDollars(model: model, tokens: row.tokensBreakdown) {
                accumulator.add(day: DailyUsageAccumulator.dayKey(from: date), tokens: row.tokens, cost: estimated, model: modelName)
            } else if let model = trimmedModel, row.tokens > 0 {
                accumulator.addUnknownModel(day: DailyUsageAccumulator.dayKey(from: date), model: model)
            }
        }
        return accumulator.build()
    }

    /// Codex-card slice: official `openai-codex` rows only. The Agent scan stays unfiltered.
    func officialCodexScan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> LogUsageScan? {
        await officialScan(card: "codex", now: now, daysBack: daysBack, pricing: pricing)
    }

    /// Z.ai This Mac slice: official `zai` host rows only.
    func officialZAIScan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> LogUsageScan? {
        await officialScan(card: "zai", now: now, daysBack: daysBack, pricing: pricing)
    }

    private func officialScan(
        card: String, now: Date, daysBack: Int, pricing: ModelPricing
    ) async -> LogUsageScan? {
        guard let path = databasePath(), FileManager.default.fileExists(atPath: path) else { return nil }
        let rows: [Row]
        do {
            guard let json = try sqlite.queryValue(path: path, sql: Self.perModelSQL) else { return nil }
            rows = Self.parseRows(json)
        } catch {
            return nil
        }
        let slices = Self.officialSlices(rows)
        let selected = card == "codex" ? slices.codex : slices.zai
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var accumulator = DailyUsageAccumulator()
        for row in selected {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= since else { continue }
            let cost = (row.cost ?? 0) > 0
                ? row.cost!
                : pricing.estimatedCostDollars(model: row.model, tokens: row.tokensBreakdown)
            guard let cost else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date), tokens: row.tokens, cost: cost,
                model: row.model, buckets: row.tokensBreakdown
            )
        }
        let scan = accumulator.build()
        return scan.series.daily.isEmpty ? nil : scan
    }

    // MARK: - Rows

    /// One per-model usage row. `cost` is Hermes' actual (else estimated) value; nil when the row
    /// carried neither column.
    struct Row {
        var ms: Double
        var model: String
        var tokens: Int
        var cost: Double?
        /// The buckets, kept for pricing the carried-cost fall-through.
        var tokensBreakdown: TokenBreakdown
        var billingProvider: String?
        var billingBaseURL: String?
    }

    /// Parse the `json_group_array(json_array(...))` payload each query emits:
    /// `[started_ms, model, input, output, cache_read, cache_write, reasoning, cost?]`.
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 6,
                  let ms = ProviderParse.number(entry[0]),
                  let model = entry[1] as? String
            else { continue }
            let input = Self.clampedTokens(entry[2])
            let output = Self.clampedTokens(entry[3])
            let cacheRead = Self.clampedTokens(entry[4])
            let cacheWrite = Self.clampedTokens(entry[5])
            let reasoning = entry.count > 6 ? Self.clampedTokens(entry[6]) : 0
            let cost = entry.count > 7 ? ProviderParse.number(entry[7]) : nil
            let billingProvider = entry.count > 8 ? entry[8] as? String : nil
            let billingBaseURL = entry.count > 9 ? entry[9] as? String : nil
            // OpenAI-family models bill reasoning as output tokens; Hermes reports the buckets
            // separately, so they fold back together for pricing (the displayed total keeps both).
            rows.append(Row(
                ms: ms,
                model: model,
                tokens: input + output + cacheRead + cacheWrite + reasoning,
                cost: cost,
                tokensBreakdown: TokenBreakdown(
                    input: input,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: output + reasoning
                ),
                billingProvider: billingProvider,
                billingBaseURL: billingBaseURL
            ))

        }
        return rows
    }

    /// Official-host slices. Proxy and custom rows stay in the unfiltered Agent scan and are dropped here.
    static func officialSlices(_ rows: [Row]) -> (codex: [Row], zai: [Row]) {
        var codex: [Row] = []
        var zai: [Row] = []
        for row in rows {
            guard let provider = row.billingProvider else { continue }
            guard let attribution = SubscriptionAttributionRules.attribution(
                providerID: provider, baseURL: row.billingBaseURL
            ) else { continue }
            if attribution.cardID == "codex", attribution.mode == .addToLocalSpend { codex.append(row) }
            if attribution.cardID == "zai", attribution.mode == .thisMacDetail { zai.append(row) }
        }
        return (codex, zai)
    }

    /// Clamp before the Int conversion so a corrupt, absurdly large token count can't trap
    /// (Int(Double) crashes above Int.max), matching the OpenCode scanner's guard.
    private static func clampedTokens(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }

    // MARK: - SQL

    /// Per-model rows grouped by (session, model, billing_provider) — the grouping Hermes' own
    /// composite primary key implies, ported from tokscale. Cost resolves per row (actual when
    /// non-zero, else estimated) before the SUM so an actual-cost sibling can't discard
    /// estimate-only ones. `started_at` is seconds; the JSON emits milliseconds. The grouped
    /// SELECT runs as a subquery — SQLite rejects nested aggregates
    /// (`json_group_array(json_array(SUM(...)))` is "misuse of aggregate function").
    static let perModelSQL = """
        SELECT json_group_array(json_array(started_ms, model, input, output, cache_read, cache_write, reasoning, cost, billing_provider, billing_base_url))
        FROM (
          SELECT s.started_at * 1000.0 AS started_ms,
                 smu.model AS model,
                 SUM(smu.input_tokens) AS input,
                 SUM(smu.output_tokens) AS output,
                 SUM(smu.cache_read_tokens) AS cache_read,
                 SUM(smu.cache_write_tokens) AS cache_write,
                 SUM(smu.reasoning_tokens) AS reasoning,
                 SUM(COALESCE(NULLIF(smu.actual_cost_usd, 0), smu.estimated_cost_usd, 0)) AS cost,
                 smu.billing_provider AS billing_provider,
                 smu.billing_base_url AS billing_base_url
          FROM session_model_usage smu
          JOIN sessions s ON s.id = smu.session_id
          WHERE smu.model IS NOT NULL
            AND TRIM(smu.model) != ''
          GROUP BY smu.session_id, smu.model, smu.billing_provider, smu.billing_base_url, s.started_at
          HAVING SUM(smu.input_tokens) > 0
              OR SUM(smu.output_tokens) > 0
              OR SUM(smu.cache_read_tokens) > 0
              OR SUM(smu.cache_write_tokens) > 0
              OR SUM(smu.reasoning_tokens) > 0
              OR SUM(COALESCE(NULLIF(smu.actual_cost_usd, 0), smu.estimated_cost_usd, 0)) > 0
        );
        """

    /// Session-level totals credited to `sessions.model` — covers builds that predate
    /// `session_model_usage`. Column order matches `perModelSQL`.
    static let sessionTotalsSQL = """
        SELECT json_group_array(json_array(
                 started_at * 1000.0,
                 model,
                 input_tokens,
                 output_tokens,
                 cache_read_tokens,
                 cache_write_tokens,
                 reasoning_tokens,
                 COALESCE(NULLIF(actual_cost_usd, 0), estimated_cost_usd, 0)))
        FROM sessions
        WHERE model IS NOT NULL
          AND TRIM(model) != ''
          AND (COALESCE(input_tokens, 0) > 0
            OR COALESCE(output_tokens, 0) > 0
            OR COALESCE(cache_read_tokens, 0) > 0
            OR COALESCE(cache_write_tokens, 0) > 0
            OR COALESCE(reasoning_tokens, 0) > 0
            OR COALESCE(actual_cost_usd, estimated_cost_usd, 0) > 0);
        """
}
