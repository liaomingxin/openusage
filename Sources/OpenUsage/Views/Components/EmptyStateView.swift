import SwiftUI

/// The quiet, centered empty state every list surface shares — the dashboard with nothing enabled,
/// an Agent Usage window with no runs, a Total Spend period with nothing to show. A one-line title
/// (semibold, primary) and an optional secondary sentence beneath, generously padded so it reads as
/// a deliberate state rather than a missing row. Never a fabricated zero: callers show this instead
/// of an empty ring or a `$0.00` line.
struct EmptyStateView: View {
    let title: String
    var message: String? = nil

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: density.supportingPointSize, weight: .semibold))
                .foregroundStyle(.primary)
            if let message {
                Text(message)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}
