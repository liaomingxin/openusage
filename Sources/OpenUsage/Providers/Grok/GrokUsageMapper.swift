import Foundation

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
}

enum GrokUsageMapper {
    /// The row label for the per-product split of the shared pool. Shared with the widget descriptor,
    /// which matches lines to tiles by label.
    static let productUsageLabel = "Product Usage"

    /// Map the credits-format billing response into the provider's remote lines: the Weekly meter,
    /// the pay-as-you-go badge, and the per-product split of the pool. The Weekly line is omitted (the
    /// tile reads "No data") when the account's current period isn't weekly — an account still on the
    /// old monthly-only billing has no weekly pool, and mislabeling its monthly percent would be worse
    /// than an honest blank.
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            lines.append(.progress(
                label: "Weekly limit",
                used: ProviderParse.clampPercent(config.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: config.periodEnd,
                periodDurationMs: config.periodDurationMs
            ))
        }
        // A missing `onDemandCap` means no pay-as-you-go (proto-JSON also drops a 0 cap) → the
        // Disabled badge, same as a present cap of 0.
        lines.append(.badge(
            label: "Pay as you go",
            text: config.onDemandCap > 0 ? "\(formatUnits(config.onDemandCap)) cap" : "Disabled",
            colorHex: config.onDemandCap > 0 ? "#22c55e" : "#a3a3a3"
        ))
        if let products = productUsageLine(config.productUsage) {
            lines.append(products)
        }
        return GrokMappedUsage(lines: lines)
    }

    /// The pool split by product, as one row whose values are built from whatever `productUsage[]`
    /// contained — "4% Build · 1% Chat". Nothing here knows the product set, so a product xAI adds
    /// later shows up on its own, with no new metric id and no code change.
    ///
    /// Products sitting at 0% are left out: the row exists to answer "what is eating my pool", and a
    /// tail of "0% Imagine · 0% App Builder" only buries the answer. A period nothing has touched
    /// yet therefore has no row at all, and the tile reads "No data" — the same rule the spend tiles
    /// use for an idle day. The row carries no period word because the pool it splits follows the
    /// account's current period, which is weekly for unified-billing accounts and monthly otherwise.
    static func productUsageLine(_ products: [GrokProductUsage]) -> MetricLine? {
        let used = products
            .filter { $0.usedPercent > 0 }
            .sorted {
                if $0.usedPercent != $1.usedPercent { return $0.usedPercent > $1.usedPercent }
                return $0.product < $1.product
            }
        guard !used.isEmpty else { return nil }
        return .values(label: productUsageLabel, values: used.map { product in
            MetricValue(
                number: ProviderParse.clampPercent(product.usedPercent),
                kind: .percent,
                label: productDisplayName(product.product)
            )
        })
    }

    /// Display name for one product slug. The API sends `GrokBuild` / `GrokAppBuilder`; inside the
    /// Grok card the repeated "Grok" prefix is noise, so drop it and split the remaining camel case
    /// into words ("App Builder"). Cosmetic and shape-agnostic: a name that doesn't match the pattern
    /// — or that the trim would empty — renders exactly as the API sent it, so an unrecognized future
    /// product stays readable instead of turning into a blank.
    static func productDisplayName(_ product: String) -> String {
        let trimmed = product.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Grok"
        let stripped = trimmed.count > prefix.count && trimmed.hasPrefix(prefix)
            ? String(trimmed.dropFirst(prefix.count))
            : trimmed
        let spaced = splittingCamelCase(stripped)
        return spaced.isEmpty ? trimmed : spaced
    }

    private static func splittingCamelCase(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let plan = body["subscription_tier_display"] as? String
        else {
            return nil
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatUnits(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
