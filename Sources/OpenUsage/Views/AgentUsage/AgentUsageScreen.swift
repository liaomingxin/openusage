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
        CapsuleSegmentedPicker(
            options: AgentUsageWindow.allCases,
            selection: Binding(get: { window }, set: { windowRawValue = $0.rawValue }),
            label: \.title
        )
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

    /// The dashboard's two-column masonry grid, minus the drag machinery (`MasonryGrid`). A window
    /// switch re-flows every card at once, so it re-snapshots the balance too.
    private func agentGrid(_ agents: [AgentUsageSummary]) -> some View {
        MasonryGrid(items: agents, spacing: density.sectionSpacing, rebalanceKey: windowRawValue) { summary in
            AgentUsageSection(summary: summary)
        }
        .animation(Motion.spring, value: windowRawValue)
    }

    /// Never a fabricated zero list: mirrors the spend tiles' "No data" rule.
    private var emptyState: some View {
        EmptyStateView(
            title: "No Agent Usage in This Window",
            message: "Run Claude Code, Codex, Pi, or another supported agent and its usage appears here."
        )
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
