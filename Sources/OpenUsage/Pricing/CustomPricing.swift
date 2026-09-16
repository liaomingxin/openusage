import Foundation

/// The user's own pricing overrides, layered above every bundled and fetched source. Lives in
/// `~/.config/openusage/custom-pricing.json` (the same directory as the provider key files), so a
/// model no catalog prices yet can be priced immediately instead of waiting for a repo update:
///
/// ```
/// {"models": {"grok-bot-cua": {"input_cost_per_million_tokens": 0.6,
///                              "output_cost_per_million_tokens": 2.2,
///                              "cache_read_cost_per_million_tokens": 0.06,
///                              "cache_write_cost_per_million_tokens": 0.75}}}
/// ```
///
/// Every field is optional and per-million-token USD. An explicit `0` means *free* — a real price.
/// An omitted field means *unknown* — never free — so a request whose usage falls in an omitted
/// bucket keeps the model unpriced (and warned about) rather than silently costing $0. A model with
/// only some buckets priced still prices requests that touch none of the missing ones.
struct CustomPricing: Sendable, Equatable {
    /// Field names as they appear in the file, in the order the tooltip names missing ones.
    struct Entry: Sendable, Equatable {
        var inputPerMillion: Double?
        var outputPerMillion: Double?
        var cacheWritePerMillion: Double?
        var cacheReadPerMillion: Double?

        /// Field display names paired with their values, in file order. Used to build both the
        /// `ModelRates` (present fields only) and the "price omits …" tooltip suffix.
        var fields: [(name: String, value: Double?)] {
            [
                ("input", inputPerMillion),
                ("output", outputPerMillion),
                ("cache write", cacheWritePerMillion),
                ("cache read", cacheReadPerMillion)
            ]
        }
    }

    var entries: [String: Entry]

    static let empty = CustomPricing(entries: [:])

    /// The canonical on-disk location, matching the provider key files' directory.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/openusage/custom-pricing.json")
    }
}

/// Filesystem access for the custom pricing file: a cheap mtime+size stamp the pricing store
/// compares between passes, so the file is re-parsed only when it actually changed on disk.
enum CustomPricingFile {
    struct Stamp: Equatable, Sendable {
        var modified: Date?
        var size: Int?
    }

    /// The file's mtime and size, or nil when the file doesn't exist (a normal state — no overrides).
    static func stamp(at url: URL) -> Stamp? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes.map {
            Stamp(modified: $0[.modificationDate] as? Date, size: $0[.size] as? Int)
        }
    }
}

// MARK: - Decoding

enum CustomPricingError: Error, LocalizedError, Equatable {
    case notAnObject
    case modelsMissing
    case modelsNotAnObject
    case entryNotAnObject(model: String)
    case invalidFieldValue(model: String, field: String)

    var errorDescription: String? {
        switch self {
        case .notAnObject:
            return "the file is not a JSON object"
        case .modelsMissing:
            return "no \"models\" object found"
        case .modelsNotAnObject:
            return "\"models\" is not an object"
        case .entryNotAnObject(let model):
            return "the entry for \"\(model)\" is not an object"
        case .invalidFieldValue(let model, let field):
            return "\"\(model)\" has a non-numeric \(field) rate"
        }
    }
}

extension CustomPricing {
    /// Decodes the override file. Throws `CustomPricingError` with a field-precise, human-readable
    /// message so the warning can tell the user exactly what to fix. Unknown extra keys are ignored
    /// so future formats don't brick today's parse. JSONSerialization (not Codable) so a type error
    /// can be reported per entry instead of failing the whole file anonymously.
    static func decode(from data: Data) throws -> CustomPricing {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CustomPricingError.notAnObject
        }
        guard let models = root["models"] as? [String: Any] else {
            throw root.keys.contains("models") ? CustomPricingError.modelsNotAnObject : CustomPricingError.modelsMissing
        }
        let fieldKeys: [(key: String, field: WritableKeyPath<Entry, Double?>)] = [
            ("input_cost_per_million_tokens", \Entry.inputPerMillion),
            ("output_cost_per_million_tokens", \Entry.outputPerMillion),
            ("cache_write_cost_per_million_tokens", \Entry.cacheWritePerMillion),
            ("cache_read_cost_per_million_tokens", \Entry.cacheReadPerMillion)
        ]
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(models.count)
        for (model, value) in models {
            guard let object = value as? [String: Any] else {
                throw CustomPricingError.entryNotAnObject(model: model)
            }
            var entry = Entry()
            for field in fieldKeys {
                guard let raw = object[field.key] else { continue }
                guard let number = raw as? NSNumber else {
                    throw CustomPricingError.invalidFieldValue(model: model, field: field.key)
                }
                entry[keyPath: field.field] = number.doubleValue
            }
            entries[model] = entry
        }
        return CustomPricing(entries: entries)
    }

    /// Rates for `model` with any omitted bucket flagged in `unpricedBuckets` — the flagged buckets
    /// carry a placeholder value that `costDollars` refuses to price, so an unknown rate can never
    /// leak into a total as $0. Present cache buckets keep their published values; an omitted
    /// cache-write falls back to the input rate and an omitted cache-read to 10% of input (the
    /// catalogs' synthesized fallbacks) so a request touching only *known* buckets still prices.
    func rates(for model: String) -> ModelRates? {
        guard let entry = entries[model] else { return nil }
        var missing: UnpricedTokenBuckets = []
        if entry.inputPerMillion == nil { missing.insert(.input) }
        if entry.outputPerMillion == nil { missing.insert(.output) }
        if entry.cacheWritePerMillion == nil { missing.insert(.cacheWrite) }
        if entry.cacheReadPerMillion == nil { missing.insert(.cacheRead) }
        var rates = ModelRates(
            inputPerMillion: entry.inputPerMillion ?? 0,
            outputPerMillion: entry.outputPerMillion ?? 0,
            cacheWritePerMillion: entry.cacheWritePerMillion ?? entry.inputPerMillion ?? 0,
            cacheReadPerMillion: entry.cacheReadPerMillion ?? (entry.inputPerMillion ?? 0) * 0.1,
            cacheReadIsExplicit: entry.cacheReadPerMillion != nil
        )
        rates.unpricedBuckets = missing
        return rates
    }

    /// The file-order display names of the fields `model`'s entry omits ("cache read"), for the
    /// warning tooltip's "price omits …" suffix. Empty for a model with no entry.
    func missingFieldNames(for model: String) -> [String] {
        guard let entry = entries[model] else { return [] }
        return entry.fields.filter { $0.value == nil }.map(\.name)
    }

    /// Whether `model` has an override entry at all (complete or partial).
    func contains(_ model: String) -> Bool {
        entries[model] != nil
    }
}
