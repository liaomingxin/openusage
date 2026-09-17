import SwiftUI

struct ICloudSyncSettingsSection: View {
    @Bindable var sync: ICloudUsageSyncStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 5) {
                Text("iCloud Sync")
                    .font(.system(size: density.captionPointSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .hoverTooltip(
                        "OpenUsage calculates costs and tokens for Claude, Codex, and other providers "
                            + "from files stored on each Mac. Account limits, credentials, and logs are "
                            + "never shared."
                    )
            }
            .padding(.horizontal, Theme.sectionHeaderInset)

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text("Sync Across Macs")
                        .font(.system(size: density.bodyPointSize))
                    if sync.enabled, sync.isSyncing, sync.serviceError == nil {
                        MotionAwareProgressView(controlSize: .small)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            .accessibilityLabel("Syncing usage history")
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $sync.enabled)
                        .settingsSwitchStyle()
                }
                .padding(.horizontal, Theme.cardRowInset)
                .padding(.vertical, density.controlRowPadding)
                .animation(Motion.spring, value: sync.isSyncing)
                Text("Shares usage history through iCloud, so you can see one combined summary for all your Macs.")
                .font(captionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.cardRowInset)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                if sync.enabled { enabledContent }
            }
            .cardSurface()
        }
    }

    @ViewBuilder
    private var enabledContent: some View {
        Divider()
        if let error = sync.serviceError { inlineNotice(error) }

        if sync.displayedDocuments.isEmpty, !sync.isSyncing, sync.serviceError == nil {
            Text("Waiting for this Mac’s first iCloud update…")
                .font(captionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.cardRowInset)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(sync.displayedDocuments) { document in
                deviceRow(document, isThisMac: document.deviceID == sync.deviceID)
            }
        }
    }

    private func deviceRow(_ document: UsageHistoryDocument, isThisMac: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isThisMac ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(document.deviceName)
                        .font(.system(size: density.bodyPointSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isThisMac {
                        Text("This Mac")
                            .font(.system(size: density.captionPointSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Updated \(relativeAge(document.updatedAt, now: context.date))")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, density.controlRowPadding)
    }

    private var captionFont: Font { .system(size: density.captionPointSize) }

    private func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(captionFont)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600)))h ago" }
        return "\(max(1, Int(seconds / 86_400)))d ago"
    }
}
