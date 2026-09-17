import SwiftUI

/// The centered source-note footer the hover popovers share (model breakdown, usage trend), so the
/// two panels can't drift apart in style.
struct PopoverSourceNote: View {
    let text: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        Text(text)
            .font(.system(size: density.captionPointSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
