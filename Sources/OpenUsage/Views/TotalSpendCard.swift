import AppKit
import SwiftUI

/// The dashboard's cross-provider Total Spend section: a donut ring on the left whose segments are
/// each provider's share of the selected metric, with the total in the center, and a right column
/// stacking a compact capsule period picker (Today / Yesterday / 30 Days) over the ranked legend.
/// The title is a pull-down menu for Cost / Cost/MTok / Tokens. Data comes from
/// `TotalSpendAggregator` over the same snapshots the provider cards render. Shown whenever any
/// enabled provider tracks spend (`LayoutStore.hasSpendCapableProvider`) and the toggle at the top
/// of Settings is on; a period (or metric) with nothing to show uses a quiet empty state instead of
/// hiding the card.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pickerNamespace
    /// The provider the pointer is over — set by the legend rows and the ring arcs alike, so hover
    /// links the two in both directions. Shared with the legend, so it lives here.
    @State private var hoveredProviderID: String?

    /// The selected period survives popover closes and relaunches, like the meter-style toggles.
    @AppStorage(TotalSpendSetting.periodKey) private var periodRawValue = TotalSpendPeriod.today.rawValue
    /// The selected metric (Cost / Cost/MTok / Tokens) survives the same way.
    @AppStorage(TotalSpendSetting.metricKey) private var metricRawValue = TotalSpendMetric.cost.rawValue
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    private var metric: TotalSpendMetric {
        TotalSpendMetric(rawValue: metricRawValue) ?? .cost
    }

    /// The spend-tile providers the card may aggregate — capability-based (see
    /// `LayoutStore.spendCapableProviders`), so a provider stays counted even when its own rows are
    /// hidden in Customize, and providers with merely similar-looking dollar rows never leak in.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        TotalSpendAggregator.total(for: period, providers: providers, snapshots: dataStore.snapshots)
    }

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            card
        }
    }

    // MARK: - Header

    /// Section header matching the provider headers' scale: title menu leading, the share control
    /// trailing where a provider header shows its mark.
    private var header: some View {
        HStack(spacing: 5) {
            metricMenu
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip)
            Spacer(minLength: 8)
            shareButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
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

    /// Names the providers actually feeding the ring — the enabled spend-capable set — instead of a
    /// hardcoded list, so disabling a provider (or a new spend provider shipping) can't make the
    /// tooltip lie about what the total reflects.
    private var infoTooltip: String {
        let names = providers.map(\.displayName)
        return "Only includes \(names.formatted(.list(type: .and)))."
    }

    private var shareButton: some View {
        CopyFeedbackButton(accessibilityLabel: "Copy \(metric.title) Screenshot") {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .cardSurface()
            .animation(Motion.spring, value: periodRawValue)
            .animation(Motion.spring, value: metricRawValue)
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

    /// Ring steady on the left in a ~40% column; the right column stacks the compact period picker
    /// over the legend, so a two-provider period no longer stretches the picker across empty space.
    @ViewBuilder private var cardBody: some View {
        if projection.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                periodPicker
                emptyState
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 18) {
                TotalSpendRing(projection: projection, hoveredProviderID: $hoveredProviderID)
                    .frame(width: Self.ringColumnWidth)
                VStack(alignment: .leading, spacing: 12) {
                    periodPicker
                    TotalSpendLegend(
                        projection: projection,
                        tokenCounts: tokenCounts,
                        hoveredProviderID: $hoveredProviderID
                    )
                }
            }
        }
    }

    /// Leading column for the 104pt ring (centered), sized to roughly a 4:6 split against the legend
    /// column at the card's ~596pt content width.
    private static let ringColumnWidth: CGFloat = 232

    /// Raw per-provider token counts for the legend's parenthetical — from the un-projected total,
    /// since projected slices carry only the ranked display amount.
    private var tokenCounts: [String: Double] {
        Dictionary(uniqueKeysWithValues: total.slices.map { ($0.provider.id, $0.tokenCount) })
    }

    /// A capsule segmented switcher in the app's own design language (the footer's glass capsule
    /// controls), replacing the stock `.segmented` picker whose legacy rounded-rect chrome clashes
    /// with the Tahoe look. The selected segment is a Liquid Glass capsule (frosted material on
    /// macOS 15) that slides between segments via `matchedGeometryEffect`. Sizes to its segments —
    /// stretching it across the card read badly once the picker moved into the legend column.
    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TotalSpendPeriod.allCases) { candidate in
                periodSegment(candidate)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
    }

    private func periodSegment(_ candidate: TotalSpendPeriod) -> some View {
        let isSelected = candidate == period
        return Button {
            periodRawValue = candidate.rawValue
        } label: {
            Text(candidate.shortLabel)
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
                    .matchedGeometryEffect(id: "totalSpendPeriod", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: periodRawValue)
    }

    /// A metric/period combination with nothing to show mirrors the spend tiles' "No data" rule —
    /// never a fabricated zero ring.
    private var emptyState: some View {
        Text(metric.emptyMessage)
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// The ring + legend composition shared by the share-card export, so the PNG can't drift from what's
/// on screen. (The live card composes the same two pieces itself, with the period picker stacked
/// above the legend.) Slices come ranked by the selected metric from `TotalSpend.projection`, so the
/// ring reads clockwise from 12 o'clock in the same order the legend reads top-down.
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
private struct TotalSpendRing: View {
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
                Text("\(totalSpendValue(slice.displayAmount, metric: projection.metric, style: .row)) · \(totalSpendShare(slice, in: projection))")
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

/// The ranked legend beside the ring — rows in the ring's clockwise order, so scanning the ring from
/// 12 o'clock matches reading top-down. Each row is one line: name leading, then the amount, share,
/// and (outside Tokens mode) that provider's token count, all monospaced so the numbers align.
/// Hovering a row drives the ring's hover state, and the ring's arcs drive the emphasis here.
private struct TotalSpendLegend: View {
    let projection: TotalSpendProjection
    let tokenCounts: [String: Double]
    @Binding var hoveredProviderID: String?

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(projection.slices) { slice in
                legendRow(slice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.spring, value: hoveredProviderID)
    }

    private func legendRow(_ slice: TotalSpendProjectedSlice) -> some View {
        let isHovered = hoveredProviderID == slice.provider.id
        return HStack(spacing: 7) {
            Circle()
                .fill(TotalSpendPalette.color(for: slice.provider.id))
                .frame(width: 8, height: 8)
            Text(slice.provider.displayName)
                .font(.system(size: density.supportingPointSize, weight: isHovered ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Tokens always abbreviate in the legend (12.4M), matching spend rows elsewhere —
            // `.full` would spill every digit. Cost modes keep cents via `.row` / `.full`.
            Text("\(totalSpendValue(slice.displayAmount, metric: projection.metric, style: legendValueStyle)) · \(totalSpendShare(slice, in: projection))")
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let tokens = tokenCountText(for: slice) {
                Text("(\(tokens))")
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredProviderID = hovering ? slice.provider.id : nil
        }
    }

    /// The parenthetical token count — skipped in Tokens mode, where the amount already is tokens.
    private func tokenCountText(for slice: TotalSpendProjectedSlice) -> String? {
        guard projection.metric != .tokens,
              let tokens = tokenCounts[slice.provider.id], tokens > 0 else { return nil }
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
private func totalSpendShare(_ slice: TotalSpendProjectedSlice, in projection: TotalSpendProjection) -> String {
    let total = projection.slices.reduce(0) { $0 + $1.displayAmount }
    guard total > 0 else { return "0%" }
    let share = slice.displayAmount / total
    if share > 0, share < 0.005 { return "<1%" }
    return share.formatted(.percent.precision(.fractionLength(0)))
}
