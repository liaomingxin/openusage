import Foundation

@MainActor
final class ZAIProvider: ProviderRuntime {
    let authStore: ZAIAuthStore
    let usageClient: ZAIUsageClient
    let piScanner: PiUsageScanner
    let openCodeSubscriptionScanner: OpenCodeSubscriptionUsageScanner
    let zcodeScanner: ZCodeUsageScanner
    let hermesScanner: HermesUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date

    /// The console this account lives on, read from the key file at launch and re-read on every
    /// refresh so a change in Settings takes effect on the next pass. Drives the API host, the two
    /// quick links, and the console URLs the error messages name.
    private(set) var platform: ZAIPlatform

    init(
        authStore: ZAIAuthStore = ZAIAuthStore(),
        usageClient: ZAIUsageClient = ZAIUsageClient(),
        piScanner: PiUsageScanner = .shared,
        openCodeSubscriptionScanner: OpenCodeSubscriptionUsageScanner = OpenCodeSubscriptionUsageScanner(),
        zcodeScanner: ZCodeUsageScanner = ZCodeUsageScanner(),
        hermesScanner: HermesUsageScanner = HermesUsageScanner(),
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.piScanner = piScanner
        self.openCodeSubscriptionScanner = openCodeSubscriptionScanner
        self.zcodeScanner = zcodeScanner
        self.hermesScanner = hermesScanner
        self.pricing = pricing
        self.now = now
        self.platform = authStore.loadPlatform()
    }

    var provider: Provider {
        Provider(
            id: "zai",
            displayName: "Z.ai",
            icon: .providerMark("zai"),
            links: platform.links
        )
    }

