import AppKit
import KeyboardShortcuts
import SwiftUI

/// A borderless, non-activating dashboard host that becomes key without activating the accessory app.
/// Unlike `NSPopover`, it receives keyboard input immediately, avoiding asynchronous activation races
/// that otherwise lose Esc/Return and require a second click in text fields or shortcut recorders.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SecondaryStripPanel: NSPanel {
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingWindow = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
            isDraggingWindow = false
            super.sendEvent(event)
        case .leftMouseDragged:
            if let startMouse = dragStartMouse, let startOrigin = dragStartOrigin {
                let mouse = NSEvent.mouseLocation
                let dx = mouse.x - startMouse.x
                let dy = mouse.y - startMouse.y
                if isDraggingWindow || hypot(dx, dy) > 3 {
                    isDraggingWindow = true
                    setFrameOrigin(NSPoint(x: (startOrigin.x + dx).rounded(), y: (startOrigin.y + dy).rounded()))
                    return
                }
            }
            super.sendEvent(event)
        case .leftMouseUp:
            let wasDragging = isDraggingWindow
            dragStartMouse = nil
            dragStartOrigin = nil
            isDraggingWindow = false
            if wasDragging { return }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

/// Owns the status item, draggable secondary strip, and key-capable dashboard panel.
/// `NSStatusItem` + `NSPanel` supports reliable text input and programmatic show/hide, unlike the
/// `MenuBarExtra` window used previously.
@MainActor
final class StatusItemController: NSObject {
    private let container: AppContainer
    private let statusItem: NSStatusItem
    /// Owns the menu-bar strip render loop. Its apply closure captures the `NSStatusItem` directly
    /// (which never retains the controller), so this can be a plain non-optional `let`.
    private let imageUpdater: StatusItemImageUpdater
    private let panel: MenuBarPanel
    private let secondaryPanel: SecondaryStripPanel
    private var secondaryHostingController: NSHostingController<SecondaryMenuBarStripView>?
    private static let secondaryExpandedKey = "menubar.secondaryBarExpanded"
    private static let secondaryCustomXKey = "menubar.secondaryBarCustomX"
    private static let secondaryCustomYKey = "menubar.secondaryBarCustomY"
    private var isUpdatingSecondaryFrame = false
    private var windowMoveObserver: NSObjectProtocol?
    private var isSecondaryBarExpanded: Bool {
        didSet {
            UserDefaults.standard.set(isSecondaryBarExpanded, forKey: Self.secondaryExpandedKey)
        }
    }
    private var latestMenuBarContent = MenuBarContent(groups: [], bars: [])
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        secondaryPanel: secondaryPanel,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private let hostingController: NSHostingController<AnyView>
    /// The panel's backdrop: an opaque tray by default, swapped to a behind-window vibrancy view when
    /// the transparency style is non-opaque. Built once and toggled, so it can't race the style observer.
    private let backdrop = PopoverBackdropView(cornerRadius: StatusItemController.cornerRadius)
    /// Token for the appearance-change observer; held to follow the documented removal pattern.
    private var appearanceObserver: NSObjectProtocol?
    /// Corner radius of the panel surface; tuned to read like a system menu-bar popover.
    private static let cornerRadius: CGFloat = 13

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        self.isSecondaryBarExpanded = UserDefaults.standard.object(forKey: Self.secondaryExpandedKey) as? Bool ?? true
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        // Captures the status item, not `self` — no retain cycle, and no optional property just to
        // work around `[weak self]` being unavailable before `super.init()`. The button is resolved
        // lazily at each apply, so a not-yet-configured button is harmless (same as before the split).
        self.imageUpdater = StatusItemImageUpdater(container: container) { image in
            statusItem.button?.image = image
        }

        let hosting = NSHostingController(
            rootView: AnyView(
                DashboardView()
                    // Own the preference outside `DashboardView` so the view can read the resolved
                    // value while deciding whether to mount its two-page transition structure.
                    .reduceAnimationsWhenRequested()
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(container.subscriptionExpiry)
                    .environment(container.transparency)
                    .environment(container.agentUsage)
                    .environment(updater)
                    .environment(\.resetClaims, container.resetClaims)
            )
        )
        // The host view fills the panel. SwiftUI measures each screen and drives the panel height;
        // content scrolls only when that height reaches the available-screen limit.
        self.hostingController = hosting

