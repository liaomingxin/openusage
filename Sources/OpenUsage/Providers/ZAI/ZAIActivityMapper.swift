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

    /// `base` with the range query the two history endpoints expect. `extraQueryItems` ride along
    /// after the bounds (the credit endpoints add their `type` / `usageType` selectors).
    static func rangeURL(
        _ base: URL,
        start: Date,
        end: Date,
        extraQueryItems: [URLQueryItem] = []
    ) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: requestString(start)),
            URLQueryItem(name: "endTime", value: requestString(end))
        ] + extraQueryItems
        return components.url ?? base
    }

    /// The calendar day a bucket label belongs to.
    ///
    /// Z.ai picks the bucket size itself: a range up to seven days comes back hourly
    /// (`2026-08-26 03:00`), anything longer comes back as whole days (`2026-08-26`). An hourly bucket
    /// is a real instant, so it is converted into the Mac's own calendar day. A daily bucket is
    /// already a whole day on the server's Beijing calendar — re-labelling it in another zone would
    /// invent precision the payload doesn't have — so its label is used as the key unchanged.
    /// `serverTimeZone` is the zone the labels are wall-clock in; the legacy endpoints never declare
    /// one (Beijing is assumed), the credit endpoints carry an explicit `timezone` field.
    static func dayKey(
        forBucketLabel label: String,
        calendar: Calendar = .current,
        serverTimeZone: TimeZone = serverTimeZone
    ) -> String? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return text
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let date = formatter(format: format, timeZone: serverTimeZone).date(from: text) {
                return DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
            }
        }
        return nil
    }

    private static func formatter(format: String) -> DateFormatter {
        formatter(format: format, timeZone: serverTimeZone)
    }

    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
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
    /// Whether the source meters per-call counts. The credit-plan endpoints don't (Z.ai dropped the
    /// figure when it moved to credit metering), so periods built from them carry tokens only;
    /// the legacy `model-usage` endpoint still reports them.
    var reportsCallCounts: Bool = true

    var dayKeys: Set<String> { Set(tokensByDay.keys).union(callsByDay.keys) }

    /// The per-day token series the shared trend chart consumes.
    var series: DailyUsageSeries {
        DailyUsageSeries(daily: tokensByDay.sorted { $0.key < $1.key }
            .map { DailyUsageEntry(date: $0.key, totalTokens: $0.value, costUSD: nil) })
    }
}

/// One MCP tool Z.ai names in its `tool-usage` summary: the tool's display name and the calls it
/// served over the requested window.
struct ZAIToolUsageEntry: Equatable, Sendable {
    var name: String
    var calls: Int
}

/// One parsed `tool-usage` response: the MCP call counts Z.ai meters separately from tokens.
///
/// `tools` is the named per-tool breakdown Z.ai reports in `toolSummaryList` — whichever tools the
/// account's plan actually enables, so nothing about the set is assumed here. The three scalars are
/// the older totals the same payload still carries; they back the row only when no summary list came
/// with it.
struct ZAIToolActivity: Equatable, Sendable {
    var webSearches: Int
    var webReads: Int
    var zreadCalls: Int
    var tools: [ZAIToolUsageEntry] = []
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
        activity.modelUsage = modelSeries(from: modelsByDay)

