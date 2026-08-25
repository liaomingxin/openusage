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
    }
}
