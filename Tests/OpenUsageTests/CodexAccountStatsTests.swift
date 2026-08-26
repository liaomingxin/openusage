import XCTest
@testable import OpenUsage

/// The parse boundary for `wham/profiles/me`: what OpenUsage reads, what it refuses to read, and what
/// it does with a payload it can't use.
final class CodexAccountStatsParserTests: XCTestCase {
    func testReadsTheStatsBlockFromARealShapedPayload() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response()))

        XCTAssertEqual(stats.lifetimeTokens, 1_588_515_077)
        XCTAssertEqual(stats.currentStreakDays, 11)
        XCTAssertEqual(stats.totalThreads, 514)
        XCTAssertEqual(stats.statsAsOf, "2026-08-26")
        XCTAssertEqual(stats.tokensByDay["2026-08-21"], 6_500_000)
        // Sparse by design: a day inside the covered range simply isn't in the payload.
        XCTAssertNil(stats.tokensByDay["2026-08-20"])
        XCTAssertEqual(stats.tokensByDay.count, 6)
    }

    /// The payload carries `profile.username`, `display_name` and an avatar URL. Those are identity,
    /// not usage: the model has no field for them, and nothing derived from the payload may carry them.
    func testDropsProfileIdentityFieldsAtTheParseBoundary() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response()))
        let lines = CodexAccountStatsMapper.lines(stats: stats, now: day("2026-08-27"))

        let rendered = String(describing: stats) + String(describing: lines)
        for identity in [
            CodexAccountStatsFixtures.redactedUsername,
            CodexAccountStatsFixtures.redactedDisplayName,
            CodexAccountStatsFixtures.redactedAvatarURL
        ] {
            XCTAssertFalse(rendered.contains(identity), "identity field \(identity) escaped the parser")
        }
    }

    func testAbsentFieldsAreNotAnError() throws {
        // A missing optional field just means that row doesn't render — the rest still parse.
        let response = CodexAccountStatsFixtures.response(
            lifetimeTokens: nil,
            currentStreakDays: nil,
            totalThreads: nil
        )

        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(response))

        XCTAssertNil(stats.lifetimeTokens)
        XCTAssertNil(stats.currentStreakDays)
        XCTAssertNil(stats.totalThreads)
        XCTAssertFalse(stats.tokensByDay.isEmpty)
    }

    func testRejectsNonSuccessResponse() {
        XCTAssertNil(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response(statusCode: 500)))
    }

    func testRejectsNonJSONBody() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>nope</html>".utf8))
        XCTAssertNil(CodexAccountStatsParser.parse(response))
    }

    func testRejectsPayloadWithoutStatsBlock() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"profile":{}}"#.utf8))
        XCTAssertNil(CodexAccountStatsParser.parse(response))
    }

    /// OpenAI reports a failed rollup in-band with a 200. Don't render the numbers riding along with it.
    func testRejectsPayloadWhoseMetadataReportsAStatsError() {
        XCTAssertNil(CodexAccountStatsParser.parse(
            CodexAccountStatsFixtures.response(statsError: "rollup failed")
        ))
    }

    func testSkipsMalformedBucketsWithoutDiscardingSiblings() throws {
        let response = CodexAccountStatsFixtures.response(dailyBuckets: [
            NSNull(),
            "not-a-dictionary",
            ["tokens": 5_000_000],                                    // no day
            ["start_date": "2026-08-25"],                             // no tokens
            ["start_date": "nonsense", "tokens": 1_000_000],          // unparseable day
            ["start_date": "2026-08-26", "tokens": "4200000"],        // numeric string
            ["start_date": "2026-08-26T00:00:00Z", "tokens": 800_000] // same day, ISO form
        ])

        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(response))

        // Two elements naming the same day are summed rather than one silently winning.
        XCTAssertEqual(stats.tokensByDay, ["2026-08-26": 5_000_000])
    }

    func testNegativeCountsAreRejectedRatherThanRendered() throws {
        let response = CodexAccountStatsFixtures.response(lifetimeTokens: -5, totalThreads: 0)

        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(response))

        XCTAssertNil(stats.lifetimeTokens)
        // A measured zero is real data and stays.
        XCTAssertEqual(stats.totalThreads, 0)
    }

    private func day(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }
}

