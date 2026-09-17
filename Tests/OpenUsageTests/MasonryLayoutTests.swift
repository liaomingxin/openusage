import XCTest
@testable import OpenUsage

/// The shared column-assignment rule behind the dashboard, Agent Usage, and Settings grids.
final class MasonryLayoutTests: XCTestCase {
    private struct Card: Identifiable, Equatable {
        let id: String
    }

    private func ids(_ columns: [MasonryLayout.Column<Card>]) -> [[String]] {
        columns.map { $0.items.map(\.id) }
    }

    func testUnmeasuredCardsAlternateLeftRight() {
        let cards = ["a", "b", "c", "d", "e"].map(Card.init)
        let columns = MasonryLayout.assignColumns(cards, heights: [:])
        XCTAssertEqual(ids(columns), [["a", "c", "e"], ["b", "d"]])
    }

    func testEachCardJoinsTheShorterColumn() {
        // "a" is tall (300), so "b", "c", "d" stack on the right (100 + 100 + 150 = 350) until the
        // right column overtakes the left and "e" returns left.
        let cards = ["a", "b", "c", "d", "e"].map(Card.init)
        let heights: [String: CGFloat] = ["a": 300, "b": 100, "c": 100, "d": 150, "e": 100]
        let columns = MasonryLayout.assignColumns(cards, heights: heights)
        XCTAssertEqual(ids(columns), [["a", "e"], ["b", "c", "d"]])
    }

    func testTiesFillLeftFirst() {
        let cards = ["a", "b"].map(Card.init)
        let columns = MasonryLayout.assignColumns(cards, heights: ["a": 100, "b": 100])
        XCTAssertEqual(ids(columns), [["a"], ["b"]])
    }

    func testUnmeasuredCardUsesTheEstimate() {
        // "b" has no height. Counted at the 140pt estimate it makes the right column (140) taller
        // than the left (100), so "c" returns left; counted at 0 it would have pulled "c" right.
        let cards = ["a", "b", "c"].map(Card.init)
        let columns = MasonryLayout.assignColumns(cards, heights: ["a": 100, "c": 50], estimated: 140)
        XCTAssertEqual(ids(columns), [["a", "c"], ["b"]])
        let flipped = MasonryLayout.assignColumns(cards, heights: ["a": 100, "c": 50], estimated: 20)
        XCTAssertEqual(ids(flipped), [["a"], ["b", "c"]])
    }

    func testEmptyInputYieldsEmptyColumns() {
        let columns = MasonryLayout.assignColumns([Card](), heights: [:])
        XCTAssertEqual(columns.count, 2)
        XCTAssertTrue(columns.allSatisfy { $0.items.isEmpty })
    }

    func testColumnsAreIdentifiedByPosition() {
        let cards = ["a", "b"].map(Card.init)
        let columns = MasonryLayout.assignColumns(cards, heights: [:])
        XCTAssertEqual(columns.map(\.id), [0, 1])
    }
}
