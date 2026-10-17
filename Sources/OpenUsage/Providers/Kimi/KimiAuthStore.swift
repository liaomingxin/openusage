import Foundation

/// The OAuth credential the `kimi` CLI keeps after `/login`. The access token lives 15 minutes; the
/// refresh token rotates on every refresh and must be written back or the next refresh dead-ends
/// with `invalid_grant` (see docs/research/kimi-code-usage-api.md).
struct KimiCredentials: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    /// Unix seconds. Present on every login/refresh the CLI writes; treated as missing when absent.
    var expiresAt: Int?
    var expiresIn: Int?
    var scope: String?
    var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case invalidAuthPayload

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `kimi` and use /login to authenticate."
        case .sessionExpired:
            return "Session expired. Run `kimi` and log in again."
        case .invalidAuthPayload:
            return "Kimi Code auth data is invalid."
        }
    }
}

/// Reads the default CLI OAuth credentials, or an additional card's app-managed API key.
/// API-key cards never read the CLI's credentials or device ID. The region selects the usage API
/// host (`cn` → api.kimi.com, `global` → api.kimi.ai).
struct KimiAuthStore: Sendable {
    static let kimiHome = "~/.kimi-code"
    static let credentialsPath = kimiHome + "/credentials/kimi-code.json"
    static let regionPath = kimiHome + "/region"
    static let deviceIDPath = kimiHome + "/device_id"
    /// Refresh once the access token is within this window of `expires_at`. The token itself lives
    /// 900 s, so a minute of slack refreshes eagerly without ever sending a known-expired token.
    static let refreshWindow: TimeInterval = 60

    var files: TextFileAccessing
    var now: @Sendable () -> Date
    let apiKeyPath: String?
    let regionOverride: String?

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        apiKeyPath: String? = nil,
        regionOverride: String? = nil
    ) {
        self.files = files
        self.now = now
        self.apiKeyPath = apiKeyPath
        self.regionOverride = regionOverride
    }

    var usesAPIKey: Bool { apiKeyPath != nil }

    /// The stored credential, or `nil` when the file is missing/unreadable or carries no refresh
    /// token — without one there is no way to mint fresh access tokens, which is the same bar
    /// `refresh()` and `hasLocalCredentials()` apply (they share this loader).
    func loadCredentials() -> KimiCredentials? {
        guard !usesAPIKey,
              files.exists(Self.credentialsPath),
              let text = try? files.readText(Self.credentialsPath),
              let credentials = Self.parse(text),
              credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return credentials
    }

    /// Reads only this card's app-managed key file, never environment variables or another login.
    func loadAPIKey() -> String? {
        guard let apiKeyPath,
              files.exists(apiKeyPath),
              let text = try? files.readText(apiKeyPath)
        else {
            return nil
        }
        return UserAPIKeyStore.keyFromConfigText(text)
    }

    /// Persists rotated credentials only to the default CLI source. API-key cards cannot write it.
    func save(_ credentials: KimiCredentials) throws {
        guard !usesAPIKey else { throw KimiAuthError.invalidAuthPayload }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(credentials),
              let text = String(data: data, encoding: .utf8)
        else {
            throw KimiAuthError.invalidAuthPayload
        }
        try files.writeText(Self.credentialsPath, text)
    }

    /// Whether the access token is expired (or within `refreshWindow` of expiring). With no readable
    /// `expires_at` we refresh too — a token of unknown age that might be 15 minutes stale beats a
    /// guaranteed 401 round-trip, and the refresh endpoint either rotates cheaply or fails loudly.
    func needsRefresh(_ credentials: KimiCredentials) -> Bool {
        guard let expiresAt = credentials.expiresAt else { return true }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt)).timeIntervalSince(now()) <= Self.refreshWindow
    }

    /// `cn` (the default) or `global` — selects the usage API host.
    func region() -> String {
        if let regionOverride {
            let trimmed = regionOverride.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? "cn" : trimmed
        }
        guard files.exists(Self.regionPath),
              let raw = try? files.readText(Self.regionPath)
        else {
            return "cn"
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "cn" : trimmed
    }

    /// The CLI's device ID belongs only to its default OAuth account.
    func deviceID() -> String? {
        guard !usesAPIKey else { return nil }
        guard files.exists(Self.deviceIDPath),
              let raw = try? files.readText(Self.deviceIDPath)
        else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parse(_ text: String) -> KimiCredentials? {
        ProviderParse.decodeJSONWithHexFallback(text, as: KimiCredentials.self)
    }
}

/// Additional API-key cards provide guidance independent of the default CLI login.
enum KimiAccountAuthError: Error, LocalizedError, Equatable, CategorizedError {
    case missingAPIKey
    case rejectedAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "This card's Kimi API key is missing or invalid. Replace the account's key in Customize."
        case .rejectedAPIKey:
            return "Kimi rejected this card's API key. Replace it in Customize with a Kimi Coding Plan key, not a Moonshot Open Platform key."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .missingAPIKey: .notLoggedIn
        case .rejectedAPIKey: .authInvalid
        }
    }
}
