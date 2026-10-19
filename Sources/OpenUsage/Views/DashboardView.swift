import SwiftUI

/// Popover pages share fixed chrome, native scroll-edge fades, and content-driven panel height.
/// Each page owns its chrome so it travels with the page during horizontal screen switches.
/// `animatedHeight` drives AppKit on SwiftUI's animation clock, keeping the panel's morph and
/// page slide on one spring. Scrolling takes over only when content exceeds the display cap.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverTransparencyStore.self) private var transparency
    @Environment(UpdaterController.self) private var updater
    @Environment(\.reduceAnimations) private var reduceAnimations
    @AppStorage(DashboardColumnsSetting.key) private var columnsSetting = DashboardColumnsSetting.two
    @State private var reorderLift: ReorderLift?
    /// The panel height SwiftUI drives — the single animation clock. `PanelHeightModifier` follows it
    /// frame-by-frame onto the AppKit panel, so the window resize rides the same spring as the screen
    /// slide (no second AppKit animation to fight). 0 means "not established yet": the panel keeps the
    /// size the controller opened it at until the first measurement lands, then we snap un-animated.
    @State private var animatedHeight: CGFloat = 0
    /// Whether `animatedHeight` has been seeded for this open. Until then the first measurement (or a
    /// reopen) establishes it without animation; afterwards, changes spring.
    @State private var didEstablishHeight = false
    /// Popover auto-fit height computation: per-screen measured pieces summed into each screen's clamped
    /// morph target (`heightCoordinator.measuredIdeal` / `.target(for:)`). Written from the geometry
    /// actions below. The animation itself — `animatedHeight`, the slide, the `withAnimation` spring —
    /// stays in this view; the coordinator holds only the deterministic measurement.
    @State private var heightCoordinator = PanelHeightCoordinator(topBarHeight: Self.topBarHeight)
    /// Horizontal screen-switch slide: 0 shows the outgoing screen, 1 the incoming one. Drives the
    /// page offset so the screens slide between modes on one spring.
    @State private var slideProgress: CGFloat = 1
    /// The `layout.screenSlideID` whose slide has begun animating. Until it catches up to the store's
    /// id, a freshly-started transition pins to the outgoing screen so the first frame never flashes
    /// the destination.
    @State private var animatedSlideID = 0
    /// Reset to the top whenever the popover closes, so it never reopens mid-scroll.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Settings is expensive to mount because each menu picker creates an `NSPopUpButton`. Keep its
    /// view tree alive after the first visit so later screen switches don't rebuild those controls.
    @State private var hasVisitedSettings = false
    /// Drives the macOS-native confirmation sheet for the Customize "reset all" button. The alert
    /// attaches to this panel as a sheet (see `StatusItemController`'s attached-sheet guard), so a
    /// click on its buttons can't be misread as an outside click that dismisses the popover.
    @State private var isPresentingResetAllConfirm = false
    /// Shared horizontal inset for dashboard content and fixed chrome.
    private static let outerPadding: CGFloat = Theme.screenInset
    /// Breathing room between the bottom of the scrolling content and the pinned footer. Kept small
    /// because the native scroll edge effect — not whitespace — provides the visual separation.
    private static let contentBottomGap: CGFloat = 12
    /// Footer content starts at the same standard padding as the provider containers.
    private static let footerHorizontalPadding: CGFloat = outerPadding
    private static let reorderSpace = "popoverReorderSpace"
    /// Fixed height of the Customize / Settings back nav bar — the bar pins itself to exactly this height.
    private static let topBarHeight: CGFloat = 44

    var body: some View {
        framedBody
            // Fill the panel. The panel auto-fits its content (the window height is driven to each
            // screen's measured ideal via `drivesPanelHeight`), so at rest the window is exactly the
            // content's height and this fill is a no-op; when content exceeds the screen cap the window
            // clamps and the scroll views inside take the overflow.
            .frame(maxHeight: .infinity, alignment: .top)
            // Paint the page surface behind all content (and the footer). Opaque by default so the
            // popover reads as one solid panel; under Increase Transparency / the egg it clears so the
            // behind-window backdrop (or party gradient) shows through. Outermost so the footer, header,
            // and scroll content all sit on it; separation from the footer comes from the native soft
            // scroll-edge fade (not a distinct bar).
            .background(PopoverSurface())
            // Drive the host panel's height on SwiftUI's clock. At the body root, OUTSIDE `modeBody`'s
            // `.animation(nil, value: layout.screenSlideID)`, so the height rides the active spring (the
            // slide's, during a switch) instead of being snapped.
            .drivesPanelHeight(animatedHeight)
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .background(
                // Esc backs out of Customize / Settings first; only from the dashboard does it close
                // the popover. Return opens Customize from the dashboard (the same affordance the
                // footer's Options ▸ Customize menu item carries) and returns to the
                // dashboard from Customize or Settings — matching Esc and the back navigation,
                // never jumping Settings → Customize. Always consumed, so a bare Return can't fall
                // through and dismiss the popover.
                PopoverKeyReader(
                    onEscape: {
                        // From a provider's L2 detail, back out to the L1 list first; only from L1 /
                        // Settings drop to the dashboard. Pressing Esc again from L1 closes the popover.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        guard layout.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
                        return true
                    },
                    onReturn: {
                        // From a provider's L2 detail, back out to the L1 list first — matching Esc —
                        // so Return steps L2 → L1 → dashboard instead of jumping L2 → dashboard.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        let target: PopoverScreen = layout.screen == .dashboard ? .customize : .dashboard
                        withAnimation(Motion.modeSwitch) { layout.screen = target }
                        return true
                    },
                    // ⌘, toggles Settings, on this always-on monitor so it fires from every screen —
                    // including Settings, whose footer has no Settings action. Handling it here (and
                    // consuming it) also lets the Options menu's Settings item carry ⌘, as a label
                    // without a second SwiftUI registration fighting it.
                    onSettings: {
                        withAnimation(Motion.modeSwitch) {
                            layout.screen = layout.screen == .settings ? .dashboard : .settings
                        }
                        return true
                    },
                    // ⌘Z walks back the last customization step (remove/add, reorder, pin/unpin, caret
                    // move) — app-wide, since Hide and Pin happen via the dashboard's context menus too,
                    // not only in Customize. Always consumed here: by the time the monitor calls this it
                    // has already confirmed the panel owns the keystroke and no text field is editing
                    // (those keep their own ⌘Z), so returning false would only let AppKit beep on an empty
                    // undo. With nothing to undo we swallow it silently instead.
                    onUndo: {
                        guard layout.canUndo else { return true }
                        withAnimation(Motion.spring) { _ = layout.undo() }
                        return true
                    }
                )
            )
    }

    private var isCustomizeListVisible: Bool {
        layout.screen == .customize && layout.customizeProviderID == nil
    }

    private var observedBody: some View {
        modeBody
            .frame(width: columnsSetting.panelWidth)
            .onChange(of: columnsSetting) { _, _ in
                MenuBarPopover.applyHeight?(animatedHeight)
            }
            .onChange(of: transparency.popoverShown) { _, shown in
                if shown {
                    if let target = heightCoordinator.target(for: layout.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                } else {
                    resetTransientState()
                }
            }
            .onChange(of: layout.screen) { _, screen in
                reorderLift = nil
                layout.cancelDrag()
                if screen == .settings { hasVisitedSettings = true }
            }
            .onChange(of: isCustomizeListVisible) { _, isL1Visible in
                if !isL1Visible { isPresentingResetAllConfirm = false }
            }
    }

    private var framedBody: some View {
        observedBody
            .onChange(of: layout.screenSlideID) { _, id in
                handleScreenSlideChange(id)
            }
            .onChange(of: heightCoordinator.measuredIdeal[layout.screen]) { _, _ in
                guard let target = heightCoordinator.target(for: layout.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !isSliding, abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
            .background(TooMuchTransparencyKeyReader { transparency.toggleSecretCode() })
            .environment(\.popoverSurfaceTreatment, transparency.surfaceTreatment)
            .tooMuchTransparency(transparency.effectiveStyle)
            .environment(\.popoverIsVisible, transparency.popoverShown)
    }

    private func handleScreenSlideChange(_ id: Int) {
        guard id != 0 else { return }
        if reduceAnimations {
            animatedSlideID = id
            slideProgress = 1
            if let target = heightCoordinator.target(for: layout.screen) {
                didEstablishHeight = true
                animatedHeight = target
            }
            return
        }
        slideProgress = 0
        animatedSlideID = id
        let destination = layout.screen
        Task { @MainActor in
            let coTarget: CGFloat? = heightCoordinator.target(for: destination)
                ?? (animatedHeight > 0 ? animatedHeight : nil)
            if coTarget != nil { didEstablishHeight = true }
            withAnimation(Motion.spring, completionCriteria: .logicallyComplete) {
                slideProgress = 1
                if let coTarget { animatedHeight = coTarget }
            } completion: {
                guard let target = heightCoordinator.target(for: layout.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
        }
    }

    private func resetTransientState() {
        // Backstop for any popover-close path the status-item controller's hide doesn't cover: clear a
        // tooltip the cursor was resting on, since the closed popover fires no hover-exit. The Usage
        // Trend hover popover rides the same backstop.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        if layout.screen != .dashboard { layout.screen = .dashboard }
        reorderLift = nil
        layout.cancelDrag()
        // A "Copied to clipboard" pill mid-countdown would otherwise reappear stale on the next open,
        // since the layout store survives the popover and only the timer clears it.
        layout.clearShareConfirmation()
        layout.clearCustomizationNotice()
        // Dismiss a pending Reset All confirmation if the popover closes mid-alert — the SwiftUI tree
        // survives `orderOut`, so without this the sheet would reappear stale on the next open.
        isPresentingResetAllConfirm = false
        // Drop the driven height so the next open re-establishes it (un-animated) from the reopened
        // screen's measurement instead of springing from this session's last value. Until then the
        // 0 sentinel keeps `PanelHeightModifier` from pushing, so the controller's opening guess stands.
        animatedHeight = 0
        didEstablishHeight = false
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// At rest only the current page is mounted; during a switch both pages slide by a pure offset.
    /// Avoid opacity transitions: they flatten translucent glass into an opaque near-white flash.
    /// Screen-keyed identities preserve the incoming page's scroll position after a slide.
    /// Settings stays in a sibling overlay after its first visit so its native controls survive;
    /// an empty pager slot preserves slide geometry. Only `slideProgress` animates the offset.
    private var modeBody: some View {
        let pages = slidePages
        let pagerOffset = slideOffset(pages)
        let keepSettings = isSettingsKeptAlive
        return ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(pages, id: \.self) { screen in
                    pagerPage(screen, settingsKeptAlive: keepSettings)
                        .frame(width: columnsSetting.panelWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: columnsSetting.panelWidth, alignment: .leading)
            .offset(x: pagerOffset)

            if keepSettings {
                screenView(.settings, includeChrome: Self.settingsChromeIsVisible(pages: pages))
                    .frame(width: columnsSetting.panelWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(x: Self.settingsOverlayOffset(
                        pages: pages,
                        slideOffset: pagerOffset,
                        pageWidth: columnsSetting.panelWidth
                    ))
                    .allowsHitTesting(layout.screen == .settings && !isSliding)
                    .accessibilityHidden(layout.screen != .settings)
            }
        }
        .frame(width: columnsSetting.panelWidth, alignment: .leading)
        .animation(nil, value: layout.screenSlideID)
    }

    /// Include the first render targeting Settings so it mounts directly in its permanent overlay,
    /// never first inside the pager and then again when the visit flag catches up.
    private var isSettingsKeptAlive: Bool {
        hasVisitedSettings || layout.screen == .settings
    }

    /// Preserve Settings' pager slot without mounting a duplicate of its kept-alive view tree.
    @ViewBuilder
    private func pagerPage(_ screen: PopoverScreen, settingsKeptAlive: Bool) -> some View {
        if screen == .settings && settingsKeptAlive {
            Color.clear
                .allowsHitTesting(false)
        } else {
            screenView(screen)
        }
    }

    /// Follow the Settings pager slot during its slide, or park safely beyond a Dashboard ↔ Customize
    /// transition when Settings isn't one of the visible pages.
    static func settingsOverlayOffset(
        pages: [PopoverScreen],
        slideOffset: CGFloat,
        pageWidth: CGFloat
    ) -> CGFloat {
        if let index = pages.firstIndex(of: .settings) {
            return CGFloat(index) * pageWidth + slideOffset
        }
        // Beyond the rightmost page (Settings sits at rank 3 in the four-screen slide order).
        return pageWidth * 3
    }

    /// Parked Settings must not keep a second footer, keyboard shortcuts, or alert presenter alive.
    /// Restore its chrome whenever Settings is the current page or participates in a transition.
    static func settingsChromeIsVisible(pages: [PopoverScreen]) -> Bool {
        pages.contains(.settings)
    }

    /// True from the moment `layout.screen` changes until the slide reaches the incoming screen.
    private var isSliding: Bool {
        Self.screenTransitionIsActive(
            reduceAnimations: reduceAnimations,
            screenSlideID: layout.screenSlideID,
            animatedSlideID: animatedSlideID,
            slideProgress: slideProgress
        )
    }

    /// Reduced motion never mounts the outgoing + incoming pager together: destination chrome and
    /// content must replace the old screen atomically instead of exposing the pager's setup frame.
    static func screenTransitionIsActive(
        reduceAnimations: Bool,
        screenSlideID: Int,
        animatedSlideID: Int,
        slideProgress: CGFloat
    ) -> Bool {
        !reduceAnimations
            && screenSlideID != 0
            && (screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// One page at rest (the current screen); the two involved screens in left-to-right rank order
    /// while a switch animates.
    private var slidePages: [PopoverScreen] {
        guard isSliding else { return [layout.screen] }
        let from = layout.screenSlideFrom
        let to = layout.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    /// Horizontal offset that places the outgoing screen at `slideProgress == 0` and the incoming one
    /// at `1`. Pinned to the outgoing screen until this transition's animation has actually started, so
    /// the first frame after a switch shows the screen being left — never a flash of the destination.
    private func slideOffset(_ pages: [PopoverScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let fromOffset = -CGFloat(pages.firstIndex(of: layout.screenSlideFrom) ?? 0) * columnsSetting.panelWidth
        let toOffset = -CGFloat(pages.firstIndex(of: layout.screen) ?? 0) * columnsSetting.panelWidth
        let progress = animatedSlideID == layout.screenSlideID ? slideProgress : 0
        return fromOffset + progress * (toOffset - fromOffset)
    }

    /// Builds one screen: its scroll body wrapped in its own chrome. The chrome (top bar + footer) is
    /// keyed off the per-page `screen`, not `layout.screen`, so a page always draws the bar its content
    /// belongs to: the dashboard never grows a nav bar on its way out, and an incoming screen's title
    /// arrives with it rather than a slide ahead of it. The soft scroll-edge styles and the pinned bars
    /// attach to each page's scroll view (`PopoverScrollView`), the documented place for them. Identity
    /// stays stable across the slide via the `ForEach` key in `modeBody`.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen, includeChrome: Bool = true) -> some View {
        scrollBody(for: screen)
            // Auto-fit: the scroll content publishes its intrinsic height (invariant to the viewport),
            // which we sum with the chrome into this screen's ideal window height. Keyed by the per-page
            // `screen`, so during a slide each mounted page measures its own content.
            .onPreferenceChange(ScrollContentHeightKey.self) { height in
                heightCoordinator.setScrollContent(height, for: screen)
            }
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) {
                if includeChrome {
                    PopoverTopBar(
                        layout: layout,
                        screen: screen,
                        height: Self.topBarHeight,
                        horizontalPadding: Self.footerHorizontalPadding,
                        onResetAll: {
                            layout.resetToDefault()
                            container.reseedEnabledProviders()
                        },
                        isPresentingResetAllConfirm: $isPresentingResetAllConfirm
                    )
                }
            }
            .pinnedFooter(spacing: 0) {
                if includeChrome {
                    PopoverFooter(
                        screen: screen,
                        layout: layout,
                        dataStore: dataStore,
                        horizontalPadding: Self.footerHorizontalPadding
                    ) { screen, height in
                        heightCoordinator.setFooter(height, for: screen)
                    }
                }
            }
    }

    /// The scrolling content for a screen, without chrome — this is the part that slides during a
    /// switch (its `screen` is the per-page one, so each mounted page shows its own content).
    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                container: container,
                layout: layout,
                updater: updater,
                reorderSpaceName: Self.reorderSpace,
                horizontalPadding: Self.outerPadding,
                bottomGap: Self.contentBottomGap,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .customize:
            CustomizeView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .agentUsage:
            AgentUsageScreen()
        case .settings:
            SettingsScreen()
        }
    }

}

/// The popover's opaque backdrop tray, painted behind all content so the popover reads as one solid
/// panel — the data region never shows the desktop through it. Matches the AppKit panel backdrop
/// (`PopoverBackdropView`'s `NSBox`): SwiftUI uses `Theme.traySurface` here while AppKit uses the
/// matching `Theme.trayNSColor`. The footer draws its own frosted glass bar on top of this (in-window),
/// so glass stays chrome over solid content. Never hit-tests, so it can't steal clicks from the content
/// above it.
private struct PopoverSurface: View {
    @Environment(\.popoverSurfaceTreatment) private var treatment

    var body: some View {
        Group {
            switch treatment {
            case .opaque:
                Theme.traySurface
            case .translucent:
                // Clear so what's behind the page shows through: the behind-window vibrancy backdrop —
                // the blurred desktop for increased/drunk, and the same desktop tinted by the party
                // gradient for party mode.
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }
}
