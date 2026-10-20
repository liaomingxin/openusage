import SwiftUI

enum QuotaResetWindowFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "all"
    case weeklyAndLonger = "weekly"
    case shortSession = "session"
    case hasRemaining = "remaining"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .weeklyAndLonger: "Weekly+"
        case .shortSession: "5h / Daily"
        case .hasRemaining: "Has Quota"
        }
    }

    func matches(_ item: QuotaResetItem) -> Bool {
        switch self {
        case .all: true
        case .weeklyAndLonger: item.data.periodDurationMs.map { $0 > MetricPeriod.dayMs } ?? true
        case .shortSession: item.data.periodDurationMs.map { $0 <= MetricPeriod.dayMs } ?? false
        case .hasRemaining: item.remainingPercent > 1
        }
    }
}

/// A resolved quota window at a single timeline tick, independent of the stores and display mode.
struct QuotaResetItem: Identifiable, Equatable, Sendable {
    let id: String
    let provider: Provider
    let plan: String?
    let metricTitle: String
    let data: WidgetData
    let resetsAt: Date
    let now: Date

    var timeRemaining: TimeInterval { resetsAt.timeIntervalSince(now) }

    var remainingPercent: Double {
        if data.kind == .percent { return max(0, 100 - data.used) }
        guard let limit = data.limit, limit > 0 else { return 0 }
        return max(0, (limit - data.used) / limit * 100)
    }

    var isExhausted: Bool { remainingPercent <= 0.5 }
}

struct QuotaResetBucket: Identifiable, Equatable, Sendable {
    enum Horizon: Int, CaseIterable, Sendable {
        case within24Hours
        case oneToThreeDays
        case later

        var title: String {
            switch self {
            case .within24Hours: "Resetting Within 24h"
            case .oneToThreeDays: "Resetting in 1–3 Days"
            case .later: "Later (> 3 Days)"
            }
        }

        static func containing(_ seconds: TimeInterval) -> Self {
            if seconds <= 24 * 3600 { return .within24Hours }
            if seconds <= 3 * 24 * 3600 { return .oneToThreeDays }
            return .later
        }
    }

    let id: Horizon
    let items: [QuotaResetItem]
    var title: String { id.title }
}

enum QuotaResetsBuilder {
    @MainActor
    static func items(
        groups: [ProviderGroup],
        layout: LayoutStore,
        dataStore: WidgetDataStore,
        filter: QuotaResetWindowFilter,
        now: Date
    ) -> [QuotaResetItem] {
        var result: [QuotaResetItem] = []
        let cutoff = now.addingTimeInterval(-60)
        for group in groups where layout.isProviderEnabled(group.provider.id) {
            let enabledIDs = Set(group.widgets.map(\.descriptorID))
            let plan = dataStore.plan(for: group.provider.id)
            for descriptor in layout.orderedSupportedMetrics(for: group.provider.id)
                where enabledIDs.contains(descriptor.id) {
                let data = dataStore.data(for: descriptor)
                guard data.isBounded, data.hasData, let resetsAt = data.resetsAt,
                      resetsAt > cutoff else { continue }
                let item = QuotaResetItem(
                    id: descriptor.id, provider: group.provider, plan: plan,
                    metricTitle: descriptor.title, data: data, resetsAt: resetsAt, now: now
                )
                if filter.matches(item) { result.append(item) }
            }
        }
        return sorted(result)
    }

    static func sorted(_ items: [QuotaResetItem]) -> [QuotaResetItem] {
        var result = items.sorted {
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            return $0.id < $1.id
        }
        // A pairwise "within 60s" comparator is non-transitive. Anchor each near-simultaneous
        // cohort to its earliest reset instead, then prioritize quota to burn within that cohort.
        var start = 0
        while start < result.count {
            let earliestReset = result[start].resetsAt
            var end = start + 1
            while end < result.count, result[end].resetsAt.timeIntervalSince(earliestReset) < 60 {
                end += 1
            }
            result[start..<end].sort {
                if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent > $1.remainingPercent }
                return $0.id < $1.id
            }
            start = end
        }
        return result
    }

    static func buckets(items: [QuotaResetItem]) -> [QuotaResetBucket] {
        let grouped = Dictionary(grouping: items) { QuotaResetBucket.Horizon.containing($0.timeRemaining) }
        return QuotaResetBucket.Horizon.allCases.compactMap { horizon in
            guard let items = grouped[horizon], !items.isEmpty else { return nil }
            return QuotaResetBucket(id: horizon, items: items)
        }
    }
}

