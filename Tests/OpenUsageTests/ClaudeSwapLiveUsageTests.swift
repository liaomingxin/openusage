import XCTest
@testable import OpenUsage

/// Destructures a bounded meter the way every other provider's tests do.
private func progress(
    _ lines: [MetricLine], _ label: String
) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) =
        lines.first(where: { $0.label == label })
    else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

/// Fixtures for the live tier: the credential blob claude-swap stashes in its Keychain service, and
/// the usage payload Anthropic answers with.
enum ClaudeSwapLiveFixtures {
    static let email = "two@example.com"
    static let slot = "2"
    static let accountLabel = "account-2-two@example.com"
    static let legacyAccountLabel = "account-None-two@example.com"

    /// claude-swap stores Claude Code's credential file verbatim — including the refresh token, which
    /// this fixture keeps so the tests exercise a realistic blob that OpenUsage must not decode.
    static func stashedBlob(expiresAt: Date, accessToken: String = "sk-ant-oat01-stashed") -> String {
        """
        {"claudeAiOauth":{"accessToken":"\(accessToken)",\
        "refreshToken":"sk-ant-ort01-must-never-be-touched",\
        "expiresAt":\(Int(expiresAt.timeIntervalSince1970 * 1000)),\
        "scopes":["user:inference","user:profile"],"subscriptionType":"max"}}
        """
    }

    /// A full usage payload: the two headline windows, the Sonnet weekly window, the scoped Fable
    /// window Anthropic now returns under `limits[]`, and Extra Usage — none of which claude-swap's
    /// own cache records beyond the first three.
    static let usageResponse = HTTPResponse(
        statusCode: 200,
        headers: [:],
        body: Data("""
        {
          "five_hour": { "utilization": 33, "resets_at": "2099-01-01T00:00:00.000Z" },
          "seven_day": { "utilization": 44, "resets_at": "2099-01-08T00:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 6, "resets_at": "2099-01-08T00:00:00.000Z" },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 71,
              "resets_at": "2099-01-08T00:00:00.000Z",
              "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } }
          ],
          "extra_usage": { "is_enabled": true, "used_credits": 500, "monthly_limit": 1000 }
        }
        """.utf8)
    )
}

/// A Keychain double that models accounts, which claude-swap's per-slot items need. Records every
/// (service, account) it was asked for so the tests can assert which labels were probed.
final class SlotKeychain: KeychainAccessing, @unchecked Sendable {
    private(set) var reads: [(service: String, account: String)] = []
    var values: [String: String]
    var failure: Error?

    init(_ values: [String: String] = [:], failure: Error? = nil) {
        self.values = values
        self.failure = failure
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        reads.append((service, account))
        if let failure { throw failure }
        return values[account]
    }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the claude-swap reader must always scope its read to an account label")
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws {
        XCTFail("nothing on a claude-swap card's path may write to the Keychain")
    }
}

/// An HTTP double that fails the test if anything but the usage endpoint is ever touched. Every live
/// test routes through it, so "no card can reach the token endpoint" is asserted structurally rather
/// than by inspection: a refresh would have to POST `platform.claude.com/v1/oauth/token`, and any
/// request that isn't a `GET` to the usage URL fails here.
final class UsageOnlyHTTPClient: HTTPClient, @unchecked Sendable {
    private(set) var requests: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    /// Refuses every request outright — for the paths that must not reach the network at all.
    static func refusingEverything() -> UsageOnlyHTTPClient {
        UsageOnlyHTTPClient { request in
            XCTFail("no request may be made here, got \(request.method) \(request.url)")
            throw ClaudeUsageError.connectionFailed
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url != ClaudeSwapOAuth.usageURL || request.method != "GET" {
            XCTFail("a claude-swap card may only GET the usage endpoint, got \(request.method) \(request.url)")
        }
        requests.append(request)
        return try await handler(request)
    }
}

final class ClaudeSwapCredentialReaderTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadsTheAccessTokenAndExpiryFromTheWrapperBlob() throws {
        let keychain = SlotKeychain([
            ClaudeSwapLiveFixtures.accountLabel: ClaudeSwapLiveFixtures.stashedBlob(expiresAt: expiry)
        ])

