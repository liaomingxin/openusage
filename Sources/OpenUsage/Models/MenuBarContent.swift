import Foundation

/// Resolved, ordered data for the menu-bar strip, built from the pinned metrics and their live
/// values. The Text style splits `groups` across the primary and secondary rows (one segment per
/// pinned provider, each with its 1–2 pinned metrics); `bars` drives the Bars style (the first four
/// bounded metrics — any with a fill, not just percentages — in order). `isEmpty` means render the
/// plain app icon.
struct MenuBarContent: Equatable {
    static let maxPrimaryGroups = 4

    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        let label: String       // metric label, e.g. "Session" (shown when a provider has two metrics)
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let fraction: Double     // 0...1 fill, meaningful for bounded metrics (drives the bars)
        let isBounded: Bool      // has a limit → has a fill, so it can render as a bar
        let hasData: Bool
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
    }

    /// Provider groups for the Text style, in Customize order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders.
    let groups: [Group]
    /// Bounded metrics (those with a fill) for the Bars style, flattened in order and capped to four.
    let bars: [Metric]

    var primaryGroups: [Group] { Array(groups.prefix(Self.maxPrimaryGroups)) }
    var secondaryGroups: [Group] { Array(groups.dropFirst(Self.maxPrimaryGroups)) }
    var hasSecondaryRow: Bool { !secondaryGroups.isEmpty }
    var primaryContent: MenuBarContent { MenuBarContent(groups: primaryGroups, bars: bars) }
    var secondaryContent: MenuBarContent { MenuBarContent(groups: secondaryGroups, bars: []) }

    /// Nothing is pinned, every pinned provider is disabled, or no pinned metric has data yet — the
    /// menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// Max bars the compact style renders (matches the original OpenUsage tray).
    static let maxBars = 4

    /// Resolve pinned provider groups into menu-bar content. `groups` is `LayoutStore.pinnedGroups`
    /// (already ordered, disabled providers excluded); `data` resolves each descriptor to its live
    /// `WidgetData` (i.e. `WidgetDataStore.data(for:)`), so the values follow the global meter style
    /// just like the dashboard tiles.
    ///
    /// The strip is dynamic: a pinned metric without data is dropped (one of two pins renders alone at
    /// full size), and a provider with no data-carrying pins contributes no icon at all. Pins are
    /// membership; the strip shows whatever subset is real right now.
    /// When family coalescing is enabled, each family keeps its most urgent, then active and
    /// constrained account. Family order and exact-priority ties follow the original pin order.
    static func build(
        groups: [ProviderMetrics],
        coalesceByFamily: Bool = false,
        data: (WidgetDescriptor) -> WidgetData
    ) -> MenuBarContent {
        var resolvedGroups: [MenuBarContent.Group] = []
        var familyRepresentatives: [String: (index: Int, priority: RepresentativePriority)] = [:]
        for group in groups {
            var metrics: [MenuBarContent.Metric] = []
            var priority = RepresentativePriority()
            for descriptor in group.metrics {
                let value = data(descriptor)
                guard value.hasData else { continue }
                metrics.append(resolve(descriptor, value))
                if coalesceByFamily { priority.include(value) }
            }
            guard !metrics.isEmpty else { continue }
            let resolvedGroup = MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: coalesceByFamily ? group.provider.familyName : group.provider.displayName,
                icon: group.provider.icon,
                metrics: metrics
            )
            guard coalesceByFamily else {
                resolvedGroups.append(resolvedGroup)
                continue
            }
            let family = ProviderAccountID.family(of: group.provider.id)
            if let representative = familyRepresentatives[family] {
                guard priority.outranks(representative.priority) else { continue }
                resolvedGroups[representative.index] = resolvedGroup
                familyRepresentatives[family] = (representative.index, priority)
            } else {
                familyRepresentatives[family] = (resolvedGroups.count, priority)
                resolvedGroups.append(resolvedGroup)
            }
        }
        // Bars show any *bounded* metric (it has a fill), not just percentages. Unbounded values (raw
        // spend/credits, no limit) have no fill and are dropped.
        let bars = resolvedGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(groups: resolvedGroups, bars: Array(bars))
    }

    private struct RepresentativePriority {
        var severityRank = 0
        var isActive = false
        var lowestRemainingFraction = 1.0

        mutating func include(_ data: WidgetData) {
            isActive = isActive || data.used > 0.0001
            guard data.isBounded else { return }
            let rank: Int
            switch data.meterState().severity {
            case .critical: rank = 3
            case .warning: rank = 2
            case .normal: rank = 1
            case nil: rank = 0
            }
            severityRank = max(severityRank, rank)
            lowestRemainingFraction = min(lowestRemainingFraction, data.remainingFraction)
        }

        func outranks(_ other: Self) -> Bool {
            if severityRank != other.severityRank { return severityRank > other.severityRank }
            if isActive != other.isActive { return isActive }
            return lowestRemainingFraction < other.lowestRemainingFraction
        }
    }

    private static func resolve(_ descriptor: WidgetDescriptor, _ data: WidgetData) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: descriptor.id,
            label: trayLabel(descriptor.metricLabel),
            value: data.menuBarValue,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.hasData
        )
    }

    /// Tray-only label shortening (the dashboard keeps the full names): the long time-window metrics
    /// collapse to a single letter so a two-metric stack stays narrow. Unknown labels pass through.
    private static func trayLabel(_ metricLabel: String) -> String {
        switch metricLabel.lowercased() {
        case "today": return "T"
        case "yesterday": return "Y"
        case "last 30 days": return "M"
        default: return metricLabel
        }
    }
}