        // Z.ai reports the window totals directly; they are exact for the requested range, so they win
        // over re-summing the buckets. A payload without them falls back to the sum.
        let totals = data["totalUsage"] as? [String: Any]
        activity.totalTokens = int(totals?["totalTokensUsage"]) ?? activity.tokensByDay.values.reduce(0, +)
        activity.totalCalls = int(totals?["totalModelCallCount"]) ?? activity.callsByDay.values.reduce(0, +)
        return activity
    }

    /// The named per-tool breakdown plus the web-search / web-read / ZRead totals from a `tool-usage`
    /// payload. `nil` when the body carries neither — the caller then leaves the MCP row absent.
    static func parseToolUsage(_ body: Data) -> ZAIToolActivity? {
        guard let data = payload(body) else { return nil }
        let totals = data["totalUsage"] as? [String: Any]
        let searches = int(totals?["totalNetworkSearchCount"])
        let reads = int(totals?["totalWebReadMcpCount"])
        let zread = int(totals?["totalZreadMcpCount"])
        let tools = toolSummary(data: data, totals: totals)
        guard searches != nil || reads != nil || zread != nil || !tools.isEmpty else { return nil }
        return ZAIToolActivity(
            webSearches: searches ?? 0, webReads: reads ?? 0, zreadCalls: zread ?? 0, tools: tools
        )
    }

    /// The tools named in `toolSummaryList`, ranked by calls.
    ///
    /// Z.ai repeats the list in two places — directly on `data` and nested inside `totalUsage` — and a
    /// live capture carries both, so both are read, `data` first. Ranking is by calls (largest share
    /// first, like the model breakdown), with Z.ai's own `sortOrder` and then the name breaking ties
    /// so the list can't reshuffle between refreshes. An entry with no usable name or count is skipped
    /// rather than rendered as a nameless row; an absent list is not an error, it just leaves the row
    /// on its older three-counter reading.
    private static func toolSummary(data: [String: Any], totals: [String: Any]?) -> [ZAIToolUsageEntry] {
        let raw = (data["toolSummaryList"] as? [[String: Any]])
            ?? (totals?["toolSummaryList"] as? [[String: Any]])
            ?? []
        let ranked = raw.compactMap { entry -> (tool: ZAIToolUsageEntry, sortOrder: Int)? in
            guard let name = toolName(entry), let calls = int(entry["totalUsageCount"]) else { return nil }
            return (ZAIToolUsageEntry(name: name, calls: calls), int(entry["sortOrder"]) ?? Int.max)
        }
        return ranked.sorted {
            if $0.tool.calls != $1.tool.calls { return $0.tool.calls > $1.tool.calls }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.tool.name < $1.tool.name
        }.map(\.tool)
    }

    /// A summary entry's display name: the English-localized name Z.ai ships, falling back to its
    /// native name and then to the bare tool code, so a tool OpenUsage has never seen still gets a row.
    private static func toolName(_ entry: [String: Any]) -> String? {
        for key in ["toolNameI18n", "toolName", "toolCode"] {
            if let name = (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
        }
        return nil
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
                values: usageValues(tokens: window.totalTokens, calls: window.totalCalls,
                                    reportsCalls: window.reportsCallCounts),
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
            lines.append(mcpToolsLine(tools, note: note))
        }
        return lines
    }

    // MARK: - Private

    /// The MCP Tools row.
    ///
    /// When Z.ai names the tools, the row reads one total ("27 calls") and its value reveals the same
    /// ranked hover breakdown the period rows use — one line per named tool, sized by its share of the
    /// window's calls. The named list is whatever the plan enables, so a tool added or dropped by Z.ai
    /// shows up (or stops showing up) without a code change. A payload with no summary list keeps the
    /// older three-counter reading, which is all such a response can say.
    ///
    /// Unlike the token rows, a zero here is a measurement: the endpoint reports the window's MCP
    /// totals authoritatively, so a listed tool at "0 calls" is real and the row shows it.
    private static func mcpToolsLine(_ activity: ZAIToolActivity, note: String) -> MetricLine {
        guard !activity.tools.isEmpty else {
            return .values(label: "MCP Tools", values: [
                MetricValue(number: Double(activity.webSearches), kind: .count, label: "searches"),
                MetricValue(number: Double(activity.webReads), kind: .count, label: "reads"),
                MetricValue(number: Double(activity.zreadCalls), kind: .count, label: "ZRead")
            ])
        }
        let total = activity.tools.reduce(0) { $0 + $1.calls }
        return .values(
            label: "MCP Tools",
            values: [MetricValue(number: Double(total), kind: .count, label: "calls")],
            modelBreakdown: ModelUsageBreakdown(
                totalTokens: total,
                totalCostUSD: nil,
                models: activity.tools.map {
                    ModelUsageEntry(model: $0.name, totalTokens: $0.calls, costUSD: nil)
                },
                sourceNote: note,
                unitLabel: "calls"
            )
        )
    }

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
            values: usageValues(tokens: tokens, calls: calls, reportsCalls: activity.reportsCallCounts),
            modelBreakdown: SpendTileMapper.modelBreakdown(
                activity.modelUsage,
                days: [day],
                totalTokens: tokens,
                totalCostUSD: nil,
                sourceNote: note
            )
        )
    }

    /// One period's activity: tokens then — when the source reports them — calls, rendered combined
    /// as "66.1M tokens · 426 calls". Credit-plan periods carry tokens alone ("66.1M tokens"):
    /// Z.ai's credit accounting dropped call counts, so inventing a "· 0 calls" would read as a real
    /// measurement. No dollars — a GLM Coding Plan is a flat subscription, so there is nothing to price.
    private static func usageValues(tokens: Int, calls: Int, reportsCalls: Bool) -> [MetricValue] {
        var values = [MetricValue(number: Double(tokens), kind: .count, label: "tokens")]
        if reportsCalls {
            values.append(MetricValue(number: Double(calls), kind: .count, label: "calls"))
        }
        return values
    }

    /// The `data` object of a 2xx response, or `nil` when the body isn't a usable success payload.
    /// Shared with the credit-usage parsers, which answer in the same envelope.
    static func payload(_ body: Data) -> [String: Any]? {
        guard let root = ProviderParse.jsonObject(body) else { return nil }
        if (root["success"] as? Bool) == false { return nil }
        return root["data"] as? [String: Any]
    }

    /// A non-negative finite integer read of a JSON value (number or numeric string). Shared with the
    /// credit-usage parsers.
    static func int(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number.isFinite, number >= 0,
              number < Double(Int.max) else { return nil }
        return Int(number)
    }

    /// Fold a bucket-parallel numeric array into per-day totals. Entries whose label didn't parse are
    /// skipped rather than dropped into a wrong day. Shared with the credit-usage parsers.
    static func accumulate(_ raw: Any?, into totals: inout [String: Int], dayKeys: [String?]) {
        guard let values = raw as? [Any] else { return }
        for (index, value) in values.enumerated() {
            guard index < dayKeys.count, let day = dayKeys[index], let amount = int(value), amount > 0 else { continue }
            totals[day, default: 0] += amount
        }
    }

    /// The ranked per-day model series every `modelDataList`-shaped payload normalizes into — used by
    /// both the legacy and the credit-usage model parsers.
    static func modelSeries(from modelsByDay: [String: [String: Int]]) -> ModelUsageSeries {
        ModelUsageSeries(daily: modelsByDay.sorted { $0.key < $1.key }.map { day, models in
            DailyModelUsageEntry(
                date: day,
                models: models.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                    .map { ModelUsageEntry(model: $0.key, totalTokens: $0.value, costUSD: nil) }
            )
        })
    }
}
