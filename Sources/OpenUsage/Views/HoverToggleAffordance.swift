import SwiftUI

/// Hover cue for the clickable toggle texts on meter rows — the "52% left" ⟷ "48% used" headline,
/// the "Resets in 3h" ⟷ "6:38 PM" reset label, and the flame's run-out time. These flip a global
/// display mode on click but are plain text at rest, so a faint quaternary capsule lights behind the
/// text while the pointer is over it: the same chip idiom the spend-value and sparkline highlights
/// use, with their negative insets (the row's height must not shift) and quick opacity fade. Plain
/// `@State` + `onHover`, matching `ProviderSectionHeader`'s copy-control reveal.
private struct HoverToggleAffordance: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -7)
                    .padding(.vertical, -4)
                    .opacity(isHovering ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Lights a faint capsule behind the view while the pointer is over it — the hover cue for the
    /// meter rows' click-to-toggle texts. No tooltip; the click targets already carry one.
    func hoverToggleAffordance() -> some View {
        modifier(HoverToggleAffordance())
    }
}
