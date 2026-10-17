import XCTest
@testable import OpenUsage

private let accountTestEpoch = 1_800_000_000
private let accountTestNow = Date(timeIntervalSince1970: TimeInterval(accountTestEpoch))

private func accountCredentials(_ name: String, expiresAt: Int = accountTestEpoch + 600) -> String {
    """
    {"access_token":"\(name)-access","refresh_token":"\(name)-refresh","expires_at":\(expiresAt)}
    """
}

private func accountUsage(_ used: Int) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data("""
    {"usage":{"limit":100,"used":\(used),"remaining":\(100 - used),"resetTime":"2030-01-01T00:00:00Z"}}
    """.utf8))
}

private actor AccountHTTPClient: HTTPClient {
    enum Failure: Error { case unexpectedRequest }

    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw Failure.unexpectedRequest }
        return responses.removeFirst()
    }
}

private actor AccountPricingProbe {
    let pricing: ModelPricing
    private(set) var loads = 0

    init(_ pricing: ModelPricing) {
        self.pricing = pricing
    }

    func load() -> ModelPricing {
        loads += 1
        return pricing
    }
}

final class KimiAPIKeyAuthStoreTests: XCTestCase {
    func testAPIKeyReadersAreIsolatedFromOAuthAndOtherKeyFiles() throws {
        let firstPath = "/accounts/first-key.json"
        let secondPath = "/accounts/second-key.json"
        let files = FakeFiles([
            KimiAuthStore.credentialsPath: accountCredentials("default"),
            KimiAuthStore.deviceIDPath: "default-device",
            KimiAuthStore.regionPath: "cn",
            firstPath: #"{"apiKey":"first-test-key"}"#,
            secondPath: #"{"api_key":"second-test-key"}"#
        ])
        let first = KimiAuthStore(files: files, apiKeyPath: firstPath, regionOverride: " GLOBAL\n")
        let second = KimiAuthStore(files: files, apiKeyPath: secondPath, regionOverride: "cn")
        let defaultStore = KimiAuthStore(files: files)

        XCTAssertTrue(first.usesAPIKey)
        XCTAssertTrue(second.usesAPIKey)
        XCTAssertFalse(defaultStore.usesAPIKey)
        XCTAssertEqual(first.loadAPIKey(), "first-test-key")
        XCTAssertEqual(second.loadAPIKey(), "second-test-key")
        XCTAssertEqual(first.region(), "global")
        XCTAssertEqual(second.region(), "cn")
        XCTAssertNil(first.loadCredentials())
        XCTAssertNil(second.loadCredentials())
        XCTAssertNil(first.deviceID())
        XCTAssertNil(second.deviceID())
        XCTAssertNil(defaultStore.loadAPIKey())
        XCTAssertEqual(defaultStore.deviceID(), "default-device")

        let oauth = try XCTUnwrap(defaultStore.loadCredentials())
        XCTAssertEqual(oauth.accessToken, "default-access")
        let initialFiles = files.files
        XCTAssertThrowsError(try first.save(oauth)) { error in
            XCTAssertEqual(error as? KimiAuthError, .invalidAuthPayload)
        }
        XCTAssertEqual(files.files, initialFiles, "API-key mode must not write OAuth or key files")

        for invalidSource in [nil, "{", accountCredentials("wrong-mode")] as [String?] {
            files.files[firstPath] = invalidSource
            XCTAssertNil(first.loadAPIKey())
            XCTAssertTrue(first.usesAPIKey)
            XCTAssertNil(first.loadCredentials(), "A missing or invalid key must not fall back to OAuth")
            XCTAssertNil(first.deviceID())
            XCTAssertEqual(second.loadAPIKey(), "second-test-key")
            XCTAssertEqual(defaultStore.loadCredentials()?.accessToken, "default-access")
        }
    }
}

@MainActor
final class KimiAccountBackendTests: XCTestCase {
    private func makeProvider(
        files: FakeFiles,
        path: String,
        http: AccountHTTPClient,
        id: String,
        region: String = "cn"
    ) -> KimiProvider {
        KimiProvider(
            authStore: KimiAuthStore(
                files: files, now: { accountTestNow }, apiKeyPath: path, regionOverride: region
            ),
            usageClient: KimiUsageClient(http: http),
            pricing: { .empty },
            now: { accountTestNow },
            id: id,
            accountLabel: id,
            scansLocalLogs: false
        )
    }

