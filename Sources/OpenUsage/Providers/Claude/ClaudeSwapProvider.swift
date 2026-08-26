import Foundation

/// One extra Claude card backed by a claude-swap slot. Everything it shows comes from claude-swap's
/// own stash on disk — the config snapshot names the account, the usage cache holds the numbers — so a
/// refresh is a file read, never a network call and never a token touch. claude-swap's OAuth material
/// (Keychain service `claude-swap`) is deliberately out of reach: refreshing it here would race
/// claude-swap's own rotation and strand its refresh tokens.
@MainActor
final class ClaudeSwapProvider: ProviderRuntime {
    let provider: Provider
    let card: ClaudeSwapCard
    let usageClient: ClaudeSwapUsageClient
    let files: TextFileAccessing
    let now: @Sendable () -> Date

    init(
        card: ClaudeSwapCard,
        usageClient: ClaudeSwapUsageClient = ClaudeSwapUsageClient(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName)
        self.card = card
        self.usageClient = usageClient
        self.files = files
        self.now = now
    }

    /// The same three quota meters the Claude card leads with, so `DefaultLayout`'s claude rows and
    /// pins translate onto this card unchanged. There is no Usage Trend or spend tile: those come from
    /// local Claude Code logs, which belong to whichever account is active in `~/.claude`, not to a
    /// stashed one.
    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session",
                     sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent")
        ]
    }

    /// Probe only: the slot's config snapshot is still in claude-swap's stash. No token is read.
    func hasLocalCredentials() async -> Bool {
        let path = card.configPath
        return await loadOffMainActor { [files] in files.exists(path) }
    }

    func refresh() async -> ProviderSnapshot {
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
            if let warning {
                AppLog.warn(LogTag.plugin("claude"), "\(provider.id): serving claude-swap's last-good usage — \(warning)")
            }
            return ProviderSnapshot.make(
                provider: provider, plan: nil, lines: lines, refreshedAt: now(), warning: warning
            )
        case .noData(let reason):
            AppLog.info(LogTag.plugin("claude"), "\(provider.id): no usage to show — \(reason)")
            var lines: [MetricLine] = []
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        case .failure(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
