import Foundation

/// The four Z.ai endpoints OpenUsage reads, on whichever platform the key belongs to (see
/// `ZAIPlatform`). The paths are identical on both hosts, so the platform only picks the base URL.
struct ZAIUsageClient: Sendable {
    static let subscriptionPath = "/api/biz/subscription/list"
    static let quotaPath = "/api/monitor/usage/quota/limit"
    static let modelUsagePath = "/api/monitor/usage/model-usage"
    static let toolUsagePath = "/api/monitor/usage/tool-usage"
    static let creditActivityPath = "/api/monitor/credit-usage/activity"
    static let creditUsageDetailPath = "/api/monitor/credit-usage/usage-detail"

    static func subscriptionURL(_ platform: ZAIPlatform) -> URL { url(platform, subscriptionPath) }
    static func quotaURL(_ platform: ZAIPlatform) -> URL { url(platform, quotaPath) }
    static func modelUsageURL(_ platform: ZAIPlatform) -> URL { url(platform, modelUsagePath) }
    static func toolUsageURL(_ platform: ZAIPlatform) -> URL { url(platform, toolUsagePath) }
    static func creditActivityURL(_ platform: ZAIPlatform) -> URL { url(platform, creditActivityPath) }
    static func creditUsageDetailURL(_ platform: ZAIPlatform) -> URL { url(platform, creditUsageDetailPath) }

    /// Which slice of `credit-usage/usage-detail` to read: per-model token usage or per-tool MCP
    /// call counts. Z.ai's own usage page switches between them with the same values.
    enum CreditUsageKind: String, Sendable {
        case model = "MODEL"
        case mcp = "MCP"
    }

    private static func url(_ platform: ZAIPlatform, _ path: String) -> URL {
        platform.apiBaseURL.appendingPathComponent(path)
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The user's active subscription(s) — best-effort, used only to surface the plan name. A failure
    /// here must not blank out the quota meters, so the provider treats it as optional.
    func fetchSubscription(apiKey: String, platform: ZAIPlatform) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL(platform), apiKey: apiKey)
    }

    /// Session token usage and web-search quotas. Required for a usable snapshot.
    func fetchQuota(apiKey: String, platform: ZAIPlatform) async throws -> HTTPResponse {
        try await get(Self.quotaURL(platform), apiKey: apiKey)
    }

    /// Tokens and call counts per time bucket, plus per-model totals, over `[start, end]`. Best-effort:
    /// it feeds the trend and the day rows, never the meters.
    func fetchModelUsage(
        apiKey: String,
        platform: ZAIPlatform,
        start: Date,
        end: Date
    ) async throws -> HTTPResponse {
        try await get(ZAITime.rangeURL(Self.modelUsageURL(platform), start: start, end: end), apiKey: apiKey)
    }

    /// Web-search / web-read / ZRead MCP call counts over `[start, end]`. Best-effort, like model usage.
    func fetchToolUsage(
        apiKey: String,
        platform: ZAIPlatform,
        start: Date,
        end: Date
    ) async throws -> HTTPResponse {
        try await get(ZAITime.rangeURL(Self.toolUsageURL(platform), start: start, end: end), apiKey: apiKey)
    }

    /// The account-wide daily token series and window totals behind the credit-plan KPI card — the
    /// widest accounting Z.ai reports, covering consumption the per-model detail can't attribute.
    /// Feeds Usage Trend and the Last 30 Days total. Best-effort, like the legacy history calls.
    func fetchCreditActivity(
        apiKey: String,
        platform: ZAIPlatform,
        start: Date,
        end: Date
    ) async throws -> HTTPResponse {
        try await get(creditRangeURL(Self.creditActivityURL(platform), start: start, end: end, kind: nil),
                      apiKey: apiKey)
    }

    /// The per-model token buckets (`kind == .model`) or per-tool MCP call counts (`kind == .mcp`)
    /// behind the credit-plan usage history. Feeds the period rows' model breakdowns — and, from a
    /// short-range `MODEL` call (hourly buckets), the Today / Yesterday totals. Best-effort.
    func fetchCreditUsageDetail(
        apiKey: String,
        platform: ZAIPlatform,
        start: Date,
        end: Date,
        kind: CreditUsageKind
    ) async throws -> HTTPResponse {
        try await get(creditRangeURL(Self.creditUsageDetailURL(platform), start: start, end: end, kind: kind),
                      apiKey: apiKey)
    }

    /// The range query the credit endpoints expect: the same wall-clock bounds as the legacy
    /// endpoints plus `type=1` (the token-denominated view Z.ai's own page reads; `type=0` switches
    /// the payloads to a credits-first view OpenUsage doesn't consume) and, for `usage-detail`, the
    /// `usageType` slice.
    private func creditRangeURL(_ base: URL, start: Date, end: Date, kind: CreditUsageKind?) -> URL {
        var items = [URLQueryItem(name: "type", value: "1")]
        if let kind { items.append(URLQueryItem(name: "usageType", value: kind.rawValue)) }
        return ZAITime.rangeURL(base, start: start, end: end, extraQueryItems: items)
    }

    private func get(_ url: URL, apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum ZAIUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The key is valid but the account has no GLM Coding Plan (the quota endpoint answers a 2xx with
    /// `success:false`). Distinct from a malformed/failed request — there is simply nothing to meter.
    /// Carries the platform so the message points at the right store.
    case noCodingPlan(ZAIPlatform)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noCodingPlan(let platform):
            return "No active GLM Coding Plan. Subscribe at \(platform.subscribeLabel) to see usage."
        }
    }
}
