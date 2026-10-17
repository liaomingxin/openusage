import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider: Provider

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let piScanner: PiUsageScanner
    let cliScanner: KimiCLIUsageScanner
    let openCodeSubscriptionScanner: OpenCodeSubscriptionUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date
    let scansLocalLogs: Bool

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        piScanner: PiUsageScanner = .shared,
        cliScanner: KimiCLIUsageScanner = KimiCLIUsageScanner(),
        openCodeSubscriptionScanner: OpenCodeSubscriptionUsageScanner = OpenCodeSubscriptionUsageScanner(),
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init,
        id: String = "kimi",
        accountLabel: String? = nil,
        scansLocalLogs: Bool = true
    ) {
        self.provider = Provider(
            id: id, familyName: "Kimi Code", accountLabel: accountLabel, icon: .providerMark("kimi")
        )
        self.authStore = authStore
        self.usageClient = usageClient
        self.piScanner = piScanner
        self.cliScanner = cliScanner
        self.openCodeSubscriptionScanner = openCodeSubscriptionScanner
        self.pricing = pricing
        self.now = now
        self.scansLocalLogs = scansLocalLogs
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Kimi's mapper divides raw used/limit counts into a full-precision percent (no
            // whole-percent rounding), so any touched window reads above 0 — `used == 0` really does
            // mean the rolling 5-hour window is untouched. The signal is additionally gated on a
            // future `resetsAt`, so a payload without a reset time renders exactly as it does today.
            .percent(id: "\(provider.id).session", provider: provider, title: "Session",
                     metricLabel: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).monthlyTotal", provider: provider, title: "Monthly Total",
                     metricLabel: "Monthly Total")
                .exportingLimit("monthlyTotal", unit: "percent"),
            .percent(id: "\(provider.id).monthlyCoding", provider: provider, title: "Monthly Coding",
                     metricLabel: "Monthly Coding")
                .exportingLimit("monthlyCoding", unit: "percent"),
            // Pay-as-you-go booster balance; absent on subscription accounts, so seeded off by
            // default and below the caret for the pay-as-you-go users who enable it.
            .dollarBalance(id: "\(provider.id).booster", provider: provider, title: "Booster",
                           metricLabel: "Booster", valueWord: "left")
                .exportingLimit("booster", kind: .balance, unit: "usd",
                                source: .value(kind: .dollars))
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            authStore.usesAPIKey ? authStore.loadAPIKey() != nil : authStore.loadCredentials() != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let response = try await fetchUsage()
            var mapped = try KimiUsageMapper.map(response, now: now())
            var history: LogUsageScan?
            if scansLocalLogs {
                let priced = await pricing()
                let piScan = await piScanner.scan(cardID: provider.id, now: now(), pricing: priced)
                let cliScan = cliScanner.scan(now: now(), pricing: priced)
                let openCodeScan = await openCodeSubscriptionScanner.scan(now: now(), pricing: priced).localSpend[provider.id]
                history = DailyUsageAccumulator.merged([piScan, cliScan, openCodeScan])
                if let history {
                    SpendTileMapper.appendTokenUsage(
                        history.series, to: &mapped.lines, now: now(),
                        unknownModelsByDay: history.unknownModelsByDay,
                        modelUsage: history.modelUsage,
                        modelSourceNote: "From your Kimi Code logs (estimated)",
                        pricing: priced
                    )
                    mapped.lines.removeAll { $0.label == "No data" }
                }
            }
            MetricLine.appendNoDataIfNeeded(&mapped.lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now(),
                usageHistory: history.map {
                    ProviderUsageHistory(
                        series: $0.series, modelUsage: $0.modelUsage, unknownModelsByDay: $0.unknownModelsByDay
                    )
                }
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func fetchUsage() async throws -> HTTPResponse {
        let region = await loadOffMainActor { [authStore] in authStore.region() }
        if authStore.usesAPIKey {
            guard let key = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
                throw KimiAccountAuthError.missingAPIKey
            }
            let response: HTTPResponse
            do {
                response = try await usageClient.fetchUsage(apiKey: key, region: region)
            } catch {
                throw KimiUsageError.connectionFailed
            }
            if ProviderAuthRetry.isAuthFailure(response) {
                throw KimiAccountAuthError.rejectedAPIKey
            }
            return response
        }

        guard var credentials = await loadOffMainActor({ [authStore] in authStore.loadCredentials() }) else {
            throw KimiAuthError.notLoggedIn
        }
        let deviceID = await loadOffMainActor { [authStore] in authStore.deviceID() }
        // Access tokens last 15 minutes; renew before sending one known to be expired.
        if authStore.needsRefresh(credentials) {
            credentials = try await refreshCredentials(credentials, deviceID: deviceID)
        }
        return try await fetchUsageWithRetry(
            credentials: &credentials, region: region, deviceID: deviceID
        )
    }

    /// The shared attempt → on 401 refresh → retry-once sequence. The closure owns the provider-
    /// specific parts: loading the refresh token, calling Kimi's token endpoint, persisting the
    /// rotated pair.
    private func fetchUsageWithRetry(
        credentials: inout KimiCredentials,
        region: String,
        deviceID: String?
    ) async throws -> HTTPResponse {
        var working = credentials
        defer { credentials = working }
        let accessToken = working.accessToken ?? ""
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, region: region) },
            refreshAccessToken: {
                guard let refreshToken = working.refreshToken, !refreshToken.isEmpty else {
                    throw KimiAuthError.sessionExpired
                }
                working = try await self.refreshCredentials(working, deviceID: deviceID)
                return working.accessToken ?? ""
            },
            connectionFailed: KimiUsageError.connectionFailed,
            authExpired: KimiAuthError.sessionExpired
        )
    }

    /// Mints a fresh access token and writes the rotated pair back to the default CLI credential
    /// file. A failed save is logged; the current request can still use the new token, while a
    /// later invalid_grant is surfaced rather than falling back to another account.
    private func refreshCredentials(
        _ credentials: KimiCredentials,
        deviceID: String?
    ) async throws -> KimiCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw KimiAuthError.sessionExpired
        }
        let response = try await usageClient.refreshToken(refreshToken, deviceID: deviceID)

        var updated = credentials
        updated.accessToken = response.accessToken
        if let rotated = response.refreshToken {
            updated.refreshToken = rotated
        }
        updated.expiresIn = response.expiresIn
        updated.expiresAt = Int(now().timeIntervalSince1970) + (response.expiresIn ?? 900)

        do {
            try authStore.save(updated)
        } catch {
            AppLog.error(LogTag.auth(provider.id), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return updated
    }
}
