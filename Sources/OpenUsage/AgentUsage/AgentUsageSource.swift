import Foundation

/// One local agent the Agent Usage screen aggregates. Each adapter wraps an existing per-provider
/// log scanner with a fresh machine-wide instance (the provider cards scan account- or card-scoped
/// slices of the same logs, so the shared incremental parse caches make this cheap) or — for
/// network-backed sources with no local logs — the provider's last refreshed snapshot.
struct AgentUsageSource: Sendable {
    var id: String
    var displayName: String
    var icon: IconSource
    /// Runs the agent's scan. Returns nil when the tool isn't installed or has no logs at all;
    /// a scan that found logs but no window usage yields an empty `LogUsageScan`.
    var scan: @Sendable (ModelPricing) async -> LogUsageScan?
}

/// The agents the screen lists, in display order: the CLI/coding agents with local logs first,
/// then the network-backed ones reading their refreshed snapshots. The screen itself re-sorts by
/// spend per window; this order is the tiebreak for agents with equal (e.g. zero-cost) usage and
/// the stable base so the list never reorders while reading it.
enum AgentUsageCatalog {
    static func make(cursorSnapshot: @escaping @Sendable () -> ProviderSnapshot?) -> [AgentUsageSource] {
        [
            AgentUsageSource(id: "claude-code", displayName: "Claude Code", icon: .providerMark("claude")) { pricing in
                await ClaudeLogUsageScanner().scan(daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "codex", displayName: "Codex", icon: .providerMark("codex")) { pricing in
                await CodexLogUsageScanner().scan(daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "pi", displayName: "Pi", icon: .providerMark("pi")) { pricing in
                await PiUsageScanner.shared.scanAll(root: .pi, daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "omp", displayName: "omp", icon: .providerMark("grok")) { pricing in
                // omp is a pi-family agent (~/.omp/agent/sessions, same usage jsonl) — its own row on
                // this screen, while its provider usage folds into cards through the shared scanner.
                await PiUsageScanner.shared.scanAll(root: .omp, daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode")) { pricing in
                let now = Date()
                let hosted = try? await OpenCodeUsageScanner().scan(now: now, daysBack: 30)?.logScan
                let codex = await OpenCodeCodexUsageScanner().scan(now: now, daysBack: 30, pricing: pricing)
                let sub = await OpenCodeSubscriptionUsageScanner().scan(now: now, daysBack: 30, pricing: pricing)
                return DailyUsageAccumulator.merged(
                    [hosted, codex] + Array(sub.localSpend.values) + Array(sub.thisMac.values)
                )
            },
            AgentUsageSource(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity")) { pricing in
                await AntigravityDbUsageScanner().scan(daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "grok", displayName: "Grok", icon: .providerMark("grok")) { pricing in
                await GrokLogUsageScanner().scan(daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "zcode", displayName: "ZCode", icon: .providerMark("zai")) { pricing in
                await ZCodeUsageScanner().scan(now: Date(), daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "kimi-cli", displayName: "Kimi CLI", icon: .providerMark("kimi")) { pricing in
                KimiCLIUsageScanner().scan(now: Date(), daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "muse", displayName: "Muse Code", icon: .providerMark("muse")) { pricing in
                MuseCLIUsageScanner().scan(now: Date(), daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes")) { pricing in
                await HermesUsageScanner().scan(daysBack: 30, pricing: pricing)
            },
            AgentUsageSource(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor")) { _ in
                // Cursor's usage CSV comes from its API, not local logs, so the screen reads the
                // provider card's last refreshed history instead of scanning anything.
                cursorSnapshot().flatMap { snapshot in
                    snapshot.usageHistory.map { history in
                        LogUsageScan(
                            series: history.series,
                            modelUsage: history.modelUsage,
                            unknownModelsByDay: history.unknownModelsByDay
                        )
                    }
                }
            },
        ]
    }
}
