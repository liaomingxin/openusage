import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead, followed by optional account and plan badges. Dashboard callers
/// supply a screenshot-copy action, revealed at the trailing edge while the header is hovered. Callers can also
/// supply an optional `warning` — the latest refresh error, rendered as a small amber
/// triangle beside the name whose hover tooltip carries the message (e.g. "Not logged in. Run `codex`
/// to authenticate."). The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
///
/// The title is the provider's family name alone ("Codex", "Claude"). Multi-account cards show a
/// compact account badge and keep the full account label in the title's hover tooltip; the badge
/// truncates before the name or plan under width pressure. Every other place the name stands on
/// its own keeps the full `displayName`.
struct ProviderSectionHeader: View {
    let provider: Provider
    var showsAccountBadge: Bool = true
    var plan: String?
    var warning: String?
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    /// A muted "Outdated" hint shown only when the displayed snapshot has aged past its freshness window
    /// (dashboard only; `nil` in the reorder preview, which never surfaces staleness). Its tooltip carries
    /// the precise age.
    var staleness: StalenessHint?
    /// Dashboard-only screenshot action. The reorder preview omits it, while Customize uses its own
    /// row type and is unaffected by this header.
    var onCopyScreenshot: (() -> Bool)?

    /// Header type and icon track the density setting like the rows do, so Compact shrinks the
    /// whole section anatomy — not just the rows under it.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode
    @State private var isHovered = false

    init(
        provider: Provider,
        showsAccountBadge: Bool = true,
        plan: String? = nil,
        warning: String? = nil,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onCopyScreenshot: (() -> Bool)? = nil
    ) {
        self.provider = provider
        self.showsAccountBadge = showsAccountBadge
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
        self.onCopyScreenshot = onCopyScreenshot
    }

    /// The card title — the family name, never "Codex — extra@example.com".
    var title: String { provider.familyName }
    /// Hovering the title names the account this card tracks. `nil` (no bubble) for a single-account
    /// card. The owner asked for this tooltip explicitly.
    var titleTooltip: String? { provider.accountLabel }

    var body: some View {
        HStack(spacing: 5) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational.
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
            // The smaller account, plan, and staleness text share the name's baseline. The name and
            // plan keep priority while the account badge and stale tag yield under width pressure.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(2)
                    .hoverTooltip(titleTooltip)
                if showsAccountBadge, let accountLabel = provider.accountLabel, !accountLabel.isEmpty {
                    ProviderAccountBadge(label: accountLabel)
                        .layoutPriority(1)
                }
                if let plan {
                    ProviderPlanBadge(plan: plan)
                        .layoutPriority(0.5)
                }
                // Tertiary, below the plan in hierarchy: outdated content, not something the user acts on.
                // Short by design ("Outdated") so it never pushes the plan name onto a second line — the
                // precise age rides in the hover tooltip. Hidden while a refresh is in flight: the spinner
                // already says "working on it".
                if let staleness, !refreshing {
                    Text(staleness.label)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .hoverTooltip(staleness.tooltip)
                }
            }
            if refreshing {
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityLabel("Refreshing")
            } else if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
            Spacer(minLength: 8)
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(provider.displayName) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot
                )
            }
        }
        // No horizontal padding of its own: the caller applies `Theme.sectionHeaderInset`, the one
        // inset every section title on every screen shares.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct ProviderAccountBadge: View {
    let label: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        Text(label)
            .font(.system(size: density.planBadgePointSize, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .frame(maxWidth: 88)
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        // Plain text — no pill/capsule — for a cleaner header. Secondary (not tertiary): the plan
        // name is information the user reads, and tertiary on glass is reserved for inactive
        // content. The smaller point size alone keeps it subordinate to metric values.
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}
