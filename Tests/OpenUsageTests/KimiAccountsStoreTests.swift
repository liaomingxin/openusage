import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class KimiAccountsStoreTests: XCTestCase {
    private let settingsPath = "/test/kimi-accounts.json"
    private let credentialsDirectory = "/test/kimi-credentials"

    private func store(files: any TextFileAccessing) -> KimiAccountsStore {
        KimiAccountsStore(
            files: files,
            configurationPath: settingsPath,
            credentialsDirectory: credentialsDirectory
        )
    }

    private func metadata(_ accounts: [KimiAccountConfiguration]) throws -> String {
        String(decoding: try JSONEncoder().encode(accounts), as: UTF8.self)
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.KimiAccounts.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testMissingConfigurationStartsEmptyWithoutWriting() {
        let files = FakeFiles()
        let accounts = store(files: files)

        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertNil(accounts.loadError)
        XCTAssertTrue(files.files.isEmpty)
    }

    func testAPIKeyMetadataPersistsAndReloadsWithoutSecrets() throws {
        let files = FakeFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(label: "  Work  ", key: "  fixture-api-key\n", region: " GLOBAL ")
        try accounts.addAPIKey(label: "Personal", key: "fixture-personal-key", region: "cn")

        let reloaded = store(files: files)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.accounts, accounts.accounts)
        XCTAssertEqual(reloaded.accounts.map(\.label), ["Work", "Personal"])
        XCTAssertEqual(reloaded.accounts.map(\.region), ["global", "cn"])
        for (account, key) in zip(reloaded.accounts, ["fixture-api-key", "fixture-personal-key"]) {
            XCTAssertEqual(account.credentialPath, credentialsDirectory + "/\(account.id.uuidString).json")
            XCTAssertEqual(UserAPIKeyStore.keyFromConfigText(try files.readText(account.credentialPath)), key)
        }
        let savedMetadata = try files.readText(settingsPath)
        XCTAssertFalse(savedMetadata.contains("fixture-api-key"))
        XCTAssertFalse(savedMetadata.contains("fixture-personal-key"))
        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(savedMetadata.utf8)) as? [[String: Any]]
        )
        for object in objects {
            XCTAssertEqual(Set(object.keys), ["id", "label", "credentialPath", "region"])
        }
    }

    func testOmittedAndBlankLabelsGenerateUnusedAccountNames() throws {
        let files = FakeFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(label: "Account 2", key: "fixture-named-key", region: "cn")
        try accounts.addAPIKey(key: "fixture-unnamed-key", region: "cn")
        try accounts.addAPIKey(label: " \n\t", key: "fixture-blank-label-key", region: "global")

        XCTAssertEqual(accounts.accounts.map(\.label), ["Account 2", "Account 1", "Account 3"])
        XCTAssertEqual(store(files: files).accounts, accounts.accounts)
    }

    func testGeneratedLabelsReuseUnusedNumbersAfterRemovalAndReload() throws {
        let files = FakeFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(key: "fixture-first-unnamed-key", region: "cn")
        try accounts.addAPIKey(key: "fixture-second-unnamed-key", region: "cn")
        try accounts.remove(id: XCTUnwrap(accounts.accounts.first?.id))

        let reloaded = store(files: files)
        try reloaded.addAPIKey(key: "fixture-replacement-key", region: "cn")

        XCTAssertEqual(reloaded.accounts.map(\.label), ["Account 2", "Account 1"])
    }

    func testAPIKeyFileIsJSONWithOwnerOnlyPermissions() throws {
        let directory = try scratchDirectory()
        let settings = directory.appendingPathComponent("accounts.json").path
        let accounts = KimiAccountsStore(
            configurationPath: settings,
            credentialsDirectory: directory.appendingPathComponent("credentials").path
        )
        try accounts.addAPIKey(label: "Private", key: "fixture-private-key", region: "cn")

        let account = try XCTUnwrap(accounts.accounts.first)
        let text = try LocalTextFileAccessor().readText(account.credentialPath)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(object, ["apiKey": "fixture-private-key"])
        for path in [settings, account.credentialPath] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
            XCTAssertEqual(mode, 0o600)
        }
    }

    func testDistinctKeysKeepDistinctStableCardIDsEvenWithTheSameLabel() throws {
        let files = FakeFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(label: "Account", key: "fixture-key-one", region: "cn")
        try accounts.addAPIKey(label: "Account", key: "fixture-key-two", region: "global")

        let first = accounts.accounts[0]
        let second = accounts.accounts[1]
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.cardID, second.cardID)
        XCTAssertNotEqual(first.credentialPath, second.credentialPath)
        XCTAssertTrue(first.cardID.hasPrefix("kimi@"))
        XCTAssertEqual(first.cardID, ProviderAccountID.make(family: "kimi", identityKey: first.id.uuidString))
        XCTAssertEqual(store(files: files).accounts.map(\.cardID), [first.cardID, second.cardID])

        try accounts.remove(id: first.id)
        XCTAssertFalse(files.exists(first.credentialPath))
        XCTAssertEqual(UserAPIKeyStore.keyFromConfigText(try files.readText(second.credentialPath)), "fixture-key-two")
        XCTAssertEqual(store(files: files).accounts, [second])
    }

    func testRemovalNeverDeletesAnUnmanagedKeyPath() throws {
        let id = UUID()
        let externalPath = "/test/external/\(id.uuidString).json"
        let account = KimiAccountConfiguration(
            id: id, label: "External",
            credentialPath: externalPath, region: "cn"
        )
        let files = FakeFiles([
            settingsPath: try metadata([account]),
            externalPath: #"{"apiKey":"fixture-external-key"}"#
        ])
        let accounts = store(files: files)

        try accounts.remove(id: id)

        XCTAssertTrue(files.exists(externalPath))
        XCTAssertTrue(accounts.accounts.isEmpty)
    }

    func testOnlyTheMatchingManagedUUIDFileMayBeDeleted() throws {
        let account = KimiAccountConfiguration(
            id: UUID(), label: "Manual",
            credentialPath: credentialsDirectory + "/not-owned-by-this-account.json", region: "cn"
        )
        let files = FakeFiles([
            settingsPath: try metadata([account]),
            account.credentialPath: #"{"apiKey":"fixture-manual-key"}"#
        ])

        try store(files: files).remove(id: account.id)

        XCTAssertTrue(files.exists(account.credentialPath))
    }

    func testDuplicateAPIKeyIsRejectedAfterReloadWithoutLeakingIt() throws {
        let files = FakeFiles()
        try store(files: files).addAPIKey(label: "First", key: "fixture-duplicate-key", region: "cn")
        let original = files.files
        let accounts = store(files: files)

        XCTAssertThrowsError(try accounts.addAPIKey(label: "Second", key: " fixture-duplicate-key\n", region: "global")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .duplicateKey)
            XCTAssertFalse(error.localizedDescription.contains("fixture-duplicate-key"))
        }
        XCTAssertEqual(files.files, original)
        XCTAssertEqual(accounts.accounts.count, 1)
    }

    func testInvalidInputsAreRejectedWithoutWriting() {
        let files = FakeFiles()
        let accounts = store(files: files)
        XCTAssertThrowsError(try accounts.addAPIKey(key: " \n", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .missingKey)
        }
        XCTAssertThrowsError(try accounts.addAPIKey(key: "fixture-key", region: "invalid")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .invalidRegion)
        }
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertTrue(files.files.isEmpty)
    }

    func testCorruptConfigurationBlocksAllMutationsAndPreservesOriginalBytes() throws {
        let corrupt = #"{"accidental_token":"fixture-secret",broken"#
        let files = FakeFiles([settingsPath: corrupt])
        let accounts = store(files: files)
        XCTAssertNotNil(accounts.loadError)
        XCTAssertFalse(try XCTUnwrap(accounts.loadError).contains("fixture-secret"))

        XCTAssertThrowsError(try accounts.addAPIKey(label: "Key", key: "fixture-key", region: "cn"))
        XCTAssertThrowsError(try accounts.remove(id: UUID()))

        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertEqual(files.files, [settingsPath: corrupt])
    }

    func testSemanticallyInvalidConfigurationIsPreserved() throws {
        let account = KimiAccountConfiguration(
            id: UUID(), label: "Account", credentialPath: credentialsDirectory + "/invalid.json", region: "unknown"
        )
        let invalidRegion = try metadata([account])
        var valid = account
        valid.region = "cn"
        var emptyLabel = valid
        emptyLabel.label = " \n"
        var emptyPath = valid
        emptyPath.credentialPath = " \n"
        let duplicatePath = KimiAccountConfiguration(
            id: UUID(), label: "Another", credentialPath: valid.credentialPath, region: "cn"
        )
        let duplicates = try metadata([valid, valid])
        let invalidConfigurations = [
            "{}",
            invalidRegion,
            duplicates,
            try metadata([emptyLabel]),
            try metadata([emptyPath]),
            try metadata([valid, duplicatePath])
        ]
        for text in invalidConfigurations {
            let files = FakeFiles([settingsPath: text])
            let accounts = store(files: files)
            XCTAssertNotNil(accounts.loadError)
            XCTAssertThrowsError(try accounts.addAPIKey(label: "Key", key: "fixture-key", region: "cn"))
            XCTAssertEqual(try files.readText(settingsPath), text)
        }
    }

    func testUnreadableConfigurationIsNotTreatedAsMissing() {
        let files = FailingKimiAccountFiles([settingsPath: "[]"])
        files.unreadable.insert(settingsPath)
        let accounts = store(files: files)

        XCTAssertNotNil(accounts.loadError)
        XCTAssertThrowsError(try accounts.addAPIKey(label: "Key", key: "fixture-key", region: "cn"))
        XCTAssertEqual(files.base.files, [settingsPath: "[]"])
    }

    func testConfigurationCorruptedAfterLoadCannotBeOverwritten() {
        let files = FakeFiles()
        let accounts = store(files: files)
        files.files[settingsPath] = "corrupted after launch"

        XCTAssertThrowsError(try accounts.addAPIKey(label: "Key", key: "fixture-key", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .configurationUnavailable)
        }
        XCTAssertNotNil(accounts.loadError)
        XCTAssertEqual(files.files, [settingsPath: "corrupted after launch"])
    }

    func testExternalValidChangesAreNotOverwrittenByStaleStore() throws {
        let files = FakeFiles()
        let stale = store(files: files)
        try store(files: files).addAPIKey(label: "Other Window", key: "fixture-other-key", region: "cn")
        let original = files.files

        XCTAssertThrowsError(try stale.addAPIKey(label: "Stale", key: "fixture-stale-key", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .configurationChanged)
        }
        XCTAssertEqual(files.files, original)
        XCTAssertTrue(stale.accounts.isEmpty)
    }

    func testFailedMetadataSaveRollsBackNewAPIKeyFile() {
        let files = FailingKimiAccountFiles()
        files.unwritable.insert(settingsPath)
        let accounts = store(files: files)

        XCTAssertThrowsError(try accounts.addAPIKey(label: "Key", key: "fixture-unsaved-key", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .saveFailed)
            XCTAssertFalse(error.localizedDescription.contains("fixture-unsaved-key"))
        }
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertTrue(files.base.files.isEmpty)
    }

    func testFailedKeyWriteDoesNotCreateAccountSettings() {
        let files = FailingKimiAccountFiles()
        files.rejectWrites = true
        let accounts = store(files: files)

        XCTAssertThrowsError(try accounts.addAPIKey(key: "fixture-unwritten-key", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .credentialWriteFailed)
            XCTAssertFalse(error.localizedDescription.contains("fixture-unwritten-key"))
        }
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertTrue(files.base.files.isEmpty)
    }

    func testFailedMetadataSaveReportsUnremovedKeyWithoutAddingAccount() throws {
        let files = FailingKimiAccountFiles()
        files.unwritable.insert(settingsPath)
        files.rejectRemovals = true
        let accounts = store(files: files)

        XCTAssertThrowsError(try accounts.addAPIKey(key: "fixture-orphaned-key", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .saveFailedKeyRemains)
            XCTAssertFalse(error.localizedDescription.contains("fixture-orphaned-key"))
        }
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertFalse(files.exists(settingsPath))
        XCTAssertEqual(files.base.files.count, 1)
        let savedKey = try XCTUnwrap(files.base.files.first)
        XCTAssertTrue(savedKey.key.hasPrefix(credentialsDirectory + "/"))
        XCTAssertEqual(UserAPIKeyStore.keyFromConfigText(savedKey.value), "fixture-orphaned-key")
    }

    func testFailedRemovalMetadataSaveKeepsAccountAndCredential() throws {
        let files = FailingKimiAccountFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(label: "Key", key: "fixture-retained-key", region: "cn")
        let original = files.base.files
        let account = try XCTUnwrap(accounts.accounts.first)
        files.unwritable.insert(settingsPath)

        XCTAssertThrowsError(try accounts.remove(id: account.id)) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .saveFailed)
        }
        XCTAssertEqual(accounts.accounts, [account])
        XCTAssertEqual(files.base.files, original)
    }

    func testKeyDeletionFailureReportsThatTheAccountWasAlreadyRemoved() throws {
        let files = FailingKimiAccountFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(label: "Key", key: "fixture-retained-file", region: "cn")
        let account = try XCTUnwrap(accounts.accounts.first)
        files.unremovable.insert(account.credentialPath)

        XCTAssertThrowsError(try accounts.remove(id: account.id)) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .credentialRemovalFailed)
        }
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertTrue(store(files: files).accounts.isEmpty)
        XCTAssertTrue(files.exists(account.credentialPath))
    }

    func testMissingOrCorruptSavedKeyDoesNotBypassDuplicateDetection() throws {
        let invalidKeys: [String?] = [nil, "", "{}", #"{"apiKey":"  "}"#, #"{"apiKey":"broken""#]
        for invalidKey in invalidKeys {
            let files = FakeFiles()
            let accounts = store(files: files)
            try accounts.addAPIKey(label: "First", key: "fixture-first-key", region: "cn")
            let path = try XCTUnwrap(accounts.accounts.first?.credentialPath)
            if let invalidKey {
                files.files[path] = invalidKey
            } else {
                try files.remove(path)
            }
            let original = files.files
            let reloaded = store(files: files)

            XCTAssertThrowsError(try reloaded.addAPIKey(key: "fixture-second-key", region: "cn")) { error in
                XCTAssertEqual(error as? KimiAccountsStore.Failure, .storedKeyUnavailable)
            }
            XCTAssertEqual(reloaded.accounts, accounts.accounts)
            XCTAssertEqual(files.files, original)
        }
    }

    func testUnreadableSavedKeyDoesNotBypassDuplicateDetection() throws {
        let files = FailingKimiAccountFiles()
        let accounts = store(files: files)
        try accounts.addAPIKey(key: "fixture-unreadable-key", region: "cn")
        files.unreadable.insert(try XCTUnwrap(accounts.accounts.first?.credentialPath))
        let original = files.base.files

        XCTAssertThrowsError(try accounts.addAPIKey(key: "fixture-another-key", region: "cn")) { error in
            XCTAssertEqual(error as? KimiAccountsStore.Failure, .storedKeyUnavailable)
        }
        XCTAssertEqual(accounts.accounts.count, 1)
        XCTAssertEqual(files.base.files, original)
    }

    func testRemovingUnknownAccountDoesNotWriteSettingsOrTouchSavedKeys() throws {
        let files = FakeFiles()
        let accounts = store(files: files)
        try accounts.remove(id: UUID())
        XCTAssertTrue(files.files.isEmpty)
        try accounts.addAPIKey(key: "fixture-retained-key", region: "cn")
        let original = files.files

        try accounts.remove(id: UUID())

        XCTAssertEqual(accounts.accounts.count, 1)
        XCTAssertEqual(files.files, original)
    }
}

private final class FailingKimiAccountFiles: TextFileAccessing, @unchecked Sendable {
    let base: FakeFiles
    var unreadable = Set<String>()
    var unwritable = Set<String>()
    var unremovable = Set<String>()
    var rejectWrites = false
    var rejectRemovals = false

    init(_ files: [String: String] = [:]) {
        base = FakeFiles(files)
    }

    func exists(_ path: String) -> Bool { base.exists(path) }

    func readText(_ path: String) throws -> String {
        if unreadable.contains(path) { throw CocoaError(.fileReadNoPermission) }
        return try base.readText(path)
    }

    func writeText(_ path: String, _ text: String) throws {
        if rejectWrites || unwritable.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        try base.writeText(path, text)
    }

    func remove(_ path: String) throws {
        if rejectRemovals || unremovable.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        try base.remove(path)
    }
}
