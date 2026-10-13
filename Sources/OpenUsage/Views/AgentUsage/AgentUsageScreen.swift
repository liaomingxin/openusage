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
    @AppStorage("agentUsage.metric") private var metricRawValue = TotalSpendMetric.cost.rawValue
    @State private var hoveredAgentID: String?

    private static let ringColumnWidth: CGFloat = 132
    private static let legendColumnMaxWidth: CGFloat = 360

    private var window: AgentUsageWindow {
        AgentUsageWindow(rawValue: windowRawValue) ?? .today
    }

    private var metric: TotalSpendMetric {
        TotalSpendMetric(rawValue: metricRawValue) ?? .cost
    }

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                summarySection
                    .padding(.bottom, density.sectionSpacing)
                content
                PopoverSourceNote(text: "Scanned from local agent logs — costs are provider-reported or estimated from bundled rates")
                    .padding(.top, density.sectionSpacing)
            }
            .animation(Motion.spring, value: windowRawValue)
            .animation(Motion.spring, value: metricRawValue)
            .animation(Motion.spring, value: store.isLoading)
            .padding(.horizontal, Theme.screenInset)
            .padding(.top, density.contentTopPadding)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.refreshIfNeeded() }
    }

    // MARK: - Top Summary Card (Cost / Cost/MTok / Tokens)

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            summaryHeader
            summaryCard
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 5) {
            metricMenu
            if store.isLoading {
                MotionAwareProgressView(controlSize: .mini)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.sectionHeaderInset)
        .padding(.vertical, 2)
    }

    private var metricMenu: some View {
        Menu {
            ForEach(TotalSpendMetric.allCases) { option in
                Button {
                    metricRawValue = option.rawValue
                } label: {
                    if option == metric {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(metric.title)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Agent Usage Metric")
        .accessibilityValue(metric.title)
    }

    private var summaryCard: some View {
        summaryCardBody
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .cardSurface()
    }

    @ViewBuilder
    private var summaryCardBody: some View {
        let total = store.report(for: window)?.totalSpend ?? TotalSpend(period: .today, slices: [])
        let projection = total.projection(for: metric)
        let tokenCounts = Dictionary(uniqueKeysWithValues: total.slices.map { ($0.provider.id, $0.tokenCount) })
        if projection.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                windowPicker
                EmptyStateView(title: metric.emptyMessage)
                    .padding(.vertical, -8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 18) {
                TotalSpendRing(projection: projection, hoveredProviderID: $hoveredAgentID)
                    .frame(width: Self.ringColumnWidth)
                    .frame(maxHeight: .infinity, alignment: .center)
                VStack(alignment: .leading, spacing: 12) {
                    windowPicker
                    TotalSpendLegend(
                        projection: projection,
                        tokenCounts: tokenCounts,
                        hoveredProviderID: $hoveredAgentID
                    )
                }
                .frame(maxWidth: Self.legendColumnMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var windowPicker: some View {
        CapsuleSegmentedPicker(
            options: AgentUsageWindow.allCases,
            selection: Binding(get: { window }, set: { windowRawValue = $0.rawValue }),
            label: \.title
        )
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
