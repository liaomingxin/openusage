import AppKit
import SwiftUI

/// The dashboard display: a two-column masonry grid of provider cards (System Settings style). A
/// provider's icon + name sits above a rounded container holding its metric rows. Rows are the shared
/// `WidgetRowView`, fed by the same `WidgetDataStore` the menu bar uses.
///
/// Reordering works here directly (no Customize needed): drag any metric row to reorder it within its
/// provider, or drag a provider's header line to reorder whole providers. Customize stays the discoverable,
/// obvious place to do the same plus toggle metrics on/off. Both surfaces use the same local gesture/geometry
/// helper so they work inside the menu-bar popover without a system drag/drop session.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var frameStore = ReorderFrameStore()
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    /// Latest measured height of each card section, lifted from the reorder frames (which already
    /// measure every section each layout pass).
    @State private var cardHeights: [String: CGFloat] = [:]
    /// The heights the column split is actually balanced with — see `recordHeights`.
    @State private var balanceHeights: [String: CGFloat] = [:]
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Rough stand-in height (header + a couple of rows) for a card that hasn't been measured yet.
    /// Only needs to be even across cards so an unmeasured grid alternates left/right.
    private static let estimatedCardHeight: CGFloat = 140

    var body: some View {
        // Masonry grid: two independent columns, each card joining the currently shorter one instead
        // of pairing into fixed rows. Row pairing left ragged whitespace under the shorter card of a
        // row and stretched a leftover odd card to full width; independent columns stack tight and
        // every card keeps the standard half width. Gap matches section spacing so the grid reads as
        // even on both axes.
        let columns = Self.assignColumns(layout.displayGroups, heights: balanceHeights)
        HStack(alignment: .top, spacing: density.sectionSpacing) {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: density.sectionSpacing) {
                    ForEach(column.groups) { group in
                        section(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { frames in
            frameStore.frames = frames
            recordHeights(frames)
        }
        .onChange(of: layout.displayGroups.map(\.provider.id)) { _, _ in rebalanceColumns() }
        .animation(Motion.spring, value: layout.displayGroups.map(\.provider.id))
    }

    /// One side of the masonry grid. Identified by position, so a card moving between columns moves
    /// between two stable parents — same as it did between rows.
    private struct CardColumn: Identifiable {
        let index: Int
        var groups: [ProviderGroup] = []
        var id: Int { index }
    }

    /// Splits the cards between the two columns by walking them in display order and always adding
    /// the next card to the currently shorter column. A card with no measurement yet (first render,
    /// or a provider just turned on) counts as `estimatedCardHeight`, so a fresh grid starts in an
    /// even left/right alternation and settles once real heights arrive. A card's height doesn't
    /// depend on which equal-width column it lands in, so the split converges after one measurement
    /// pass instead of looping.
    private static func assignColumns(_ groups: [ProviderGroup], heights: [String: CGFloat]) -> [CardColumn] {
        var columns = [CardColumn(index: 0), CardColumn(index: 1)]
        var totals: [CGFloat] = [0, 0]
        for group in groups {
            let target = totals[0] <= totals[1] ? 0 : 1
            columns[target].groups.append(group)
            totals[target] += heights[group.provider.id] ?? estimatedCardHeight
        }
        return columns
    }

    /// Feeds the balancing heights from the reorder frames. `cardHeights` tracks the latest
    /// measurements; `balanceHeights` — the snapshot the column split uses — only absorbs a card's
    /// first height. Re-splitting on a live height change (a caret opening, a density switch) would
    /// shuffle neighboring cards out from under the pointer, so the snapshot otherwise refreshes
    /// only in `rebalanceColumns()`.
    private func recordHeights(_ frames: [String: CGRect]) {
        let providerIDs = Set(layout.displayGroups.map(\.provider.id))
        let measured = frames.reduce(into: [String: CGFloat]()) { result, entry in
            if providerIDs.contains(entry.key) { result[entry.key] = entry.value.height }
        }
        guard measured != cardHeights else { return }
        cardHeights = measured
        var snapshot = balanceHeights
        var grew = false
        for (id, height) in measured where snapshot[id] == nil {
            snapshot[id] = height
            grew = true
        }
        if grew { balanceHeights = snapshot }
    }

    /// Re-splits the columns against the latest measured heights when the provider set or order
    /// changes (a drag reorder, a provider hidden or shown), so the new arrangement lands balanced.
    /// Prunes heights of providers no longer on the dashboard.
    private func rebalanceColumns() {
        let providerIDs = Set(layout.displayGroups.map(\.provider.id))
        balanceHeights = cardHeights.filter { providerIDs.contains($0.key) }
    }

    private func section(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(group)
            container(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: .named(reorderSpaceName))
    }

    private func header(_ group: ProviderGroup) -> some View {
        ProviderSectionHeader(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            warning: dataStore.headerNotice(for: group.provider.id),
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            staleness: dataStore.stalenessHint(for: group.provider.id),
            onCopyScreenshot: { shareCard(group) }
        )
        // Keep the provider mark and hover-revealed copy control aligned with the card's content edges.
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
        .contextMenu {
            // Hides the whole provider section (the Customize provider list brings it back). Mirrors
            // the per-metric "Hide" but one level up, so the verb order reads the same on a header as a row.
            Button("Hide \(group.provider.displayName)") {
                container.enablement.setEnabled(false, for: group.provider.id)
            }
            Divider()
            Button("Refresh \(group.provider.displayName)") {
                Task { await dataStore.refresh(providerID: group.provider.id, force: true) }
            }
            Button("Customize…") {
                openCustomize(for: group.provider.id)
            }
            Divider()
            Button("Share Screenshot") { _ = shareCard(group) }
        }
    }

    /// Renders the provider's branded share card and copies the PNG to the clipboard. The appearance is
    /// taken from the popover's own `colorScheme` — this view is hosted in the popover panel, whose
    /// appearance is `AppearanceSetting.current` (explicit for Light/Dark, the menu bar for System) — so
    /// the export matches the card on screen instead of guessing from `NSApp.effectiveAppearance`. The
    /// same render path backs the footer's "Share Screenshot" submenu, which reaches it without a
    /// right-click.
    private func shareCard(_ group: ProviderGroup) -> Bool {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme
        )
    }

    /// A row's placed widget paired with its resolved descriptor + data, so each `dataStore.data(for:)`
    /// is computed once per render and reused by both the condensing rule and the row. Keyed off the
    /// `PlacedWidget` so `ForEach` identity stays exactly what it was before this was precomputed.
    private struct ResolvedRow: Identifiable {
        let widget: PlacedWidget
        let descriptor: WidgetDescriptor
        let data: WidgetData
        var id: PlacedWidget.ID { widget.id }
    }

    private enum DashboardMetricCardRow: Identifiable {
        case metric(ResolvedRow)
        /// Faint separator between adjacent metric modules, keyed by the row it precedes. Skipped
        /// inside a condensed one-liner cluster, which reads as a single module.
        case hairline(before: String)
        case divider
        /// #596: the provider's quick-link buttons (Status / Console / Dashboard ...), pinned at the
        /// bottom of the collapsible expanded section. They collapse with the caret — part of the
        /// expander, not always-visible chrome.
        case links([ProviderLink])

        var id: String {
            switch self {
            case .metric(let row):
                "metric:\(row.descriptor.id)"
            case .hairline(let beforeID):
                "hairline-before:\(beforeID)"
            case .divider:
                "expanded-divider"
            case .links:
                "provider-links"
            }
        }
    }

    private func container(_ group: ProviderGroup) -> some View {
        // Resolve each row's descriptor + data exactly once per render, then reuse it for both the
        // neighbor-aware condensing rule and the row itself — `dataStore.data(for:)` used to be
        // recomputed several times per row (twice per adjacent pair plus once in `row`).
        let providerID = group.provider.id
        let isExpanded = layout.isProviderExpanded(providerID)
        let alwaysRows = resolvedRows(group.alwaysShownWidgets)
        let expandedRows = resolvedRows(group.expandedWidgets)
        // The caret separates Always Visible and On Demand rows, so text-row condensing should not
        // bridge across it. Each side tightens only against rows on the same side of the separator.
        let condensedIDs = visibleCondensedTextRowIDs(alwaysRows: alwaysRows, expandedRows: isExpanded ? expandedRows : [])
        let cardRows = metricCardRows(
            alwaysRows: alwaysRows,
            expandedRows: expandedRows,
            hasExpandedMetrics: group.hasExpandedMetrics,
            isExpanded: isExpanded,
            links: dataStore.links(for: providerID),
            condensedIDs: condensedIDs
        )
        // Same card builder the lifted preview uses, so the floating chip can't drift from the live card.
        return DashboardMetricCard {
            // One stable list keeps the drag-owning metric row alive when it crosses the caret boundary.
            // Separate always-shown/expanded loops can tear that source view down before `onEnded` fires,
            // leaving the lift overlay visible until another drag forces a reset.
            ForEach(cardRows) { cardRow in
                switch cardRow {
                case .metric(let entry):
                    row(entry.descriptor, data: entry.data, in: providerID,
                        condensedTop: condensedIDs.contains(entry.descriptor.id))
                case .hairline:
                    CardHairline()
                case .links(let links):
                    ProviderLinksView(links: links)
                case .divider:
                    expandToggle(providerID: providerID, isExpanded: isExpanded)
                }
            }
        }
    }

    private func resolvedRows(_ widgets: [PlacedWidget]) -> [ResolvedRow] {
        widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return ResolvedRow(widget: widget, descriptor: descriptor, data: dataStore.data(for: descriptor))
        }
    }

    private func metricCardRows(
        alwaysRows: [ResolvedRow],
        expandedRows: [ResolvedRow],
        hasExpandedMetrics: Bool,
        isExpanded: Bool,
        links: [ProviderLink],
        condensedIDs: Set<String>
    ) -> [DashboardMetricCardRow] {
        // #596: provider quick-link buttons live INSIDE the collapsible expanded section, pinned at its
        // bottom, so collapsing the caret hides them along with the expanded metrics — they're part of
        // the expander, not always-visible chrome. The caret shows for any provider with expanded
        // content (metrics OR links), so a links-only provider still gets a caret to reveal its buttons.
        let hasLinks = !links.isEmpty
        let hasExpandedContent = hasExpandedMetrics || hasLinks
        return metricModuleRows(alwaysRows, condensedIDs: condensedIDs)
            + (hasExpandedContent ? [.divider] : [])
            + (isExpanded ? metricModuleRows(expandedRows, condensedIDs: condensedIDs) : [])
            + (isExpanded && hasLinks ? [.links(links)] : [])
    }

    /// One segment's metric rows with a faint hairline between adjacent modules. A condensed one-liner
    /// (a text row pulled up against the text row above it) gets no hairline — the cluster reads as a
    /// single module, and a line inside it would fight the grouping the hairlines create.
    private func metricModuleRows(_ rows: [ResolvedRow], condensedIDs: Set<String>) -> [DashboardMetricCardRow] {
        var result: [DashboardMetricCardRow] = []
        for row in rows {
            if !result.isEmpty && !condensedIDs.contains(row.descriptor.id) {
                result.append(.hairline(before: row.descriptor.id))
            }
            result.append(.metric(row))
        }
        return result
    }

    /// The centered caret at the bottom of a provider card that reveals or hides its On Demand metrics
    /// and quick links. Rendered whenever the provider has either kind of expanded content. A plain
    /// click toggles just this card; ⌥-click expands/collapses every card with expandable content at
    /// once (the clicked card's direction wins), both on the same spring.
    private func expandToggle(providerID: String, isExpanded: Bool) -> some View {
        Button {
            let expand = !isExpanded
            withAnimation(Motion.spring) {
                if NSEvent.modifierFlags.contains(.option) {
                    for group in layout.displayGroups
                    where group.hasExpandedMetrics || !dataStore.links(for: group.provider.id).isEmpty {
                        _ = layout.setProviderExpanded(expand, for: group.provider.id)
                    }
                } else {
                    _ = layout.setProviderExpanded(expand, for: providerID)
                }
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reorderFrame(
            id: expandedDividerID(for: providerID),
            in: .named(reorderSpaceName)
        )
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::dashboard-expanded-divider"
    }

    private func visibleCondensedTextRowIDs(alwaysRows: [ResolvedRow], expandedRows: [ResolvedRow]) -> Set<String> {
        condensedTextRowIDs(alwaysRows).union(condensedTextRowIDs(expandedRows))
    }

    /// Neighbor-aware rule (shared with the share-card export via `WidgetData.condensedTextRowOffsets`):
    /// IDs of text-only rows sitting directly under another text-only row. Rows can't see their
    /// neighbors, so the list computes the pairs; Compact density pulls these rows up so a run of
    /// one-liners reads as one cluster. Called per segment (always-shown / expanded), so the expand
    /// caret is never crossed.
    private func condensedTextRowIDs(_ rows: [ResolvedRow]) -> Set<String> {
        let offsets = WidgetData.condensedTextRowOffsets(in: rows.map(\.data))
        return Set(offsets.map { rows[$0].descriptor.id })
    }

    private func row(_ descriptor: WidgetDescriptor, data: WidgetData, in providerID: String,
                     condensedTop: Bool) -> some View {
        return WidgetRowView(
            data: data,
            onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
            onToggleMeterStyle: { dataStore.meterStyle.toggle() },
            condensedTop: condensedTop,
            providerID: providerID
        )
            .contentShape(Rectangle())
            .opacity(activeMetricID == descriptor.id ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: descriptor, providerID: providerID))
            .contextMenu { rowMenu(descriptor, providerID: providerID) }
            .reorderFrame(id: descriptor.id, in: .named(reorderSpaceName))
    }

    /// Desktop-native management for a single metric: hide it, pin/unpin it, refresh its provider, or jump
    /// into Customize — without a trip through Customize first. Hide leads (the most-reached-for verb), then
    /// star, then a divider before the two provider-/app-level actions.
    @ViewBuilder
    private func rowMenu(_ descriptor: WidgetDescriptor, providerID: String) -> some View {
        Button("Hide") {
            layout.setMetricEnabled(descriptor.id, false)
        }
        if descriptor.pinnable {
            Button(layout.isPinned(descriptor.id) ? "Unstar" : "Star for menu bar") {
                if layout.isPinned(descriptor.id) {
                    layout.setPinned(false, for: descriptor.id)
                } else if layout.canPin(descriptor.id) {
                    layout.setPinned(true, for: descriptor.id)
                } else {
                    layout.notePinDenied(descriptor.id)
                }
            }
        }
        Divider()
        if let provider = layout.provider(id: providerID) {
            Button("Refresh \(provider.displayName)") {
                Task { await dataStore.refresh(providerID: providerID, force: true) }
            }
        }
        Button("Customize…") {
            openCustomize(for: providerID)
        }
    }

    /// From the dashboard, jump straight into this provider's Customize metrics (L2), not the provider list.
    private func openCustomize(for providerID: String) {
        withAnimation(Motion.modeSwitch) {
            layout.customizeProviderID = providerID
            layout.isEditing = true
        }
    }

    private func providerDragGesture(for group: ProviderGroup) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { layout.displayGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for descriptor: WidgetDescriptor, providerID: String) -> some Gesture {
        reorderDragGesture(
            id: descriptor.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(for: descriptor, value: $0) },
            orderedIDs: { metricTargetIDs(for: providerID) },
            reorder: { target in
                let current = metricTargetIDs(for: providerID)
                if current.contains(expandedDividerID(for: providerID)) {
                    guard let next = LayoutStore.reordered(current, dragged: descriptor.id, target: target) else {
                        return false
                    }
                    return layout.applyMetricDividerOrder(
                        next,
                        dragged: descriptor.id,
                        dividerID: expandedDividerID(for: providerID),
                        in: providerID
                    )
                }
                return layout.reorderMetric(dragged: descriptor.id, target: target, in: providerID)
            }
        )
    }

    private func metricTargetIDs(for providerID: String) -> [String] {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return []
        }
        let alwaysShown = group.alwaysShownWidgets.compactMap { layout.descriptor(for: $0)?.id }
        // The caret is a drop target whenever the expanded section is open — including a links-only
        // section (buttons but no expanded metrics), so a metric can be dragged past the caret to tuck
        // it below the fold even when only buttons are showing there.
        let hasExpandedContent = group.hasExpandedMetrics || !dataStore.links(for: group.provider.id).isEmpty
        guard hasExpandedContent, layout.isProviderExpanded(providerID) else { return alwaysShown }
        let expanded = group.expandedWidgets.compactMap { layout.descriptor(for: $0)?.id }
        return alwaysShown + [expandedDividerID(for: providerID)] + expanded
    }

    private func makeProviderLift(for group: ProviderGroup, value: DragGesture.Value) -> ReorderLift? {
        // The floating preview should match what the card shows: only the always-shown rows unless this
        // provider's caret is currently open.
        let visibleWidgets = layout.isProviderExpanded(group.provider.id) ? group.widgets : group.alwaysShownWidgets
        let rows = visibleWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        return ReorderLift.make(
            id: group.provider.id,
            payload: .dashboardProvider(
                provider: group.provider,
                plan: dataStore.plan(for: group.provider.id),
                rows: rows
            ),
            value: value,
            frames: frameStore.frames
        )
    }

    private func makeMetricLift(for descriptor: WidgetDescriptor, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: descriptor.id,
            payload: .dashboardMetric(data: dataStore.data(for: descriptor)),
            value: value,
            frames: frameStore.frames
        )
    }
}
