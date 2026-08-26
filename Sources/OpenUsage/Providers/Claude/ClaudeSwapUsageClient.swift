import Foundation

enum ClaudeSwapUsageError: Error, LocalizedError, Equatable {
    /// `usage.json` exists but could not be read (permissions, encoding).
    case cacheUnreadable(String)
    /// `usage.json` is not the table this reader understands.
    case invalidCache
    /// `usage.json` is stamped with a schema this reader was not written against.
    case unsupportedSchema(Int)
    /// claude-swap's own last poll for this account failed; the payload is its stable error token
    /// (`http-429`, `timeout`, `network`, `bad-response`, `invalid_grant`, …).
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .cacheUnreadable(let reason):
            return "Couldn't read claude-swap's usage cache: \(reason)"
        case .invalidCache:
            return "claude-swap's usage cache is not in a readable format."
        case .unsupportedSchema:
            return "claude-swap's usage cache uses a newer format than OpenUsage understands."
        case .pollFailed(let token):
            return Self.pollFailureText(token)
        }
    }

    /// Friendly copy for claude-swap's error tokens. OpenUsage never polls these accounts itself, so
    /// every remedy points back at `cswap`.
    private static func pollFailureText(_ token: String) -> String {
        switch token {
        case "http-429":
            return "claude-swap is rate limited by Anthropic. Usage updates once the limit clears."
        case "timeout", "network":
            return "claude-swap couldn't reach Anthropic to update this account."
        case "bad-response":
            return "claude-swap got an unreadable usage response for this account."
        case "invalid_grant", "no_refresh_token", "http-401", "http-403":
            return "claude-swap can't sign in to this account. Run `cswap` and re-authenticate it."
        default:
            return "claude-swap couldn't update this account (\(token))."
        }
    }

    /// Map claude-swap's token onto the shared telemetry buckets. `http-<code>` reuses the HTTP split
    /// so a 429 still reads as rate limiting.
    static func category(forPollFailure token: String) -> ErrorCategory {
        if token.hasPrefix("http-"), let status = Int(token.dropFirst("http-".count)) {
            return ErrorCategory.http(status)
        }
        switch token {
        case "timeout", "network": return .network
        case "bad-response": return .decoding
        case "invalid_grant", "no_refresh_token": return .authExpired
        default: return .other
        }
    }
}

/// One account's row in claude-swap's usage cache, normalized. claude-swap re-polls every managed
/// account (~3 minutes per account) whenever any of its surfaces runs — the menu bar, `cswap auto`,
/// `cswap list` — so this file, not the network, is the freshness source for the extra cards.
struct ClaudeSwapUsageEntry: Equatable, Sendable {
    /// One usage window as claude-swap stores it: a percent plus, when the window has started, the
    /// instant it resets. `resets_at` is absent for an untouched window.
    struct Window: Equatable, Sendable {
        var pct: Double
        var resetsAt: Date?
    }

    /// A per-model weekly window (`scoped[]`), named by the model's display name (e.g. "Fable").
    struct ScopedWindow: Equatable, Sendable {
        var name: String
        var pct: Double
        var resetsAt: Date?
    }

    var email: String?
    var organizationUUID: String?
    /// `true` once claude-swap has recorded at least one successful measurement for the slot.
    var hasLastGood: Bool
    var fiveHour: Window?
    var sevenDay: Window?
    var scoped: [ScopedWindow]
    /// When the stored measurement was taken. Absent until the first success.
    var fetchedAt: Date?
    /// claude-swap's error token for its most recent poll; cleared on every success.
    var lastError: String?
}

/// Reads claude-swap's usage table. Purely local: no network, no credentials, no Keychain — the OAuth
/// tokens claude-swap manages are never touched.
struct ClaudeSwapUsageClient: Sendable {
    static let cachePath = ClaudeSwapDiscovery.stashDirectory + "/cache/usage.json"
    /// claude-swap's `SCHEMA_VERSION`. It stamps every table it writes, so a different number means
    /// the layout below may no longer describe the file — fail loudly rather than read a renamed key
    /// or a rescaled percent as if nothing changed.
    static let supportedSchemaVersion = 2

    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.homeDirectory = homeDirectory
    }

    /// The row claude-swap last wrote for `slot`, or `nil` when the cache (or the row) doesn't exist
    /// yet — a brand-new slot claude-swap hasn't polled reads as no data, not as an error.
    func entry(slot: String) throws -> ClaudeSwapUsageEntry? {
        let path = expandTilde(Self.cachePath)
        let text: String
        do {
            guard let contents = try files.readTextIfPresent(path) else { return nil }
            text = contents
        } catch {
            throw ClaudeSwapUsageError.cacheUnreadable(error.localizedDescription)
        }
        guard let root = ProviderParse.jsonObject(Data(text.utf8)) else {
            throw ClaudeSwapUsageError.invalidCache
        }
        // A version-less file is claude-swap's own pre-v2 legacy shape, which claude-swap itself
        // treats as empty — it is not a table this reader can trust either.
        guard let version = ProviderParse.number(root["schemaVersion"]).map({ Int($0) }) else {
            throw ClaudeSwapUsageError.invalidCache
        }
        guard version == Self.supportedSchemaVersion else {
            throw ClaudeSwapUsageError.unsupportedSchema(version)
        }
        guard let accounts = root["accounts"] as? [String: Any] else {
            throw ClaudeSwapUsageError.invalidCache
        }
        guard let row = accounts[slot] as? [String: Any] else { return nil }
        return Self.entry(from: row)
    }

    static func entry(from row: [String: Any]) -> ClaudeSwapUsageEntry {
        let lastGood = row["lastGood"] as? [String: Any]
        return ClaudeSwapUsageEntry(
            email: (row["email"] as? String)?.nilIfEmpty,
            organizationUUID: (row["organizationUuid"] as? String)?.nilIfEmpty,
            hasLastGood: lastGood != nil,
            fiveHour: window(lastGood?["five_hour"]),
            sevenDay: window(lastGood?["seven_day"]),
            scoped: scopedWindows(lastGood?["scoped"]),
            fetchedAt: ProviderParse.number(row["fetchedAt"]).map { Date(timeIntervalSince1970: $0) },
            lastError: (row["lastError"] as? String)?.nilIfEmpty
        )
    }

    private static func window(_ value: Any?) -> ClaudeSwapUsageEntry.Window? {
        guard let object = value as? [String: Any],
              let pct = ProviderParse.number(object["pct"])
        else {
            return nil
        }
        return ClaudeSwapUsageEntry.Window(pct: pct, resetsAt: resetDate(object["resets_at"]))
    }

    private static func scopedWindows(_ value: Any?) -> [ClaudeSwapUsageEntry.ScopedWindow] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            guard let object = element as? [String: Any],
                  let name = (object["name"] as? String)?.nilIfEmpty,
                  let pct = ProviderParse.number(object["pct"])
            else {
                return nil
            }
            return ClaudeSwapUsageEntry.ScopedWindow(
                name: name, pct: pct, resetsAt: resetDate(object["resets_at"])
            )
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }
        return OpenUsageISO8601.date(from: text)
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }
}
