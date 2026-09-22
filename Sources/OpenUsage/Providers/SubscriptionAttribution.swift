import Foundation

/// Where one local agent row belongs, once its provider id and optional base URL are known.
/// `addToLocalSpend` changes that card's Today / Yesterday / Last 30 Days totals.
/// `thisMacDetail` is a hover-only breakdown and must not change a server-backed headline.
struct SubscriptionAttribution: Sendable, Equatable {
    var cardID: String
    var mode: SubscriptionSpendMode
}

enum SubscriptionSpendMode: Sendable, Equatable {
    case addToLocalSpend
    case thisMacDetail
}

/// Official-login allowlist for agent logs. A provider id counts only for that provider's own
/// service. A base URL, when the log has one, must be that service's host; gateways and localhost
/// proxies are dropped even when the provider id looks official. Model names are never consulted.
enum SubscriptionAttributionRules {
    static func attribution(providerID: String, baseURL: String? = nil) -> SubscriptionAttribution? {
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !provider.isEmpty, !excludedProviders.contains(provider) else { return nil }
        guard !isProxy(baseURL) else { return nil }
        guard let rule = rule(for: provider) else { return nil }
        if let baseURL = normalized(baseURL), !matches(baseURL, rule: rule) { return nil }
        return SubscriptionAttribution(cardID: rule.cardID, mode: rule.mode)
    }

    private struct Rule {
        var cardID: String
        var mode: SubscriptionSpendMode
        /// Empty means any non-proxy URL is rejected: the caller passed a host we do not recognize
        /// as this provider's. No URL at all is still accepted, because some logs only name the provider.
        var officialMarkers: [String]
    }

    private static let excludedProviders: Set<String> = [
        "cliproxy-openai", "02yidyidayidao-openai", "bmw888",
        "github-copilot", "cursor", "google-antigravity",
        "custom", "opencode", "opencode-go"
    ]

    private static let proxyMarkers = ["6688ai.xyz", "127.0.0.1", "localhost"]

    private static func rule(for provider: String) -> Rule? {
        if provider.contains("bigmodel") {
            return Rule(cardID: "zai", mode: .thisMacDetail, officialMarkers: ["api.z.ai"])
        }
        switch provider {
        case "anthropic", "claude-agent-sdk":
            return Rule(cardID: "claude", mode: .addToLocalSpend, officialMarkers: ["api.anthropic.com"])
        case "openai-codex":
            return Rule(cardID: "codex", mode: .addToLocalSpend, officialMarkers: ["chatgpt.com/backend-api/codex"])
        case "openai":
            return Rule(cardID: "codex", mode: .addToLocalSpend, officialMarkers: ["api.openai.com"])
        case "xai":
            return Rule(cardID: "grok", mode: .addToLocalSpend, officialMarkers: ["api.x.ai"])
        case "kimi-coding", "kimi-for-coding", "moonshotai-cn":
            return Rule(
                cardID: "kimi", mode: .addToLocalSpend,
                officialMarkers: ["api.kimi.com", "api.kimi.ai", "api.moonshot.cn", "api.moonshot.com"]
            )
        case "zai", "zhipu", "zai-coding-cn", "zai-coding-plan":
            return Rule(cardID: "zai", mode: .thisMacDetail, officialMarkers: ["api.z.ai"])
        default:
            return nil
        }
    }

    private static func isProxy(_ baseURL: String?) -> Bool {
        guard let baseURL = normalized(baseURL) else { return false }
        return proxyMarkers.contains { baseURL.contains($0) }
    }

    private static func matches(_ baseURL: String, rule: Rule) -> Bool {
        rule.officialMarkers.contains { baseURL.contains($0) }
    }

    private static func normalized(_ baseURL: String?) -> String? {
        guard let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
