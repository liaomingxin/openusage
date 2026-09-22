import XCTest
@testable import OpenUsage

@MainActor
final class KimiLayoutTests: XCTestCase {
    func testFreshDefaultsPinSessionAndWeeklyAsMenuBarPair() {
        let suiteName = "OpenUsageTests.KimiLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let registry = WidgetRegistry.from([KimiProvider()])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(
            store.pinnedGroups.flatMap { $0.metrics.map(\.id) },
            ["kimi.session", "kimi.weekly"]
        )
        for id in ["kimi.today", "kimi.yesterday", "kimi.last30"] {
            XCTAssertTrue(store.isMetricEnabled(id))
            XCTAssertTrue(store.expandedMetricIDs.contains(id))
            XCTAssertFalse(store.pinnedGroups.flatMap { $0.metrics.map(\.id) }.contains(id))
        }
    }
}
