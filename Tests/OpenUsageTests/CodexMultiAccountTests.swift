import XCTest
@testable import OpenUsage

final class CodexFlattenedAuthTests: XCTestCase {
    private let flattened = """
        {
          "type": "codex",
          "access_token": "at-extra",
          "refresh_token": "rt-extra",
          "id_token": "id-extra",
          "account_id": "ACCT-EXTRA-1",
          "email": "extra@example.com",
          "disabled": false,
          "expired": "2026-09-04T15:51:40+08:00",
          "last_refresh": "2026-08-25T00:00:00Z"
        }
        """

    func testParsesFlattenedCliProxyDump() {
        let auth = CodexAuthStore.parseAuth(flattened)

        XCTAssertEqual(auth?.tokens?.accessToken, "at-extra")
        XCTAssertEqual(auth?.tokens?.refreshToken, "rt-extra")
        XCTAssertEqual(auth?.tokens?.accountID, "ACCT-EXTRA-1")
        XCTAssertEqual(CodexAuthStore.detectFormat(flattened), .flattened)
        XCTAssertEqual(
            CodexAuthStore.accountIdentity(from: auth!, emailOverride: "extra@example.com"),
            CodexAccountIdentity(identityKey: "acct-extra-1", label: "extra@example.com")
        )
    }

    func testSaveFlattenedPreservesSiblingFields() throws {
        let path = "/tmp/codex-extra.json"
        let files = FakeFiles([path: flattened])
        let store = CodexAuthStore(files: files, keychain: FakeKeychain())
        var auth = try XCTUnwrap(CodexAuthStore.parseAuth(flattened))
        auth.tokens?.accessToken = "at-rotated"
        auth.lastRefresh = "2026-08-25T12:00:00Z"

        try store.save(CodexAuthState(auth: auth, source: .file(path: path, format: .flattened)))

        let saved = try XCTUnwrap(files.files[path])
        let object = try XCTUnwrap(ProviderParse.jsonObject(Data(saved.utf8)))
        XCTAssertEqual(object["access_token"] as? String, "at-rotated")
        XCTAssertEqual(object["email"] as? String, "extra@example.com")
        XCTAssertEqual(object["type"] as? String, "codex")
        XCTAssertEqual(ProviderParse.bool(object["disabled"]), false)
        XCTAssertEqual(object["expired"] as? String, "2026-09-04T15:51:40+08:00")
    }

    func testScopedStoreIgnoresKeychain() {
        let path = "/tmp/only.json"
        let files = FakeFiles([path: #"{"tokens":{"access_token":"file-at","account_id":"acct-1"}}"#])
        let store = CodexAuthStore(
            files: files,
            keychain: FakeKeychain(#"{"tokens":{"access_token":"kc-at","account_id":"acct-kc"}}"#),
            scopedAuthPath: path
        )

        XCTAssertEqual(store.loadAuthCandidates().count, 1)
        XCTAssertEqual(store.loadAuthCandidates().first?.auth.tokens?.accessToken, "file-at")
        XCTAssertNil(store.loadKeychainAuth())
    }
}

final class CodexAccountDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func discovery(files: [String: String]) -> CodexAccountDiscovery {
        CodexAccountDiscovery(files: FakeFiles(files), homeDirectory: { [home] in home })
    }

    private func flattenedJSON(
        accountID: String = "acct-extra-1",
        email: String = "extra@example.com",
        type: String = "codex",
        disabled: Bool = false,
        accessToken: String = "at-1"
    ) -> String {
        """
        {"type":"\(type)","access_token":"\(accessToken)","account_id":"\(accountID)","email":"\(email)","disabled":\(disabled)}
        """
    }

    func testDiscoversNamedCodexDump() {
        let extras = discovery(files: [
            "/Users/dev/.cli-proxy-api/codex-aaaa-extra@example.com-pro.json": flattenedJSON(),
        ]).extraCredentials()

        XCTAssertEqual(extras, [
            CodexAccountDiscovery.ExtraCredential(
                path: "/Users/dev/.cli-proxy-api/codex-aaaa-extra@example.com-pro.json",
                identityKey: "acct-extra-1",
                label: "extra@example.com"
            )
        ])
    }

    func testSkipsDisabledAndNonCodexDumps() {
        let extras = discovery(files: [
            "/Users/dev/.cli-proxy-api/codex-on.json": flattenedJSON(),
            "/Users/dev/.cli-proxy-api/codex-off.json": flattenedJSON(accountID: "acct-off", disabled: true),
            "/Users/dev/.cli-proxy-api/claude-other.json": flattenedJSON(accountID: "acct-claude", type: "claude"),
            "/Users/dev/.cli-proxy-api/nameless.json": #"{"type":"codex","access_token":"at"}"#,
        ]).extraCredentials()

        XCTAssertEqual(extras.map(\.identityKey), ["acct-extra-1"])
    }
}

@MainActor
final class CodexExtraAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexExtra.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func observer(files: [String: String]) -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
    }

