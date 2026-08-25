import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        extraCodexCards: [CodexExtraCard] = []
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Extra Codex cards sit immediately
        // after the default Codex card so a family stays grouped.
        [ClaudeProvider(), CodexProvider()]
            + extraCodexCards.map { card in
                CodexProvider(
                    id: card.id,
                    displayName: card.displayName,
                    authStore: CodexAuthStore(scopedAuthPath: card.credentialPath),
                    scansLocalLogs: false
                )
            }
            + [
                CursorProvider(),
                AntigravityProvider(),
                CopilotProvider(defaults: defaults),
                DevinProvider(),
                GrokProvider(),
                KimiProvider(),
                OpenCodeProvider(),
                OpenRouterProvider(),
                ZAIProvider()
            ]
    }
}
