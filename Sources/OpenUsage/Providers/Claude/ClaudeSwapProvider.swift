import Foundation

/// One extra Claude card backed by a claude-swap slot: an account parked in claude-swap's stash
/// rather than signed in at `~/.claude`.
///
/// The card reads live usage the same way the active Claude card does — one `GET` to Anthropic's
/// usage endpoint — using the access token claude-swap has already stashed for that account, so a
/// stashed account shows the same meters, including Extra Usage. That read is strictly read-only.
/// OpenUsage never refreshes, rotates, or writes claude-swap's OAuth material and never builds a
/// `ClaudeAuthStore` for these cards: rotating a refresh token here would race claude-swap's own
/// rotation and strand its sign-ins. When the stashed token is expired, rejected, or unreachable, the
/// card falls back to claude-swap's own usage cache on disk (Session / Weekly / Fable percentages)
/// and says so in the log — a fallback, never a refresh.
@MainActor
final class ClaudeSwapProvider: ProviderRuntime {
    let provider: Provider
    let card: ClaudeSwapCard
    let usageClient: ClaudeSwapUsageClient
    let credentialReader: ClaudeSwapCredentialReader
    let liveUsageClient: ClaudeUsageClient
    let files: TextFileAccessing
    let now: @Sendable () -> Date

    /// The last thing each tier logged about its own state. A card parked in the no-data, fallen-back,
    /// or poll-failed state would otherwise write the same line on every refresh tick for as long as it
    /// stayed there, so only a change is worth recording. The tiers keep separate slots so a card that
    /// is steadily serving the cache doesn't re-log both lines on alternating ticks.
    private var lastLoggedLiveState: String?
    private var lastLoggedCacheState: String?

    /// A rate-limit cooldown, carried across refreshes (one provider instance lives per stashed card,
    /// for as long as the app runs). Anthropic's usage endpoint throttles aggressively, and these cards
    /// multiply the traffic by however many accounts claude-swap is holding — so a 429 parks this card's
    /// live tier, honouring `Retry-After`, and the card serves claude-swap's cached usage until the
    /// cooldown expires rather than re-sending a request that is already being refused. Mirrors the
    /// active Claude card's `rateLimitedUntil`.
    private var liveRateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    /// When a refused Keychain read stops being retried until. Reading claude-swap's item can put a
    /// macOS access prompt on screen, and clicking *Deny* answers that one prompt only — it doesn't
    /// amend the item's ACL — so retrying on every background tick would put the same dialog back in
    /// front of the user every few minutes, once per stashed card. After a refusal the card waits an
    /// hour before asking again, and a manual refresh clears the wait outright: asking again is exactly
    /// what the troubleshooting docs tell the user a manual refresh is for.
    private var keychainRefusedUntil: Date?
    private static let keychainRefusalCooldown: TimeInterval = 60 * 60

    init(
        card: ClaudeSwapCard,
        usageClient: ClaudeSwapUsageClient = ClaudeSwapUsageClient(),
        credentialReader: ClaudeSwapCredentialReader = ClaudeSwapCredentialReader(),
        liveUsageClient: ClaudeUsageClient = ClaudeUsageClient(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName)
        self.card = card
        self.usageClient = usageClient
        self.credentialReader = credentialReader
        self.liveUsageClient = liveUsageClient
        self.files = files
        self.now = now
    }

