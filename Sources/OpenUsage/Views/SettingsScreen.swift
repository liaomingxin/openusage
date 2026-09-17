import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

/// The in-popover Settings screen — the popover's third mode alongside the dashboard and
/// Customize. It replaces the old separate Settings window, which forced the popover closed every
/// time it opened. Sections are `SectionCard`s (caption header over a rounded card of `ControlRow`s)
/// laid out in the dashboard's two-column masonry, so the popover keeps one visual language;
/// controls sit on each row's trailing edge like System Settings. The footer already shows the
/// version; the release build adds an "Updates" section (auto-check, beta channel, and a full-width
/// manual check button).
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater

    @State private var launchAtLogin = LaunchAtLoginSetting()
    @State private var commandLineTool = CommandLineToolInstaller()
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(ReduceAnimationsSetting.key) private var reduceAnimations = ReduceAnimationsSetting.fallback
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.fallback
    /// Surfaced under the Advanced rows when copying the path or revealing the file fails.
    @State private var logActionError: String?
    /// Gates the destructive Reset All Settings action behind a confirmation alert. Settings remains
    /// mounted after its first visit, so leaving the screen must explicitly dismiss a pending alert.
    @State private var isPresentingResetConfirm = false
    /// Remounts `ShortcutRecorderField` after a reset. The field seeds its chip from the
    /// KeyboardShortcuts store only on appear (the store isn't observable), so without a fresh
    /// identity the still-mounted Settings screen would keep showing the cleared shortcut.
    @State private var shortcutFieldGeneration = 0
    /// Settings stays mounted between visits, so explicitly restore its previous scroll-to-top behavior.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// The screen's sections in display order — the grid walks them in this order, so General and
    /// iCloud Sync head the two columns. Enumerated (rather than listed inline) so the masonry can
    /// place them as identifiable cards.
    private enum Section: String, CaseIterable, Identifiable {
        case general, iCloudSync, appearance, usageDisplay, notifications, privacy, commandLine, advanced
        case updates
        var id: String { rawValue }
    }

    /// Fills the region the dashboard's pinned footer leaves. Same scroller treatment as Customize:
    /// the overlay scroller stays (the scroll edge effect needs it) but is invisible.
    var body: some View {
        PopoverScrollView {
            content
        }
        .scrollPosition($scrollPosition)
    }

    /// The sections shown: Updates only while the updater is active (only the signed release build
    /// ships a feed; the dev build and a bare `swift run`, with no feed, hide it).
    private var visibleSections: [Section] {
        Section.allCases.filter { $0 != .updates || updater.isActive }
    }

    private var content: some View {
        // The dashboard's two-column masonry, so the settings cards pack the wide panel the way the
        // provider cards do instead of stretching every label→control row across it. Same section
        // rhythm as the dashboard and Customize (all read the density setting). The cross-link to
        // Customize sits full width under the grid — a navigation row, not a settings card.
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            MasonryGrid(items: visibleSections, spacing: density.sectionSpacing) { section in
                sectionView(section)
            }
            // Mirror of the Customize cross-link — the layout controls live on the other screen.
            ScreenCrossLinkRow(
                systemImage: "slider.horizontal.3",
                title: "Customize",
                subtitle: "Choose what's visible and where",
                destination: .customize
            )
        }
        .padding(.horizontal, Theme.screenInset)
        .padding(.vertical, 12)
        .onChange(of: layout.screen) { _, screen in
            if screen == .settings {
                scrollPosition.scrollTo(edge: .top)
                launchAtLogin.refreshStatus()
                commandLineTool.refreshStatus()
            } else {
                isPresentingResetConfirm = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard layout.screen == .settings else { return }
            launchAtLogin.refreshStatus()
            commandLineTool.refreshStatus()
        }
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        switch section {
        case .general: generalSection
        case .iCloudSync: ICloudSyncSettingsSection(sync: container.iCloudSync)
        case .appearance: appearanceSection
        case .usageDisplay: usageDisplaySection
        case .notifications: NotificationsSettingsSection()
        case .privacy: privacySection
        case .commandLine: commandLineSection
        case .advanced: advancedSection
        case .updates: updatesSection
        }
    }

    private var generalSection: some View {
        SectionCard("General") {
            // The dashboard's cross-provider Total Spend card; at least one enabled spend-capable
            // provider must exist, so this toggle can't conjure it up alone.
            ControlRow("Show Total Spend") {
                Toggle("", isOn: $showTotalSpend)
                    .settingsSwitchStyle()
            }
            ControlRow("Launch at Login") {
                Toggle("", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.update(to: $0) }
                ))
                    .settingsSwitchStyle()
            }
            if let launchAtLoginError = launchAtLogin.errorMessage {
                CardCaption(text: launchAtLoginError, tint: Theme.notice)
            }
            // Click-to-record field; its ⓧ clears the combo and disables the shortcut.
            ControlRow("Global Shortcut") {
                ShortcutRecorderField(name: .togglePopover, isVisible: layout.screen == .settings)
                    .id(shortcutFieldGeneration)
                    .hoverTooltip("Open OpenUsage from anywhere")
            }
        }
    }

    private var appearanceSection: some View {
        @Bindable var layout = container.layout
        @Bindable var transparency = container.transparency
        return SectionCard("Appearance") {
            ControlRow("Icon Style") {
                picker($layout.menuBarStyle, options: MenuBarStyle.allCases, label: \.label)
            }
            ControlRow("Theme") {
                picker($appearance, options: AppearanceSetting.allCases, label: \.label)
                    // NSApp-level so the popover panel restyles too (it ignores preferredColorScheme).
                    .onChange(of: appearance) {
                        AppearanceSetting.applyCurrent()
                    }
            }
            ControlRow("Density") {
                picker($density, options: DensitySetting.allCases, label: \.label)
            }
            ControlRow("Reduce Animations") {
                Toggle("", isOn: $reduceAnimations)
                    .settingsSwitchStyle()
            }
            ControlRow("Time Format") {
                picker($timeFormat, options: TimeFormatSetting.allCases, label: \.label)
            }
            // Translucent popover the proper way (behind-window vibrancy, text stays legible). It
            // yields to the system accessibility settings, and to the party easter egg while that's
            // running (the egg drives the look) — either way, see the paused notice below.
            ControlRow("Increase Transparency") {
                Toggle("", isOn: $transparency.increaseTransparency)
                    .settingsSwitchStyle()
                    // Party mode owns the look while it's active, so disable (dim) the toggle to show
                    // it has no effect right now — its stored value resumes once the egg is exited.
                    .disabled(transparency.secretCodeActive)
            }
            // Egg first: while Party runs it overrides the toggle regardless of the system flags, so
            // its notice takes precedence over the accessibility one.
            if transparency.secretCodeActive {
                CardCaption(text: "Party mode is on, so this stays paused.", tint: Theme.notice)
            } else if transparency.isPaused {
                CardCaption(
                    text: "macOS Reduce Transparency or Increase Contrast is on, so this stays paused.",
                    tint: Theme.notice
                )
            }
            // Both rows surface only after the secret code has been entered. Party Mode is the egg's
            // own switch: turning it off (like re-typing the code) exits the egg and hides both rows,
            // dropping back to the base state. Drunk Mode escalates the readable party into the woozy,
            // barely-readable state and back — turning it off stays in the party (4 → 3), while turning
            // Party Mode off from there clears Drunk Mode too (4 → base).
            if transparency.secretCodeActive {
                ControlRow("Party Mode") {
                    Toggle("", isOn: $transparency.partyModeActive)
                        .settingsSwitchStyle()
                }
                ControlRow("Drunk Mode") {
                    Toggle("", isOn: $transparency.drunkMode)
                        .settingsSwitchStyle()
                }
                // The egg yields to the accessibility flags too: when one is on the panel stays
                // opaque, so explain why the party looks normal rather than leaving it a mystery.
                if transparency.partyPaused {
                    CardCaption(
                        text: "macOS Reduce Transparency or Increase Contrast is on, so the party stays paused.",
                        tint: Theme.notice
                    )
                }
            }
        }
    }

    private var usageDisplaySection: some View {
        @Bindable var store = container.dataStore
        return SectionCard("Usage Display") {
            ControlRow("Show Usage As") {
                picker($store.meterStyle, options: WidgetDisplayMode.allCases, label: \.label)
            }
            ControlRow("Reset Times") {
                picker($store.resetDisplayMode, options: ResetDisplayMode.allCases, label: \.label)
            }
            // Off (default) leaves pacing on yellow and red only. On also surfaces projection
            // and the even-pace tick on blue rows.
            ControlRow("Always Show Pacing") {
                Toggle("", isOn: $store.alwaysShowPacing)
                    .settingsSwitchStyle()
                    .hoverTooltip("Show how you're pacing on every metric, not just ones near their limit")
            }
        }
    }

    private var privacySection: some View {
        @Bindable var privacy = container.privacy
        return SectionCard("Privacy") {
            ControlRow("Hide From Screen Share") {
                Toggle("", isOn: $privacy.hideUsageWhileScreenSharing)
                    .settingsSwitchStyle()
            }
            CardCaption(text: "While your screen is shared or recorded, the menu bar shows “OpenUsage” instead of your usage.")
            ControlRow {
                Text("Help make OpenUsage better by sharing anonymous usage analytics")
                    .font(.system(size: density.bodyPointSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } control: {
                Toggle("", isOn: Binding(
                    get: { container.telemetry.isEnabled },
                    set: { container.telemetry.setEnabled($0) }
                ))
                .settingsSwitchStyle()
            }
            // Daily activity and crash reports are always on; the toggle only gates extra analytics.
            CardCaption(text: "A daily anonymous active ping and crash reports are always sent. This toggle shares extra anonymous usage analytics — provider refreshes and error types. No account details, credentials, or usage values are sent.")
        }
    }

    private var updatesSection: some View {
        @Bindable var updater = updater
        return SectionCard("Updates") {
            ControlRow("Update Automatically") {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .settingsSwitchStyle()
            }
            ControlRow("Beta Updates") {
                Toggle("", isOn: $updater.betaChannelEnabled)
                    .settingsSwitchStyle()
                    .hoverTooltip("Receive pre-release builds before they ship to everyone")
            }
            // No version label here — the footer already shows it.
            buttonRow("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }

    // MARK: - Command Line

    private var commandLineSection: some View {
        SectionCard("Command Line") {
            ControlRow("Terminal Helper") {
                switch commandLineTool.status {
                case .installed:
                    Button("Uninstall") { commandLineTool.uninstall() }
                case .notInstalled:
                    Button("Install…") { commandLineTool.install() }
                case .conflict:
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            CardCaption(text: "Adds a global `openusage` command agents can use to monitor limits.")
            if commandLineTool.status == .conflict {
                CardCaption(
                    text: "\(commandLineTool.destinationPath) already exists and wasn't installed by OpenUsage.",
                    tint: Theme.notice
                )
            } else if let errorMessage = commandLineTool.errorMessage {
                CardCaption(text: errorMessage, tint: Theme.notice)
            }
        }
    }

    // MARK: - Advanced (logging)

    /// Log-level control plus copy/reveal buttons for the file log, and the Reset All Settings row.
    /// The file lives at a fixed path (`~/Library/Logs/OpenUsage/OpenUsage.log`); raising the level
    /// here applies live (no restart) and persists across launches. Default Info, Debug is opt-in.
    private var advancedSection: some View {
        SectionCard("Advanced") {
            ControlRow("Log Level") {
                picker($logLevel, options: LogLevelSetting.allCases, label: \.label)
                    .onChange(of: logLevel) {
                        // Apply the new floor to the file sink immediately, then record the transition.
                        AppLog.reloadLevel()
                        AppLog.info(.config, "Log level changed to \(logLevel.rawValue)")
                    }
            }
            buttonRow("Copy Log Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(LogFile.url.path, forType: .string) else {
                    logActionError = "Couldn't copy the log path to the clipboard."
                    AppLog.warn(.config, "Copy log path failed")
                    return
                }
                logActionError = nil
            }
            buttonRow("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                logActionError = nil
            }
            if let logActionError {
                CardCaption(text: logActionError, tint: Theme.notice)
            }
            // The Settings-wide destructive reset (issue #602). Red label, confirmation alert;
            // confirming restores every preference to its default — the container-owned stores plus
            // the two view-scoped ones (Launch at Login lives in the system's login-item registry,
            // the update preferences on the updater controller).
            buttonRow("Reset All Settings…", destructive: true) {
                isPresentingResetConfirm = true
            }
            .alert("Reset All Settings?", isPresented: $isPresentingResetConfirm) {
                Button("Reset", role: .destructive) {
                    withAnimation(Motion.spring) { container.resetAllSettings() }
                    launchAtLogin.update(to: false)
                    updater.resetToDefaults()
                    shortcutFieldGeneration += 1
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores every setting and customization to its default and turns providers back on for the tools you have installed. If iCloud sync is on, it turns off and this Mac's synced history is removed. This cannot be undone.")
            }
        }
    }

    // MARK: - Row scaffolding

    /// A full-width glass button row — the "Check for Updates…" idiom, shared by the log buttons and
    /// the destructive reset (red label). Glass on macOS 26+, bordered fallback on macOS 15.
    private func buttonRow(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Only the destructive label takes a color; the default label keeps the button style's
            // own foreground so `.disabled` still dims it.
            if destructive {
                Text(title).foregroundStyle(.red).frame(maxWidth: .infinity)
            } else {
                Text(title).frame(maxWidth: .infinity)
            }
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, density.controlRowPadding)
    }

    /// A trailing popup picker that hugs its selection — segmented controls don't fit a card column
    /// once options have real words in them.
    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
