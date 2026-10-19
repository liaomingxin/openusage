import AppKit
import SwiftUI

/// A configurable masonry grid of provider and family cards using the shared metric rows.
/// Drag headers to reorder providers/families or metric rows to reorder within a provider.
/// Local gestures and frame geometry keep reordering inside the menu-bar popover.
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
    @State private var selectedFamilyAccountIDs: [String: String] = [:]
    /// Latest measured height of each card section, lifted from the reorder frames (which already
    /// measure every section each layout pass).
    @State private var cardHeights: [String: CGFloat] = [:]
    /// The heights the column split is actually balanced with — see `recordHeights`.
    @State private var balanceHeights: [String: CGFloat] = [:]
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(DashboardFilterMode.key) private var filterMode = DashboardFilterMode.all
    @AppStorage(DashboardGroupingSetting.groupByFamilyKey) private var groupByFamily = true
    @AppStorage(DashboardColumnsSetting.key) private var columnsSetting = DashboardColumnsSetting.two

    var body: some View {
        let clusters = ProviderFamilyCluster.clusters(from: filteredGroups, groupByFamily: groupByFamily)
        let columns = MasonryLayout.assignColumns(
            clusters, heights: balanceHeights, columnCount: columnsSetting.rawValue
        )
        Group {
            if clusters.isEmpty {
                EmptyStateView(title: filterMode == .alerts ? "All quotas are healthy" : "No matching metrics")
            } else {
                HStack(alignment: .top, spacing: density.sectionSpacing) {
                    ForEach(columns) { column in
                        VStack(alignment: .leading, spacing: density.sectionSpacing) {
                            ForEach(column.items) { cluster in
                                clusterSection(cluster)
                                    .reorderFrame(id: cluster.id, in: .named(reorderSpaceName))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { frames in
            frameStore.frames = frames
            recordHeights(frames, clusters: clusters)
        }
        .onChange(of: clusters.map { $0.groups.map(\.id) }) { _, _ in rebalanceColumns(clusters) }
        .onChange(of: filterMode) { _, _ in resetBalance() }
        .onChange(of: groupByFamily) { _, _ in resetBalance() }
        .onChange(of: columnsSetting) { _, _ in resetBalance() }
        .animation(Motion.spring, value: clusters.map(\.id))
    }

    private var filteredGroups: [ProviderGroup] {
        guard filterMode != .all else { return layout.displayGroups }
        return layout.displayGroups.filter { group in
            if filterMode == .alerts, dataStore.headerNotice(for: group.provider.id) != nil { return true }
            return group.widgets.contains { widget in
                guard let descriptor = layout.descriptor(for: widget) else { return false }
                return filterMode.matches(data: dataStore.data(for: descriptor))
            }
        }
    }

    @ViewBuilder
    private func clusterSection(_ cluster: ProviderFamilyCluster) -> some View {
        if cluster.isMultiAccount && groupByFamily {
            ProviderFamilySection(
                cluster: cluster,
                selectedAccountID: selectedFamilyAccountIDs[cluster.id],
                onSelectAccount: { selectedFamilyAccountIDs[cluster.id] = $0 },
                filterMode: filterMode,
                focusedAccountContent: { group in containerContentRows(group) }
            )
            .opacity(activeProviderID == cluster.id ? 0 : 1)
            .highPriorityGesture(familyDragGesture(for: cluster))
            .contextMenu {
                Button("Refresh All \(cluster.groups[0].provider.familyName) Accounts") {
                    Task {
                        for group in layout.customizeGroups
                        where ProviderAccountID.family(of: group.provider.id) == cluster.familyID {
                            await dataStore.refreshOnUserRequest(providerID: group.provider.id)
                        }
                    }
                }
                Button("Customize…") { openCustomize(for: cluster.groups[0].provider.id) }
                Divider()
                Button("Hide \(cluster.groups[0].provider.familyName)") {
                    for group in layout.customizeGroups
                    where ProviderAccountID.family(of: group.provider.id) == cluster.familyID {
                        container.enablement.setEnabled(false, for: group.provider.id)
                    }
                }
            }
        } else if let group = cluster.groups.first {
            section(group)
        }
    }

    /// First measurements feed the split; live height changes never shuffle cards under the pointer.
    private func recordHeights(_ frames: [String: CGRect], clusters: [ProviderFamilyCluster]) {
        let clusterIDs = Set(clusters.map(\.id))
        let measured = frames.reduce(into: [String: CGFloat]()) { result, entry in
            if clusterIDs.contains(entry.key) { result[entry.key] = entry.value.height }
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

    private func rebalanceColumns(_ clusters: [ProviderFamilyCluster]) {
        let clusterIDs = Set(clusters.map(\.id))
        balanceHeights = cardHeights.filter { clusterIDs.contains($0.key) }
    }

    private func resetBalance() {
        cardHeights = [:]
        balanceHeights = [:]
    }

    private func section(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(group)
            container(group)
        }
        .opacity(activeProviderID == (groupByFamily ? ProviderAccountID.family(of: group.provider.id) : group.provider.id) ? 0 : 1)
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
        .padding(.horizontal, Theme.sectionHeaderInset)
        .highPriorityGesture(providerDragGesture(for: group))
        .contextMenu {
            // Hides the whole provider section (the Customize provider list brings it back). Mirrors
            // the per-metric "Hide" but one level up, so the verb order reads the same on a header as a row.
            Button("Hide \(group.provider.displayName)") {
                container.enablement.setEnabled(false, for: group.provider.id)
            }
            Divider()
            Button("Refresh \(group.provider.displayName)") {
                Task { await dataStore.refreshOnUserRequest(providerID: group.provider.id) }
            }
            Button("Customize…") {
                openCustomize(for: group.provider.id)
            }
            Divider()
            Button("Share Screenshot") { _ = shareCard(group) }
        }
    }

    /// Copy a branded share card using this popover's appearance, including explicit Light/Dark.
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
        case separator
        case toggle
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
            case .separator:
                "expanded-separator"
            case .toggle:
                "expand-toggle"
            case .links:
                "provider-links"
            }
        }
    }

    private func container(_ group: ProviderGroup) -> some View {
        DashboardMetricCard { containerContentRows(group) }
    }

    /// Shared with the focused family tab so its rows keep their gestures, menus, and hover content.
    private func containerContentRows(_ group: ProviderGroup) -> some View {
        let providerID = group.provider.id
        let isExpanded = layout.isProviderExpanded(providerID)
        let alwaysRows = resolvedRows(group.alwaysShownWidgets)
        let expandedRows = resolvedRows(group.expandedWidgets)
        // Text-row condensing stays within Always Visible and On Demand groups; it never crosses
        // their separator. While collapsed, only the Always Visible group is passed through.
        let condensedIDs = visibleCondensedTextRowIDs(alwaysRows: alwaysRows, expandedRows: isExpanded ? expandedRows : [])
        let cardRows = metricCardRows(
            alwaysRows: alwaysRows,
            expandedRows: expandedRows,
            hasExpandedMetrics: !expandedRows.isEmpty,
            isExpanded: isExpanded,
            links: dataStore.links(for: providerID),
            condensedIDs: condensedIDs
        )
        // A single list preserves drag-owning row identity when crossing the expanded divider.
        return ForEach(cardRows) { cardRow in
            switch cardRow {
            case .metric(let entry):
                row(entry.descriptor, data: entry.data, in: providerID,
                    condensedTop: condensedIDs.contains(entry.descriptor.id))
            case .hairline:
                CardHairline()
            case .links(let links):
                ProviderLinksView(links: links)
            case .separator:
                DashboardMetricCardSeparator()
                    .reorderFrame(
                        id: expandedDividerID(for: providerID),
                        in: .named(reorderSpaceName)
                    )
            case .toggle:
                expandToggle(providerID: providerID, isExpanded: isExpanded)
            }
        }
    }

    private func resolvedRows(_ widgets: [PlacedWidget]) -> [ResolvedRow] {
        widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            let data = dataStore.data(for: descriptor)
            guard filterMode.matches(data: data) else { return nil }
            return ResolvedRow(widget: widget, descriptor: descriptor, data: data)
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
        let always = metricModuleRows(alwaysRows, condensedIDs: condensedIDs)
        guard hasExpandedContent else { return always }
        guard isExpanded else { return always + [.toggle] }
        return always
            + [.separator]
            + metricModuleRows(expandedRows, condensedIDs: condensedIDs)
            + (hasLinks ? [.links(links)] : [])
            + [.toggle]
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
    /// and quick links. It stays below the Always Visible rows when collapsed and slides below all
    /// expanded content when open. A plain click toggles just this card; ⌥-click expands/collapses
    /// every card with expandable content at once (the clicked card's direction wins), both on the
    /// same spring.
    private func expandToggle(providerID: String, isExpanded: Bool) -> some View {
        DashboardMetricCardCaret(isExpanded: isExpanded) {
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
        }
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
    /// separator is never crossed.
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
                Task { await dataStore.refreshOnUserRequest(providerID: providerID) }
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

    private func familyDragGesture(for cluster: ProviderFamilyCluster) -> some Gesture {
        providerDragGesture(for: cluster.groups[0])
    }

    private func providerDragGesture(for group: ProviderGroup) -> some Gesture {
        let id = groupByFamily ? ProviderAccountID.family(of: group.provider.id) : group.provider.id
        return reorderDragGesture(
            id: id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, id: id, value: $0) },
            orderedIDs: { ProviderFamilyCluster.clusters(from: filteredGroups, groupByFamily: groupByFamily).map(\.id) },
            reorder: { target in
                if groupByFamily { return layout.reorderProviderFamily(draggedFamily: id, targetFamily: target) }
                return layout.reorderProvider(dragged: id, target: target)
            }
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
        let alwaysShown = resolvedRows(group.alwaysShownWidgets).map(\.descriptor.id)
        // Only rendered rows participate in drag targeting; hidden lens rows have no frames.
        let expanded = resolvedRows(group.expandedWidgets).map(\.descriptor.id)
        let hasExpandedContent = !expanded.isEmpty || !dataStore.links(for: group.provider.id).isEmpty
        guard hasExpandedContent, layout.isProviderExpanded(providerID) else { return alwaysShown }
        return alwaysShown + [expandedDividerID(for: providerID)] + expanded
    }

    private func makeProviderLift(for group: ProviderGroup, id: String, value: DragGesture.Value) -> ReorderLift? {
        let isExpanded = layout.isProviderExpanded(group.provider.id)
        let alwaysRows = resolvedRows(group.alwaysShownWidgets).map(\.data)
        let resolvedExpandedRows = resolvedRows(group.expandedWidgets)
        let expandedRows = isExpanded ? resolvedExpandedRows.map(\.data) : []
        let links = dataStore.links(for: group.provider.id)
        let hasExpandedContent = !resolvedExpandedRows.isEmpty || !links.isEmpty
        return ReorderLift.make(
            id: id,
            payload: .dashboardProvider(
                provider: group.provider,
                plan: dataStore.plan(for: group.provider.id),
                rows: alwaysRows + expandedRows,
                dividerIndex: isExpanded && hasExpandedContent ? alwaysRows.count : nil,
                links: links,
                showsCaret: hasExpandedContent,
                isExpanded: isExpanded
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
