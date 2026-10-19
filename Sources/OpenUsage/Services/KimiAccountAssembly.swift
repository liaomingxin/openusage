import Foundation

extension ProviderAccountAssembly {
    /// A configured source owns a permanent card identity. Token rotation changes its credential,
    /// not its card; removing and adding a source creates a new identity and cannot reuse its cache.
    func includingKimiAccounts(_ accounts: [KimiAccountConfiguration]) -> ProviderAccountAssembly {
        var identities = identityKeysByCard
        for account in accounts {
            identities[account.cardID] = "kimi-config:\(account.id.uuidString.lowercased())"
        }
        return ProviderAccountAssembly(
            identityKeysByCard: identities,
            extraCodexCards: extraCodexCards,
            claudeCards: claudeCards,
            claudeSwapCards: claudeSwapCards,
            kimiAccounts: accounts,
            ompAccounts: ompAccounts,
            defaultAccountLabels: defaultAccountLabels
        )
    }
}
