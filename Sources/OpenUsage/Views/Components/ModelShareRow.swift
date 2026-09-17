import SwiftUI

/// One entry of a ranked share breakdown: two text lines — name / cost on top, share percent / amount
/// beneath — over a thin proportional share bar. The spend tiles' model-breakdown hover panel and the
/// Agent Usage cards both render their per-model figures through this, so a model reads the same
/// wherever it appears. The amount's unit comes from the caller ("tokens" for a spend period, "calls"
/// for Z.ai's MCP tool list). Carries no horizontal inset of its own: the popover pads its whole
/// content, the card pads each row to `Theme.cardRowInset`.
struct ModelShareRow: View {
    let entry: ModelUsageEntry
    /// The entry's share of the list, 0…1 — drives the bar.
    let share: Double
    /// The whole-number percent printed beside the bar (largest-remainder rounded by the caller so a
    /// column always totals 100).
    let percent: Int
    /// Unit word after the amount, e.g. "tokens".
    let unit: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Middle truncation keeps both the family and the variant suffix of a long slug
                // ("claude-opus-4-8-thinking-max") readable when the name has to give way.
                Text(entry.model)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let cost = entry.costUSD {
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
                    for: MetricValue(number: Double(entry.totalTokens), kind: .count, label: unit),
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
        .padding(.vertical, density.textRowPadding)
    }
}
