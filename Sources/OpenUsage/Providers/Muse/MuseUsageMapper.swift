import Foundation

struct MuseMappedUsage {
    var plan: String?
    var lines: [MetricLine]
}

enum MuseUsageMapper {
    static let defaultWindowDurationMs = 5 * 60 * 60 * 1000
    static let weeklyDurationMs = 7 * 24 * 60 * 60 * 1000

    static func map(_ response: HTTPResponse) throws -> MuseMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: MuseAuthError.sessionExpired,
            requestFailed: { MuseUsageError.requestFailed($0) }
        )

        guard let root = ProviderParse.jsonObject(response.body) else {
            throw MuseUsageError.invalidResponse
        }

        if (root["require_payment"] as? Bool) == true,
           (root["is_subs_active"] as? Bool) != true {
            throw MuseUsageError.paymentRequired
        }

        let plan = formatPlan(
            tierName: root["subs_tier_name"] as? String,
            isSubsActive: root["is_subs_active"] as? Bool,
            hasPaymentMethod: root["has_payment_method"] as? Bool
        )

        var lines: [MetricLine] = []
        if let usage = root["subs_usage"] as? [String: Any] {
            if let window = usage["window"] as? [String: Any],
               let usedPercent = ProviderParse.number(window["used_percent"]) {
                let durationMins = ProviderParse.number(window["window_duration_mins"]) ?? 300
                let durationMs = max(Int(durationMins * 60 * 1000), Self.defaultWindowDurationMs)
                let resetsAt = parseEpochSeconds(window["resets_at"])
                lines.append(.progress(
                    label: "Session",
                    used: max(0, usedPercent),
                    limit: 100,
                    format: .percent,
                    resetsAt: resetsAt,
                    periodDurationMs: durationMs
                ))
            }

            if let weekly = usage["weekly"] as? [String: Any],
               let usedPercent = ProviderParse.number(weekly["used_percent"]) {
                let resetsAt = parseEpochSeconds(weekly["resets_at"])
                lines.append(.progress(
                    label: "Weekly",
                    used: max(0, usedPercent),
                    limit: 100,
                    format: .percent,
                    resetsAt: resetsAt,
                    periodDurationMs: Self.weeklyDurationMs
                ))
            }
        }

        return MuseMappedUsage(plan: plan, lines: lines)
    }

    static func formatPlan(
        tierName: String?,
        isSubsActive: Bool?,
        hasPaymentMethod: Bool?
    ) -> String? {
        if let raw = tierName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let prefix = "Muse Code "
            if raw.lowercased().hasPrefix(prefix.lowercased()) {
                let stripped = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { return stripped }
            }
            return raw
        }
        if isSubsActive == true {
            return "Subscribed"
        }
        if hasPaymentMethod == true {
            return "Pay As You Go"
        }
        return nil
    }

    private static func parseEpochSeconds(_ raw: Any?) -> Date? {
        guard let seconds = ProviderParse.number(raw), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
