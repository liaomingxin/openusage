import XCTest
@testable import OpenUsage

@MainActor
final class QuotaResetsCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDashboardIncludesResetsBetweenQuotasAndAlerts() {
        XCTAssertEqual(DashboardFilterMode.allCases.map(\.rawValue), ["all", "quotas", "resets", "alerts", "expiries"])
        XCTAssertEqual(DashboardFilterMode.resets.label, "Resets")
        XCTAssertTrue(DashboardFilterMode.resets.matches(data: makeItem("quota").data))
        XCTAssertEqual(QuotaResetWindowFilter.allCases.map(\.rawValue), ["all", "weekly", "session", "remaining"])
        XCTAssertEqual(QuotaResetWindowFilter.allCases.map(\.label), ["All", "Weekly+", "5h / Daily", "Has Quota"])
    }

    func testSortsBySoonestResetAcrossProviders() {
        let items = [
            makeItem("claude.weekly", seconds: 7_200, used: 0),
            makeItem("codex.session", seconds: 600, used: 95),
            makeItem("cursor.monthly", seconds: 3_600, used: 20)
        ]
        XCTAssertEqual(QuotaResetsBuilder.sorted(items).map(\.id), ["codex.session", "cursor.monthly", "claude.weekly"])
    }

    func testSimultaneousResetsPrioritizeRemainingQuotaThenID() {
        let items = [
            makeItem("z.weekly", used: 10),
            makeItem("spent.weekly", used: 100),
            makeItem("a.weekly", used: 10),
            makeItem("half.weekly", used: 50)
        ]
        XCTAssertEqual(QuotaResetsBuilder.sorted(items).map(\.id), ["a.weekly", "z.weekly", "half.weekly", "spent.weekly"])
    }

    func testNearSimultaneousResetsPrioritizeQuotaButSixtySecondsStartsNextCohort() {
        let items = [
            makeItem("first", seconds: 600, used: 90),
            makeItem("nearby", seconds: 659, used: 20),
            makeItem("next", seconds: 660, used: 0)
        ]
        XCTAssertEqual(QuotaResetsBuilder.sorted(items).map(\.id), ["nearby", "first", "next"])
    }

    func testOverlappingNearResetPairsHaveDeterministicOrdering() {
        let a = makeItem("a", seconds: 600, used: 90)
        let b = makeItem("b", seconds: 650, used: 50)
        let c = makeItem("c", seconds: 700, used: 0)
        for order in [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            XCTAssertEqual(QuotaResetsBuilder.sorted(order).map(\.id), ["b", "a", "c"])
        }
    }

    func testWeeklyFilterIncludesUnknownDurationAndLongerThanDaily() {
        let items = periodItems()
        XCTAssertEqual(items.filter(QuotaResetWindowFilter.weeklyAndLonger.matches).map(\.id), [
            "unknown", "weekly", "monthly", "longerThanDaily"
        ])
    }

    func testSessionFilterIncludesFiveHourAndExactDailyWindows() {
        XCTAssertEqual(periodItems().filter(QuotaResetWindowFilter.shortSession.matches).map(\.id), ["session", "daily"])
    }

    func testHasQuotaRequiresStrictlyMoreThanOnePercentAndIgnoresDisplayMode() {
        let items = [
            makeItem("available", used: 98.9),
            makeItem("onePercent", used: 99),
            makeItem("exhausted", used: 100),
            makeItem("overLimit", used: 120),
            makeItem("dollars", used: 5, limit: 10, kind: .dollars),
            makeItem("count", used: 199, limit: 200, kind: .count)
        ]
        XCTAssertEqual(items.filter(QuotaResetWindowFilter.hasRemaining.matches).map(\.id), ["available", "dollars"])
        XCTAssertEqual(items.filter(QuotaResetWindowFilter.all.matches), items)
    }

    func testRemainingPercentHandlesPercentAbsoluteZeroAndMissingLimits() {
        XCTAssertEqual(makeItem("percent", used: 40, limit: 50).remainingPercent, 60)
        XCTAssertEqual(makeItem("dollars", used: 25, limit: 50, kind: .dollars).remainingPercent, 50)
        XCTAssertEqual(makeItem("count", used: 150, limit: 200, kind: .count).remainingPercent, 25)
        XCTAssertEqual(makeItem("over", used: 300, limit: 200, kind: .count).remainingPercent, 0)
        XCTAssertEqual(makeItem("zero", used: 0, limit: 0, kind: .dollars).remainingPercent, 0)
        XCTAssertEqual(makeItem("unbounded", used: 0, limit: nil, kind: .count).remainingPercent, 0)
    }

    func testExhaustionThresholdAndRemainingTimeUseInjectedClock() {
        XCTAssertTrue(makeItem("exhausted", used: 100).isExhausted)
        XCTAssertTrue(makeItem("threshold", used: 99.5).isExhausted)
        XCTAssertFalse(makeItem("available", used: 99.49).isExhausted)
        XCTAssertEqual(makeItem("future", seconds: 123).timeRemaining, 123)
        XCTAssertEqual(makeItem("past", seconds: -30).timeRemaining, -30)
    }

    func testBucketPartitionsIncludeExactDayBoundaries() {
        let items = [
            makeItem("recent", seconds: -59),
            makeItem("now", seconds: 0),
            makeItem("oneDay", seconds: 24 * 3600),
            makeItem("overOneDay", seconds: 24 * 3600 + 1),
            makeItem("threeDays", seconds: 3 * 24 * 3600),
            makeItem("later", seconds: 3 * 24 * 3600 + 1)
        ]
        let buckets = QuotaResetsBuilder.buckets(items: items)
        XCTAssertEqual(buckets.map(\.title), ["Resetting Within 24h", "Resetting in 1–3 Days", "Later (> 3 Days)"])
        XCTAssertEqual(buckets.map { $0.items.map(\.id) }, [
            ["recent", "now", "oneDay"], ["overOneDay", "threeDays"], ["later"]
        ])
        XCTAssertEqual(buckets.flatMap(\.items), items)
    }

    func testBucketsOmitEmptySections() {
        XCTAssertTrue(QuotaResetsBuilder.buckets(items: []).isEmpty)
        let buckets = QuotaResetsBuilder.buckets(items: [makeItem("later", seconds: 400_000)])
        XCTAssertEqual(buckets.map(\.id), [.later])
    }

    func testBuilderIncludesEnabledOnDemandMetricsAndExcludesInvalidWindows() throws {
        let descriptors = [
            makeDescriptor("codex.session", seconds: 600),
            makeDescriptor("codex.weekly", seconds: 3_600),
            makeDescriptor("codex.hidden", seconds: 700),
            makeDescriptor("codex.missing", seconds: 800),
            makeDescriptor("codex.noReset", seconds: nil),
            makeDescriptor("codex.tooOld", seconds: -61),
            makeDescriptor("codex.cutoff", seconds: -60),
            makeDescriptor("codex.justReset", seconds: -59),
            makeDescriptor("codex.unbounded", seconds: 900, limit: nil)
        ]
        try withStores(
            descriptors: descriptors, disabledMetricIDs: ["codex.hidden"],
            missingDataIDs: ["codex.missing"], onDemandIDs: ["codex.weekly"]
        ) { layout, dataStore in
            let items = QuotaResetsBuilder.items(
                groups: layout.displayGroups, layout: layout, dataStore: dataStore, filter: .all, now: now
            )
            XCTAssertEqual(items.map(\.id), ["codex.justReset", "codex.session", "codex.weekly"])
            XCTAssertEqual(items.map(\.metricTitle), ["justReset", "session", "weekly"])
            XCTAssertTrue(items.allSatisfy { $0.plan == "Pro" && $0.now == now })
        }
    }

    func testBuilderPreservesSeparateAccountsAndSkipsDisabledProviders() throws {
        let descriptors = [
            makeDescriptor("codex.weekly", seconds: 3_600),
            makeDescriptor("codex@second.weekly", seconds: 600),
            makeDescriptor("claude.session", seconds: 300)
        ]
        try withStores(descriptors: descriptors, disabledProviderIDs: ["claude"]) { layout, dataStore in
            let items = QuotaResetsBuilder.items(
                groups: layout.displayGroups, layout: layout, dataStore: dataStore, filter: .all, now: now
            )
            XCTAssertEqual(items.map(\.id), ["codex@second.weekly", "codex.weekly"])
            XCTAssertEqual(items.map { $0.provider.id }, ["codex@second", "codex"])
            XCTAssertEqual(items.first?.provider.accountLabel, "second")
            // Even an explicitly supplied group cannot reintroduce a disabled provider.
            let disabled = ProviderGroup(
                provider: layout.registry.provider(id: "claude")!,
                alwaysShownWidgets: [PlacedWidget(descriptorID: "claude.session")], expandedWidgets: []
            )
            XCTAssertTrue(QuotaResetsBuilder.items(
                groups: [disabled], layout: layout, dataStore: dataStore, filter: .all, now: now
            ).isEmpty)
        }
    }

    func testBuilderAppliesWindowFiltersAndUsesGlobalDisplaySettings() throws {
        let descriptors = [
            makeDescriptor("codex.session", used: 100, period: MetricPeriod.sessionMs),
            makeDescriptor("codex.daily", used: 99, period: MetricPeriod.dayMs),
            makeDescriptor("codex.weekly", used: 20, period: MetricPeriod.weekMs),
            makeDescriptor("codex.monthly", used: 30, period: MetricPeriod.monthMs),
            makeDescriptor("codex.unknown", used: 99.5, period: nil)
        ]
        try withStores(descriptors: descriptors) { layout, dataStore in
            let expected: [(QuotaResetWindowFilter, [String])] = [
                (.weeklyAndLonger, ["codex.weekly", "codex.monthly", "codex.unknown"]),
                (.shortSession, ["codex.daily", "codex.session"]),
                (.hasRemaining, ["codex.weekly", "codex.monthly"])
            ]
            dataStore.meterStyle = .used
            dataStore.resetDisplayMode = .absolute
            for (filter, ids) in expected {
                let items = QuotaResetsBuilder.items(
                    groups: layout.displayGroups, layout: layout, dataStore: dataStore, filter: filter, now: now
                )
                XCTAssertEqual(items.map(\.id), ids)
                XCTAssertTrue(items.allSatisfy { $0.data.displayMode == .used && $0.data.resetDisplayMode == .absolute })
            }
        }
    }

    private func periodItems() -> [QuotaResetItem] {
        [
            makeItem("unknown", period: nil),
            makeItem("weekly", period: MetricPeriod.weekMs),
            makeItem("monthly", period: MetricPeriod.monthMs),
            makeItem("longerThanDaily", period: MetricPeriod.dayMs + 1),
            makeItem("session", period: MetricPeriod.sessionMs),
            makeItem("daily", period: MetricPeriod.dayMs)
        ]
    }

    private func makeItem(
        _ id: String,
        seconds: TimeInterval = 3_600,
        used: Double = 20,
        limit: Double? = 100,
        kind: MetricKind = .percent,
        period: Int? = MetricPeriod.weekMs
    ) -> QuotaResetItem {
        let provider = Provider(id: id, displayName: id, icon: .providerMark("codex"))
        let data = WidgetData(
            title: id, icon: provider.icon, kind: kind, used: used, limit: limit,
            resetsAt: now.addingTimeInterval(seconds), periodDurationMs: period
        )
        return QuotaResetItem(
            id: id, provider: provider, plan: "Pro", metricTitle: id,
            data: data, resetsAt: now.addingTimeInterval(seconds), now: now
        )
    }

    private func makeDescriptor(
        _ id: String,
        seconds: TimeInterval? = 3_600,
        used: Double = 20,
        limit: Double? = 100,
        period: Int? = MetricPeriod.weekMs
    ) -> WidgetDescriptor {
        let components = id.split(separator: ".", maxSplits: 1).map(String.init)
        return WidgetDescriptor(
            id: id, providerID: components[0], metricLabel: components[1],
            sample: WidgetData(
                title: components[1], icon: .providerMark("codex"), kind: .percent, used: used, limit: limit,
                resetsAt: seconds.map { now.addingTimeInterval($0) }, periodDurationMs: period
            )
        )
    }

    private func withStores(
        descriptors: [WidgetDescriptor],
        disabledMetricIDs: Set<String> = [],
        missingDataIDs: Set<String> = [],
        onDemandIDs: Set<String> = [],
        disabledProviderIDs: Set<String> = [],
        body: (LayoutStore, WidgetDataStore) -> Void
    ) throws {
        let suiteName = "QuotaResetsCardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = Set(descriptors.map(\.providerID)).sorted().map { id in
            let components = id.split(separator: "@", maxSplits: 1).map(String.init)
            return Provider(
                id: id, familyName: components[0].capitalized,
                accountLabel: components.count == 2 ? components[1] : nil, icon: .providerMark(components[0])
            )
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let layout = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: descriptors.map(\.id).filter { !disabledMetricIDs.contains($0) },
            migrationBaselineMetricIDs: [], defaultPinnedMetricIDs: [], defaultExpandedMetricIDs: Array(onDemandIDs),
            isProviderEnabled: { !disabledProviderIDs.contains($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry, providers: [], cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults, isProviderEnabled: { !disabledProviderIDs.contains($0) }
        )
        for provider in providers {
            let lines = descriptors.filter { $0.providerID == provider.id && !missingDataIDs.contains($0.id) }.map { descriptor in
                let data = descriptor.sample
                if let limit = data.limit {
                    return MetricLine.progress(
                        label: descriptor.metricLabel, used: data.used, limit: limit, format: .percent,
                        resetsAt: data.resetsAt, periodDurationMs: data.periodDurationMs
                    )
                }
                return MetricLine.values(label: descriptor.metricLabel, values: [MetricValue(number: data.used, kind: .count)])
            }
            dataStore.snapshots[provider.id] = ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName, plan: "Pro", lines: lines, refreshedAt: now
            )
        }
        body(layout, dataStore)
    }
}