struct QuotaResetsCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage("quotaResets.windowFilter") private var windowFilter = QuotaResetWindowFilter.all

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let items = QuotaResetsBuilder.items(
                groups: layout.displayGroups, layout: layout, dataStore: dataStore,
                filter: windowFilter, now: context.date
            )
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                header(count: items.count)
                if items.isEmpty {
                    EmptyStateView(title: windowFilter == .all ? "No upcoming quota resets" : "No matching quota windows")
                        .frame(maxWidth: .infinity)
                        .cardSurface()
                } else {
                    ForEach(QuotaResetsBuilder.buckets(items: items)) { bucket in
                        section(bucket, now: context.date)
                    }
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                title(count: count)
                Spacer(minLength: 8)
                windowPicker
            }
            VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
                title(count: count)
                windowPicker
            }
        }
        .padding(.horizontal, Theme.sectionHeaderInset)
        .padding(.vertical, 2)
    }

    private func title(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("Upcoming Resets")
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .fixedSize()
            Text("\(count)")
                .font(.system(size: density.planBadgePointSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(count) quota windows")
        }
    }

    private var windowPicker: some View {
        CapsuleSegmentedPicker(
            options: QuotaResetWindowFilter.allCases, selection: $windowFilter, label: \.label
        )
        .fixedSize()
        .accessibilityLabel("Quota reset window filter")
    }

    private func section(_ bucket: QuotaResetBucket, now: Date) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 6) {
                Text(bucket.title)
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                Text("\(bucket.items.count)")
                    .font(.system(size: density.captionPointSize))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.sectionHeaderInset)
            VStack(spacing: 0) {
                ForEach(Array(bucket.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { CardHairline() }
                    QuotaResetRow(
                        item: item, now: now, density: density,
                        onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                        onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() }
                    )
                }
            }
            .cardSurface()
        }
    }
}

private struct QuotaResetRow: View {
    let item: QuotaResetItem
    let now: Date
    let density: DensitySetting
    let onToggleMeterStyle: () -> Void
    let onToggleResetDisplay: () -> Void

    private var isUrgent: Bool { item.timeRemaining <= 6 * 3600 && !item.isExhausted }

    var body: some View {
        VStack(spacing: density.rowInnerSpacing) {
            HStack(spacing: 5) {
                ProviderIcon(source: item.provider.icon, inset: 0.04)
                    .frame(width: 16, height: 16)
                Text(item.provider.familyName)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .lineLimit(1)
                if let label = item.provider.accountLabel, !label.isEmpty {
                    ProviderAccountBadge(label: label)
                        .hoverTooltip(item.provider.displayName)
                }
                Text(item.metricTitle)
                    .font(.system(size: density.planBadgePointSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .lineLimit(1)
                    .layoutPriority(1)
                    .hoverTooltip(item.metricTitle)
                if let plan = item.plan {
                    ProviderPlanBadge(plan: plan)
                }
                Spacer(minLength: 6)
                Button(action: onToggleMeterStyle) {
                    Text(item.data.headline)
                        .font(.system(size: density.supportingPointSize, weight: .semibold))
                        .foregroundStyle(item.isExhausted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .hoverToggleAffordance()
                .hoverTooltip(item.data.meterStyleTooltip)
                .accessibilityLabel("\(item.metricTitle): \(item.data.headline). Toggle used or remaining quota")
                .fixedSize()
                Text("·").foregroundStyle(.tertiary)
                countdown
            }
            MeterBarView(data: item.data, state: item.data.meterState(now: now))
        }
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, density.barRowPadding)
    }

    private var countdown: some View {
        let text = Formatters.whenLabel(at: item.resetsAt, mode: item.data.resetDisplayMode, now: now) ?? Formatters.imminent
        return Button(action: onToggleResetDisplay) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isUrgent ? Theme.notice : AnyShapeStyle(.tertiary))
                    .frame(width: 5, height: 5)
                Text(text)
                    .font(.system(size: density.captionPointSize, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(isUrgent ? Theme.notice : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .hoverToggleAffordance()
        .hoverTooltip(item.data.resetTooltip(now: now))
        .accessibilityLabel("\(item.metricTitle) resets. Toggle countdown or exact time")
        .accessibilityValue(text)
        .accessibilityHint(isUrgent ? "Quota remains in a window resetting within six hours" : "")
        .fixedSize()
    }
}
