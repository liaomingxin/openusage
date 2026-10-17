import Foundation

/// Reads Muse Code CLI turn usage from `~/.local/share/muse/sessions/**/session.jsonl`.
///
/// Each completed model turn writes a `runtime.session` record with `payload.event.kind == "model_completed"`,
/// `recorded_at` in epoch microseconds, `payload.event.model`, and `payload.event.usage`
/// (`input_tokens`, `output_tokens`, `cached_tokens`, `cache_write_tokens`, `cache_read_tokens`).
struct MuseCLIUsageScanner: Sendable {
    private let sessionsDirectory: @Sendable () -> URL?

    init(sessionsDirectory: @escaping @Sendable () -> URL? = MuseCLIUsageScanner.defaultDirectory) {
        self.sessionsDirectory = sessionsDirectory
    }

    static let defaultDirectory: @Sendable () -> URL? = {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        }
        let url = base.appendingPathComponent("muse/sessions")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) -> LogUsageScan? {
        guard let root = sessionsDirectory() else { return nil }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let files = Self.discoverSessionLogs(under: root, modifiedSince: since)
        guard !files.isEmpty else { return nil }

        var accumulator = DailyUsageAccumulator()
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for row in Self.parse(data) where row.timestamp >= since {
                let cost = pricing.estimatedCostDollars(model: row.model, tokens: row.tokens)
                guard let cost else {
                    if row.tokens.totalTokens > 0 {
                        accumulator.addUnknownModel(
                            day: DailyUsageAccumulator.dayKey(from: row.timestamp),
                            model: row.model
                        )
                    }
                    continue
                }
                accumulator.add(
                    day: DailyUsageAccumulator.dayKey(from: row.timestamp),
                    tokens: row.tokens.totalTokens,
                    cost: cost,
                    model: row.model,
                    buckets: row.tokens
                )
            }
        }
        let scan = accumulator.build()
        return scan.series.daily.isEmpty && scan.unknownModelsByDay.isEmpty ? nil : scan
    }

    struct Row: Sendable, Equatable {
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
    }

    private static let modelCompletedMarker = Data(#""model_completed""#.utf8)

    static func parse(_ data: Data) -> [Row] {
        var rows: [Row] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let slice = Data(line)
            guard slice.range(of: modelCompletedMarker) != nil,
                  let root = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any],
                  (root["payload_type"] as? String) == "runtime.session",
                  let recordedAtUs = ProviderParse.number(root["recorded_at"]),
                  recordedAtUs > 0,
                  let payload = root["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any],
                  (event["kind"] as? String) == "model_completed",
                  let usage = event["usage"] as? [String: Any]
            else { continue }

            let rawInput = int(usage["input_tokens"])
            let cacheRead = max(int(usage["cache_read_tokens"]), int(usage["cached_tokens"]))
            let cacheWrite = int(usage["cache_write_tokens"])
            let uncachedInput = max(rawInput - cacheRead - cacheWrite, 0)
            let output = int(usage["output_tokens"])
            guard uncachedInput + cacheRead + cacheWrite + output > 0 else { continue }

            let rawModel = (event["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "muse-spark-1.3"
            let model = rawModel.hasPrefix("meta.") ? String(rawModel.dropFirst(5)) : rawModel
            rows.append(Row(
                timestamp: Date(timeIntervalSince1970: recordedAtUs / 1_000_000.0),
                model: model,
                tokens: TokenBreakdown(
                    input: uncachedInput,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: output
                )
            ))
        }
        return rows
    }

    private static func discoverSessionLogs(under root: URL, modifiedSince since: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "session.jsonl" else { continue }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
               values.isRegularFile == true {
                if let mtime = values.contentModificationDate, mtime < since {
                    continue
                }
                results.append(url)
            }
        }
        return results
    }

    private static func int(_ value: Any?) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }
}
