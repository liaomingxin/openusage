import Foundation

struct KimiRefreshResponse: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Seconds the access token stays valid (900 for Kimi).
    var expiresIn: Int?
}

struct KimiUsageClient: Sendable {
    /// The `kimi` CLI's public OAuth client, extracted from its bundle (research doc). Refresh-token
    /// grants require it.
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let cnUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let globalUsageURL = URL(string: "https://api.kimi.ai/coding/v1/usages")!
    /// The CLI sends its own version here; a plausible `kimi-code-cli/<version>` keeps the auth
    /// server's device headers happy without pretending to be a browser.
    static let cliVersion = "0.38.0"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Exchanges the refresh token for a fresh access token. The response rotates the refresh token;
    /// the caller persists the returned pair. `invalid_grant` (a reused/revoked refresh token)
    /// surfaces as `sessionExpired` so the user is told to re-run `kimi /login`.
    func refreshToken(_ refreshToken: String, deviceID: String?) async throws -> KimiRefreshResponse {
        let body =
            "client_id=\(Self.clientID.urlFormEncoded)" +
            "&grant_type=refresh_token" +
            "&refresh_token=\(refreshToken.urlFormEncoded)"

        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "kimi-code-cli/\(Self.cliVersion)",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": Self.cliVersion
        ]
        if let deviceID, !deviceID.isEmpty {
            headers["X-Msh-Device-Id"] = deviceID
        }

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: headers,
            body: Data(body.utf8),
            timeout: 15
        ))

        if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
            let errorBody = ProviderParse.jsonObject(response.body)
            let code = errorBody?["error"] as? String ?? errorBody?["error_description"] as? String
            if code == "invalid_grant" || code?.contains("invalid_grant") == true {
                throw KimiAuthError.sessionExpired
            }
            throw KimiUsageError.requestFailed(response.statusCode)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw KimiUsageError.requestFailed(response.statusCode)
        }
        guard let body = ProviderParse.jsonObject(response.body),
              let accessToken = body["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw KimiAuthError.sessionExpired
        }

        return KimiRefreshResponse(
            accessToken: accessToken,
            refreshToken: body["refresh_token"] as? String,
            expiresIn: ProviderParse.number(body["expires_in"]).map(Int.init)
        )
    }

    /// The subscription usage meter. One call, no body, Bearer-only — the plural `usages` is not a
    /// typo (singular 404s). Host follows the CLI's region file.
    func fetchUsage(accessToken: String, region: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: usageURL(region: region),
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ],
            timeout: 10
        ))
    }

    func usageURL(region: String) -> URL {
        region.lowercased() == "global" ? Self.globalUsageURL : Self.cnUsageURL
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