    private func weeklyUsage(_ snapshot: ProviderSnapshot) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _, _) = snapshot.line(label: "Weekly") else { return nil }
        return used
    }

    func testTwoAPIKeyCardsUseIndependentHeadersAndWidgetIdentities() async {
        let firstPath = "/accounts/first-key.json"
        let secondPath = "/accounts/second-key.json"
        let files = FakeFiles([
            KimiAuthStore.credentialsPath: accountCredentials("default", expiresAt: accountTestEpoch - 1),
            firstPath: #"{"apiKey":"first-test-key"}"#,
            secondPath: #"{"apiKey":"second-test-key"}"#
        ])
        let firstHTTP = AccountHTTPClient([accountUsage(17)])
        let secondHTTP = AccountHTTPClient([accountUsage(63)])
        let first = makeProvider(files: files, path: firstPath, http: firstHTTP, id: "kimi-first")
        let second = makeProvider(files: files, path: secondPath, http: secondHTTP, id: "kimi-second", region: "global")

        let firstSnapshot = await first.refresh()
        let secondSnapshot = await second.refresh()
        let firstAvailable = await first.hasLocalCredentials()
        let secondAvailable = await second.hasLocalCredentials()

        XCTAssertTrue(firstAvailable)
        XCTAssertTrue(secondAvailable)
        XCTAssertNil(firstSnapshot.errorCategory)
        XCTAssertNil(secondSnapshot.errorCategory)
        XCTAssertEqual(weeklyUsage(firstSnapshot), 17)
        XCTAssertEqual(weeklyUsage(secondSnapshot), 63)
        XCTAssertEqual(first.provider.familyName, "Kimi Code")
        XCTAssertEqual(first.provider.accountLabel, "kimi-first")
        XCTAssertEqual(firstSnapshot.displayName, "Kimi Code — kimi-first")
        XCTAssertTrue(first.widgetDescriptors.allSatisfy { $0.id.hasPrefix("kimi-first.") && $0.providerID == "kimi-first" })
        XCTAssertTrue(second.widgetDescriptors.allSatisfy { $0.id.hasPrefix("kimi-second.") && $0.providerID == "kimi-second" })
        XCTAssertTrue(Set(first.widgetDescriptors.map(\.id)).isDisjoint(with: second.widgetDescriptors.map(\.id)))

        let firstRequests = await firstHTTP.requests
        let secondRequests = await secondHTTP.requests
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertEqual(secondRequests.count, 1)
        XCTAssertEqual(firstRequests.first?.url, KimiUsageClient.cnUsageURL)
        XCTAssertEqual(secondRequests.first?.url, KimiUsageClient.globalUsageURL)
        XCTAssertEqual(firstRequests.first?.method, "GET")
        XCTAssertEqual(firstRequests.first?.headers["x-api-key"], "first-test-key")
        XCTAssertEqual(secondRequests.first?.headers["x-api-key"], "second-test-key")
        XCTAssertNil(firstRequests.first?.headers["Authorization"])
        XCTAssertNil(secondRequests.first?.headers["Authorization"])
        XCTAssertNil(firstRequests.first?.body)
    }

    func testRejectedAPIKeyNeverRefreshesOrFallsBackToDefaultOAuth() async {
        for status in [401, 403] {
            let keyPath = "/accounts/key.json"
            let initialFiles = [
                KimiAuthStore.credentialsPath: accountCredentials("default", expiresAt: accountTestEpoch - 1),
                keyPath: #"{"apiKey":"rejected-test-key"}"#
            ]
            let files = FakeFiles(initialFiles)
            let http = AccountHTTPClient([HTTPResponse(statusCode: status, headers: [:], body: Data())])
            let provider = makeProvider(files: files, path: keyPath, http: http, id: "kimi-key")

            let snapshot = await provider.refresh()
            let requests = await http.requests

            XCTAssertEqual(snapshot.errorCategory, .authInvalid)
            guard case .badge(_, let message, _, _) = snapshot.lines.first else {
                return XCTFail("Expected actionable API-key error")
            }
            XCTAssertTrue(message.contains("API key"))
            XCTAssertTrue(message.contains("Coding Plan"))
            XCTAssertFalse(message.contains("/login"))
            XCTAssertFalse(message.contains("rejected-test-key"))
            XCTAssertEqual(requests.count, 1, "A key rejection must not enter the OAuth retry path")
            XCTAssertEqual(requests.first?.url, KimiUsageClient.cnUsageURL)
            XCTAssertEqual(requests.first?.headers["x-api-key"], "rejected-test-key")
            XCTAssertNil(requests.first?.headers["Authorization"])
            XCTAssertEqual(files.files, initialFiles)
        }
    }

    func testMissingOrInvalidAPIKeyDoesNotUseAvailableDefaultLogin() async {
        let keyPath = "/accounts/missing.json"
        let files = FakeFiles([KimiAuthStore.credentialsPath: accountCredentials("default")])
        for invalidSource in [nil, "{", accountCredentials("wrong-mode")] as [String?] {
            files.files[keyPath] = invalidSource
            let initialFiles = files.files
            let http = AccountHTTPClient([])
            let provider = makeProvider(files: files, path: keyPath, http: http, id: "kimi-missing")

            let available = await provider.hasLocalCredentials()
            let snapshot = await provider.refresh()
            let requests = await http.requests

            XCTAssertFalse(available)
            XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(files.files, initialFiles)
            guard case .badge(_, let message, _, _) = snapshot.lines.first else {
                return XCTFail("Expected API-key guidance")
            }
            XCTAssertTrue(message.contains("API key"))
            XCTAssertTrue(message.contains("Customize"))
            XCTAssertFalse(message.contains("/login"))
            XCTAssertFalse(message.contains("file"))
            XCTAssertFalse(message.contains(keyPath))
        }
    }

    func testExtraCardsDoNotMultiplyDefaultCLISpendOrLoadPricing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: accountTestNow)
        try """
        {"envelope":{"timestamp":"\(timestamp)","payload":{"model":"test-kimi","usage":{"inputOther":100,"output":50}}}}
        """.write(to: directory.appendingPathComponent("session_test.jsonl"), atomically: true, encoding: .utf8)
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "test-kimi": ModelRates(inputPerMillion: 2, outputPerMillion: 4, cacheWritePerMillion: 2, cacheReadPerMillion: 0.2)
            ]),
            primary: PricingCatalog(), secondary: PricingCatalog()
        )
        let probe = AccountPricingProbe(pricing)
        let files = FakeFiles([
            KimiAuthStore.credentialsPath: accountCredentials("default"),
            "/accounts/first.json": #"{"apiKey":"first-test-key"}"#,
            "/accounts/second.json": #"{"apiKey":"second-test-key"}"#
        ])
        let piScanner = PiUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { directory })
        let cliScanner = KimiCLIUsageScanner(eventsDirectory: { directory })
        let openCodeScanner = OpenCodeSubscriptionUsageScanner(databasePaths: { [] })
        var snapshots: [ProviderSnapshot] = []
        for (id, path) in [("kimi", nil), ("kimi-first", "/accounts/first.json"), ("kimi-second", "/accounts/second.json")] as [(String, String?)] {
            let provider = KimiProvider(
                authStore: KimiAuthStore(files: files, now: { accountTestNow }, apiKeyPath: path),
                usageClient: KimiUsageClient(http: AccountHTTPClient([accountUsage(20)])),
                piScanner: piScanner, cliScanner: cliScanner, openCodeSubscriptionScanner: openCodeScanner,
                pricing: { await probe.load() }, now: { accountTestNow }, id: id, scansLocalLogs: path == nil
            )
            snapshots.append(await provider.refresh())
        }

        XCTAssertTrue(snapshots.allSatisfy { $0.errorCategory == nil })
        let defaultHistory = try XCTUnwrap(snapshots[0].usageHistory)
        XCTAssertEqual(defaultHistory.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertEqual(defaultHistory.series.daily.compactMap(\.costUSD).reduce(0, +), 0.0004, accuracy: 0.0000001)
        XCTAssertNotNil(snapshots[0].line(label: "Today"))
        for snapshot in snapshots.dropFirst() {
            XCTAssertNil(snapshot.usageHistory)
            XCTAssertNil(snapshot.line(label: "Today"))
            XCTAssertNil(snapshot.line(label: "Last 30 Days"))
            XCTAssertEqual(weeklyUsage(snapshot), 20)
        }
        let pricingLoads = await probe.loads
        XCTAssertEqual(pricingLoads, 1, "Extra-account refreshes must bypass local scanning, including pricing")
    }
}
