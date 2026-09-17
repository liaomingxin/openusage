import SwiftUI

/// The app's segmented switcher — a capsule in the footer's own glass-control language, replacing
/// the stock `.segmented` picker whose legacy rounded-rect chrome clashes with the Tahoe look. The
/// selected segment is a raised capsule that slides between segments via `matchedGeometryEffect`;
/// the control sizes to its segments rather than stretching across its container.
///
/// Shared by the Total Spend period switcher and the Agent Usage window switcher, so the two read as
/// one family and a tweak lands in both. `label` maps each option to its short segment title; the
/// caller owns persistence (both current users store the selection's raw value in `@AppStorage`).
struct CapsuleSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            selection = option
        } label: {
            Text(label(option))
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
                    .matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
        .animation(Motion.spring, value: selection)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
