import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    let provider: Provider

    let authStore: CodexAuthStore
    let usageClient: CodexUsageClient
    let logUsageScanner: CodexLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    /// Extra-account cards (credential dumps without a Codex home) skip local JSONL spend so they
    /// don't inherit the default home's sessions.
    let scansLocalLogs: Bool

    /// `accountLabel` is the extra card's ChatGPT email (or id suffix); `nil` for the default-home card.
    init(
        id: String = "codex",
        accountLabel: String? = nil,
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        logUsageScanner: CodexLogUsageScanner = CodexLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        scansLocalLogs: Bool = true
    ) {
        self.provider = Provider(
            id: id,
            familyName: "Codex",
            accountLabel: accountLabel,
            icon: .providerMark("codex"),
            links: [
                .init(label: "Status", url: "https://status.openai.com/"),
                .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
            ]
        )
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
        self.scansLocalLogs = scansLocalLogs
    }

    private func metricID(_ name: String) -> String { "\(provider.id).\(name)" }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: metricID("session"), provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: metricID("weekly"), provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            // Model-specific Spark limits (GPT-5.3-Codex-Spark), parsed from `additional_rate_limits`.
            // Declared right after Weekly so they group with the core rate-limit meters; seeded On
            // Demand (below the caret) and unpinned in `DefaultLayout`.
            .percent(id: metricID("spark"), provider: provider, title: "Spark")
                .exportingLimit("spark", unit: "percent"),
            .percent(id: metricID("sparkWeekly"), provider: provider, title: "Spark Weekly")
                .exportingLimit("sparkWeekly", unit: "percent"),
            // The `gpt-reserve` base-model window from the same `additional_rate_limits` array — a
            // second meter Codex reports but never shows in its own UI. Seeded On Demand and unpinned,
            // like Spark; accounts without the limit read "No data".
            .percent(id: metricID("gptReserve"), provider: provider, title: "GPT Reserve")
                .exportingLimit("gptReserve", unit: "percent"),
            .percent(id: metricID("gptReserveWeekly"), provider: provider, title: "GPT Reserve Weekly")
                .exportingLimit("gptReserveWeekly", unit: "percent"),
            .combined(id: metricID("credits"), provider: provider, title: "Extra Usage", metricLabel: "Credits")
                .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
                .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: metricID("rateLimitResets"), provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets", traySuffix: "resets", showsResetExpiries: true)
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available")),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider) + [
            // OpenAI's own account-wide rollup (`wham/profiles/me`), declared after — never inside —
            // the local history rows above. Account Trend is a second, separate chart: it counts every
            // Mac the account codes on, carries no dollars, and lags a day behind the local scan, so it
            // must never merge with or replace the machine-local Usage Trend. The `.accountWide`
            // classification here says so out loud, and keeps this source out of the iCloud sync file.
            .chart(id: metricID("accountTrend"), provider: provider, title: "Account Trend")
                .exportingHistory(
                    scope: .accountWide,
                    estimatedCost: false,
                    sourceNote: "From your OpenAI account (updated daily)"
                ),
            // Each row's own `MetricValue` carries its unit ("tokens" / "days" / "threads"), so these
            // need no `traySuffix` override the way Rate Limit Resets does.
            .values(id: metricID("lifetimeTokens"), provider: provider, title: "Lifetime Tokens",
                    selection: .kind(.count)),
            .values(id: metricID("dayStreak"), provider: provider, title: "Day Streak",
                    selection: .kind(.count)),
            .values(id: metricID("threads"), provider: provider, title: "Threads",
                    selection: .kind(.count)),
            // Account metadata rather than usage, so it sits last (and On Demand by default). Extra
            // account cards inherit this descriptor and fill it from their own auth file's claim.
            .subscriptionRenewal(provider: provider)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: auth.json candidates first, keychain as the fallback. Only a
        // usable access token counts (see `hasUsableAccessToken`) — an API-key-only auth.json can't
        // serve the usage API, so seeding it on would just show an error row.
        let fileCandidates = authStore.loadAuthCandidates()
        if fileCandidates.contains(where: \.hasUsableAccessToken) {
            return true
        }
        let keychain = await loadOffMainActor { [authStore] in authStore.loadKeychainAuth() }
        return keychain?.hasUsableAccessToken == true
    }

    func refresh() async -> ProviderSnapshot {
        let fileCandidates = authStore.loadAuthCandidates()
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            do {
                return try await probe(authState: candidate)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let keychainCandidate = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }) {
            do {
                return try await probe(authState: keychainCandidate)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let lastFallbackError {
            return ProviderSnapshot.error(provider: provider, error: lastFallbackError)
        }
        return ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
    }

    private func probe(authState initialState: CodexAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth) {
            // The `codex` CLI may have rotated the token on disk since we loaded it. Re-read the live
            // credential first and adopt its (newer) access token — refreshing our stale copy would send
            // an already-rotated refresh_token and trip `refresh_token_reused` (issue #516).
            if let live = reloadLiveAuth(source: authState.source),
               let liveToken = live.auth.tokens?.accessToken, !liveToken.isEmpty {
                authState = live
                accessToken = liveToken
            }
        }

        if authStore.needsRefresh(authState.auth),
           let refreshToken = authState.auth.tokens?.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(authState: &authState, refreshToken: refreshToken)
            accessToken = refreshed
        }

        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let accountID = authState.auth.tokens?.accountID
        // Both supplementary reads run together, so the account-wide rollup costs one extra request but
        // effectively no extra wall-clock. Neither can fail the refresh.
        async let pendingResetCredits = fetchResetCreditsBestEffort(accessToken: currentToken, accountID: accountID)
        async let pendingAccountStats = fetchAccountStatsBestEffort(accessToken: currentToken, accountID: accountID)
        let resetCredits = await pendingResetCredits
        let accountStats = await pendingAccountStats
        var mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())

        // Local spend tiles, scanned natively from the Codex CLI's session rollouts and priced through
        // the shared pricing store, merged with Codex usage that happened inside pi (attributed back
        // here). Both scans run on their scanner actors, off the main actor.
        let pricing = await pricing()
        let nativeScan = scansLocalLogs ? await logUsageScanner.scan(now: now(), pricing: pricing) : nil
        let piScan = scansLocalLogs
            ? await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
            : nil
        var usageHistory: ProviderUsageHistory?
        // Cancellation can land between the native and pi scans. Treat the pair as one unit so a
        // partial result cannot replace the last-good combined history in WidgetDataStore.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Codex logs (estimated)"
                : "From your Codex logs and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        // OpenAI's account-wide rollup, appended after the machine-local rows so the two stay visibly
        // separate: distinct labels, distinct rows, no merging. Absent when the call or the payload
        // wasn't usable (logged there), which just leaves these rows reading "No data".
        if let accountStats {
            mapped.lines.append(contentsOf: CodexAccountStatsMapper.lines(stats: accountStats, now: now()))
        }

        // A pure local read of the credential this card already loaded — no request, no refresh. Extra
        // account cards each carry their own auth file, so each one's row names its own subscription;
        // an API-key login (no id_token) simply has no row.
        if let period = CodexAuthStore.subscriptionPeriod(from: authState.auth),
           let line = CodexUsageMapper.subscriptionLine(period: period, now: now()) {
            mapped.lines.append(line)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }

    /// Fetches the on-demand reset-credit balance (and per-credit expiry) without ever failing the
    /// refresh: this is supplementary to the usage metrics, so a network error, timeout, or non-2xx just
    /// yields `nil` and the mapper falls back to the count embedded in the usage body. Logged, not thrown —
    /// the user still gets Session/Weekly/Credits even if this endpoint is down.
    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetches OpenAI's account-wide usage rollup without ever failing the refresh. Like the
    /// reset-credit call this is supplementary — a network error, timeout, or unusable payload just
    /// yields `nil` and the account rows read "No data", while Session / Weekly / Credits and the local
    /// spend rows are unaffected. Logged, not thrown; the parser logs an unusable payload itself.
    private func fetchAccountStatsBestEffort(accessToken: String, accountID: String?) async -> CodexAccountStats? {
        do {
            let response = try await usageClient.fetchAccountStats(accessToken: accessToken, accountID: accountID)
            return CodexAccountStatsParser.parse(response)
        } catch {
            AppLog.warn(LogTag.plugin("codex"),
                        "account stats fetch failed; keeping the existing rows: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CodexAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, accountID: working.auth.tokens?.accountID) },
            refreshAccessToken: {
                guard let refreshToken = working.auth.tokens?.refreshToken, !refreshToken.isEmpty else {
                    throw CodexAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, refreshToken: refreshToken)
                } catch let error as CodexAuthError {
                    throw error
                } catch {
                    throw CodexUsageError.connectionFailed
                }
            },
            connectionFailed: CodexUsageError.connectionFailed,
            authExpired: CodexAuthError.tokenExpired
        )
    }

    /// Re-reads the credential from its original source (the same on-disk file or keychain entry) so a
    /// token the `codex` CLI rotated out-of-band is picked up before we attempt our own refresh. Reads
    /// only that one source — matching how `codex` reads the single `auth.json` from `CODEX_HOME` —
    /// rather than re-scanning every candidate path.
    private func reloadLiveAuth(source: CodexAuthState.Source) -> CodexAuthState? {
        switch source {
        case .file(let path, _):
            return authStore.loadAuth(at: path)
        case .keychain:
            return authStore.loadKeychainAuth()
        }
    }

    private func refreshAccessToken(authState: inout CodexAuthState, refreshToken: String) async throws -> String {
        let response = try await usageClient.refreshToken(refreshToken)
        authState.auth.tokens?.accessToken = response.accessToken
        if let refreshToken = response.refreshToken {
            authState.auth.tokens?.refreshToken = refreshToken
        }
        if let idToken = response.idToken {
            authState.auth.tokens?.idToken = idToken
        }
        authState.auth.lastRefresh = OpenUsageISO8601.string(from: now())
        // Fail loudly: a swallowed save strands the rotated token on disk (next launch re-refreshes /
        // can surface a false "token expired"). The refreshed token works for this session, so log and
        // continue. This is also the only call site of authStore.save, so a genuinely undecodable
        // payload (CodexAuthError.invalidAuthPayload) now surfaces in the log instead of vanishing.
        do {
            try authStore.save(authState)
        } catch {
            AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return response.accessToken
    }
}
