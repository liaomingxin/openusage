import SwiftUI

/// The grouped-card section used by every management screen: a small caption title (with an optional
/// trailing accessory — an info glyph, a warning triangle) over a rounded card of rows. Settings,
/// iCloud Sync, Customize's Always Visible / On Demand, API Key, and Cost Estimates all build through
/// this, so the title scale, the title→card gap, and the header inset live in one place and can't
/// drift between screens.
///
/// `clipsContent` clips the card body to the card's rounded shape — for cards whose rows paint a
/// flush rectangle background (the API-key editor's recessed block) that would otherwise poke out of
/// the rounded bottom corners. Off by default so native controls' focus rings aren't clipped.
struct SectionCard<Accessory: View, Rows: View>: View {
    let title: String
    var clipsContent = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var rows: Rows

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: density.captionPointSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                accessory
            }
            .padding(.horizontal, Theme.sectionHeaderInset)
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        let body = VStack(alignment: .leading, spacing: 0) {
            rows
        }
        .cardSurface()
        if clipsContent {
            body.clipShape(Theme.cardShape)
        } else {
            body
        }
    }
}

extension SectionCard where Accessory == EmptyView {
    /// A section with a plain title and no header accessory.
    init(_ title: String, clipsContent: Bool = false, @ViewBuilder rows: () -> Rows) {
        self.init(title: title, clipsContent: clipsContent, accessory: { EmptyView() }, rows: rows)
    }
}

/// One control row inside a `SectionCard`: the label on the leading edge, the control (toggle, popup
/// picker, button) on the trailing edge — System Settings' row anatomy. Same insets as a Customize
/// metric row, so every card on every screen shares one rhythm. The `Label`-generic form takes a
/// custom leading view for rows whose label carries more than text (a spinner, an info glyph, a
/// two-line explanation).
struct ControlRow<Label: View, Control: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var control: Control

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        HStack(spacing: 10) {
            label
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, density.controlRowPadding)
    }
}

extension ControlRow where Label == ControlRowLabel {
    /// The common case: a one-line text label.
    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.init(label: { ControlRowLabel(title: title) }, control: control)
    }
}

/// The plain text label of a `ControlRow`, at the density's body size (regular weight — the control
/// beside it carries the emphasis).
struct ControlRowLabel: View {
    let title: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        Text(title)
            .font(.system(size: density.bodyPointSize))
    }
}

/// An explanatory caption inside a `SectionCard` — the one-sentence note under a row ("Adds a global
/// `openusage` command…"), or, tinted `Theme.notice`, an inline error/paused notice. Full width,
/// wrapping, flush with the rows' content edge. `topPadding` is for a caption that follows a
/// `Divider` rather than a row (the row's own padding otherwise provides the gap).
struct CardCaption: View {
    let text: String
    var tint: AnyShapeStyle = AnyShapeStyle(.secondary)
    var topPadding: CGFloat = 0

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        Text(text)
            .font(.system(size: density.captionPointSize))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.top, topPadding)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
