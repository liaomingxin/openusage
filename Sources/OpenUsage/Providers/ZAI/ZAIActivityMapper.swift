import Foundation

/// Time handling for the two Z.ai usage-history endpoints.
///
/// Both take `startTime` / `endTime` as wall-clock strings (`yyyy-MM-dd HH:mm:ss`) with no zone —
/// epoch milliseconds are rejected — and answer with bucket labels in the same clock. That clock is
/// the server's, Beijing time, so requests are formatted and labels parsed in `Asia/Shanghai`
/// regardless of where the Mac is.
enum ZAITime {
    static let serverTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// An instant as the server's wall clock, the only format the endpoints accept.
    static func requestString(_ date: Date) -> String {
        formatter(format: "yyyy-MM-dd HH:mm:ss").string(from: date)
    }

    /// `base` with the range query the two history endpoints expect.
    static func rangeURL(_ base: URL, start: Date, end: Date) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: requestString(start)),
            URLQueryItem(name: "endTime", value: requestString(end))
        ]
        return components.url ?? base
    }

    /// The calendar day a bucket label belongs to.
    ///
    /// Z.ai picks the bucket size itself: a range up to seven days comes back hourly
    /// (`2026-08-26 03:00`), anything longer comes back as whole days (`2026-08-26`). An hourly bucket
    /// is a real instant, so it is converted into the Mac's own calendar day. A daily bucket is
    /// already a whole day on the server's Beijing calendar — re-labelling it in another zone would
    /// invent precision the payload doesn't have — so its label is used as the key unchanged.
    static func dayKey(forBucketLabel label: String, calendar: Calendar = .current) -> String? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return text
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let date = formatter(format: format).date(from: text) {
                return DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
            }
        }
        return nil
    }

    private static func formatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = serverTimeZone
        formatter.dateFormat = format
        return formatter
    }
}

/// One parsed `model-usage` response: tokens and calls per calendar day, the per-model daily split,
/// and the window totals Z.ai reports for the requested range.
struct ZAIModelActivity: Equatable, Sendable {
    var tokensByDay: [String: Int] = [:]
    var callsByDay: [String: Int] = [:]
    var modelUsage: ModelUsageSeries = ModelUsageSeries(daily: [])
    var totalTokens: Int = 0
    var totalCalls: Int = 0

    var dayKeys: Set<String> { Set(tokensByDay.keys).union(callsByDay.keys) }

    /// The per-day token series the shared trend chart consumes.
    var series: DailyUsageSeries {
        DailyUsageSeries(daily: tokensByDay.sorted { $0.key < $1.key }
            .map { DailyUsageEntry(date: $0.key, totalTokens: $0.value, costUSD: nil) })
    }
}

/// One parsed `tool-usage` response: the MCP call counts Z.ai meters separately from tokens.
struct ZAIToolActivity: Equatable, Sendable {
    var webSearches: Int
    var webReads: Int
    var zreadCalls: Int
}

/// Builds the Z.ai usage-history rows — Usage Trend, Today / Yesterday / Last 30 Days, and MCP Tools —
/// from the `model-usage` and `tool-usage` endpoints.
///
/// Both endpoints are the undocumented internal APIs Z.ai's own usage dashboard calls, and both are
/// best-effort here: a failure leaves these rows absent ("No data") and never touches the quota
/// meters. The mapper is pure, so it tests against captured payloads like the rest of the provider.
enum ZAIActivityMapper {
    /// How far back the trend and the Last 30 Days row look — today plus the previous 30 calendar days,
    /// the same window every other provider's trend uses.
    static let trendWindowDays = UsageHistoryWindow.previousDays

    /// How far back the Today / Yesterday rows look. Z.ai only returns hourly buckets for ranges up to
    /// seven days, and only hourly buckets can be attributed to the Mac's own calendar days, so those
    /// two rows come from their own short request. Three days covers the user's yesterday from any
    /// time zone.
    static let recentWindowDays = 3

