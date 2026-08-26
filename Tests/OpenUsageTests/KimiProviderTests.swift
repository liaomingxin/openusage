import XCTest
@testable import OpenUsage

/// Frozen clock shared by the suites: `now` closures are `@Sendable` under strict concurrency, so
/// they must not capture a non-Sendable test-case `self`.
private let kimiNow = Date(timeIntervalSince1970: 1_800_000_000)
private let kimiEpoch = 1_800_000_000

private func credentialsJSON(
    accessToken: String = "access",
    refreshToken: String = "refresh",
    expiresAt: Int? = nil
) -> String {
    var fields = [
        "\"access_token\": \"\(accessToken)\"",
        "\"refresh_token\": \"\(refreshToken)\""
    ]
    if let expiresAt {
        fields.append("\"expires_at\": \(expiresAt)")
    }
    return "{\(fields.joined(separator: ", "))}"
}

// MARK: - KimiAuthStoreTests

final class KimiAuthStoreTests: XCTestCase {
    private func store(_ files: [String: String]) -> KimiAuthStore {
        KimiAuthStore(files: FakeFiles(files), now: { kimiNow })
    }

    func testLoadsCredentialsFromKimiCLIFile() {
        let credentials = store([KimiAuthStore.credentialsPath: credentialsJSON()]).loadCredentials()

        XCTAssertEqual(credentials?.accessToken, "access")
        XCTAssertEqual(credentials?.refreshToken, "refresh")
    }

    func testMissingFileOrEmptyRefreshTokenYieldsNoCredentials() {
        // The usability filter `refresh()` and `hasLocalCredentials()` share: without a refresh
        // token there is no way to mint fresh access tokens, so the provider must not seed on.
        XCTAssertNil(store([:]).loadCredentials(), "missing file")
        XCTAssertNil(store([KimiAuthStore.credentialsPath: credentialsJSON(refreshToken: "")]).loadCredentials(), "empty refresh token")
    }

    func testNeedsRefreshUsesExpiresAtWithSlack() {
        let epoch = kimiEpoch
        let cases: [(name: String, expiresAt: Int?, expected: Bool)] = [
            ("fresh token", epoch + 900, false),
            ("inside the slack window", epoch + 30, true),
            ("expired", epoch - 1, true),
            ("no expires_at — unknown age refreshes", nil, true)
        ]

        for entry in cases {
            let credentials = KimiCredentials(
                accessToken: "access", refreshToken: "refresh",
                expiresAt: entry.expiresAt
            )
            XCTAssertEqual(store([:]).needsRefresh(credentials), entry.expected, entry.name)
        }
    }

    func testSaveWritesBackRotatedCredentials() throws {
        let files = FakeFiles([KimiAuthStore.credentialsPath: credentialsJSON()])
        var credentials = try XCTUnwrap(KimiAuthStore(files: files, now: { kimiNow }).loadCredentials())

        credentials.accessToken = "rotated-access"
        credentials.refreshToken = "rotated-refresh"
        try KimiAuthStore(files: files, now: { kimiNow }).save(credentials)

        let reloaded = try XCTUnwrap(KimiAuthStore(files: files, now: { kimiNow }).loadCredentials())
        XCTAssertEqual(reloaded.accessToken, "rotated-access")
        XCTAssertEqual(reloaded.refreshToken, "rotated-refresh")
    }

    func testRegionDefaultsToCNAndTrimsTheFile() {
        let cases: [(name: String, file: String?, expected: String)] = [
            ("missing file", nil, "cn"),
            ("cn with newline", "cn\n", "cn"),
            ("global", "global", "global")
        ]

        for entry in cases {
            var files: [String: String] = [:]
            if let file = entry.file {
                files[KimiAuthStore.regionPath] = file
            }
            XCTAssertEqual(store(files).region(), entry.expected, entry.name)
        }
    }

    func testDeviceIDReadAndTrimmed() {
        XCTAssertNil(store([:]).deviceID(), "missing file")
        XCTAssertEqual(store([KimiAuthStore.deviceIDPath: "uuid\n"]).deviceID(), "uuid")
    }
}

