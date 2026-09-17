import XCTest
import SwiftUI
@testable import OpenUsage

/// The Agent Usage grid's column splitter — the static twin of the dashboard's masonry split: walk
/// the cards in order, always add the next to the currently shorter column.
final class AgentUsageScreenTests: XCTestCase {
    private func agent(_ id: String) -> AgentUsageSummary {
        AgentUsageSummary(
            agentID: id, displayName: id, icon: .providerMark(id),
            models: [], totalTokens: 0, totalCostUSD: 0, unpricedModels: []
        )
    }

    func testCardsJoinTheShorterColumn() {
        let agents = [agent("a"), agent("b"), agent("c")]
        let columns = AgentUsageScreen.assignColumns(agents, heights: ["a": 100, "b": 50, "c": 10])
        // a → empty col 0; b (50) → shorter col 1; c (10) → col 1 again (60 < 100).
        XCTAssertEqual(columns[0].agents.map(\.agentID), ["a"])
        XCTAssertEqual(columns[1].agents.map(\.agentID), ["b", "c"])
    }

    func testUnmeasuredCardsUseTheEstimateAndAlternate() {
        let agents = [agent("a"), agent("b"), agent("c"), agent("d")]
        let columns = AgentUsageScreen.assignColumns(agents, heights: [:])
        // Equal estimates keep the fresh grid in an even left/right alternation.
        XCTAssertEqual(columns[0].agents.map(\.agentID), ["a", "c"])
        XCTAssertEqual(columns[1].agents.map(\.agentID), ["b", "d"])
    }

    func testTallMeasuredCardFlipsToTheOtherColumn() {
        let agents = [agent("a"), agent("b"), agent("c")]
        let columns = AgentUsageScreen.assignColumns(agents, heights: ["a": 300, "b": 10, "c": 10])
        // a (300) → col 0; b (10) → col 1; c (10) → col 1 (20 < 300).
        XCTAssertEqual(columns[0].agents.map(\.agentID), ["a"])
        XCTAssertEqual(columns[1].agents.map(\.agentID), ["b", "c"])
    }
}
