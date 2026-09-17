import Foundation

/// Turns one machine-wide 30-day scan per agent into the per-window reports the Agent Usage screen
/// renders. All four windows derive from the same scan results, so switching windows is instant.
enum AgentUsageAggregator {
    /// The scan result one agent produced, paired with its identity for the report.
    struct SourceResult: Sendable {
        var source: AgentUsageSource
        var scan: LogUsageScan?
    }

    /// Builds every window's report from one set of scan results.
    static func reports(
        from results: [SourceResult], now: Date = Date(), calendar: Calendar = .current
    ) -> [AgentUsageWindow: AgentUsageReport] {
        var reports: [AgentUsageWindow: AgentUsageReport] = [:]
        for window in AgentUsageWindow.allCases {
            reports[window] = report(window: window, from: results, now: now, calendar: calendar)
        }
        return reports
    }

    /// One window's report: per agent, the window's day-filtered per-model sums.
    static func report(
        window: AgentUsageWindow, from results: [SourceResult],
        now: Date = Date(), calendar: Calendar = .current
    ) -> AgentUsageReport {
        let dayKeys = window.dayKeys(now: now, calendar: calendar)
        var agents: [AgentUsageSummary] = []
        agents.reserveCapacity(results.count)

        for result in results {
            guard let scan = result.scan else { continue }
            var models: [String: (tokens: Int, cost: Double)] = [:]
            for daily in scan.modelUsage?.daily ?? [] where dayKeys.contains(daily.date) {
                for model in daily.models {
                    let bucket = models[model.model] ?? (0, 0)
                    models[model.model] = (
                        bucket.tokens + model.totalTokens,
                        bucket.cost + (model.costUSD ?? 0)
                    )
                }
            }
            // The scanners already excluded unpriced usage from the daily model rows; the names
            // surface here as the section's amber warning, scoped to this window's days.
            let unpriced = Set(
                scan.unknownModelsByDay
                    .filter { dayKeys.contains($0.key) }
                    .flatMap(\.value)
            ).sorted()

            guard !models.isEmpty || !unpriced.isEmpty else { continue }

            let rows = models
                .map { model, totals in
                    AgentModelUsage(model: model, totalTokens: totals.tokens, costUSD: totals.cost)
                }
                .sorted { lhs, rhs in
                    let lhsCost = lhs.costUSD ?? 0
                    let rhsCost = rhs.costUSD ?? 0
                    if lhsCost != rhsCost { return lhsCost > rhsCost }
                    if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                    return lhs.model < rhs.model
                }
            agents.append(AgentUsageSummary(
                agentID: result.source.id,
                displayName: result.source.displayName,
                icon: result.source.icon,
                models: rows,
                totalTokens: rows.reduce(0) { $0 + $1.totalTokens },
                totalCostUSD: rows.reduce(0) { $0 + ($1.costUSD ?? 0) },
                unpricedModels: unpriced
            ))
        }

        agents.sort { lhs, rhs in
            if lhs.totalCostUSD != rhs.totalCostUSD { return lhs.totalCostUSD > rhs.totalCostUSD }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.displayName < rhs.displayName
        }
        return AgentUsageReport(window: window, agents: agents, generatedAt: now)
    }
}
