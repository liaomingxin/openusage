import Foundation
import os

/// An immutable pricing snapshot: the supplement plus the two public catalogs, with the resolution
/// order ported from ccusage. `ModelPricingStore` builds one; scanners and mappers use it
/// synchronously for a whole parse pass.
///
/// Resolution for a model name:
/// 1. The user's custom pricing file (`~/.config/openusage/custom-pricing.json`), by exact id or
///    alias-canonical key — the user is explicitly overriding, so it wins over every other source.
/// 2. Supplement alias rules rewrite the slug to a canonical key (raw name kept as fallback).
/// 3. Supplement pricing (exact) — Cursor-native models live here.
/// 4. LiteLLM exact.
/// 5. `-fast` suffix: price the base model and scale by its fast multiplier; if no multiplier or
///    exact fast entry exists, leave it unpriced instead of silently using standard-speed rates.
/// 6. LiteLLM fuzzy (boundary-aware substring matching, for non-fast slugs only).
/// 7. models.dev exact — id-level gap-filler only. models.dev aggregates resellers under near-
///    identical bare ids (`glm-5-2` vs `glm-5.2`) with diverging rates, so fuzzy matching against
///    it risks wrong dollars; unknown slug variants stay unpriced (and visibly flagged) instead.
final class ModelPricing: Sendable {
    let supplement: PricingSupplement
    /// The user's own overrides — highest-precedence source (see the type doc for the layer order).
    let custom: CustomPricing
    /// A friendly reason the custom file's overrides are currently ignored (unreadable file), shown
    /// on the spend tiles' warning tooltip. Nil when the file is absent or loaded fine — an absent
    /// file is normal, not an error.
    let customPricingProblem: String?
    /// LiteLLM `model_prices_and_context_window.json` (bundled snapshot merged with fetched data).
    let primary: PricingCatalog
    /// models.dev `api.json` — gap-filler for models LiteLLM misses (e.g. `grok-build-0.1`).
    let secondary: PricingCatalog

    /// Resolution walks every catalog entry on a fuzzy miss, so memoize per model name. Shared
    /// across threads; a pricing snapshot is immutable so entries never invalidate.
    private let memo = OSAllocatedUnfairLock<[String: ModelRates?]>(initialState: [:])
    /// The alias scan walks every rule, and breakdown naming asks for the same slugs row after row.
    private let canonicalMemo = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    init(
        supplement: PricingSupplement,
        custom: CustomPricing = .empty,
        customPricingProblem: String? = nil,
        primary: PricingCatalog,
        secondary: PricingCatalog
    ) {
        self.supplement = supplement
        self.custom = custom
        self.customPricingProblem = customPricingProblem
        self.primary = primary
        self.secondary = secondary
    }

