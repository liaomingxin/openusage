import Foundation

/// Turns `CodexAccountStats` into the four account-wide rows: Account Trend, Lifetime Tokens,
/// Day Streak and Threads.
///
/// These sit *beside* Codex's machine-local Usage Trend and spend tiles, never inside them. The labels
/// here are deliberately distinct from the shared history labels ("Usage Trend", "Today", "Yesterday",
/// "Last 30 Days") so the cross-Mac history renderer, which owns those four labels, can never rewrite
/// or drop an account-wide row — and so an account-wide token count can never land in a dollar tile.
enum CodexAccountStatsMapper {
    static let trendLabel = "Account Trend"
    static let lifetimeTokensLabel = "Lifetime Tokens"
    static let dayStreakLabel = "Day Streak"
    static let threadsLabel = "Threads"

    /// Every renderable account row, in descriptor order. An absent field yields no row (it reads
    /// "No data") rather than a fabricated zero.
    static func lines(stats: CodexAccountStats, now: Date, calendar: Calendar = .current) -> [MetricLine] {
        guard !stats.isEmpty else { return [] }
        return [
            trendLine(stats: stats, now: now, calendar: calendar),
            countLine(label: lifetimeTokensLabel, count: stats.lifetimeTokens, unit: "tokens"),
            countLine(label: dayStreakLabel, count: stats.currentStreakDays, unit: "days"),
            countLine(label: threadsLabel, count: stats.totalThreads, unit: "threads")
        ].compactMap { $0 }
    }

    /// What these rows are and why they lag: OpenAI's own account-wide rollup, recomputed once a day,
    /// so the newest day it can show is normally yesterday.
    static func sourceNote(countedThrough day: Date) -> String {
        "Across your whole OpenAI account · counted through \(Formatters.monthDayLabel(day)) (updated daily)"
    }

    /// The account-wide token chart: one bar per calendar day across the days the rollup actually
    /// covers, inside the app's usual 31-day window.
    ///
    /// Both ends of the range are clamped to what OpenAI counted, which is what keeps the row honest:
    ///
    /// - It **stops at `statsAsOf`**, so today (and anything else the batch hasn't counted yet) draws
    ///   no bar at all instead of an empty one that would read as "you used nothing today".
    /// - It **starts no earlier than the first day the rollup reports**, so an account younger than the
    ///   window doesn't get empty bars for days it didn't exist.
    ///
    /// Between those two days a missing bucket is a real zero — the rollup covered that day and found
    /// no usage — so idle days are zero-filled in place rather than dropped. Dropping them would
    /// collapse two non-adjacent days into neighbors and make the sparkline lie about the calendar,
    /// the same reasoning the local trend uses.
    ///
    /// Returns `nil` when the rollup names no covered day, when its window falls entirely outside ours,
    /// or when every covered day is idle — all cases where the row should read "No data" rather than
    /// draw a flat axis.
    private static func trendLine(stats: CodexAccountStats, now: Date, calendar: Calendar) -> MetricLine? {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -UsageHistoryWindow.previousDays, to: today),
              let countedThrough = stats.statsAsOf.flatMap({ startOfDay($0, calendar: calendar) })
        else {
            return nil
        }
        let end = min(countedThrough, today)
        let firstReported = stats.tokensByDay.keys.min().flatMap { startOfDay($0, calendar: calendar) }
        let start = max(windowStart, firstReported ?? windowStart)
        guard start <= end else { return nil }

        var points: [MetricChartPoint] = []
        var day = start
        while day <= end {
            let tokens = Double(stats.tokensByDay[DailyUsageAccumulator.dayKey(from: day, calendar: calendar)] ?? 0)
            points.append(MetricChartPoint(
                value: tokens,
                label: Formatters.monthDayLabel(day),
                valueLabel: MetricFormatter.number(tokens, kind: .count, style: .row) + " tokens"
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard points.contains(where: { $0.value > 0 }) else { return nil }
        return .chart(label: trendLabel, points: points, note: sourceNote(countedThrough: end))
    }

    /// One measured count as its own row. Zero is kept — an account with no threads yet really has
    /// none — while an absent field yields no row.
    private static func countLine(label: String, count: Int?, unit: String) -> MetricLine? {
        guard let count else { return nil }
        return .values(label: label, values: [MetricValue(number: Double(count), kind: .count, label: unit)])
    }

    /// A `yyyy-MM-dd` day key back to that day's local start. The rollup's days are plain calendar
    /// dates with no time zone of their own, so they are read in the Mac's calendar — the same one the
    /// local scanner groups its days by, which keeps the two trends' axes aligned.
    private static func startOfDay(_ dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
