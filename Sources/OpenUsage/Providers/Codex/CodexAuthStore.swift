import Foundation

struct CodexTokens: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

/// How an on-disk Codex credential is laid out. The Codex CLI writes a nested `tokens` object;
/// cli-proxy-api (and similar dumps) flatten the same fields to the top level and add `type`/`email`.
enum CodexAuthFileFormat: String, Hashable, Sendable {
    case nestedTokens
    case flattened
}

struct CodexAccountIdentity: Equatable, Sendable {
    var identityKey: String
    var label: String?
}

struct CodexAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file(path: String, format: CodexAuthFileFormat)
        case keychain
    }

    var auth: CodexAuth
    var source: Source

    /// Whether this candidate carries a non-empty OAuth access token — the same bar `refresh()`'s
    /// probe requires before fetching usage (an API-key-only auth.json can't serve the usage API).
    /// `hasLocalCredentials()`'s first-run detection checks this, so the two can never drift.
    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.isEmpty == false
    }
}

enum CodexAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenConflict
    case tokenRevoked
    case tokenExpired
    case usageAPIKey
    case invalidAuthPayload

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `codex` to authenticate."
        case .sessionExpired:
            return "Session expired. Run `codex` to log in again."
        case .tokenConflict:
            return "Token conflict. Run `codex` to log in again."
        case .tokenRevoked:
            return "Token revoked. Run `codex` to log in again."
        case .tokenExpired:
            return "Token expired. Run `codex` to log in again."
        case .usageAPIKey:
            return "Usage not available for API key."
        case .invalidAuthPayload:
            return "Codex auth data is invalid."
        }
    }

    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenConflict, .tokenRevoked, .tokenExpired:
            return true
        case .notLoggedIn, .usageAPIKey, .invalidAuthPayload:
            return false
        }
    }
}

struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    /// Refresh once the access token is within this window of its JWT `exp` — the same 5-minute slack
    /// the `codex` CLI itself uses, so OpenUsage rotates on the same schedule rather than guessing.
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    private static let authFile = "auth.json"
    private static let defaultAuthHomes = ["~/.config/codex", "~/.codex"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date
    /// When set, this store reads and writes only that one credential file — used for extra-account
    /// cards so they never fall through to another home or the keychain.
    var scopedAuthPath: String?

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        scopedAuthPath: String? = nil
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.now = now
        self.scopedAuthPath = scopedAuthPath
    }

    func loadAuthCandidates() -> [CodexAuthState] {
        authPaths().compactMap { loadAuth(at: $0) }
    }

    /// Reads the credential from a single on-disk auth file — the targeted counterpart to
    /// `loadKeychainAuth()`, used when reloading the exact source we already loaded from so we don't
    /// re-scan every candidate path. Returns `nil` when the file is missing, unreadable, or doesn't
    /// carry token-like auth.
    func loadAuth(at path: String) -> CodexAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let auth = Self.parseAuth(text),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .file(path: path, format: Self.detectFormat(text)))
    }

    func loadKeychainAuth() -> CodexAuthState? {
        // Extra-account cards are file-scoped: a shared keychain item belongs to whoever last wrote
        // it, not this card, so falling through would stamp the wrong account on the snapshot.
        guard scopedAuthPath == nil else { return nil }
        guard let value = try? keychain.readGenericPassword(service: Self.keychainService),
              let auth = Self.parseAuth(value),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .keychain)
    }

    func save(_ state: CodexAuthState) throws {
        switch state.source {
        case .file(let path, .flattened):
            try saveFlattened(state.auth, at: path)
        case .file(let path, .nestedTokens):
            try files.writeText(path, try encodeAuth(state.auth, prettyPrinted: true))
        case .keychain:
            try keychain.writeGenericPassword(
                service: Self.keychainService,
                value: try encodeAuth(state.auth, prettyPrinted: false)
            )
        }
    }

    private func encodeAuth(_ auth: CodexAuth, prettyPrinted: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : []
        let data = try encoder.encode(auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }
        return text
    }

    /// Whether the access token should be proactively refreshed.
    ///
    /// Prefers the access token's own JWT `exp` — refresh only when it is at (or within
    /// `accessTokenRefreshWindow` of) expiry, mirroring the `codex` CLI. The hardcoded 8-day
    /// wall-clock age is only a fallback for tokens whose `exp` we can't read; on its own it forced a
    /// refresh while the access token was still valid, tripping `refresh_token_reused` (issue #516).
    /// A brand-new login with no `last_refresh` and no readable `exp` does NOT need a refresh.
    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let accessToken = auth.tokens?.accessToken,
           let expiresAt = accessTokenExpiresAt(accessToken) {
            return expiresAt.timeIntervalSince(now()) <= Self.accessTokenRefreshWindow
        }
        guard let lastRefresh = auth.lastRefresh,
              let date = OpenUsageISO8601.date(from: lastRefresh)
        else {
            return false
        }
        return now().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    /// The access token's expiry from its JWT `exp` claim, or `nil` when the token isn't a decodable
    /// JWT or omits `exp`.
    func accessTokenExpiresAt(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func authPaths() -> [String] {
        if let scopedAuthPath {
            return [scopedAuthPath]
        }
        if let codexHome = codexHome() {
            return [joinPath(codexHome, Self.authFile)]
        }
        return Self.defaultAuthHomes.map { joinPath($0, Self.authFile) }
    }

    func codexHome() -> String? {
        guard let codexHome = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexHome.isEmpty
        else {
            return nil
        }
        return codexHome
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        if let nested = ProviderParse.decodeJSONWithHexFallback(text, as: CodexAuth.self),
           hasTokenLikeAuth(nested) {
            return nested
        }
        guard let flattened = ProviderParse.decodeJSONWithHexFallback(text, as: FlattenedCodexAuthFile.self)
        else {
            return nil
        }
        let auth = flattened.asCodexAuth()
        return hasTokenLikeAuth(auth) ? auth : nil
    }

    /// Nested Codex CLI `auth.json` vs a flattened dump (`access_token` at the top level). A file
    /// with both is treated as nested — that's the CLI shape, and flattening it on save would drop
    /// fields the CLI still reads.
    static func detectFormat(_ text: String) -> CodexAuthFileFormat {
        guard let object = ProviderParse.jsonObject(Data(text.utf8)) else { return .nestedTokens }
        if object["tokens"] is [String: Any] { return .nestedTokens }
        if object["access_token"] is String { return .flattened }
        return .nestedTokens
    }

    /// Strict identity: `tokens.account_id`, else the id_token's ChatGPT account claim. No path-derived
    /// fallback — a credential that can't name its account never becomes a card.
    static func accountIdentity(from auth: CodexAuth, emailOverride: String? = nil) -> CodexAccountIdentity? {
        let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
        let email = emailOverride?.nilIfEmpty
            ?? (payload?["email"] as? String)?.nilIfEmpty
        if let accountID = auth.tokens?.accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return CodexAccountIdentity(identityKey: accountID.lowercased(), label: email)
        }
        if let claimID = DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload) {
            return CodexAccountIdentity(identityKey: claimID.lowercased(), label: email)
        }
        return nil
    }

    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        if auth.tokens?.accessToken?.isEmpty == false { return true }
        if auth.apiKey?.isEmpty == false { return true }
        return false
    }

    /// Rewrite only the token fields of a flattened dump so sibling keys (`email`, `type`, `expired`,
    /// `disabled`) survive a refresh.
    private func saveFlattened(_ auth: CodexAuth, at path: String) throws {
        var object: [String: Any] = [:]
        if let existing = try files.readTextIfPresent(path),
           let parsed = ProviderParse.jsonObject(Data(existing.utf8)) {
            object = parsed
        }
        if object["type"] == nil { object["type"] = "codex" }
        if let token = auth.tokens?.accessToken { object["access_token"] = token }
        if let token = auth.tokens?.refreshToken { object["refresh_token"] = token }
        if let token = auth.tokens?.idToken { object["id_token"] = token }
        if let accountID = auth.tokens?.accountID { object["account_id"] = accountID }
        if let lastRefresh = auth.lastRefresh { object["last_refresh"] = lastRefresh }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }
        try files.writeText(path, text)
    }

    private func joinPath(_ base: String, _ leaf: String) -> String {
        base.trimmingTrailingSlashes + "/" + leaf
    }
}

/// Flattened Codex credential dump (cli-proxy-api `codex-*.json` and similar). Same OAuth fields as
/// the CLI's nested `tokens` object, plus dump-specific metadata we preserve on save.
private struct FlattenedCodexAuthFile: Codable {
    var type: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var email: String?
    var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case type
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
        case email
        case lastRefresh = "last_refresh"
    }

    func asCodexAuth() -> CodexAuth {
        CodexAuth(
            tokens: CodexTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                accountID: accountID
            ),
            lastRefresh: lastRefresh,
            apiKey: nil
        )
    }
}

