import XCTest
@testable import OpenUsage

/// Verifies the Swift mapper against a captured live Z.ai API response. Both endpoints are
/// undocumented internal APIs, so this guards the mapping against the real shape — not just the
/// fixtures in `ZAIProviderTests`. Anonymized: the key, customer id, and agreement number are gone;
/// only the structural fields the mapper reads remain. Run locally with `swift test --filter ZAILive`.
final class ZAILiveResponseMappingTests: XCTestCase {
    // Captured from a GLM Coding Pro plan on 2026-06-29. Strips PII; keeps the fields the mapper reads.
    private let liveQuota = #"""
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17,"nextResetTime":1782724971179},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3,"nextResetTime":1783305486997},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":0,"remaining":1000,"percentage":0,"nextResetTime":1785292686976,"usageDetails":[{"modelCode":"search-prime","usage":0},{"modelCode":"web-reader","usage":0},{"modelCode":"zread","usage":0}]}
    ],"level":"pro"},"success":true}
    """#

    // Captured from a GLM Coding Lite plan on 2026-08-13. Z.ai renamed the percentage quota type
    // from TOKENS_LIMIT to CREDIT_LIMIT and no longer includes reset time for the active 5-hour window.
    private let liveCreditQuota = #"""
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":0,"remaining":2000,"percentage":0},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":9855,"remaining":145,"percentage":98,"nextResetTime":1786685679998}
    ],"level":"lite"},"success":true}
    """#

    private let liveSubscription = #"""
    {"code":200,"msg":"Operation successful","data":[{"productName":"GLM Coding Pro","status":"VALID","nextRenewTime":"2026-07-29","billingCycle":"monthly","inCurrentPeriod":true}],"success":true}
    """#

    func testMapsLiveResponseToSessionWeeklyAndWebSearches() throws {
        let mapped = try ZAIUsageMapper.map(
            quotaBody: Data(liveQuota.utf8),
            subscriptionBody: Data(liveSubscription.utf8)
        )

        XCTAssertEqual(mapped.plan, "GLM Coding Pro")

        let session = try XCTUnwrap(progress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 17, accuracy: 0.001)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 3, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        let web = try XCTUnwrap(progress(mapped.lines, "Web Searches"))
        XCTAssertEqual(web.used, 0, accuracy: 0.001)
        XCTAssertEqual(web.limit, 1000, accuracy: 0.001)
    }

    func testMapsCurrentCreditLimitResponseToSessionAndWeekly() throws {
        let mapped = try ZAIUsageMapper.map(quotaBody: Data(liveCreditQuota.utf8), subscriptionBody: nil)

        let session = try XCTUnwrap(progress(mapped.lines, "Session"))
        XCTAssertEqual(session.used, 0, accuracy: 0.001)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)

        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.used, 98, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)
    }

    func testCreditQuotaSurfacesTheAbsoluteCreditsUnderEachMeter() throws {
        // The current CREDIT_LIMIT shape carries the raw credits behind the percentage.
        let mapped = try ZAIUsageMapper.map(quotaBody: Data(liveCreditQuota.utf8), subscriptionBody: nil)
        XCTAssertEqual(detail(mapped.lines, "Session"), "0 / 2,000 credits")
        XCTAssertEqual(detail(mapped.lines, "Weekly"), "9,855 / 10,000 credits")

        // The older TOKENS_LIMIT shape reported percentages only, so those rows carry no detail.
        let legacy = try ZAIUsageMapper.map(quotaBody: Data(liveQuota.utf8), subscriptionBody: nil)
        XCTAssertNil(detail(legacy.lines, "Session"))
        XCTAssertNil(detail(legacy.lines, "Weekly"))
    }

    // Captured from a GLM Coding Max plan on 2026-08-27, trimmed to the fields the mapper reads. A
    // 30-day range comes back in whole (Beijing) days; a range up to seven days comes back hourly.
    private let liveModelUsage = #"""
    {"code":200,"msg":"Operation successful","success":true,"data":{
      "x_time":["2026-08-25","2026-08-26","2026-08-27"],
      "modelCallCount":[251,426,163],
      "tokensUsage":[43297075,66148252,11986486],
      "totalUsage":{"totalModelCallCount":840,"totalTokensUsage":121431813,
        "modelSummaryList":[{"modelName":"GLM-5.3","totalTokens":100000000,"sortOrder":1},
                            {"modelName":"GLM-5.2","totalTokens":21431813,"sortOrder":2}]},
      "modelDataList":[
        {"modelName":"GLM-5.3","sortOrder":1,"tokensUsage":[40000000,50000000,10000000],"totalTokens":100000000},
        {"modelName":"GLM-5.2","sortOrder":2,"tokensUsage":[3297075,16148252,1986486],"totalTokens":21431813}],
      "modelSummaryList":[{"modelName":"GLM-5.3","totalTokens":100000000,"sortOrder":1}],
      "granularity":"daily"}}
    """#

    private let liveToolUsage = #"""
    {"code":200,"msg":"Operation successful","success":true,"data":{
      "x_time":["2026-08-25","2026-08-26","2026-08-27"],
      "networkSearchCount":[0,4,1],"webReadMcpCount":[2,5,0],"zreadMcpCount":[0,0,0],
      "totalUsage":{"totalNetworkSearchCount":15,"totalWebReadMcpCount":12,"totalZreadMcpCount":0,
        "totalSearchMcpCount":27,
        "toolDetails":[{"modelName":"search-prime","totalUsageCount":15}],
        "toolSummaryList":[{"toolCode":"search-prime","toolName":"联网搜索 MCP","toolNameI18n":"Web Search MCP","totalUsageCount":15,"sortOrder":1},
                           {"toolCode":"web-reader","toolName":"网页读取 MCP","toolNameI18n":"Web Read MCP","totalUsageCount":12,"sortOrder":2}]},
      "toolDataList":[{"toolCode":"search-prime","toolName":"联网搜索 MCP","toolNameI18n":"Web Search MCP","sortOrder":1,"usageCount":[0,4,1],"totalUsageCount":15}],
      "granularity":"daily"}}
    """#

    func testMapsLiveUsageHistoryResponses() throws {
        let activity = try XCTUnwrap(ZAIActivityMapper.parseModelUsage(Data(liveModelUsage.utf8)))
        XCTAssertEqual(activity.totalTokens, 121_431_813)
        XCTAssertEqual(activity.totalCalls, 840)
        XCTAssertEqual(activity.tokensByDay["2026-08-26"], 66_148_252)
        XCTAssertEqual(activity.callsByDay["2026-08-26"], 426)
        XCTAssertEqual(activity.modelUsage.daily.first { $0.date == "2026-08-26" }?.models.map(\.model),
                       ["GLM-5.3", "GLM-5.2"])

        let tools = try XCTUnwrap(ZAIActivityMapper.parseToolUsage(Data(liveToolUsage.utf8)))
        XCTAssertEqual(tools, ZAIToolActivity(webSearches: 15, webReads: 12, zreadCalls: 0))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, _, let period, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, period)
    }

    private func detail(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .progress(_, _, _, _, _, _, _, let detail) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return detail
    }
}
