import XCTest
@testable import OpenUsage

final class ZCodeUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-09-21T12:00:00.000Z")!
    private let pricing = ModelPricing(
        supplement: PricingSupplement(pricing: [
            "GLM-5.3": ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
        ]),
        primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    func testCompletedBigModelRowDropsCacheFromInput() async throws {
        let ms = Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let rows = """
        [\(ms),"builtin:bigmodel-coding-plan","GLM-5.3","completed",232,9,192,0,241],
        [\(ms),"builtin:bigmodel-coding-plan","GLM-5.3","error",100,10,0,0,110],
        [\(ms),"openai","gpt-5.5","completed",50,10,0,0,60]
        """
        let scanner = ZCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/z/db.sqlite": "[\(rows)]"]),
            databasePath: { "/z/db.sqlite" }
        )
        let scanned = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(scanned)
        let model = try XCTUnwrap(scan.modelUsage?.daily.first?.models.first)
        XCTAssertEqual(model.model, "GLM-5.3")
        XCTAssertEqual(model.inputTokens, 40)
        XCTAssertEqual(model.cacheReadTokens, 192)
        XCTAssertEqual(model.totalTokens, 241)
        let rate = try XCTUnwrap(CacheUsage.hitRate(
            input: model.inputTokens, cacheRead: model.cacheReadTokens, cacheWrite: model.cacheWriteTokens
        ))
        XCTAssertLessThanOrEqual(rate, 1)
        XCTAssertEqual(scan.series.daily.count, 1)
    }
}
