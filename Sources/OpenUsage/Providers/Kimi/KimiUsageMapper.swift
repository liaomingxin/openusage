import Foundation

struct KimiMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Normalizes the Kimi Code subscription-usage response (`GET …/coding/v1/usages`) into metric lines.
/// Kimi reports raw used/limit counts, which convert to the percent meters every provider uses
/// (`.percent` carries 0...100 with `limit: 100`). All numbers arrive as strings — the CLI accepts
/// string-or-number, and so does `ProviderParse.number`. `usage` is the headline weekly allowance;
/// `limits[]` carries fine-grained windows, of which the 5-hour entry is the session meter — the
/// same shape Codex reports. See docs/research/kimi-code-usage-api.md for the protocol reference.
enum KimiUsageMapper {
    static let weeklyPeriodMs = MetricPeriod.weekMs
    static let sessionPeriodMs = MetricPeriod.sessionMs

    static func map(_ response: HTTPResponse, now: Date = Date()) throws -> KimiMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: KimiAuthError.sessionExpired,
            requestFailed: { KimiUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw KimiUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let usage = body["usage"] as? [String: Any] {
            if let line = weeklyLine(usage: usage) {
                lines.append(line)
            }
        }
        if let session = sessionLine(body: body) {
            lines.append(session)
        }
        if let booster = boosterLine(body: body) {
            lines.append(booster)
        }

        return KimiMappedUsage(plan: planName(body), lines: lines)
    }

    // MARK: - Windows

    /// `usage` is the headline allowance. When the response omits its window the CLI assumes a week —
    /// we default `periodDurationMs` the same way rather than guessing from `resetTime` alone. A
    /// usage block with a zero limit has nothing to meter and yields no line (the provider appends
    /// the shared "No data" badge when the snapshot ends up empty).
    private static func weeklyLine(usage: [String: Any]) -> MetricLine? {
        guard let line = percentLine(
            label: "Weekly",
            used: ProviderParse.number(usage["used"]),
            limit: ProviderParse.number(usage["limit"]),
            resetTime: usage["resetTime"],
            periodMs: windowMs(usage["window"] as? [String: Any]) ?? weeklyPeriodMs
        ) else { return nil }
        return line
    }

    /// The first `limits[]` entry whose window is the 5-hour session (300 minutes), if present.
    /// Other windows (daily caps and the like) exist but aren't metered yet; per the CLI's own
    /// parser, an entry missing both `used` and `limit` is dropped.
    private static func sessionLine(body: [String: Any]) -> MetricLine? {
        let limits = body["limits"] as? [[String: Any]] ?? []
        for entry in limits {
            guard let window = entry["window"] as? [String: Any],
                  windowMs(window) == sessionPeriodMs,
                  let detail = entry["detail"] as? [String: Any]
            else { continue }
            if let line = percentLine(
                label: "Session",
                used: ProviderParse.number(detail["used"]),
                limit: ProviderParse.number(detail["limit"]),
                resetTime: detail["resetTime"],
                periodMs: sessionPeriodMs
            ) {
                return line
            }
        }
        return nil
    }

    /// One used/limit pair → a percent meter, or `nil` when there is no limit to fill against.
    private static func percentLine(
        label: String,
        used: Double?,
        limit: Double?,
        resetTime: Any?,
        periodMs: Int
    ) -> MetricLine? {
        guard let limit, limit > 0 else { return nil }
        let percent = ProviderParse.clampPercent((used ?? 0) / limit * 100)
        return .progress(
            label: label,
            used: percent,
            limit: 100,
            format: .percent,
            resetsAt: (resetTime as? String).flatMap(OpenUsageISO8601.date(from:)),
            periodDurationMs: periodMs
        )
    }

    // MARK: - Pay-as-you-go wallet

    /// `boosterWallet` is absent on subscription accounts; when present it is the pay-as-you-go
    /// balance. Amounts are fixed-point millionths of a cent (`/1e6` → cents, `/100` → dollars).
    private static func boosterLine(body: [String: Any]) -> MetricLine? {
        guard let wallet = body["boosterWallet"] as? [String: Any],
              let balance = wallet["balance"] as? [String: Any],
              let leftMicro = ProviderParse.number(balance["amountLeft"])
        else {
            return nil
        }
        let left = ProviderParse.centsToDollars(leftMicro / 1e6)
        return .values(label: "Booster", values: [MetricValue(number: left, kind: .dollars)])
    }

    // MARK: - Scalars

    /// `membership.level` arrives as an enum name (`LEVEL_ADVANCED`) — strip the prefix and title-case.
    private static func planName(_ body: [String: Any]) -> String? {
        guard let user = body["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = membership["level"] as? String,
              level.hasPrefix("LEVEL_")
        else {
            return nil
        }
        let name = String(level.dropFirst("LEVEL_".count)).lowercased()
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A Kimi window — `{duration, timeUnit}` with `duration` as a count of minutes/hours/days/weeks
    /// (`TIME_UNIT_MINUTE` etc.). Returns milliseconds, or `nil` when the window is missing or uses
    /// an unknown unit (never guess a period).
    static func windowMs(_ window: [String: Any]?) -> Int? {
        guard let window,
              let duration = ProviderParse.number(window["duration"]), duration > 0
        else { return nil }
        let unitSeconds: Double
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": unitSeconds = 60
        case "TIME_UNIT_HOUR": unitSeconds = 3600
        case "TIME_UNIT_DAY": unitSeconds = 86_400
        case "TIME_UNIT_WEEK": unitSeconds = 604_800
        default: return nil
        }
        return Int(duration * unitSeconds * 1000)
    }
}
