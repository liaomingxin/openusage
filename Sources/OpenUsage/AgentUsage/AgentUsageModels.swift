import Foundation

/// The selectable time window on the Agent Usage screen. Each window is a set of local calendar
/// days, so switching windows never re-scans: one 30-day scan backs all four reports.
enum AgentUsageWindow: String, CaseIterable, Sendable, Identifiable {
    case today
    case yesterday
    case last7Days
    case last30Days

    var id: String { rawValue }

    /// Where the picker's selection persists across popover closes and relaunches.
    static let storageKey = "agentUsage.window"

    /// The short label the window picker shows (title case, matching the period picker's tone).
    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last7Days: "7 Days"
        case .last30Days: "30 Days"
        }
    }

    /// Calendar-day offsets from today that belong to the window: today is `0`, yesterday `1`,
    /// "7 Days" is today plus the previous six, "30 Days" today plus the previous twenty-nine.
    var includedDayOffsets: Range<Int> {
        switch self {
        case .today: 0..<1
        case .yesterday: 1..<2
        case .last7Days: 0..<7
        case .last30Days: 0..<30
        }
    }

    /// The window's `yyyy-MM-dd` day keys (the same keys `DailyUsageAccumulator` buckets by).
    func dayKeys(now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set(includedDayOffsets.compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
        })
    }
}

/// One model's usage inside an agent's window report.
struct AgentModelUsage: Hashable, Sendable, Identifiable {
    var model: String
    var totalTokens: Int
    var costUSD: Double?

    var id: String { model }
}

/// One local agent's usage inside a window: the per-model rows plus the totals the section header
/// shows. Agents with no priced usage in the window are omitted from the report entirely.
struct AgentUsageSummary: Hashable, Sendable, Identifiable {
    var agentID: String
    var displayName: String
    var icon: IconSource
    /// Priced model rows, sorted by cost (desc), then tokens (desc), then name.
    var models: [AgentModelUsage]
    var totalTokens: Int
    var totalCostUSD: Double
    /// Models the scanners excluded from every total because no pricing source knows them. They
    /// surface as the section's amber warning instead — never silently folded into "Unattributed".
    var unpricedModels: [String]

    var id: String { agentID }
}

/// All agents' usage for one window, ready for the screen to render.
struct AgentUsageReport: Sendable {
    var window: AgentUsageWindow
    /// Agents sorted by window cost (desc), then tokens (desc), then display name.
    var agents: [AgentUsageSummary]
    var generatedAt: Date

    var totalCostUSD: Double { agents.reduce(0) { $0 + $1.totalCostUSD } }
    var totalTokens: Int { agents.reduce(0) { $0 + $1.totalTokens } }
}
