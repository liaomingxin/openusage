import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeSwapReviewRegressionTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/swap-review-test")
    private let user = "11111111-1111-1111-1111-111111111111"
    private let organization = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    private var swap: ClaudeSwapAccount {
        ClaudeSwapAccount(root: home.path + "/.claude-swap-backup", slot: "1",
            email: "saved@example.com", identityKey: "\(user)|\(organization)", organizationID: organization)
    }

    private func credentials(_ token: String, scope: String = "user:profile") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000,"scopes":["\#(scope)"]}}"#
    }

    func testFullScopeSwapSessionSuppliesLiveUsageBeforeLimitedDefault() async throws {
        let files = FakeFiles([
            home.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(organization)"}}"#,
            swap.sessionDirectory + "/.credentials.json": credentials("session")
        ])
        let keychain = ServiceKeychain(currentUserValues: [
            "Claude Code-credentials": credentials("limited-default", scope: "user:inference")
        ])
        let auth = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain,
            swapAccount: swap)
        let generation = auth.credentialGeneration()
        let http = usageHTTP()
        let provider = ClaudeProvider(authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled })
        let result = await provider.refresh()
        XCTAssertEqual(auth.loadCredentialCandidates().map(\.oauth.accessToken), ["session", "limited-default"])
        XCTAssertNil(result.warning)
        for (label, expected) in [("Session", 37.0), ("Weekly", 64.0)] {
            guard case let .progress(_, used, _, _, _, _, _, _) = result.line(label: label) else {
                XCTFail("Missing live \(label) limits")
                continue
            }
            XCTAssertEqual(used, expected)
        }
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer session" })
        XCTAssertEqual(auth.credentialGeneration(), generation)
    }

    func testFullScopeSwapSessionStillRejectsAnotherOrganization() async throws {
        let files = FakeFiles([
            home.path + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(organization)"}}"#,
            swap.sessionDirectory + "/.credentials.json": credentials("session")
        ])
        let keychain = ServiceKeychain(currentUserValues: [
            "Claude Code-credentials": credentials("limited-default", scope: "user:inference")
        ])
        let auth = ClaudeAuthStore(environment: FakeEnvironment([:]), files: files, keychain: keychain,
            swapAccount: swap)
        let http = usageHTTP(profileOrganization: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let provider = ClaudeProvider(authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), pricing: { TestPricing.bundled })
        let result = await provider.refresh()
        XCTAssertNil(result.line(label: "Session"))
        XCTAssertEqual(result.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
    }

    func testUUIDOnlyCardExcludesHistoryWhenMultipleAccountsAreKnown() async throws {
        let timestamp = "2026-02-20T12:00:00Z"
        let owned = #"{"ownerOrganizationUuid":"\#(organization)","ownerAccountUuid":"\#(user)"}"# + "\n" +
            ClaudeLogFixture.usageLine(timestamp: timestamp, input: 100, output: 10)
        let fixtureHome = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "project/owned.jsonl": owned,
            "project/unowned.jsonl": ClaudeLogFixture.usageLine(timestamp: timestamp, input: 999,
                messageID: "unowned", requestID: "unowned")
        ])
        defer { try? FileManager.default.removeItem(at: fixtureHome) }
        let scanner = ClaudeLogUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { fixtureHome },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(), accountUUID: user,
            organizationUUID: nil, allowsUnattributedSessions: false)
        let result = await scanner.scan(now: Date(timeIntervalSince1970: 1_771_603_200), pricing: TestPricing.bundled)
        XCTAssertNil(result, "An unknown organization cannot claim the saved organization's history")
    }

    private func usageHTTP(profileOrganization: String? = nil) -> RoutingHTTPClient {
        let expectedUser = user
        let profileOrganization = profileOrganization ?? organization
        return RoutingHTTPClient { request in
            if request.url.path == "/api/oauth/profile" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"account":{"uuid":"\#(expectedUser)"},"organization":{"uuid":"\#(profileOrganization)"}}"#.utf8))
            }
            XCTAssertEqual(request.url.path, "/api/oauth/usage")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"five_hour":{"utilization":37},"seven_day":{"utilization":64}}"#.utf8))
        }
    }
}
