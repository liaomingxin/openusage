import XCTest
@testable import OpenUsage

/// Destructures a bounded meter the way every other provider's tests do.
private func progress(
    _ lines: [MetricLine], _ label: String
) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) =
        lines.first(where: { $0.label == label })
    else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

@MainActor
final class ClaudeSwapProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-08-26T16:34:20.000Z")!

    private func card(id: String = "claude@abcd1234") -> ClaudeSwapCard {
        ClaudeSwapCard(
            id: id,
            identityKey: "acct-2|0a6595d2-b78c-4f2a-a1a1-da26d8958537",
            accountLabel: "two@example.com",
            configPath: ClaudeSwapFixtures.configPath(slot: "2", email: "two@example.com"),
            slot: "2",
            email: "two@example.com"
        )
    }

    /// The cache tier on its own: an empty stash means the live tier has no token to spend, and the
    /// refusing HTTP client proves the card doesn't reach the network to find that out.
    private func provider(files: [String: String]) -> ClaudeSwapProvider {
        let fake = FakeFiles(files)
        return ClaudeSwapProvider(
            card: card(),
            usageClient: ClaudeSwapUsageClient(files: fake, homeDirectory: { ClaudeSwapFixtures.home }),
            credentialReader: ClaudeSwapCredentialReader(keychain: SlotKeychain()),
            liveUsageClient: ClaudeUsageClient(httpClient: UsageOnlyHTTPClient.refusingEverything()),
            files: fake,
            now: { [now] in now }
        )
    }

    /// Every API-derived row the active Claude card declares, in the same order — that card reads the
    /// same endpoint with the same mapper, so the rows it can produce are exactly the rows this card
    /// can produce.
    func testDescriptorsAreTheClaudeAPIMetersUnderTheCardID() {
        let descriptors = provider(files: [:]).widgetDescriptors
        XCTAssertEqual(descriptors.map(\.id), [
            "claude@abcd1234.session", "claude@abcd1234.weekly", "claude@abcd1234.fable",
            "claude@abcd1234.sonnet", "claude@abcd1234.extra"
        ])
        let claudeAPIRows = ClaudeProvider().widgetDescriptors
            .map { $0.id.dropFirst("claude.".count) }
            .filter { !["trend", "today", "yesterday", "last30"].contains(String($0)) }
        XCTAssertEqual(descriptors.map { $0.id.dropFirst("claude@abcd1234.".count) }, claudeAPIRows)
        // No local-log rows: the scanned trend and spend tiles belong to whichever account is active
        // in ~/.claude, never to a stashed one.
        XCTAssertFalse(descriptors.contains { $0.id.hasSuffix(".trend") })
    }

    func testRefreshRendersTheCachedMeasurement() async {
        let snapshot = await provider(files: [
            ClaudeSwapFixtures.usageCachePath: ClaudeSwapFixtures.usageCache("""
                "2":{"email":"two@example.com","organizationUuid":"0a6595d2-b78c-4f2a-a1a1-da26d8958537",
                "lastError":null,
                "lastGood":{"five_hour":{"pct":7.0,"resets_at":"2026-08-26T17:49:59.560813+00:00"},
                "seven_day":{"pct":21.0},"scoped":[]},
                "fetchedAt":\(now.timeIntervalSince1970 - 60)}
                """)
        ]).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.providerID, "claude@abcd1234")
        XCTAssertEqual(snapshot.displayName, "Claude — two@example.com")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(progress(snapshot.lines, "Session")?.used, 7)
        XCTAssertEqual(progress(snapshot.lines, "Weekly")?.used, 21)
    }

    func testRefreshWithoutACacheShowsTheNoDataStatus() async {
        let snapshot = await provider(files: [:]).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines, [MetricLine.noUsageData])
    }

    func testLocalCredentialProbeIsTheConfigSnapshotAlone() async {
        let present = provider(files: [
            ClaudeSwapFixtures.configPath(slot: "2", email: "two@example.com"): "{}"
        ])
        let absent = provider(files: [:])

        let hasPresent = await present.hasLocalCredentials()
        let hasAbsent = await absent.hasLocalCredentials()
        XCTAssertTrue(hasPresent)
        XCTAssertFalse(hasAbsent)
    }
}

@MainActor
final class ClaudeSwapCatalogAndLayoutTests: XCTestCase {
    private let cardID = ProviderAccountID.make(family: "claude", identityKey: "acct-2|org-2")

    private func card() -> ClaudeSwapCard {
        ClaudeSwapCard(
            id: cardID,
            identityKey: "acct-2|org-2",
            accountLabel: "two@example.com",
            configPath: ClaudeSwapFixtures.configPath(slot: "2", email: "two@example.com"),
            slot: "2",
            email: "two@example.com"
        )
    }

    func testCatalogKeepsTheClaudeFamilyTogetherAheadOfCodex() throws {
        let ids = ProviderCatalog.make(claudeSwapCards: [card()]).map(\.provider.id)

        XCTAssertEqual(Array(ids.prefix(4)), ["claude", cardID, "codex", "cursor"])
    }

    func testCatalogIsUnchangedWithoutAStash() {
        XCTAssertEqual(
            ProviderCatalog.make().map(\.provider.id),
            ProviderCatalog.make(claudeSwapCards: []).map(\.provider.id)
        )
        XCTAssertFalse(ProviderCatalog.make().contains { $0.provider.id.hasPrefix("claude@") })
    }

    /// No new `DefaultLayout` entries: the card is a `claude@<hash>` instance, so the family's default
    /// rows and pins translate onto it and the registry drops the rows it has no descriptor for.
    func testCardInheritsTheClaudeRowsItHasAndItsOwnSessionAndWeeklyPins() throws {
        let registry = WidgetRegistry.from([ClaudeProvider(), ClaudeSwapProvider(card: card())])
        let store = LayoutStore(
            registry: registry, defaults: makeLayoutDefaults("SwapPins"), storageKey: "layout"
        )

        let group = try XCTUnwrap(store.displayGroups.first { $0.provider.id == cardID })
        XCTAssertEqual(
            group.alwaysShownWidgets.map(\.descriptorID) + group.expandedWidgets.map(\.descriptorID),
            ["\(cardID).session", "\(cardID).weekly", "\(cardID).fable", "\(cardID).extra"]
        )
        XCTAssertEqual(
            store.pinnedGroups.flatMap { $0.metrics.map(\.id) },
            ["claude.session", "claude.weekly", "\(cardID).session", "\(cardID).weekly"]
        )
        XCTAssertEqual(store.pinnedCount(forProvider: cardID), LayoutStore.maxPinsPerProvider)
    }

    private func makeLayoutDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.ClaudeSwapLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
