import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        extraCodexCards: [CodexExtraCard] = [],
        claudeCards: [ClaudeAccountCard] = [],
        claudeSwapCards: [ClaudeSwapCard] = [],
        claudeIdentityKeys: [String: String] = [:]
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Extra account cards sit immediately
        // after their family's default card (claude-swap cards after Claude, credential dumps after
        // Codex) so a family stays grouped.
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider()]
        } else {
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage
                )
                return ClaudeProvider(
                    // A lone Claude card carries no account label: nothing to tell it apart from.
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        accountLabel: claudeCards.count == 1 ? nil : card.accountLabel
                    ),
                    authStore: ClaudeAuthStore(
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        preferOrganizationScopedDesktop: claudeCards.count > 1 && !card.usesDesktopCredentials
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        providers += claudeSwapCards.map { ClaudeSwapProvider(card: $0) }
        providers.append(CodexProvider())
        providers += extraCodexCards.map { card in
            CodexProvider(
                id: card.id,
                accountLabel: card.accountLabel,
                authStore: CodexAuthStore(scopedAuthPath: card.credentialPath),
                scansLocalLogs: false
            )
        }
        providers += [
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
        return providers
    }
}
