import XCTest
@testable import OpenUsage

private let quotaJSON = #"""
{"code":200,"msg":"Operation successful","data":{"limits":[
  {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":28000,"currentValue":1030,"remaining":26970,"percentage":3,"nextResetTime":1787782033933},
  {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":140000,"currentValue":1474,"remaining":138526,"percentage":1,"nextResetTime":1788075596997}
],"level":"max"},"success":true}
"""#

private let subscriptionJSON = #"""
{"code":200,"data":[{"productName":"GLM Coding Max","status":"VALID","nextRenewTime":"2026-09-16","inCurrentPeriod":true}],"success":true}
"""#

/// Fixed instant every Z.ai card test refreshes at.
private let testNow = Date(timeIntervalSince1970: 1_787_772_600)

/// A daily-bucket `model-usage` payload anchored on `testNow`, so Today / Yesterday resolve the same
/// way wherever the suite runs.
private var modelUsageJSON: String {
    let days = (0...1).map { offset -> String in
        let day = Calendar.current.date(byAdding: .day, value: -offset, to: testNow) ?? testNow
        return DailyUsageAccumulator.dayKey(from: day)
    }
    return """
    {"success":true,"data":{
      "x_time":["\(days[1])","\(days[0])"],
      "tokensUsage":[2000000,1000000],
      "modelCallCount":[20,10],
      "totalUsage":{"totalTokensUsage":3000000,"totalModelCallCount":30},
      "modelDataList":[{"modelName":"GLM-5.3","tokensUsage":[2000000,1000000],"totalTokens":3000000}],
      "granularity":"daily"}}
    """
}

private let toolUsageJSON = #"""
{"success":true,"data":{"totalUsage":{"totalNetworkSearchCount":1,"totalWebReadMcpCount":3,"totalZreadMcpCount":0}}}
"""#

private func jsonResponse(_ json: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
}

/// Routes by path so a test doesn't have to know which host the platform picked.
private func zaiRoutingClient(
    record: (@Sendable (URL) -> Void)? = nil,
    modelUsage: @escaping @Sendable () -> HTTPResponse = { jsonResponse(modelUsageJSON) }
) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        record?(request.url)
        switch request.url.path {
        case ZAIUsageClient.quotaPath: return jsonResponse(quotaJSON)
        case ZAIUsageClient.subscriptionPath: return jsonResponse(subscriptionJSON)
        case ZAIUsageClient.modelUsagePath: return modelUsage()
        case ZAIUsageClient.toolUsagePath: return jsonResponse(toolUsageJSON)
        default:
            XCTFail("unexpected Z.ai request path \(request.url.path)")
            return jsonResponse("{}")
        }
    }
}

// MARK: - Platform storage

final class ZAIPlatformStorageTests: XCTestCase {
    private let primary = ZAIAuthStore.configPaths[0]

    func testMissingPlatformFieldReadsAsGlobal() {
        let store = ZAIAuthStore(files: FakeFiles([primary: #"{"api_key":"zai-json"}"#]),
                                 environment: FakeEnvironment())
        XCTAssertEqual(store.loadPlatform(), .global)
        XCTAssertEqual(store.loadAPIKey()?.platform, .global)
    }

    func testSnakeCaseKeyAndPlatformAreReadTogether() {
        let store = ZAIAuthStore(files: FakeFiles([primary: #"{"api_key":"zai-json","platform":"cn"}"#]),
                                 environment: FakeEnvironment())
        let auth = store.loadAPIKey()
        XCTAssertEqual(auth?.apiKey, "zai-json")
        XCTAssertEqual(auth?.platform, .cn)
    }

    func testCamelCaseKeyAndUnknownPlatformFallBackToGlobal() {
        let store = ZAIAuthStore(files: FakeFiles([primary: #"{"apiKey":"zai-json","platform":"mars"}"#]),
                                 environment: FakeEnvironment())
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-json")
        XCTAssertEqual(store.loadPlatform(), .global)
    }

    func testPlatformAppliesToAnEnvironmentOnlyKey() throws {
        let files = FakeFiles()
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment(["ZAI_API_KEY": "zai-env"]))

        try store.savePlatform(.cn)

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-env")
        XCTAssertEqual(store.loadAPIKey()?.platform, .cn)
        // A platform-only file must not read as a saved key, or the editor would offer to clear one.
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }

    func testSavingPlatformKeepsTheStoredKey() throws {
        let files = FakeFiles([primary: #"{"api_key":"zai-json"}"#])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.savePlatform(.cn)

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "zai-json")
        XCTAssertEqual(store.loadPlatform(), .cn)
    }

    func testSavingAKeyKeepsThePlatformChoice() throws {
        let files = FakeFiles([primary: #"{"api_key":"old","platform":"cn"}"#])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  new-key  ")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "new-key")
        XCTAssertEqual(store.loadPlatform(), .cn)
    }

    func testClearingTheKeyKeepsThePlatformChoice() throws {
        let files = FakeFiles([primary: #"{"apiKey":"zai-json","platform":"cn"}"#])
        let store = ZAIAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertEqual(store.keyStatus(), .notSet)
        XCTAssertEqual(store.loadPlatform(), .cn)
    }
}

// MARK: - Hosts, links, error copy

final class ZAIPlatformRoutingTests: XCTestCase {
    func testEveryEndpointFollowsTheChosenHost() {
        XCTAssertEqual(ZAIUsageClient.quotaURL(.global).absoluteString, "https://api.z.ai/api/monitor/usage/quota/limit")
        XCTAssertEqual(ZAIUsageClient.subscriptionURL(.global).absoluteString, "https://api.z.ai/api/biz/subscription/list")
        XCTAssertEqual(ZAIUsageClient.modelUsageURL(.cn).absoluteString, "https://open.bigmodel.cn/api/monitor/usage/model-usage")
        XCTAssertEqual(ZAIUsageClient.toolUsageURL(.cn).absoluteString, "https://open.bigmodel.cn/api/monitor/usage/tool-usage")
    }

    func testQuickLinksPointAtTheChosenConsole() {
        XCTAssertEqual(ZAIPlatform.global.links.map(\.url), [
            "https://z.ai/manage-apikey/coding-plan/personal/my-plan",
            "https://z.ai/manage-apikey/apikey-list"
        ])
        XCTAssertEqual(ZAIPlatform.cn.links.map(\.url), [
            "https://open.bigmodel.cn/coding-plan/personal/overview",
            "https://open.bigmodel.cn/apikey"
        ])
        XCTAssertEqual(ZAIPlatform.cn.links.map(\.label), ["Dashboard", "API Keys"])
    }

    func testErrorCopyNamesTheChosenConsole() {
        XCTAssertEqual(ZAIAuthError.invalidKey(.global).errorDescription,
                       "Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list.")
        XCTAssertEqual(ZAIAuthError.invalidKey(.cn).errorDescription,
                       "Z.ai API key invalid. Check your key at open.bigmodel.cn/apikey.")
        XCTAssertEqual(ZAIUsageError.noCodingPlan(.global).errorDescription,
                       "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.")
        XCTAssertEqual(ZAIUsageError.noCodingPlan(.cn).errorDescription,
                       "No active GLM Coding Plan. Subscribe at open.bigmodel.cn/glm-coding to see usage.")
    }

    @MainActor
    func testRefreshSendsEveryRequestToTheStoredPlatformsHost() async {
        let hosts = Hosts()
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"api_key":"zai-test","platform":"cn"}"#]),
                environment: FakeEnvironment()
            ),
            usageClient: ZAIUsageClient(http: zaiRoutingClient(record: { hosts.add($0.host ?? "") })),
            now: { testNow }
        )

        _ = await provider.refresh()

        XCTAssertEqual(hosts.seen, ["open.bigmodel.cn"])
        XCTAssertEqual(provider.provider.links.map(\.url).first, "https://open.bigmodel.cn/coding-plan/personal/overview")
    }

    @MainActor
    func testSelectingAPlatformPersistsItAndMovesTheLinks() throws {
        let files = FakeFiles([ZAIAuthStore.configPaths[0]: #"{"api_key":"zai-test"}"#])
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: files, environment: FakeEnvironment()),
            usageClient: ZAIUsageClient(http: zaiRoutingClient())
        )
        XCTAssertEqual(provider.selectedPlatformID, "global")
        XCTAssertEqual(provider.platformOptions.map(\.id), ["global", "cn"])
        XCTAssertEqual(provider.platformOptions.map(\.host), ["api.z.ai", "open.bigmodel.cn"])

        try provider.selectPlatform("cn")

        XCTAssertEqual(provider.selectedPlatformID, "cn")
        XCTAssertEqual(provider.provider.links.map(\.url).last, "https://open.bigmodel.cn/apikey")
        XCTAssertEqual(provider.currentAPIKey(), "zai-test")
    }

    /// Collects the hosts a refresh actually talked to, from the HTTP stub's background callback.
    private final class Hosts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: Set<String> = []
        func add(_ host: String) { lock.lock(); values.insert(host); lock.unlock() }
        var seen: Set<String> { lock.lock(); defer { lock.unlock() }; return values }
    }
}

// MARK: - Card contents

@MainActor
final class ZAICardContentsTests: XCTestCase {
    private func makeProvider(
        modelUsage: @escaping @Sendable () -> HTTPResponse = { jsonResponse(modelUsageJSON) }
    ) -> ZAIProvider {
        ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])),
            usageClient: ZAIUsageClient(http: zaiRoutingClient(modelUsage: modelUsage)),
            now: { testNow }
        )
    }

    func testRefreshBuildsEveryRowInDisplayOrder() async {
        let snapshot = await makeProvider().refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "GLM Coding Max")
        XCTAssertEqual(snapshot.lines.map(\.label),
                       ["Session", "Weekly", "Usage Trend", "Today", "Yesterday", "Last 30 Days",
                        "MCP Tools", "Renews"])
    }

    func testSessionAndWeeklyKeepPercentAndGainAbsoluteCredits() async throws {
        let snapshot = await makeProvider().refresh()

        guard case .progress(_, let used, let limit, let format, _, _, _, let detail) =
                try XCTUnwrap(snapshot.line(label: "Session")) else {
            return XCTFail("Session is not a progress line")
        }
        XCTAssertEqual(used, 3, accuracy: 0.001)
        XCTAssertEqual(limit, 100, accuracy: 0.001)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(detail, "1,030 / 28,000 credits")

        guard case .progress(_, _, _, _, _, _, _, let weeklyDetail) =
                try XCTUnwrap(snapshot.line(label: "Weekly")) else {
            return XCTFail("Weekly is not a progress line")
        }
        XCTAssertEqual(weeklyDetail, "1,474 / 140,000 credits")
    }

    func testCreditsDetailIsAbsentWithoutBothFigures() {
        XCTAssertNil(ZAIUsageMapper.creditsDetail(["percentage": 3]))
        XCTAssertNil(ZAIUsageMapper.creditsDetail(["currentValue": 10, "usage": 0]))
        XCTAssertEqual(ZAIUsageMapper.creditsDetail(["currentValue": 10, "usage": 20]), "10 / 20 credits")
    }

    func testUsageHistoryFailureLeavesTheMetersIntact() async {
        let snapshot = await makeProvider(modelUsage: {
            HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
        }).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "MCP Tools"))
        XCTAssertNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNil(snapshot.line(label: "Last 30 Days"))
    }

    func testSnapshotCarriesAccountWideUsageHistory() async throws {
        let snapshot = await makeProvider().refresh()
        let history = try XCTUnwrap(snapshot.usageHistory)
        XCTAssertEqual(history.series.daily.map(\.totalTokens), [2_000_000, 1_000_000])
        XCTAssertTrue(history.series.daily.allSatisfy { $0.costUSD == nil })

        let descriptor = try XCTUnwrap(
            WidgetRegistry.from([ZAIProvider()]).historyDescriptorsByProvider["zai"]
        )
        // Account-wide, so it is never merged across Macs or written to the iCloud sync file.
        XCTAssertEqual(descriptor.scope, .accountWide)
        XCTAssertFalse(descriptor.estimatedCost)
    }
}

// MARK: - Layout defaults and the local API

@MainActor
final class ZAILayoutAndWireTests: XCTestCase {
    private func makeLayout() -> LayoutStore {
        let suiteName = "OpenUsageTests.ZAILayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return LayoutStore(
            registry: WidgetRegistry.from([ZAIProvider()]),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: DefaultLayout.metricIDs,
            defaultPinnedMetricIDs: DefaultLayout.pinnedMetricIDs,
            defaultExpandedMetricIDs: DefaultLayout.expandedMetricIDs
        )
    }

    func testDescriptorsDeclareTheCardsOrder() {
        XCTAssertEqual(ZAIProvider().widgetDescriptors.map(\.id), [
            "zai.session", "zai.weekly", "zai.webSearches", "zai.trend",
            "zai.today", "zai.yesterday", "zai.last30", "zai.mcpTools", "zai.renews"
        ])
        // The trend can't be drawn in the menu bar, so it never offers a pin.
        let trend = ZAIProvider().widgetDescriptors.first { $0.id == "zai.trend" }
        XCTAssertEqual(trend?.pinnable, false)
        // Z.ai prices nothing, so its period rows must not feed the Total Spend card.
        XCTAssertFalse(ZAIProvider().widgetDescriptors.contains { $0.isSpendTile })
    }

    func testFreshDefaultsEnableEveryRowWithTheTrendAboveTheFold() {
        let group = makeLayout().displayGroups.first { $0.provider.id == "zai" }
        XCTAssertEqual(group?.alwaysShownWidgets.map(\.descriptorID),
                       ["zai.session", "zai.weekly", "zai.trend"])
        XCTAssertEqual(group?.expandedWidgets.map(\.descriptorID),
                       ["zai.webSearches", "zai.today", "zai.yesterday", "zai.last30", "zai.mcpTools", "zai.renews"])
    }

    func testFreshDefaultsPinOnlySessionAndWeekly() {
        XCTAssertEqual(makeLayout().pinnedGroups.flatMap { $0.metrics.map(\.id) },
                       ["zai.session", "zai.weekly"])
    }

    func testLocalAPIExportsTheNewRowsAndTheCreditsDetail() throws {
        let snapshot = ProviderSnapshot(
            providerID: "zai",
            displayName: "Z.ai",
            lines: [
                .progress(label: "Session", used: 3, limit: 100, format: .percent, detail: "1,030 / 28,000 credits"),
                .progress(label: "Weekly", used: 1, limit: 100, format: .percent),
                .chart(label: "Usage Trend", points: [MetricChartPoint(value: 5, label: "Aug 27", valueLabel: "5 tokens")], note: "note"),
                .values(label: "Today", values: [
                    MetricValue(number: 66_100_000, kind: .count, label: "tokens"),
                    MetricValue(number: 426, kind: .count, label: "calls")
                ]),
                .values(label: "MCP Tools", values: [
                    MetricValue(number: 1, kind: .count, label: "searches"),
                    MetricValue(number: 3, kind: .count, label: "reads"),
                    MetricValue(number: 0, kind: .count, label: "ZRead")
                ])
            ],
            refreshedAt: testNow
        )
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["zai"], knownIDs: ["zai"], snapshots: ["zai": snapshot])
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state)
        let body = try XCTUnwrap(response.body)
        let cards = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let lines = try XCTUnwrap(cards.first?["lines"] as? [[String: Any]])

        XCTAssertEqual(lines.map { $0["label"] as? String },
                       ["Session", "Weekly", "Usage Trend", "Today", "MCP Tools"])
        // The credits detail rides along only where a provider supplied one.
        XCTAssertEqual(lines[0]["detail"] as? String, "1,030 / 28,000 credits")
        XCTAssertNil(lines[1]["detail"])
        // The trend keeps the documented bar-chart shape; the period rows keep the combined string.
        XCTAssertEqual(lines[2]["type"] as? String, "barChart")
        XCTAssertEqual(lines[3]["value"] as? String, "66.1M tokens · 426 calls")
        XCTAssertEqual(lines[4]["value"] as? String, "1 searches · 3 reads · 0 ZRead")
    }
}
