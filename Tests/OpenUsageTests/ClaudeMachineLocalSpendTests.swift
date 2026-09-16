import XCTest
@testable import OpenUsage

/// Fork behavior (see FORK.md): the card backed by `~/.claude` reports this Mac's local Claude spend as
/// a machine-level number. Upstream drops every session whose log carries no ownership once a second
/// Claude account is known — but Claude Code only began stamping ownership in September 2026, and a
/// bridge (remote-driven) session stamps the account driving it, so that rule empties the spend tiles
/// on a machine that has a stashed or Desktop account alongside its own login.
@MainActor
final class ClaudeMachineLocalSpendTests: XCTestCase {
    private let identity = "acct-1|org-1"

    private func assembly(withSecondAccount: Bool) throws -> ProviderAccountAssembly {
        let home = ClaudeSwapFixtures.home
        var files: [String: String] = [
            home.path + "/.claude.json": #"""
            {"oauthAccount":{"accountUuid":"acct-1","organizationUuid":"org-1",
             "emailAddress":"me@example.com","organizationName":"Personal"}}
            """#
        ]
        if withSecondAccount {
            files[ClaudeSwapFixtures.configPath(slot: "2", email: "other@example.com")] = #"""
            {"oauthAccount":{"accountUuid":"acct-2","organizationUuid":"org-2",
             "emailAddress":"other@example.com"}}
            """#
        }
        let suite = "ClaudeMachineLocal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let fakeFiles = FakeFiles(files)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: fakeFiles, keychain: FakeKeychain(),
            homeDirectory: { home }
        )
        return ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults),
            families: ["claude"],
            claudeSwap: withSecondAccount
                ? ClaudeSwapDiscovery(files: fakeFiles, homeDirectory: { home }).extraCredentials()
                : [],
            desktop: ClaudeDesktopAuthStore(files: FakeFiles(), homeDirectory: { home }),
            listDesktopOrganizationDirectories: { _ in [] }
        )
    }

    /// A stashed second account must not silence the default card's own spend tiles.
    func testDefaultHomeCardStillCountsUnownedSessionsAlongsideASecondAccount() throws {
        let assembly = try assembly(withSecondAccount: true)

        let card = try XCTUnwrap(assembly.claudeCards.first { $0.ownsDefaultHome })
        XCTAssertEqual(assembly.claudeSwapCards.count, 1, "the fixture's second account mints its own card")
        // Upstream's flag is off — several accounts are known — but the default-home card overrides it.
        XCTAssertFalse(card.allowsUnattributedPiUsage)

        let provider = try XCTUnwrap(
            ProviderCatalog.make(
                claudeCards: assembly.claudeCards,
                claudeSwapCards: assembly.claudeSwapCards,
                claudeIdentityKeys: assembly.identityKeysByCard
            ).compactMap { $0 as? ClaudeProvider }.first { $0.provider.id == card.id }
        )
        XCTAssertTrue(provider.logUsageScanner.allowsUnattributedSessions)
        XCTAssertTrue(provider.allowsUnattributedPiUsage, "pi sessions carry no ownership either")
    }

    /// The single-account case is unchanged, and the card is still the one that owns `~/.claude`.
    func testSingleAccountKeepsUpstreamBehavior() throws {
        let assembly = try assembly(withSecondAccount: false)

        XCTAssertTrue(assembly.claudeSwapCards.isEmpty)
        for card in assembly.claudeCards {
            XCTAssertTrue(card.allowsUnattributedPiUsage)
            XCTAssertTrue(card.ownsDefaultHome)
        }
    }

    /// A session stamped with an organization that has no card here — a remote/bridge session driven
    /// from another device, or a login since removed — is still this Mac's spending, so the machine-local
    /// card takes it. An organization that does have a card keeps its own sessions.
    func testMachineLocalCardTakesSessionsNoOtherCardClaims() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        func session(owner: String, account: String, id: String) -> String {
            #"{"ownerOrganizationUuid":"\#(owner)","ownerAccountUuid":"\#(account)"}"# + "\n"
                + ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 1000, output: 0, costUSD: 1,
                    messageID: id, requestID: id
                )
        }
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/mine.jsonl": session(owner: "org-1", account: "acct-1", id: "mine"),
            "workspace/bridge.jsonl": session(owner: "org-remote", account: "acct-remote", id: "bridge"),
            "workspace/other-card.jsonl": session(owner: "org-9", account: "acct-9", id: "other")
        ])

        let machineLocal = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            accountUUID: "acct-1", organizationUUID: "org-1",
            allowsUnattributedSessions: true, organizationsClaimedByOtherCards: ["org-9"]
        )
        let machineResult = await machineLocal.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(machineResult)
        // Its own session plus the unclaimed remote one; never org-9's, which has its own card.
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 2000)

        let otherCard = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            accountUUID: "acct-9", organizationUUID: "org-9"
        )
        let otherResult = await otherCard.scan(now: now, pricing: TestPricing.bundled)
        let otherScan = try XCTUnwrap(otherResult)
        XCTAssertEqual(otherScan.series.daily.first?.totalTokens, 1000, "org-9 keeps its own session")
    }

    /// The catalog tells each card which organizations the others already scan, so one session is
    /// never counted on two cards.
    func testCatalogTellsEachCardWhichOrganizationsOthersClaim() throws {
        let cards = [
            ClaudeAccountCard(
                id: "claude", identityKey: "acct-1|org-1", organizationID: "org-1",
                accountLabel: "Personal", usesDesktopCredentials: false,
                allowsUnattributedPiUsage: false, ownsDefaultHome: true
            ),
            ClaudeAccountCard(
                id: "claude@desktop", identityKey: "acct-9|org-9", organizationID: "org-9",
                accountLabel: "Work", usesDesktopCredentials: true, allowsUnattributedPiUsage: false
            )
        ]

        let claimed = ProviderCatalog.make(
            claudeCards: cards,
            claudeIdentityKeys: ["claude": "acct-1|org-1", "claude@desktop": "acct-9|org-9"]
        ).compactMap { $0 as? ClaudeProvider }.reduce(into: [String: Set<String>]()) {
            $0[$1.provider.id] = $1.logUsageScanner.organizationsClaimedByOtherCards
        }

        XCTAssertEqual(claimed, ["claude": ["org-9"], "claude@desktop": ["org-1"]])
    }

    /// Only the `~/.claude` login gets the machine-wide reading: a Desktop organization card keeps the
    /// strict rule, or two cards would each claim the same unowned sessions.
    func testDesktopOrganizationCardKeepsTheStrictOwnershipRule() throws {
        let desktopCard = ClaudeAccountCard(
            id: "claude@desktop", identityKey: "acct-9|org-9", organizationID: "org-9",
            accountLabel: "Work", usesDesktopCredentials: true, allowsUnattributedPiUsage: false
        )
        let defaultCard = ClaudeAccountCard(
            id: "claude", identityKey: identity, organizationID: "org-1",
            accountLabel: "Personal", usesDesktopCredentials: false, allowsUnattributedPiUsage: false,
            ownsDefaultHome: true
        )

        let providers = ProviderCatalog.make(
            claudeCards: [defaultCard, desktopCard],
            claudeIdentityKeys: ["claude": identity, "claude@desktop": "acct-9|org-9"]
        ).compactMap { $0 as? ClaudeProvider }

        let flags = providers.reduce(into: [String: Bool]()) {
            $0[$1.provider.id] = $1.logUsageScanner.allowsUnattributedSessions
        }
        XCTAssertEqual(flags, ["claude": true, "claude@desktop": false])
    }
}
