import SwiftUI

/// The grouped metric-card body shared by the live dashboard list and its lifted drag preview:
/// a spacing-0 stack of rows separated by row padding (the live list additionally threads faint
/// `CardHairline`s between adjacent metric modules), the density gutter that keeps the first/last
/// row off the card edge, and the shared card surface. Both surfaces build the card through this so
/// the floating preview can't drift from the live card (it once hard-coded its own spacing).
///
/// The live list threads per-row gestures/opacity/frames through `rows`; the preview passes plain
/// `WidgetRowView`s; the preview's shadow supplies its lifted depth.
struct DashboardMetricCard<Rows: View>: View {
    @ViewBuilder var rows: Rows

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(spacing: 0) {
            rows
        }
        .padding(.vertical, density.cardGutter)
        .cardSurface()
    }
}

/// The faint hairline the live dashboard list inserts between adjacent metric modules inside a card
/// (and above the quick-links strip): a native Divider at reduced opacity, so it groups the three row
/// kinds (meter / text / sparkline) without reading as chrome in either appearance. Inset to the row
/// gutter so it never touches the card's edge. Static renders (share cards, drag previews) skip it.
struct CardHairline: View {
    var body: some View {
        Divider()
            .opacity(0.4)
            .padding(.horizontal, 14)
    }
}
