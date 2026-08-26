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
        XCTAssertEqual(assembly.claudeCards.map(\.accountLabel), ["SUNSTORY"])
        XCTAssertEqual(assembly.claudeCards.first?.organizationID, "org-9")
        XCTAssertEqual(assembly.claudeCards.first?.usesDesktopCredentials, false)
        XCTAssertEqual(assembly.extraCodexCards.map(\.id), [extraID])
        XCTAssertEqual(assembly.extraCodexCards.first?.accountLabel, "extra@example.com")
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
        // The lone Claude card carries no account label; the extra Codex card keeps the family name
        // as its title and the email as its label, folded into the full display name.
        XCTAssertEqual(ids.first?.displayName, "Claude")
        XCTAssertNil(ids.first?.accountLabel)
        XCTAssertEqual(ids[2].familyName, "Codex")
        XCTAssertEqual(ids[2].accountLabel, "extra@example.com")
        XCTAssertEqual(ids[2].displayName, "Codex — extra@example.com")
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
