import XCTest
@testable import OpenUsage

/// Streak derivation from the daily usage series and the chart window. Days are fixed to a UTC
/// calendar so the tests never depend on the machine's local time zone.
final class UsageStreakTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func series(activeDays: [(Int, Int, Int)], costOnlyDays: [(Int, Int, Int)] = []) -> DailyUsageSeries {
        var daily = activeDays.map {
            DailyUsageEntry(date: day($0.0, $0.1, $0.2), totalTokens: 1_000, costUSD: 1.0)
        }
        daily += costOnlyDays.map {
            DailyUsageEntry(date: day($0.0, $0.1, $0.2), totalTokens: 0, costUSD: 0.5)
        }
        return DailyUsageSeries(daily: daily)
    }

    // MARK: - Series: the required edge cases

    func testEmptySeriesHasNoStreaks() {
        let streak = UsageStreakCalculator.streaks(
            in: DailyUsageSeries(daily: []), now: date(2026, 3, 10), calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 0)
        XCTAssertEqual(streak.longestDays, 0)
    }

    func testSingleActiveDayTodayIsAOneDayStreak() {
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [(2026, 3, 10)]), now: date(2026, 3, 10), calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 1)
        XCTAssertEqual(streak.longestDays, 1)
    }

    func testConsecutiveRunEndingTodayCountsWholeRun() {
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [
                (2026, 3, 6), (2026, 3, 7), (2026, 3, 8), (2026, 3, 9), (2026, 3, 10),
            ]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 5)
        XCTAssertEqual(streak.longestDays, 5)
    }

    func testZeroCostDayInTheMiddleBreaksTheRun() {
        // Mar 7 exists in the series but recorded nothing — an idle day, not a gap, and it breaks
        // the run exactly like a missing day would.
        let streak = UsageStreakCalculator.streaks(
            in: DailyUsageSeries(daily: [
                DailyUsageEntry(date: day(2026, 3, 5), totalTokens: 1_000, costUSD: 1.0),
                DailyUsageEntry(date: day(2026, 3, 6), totalTokens: 1_000, costUSD: 1.0),
                DailyUsageEntry(date: day(2026, 3, 7), totalTokens: 0, costUSD: 0),
                DailyUsageEntry(date: day(2026, 3, 8), totalTokens: 1_000, costUSD: 1.0),
                DailyUsageEntry(date: day(2026, 3, 9), totalTokens: 1_000, costUSD: 1.0),
                DailyUsageEntry(date: day(2026, 3, 10), totalTokens: 1_000, costUSD: 1.0),
            ]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 3, "the run picks up after the idle day")
        XCTAssertEqual(streak.longestDays, 3, "the idle day caps the longest run at the Mar 8–10 side")
    }

    func testMissingDayBreaksTheRunLikeAnIdleDay() {
        // No entry at all for Mar 8 — a calendar gap between two active days.
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [
                (2026, 3, 7), (2026, 3, 9), (2026, 3, 10),
            ]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 2, "the gap splits Mar 7 from the Mar 9–10 run")
        XCTAssertEqual(streak.longestDays, 2)
    }

    // MARK: - Series: current-streak anchoring

    func testIdleTodayKeepsStreakAliveThroughYesterday() {
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [
                (2026, 3, 7), (2026, 3, 8), (2026, 3, 9),
            ]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 3, "an unfinished today must not break yesterday's run")
        XCTAssertEqual(streak.longestDays, 3)
    }

    func testIdleTodayAndYesterdayEndsTheStreak() {
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [
                (2026, 3, 6), (2026, 3, 7),
            ]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 0, "two full idle days mean the streak is over")
        XCTAssertEqual(streak.longestDays, 2)
    }

    func testLongestStreakCanBeOlderRunThanCurrent() {
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [
                (2026, 2, 20), (2026, 2, 21), (2026, 2, 22), (2026, 2, 23), (2026, 2, 24), (2026, 2, 25),
                (2026, 3, 9), (2026, 3, 10),
            ]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 2)
        XCTAssertEqual(streak.longestDays, 6)
    }

    func testCostOnlyDayStillCountsAsActive() {
        // Tokens zero but dollars priced — the same "real usage" rule the spend tiles apply.
        let streak = UsageStreakCalculator.streaks(
            in: series(activeDays: [(2026, 3, 9)], costOnlyDays: [(2026, 3, 10)]),
            now: date(2026, 3, 10),
            calendar: calendar
        )
        XCTAssertEqual(streak.currentDays, 2)
        XCTAssertEqual(streak.longestDays, 2)
    }

    // MARK: - Activity window (the chart points)

    func testEmptyWindowHasNoStreaks() {
        let streak = UsageStreakCalculator.streaks(activityWindow: [])
        XCTAssertEqual(streak.currentDays, 0)
        XCTAssertEqual(streak.longestDays, 0)
    }

    func testWindowCountsTrailingRunEndingOnActiveToday() {
        let streak = UsageStreakCalculator.streaks(activityWindow: [true, true, false, true, true, true])
        XCTAssertEqual(streak.currentDays, 3)
        XCTAssertEqual(streak.longestDays, 3)
    }

    func testWindowGivesIdleNewestDayOneDayOfGrace() {
        // Last entry is today, still idle — the run ending yesterday keeps counting.
        let streak = UsageStreakCalculator.streaks(activityWindow: [false, true, true, true, false])
        XCTAssertEqual(streak.currentDays, 3)
        XCTAssertEqual(streak.longestDays, 3)
    }

    func testWindowEndsStreakAfterTwoIdleTrailingDays() {
        let streak = UsageStreakCalculator.streaks(activityWindow: [true, false, false])
        XCTAssertEqual(streak.currentDays, 0)
        XCTAssertEqual(streak.longestDays, 1)
    }

    func testWindowSaturatedRunCountsEveryDay() {
        let streak = UsageStreakCalculator.streaks(activityWindow: Array(repeating: true, count: 31))
        XCTAssertEqual(streak.currentDays, 31)
        XCTAssertEqual(streak.longestDays, 31)
    }
}
