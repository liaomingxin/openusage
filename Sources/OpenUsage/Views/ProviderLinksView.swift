import AppKit
import SwiftUI

/// The strip of per-provider quick-link buttons (e.g. "Status", "Console") pinned at the bottom of a
/// provider card's expanded area: a hairline partitions this action strip from the metric rows above,
/// then a row of quaternary capsules — up to three across, wrapping to the next row when a provider
/// ships more. Each button opens its URL in the default browser. Mirrors the legacy Tauri
/// `provider-card` quick-links row, adapted to the native card's expanded area (issue #596 — "bring
/// back provider buttons").
struct ProviderLinksView: View {
    let links: [ProviderLink]
    /// Matches the metric-row inset so the button row lines up with the rows above/below it.
    private static let horizontalInset: CGFloat = 14

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Hard ceiling from #596: never more than three buttons across, regardless of how many links a
    /// provider ships. Fewer links use fewer columns so a lone button isn't boxed into a third of the row.
    private static let maxColumns = 3

    private var columns: [GridItem] {
        let count = min(Self.maxColumns, max(1, links.count))
        return Array(repeating: GridItem(.flexible(), spacing: density.expandedGridSpacing, alignment: .top),
                     count: count)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The strip is an action surface, not another metric, so the hairline fences it off from
            // whatever sits above — the expanded metrics, or the caret in a links-only section.
            CardHairline()
            LazyVGrid(columns: columns, alignment: .leading, spacing: density.expandedGridSpacing) {
                ForEach(links, id: \.self) { link in
                    ProviderLinkButton(link: link)
                }
            }
            .padding(.horizontal, Self.horizontalInset)
            .padding(.top, density.textRowPadding)
            .padding(.bottom, density.textRowPadding)
        }
    }
}

/// One quick link: a plain button over a quaternary capsule (the app's subtle-fill token) that
/// brightens a step on hover — the strip's only affordance, matching the value/sparkline highlight
/// chips elsewhere on the card.
private struct ProviderLinkButton: View {
    let link: ProviderLink

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = URL(string: link.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(link.label)
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: density.supportingPointSize - 2))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(isHovering ? .tertiary : .quaternary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel("\(link.label), opens in browser")
    }
}