    var widgetDescriptors: [WidgetDescriptor] {
        let provider = provider
        return [
            .percent(id: "zai.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                          metricLabel: "Web Searches", limit: 1000, suffix: "searches",
                          periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
                .exportingLimit("webSearches", unit: "searches"),
            // The usage-history rows, fed by the model-usage / tool-usage endpoints. The trend sits
            // with the meters above the fold; the period rows and MCP Tools are seeded On Demand in
            // `DefaultLayout`, matching every other provider's spend history.
            .usageTrend(provider: provider)
                .exportingHistory(
                    // Z.ai reports this history per account, not per Mac, so it is never merged across
                    // devices or written to the iCloud sync file — the same classification Cursor's
                    // API-derived history carries.
                    scope: .accountWide,
                    estimatedCost: false,
                    sourceNote: ZAIActivityMapper.sourceNote(for: platform)
                ),
            .combined(id: "zai.today", provider: provider, title: "Today", isUsagePeriod: true),
            .combined(id: "zai.yesterday", provider: provider, title: "Yesterday", isUsagePeriod: true),
            .combined(id: "zai.last30", provider: provider, title: "Last 30 Days", isUsagePeriod: true),
            // MCP Tools is a window accumulation like the period rows above (`isUsagePeriod`), so its
            // value reveals the per-tool hover breakdown and an all-zero window reads as "no usage"
            // rather than a depleted balance.
            .values(id: "zai.mcpTools", provider: provider, title: "MCP Tools", metricLabel: "MCP Tools",
                    selection: .kind(.count), isUsagePeriod: true),
            // Account metadata rather than usage, so it sits last (and On Demand by default).
            .subscriptionRenewal(provider: provider)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported API key.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.missingKey)
        }
        // Adopt the key file's platform for this pass, so switching it in Settings moves every request
        // (and the quick links) without a relaunch.
        platform = auth.platform
        let provider = provider

        // The quota endpoint is required. Everything else is best-effort — the plan name and renewal
        // row, the usage history behind the trend and period rows, and the MCP tool counts — so a
        // failure there logs and leaves those rows absent without blanking the meters.
        let quota = await load { try await usageClient.fetchQuota(apiKey: auth.apiKey, platform: auth.platform) }

        switch quota {
        case .success(let body):
            // A valid key whose account has no GLM Coding Plan gets a 2xx with `success:false`. Surface
            // that as a clear provider warning (the header's amber notice) rather than three blank "No
            // data" meters that don't explain why nothing's there.
            if ZAIUsageMapper.isNoCodingPlan(body) {
                return ProviderSnapshot.error(provider: provider, error: ZAIUsageError.noCodingPlan(auth.platform))
            }
            let subscription = await loadOptional("subscription") {
                try await usageClient.fetchSubscription(apiKey: auth.apiKey, platform: auth.platform)
            }
            // Credit-metered plans read their history from the credit-usage endpoints; token plans
            // keep the legacy pair. See `loadActivity`.
            let credit = ZAIUsageMapper.isCreditPackage(body)
            let activity = await loadActivity(auth: auth, credit: credit)
            do {
                var mapped = try ZAIUsageMapper.map(
                    quotaBody: body,
                    subscriptionBody: subscription,
                    activityLines: ZAIActivityMapper.lines(
                        window: activity.window,
                        recent: activity.recent,
                        tools: activity.tools,
                        platform: auth.platform,
                        now: now()
                    )
                )
                let priced = await pricing()
                let piScan = await piScanner.scan(cardID: "zai", now: now(), pricing: priced)
                let openCodeScan = await openCodeSubscriptionScanner.scan(now: now(), pricing: priced).thisMac["zai"]
                let zcodeScan = await zcodeScanner.scan(now: now(), pricing: priced)
                let hermesScan = await hermesScanner.officialZAIScan(now: now(), pricing: priced)
                let thisMac = DailyUsageAccumulator.merged([piScan, openCodeScan, zcodeScan, hermesScan])
                Self.attachThisMac(thisMac, now: now(), to: &mapped.lines)
                return ProviderSnapshot.make(
                    provider: provider,
                    plan: mapped.plan,
                    lines: mapped.lines,
                    refreshedAt: now(),
                    usageHistory: Self.usageHistory(server: activity.window, thisMac: thisMac)
                )
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.invalidKey(auth.platform))
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Server history stays the headline. Pi's Z.ai rows hang off `thisMac` and must not change
    /// `series`, which is what the spend tiles and Total Spend already rendered.
    private static func attachThisMac(_ scan: LogUsageScan?, now: Date, to lines: inout [MetricLine]) {
        guard let scan else { return }
        let today = DailyUsageAccumulator.dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)
            .map { DailyUsageAccumulator.dayKey(from: $0) }
        lines = lines.map { line in
            guard case .values(let label, let values, let color, let expiries, let unknown, var breakdown) = line
            else { return line }
            let days: Set<String>
            switch label {
            case "Today": days = [today]
            case "Yesterday": days = Set([yesterday].compactMap { $0 })
            case "Last 30 Days": days = Set(scan.series.daily.map(\.date))
            default: return line
            }
            let models = (scan.modelUsage?.daily ?? []).filter { days.contains($0.date) }.flatMap(\.models)
            guard !models.isEmpty else { return line }
            if breakdown == nil {
                breakdown = ModelUsageBreakdown(
                    totalTokens: Int(values.first { $0.label == "tokens" }?.number ?? 0),
                    totalCostUSD: nil, models: [], sourceNote: "From Z.ai"
                )
            }
            breakdown?.thisMacModels = models
            breakdown?.thisMacSourceNote = "This Mac"
            return .values(
                label: label, values: values, colorHex: color, expiriesAt: expiries,
                unknownModels: unknown, modelBreakdown: breakdown
            )
        }
    }

    private static func usageHistory(server: ZAIModelActivity?, thisMac: LogUsageScan?) -> ProviderUsageHistory? {
        if let server {
            return ProviderUsageHistory(
                series: server.series,
                modelUsage: server.modelUsage,
                thisMacSeries: thisMac?.series,
                thisMacModelUsage: thisMac?.modelUsage
            )
        }
        guard let thisMac else { return nil }
        return ProviderUsageHistory(
            series: DailyUsageSeries(daily: []),
            thisMacSeries: thisMac.series,
            thisMacModelUsage: thisMac.modelUsage
        )
    }

    /// The usage-history payloads behind the trend, the day rows and MCP Tools, on whichever endpoint
    /// family the plan meters with.
    ///
    /// The legacy path makes two `model-usage` calls, not one: Z.ai returns hourly buckets only for
    /// ranges up to seven days and whole (Beijing) days for anything longer, and only hourly buckets
    /// can be attributed to the Mac's own calendar days. So the 30-day call feeds the trend and the
    /// Last 30 Days total, while a short call feeds Today and Yesterday; `tool-usage` feeds MCP Tools.
    /// Each call is independent: one failing leaves only its own rows empty.
    ///
    /// The credit path mirrors the split with the endpoint family Z.ai's own page reads for
    /// credit-metered plans: `activity` (the account-wide totals behind the trend and Last 30 Days),
    /// `usage-detail` MODEL in both ranges (per-model breakdowns, plus the hourly short call behind
    /// Today / Yesterday), and `usage-detail` MCP (the tool counts). See `ZAICreditUsageMapper`.
    private func loadActivity(
        auth: ZAIAuth,
        credit: Bool
    ) async -> (window: ZAIModelActivity?, recent: ZAIModelActivity?, tools: ZAIToolActivity?) {
        if credit { return await loadCreditActivity(auth: auth) }
        let now = now()
        let window = await loadOptional("model-usage (30 days)") {
            try await usageClient.fetchModelUsage(
                apiKey: auth.apiKey, platform: auth.platform,
                start: ZAIActivityMapper.trendWindowStart(now: now), end: now
            )
        }.flatMap { ZAIActivityMapper.parseModelUsage($0) }
        let recent = await loadOptional("model-usage (recent days)") {
            try await usageClient.fetchModelUsage(
                apiKey: auth.apiKey, platform: auth.platform,
                start: ZAIActivityMapper.recentWindowStart(now: now), end: now
            )
        }.flatMap { ZAIActivityMapper.parseModelUsage($0) }
        let tools = await loadOptional("tool-usage") {
            try await usageClient.fetchToolUsage(
                apiKey: auth.apiKey, platform: auth.platform,
                start: ZAIActivityMapper.trendWindowStart(now: now), end: now
            )
        }.flatMap { ZAIActivityMapper.parseToolUsage($0) }
        return (window, recent, tools)
    }

    /// The credit-plan history. Four best-effort calls, each independent: the 30-day `activity`
    /// totals and the 30-day `usage-detail` model split merge into one window (the totals are the
    /// row values, the split is the hover breakdown); the short-range `usage-detail` call carries
    /// Today / Yesterday; the MCP detail carries the tool row.
    private func loadCreditActivity(
        auth: ZAIAuth
    ) async -> (window: ZAIModelActivity?, recent: ZAIModelActivity?, tools: ZAIToolActivity?) {
        let now = now()
        let trendStart = ZAIActivityMapper.trendWindowStart(now: now)
        let totals = await loadOptional("credit-usage/activity (30 days)") {
            try await usageClient.fetchCreditActivity(
                apiKey: auth.apiKey, platform: auth.platform, start: trendStart, end: now
            )
        }.flatMap { ZAICreditUsageMapper.parseActivity($0) }
        let breakdown = await loadOptional("credit-usage/usage-detail (30 days, models)") {
            try await usageClient.fetchCreditUsageDetail(
                apiKey: auth.apiKey, platform: auth.platform, start: trendStart, end: now, kind: .model
            )
        }.flatMap { ZAICreditUsageMapper.parseModelDetail($0) }
        let recent = await loadOptional("credit-usage/usage-detail (recent days, models)") {
            try await usageClient.fetchCreditUsageDetail(
                apiKey: auth.apiKey, platform: auth.platform,
                start: ZAIActivityMapper.recentWindowStart(now: now), end: now, kind: .model
            )
        }.flatMap { ZAICreditUsageMapper.parseModelDetail($0) }
        let tools = await loadOptional("credit-usage/usage-detail (30 days, MCP)") {
            try await usageClient.fetchCreditUsageDetail(
                apiKey: auth.apiKey, platform: auth.platform, start: trendStart, end: now, kind: .mcp
            )
        }.flatMap { ZAICreditUsageMapper.parseMcpDetail($0) }
        return (ZAICreditUsageMapper.window(totals: totals, breakdown: breakdown), recent, tools)
    }

    /// Run the required quota call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx, transport error, or empty body.
    private func load(_ call: () async throws -> HTTPResponse) async -> QuotaResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run one of the supplementary calls — never throws into the snapshot: a transport error, a
    /// non-2xx, or an auth failure all just mean "those rows are absent this refresh". The reason is
    /// logged under `endpoint` so a persistently failing endpoint is visible instead of silent.
    private func loadOptional(
        _ endpoint: String,
        _ call: () async throws -> HTTPResponse
    ) async -> Data? {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else {
                AppLog.warn(LogTag.plugin("zai"), "\(endpoint) returned HTTP \(response.statusCode); its rows stay empty")
                return nil
            }
            return response.body
        } catch {
            AppLog.warn(LogTag.plugin("zai"), "\(endpoint) fetch failed; its rows stay empty: \(error.localizedDescription)")
            return nil
        }
    }
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

extension ZAIProvider: ProviderPlatformSelecting {
    var platformOptions: [ProviderPlatformOption] {
        ZAIPlatform.allCases.map {
            ProviderPlatformOption(id: $0.rawValue, title: $0.displayName, host: $0.apiHost)
        }
    }

    var selectedPlatformID: String { authStore.loadPlatform().rawValue }

    func selectPlatform(_ id: String) throws {
        guard let chosen = ZAIPlatform(rawValue: id) else { throw ZAIAuthError.saveFailed }
        try authStore.savePlatform(chosen)
        platform = chosen
    }
}

private enum QuotaResult {
    case success(Data)
    case authFailure
    case failed(ZAIUsageError)
}
