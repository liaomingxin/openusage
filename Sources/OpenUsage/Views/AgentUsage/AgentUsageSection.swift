import SwiftUI

/// One agent's section on the Agent Usage screen, in the dashboard's card anatomy: the agent's mark
/// and name above a rounded card holding one row per model (each two text lines — name/cost over
/// percent/tokens — and a thin share bar, mirroring the spend tile's model-breakdown hover). The
/// window's cost and tokens sit on the header's trailing edge, matching a provider header's reading
/// hierarchy. Unpriced models land in the card's amber warning row instead of the totals, matching
/// the spend tiles' unknown-model rule.
struct AgentUsageSection: View {
    let summary: AgentUsageSummary

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            DashboardMetricCard {
                modelRows
            }
        }
    }

    /// The agent identity on the mark + name (a provider header's anatomy), with the window's cost
    /// primary and tokens secondary on the trailing edge.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ProviderIcon(source: summary.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.displayName)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(MetricFormatter.number(summary.totalCostUSD, kind: .dollars, style: .row))
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(MetricFormatter.string(
                    for: MetricValue(number: Double(summary.totalTokens), kind: .count, label: "tokens"),
                    style: .row
                ))
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, Theme.sectionHeaderInset)
    }

    @ViewBuilder
    private var modelRows: some View {
        let entries = summary.models.map { model in
            ModelUsageEntry(model: model.model, totalTokens: model.totalTokens, costUSD: model.costUSD)
        }
        let shares = ModelUsageDetail.shares(for: entries)
        let percents = ModelUsageDetail.wholePercents(shares)
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
            if index > 0 {
                CardHairline()
            }
            modelRow(entry, share: shares[index], percent: percents[index])
        }
        if !summary.unpricedModels.isEmpty {
            CardHairline()
            unpricedWarning
        }
    }

    /// Two text lines and the bar, identical to the spend tile's model-breakdown row so per-model
    /// figures read the same wherever they appear.
    private func modelRow(_ model: ModelUsageEntry, share: Double, percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.model)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let cost = model.costUSD {
                    Text(MetricFormatter.number(cost, kind: .dollars, style: .row))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: density.supportingPointSize))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(percent)%")
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(MetricFormatter.string(
                    for: MetricValue(number: Double(model.totalTokens), kind: .count, label: "tokens"),
                    style: .row
                ))
                .monospacedDigit()
            }
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.meterFill(.normal))
                            .frame(width: proxy.size.width * share)
                    }
            }
            .frame(height: density.meterHeight)
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, density.textRowPadding)
    }

    /// Models no pricing source knows — excluded from every total above, so the warning names them
    /// rather than letting the figures silently omit usage.
    private var unpricedWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(Theme.notice)
            Text("No pricing for \(summary.unpricedModels.joined(separator: ", ")) — excluded from totals")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, density.textRowPadding)
    }
}
