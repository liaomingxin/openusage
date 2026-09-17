import SwiftUI

/// The full-width capsule meter under a bounded metric's label — the Tahoe-era level-indicator form
/// (capsule, full-height leading-anchored fill, like the redesigned Slider / Control Center).
/// Deliberately NOT the native linear `Gauge`/`ProgressView`, which Tahoe left as the thin legacy
/// bar. The fill is a flat **system color** carrying the pace verdict (blue = well within limits,
/// yellow = projected to land inside the last 10%, red = projected to run out; `Theme.meterFill` /
/// `MeterState.severity`) at full strength on the opaque popover surface; the earlier provider-brand
/// gradient was removed deliberately so the bar's color always reads as state. Empty + colorless
/// without data. A thin tick marks the even-pace line — where usage would sit if it burned evenly
/// across the reset window — on yellow and red bars always, and on blue when "always show pacing" is
/// on. The tick rides in an overlay so it pokes out top and bottom without changing the bar's height.
/// Hovering shows the pace projection (`MeterState.tooltip`).
struct MeterBarView: View {
    let data: WidgetData
    let state: WidgetData.MeterState

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    /// Party easter egg: fill meter bars with the party gradient instead of the severity color. Off by
    /// default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode

    var body: some View {
        let tick = data.paceTick(for: state)
        return GeometryReader { proxy in
            // Track + fill define the bar's height; the tick rides in an `.overlay` so its taller frame
            // pokes out top and bottom without stretching the capsules. (As a ZStack sibling it grew the
            // stack and the flexible capsules stretched with it, so a tick'd bar read as a thicker bar.)
            ZStack(alignment: .leading) {
                // Semantic quaternary fill (not an opacity-faded color) so the track stays vibrant
                // on glass and adapts to Increase Contrast / Reduce Transparency.
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(partyMode ? PartyMode.meterFill : Theme.severityFill(state.severity))
                    .frame(width: fillWidth(track: proxy.size.width))
            }
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: Self.paceTickWidth, height: density.meterHeight + Self.paceTickOverhang)
                        .offset(x: paceTickOffset(track: proxy.size.width, fraction: tick))
                }
            }
        }
        .frame(height: density.meterHeight)
        .animation(Motion.spring, value: data.fraction)
        .accessibilityHidden(true)
        .hoverTooltip(state.tooltip)
    }

    private static let paceTickWidth: CGFloat = 2
    /// How much taller than the bar the tick is, so it pokes out slightly above and below (half each
    /// end). The bar itself stays at `meterHeight` regardless — the tick lives in an overlay.
    private static let paceTickOverhang: CGFloat = 4

    /// Leading offset that centers the tick on its fraction, clamped so the tick never pokes past
    /// either rounded end of the track.
    private func paceTickOffset(track: CGFloat, fraction: Double) -> CGFloat {
        let centered = track * fraction - Self.paceTickWidth / 2
        return min(max(centered, 0), max(track - Self.paceTickWidth, 0))
    }

    /// Fill width with a minimum-visible rule: any non-zero fraction renders at least a full circle
    /// (width = bar height) so 1–2% never squashes into an invisible sliver — the same idea as the
    /// menu-bar bars' minimum fill.
    private func fillWidth(track: CGFloat) -> CGFloat {
        guard data.hasData, data.fraction > 0 else { return 0 }
        return max(density.meterHeight, track * data.fraction)
    }
}
