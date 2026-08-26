import Foundation

/// Extra Claude logins parked in [claude-swap](https://github.com/realiti4/claude-swap)'s stash.
/// `cswap` keeps exactly one account live in `~/.claude` and backs the rest up as full `~/.claude.json`
/// snapshots under `~/.claude-swap-backup/configs/.claude-config-<slot>-<email>.json`. Each snapshot
/// carries the same `oauthAccount` object the default-home observer reads, so an inactive account can
/// name itself from a plain file — no Keychain, and so no access prompt on the launch path. Reading a
/// slot's *usage* is a separate step (`ClaudeSwapCredentialReader`), and read-only: claude-swap's own
/// token rotation must never be raced.
///
/// A snapshot that can't name its Claude account never becomes a card — the same strict identity rule
/// the default-home observer applies.
struct ClaudeSwapDiscovery: Sendable {
    /// One managed claude-swap slot: where its config snapshot lives and which account it holds.
    struct ExtraCredential: Equatable, Sendable {
        /// The config snapshot's path — the source anchor for the account record.
        var path: String
        /// claude-swap's slot number as written in the file name; also the key its usage cache uses.
        var slot: String
        var identityKey: String
        /// The account's email address, per the snapshot's `oauthAccount`. This is the card's name.
        var label: String?
        /// The account registry's label for the same account — `"email (Org Name)"` when the snapshot
        /// names an organization, exactly what the default-home observer records. A slot can share its
        /// identity with a Claude Desktop organization card, which derives its own name from the
        /// record label, so the record must carry the organization-qualified form rather than the bare
        /// email the card title uses.
        var identityLabel: String?
    }

    /// claude-swap's stash lives at a fixed path, independent of `CLAUDE_CONFIG_DIR`.
    static let stashDirectory = "~/.claude-swap-backup"
    static let configsDirectory = stashDirectory + "/configs"

    private static let fileNamePrefix = ".claude-config-"
    private static let fileNameSuffix = ".json"

    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.homeDirectory = homeDirectory
    }

    /// Every managed slot claude-swap has stashed, ordered by slot number.
    func extraCredentials() -> [ExtraCredential] {
        let directory = expandTilde(Self.configsDirectory)
        // The snapshots are dot-files, so the visible-only listing would find none of them.
        return files.jsonFilePaths(in: directory, includingHidden: true)
            .compactMap(credential(at:))
            .sorted { (Int($0.slot) ?? 0, $0.slot) < (Int($1.slot) ?? 0, $1.slot) }
    }

    private func credential(at path: String) -> ExtraCredential? {
        guard let slot = Self.slot(inFileNameOf: path) else { return nil }
        let text: String
        do {
            guard let contents = try files.readTextIfPresent(path) else { return nil }
            text = contents
        } catch {
            AppLog.warn(.config, "accounts: skipped unreadable claude-swap config \(path): \(error.localizedDescription)")
            return nil
        }
        guard let parsed = try? JSONDecoder().decode(
            DefaultAccountObserver.ClaudeStateFile.self, from: Data(text.utf8)
        ) else {
            AppLog.warn(.config, "accounts: skipped malformed claude-swap config \(path)")
            return nil
        }
        guard let account = parsed.oauthAccount,
              let identityKey = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            AppLog.warn(.config, "accounts: claude-swap config \(path) names no Claude account")
            return nil
        }
        return ExtraCredential(
            path: path,
            slot: slot,
            identityKey: identityKey,
            label: account.emailAddress?.nilIfEmpty,
            identityLabel: DefaultAccountObserver.claudeIdentityLabel(account)
        )
    }

    /// `.claude-config-2-someone@example.com.json` → `"2"`. A file in the stash that doesn't follow
    /// claude-swap's naming isn't one of its slots, so it is skipped without a warning.
    static func slot(inFileNameOf path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(fileNameSuffix) else { return nil }
        let body = name.dropFirst(fileNamePrefix.count).dropLast(fileNameSuffix.count)
        let slot = body.prefix { $0 != "-" }
        guard !slot.isEmpty, slot.allSatisfy(\.isNumber) else { return nil }
        return String(slot)
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }
}
