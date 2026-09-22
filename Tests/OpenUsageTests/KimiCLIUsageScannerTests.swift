import XCTest
@testable import OpenUsage

final class KimiCLIUsageScannerTests: XCTestCase {
    func testParsesTurnUsageBuckets() throws {
        let line = """
        {"kind":"event","envelope":{"type":"turn.step.completed","timestamp":"2026-09-21T10:00:00.000Z","payload":{"type":"turn.step.completed","model":"k3","usage":{"inputOther":100,"inputCacheRead":40,"inputCacheCreation":10,"output":5}}}}
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try line.write(to: directory.appendingPathComponent("session_a.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "k3": ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
            ]),
            primary: PricingCatalog(entries: [:]),
            secondary: PricingCatalog(entries: [:])
        )
        let scan = try XCTUnwrap(KimiCLIUsageScanner(eventsDirectory: { directory }).scan(
            now: OpenUsageISO8601.date(from: "2026-09-21T12:00:00.000Z")!, pricing: pricing
        ))
        let model = try XCTUnwrap(scan.modelUsage?.daily.first?.models.first)
        XCTAssertEqual(model.cacheReadTokens, 40)
        XCTAssertEqual(model.cacheWriteTokens, 10)
        XCTAssertEqual(model.inputTokens, 100)
        XCTAssertEqual(model.totalTokens, 155)
    }
}
