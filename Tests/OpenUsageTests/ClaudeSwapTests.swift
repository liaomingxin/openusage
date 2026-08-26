import XCTest
@testable import OpenUsage

/// Fixtures shaped like claude-swap's real stash: a full `~/.claude.json` snapshot per slot under
/// `~/.claude-swap-backup/configs`, and the `schemaVersion: 2` usage table under `cache/usage.json`.
enum ClaudeSwapFixtures {
    static let home = URL(fileURLWithPath: "/Users/dev")
    static let configsDirectory = "/Users/dev/.claude-swap-backup/configs"
    static let usageCachePath = "/Users/dev/.claude-swap-backup/cache/usage.json"

    static func configPath(slot: String, email: String) -> String {
        "\(configsDirectory)/.claude-config-\(slot)-\(email).json"
    }

    /// The snapshot claude-swap stashes: the whole Claude Code config, of which only `oauthAccount`
    /// matters here. The sibling keys are kept so the fixture exercises decoding a real-shaped file.
    static func config(
        accountUUID: String,
        organizationUUID: String?,
        email: String,
        organizationName: String = "Test Org"
    ) -> String {
        let organization = organizationUUID.map {
            #""organizationUuid":"\#($0)","organizationName":"\#(organizationName)","#
        } ?? ""
        return """
            {"numStartups":42,"installMethod":"native","oauthAccount":{\
            "accountUuid":"\(accountUUID)",\(organization)"emailAddress":"\(email)"},\
            "projects":{}}
            """
    }

    static func usageCache(_ accounts: String) -> String {
        #"{"schemaVersion":2,"accounts":{\#(accounts)}}"#
    }
}

final class ClaudeSwapDiscoveryTests: XCTestCase {
    private func discovery(files: [String: String]) -> ClaudeSwapDiscovery {
        ClaudeSwapDiscovery(files: FakeFiles(files), homeDirectory: { ClaudeSwapFixtures.home })
    }

    func testParsesEverySlotInNumericOrder() {
        let slotOne = ClaudeSwapFixtures.configPath(slot: "1", email: "one@example.com")
        let slotTwo = ClaudeSwapFixtures.configPath(slot: "2", email: "two@example.com")
        let slotTen = ClaudeSwapFixtures.configPath(slot: "10", email: "ten@example.com")

        let slots = discovery(files: [
            slotOne: ClaudeSwapFixtures.config(
                accountUUID: "ACCT-1", organizationUUID: "ORG-1", email: "one@example.com"
            ),
            slotTwo: ClaudeSwapFixtures.config(
                accountUUID: "ACCT-2", organizationUUID: "ORG-2", email: "two@example.com"
            ),
            slotTen: ClaudeSwapFixtures.config(
                accountUUID: "ACCT-10", organizationUUID: "ORG-10", email: "ten@example.com"
            ),
        ]).extraCredentials()

        XCTAssertEqual(slots, [
            ClaudeSwapDiscovery.ExtraCredential(
                path: slotOne, slot: "1", identityKey: "acct-1|org-1", label: "one@example.com"
            ),
            ClaudeSwapDiscovery.ExtraCredential(
                path: slotTwo, slot: "2", identityKey: "acct-2|org-2", label: "two@example.com"
            ),
            // Numeric, not lexicographic: slot 10 sorts after slot 2.
            ClaudeSwapDiscovery.ExtraCredential(
                path: slotTen, slot: "10", identityKey: "acct-10|org-10", label: "ten@example.com"
            ),
        ])
    }

    /// The identity a stashed slot reports must be byte-identical to the one the default-home observer
    /// produces for the same account — otherwise the active account would mint a second card the
    /// moment `cswap switch` moved it into `~/.claude`.
    func testIdentityMatchesTheDefaultHomeObserverForTheSameAccount() throws {
        let path = ClaudeSwapFixtures.configPath(slot: "3", email: "same@example.com")
        let snapshot = ClaudeSwapFixtures.config(
            accountUUID: "ACCT-Same", organizationUUID: "ORG-Same", email: "same@example.com"
        )
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            // The very same JSON, read from the default home this time.
            files: FakeFiles(["/Users/dev/.claude.json": snapshot]),
            keychain: FakeKeychain(nil),
            homeDirectory: { ClaudeSwapFixtures.home }
        )

        let slot = try XCTUnwrap(discovery(files: [path: snapshot]).extraCredentials().first)
        guard case .resolved(let identityKey, _, _) = observer.observeClaude() else {
            return XCTFail("the default-home observer did not resolve the fixture")
        }

