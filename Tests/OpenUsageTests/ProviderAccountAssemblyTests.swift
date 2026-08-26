import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    /// The fork's extra Codex cards and upstream's Claude organization cards are minted by the same
    /// pass: one reconcile covers both families, and `identityKeysByCard` carries the family keys,
    /// every extra Codex card id, and the Claude card id together. A single Claude account still
    /// renders as one card titled "Claude" while the extra Codex runtimes sit behind the default one.
    func testExtraCodexCardsAndClaudeOrganizationCardComeFromOneReconcilePass() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let home = URL(fileURLWithPath: "/Users/dev")
        let extraPath = "/Users/dev/.cli-proxy-api/codex-extra.json"
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"ORG-9","emailAddress":"dev@example.com","organizationName":"SUNSTORY"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"at-1","account_id":"acct-default"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            extraCodex: [
                CodexAccountDiscovery.ExtraCredential(
                    path: extraPath, identityKey: "acct-extra-1", label: "extra@example.com"
                )
            ],
            // No Claude Desktop material: the organization card comes from the CLI's own
            // organization-scoped identity, so this pass exercises both card models without a
            // Desktop fixture.
            desktop: ClaudeDesktopAuthStore(files: FakeFiles(), homeDirectory: { home })
        )
        let extraID = ProviderAccountID.make(family: "codex", identityKey: "acct-extra-1")

        XCTAssertEqual(assembly.claudeCards.map(\.id), ["claude"])
        XCTAssertEqual(assembly.claudeCards.map(\.displayName), ["Claude — SUNSTORY"])
        XCTAssertEqual(assembly.claudeCards.first?.organizationID, "org-9")
        XCTAssertEqual(assembly.claudeCards.first?.usesDesktopCredentials, false)
        XCTAssertEqual(assembly.extraCodexCards.map(\.id), [extraID])
        XCTAssertEqual(assembly.extraCodexCards.first?.displayName, "Codex — extra@example.com")
        XCTAssertEqual(assembly.identityKeysByCard, [
            "claude": "acct-1|org-9", "codex": "acct-default", extraID: "acct-extra-1"
        ])
        // One pass, one reconcile: three records, no duplicate cards for either family.
        XCTAssertEqual(Set(store.records.map(\.id)), ["claude", "codex", extraID])

        let ids = ProviderCatalog.make(
            extraCodexCards: assembly.extraCodexCards,
            claudeCards: assembly.claudeCards,
            claudeIdentityKeys: assembly.identityKeysByCard
        ).map(\.provider)
        XCTAssertEqual(ids.prefix(4).map(\.id), ["claude", "codex", extraID, "cursor"])
        XCTAssertEqual(ids.first?.displayName, "Claude")
    }

    /// A claude-swap slot holding the account that is currently signed in at `~/.claude` is the SAME
    /// account seen twice: it attaches as another source on that record, never as a second card.
    func testActiveClaudeSwapSlotAttachesAsASourceNotASecondCard() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let home = URL(fileURLWithPath: "/Users/dev")
        let slotPath = "/Users/dev/.claude-swap-backup/configs/.claude-config-1-dev@example.com.json"
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"ORG-9","emailAddress":"dev@example.com","organizationName":"SUNSTORY"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            claudeSwap: [
                ClaudeSwapDiscovery.ExtraCredential(
                    path: slotPath, slot: "1", identityKey: "acct-1|org-9", label: "dev@example.com"
                )
            ],
            desktop: ClaudeDesktopAuthStore(files: FakeFiles(), homeDirectory: { home })
        )

        XCTAssertTrue(assembly.claudeSwapCards.isEmpty, "the active account already has a card")
        XCTAssertEqual(store.records.count { $0.family == "claude" }, 1)
        let record = try XCTUnwrap(store.records.first { $0.family == "claude" })
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(Set(record.sources.map(\.kind)), [.defaultHome, .credentialFile])
        XCTAssertEqual(record.sources.first { $0.kind == .credentialFile }?.anchor, slotPath)
    }

    /// The fork's two extra-card models plus upstream's Claude organization card, all minted by one
    /// pass: a stashed claude-swap account becomes its own `claude@<hash>` card, sitting between the
    /// Claude family card and Codex, and every card's identity lands in `identityKeysByCard`.
    func testClaudeSwapAndCodexExtraCardsComeFromOneReconcilePass() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let home = URL(fileURLWithPath: "/Users/dev")
        let slotPath = "/Users/dev/.claude-swap-backup/configs/.claude-config-2-other@example.com.json"
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-1","organizationUuid":"ORG-9","emailAddress":"dev@example.com","organizationName":"SUNSTORY"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"at-1","account_id":"acct-default"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            extraCodex: [
                CodexAccountDiscovery.ExtraCredential(
                    path: "/Users/dev/.cli-proxy-api/codex-extra.json",
                    identityKey: "acct-extra-1", label: "extra@example.com"
                )
            ],
            claudeSwap: [
                ClaudeSwapDiscovery.ExtraCredential(
                    path: slotPath, slot: "2", identityKey: "acct-2|org-2", label: "other@example.com"
                )
            ],
            desktop: ClaudeDesktopAuthStore(files: FakeFiles(), homeDirectory: { home })
        )
        let swapID = ProviderAccountID.make(family: "claude", identityKey: "acct-2|org-2")
        let codexID = ProviderAccountID.make(family: "codex", identityKey: "acct-extra-1")

        XCTAssertEqual(assembly.claudeSwapCards, [
            ClaudeSwapCard(
                id: swapID, identityKey: "acct-2|org-2",
                displayName: "Claude — other@example.com", configPath: slotPath, slot: "2"
            )
        ])
        XCTAssertEqual(assembly.claudeSwapCards.first?.organizationID, "org-2")
        XCTAssertEqual(assembly.claudeCards.map(\.id), ["claude"])
        XCTAssertEqual(assembly.extraCodexCards.map(\.id), [codexID])
        XCTAssertEqual(assembly.identityKeysByCard, [
            "claude": "acct-1|org-9", swapID: "acct-2|org-2",
            "codex": "acct-default", codexID: "acct-extra-1",
        ])
        // One pass, one reconcile: four records, no duplicate card for any account.
        XCTAssertEqual(Set(store.records.map(\.id)), ["claude", swapID, "codex", codexID])
        // A second Claude account exists, so unattributed pi sessions can no longer be assumed to
        // belong to the default card.
        XCTAssertEqual(assembly.claudeCards.first?.allowsUnattributedPiUsage, false)

        let ids = ProviderCatalog.make(
            extraCodexCards: assembly.extraCodexCards,
            claudeCards: assembly.claudeCards,
            claudeSwapCards: assembly.claudeSwapCards,
            claudeIdentityKeys: assembly.identityKeysByCard
        ).map(\.provider.id)
        XCTAssertEqual(Array(ids.prefix(5)), ["claude", swapID, "codex", codexID, "cursor"])
    }

    /// claude-swap's stash sits at a fixed path, so a launch that skips the Claude family for a cold
    /// login shell still mints its cards — and a stashed account never steals the bare `claude` id
    /// from the default-home card that may resolve on the next launch.
    func testClaudeSwapCardsMintWhenTheClaudeFamilyIsSkipped() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let home = URL(fileURLWithPath: "/Users/dev")
        let slotPath = "/Users/dev/.claude-swap-backup/configs/.claude-config-2-other@example.com.json"
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: FakeFiles([:]),
            keychain: FakeKeychain(nil), homeDirectory: { home }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: [],
            claudeSwap: [
                ClaudeSwapDiscovery.ExtraCredential(
                    path: slotPath, slot: "2", identityKey: "acct-2|org-2", label: "other@example.com"
                )
            ]
        )
        let swapID = ProviderAccountID.make(family: "claude", identityKey: "acct-2|org-2")

        XCTAssertEqual(assembly.claudeSwapCards.map(\.id), [swapID])
        XCTAssertEqual(store.records.map(\.id), [swapID])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "a stashed account never takes the default badge")
    }

    /// `cswap switch` moves an account between `~/.claude` and the stash. The account that occupied
    /// the default home when the registry was first written keeps the bare `claude` record id forever,
    /// so a second launch that finds it stashed must still give it a card — under that same bare id,
    /// which is free precisely because the new default-home account took a hashed one.
    func testAccountThatOwnsTheBareIDKeepsACardOnceItIsStashed() throws {
        let defaults = makeScratchDefaults()
        let home = URL(fileURLWithPath: "/Users/dev")
        let pathA = "/Users/dev/.claude-swap-backup/configs/.claude-config-1-a@example.com.json"
        let pathB = "/Users/dev/.claude-swap-backup/configs/.claude-config-2-b@example.com.json"
        let identityA = "acct-a|org-a"
        let identityB = "acct-b|org-b"
        let slotA = ClaudeSwapDiscovery.ExtraCredential(
            path: pathA, slot: "1", identityKey: identityA, label: "a@example.com"
        )
        let slotB = ClaudeSwapDiscovery.ExtraCredential(
            path: pathB, slot: "2", identityKey: identityB, label: "b@example.com"
        )
        func launch(active: String) -> ProviderAccountAssembly {
            let observer = DefaultAccountObserver(
                environment: FakeEnvironment([:]),
                files: FakeFiles([
                    "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-\#(active)","organizationUuid":"ORG-\#(active)","emailAddress":"\#(active.lowercased())@example.com","organizationName":"Org \#(active)"}}"#,
                ]),
                keychain: FakeKeychain(nil),
                homeDirectory: { home }
            )
            // Both accounts stay in the stash; only which one `~/.claude` holds changes.
            return ProviderAccountAssembly.make(
                observer: observer,
                accountsStore: ProviderAccountsStore(defaults: defaults),
                claudeSwap: [slotA, slotB],
                desktop: ClaudeDesktopAuthStore(files: FakeFiles(), homeDirectory: { home })
            )
        }

        // Launch 1: A is signed in, so A takes the bare id and B is the stashed card.
        let first = launch(active: "A")
        let hashedB = ProviderAccountID.make(family: "claude", identityKey: identityB)
        XCTAssertEqual(first.claudeCards.map(\.id), ["claude"])
        XCTAssertEqual(first.claudeSwapCards.map(\.id), [hashedB])
        XCTAssertEqual(first.identityKeysByCard["claude"], identityA)
        XCTAssertEqual(first.identityKeysByCard[hashedB], identityB)

        // Launch 2: after `cswap switch`, B holds the default home and A is stashed. A keeps the bare
        // record id it was minted with, and must still get a card.
        let second = launch(active: "B")
        XCTAssertEqual(second.claudeCards.map(\.id), [hashedB], "B's record id never moves")
        XCTAssertEqual(second.claudeSwapCards.map(\.id), ["claude"])
        XCTAssertEqual(second.claudeSwapCards.map(\.configPath), [pathA])
        XCTAssertEqual(second.identityKeysByCard["claude"], identityA, "the bare card now points at A")
        XCTAssertEqual(second.identityKeysByCard[hashedB], identityB)

        // Two Claude cards on both launches, and the catalog emits exactly those two runtimes.
        for assembly in [first, second] {
            XCTAssertEqual(assembly.claudeCards.count + assembly.claudeSwapCards.count, 2)
            let ids = ProviderCatalog.make(
                defaults: defaults,
                claudeCards: assembly.claudeCards,
                claudeSwapCards: assembly.claudeSwapCards,
                claudeIdentityKeys: assembly.identityKeysByCard
            ).map(\.provider.id)
            XCTAssertEqual(ids.count { ProviderAccountID.family(of: $0) == "claude" }, 2)
            XCTAssertEqual(Set(ids).count, ids.count, "no duplicate card ids")
        }
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }
}
