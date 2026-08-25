import Foundation

/// Extra Codex logins that aren't the family's default home. Today that's flattened credential
/// dumps under `~/.cli-proxy-api` (the layout `cli-proxy-api` writes: `codex-<id>-<email>-<plan>.json`).
/// A file that can't name its ChatGPT account never becomes a card — same strict identity rule as
/// the default-home observer.
struct CodexAccountDiscovery: Sendable {
    struct ExtraCredential: Equatable, Sendable {
        var path: String
        var identityKey: String
        var label: String?
    }

    static let extraDirectory = "~/.cli-proxy-api"

    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.homeDirectory = homeDirectory
    }

    func extraCredentials() -> [ExtraCredential] {
        let directory = expandTilde(Self.extraDirectory)
        return files.jsonFilePaths(in: directory).compactMap(credential(at:))
    }

    private func credential(at path: String) -> ExtraCredential? {
        let text: String
        do {
            guard let contents = try files.readTextIfPresent(path) else { return nil }
            text = contents
        } catch {
            AppLog.info(.config, "accounts: skipped unreadable Codex extra credential \(path): \(error.localizedDescription)")
            return nil
        }
        guard let object = ProviderParse.jsonObject(Data(text.utf8)) else { return nil }
        if let type = (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           type.lowercased() != "codex" {
            return nil
        }
        if ProviderParse.bool(object["disabled"]) == true { return nil }
        guard let auth = CodexAuthStore.parseAuth(text),
              auth.tokens?.accessToken?.nilIfEmpty != nil,
              let identity = CodexAuthStore.accountIdentity(
                from: auth,
                emailOverride: (object["email"] as? String)?.nilIfEmpty
              )
        else {
            return nil
        }
        return ExtraCredential(path: path, identityKey: identity.identityKey, label: identity.label)
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }
}