        XCTAssertEqual(slot.identityKey, identityKey)
        XCTAssertEqual(slot.identityKey, "acct-same|org-same")
    }

    func testSkipsMalformedUnnamedAndForeignFiles() {
        let good = ClaudeSwapFixtures.configPath(slot: "1", email: "good@example.com")
        let slots = discovery(files: [
            good: ClaudeSwapFixtures.config(
                accountUUID: "ACCT-1", organizationUUID: "ORG-1", email: "good@example.com"
            ),
            // Truncated JSON — claude-swap interrupted mid-write.
            ClaudeSwapFixtures.configPath(slot: "2", email: "broken@example.com"): #"{"oauthAccount":"#,
            // Valid JSON that names no account.
            ClaudeSwapFixtures.configPath(slot: "3", email: "empty@example.com"): #"{"projects":{}}"#,
            // An account object without the account UUID can't be attributed.
            ClaudeSwapFixtures.configPath(slot: "4", email: "partial@example.com"):
                #"{"oauthAccount":{"emailAddress":"partial@example.com"}}"#,
            // Not one of claude-swap's slot files.
            "\(ClaudeSwapFixtures.configsDirectory)/notes.json": #"{"oauthAccount":{"accountUuid":"X"}}"#,
        ]).extraCredentials()

        XCTAssertEqual(slots.map(\.slot), ["1"])
        XCTAssertEqual(slots.map(\.path), [good])
    }

    func testLegacySnapshotWithoutAnOrganizationStillNamesItsAccount() throws {
        let path = ClaudeSwapFixtures.configPath(slot: "7", email: "legacy@example.com")
        let slot = try XCTUnwrap(discovery(files: [
            path: ClaudeSwapFixtures.config(
                accountUUID: "ACCT-Legacy", organizationUUID: nil, email: "legacy@example.com"
            )
        ]).extraCredentials().first)

        XCTAssertEqual(slot.identityKey, "acct-legacy")
        XCTAssertEqual(slot.slot, "7")
    }

    func testNoStashYieldsNoSlots() {
        XCTAssertTrue(discovery(files: [:]).extraCredentials().isEmpty)
    }
}

/// Destructures a bounded meter the way every other provider's mapper tests do.
private func progress(
    _ lines: [MetricLine], _ label: String
) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) =
        lines.first(where: { $0.label == label })
    else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

final class ClaudeSwapUsageMapperTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-08-26T16:34:20.000Z")!

    private func client(_ cache: String?) -> ClaudeSwapUsageClient {
        ClaudeSwapUsageClient(
            files: FakeFiles(cache.map { [ClaudeSwapFixtures.usageCachePath: $0] } ?? [:]),
            homeDirectory: { ClaudeSwapFixtures.home }
        )
    }

    /// The row claude-swap writes after a good poll: 5h/7d percentages plus the per-model weekly
    /// windows it surfaces under `scoped`.
    private func healthyRow(fetchedAt: Double, lastError: String? = nil) -> String {
        """
        "1":{"email":"one@example.com","organizationUuid":"882cf738-5e37-45ae-9890-cff59b482890",
        "consecutiveFailures":0,"lastError":\(lastError.map { "\"\($0)\"" } ?? "null"),
        "lastGood":{
          "five_hour":{"pct":12.0,"resets_at":"2026-08-26T17:49:59.560813+00:00","countdown":"1h 15m","clock":"01:49"},
          "seven_day":{"pct":49.0,"resets_at":"2026-08-27T02:59:59.560838+00:00"},
          "scoped":[{"name":"Fable","pct":83.0,"resets_at":"2026-08-27T02:59:59.561167+00:00"}]
        },
        "fetchedAt":\(fetchedAt),"nextPollAt":\(fetchedAt + 180),"pollIntervalS":180.0}
        """
    }

    private func map(
        _ cache: String?,
        slot: String = "1",
        organization: String? = "882cf738-5e37-45ae-9890-cff59b482890",
        email: String? = "one@example.com"
    ) throws -> ClaudeSwapMappedUsage {
        ClaudeSwapUsageMapper.map(
            try client(cache).entry(slot: slot),
            expectedOrganizationUUID: organization,
            expectedEmail: email,
            now: now
        )
    }

    func testMapsPercentagesResetsAndTheScopedFableWindow() throws {
        let mapped = try map(ClaudeSwapFixtures.usageCache(
            healthyRow(fetchedAt: now.timeIntervalSince1970 - 120)
        ))

        guard case .usage(let lines, let warning) = mapped else {
            return XCTFail("expected usable measurements, got \(mapped)")
        }
        XCTAssertNil(warning)
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Fable"])
        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertEqual(session.used, 12)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.periodDurationMs, MetricPeriod.sessionMs)
        XCTAssertEqual(session.resetsAt, OpenUsageISO8601.date(from: "2026-08-26T17:49:59.560813+00:00"))
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).used, 49)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).periodDurationMs, MetricPeriod.weekMs)
        // The per-model weekly window claude-swap surfaces under `scoped`, matched by display name.
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Fable")).used, 83)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Fable")).periodDurationMs, MetricPeriod.weekMs)
    }

    /// A brand-new account claude-swap has polled but that has never touched a window: percentages of
    /// zero with no `resets_at`, and no per-model window at all.
    func testUntouchedWindowsMapWithoutAFableRow() throws {
        let mapped = try map(ClaudeSwapFixtures.usageCache("""
            "1":{"email":"one@example.com","organizationUuid":"882cf738-5e37-45ae-9890-cff59b482890",
            "lastError":null,"lastGood":{"five_hour":{"pct":0.0},"seven_day":{"pct":0.0},"scoped":[]},
            "fetchedAt":\(now.timeIntervalSince1970 - 30)}
            """))

        guard case .usage(let lines, _) = mapped else {
            return XCTFail("expected usable measurements, got \(mapped)")
        }
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly"])
        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertEqual(session.used, 0)
        XCTAssertNil(session.resetsAt, "an untouched five-hour window reports no reset instant")
    }

    func testUnknownSlotAndMissingMeasurementReadAsNoData() throws {
        let missingSlot = try map(
            ClaudeSwapFixtures.usageCache(healthyRow(fetchedAt: now.timeIntervalSince1970 - 60)),
            slot: "9"
        )
        let neverPolled = try map(ClaudeSwapFixtures.usageCache("""
            "1":{"email":"one@example.com","organizationUuid":"882cf738-5e37-45ae-9890-cff59b482890",
            "lastError":null,"lastGood":null,"fetchedAt":null}
            """))
        let noCacheFile = try map(nil)

        for mapped in [missingSlot, neverPolled, noCacheFile] {
            guard case .noData = mapped else {
                return XCTFail("expected the no-data state, got \(mapped)")
            }
        }
    }

    func testMeasurementOlderThanTheFreshnessWindowReadsAsNoDataNotAStalePercent() throws {
        let stale = now.timeIntervalSince1970 - ClaudeSwapUsageMapper.freshnessWindow - 1
        let justInside = now.timeIntervalSince1970 - ClaudeSwapUsageMapper.freshnessWindow + 1

        guard case .noData = try map(ClaudeSwapFixtures.usageCache(healthyRow(fetchedAt: stale))) else {
            return XCTFail("a measurement past the freshness window must not render as a percent")
        }
        guard case .usage = try map(ClaudeSwapFixtures.usageCache(healthyRow(fetchedAt: justInside))) else {
            return XCTFail("a measurement inside the freshness window still renders")
        }
    }

    /// claude-swap keeps its last-good measurement across a failed poll, so a fresh measurement still
    /// renders — with the failure carried as the header's amber notice. Once that measurement ages
    /// out, the failure itself is what the card shows.
    func testLastErrorWarnsWhileFreshAndBecomesACategorizedErrorOnceStale() throws {
        let fresh = try map(ClaudeSwapFixtures.usageCache(
            healthyRow(fetchedAt: now.timeIntervalSince1970 - 90, lastError: "http-429")
        ))
        guard case .usage(let lines, let warning) = fresh else {
            return XCTFail("expected the last-good measurement, got \(fresh)")
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(warning, ClaudeSwapUsageMapper.warningText("http-429"))

        let stale = try map(ClaudeSwapFixtures.usageCache(healthyRow(
            fetchedAt: now.timeIntervalSince1970 - ClaudeSwapUsageMapper.freshnessWindow - 1,
            lastError: "http-429"
        )))
        guard case .failure(let error) = stale else {
            return XCTFail("expected claude-swap's failure to surface, got \(stale)")
        }
        XCTAssertEqual(error, .pollFailed("http-429"))
        XCTAssertEqual(error.errorCategory, .rateLimited)
    }

    func testEveryClaudeSwapErrorTokenLandsInAStableCategory() {
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("http-500").errorCategory, .http5xx)
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("http-403").errorCategory, .http4xx)
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("timeout").errorCategory, .network)
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("network").errorCategory, .network)
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("bad-response").errorCategory, .decoding)
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("invalid_grant").errorCategory, .authExpired)
        XCTAssertEqual(ClaudeSwapUsageError.pollFailed("KeyError").errorCategory, .other)
        XCTAssertEqual(ClaudeSwapUsageError.invalidCache.errorCategory, .decoding)
        XCTAssertEqual(ClaudeSwapUsageError.unsupportedSchema(3).errorCategory, .decoding)
        XCTAssertEqual(ClaudeSwapUsageError.cacheUnreadable("denied").errorCategory, .credentialAccess)
        // Every case must carry user-facing copy — a bare enum name is not a friendly error.
        for error: ClaudeSwapUsageError in [
            .pollFailed("http-429"), .pollFailed("boom"), .invalidCache, .cacheUnreadable("denied"),
            .unsupportedSchema(3)
        ] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    /// claude-swap keys its cache by slot number, so a re-added account can inherit a number whose
    /// stored measurement belongs to somebody else. Show nothing rather than another account's usage.
    func testRowBelongingToAnotherOrganizationReadsAsNoData() throws {
        let mapped = try map(
            ClaudeSwapFixtures.usageCache(healthyRow(fetchedAt: now.timeIntervalSince1970 - 60)),
            organization: "0a6595d2-b78c-4f2a-a1a1-da26d8958537"
        )
        guard case .noData = mapped else {
            return XCTFail("expected the no-data state, got \(mapped)")
        }
    }

    /// A legacy account names no organization, so the strong half of the fence is unavailable and the
    /// email carries it instead — otherwise a renumbered slot would render a stranger's percentages.
    func testLegacyIdentityFencesTheRowOnEmailInstead() throws {
        let cache = ClaudeSwapFixtures.usageCache("""
            "1":{"email":"someone-else@example.com","organizationUuid":null,"lastError":null,
            "lastGood":{"five_hour":{"pct":31.0},"seven_day":{"pct":44.0},"scoped":[]},
            "fetchedAt":\(now.timeIntervalSince1970 - 60)}
            """)

        let mismatch = try map(cache, organization: nil, email: "legacy@example.com")
        guard case .noData = mismatch else {
            return XCTFail("expected the no-data state, got \(mismatch)")
        }
        // The same row read by the account it actually belongs to still renders.
        let match = try map(cache, organization: nil, email: "SOMEONE-ELSE@example.com")
        guard case .usage(let lines, _) = match else {
            return XCTFail("expected usable measurements, got \(match)")
        }
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly"])
    }

    /// claude-swap stamps every table it writes. A version it wasn't written against may have renamed
    /// a key or rescaled a percent, so the reader refuses it instead of showing wrong numbers.
    func testUnsupportedAndUnstampedSchemasAreRefused() {
        let newer = client(#"{"schemaVersion":3,"accounts":{"1":{"lastGood":{"five_hour":{"pct":12.0}}}}}"#)
        XCTAssertThrowsError(try newer.entry(slot: "1")) { error in
            XCTAssertEqual(error as? ClaudeSwapUsageError, .unsupportedSchema(3))
            XCTAssertEqual((error as? ClaudeSwapUsageError)?.errorCategory, .decoding)
        }

        // claude-swap's own pre-v2 file carries no stamp at all; it treats that as empty, and so do we.
        let unstamped = client(#"{"accounts":{"1":{"lastGood":{"five_hour":{"pct":12.0}}}}}"#)
        XCTAssertThrowsError(try unstamped.entry(slot: "1")) { error in
            XCTAssertEqual(error as? ClaudeSwapUsageError, .invalidCache)
        }
    }

    func testUnreadableAndUndecodableCachesFailLoudly() {
        let unreadable = ClaudeSwapUsageClient(
            files: UnreadableFiles(present: [ClaudeSwapFixtures.usageCachePath]),
            homeDirectory: { ClaudeSwapFixtures.home }
        )
        XCTAssertThrowsError(try unreadable.entry(slot: "1")) { error in
            guard case .cacheUnreadable = error as? ClaudeSwapUsageError else {
                return XCTFail("expected a loud read failure, got \(error)")
            }
        }

        let garbage = client("not json at all")
        XCTAssertThrowsError(try garbage.entry(slot: "1")) { error in
            XCTAssertEqual(error as? ClaudeSwapUsageError, .invalidCache)
        }
    }
}

@MainActor
final class ClaudeSwapProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-08-26T16:34:20.000Z")!

    private func card(id: String = "claude@abcd1234") -> ClaudeSwapCard {
        ClaudeSwapCard(
            id: id,
            identityKey: "acct-2|0a6595d2-b78c-4f2a-a1a1-da26d8958537",
            displayName: "Claude — two@example.com",
            configPath: ClaudeSwapFixtures.configPath(slot: "2", email: "two@example.com"),
            slot: "2",
            email: "two@example.com"
        )
    }

    private func provider(files: [String: String]) -> ClaudeSwapProvider {
        let fake = FakeFiles(files)
        return ClaudeSwapProvider(
            card: card(),
            usageClient: ClaudeSwapUsageClient(files: fake, homeDirectory: { ClaudeSwapFixtures.home }),
            files: fake,
            now: { [now] in now }
        )
    }

    func testDescriptorsAreTheClaudeQuotaMetersUnderTheCardID() {
        let descriptors = provider(files: [:]).widgetDescriptors
        XCTAssertEqual(descriptors.map(\.id), [
            "claude@abcd1234.session", "claude@abcd1234.weekly", "claude@abcd1234.fable"
        ])
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
            displayName: "Claude — two@example.com",
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
            ["\(cardID).session", "\(cardID).weekly", "\(cardID).fable"]
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