    /// Start of the 30-day window: midnight, `trendWindowDays` ago, in the Mac's calendar.
    static func trendWindowStart(now: Date, calendar: Calendar = .current) -> Date {
        windowStart(days: trendWindowDays, now: now, calendar: calendar)
    }

    /// Start of the short window backing Today / Yesterday.
    static func recentWindowStart(now: Date, calendar: Calendar = .current) -> Date {
        windowStart(days: recentWindowDays, now: now, calendar: calendar)
    }

    private static func windowStart(days: Int, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }

    /// The source note shown under the model-breakdown popover and the trend chart. Names the account's
    /// platform so a China-platform card doesn't claim its numbers came from z.ai.
    static func sourceNote(for platform: ZAIPlatform) -> String {
        "From your \(platform.apiHost) usage history"
    }

    // MARK: - Parsing

    /// Tokens, calls, and the per-model split from a `model-usage` payload. Returns `nil` when the body
    /// isn't a usable response — the caller then leaves these rows absent rather than showing zeros.
    static func parseModelUsage(_ body: Data, calendar: Calendar = .current) -> ZAIModelActivity? {
        guard let data = payload(body) else { return nil }
        guard let labels = data["x_time"] as? [Any] else { return nil }

        let dayKeys = labels.map { ($0 as? String).flatMap { ZAITime.dayKey(forBucketLabel: $0, calendar: calendar) } }
        var activity = ZAIModelActivity()
        accumulate(data["tokensUsage"], into: &activity.tokensByDay, dayKeys: dayKeys)
        accumulate(data["modelCallCount"], into: &activity.callsByDay, dayKeys: dayKeys)

        var modelsByDay: [String: [String: Int]] = [:]
        for entry in (data["modelDataList"] as? [[String: Any]]) ?? [] {
            guard let name = (entry["modelName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            var perDay: [String: Int] = [:]
            accumulate(entry["tokensUsage"], into: &perDay, dayKeys: dayKeys)
            for (day, tokens) in perDay where tokens > 0 {
                modelsByDay[day, default: [:]][name, default: 0] += tokens
            }
        }
        activity.modelUsage = ModelUsageSeries(daily: modelsByDay.sorted { $0.key < $1.key }.map { day, models in
            DailyModelUsageEntry(
                date: day,
                models: models.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                    .map { ModelUsageEntry(model: $0.key, totalTokens: $0.value, costUSD: nil) }
            )
        })

        // Z.ai reports the window totals directly; they are exact for the requested range, so they win
        // over re-summing the buckets. A payload without them falls back to the sum.
        let totals = data["totalUsage"] as? [String: Any]
        activity.totalTokens = int(totals?["totalTokensUsage"]) ?? activity.tokensByDay.values.reduce(0, +)
        activity.totalCalls = int(totals?["totalModelCallCount"]) ?? activity.callsByDay.values.reduce(0, +)
        return activity
    }

    /// Web-search / web-read / ZRead totals from a `tool-usage` payload.
    static func parseToolUsage(_ body: Data) -> ZAIToolActivity? {
        guard let data = payload(body),
              let totals = data["totalUsage"] as? [String: Any]
        else { return nil }
        let searches = int(totals["totalNetworkSearchCount"])
        let reads = int(totals["totalWebReadMcpCount"])
        let zread = int(totals["totalZreadMcpCount"])
        guard searches != nil || reads != nil || zread != nil else { return nil }
        return ZAIToolActivity(webSearches: searches ?? 0, webReads: reads ?? 0, zreadCalls: zread ?? 0)
    }

    // MARK: - Lines

    /// Usage Trend, Today, Yesterday, Last 30 Days and MCP Tools, in display order.
    ///
    /// `window` is the 30-day payload (daily buckets on Z.ai's calendar) behind the trend and the
    /// Last 30 Days row; `recent` is the short hourly payload behind Today and Yesterday. Any of the
    /// three inputs may be `nil` — its rows are simply left out, so one failed endpoint can't take the
    /// others down. Periods with no usage produce no row, matching the shared spend tiles: a
    /// confident "0 tokens" would be indistinguishable from "not accounted for yet".
    static func lines(
        window: ZAIModelActivity?,
        recent: ZAIModelActivity?,
        tools: ZAIToolActivity?,
        platform: ZAIPlatform,
        now: Date,
        calendar: Calendar = .current
    ) -> [MetricLine] {
        let note = sourceNote(for: platform)
        var lines: [MetricLine] = []

        if let window {
            SpendTileMapper.appendUsageTrend(window.series, to: &lines, now: now, note: note)
        }
        if let recent {
            let today = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
                .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
            if let line = dayLine(label: "Today", day: today, activity: recent, note: note) {
                lines.append(line)
            }
            if let yesterday, let line = dayLine(label: "Yesterday", day: yesterday, activity: recent, note: note) {
                lines.append(line)
            }
        }
        if let window, window.totalTokens > 0 || window.totalCalls > 0 {
            lines.append(.values(
                label: "Last 30 Days",
                values: usageValues(tokens: window.totalTokens, calls: window.totalCalls),
                modelBreakdown: SpendTileMapper.modelBreakdown(
                    window.modelUsage,
                    days: window.dayKeys,
                    totalTokens: window.totalTokens,
                    totalCostUSD: nil,
                    sourceNote: note
                )
            ))
        }
        if let tools {
            // Unlike the token rows, a zero here is a measurement: the endpoint reports the window's
            // MCP totals authoritatively, so "0 ZRead" is real and the row shows it.
            lines.append(.values(label: "MCP Tools", values: [
                MetricValue(number: Double(tools.webSearches), kind: .count, label: "searches"),
                MetricValue(number: Double(tools.webReads), kind: .count, label: "reads"),
                MetricValue(number: Double(tools.zreadCalls), kind: .count, label: "ZRead")
            ]))
        }
        return lines
    }

    // MARK: - Private

    private static func dayLine(
        label: String,
        day: String,
        activity: ZAIModelActivity,
        note: String
    ) -> MetricLine? {
        let tokens = activity.tokensByDay[day] ?? 0
        let calls = activity.callsByDay[day] ?? 0
        guard tokens > 0 || calls > 0 else { return nil }
        return .values(
            label: label,
            values: usageValues(tokens: tokens, calls: calls),
            modelBreakdown: SpendTileMapper.modelBreakdown(
                activity.modelUsage,
                days: [day],
                totalTokens: tokens,
                totalCostUSD: nil,
                sourceNote: note
            )
        )
    }

    /// One period's activity: tokens then calls, rendered combined as "66.1M tokens · 426 calls". No
    /// dollars — a GLM Coding Plan is a flat subscription, so there is nothing to price.
    private static func usageValues(tokens: Int, calls: Int) -> [MetricValue] {
        [
            MetricValue(number: Double(tokens), kind: .count, label: "tokens"),
            MetricValue(number: Double(calls), kind: .count, label: "calls")
        ]
    }

    /// The `data` object of a 2xx response, or `nil` when the body isn't a usable success payload.
    private static func payload(_ body: Data) -> [String: Any]? {
        guard let root = ProviderParse.jsonObject(body) else { return nil }
        if (root["success"] as? Bool) == false { return nil }
        return root["data"] as? [String: Any]
    }

    /// Fold a bucket-parallel numeric array into per-day totals. Entries whose label didn't parse are
    /// skipped rather than dropped into a wrong day.
    private static func accumulate(_ raw: Any?, into totals: inout [String: Int], dayKeys: [String?]) {
        guard let values = raw as? [Any] else { return }
        for (index, value) in values.enumerated() {
            guard index < dayKeys.count, let day = dayKeys[index], let amount = int(value), amount > 0 else { continue }
            totals[day, default: 0] += amount
        }
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number.isFinite, number >= 0,
              number < Double(Int.max) else { return nil }
        return Int(number)
    }
}
