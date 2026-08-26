import Foundation

/// Which Z.ai console a key belongs to.
///
/// Z.ai publishes the same GLM Coding Plan API on two platforms — the global `api.z.ai` and the
/// China platform `open.bigmodel.cn` (Zhipu's BigModel console) — and an account lives on exactly
/// one of them. The endpoints, request shapes and payloads are identical; only the host and the
/// console pages differ. The choice is stored next to the key in `~/.config/openusage/zai.json`
/// (`"platform": "global" | "cn"`, missing reads as global) and every request, quick link, and
/// error-message URL follows it. There is no fallback between hosts: a key that belongs to the
/// other platform must fail loudly rather than silently retry elsewhere.
enum ZAIPlatform: String, CaseIterable, Sendable, Hashable, Identifiable {
    case global
    case cn

    var id: String { rawValue }

    /// What a key file without a `platform` field means — the behavior of every file written before
    /// the choice existed.
    static let fallback = ZAIPlatform.global

    /// Reads a stored value, tolerating case and surrounding whitespace. An unknown or missing value
    /// reads as the global platform.
    init(configValue: String?) {
        let raw = configValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = ZAIPlatform(rawValue: raw) ?? .fallback
    }

    /// Title-case name shown in the Settings picker.
    var displayName: String {
        switch self {
        case .global: return "Global"
        case .cn: return "China"
        }
    }

    /// The host the picker shows under each option, and the one every request goes to.
    var apiHost: String {
        switch self {
        case .global: return "api.z.ai"
        case .cn: return "open.bigmodel.cn"
        }
    }

    /// Base URL for all four Z.ai endpoints.
    var apiBaseURL: URL {
        URL(string: "https://\(apiHost)")!
    }

    /// The plan/usage console the "Dashboard" quick link opens.
    var dashboardURL: String {
        switch self {
        case .global: return "https://z.ai/manage-apikey/coding-plan/personal/my-plan"
        case .cn: return "https://open.bigmodel.cn/coding-plan/personal/overview"
        }
    }

    /// The key-management console the "API Keys" quick link opens.
    var apiKeysURL: String {
        switch self {
        case .global: return "https://z.ai/manage-apikey/apikey-list"
        case .cn: return "https://open.bigmodel.cn/apikey"
        }
    }

    /// Bare host+path used inside error copy (messages read better without the scheme).
    var apiKeysLabel: String {
        switch self {
        case .global: return "z.ai/manage-apikey/apikey-list"
        case .cn: return "open.bigmodel.cn/apikey"
        }
    }

    /// Where to buy a GLM Coding Plan, named in the "no coding plan" error.
    var subscribeLabel: String {
        switch self {
        case .global: return "z.ai/subscribe"
        case .cn: return "open.bigmodel.cn/glm-coding"
        }
    }

    /// The two quick-link buttons under the Z.ai card, pointed at this platform's console.
    var links: [ProviderLink] {
        [
            ProviderLink(label: "Dashboard", url: dashboardURL),
            ProviderLink(label: "API Keys", url: apiKeysURL)
        ]
    }
}