    func testDistinctExtraCredentialMintsASecondCodexCard() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let extraPath = "/Users/dev/.cli-proxy-api/codex-extra.json"
        let assembly = ProviderAccountAssembly.make(
            observer: observer(files: [
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"at-1","account_id":"acct-default"}}"#,
            ]),
            accountsStore: store,
            extraCodex: [
                CodexAccountDiscovery.ExtraCredential(
                    path: extraPath, identityKey: "acct-extra-1", label: "extra@example.com"
                )
            ]
        )

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.id, "codex")
        let extraID = ProviderAccountID.make(family: "codex", identityKey: "acct-extra-1")
        XCTAssertEqual(assembly.extraCodexCards.map(\.id), [extraID])
        XCTAssertEqual(assembly.extraCodexCards.first?.accountLabel, "extra@example.com")
        XCTAssertEqual(assembly.identityKeysByCard[extraID], "acct-extra-1")
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "acct-default")
    }

    func testExtraCardsMintWhenDefaultFamilyIsSkipped() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let extraPath = "/Users/dev/.cli-proxy-api/codex-extra.json"
        let assembly = ProviderAccountAssembly.make(
            observer: observer(files: [:]),
            accountsStore: store,
            families: [],
            extraCodex: [
                CodexAccountDiscovery.ExtraCredential(
                    path: extraPath, identityKey: "acct-extra-1", label: "extra@example.com"
                )
            ]
        )

        let extraID = ProviderAccountID.make(family: "codex", identityKey: "acct-extra-1")
        XCTAssertEqual(assembly.extraCodexCards.map(\.id), [extraID])
        XCTAssertEqual(store.records.first?.id, extraID)
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"), "a dump-only account does not take the default badge")
    }

    func testSameIdentityAttachesAsAnotherSourceNotAnotherCard() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let extraPath = "/Users/dev/.cli-proxy-api/codex-same.json"
        let assembly = ProviderAccountAssembly.make(
            observer: observer(files: [
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"at-1","account_id":"acct-same"}}"#,
            ]),
            accountsStore: store,
            extraCodex: [
                CodexAccountDiscovery.ExtraCredential(
                    path: extraPath, identityKey: "acct-same", label: "same@example.com"
                )
            ]
        )

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].id, "codex")
        XCTAssertEqual(Set(store.records[0].sources.map(\.kind)), [.defaultHome, .credentialFile])
        XCTAssertTrue(assembly.extraCodexCards.isEmpty)
    }
}

@MainActor
final class CodexExtraCardCatalogTests: XCTestCase {
    func testExtraCardUsesPrefixedMetricIDsAndSkipsLocalLogs() {
        let extra = CodexProvider(
            id: "codex@deadbeef",
            accountLabel: "extra@example.com",
            scansLocalLogs: false
        )

        XCTAssertEqual(extra.provider.id, "codex@deadbeef")
        XCTAssertEqual(extra.provider.familyName, "Codex")
        XCTAssertEqual(extra.provider.displayName, "Codex — extra@example.com")
        XCTAssertTrue(extra.widgetDescriptors.contains { $0.id == "codex@deadbeef.weekly" })
        XCTAssertFalse(extra.widgetDescriptors.contains { $0.id == "codex.weekly" })
        XCTAssertFalse(extra.scansLocalLogs)
    }

    func testCatalogInsertsExtraCardsAfterDefaultCodex() throws {
        let extraID = ProviderAccountID.make(family: "codex", identityKey: "acct-extra-1")
        let providers = ProviderCatalog.make(extraCodexCards: [
            CodexExtraCard(
                id: extraID,
                identityKey: "acct-extra-1",
                accountLabel: "extra@example.com",
                credentialPath: "/tmp/extra.json"
            )
        ])
        let ids = providers.map(\.provider.id)
        let defaultIndex = try XCTUnwrap(ids.firstIndex(of: "codex"))
        let extraIndex = try XCTUnwrap(ids.firstIndex(of: extraID))
        XCTAssertEqual(extraIndex, defaultIndex + 1)
    }
}

@MainActor
final class CodexExtraLayoutTests: XCTestCase {
    func testTranslatesFamilyDefaultsOntoExtraCard() {
        let ids = DefaultLayout.translated(
            ["codex.weekly", "codex.credits", "claude.session"],
            family: "codex",
            instanceID: "codex@abcd1234"
        )
        XCTAssertEqual(ids, ["codex@abcd1234.weekly", "codex@abcd1234.credits"])
    }

