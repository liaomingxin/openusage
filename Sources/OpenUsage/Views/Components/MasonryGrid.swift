import SwiftUI

/// The column-assignment rule behind every two-column card grid in the popover (the dashboard's
/// provider cards, the Agent Usage cards, the Settings sections): walk the items in display order
/// and drop each into the currently shorter column. Cards of different heights pack without gaps
/// and every card keeps the standard half width — unlike row pairing, which left ragged whitespace
/// under the shorter card of a row and stretched a leftover odd card to full width.
///
/// Pure and static so it's unit-testable and the dashboard (which measures heights through its
/// reorder frames) and `MasonryGrid` (which measures through `onGeometryChange`) can't drift.
enum MasonryLayout {
    /// One side of the grid. Identified by position, so an item moving between columns moves between
    /// two stable parents.
    struct Column<Item: Identifiable>: Identifiable {
        let index: Int
        var items: [Item] = []
        var id: Int { index }
    }

    /// Rough stand-in height (a header + a couple of rows) for a card that hasn't been measured yet.
    /// Only needs to be even across cards so an unmeasured grid alternates left/right.
    static let estimatedCardHeight: CGFloat = 140

    /// Splits `items` between `columnCount` columns, always adding the next item to the currently
    /// shorter column (ties go left). An item with no measurement yet counts as `estimated`, so a
    /// fresh grid starts in an even alternation and settles once real heights arrive. An item's
    /// height doesn't depend on which equal-width column it lands in, so the split converges after
    /// one measurement pass instead of looping.
    static func assignColumns<Item: Identifiable>(
        _ items: [Item],
        heights: [Item.ID: CGFloat],
        estimated: CGFloat = estimatedCardHeight,
        columnCount: Int = 2
    ) -> [Column<Item>] {
        precondition(columnCount >= 1, "a grid needs at least one column")
        var columns = (0..<columnCount).map { Column<Item>(index: $0) }
        var totals = [CGFloat](repeating: 0, count: columnCount)
        for item in items {
            // `min` returns the first minimum, so ties fill left to right.
            let target = totals.indices.min { totals[$0] < totals[$1] } ?? 0
            columns[target].items.append(item)
            totals[target] += heights[item.id] ?? estimated
        }
        return columns
    }
}

/// A two-column masonry of identifiable cards, measured and balanced with `MasonryLayout`.
///
/// Heights come from each card's own `onGeometryChange`. The split is balanced against a *snapshot*
/// of heights that absorbs only a card's first measurement: re-splitting on a live height change (a
/// caret opening, a section growing a notice) would shuffle neighboring cards out from under the
/// pointer, so the snapshot otherwise refreshes only when the item set changes — or when the
/// caller's `rebalanceKey` changes (a period/window switch that re-flows every card at once).
///
/// The dashboard grid doesn't use this view: its cards already publish frames for drag-reorder, so it
/// feeds those into `MasonryLayout.assignColumns` directly. Everything else (Agent Usage, Settings,
/// Customize) renders through here.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// Gap between columns and between cards in a column — the same value on both axes so the grid
    /// reads as even.
    let spacing: CGFloat
    /// A value whose change re-snapshots the balance against the latest measurements (see above).
    var rebalanceKey: AnyHashable = AnyHashable(0)
    @ViewBuilder let content: (Item) -> Content

    /// Latest measured height of each card.
    @State private var heights: [Item.ID: CGFloat] = [:]
    /// The heights the column split is actually balanced with — see the type doc.
    @State private var balanceHeights: [Item.ID: CGFloat] = [:]

    var body: some View {
        let columns = MasonryLayout.assignColumns(items, heights: balanceHeights)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(column.items) { item in
                        content(item)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                record(height, for: item.id)
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            rebalance(Set(ids))
        }
        .onChange(of: rebalanceKey) { _, _ in
            rebalance(Set(items.map(\.id)))
        }
    }

    /// `heights` tracks the latest measurement; `balanceHeights` only absorbs a card's first height.
    private func record(_ height: CGFloat, for id: Item.ID) {
        heights[id] = height
        if balanceHeights[id] == nil { balanceHeights[id] = height }
    }

    /// Re-split against the latest measurements, pruning items no longer listed.
    private func rebalance(_ ids: Set<Item.ID>) {
        balanceHeights = heights.filter { ids.contains($0.key) }
    }
}
