import XCTest
@testable import OpenUsage

final class SubscriptionAttributionTests: XCTestCase {
    func testAllowlist() {
        let cases: [(String, String?, String, SubscriptionSpendMode)] = [
            ("anthropic", nil, "claude", .addToLocalSpend),
            ("claude-agent-sdk", nil, "claude", .addToLocalSpend),
            ("anthropic", "https://api.anthropic.com", "claude", .addToLocalSpend),
            ("openai-codex", nil, "codex", .addToLocalSpend),
            ("openai-codex", "https://chatgpt.com/backend-api/codex", "codex", .addToLocalSpend),
            ("openai", nil, "codex", .addToLocalSpend),
            ("openai", "https://api.openai.com/v1", "codex", .addToLocalSpend),
            ("xai", nil, "grok", .addToLocalSpend),
            ("xai", "https://api.x.ai/v1", "grok", .addToLocalSpend),
            ("kimi-coding", nil, "kimi", .addToLocalSpend),
            ("kimi-for-coding", "https://api.kimi.com/coding", "kimi", .addToLocalSpend),
            ("moonshotai-cn", "https://api.moonshot.cn/v1", "kimi", .addToLocalSpend),
            ("zai", "https://api.z.ai/api/coding/paas/v4", "zai", .thisMacDetail),
            ("zhipu", nil, "zai", .thisMacDetail),
            ("zai-coding-cn", nil, "zai", .thisMacDetail),
            ("zai-coding-plan", nil, "zai", .thisMacDetail),
            ("builtin:bigmodel-coding-plan", nil, "zai", .thisMacDetail),
            ("account:bigmodel-individual-coding-plan", nil, "zai", .thisMacDetail)
        ]
        for (provider, url, card, mode) in cases {
            let attribution = SubscriptionAttributionRules.attribution(providerID: provider, baseURL: url)
            XCTAssertEqual(attribution?.cardID, card, provider)
            XCTAssertEqual(attribution?.mode, mode, provider)
        }
    }

    func testExclusions() {
        let dropped: [(String, String?)] = [
            ("anthropic", "https://6688ai.xyz"),
            ("openai-codex", "http://127.0.0.1:8317/v1"),
            ("custom", "http://localhost:8317/v1"),
            ("xai", "https://6688ai.xyz/v1"),
            ("zai", "https://example.com"),
            ("cliproxy-openai", nil),
            ("02yidyidayidao-openai", nil),
            ("bmw888", nil),
            ("github-copilot", nil),
            ("cursor", nil),
            ("google-antigravity", nil),
            ("custom", nil),
            ("opencode", nil),
            ("opencode-go", nil),
            ("deepseek", nil),
            ("", nil)
        ]
        for (provider, url) in dropped {
            XCTAssertNil(
                SubscriptionAttributionRules.attribution(providerID: provider, baseURL: url),
                "\(provider) \(url ?? "no url")"
            )
        }
    }
}
