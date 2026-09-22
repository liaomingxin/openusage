import Foundation

/// Maps a pi session log's `provider` field to the OpenUsage provider whose card its usage belongs on.
/// Pi is a BYO-key agent that drives other providers' models, so its usage is attributed back to the
/// underlying provider (a Claude sub used inside pi lands on the Claude card) rather than shown on a
/// card of its own.
///
/// Only providers OpenUsage already has a card for are listed. Pi providers with no OpenUsage
/// equivalent are intentionally absent and left for future work:
/// - `nvidia-nim` — no OpenUsage card.
///
/// `cursor`, `google-antigravity`, and `github-copilot` stay mapped for the Agent Usage screen
/// but no card consumes them: Cursor's headline is its account CSV, Antigravity already scans its
/// own databases, and Copilot CLI is out of scope. Consuming them would double-count.
enum PiProviderMapping {
    /// pi `provider` value → OpenUsage `Provider.id`.
    static let providerToCard: [String: String] = [
        "anthropic": "claude",
        "claude-agent-sdk": "claude",
        "openai-codex": "codex",
        "xai": "grok",
        "kimi-coding": "kimi",
        "cursor": "cursor",
        "zai": "zai",
        "zhipu": "zai",
        "zai-coding-cn": "zai",
        "google-antigravity": "antigravity",
        "github-copilot": "copilot"
    ]

    /// The OpenUsage card id for a pi provider, or nil when pi used a provider OpenUsage doesn't track.
    static func cardID(forPiProvider provider: String) -> String? {
        providerToCard[provider]
    }
}
