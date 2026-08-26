import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi Code",
        icon: .providerMark("kimi")
        // No `links:` — Kimi Code's usage view lives in the CLI (`/usage`, `kimi web` local UI);
        // Moonshot ships no public usage dashboard to link to yet.
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Kimi's mapper divides raw used/limit counts into a full-precision percent (no
            // whole-percent rounding), so any touched window reads above 0 — `used == 0` really does
            // mean the rolling 5-hour window is untouched. The signal is additionally gated on a
            // future `resetsAt`, so a payload without a reset time renders exactly as it does today.
            .percent(id: "kimi.session", provider: provider, title: "Session",
                     metricLabel: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            // Pay-as-you-go booster balance; absent on subscription accounts, so seeded off by
            // default and below the caret for the pay-as-you-go users who enable it.
            .dollarBalance(id: "kimi.booster", provider: provider, title: "Booster",
                           metricLabel: "Booster", valueWord: "left")
                .exportingLimit("booster", kind: .balance, unit: "usd",
                                source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same loader as `refresh()`: the kimi CLI's credential file with a refresh token.
        await loadOffMainActor { [authStore] in authStore.loadCredentials() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard var credentials = await loadOffMainActor({ [authStore] in authStore.loadCredentials() }) else {
            return ProviderSnapshot.error(provider: provider, error: KimiAuthError.notLoggedIn)
        }
        let region = await loadOffMainActor { [authStore] in authStore.region() }
        let deviceID = await loadOffMainActor { [authStore] in authStore.deviceID() }

        do {
            // 15-minute access tokens: refresh eagerly when at/near expiry so the usage call never
            // starts from a token we know is dead.
            if authStore.needsRefresh(credentials) {
                credentials = try await refreshCredentials(credentials, deviceID: deviceID)
            }

            let response = try await fetchUsageWithRetry(
                credentials: &credentials, region: region, deviceID: deviceID
            )
            var mapped = try KimiUsageMapper.map(response, now: now())
            MetricLine.appendNoDataIfNeeded(&mapped.lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
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

    /// Mints a fresh access token and writes the rotated pair back to the credential file the
    /// `kimi` CLI reads. A failed save is logged loudly and the refreshed token still serves this
    /// refresh — but the next one must not reuse the stale refresh token, so it fails visibly
    /// (`invalid_grant` → "log in again") rather than silently looping.
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
            AppLog.error(LogTag.auth("kimi"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return updated
    }
}
