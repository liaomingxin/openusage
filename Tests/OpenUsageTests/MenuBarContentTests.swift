import XCTest
@testable import OpenUsage

/// Covers `MenuBarContentBuilder`: it resolves pinned provider groups into Text groups (order, labels,
/// and values preserved) and Bars entries (bounded metrics only, first four in order), and reports empty
/// when nothing is pinned.
@MainActor
final class MenuBarContentTests: XCTestCase {
    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testTextGroupsSplitIntoPrimaryAndSecondaryRowsAtFourProviders() {
        XCTAssertEqual(MenuBarContent.maxPrimaryGroups, 4)
        for count in [0, 1, 4, 5, 7] {
            let providerIDs = (0..<count).map { "provider\($0)" }
            let content = MenuBarContentBuilder.build(
                groups: providerIDs.map { group($0, percent("\($0).session", "Session", 40)) },
                data: { $0.sample }
            )

            XCTAssertEqual(content.primaryGroups.map(\.providerID), Array(providerIDs.prefix(4)))
            XCTAssertEqual(content.secondaryGroups.map(\.providerID), Array(providerIDs.dropFirst(4)))
            XCTAssertEqual(content.hasSecondaryRow, count > 4)
            XCTAssertEqual(content.primaryContent.groups, content.primaryGroups)
            XCTAssertEqual(content.primaryContent.bars, content.bars)
            XCTAssertEqual(content.secondaryContent.groups, content.secondaryGroups)
            XCTAssertTrue(content.secondaryContent.bars.isEmpty)
        }
    }

