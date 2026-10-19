import Foundation

@MainActor
final class MuseProvider: ProviderRuntime {
    let provider: Provider

    let authStore: MuseAuthStore
    let usageClient: MuseUsageClient
    let cliScanner: MuseCLIUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageClient: MuseUsageClient = MuseUsageClient(),
        cliScanner: MuseCLIUsageScanner = MuseCLIUsageScanner(),
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init,
        accountLabel: String? = nil
    ) {
        self.provider = Provider(
            id: "muse",
            familyName: "Muse Code",
            accountLabel: accountLabel,
            icon: .providerMark("muse"),
            links: [
                .init(label: "Dashboard", url: "https://accountscenter.meta.com/muse_code/")
            ]
        )
        self.authStore = authStore
        self.usageClient = usageClient
        self.cliScanner = cliScanner
        self.pricing = pricing
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: "muse.session",
                provider: provider,
                title: "Session",
                metricLabel: "Session",
                sessionStartSignal: .zeroUsage
            )
                .exportingLimit("session", unit: "percent"),
            .percent(
                id: "muse.weekly",
                provider: provider,
                title: "Weekly",
                metricLabel: "Weekly"
            )
                .exportingLimit("weekly", unit: "percent")
        ] + WidgetDescriptor.spendTiles(provider: provider) + [
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Muse Code logs (estimated)"
                )
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasLocalCredentials() }
    }

    func refresh() async -> ProviderSnapshot {
        let credentials: MuseCredentials?
        do {
            credentials = try await loadOffMainActor { [authStore] in
                try authStore.loadCredentials()
            }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let credentials else {
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchUsage(credentials: credentials)
            var mapped = try MuseUsageMapper.map(response)
            let priced = await pricing()
            let cliScan = await loadOffMainActor { [cliScanner, now] in
                cliScanner.scan(now: now(), pricing: priced)
            }
            if let scan = cliScan {
                SpendTileMapper.appendTokenUsage(
                    scan.series,
                    to: &mapped.lines,
                    now: now(),
                    unknownModelsByDay: scan.unknownModelsByDay,
                    modelUsage: scan.modelUsage,
                    modelSourceNote: "From your Muse Code logs (estimated)",
                    pricing: priced
                )
                SpendTileMapper.appendUsageTrend(
                    scan.series,
                    to: &mapped.lines,
                    now: now(),
                    note: "From your Muse Code logs (estimated)"
                )
                mapped.lines.removeAll { $0.label == "No data" }
            }
            MetricLine.appendNoDataIfNeeded(&mapped.lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now(),
                usageHistory: cliScan.map {
                    ProviderUsageHistory(
                        series: $0.series,
                        modelUsage: $0.modelUsage,
                        unknownModelsByDay: $0.unknownModelsByDay
                    )
                }
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
