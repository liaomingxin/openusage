import Foundation

struct KimiMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Normalizes both current ratio-based quotas and legacy counter-based Kimi Code responses.
/// The current API exposes separate monthly total and coding pools; legacy plans also have a
/// weekly pool. Missing windows stay absent rather than appearing as unused allowances.
enum KimiUsageMapper {
    static let weeklyPeriodMs = MetricPeriod.weekMs
    static let sessionPeriodMs = MetricPeriod.sessionMs

    static func map(_ response: HTTPResponse, now: Date = Date()) throws -> KimiMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: KimiAuthError.sessionExpired,
            requestFailed: { KimiUsageError.requestFailed($0) }
        )

        guard let envelope = ProviderParse.jsonObject(response.body) else {
            throw KimiUsageError.invalidResponse
        }
        let body = (envelope["data"] as? [String: Any])?["quota"] as? [String: Any] ?? envelope
        let usages = body["usages"] as? [String: Any] ?? [:]
        var lines: [MetricLine] = []
        let session = sessionLine(body: body)
        let weekly = (body["usage"] as? [String: Any]).flatMap(weeklyLine)
        if let line = quotaLine(
            label: "Session", summary: usages["limit_5h"] ?? usages["limit5h"],
            legacy: session, periodMs: sessionPeriodMs
        ) {
            lines.append(line)
        }
        if let line = quotaLine(
            label: "Weekly", summary: usages["limit_7d"] ?? usages["limit7d"],
            legacy: weekly, periodMs: weeklyPeriodMs
        ) {
            lines.append(line)
        }
        if let total = quotaLine(
            label: "Monthly Total", summary: usages["limit_month_total"], legacy: nil, periodMs: nil
        ) {
            lines.append(total)
        }
        if let coding = quotaLine(
            label: "Monthly Coding", summary: usages["limit_month_code"], legacy: nil, periodMs: nil
        ) {
            lines.append(coding)
        }
        if let booster = boosterLine(body: body) {
            lines.append(booster)
        }
        return KimiMappedUsage(plan: planName(body), lines: lines)
    }

    // MARK: - Windows

    private static func quotaLine(
        label: String, summary: Any?, legacy: MetricLine?, periodMs: Int?
    ) -> MetricLine? {
        guard let summary = summary as? [String: Any],
              let ratio = ProviderParse.number(summary["used_ratio"] ?? summary["usedRatio"]),
              ratio.isFinite, (0...1).contains(ratio)
        else { return legacy }
        // Some accounts receive zeroed summary ratios alongside live counters. Never turn a
        // demonstrably used pool into "Not started" just because that summary is stale.
        if ratio == 0, case .progress(_, let used, _, _, _, _, _, _) = legacy, used > 0 {
            return legacy
        }
        let reset = summary["reset_time"] ?? summary["resetAt"]
        return .progress(
            label: label, used: ratio * 100, limit: 100, format: .percent,
            resetsAt: (reset as? String).flatMap(OpenUsageISO8601.date(from:)),
            periodDurationMs: periodMs
        )
    }

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

    /// Amounts are fixed-point millionths of a cent; a disabled/empty wallet has no amount to show.
    private static func boosterLine(body: [String: Any]) -> MetricLine? {
        guard let wallet = (body["booster_wallet"] ?? body["boosterWallet"]) as? [String: Any],
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