        let token = try XCTUnwrap(ClaudeSwapCredentialReader(keychain: keychain)
            .stashedToken(slot: ClaudeSwapLiveFixtures.slot, email: ClaudeSwapLiveFixtures.email))

        XCTAssertEqual(token.accessToken, "sk-ant-oat01-stashed")
        XCTAssertEqual(token.expiresAt, expiry)
        XCTAssertEqual(keychain.reads.map(\.service), ["claude-swap"])
        XCTAssertEqual(keychain.reads.map(\.account), [ClaudeSwapLiveFixtures.accountLabel])
    }

    /// claude-swap's `_backup_username` numbers the slot, but a stash first written by an older
    /// version can still hold its token under the `account-None-<email>` alias claude-swap sweeps.
    func testFallsBackToTheLegacyAccountLabel() throws {
        let keychain = SlotKeychain([
            ClaudeSwapLiveFixtures.legacyAccountLabel: ClaudeSwapLiveFixtures.stashedBlob(expiresAt: expiry)
        ])

        let token = try XCTUnwrap(ClaudeSwapCredentialReader(keychain: keychain)
            .stashedToken(slot: ClaudeSwapLiveFixtures.slot, email: ClaudeSwapLiveFixtures.email))

        XCTAssertEqual(token.accessToken, "sk-ant-oat01-stashed")
        XCTAssertEqual(keychain.reads.map(\.account), [
            ClaudeSwapLiveFixtures.accountLabel, ClaudeSwapLiveFixtures.legacyAccountLabel
        ])
    }

    func testAbsentItemIsNotAFailure() throws {
        let reader = ClaudeSwapCredentialReader(keychain: SlotKeychain())
        XCTAssertNil(try reader.stashedToken(slot: "2", email: ClaudeSwapLiveFixtures.email))
    }

    /// A locked or denied Keychain is a different thing from "nothing stashed" and must reach the
    /// caller as a throw rather than being flattened into an absent item.
    func testKeychainRefusalThrows() {
        let reader = ClaudeSwapCredentialReader(
            keychain: SlotKeychain(failure: KeychainError.readFailed("User canceled the operation."))
        )
        XCTAssertThrowsError(try reader.stashedToken(slot: "2", email: ClaudeSwapLiveFixtures.email))
    }

