import Foundation

@MainActor
final class CursorProvider: ProviderRuntime {
    let provider: Provider

    let authStore: CursorAuthStore
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    let spendHistoryBudget: TimeInterval
    let usageHistoryStore: CursorUsageHistoryStore

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        spendHistoryBudget: TimeInterval = 20,
        usageHistoryStore: CursorUsageHistoryStore = CursorUsageHistoryStore(),
        id: String = "cursor",
        accountLabel: String? = nil
    ) {
        self.provider = Provider(
            id: id,
            familyName: "Cursor",
            accountLabel: accountLabel,
            icon: .providerMark("cursor"),
            links: [
                .init(label: "Status", url: "https://status.cursor.com/"),
                .init(label: "Dashboard", url: "https://www.cursor.com/dashboard")
            ]
        )
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.pricing = pricing
        self.spendHistoryBudget = spendHistoryBudget
        self.usageHistoryStore = usageHistoryStore
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).usage", provider: provider, title: "Total Usage", metricLabel: "Total usage")
                .exportingLimit("totalUsage", unit: "percent"),
            .percent(id: "\(provider.id).auto", provider: provider, title: "Cursor Models")
                .exportingLimit("autoUsage", unit: "percent"),
            .percent(id: "\(provider.id).api", provider: provider, title: "Other Models")
                .exportingLimit("apiUsage", unit: "percent"),
            .percent(id: "\(provider.id).grokBot", provider: provider, title: "Grok Bot", metricLabel: "Grok Bot usage")
                .exportingLimit("grokBot", unit: "percent"),
            .boundedDollars(id: "\(provider.id).onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand", limit: 100, valueWord: "spent")
                .exportingLimit("onDemand", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .boundedCount(id: "\(provider.id).requests", provider: provider, title: "Requests", limit: 500,
                          suffix: "requests", periodDurationMs: CursorUsageMapper.billingPeriodMs)
                .exportingLimit("requests", unit: "requests"),
            .dollarBalance(id: "\(provider.id).credits", provider: provider, title: "Credits", valueWord: "left")
                .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .accountWide,
                    estimatedCost: true,
                    sourceNote: "From your Cursor usage history"
                )
        ] + WidgetDescriptor.spendTiles(
            provider: provider,
            valueTooltipNote: WidgetData.cursorUsageHistoryNote
        ) + [
            // Account metadata rather than usage, so it sits last (and On Demand by default).
            .subscriptionRenewal(provider: provider)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Probe only the selected source; an OMP card must never borrow the native login.
        await loadOffMainActor { [authStore] in authStore.loadAuthState() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let state: CursorAuthState
            if authStore.ompAccount != nil {
                state = try await loadOffMainActor { [authStore] in
                    try authStore.loadOMPAuthState()
                }
            } else {
                guard let nativeState = await loadOffMainActor({ [authStore] in authStore.loadAuthState() }) else {
                    throw CursorAuthError.notLoggedIn
                }
                state = nativeState
            }
            do {
                return try await probe(authState: state)
            } catch let error as CursorAuthError where state.source == .sqlite {
                if let keychainState = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuthState() }),
                   keychainState.accessToken != state.accessToken {
                    return try await probe(authState: keychainState)
                }
                throw error
            }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func probe(authState initialState: CursorAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        var accessToken = authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if authState.source == .omp, let expiresAt = authState.expiresAt, expiresAt <= now() {
            throw OMPOAuthError.sessionExpired("Cursor")
        }

        if authState.source != .omp, authStore.needsRefresh(accessToken) {
            do {
                if let refreshed = try await refreshAccessToken(authState: authState) {
                    authState.accessToken = refreshed
                    accessToken = refreshed
                } else if accessToken == nil {
                    throw CursorAuthError.notLoggedIn
                }
            } catch {
                if accessToken == nil {
                    throw error
                }
            }
        }

        guard let accessToken else {
            if authState.source == .omp {
                throw OMPOAuthError.unavailable("Cursor")
            }
            throw CursorAuthError.notLoggedIn
        }

        let usageResponse: HTTPResponse
        do {
            usageResponse = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        } catch CursorUsageError.connectionFailed {
            let currentToken = authState.accessToken ?? accessToken
            if let mapped = try? await usageSummaryAndRequestResult(
                accessToken: currentToken,
                planName: CursorUsageMapper.resolvedPlanName(
                    planInfoName: nil,
                    membershipType: authState.membershipType
                ),
                unavailableMessage: CursorUsageError.connectionFailed.localizedDescription
            ) {
                var enriched = mapped
                let history = await appendSpendLines(to: &enriched.lines, accessToken: currentToken)
                return snapshot(enriched, usageHistory: history)
            }
            throw CursorUsageError.connectionFailed
        }
        try ProviderAuthRetry.requireSuccess(
            usageResponse,
            authExpired: CursorAuthError.tokenExpired,
            requestFailed: { CursorUsageError.requestFailed($0) }
        )
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.accessToken ?? accessToken
        let isUnifiedGrokWithoutPlanUsage = !CursorPlanUsageFacts(usage: usage).hasPlanUsage
            && (CursorAuthStore.tokenSubject(currentToken)?.hasPrefix("grok|") == true)

        let planInfo = isUnifiedGrokWithoutPlanUsage
            ? CursorPlanInfo(name: nil, unavailable: true, billingCycleEnd: nil)
            : await fetchPlanInfo(accessToken: currentToken)
        let planInfoName = planInfo.name
        let planInfoUnavailable = planInfo.unavailable
        let routingPlanName = CursorUsageMapper.routingPlanName(
            planInfoName: planInfoName,
            membershipType: authState.membershipType
        )
        let displayPlanName = CursorUsageMapper.resolvedPlanName(
            planInfoName: planInfoName,
            membershipType: authState.membershipType
        )
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: routingPlanName,
            planInfoUnavailable: planInfoUnavailable
        )
        if fallback.shouldFallback {
            var mapped = try await usageSummaryAndRequestResult(
                accessToken: currentToken,
                planName: displayPlanName ?? routingPlanName,
                unavailableMessage: fallback.message
            )
            if !isUnifiedGrokWithoutPlanUsage {
                await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
            }
            let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
            return snapshot(mapped, usageHistory: history)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            do {
                var mapped = try await requestBasedResult(
                    accessToken: currentToken,
                    planName: displayPlanName ?? routingPlanName,
                    unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
                )
                await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
                return snapshot(mapped)
            } catch {
                AppLog.warn(LogTag.plugin("cursor"), "optional request-based usage fallback failed")
            }
        }

        let creditGrants = await fetchCreditGrants(accessToken: currentToken)
        let stripe = await fetchStripeAccount(accessToken: currentToken)
        var mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planInfoName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripe.balanceCents,
            planBillingCycleEnd: planInfo.billingCycleEnd,
            subscriptionIsEnding: stripe.isEnding
        )
        mapped.plan = CursorUsageMapper.resolvedPlanLabel(
            planInfoName: planInfoName,
            membershipType: authState.membershipType
        )
        await enrichPrimaryUsageFromSummaryIfNeeded(
            accessToken: currentToken,
            usage: usage,
            planInfoName: planInfoName,
            membershipType: authState.membershipType,
            mapped: &mapped
        )
        await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
        let history = await appendSpendLines(to: &mapped.lines, accessToken: currentToken)
        return snapshot(mapped, usageHistory: history, warning: stripe.paymentWarning)
    }

    /// Model-pool Enterprise/team seats often keep a usable primary usage payload but omit on-demand
    /// there. usage-summary still carries Extra Usage for those accounts.
    private func enrichPrimaryUsageFromSummaryIfNeeded(
        accessToken: String,
        usage: [String: Any],
        planInfoName: String?,
        membershipType: String?,
        mapped: inout CursorMappedUsage
    ) async {
        let needsOnDemand = !mapped.lines.contains(where: { $0.label == "On-demand" })
        let facts = CursorPlanUsageFacts(usage: usage)
        let localIsOrg = membershipType.map { CursorUsageMapper.orgMembershipTypes.contains($0) } ?? false
        // Only org / team-shaped seats: personal Pro model pools must not trigger usage-summary.
        guard localIsOrg || facts.isTeamByShape else { return }
        // Local org already fixed the badge; skip the extra call when Extra Usage is present.
        if localIsOrg, !needsOnDemand { return }

        guard let summary = await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        }) else {
            return
        }
        if !CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
            AppLog.warn(LogTag.plugin("cursor"), "optional usage-summary response contained no usable usage fields")
            return
        }
        if needsOnDemand {
            CursorUsageSummaryMapper.appendMissingOnDemand(from: summary, to: &mapped.lines)
        }
        let summaryMembership = (summary["membershipType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        mapped.plan = CursorUsageMapper.resolvedPlanLabel(
            planInfoName: planInfoName,
            membershipType: CursorUsageMapper.preferredMembership(
                local: membershipType,
                summary: summaryMembership
            )
        ) ?? mapped.plan
    }

    /// Grok Bot uses the same Cursor account but keeps a separate weekly allowance. Missing access is
    /// normal for ineligible accounts; malformed data and request failures remain visible in diagnostics.
    private func appendGrokBotUsage(to lines: inout [MetricLine], accessToken: String) async {
        guard let usage = await fetchOptionalJSONObject(label: "Grok Bot usage", request: {
            try await self.usageClient.fetchGrokBotUsage(accessToken: accessToken)
        }) else {
            return
        }
        guard usage["usesPooledEnterpriseAllowance"] as? Bool != true,
              usage["hasNonZeroIncludedLimit"] as? Bool != false,
              usage["includedLimitZero"] as? Bool != true
        else {
            return
        }
        guard let line = CursorUsageMapper.mapGrokBotUsage(usage) else {
            if usage["usagePercent"] != nil || usage["hasNonZeroIncludedLimit"] as? Bool == true ||
                usage["hasAvailableUsage"] as? Bool == true {
                AppLog.warn(LogTag.plugin("cursor"), "optional Grok Bot usage response contained invalid usage metadata")
            }
            return
        }
        lines.append(line)
    }

    /// Spend history is best-effort and never affects the live Cursor usage mapping.
    private func appendSpendLines(to lines: inout [MetricLine], accessToken: String) async -> ProviderUsageHistory? {
        guard let session = CursorUsageClient.session(from: accessToken) else {
            AppLog.warn(LogTag.plugin("cursor"), "usage events could not be prepared from the current session")
            return nil
        }
        let currentTime = now()
        let fetcher = CursorSpendHistoryFetcher(
            client: usageClient,
            store: usageHistoryStore,
            budget: spendHistoryBudget
        )
        guard let days = await fetcher.refresh(
            accessToken: accessToken,
            userID: session.userID,
            now: currentTime
        ) else {
            return nil
        }
        let pricing = await pricing()
        let rows = days.flatMap { dayStart, day in
            day.models.map { model, tokens in
                CursorUsageRow(
                    date: dayStart,
                    model: model,
                    tokens: tokens,
                    imputedCostDollars: pricing.estimatedCostDollars(
                        model: model,
                        tokens: tokens,
                        applyLongContextRates: false
                    )
                )
            }
        }
        return CursorUsageMapper.appendSpendLines(rows: rows, now: currentTime, pricing: pricing, to: &lines)
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CursorAuthState) async throws -> HTTPResponse {
        if authState.source == .omp {
            let response: HTTPResponse
            do {
                response = try await usageClient.fetchUsage(accessToken: accessToken)
            } catch {
                throw CursorUsageError.connectionFailed
            }
            if ProviderAuthRetry.isAuthFailure(response) {
                throw OMPOAuthError.sessionExpired("Cursor")
            }
            return response
        }

        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(authState: working) else {
                    throw CursorAuthError.tokenExpired
                }
                working.accessToken = refreshed
                return refreshed
            },
            connectionFailed: CursorUsageError.connectionFailed,
            retriedConnectionFailed: CursorUsageError.usageAfterRefreshFailed,
            authExpired: CursorAuthError.tokenExpired
        )
    }

    private func refreshAccessToken(authState: CursorAuthState) async throws -> String? {
        guard authState.source != .omp else {
            throw OMPOAuthError.readOnly
        }
        guard let refreshToken = authState.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        let response = try await usageClient.refreshToken(refreshToken)
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = ProviderParse.jsonObject(response.body)
            if body?["shouldLogout"] as? Bool == true {
                throw CursorAuthError.sessionExpired
            }
            throw CursorAuthError.tokenExpired
        }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body)
        else {
            return nil
        }
        if body["shouldLogout"] as? Bool == true {
            throw CursorAuthError.sessionExpired
        }
        guard let accessToken = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        // Fail loudly, but do NOT interpolate the error: the Cursor token is persisted via a SQL
        // statement that embeds the token, and a sqlite3 failure surfaces as stderr that could echo a
        // fragment of that statement (JWTs aren't covered by log redaction). A generic error line keeps
        // it loud without risking a token leak. The refreshed token still works for this session.
        do {
            let source = authState.source
            try await loadOffMainActor { [authStore, accessToken, source] in
                try authStore.saveAccessToken(accessToken, source: source)
            }
        } catch {
            AppLog.error(LogTag.auth("cursor"), "failed to persist rotated access token to the Cursor state DB; using it for this session only")
        }
        return accessToken
    }

    /// What `GetPlanInfo` contributes: the plan name shown beside the provider, and the same
    /// billing-cycle end the usage payload carries — read here only as the subscription row's fallback.
    /// The rest of that response (price, plan owner) is deliberately ignored.
    private struct CursorPlanInfo {
        var name: String?
        var unavailable: Bool
        var billingCycleEnd: Date?
    }

    private func fetchPlanInfo(accessToken: String) async -> CursorPlanInfo {
        guard let body = await fetchOptionalJSONObject(label: "plan", request: {
            try await self.usageClient.fetchPlan(accessToken: accessToken)
        }) else {
            return CursorPlanInfo(name: nil, unavailable: true, billingCycleEnd: nil)
        }
        let planInfo = body["planInfo"] as? [String: Any]
        let cycleEnd = CursorUsageMapper.planBillingCycleEnd(from: planInfo)
        guard let planName = (planInfo?["planName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            AppLog.warn(LogTag.plugin("cursor"), "optional plan response contained invalid plan metadata")
            return CursorPlanInfo(name: nil, unavailable: true, billingCycleEnd: cycleEnd)
        }
        return CursorPlanInfo(name: planName, unavailable: false, billingCycleEnd: cycleEnd)
    }

    private func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard let body = await fetchOptionalJSONObject(label: "credit-grants", request: {
            try await self.usageClient.fetchCredits(accessToken: accessToken)
        }) else {
            return nil
        }
        // Enterprise seats often return a body without grant fields. That is not a schema error —
        // only warn when Cursor claimed grants but the payload cannot be read.
        guard let hasCreditGrants = body["hasCreditGrants"] as? Bool else {
            if body["hasCreditGrants"] != nil {
                AppLog.warn(LogTag.plugin("cursor"), "optional credit-grants response contained invalid grant metadata")
            }
            return nil
        }
        if hasCreditGrants {
            guard let totalCents = ProviderParse.number(body["totalCents"]), totalCents > 0,
                  let usedCents = ProviderParse.number(body["usedCents"]), usedCents >= 0 else {
                AppLog.warn(LogTag.plugin("cursor"), "optional credit-grants response contained invalid grant metadata")
                return nil
            }
        }
        return body
    }

    /// The three things the already-running `auth/stripe` call tells us: the prepaid balance behind the
    /// Credits row, whether the plan is set to lapse (the subscription row's "Renews" ⟷ "Ends"), and
    /// whether the account is in payment trouble (`paymentWarning`, the header triangle).
    /// Nothing else in that response — `paymentId`, card metadata — is read, logged, or persisted.
    private struct CursorStripeAccount {
        var balanceCents: Double = 0
        var isEnding: Bool = false
        /// Header warning text when Cursor reports a failed payment; `nil` on a healthy account, which
        /// is also what a missing, failed, or unreadable `auth/stripe` response yields.
        var paymentWarning: String?
    }

    private func fetchStripeAccount(accessToken: String) async -> CursorStripeAccount {
        guard let body = await fetchOptionalJSONObject(label: "prepaid-balance", request: {
            try await self.usageClient.fetchStripeBalance(accessToken: accessToken)
        }) else {
            return CursorStripeAccount()
        }
        let isEnding = CursorUsageMapper.subscriptionIsEnding(from: body)
        // Billing trouble is worth surfacing even when the balance field is unusable, so read it before
        // the balance guard below. An absent flag is the healthy case and stays silent; a present but
        // unreadable one is loud, because it could be hiding a real payment failure.
        if let rawPaymentFailed = body["lastPaymentFailed"],
           !(rawPaymentFailed is NSNull),
           rawPaymentFailed as? Bool == nil {
            AppLog.warn(LogTag.plugin("cursor"), "optional prepaid-balance response contained invalid payment-status metadata")
        }
        let paymentWarning = CursorUsageMapper.paymentFailureWarning(from: body)
        guard ProviderParse.number(body["customerBalance"]) != nil else {
            AppLog.warn(LogTag.plugin("cursor"), "optional prepaid-balance response contained invalid balance metadata")
            return CursorStripeAccount(balanceCents: 0, isEnding: isEnding, paymentWarning: paymentWarning)
        }
        return CursorStripeAccount(
            balanceCents: CursorUsageMapper.stripeBalanceCents(from: body),
            isEnding: isEnding,
            paymentWarning: paymentWarning
        )
    }

    /// Optional endpoints enrich a usable primary snapshot; they never fail the whole provider. Keep
    /// their boundary handling in one place so transport, preparation, status, and schema failures are
    /// all visible with fixed, credential-free diagnostics.
    private func fetchOptionalJSONObject(
        label: String,
        request: () async throws -> HTTPResponse?
    ) async -> [String: Any]? {
        let response: HTTPResponse?
        do {
            response = try await request()
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request failed")
            return nil
        }
        guard let response else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request could not be prepared from the current session")
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            AppLog.warn(LogTag.plugin("cursor"), "optional \(label) response was invalid")
            return nil
        }
        return body
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        do {
            guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken),
                  (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body)
            else {
                throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
            }
            return try CursorUsageMapper.mapRequestBasedUsage(body, planName: planName, unavailableMessage: unavailableMessage)
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
    }

    private func usageSummaryAndRequestResult(
        accessToken: String,
        planName: String?,
        unavailableMessage: String
    ) async throws -> CursorMappedUsage {
        let summary = await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        })
        if let summary, !CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
            AppLog.warn(LogTag.plugin("cursor"), "optional usage-summary response contained no usable usage fields")
        }
        let requestUsage = await fetchOptionalJSONObject(label: "request-based usage", request: {
            try await self.usageClient.fetchRequestBasedUsage(accessToken: accessToken)
        })
        if let requestUsage, !CursorUsageSummaryMapper.hasUsableRequestPayload(requestUsage) {
            AppLog.warn(LogTag.plugin("cursor"), "optional request-based usage response contained no usable usage fields")
        }
        return try CursorUsageSummaryMapper.map(
            summary: summary,
            requestUsage: requestUsage,
            planName: planName,
            unavailableMessage: unavailableMessage
        )
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        CursorPlanUsageFacts(usage: usage).shouldTryGenericRequestFallback
    }

    /// `warning` is the provider header's amber triangle. Only the plan-usage path passes one: it is the
    /// only path that reads `auth/stripe`, and the request-based fallbacks would need a new request to
    /// learn the same thing.
    private func snapshot(
        _ mapped: CursorMappedUsage,
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning
        )
    }
}