    /// The Claude card's API-derived meters, so `DefaultLayout`'s claude rows and pins translate onto
    /// this card unchanged. There is no Usage Trend or spend tile: those come from local Claude Code
    /// session logs, which belong to whichever account is active in `~/.claude`, not to a stashed one.
    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session",
                     sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent"),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent"),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage",
                            metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars))
        ]
    }

    /// Probe only: the slot's config snapshot is still in claude-swap's stash. Deliberately a plain
    /// file check — first-run detection must never reach for the Keychain, which would put another
    /// app's access prompt in front of a user who hasn't even seen the dashboard yet.
    func hasLocalCredentials() async -> Bool {
        let path = card.configPath
        return await loadOffMainActor { [files] in files.exists(path) }
    }

    func refresh() async -> ProviderSnapshot {
        if let live = await liveSnapshot() { return live }
        return await cachedSnapshot()
    }

    // MARK: - Live tier

    /// Live usage for the stashed account: claude-swap's access token, spent read-only against the
    /// same endpoint and read by the same mapper the active Claude card uses — which is what gives a
    /// stashed account its Extra Usage and per-model weekly rows.
    ///
    /// `nil` means "serve the cache tier instead", and it is the answer to every unhappy path: no
    /// email to name the stash by, no stashed item, an expired token, a Keychain that wouldn't open, a
    /// rejected token, an unreachable API. The answer that is never given is a refresh.
    private func liveSnapshot() async -> ProviderSnapshot? {
        // Inside an active cooldown the live tier is skipped entirely — no request, and no Keychain
        // read to prompt for either. Piling more requests onto an endpoint that is already limiting us
        // only extends the limit, and there is nothing to gain: the answer would be another 429.
        if let until = liveRateLimitedUntil, now() < until { return nil }
        guard let stashed = await stashedToken() else { return nil }

        let response: HTTPResponse
        do {
            response = try await liveUsageClient.fetchUsage(
                accessToken: stashed.accessToken, config: ClaudeSwapOAuth.readOnlyConfig
            )
        } catch {
            logLive("couldn't reach Anthropic for live usage; showing claude-swap's cached usage", level: .warn)
            return nil
        }

        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            liveRateLimitedUntil = now().addingTimeInterval(
                TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown))
            )
            logLive("Anthropic is rate limiting this account; showing claude-swap's cached usage", level: .warn)
            return nil
        }

        do {
            let mapped = try ClaudeUsageMapper.mapUsageResponse(
                response, credentials: ClaudeOAuth(), now: now()
            )
            liveRateLimitedUntil = nil
            guard !mapped.lines.isEmpty else {
                logLive("Anthropic reported no usage windows; showing claude-swap's cached usage", level: .warn)
                return nil
            }
            logLive(nil, level: .info)
            return ProviderSnapshot.make(
                provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now(),
                warning: mapped.warning
            )
        } catch ClaudeAuthError.tokenExpired {
            // A rejected token is the one case where the obvious remedy is forbidden: refreshing it
            // would rotate claude-swap's refresh token and strand its own sign-ins. So the card falls
            // back to claude-swap's cached percentages and says loudly why, which is what makes a
            // genuinely dead login visible instead of silently stale.
            logLive(
                "claude-swap's stashed token was rejected. OpenUsage never refreshes it — run `cswap` "
                + "to re-authenticate this account. Showing claude-swap's cached usage.",
                level: .warn
            )
            return nil
        } catch {
            logLive("live usage failed (\(error.localizedDescription)); showing claude-swap's cached usage", level: .warn)
            return nil
        }
    }

    /// claude-swap's stashed access token for this slot, when there is a fresh one to spend. Every
    /// other outcome logs its reason and reads as "no live tier" — bar one: while a refused Keychain
    /// read is still in its cooldown the read is skipped silently, the warning it already wrote being
    /// the standing explanation.
    private func stashedToken() async -> ClaudeSwapStashedToken? {
        guard let email = card.email?.nilIfEmpty else {
            logLive("the slot's snapshot names no email, so its stashed login can't be located", level: .info)
            return nil
        }
        if ProviderRefreshContext.isManual {
            keychainRefusedUntil = nil
        } else if let until = keychainRefusedUntil, now() < until {
            return nil
        }
        let slot = card.slot
        let stashed: ClaudeSwapStashedToken?
        do {
            stashed = try await loadOffMainActor { [credentialReader] in
                try credentialReader.stashedToken(slot: slot, email: email)
            }
        } catch {
            // A refusal, not an absence: the Keychain was there and said no (locked, denied, or a
            // cancelled prompt). Stop asking for a while so the dialog doesn't keep reappearing.
            keychainRefusedUntil = now().addingTimeInterval(Self.keychainRefusalCooldown)
            logLive(
                "couldn't read claude-swap's stashed login (\(error.localizedDescription)); "
                + "showing its cached usage",
                level: .warn
            )
            return nil
        }
        guard let stashed else {
            logLive("claude-swap has no stashed login for this slot; showing its cached usage", level: .info)
            return nil
        }
        guard stashed.isFresh(now: now()) else {
            // Not an error: claude-swap renews its own tokens, so an expired one usually just means we
            // looked between two of its refreshes. Waiting costs a few stale minutes; refreshing it
            // ourselves would cost claude-swap its refresh token.
            logLive(
                "claude-swap's stashed token has expired; showing its cached usage until claude-swap renews it",
                level: .info
            )
            return nil
        }
        return stashed
    }

    // MARK: - Cache tier

    /// The fallback: the row claude-swap last wrote for this slot in its own usage cache. Session,
    /// Weekly, and Fable percentages only — claude-swap doesn't record Extra Usage — and subject to
    /// its own freshness and poll-failure rules.
    private func cachedSnapshot() async -> ProviderSnapshot {
        let slot = card.slot
        let entry: ClaudeSwapUsageEntry?
        do {
            entry = try await loadOffMainActor { [usageClient] in try usageClient.entry(slot: slot) }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        switch ClaudeSwapUsageMapper.map(
            entry,
            expectedOrganizationUUID: card.organizationID,
            expectedEmail: card.email,
            now: now()
        ) {
        case .usage(let lines, let warning):
            logCache(warning.map { "serving claude-swap's last-good usage — \($0)" }, level: .warn)
            return ProviderSnapshot.make(
                provider: provider, plan: nil, lines: lines, refreshedAt: now(), warning: warning
            )
        case .noData(let reason):
            logCache("no usage to show — \(reason)", level: .info)
            var lines: [MetricLine] = []
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        case .failure(let error):
            // The error snapshot is the loud signal here; tracking it still keeps a later transition
            // back into no-data from being swallowed as "unchanged".
            lastLoggedCacheState = "failure: \(error.localizedDescription)"
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    // MARK: - Logging

    private enum LogLevel { case warn, info }

    /// Record `message` only when it differs from what this tier last said about itself. `nil` is the
    /// healthy state — nothing to log, but still a change worth remembering.
    private func logLive(_ message: String?, level: LogLevel) {
        guard lastLoggedLiveState != message else { return }
        lastLoggedLiveState = message
        emit(message, level: level)
    }

    private func logCache(_ message: String?, level: LogLevel) {
        guard lastLoggedCacheState != message else { return }
        lastLoggedCacheState = message
        emit(message, level: level)
    }

    private func emit(_ message: String?, level: LogLevel) {
        guard let message else { return }
        switch level {
        case .warn: AppLog.warn(LogTag.plugin("claude"), "\(provider.id): \(message)")
        case .info: AppLog.info(LogTag.plugin("claude"), "\(provider.id): \(message)")
        }
    }
}
