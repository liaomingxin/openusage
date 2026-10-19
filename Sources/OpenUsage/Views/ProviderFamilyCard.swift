import SwiftUI

struct ProviderFamilyCluster: Identifiable {
    let familyID: String
    let groups: [ProviderGroup]

    var id: String { familyID }
    var isMultiAccount: Bool { groups.count > 1 }

    static func clusters(from groups: [ProviderGroup], groupByFamily: Bool) -> [ProviderFamilyCluster] {
        guard groupByFamily else {
            return groups.map { ProviderFamilyCluster(familyID: $0.provider.id, groups: [$0]) }
        }
        var familyOrder: [String] = []
        var groupsByFamily: [String: [ProviderGroup]] = [:]
        for group in groups {
            let family = ProviderAccountID.family(of: group.provider.id)
            if groupsByFamily[family] == nil { familyOrder.append(family) }
            groupsByFamily[family, default: []].append(group)
        }
        return familyOrder.map { ProviderFamilyCluster(familyID: $0, groups: groupsByFamily[$0] ?? []) }
    }
}

/// A family stays in one place while its account pills switch between the compact matrix and the
/// dashboard's full interactive account content. The caller owns that selection across grid moves.
struct ProviderFamilySection<SingleAccountContent: View>: View {
    let cluster: ProviderFamilyCluster
    let selectedAccountID: String?
    let onSelectAccount: (String?) -> Void
    let filterMode: DashboardFilterMode
    @ViewBuilder var focusedAccountContent: (ProviderGroup) -> SingleAccountContent

    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private struct MatrixRow: Identifiable {
        let id: String
        let data: WidgetData
    }

    private struct Account: Identifiable {
        let group: ProviderGroup
        let severity: WidgetData.MeterSeverity?
        let rows: [MatrixRow]
        let plan: String?
        let warning: String?
        let refreshing: Bool
        let isIdle: Bool
        let lowestRemainingFraction: Double
        var id: String { group.provider.id }

        var priority: Int {
            if severity == .critical || warning != nil { return 3 }
            if severity == .warning { return 2 }
            return isIdle ? 0 : 1
        }
    }