    /// Same rule as upstream's Claude account cards: a fresh install pins each extra Codex card's
    /// Session + Weekly (the per-provider cap counts per card), and that card's Reset restores
    /// exactly those two without touching the family card.
    func testExtraCardStartsWithItsOwnSessionAndWeeklyPins() {
        let extraID = "codex@abcd1234"
        let registry = WidgetRegistry.from([
            CodexProvider(),
            CodexProvider(id: extraID, accountLabel: "extra", scansLocalLogs: false)
        ])
        let store = LayoutStore(registry: registry, defaults: makeLayoutDefaults("ExtraPins"), storageKey: "layout")

        XCTAssertEqual(
            store.pinnedGroups.flatMap { $0.metrics.map(\.id) },
            ["codex.session", "codex.weekly", "\(extraID).session", "\(extraID).weekly"]
        )
        XCTAssertEqual(store.pinnedCount(forProvider: extraID), LayoutStore.maxPinsPerProvider)

        store.setPinned(false, for: "\(extraID).weekly")
        store.setPinned(false, for: "codex.weekly")
        store.resetProvider(extraID)

        XCTAssertTrue(store.isPinned("\(extraID).weekly"))
        XCTAssertFalse(store.isPinned("codex.weekly"), "resetting the extra card leaves the family card alone")
    }

    func testExtraCardDisplayFollowsFamilyEnabledMetrics() {
        let extraID = "codex@abcd1234"
        let store = makeLinkedStore("FollowFamily", extraID: extraID, placed: [
            "codex.session", "codex.weekly", "codex.trend"
        ])

        XCTAssertTrue(store.isMetricEnabled("codex.session"))
        XCTAssertTrue(store.isMetricEnabled("\(extraID).session"))
        XCTAssertTrue(store.isMetricEnabled("\(extraID).weekly"))
        XCTAssertEqual(store.isMetricEnabled("codex.spark"), store.isMetricEnabled("\(extraID).spark"))

        let extra = try! XCTUnwrap(store.displayGroups.first { $0.provider.id == extraID })
        let family = try! XCTUnwrap(store.displayGroups.first { $0.provider.id == "codex" })
        XCTAssertEqual(extra.alwaysShownWidgets.map(\.descriptorID), [
            "\(extraID).session", "\(extraID).weekly", "\(extraID).trend"
        ])
        XCTAssertEqual(
            extra.alwaysShownWidgets.map { suffix(of: $0.descriptorID) },
            family.alwaysShownWidgets.map { suffix(of: $0.descriptorID) }
        )
        XCTAssertEqual(
            extra.expandedWidgets.map { suffix(of: $0.descriptorID) },
            family.expandedWidgets.map { suffix(of: $0.descriptorID) }
        )
    }

    func testHidingMetricOnExtraCardHidesFamily() {
        let extraID = "codex@abcd1234"
        let store = makeLinkedStore("HideLinked", extraID: extraID, placed: [
            "codex.session", "codex.weekly"
        ])

        store.setMetricEnabled("\(extraID).session", false)

        XCTAssertFalse(store.isMetricEnabled("codex.session"))
        XCTAssertFalse(store.isMetricEnabled("\(extraID).session"))
        XCTAssertTrue(store.isMetricEnabled("codex.weekly"))
        XCTAssertTrue(store.isMetricEnabled("\(extraID).weekly"))
    }

    func testMetricOrderOnExtraFollowsFamily() {
        let extraID = "codex@abcd1234"
        let store = makeLinkedStore("OrderLinked", extraID: extraID, placed: [
            "codex.session", "codex.weekly"
        ])

        XCTAssertTrue(store.reorderMetric(dragged: "codex.weekly", target: "codex.session", in: "codex"))
        XCTAssertEqual(
            store.metricOrder(for: extraID).map { suffix(of: $0) },
            store.metricOrder(for: "codex").map { suffix(of: $0) }
        )
        XCTAssertEqual(Array(store.metricOrder(for: extraID).prefix(2).map { suffix(of: $0) }), [
            "weekly", "session"
        ])
    }

    private func suffix(of id: String) -> String {
        String(id.split(separator: ".").last ?? "")
    }

    private func makeLinkedStore(_ name: String, extraID: String, placed: [String]) -> LayoutStore {
        let registry = WidgetRegistry.from([
            CodexProvider(),
            CodexProvider(id: extraID, accountLabel: "extra", scansLocalLogs: false)
        ])
        let defaults = makeLayoutDefaults(name)
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced(placed.map { PlacedWidget(descriptorID: $0) })
        persistence.saveSeededDefaults(
            Set(DefaultLayout.includingInstances(DefaultLayout.metricIDs, registry: registry))
        )
        return LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
    }

    private func makeLayoutDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexExtraLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testOrderedProviderIDsInsertExtraCardAfterFamily() {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let extra = Provider(id: "codex@abcd", familyName: "Codex", accountLabel: "extra", icon: .providerMark("codex"))
        let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let registry = WidgetRegistry(providers: [claude, codex, extra, cursor], descriptors: [])

        XCTAssertEqual(
            registry.orderedProviderIDs(savedOrder: ["claude", "codex", "cursor"]),
            ["claude", "codex", "codex@abcd", "cursor"]
        )
    }
}

@MainActor
final class CodexResetClaimRouterTests: XCTestCase {
    func testUnknownCardFailsWithoutTouchingAnotherService() async {
        let router = CodexResetClaimRouter(services: [:])
        let outcome = await router.claim(
            providerID: "codex@missing",
            creditExpiringAt: Date(),
            redeemRequestID: UUID().uuidString
        )
        XCTAssertEqual(outcome, .failed)
    }
}