    func testBarsIncludeBoundedMetricsAndDropUnbounded() {
        // A bounded dollar metric has a fill, so it belongs in Bars. An unbounded value (raw spend,
        // no limit) has no fill and is dropped.
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                percent("a.pct", "Pct", 40),
                boundedDollars("a.credits", "Credits", used: 12000, limit: 18000),
                unbounded("a.spend", "Spend"))],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.pct", "a.credits", "a.spend"])  // Text: all
        XCTAssertEqual(content.bars.map(\.id), ["a.pct", "a.credits"])                          // Bars: bounded only
    }

    func testBarsCappedToFourInOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "M1", 10), percent("a.m2", "M2", 20)),
                group("b", percent("b.m1", "M1", 30), percent("b.m2", "M2", 40)),
                group("c", percent("c.m1", "M1", 50), percent("c.m2", "M2", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.bars.count, 4)
        XCTAssertEqual(content.bars.map(\.id), ["a.m1", "a.m2", "b.m1", "b.m2"])
    }

    func testNoDataMetricsDropFromStrip() {
        // The strip is dynamic: a pinned metric without data vanishes instead of rendering "—", and
        // the surviving pin renders alone (full size). A provider whose pins all lack data
        // contributes no icon at all.
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly")),
                group("b", noDataPercent("b.nd", "ND"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
        XCTAssertEqual(content.bars.map(\.id), ["a.live"])
    }

    func testAllPinsWithoutDataFallBackToAppIcon() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "ND"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testTrayLabelsShortenLongTimeWindows() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["T", "M"])
    }

    func testBoundedTrayValuesStayUnitAware() {
        // Percent meters still read as percentages, while bounded dollars/counts keep their natural
        // unit in the strip instead of collapsing to "used / limit" percentages.
        let usage = percent("a.usage", "Usage", 67)
        let credits = boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)
        let requests = boundedCount("a.requests", "Requests", used: 412, limit: 500)
        let spend = unbounded("a.spend", "Spend")   // unbounded $42
        let content = MenuBarContentBuilder.build(groups: [group("a", usage, credits, requests, spend)], data: { $0.sample })

        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["67%", "$12K", "412", "$42"])
    }

    func testFamilyCoalescingPreservesDistinctFamiliesAndFirstAppearanceOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", percent("claude.session", "Session", 20)),
                group("codex", percent("codex.weekly", "Weekly", 40)),
                group("claude@1", percent("claude@1.session", "Session", 20)),
                group("kimi", percent("kimi.weekly", "Weekly", 30)),
                group("claude@2", percent("claude@2.session", "Session", 20))
            ],
            coalesceByFamily: true,
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude", "codex", "kimi"])
        XCTAssertEqual(content.groups.map(\.displayName), ["CLAUDE", "CODEX", "KIMI"])
        XCTAssertEqual(content.bars.map(\.id), ["claude.session", "codex.weekly", "kimi.weekly"])
    }

    func testFamilyCoalescingChoosesActiveAccountWithLowestRemainingQuota() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", percent("claude.session", "Session", 0)),
                group("claude@1", percent("claude@1.session", "Session", 25)),
                group("claude@2", percent("claude@2.session", "Session", 60))
            ],
            coalesceByFamily: true,
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude@2"])
        XCTAssertEqual(content.groups.first?.displayName, "CLAUDE")
        XCTAssertEqual(content.groups.first?.metrics.map(\.id), ["claude@2.session"])
        XCTAssertEqual(content.accessibilityText, "CLAUDE Session 60%")
        XCTAssertEqual(content.bars.map(\.id), ["claude@2.session"])
    }

    func testFamilyCoalescingUsesHighestSeverityAcrossBoundedMetrics() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", percent("claude.weekly", "Weekly", 85)),
                group("claude@1",
                    percent("claude@1.session", "Session", 10),
                    percent("claude@1.weekly", "Weekly", 95)),
                group("claude@2", percent("claude@2.weekly", "Weekly", 88))
            ],
            coalesceByFamily: true,
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude@1"])
        XCTAssertEqual(content.bars.map(\.id), ["claude@1.session", "claude@1.weekly"])
    }

    func testFamilyCoalescingRecognizesUnboundedActivityAndKeepsExactTiesStable() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", unbounded("claude.spend", "Spend", 0)),
                group("claude@1", unbounded("claude@1.spend", "Spend", 42)),
                group("claude@2", unbounded("claude@2.spend", "Spend", 100))
            ],
            coalesceByFamily: true,
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude@1"])
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testFamilyCoalescingRanksBoundedSeverityBeforeUnboundedActivity() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", percent("claude.session", "Session", 0)),
                group("claude@1", unbounded("claude@1.spend", "Spend", 42))
            ],
            coalesceByFamily: true,
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude"])
    }

    func testFamilyCoalescingIgnoresMissingDataInPriorityAndFamilyOrder() {
        var missing = percent("claude@1.weekly", "Weekly", 99).sample
        missing.hasData = false
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", noDataPercent("claude.session", "Session")),
                group("codex", percent("codex.weekly", "Weekly", 40)),
                group("claude@1",
                    percent("claude@1.session", "Session", 10),
                    descriptor("claude@1.weekly", "Weekly", missing)),
                group("claude@2", percent("claude@2.session", "Session", 60))
            ],
            coalesceByFamily: true,
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["codex", "claude@2"])
        XCTAssertEqual(content.bars.map(\.id), ["codex.weekly", "claude@2.session"])
    }

    func testFamilyCoalescingResolvesEachMetricOnceUsingLiveData() {
        let idle = percent("claude.session", "Session", 0)
        let active = percent("claude@1.session", "Session", 60)
        let liveData = [idle.id: active.sample, active.id: idle.sample]
        var resolutions: [String: Int] = [:]
        let content = MenuBarContentBuilder.build(
            groups: [group("claude", idle), group("claude@1", active)],
            coalesceByFamily: true,
            data: { descriptor in
                resolutions[descriptor.id, default: 0] += 1
                return liveData[descriptor.id]!
            }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude"])
        XCTAssertEqual(content.groups.first?.metrics.first?.value, "60%")
        XCTAssertEqual(resolutions, [idle.id: 1, active.id: 1])
    }

    func testFamilyAccountsRemainSeparateByDefault() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude", percent("claude.session", "Session", 0)),
                group("claude@1", percent("claude@1.session", "Session", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["claude", "claude@1"])
        XCTAssertEqual(content.groups.map(\.displayName), ["CLAUDE", "CLAUDE — claude@1"])
    }

    // Compact-notation rules for tray values (abbreviation, decimal rounding) are pinned exactly in
    // MetricFormatterTests — the strip only relays MetricFormatter output.

    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let familyID = ProviderAccountID.family(of: providerID)
        let provider = Provider(
            id: providerID,
            familyName: familyID.uppercased(),
            accountLabel: providerID == familyID ? nil : providerID,
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
