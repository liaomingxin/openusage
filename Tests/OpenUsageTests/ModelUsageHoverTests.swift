import XCTest
@testable import OpenUsage

@MainActor
final class ModelUsageHoverTests: XCTestCase {
    func testValuesLineCodableRoundTripsModelBreakdown() throws {
        let breakdown = sampleBreakdown()
        let line = MetricLine.values(
            label: "Today",
            values: [MetricValue(number: 3, kind: .dollars), MetricValue(number: 300, kind: .count, label: "tokens")],
            modelBreakdown: breakdown
        )

        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(MetricLine.self, from: data)

        XCTAssertEqual(decoded, line)
    }

    /// A snapshot cached before the breakdown carried a unit still decodes, and reads as the spend
    /// rows' "tokens" — the field is optional precisely so an older payload can't fail to decode.
    func testBreakdownWithoutAUnitDecodesAsTokens() throws {
        let json = Data(#"""
        {"type":"values","label":"Today","values":[{"number":300,"kind":"count","label":"tokens","estimated":false}],
         "modelBreakdown":{"totalTokens":300,"models":[{"model":"alpha","totalTokens":300}],"sourceNote":"From test logs"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(MetricLine.self, from: json)
        guard case .values(_, _, _, _, _, let breakdown) = decoded else {
            return XCTFail("expected a values line")
        }
        XCTAssertNil(try XCTUnwrap(breakdown).unitLabel)
        XCTAssertEqual(try XCTUnwrap(breakdown).unit, "tokens")
    }

    /// A breakdown that names its own unit keeps it across a round trip — Z.ai's MCP tool list is
    /// counted in calls, not tokens.
    func testBreakdownKeepsItsOwnUnitAcrossACodableRoundTrip() throws {
        let line = MetricLine.values(
            label: "MCP Tools",
            values: [MetricValue(number: 27, kind: .count, label: "calls")],
            modelBreakdown: ModelUsageBreakdown(
                totalTokens: 27, totalCostUSD: nil,
                models: [ModelUsageEntry(model: "Web Search MCP", totalTokens: 27, costUSD: nil)],
                sourceNote: "From your api.z.ai usage history",
                unitLabel: "calls"
            )
        )
        let decoded = try JSONDecoder().decode(MetricLine.self, from: try JSONEncoder().encode(line))
        XCTAssertEqual(decoded, line)
        guard case .values(_, _, _, _, _, let breakdown) = decoded else {
            return XCTFail("expected a values line")
        }
        XCTAssertEqual(try XCTUnwrap(breakdown).unit, "calls")
    }

    func testDataStoreResolvesSingleAndMultipleModelBreakdowns() {
        let cases: [(providerID: String, breakdown: ModelUsageBreakdown, models: [String])] = [
            ("claude", sampleBreakdown(), ["alpha", "beta"]),
            ("codex", ModelUsageBreakdown(
                totalTokens: 300, totalCostUSD: 3,
                models: [ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)],
                sourceNote: "From Codex test logs"
            ), ["gpt-5.5"])
        ]

        for item in cases {
            let provider = Provider(
                id: item.providerID, displayName: item.providerID.capitalized, icon: .providerMark(item.providerID)
            )
            let descriptor = WidgetDescriptor.spendTiles(provider: provider).first { $0.id == "\(provider.id).today" }!
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
                providers: [],
                defaults: makeDefaults(item.providerID)
            )
            store.snapshots[provider.id] = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3, kind: .dollars, estimated: true),
                        MetricValue(number: 300, kind: .count, label: "tokens")
                    ],
                    modelBreakdown: item.breakdown
                )]
            )

            let data = store.data(for: descriptor)
            XCTAssertTrue(data.hasModelBreakdown, item.providerID)
            XCTAssertEqual(data.modelBreakdown?.models.map(\.model), item.models, item.providerID)
            XCTAssertEqual(data.modelBreakdown?.sourceNote, item.breakdown.sourceNote, item.providerID)
        }
    }

    /// Z.ai's MCP Tools row opts into the same hover machinery as the spend tiles, so the real
    /// descriptor has to resolve a breakdown — the `isUsagePeriod` opt-in is what gates it.
    func testDataStoreResolvesTheZAIMCPToolsBreakdown() {
        let zai = ZAIProvider(authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment([:])))
        let descriptor = zai.widgetDescriptors.first { $0.id == "zai.mcpTools" }!
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [zai.provider], descriptors: [descriptor]),
            providers: [],
            defaults: makeDefaults("ZAIMCPTools")
        )
        store.snapshots["zai"] = ProviderSnapshot(
            providerID: "zai",
            displayName: "Z.ai",
            lines: [.values(
                label: "MCP Tools",
                values: [MetricValue(number: 27, kind: .count, label: "calls")],
                modelBreakdown: ModelUsageBreakdown(
                    totalTokens: 27, totalCostUSD: nil,
                    models: [
                        ModelUsageEntry(model: "Web Search MCP", totalTokens: 15, costUSD: nil),
                        ModelUsageEntry(model: "Web Read MCP", totalTokens: 12, costUSD: nil)
                    ],
                    sourceNote: "From your api.z.ai usage history",
                    unitLabel: "calls"
                )
            )]
        )

        let data = store.data(for: descriptor)
        XCTAssertEqual(data.unboundedDetail, "27 calls")
        XCTAssertTrue(data.hasModelBreakdown)
        XCTAssertEqual(data.modelBreakdown?.models.map(\.model), ["Web Search MCP", "Web Read MCP"])
        XCTAssertEqual(data.modelBreakdown?.unit, "calls")
    }

    func testWholePercentsAlwaysSumToOneHundred() {
        // Independent rounding would print 33 / 33 / 33 = 99; the largest remainder takes the leftover point.
        XCTAssertEqual(ModelUsageDetail.wholePercents([1.0 / 3, 1.0 / 3, 1.0 / 3]), [34, 33, 33])
        // Independent rounding would print 62 + 34 + 5 = 101 (0.045 rounds up); flooring plus
        // remainder distribution keeps the column at exactly 100.
        XCTAssertEqual(ModelUsageDetail.wholePercents([0.62, 0.335, 0.045]), [62, 34, 4])
        XCTAssertEqual(ModelUsageDetail.wholePercents([1.0]), [100])
        XCTAssertEqual(ModelUsageDetail.wholePercents([0, 0]), [0, 0], "an empty period stays all zero")

    }

    func testSharesUseCostWhenEveryModelIsPriced() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 10, costUSD: 3),
            ModelUsageEntry(model: "beta", totalTokens: 90, costUSD: 1)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0.75, 0.25])
    }

    func testSharesUseTokensForEveryModelWhenOneIsUnpriced() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 25, costUSD: 9),
            ModelUsageEntry(model: "beta", totalTokens: 75, costUSD: nil)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0.25, 0.75])
    }

    func testSharesAreZeroWhenThereIsNoCostOrTokenTotal() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 0, costUSD: nil),
            ModelUsageEntry(model: "beta", totalTokens: 0, costUSD: nil)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0, 0])
    }

    func testHoverPopoverStateOpensThenClosesAroundBothRegions() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        XCTAssertFalse(state.isPresented)

        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "opens after the reveal dwell while the row is hovered")

        state.inlineHover(false)
        state.detailHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "stays open while the cursor is inside the popover")

        state.detailHover(false)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.isPresented, "closes once the cursor has left both the row and the popover")
    }

    func testHoverPopoverStateQuickPassDoesNotOpen() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(60), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        state.inlineHover(false)
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(state.isPresented, "a quick pass over the row never opens the popover")
    }

    func testHoverPopoverStateDismissForcesClosed() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented)

        state.dismiss()
        XCTAssertFalse(state.isPresented, "teardown closes it immediately")
    }

    private func sampleBreakdown() -> ModelUsageBreakdown {
        ModelUsageBreakdown(
            totalTokens: 300,
            totalCostUSD: 3,
            models: [
                ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 1),
                ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 2)
            ],
            sourceNote: "From test logs"
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.ModelUsageHover.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
