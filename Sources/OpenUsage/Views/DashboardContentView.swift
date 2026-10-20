import SwiftUI

/// The dashboard-only scrolling content. Screen switching, panel sizing, fixed bars, keyboard handling,
/// and close/reset behavior stay with `DashboardView`.
struct DashboardContentView: View {
    let container: AppContainer
    let layout: LayoutStore
    let updater: UpdaterController
    let reorderSpaceName: String
    let horizontalPadding: CGFloat
    let bottomGap: CGFloat

    @Binding var reorderLift: ReorderLift?
    @Binding var scrollPosition: ScrollPosition

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    @AppStorage(DashboardFilterMode.key) private var filterMode = DashboardFilterMode.all
    @AppStorage(DashboardGroupingSetting.groupByFamilyKey) private var groupByFamily = true

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A pending update found by a scheduled Sparkle check tops everything — it's the
                // reminder the buried Sparkle window can't deliver for a dockless app.
                if let updateVersion = updater.availableUpdateVersion {
                    UpdateBannerCard(version: updateVersion)
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                // The one-time first-run hint sits above the provider sections (and above the
                // empty-state line, which a fresh install can hit while nothing has data yet).
                if container.onboarding.isCustomizeHintPending {
                    CustomizeHintCard()
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                if !layout.displayGroups.isEmpty {
                    dashboardControlBar
                        .padding(.bottom, density.sectionSpacing)
                }
                widgetContent
            }
            .animation(Motion.spring, value: container.onboarding.isCustomizeHintPending)
            .animation(Motion.spring, value: updater.availableUpdateVersion)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, density.contentTopPadding)
            .padding(.bottom, bottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
    }

    private var hasMultiAccountFamily: Bool {
        var families: Set<String> = []
        for group in layout.displayGroups {
            if !families.insert(ProviderAccountID.family(of: group.provider.id)).inserted { return true }
        }
        return false
    }

    private var dashboardControlBar: some View {
        HStack(spacing: 0) {
            CapsuleSegmentedPicker(
                options: DashboardFilterMode.allCases,
                selection: $filterMode,
                label: \.label
            )
            Spacer(minLength: 8)
            if hasMultiAccountFamily, filterMode != .expiries, filterMode != .resets {
                Button {
                    withAnimation(Motion.spring) { groupByFamily.toggle() }
                } label: {
                    Label(
                        groupByFamily ? "Grouped" : "Separate",
                        systemImage: groupByFamily ? "rectangle.stack.fill" : "square.grid.2x2"
                    )
                    .font(.system(size: density.captionPointSize, weight: .medium))
                    .foregroundStyle(groupByFamily ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group accounts by provider family")
                .accessibilityValue(groupByFamily ? "Grouped" : "Separate")
            }
        }
    }

    @ViewBuilder
    private var widgetContent: some View {
        if layout.displayGroups.isEmpty {
            EmptyDashboardView {
                withAnimation(Motion.modeSwitch) { layout.screen = .customize }
            }
        } else if filterMode == .resets {
            QuotaResetsCard()
        } else if filterMode == .expiries {
            SubscriptionExpiryCard()
        } else {
            // Spend remains reachable before fresh metrics arrive, except in the alerts-only lens.
            if showTotalSpend, layout.hasSpendCapableProvider, filterMode != .alerts {
                TotalSpendCard()
                    .padding(.bottom, density.sectionSpacing)
            }
            WidgetGroupedListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift
            )
        }
    }
}