    static let empty = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog())

    /// Rates for `model`, or nil when no source can price it (caller shows the unknown-model
    /// warning and counts tokens at $0).
    func resolve(model: String) -> ModelRates? {
        if let cached = memo.withLock({ $0[model] }) {
            return cached
        }
        let resolved = resolveUncached(model: model)
        memo.withLock { $0[model] = resolved }
        return resolved
    }

    /// The canonical pricing key for `model`: the alias rule's target, or the raw name when no rule
    /// matches. Memoized, unlike `PricingSupplement.canonicalName(for:)`.
    func canonicalName(for model: String) -> String {
        if let cached = canonicalMemo.withLock({ $0[model] }) { return cached }
        let canonical = supplement.canonicalName(for: model) ?? model
        canonicalMemo.withLock { $0[model] = canonical }
        return canonical
    }

    /// The display family for a raw slug: its canonical key with the first matching suffix dropped
    /// (`-fast` for Cursor, `-preview` for Antigravity), so effort variants, display labels, and
    /// placeholder IDs share one breakdown row. Slugs no alias rule knows keep their raw name — a
    /// guess would silently merge unrelated models.
    func familyName(for model: String, stripping suffixes: [String]) -> String {
        let canonical = canonicalName(for: model)
        for suffix in suffixes where canonical.hasSuffix(suffix) {
            let base = String(canonical.dropLast(suffix.count))
            if !base.isEmpty { return base }
        }
        return canonical
    }

    /// Dollar cost of `tokens` for `model`, or nil when the model can't be priced — including when a
    /// custom-pricing entry omits one of the rates this request would bill at. Aggregated sources
    /// can disable long-context tiers when they do not preserve individual request boundaries.
    func estimatedCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double? {
        guard let rates = resolve(model: model) else { return nil }
        return rates.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }

    /// Why a model the spend tiles flagged as unpriced has no price, so the warning can tell the
    /// user what to do instead of just naming the model. Nil when every source prices it fine.
    enum UnpricedModelReason: Equatable, Sendable {
        /// No source — custom file, supplement, or either catalog — recognizes the model id.
        case unknownModel
        /// The custom file has an entry, but it omits rates; the missing fields' display names ride
        /// along so the tooltip can say exactly which lines to add.
        case incompleteCustomRates(missingFields: [String])
    }

    /// Classifies one flagged model name (the raw slug the scanner reported). A model whose custom
    /// entry is complete but whose *usage* touches an omitted bucket still resolves to rates, so
    /// this consults the custom entry's missing fields directly rather than `resolve`'s result.
    func unpricedReason(for model: String) -> UnpricedModelReason? {
        let missing = custom.missingFieldNames(for: model)
        if !missing.isEmpty { return .incompleteCustomRates(missingFields: missing) }
        let canonical = canonicalName(for: model)
        if canonical != model {
            let canonicalMissing = custom.missingFieldNames(for: canonical)
            if !canonicalMissing.isEmpty { return .incompleteCustomRates(missingFields: canonicalMissing) }
        }
        guard resolve(model: model) == nil else { return nil }
        return .unknownModel
    }

    private func resolveUncached(model: String) -> ModelRates? {
        if let canonical = supplement.canonicalName(for: model), canonical != model {
            return (custom.rates(for: model) ?? custom.rates(for: canonical))
                ?? (lookup(canonical) ?? lookup(model))
        }
        return custom.rates(for: model) ?? lookup(model)
    }

    /// The secondary catalog is consulted only after the whole primary lookup misses, like ccusage —
    /// models.dev aggregates resellers whose rates can differ, so LiteLLM wins whenever it knows the
    /// model at all, and models.dev answers exact ids only (see the fuzzy note on the type).
    private func lookup(_ name: String) -> ModelRates? {
        if let entry = supplement.pricing[name] { return entry }
        if let exact = primary.findExact(name) { return exact.rates }
        if let fast = fastVariant(name) { return fast }
        if name.hasSuffix("-fast") { return secondary.findExact(name)?.rates }
        if let fuzzy = primary.findFuzzy(name) { return fuzzy.rates }
        if let exact = secondary.findExact(name) { return exact.rates }
        return nil
    }

    /// Prices `<base>-fast` slugs from their base entry when a fast multiplier is known. Returns
    /// nil when the multiplier is unknown; the caller may still accept an exact fast entry from
    /// models.dev, but never fuzzy-matches the standard-speed base rate.
    private func fastVariant(_ name: String) -> ModelRates? {
        guard name.hasSuffix("-fast") else { return nil }
        let base = String(name.dropLast("-fast".count))
        guard !base.isEmpty else { return nil }
        guard let (key, rates) = baseEntry(base) else { return nil }
        let multiplier: Double
        if rates.fastMultiplier != 1 {
            multiplier = rates.fastMultiplier
        } else if let supplementMultiplier = supplement.fastMultiplier(for: key) ?? supplement.fastMultiplier(for: base) {
            multiplier = supplementMultiplier
        } else {
            return nil
        }
        return rates.scaled(by: multiplier)
    }

    private func baseEntry(_ base: String) -> (key: String, rates: ModelRates)? {
        if let entry = supplement.pricing[base] { return (base, entry) }
        return primary.findExact(base)
            ?? primary.findFuzzy(base)
            ?? secondary.findExact(base)
    }
}
