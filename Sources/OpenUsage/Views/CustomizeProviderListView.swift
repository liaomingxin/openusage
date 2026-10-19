import SwiftUI

/// The Customize provider list (L1): one row per family in the user's saved order, including disabled
/// accounts so they stay manageable. Families are dealt into two side-by-side cards; their toggle
/// controls every account and their detail (L2) provides per-account controls. The leading grip
/// reorders the whole family across both cards.
struct CustomizeProviderListView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let frameStore: ReorderFrameStore

    @State private var activeProviderID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private struct FamilyRow: Identifiable {
        let familyID: String
        var rows: [ProviderRow]
        var id: String { primary.id }
        var primary: ProviderRow { rows[0] }
    }

    private var familyRows: [FamilyRow] {
        var result: [FamilyRow] = []
        var indexByFamily: [String: Int] = [:]
        for row in layout.customizeProviderRows {
            let familyID = ProviderAccountID.family(of: row.provider.id)
            if let index = indexByFamily[familyID] {
                result[index].rows.append(row)
            } else {
                indexByFamily[familyID] = result.count
                result.append(FamilyRow(familyID: familyID, rows: [row]))
            }
        }
        return result
    }

    var body: some View {
        // Two cards side by side, the rows dealt into them in reading order (row 1 left, row 2 right,
        // …) — the dashboard's shorter-column rule with equal-height rows, which is exactly that
        // alternation. Halves the list's height on the wide panel and keeps each toggle within reach
        // of its name. Drag-reorder is unchanged: the gesture hit-tests row frames in the shared
        // coordinate space, so a drop onto any row (either card) takes that row's position and the
        // rest re-deal. No measurement pass — every row is one line tall, so the split is fixed.
        let rows = familyRows
        let columns = MasonryLayout.assignColumns(rows, heights: [:])
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            HStack(alignment: .top, spacing: density.sectionSpacing) {
                ForEach(columns) { column in
                    VStack(spacing: 0) {
                        ForEach(column.items) { row in
                            providerRow(row)
                        }
                    }
                    .cardSurface()
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            // App behavior/appearance options live on the other screen; catch users who came here
            // hunting for them once they've scanned past the provider list.
            ScreenCrossLinkRow(
                systemImage: "gearshape",
                title: "Settings",
                subtitle: "Notifications, appearance and more",
                destination: .settings
            )
        }
        .animation(Motion.spring, value: rows.map(\.id))
    }

    private func providerRow(_ familyRow: FamilyRow) -> some View {
        let row = familyRow.primary
        let enabledCount = familyRow.rows.filter(\.isEnabled).count
        let isFamily = familyRow.rows.count > 1
        return ProviderListRow(
            provider: row.provider,
            isEnabled: enabledCount > 0,
            metricCount: row.metricCount,
            // Fully disabled families stay openable but do not participate in enabled-family reorder.
            handle: { grip in
                if enabledCount > 0 {
                    AnyView(grip.highPriorityGesture(providerDragGesture(for: familyRow)))
                } else {
                    grip
                }
            },
            titleOverride: isFamily ? row.provider.familyName : nil,
            subtitleOverride: isFamily ? "\(enabledCount)/\(familyRow.rows.count) accounts · \(row.metricCount) metrics" : nil,
            onToggle: { enabled in
                for accountRow in familyRow.rows {
                    container.enablement.setEnabled(enabled, for: accountRow.id)
                }
            },
            onOpen: { withAnimation(Motion.spring) { layout.customizeProviderID = row.id } }
        )
        .opacity(activeProviderID == row.id ? 0 : 1)
        .reorderFrame(id: row.id, in: .named(reorderSpaceName))
    }

    private func providerDragGesture(for familyRow: FamilyRow) -> some Gesture {
        reorderDragGesture(
            id: familyRow.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: familyRow.primary, value: $0) },
            // Only visible, enabled family rows publish usable reorder targets.
            orderedIDs: { familyRows.filter { $0.rows.contains(where: \.isEnabled) }.map(\.id) },
            reorder: {
                layout.reorderProviderFamily(
                    draggedFamily: familyRow.familyID,
                    targetFamily: ProviderAccountID.family(of: $0)
                )
            }
        )
    }

    private func makeProviderLift(for row: ProviderRow, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: row.id,
            payload: .customizeProviderRow(provider: row.provider, isEnabled: row.isEnabled, metricCount: row.metricCount),
            value: value,
            frames: frameStore.frames
        )
    }
}
