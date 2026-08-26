import Foundation

struct ZAIAuth: Hashable, Sendable {
    var apiKey: String
    /// Which console the key belongs to (see `ZAIPlatform`). Every request this auth backs uses it.
    var platform: ZAIPlatform = .fallback
}

enum ZAIAuthError: Error, LocalizedError, Equatable {
    case missingKey
    /// Carries the platform so the message names the console the key was actually tried against.
    case invalidKey(ZAIPlatform)
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Z.ai API key. Set ZAI_API_KEY or add it to ~/.config/openusage/zai.json."
        case .invalidKey(let platform):
            return "Z.ai API key invalid. Check your key at \(platform.apiKeysLabel)."
        case .saveFailed:
            return "Couldn't save the Z.ai API key."
        case .deleteFailed:
            return "Couldn't remove the saved Z.ai API key."
        }
    }
}

/// Reads a [Z.ai](https://z.ai) (Zhipu AI) API key the user has already placed on the machine. Like
/// OpenRouter, Z.ai has no companion CLI/app that stashes a credential in a known spot, so the key
/// comes from an environment variable or a small config file. A GUI app launched from Finder/Dock
/// doesn't inherit the interactive shell environment, so `ProcessEnvironmentReader` captures the
/// login shell's environment at launch (see `LoginShellEnvironment`) — meaning an env var exported
/// in a shell profile is honored even in a packaged build; the config file remains the explicit path.
///
/// `ZAI_API_KEY` is the primary name; `GLM_API_KEY` is accepted as a fallback (the older Zhipu name
/// some users still export), mirroring the legacy plugin's lookup order.
///
/// The same config file also stores the platform choice (`"platform": "global" | "cn"`), because a
/// key is only valid on the console that issued it — so the key and the host it is sent to travel
/// together. The platform is read from the first config file that names one; a file that names none
/// (and an environment-only key) reads as the global platform.
struct ZAIAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key. The optional `platform` field lives in the same JSON.
    static let configPaths = [
        "~/.config/openusage/zai.json",
        "~/.config/zai/key.json"
    ]
    /// Environment variables checked in order. `ZAI_API_KEY` is current; `GLM_API_KEY` is the legacy
    /// Zhipu name some users still have exported.
    static let environmentNames = ["ZAI_API_KEY", "GLM_API_KEY"]
    /// The JSON field the platform choice is stored under, in the primary config file.
    static let platformField = "platform"

    private let store: UserAPIKeyStore
    private let files: TextFileAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { ZAIAuthError($0) }
        )
    }

    func loadAPIKey() -> ZAIAuth? {
        store.loadKey().map { ZAIAuth(apiKey: $0, platform: loadPlatform()) }
    }

    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }

    /// The stored platform, or `.global` when no config file names one.
    func loadPlatform() -> ZAIPlatform {
        for path in Self.configPaths {
            guard let object = configObject(at: path),
                  let raw = object[Self.platformField] as? String,
                  ZAIPlatform(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) != nil
            else { continue }
            return ZAIPlatform(configValue: raw)
        }
        return .fallback
    }

    /// Persist the platform choice into the primary config file, keeping whatever key (and any other
    /// field) that file already holds. Writing it for an environment-only key is fine: a file with no
    /// key field leaves the environment key in charge.
    func savePlatform(_ platform: ZAIPlatform) throws {
        var object = configObject(at: Self.configPaths[0]) ?? [:]
        object[Self.platformField] = platform.rawValue
        try write(object, to: Self.configPaths[0])
    }

    /// Save the key without losing the platform choice — `UserAPIKeyStore.saveKey` rewrites the file
    /// as a bare `{"apiKey": …}`, which would silently drop it (and send the next refresh to the wrong
    /// host).
    func saveAPIKey(_ key: String) throws {
        let platform = loadPlatform()
        try store.saveKey(key)
        if platform != .fallback {
            try savePlatform(platform)
        }
    }

    /// Clearing the key removes the config files; the platform choice is re-written afterwards so
    /// re-entering a key doesn't silently move the account back to the global console.
    func deleteAPIKey() throws {
        let platform = loadPlatform()
        try store.deleteKey()
        if platform != .fallback {
            try savePlatform(platform)
        }
    }

    private func configObject(at path: String) -> [String: Any]? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func write(_ object: [String: Any], to path: String) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { throw ZAIAuthError.saveFailed }
        do {
            try files.writeText(path, text)
        } catch {
            AppLog.error(.auth, "save Z.ai platform to \(path) failed: \(error.localizedDescription)")
            throw ZAIAuthError.saveFailed
        }
    }
}
