import Foundation

/// Builds metric lines from the Z.ai `/api/monitor/usage/quota/limit` payload, plus the plan name and
/// the subscription renewal row from `/api/biz/subscription/list`. Ports and extends the legacy Tauri
/// plugin's mapping:
/// - a `CREDIT_LIMIT` (or legacy `TOKENS_LIMIT`) entry whose window is sub-daily (`unit: 3`, hours)
///   is the 5-hour session meter,
/// - a `CREDIT_LIMIT` (or legacy `TOKENS_LIMIT`) entry whose window is multi-day (`unit: 6`, weeks)
///   is the weekly meter,
/// - a `TIME_LIMIT` entry (`unit: 5`, monthly) is the web-search/reader count meter (used / limit).
///
/// Both endpoints are undocumented internal APIs used by Z.ai's own subscription UI; the response
/// shapes are stable in practice. The mapper is pure (no I/O) so it tests cleanly against sample
/// payloads, exactly like the legacy plugin's fixture-based tests.
enum ZAIUsageMapper {
    /// One monthly web-search cycle, in milliseconds (Z.ai reports `unit: 5, number: 1`). The session
    /// and weekly meters instead carry the *payload's* actual window (see `classifyTokenWindow`), so
    /// their cadence tracks the plan rather than a hardcoded assumption; this monthly constant is only a
    /// fallback for the web-search line and the widget-descriptor default.
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    /// `(plan, lines)` from the quota + subscription payloads. `subscription` may be `nil` (the
    /// request is best-effort) and the quota's `limits` array may carry one to three entries — only
    /// what's present is mapped, so a plan without web searches still shows the session meter. The
    /// subscription payload adds the renewal row when it names a `VALID` period.
    ///
    /// `activityLines` are the usage-history rows built by `ZAIActivityMapper` (Usage Trend, the day
    /// rows, MCP Tools). They slot in after the quota meters and before the renewal row, which stays
    /// last because it is account metadata rather than usage.
    static func map(
        quotaBody: Data,
        subscriptionBody: Data?,
        activityLines: [MetricLine] = []
    ) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        var lines = try mapQuota(quotaBody)
        // The no-data badge means "the quota endpoint produced nothing"; a real row replaces it
        // rather than sitting underneath it.
        let renewal = subscriptionBody.flatMap { renewalLine(from: $0) }
        if lines == [.noUsageData], !activityLines.isEmpty || renewal != nil {
            lines.removeAll()
        }
        lines.append(contentsOf: activityLines)
        if let renewal {
            lines.append(renewal)
        }
        return (plan, lines)
    }

    /// True when a 2xx quota body is the "valid key, but no GLM Coding Plan" signal: Z.ai answers
    /// `{"success":false,"code":500,"msg":"…coding plan"}` with no `data`. The provider turns this into a
    /// clear `.notAvailable` error (a header warning) instead of three blank "No data" meters that don't
    /// say why. Matched on the structured `success:false` plus the "coding plan" phrase the message
    /// carries (ASCII even in the localized string), so an unrelated business failure doesn't trip it.
    static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// Session + weekly + web-search meters from the quota payload. Missing required values are an
    /// invalid response rather than zero usage; an explicit empty array remains a valid no-data state.
    static func mapQuota(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ZAIUsageError.invalidResponse
        }
        // The limits array lives under `data.limits`; the legacy plugin also tolerated the root object
        // being the container directly (no `data` wrapper), so honor both.
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ZAIUsageError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageError.invalidResponse
        }
        guard !limits.isEmpty else {
            return [.noUsageData]
        }

        var lines: [MetricLine] = []
        var sawRecognizedLimit = false

        // Split the percentage quota entries by window length: a sub-daily window is the session
        // meter, and a multi-day window is the weekly meter. Current responses call these
        // CREDIT_LIMIT; older plans used TOKENS_LIMIT for the same shape.
        let percentageLimits = limits.filter {
            let type = ($0["type"] as? String) ?? ($0["name"] as? String)
            return type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT"
        }
        for entry in percentageLimits {
            guard let window = try classifyTokenWindow(entry) else { continue }
            sawRecognizedLimit = true
            switch window {
            case .session(let periodMs):
                lines.append(try percentLine(entry, label: "Session", periodMs: periodMs))
            case .weekly(let periodMs):
                lines.append(try percentLine(entry, label: "Weekly", periodMs: periodMs))
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            sawRecognizedLimit = true
            lines.append(try webSearchLine(from: web))
        }

        guard !lines.isEmpty else {
            if sawRecognizedLimit { throw ZAIUsageError.invalidResponse }
            return [.noUsageData]
        }
        return lines
    }

    /// `productName` from the first valid subscription entry (e.g. "GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return name
    }

    /// The subscription row from the same `subscription/list` payload the plan name comes from — no
    /// extra request. Uses `nextRenewTime` (the end of the running period); `autoRenew: 0` turns the
    /// row into "Ends". An account with no `VALID` entry gets no row at all.
    static func renewalLine(from body: Data) -> MetricLine? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let entry = activeSubscription(list),
              let renewsAt = renewTime(entry["nextRenewTime"])
        else {
            return nil
        }
        // Absent `autoRenew` reads as renewing — only an explicit 0 means the plan lapses.
        let autoRenew = ProviderParse.number(entry["autoRenew"]) ?? 1
        return .subscription(at: renewsAt, isEnding: autoRenew == 0)
    }

    /// The entry describing the running period. `data` is an array — plan changes and stacked add-ons
    /// can produce several entries — so prefer the `VALID` one Z.ai flags as `inCurrentPeriod`, then
    /// any other `VALID` entry. Entries that aren't `VALID` are past or cancelled and never picked.
    private static func activeSubscription(_ list: [[String: Any]]) -> [String: Any]? {
        let valid = list.filter { ($0["status"] as? String)?.uppercased() == "VALID" }
        return valid.first { $0["inCurrentPeriod"] as? Bool == true } ?? valid.first
    }

    /// `nextRenewTime` is a bare calendar string ("2026-11-23", occasionally with a wall-clock time)
    /// and carries no time zone. It's read in the Mac's own calendar so the row renders the exact day
    /// Z.ai's dashboard shows; the countdown can therefore be a few hours out, which is immaterial for
    /// a date that moves once a billing period.
    private static func renewTime(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Private

    /// How a percentage quota entry's window maps to a meter. Z.ai encodes the window as a
    /// `(unit, number)` pair: `unit: 3` is hours (session), `unit: 6` is weeks (weekly), `unit: 5` is
    /// months. A sub-daily window is the session meter; a multi-day window is the weekly meter.
    /// Unknown units are ignored so a future Z.ai window cannot hide meters whose units OpenUsage
    /// still understands.
    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) throws -> TokenWindow? {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]),
              number > 0 else {
            throw ZAIUsageError.invalidResponse
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000
        default: return nil
        }
        let duration = unitMs * number
        guard duration >= 1, duration < Double(Int.max) else {
            throw ZAIUsageError.invalidResponse
        }
        let periodMs = Int(duration)
        // Sub-daily → session; multi-day → weekly. The computed window rides along so the meter's
        // cadence reflects the payload instead of a hardcoded constant.
        if periodMs < 24 * 60 * 60 * 1000 {
            return .session(periodMs: periodMs)
        }
        return .weekly(periodMs: periodMs)
    }

    /// A percentage meter (Session or Weekly) from a credit/token quota entry.
    ///
    /// The percentage is what Z.ai meters (and what the menu-bar pin and `/v1/limits` export), but the
    /// payload also carries the raw credits behind it, so those ride along as the row's `detail` —
    /// "1,030 / 28,000 credits" under the bar. An entry without both numbers simply has no detail.
    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawPercentage = ProviderParse.number(entry["percentage"]) else {
            throw ZAIUsageError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs,
            detail: creditsDetail(entry)
        )
    }

    /// "1,030 / 28,000 credits" from a quota entry's `currentValue` / `usage` pair. `nil` when either
    /// number is missing or the limit is zero — there is no ratio to state then.
    static func creditsDetail(_ entry: [String: Any]) -> String? {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0, limit > 0
        else { return nil }
        let usedText = MetricFormatter.number(used, kind: .count, style: .full)
        let limitText = MetricFormatter.number(limit, kind: .count, style: .full)
        return "\(usedText) / \(limitText) credits"
    }

    /// TIME_LIMIT → a count meter (used / limit) for monthly web-search/reader calls.
    private static func webSearchLine(from entry: [String: Any]) throws -> MetricLine {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0,
              limit >= 0 else {
            throw ZAIUsageError.invalidResponse
        }
        // TIME_LIMIT carries a nextResetTime in current payloads (monthly renewal); honor it when
        // present so the countdown shows the real reset, otherwise the period cadence reads "monthly".
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: monthlyPeriodMs
        )
    }

    /// A limit entry matches by `type` or `name`; the legacy plugin checked both because Z.ai's
    /// payload has used either field across revisions.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }

    /// `nextResetTime` arrives as epoch milliseconds (e.g. `1770648402389`).
    private static func epochMsToDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}
