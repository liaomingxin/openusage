import AppKit
import SwiftUI

/// Cross-provider spend with a grouped ring/legend or compact strip, sharing the provider snapshots.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    /// The provider the pointer is over — set by the legend rows and the ring arcs alike, so hover
    /// links the two in both directions. Shared with the legend, so it lives here.
    @State private var hoveredProviderID: String?
    /// Whether the pointer is over the header — reveals the share control, like a provider header.
    @State private var isHeaderHovered = false

    /// The selected period survives popover closes and relaunches, like the meter-style toggles.
    @AppStorage(TotalSpendSetting.periodKey) private var periodRawValue = TotalSpendPeriod.today.rawValue
    /// The selected metric (Cost / Cost/MTok / Tokens) survives the same way.
    @AppStorage(TotalSpendSetting.metricKey) private var metricRawValue = TotalSpendMetric.cost.rawValue
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage("dashboard.groupByFamily") private var groupByFamily = true
    @AppStorage("dashboard.filterMode") private var filterModeRaw = "all"
    @AppStorage("totalSpend.compactMode") private var isCompactMode = false

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    private var metric: TotalSpendMetric {
        TotalSpendMetric(rawValue: metricRawValue) ?? .cost
    }

    /// Include spend-capable providers even when their own rows are hidden in Customize.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        let total = TotalSpendAggregator.total(for: period, providers: providers, snapshots: dataStore.snapshots)
        return groupByFamily ? total.groupedByFamily() : total
    }

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    private var compactModeActive: Bool { isCompactMode || filterModeRaw == "quotas" }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            card
        }
    }

    // MARK: - Header

    /// Match provider headers, keeping compact mode available beside the hover-revealed share action.
    private var header: some View {
        HStack(spacing: 5) {
            metricMenu
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip)
            Spacer(minLength: 8)
            compactModeButton
            shareButton
        }
        .padding(.horizontal, Theme.sectionHeaderInset)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHeaderHovered = $0 }
    }

    /// Title that is itself the metric switch — a plain pull-down with zero extra chrome.
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
        .accessibilityLabel("Total Spend Metric")
        .accessibilityValue(metric.title)
    }

    /// Name the enabled providers actually contributing, rather than a fixed provider list.
    private var infoTooltip: String {
        let names = providers.map(\.displayName)
        return "Only includes \(names.formatted(.list(type: .and)))."
    }

    private var compactModeButton: some View {
        Button {
            isCompactMode.toggle()
        } label: {
            Image(systemName: compactModeActive ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(filterModeRaw == "quotas")
        .hoverTooltip(filterModeRaw == "quotas" ? "Quotas view keeps spend compact" : compactModeActive ? "Expand spend" : "Compact spend")
        .accessibilityLabel(compactModeActive ? "Expand Total Spend" : "Compact Total Spend")
    }

    private var shareButton: some View {
        CopyFeedbackButton(accessibilityLabel: "Copy \(metric.title) Screenshot", isRevealed: isHeaderHovered) {
            ShareCardRenderer.shareTotalSpend(
                total: total,
                metric: metric,
                appearance: colorScheme,
                layout: layout
            )
        }
    }

    // MARK: - Card

    private var card: some View {
        cardBody
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.vertical, compactModeActive && !projection.isEmpty ? 4 : 12)
            .frame(maxWidth: .infinity)
            .cardSurface()
            .animation(Motion.spring, value: periodRawValue)
            .animation(Motion.spring, value: metricRawValue)
            .animation(Motion.spring, value: compactModeActive)
            .animation(Motion.spring, value: groupByFamily)
            .contextMenu {
                Button("Share Screenshot") {
                    ShareCardRenderer.shareTotalSpend(
                        total: total,
                        metric: metric,
                        appearance: colorScheme,
                        layout: layout
                    )
                }
            }
    }

    /// Keep the full ring and legend snug; compact mode preserves the same period and metric.
    @ViewBuilder private var cardBody: some View {
        if projection.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                periodPicker
                emptyState
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if compactModeActive {
            compactCardBody
        } else {
            HStack(alignment: .top, spacing: 18) {
                TotalSpendRing(projection: projection, hoveredProviderID: $hoveredProviderID)
                    .frame(width: Self.ringColumnWidth)
                    // Center the ring on the legend column's height (the legend grows with its rows).
                    .frame(maxHeight: .infinity, alignment: .center)
                VStack(alignment: .leading, spacing: 12) {
                    periodPicker
                    TotalSpendLegend(
                        projection: projection,
                        tokenCounts: tokenCounts,
                        hoveredProviderID: $hoveredProviderID
                    )
                }
                .frame(maxWidth: Self.legendColumnMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compactCardBody: some View {
        let totalDisplay = projection.slices.reduce(0) { $0 + $1.displayAmount }
        let center = MetricFormatter.totalSpendRingCenter(projection.centerValue, metric: projection.metric)
        return HStack(spacing: 12) {
            periodPicker
                .fixedSize()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(projection.slices) { slice in
                        Rectangle()
                            .fill(TotalSpendPalette.color(for: slice.provider.id))
                            .frame(width: totalDisplay > 0 ? geometry.size.width * slice.displayAmount / totalDisplay : 0)
                    }
                }
            }
            .frame(height: 6)
            .clipShape(.rect(cornerRadius: 3))
            .accessibilityHidden(true)
            Text("\(center.primary) \(center.unit)")
                .font(.system(size: density.supportingPointSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
        .frame(minHeight: 24)
        .hoverTooltip(projection.slices.prefix(5).map {
            "\($0.provider.displayName): \(totalSpendValue($0.displayAmount, metric: projection.metric, style: .full))"
        }.joined(separator: "\n"))
    }

    /// Air around the 104pt ring prevents the hovered arc's 5% growth from clipping.
    private static let ringColumnWidth: CGFloat = 132

    /// Keep legend names and figures within one glance on wide cards.
    private static let legendColumnMaxWidth: CGFloat = 360

    /// Raw token counts remain available when projection switches to dollars or rates.
    private var tokenCounts: [String: Double] {
        Dictionary(uniqueKeysWithValues: total.slices.map { ($0.provider.id, $0.tokenCount) })
    }

    /// Shared period switcher, sized to its segments rather than stretched across the card.
    private var periodPicker: some View {
        CapsuleSegmentedPicker(
            options: TotalSpendPeriod.allCases,
            selection: Binding(get: { period }, set: { periodRawValue = $0.rawValue }),
            label: \.shortLabel
        )
    }

    /// No data stays empty rather than drawing a fabricated zero ring.
    private var emptyState: some View {
        EmptyStateView(title: metric.emptyMessage)
            .padding(.vertical, -8)
    }
}

/// Shared ring and capped legend composition for screenshot export.
struct TotalSpendRingContent: View {
    let projection: TotalSpendProjection
    /// Per-provider token counts for the legend's parenthetical, keyed by provider ID.
    var tokenCounts: [String: Double] = [:]

    @State private var hoveredProviderID: String?

    var body: some View {
        HStack(spacing: 18) {
            TotalSpendRing(projection: projection, hoveredProviderID: $hoveredProviderID)
            TotalSpendLegend(
                projection: projection,
                tokenCounts: tokenCounts,
                hoveredProviderID: $hoveredProviderID
            )
        }
    }
}

/// The Total Spend donut with its two-line center.
///
/// A period or metric switch **morphs** the arcs: each provider's slice slides and resizes to its
/// new share. Swift Charts' `SectorMark` can't do this — it matches sectors by array position when
/// animating, so any re-sort smears one provider's arc into another's color mid-morph (there is no
/// identity hook for sectors). The ring therefore draws its own sectors: one `RingSectorShape` per
/// provider, identity-keyed by provider ID, with the start/end angles as `animatableData`. SwiftUI
/// animates each provider's own arc, and the color can't swap because each arc view owns its
/// provider's color. The shape reproduces the SectorMark look — golden-ratio hole, hairline gaps,
/// rounded sector corners — so nothing changes visually at rest.
///
/// Hover links the ring and the legend through `hoveredProviderID`: the hovered arc grows slightly
/// and keeps its full color while the rest fade, and the center swaps to that provider's amount and
/// share.
struct TotalSpendRing: View {
    let projection: TotalSpendProjection
    @Binding var hoveredProviderID: String?

    private static let ringDiameter: CGFloat = 104

    var body: some View {
        ZStack {
            // Identity is the provider ID: a provider that exists in both states keeps its view,
            // so a switch animates that arc's angles. A provider entering or leaving fades in/out
            // (the default transition) while the survivors re-flow around it.
            ForEach(arcs) { arc in
                RingSectorShape(startFraction: arc.start, endFraction: arc.end)
                    .fill(TotalSpendPalette.color(for: arc.providerID))
                    .opacity(isDimmed(arc.providerID) ? 0.35 : 1)
                    .scaleEffect(activeHover == arc.providerID ? 1.05 : 1)
                    .onHover { hovering in
                        hoveredProviderID = hovering ? arc.providerID : nil
                    }
            }
            centerLabel
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .animation(Motion.spring, value: hoveredProviderID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Every slice is guaranteed at least this share of the circle, so a tiny provider next to a
    /// dominant one still shows a visible sliver instead of vanishing. Presentation-only — the
    /// legend and center keep the true amounts.
    private static let minimumSliceShare = 0.025

    private struct RingArc: Identifiable, Equatable {
        let providerID: String
        var start: Double
        var end: Double

        var id: String { providerID }
    }

    /// The ranked slices as cumulative ring fractions, with the minimum-sliver floor applied and the
    /// result renormalized so the ring always closes exactly.
    private var arcs: [RingArc] {
        let totalDisplay = projection.slices.reduce(0) { $0 + $1.displayAmount }
        guard totalDisplay > 0 else { return [] }
        let floored = projection.slices.map { max($0.displayAmount / totalDisplay, Self.minimumSliceShare) }
        let sum = floored.reduce(0, +)
        guard sum > 0 else { return [] }

        var cursor = 0.0
        return zip(projection.slices, floored).map { slice, share in
            let width = share / sum
            defer { cursor += width }
            return RingArc(providerID: slice.provider.id, start: cursor, end: cursor + width)
        }
    }

    /// The hover that still names a slice in the current projection — a provider can vanish on a
    /// period/metric switch while the pointer sits still, and a stale ID must not dim everything.
    private var activeHover: String? {
        hoveredProviderID.flatMap { id in
            projection.slices.contains { $0.provider.id == id } ? id : nil
        }
    }

    private var hoveredSlice: TotalSpendProjectedSlice? {
        activeHover.flatMap { id in projection.slices.first { $0.provider.id == id } }
    }

    private func isDimmed(_ providerID: String) -> Bool {
        activeHover != nil && activeHover != providerID
    }

    private var accessibilityLabel: String {
        let center = totalSpendValue(projection.centerValue, metric: projection.metric, style: .full)
        switch projection.metric {
        case .cost:
            return "Total cost \(center) across \(projection.slices.count) providers"
        case .tokens:
            return "Total tokens \(center) across \(projection.slices.count) providers"
        case .costPerMtok:
            return "Blended cost per megatoken \(center) across \(projection.slices.count) providers"
        }
    }

    /// Quiet two-line center — short primary on top, unit underneath — so Cost/MTok (and big token
    /// totals) never force a long one-liner into the hole. While hovering, it becomes that
    /// provider's amount and share over its name; the tooltip still carries the exact total.
    private var centerLabel: some View {
        VStack(spacing: 1) {
            if let slice = hoveredSlice {
                Text("\(totalSpendValue(slice.displayAmount, metric: projection.metric, style: .row)) · \(totalSpendShare(slice.displayAmount, in: projection))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(slice.provider.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                let center = MetricFormatter.totalSpendRingCenter(projection.centerValue, metric: projection.metric)
                Text(center.primary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(center.unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .hoverTooltip(centerTooltip)
    }

    private var centerTooltip: String {
        let exact = totalSpendValue(projection.centerValue, metric: projection.metric, style: .full)
        if projection.isEstimated, projection.metric.usesDollarEstimateNote {
            return "\(exact) · \(WidgetData.localEstimateNote)"
        }
        return exact
    }
}

/// Ranked contributions, capped at five rows by default; clicking `Others (N)` expands all rows in place.
struct TotalSpendLegend: View {
    let projection: TotalSpendProjection
    let tokenCounts: [String: Double]
    @Binding var hoveredProviderID: String?

    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(TotalSpendSetting.periodKey) private var spendPeriodRaw = TotalSpendPeriod.today.rawValue
    @AppStorage(TotalSpendSetting.metricKey) private var spendMetricRaw = TotalSpendMetric.cost.rawValue
    @AppStorage(AgentUsageWindow.storageKey) private var agentWindowRaw = AgentUsageWindow.today.rawValue
    @AppStorage("agentUsage.metric") private var agentMetricRaw = TotalSpendMetric.cost.rawValue
    @AppStorage(DashboardFilterMode.key) private var filterModeRaw = DashboardFilterMode.all.rawValue
    @AppStorage(DashboardGroupingSetting.groupByFamilyKey) private var groupByFamily = true
    @AppStorage("totalSpend.compactMode") private var isCompactMode = false

    @State private var isOthersExpanded = false

    private var visibleSlices: ArraySlice<TotalSpendProjectedSlice> {
        if isOthersExpanded || projection.slices.count <= 5 {
            return projection.slices[...]
        }
        return projection.slices.prefix(4)
    }

    private var expansionResetToken: String {
        "\(popoverIsVisible)|\(spendPeriodRaw)|\(spendMetricRaw)|\(agentWindowRaw)|\(agentMetricRaw)|\(filterModeRaw)|\(groupByFamily)|\(isCompactMode)|\(projection.metric.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(visibleSlices) { slice in
                legendRow(slice)
            }
            if projection.slices.count > 5, !isOthersExpanded {
                othersRow
            }
            if !projection.slices.isEmpty {
                Divider()
                    .opacity(0.4)
                totalRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.spring, value: hoveredProviderID)
        .animation(Motion.spring, value: isOthersExpanded)
        .onChange(of: expansionResetToken) { _, _ in
            isOthersExpanded = false
        }
        .onDisappear {
            isOthersExpanded = false
        }
    }

    private func legendRow(_ slice: TotalSpendProjectedSlice) -> some View {
        legendRowContent(
            name: slice.provider.displayName,
            value: sliceValueText(slice.displayAmount),
            tokens: tokenCountText(tokenCounts[slice.provider.id] ?? 0),
            color: TotalSpendPalette.color(for: slice.provider.id),
            isHovered: hoveredProviderID == slice.provider.id
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredProviderID = hovering ? slice.provider.id : nil
        }
    }

    private var othersRow: some View {
        let remaining = projection.slices.dropFirst(4)
        return Button {
            withAnimation(Motion.spring) {
                isOthersExpanded = true
            }
        } label: {
            legendRowContent(
                name: "Others (\(remaining.count))",
                value: sliceValueText(remaining.reduce(0) { $0 + $1.displayAmount }),
                tokens: tokenCountText(remaining.reduce(0) { $0 + (tokenCounts[$1.provider.id] ?? 0) }),
                color: .secondary,
                showsExpandChevron: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hoveredProviderID = nil } }
        .accessibilityLabel("Expand \(remaining.count) more items")
    }
    private func legendRowContent(
        name: String, value: String, tokens: String?, color: Color,
        isHovered: Bool = false, isTotal: Bool = false, showsExpandChevron: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: density.supportingPointSize, weight: isHovered || isTotal ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if showsExpandChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: density.supportingPointSize, weight: isTotal ? .semibold : .medium))
                .foregroundStyle(isHovered || isTotal ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let tokens {
                Text("(\(tokens))")
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private var totalRow: some View {
        legendRowContent(
            name: "Total", value: totalRowPrimaryText, tokens: totalTokenCountText, color: .clear, isTotal: true
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredProviderID = nil }
        }
    }

    private func sliceValueText(_ amount: Double) -> String {
        "\(totalSpendValue(amount, metric: projection.metric, style: legendValueStyle)) · \(totalSpendShare(amount, in: projection))"
    }

    private var totalRowPrimaryText: String {
        let value = totalSpendValue(projection.centerValue, metric: projection.metric, style: legendValueStyle)
        switch projection.metric {
        case .cost, .tokens:
            return "\(value) · 100%"
        case .costPerMtok:
            return value
        }
    }

    private var totalTokenCountText: String? {
        tokenCountText(projection.slices.reduce(0) { $0 + (tokenCounts[$1.provider.id] ?? 0) })
    }

    /// The parenthetical token count — skipped in Tokens mode, where the amount already is tokens.
    private func tokenCountText(_ tokens: Double) -> String? {
        guard projection.metric != .tokens, tokens > 0 else { return nil }
        return MetricFormatter.number(tokens, kind: .count, style: .row)
    }

    /// Legend amounts: tokens always abbreviated; dollar modes keep exact cents like before.
    private var legendValueStyle: MetricFormatter.Style {
        switch projection.metric {
        case .tokens: .row
        case .cost, .costPerMtok: .full
        }
    }
}

/// Formats one slice or center amount in the projection's metric.
private func totalSpendValue(_ value: Double, metric: TotalSpendMetric, style: MetricFormatter.Style) -> String {
    switch metric {
    case .cost:
        return MetricFormatter.number(value, kind: .dollars, style: style)
    case .tokens:
        return MetricFormatter.number(value, kind: .count, style: style)
    case .costPerMtok:
        return MetricFormatter.costPerMtok(value, style: style)
    }
}

/// A slice's true share of the projection, e.g. `62%`; a tiny but nonzero share reads `<1%` rather
/// than rounding down to a misleading `0%`.
private func totalSpendShare(_ amount: Double, in projection: TotalSpendProjection) -> String {
    let total = projection.slices.reduce(0) { $0 + $1.displayAmount }
    guard total > 0 else { return "0%" }
    let share = amount / total
    if share > 0, share < 0.005 { return "<1%" }
    return share.formatted(.percent.precision(.fractionLength(0)))
}
