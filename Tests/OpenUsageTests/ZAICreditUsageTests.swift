import XCTest
@testable import OpenUsage

/// The credit-usage endpoint family: the parsers behind Usage Trend / period rows / MCP Tools on
/// credit-metered GLM Coding plans, the quota-based routing between the two endpoint families, and
/// the provider wiring that picks the family per refresh. Fixtures are captured from
/// open.bigmodel.cn on 2026-08-29 (a GLM Coding Max account) and trimmed to the fields the mappers
/// read — the shapes are what the live endpoints return, not inventions.
final class ZAICreditUsageTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    // MARK: - Routing: quota payload decides the endpoint family

    func testCreditPackageDetectionFollowsTheLimitType() {
        // CREDIT_LIMIT — the credit endpoints; matched on `type` or the legacy `name` spelling.
        XCTAssertTrue(ZAIUsageMapper.isCreditPackage(Data(#"""
        {"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":16}]},"success":true}
        """#.utf8)))
        XCTAssertTrue(ZAIUsageMapper.isCreditPackage(Data(#"""
        {"limits":[{"name":"CREDIT_LIMIT","unit":6,"number":1,"percentage":10}]}
        """#.utf8)))
        // TOKENS_LIMIT-only or TIME_LIMIT-only — the legacy endpoints.
        XCTAssertFalse(ZAIUsageMapper.isCreditPackage(Data(#"""
        {"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17}]},"success":true}
        """#.utf8)))
        XCTAssertFalse(ZAIUsageMapper.isCreditPackage(Data(#"""
        {"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":0}]},"success":true}
        """#.utf8)))
        // A transition payload carrying both reads as credit — the newer accounting wins.
        XCTAssertTrue(ZAIUsageMapper.isCreditPackage(Data(#"""
        {"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17},
                           {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":10}]},"success":true}
        """#.utf8)))
        // Nothing usable stays on the legacy path.
        XCTAssertFalse(ZAIUsageMapper.isCreditPackage(Data("{}".utf8)))
    }

    // MARK: - activity

    /// Captured 30-day `activity` response, trimmed: three daily entries plus the summary the live
    /// endpoint returns (streaks and duration ride along; only the token figures are read).
    private let activityJSON = #"""
    {"code":200,"msg":"操作成功","data":{
      "granularity":"DAY","timezone":"Asia/Shanghai",
      "summary":{"totalTokens":250000000,"peakDailyTokens":116331283,"peakDailyTokensDate":"2026-08-27",
                 "totalUsageDurationMs":108630765,"currentStreakDays":31,"longestStreakDays":31},
      "series":[
        {"date":"2026-08-27","totalCredits":"10592.0019","totalTokens":116331283,"mcpCalls":2},
        {"date":"2026-08-28","totalCredits":"6154.4812","totalTokens":57321244,"mcpCalls":14},
        {"date":"2026-08-29","totalCredits":"5938.3180","totalTokens":69374046,"mcpCalls":2}]},
     "success":true}
    """#

    func testActivityParsesDailyTokensAndSummaryTotals() throws {
        let activity = try XCTUnwrap(ZAICreditUsageMapper.parseActivity(Data(activityJSON.utf8)))
        XCTAssertEqual(activity.tokensByDay, [
            "2026-08-27": 116_331_283, "2026-08-28": 57_321_244, "2026-08-29": 69_374_046
        ])
        // The summary total wins over the bucket sum (it is exact for the requested range).
        XCTAssertEqual(activity.totalTokens, 250_000_000)
        // The credit endpoints report no call counts — the period rows carry tokens only.
        XCTAssertFalse(activity.reportsCallCounts)
        XCTAssertTrue(activity.callsByDay.isEmpty)
        XCTAssertEqual(activity.totalCalls, 0)
    }

    func testActivityWithoutTokensIsNilSoTheRowsStayAbsent() {
        let zeroSeries = #"""
        {"data":{"timezone":"Asia/Shanghai","series":[{"date":"2026-08-27","totalTokens":0}],"success":true}}
        """#
        XCTAssertNil(ZAICreditUsageMapper.parseActivity(Data(zeroSeries.utf8)))
        XCTAssertNil(ZAICreditUsageMapper.parseActivity(Data("{\"success\":false}".utf8)))
    }

    // MARK: - usage-detail (MODEL)

    /// Captured `usage-detail` MODEL response, trimmed: one model, hourly buckets (the shape a
    /// short-range request returns), with the cached/uncached splits the live payload carries.
    private let modelDetailHourlyJSON = #"""
    {"code":200,"msg":"操作成功","data":{
      "granularity":"HOUR","timezone":"Asia/Shanghai",
      "summary":{"cacheHitRate":{"value":"0.9125","trend":"0.0182"},
                 "totalCredits":{"value":"26935.6627","trend":"0.2722"}},
      "modelUsage":{
        "xTime":["2026-08-29 15:00:00","2026-08-29 16:00:00","2026-08-30 01:00:00"],
        "totalUsage":{"totalTokens":52000000,"totalCredits":"21000.0000"},
        "modelSummaryList":[{"modelCode":"glm-5.3","modelName":"GLM-5.3","sortOrder":1}],
        "modelDataList":[{"modelCode":"glm-5.3","modelName":"GLM-5.3","sortOrder":1,
          "uncachedInputTokensUsage":[900000,800000,700000],
          "cachedInputTokensUsage":[41000000,41000000,40000000],
          "inputTokensUsage":[41900000,41800000,40700000],
          "outputTokensUsage":[100000,100000,100000],
          "totalTokensUsage":[42000000,41900000,40800000],
          "uncachedInputCreditsUsage":[0,0,0],"cachedInputCreditsUsage":[0,0,0],
          "inputCreditsUsage":[0,0,0],"outputCreditsUsage":[0,0,0],"totalCreditsUsage":[0,0,0]}]}},
     "success":true}
    """#

    func testModelDetailHourlyBucketsLandOnTheMacsOwnDays() throws {
        // The hourly labels are Beijing wall clock: the 01:00 bucket on Aug 30 is still Aug 29 in
        // Los Angeles, so the model split and the day totals follow the Mac's calendar.
        let losAngeles = try XCTUnwrap(
            ZAICreditUsageMapper.parseModelDetail(Data(modelDetailHourlyJSON.utf8),
                                                  calendar: calendar("America/Los_Angeles"))
        )
        XCTAssertEqual(losAngeles.tokensByDay, ["2026-08-29": 124_700_000])
        XCTAssertEqual(losAngeles.totalTokens, 52_000_000)
        XCTAssertEqual(losAngeles.modelUsage.daily.count, 1)
        XCTAssertEqual(losAngeles.modelUsage.daily.first?.models.first?.model, "GLM-5.3")
        XCTAssertEqual(losAngeles.modelUsage.daily.first?.models.first?.totalTokens, 124_700_000)
        XCTAssertFalse(losAngeles.reportsCallCounts)

        // In Shanghai the buckets straddle the midnight boundary.
        let shanghai = try XCTUnwrap(
            ZAICreditUsageMapper.parseModelDetail(Data(modelDetailHourlyJSON.utf8),
                                                  calendar: calendar("Asia/Shanghai"))
        )
        XCTAssertEqual(shanghai.tokensByDay, ["2026-08-29": 83_900_000, "2026-08-30": 40_800_000])
    }

    func testModelDetailDailyBucketsUseTheDeclaredDayLabels() throws {
        let daily = #"""
        {"data":{"timezone":"Asia/Shanghai",
          "modelUsage":{"xTime":["2026-08-28","2026-08-29"],
            "totalUsage":{"totalTokens":9000},
            "modelDataList":[
              {"modelName":"GLM-5.3","totalTokensUsage":[6000,3000]},
              {"modelName":"GLM-5.3-Flash","totalTokensUsage":[0,200]}]}},
         "success":true}
        """#
        let activity = try XCTUnwrap(ZAICreditUsageMapper.parseModelDetail(Data(daily.utf8)))
        XCTAssertEqual(activity.tokensByDay, ["2026-08-28": 6000, "2026-08-29": 3200])
        // Totals fall back to the bucket sum when the payload omits them.
        XCTAssertEqual(activity.totalTokens, 9000)
        // Ranked by tokens within the day; a zero-bucket model contributes no day entry.
        let byDay = Dictionary(uniqueKeysWithValues: activity.modelUsage.daily.map { ($0.date, $0.models) })
        XCTAssertEqual(byDay["2026-08-28"]?.map(\.model), ["GLM-5.3"])
        XCTAssertEqual(byDay["2026-08-29"]?.map(\.model), ["GLM-5.3", "GLM-5.3-Flash"])
    }

    // MARK: - usage-detail (MCP)

    /// Captured `usage-detail` MCP response, trimmed to named tools with the parallel daily arrays.
    private let mcpDetailJSON = #"""
    {"code":200,"msg":"操作成功","data":{
      "granularity":"DAY","timezone":"Asia/Shanghai",
      "mcpUsage":{
        "xTime":["2026-08-27","2026-08-28","2026-08-29"],
        "totalUsage":{"totalMcpCalls":26,"totalCredits":"26.4000"},
        "mcpSummaryList":null,
        "mcpDataList":[
          {"mcpCode":"search-prime","mcpName":"联网搜索 MCP","mcpNameI18n":"Web Search MCP","sortOrder":1,
           "mcpCallCount":[2,9,1],"creditsUsage":["1.0000","9.0000","1.0000"]},
          {"mcpCode":"web-reader","mcpName":"网页读取 MCP","sortOrder":2,
           "mcpCallCount":[0,7,7],"creditsUsage":["0.0000","7.0000","7.0000"]},
          {"mcpCode":"zread","mcpName":"ZRead","sortOrder":3,
           "mcpCallCount":[0,0,0],"creditsUsage":["0.0000","0.0000","0.0000"]}]}},
     "success":true}
    """#

    func testMcpDetailNamesToolsInEnglishWithFallbacksAndKeepsZeroCalls() throws {
        let tools = try XCTUnwrap(ZAICreditUsageMapper.parseMcpDetail(Data(mcpDetailJSON.utf8)))
        // English-localized name first, then the native name; a listed tool at 0 calls is kept.
        XCTAssertEqual(tools.tools, [
            ZAIToolUsageEntry(name: "Web Search MCP", calls: 12),
            ZAIToolUsageEntry(name: "网页读取 MCP", calls: 14),
            ZAIToolUsageEntry(name: "ZRead", calls: 0)
        ])
    }

    func testMcpDetailWithoutNamedToolsIsNil() {
        let empty = #"""
        {"data":{"mcpUsage":{"totalUsage":{"totalMcpCalls":0},"mcpDataList":[]}},"success":true}
        """#
        XCTAssertNil(ZAICreditUsageMapper.parseMcpDetail(Data(empty.utf8)))
    }

    // MARK: - The credit window merge and the lines it produces

    func testCreditPeriodsCarryTokensOnlyAndMcpRowCarriesCalls() throws {
        let now = Date(timeIntervalSince1970: 1_787_772_600) // 2026-08-27 03:30 Beijing
        let totals = ZAICreditUsageMapper.parseActivity(Data(activityJSON.utf8))
        let breakdown = ZAICreditUsageMapper.parseModelDetail(Data(modelDetailHourlyJSON.utf8))
        let recent = breakdown
        let tools = ZAICreditUsageMapper.parseMcpDetail(Data(mcpDetailJSON.utf8))

        let window = ZAICreditUsageMapper.window(totals: totals, breakdown: breakdown)
        // The activity tokens are the row value; the model split rides along for the hover breakdown.
        XCTAssertEqual(window?.totalTokens, 250_000_000)
        XCTAssertEqual(window?.modelUsage, breakdown?.modelUsage)
        // Either half alone still yields a window.
        XCTAssertEqual(ZAICreditUsageMapper.window(totals: totals, breakdown: nil)?.totalTokens,
                       250_000_000)
        XCTAssertNil(ZAICreditUsageMapper.window(totals: nil, breakdown: nil))

        let lines = ZAIActivityMapper.lines(
            window: window, recent: recent, tools: tools, platform: .cn, now: now
        )
        let last30 = try XCTUnwrap(values(lines, "Last 30 Days"))
        // Tokens only — the credit endpoints report no call counts, so no "· N calls" is invented.
        XCTAssertEqual(last30.map(\.label), ["tokens"])
        XCTAssertEqual(last30.first?.number, 250_000_000)

        let mcp = try XCTUnwrap(values(lines, "MCP Tools"))
        XCTAssertEqual(mcp.map(\.label), ["calls"])
        XCTAssertEqual(mcp.first?.number, 26)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }
}

// MARK: - Provider routing between the endpoint families

/// Fixtures and helpers for the routing tests, at file scope so the mock client's `@Sendable`
/// handler can read them from any executor.
private enum ZAICreditRoutingFixtures {
    static let creditQuotaJSON = #"""
    {"data":{"limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,"currentValue":4481,"percentage":16},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":140000,"currentValue":15150,"percentage":10}],
     "level":"max"},"success":true}
    """#

    static let tokenQuotaJSON = #"""
    {"data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":0}],"level":"pro"},"success":true}
    """#

    static let creditActivityJSON = #"""
    {"data":{"timezone":"Asia/Shanghai",
      "summary":{"totalTokens":250000000},
      "series":[{"date":"2026-08-29","totalTokens":69374046,"mcpCalls":2}]},"success":true}
    """#

    static let creditModelDetailJSON = #"""
    {"data":{"timezone":"Asia/Shanghai",
      "modelUsage":{"xTime":["2026-08-29 03:00:00"],
        "totalUsage":{"totalTokens":69374046},
        "modelDataList":[{"modelName":"GLM-5.3","totalTokensUsage":[69374046]}]}},
     "success":true}
    """#

    static let creditMcpDetailJSON = #"""
    {"data":{"mcpUsage":{"totalUsage":{"totalMcpCalls":26},
      "mcpDataList":[{"mcpCode":"search-prime","mcpNameI18n":"Web Search MCP","mcpCallCount":[26]}]}},
     "success":true}
    """#

    static let legacyModelUsageJSON = #"""
    {"data":{"x_time":["2026-08-29 03:00"],"tokensUsage":[4218893],"modelCallCount":[380],
      "totalUsage":{"totalTokensUsage":4218893,"totalModelCallCount":380},
      "modelDataList":[{"modelName":"GLM-5.3","tokensUsage":[4218893]}]},"success":true}
    """#

    static let legacyToolUsageJSON = #"""
    {"data":{"totalUsage":{"totalNetworkSearchCount":26,"totalWebReadMcpCount":18,"totalZreadMcpCount":0,
      "toolSummaryList":[{"toolCode":"search-prime","toolNameI18n":"Web Search MCP","totalUsageCount":26}]},
      "toolSummaryList":[{"toolCode":"search-prime","toolNameI18n":"Web Search MCP","totalUsageCount":26}]},
     "success":true}
    """#

    /// A fixed clock inside 2026-08-29 (03:30 Beijing) so every fixture day key resolves inside the
    /// trend window on the Mac's own calendar.
    static let now = Date(timeIntervalSince1970: 1_787_945_400)

    static func response(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

@MainActor
final class ZAICreditRoutingTests: XCTestCase {
    private func makeProvider(quotaJSON: String) -> (ZAIProvider, RoutingHTTPClient) {
        let client = RoutingHTTPClient { request in
            let url = request.url
            if url == ZAIUsageClient.quotaURL(.global) {
                return ZAICreditRoutingFixtures.response(quotaJSON)
            }
            if url.path == ZAIUsageClient.subscriptionPath {
                return ZAICreditRoutingFixtures.response(#"{"data":[]}"#)
            }
            if url.path == ZAIUsageClient.creditActivityPath {
                return ZAICreditRoutingFixtures.response(ZAICreditRoutingFixtures.creditActivityJSON)
            }
            if url.path == ZAIUsageClient.creditUsageDetailPath {
                let kind = url.queryPairs?["usageType"]
                return kind == "MCP"
                    ? ZAICreditRoutingFixtures.response(ZAICreditRoutingFixtures.creditMcpDetailJSON)
                    : ZAICreditRoutingFixtures.response(ZAICreditRoutingFixtures.creditModelDetailJSON)
            }
            if url.path == ZAIUsageClient.modelUsagePath {
                return ZAICreditRoutingFixtures.response(ZAICreditRoutingFixtures.legacyModelUsageJSON)
            }
            if url.path == ZAIUsageClient.toolUsagePath {
                return ZAICreditRoutingFixtures.response(ZAICreditRoutingFixtures.legacyToolUsageJSON)
            }
            return ZAICreditRoutingFixtures.response("{}")
        }
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])),
            usageClient: ZAIUsageClient(http: client),
            now: { ZAICreditRoutingFixtures.now }
        )
        return (provider, client)
    }

    func testCreditQuotaRoutesToTheCreditEndpointsAndDropsCallCounts() async throws {
        let (provider, client) = makeProvider(quotaJSON: ZAICreditRoutingFixtures.creditQuotaJSON)

        let snapshot = await provider.refresh()

        let paths = client.requests.map(\.url.path)
        // The credit family, and only it — the legacy history endpoints are not called.
        XCTAssertTrue(paths.contains(ZAIUsageClient.creditActivityPath))
        XCTAssertTrue(paths.contains(ZAIUsageClient.creditUsageDetailPath))
        XCTAssertFalse(paths.contains(ZAIUsageClient.modelUsagePath))
        XCTAssertFalse(paths.contains(ZAIUsageClient.toolUsagePath))
        // usage-detail is asked for both slices, and the credit URLs carry the token-view selector.
        let detailURLs = client.requests.map(\.url).filter { $0.path == ZAIUsageClient.creditUsageDetailPath }
        XCTAssertEqual(Set(detailURLs.compactMap { $0.queryPairs?["usageType"] }), ["MODEL", "MCP"])
        XCTAssertTrue(detailURLs.allSatisfy { $0.queryPairs?["type"] == "1" })

        // The rows: tokens from the activity accounting, no invented call counts, MCP from the detail.
        let last30 = try XCTUnwrap(snapshot.line(label: "Last 30 Days"))
        guard case .values(_, let values, _, _, _, _) = last30 else { return XCTFail("expected values") }
        XCTAssertEqual(values.map(\.label), ["tokens"])
        XCTAssertEqual(values.first?.number, 250_000_000)
        let mcp = try XCTUnwrap(snapshot.line(label: "MCP Tools"))
        guard case .values(_, let mcpValues, _, _, _, let breakdown) = mcp else { return XCTFail("expected values") }
        XCTAssertEqual(mcpValues.first?.number, 26)
        XCTAssertEqual(breakdown?.models.first?.model, "Web Search MCP")
        // The trend carries the activity series, today's bar included.
        guard case .chart(_, let points, _) = snapshot.line(label: "Usage Trend") else {
            return XCTFail("expected trend chart")
        }
        XCTAssertEqual(points.last?.value, 69_374_046)
        // Today reads the hourly model detail and lands on the Mac's calendar day.
        let today = try XCTUnwrap(snapshot.line(label: "Today"))
        guard case .values(_, let todayValues, _, _, _, _) = today else { return XCTFail("expected values") }
        XCTAssertEqual(todayValues.map(\.label), ["tokens"])
        XCTAssertEqual(todayValues.first?.number, 69_374_046)
    }

    func testTokenQuotaKeepsTheLegacyEndpoints() async {
        let (provider, client) = makeProvider(quotaJSON: ZAICreditRoutingFixtures.tokenQuotaJSON)

        let snapshot = await provider.refresh()

        let paths = client.requests.map(\.url.path)
        XCTAssertFalse(paths.contains(ZAIUsageClient.creditActivityPath))
        XCTAssertFalse(paths.contains(ZAIUsageClient.creditUsageDetailPath))
        XCTAssertTrue(paths.contains(ZAIUsageClient.modelUsagePath))
        XCTAssertTrue(paths.contains(ZAIUsageClient.toolUsagePath))
        // The legacy path still reports call counts.
        let last30 = snapshot.line(label: "Last 30 Days")
        guard case .values(_, let values, _, _, _, _)? = last30 else { return XCTFail("expected values") }
        XCTAssertEqual(values.map(\.label), ["tokens", "calls"])
    }
}

private extension URL {
    /// Query names to first values, decoded — a read helper for asserting request parameters.
    var queryPairs: [String: String]? {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        var pairs: [String: String] = [:]
        for item in items where item.value != nil { pairs[item.name] = item.value }
        return pairs
    }
}
