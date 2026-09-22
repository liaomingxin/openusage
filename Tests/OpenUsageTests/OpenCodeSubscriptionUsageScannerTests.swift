import XCTest
@testable import OpenUsage

final class OpenCodeSubscriptionUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let pricing = ModelPricing(
        supplement: PricingSupplement(pricing: [
            "gpt-test": ModelRates(inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2, cacheReadPerMillion: 0.2),
            "glm-5.3": ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
        ]),
        primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    private func ms(_ iso: String) -> Int {
        Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    /// `[time, cost, total, model, provider, input, cacheRead, cacheWrite, output, id]`
    private func row(
        _ iso: String, cost: String, model: String, provider: String,
        input: Int, cacheRead: Int = 0, output: Int, id: String
    ) -> String {
        "[\(ms(iso)),\(cost),0,\"\(model)\",\"\(provider)\",\(input),\(cacheRead),0,\(output),\"\(id)\"]"
    }

    private func scanner(auth: String, rows: String) -> OpenCodeSubscriptionUsageScanner {
        OpenCodeSubscriptionUsageScanner(
            authStore: openCodeAuthStore(files: FakeFiles(["/oc/auth.json": auth])),
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[\(rows)]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
    }

    func testOAuthZeroCostStaysOutAndAPIKeyCostIsPricedNotRecorded() async {
        let rows = [
            row("2026-07-12T10:00:00.000Z", cost: "0", model: "gpt-test", provider: "openai", input: 100, output: 20, id: "oauth"),
            row("2026-07-12T11:00:00.000Z", cost: "9", model: "gpt-test", provider: "openai", input: 100, output: 20, id: "api")
        ].joined(separator: ",")
        let result = await scanner(auth: #"{"openai":{"type":"api","key":"sk"}}"#, rows: rows).scan(now: now, pricing: pricing)
        let day = result.localSpend["codex"]?.series.daily.first
        XCTAssertEqual(day?.totalTokens, 120)
        // 100 * $2/M + 20 * $10/M. The recorded $9 is not added.
        XCTAssertEqual(day?.costUSD ?? -1, 0.0004, accuracy: 0.0000001)
        XCTAssertNil(result.thisMac["zai"])
    }

    func testZAICodingPlanIsThisMacAndCliproxyIsNowhere() async {
        let rows = [
            row("2026-07-12T10:00:00.000Z", cost: "0", model: "glm-5.3", provider: "zai-coding-plan", input: 1000, cacheRead: 400, output: 10, id: "zai"),
            row("2026-07-12T10:00:00.000Z", cost: "0", model: "gpt-5.4", provider: "cliproxy-openai", input: 5000, output: 10, id: "proxy")
        ].joined(separator: ",")
        let result = await scanner(
            auth: #"{"zai-coding-plan":{"type":"api","key":"k"}}"#,
            rows: rows
        ).scan(now: now, pricing: pricing)
        XCTAssertNil(result.localSpend["codex"])
        XCTAssertNil(result.localSpend["opencode"])
        let zai = result.thisMac["zai"]?.modelUsage?.daily.first?.models.first
        XCTAssertEqual(zai?.model, "glm-5.3")
        XCTAssertEqual(zai?.cacheReadTokens, 400)
        XCTAssertEqual(result.thisMac["zai"]?.series.daily.first?.totalTokens, 1410)
    }
}