        let panel = MenuBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PanelHeightController.panelWidth,
                height: PanelHeightController.defaultHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.heightController = PanelHeightController(panel: panel) { container.layout.screen }
        self.secondaryPanel = SecondaryStripPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        configureSecondaryPanel()
        configureStatusItem()
        imageUpdater.isSecondaryExpanded = { [weak self] in self?.isSecondaryBarExpanded ?? false }
        imageUpdater.onContentUpdated = { [weak self] content in self?.handleMenuBarContentUpdated(content) }
        imageUpdater.update()
        applyTransparency()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.appearance = AppearanceSetting.current.nsAppearance
                self?.secondaryPanel.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        // Registered once here; the controller lives for the app's whole life.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // Esc on the dashboard dismisses through the same code path as a status-item click.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.hidePanel()
        }
        MenuBarPopover.showHandler = { [weak self] in
            self?.container.layout.screen = .dashboard
            self?.showPopover()
        }

        heightController.installBridge()

        AppLog.info(.statusItem, "Status item ready (button: \(self.statusItem.button != nil), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))")
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pin the theme override (nil for System) so the menu bar's appearance doesn't win; tracked
        // live by `appearanceObserver`.
        panel.appearance = AppearanceSetting.current.nsAppearance

        let container = NSView()

        // Backdrop: by default an opaque tray so the data region never shows the desktop through it
        // (Liquid Glass stays reserved for the footer chrome, rendered in-window over this backing). The
        // `PopoverBackdropView` also holds a behind-window vibrancy layer that the transparency style
        // swaps in for Increase Transparency / the secret-code egg. It fills the whole window, so a
        // screen-switch resize can't reveal a transparent strip, and any region SwiftUI leaves unpainted
        // shows the backdrop, not a raw hole. Its opaque tray is `Theme.trayNSColor` (tracks light/dark
        // and the forced appearance override) matching the SwiftUI tray (`DashboardView.PopoverSurface`),
        // rounded via `cornerRadius`. `panel.appearance` (tracked by `appearanceObserver`) pins the mode.
        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // Redraw the SwiftUI content on every step of a height change instead of stretching the layer's
        // cached contents (the default `.onSetNeedsDisplay`), which keeps cards steady during a morph.
        host.layerContentsRedrawPolicy = .duringViewResize
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(backdrop)
        container.addSubview(host, positioned: .above, relativeTo: backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // A plain container VC owns the backdrop; the hosting controller is its child so SwiftUI gets
        // a proper view-controller hierarchy. Panel placement and height live in `heightController`.
        let rootVC = NSViewController()
        rootVC.view = container
        rootVC.addChild(hostingController)
        panel.contentViewController = rootVC
    }

    private func configureSecondaryPanel() {
        secondaryPanel.level = .statusBar
        secondaryPanel.hidesOnDeactivate = false
        secondaryPanel.hasShadow = true
        secondaryPanel.isMovable = true
        secondaryPanel.isMovableByWindowBackground = true
        secondaryPanel.isOpaque = false
        secondaryPanel.backgroundColor = .clear
        secondaryPanel.animationBehavior = .utilityWindow
        secondaryPanel.isReleasedWhenClosed = false
        secondaryPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        secondaryPanel.appearance = AppearanceSetting.current.nsAppearance
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: secondaryPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isUpdatingSecondaryFrame, self.secondaryPanel.isVisible else { return }
                let frame = self.secondaryPanel.frame
                UserDefaults.standard.set(frame.minX, forKey: Self.secondaryCustomXKey)
                UserDefaults.standard.set(frame.maxY, forKey: Self.secondaryCustomYKey)
                if self.panel.isVisible {
                    self.heightController.prepareForOpening(below: frame)
                }
            }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        // Context clicks open the native menu; left-clicks toggle the strip or dashboard.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Transparency

    /// True once the launch application has run, so subsequent style changes animate (the first one
    /// shouldn't fade in from nothing).
    private var hasAppliedTransparency = false

    /// Applies the resolved toggle, egg, and accessibility style, then re-arms one-shot observation
    /// like `StatusItemImageUpdater.update()`. The stored backdrop is ready for the initial call.
    /// Subsequent changes crossfade the window alpha and backdrop together over ~0.55s, matching
    /// SwiftUI's `tooMuchTransparency` animation; the initial appearance is applied immediately.
    private func applyTransparency() {
        let style = withObservationTracking {
            container.transparency.effectiveStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyTransparency()
            }
        }
        let mode: PopoverBackdropView.Mode = style.surfaceTreatment == .opaque ? .opaque : .translucent
        let shouldAnimate = hasAppliedTransparency && !ReduceAnimationsSetting.isEnabled
        hasAppliedTransparency = true
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.55
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = style.windowAlpha
                backdrop.setMode(mode, animated: true)
            }
        } else {
            panel.alphaValue = style.windowAlpha
            backdrop.setMode(mode, animated: false)
        }
        // Shadow isn't animatable; set it directly (the crossfade masks the change).
        panel.hasShadow = style.wantsShadow
        panel.invalidateShadow()
    }

    // MARK: - Show / hide

    private func handleMenuBarContentUpdated(_ content: MenuBarContent) {
        latestMenuBarContent = content
        updateSecondaryBar()
    }

    private func setSecondaryBarExpanded(_ expanded: Bool) {
        guard isSecondaryBarExpanded != expanded else { return }
        isSecondaryBarExpanded = expanded
        updateSecondaryBar()
        imageUpdater.update()
    }

    private func dashboardAnchorRect(for buttonRect: NSRect) -> NSRect {
        secondaryPanel.isVisible ? secondaryPanel.frame : buttonRect
    }

    private func resetSecondaryBarPosition() {
        UserDefaults.standard.removeObject(forKey: Self.secondaryCustomXKey)
        UserDefaults.standard.removeObject(forKey: Self.secondaryCustomYKey)
        updateSecondaryBar()
    }

    private func updateSecondaryBar() {
        let rawButtonRect = statusItem.button.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        let fallbackRect = NSScreen.main.map {
            NSRect(x: $0.visibleFrame.maxX - 240, y: $0.visibleFrame.maxY, width: 24, height: 24)
        }
        let buttonRectOnScreen = (rawButtonRect?.width ?? 0) > 0 ? rawButtonRect : fallbackRect
        if !latestMenuBarContent.groups.isEmpty && isSecondaryBarExpanded
            && container.layout.menuBarStyle == .text && !container.privacy.concealUsage,
           let buttonRect = buttonRectOnScreen {
            let strip = SecondaryMenuBarStripView(
                groups: latestMenuBarContent.groups,
                isDashboardOpen: panel.isVisible,
                onToggleDashboard: { [weak self] in self?.togglePopover() },
                onCollapse: { [weak self] in self?.setSecondaryBarExpanded(false) },
                onResetPosition: { [weak self] in self?.resetSecondaryBarPosition() }
            )
            let hosting: NSHostingController<SecondaryMenuBarStripView>
            if let existing = secondaryHostingController {
                existing.rootView = strip
                hosting = existing
            } else {
                hosting = NSHostingController(rootView: strip)
                secondaryHostingController = hosting
                secondaryPanel.contentViewController = hosting
            }
            let view = hosting.view
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize
            let size = NSSize(width: max(fitting.width, 80).rounded(), height: max(fitting.height, 28).rounded())
            let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
            var topLeft = PanelGeometry.clampedTopLeft(
                below: buttonRect, width: size.width, visibleFrame: screen?.visibleFrame
            )
            topLeft.y = (buttonRect.minY - 2).rounded(.down)
            if UserDefaults.standard.object(forKey: Self.secondaryCustomXKey) != nil {
                topLeft = NSPoint(
                    x: UserDefaults.standard.double(forKey: Self.secondaryCustomXKey),
                    y: UserDefaults.standard.double(forKey: Self.secondaryCustomYKey)
                )
                let savedFrame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
                if let visibleFrame = (NSScreen.screens.first { $0.frame.intersects(savedFrame) } ?? screen)?.visibleFrame {
                    topLeft.x = min(max(topLeft.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
                    topLeft.y = min(max(topLeft.y, visibleFrame.minY + min(size.height, visibleFrame.height)), visibleFrame.maxY)
                }
            }
            isUpdatingSecondaryFrame = true
            defer { isUpdatingSecondaryFrame = false }
            secondaryPanel.setFrame(
                NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                display: true
            )
            secondaryPanel.orderFrontRegardless()
        } else {
            secondaryPanel.orderOut(nil)
        }
        if panel.isVisible, let buttonRectOnScreen {
            heightController.prepareForOpening(below: dashboardAnchorRect(for: buttonRectOnScreen))
        }
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        let isOptionClick = event?.modifierFlags.contains(.option) == true
        if isContextClick {
            showContextMenu()
        } else if !latestMenuBarContent.groups.isEmpty && container.layout.menuBarStyle == .text && !isOptionClick {
            if panel.isVisible {
                hidePanel()
            } else {
                setSecondaryBarExpanded(!isSecondaryBarExpanded)
            }
        } else {
            togglePopover()
        }
    }

    /// Right-click / control-click on the status item: a native menu mirroring the Settings and Quit
    /// items in the popover footer's Options menu (same titles, symbols, and ⌘ shortcuts). Assigning
    /// `statusItem.menu` for the span of one `performClick` shows the menu anchored under the item and
    /// highlights the button, then clearing it restores the left-click toggle behavior.
    private func showContextMenu() {
        // The context menu is a distinct gesture from the left-click popover: close an open panel
        // first so the menu opens over a clean state (no leftover button highlight, no live
        // outside-click monitors racing the menu's own modal tracking).
        if panel.isVisible { hidePanel() }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open Dashboard", systemSymbol: "rectangle.grid.2x2", keyEquivalent: "") { [weak self] in
            self?.showPopover()
        })
        menu.addItem(ClosureMenuItem(title: "Settings", systemSymbol: "gearshape", keyEquivalent: ",") { [weak self] in
            self?.openSettings()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit OpenUsage", systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Opens the dashboard popover on the Settings screen — Settings is an in-popover screen, not a
    /// separate window. The screen is set before showing the panel so it opens already sized to Settings.
    private func openSettings() {
        container.layout.screen = .settings
        if !panel.isVisible {
            showPanel()
        }
    }

    func togglePopover() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Opens the dashboard panel without toggling it shut when already visible — used when an external
    /// trigger (a tapped pace notification) should surface the popover.
    func showPopover() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            statusItem.button?.highlight(true)
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // Record the display before changing the visibility signal. That signal makes SwiftUI
        // immediately clamp the measured height; without the display anchor the clamp falls back to
        // the fixed opening guess, making large and small displays open at the same height.
        let anchorRect = dashboardAnchorRect(for: buttonRectOnScreen)
        heightController.prepareForOpening(below: anchorRect)
        // Mark the popover on-screen before laying out, so the egg's animation loops mount their
        // `TimelineView` clocks in time for the first displayed frame. Read by the SwiftUI egg via
        // `\.popoverIsVisible`; a closed popover keeps the loops unmounted, so a left-on egg costs no CPU.
        container.transparency.setPopoverShown(true)

        // Lay the content out first so the panel opens at the right size (no first-frame flash).
        hostingController.view.layoutSubtreeIfNeeded()

        // `canBecomeKey` + `.nonactivatingPanel` makes this key without activating the app — no
        // activation race, so the dashboard receives keys on the first try.
        panel.makeKeyAndOrderFront(nil)
        // Becoming key, AppKit auto-focuses the first control in the key-view loop (the first row's
        // Used/Left toggle) when system Keyboard Navigation is on — so the popover would open with a
        // stray focus ring nobody asked for. Drop it; keyboard nav still works (it rides a local key
        // monitor, not first responder), and Tab from here focuses the first control as expected.
        clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
        updateSecondaryBar()
    }

    private func hidePanel() {
        // The popover's SwiftUI tree survives `orderOut`, so a tooltip the cursor was resting on gets
        // no hover-exit and would orphan on screen — clear it here, the one chokepoint every close hits.
        // The Usage Trend hover popover is on the same survives-orderOut footing, so dismiss it too.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        ReducedMotionPopoverController.dismissAll()
        // Same survival problem for keyboard focus: a clicked plain-styled control (a row's Used/Left
        // or reset toggle) stays first responder, so its focus ring would reopen with the popover as a
        // stray blue outline. Drop it on close so every reopen starts unfocused.
        clearStrayFocus()
        // Save while the closing screen is still current; the authoritative SwiftUI close reset runs
        // afterward.
        heightController.saveBeforeClosing()
        // Closing: drop the on-screen flag so the egg's animation loops unmount their `TimelineView`
        // clocks and stop ticking — the whole point of the gate (no CPU while the egg is left on but the
        // popover is hidden). This is the authoritative hide signal, flipped synchronously with `orderOut`.
        container.transparency.setPopoverShown(false)
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
        updateSecondaryBar()
    }

    /// Drops keyboard focus inside the panel so a clicked plain-styled control (a metric row's
    /// Used/Left + reset toggles) doesn't keep the system focus ring lingering as a stray outline:
    /// AppKit leaves the control first responder until focus moves, which a click on empty space or a
    /// close otherwise never does. Skips a live text field / shortcut recorder, whose focus is the
    /// user's intent — mirrors the `NSText` guard `PopoverKeyReader` uses for the same reason.
    private func clearStrayFocus() {
        guard !ShortcutRecorderField.isRecordingActive,
              !(panel.firstResponder is NSText) else { return }
        panel.makeFirstResponder(nil)
    }

}
