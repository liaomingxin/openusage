import XCTest
@testable import OpenUsage

final class DailyUsageAccumulatorTests: XCTestCase {
    func testMergedScanKeepsReportedCacheAndLeavesUnreportedNil() throws {
        var cached = DailyUsageAccumulator()
        cached.add(
            day: "2026-06-26", tokens: 100, cost: 1.5, model: "cached",
            buckets: TokenBreakdown(input: 40, cacheWrite5m: 10, cacheWrite1h: 5, cacheRead: 50, output: 20)
        )
        var plain = DailyUsageAccumulator()
        plain.add(day: "2026-06-26", tokens: 80, cost: 0.5, model: "plain")

        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([cached.build(), plain.build()]))

        XCTAssertEqual(merged.series.daily, [
            DailyUsageEntry(date: "2026-06-26", totalTokens: 180, costUSD: 2)
        ])
        let models = Dictionary(uniqueKeysWithValues: (merged.modelUsage?.daily.first?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["cached"]?.inputTokens, 40)
        XCTAssertEqual(models["cached"]?.cacheReadTokens, 50)
        XCTAssertEqual(models["cached"]?.cacheWriteTokens, 15)
        XCTAssertEqual(models["cached"]?.totalTokens, 100)
        XCTAssertEqual(models["cached"]?.costUSD, 1.5)
        XCTAssertNil(models["plain"]?.inputTokens)
        XCTAssertNil(models["plain"]?.cacheReadTokens)
        XCTAssertNil(models["plain"]?.cacheWriteTokens)
        XCTAssertEqual(models["plain"]?.totalTokens, 80)
        XCTAssertEqual(models["plain"]?.costUSD, 0.5)
    }

    func testMergingAReportedBucketWithAGapStaysNil() throws {
        var reported = DailyUsageAccumulator()
        reported.add(
            day: "2026-06-26", tokens: 30, cost: 1, model: "same",
            buckets: TokenBreakdown(input: 10, cacheWrite5m: 0, cacheRead: 20, output: 0)
        )
        var gap = DailyUsageAccumulator()
        gap.add(day: "2026-06-26", tokens: 5, cost: 0.25, model: "same")

        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([reported.build(), gap.build()]))
        let model = try XCTUnwrap(merged.modelUsage?.daily.first?.models.first { $0.model == "same" })
        XCTAssertEqual(model.totalTokens, 35)
        XCTAssertEqual(model.costUSD, 1.25)
        XCTAssertNil(model.inputTokens)
        XCTAssertNil(model.cacheReadTokens)
        XCTAssertNil(model.cacheWriteTokens)
    }

    func testReportedZeroCacheStaysZero() throws {
        var scan = DailyUsageAccumulator()
        scan.add(
            day: "2026-06-26", tokens: 12, cost: 0.1, model: "zero",
            buckets: TokenBreakdown(input: 12, cacheRead: 0, output: 0)
        )
        let model = try XCTUnwrap(scan.build().modelUsage?.daily.first?.models.first)
        XCTAssertEqual(model.inputTokens, 12)
        XCTAssertEqual(model.cacheReadTokens, 0)
        XCTAssertEqual(model.cacheWriteTokens, 0)
    }

    func testHistoryWithoutCacheBucketsStillDecodes() throws {
        let json = #"{"model":"gpt-5.5","totalTokens":10,"costUSD":1}"#
        let entry = try JSONDecoder().decode(ModelUsageEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.totalTokens, 10)
        XCTAssertNil(entry.inputTokens)
        XCTAssertNil(entry.cacheReadTokens)
        XCTAssertNil(entry.cacheWriteTokens)
    }
}
