import Foundation

/// The OAuth access token claude-swap has stashed for one slot.
///
/// Only what a read-only usage call needs is carried: the access token, its expiry, and the two plan
/// labels that put the right badge on the card. claude-swap keeps the whole Claude Code credential
/// blob — access token, **refresh** token, expiry, plan — in the same Keychain item, and the refresh
/// token is deliberately never decoded: spending it would rotate it out from under claude-swap and
/// strand the sign-ins it manages. That is the single reason these cards read the stash at all rather
/// than authenticating themselves.
struct ClaudeSwapStashedToken: Equatable, Sendable {
    var accessToken: String
    /// When Anthropic stops honouring the token. Claude Code writes this as unix milliseconds.
    var expiresAt: Date
    /// The account's plan and rate-limit tier, the only other fields read out of the blob. They are
    /// labels rather than credentials — nothing can be signed or spent with them — and without them a
    /// stashed card can't show the "Max 20x" badge the active Claude card shows for the same account.
    var subscriptionType: String?
    var rateLimitTier: String?

    /// Whether the token is still worth spending on a usage call. The skew keeps a token that would
    /// expire mid-flight from being sent at all: a rejected call has no remedy here, because the one
    /// remedy — refreshing — is exactly what these cards must never do.
    func isFresh(now: Date, skew: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) > skew
    }
}

/// The whole OAuth surface a claude-swap card is allowed to touch: one production endpoint, reached
/// with one verb (`GET`), using a token somebody else owns.
enum ClaudeSwapOAuth {
    /// claude-swap manages claude.ai subscription logins, which are always production logins. The
    /// staging / custom-OAuth environment overrides `ClaudeAuthStore` honours describe whichever login
    /// is active in `~/.claude`, never a stashed one, so they are not consulted here.
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// `ClaudeUsageClient.fetchUsage` reads `usageURL` and nothing else, so the remaining fields are
    /// inert on this path. They are pointed back at the usage endpoint on purpose: with no token
    /// endpoint anywhere in a claude-swap card's configuration, even a future miswiring could only
    /// issue a harmless request to the usage URL instead of rotating claude-swap's refresh token. The
    /// card has nothing to rotate with either — `ClaudeSwapCredentialReader` never decodes a refresh
    /// token, and no `ClaudeAuthStore` is ever built for these cards.
    static let readOnlyConfig = ClaudeOAuthConfig(
        usageURL: usageURL, refreshURL: usageURL, clientID: ""
    )
}

/// Reads — only ever reads — the access token claude-swap stashed for one slot.
///
/// claude-swap keeps each managed account's credential blob in the macOS Keychain under its own
/// service (`claude-swap`), one item per account. This reader opens that item, takes the access token
/// and its expiry, and leaves everything else alone: it never writes, never deletes, and never
/// decodes the refresh token sitting beside them.
struct ClaudeSwapCredentialReader: Sendable {
    /// claude-swap's `SECURITY_SERVICE`.
    static let keychainService = "claude-swap"

    var keychain: KeychainAccessing

    init(keychain: KeychainAccessing = SecurityKeychainAccessor()) {
        self.keychain = keychain
    }

    /// The account labels claude-swap writes for a slot, in the order it prefers them.
    ///
    /// Current claude-swap names the item `account-<slot>-<email>`. Older versions wrote the slot as
    /// the literal `None`, and claude-swap still sweeps that alias whenever it deletes a slot, so a
    /// stash first written by one of those can still be holding its token under the legacy label.
    /// A slot is always a number here — `ClaudeSwapDiscovery` refuses any that isn't — so the two
    /// labels can never collide.
    static func accountLabels(slot: String, email: String) -> [String] {
        ["account-\(slot)-\(email)", "account-None-\(email)"]
    }

    /// The slot's stashed token, or `nil` when claude-swap has no usable item for it — no item at all,
    /// or one this reader can't make sense of. Throws only when the Keychain itself refused the read
    /// (locked, access denied, a cancelled prompt), which is a different thing from "nothing stashed"
    /// and must not be flattened into it.
    func stashedToken(slot: String, email: String) throws -> ClaudeSwapStashedToken? {
        for account in Self.accountLabels(slot: slot, email: email) {
            guard let blob = try keychain
                .readGenericPassword(service: Self.keychainService, account: account)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            else {
                continue
            }
            guard let token = Self.parse(blob) else {
                // Keep looking rather than giving up: a stash can hold a stale unreadable blob under
                // one label and the account's real token under the other.
                AppLog.warn(
                    .keychain,
                    "claude-swap: the credential stashed for slot \(slot) carries no usable access token and expiry"
                )
                continue
            }
            return token
        }
        return nil
    }

    /// claude-swap stores Claude Code's credential file verbatim, so the blob is normally the
    /// `{"claudeAiOauth": {...}}` wrapper `~/.claude/.credentials.json` uses; a bare OAuth object is
    /// tolerated as well. Only the access token, its expiry, and the two plan labels are declared — a
    /// field that is never decoded cannot be misused.
    static func parse(_ blob: String) -> ClaudeSwapStashedToken? {
        let oauth = ProviderParse.decodeJSONWithHexFallback(blob, as: StashedBlob.self)?.claudeAiOauth
            ?? ProviderParse.decodeJSONWithHexFallback(blob, as: StashedOAuth.self)
        guard let accessToken = oauth?.accessToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            return nil
        }
        // A blob with no expiry is refused rather than tried: without one there is no way to tell a
        // live token from a spent one, and the usual way of finding out — send it and refresh if it
        // bounces — is precisely what these cards may not do.
        guard let milliseconds = oauth?.expiresAt, milliseconds.isFinite, milliseconds > 0 else {
            return nil
        }
        return ClaudeSwapStashedToken(
            accessToken: accessToken,
            expiresAt: Date(timeIntervalSince1970: milliseconds / 1000),
            subscriptionType: oauth?.subscriptionType,
            rateLimitTier: oauth?.rateLimitTier
        )
    }

    private struct StashedOAuth: Decodable {
        var accessToken: String?
        /// Unix milliseconds, as Claude Code writes it.
        var expiresAt: Double?
        /// Plan labels for the card's badge — `"max"` and `"default_claude_max_20x"` become "Max 20x".
        /// Nothing else in the blob is declared; the token sitting beside these that would let a card
        /// rotate claude-swap's login stays undeclared on purpose.
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    private struct StashedBlob: Decodable {
        var claudeAiOauth: StashedOAuth?
    }
}