/// The four account-wide rows, and the two framing rules the trend has to hold: it never claims to
/// cover today, and it never merges with the machine-local history.
final class CodexAccountStatsMapperTests: XCTestCase {
    func testRendersAllFourRows() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response()))

        let lines = CodexAccountStatsMapper.lines(stats: stats, now: day("2026-08-27"))

        XCTAssertEqual(lines.map(\.label),
                       ["Account Trend", "Lifetime Tokens", "Day Streak", "Threads"])
        XCTAssertEqual(values(lines, "Lifetime Tokens")?.first?.number, 1_588_515_077)
        XCTAssertEqual(values(lines, "Lifetime Tokens")?.first?.label, "tokens")
        XCTAssertEqual(values(lines, "Day Streak")?.first?.number, 11)
        XCTAssertEqual(values(lines, "Threads")?.first?.number, 514)
        // Tokens only: nothing here may ever carry a dollar value into a spend tile.
        XCTAssertFalse(lines.contains { line in
            guard case .values(_, let values, _, _, _, _) = line else { return false }
            return values.contains { $0.kind == .dollars }
        })
    }

    /// The single most important framing rule: `stats_as_of` is yesterday, so the chart must stop there.
    /// A zero bar for today would read as "you used nothing today" on data that simply isn't counted yet.
    func testTrendStopsAtStatsAsOfAndNeverDrawsToday() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(
            CodexAccountStatsFixtures.response(statsAsOf: "2026-08-26")
        ))

        let points = try XCTUnwrap(chart(
            CodexAccountStatsMapper.lines(stats: stats, now: day("2026-08-27")), "Account Trend"
        ))

        XCTAssertEqual(points.points.last?.label, Formatters.monthDayLabel(day("2026-08-26")))
        XCTAssertFalse(points.points.contains { $0.label == Formatters.monthDayLabel(day("2026-08-27")) })
        // The note says both things a reader needs: whose usage it is, and how far it counts.
        let note = try XCTUnwrap(points.note)
        XCTAssertTrue(note.contains("Across your whole OpenAI account"))
        XCTAssertTrue(note.contains(Formatters.monthDayLabel(day("2026-08-26"))))
        XCTAssertTrue(note.contains("updated daily"))
    }

    /// Inside the covered range a missing bucket is a real zero (the rollup looked and found nothing),
    /// so idle days are zero-filled in place — dropping them would make the axis skip calendar days.
    /// Before the first day the rollup reports there is nothing to claim, so the chart starts there.
    func testTrendZeroFillsCoveredGapsAndStartsAtTheFirstReportedDay() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response()))

        let line = try XCTUnwrap(chart(
            CodexAccountStatsMapper.lines(stats: stats, now: day("2026-08-27")), "Account Trend"
        ))

        // 2026-08-19 (first reported) through 2026-08-26 (stats_as_of) — eight consecutive days.
        XCTAssertEqual(line.points.count, 8)
        XCTAssertEqual(line.points.first?.label, Formatters.monthDayLabel(day("2026-08-19")))
        XCTAssertEqual(line.points.map(\.value),
                       [4_000_000, 0, 6_500_000, 1_200_000, 0, 9_800_000, 3_300_000, 7_100_000])
    }

    func testNoTrendWhenTheRollupNamesNoCoveredDay() throws {
        // Without `stats_as_of` there is no way to say where the counted range ends, so no chart is
        // drawn rather than one that silently implies it covers today.
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(
            CodexAccountStatsFixtures.response(statsAsOf: nil)
        ))

        let lines = CodexAccountStatsMapper.lines(stats: stats, now: day("2026-08-27"))

        XCTAssertNil(chart(lines, "Account Trend"))
        // The plain counts still render — one absent field never blanks the others.
        XCTAssertEqual(lines.map(\.label), ["Lifetime Tokens", "Day Streak", "Threads"])
    }

    func testNoTrendWhenTheRollupIsOlderThanTheWindow() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response()))

        // Two months on, everything the rollup covered has fallen out of the 31-day window.
        let lines = CodexAccountStatsMapper.lines(stats: stats, now: day("2026-10-27"))

        XCTAssertNil(chart(lines, "Account Trend"))
    }

    func testNoRowsAtAllWhenNothingUsableCameBack() {
        XCTAssertTrue(CodexAccountStatsMapper.lines(stats: CodexAccountStats(), now: Date()).isEmpty)
    }

    /// The account rows must never collide with the labels the cross-Mac history renderer owns, or it
    /// would rewrite/drop them when peer documents merge.
    func testAccountRowLabelsNeverCollideWithTheSharedHistoryLabels() throws {
        let stats = try XCTUnwrap(CodexAccountStatsParser.parse(CodexAccountStatsFixtures.response()))
        let labels = Set(CodexAccountStatsMapper.lines(stats: stats, now: day("2026-08-27")).map(\.label))

        XCTAssertTrue(labels.isDisjoint(with: ["Usage Trend", "Today", "Yesterday", "Last 30 Days"]))
    }

    private func day(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private func chart(_ lines: [MetricLine], _ label: String) -> (points: [MetricChartPoint], note: String?)? {
        guard case .chart(_, let points, let note) = lines.first(where: { $0.label == label }) else { return nil }
        return (points, note)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}