    func testParsesTheFlatShapeAndTheHexEncodedBlob() throws {
        let flat = #"{"accessToken":"sk-ant-oat01-flat","expiresAt":1800000000000}"#
        XCTAssertEqual(ClaudeSwapCredentialReader.parse(flat)?.accessToken, "sk-ant-oat01-flat")
        // `security -w` prints hex when the stored data isn't plain UTF-8 text.
        let hex = flat.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ClaudeSwapCredentialReader.parse(hex)?.expiresAt, expiry)
    }

    /// Without an expiry there is no way to tell a live token from a spent one, and the usual way of
    /// finding out — send it, refresh if it bounces — is exactly what these cards may not do.
    func testBlobWithoutAnExpiryOrTokenIsRefused() {
        XCTAssertNil(ClaudeSwapCredentialReader.parse(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01"}}"#))
        XCTAssertNil(ClaudeSwapCredentialReader.parse(#"{"claudeAiOauth":{"expiresAt":1800000000000}}"#))
        XCTAssertNil(ClaudeSwapCredentialReader.parse("not json"))
    }

    func testFreshnessLeavesASkewSoATokenCannotExpireMidFlight() {
        let token = ClaudeSwapStashedToken(accessToken: "t", expiresAt: expiry)
        XCTAssertTrue(token.isFresh(now: expiry.addingTimeInterval(-61)))
        XCTAssertFalse(token.isFresh(now: expiry.addingTimeInterval(-60)))
        XCTAssertFalse(token.isFresh(now: expiry.addingTimeInterval(1)))
    }

    /// The card's whole OAuth configuration names one endpoint, and it isn't a token endpoint — so
    /// even a future miswiring could only issue a harmless request to the usage URL.
    func testTheCardsOAuthConfigCarriesNoTokenEndpoint() {
        XCTAssertEqual(ClaudeSwapOAuth.readOnlyConfig.usageURL.absoluteString,
                       "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(ClaudeSwapOAuth.readOnlyConfig.refreshURL, ClaudeSwapOAuth.usageURL)
        XCTAssertTrue(ClaudeSwapOAuth.readOnlyConfig.clientID.isEmpty)
    }
}

@MainActor
final class ClaudeSwapLiveUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-08-26T16:34:20.000Z")!

    private func card() -> ClaudeSwapCard {
        ClaudeSwapCard(
            id: "claude@abcd1234",
            identityKey: "acct-2|0a6595d2-b78c-4f2a-a1a1-da26d8958537",
            displayName: "Claude — two@example.com",
            configPath: ClaudeSwapFixtures.configPath(slot: "2", email: ClaudeSwapLiveFixtures.email),
            slot: ClaudeSwapLiveFixtures.slot,
            email: ClaudeSwapLiveFixtures.email
        )
    }

    /// The cache tier's fixture, so every fallback test can prove the card really degraded to
    /// claude-swap's stored percentages instead of going blank.
    private var cachedFiles: [String: String] {
        [ClaudeSwapFixtures.usageCachePath: ClaudeSwapFixtures.usageCache("""
            "2":{"email":"two@example.com","organizationUuid":"0a6595d2-b78c-4f2a-a1a1-da26d8958537",
            "lastError":null,
            "lastGood":{"five_hour":{"pct":7.0},"seven_day":{"pct":21.0},"scoped":[]},
            "fetchedAt":\(now.timeIntervalSince1970 - 60)}
            """)]
    }

    private func provider(
        keychain: SlotKeychain,
        http: UsageOnlyHTTPClient
    ) -> ClaudeSwapProvider {
        let files = FakeFiles(cachedFiles)
        return ClaudeSwapProvider(
            card: card(),
            usageClient: ClaudeSwapUsageClient(files: files, homeDirectory: { ClaudeSwapFixtures.home }),
            credentialReader: ClaudeSwapCredentialReader(keychain: keychain),
            liveUsageClient: ClaudeUsageClient(httpClient: http),
            files: files,
            now: { [now] in now }
        )
    }

    private func freshBlob() -> String {
        ClaudeSwapLiveFixtures.stashedBlob(expiresAt: now.addingTimeInterval(3600))
    }

    /// The point of the whole live tier: a stashed account shows what the active Claude card shows,
    /// Extra Usage and the per-model weekly rows included — none of which claude-swap's cache carries.
    func testFreshStashedTokenRendersLiveUsageIncludingExtraUsage() async throws {
        let http = UsageOnlyHTTPClient { _ in ClaudeSwapLiveFixtures.usageResponse }
        let snapshot = await provider(
            keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()]), http: http
        ).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label),
                       ["Session", "Weekly", "Sonnet", "Fable", "Extra usage spent"])
        XCTAssertEqual(progress(snapshot.lines, "Session")?.used, 33)
        XCTAssertEqual(progress(snapshot.lines, "Weekly")?.used, 44)
        XCTAssertEqual(progress(snapshot.lines, "Sonnet")?.used, 6)
        XCTAssertEqual(progress(snapshot.lines, "Fable")?.used, 71)
        XCTAssertEqual(progress(snapshot.lines, "Extra usage spent")?.used, 5)
        XCTAssertEqual(progress(snapshot.lines, "Extra usage spent")?.limit, 10)

        // Exactly one request, and it carries the stashed access token — never the refresh token.
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, ClaudeSwapOAuth.usageURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-ant-oat01-stashed")
        XCTAssertNil(request.body)
    }

    /// An expired stash means claude-swap is between two of its own refreshes. Waiting costs a few
    /// stale minutes; refreshing it here would cost claude-swap its refresh token — so the card does
    /// not even spend the request.
    func testExpiredStashedTokenFallsBackToTheCacheWithoutCallingAnthropic() async {
        let blob = ClaudeSwapLiveFixtures.stashedBlob(expiresAt: now.addingTimeInterval(-1))
        let snapshot = await provider(
            keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: blob]),
            http: .refusingEverything()
        ).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(progress(snapshot.lines, "Session")?.used, 7)
    }

    /// A rejected token is the one case where the obvious remedy is forbidden. The card degrades to
    /// claude-swap's cached percentages and makes no second attempt of any kind.
    func testRejectedTokenFallsBackToTheCacheAndNeverRetriesOrRefreshes() async {
        let http = UsageOnlyHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
        }
        let snapshot = await provider(
            keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()]), http: http
        ).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        // One attempt only: `ProviderAuthRetry`'s refresh-and-retry loop is not on this path.
        XCTAssertEqual(http.requests.count, 1)
    }

    func testForbiddenTokenAlsoFallsBackRatherThanErroring() async {
        let http = UsageOnlyHTTPClient { _ in
            HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
        }
        let snapshot = await provider(
            keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()]), http: http
        ).refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(http.requests.count, 1)
    }

    /// Rate limits and server errors are transient, so they read as "use the cache this tick" — never
    /// as a dead login, and never as a reason to touch a token.
    func testRateLimitedAndServerErrorsFallBackToTheCache() async {
        for status in [429, 500] {
            let http = UsageOnlyHTTPClient { _ in
                HTTPResponse(statusCode: status, headers: [:], body: Data("{}".utf8))
            }
            let snapshot = await provider(
                keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()]), http: http
            ).refresh()

            XCTAssertNil(snapshot.errorCategory, "HTTP \(status) must not blank the card")
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        }
    }

    /// The one way these cards could make a user's situation worse: re-sending a throttled account's
    /// usage request every few minutes, once per stashed login. A 429 parks the live tier for as long
    /// as `Retry-After` says, and the parked card doesn't even open the Keychain.
    func testRateLimitParksTheLiveTierUntilTheCooldownExpires() async {
        let http = UsageOnlyHTTPClient { _ in
            HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data("{}".utf8))
        }
        let keychain = SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()])
        let provider = provider(keychain: keychain, http: http)

        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 1)

        let second = await provider.refresh()
        XCTAssertEqual(http.requests.count, 1, "a throttled account must not be asked again during the cooldown")
        XCTAssertEqual(keychain.reads.count, 1, "a parked card has no reason to open the Keychain either")
        XCTAssertNil(second.errorCategory)
        XCTAssertEqual(second.lines.map(\.label), ["Session", "Weekly"])

        // Manual refreshes extend Anthropic's rate limiting, so they wait out the cooldown too — the
        // same rule the active Claude card follows.
        let manual = await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(manual.lines.map(\.label), ["Session", "Weekly"])
    }

    /// The cooldown is a pause, not a latch: once `Retry-After` has run out the card asks again.
    func testTheLiveTierResumesOnceTheRateLimitCooldownHasExpired() async {
        let http = UsageOnlyHTTPClient { _ in
            HTTPResponse(statusCode: 429, headers: ["retry-after": "60"], body: Data("{}".utf8))
        }
        let clock = ClaudeSwapTestClock(now)
        let files = FakeFiles(cachedFiles)
        let provider = ClaudeSwapProvider(
            card: card(),
            usageClient: ClaudeSwapUsageClient(files: files, homeDirectory: { ClaudeSwapFixtures.home }),
            credentialReader: ClaudeSwapCredentialReader(
                keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()])
            ),
            liveUsageClient: ClaudeUsageClient(httpClient: http),
            files: files,
            now: { clock.now }
        )

        _ = await provider.refresh()
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 1)

        clock.set(now.addingTimeInterval(61))
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 2)
    }

    func testTransportFailureFallsBackToTheCache() async {
        let http = UsageOnlyHTTPClient { _ in throw URLError(.timedOut) }
        let snapshot = await provider(
            keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()]), http: http
        ).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    func testMissingKeychainItemFallsBackToTheCache() async {
        let snapshot = await provider(keychain: SlotKeychain(), http: .refusingEverything()).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    /// A locked or denied Keychain must degrade, not crash and not blank the card.
    func testKeychainRefusalFallsBackToTheCache() async {
        let keychain = SlotKeychain(failure: KeychainError.readFailed("User canceled the operation."))
        let snapshot = await provider(keychain: keychain, http: .refusingEverything()).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    /// Reading claude-swap's item can put a macOS access prompt on screen, and *Deny* answers that one
    /// prompt only. Without a backoff the same dialog would come back every few minutes, once per
    /// stashed card — so a refusal stops the automatic reads, and only a manual refresh asks again.
    func testADeniedKeychainIsNotAskedAgainUntilAManualRefresh() async {
        let keychain = SlotKeychain(failure: KeychainError.readFailed("User canceled the operation."))
        let provider = provider(keychain: keychain, http: .refusingEverything())

        _ = await provider.refresh()
        XCTAssertEqual(keychain.reads.count, 1)

        let second = await provider.refresh()
        XCTAssertEqual(keychain.reads.count, 1, "an automatic refresh must not re-show the access prompt")
        XCTAssertNil(second.errorCategory)
        XCTAssertEqual(second.lines.map(\.label), ["Session", "Weekly"])

        let manual = await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }
        XCTAssertEqual(keychain.reads.count, 2, "a manual refresh is the user asking to be prompted again")
        XCTAssertEqual(manual.lines.map(\.label), ["Session", "Weekly"])
    }

    /// An item that simply isn't there is not a refusal, so it must not start a backoff — the stash can
    /// gain one at any moment when claude-swap signs that account in.
    func testAnAbsentKeychainItemIsStillLookedForEveryRefresh() async {
        let keychain = SlotKeychain()
        let provider = provider(keychain: keychain, http: .refusingEverything())

        _ = await provider.refresh()
        _ = await provider.refresh()

        XCTAssertEqual(keychain.reads.count, 4, "both labels, on both refreshes")
    }

    func testLegacyAccountLabelStillReachesTheLiveTier() async {
        let http = UsageOnlyHTTPClient { _ in ClaudeSwapLiveFixtures.usageResponse }
        let keychain = SlotKeychain([ClaudeSwapLiveFixtures.legacyAccountLabel: freshBlob()])
        let snapshot = await provider(keychain: keychain, http: http).refresh()

        XCTAssertEqual(progress(snapshot.lines, "Session")?.used, 33)
        XCTAssertEqual(keychain.reads.map(\.account), [
            ClaudeSwapLiveFixtures.accountLabel, ClaudeSwapLiveFixtures.legacyAccountLabel
        ])
    }

    /// A usable token whose account answers with nothing renderable is still a fallback, not a blank
    /// card: claude-swap's own percentages are better than an empty meter list.
    func testEmptyLiveResponseFallsBackToTheCache() async {
        let http = UsageOnlyHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let snapshot = await provider(
            keychain: SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()]), http: http
        ).refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    /// The credential probe is what first-run detection calls on the launch path. It must never reach
    /// for the Keychain, or a user who has not even seen the dashboard gets another app's access
    /// prompt thrown at them.
    func testLocalCredentialProbeNeverTouchesTheKeychain() async {
        let keychain = SlotKeychain([ClaudeSwapLiveFixtures.accountLabel: freshBlob()])
        let has = await provider(keychain: keychain, http: .refusingEverything()).hasLocalCredentials()

        XCTAssertFalse(has, "the fixture has no config snapshot, only a cache and a stashed token")
        XCTAssertTrue(keychain.reads.isEmpty)
    }

    /// Structural backstop for the rule the whole design rests on: nothing in the claude-swap sources
    /// builds a `ClaudeAuthStore` or names a token endpoint, so no refresh path can exist for these
    /// cards regardless of what a future edit wires together.
    func testClaudeSwapSourcesBuildNoAuthStoreAndNameNoTokenEndpoint() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenUsage/Providers/Claude")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ClaudeSwap") && $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "expected to find the claude-swap sources to scan")

        for name in names {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for forbidden in ["ClaudeAuthStore(", "refreshToken", "oauth/token", "writeGenericPassword"] {
                XCTAssertFalse(
                    code.contains(forbidden),
                    "\(name) must not reference \(forbidden) — a claude-swap card is read-only"
                )
            }
        }
    }
}

/// A mutable clock so a test can advance `now` between refreshes to exercise the cooldowns.
private final class ClaudeSwapTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
