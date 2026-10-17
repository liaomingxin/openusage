import Foundation

extension ProviderAccountAssembly {
    /// Keep native sources as the default cards, and add only identities not already represented.
    /// Each OMP card stores a row identity, never a copied token, so later reads see OMP's rotations.
    func includingOMPAccounts(
        store: OMPOAuthStore = OMPOAuthStore(),
        cursorAuthStore: CursorAuthStore = CursorAuthStore(),
        grokAuthStore: GrokAuthStore = GrokAuthStore()
    ) -> ProviderAccountAssembly {
        var identities = identityKeysByCard
        let cursorIdentity = cursorAuthStore.loadAuthState()?.accessToken.flatMap {
            OMPOAuthStore.accountID(providerKey: "cursor", token: $0)
        }
        let grokIdentities = Set(((try? grokAuthStore.loadAuthCandidates()) ?? []).compactMap { state in
            OMPOAuthStore.accountID(providerKey: "xai-oauth", token: state.token)
                ?? state.entry.idToken.flatMap { OMPOAuthStore.accountID(providerKey: "xai-oauth", token: $0) }
        })
        if let cursorIdentity { identities["cursor"] = "cursor:\(cursorIdentity)" }
        if grokIdentities.count == 1, let identity = grokIdentities.first {
            identities["grok"] = "grok:\(identity)"
        }

        let discovered: [OMPOAuthAccount]
        do {
            discovered = try store.accounts()
        } catch {
            AppLog.error(.auth, "OMP account discovery failed; native provider logins remain available")
            discovered = []
        }
        let extra = discovered.filter { account in
            if account.family == "cursor" { return account.accountID != cursorIdentity }
            return !grokIdentities.contains(account.accountID)
        }
        for account in extra {
            identities[account.cardID] = "\(account.family):\(account.accountID)"
        }
        return ProviderAccountAssembly(
            identityKeysByCard: identities,
            extraCodexCards: extraCodexCards,
            claudeCards: claudeCards,
            claudeSwapCards: claudeSwapCards,
            kimiAccounts: kimiAccounts,
            ompAccounts: extra
        )
    }
}
