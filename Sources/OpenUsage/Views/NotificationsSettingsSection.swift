import SwiftUI
import UserNotifications

/// The Settings "Notifications" section: quota pace notifications as three per-trigger toggles (no
/// master switch — turn all three off to silence), each with an (i) tooltip. A warning glyph on the
/// section header and an action row under the toggles appear when macOS permission isn't authorized
/// and at least one trigger is on. Defaults are all off; the app requests authorization the first time
/// a trigger is turned on.
///
/// Split out of `SettingsScreen` because it owns its own state — the live macOS authorization status,
/// refreshed on appear, when a trigger turns on, and when the app becomes active again (e.g. the user
/// returns from System Settings after re-enabling).
struct NotificationsSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout

    private enum AuthState { case authorized, denied, notDetermined }
    @State private var auth: AuthState = .authorized
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        @Bindable var notifications = container.notificationSettings
        let needsAttention = auth != .authorized && anyToggleOn
        return SectionCard(title: "Notifications") {
            if needsAttention {
                Image(systemName: "exclamationmark.triangle")
                    .imageScale(.small)
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(auth == .denied
                        ? "Notifications are turned off for OpenUsage. Enable them in System Settings."
                        : "OpenUsage needs permission to send alerts.")
            }
        } rows: {
            toggleRow(.underTenPercent, isOn: $notifications.underTenPercent)
            toggleRow(.healthyToClose, isOn: $notifications.healthyToClose)
            toggleRow(.closeToRunningOut, isOn: $notifications.closeToRunningOut)
            if needsAttention {
                actionRow
            }
        }
        .task { await refreshAuth() }
        .onChange(of: layout.screen) { _, screen in
            if screen == .settings { Task { await refreshAuth() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard layout.screen == .settings else { return }
            Task { await refreshAuth() }
        }
        .onChange(of: anyToggleOn) { _, on in
            if on {
                // The first time a trigger is turned on, ask macOS for permission (memoized — it only
                // prompts while authorization is still not determined). Then refresh so the
                // warning/action row reflects the new status.
                AppNotifications.shared.requestAuthorization()
                Task { await refreshAuth() }
            }
        }
    }

    /// One trigger row: the setting label, an (i) info icon with a one-sentence tooltip, and the toggle.
    private func toggleRow(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        ControlRow {
            HStack(spacing: 6) {
                ControlRowLabel(title: milestone.settingLabel)
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .hoverTooltip(milestone.tooltip)
            }
        } control: {
            Toggle("", isOn: isOn)
                .settingsSwitchStyle()
        }
    }

    /// The conditional action under the toggles: a full-width "Open System Settings" button when macOS
    /// denied permission, or "Allow Notifications" when still undecided. The reason lives in the header
    /// triangle's tooltip. Shown only when a trigger is on.
    private var actionRow: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if auth == .denied {
                    AppNotifications.shared.openSystemNotificationsSettings()
                } else {
                    AppNotifications.shared.requestAuthorization()
                    Task { await refreshAuth() }
                }
            } label: {
                Text(auth == .denied ? "Open System Settings" : "Allow Notifications")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.vertical, density.controlRowPadding)
        }
    }

    /// True when at least one trigger is on — the gate for the permission warning + action row.
    /// Delegates to the store's `anyEnabled` so the disjunction lives in one place.
    private var anyToggleOn: Bool {
        container.notificationSettings.anyEnabled
    }

    /// Read the live macOS authorization status, but only when at least one trigger is on so no
    /// warning shows while all alerts are off.
    private func refreshAuth() async {
        guard anyToggleOn else {
            auth = .authorized
            return
        }
        let status = await AppNotifications.shared.authorizationStatus()
        switch status {
        case .denied: auth = .denied
        case .notDetermined: auth = .notDetermined
        default: auth = .authorized
        }
    }
}
