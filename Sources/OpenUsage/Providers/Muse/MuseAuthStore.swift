import Foundation

struct MuseCredentials: Sendable, Equatable {
    var accessToken: String
    var apiBaseURL: String
    var userEmail: String?
    var userFullName: String?

    init(
        accessToken: String,
        apiBaseURL: String = MuseAuthStore.defaultAPIBaseURL,
        userEmail: String? = nil,
        userFullName: String? = nil
    ) {
        self.accessToken = accessToken
        self.apiBaseURL = apiBaseURL
        self.userEmail = userEmail
        self.userFullName = userFullName
    }
}

enum MuseAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case keychainAccessDenied

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `muse login` to authenticate."
        case .sessionExpired:
            return "Muse Code session expired. Run `muse login` to re-authenticate."
        case .keychainAccessDenied:
            return "Keychain access was not granted. Press Refresh to try again."
        }
    }
}

/// Reads Muse Code credentials already on the machine (`~/.config/muse/auth.json` + macOS Keychain
/// service `ai.meta.dev.credentials`, account `meta`).
struct MuseAuthStore: Sendable {
    static let defaultAuthPath = "~/.config/muse/auth.json"
    static let defaultAPIBaseURL = "https://api.meta.ai"
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"

    private let files: TextFileAccessing
    private let keychain: KeychainAccessing
    private let environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.keychain = keychain
        self.environment = environment
    }

    var authFilePath: String {
        if let custom = environment.value(for: "MUSE_AUTH_PATH")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return custom
        }
        if let xdg = environment.value(for: "XDG_CONFIG_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return (xdg as NSString).appendingPathComponent("muse/auth.json")
        }
        return Self.defaultAuthPath
    }

    /// Popup-free local probe used by `FirstLaunchSetup` and `NewProviderSeeder`.
    func hasLocalCredentials() -> Bool {
        guard let meta = loadMetaProviderRecord() else { return false }
        if let fileToken = (meta["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return !fileToken.isEmpty
        }
        if (meta["storage"] as? String) == "keychain" {
            return keychain.genericPasswordExists(service: Self.keychainService) != false
        }
        return false
    }

    func defaultAccountLabel() -> String? {
        guard let meta = loadMetaProviderRecord() else { return nil }
        return (meta["user_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (meta["user_full_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func loadCredentials() throws -> MuseCredentials? {
        guard let meta = loadMetaProviderRecord() else { return nil }
        let baseURL = Self.normalizeBaseURL(meta["api_base_url"] as? String)
        let email = (meta["user_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let fullName = (meta["user_full_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if let fileToken = (meta["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return MuseCredentials(
                accessToken: fileToken,
                apiBaseURL: baseURL,
                userEmail: email,
                userFullName: fullName
            )
        }

        guard (meta["storage"] as? String) == "keychain" else { return nil }
        let rawSecret: String?
        do {
            rawSecret = try keychain.readGenericPassword(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch {
            throw MuseAuthError.keychainAccessDenied
        }
        guard let rawSecret,
              let secretObj = ProviderParse.jsonObject(Data(rawSecret.utf8)),
              let accessToken = (secretObj["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }
        return MuseCredentials(
            accessToken: accessToken,
            apiBaseURL: baseURL,
            userEmail: email,
            userFullName: fullName
        )
    }

    private func loadMetaProviderRecord() -> [String: Any]? {
        guard let text = try? files.readTextIfPresent(authFilePath),
              let root = ProviderParse.jsonObject(Data(text.utf8)),
              let providers = root["providers"] as? [String: Any],
              let meta = providers["meta"] as? [String: Any]
        else {
            return nil
        }
        return meta
    }

    static func normalizeBaseURL(_ raw: String?) -> String {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return defaultAPIBaseURL
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed.removeLast(3)
        }
        return trimmed.isEmpty ? defaultAPIBaseURL : trimmed
    }
}
