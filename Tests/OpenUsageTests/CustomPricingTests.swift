import XCTest
@testable import OpenUsage

/// The user-editable pricing override file (`~/.config/openusage/custom-pricing.json`): decode
/// semantics (explicit 0 = free, omitted = unknown), its win over every other source, the spend
/// tile's unpriced-reason hints, and the store's mtime-gated reload with loud corruption handling.
final class CustomPricingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var customFileURL: URL {
        tempDir.appendingPathComponent("custom-pricing.json")
    }

    private func writeCustomPricing(_ json: String, modified: Date? = nil) throws {
        try Data(json.utf8).write(to: customFileURL, options: .atomic)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: customFileURL.path)
        }
    }

    // MARK: - Decode semantics

    func testDecodeAcceptsFullAndPartialEntriesAndIgnoresUnknownKeys() throws {
        let custom = try CustomPricing.decode(from: Data("""
        {"models": {
          "full-model": {"input_cost_per_million_tokens": 0.6, "output_cost_per_million_tokens": 2.2,
                          "cache_read_cost_per_million_tokens": 0.06, "cache_write_cost_per_million_tokens": 0.75},
          "partial-model": {"input_cost_per_million_tokens": 1, "output_cost_per_million_tokens": 4},
          "free-model": {"input_cost_per_million_tokens": 0, "output_cost_per_million_tokens": 0,
                          "cache_read_cost_per_million_tokens": 0, "cache_write_cost_per_million_tokens": 0}
        }, "future_field": 42}
        """.utf8))

        let full = try XCTUnwrap(custom.rates(for: "full-model"))
        XCTAssertEqual(full.inputPerMillion, 0.6)
        XCTAssertEqual(full.outputPerMillion, 2.2)
        XCTAssertEqual(full.cacheReadPerMillion, 0.06)
        XCTAssertEqual(full.cacheWritePerMillion, 0.75)
        XCTAssertTrue(full.unpricedBuckets.isEmpty)

        let partial = try XCTUnwrap(custom.rates(for: "partial-model"))
        XCTAssertTrue(partial.unpricedBuckets.contains(.cacheWrite))
        XCTAssertTrue(partial.unpricedBuckets.contains(.cacheRead))
        XCTAssertFalse(partial.unpricedBuckets.contains(.input))
        XCTAssertEqual(custom.missingFieldNames(for: "partial-model"), ["cache write", "cache read"])

        let free = try XCTUnwrap(custom.rates(for: "free-model"))
        XCTAssertEqual(free.inputPerMillion, 0)
        XCTAssertEqual(free.outputPerMillion, 0)
        XCTAssertTrue(free.unpricedBuckets.isEmpty)
    }

    func testDecodeRejectsMalformedFilesWithFieldPreciseErrors() {
        XCTAssertThrowsError(try CustomPricing.decode(from: Data("[1,2]".utf8)))
        XCTAssertThrowsError(try CustomPricing.decode(from: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? CustomPricingError, .modelsMissing)
        }
        XCTAssertThrowsError(try CustomPricing.decode(from: Data(#"{"models": []}"#.utf8))) { error in
            XCTAssertEqual(error as? CustomPricingError, .modelsNotAnObject)
        }
        XCTAssertThrowsError(try CustomPricing.decode(from: Data(#"{"models": {"m": 3}}"#.utf8))) { error in
            XCTAssertEqual(error as? CustomPricingError, .entryNotAnObject(model: "m"))
        }
        XCTAssertThrowsError(
            try CustomPricing.decode(
                from: Data(#"{"models": {"m": {"input_cost_per_million_tokens": "free"}}}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? CustomPricingError, .invalidFieldValue(model: "m", field: "input_cost_per_million_tokens"))
        }
    }

    // MARK: - Resolution priority

    /// A snapshot with one model priced by every source; the custom file must win for all of them.
    private func makePricing(custom: CustomPricing) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(pricing: [
                "overridden-model": ModelRates(
                    inputPerMillion: 9, outputPerMillion: 9, cacheWritePerMillion: 9, cacheReadPerMillion: 9
                )
            ]),
            custom: custom,
            primary: PricingCatalog(entries: [
                "overridden-model": ModelRates(inputPerMillion: 8, outputPerMillion: 8, cacheWritePerMillion: 8, cacheReadPerMillion: 8),
                "catalog-only-model": ModelRates(inputPerMillion: 1, outputPerMillion: 5, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
            ]),
            secondary: PricingCatalog()
        )
    }

    private let fullOverride = #"{"models": {"overridden-model": {"input_cost_per_million_tokens": 0.6, "output_cost_per_million_tokens": 2.2, "cache_read_cost_per_million_tokens": 0.06, "cache_write_cost_per_million_tokens": 0.75}}}"#

    func testCustomEntryOverridesSupplementAndCatalogs() throws {
        let custom = try CustomPricing.decode(from: Data(fullOverride.utf8))
        let pricing = makePricing(custom: custom)

        let rates = try XCTUnwrap(pricing.resolve(model: "overridden-model"))
        XCTAssertEqual(rates.inputPerMillion, 0.6)
        XCTAssertEqual(rates.outputPerMillion, 2.2)
        XCTAssertEqual(rates.cacheReadPerMillion, 0.06)
        XCTAssertEqual(rates.cacheWritePerMillion, 0.75)

        // Sources without an override price exactly as before.
        XCTAssertEqual(pricing.resolve(model: "catalog-only-model")?.inputPerMillion, 1)
        XCTAssertNil(pricing.resolve(model: "never-seen-model"))
    }

    func testExplicitZeroIsAFreePriceNotAnUnknown() throws {
        let custom = try CustomPricing.decode(from: Data("""
        {"models": {
          "free-model": {"input_cost_per_million_tokens": 0, "output_cost_per_million_tokens": 0,
                          "cache_read_cost_per_million_tokens": 0, "cache_write_cost_per_million_tokens": 0},
          "free-cache-model": {"input_cost_per_million_tokens": 1, "output_cost_per_million_tokens": 4,
                                "cache_read_cost_per_million_tokens": 0}
        }}
        """.utf8))
        let pricing = makePricing(custom: custom)

        let cost = pricing.estimatedCostDollars(
            model: "free-model",
            tokens: TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        )
        // A $0 rate is a real price: the request prices (at zero), instead of staying unknown.
        XCTAssertEqual(try XCTUnwrap(cost), 0, accuracy: 0.000_001)

        // An explicit 0 cache read is likewise a published price: cached input bills at $0, and only
        // the omitted cache-write field keeps its bucket unknown.
        let cached = pricing.estimatedCostDollars(
            model: "free-cache-model", tokens: TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        )
        XCTAssertEqual(try XCTUnwrap(cached), 5, accuracy: 0.000_001)
    }

    func testOmittedFieldIsUnknownNotZero() throws {
        // Input/output published, both cache fields omitted. Requests touching only known buckets
        // price; a request touching an omitted bucket stays unpriced — never silently $0.
        let custom = try CustomPricing.decode(from: Data(
            #"{"models": {"partial-model": {"input_cost_per_million_tokens": 1, "output_cost_per_million_tokens": 4}}}"#.utf8
        ))
        let pricing = makePricing(custom: custom)

        let plain = pricing.estimatedCostDollars(model: "partial-model", tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000))
        XCTAssertEqual(try XCTUnwrap(plain), 5, accuracy: 0.000_001)

        let withCacheRead = pricing.estimatedCostDollars(
            model: "partial-model", tokens: TokenBreakdown(input: 0, cacheRead: 1_000_000, output: 0)
        )
        XCTAssertNil(withCacheRead, "an omitted cache-read rate must not bill at the synthesized $0 placeholder")

        let withCacheWrite = pricing.estimatedCostDollars(
            model: "partial-model", tokens: TokenBreakdown(input: 0, cacheWrite5m: 500_000, output: 0)
        )
        XCTAssertNil(withCacheWrite)
    }

    func testUnpricedReasonDistinguishesUnknownModelFromIncompleteCustomEntry() throws {
        let custom = try CustomPricing.decode(from: Data(
            #"{"models": {"partial-model": {"input_cost_per_million_tokens": 1}}}"#.utf8
        ))
        let pricing = makePricing(custom: custom)

        XCTAssertEqual(pricing.unpricedReason(for: "never-seen-model"), .unknownModel)
        XCTAssertEqual(
            pricing.unpricedReason(for: "partial-model"),
            .incompleteCustomRates(missingFields: ["output", "cache write", "cache read"])
        )
        // A model every source prices has no reason to warn.
        XCTAssertNil(pricing.unpricedReason(for: "catalog-only-model"))
    }

    // MARK: - Per-bucket omission behavior

    /// One omitted field per row. Each row holds its own guard in `ModelRates.costDollars`
    /// accountable: a request whose usage falls in the omitted bucket must come back unpriced
    /// (never silently $0 or a synthesized fallback), a request avoiding that bucket must price
    /// normally at the published fields, and the spend tile's warning must name the omitted field.
    /// The rows are separate cases (not one merged entry) so deleting any single guard line fails
    /// exactly its own row.
    func testEachOmittedFieldKeepsItsBucketUnpricedButPricesUntouchedBuckets() throws {
        struct OmissionCase {
            let model: String
            let entry: CustomPricing.Entry
            let omittedField: String
            let touching: TokenBreakdown
            let avoiding: TokenBreakdown
            let avoidingCost: Double
        }

        // Entry template rates per million: input 1, output 4, cache write 0.5, cache read 0.1 —
        // each row removes exactly one of them.
        let cases = [
            OmissionCase(
                model: "omit-input",
                entry: CustomPricing.Entry(inputPerMillion: nil, outputPerMillion: 4, cacheWritePerMillion: 0.5, cacheReadPerMillion: 0.1),
                omittedField: "input",
                touching: TokenBreakdown(input: 1_000_000),
                avoiding: TokenBreakdown(cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000),
                avoidingCost: 0.5 + 0.1 + 4
            ),
            OmissionCase(
                model: "omit-output",
                entry: CustomPricing.Entry(inputPerMillion: 1, outputPerMillion: nil, cacheWritePerMillion: 0.5, cacheReadPerMillion: 0.1),
                omittedField: "output",
                touching: TokenBreakdown(output: 1_000_000),
                avoiding: TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000),
                avoidingCost: 1 + 0.5 + 0.1
            ),
            OmissionCase(
                model: "omit-cache-write",
                entry: CustomPricing.Entry(inputPerMillion: 1, outputPerMillion: 4, cacheWritePerMillion: nil, cacheReadPerMillion: 0.1),
                omittedField: "cache write",
                touching: TokenBreakdown(cacheWrite5m: 1_000_000),
                avoiding: TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000),
                avoidingCost: 1 + 0.1 + 4
            ),
            OmissionCase(
                model: "omit-cache-read",
                entry: CustomPricing.Entry(inputPerMillion: 1, outputPerMillion: 4, cacheWritePerMillion: 0.5, cacheReadPerMillion: nil),
                omittedField: "cache read",
                touching: TokenBreakdown(cacheRead: 1_000_000),
                avoiding: TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, output: 1_000_000),
                avoidingCost: 1 + 0.5 + 4
            )
        ]

        var custom = CustomPricing(entries: [:])
        for testCase in cases {
            custom.entries[testCase.model] = testCase.entry
        }
        let pricing = makePricing(custom: custom)

        for testCase in cases {
            XCTAssertNil(
                pricing.estimatedCostDollars(model: testCase.model, tokens: testCase.touching),
                "usage in the omitted \(testCase.omittedField) bucket must stay unpriced, not bill at a placeholder"
            )
            let priced = try XCTUnwrap(
                pricing.estimatedCostDollars(model: testCase.model, tokens: testCase.avoiding),
                "usage avoiding the omitted \(testCase.omittedField) bucket must still price"
            )
            XCTAssertEqual(priced, testCase.avoidingCost, accuracy: 0.000_001, testCase.omittedField)
            XCTAssertEqual(
                pricing.unpricedReason(for: testCase.model),
                .incompleteCustomRates(missingFields: [testCase.omittedField]),
                testCase.omittedField
            )
        }

        // Every omission also reaches the spend tile's warning with its own field named.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = DailyUsageAccumulator.dayKey(from: now)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            todaySeries(now: now), to: &lines, now: now,
            unknownModelsByDay: [day: Set(cases.map(\.model))],
            pricing: pricing
        )
        guard case .values(_, _, _, _, let unknownModels, _)? = lines.first else {
            return XCTFail("Missing spend row")
        }
        XCTAssertEqual(unknownModels, cases.map { "\($0.model) (custom price omits \($0.omittedField) rates)" }.sorted())
    }

    /// The input guard's other half: 1-hour cache writes bill at twice the *input* rate, so an
    /// omitted input field must block them too — including on a request whose plain input is 0.
    func testOmittedInputRateAlsoBlocksOneHourCacheWrites() throws {
        let custom = CustomPricing(entries: [
            "omit-input": CustomPricing.Entry(inputPerMillion: nil, outputPerMillion: 4, cacheWritePerMillion: 0.5, cacheReadPerMillion: 0.1)
        ])
        let pricing = makePricing(custom: custom)

        XCTAssertNil(pricing.estimatedCostDollars(model: "omit-input", tokens: TokenBreakdown(cacheWrite1h: 1_000_000)))
        // The same entry still prices a request that bills no input-derived bucket at all.
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "omit-input", tokens: TokenBreakdown(output: 1_000_000))),
            4,
            accuracy: 0.000_001
        )
    }

    // MARK: - Spend tile hints

    private func todaySeries(now: Date) -> DailyUsageSeries {
        DailyUsageSeries(daily: [DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 1_000, costUSD: 0.5)])
    }

    func testSpendTileAnnotatesUnknownModelsWithReasonsAndNamesTheRemedy() throws {
        let custom = try CustomPricing.decode(from: Data(
            #"{"models": {"partial-model": {"input_cost_per_million_tokens": 1}}}"#.utf8
        ))
        let pricing = makePricing(custom: custom)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            todaySeries(now: now), to: &lines, now: now,
            unknownModelsByDay: [DailyUsageAccumulator.dayKey(from: now): ["never-seen-model", "partial-model"]],
            pricing: pricing
        )

        guard case .values(_, _, _, _, let unknownModels, _)? = lines.first else {
            return XCTFail("Missing spend row")
        }
        XCTAssertEqual(unknownModels, [
            "never-seen-model (no known price)",
            "partial-model (custom price omits output, cache write, cache read rates)"
        ])

        var tile = WidgetData(title: "Today", icon: .providerMark("codex"), kind: .dollars, used: 0)
        tile.values = [MetricValue(number: 0.5, kind: .dollars)]
        tile.hasData = true
        tile.unknownModels = unknownModels
        XCTAssertEqual(
            tile.unknownModelTooltip,
            "Unknown models found\n"
                + "- never-seen-model (no known price)\n"
                + "- partial-model (custom price omits output, cache write, cache read rates)\n"
                + "Add prices in ~/.config/openusage/custom-pricing.json."
        )
    }

    func testUnreadableCustomFileSurfacesOnTheSpendTileWarning() throws {
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            custom: .empty,
            customPricingProblem: "Couldn't read the custom pricing file: no \"models\" object found.",
            primary: PricingCatalog(),
            secondary: PricingCatalog()
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            todaySeries(now: now), to: &lines, now: now,
            unknownModelsByDay: [:],
            pricing: pricing
        )

        // No unknown models — but the broken file itself must still raise the warning triangle so
        // silently-ignored overrides can't hide.
        guard case .values(_, _, _, _, let unknownModels, _)? = lines.first else {
            return XCTFail("Missing spend row")
        }
        XCTAssertEqual(unknownModels, ["Couldn't read the custom pricing file: no \"models\" object found."])
    }

    // MARK: - Store integration (mtime-gated reload, corruption, absence)

    private static let bundledFixtures: @Sendable (String) -> Data? = { name in
        switch name {
        case "pricing_supplement":
            return Data(#"{"pricing": {}, "fast_multipliers": {}, "alias_rules": []}"#.utf8)
        case "pricing_litellm_snapshot":
            return Data(#"{"models": {"catalog-model": {"i": 1, "o": 2, "cw": 1, "cr": 0.1}}}"#.utf8)
        default:
            return nil
        }
    }

    private func makeStore() -> ModelPricingStore {
        ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            customPricingURL: customFileURL,
            bundledData: Self.bundledFixtures
        )
    }

    func testAbsentFilePricesFromCatalogsUnchangedAndCarriesNoProblem() async throws {
        let store = makeStore()
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "catalog-model")?.inputPerMillion, 1)
        XCTAssertNil(pricing.customPricingProblem)
        XCTAssertTrue(pricing.custom.entries.isEmpty)
    }

    func testStoreLoadsOverridesAndServesThemAboveCatalogs() async throws {
        try writeCustomPricing(fullOverride, modified: Date(timeIntervalSince1970: 100))
        let store = makeStore()

        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "overridden-model")?.inputPerMillion, 0.6)
        XCTAssertEqual(pricing.resolve(model: "catalog-model")?.inputPerMillion, 1)
        XCTAssertNil(pricing.customPricingProblem)
    }

    func testStoreRereadsOnlyWhenTheFileStampChanges() async throws {
        // Two same-length bodies: only the stamp (mtime + size are equal after the second write)
        // decides whether the new content is seen.
        let first = #"{"models": {"m": {"input_cost_per_million_tokens": 0.6, "output_cost_per_million_tokens": 2.2}}}"#
        let second = #"{"models": {"m": {"input_cost_per_million_tokens": 0.7, "output_cost_per_million_tokens": 2.2}}}"#
        let stamp = Date(timeIntervalSince1970: 500)
        try writeCustomPricing(first, modified: stamp)
        let store = makeStore()

        var pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "m")?.inputPerMillion, 0.6)

        // Same size, same mtime: the file is not re-read even though its bytes changed.
        try writeCustomPricing(second, modified: stamp)
        pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "m")?.inputPerMillion, 0.6, "unchanged stamp must not re-parse the file")

        // A new mtime picks the new content up on the next pass.
        try writeCustomPricing(second, modified: stamp.addingTimeInterval(5))
        pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "m")?.inputPerMillion, 0.7)

        // Deleting the file clears the override on the next pass.
        try FileManager.default.removeItem(at: customFileURL)
        pricing = await store.current()
        XCTAssertNil(pricing.resolve(model: "m"))
    }

    func testCorruptFileFailsLoudlyAndKeepsCatalogPricing() async throws {
        try writeCustomPricing(#"{"models": "not an object"}"#, modified: Date(timeIntervalSince1970: 100))
        let store = makeStore()

        let pricing = await store.current()
        // Overrides are ignored (as if no file existed), the problem is carried for the UI, and the
        // bundled/fetched sources keep pricing — never a silent total loss of rates.
        XCTAssertEqual(pricing.resolve(model: "catalog-model")?.inputPerMillion, 1)
        XCTAssertNotNil(pricing.customPricingProblem)
        XCTAssertTrue(pricing.customPricingProblem?.contains("custom pricing file") == true)

        // Fixing the file restores overriding on the next pass.
        try writeCustomPricing(fullOverride, modified: Date(timeIntervalSince1970: 200))
        let fixed = await store.current()
        XCTAssertEqual(fixed.resolve(model: "overridden-model")?.inputPerMillion, 0.6)
        XCTAssertNil(fixed.customPricingProblem)
    }
}
