import Foundation

struct OMPOAuthAccount: Hashable, Sendable {
    let credentialID: Int
    let providerKey: String
    let accountID: String
    let email: String?

    var family: String { providerKey == "cursor" ? "cursor" : "grok" }
    var cardID: String { ProviderAccountID.make(family: family, identityKey: accountID) }
    var accountLabel: String { email ?? String(cardID.suffix(8)) }
}

struct OMPOAuthCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
}

enum OMPOAuthError: Error, LocalizedError, CategorizedError {
    case unavailable(String)
    case sessionExpired(String)
    case invalidStore
    case readOnly

    var errorDescription: String? {
        switch self {
        case .unavailable(let provider):
            "This \(provider) account is no longer available in OMP. Sign in again in OMP and restart OpenUsage."
        case .sessionExpired(let provider):
            "This \(provider) login has expired. Refresh or sign in to this account in OMP."
        case .invalidStore:
            "OMP account credentials could not be read. Check your OMP installation and sign-in."
        case .readOnly:
            "OMP owns this login. Refresh it in OMP instead of OpenUsage."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .unavailable: .notLoggedIn
        case .sessionExpired: .authExpired
        case .invalidStore, .readOnly: .authInvalid
        }
    }
}

/// Borrows only access tokens. OMP owns its refresh leases and remains the sole credential writer.
struct OMPOAuthStore: Sendable {
    static let databasePath = "~/.omp/agent/agent.db"

    private struct Row: Decodable {
        let id: Int
        let provider: String
        let access: String?
        let expires: Double?
        let email: String?
        let accountId: String?
    }

    private let sqlite: SQLiteAccessing
    private let files: TextFileAccessing
    private let databasePath: String

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        databasePath: String = OMPOAuthStore.databasePath
    ) {
        self.sqlite = sqlite
        self.files = files
        self.databasePath = databasePath
    }

    func accounts() throws -> [OMPOAuthAccount] {
        var seen = Set<String>()
        return try rows().compactMap { row in
            guard let token = row.access?.nilIfEmpty,
                  let identity = Self.accountID(providerKey: row.provider, token: token, fallback: row.accountId)
            else { return nil }
            guard seen.insert("\(row.provider):\(identity)").inserted else { return nil }
            return OMPOAuthAccount(
                credentialID: row.id, providerKey: row.provider, accountID: identity,
                email: row.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        }
    }

    func credential(for account: OMPOAuthAccount) throws -> OMPOAuthCredential {
        let name = account.family == "cursor" ? "Cursor" : "Grok"
        guard let row = try rows(credentialID: account.credentialID).first,
              row.provider == account.providerKey,
              let token = row.access?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              Self.accountID(providerKey: row.provider, token: token, fallback: row.accountId) == account.accountID
        else { throw OMPOAuthError.unavailable(name) }

        let jwtExpiry = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number)
            .flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let storedExpiry = row.expires.flatMap {
            $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil
        }
        let expiry: Date?
        if let jwtExpiry, let storedExpiry {
            expiry = min(jwtExpiry, storedExpiry)
        } else {
            expiry = jwtExpiry ?? storedExpiry
        }
        return OMPOAuthCredential(accessToken: token, expiresAt: expiry)
    }

    static func accountID(providerKey: String, token: String, fallback: String? = nil) -> String? {
        let subject = (ProviderParse.jwtPayload(token)?["sub"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if providerKey == "cursor" {
            return subject?.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init)?.nilIfEmpty
        }
        return subject ?? fallback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func rows(credentialID: Int? = nil) throws -> [Row] {
        guard files.exists(databasePath) else { return [] }
        let rowFilter = credentialID.map { " AND id = \($0)" } ?? ""
        // Do not select refresh tokens. Every query is read-only, including the SQLite accessor's
        // WAL fallback; no migrations, auth writes, or OMP refresh leases are touched.
        let sql = """
        SELECT COALESCE(json_group_array(json_object(
          'id', id, 'provider', provider,
          'access', json_extract(data, '$.access'),
          'expires', json_extract(data, '$.expires'),
          'email', json_extract(data, '$.email'),
          'accountId', json_extract(data, '$.accountId')
        )), '[]') FROM (
          SELECT id, provider, data FROM auth_credentials
          WHERE provider IN ('cursor', 'xai-oauth')
            AND credential_type = 'oauth' AND disabled_cause IS NULL\(rowFilter)
          ORDER BY id
        );
        """
        do {
            guard let text = try sqlite.queryValue(path: databasePath, sql: sql) else { return [] }
            return try JSONDecoder().decode([Row].self, from: Data(text.utf8))
        } catch {
            // A database error may quote credential JSON; never log the underlying error text.
            AppLog.error(.auth, "OMP OAuth credential database could not be read")
            throw OMPOAuthError.invalidStore
        }
    }
}
