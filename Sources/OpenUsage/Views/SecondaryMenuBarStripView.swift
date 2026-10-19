import SwiftUI

@MainActor
struct SecondaryMenuBarStripView: View {
    let groups: [MenuBarContent.Group]
    let isDashboardOpen: Bool
    let onToggleDashboard: () -> Void
    let onCollapse: () -> Void
    var onResetPosition: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "circle.grid.2x3.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 11) {
                    ForEach(groups, id: \.providerID) { group in
                        HStack(spacing: 4) {
                            ProviderIcon(source: group.icon, inset: 0.04)
                                .frame(width: 15, height: 15)
                            metricsView(group.metrics)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleDashboard)

            Divider()
                .frame(height: 14)
                .opacity(0.5)

            Button(action: onToggleDashboard) {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isDashboardOpen ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }

            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .modifier(SecondaryBarGlassModifier())
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .fixedSize()
        .contextMenu {
            Button("Open Dashboard", action: onToggleDashboard)
            if let onResetPosition {
                Button("Reset Position", action: onResetPosition)
            }
            Divider()
            Button("Collapse Bar", action: onCollapse)
        }
    }

    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric]) -> some View {
        if metrics.count <= 1 {
            Text(metrics.first?.value ?? "")
                .font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(metrics, id: \.id) { metric in
                    Text(metric.value)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .fixedSize()
        }
    }
}

private struct SecondaryBarGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                BehindWindowGlassView()
                    .clipShape(Capsule(style: .continuous))
            }
    }
}

private struct BehindWindowGlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.alphaValue = 0.78
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}
