import XCTest
@testable import OpenUsage

final class DashboardCardRowTests: XCTestCase {
    func testRowsFillLeftToRightTwoUp() {
        let groups = ["claude", "codex", "cursor", "grok", "kimi"].map(dummyGroup)
        let rows = DashboardCardRow.rows(from: groups)
        XCTAssertEqual(rows.map { $0.groups.map(\.id) }, [
            ["claude", "codex"],
            ["cursor", "grok"],
            ["kimi"]
        ])
    }

    func testSingleCardIsOneFullWidthRow() {
        let rows = DashboardCardRow.rows(from: [dummyGroup("claude")])
        XCTAssertEqual(rows.map { $0.groups.map(\.id) }, [["claude"]])
    }

    func testConsecutiveAccountFamilyGetsDedicatedRow() {
        let groups = ["claude", "codex", "codex@first", "cursor", "grok"].map(dummyGroup)
        let rows = DashboardCardRow.rows(from: groups)

        XCTAssertEqual(rows.map { $0.groups.map(\.id) }, [
            ["claude"],
            ["codex", "codex@first"],
            ["cursor", "grok"]
        ])
    }

    func testThreeAccountFamilyWrapsWithoutMixingNextProvider() {
        let groups = ["codex", "codex@first", "codex@second", "cursor", "grok"].map(dummyGroup)
        let rows = DashboardCardRow.rows(from: groups)

        XCTAssertEqual(rows.map { $0.groups.map(\.id) }, [
            ["codex", "codex@first"],
            ["codex@second"],
            ["cursor", "grok"]
        ])
    }

    func testEmptyGroupsYieldNoRows() {
        XCTAssertTrue(DashboardCardRow.rows(from: []).isEmpty)
    }

    private func dummyGroup(_ id: String) -> ProviderGroup {
        ProviderGroup(
            provider: Provider(id: id, displayName: id, icon: .providerMark(id)),
            alwaysShownWidgets: [],
            expandedWidgets: []
        )
    }
}
