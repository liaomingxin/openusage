import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
        case omp
    }

    var accessToken: String?
    var refreshToken: String?
    /// Lowercased `cursorAuth/stripeMembershipType` from the Cursor state DB when present.
    var membershipType: String?
    var source: Source
    var expiresAt: Date? = nil
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date
    let ompAccount: OMPOAuthAccount?
    private let ompStore: OMPOAuthStore

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        ompAccount: OMPOAuthAccount? = nil,
        ompStore: OMPOAuthStore = OMPOAuthStore()
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
        self.ompAccount = ompAccount
        self.ompStore = ompStore
    }

    func loadAuthState() -> CursorAuthState? {
        if ompAccount != nil {
            return try? loadOMPAuthState()
        }

        let sqliteAccessToken = readStateValue(Self.accessTokenKey)
        let sqliteRefreshToken = readStateValue(Self.refreshTokenKey)
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            let activeAuthID = readStateValue("glass.lastSignedInAuthId")
                ?? readStateValue("cursorAuth/stripeMembershipAuthId")
            let keychainMatchesActiveAuthID = activeAuthID != nil && activeAuthID == keychainSubject
            let sqliteIsExpired = sqliteAccessToken.flatMap(Self.tokenExpiration) != nil && needsRefresh(sqliteAccessToken)
            let keychainIsFresh = keychainAccessToken.flatMap(Self.tokenExpiration) != nil && !needsRefresh(keychainAccessToken)
            if hasKeychainAuth,
               (sqliteMembershipType == "free" && subjectsDiffer)
                || (keychainMatchesActiveAuthID && subjectsDiffer)
                || (sqliteIsExpired && keychainIsFresh) {
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    membershipType: nil,
                    source: .keychain
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                membershipType: sqliteMembershipType,
                source: .sqlite
            )
        }

        return loadKeychainAuthState()
    }

    func defaultAccountLabel() -> String? {
        let state = loadAuthState()
        let subject = Self.tokenSubject(state?.accessToken)
        let profile = readStateValue("cursorAuth/cachedScopedProfile").flatMap {
            ProviderParse.jsonObject(Data($0.utf8))
        }
        if let profile, (profile["authId"] as? String) == subject || subject == nil,
           let email = (profile["email"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return email
        }
        if state?.source == .sqlite,
           let cachedEmail = readStateValue("cursorAuth/cachedEmail")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return cachedEmail
        }
        if let profile, (profile["authId"] as? String) == subject,
           let name = (profile["displayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return name
        }
        return nil
    }

    func loadKeychainAuthState() -> CursorAuthState? {
        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)
        guard keychainAccessToken != nil || keychainRefreshToken != nil else { return nil }
        return CursorAuthState(
            accessToken: keychainAccessToken,
            refreshToken: keychainRefreshToken,
            source: .keychain
        )
    }

    func loadOMPAuthState() throws -> CursorAuthState {
        guard let ompAccount else {
            throw OMPOAuthError.unavailable("Cursor")
        }
        let credential = try ompStore.credential(for: ompAccount)
        return CursorAuthState(
            accessToken: credential.accessToken,
            refreshToken: nil,
            source: .omp,
            expiresAt: credential.expiresAt
        )
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, source: CursorAuthState.Source) throws {
        guard ompAccount == nil else {
            throw OMPOAuthError.readOnly
        }
        switch source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        case .omp:
            throw OMPOAuthError.readOnly
        }
    }

    private func readStateValue(_ key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