    var body: some View {
        let accounts = cluster.groups.map(resolveAccount).sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.priority == 1 && lhs.lowestRemainingFraction < rhs.lowestRemainingFraction
        }
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            if let first = cluster.groups.first {
                familyHeader(provider: first.provider, accounts: accounts)
                    .padding(.horizontal, Theme.sectionHeaderInset)
            }
            DashboardMetricCard {
                accountSwitcher(accounts)
                CardHairline()
                if let account = accounts.first(where: { $0.id == selectedAccountID }) {
                    focusedAccountBar(account)
                    focusedAccountContent(account.group)
                } else {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { CardHairline() }
                        matrixSection(account)
                    }
                }
            }
        }
    }

    private func familyHeader(provider: Provider, accounts: [Account]) -> some View {
        let warnings = accounts.compactMap { account in
            account.warning.map { "\(account.group.provider.accountLabel ?? "Default"): \($0)" }
        }
        return HStack(spacing: 6) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
            Text(provider.familyName)
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text("\(accounts.count) accounts")
                .font(.system(size: density.planBadgePointSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .fixedSize()
            if accounts.contains(where: \.refreshing) {
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityLabel("Refreshing accounts")
            }
            if !warnings.isEmpty {
                warningIcon(warnings.joined(separator: "\n"))
            }
            Spacer(minLength: 4)
            familyActions
        }
        .padding(.vertical, 2)
    }

    private var familyActions: some View {
        Menu {
            Button("Refresh All Accounts") {
                Task {
                    for group in cluster.groups {
                        await dataStore.refreshOnUserRequest(providerID: group.provider.id)
                    }
                }
            }
            Divider()
            ForEach(cluster.groups) { group in
                Menu(group.provider.accountLabel ?? "Default") {
                    Button("Refresh") {
                        Task { await dataStore.refreshOnUserRequest(providerID: group.provider.id) }
                    }
                    Button("Customize…") { openCustomize(for: group.provider.id) }
                    Button("Share Screenshot") {
                        ShareCardRenderer.share(
                            group: group, dataStore: dataStore, layout: layout, appearance: colorScheme
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Family account actions")
    }

    private func accountSwitcher(_ accounts: [Account]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                accountPill(id: nil, label: "All (\(accounts.count))", severity: nil)
                ForEach(accounts) { account in
                    accountPill(
                        id: account.id, label: account.group.provider.accountLabel ?? "Default",
                        severity: account.severity
                    )
                }
            }
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.vertical, 6)
        }
    }

    private func accountPill(id: String?, label: String, severity: WidgetData.MeterSeverity?) -> some View {
        let isSelected = id == selectedAccountID || (id == nil && !cluster.groups.contains { $0.id == selectedAccountID })
        return Button {
            withAnimation(Motion.spring) { onSelectAccount(id) }
        } label: {
            HStack(spacing: 4) {
                if id != nil { statusDot(severity) }
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130)
            }
            .font(.system(size: density.captionPointSize, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverTooltip(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func focusedAccountBar(_ account: Account) -> some View {
        HStack(spacing: 6) {
            if let plan = account.plan { ProviderPlanBadge(plan: plan) }
            if let warning = account.warning { warningIcon(warning) }
            Spacer(minLength: 4)
            Button {
                Task { await dataStore.refreshOnUserRequest(providerID: account.id) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(account.refreshing)
            Button("Customize…") { openCustomize(for: account.id) }
        }
        .buttonStyle(.plain)
        .font(.system(size: density.captionPointSize, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, 6)
    }

    private func matrixSection(_ account: Account) -> some View {
        let quotaRows = Array(account.rows.lazy.filter { $0.data.isBounded }.prefix(2))
        return Button {
            withAnimation(Motion.spring) { onSelectAccount(account.id) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.isIdle ? AnyShapeStyle(.tertiary) : Theme.severityFill(account.severity))
                    .frame(width: 6, height: 6)
                Text(account.group.provider.accountLabel ?? "Default")
                    .font(.system(size: density.supportingPointSize, weight: account.isIdle ? .regular : .semibold))
                    .foregroundStyle(account.isIdle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = account.plan { ProviderPlanBadge(plan: plan) }
                if let warning = account.warning { warningIcon(warning) }
                Spacer(minLength: 6)
                if quotaRows.isEmpty {
                    if let row = account.rows.first(where: { !$0.data.isBounded }) {
                        Text(row.data.unboundedDetail)
                            .font(.system(size: density.captionPointSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    ForEach(quotaRows) { row in
                        matrixQuotaCell(row.data)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.cardRowInset)
            .frame(height: density == .compact ? 28 : 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(account.rows.map { "\($0.data.title): \($0.data.headline)" }.joined(separator: "\n"))
        .accessibilityLabel("Show \(account.group.provider.accountLabel ?? "Default") account")
    }

    private func matrixQuotaCell(_ data: WidgetData) -> some View {
        let isIdle = data.used <= 0.0001
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text(shortMatrixLabel(data.title))
                    .font(.system(size: density.captionPointSize, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(isIdle ? "Idle" : data.menuBarValue)
                    .font(.system(size: density.captionPointSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isIdle ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
            .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Theme.severityFill(data.meterState().severity))
                        .opacity(isIdle ? 0.35 : 1)
                        .frame(width: data.hasData ? proxy.size.width * data.fraction : 0)
                }
            }
            .frame(height: 4)
        }
        .frame(width: density == .compact ? 74 : 84)
    }

    private func shortMatrixLabel(_ title: String) -> String {
        switch title {
        case "Session": return "5h"
        case "Weekly": return "7d"
        case "Monthly Total": return "Mo"
        case "Monthly Coding": return "Code"
        case "Gemini Pro": return "Pro"
        default: return String(title.prefix { !$0.isWhitespace }.prefix(6))
        }
    }

    private func resolveAccount(_ group: ProviderGroup) -> Account {
        var severity: WidgetData.MeterSeverity?
        var rows: [MatrixRow] = []
        let warning = dataStore.headerNotice(for: group.provider.id)
        var isIdle = warning == nil
        var lowestRemainingFraction = 1.0
        let alwaysShownIDs = Set(group.alwaysShownWidgets.map(\.id))
        for widget in group.widgets {
            guard let descriptor = layout.descriptor(for: widget) else { continue }
            let data = dataStore.data(for: descriptor)
            if data.isBounded {
                if data.used > 0.0001 { isIdle = false }
                if data.hasData {
                    lowestRemainingFraction = min(lowestRemainingFraction, data.remainingFraction)
                }
            }
            if data.isBounded, let candidate = data.meterState().severity {
                if candidate == .critical || severity == nil || (candidate == .warning && severity == .normal) {
                    severity = candidate
                }
            }
            if alwaysShownIDs.contains(widget.id), !data.isChart, filterMode.matches(data: data) {
                rows.append(MatrixRow(id: descriptor.id, data: data))
            }
        }
        return Account(
            group: group, severity: severity, rows: rows,
            plan: dataStore.plan(for: group.provider.id),
            warning: warning,
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            isIdle: isIdle,
            lowestRemainingFraction: lowestRemainingFraction
        )
    }

    private func statusDot(_ severity: WidgetData.MeterSeverity?) -> some View {
        Circle()
            .fill(Theme.severityFill(severity))
            .frame(width: 6, height: 6)
            .accessibilityLabel(severity == .critical ? "Critical quota" : severity == .warning ? "Quota warning" : "Quota status")
    }

    private func warningIcon(_ warning: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.notice)
            .hoverTooltip(warning)
            .accessibilityLabel(warning)
    }

    private func openCustomize(for providerID: String) {
        withAnimation(Motion.modeSwitch) {
            layout.customizeProviderID = providerID
            layout.isEditing = true
        }
    }
}
