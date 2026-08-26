import Foundation

/// The four Z.ai endpoints OpenUsage reads, on whichever platform the key belongs to (see
/// `ZAIPlatform`). The paths are identical on both hosts, so the platform only picks the base URL.
struct ZAIUsageClient: Sendable {
    static let subscriptionPath = "/api/biz/subscription/list"
    static let quotaPath = "/api/monitor/usage/quota/limit"
    static let modelUsagePath = "/api/monitor/usage/model-usage"
    static let toolUsagePath = "/api/monitor/usage/tool-usage"

    static func subscriptionURL(_ platform: ZAIPlatform) -> URL { url(platform, subscriptionPath) }
    static func quotaURL(_ platform: ZAIPlatform) -> URL { url(platform, quotaPath) }
    static func modelUsageURL(_ platform: ZAIPlatform) -> URL { url(platform, modelUsagePath) }
    static func toolUsageURL(_ platform: ZAIPlatform) -> URL { url(platform, toolUsagePath) }

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