// MARK: - KimiUsageMapperTests

private let liveSampleJSON = #"""
{
  "user": {
    "userId": "cno2i0ilnl93bcsjk4",
    "region": "REGION_CN",
    "membership": { "level": "LEVEL_ADVANCED" },
    "businessId": ""
  },
  "usage": {
    "limit": "100",
    "used": "79",
    "remaining": "21",
    "resetTime": "2026-08-28T03:18:21.328791Z"
  },
  "limits": [
    {
      "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
      "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-08-25T07:18:21.328791Z" }
    }
  ],
  "parallel": { "limit": "30" },
  "totalQuota": {},
  "authentication": { "method": "METHOD_ACCESS_TOKEN", "scope": "FEATURE_CODING" },
  "subType": "TYPE_PURCHASE",
  "domain": "DOMAIN_NEXUS"
}
"""#

final class KimiUsageMapperTests: XCTestCase {
    private func map(_ json: String, status: Int = 200) throws -> KimiMappedUsage {
        try KimiUsageMapper.map(
            HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
        )
    }

    private func progress(_ mapped: KimiMappedUsage, _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) =
            mapped.lines.first(where: { $0.label == label })
        else { return nil }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func values(_ mapped: KimiMappedUsage, _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = mapped.lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    func testLiveSampleMapsWeeklyAndSessionAndPlan() throws {
        let mapped = try map(liveSampleJSON)

        XCTAssertEqual(mapped.plan, "Advanced")
        let weekly = try XCTUnwrap(progress(mapped, "Weekly"))
        XCTAssertEqual(weekly.used, 79)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.periodDurationMs, KimiUsageMapper.weeklyPeriodMs)
        XCTAssertEqual(weekly.resetsAt, OpenUsageISO8601.date(from: "2026-08-28T03:18:21.328791Z"))

        // The 5-hour session entry starts fresh in the sample: used is absent, limit 100 → 0%.
        let session = try XCTUnwrap(progress(mapped, "Session"))
        XCTAssertEqual(session.used, 0)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.periodDurationMs, KimiUsageMapper.sessionPeriodMs)
        XCTAssertEqual(session.resetsAt, OpenUsageISO8601.date(from: "2026-08-25T07:18:21.328791Z"))
    }

    func testSessionUsesUsedOverLimitPercent() throws {
        let json = #"""
{"usage":{"used":"10","limit":"40","resetTime":"2026-08-28T03:18:21Z"},
 "limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},
            "detail":{"used":"3","limit":"40","resetTime":"2026-08-25T07:18:21Z"}}]}
"""#
        let mapped = try map(json)

        XCTAssertEqual(progress(mapped, "Weekly")?.used, 25)
        XCTAssertEqual(progress(mapped, "Session")?.used, 7.5)
        XCTAssertEqual(progress(mapped, "Session")?.periodDurationMs, KimiUsageMapper.sessionPeriodMs)
    }

    func testWindowNormalizationAcrossUnitsAndUnknownUnitsRefused() {
        let window: (Double, String) -> [String: Any] = { duration, unit in
            ["duration": duration, "timeUnit": unit]
        }
        XCTAssertEqual(KimiUsageMapper.windowMs(window(300, "TIME_UNIT_MINUTE")), 5 * 3_600_000)
        XCTAssertEqual(KimiUsageMapper.windowMs(window(5, "TIME_UNIT_HOUR")), 5 * 3_600_000)
        XCTAssertEqual(KimiUsageMapper.windowMs(window(1, "TIME_UNIT_DAY")), 86_400_000)
        XCTAssertEqual(KimiUsageMapper.windowMs(window(1, "TIME_UNIT_WEEK")), 604_800_000)
        XCTAssertNil(KimiUsageMapper.windowMs(window(1, "TIME_UNIT_FORTNIGHT")))
        XCTAssertNil(KimiUsageMapper.windowMs(nil))
    }

    func testZeroLimitUsageYieldsNoLineAndLimitsEntryWithoutBothFieldsIsDropped() throws {
        let json = #"""
{"usage":{"used":"0","limit":"0"},
 "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
            "detail":{"remaining":"100"}}]}
