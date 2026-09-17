import XCTest
@testable import OpenUsage

/// The Agent Usage screen's machine-wide pi view: `scanAll` aggregates every provider's entries
/// (mapped cards and unmapped pi providers alike), while a card scan keeps filtering to its card.
final class PiUsageScanAllTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "claude-opus-4-8": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 10, cacheReadPerMillion: 1
            ),
            "nemotron-super": ModelRates(
                inputPerMillion: 5, outputPerMillion: 10,
                cacheWritePerMillion: 5, cacheReadPerMillion: 0.5
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func entry(
        provider: String, model: String, input: Int = 100, output: Int = 50,
        cost: Double? = 0.5, timestamp: String = "2026-07-12T10:00:00.000Z"
    ) -> PiUsageScanner.Entry {
        PiUsageScanner.Entry(
            id: "m-\(provider)-\(model)",
            timestamp: d(timestamp),
            cardID: PiProviderMapping.cardID(forPiProvider: provider) ?? provider,
            model: model,
            carriedCost: cost,
            tokens: TokenBreakdown(input: input, output: output),
            reportedTotalTokens: input + output
        )
    }

    func testParseLineKeepsUnmappedProviderLines() throws {
        let line = PiUsageScannerTestsHelper.unmappedProviderLine
        let parsed = try XCTUnwrap(PiUsageScanner.parseLine(line))
        // No OpenUsage card exists for nvidia-nim; the raw pi provider id stands in so the line
        // survives into the cached parse (card scans still filter it out at aggregation).
        XCTAssertEqual(parsed.cardID, "nvidia-nim")
        XCTAssertEqual(parsed.model, "nemotron-super")
    }

    func testScanAllAggregatesMappedAndUnmappedProviders() {
        let entries = [
            entry(provider: "anthropic", model: "claude-opus-4-8", cost: 0.5),
            entry(provider: "nvidia-nim", model: "nemotron-super", cost: 0.0),
        ]
        let scan = PiUsageScanner.aggregate(
            entries: entries, cardID: nil, since: .distantPast, pricing: pricing
        )
        let day = try! XCTUnwrap(scan.modelUsage?.daily.first)
        let models = Set(day.models.map(\.model))
        XCTAssertEqual(models, ["claude-opus-4-8", "nemotron-super"])
    }

    func testScanAllPricesZeroCostRowsThroughEngine() {
        let entries = [
            entry(provider: "nvidia-nim", model: "nemotron-super", input: 1_000_000, output: 0, cost: 0.0),
        ]
        let scan = PiUsageScanner.aggregate(
            entries: entries, cardID: nil, since: .distantPast, pricing: pricing
        )
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 5.0, accuracy: 0.0001)
    }

    func testCardScanStillFiltersToItsCard() {
        let entries = [
            entry(provider: "anthropic", model: "claude-opus-4-8", cost: 0.5),
            entry(provider: "nvidia-nim", model: "nemotron-super", cost: 0.5),
        ]
        let scan = PiUsageScanner.aggregate(
            entries: entries, cardID: "claude", since: .distantPast, pricing: pricing
        )
        let day = try! XCTUnwrap(scan.modelUsage?.daily.first)
        XCTAssertEqual(day.models.map(\.model), ["claude-opus-4-8"])
    }
}

/// Namespace so the shared fixture line reads clearly in the test body.
private enum PiUsageScannerTestsHelper {
    /// A pi assistant usage line whose provider has no OpenUsage card.
    static let unmappedProviderLine: Data = {
        let json = """
        {"type":"message","id":"m-nim","timestamp":"2026-07-12T10:00:00.000Z",\
        "message":{"role":"assistant","provider":"nvidia-nim","model":"nemotron-super",\
        "usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"cacheWrite1h":0,\
        "totalTokens":150,"cost":{"total":0.25}}}}
        """
        return Data(json.utf8)
    }()
}
