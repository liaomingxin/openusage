import XCTest
@testable import OpenUsage

/// The pi log fold-in: parse pi's assistant usage lines, attribute them to the mapped OpenUsage card,
/// and price by pi's carried cost (else the engine). Also covers the shared scan-merge that folds the
/// pi slice into a provider's native scan.
final class PiUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }

    /// Fixture pricing so the carried-$0 fall-through can be exercised: composer priced at $10/M input.
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "composer-2.5": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 10, cacheReadPerMillion: 1
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private let codexPricing = ModelPricing(
        supplement: PricingSupplement(pricing: [
            "gpt-5.6-sol": ModelRates(
                inputPerMillion: 5,
                outputPerMillion: 30,
                cacheWritePerMillion: 6.25,
                cacheReadPerMillion: 0.5
            )
        ]),
        primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    private func line(
        id: String = "m1", ts: String = "2026-07-12T10:00:00.000Z", provider: String = "anthropic",
        model: String = "claude-opus-4-8", input: Int = 100, output: Int = 50,
        cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, total: Int = 150,
        cost: String? = "0.5", serviceTier: String? = nil
    ) -> Data {
        let costJSON = cost.map { ",\"cost\":{\"total\":\($0)}" } ?? ""
        let tierJSON = serviceTier.map { ",\"serviceTier\":\"\($0)\"" } ?? ""
        let json = """
        {"type":"message","id":"\(id)","timestamp":"\(ts)","message":{"role":"assistant","provider":"\(provider)","model":"\(model)"\(tierJSON),"usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),"cacheWrite1h":\(cacheWrite1h),"totalTokens":\(total)\(costJSON)}}}
        """
        return Data(json.utf8)
    }

    // MARK: - Parsing

    func testParsesMappedAnthropicLine() {
        let entry = PiUsageScanner.parseLine(line())
        XCTAssertEqual(entry?.cardID, "claude")
        XCTAssertEqual(entry?.model, "claude-opus-4-8")
        XCTAssertEqual(entry?.carriedCost, 0.5)
        XCTAssertEqual(entry?.reportedTotalTokens, 150)
        XCTAssertEqual(entry?.tokens.input, 100)
        XCTAssertEqual(entry?.tokens.output, 50)
    }

    func testSplitsCacheWriteBucketsBy1hPortion() {
        let entry = PiUsageScanner.parseLine(line(cacheWrite: 1000, cacheWrite1h: 400))
        XCTAssertEqual(entry?.tokens.cacheWrite1h, 400)
        XCTAssertEqual(entry?.tokens.cacheWrite5m, 600)
    }

    func testMapsCodexAndKeepsUnmappedLinesForScanAll() {
        XCTAssertEqual(PiUsageScanner.parseLine(line(provider: "openai-codex"))?.cardID, "codex")
        // Unmapped providers have no OpenUsage card, but their lines now parse (the raw pi provider
        // id stands in as cardID) so the Agent Usage screen's machine-wide scanAll sees every model;
        // card scans filter them out at aggregation (see PiUsageScanAllTests).
        XCTAssertEqual(PiUsageScanner.parseLine(line(provider: "nvidia-nim"))?.cardID, "nvidia-nim")
        let userLine = Data(#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"user","provider":"anthropic","usage":{}}}"#.utf8)
        XCTAssertNil(PiUsageScanner.parseLine(userLine))
    }

    // MARK: - Aggregation

    func testCarriedCostUsedWhenPresent() {
        let scan = PiUsageScanner.aggregate(
            entries: [PiUsageScanner.parseLine(line(cost: "0.5"))!],
            cardID: "claude", since: .distantPast, pricing: .empty
        )
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
    }

    func testZeroCarriedCostFallsThroughToPricing() {
        // Cursor logs $0; the engine prices composer's 100 input @ $10/M + 50 output @ $20/M = $0.002.
        let entry = PiUsageScanner.parseLine(line(provider: "cursor", model: "composer-2.5", cost: "0"))!
        let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: pricing)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.002, accuracy: 0.00001)
    }

    func testZeroCostCodexFallbackUsesCodexLongContextRates() throws {
        let pricing = codexPricing
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(line(
            provider: "openai-codex", model: "gpt-5.6-sol",
            input: 200_000, output: 10_000, cacheRead: 100_000, total: 310_000, cost: "0"
        )))
        let scan = PiUsageScanner.aggregate(
            entries: [entry], cardID: "codex", since: .distantPast, pricing: pricing,
            estimateCost: { CodexUsagePricing.estimatedCost(pricing: pricing, model: $0, tokens: $1) }
        )

        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 1.98, accuracy: 0.000_001)
    }

    func testPositiveCarriedCodexCostWinsOverSharedEstimator() throws {
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(line(
            provider: "openai-codex", model: "gpt-5.6-sol",
            input: 200_000, output: 10_000, cacheRead: 100_000, total: 310_000, cost: "0.25"
        )))
        let scan = PiUsageScanner.aggregate(
            entries: [entry], cardID: "codex", since: .distantPast, pricing: codexPricing
        )

        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.cacheReadTokens, 100_000)
    }

    func testUnpriceableZeroCostBecomesUnknownModel() {
        let entry = PiUsageScanner.parseLine(line(provider: "cursor", model: "mystery-model", cost: "0"))!
        let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: .empty)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay["2026-07-12"], ["mystery-model"])
    }

    func testDedupDropsRepeatedIDs() {
        let entries = [PiUsageScanner.parseLine(line(id: "dup"))!, PiUsageScanner.parseLine(line(id: "dup"))!]
        let scan = PiUsageScanner.aggregate(entries: PiUsageScanner.dedup(entries), cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.5, accuracy: 0.0001)
    }

    func testFiltersToRequestedCard() {
        let scan = PiUsageScanner.aggregate(
            entries: [PiUsageScanner.parseLine(line(provider: "openai-codex"))!],
            cardID: "claude", since: .distantPast, pricing: .empty
        )
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    // MARK: - Mapping and merge

    func testProviderMapping() {
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "claude-agent-sdk"), "claude")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "zhipu"), "zai")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "xai-oauth"), "grok")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "moonshot"), "kimi")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "kimi-code"), "kimi")
        XCTAssertNil(PiProviderMapping.cardID(forPiProvider: "nvidia-nim"))
    }

    /// omp stamps subscription rows with `message.serviceTier`. A tiered openai-codex row must drop
    /// omp's subscription-quota-basis carried cost (8x ultrafast) and carry the tier flags instead,
    /// so pricing goes through the tier-aware Codex estimator at the credits basis (6x) — the same
    /// numbers the Codex card's own logs produce. Untiered rows keep their carried total.
    func testTieredCodexRowsDropSubscriptionBasisCarriedCost() {
        let tiered = PiUsageScanner.parseLine(line(
            provider: "openai-codex", model: "gpt-6.1-sol", cost: "0.163", serviceTier: "ultrafast"
        ))
        XCTAssertNil(tiered?.carriedCost)
        XCTAssertTrue(tiered?.tokens.isUltrafast ?? false)
        XCTAssertFalse(tiered?.tokens.isFast ?? true)

        let fast = PiUsageScanner.parseLine(line(
            provider: "openai-codex", model: "gpt-6.1-sol", cost: "0.05", serviceTier: "fast"
        ))
        XCTAssertNil(fast?.carriedCost)
        XCTAssertTrue(fast?.tokens.isFast ?? false)

        // Untiered (BYO-key API) rows keep pi's real-money carried cost.
        let plain = PiUsageScanner.parseLine(line(provider: "openai-codex", model: "gpt-6.1-sol"))
        XCTAssertEqual(plain?.carriedCost, 0.5)
        // A tiered non-codex provider (none known today) keeps its carried cost — the tier drop is
        // scoped to the basis clash we measured on codex subscriptions.
        let tieredOther = PiUsageScanner.parseLine(line(
            provider: "xai-oauth", model: "grok-4.7", cost: "0.02", serviceTier: "ultrafast"
        ))
        XCTAssertEqual(tieredOther?.carriedCost, 0.02)
    }

    /// omp sometimes prefixes the model slug with its own provider id ("openai-codex/gpt-6.1-sol",
    /// "moonshot/kimi-k2.7-code") — the prefix is stripped at parse time so the slug prices.
    func testProviderPrefixedModelSlugIsStripped() {
        let entry = PiUsageScanner.parseLine(line(provider: "moonshot", model: "moonshot/kimi-k2.7-code"))
        XCTAssertEqual(entry?.model, "kimi-k2.7-code")
        XCTAssertEqual(entry?.cardID, "kimi")

        let codex = PiUsageScanner.parseLine(line(provider: "openai-codex", model: "openai-codex/gpt-6.1-sol"))
        XCTAssertEqual(codex?.model, "gpt-6.1-sol")
    }

    /// Cached parses written before `isUltrafast` existed must keep decoding (tier flags default
    /// to false), so the added field doesn't invalidate every scanner's persisted cache.
    func testTokenBreakdownDecodesLegacyJSONWithoutTierFlags() throws {
        let legacy = Data("""
        {"input":10,"cacheRead":5,"output":2,"isFast":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(TokenBreakdown.self, from: legacy)
        XCTAssertEqual(decoded.input, 10)
        XCTAssertEqual(decoded.cacheRead, 5)
        XCTAssertEqual(decoded.output, 2)
        XCTAssertTrue(decoded.isFast)
        XCTAssertFalse(decoded.isUltrafast)
    }

    /// omp writes the same usage jsonl under `~/.omp/agent/sessions`. A card's fold-in must see
    /// both roots (all grok usage lands on the grok card, whichever agent produced it), while the
    /// Agent Usage screen's per-root scans keep pi and omp in separate rows.
    func testOmpRootFoldsIntoCardsAndStaysSeparateOnAgentUsage() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-tests-\(UUID().uuidString)", isDirectory: true)
        let piSessions = home.appendingPathComponent(".pi/agent/sessions/-proj", isDirectory: true)
        let ompSessions = home.appendingPathComponent(".omp/agent/sessions/-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: piSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ompSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try line(id: "pi-1", ts: "2026-07-12T10:00:00.000Z", provider: "xai", model: "grok-4.7",
                 input: 100, output: 50, total: 150, cost: "0.5")
            .write(to: piSessions.appendingPathComponent("s.jsonl"))
        try line(id: "omp-1", ts: "2026-07-12T11:00:00.000Z", provider: "xai-oauth", model: "grok-4.7",
                 input: 80, output: 40, total: 120, cost: "0.25")
            .write(to: ompSessions.appendingPathComponent("s.jsonl"))

        let scanner = PiUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>(
                logTag: LogTag.plugin("pi-test"),
                persistence: JSONLScanCachePersistence(
                    namespace: "pitest", schemaVersion: 1,
                    directory: home.appendingPathComponent("cache", isDirectory: true)
                )
            )
        )
        let now = d("2026-07-15T00:00:00.000Z")

        // Card fold-in: both roots' grok usage lands on the grok card.
        let grok = await scanner.scan(cardID: "grok", daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(grok?.series.daily.first?.totalTokens, 270)
        XCTAssertEqual(grok?.series.daily.first?.costUSD ?? 0, 0.75, accuracy: 1e-9)

        // Agent Usage: each root keeps its own row.
        let omp = await scanner.scanAll(root: .omp, daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(omp?.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(omp?.series.daily.first?.costUSD ?? 0, 0.25, accuracy: 1e-9)
        let pi = await scanner.scanAll(root: .pi, daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(pi?.series.daily.first?.totalTokens, 150)
    }

    func testSubscriptionProvidersLandOnTheRightCardWithoutChangingAZAIHeadline() {
        let cases: [(String, String, SubscriptionSpendMode)] = [
            ("zai-coding-cn", "zai", .thisMacDetail),
            ("kimi-coding", "kimi", .addToLocalSpend),
            ("xai", "grok", .addToLocalSpend),
            ("openai-codex", "codex", .addToLocalSpend)
        ]
        for (provider, card, mode) in cases {
            let entry = PiUsageScanner.parseLine(line(id: provider, provider: provider, model: "m", cost: "1"))!
            XCTAssertEqual(entry.cardID, card, provider)
            XCTAssertEqual(SubscriptionAttributionRules.attribution(providerID: provider)?.mode, mode, provider)
            let onCard = PiUsageScanner.aggregate(entries: [entry], cardID: card, since: .distantPast, pricing: .empty)
            XCTAssertEqual(onCard.series.daily.first?.totalTokens, 150, provider)
            let elsewhere = PiUsageScanner.aggregate(entries: [entry], cardID: "claude", since: .distantPast, pricing: .empty)
            XCTAssertTrue(elsewhere.series.daily.isEmpty, provider)
        }

        let zai = PiUsageScanner.aggregate(
            entries: [PiUsageScanner.parseLine(line(id: "z", provider: "zai-coding-cn", cost: "1"))!],
            cardID: "zai", since: .distantPast, pricing: .empty
        )
        let headline = DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-07-12", totalTokens: 10, costUSD: nil)])
        let history = ProviderUsageHistory(
            series: headline,
            thisMacSeries: zai.series,
            thisMacModelUsage: zai.modelUsage
        )
        XCTAssertEqual(history.series.daily.first?.totalTokens, 10)
        XCTAssertEqual(history.thisMacSeries?.daily.first?.totalTokens, 150)
    }

    func testMergedSumsNativeAndPiOnSameDay() {
        let native = DailyUsageAccumulator.merged([
            PiUsageScanner.aggregate(entries: [PiUsageScanner.parseLine(line(id: "n", cost: "1.0"))!], cardID: "claude", since: .distantPast, pricing: .empty)
        ])
        let pi = PiUsageScanner.aggregate(entries: [PiUsageScanner.parseLine(line(id: "p", cost: "0.5"))!], cardID: "claude", since: .distantPast, pricing: .empty)
        let merged = DailyUsageAccumulator.merged([native, pi])
        XCTAssertEqual(merged?.series.daily.first?.costUSD ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(merged?.series.daily.first?.totalTokens, 300)
    }

    func testMergedReturnsNilWhenAllNil() {
        XCTAssertNil(DailyUsageAccumulator.merged([nil, nil]))
    }
}
