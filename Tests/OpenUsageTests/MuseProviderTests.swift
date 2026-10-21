import XCTest
@testable import OpenUsage

final class MuseProviderTests: XCTestCase {
    private let sampleKeyResponse = #"""
    {
      "api_key": "meta_sk_test",
      "base_url": "https://api.meta.ai/v1",
      "has_payment_method": true,
      "require_payment": false,
      "is_subs_active": true,
      "can_subscribe": false,
      "show_subs_upsell": true,
      "user_full_name": "Della Biddle",
      "user_email": "dellabiddle1@gmail.com",
      "user_avatar_url": null,
      "payment_method": "Mastercard-4743",
      "action_url": null,
      "subs_tier_id": "27681631238169137",
      "subs_tier_name": "Muse Code Power Usage",
      "is_subs_upgrade_available": true,
      "subs_usage": {
        "window": {
          "used_percent": 15,
          "window_duration_mins": 300,
          "resets_at": 1792267278
        },
        "weekly": {
          "used_percent": 42,
          "resets_at": 1792368000
        },
        "tier": "27681631238169137"
      }
    }
    """#

    func testMapperExtractsPowerUsagePlanAndBothWindows() throws {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(sampleKeyResponse.utf8))
        let mapped = try MuseUsageMapper.map(response)

        XCTAssertEqual(mapped.plan, "Power Usage")
        XCTAssertEqual(mapped.lines.map(\.label), ["Session", "Weekly"])

        guard case .progress(_, let sessionUsed, let sessionLimit, _, let sessionReset, let sessionDuration, _, _) = mapped.lines[0],
              case .progress(_, let weeklyUsed, let weeklyLimit, _, let weeklyReset, let weeklyDuration, _, _) = mapped.lines[1]
        else {
            return XCTFail("Expected progress lines")
        }

        XCTAssertEqual(sessionUsed, 15)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionReset, Date(timeIntervalSince1970: 1_792_267_278))
        XCTAssertEqual(sessionDuration, 18_000_000)

        XCTAssertEqual(weeklyUsed, 42)
        XCTAssertEqual(weeklyLimit, 100)
        XCTAssertEqual(weeklyReset, Date(timeIntervalSince1970: 1_792_368_000))
        XCTAssertEqual(weeklyDuration, 604_800_000)
    }

    func testAuthStoreLoadsKeychainCredentialsFromAuthJSON() throws {
        let authJSON = #"""
        {
          "schema_version": 2,
          "providers": {
            "meta": {
              "mechanism": "oauth",
              "storage": "keychain",
              "obtained_via": "device_code",
              "api_base_url": "https://api.meta.ai/v1",
              "subs_active": true,
              "user_full_name": "Della Biddle",
              "user_email": "dellabiddle1@gmail.com"
            }
          }
        }
        """#
        let secretJSON = #"{"secret_schema_version":1,"api_key":"meta_sk","access_token":"meta_oauth_token"}"#
        let store = MuseAuthStore(
            files: FakeFiles([MuseAuthStore.defaultAuthPath: authJSON]),
            keychain: FakeKeychain(secretJSON),
            environment: FakeEnvironment([:])
        )

        XCTAssertTrue(store.hasLocalCredentials())
        let creds = try XCTUnwrap(try store.loadCredentials())
        XCTAssertEqual(creds.accessToken, "meta_oauth_token")
        XCTAssertEqual(creds.apiBaseURL, "https://api.meta.ai")
        XCTAssertEqual(creds.userEmail, "dellabiddle1@gmail.com")
    }

    func testCLIScannerParsesModelCompletedEventsAndPricesWonderAndSpark() {
        let lines = [
            #"{"schema_version":1,"id":"1","recorded_at":1792249290187424,"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed","usage":{"input_tokens":1000000,"output_tokens":500000,"cached_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"reasoning_tokens":23},"model":"muse-wonder-full-1.0"}}}"#,
            #"{"schema_version":1,"id":"2","recorded_at":1792249292601676,"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed","usage":{"input_tokens":1000000,"output_tokens":1000000,"cached_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,"reasoning_tokens":52},"model":"muse-spark-1.3"}}}"#
        ].joined(separator: "\n")

        let rows = MuseCLIUsageScanner.parse(Data(lines.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, "muse-wonder-full-1.0")
        XCTAssertEqual(rows[0].tokens, TokenBreakdown(input: 1_000_000, output: 500_000))
        XCTAssertEqual(rows[1].model, "muse-spark-1.3")
        XCTAssertEqual(rows[1].tokens, TokenBreakdown(input: 1_000_000, output: 1_000_000))

        let pricing = TestPricing.bundled
        XCTAssertEqual(pricing.estimatedCostDollars(model: rows[0].model, tokens: rows[0].tokens), 14.0)
        XCTAssertEqual(pricing.estimatedCostDollars(model: rows[1].model, tokens: rows[1].tokens), 5.5)
    }

    @MainActor
    func testProviderRefreshCombinesSubscriptionAndLocalLogs() async throws {
        let authJSON = #"{"schema_version":2,"providers":{"meta":{"mechanism":"oauth","storage":"file","access_token":"tok_123","api_base_url":"https://api.meta.ai/v1"}}}"#
        let authStore = MuseAuthStore(
            files: FakeFiles([MuseAuthStore.defaultAuthPath: authJSON]),
            keychain: FakeKeychain(nil),
            environment: FakeEnvironment([:])
        )
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(sampleKeyResponse.utf8)
        ))
        let provider = MuseProvider(
            authStore: authStore,
            usageClient: MuseUsageClient(http: http),
            cliScanner: MuseCLIUsageScanner(sessionsDirectory: { nil }),
            piScanner: PiUsageScanner(homeDirectory: { URL(fileURLWithPath: "/nonexistent") }),
            pricing: { TestPricing.bundled },
            now: { Date(timeIntervalSince1970: 1_792_250_000) }
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertEqual(snapshot.lines.map { $0.label }, ["Session", "Weekly"])
    }

    func testContributorModelsArePricedInSupplement() {
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 0, cacheRead: 1_000_000, output: 1_000_000)
        let wonderContrib = TestPricing.bundled.estimatedCostDollars(model: "muse-wonder-full-1.0-contributor", tokens: tokens)
        XCTAssertEqual(wonderContrib ?? -1, 1.6 + 0.08 + 8.0, accuracy: 0.0001)
        let sparkContrib = TestPricing.bundled.estimatedCostDollars(model: "muse-spark-1.3-contributor", tokens: tokens)
        XCTAssertEqual(sparkContrib ?? -1, 0.1 + 0.002 + 0.2, accuracy: 0.0001)
    }
}
