import Foundation
import Observation

struct KimiAccountConfiguration: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var label: String
    var credentialPath: String
    var region: String

    var cardID: String {
        ProviderAccountID.make(family: "kimi", identityKey: id.uuidString)
    }
}

/// Persists card metadata separately from secrets. Only UUID-named API-key files created
/// in this store's private credentials directory are removable.
@MainActor
@Observable
final class KimiAccountsStore {
    static let configurationPath = "~/.config/openusage/kimi-accounts.json"
    static let credentialsDirectory = "~/.config/openusage/kimi-credentials"

    enum Failure: Error, LocalizedError, Equatable {
        case missingKey
        case invalidRegion
        case duplicateKey
        case configurationUnavailable
        case configurationChanged
        case storedKeyUnavailable
        case credentialWriteFailed
        case saveFailed
        case saveFailedKeyRemains
        case credentialRemovalFailed

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "Enter a Kimi Coding Plan API key."
            case .invalidRegion:
                "Choose China or Global for the account region."
            case .duplicateKey:
                "This API key is already saved for a Kimi account."
            case .configurationUnavailable:
                "Kimi account settings could not be read. Restart OpenUsage before making changes."
            case .configurationChanged:
                "Kimi account settings changed. Restart OpenUsage to load those changes before editing."
            case .storedKeyUnavailable:
                "A saved API key could not be read. Remove its account and add the key again before adding another account."
            case .credentialWriteFailed:
                "The API key could not be saved. Check that OpenUsage can save account settings."
            case .saveFailed:
                "Kimi account settings could not be saved. No account changes were applied."
            case .saveFailedKeyRemains:
                "Kimi account settings could not be saved, and the unused saved API key could not be deleted."
            case .credentialRemovalFailed:
                "The account was removed, but its saved API key could not be deleted."
            }
        }
    }

    private let files: TextFileAccessing
    private let settingsPath: String
    private let managedDirectory: String

    private(set) var accounts: [KimiAccountConfiguration] = []
    private(set) var loadError: String?

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        configurationPath: String = KimiAccountsStore.configurationPath,
        credentialsDirectory: String = KimiAccountsStore.credentialsDirectory
    ) {
        self.files = files
        self.settingsPath = Self.canonicalPath(configurationPath)
        self.managedDirectory = Self.canonicalPath(credentialsDirectory)
        do {
            accounts = try readConfiguration()
        } catch {
            markConfigurationUnavailable()
        }
    }

    func addAPIKey(label: String = "", key: String, region: String) throws {
        try ensureConfigurationIsCurrent()
        let label = resolvedLabel(label)
        let region = try validatedRegion(region)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.missingKey }

        for account in accounts {
            guard let text = try? files.readText(account.credentialPath),
                  let existingKey = UserAPIKeyStore.keyFromConfigText(text)
            else { throw Failure.storedKeyUnavailable }
            guard existingKey != key else { throw Failure.duplicateKey }
        }

        let id = availableID()
        let path = managedCredentialPath(for: id)
        let account = KimiAccountConfiguration(
            id: id, label: label, credentialPath: path, region: region
        )
        let data = try JSONEncoder().encode(["apiKey": key])
        let text = String(decoding: data, as: UTF8.self)
        do {
            // LocalTextFileAccessor publishes this atomically with owner-only (0600) permissions.
            try files.writeText(path, text)
        } catch {
            AppLog.error(.auth, "Kimi account API key could not be saved")
            throw Failure.credentialWriteFailed
        }
        do {
            try persist(accounts + [account])
        } catch {
            do {
                try files.remove(path)
            } catch {
                AppLog.error(.auth, "Unused Kimi account API key could not be removed after a settings save failure")
                throw Failure.saveFailedKeyRemains
            }
            throw Failure.saveFailed
        }
    }

    func remove(id: UUID) throws {
        try ensureConfigurationIsCurrent()
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        // Commit metadata first: a failed settings write must never delete a working credential.
        try persist(accounts.filter { $0.id != id })
        guard Self.standardizedPath(account.credentialPath) == managedCredentialPath(for: id)
        else { return }
        do {
            try files.remove(account.credentialPath)
        } catch {
            AppLog.error(.auth, "Removed Kimi account's saved API key file could not be deleted")
            throw Failure.credentialRemovalFailed
        }
    }

    private func readConfiguration() throws -> [KimiAccountConfiguration] {
        guard let text = try files.readTextIfPresent(settingsPath) else { return [] }
        let decoded = try JSONDecoder().decode([KimiAccountConfiguration].self, from: Data(text.utf8))
        var ids = Set<UUID>()
        var cardIDs = Set<String>()
        var paths = Set<String>()
        for account in decoded {
            guard !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.credentialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.region == "cn" || account.region == "global",
                  ids.insert(account.id).inserted,
                  cardIDs.insert(account.cardID).inserted,
                  paths.insert(Self.canonicalPath(account.credentialPath)).inserted
            else { throw Failure.configurationUnavailable }
        }
        return decoded
    }

    private func ensureConfigurationIsCurrent() throws {
        guard loadError == nil else { throw Failure.configurationUnavailable }
        let current: [KimiAccountConfiguration]
        do {
            current = try readConfiguration()
        } catch {
            markConfigurationUnavailable()
            throw Failure.configurationUnavailable
        }
        guard current == accounts else { throw Failure.configurationChanged }
    }

    private func markConfigurationUnavailable() {
        loadError = Failure.configurationUnavailable.localizedDescription
        // Never interpolate decoding errors: malformed credential-like content can be echoed by them.
        AppLog.error(.config, "Kimi account settings could not be read; preserving the existing file")
    }

    private func persist(_ updated: [KimiAccountConfiguration]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(updated)
            try files.writeText(settingsPath, String(decoding: data, as: UTF8.self))
        } catch {
            AppLog.error(.config, "Kimi account settings could not be saved")
            throw Failure.saveFailed
        }
        accounts = updated
    }

    private func resolvedLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let usedLabels = Set(accounts.lazy.map(\.label))
        var number = 1
        while usedLabels.contains("Account \(number)") {
            number += 1
        }
        return "Account \(number)"
    }

    private func validatedRegion(_ region: String) throws -> String {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "cn" || trimmed == "global" else { throw Failure.invalidRegion }
        return trimmed
    }

    private func availableID() -> UUID {
        while true {
            let id = UUID()
            let cardID = ProviderAccountID.make(family: "kimi", identityKey: id.uuidString)
            if !accounts.contains(where: { $0.id == id || $0.cardID == cardID }),
               !files.exists(managedCredentialPath(for: id)) {
                return id
            }
        }
    }

    private func managedCredentialPath(for id: UUID) -> String {
        URL(fileURLWithPath: managedDirectory).appendingPathComponent("\(id.uuidString).json").path
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: standardizedPath(path)).resolvingSymlinksInPath().path
    }
}
