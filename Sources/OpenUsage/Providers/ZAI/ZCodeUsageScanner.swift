import Foundation

/// Reads ZCode's local `model_usage` table. Only completed BigModel rows become Z.ai This Mac
/// detail. `input_tokens` already includes cache read, so the stored input has that overlap removed.
/// A database that cannot be read is logged and skipped; it never blanks Z.ai's quota meters.
struct ZCodeUsageScanner: Sendable {
    private let sqlite: SQLiteAccessing
    private let databasePath: @Sendable () -> String?

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePath: @escaping @Sendable () -> String? = ZCodeUsageScanner.defaultDatabasePath
    ) {
        self.sqlite = sqlite
        self.databasePath = databasePath
    }

    static let defaultDatabasePath: @Sendable () -> String? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> LogUsageScan? {
        guard let path = databasePath() else { return nil }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(since.timeIntervalSince1970 * 1000)
        guard let json = try? sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) else {
            AppLog.warn(LogTag.plugin("zai"), "ZCode usage query failed for \(path)")
            return nil
        }
        var accumulator = DailyUsageAccumulator()
        for row in Self.parseRows(json) where row.timestamp >= since {
            guard SubscriptionAttributionRules.attribution(providerID: row.providerID)?.cardID == "zai" else { continue }
            let cost = row.model.isEmpty ? nil : pricing.estimatedCostDollars(model: row.model, tokens: row.tokens)
            guard let cost else {
                if row.reportedTotal > 0, !row.model.isEmpty {
                    accumulator.addUnknownModel(day: DailyUsageAccumulator.dayKey(from: row.timestamp), model: row.model)
                }
                continue
            }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: row.timestamp),
                tokens: row.reportedTotal,
                cost: cost,
                model: row.model,
                buckets: row.tokens
            )
        }
        let scan = accumulator.build()
        return scan.series.daily.isEmpty && scan.unknownModelsByDay.isEmpty ? nil : scan
    }

    struct Row: Sendable, Equatable {
        var timestamp: Date
        var providerID: String
        var model: String
        var tokens: TokenBreakdown
        var reportedTotal: Int
    }

    /// `[started_ms, provider_id, model_id, status, input, output, cache_read, cache_write, computed_total]`
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return payload.compactMap { element in
            guard let values = element as? [Any], values.count >= 9,
                  let milliseconds = ProviderParse.number(values[0]),
                  (values[3] as? String) == "completed",
                  let providerID = (values[1] as? String)?.nilIfEmpty
            else { return nil }
            let rawInput = clamped(values[4])
            let output = clamped(values[5])
            let cacheRead = clamped(values[6])
            let cacheWrite = clamped(values[7])
            let computed = clamped(values[8])
            let input = max(0, rawInput - cacheRead - cacheWrite)
            return Row(
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
                providerID: providerID,
                model: ((values[2] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output),
                reportedTotal: computed > 0 ? computed : input + cacheRead + cacheWrite + output
            )
        }
    }

    private static func clamped(_ value: Any) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 started_at, provider_id, model_id, status,
                 input_tokens, output_tokens, cache_read_input_tokens,
                 cache_creation_input_tokens, computed_total_tokens))
        FROM model_usage
        WHERE started_at >= \(cutoffMs)
        """
    }
}
