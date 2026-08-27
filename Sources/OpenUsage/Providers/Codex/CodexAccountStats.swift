import Foundation

/// OpenAI's own account-wide usage rollup — the `stats` block of
/// `GET /backend-api/wham/profiles/me`, behind the Account Trend, Lifetime Tokens, Day Streak and
/// Threads rows.
///
/// Three properties shape every consumer:
///
/// - **Account-wide, not machine-local.** It covers every Mac the user codes on, while Codex's Usage
///   Trend and spend tiles are scanned from *this* Mac's session logs. The two are never merged or
///   swapped: this type deliberately never becomes a `ProviderUsageHistory`, so it cannot reach the
///   spend tiles, the iCloud sync file, or the Total Spend card.
/// - **A daily batch, not live.** `statsAsOf` is the last day the rollup covers — normally yesterday —
///   so it always lags the local scanner by about a day and never carries today's tokens. The rows say
///   so, and the chart stops at that day rather than drawing an empty bar for today.
/// - **Tokens only.** The payload carries no dollar figure anywhere, so nothing here can feed a spend
///   or dollar row.
struct CodexAccountStats: Equatable, Sendable {
    /// `yyyy-MM-dd` day key → tokens, for the days the rollup reports. Sparse: only days inside the
    /// rollup's own window appear, and a day it covers but omits had no usage.
    var tokensByDay: [String: Int]
    var lifetimeTokens: Int?
    var currentStreakDays: Int?
    var totalThreads: Int?
    /// `metadata.stats_as_of` as a `yyyy-MM-dd` day key: the last day the rollup counted. Nothing after
    /// it is known yet.
    var statsAsOf: String?

    init(
        tokensByDay: [String: Int] = [:],
        lifetimeTokens: Int? = nil,
        currentStreakDays: Int? = nil,
        totalThreads: Int? = nil,
        statsAsOf: String? = nil
    ) {
        self.tokensByDay = tokensByDay
        self.lifetimeTokens = lifetimeTokens
        self.currentStreakDays = currentStreakDays
        self.totalThreads = totalThreads
        self.statsAsOf = statsAsOf
    }

    /// True when nothing usable came back — every row would be absent, so the caller can skip mapping.
    var isEmpty: Bool {
        tokensByDay.isEmpty && lifetimeTokens == nil && currentStreakDays == nil && totalThreads == nil
    }
}

enum CodexAccountStatsParser {
    /// Parses the profile response into the numbers OpenUsage renders.
    ///
    /// **Privacy boundary.** The same response carries a `profile` object — username, display name and
    /// an avatar URL. That is identity, not usage: it is never read here, never decoded into a model,
    /// and never logged. Only the numeric `stats` fields and `metadata.stats_as_of` named below leave
    /// this function, so nothing identifying can reach a row, the local API, or the log file.
    ///
    /// Returns `nil` — with a log line, never silently — when the response can't be used at all: a
    /// non-2xx status, a body that isn't JSON, a payload with no `stats` block, or a rollup OpenAI
    /// itself reports as failed (`metadata.stats_error`). This endpoint is supplementary, so the
    /// caller degrades to the rows it already has rather than failing the whole Codex refresh.
    /// A *missing individual field* is not an error: that row simply doesn't render.
    static func parse(_ response: HTTPResponse) -> CodexAccountStats? {
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("codex"),
                        "account stats unavailable: profile request returned \(response.statusCode)")
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            AppLog.warn(LogTag.plugin("codex"), "account stats unavailable: profile response wasn't JSON")
            return nil
        }

        let metadata = body["metadata"] as? [String: Any]
        // OpenAI reports a failed rollup in-band with a 200. Say so rather than rendering the partial
        // (or stale) numbers that ride along with it. The error text itself isn't logged — it's an
        // upstream string we don't control and don't need.
        if let statsError = metadata?["stats_error"], !(statsError is NSNull) {
            AppLog.warn(LogTag.plugin("codex"), "account stats unavailable: the profile endpoint reported a stats error")
            return nil
        }

        guard let stats = body["stats"] as? [String: Any] else {
            AppLog.warn(LogTag.plugin("codex"), "account stats unavailable: profile response carried no stats block")
            return nil
        }

        return CodexAccountStats(
            tokensByDay: tokensByDay(stats["daily_usage_buckets"]),
            lifetimeTokens: count(stats["lifetime_tokens"]),
            currentStreakDays: count(stats["current_streak_days"]),
            totalThreads: count(stats["total_threads"]),
            statsAsOf: dayKey(metadata?["stats_as_of"])
        )
    }

    /// `daily_usage_buckets` → day key → tokens. Each element is `{ start_date, tokens }`; an element
    /// that isn't a dictionary, names no parseable day, or carries no numeric token count is skipped
    /// rather than discarding its valid siblings. Two elements on the same day are summed, so a shape
    /// change that splits a day can't silently halve it.
    private static func tokensByDay(_ value: Any?) -> [String: Int] {
        guard let entries = value as? [Any] else { return [:] }
        var result: [String: Int] = [:]
        for case let entry as [String: Any] in entries {
            guard let day = dayKey(entry["start_date"]), let tokens = count(entry["tokens"]) else { continue }
            result[day, default: 0] += tokens
        }
        return result
    }

    /// A non-negative whole number, or `nil` for an absent / null / non-numeric / negative field.
    private static func count(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number >= 0 else { return nil }
        return Int(number.rounded(.down))
    }

    /// A `yyyy-MM-dd` day key from an upstream date string. The payload's dates are already plain
    /// calendar days (`"2026-08-26"`); an ISO-8601 instant is tolerated by taking its leading date.
    private static func dayKey(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let match = raw.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
        else {
            return nil
        }
        return String(raw[match])
    }
}