"""#
        let mapped = try map(json)

        XCTAssertNil(progress(mapped, "Weekly"))
        XCTAssertNil(progress(mapped, "Session"))
        XCTAssertTrue(mapped.lines.isEmpty)
    }

    func testBoosterWalletConvertsMillionthsToDollars() throws {
        let json = #"""
{"usage":{"used":"1","limit":"100"},
 "boosterWallet":{"balance":{"type":"BOOSTER","amount":"125000000","amountLeft":"75000000"}}}
"""#
        let mapped = try map(json)

        let boosterValues = try XCTUnwrap(values(mapped, "Booster"))
        XCTAssertEqual(boosterValues.first?.number ?? 0, 0.75, accuracy: 0.0001)
        // amount (total) is not metered; amountLeft is the remaining balance.
        XCTAssertEqual(boosterValues.count, 1)
    }

    func testUnknownMembershipLevelYieldsNoPlan() throws {
        let mapped = try map(#"{"usage":{"used":"1","limit":"10"}}"#)

        XCTAssertNil(mapped.plan)
    }

    func testErrorMappingAuthAndRequestFailures() {
        XCTAssertThrowsError(try map("{}", status: 401)) { error in
            XCTAssertEqual(error as? KimiAuthError, .sessionExpired)
        }
        XCTAssertThrowsError(try map("{}", status: 500)) { error in
            XCTAssertEqual(error as? KimiUsageError, .requestFailed(500))
        }
        XCTAssertThrowsError(try map("not json")) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse)
        }
    }
}

// MARK: - KimiProviderTests

/// Serves queued responses in order (each `send` pops the next), recording every request.
private final class ScriptedHTTPClient: HTTPClient, @unchecked Sendable {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses.isEmpty ? responses.removeLast() : responses.removeFirst()
    }

    var requestURLs: [String] { requests.map(\.url.absoluteString) }
    var requestBodies: [String] { requests.compactMap { $0.body.map { String(decoding: $0, as: UTF8.self) } } }
}

private let usageBody = Data(liveSampleJSON.utf8)
private let refreshBody = Data(#"""
{"access_token":"new-access","refresh_token":"new-refresh","expires_in":900,"token_type":"bearer"}
"""#.utf8)

private func ok(_ body: Data) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: body)
}

private extension MetricLine {
    var progressUsed: Double? {
        guard case .progress(_, let used, _, _, _, _, _, _) = self else { return nil }
        return used
    }
}

@MainActor
final class KimiProviderTests: XCTestCase {

    private func provider(
        files: [String: String] = [:],
        responses: [HTTPResponse]
    ) -> (KimiProvider, ScriptedHTTPClient, FakeFiles) {
        let files = FakeFiles(files)
        let http = ScriptedHTTPClient(responses)
        return (
            KimiProvider(
                authStore: KimiAuthStore(files: files, now: { kimiNow }),
                usageClient: KimiUsageClient(http: http),
                now: { kimiNow }
            ),
            http,
            files
        )
    }

    private func liveCredentials(expiresAt: Int? = nil) -> String {
        credentialsJSON(accessToken: "access", refreshToken: "refresh", expiresAt: expiresAt)
    }

    func testNotLoggedInWithoutCredentialFile() async {
        let (provider, http, _) = provider(responses: [])

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty, "no network call without credentials")
        let seeded = await provider.hasLocalCredentials()
        XCTAssertFalse(seeded)
    }

    func testFreshTokenFetchesUsageWithoutRefresh() async throws {
        let (provider, http, _) = provider(
            files: [KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch + 600)],
            responses: [ok(usageBody)]
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requestURLs, [KimiUsageClient.cnUsageURL.absoluteString])
        XCTAssertEqual(snapshot.lines.first { $0.label == "Weekly" }?.progressUsed, 79)
        XCTAssertEqual(snapshot.plan, "Advanced")
        let seeded = await provider.hasLocalCredentials()
        XCTAssertTrue(seeded)
    }

    func testExpiredTokenRefreshesThenFetchesAndPersistsRotatedPair() async throws {
        let (provider, http, files) = provider(
            files: [KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch - 1)],
            responses: [ok(refreshBody), ok(usageBody)]
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requestURLs.count, 2)
        XCTAssertEqual(http.requestURLs.first, KimiUsageClient.refreshURL.absoluteString)
        XCTAssertEqual(http.requestURLs.last, KimiUsageClient.cnUsageURL.absoluteString)
        XCTAssertTrue(http.requestBodies.first?.contains("refresh_token=refresh") == true)

        let persisted = try XCTUnwrap(
            KimiAuthStore(files: files, now: { kimiNow }).loadCredentials()
        )
        XCTAssertEqual(persisted.accessToken, "new-access")
        XCTAssertEqual(persisted.refreshToken, "new-refresh")
        XCTAssertEqual(persisted.expiresAt, kimiEpoch + 900)
    }

    func testUsage401RefreshesOnceAndRetries() async throws {
        let (provider, http, files) = provider(
            files: [KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch + 600)],
            responses: [
                HTTPResponse(statusCode: 401, headers: [:], body: Data()),
                ok(refreshBody),
                ok(usageBody)
            ]
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requestURLs.count, 3)
        XCTAssertEqual(http.requestURLs.last, KimiUsageClient.cnUsageURL.absoluteString)

        let persisted = try XCTUnwrap(
            KimiAuthStore(files: files, now: { kimiNow }).loadCredentials()
        )
        XCTAssertEqual(persisted.refreshToken, "new-refresh")
    }

    func testSecond401SurfacesSessionExpired() async {
        let (provider, http, _) = provider(
            files: [KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch + 600)],
            responses: [
                HTTPResponse(statusCode: 401, headers: [:], body: Data()),
                ok(refreshBody),
                HTTPResponse(statusCode: 401, headers: [:], body: Data())
            ]
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(http.requestURLs.count, 3)
    }

    func testInvalidGrantOnRefreshSurfacesSessionExpired() async {
        let (provider, http, _) = provider(
            files: [KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch - 1)],
            responses: [
                HTTPResponse(
                    statusCode: 400, headers: [:],
                    body: Data(#"{"error":"invalid_grant"}"#.utf8)
                )
            ]
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(http.requestURLs, [KimiUsageClient.refreshURL.absoluteString])
    }

    func testGlobalRegionSelectsKimiAIHost() async {
        let (provider, http, _) = provider(
            files: [
                KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch + 600),
                KimiAuthStore.regionPath: "global"
            ],
            responses: [ok(usageBody)]
        )

        _ = await provider.refresh()

        XCTAssertEqual(http.requestURLs, [KimiUsageClient.globalUsageURL.absoluteString])
    }

    func testRefreshSendsDeviceHeadersAndFormBody() async throws {
        let (provider, http, _) = provider(
            files: [
                KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch - 1),
                KimiAuthStore.deviceIDPath: "device-uuid"
            ],
            responses: [ok(refreshBody), ok(usageBody)]
        )

        _ = await provider.refresh()

        let refresh = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(refresh.headers["X-Msh-Device-Id"], "device-uuid")
        XCTAssertEqual(refresh.headers["X-Msh-Platform"], "kimi_code_cli")
        XCTAssertTrue(refresh.headers["Content-Type"]?.contains("x-www-form-urlencoded") == true)
    }

    func testEmptyLinesAppendNoDataBadge() async {
        let emptyUsage = Data(#"{"usage":{"used":"0","limit":"0"}}"#.utf8)
        let (provider, _, _) = provider(
            files: [KimiAuthStore.credentialsPath: liveCredentials(expiresAt: kimiEpoch + 600)],
            responses: [ok(emptyUsage)]
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.contains(MetricLine.noUsageData))
    }
}
