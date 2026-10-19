import Foundation
import Observation

/// Account-card-specific overrides; provider-reported billing dates remain read-only fallbacks.
@MainActor
@Observable
final class SubscriptionExpiryStore {
    static let storageKey = "openusage.subscriptionExpiries.v1"

    struct Entry: Codable, Equatable, Sendable {
        var expiresAt: Date
        var isEnding: Bool
        var updatedAt: Date
    }

    enum Source: String, Equatable, Sendable {
        case manual, automatic
    }

    struct ResolvedExpiry: Equatable, Sendable {
        let providerID: String
        let date: Date
        let isEnding: Bool
        let source: Source

        func daysRemaining(now: Date = Date(), calendar: Calendar = .current) -> Int {
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
            ).day ?? 0
        }

        func severity(now: Date = Date(), calendar: Calendar = .current) -> WidgetData.MeterSeverity {
            let days = daysRemaining(now: now, calendar: calendar)
            if days <= 3 { return .critical }
            if days <= 7 { return .warning }
            return .normal
        }

        func formattedDate(calendar: Calendar = .current) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        func countdownText(now: Date = Date(), calendar: Calendar = .current) -> String {
            let days = daysRemaining(now: now, calendar: calendar)
            switch days {
            case ..<0: return "Expired \(-days)d ago"
            case 0: return "Today"
            case 1: return "Tomorrow"
            default: return "in \(days)d"
            }
        }
    }

    private let defaults: UserDefaults
    private let fileURL: URL?
    private let accountKeysByProviderID: [String: [String]]
    private(set) var entries: [String: Entry]

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("subscription-expiries.json", isDirectory: false)
    }

    static func makeAccountKeys(
        providers: [Provider],
        identityKeysByCard: [String: String]
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in providers {
            let family = ProviderAccountID.family(of: provider.id).lowercased()
            var keys: [String] = []
            if let identity = identityKeysByCard[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !identity.isEmpty {
                keys.append("\(family):id:\(identity)")
            }
            if let label = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !label.isEmpty {
                keys.append("\(family):label:\(label)")
            }
            keys.append(provider.id)
            result[provider.id] = keys
        }
        return result
    }

    init(
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        accountKeysByProviderID: [String: [String]] = [:]
    ) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.accountKeysByProviderID = accountKeysByProviderID
        let decoder = Self.makeDecoder()
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? decoder.decode([String: Entry].self, from: data) {
            self.entries = decoded
        } else if let fileURL,
                  let data = try? Data(contentsOf: fileURL),
                  let decoded = try? decoder.decode([String: Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    private func lookupKeys(for providerID: String) -> [String] {
        accountKeysByProviderID[providerID] ?? [providerID]
    }

    func entry(for providerID: String) -> Entry? {
        for key in lookupKeys(for: providerID) {
            if let found = entries[key] { return found }
        }
        return nil
    }

    func setExpiry(_ date: Date, isEnding: Bool = false, for providerID: String) {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let record = Entry(expiresAt: date, isEnding: isEnding, updatedAt: now)
        for key in lookupKeys(for: providerID) {
            entries[key] = record
        }
        persist()
    }

    func clearExpiry(for providerID: String) {
        var removed = false
        for key in lookupKeys(for: providerID) {
            if entries.removeValue(forKey: key) != nil {
                removed = true
            }
        }
        guard removed else { return }
        persist()
    }

    func resetAll() {
        entries = [:]
        defaults.removeObject(forKey: Self.storageKey)
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func resolvedExpiry(for providerID: String, snapshot: ProviderSnapshot?) -> ResolvedExpiry? {
        if let entry = entry(for: providerID) {
            return ResolvedExpiry(
                providerID: providerID, date: entry.expiresAt, isEnding: entry.isEnding, source: .manual
            )
        }
        for line in snapshot?.lines ?? [] {
            if case .date(let label, let at, _, _) = line {
                return ResolvedExpiry(
                    providerID: providerID, date: at, isEnding: label == MetricLine.endsLabel, source: .automatic
                )
            }
        }
        return nil
    }

    private func persist() {
        let encoder = Self.makeEncoder()
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else if let data = try? encoder.encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
            if let fileURL {
                let dir = fileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
