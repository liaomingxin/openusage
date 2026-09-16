import Foundation

/// Consecutive-day activity streaks derived from a provider's daily usage series — the two figures
/// the Usage Trend popover surfaces under the chart. Days are counted on the local calendar, the
/// same one the spend tiles and the trend bars group by.
struct UsageStreak: Hashable, Sendable {
    /// Consecutive active days ending at the newest covered day — today for the local trend, or the
    /// run ending the previous day when today hasn't seen usage yet (see the anchoring rule in
    /// `UsageStreakCalculator`).
    var currentDays: Int
    /// The longest run of consecutive active days anywhere in the data.
    var longestDays: Int
}

/// Derives `UsageStreak` from the shapes usage history already travels in.
///
/// A day is **active** when it recorded any usage — tokens or cost, the same bar that makes a trend
/// bar draw. An idle day (zero usage) and a day missing from the source entirely both break a run:
/// the first appears as a zero bar, the second is a calendar gap, and neither may stitch two active
/// days into one streak.
///
/// **Current-streak anchoring:** the current streak counts back from today; a today that is still
/// idle doesn't break it (the day isn't over yet, and the account-wide Codex rollup that feeds some
/// charts hasn't counted today at all), so the run may end on yesterday instead. Two consecutive
/// idle days end the streak for good.
enum UsageStreakCalculator {
    /// Streaks from a raw daily series. Entries are keyed `yyyy-MM-dd` on the local calendar (the
    /// shape every scanner and the combined history produce); entries with any other date format
    /// can't be placed on the calendar and are ignored.
    static func streaks(in series: DailyUsageSeries, now: Date = Date(), calendar: Calendar = .current) -> UsageStreak {
        let activeDays = Set(series.daily.compactMap { entry -> Date? in
            guard isActive(entry) else { return nil }
            return startOfDay(fromKey: entry.date, calendar: calendar)
        })
        return UsageStreak(
            currentDays: currentStreak(activeDays: activeDays, now: now, calendar: calendar),
            longestDays: longestStreak(activeDays: activeDays, calendar: calendar)
        )
    }

    /// Streaks from the Usage Trend chart points collapsed to per-day activity: oldest first, exactly
    /// one entry per consecutive calendar day, newest last. The chart producer zero-fills idle days
    /// in place, so both an idle day and a day the source never had arrive as `false` — the window
    /// itself stays calendar-true and no gap detection is needed here.
    static func streaks(activityWindow: [Bool]) -> UsageStreak {
        // The grace rule: an idle newest day is the still-in-progress today (or the account-wide
        // rollup's not-yet-counted today), so the run ending the day before it still counts.
        let newestActive = activityWindow.last == true
            ? trailingStreak(endingAt: activityWindow.count - 1, activityWindow: activityWindow)
            : trailingStreak(endingAt: activityWindow.count - 2, activityWindow: activityWindow)
        return UsageStreak(
            currentDays: newestActive,
            longestDays: longestStreak(activityWindow: activityWindow)
        )
    }

    // MARK: - Day-key series

    /// The run of active days ending today — or, when today is idle, ending yesterday. Neither day
    /// active means the streak is over.
    private static func currentStreak(activeDays: Set<Date>, now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        var anchor: Date? = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)
        var count = 0
        while let day = anchor, activeDays.contains(day) {
            count += 1
            anchor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return count
    }

    /// The longest run of active days that are calendar-adjacent — a missing day between two active
    /// days splits the run rather than joining it.
    private static func longestStreak(activeDays: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            run = previous.map { calendar.date(byAdding: .day, value: 1, to: $0) == day } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        return longest
    }

    /// A `yyyy-MM-dd` key back to its local start of day, or `nil` when the key doesn't parse.
    private static func startOfDay(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Same active-day rule as the spend tiles: tokens used, dollars priced, or both. A zero-cost,
    /// zero-token day is idle and draws no bar, so it can't extend a streak either.
    private static func isActive(_ entry: DailyUsageEntry) -> Bool {
        entry.totalTokens > 0 || (entry.costUSD ?? 0) > 0
    }

    // MARK: - Activity window

    /// The run of active days ending at `index`, honoring the same grace rule as the day-key path:
    /// when the newest day is idle, the run ending the day before still counts.
    private static func trailingStreak(endingAt index: Int, activityWindow: [Bool]) -> Int {
        var count = 0
        var index = index
        while index >= 0, activityWindow[index] {
            count += 1
            index -= 1
        }
        return count
    }

    private static func longestStreak(activityWindow: [Bool]) -> Int {
        var longest = 0
        var run = 0
        for active in activityWindow {
            run = active ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}
