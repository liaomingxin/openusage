import XCTest
@testable import OpenUsage

/// Locks Grok's default metric placement (owner-confirmed): the Weekly shared-pool meter and Usage
/// Trend above the fold, the pay-as-you-go badge and spend tiles below the caret, and Weekly pinned
/// to the menu bar so a detected Grok install shows its icon and remaining pool percent out of the box.
final class GrokLayoutTests: XCTestCase {
    func testCoreMetricsEnabledByDefault() {
        for id in ["grok.weekly", "grok.trend", "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"] {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled by default")
        }
    }

    func testWeeklyMeterAndTrendStayAboveTheFold() {
        for id in ["grok.weekly", "grok.trend"] {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should stay above the fold")
        }
    }

    func testOptionalRowsSitBelowTheCaret() {
        for id in ["grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"] {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should sit below the caret")
        }
    }

    func testWeeklyMeterIsPinnedByDefault() {
        XCTAssertTrue(
            DefaultLayout.pinnedMetricIDs.contains("grok.weekly"),
            "Grok Weekly should be pinned to the menu bar by default"
        )
    }

    func testOnlyWeeklyIsPinnedByDefault() {
        let grokPins = DefaultLayout.pinnedMetricIDs.filter { $0.hasPrefix("grok.") }
        XCTAssertEqual(grokPins, ["grok.weekly"], "no other Grok metric should claim a default menu-bar pin")
    }
}
