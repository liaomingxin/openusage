import XCTest
@testable import OpenUsage

/// The Z.ai usage-history rows: bucket-label handling across time zones, the `model-usage` /
/// `tool-usage` parsers, and the lines they produce. Fixtures mirror the shapes the live endpoints
/// return (a short range comes back hourly, a 30-day range comes back as whole Beijing days).
final class ZAIActivityTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    // MARK: - Time handling

    func testRequestStringUsesTheServersBeijingClock() {
        // 2026-08-26T19:30:00Z is 2026-08-27 03:30 in Beijing — the wall clock the endpoints expect.
        let instant = Date(timeIntervalSince1970: 1_787_772_600)
        XCTAssertEqual(ZAITime.requestString(instant), "2026-08-27 03:30:00")
    }

    func testHourlyBucketLabelsResolveToTheMacsOwnCalendarDay() {
        // Beijing 2026-08-26 01:00 is still 2026-08-25 in Los Angeles (UTC-7) — the bar belongs to
        // the user's day, not the server's.
        XCTAssertEqual(
            ZAITime.dayKey(forBucketLabel: "2026-08-26 01:00", calendar: calendar("America/Los_Angeles")),
            "2026-08-25"
        )
        XCTAssertEqual(
            ZAITime.dayKey(forBucketLabel: "2026-08-26 01:00", calendar: calendar("Asia/Shanghai")),
            "2026-08-26"
        )
        // A label ahead of Beijing lands on the next day in Auckland (UTC+12).
        XCTAssertEqual(
            ZAITime.dayKey(forBucketLabel: "2026-08-26 23:00", calendar: calendar("Pacific/Auckland")),
            "2026-08-27"
        )
    }

    func testDailyBucketLabelsAreUsedAsWholeDaysRegardlessOfZone() {
        // A daily bucket is already a whole day on Z.ai's calendar; re-labelling it in another zone
        // would invent precision the payload doesn't carry, so the label is the key.
        for zone in ["America/Los_Angeles", "Asia/Shanghai", "Pacific/Auckland"] {
            XCTAssertEqual(ZAITime.dayKey(forBucketLabel: "2026-08-26", calendar: calendar(zone)), "2026-08-26", zone)
        }
    }

    func testUnparseableBucketLabelIsSkipped() {
        XCTAssertNil(ZAITime.dayKey(forBucketLabel: "", calendar: .current))
        XCTAssertNil(ZAITime.dayKey(forBucketLabel: "yesterday", calendar: .current))
    }

    func testRangeURLCarriesBothWallClockBounds() throws {
        let url = ZAITime.rangeURL(
            ZAIUsageClient.modelUsageURL(.global),
            start: Date(timeIntervalSince1970: 1_787_772_600),
            end: Date(timeIntervalSince1970: 1_787_776_200)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.z.ai")
        XCTAssertEqual(components.path, "/api/monitor/usage/model-usage")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "startTime" })?.value, "2026-08-27 03:30:00")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "endTime" })?.value, "2026-08-27 04:30:00")
    }

    // MARK: - model-usage

    /// Four hourly buckets straddling the Beijing midnight between Aug 25 and Aug 26.
    private let hourlyModelUsage = #"""
    {"code":200,"msg":"Operation successful","success":true,"data":{
      "x_time":["2026-08-25 22:00","2026-08-25 23:00","2026-08-26 00:00","2026-08-26 01:00"],
      "modelCallCount":[3,5,7,11],
      "tokensUsage":[1000,2000,4000,8000],
      "totalUsage":{"totalModelCallCount":26,"totalTokensUsage":15000,
        "modelSummaryList":[{"modelName":"GLM-5.3","totalTokens":12000,"sortOrder":1},
                            {"modelName":"GLM-5.2","totalTokens":3000,"sortOrder":2}]},
      "modelDataList":[
        {"modelName":"GLM-5.3","sortOrder":1,"tokensUsage":[1000,2000,3000,6000],"totalTokens":12000},
        {"modelName":"GLM-5.2","sortOrder":2,"tokensUsage":[0,0,1000,2000],"totalTokens":3000}],
      "granularity":"hourly"}}
    """#

    func testHourlyBucketsAggregateIntoLocalDaysAcrossTheServerDayBoundary() throws {
        let shanghai = try XCTUnwrap(ZAIActivityMapper.parseModelUsage(Data(hourlyModelUsage.utf8),
                                                                      calendar: calendar("Asia/Shanghai")))
        XCTAssertEqual(shanghai.tokensByDay, ["2026-08-25": 3000, "2026-08-26": 12000])
        XCTAssertEqual(shanghai.callsByDay, ["2026-08-25": 8, "2026-08-26": 18])

        // Los Angeles is seven hours behind Beijing, so all four buckets fall on one local day.
        let losAngeles = try XCTUnwrap(ZAIActivityMapper.parseModelUsage(Data(hourlyModelUsage.utf8),
                                                                        calendar: calendar("America/Los_Angeles")))
        XCTAssertEqual(losAngeles.tokensByDay, ["2026-08-25": 15000])
        XCTAssertEqual(losAngeles.callsByDay, ["2026-08-25": 26])
    }

    func testPerModelTokensFollowTheSameLocalDays() throws {
        let activity = try XCTUnwrap(ZAIActivityMapper.parseModelUsage(Data(hourlyModelUsage.utf8),
                                                                      calendar: calendar("Asia/Shanghai")))
        let byDay = Dictionary(uniqueKeysWithValues: activity.modelUsage.daily.map { ($0.date, $0.models) })
        XCTAssertEqual(byDay["2026-08-25"]?.map(\.model), ["GLM-5.3"])
        XCTAssertEqual(byDay["2026-08-25"]?.first?.totalTokens, 3000)
        // Ranked by tokens within the day, and never priced — a coding plan has nothing to charge.
        XCTAssertEqual(byDay["2026-08-26"]?.map(\.model), ["GLM-5.3", "GLM-5.2"])
        XCTAssertEqual(byDay["2026-08-26"]?.map(\.totalTokens), [9000, 3000])
        XCTAssertTrue(byDay["2026-08-26"]?.allSatisfy { $0.costUSD == nil } ?? false)
    }

    func testWindowTotalsComeFromTheServersOwnFigures() throws {
        let activity = try XCTUnwrap(ZAIActivityMapper.parseModelUsage(Data(hourlyModelUsage.utf8),
                                                                      calendar: calendar("Asia/Shanghai")))
        XCTAssertEqual(activity.totalTokens, 15000)
        XCTAssertEqual(activity.totalCalls, 26)
    }

    func testTotalsFallBackToTheBucketSumWhenTheServerOmitsThem() throws {
        let body = #"""
        {"success":true,"data":{"x_time":["2026-08-26"],"tokensUsage":[42],"modelCallCount":[7]}}
        """#
        let activity = try XCTUnwrap(ZAIActivityMapper.parseModelUsage(Data(body.utf8)))
        XCTAssertEqual(activity.totalTokens, 42)
        XCTAssertEqual(activity.totalCalls, 7)
    }

    func testModelUsageRejectsFailureAndMalformedBodies() {
        XCTAssertNil(ZAIActivityMapper.parseModelUsage(Data(#"{"success":false,"msg":"nope"}"#.utf8)))
        XCTAssertNil(ZAIActivityMapper.parseModelUsage(Data("not json".utf8)))
        XCTAssertNil(ZAIActivityMapper.parseModelUsage(Data(#"{"success":true,"data":{}}"#.utf8)))
    }

    // MARK: - tool-usage

    func testToolUsageReadsTheWindowTotals() throws {
        let body = #"""
        {"code":200,"success":true,"data":{
          "x_time":["2026-08-26"],"networkSearchCount":[15],"webReadMcpCount":[12],"zreadMcpCount":[0],
          "totalUsage":{"totalNetworkSearchCount":15,"totalWebReadMcpCount":12,"totalZreadMcpCount":0,
            "totalSearchMcpCount":27,
            "toolSummaryList":[{"toolCode":"search-prime","toolName":"联网搜索 MCP","toolNameI18n":"Web Search MCP","totalUsageCount":15,"sortOrder":1}]},
          "granularity":"daily"}}
        """#
        let tools = try XCTUnwrap(ZAIActivityMapper.parseToolUsage(Data(body.utf8)))
        XCTAssertEqual(tools.webSearches, 15)
        XCTAssertEqual(tools.webReads, 12)
        XCTAssertEqual(tools.zreadCalls, 0)
        XCTAssertEqual(tools.tools, [ZAIToolUsageEntry(name: "Web Search MCP", calls: 15)])
    }

    func testToolUsageRejectsBodiesWithoutTotals() {
        XCTAssertNil(ZAIActivityMapper.parseToolUsage(Data(#"{"success":true,"data":{"x_time":[]}}"#.utf8)))
        XCTAssertNil(ZAIActivityMapper.parseToolUsage(Data(#"{"success":false}"#.utf8)))
    }

    /// The summary list is what names the tools, and it is ranked by calls — largest share first,
    /// like the model breakdown — with Z.ai's own `sortOrder` breaking a tie.
    func testToolSummaryListIsRankedByCalls() throws {
        let body = #"""
        {"success":true,"data":{"totalUsage":{"totalNetworkSearchCount":4,
          "toolSummaryList":[
            {"toolCode":"zread","toolNameI18n":"ZRead MCP","totalUsageCount":4,"sortOrder":3},
            {"toolCode":"search-prime","toolNameI18n":"Web Search MCP","totalUsageCount":15,"sortOrder":1},
            {"toolCode":"web-reader","toolNameI18n":"Web Read MCP","totalUsageCount":4,"sortOrder":2}]}}}
        """#
        let tools = try XCTUnwrap(ZAIActivityMapper.parseToolUsage(Data(body.utf8)))
        XCTAssertEqual(tools.tools.map(\.name), ["Web Search MCP", "Web Read MCP", "ZRead MCP"])
        XCTAssertEqual(tools.tools.map(\.calls), [15, 4, 4])
    }

    /// Z.ai has shipped `toolSummaryList` directly on `data` as well as nested inside `totalUsage`,
    /// so both are read — and a payload carrying only the list still parses.
    func testToolSummaryListIsReadFromTheDataObjectToo() throws {
        let body = #"""
        {"success":true,"data":{"x_time":["2026-08-26"],
          "toolSummaryList":[{"toolCode":"search-prime","toolNameI18n":"Web Search MCP","totalUsageCount":7,"sortOrder":1}]}}
        """#
        let tools = try XCTUnwrap(ZAIActivityMapper.parseToolUsage(Data(body.utf8)))
        XCTAssertEqual(tools.tools, [ZAIToolUsageEntry(name: "Web Search MCP", calls: 7)])
        XCTAssertEqual(tools.webSearches, 0)
    }

    /// Naming falls back through the localized name, Z.ai's native name and the bare tool code, so a
    /// tool OpenUsage has never seen still gets a named row. Entries with neither a usable name nor a
    /// usable count are skipped instead of rendering as a nameless or unmeasured row.
    func testToolSummaryListTakesWhateverNameIsThereAndSkipsUnusableEntries() throws {
        let body = #"""
        {"success":true,"data":{"totalUsage":{"totalNetworkSearchCount":0,
          "toolSummaryList":[
            {"toolCode":"search-prime","toolName":"联网搜索 MCP","totalUsageCount":9,"sortOrder":1},
            {"toolCode":"brand-new-tool","totalUsageCount":5,"sortOrder":2},
            {"toolCode":"  ","toolNameI18n":"   ","totalUsageCount":4,"sortOrder":3},
            {"toolCode":"no-count","toolNameI18n":"No Count MCP","totalUsageCount":"lots","sortOrder":4},
            {"toolCode":"zero","toolNameI18n":"Idle MCP","totalUsageCount":0,"sortOrder":5}]}}}
        """#
        let tools = try XCTUnwrap(ZAIActivityMapper.parseToolUsage(Data(body.utf8)))
        // A zero is a real measurement for this endpoint, so an idle tool stays on the list.
        XCTAssertEqual(tools.tools, [
            ZAIToolUsageEntry(name: "联网搜索 MCP", calls: 9),
            ZAIToolUsageEntry(name: "brand-new-tool", calls: 5),
            ZAIToolUsageEntry(name: "Idle MCP", calls: 0)
        ])
    }

    // MARK: - Lines

    /// A 30-day payload whose daily labels are anchored on `now`, so the trend's calendar zero-fill
    /// lines up wherever the test runs.
    private func windowBody(now: Date) -> Data {
        let days = (0...2).map { offset -> String in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now
            return DailyUsageAccumulator.dayKey(from: day)
        }
        let json = """
        {"success":true,"data":{
          "x_time":["\(days[2])","\(days[1])","\(days[0])"],
          "tokensUsage":[3000000,2000000,1000000],
          "modelCallCount":[30,20,10],
          "totalUsage":{"totalTokensUsage":6000000,"totalModelCallCount":60},
          "modelDataList":[
            {"modelName":"GLM-5.3","tokensUsage":[3000000,1500000,600000],"totalTokens":5100000},
            {"modelName":"GLM-5.2","tokensUsage":[0,500000,400000],"totalTokens":900000}],
          "granularity":"daily"}}
        """
        return Data(json.utf8)
    }

    private func toolBody() -> Data {
        Data(#"""
        {"success":true,"data":{"totalUsage":{"totalNetworkSearchCount":1,"totalWebReadMcpCount":3,"totalZreadMcpCount":0}}}
        """#.utf8)
    }

    func testLinesRenderTrendPeriodRowsAndMCPToolsInOrder() throws {
        let now = Date(timeIntervalSince1970: 1_787_772_600)
        let window = ZAIActivityMapper.parseModelUsage(windowBody(now: now))
        let tools = ZAIActivityMapper.parseToolUsage(toolBody())

        let lines = ZAIActivityMapper.lines(
            window: window, recent: window, tools: tools, platform: .global, now: now
        )
        XCTAssertEqual(lines.map(\.label), ["Usage Trend", "Today", "Yesterday", "Last 30 Days", "MCP Tools"])

        // Today: tokens then calls, no dollars — a coding plan has nothing to price.
        guard case .values(_, let today, _, _, _, let breakdown) = lines[1] else {
            return XCTFail("Today is not a values line")
        }
        XCTAssertEqual(today.map(\.kind), [.count, .count])
        XCTAssertEqual(today.map(\.label), ["tokens", "calls"])
        XCTAssertEqual(today.map(\.number), [1_000_000, 10])
        XCTAssertFalse(today.contains { $0.estimated })
        // The hover breakdown is attached and carries token shares (nothing is priced).
        let models = try XCTUnwrap(breakdown?.models)
        XCTAssertEqual(models.map(\.model), ["GLM-5.3", "GLM-5.2"])
        XCTAssertTrue(models.allSatisfy { $0.costUSD == nil })
        XCTAssertEqual(breakdown?.totalTokens, 1_000_000)
        XCTAssertEqual(breakdown?.sourceNote, "From your api.z.ai usage history")

        guard case .values(_, let total, _, _, _, _) = lines[3] else {
            return XCTFail("Last 30 Days is not a values line")
        }
        XCTAssertEqual(total.map(\.number), [6_000_000, 60])

        // No summary list in this payload, so the row keeps the older three-counter reading. A zero
        // count is a real measurement for the tool endpoint, so "0 ZRead" is shown.
        guard case .values(_, let mcp, _, _, _, _) = lines[4] else {
            return XCTFail("MCP Tools is not a values line")
        }
        XCTAssertEqual(mcp.map(\.number), [1, 3, 0])
        XCTAssertEqual(mcp.map(\.label), ["searches", "reads", "ZRead"])
    }

    /// With a summary list the row reads one total and carries the named per-tool breakdown behind it,
    /// counted in calls rather than tokens.
    func testMCPToolsRowNamesEachToolWhenTheSummaryListIsPresent() throws {
        let now = Date(timeIntervalSince1970: 1_787_772_600)
        let body = #"""
        {"success":true,"data":{"totalUsage":{
          "totalNetworkSearchCount":15,"totalWebReadMcpCount":12,"totalZreadMcpCount":0,
          "toolSummaryList":[
            {"toolCode":"search-prime","toolNameI18n":"Web Search MCP","totalUsageCount":15,"sortOrder":1},
            {"toolCode":"web-reader","toolNameI18n":"Web Read MCP","totalUsageCount":12,"sortOrder":2}]}}}
        """#
        let tools = ZAIActivityMapper.parseToolUsage(Data(body.utf8))
        let lines = ZAIActivityMapper.lines(window: nil, recent: nil, tools: tools, platform: .global, now: now)

        guard case .values(let label, let values, _, _, _, let breakdown) = lines.first else {
            return XCTFail("MCP Tools is not a values line")
        }
        XCTAssertEqual(label, "MCP Tools")
        XCTAssertEqual(values.map(\.number), [27])
        XCTAssertEqual(values.map(\.label), ["calls"])

        let panel = try XCTUnwrap(breakdown)
        XCTAssertEqual(panel.models.map(\.model), ["Web Search MCP", "Web Read MCP"])
        XCTAssertEqual(panel.models.map(\.totalTokens), [15, 12])
        XCTAssertTrue(panel.models.allSatisfy { $0.costUSD == nil })
        XCTAssertEqual(panel.totalTokens, 27)
        XCTAssertNil(panel.totalCostUSD)
        XCTAssertEqual(panel.unit, "calls")
        XCTAssertEqual(panel.sourceNote, "From your api.z.ai usage history")
    }

    /// A tool set OpenUsage has never seen renders exactly as reported — no name is baked in.
    func testMCPToolsRowRendersUnknownToolsAsReported() throws {
        let now = Date(timeIntervalSince1970: 1_787_772_600)
        let body = #"""
        {"success":true,"data":{"totalUsage":{"toolSummaryList":[
            {"toolCode":"slides-mcp","toolNameI18n":"Slides MCP","totalUsageCount":3,"sortOrder":1},
            {"toolCode":"vision-mcp","toolNameI18n":"Vision MCP","totalUsageCount":8,"sortOrder":2}]}}}
        """#
        let tools = ZAIActivityMapper.parseToolUsage(Data(body.utf8))
        let lines = ZAIActivityMapper.lines(window: nil, recent: nil, tools: tools, platform: .cn, now: now)

        guard case .values(_, let values, _, _, _, let breakdown) = lines.first else {
            return XCTFail("MCP Tools is not a values line")
        }
        XCTAssertEqual(values.map(\.number), [11])
        XCTAssertEqual(try XCTUnwrap(breakdown).models.map(\.model), ["Vision MCP", "Slides MCP"])
    }

    func testTrendChartCarriesOneCalendarDayPerPoint() throws {
        let now = Date(timeIntervalSince1970: 1_787_772_600)
        let lines = ZAIActivityMapper.lines(
            window: ZAIActivityMapper.parseModelUsage(windowBody(now: now)),
            recent: nil, tools: nil, platform: .cn, now: now
        )
        guard case .chart(_, let points, let note) = lines.first else {
            return XCTFail("expected a Usage Trend chart")
        }
        XCTAssertEqual(points.count, UsageHistoryWindow.previousDays + 1)
        XCTAssertEqual(points.last?.value, 1_000_000)
        XCTAssertEqual(note, "From your open.bigmodel.cn usage history")
    }

    func testIdlePeriodsAndMissingPayloadsProduceNoRows() {
        let now = Date(timeIntervalSince1970: 1_787_772_600)
        XCTAssertTrue(ZAIActivityMapper.lines(window: nil, recent: nil, tools: nil, platform: .global, now: now).isEmpty)

        // A parsed window with no usage at all leaves every row absent rather than claiming a zero.
        let idle = ZAIActivityMapper.parseModelUsage(Data(#"""
        {"success":true,"data":{"x_time":["2020-01-01"],"tokensUsage":[0],"modelCallCount":[0],
          "totalUsage":{"totalTokensUsage":0,"totalModelCallCount":0}}}
        """#.utf8))
        XCTAssertTrue(ZAIActivityMapper.lines(window: idle, recent: idle, tools: nil, platform: .global, now: now).isEmpty)
    }

    func testWindowStartsCoverTheirCalendarWindows() {
        let now = Date(timeIntervalSince1970: 1_787_772_600)
        let calendar = Calendar.current
        XCTAssertEqual(
            calendar.dateComponents([.day], from: ZAIActivityMapper.trendWindowStart(now: now), to: calendar.startOfDay(for: now)).day,
            UsageHistoryWindow.previousDays
        )
        XCTAssertEqual(
            calendar.dateComponents([.day], from: ZAIActivityMapper.recentWindowStart(now: now), to: calendar.startOfDay(for: now)).day,
            ZAIActivityMapper.recentWindowDays
        )
    }
}
