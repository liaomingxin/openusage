import Foundation

struct ClaudeMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    /// Provider header notice (amber triangle + tooltip) riding along with this usage, e.g. the
    /// rate-limited warning. `nil` for a clean fetch.
    var warning: String?
}

enum ClaudeUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs

    static func mapUsageResponse(_ response: HTTPResponse, credentials: ClaudeOAuth, now: Date = Date()) throws -> ClaudeMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: ClaudeAuthError.tokenExpired,
            requestFailed: { ClaudeUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ClaudeUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        appendWindows(body, to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)

        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: lines
        )
    }

    /// Snapshot shown when the usage endpoint rate-limits us and there is no last-good usage to fall back
    /// on (e.g. the first fetch after launch): a status badge plus the staleness note, no live bars.
    static func rateLimitedUsage(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let waitText = retryText.map { "Rate limited, retry in ~\($0)" } ?? "Rate limited, try again later"
        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: [
                .badge(label: "Status", text: waitText, colorHex: "#F59E0B"),
                rateLimitedNote(retryAfterSeconds: retryAfterSeconds)
            ],
            warning: rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        )
    }

    /// Provider header warning (the amber triangle + tooltip) for the rate-limited state. The badge/note
    /// lines above only render when their metrics are enabled in the layout, so without this the default
    /// dashboard showed bare "No data" rows with no hint of why. Also warns the
    /// user off manual refreshes, which extend Anthropic's rate limiting.
    static func rateLimitedWarning(retryAfterSeconds: Int?) -> String {
        let base = "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse."
        guard let retryText = retryAfterSeconds.map(formatRateLimitMinutes) else { return base }
        return "\(base) Retrying in ~\(retryText)."
    }

    /// Provider warning shown on the Claude header (the amber triangle + tooltip, like Z.ai's "no coding
    /// plan" notice) when the stored login can't read live usage because it lacks the `user:profile` scope
    /// (an inference-only token, e.g. from `claude setup-token`). Without it the Session / Weekly bars just
    /// read "No data" with no hint that a re-login restores them. The scanned spend tiles are unaffected
    /// and still load.
    static let missingProfileScopeWarning = "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits."

    /// The "live usage is rate limited" note appended to a last-good snapshot so the still-shown bars are
    /// flagged as possibly stale. Shared with `rateLimitedUsage` so the wording stays in one place.
    static func rateLimitedNote(retryAfterSeconds: Int?) -> MetricLine {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let noteText = retryText.map { "Live usage rate limited - retry in ~\($0)" } ?? "Live usage rate limited - data may be stale"
        return .text(label: "Note", value: noteText)
    }

    static func parseRetryAfterSeconds(_ response: HTTPResponse, now: Date = Date()) -> Int? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return seconds
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            return max(0, Int(ceil(date.timeIntervalSince(now))))
        }
        return nil
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.titleCased(separator: { $0 == " " }, lowercasingTail: true)

        guard let tier = rateLimitTier,
              let match = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[match])"
    }

    /// The plan-wide window labels. The model-scoped weekly windows name themselves from
    /// `scope.model.display_name` instead, so a model Anthropic adds later needs no label here.
    static let sessionLabel = "Session"
    static let weeklyLabel = "Weekly"
    static let sonnetLabel = "Sonnet"

    /// The caption written under the bar of the window Anthropic reports as currently binding.
    static let bindingLabel = "Binding limit"

    /// The `severity` Anthropic reports for a window it is not escalating; anything else is its own
    /// warning about that window.
    private static let normalSeverity = "normal"

    /// `limits[]` entry kinds. `weekly_scoped` is a per-model weekly window.
    private enum LimitKind {
        static let session = "session"
        static let weeklyAll = "weekly_all"
        static let weeklyScoped = "weekly_scoped"
    }

    /// One `limits[]` entry, normalized. The array is the general form of the usage windows: it
    /// carries the same percent and reset as the legacy top-level `five_hour` / `seven_day` /
    /// `seven_day_<model>` keys, plus the two things only it knows — `is_active` (which window is
    /// currently the binding one) and `severity` (Anthropic's own escalation for that window).
    private struct LimitEntry {
        var kind: String
        var percent: Double
        var resetsAt: Date?
        var severity: String?
        var isActive: Bool
        var modelName: String?
    }

    /// The usage windows, driven by `limits[]` with the legacy top-level keys as the second source.
    ///
    /// `limits[]` is the shape Anthropic maintains now — the per-model weekly windows already live
    /// only there (`seven_day_<model>` comes back null) — so every model-scoped entry becomes a row
    /// named after its model and a model Anthropic adds later arrives without a code change. The
    /// legacy keys are still sent for Session / Weekly / Sonnet, so a response whose `limits[]` omits
    /// one of those windows still gets its row from there. A window neither source reports simply has
    /// no row; that is an absent window, not a failure.
    private static func appendWindows(_ body: [String: Any], to lines: inout [MetricLine]) {
        let limits = parseLimits(body["limits"])

        appendWindow(limits.first { $0.kind == LimitKind.session }, legacy: body["five_hour"],
                     label: sessionLabel, periodDurationMs: sessionPeriodMs, to: &lines)
        appendWindow(limits.first { $0.kind == LimitKind.weeklyAll }, legacy: body["seven_day"],
                     label: weeklyLabel, periodDurationMs: weeklyPeriodMs, to: &lines)

        // Model-scoped weekly windows, in the order Anthropic lists them. A model claims one row, so a
        // repeated display name is ignored rather than rendering the same label twice.
        var scopedModels: Set<String> = []
        for entry in limits where entry.kind == LimitKind.weeklyScoped {
            guard let model = entry.modelName, scopedModels.insert(model).inserted else { continue }
            lines.append(progressLine(entry, label: model, periodDurationMs: weeklyPeriodMs))
        }
        if !scopedModels.contains(sonnetLabel) {
            appendWindow(nil, legacy: body["seven_day_sonnet"],
                         label: sonnetLabel, periodDurationMs: weeklyPeriodMs, to: &lines)
        }
    }

    /// One window's row: the `limits[]` entry when Anthropic listed it there, otherwise the legacy
    /// top-level object's `utilization`. Only the `limits[]` path can carry the binding caption —
    /// the legacy keys never said which window was in force.
    private static func appendWindow(
        _ entry: LimitEntry?,
        legacy: Any?,
        label: String,
        periodDurationMs: Int,
        to lines: inout [MetricLine]
    ) {
        if let entry {
            lines.append(progressLine(entry, label: label, periodDurationMs: periodDurationMs))
            return
        }
        guard let object = legacy as? [String: Any],
              let used = ProviderParse.number(object["utilization"])
        else {
            return
        }
        lines.append(.progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(object["resets_at"]),
            periodDurationMs: periodDurationMs
        ))
    }

    private static func progressLine(_ entry: LimitEntry, label: String, periodDurationMs: Int) -> MetricLine {
        .progress(
            label: label,
            used: entry.percent,
            limit: 100,
            format: .percent,
            resetsAt: entry.resetsAt,
            periodDurationMs: periodDurationMs,
            detail: bindingDetail(isActive: entry.isActive, severity: entry.severity)
        )
    }

    /// The caption under a window's bar when Anthropic reports that window as the binding one — the
    /// limit that will actually stop you first. Without it the dashboard shows several equal-looking
    /// bars and nothing says which is in force: a Fable window at 87% reads no differently from a
    /// Session window at 21%.
    ///
    /// `is_active` is undocumented, so nothing here leans on its shape. Each window is judged on its
    /// own flag, so an array that marks none — or several — is fine, and an entry that omits the flag
    /// reads as "not binding" rather than as an error. `severity` is Anthropic's own escalation for
    /// the same window, and rides along only on the binding row, where it is the actionable one.
    static func bindingDetail(isActive: Bool, severity: String?) -> String? {
        guard isActive else { return nil }
        guard let severity, severity.caseInsensitiveCompare(normalSeverity) != .orderedSame else {
            return bindingLabel
        }
        let words = severity.split(whereSeparator: { $0 == "_" || $0 == " " }).joined(separator: " ")
        return "\(bindingLabel) · Anthropic \(words.lowercased())"
    }

    /// `limits[]`, normalized. An element the app can't read as a window (no `kind`, no numeric
    /// `percent`) is skipped: the array is a list of windows, and a shape we don't recognize is a
    /// window we can't meter rather than a broken response.
    private static func parseLimits(_ value: Any?) -> [LimitEntry] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            guard let object = element as? [String: Any],
                  let kind = text(object["kind"]),
                  let percent = ProviderParse.number(object["percent"])
            else {
                return nil
            }
            let model = (object["scope"] as? [String: Any])?["model"] as? [String: Any]
            return LimitEntry(
                kind: kind,
                percent: percent,
                resetsAt: resetDate(object["resets_at"]),
                severity: text(object["severity"]),
                isActive: object["is_active"] as? Bool ?? false,
                modelName: text(model?["display_name"])
            )
        }
    }

    /// A trimmed non-empty string, or `nil` for a missing, non-string, or blank value.
    private static func text(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func appendExtraUsage(_ value: Any?, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let usedCents = ProviderParse.number(object["used_credits"])
        else {
            return
        }

        let used = ProviderParse.centsToDollars(usedCents)
        if let limitCents = ProviderParse.number(object["monthly_limit"]), limitCents > 0 {
            lines.append(.progress(
                label: "Extra usage spent",
                used: used,
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars
            ))
        } else if used > 0 {
            // No monthly cap: an unbounded spend, carried raw so it formats through `MetricFormatter`
            // (compact like the spend tiles, e.g. "$1.2K spent") instead of a baked full-currency string.
            lines.append(.values(label: "Extra usage spent", values: [MetricValue(number: used, kind: .dollars)]))
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let date = OpenUsageISO8601.date(from: text) {
            return date
        }
        guard let number = ProviderParse.number(value), number.isFinite else {
            return nil
        }
        let milliseconds = abs(number) < 1e10 ? number * 1000 : number
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func formatRateLimitMinutes(_ seconds: Int) -> String {
        guard seconds > 0 else { return "now" }
        return "\(Int(ceil(Double(seconds) / 60)))m"
    }

}

private enum HTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

