import XCTest
@testable import OpenUsage

/// Multi-account card titles: the dashboard header shows the family name alone ("Codex", "Claude")
/// and moves the account — a ChatGPT email, a Claude organization — into the title's hover tooltip,
/// so a long email can't truncate the title or crowd the plan badge. `Provider.displayName` keeps the
/// full "Codex — extra@example.com" form for every place the name stands on its own (menus, the
/// Customize title, Total Spend, the menu bar, share cards, the local API).
@MainActor
final class ProviderCardTitleTests: XCTestCase {
    func testSingleAccountProviderIsJustItsFamilyName() {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

        XCTAssertEqual(provider.familyName, "Cursor")
        XCTAssertNil(provider.accountLabel)
        XCTAssertEqual(provider.displayName, "Cursor")
    }

    func testAccountCardFoldsItsLabelIntoDisplayNameOnly() {
        let provider = Provider(
            id: "codex@ab12cd34", familyName: "Codex", accountLabel: "extra@example.com",
            icon: .providerMark("codex")
        )

        XCTAssertEqual(provider.familyName, "Codex")
        XCTAssertEqual(provider.accountLabel, "extra@example.com")
        XCTAssertEqual(provider.displayName, "Codex — extra@example.com")
    }

    /// The owner's case: an extra Codex card with a long email and a plan badge. The title is the bare
    /// family name and the email is the title's tooltip.
    func testHeaderTitleIsFamilyNameAndTooltipIsAccountLabel() {
        let extra = CodexProvider(
            id: "codex@ab12cd34", accountLabel: "dellabiddle1@example.com", scansLocalLogs: false
        ).provider
        let header = ProviderSectionHeader(provider: extra, plan: "Pro 20x")

        XCTAssertEqual(header.title, "Codex")
        XCTAssertFalse(header.title.contains("dellabiddle1@example.com"))
        XCTAssertEqual(header.titleTooltip, "dellabiddle1@example.com")
    }

    func testHeaderOfSingleAccountCardHasNoTitleTooltip() {
        let header = ProviderSectionHeader(provider: CodexProvider().provider)

        XCTAssertEqual(header.title, "Codex")
        XCTAssertNil(header.titleTooltip)
    }

    /// The catalog only labels Claude cards when there is more than one: a lone card is plain "Claude"
    /// with nothing to hover, two cards are both titled "Claude" and told apart by organization.
    func testCatalogLabelsClaudeCardsOnlyWhenMoreThanOne() throws {
        let work = ClaudeAccountCard(
            id: "claude", identityKey: "acct|org-1", organizationID: "org-1", accountLabel: "SUNSTORY",
            usesDesktopCredentials: false, allowsUnattributedPiUsage: false
        )
        let personal = ClaudeAccountCard(
            id: "claude@ab12cd34", identityKey: "acct|org-2", organizationID: "org-2", accountLabel: "Personal",
            usesDesktopCredentials: true, allowsUnattributedPiUsage: false
        )

        let lone = try XCTUnwrap(ProviderCatalog.make(claudeCards: [work]).first?.provider)
        XCTAssertEqual(lone.familyName, "Claude")
        XCTAssertNil(lone.accountLabel)
        XCTAssertEqual(lone.displayName, "Claude")

        let both = ProviderCatalog.make(claudeCards: [work, personal]).prefix(2).map(\.provider)
        XCTAssertEqual(both.map(\.familyName), ["Claude", "Claude"])
        XCTAssertEqual(both.map(\.accountLabel), ["SUNSTORY", "Personal"])
        XCTAssertEqual(both.map(\.displayName), ["Claude — SUNSTORY", "Claude — Personal"])
    }

    func testExtraCodexCardLabelIsTheEmailOrTheIDSuffix() {
        XCTAssertEqual(
            ProviderAccountAssembly.codexAccountLabel(label: "extra@example.com", id: "codex@ab12cd34"),
            "extra@example.com"
        )
        XCTAssertEqual(ProviderAccountAssembly.codexAccountLabel(label: nil, id: "codex@ab12cd34"), "ab12cd34")
        XCTAssertEqual(ProviderAccountAssembly.codexAccountLabel(label: "", id: "codex@ab12cd34"), "ab12cd34")
    }
}
