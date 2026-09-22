import XCTest
@testable import OpenUsage

final class CacheHoverTests: XCTestCase {
    func testCacheCaptionAppearsOnlyWhenCacheWasReported() {
        let cached = ModelUsageEntry(
            model: "glm", totalTokens: 241, costUSD: 1,
            inputTokens: 40, cacheReadTokens: 192, cacheWriteTokens: 0
        )
        let caption = ModelShareRow.cacheCaption(for: cached)
        XCTAssertTrue(caption?.contains("% hit") == true)
        XCTAssertNil(ModelShareRow.cacheCaption(for: ModelUsageEntry(model: "plain", totalTokens: 10, costUSD: 1)))
    }

    func testPeriodHitRateIgnoresAModelThatDidNotReportCache() {
        let cached = ModelUsageEntry(model: "a", totalTokens: 10, inputTokens: 5, cacheReadTokens: 5, cacheWriteTokens: 0)
        let gap = ModelUsageEntry(model: "b", totalTokens: 10, costUSD: 1)
        XCTAssertNil(ModelUsageDetail.periodHitRate([cached, gap]))
        XCTAssertEqual(ModelUsageDetail.periodHitRate([cached]) ?? -1, 0.5, accuracy: 0.001)
    }

    func testThisMacDoesNotChangeTheHeadlineTotal() {
        let headline = ModelUsageBreakdown(
            totalTokens: 2_000_000,
            totalCostUSD: nil,
            models: [ModelUsageEntry(model: "GLM-5.3", totalTokens: 2_000_000)],
            sourceNote: "From Z.ai",
            thisMacModels: [ModelUsageEntry(
                model: "GLM-5.3", totalTokens: 241,
                inputTokens: 40, cacheReadTokens: 192, cacheWriteTokens: 0
            )],
            thisMacSourceNote: "This Mac"
        )
        XCTAssertEqual(headline.totalTokens, 2_000_000)
        XCTAssertNil(ModelShareRow.cacheCaption(for: headline.models[0]))
        XCTAssertNotNil(ModelShareRow.cacheCaption(for: headline.thisMacModels![0]))
    }
}
