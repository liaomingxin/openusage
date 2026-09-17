import SwiftUI

/// The Agent Usage screen's scrolling content: the window picker and window totals above a
/// two-column masonry grid of agent cards — the dashboard's own grid anatomy, so the page reads as
/// a sibling of the provider dashboard rather than a separate report. All four windows' reports
/// come from one scan pass, so switching the picker is instant; the screen refreshes on appear
/// when the last pass is stale.
struct AgentUsageScreen: View {
    @Environment(AgentUsageStore.self) private var store
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(AgentUsageWindow.storageKey) private var windowRawValue = AgentUsageWindow.today.rawValue
    @Namespace private var pickerNamespace
    /// Latest measured height of each agent card, lifted per-card by `onGeometryChange`.
    @State private var cardHeights: [String: CGFloat] = [:]
    /// The heights the column split is actually balanced with — re-snapshotted when the window or
    /// agent set changes (the dashboard's drag equivalent), never on a live measurement alone, so
    /// cards can't shuffle out from under the pointer mid-read.
    @State private var balanceHeights: [String: CGFloat] = [:]

    private var window: AgentUsageWindow {
        AgentUsageWindow(rawValue: windowRawValue) ?? .today
    }

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                controlsRow
                    .padding(.bottom, density.sectionSpacing)
                content
                PopoverSourceNote(text: "Scanned from local agent logs — costs are provider-reported or estimated from bundled rates")
                    .padding(.top, density.sectionSpacing)
            }
            .animation(Motion.spring, value: windowRawValue)
            .animation(Motion.spring, value: store.isLoading)
            .padding(.horizontal, Theme.screenInset)
            .padding(.top, density.contentTopPadding)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.refreshIfNeeded() }
    }

    /// The window picker over the window's cross-agent totals — the same capsule segmented switcher
    /// the Total Spend card uses, so the two period pickers read as one family.
    private var controlsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            windowPicker
            Spacer(minLength: 12)
            totals
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 2) {
            ForEach(AgentUsageWindow.allCases) { candidate in
                windowSegment(candidate)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
    }

    private func windowSegment(_ candidate: AgentUsageWindow) -> some View {
        let isSelected = candidate == window
        return Button {
            windowRawValue = candidate.rawValue
        } label: {
            Text(candidate.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .matchedGeometryEffect(id: "agentUsageWindow", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: windowRawValue)
    }

    /// The window's cross-agent totals, right-aligned beside the picker. A background refresh
    /// (report already showing) swaps in a small progress indicator instead of blanking the figures.
    @ViewBuilder
    private var totals: some View {
        if let report = store.report(for: window) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if store.isLoading {
                    MotionAwareProgressView(controlSize: .mini)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(MetricFormatter.number(report.totalCostUSD, kind: .dollars, style: .row))
                        .font(.system(size: density.headerPointSize, weight: .semibold))
                        .monospacedDigit()
                    Text(MetricFormatter.string(
                        for: MetricValue(number: Double(report.totalTokens), kind: .count, label: "tokens"),
                        style: .row
                    ))
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = store.report(for: window) {
            if report.agents.isEmpty {
                emptyState
            } else {
                agentGrid(report.agents)
            }
        } else if store.isLoading {
            loadingState
        } else {
            emptyState
        }
    }

    /// The dashboard's two-column masonry grid, minus the drag machinery: two independent columns,
    /// each card joining the currently shorter one. Measured heights keep the split balanced; a
    /// card's height doesn't depend on which equal-width column it lands in, so the split converges
    /// after one measurement pass instead of looping.
    private func agentGrid(_ agents: [AgentUsageSummary]) -> some View {
        let columns = Self.assignColumns(agents, heights: balanceHeights)
        return HStack(alignment: .top, spacing: density.sectionSpacing) {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: density.sectionSpacing) {
                    ForEach(column.agents) { summary in
                        AgentUsageSection(summary: summary)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                cardHeights[summary.agentID] = height
                                absorbFirstHeight(summary.agentID, height)
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: agents.map(\.agentID), initial: true) { _, ids in
            rebalanceColumns(Set(ids))
        }
        .animation(Motion.spring, value: windowRawValue)
    }

    /// Splits the cards between the two columns by walking them in display order and always adding
    /// the next card to the currently shorter column. A card with no measurement yet counts as the
    /// rough estimate, so a fresh grid starts in an even left/right alternation and settles once
    /// real heights arrive. (Static twin of the dashboard grid's splitter.)
    static func assignColumns(
        _ agents: [AgentUsageSummary], heights: [String: CGFloat]
    ) -> [AgentGridColumn] {
        var columns = [AgentGridColumn(index: 0), AgentGridColumn(index: 1)]
        var totals: [CGFloat] = [0, 0]
        for agent in agents {
            let target = totals[0] <= totals[1] ? 0 : 1
            columns[target].agents.append(agent)
            totals[target] += heights[agent.agentID] ?? Self.estimatedCardHeight
        }
        return columns
    }

    /// Rough stand-in height (header + a couple of rows) for a card that hasn't been measured yet —
    /// only needs to be even across cards so an unmeasured grid alternates left/right.
    static let estimatedCardHeight: CGFloat = 140

    /// One side of the masonry grid, identified by position so a card moving between columns keeps
    /// a stable parent.
    struct AgentGridColumn: Identifiable {
        let index: Int
        var agents: [AgentUsageSummary] = []
        var id: Int { index }
    }

    /// The balance snapshot only absorbs a card's *first* height; later changes (a window switch
    /// growing or shrinking rows) wait for `rebalanceColumns` so the grid never re-splits in
    /// response to its own layout.
    private func absorbFirstHeight(_ id: String, _ height: CGFloat) {
        guard balanceHeights[id] == nil else { return }
        balanceHeights[id] = height
    }

    /// Re-splits the columns against the latest measured heights when the agent set or window
    /// changes, and prunes heights of agents no longer listed.
    private func rebalanceColumns(_ ids: Set<String>) {
        balanceHeights = cardHeights.filter { ids.contains($0.key) }
    }

    /// Never a fabricated zero list: mirrors the spend tiles' "No data" rule.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No agent usage in this window")
                .font(.system(size: density.supportingPointSize, weight: .semibold))
            Text("Run Claude Code, Codex, Pi, or another supported agent and its usage appears here.")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            MotionAwareProgressView(controlSize: .small)
            Text("Scanning local agent logs…")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
