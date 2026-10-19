import SwiftUI

/// The same native calendar editor is reachable from the summary, card headers, and account menus.
struct SubscriptionExpiryEditorPopover: View {
    let provider: Provider

    @Environment(SubscriptionExpiryStore.self) private var expiryStore
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date()
    @State private var isEnding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ProviderIcon(source: provider.icon, inset: 0.04)
                    .frame(width: 20, height: 20)
                Text(provider.familyName)
                    .font(.headline)
                if let label = provider.accountLabel, !label.isEmpty {
                    ProviderAccountBadge(label: label)
                }
                if let plan = dataStore.plan(for: provider.id) {
                    ProviderPlanBadge(plan: plan)
                }
            }
            .hoverTooltip(provider.displayName)

            DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityLabel("Subscription expiry date")

            HStack(spacing: 6) {
                presetButton("+1 Month", component: .month, value: 1)
                presetButton("+3 Months", component: .month, value: 3)
                presetButton("+1 Year", component: .year, value: 1)
            }
            .controlSize(.small)

            Picker("Subscription status", selection: $isEnding) {
                Text("Renews").tag(false)
                Text("Ends").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Manual dates override provider dates. Clear a manual date to use the automatic date again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if expiryStore.entry(for: provider.id) != nil {
                    Button("Clear") {
                        expiryStore.clearExpiry(for: provider.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    expiryStore.setExpiry(selectedDate, isEnding: isEnding, for: provider.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            if let expiry = expiryStore.resolvedExpiry(for: provider.id, snapshot: dataStore.snapshots[provider.id]) {
                selectedDate = expiry.date
                isEnding = expiry.isEnding
            }
        }
    }

    private func presetButton(_ title: String, component: Calendar.Component, value: Int) -> some View {
        Button(title) {
            let base = max(selectedDate, Date())
            if let date = Calendar.current.date(byAdding: component, value: value, to: base) {
                selectedDate = date
            }
        }
    }
}

/// Shared countdown treatment for the summary, single-account headers, and family account rows.
struct SubscriptionExpiryBadge: View {
    let expiry: SubscriptionExpiryStore.ResolvedExpiry

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        let severity = expiry.severity()
        HStack(spacing: 4) {
            Circle()
                .fill(severity == .normal ? AnyShapeStyle(.secondary) : Theme.severityFill(severity))
                .frame(width: 5, height: 5)
            Text(expiry.countdownText())
                .font(.system(size: density.captionPointSize, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(severity == .normal ? AnyShapeStyle(.quaternary) : Theme.severityFill(severity))
                .opacity(severity == .normal ? 1 : 0.18)
        }
        .fixedSize()
        .hoverTooltip("\(expiry.isEnding ? "Ends" : "Renews") \(expiry.formattedDate()) (\(expiry.countdownText())) — Click to edit")
    }
}

/// All enabled account cards, with manual overrides taking precedence over provider billing dates.
struct SubscriptionExpiryCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(SubscriptionExpiryStore.self) private var expiryStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var editingExpiryProvider: Provider?

    private struct ConfiguredSubscription: Identifiable {
        let provider: Provider
        let expiry: SubscriptionExpiryStore.ResolvedExpiry
        var id: String { provider.id }
    }

    var body: some View {
        let providers = layout.displayGroups.map(\.provider)
        let configured = providers.compactMap { provider -> ConfiguredSubscription? in
            guard let expiry = expiryStore.resolvedExpiry(
                for: provider.id, snapshot: dataStore.snapshots[provider.id]
            ) else { return nil }
            return ConfiguredSubscription(provider: provider, expiry: expiry)
        }.sorted {
            if $0.expiry.date != $1.expiry.date { return $0.expiry.date < $1.expiry.date }
            return $0.provider.id < $1.provider.id
        }
        let configuredIDs = Set(configured.map(\.id))
        let unconfigured = providers.filter { !configuredIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(configuredCount: configured.count, totalCount: providers.count)
            VStack(alignment: .leading, spacing: 0) {
                if configured.isEmpty && unconfigured.isEmpty {
                    EmptyStateView(title: "No enabled subscriptions")
                } else {
                    ForEach(Array(configured.enumerated()), id: \.element.id) { index, subscription in
                        if index > 0 { CardHairline() }
                        configuredRow(subscription)
                    }
                    if !unconfigured.isEmpty {
                        if !configured.isEmpty { CardHairline() }
                        unconfiguredSubscriptions(unconfigured)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .popover(item: $editingExpiryProvider, arrowEdge: .top) { provider in
            SubscriptionExpiryEditorPopover(provider: provider)
        }
    }

    private func header(configuredCount: Int, totalCount: Int) -> some View {
        HStack(spacing: 6) {
            Text("Subscription Expiries")
                .font(.system(size: density.headerPointSize, weight: .semibold))
            Text("\(configuredCount)/\(totalCount)")
                .font(.system(size: density.planBadgePointSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(configuredCount) of \(totalCount) subscriptions have expiry dates")
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.sectionHeaderInset)
        .padding(.vertical, 2)
    }

    private func configuredRow(_ subscription: ConfiguredSubscription) -> some View {
        let provider = subscription.provider
        let expiry = subscription.expiry
        return Button {
            editingExpiryProvider = provider
        } label: {
            HStack(spacing: 6) {
                providerIdentity(provider)
                Spacer(minLength: 8)
                if expiry.source == .manual { tag("Manual") }
                if expiry.isEnding { tag("Ends") }
                Text(expiry.formattedDate())
                    .font(.system(size: density.captionPointSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                SubscriptionExpiryBadge(expiry: expiry)
                Image(systemName: "calendar")
                    .font(.system(size: density.captionPointSize))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.cardRowInset)
            .padding(.vertical, density == .compact ? 6 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName), \(expiry.isEnding ? "Ends" : "Renews") \(expiry.formattedDate()), \(expiry.countdownText()). Edit expiry date")
    }

    private func providerIdentity(_ provider: Provider) -> some View {
        HStack(spacing: 5) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: 16, height: 16)
            Text(provider.familyName)
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if let label = provider.accountLabel, !label.isEmpty {
                ProviderAccountBadge(label: label)
            }
            if let plan = dataStore.plan(for: provider.id) {
                ProviderPlanBadge(plan: plan)
            }
        }
        .hoverTooltip(provider.displayName)
    }

    private func tag(_ title: String) -> some View {
        Text(title)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func unconfiguredSubscriptions(_ providers: [Provider]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set expiry dates")
                .font(.system(size: density.captionPointSize, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(providers) { provider in
                        Button {
                            editingExpiryProvider = provider
                        } label: {
                            HStack(spacing: 5) {
                                ProviderIcon(source: provider.icon, inset: 0.04)
                                    .frame(width: 14, height: 14)
                                Text(provider.familyName)
                                    .font(.system(size: density.captionPointSize, weight: .medium))
                                if let label = provider.accountLabel, !label.isEmpty {
                                    ProviderAccountBadge(label: label)
                                }
                                Image(systemName: "calendar.badge.plus")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip("Set expiry date for \(provider.displayName)")
                        .accessibilityLabel("Set expiry date for \(provider.displayName)")
                    }
                }
            }
        }
        .padding(.horizontal, Theme.cardRowInset)
        .padding(.vertical, 8)
    }
}
