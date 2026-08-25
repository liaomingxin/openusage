/// A provider and its placed (visible) widgets, split into Always Visible rows and On Demand rows
/// behind the dashboard's caret. Drives the grouped dashboard list.
struct ProviderGroup: Identifiable {
    let provider: Provider
    let alwaysShownWidgets: [PlacedWidget]
    let expandedWidgets: [PlacedWidget]
    var id: String { provider.id }

    /// Every visible widget in display order (always-shown first, then expanded). Used where the split
    /// doesn't matter — reorder id lists and the lifted drag preview.
    var widgets: [PlacedWidget] { alwaysShownWidgets + expandedWidgets }
    var hasExpandedMetrics: Bool { !expandedWidgets.isEmpty }
}

/// One dashboard grid row: one full-width card, or two cards sitting side by side.
struct DashboardCardRow: Identifiable {
    let groups: [ProviderGroup]
    var id: String { groups.map(\.id).joined(separator: "|") }

    /// Walk `groups` left-to-right while keeping a consecutive multi-account family together. Ordinary
    /// single-card providers still pack two per row; a family run owns dedicated rows so two Codex
    /// accounts sit side by side instead of straddling unrelated cards. A leftover card is full width.
    static func rows(from groups: [ProviderGroup], columns: Int = 2) -> [DashboardCardRow] {
        guard columns > 0, !groups.isEmpty else { return [] }

        var rows: [DashboardCardRow] = []
        var pendingSingletons: [ProviderGroup] = []

        func appendChunks(_ chunkGroups: [ProviderGroup]) {
            for start in stride(from: 0, to: chunkGroups.count, by: columns) {
                rows.append(DashboardCardRow(
                    groups: Array(chunkGroups[start..<min(start + columns, chunkGroups.count)])
                ))
            }
        }

        func flushSingletons() {
            appendChunks(pendingSingletons)
            pendingSingletons.removeAll(keepingCapacity: true)
        }

        var start = 0
        while start < groups.count {
            let family = ProviderAccountID.family(of: groups[start].provider.id)
            var end = start + 1
            while end < groups.count,
                  ProviderAccountID.family(of: groups[end].provider.id) == family {
                end += 1
            }

            let familyRun = Array(groups[start..<end])
            if familyRun.count == 1 {
                pendingSingletons.append(familyRun[0])
                if pendingSingletons.count == columns { flushSingletons() }
            } else {
                flushSingletons()
                appendChunks(familyRun)
            }
            start = end
        }

        flushSingletons()
        return rows
    }
}

/// A provider and every metric it supports, in the provider's custom order, split between Always
/// Visible and On Demand. Drives the Customize screen and the menu-bar pin grouping.
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let alwaysShownMetrics: [WidgetDescriptor]
    let expandedMetrics: [WidgetDescriptor]
    var id: String { provider.id }

    init(provider: Provider, alwaysShownMetrics: [WidgetDescriptor], expandedMetrics: [WidgetDescriptor]) {
        self.provider = provider
        self.alwaysShownMetrics = alwaysShownMetrics
        self.expandedMetrics = expandedMetrics
    }

    /// Convenience for callers that don't partition (e.g. tests): everything is always-shown.
    init(provider: Provider, metrics: [WidgetDescriptor]) {
        self.init(provider: provider, alwaysShownMetrics: metrics, expandedMetrics: [])
    }

    /// Every supported metric in custom order (always-shown first, then expanded).
    var metrics: [WidgetDescriptor] { alwaysShownMetrics + expandedMetrics }
}

/// One row in the Customize provider list (L1): the provider plus the derived bits the row renders —
/// whether it's enabled (the master toggle + Active/Inactive label), how many metrics it supports
/// (the badge), and how many are pinned. Drives `CustomizeProviderListView`. Unlike `ProviderMetrics`,
/// this includes disabled providers so they stay visible in the list.
struct ProviderRow: Identifiable {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    var id: String { provider.id }
}

/// Tone for the transient in-Customize pill (`LayoutStore.customizationNotice`): green success or
/// orange denial.
enum CustomizationNoticeTone {
    case positive
    case notice
}

/// The message + tone carried by the Customize pill's `TransientNotice`, so its two fields clear together.
struct CustomizationNoticeContent {
    var message: String
    var tone: CustomizationNoticeTone
}
