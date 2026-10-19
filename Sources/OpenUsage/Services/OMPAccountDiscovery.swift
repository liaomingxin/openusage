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
        var defaultLabels = defaultAccountLabels
        defaultLabels["muse"] = MuseAuthStore().defaultAccountLabel()
        defaultLabels["opencode"] = OpenCodeAuthStore().defaultAccountLabel()
        defaultLabels["kimi"] = KimiAuthStore().defaultAccountLabel()
        defaultLabels["zai"] = ZAIProvider.defaultAccountLabel()
        let files = LocalTextFileAccessor()
        for path in files.jsonFilePaths(in: "~/.cli-proxy-api")
            where (path as NSString).lastPathComponent.hasPrefix("antigravity-") {
            guard let text = try? files.readTextIfPresent(path),
                  let object = ProviderParse.jsonObject(Data(text.utf8)),
                  let email = (object["email"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }
            defaultLabels["antigravity"] = email
            break
        }
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
        if let cursorIdentity,
           let matched = discovered.first(where: {
               $0.family == "cursor" && $0.accountID == cursorIdentity
           })?.email?.nilIfEmpty {
            defaultLabels["cursor"] = matched
        } else if let fallback = cursorAuthStore.defaultAccountLabel() {
            defaultLabels["cursor"] = fallback
        }
        if let matched = discovered.first(where: {
            $0.family == "grok" && grokIdentities.contains($0.accountID)
        })?.email?.nilIfEmpty {
            defaultLabels["grok"] = matched
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
            ompAccounts: extra,
            defaultAccountLabels: defaultLabels
        )
    }
}
