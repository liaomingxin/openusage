import Foundation

/// Reads Kimi Code CLI turn usage from `~/.kimi-code/server/events/session_*.jsonl`.
/// `inputOther` is uncached input. Cache creation is a cache write.
struct KimiCLIUsageScanner: Sendable {
    private let eventsDirectory: @Sendable () -> URL?

    init(eventsDirectory: @escaping @Sendable () -> URL? = KimiCLIUsageScanner.defaultDirectory) {
        self.eventsDirectory = eventsDirectory
    }

    static let defaultDirectory: @Sendable () -> URL? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/server/events")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) -> LogUsageScan? {
        guard let directory = eventsDirectory() else { return nil }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "jsonl" } ?? []
        guard !files.isEmpty else { return nil }
        var accumulator = DailyUsageAccumulator()
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for row in Self.parse(data) where row.timestamp >= since {
                let cost = pricing.estimatedCostDollars(model: row.model, tokens: row.tokens)
                guard let cost else {
                    if row.tokens.totalTokens > 0 {
                        accumulator.addUnknownModel(day: DailyUsageAccumulator.dayKey(from: row.timestamp), model: row.model)
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

    struct Row {
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
    }

    static func parse(_ data: Data) -> [Row] {
        var rows: [Row] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let envelope = object["envelope"] as? [String: Any],
                  let payload = envelope["payload"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any],
                  let timestamp = OpenUsageISO8601.date(from: envelope["timestamp"] as? String ?? "")
            else { continue }
            let input = int(usage["inputOther"])
            let cacheRead = int(usage["inputCacheRead"])
            let cacheWrite = int(usage["inputCacheCreation"])
            let output = int(usage["output"])
            guard input + cacheRead + cacheWrite + output > 0 else { continue }
            let model = (payload["model"] as? String)?.nilIfEmpty ?? "kimi"
            rows.append(Row(
                timestamp: timestamp,
                model: model,
                tokens: TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output)
            ))
        }
        return rows
    }

    private static func int(_ value: Any?) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1_000_000_000_000_000))
    }
}
