import Foundation

/// Parsing for the `credit-usage` endpoint family — the usage history Z.ai's own usage page reads for
/// credit-metered GLM Coding plans (any quota payload carrying `CREDIT_LIMIT`; see
/// `ZAIUsageMapper.isCreditPackage`). Three payloads, all in the same success envelope as the legacy
/// endpoints and all declaring their bucket `timezone` (and `granularity`) explicitly:
///
/// - `GET /api/monitor/credit-usage/activity` — the account-wide daily series and window totals behind
///   Z.ai's KPI card and heatmap. The widest accounting OpenUsage gets: it covers consumption the
///   per-model detail can't attribute, so the trend and the Last 30 Days total match what Z.ai's own
///   page shows. Feeds Usage Trend and the Last 30 Days row.
/// - `GET /api/monitor/credit-usage/usage-detail?usageType=MODEL` — per-model token buckets per day
///   (or per hour, for short ranges, so Today / Yesterday land on the Mac's calendar days). The
///   entries also carry cached-input / uncached-input / output splits Z.ai reports; OpenUsage reads
///   the combined totals. Feeds the period rows' per-model breakdowns and the day rows' totals.
/// - `GET …?usageType=MCP` — the per-tool MCP call counts. Feeds the MCP Tools row.
///
/// Unlike the legacy `model-usage` endpoint, these report no per-call counts — Z.ai dropped the figure
/// when it moved to credit metering — so everything parsed here sets `reportsCallCounts: false` and
/// the period rows carry tokens only. Pure functions, tested against captured payloads.
enum ZAICreditUsageMapper {
    /// The activity series and window totals. `nil` when the body isn't a usable success payload or
    /// carries no token series (the caller leaves the trend and the Last 30 Days row absent).
    static func parseActivity(_ body: Data, calendar: Calendar = .current) -> ZAIModelActivity? {
        guard let data = ZAIActivityMapper.payload(body),
              let series = data["series"] as? [[String: Any]] else { return nil }
        let zone = serverZone(from: data)
        var activity = ZAIModelActivity(reportsCallCounts: false)
        for entry in series {
            guard let label = entry["date"] as? String,
                  let day = ZAITime.dayKey(forBucketLabel: label, calendar: calendar, serverTimeZone: zone),
                  let tokens = ZAIActivityMapper.int(entry["totalTokens"]), tokens > 0 else { continue }
            activity.tokensByDay[day, default: 0] += tokens
        }
        guard !activity.tokensByDay.isEmpty else { return nil }
        // The summary totals are exact for the requested range; the bucket sum is the fallback.
        let summary = data["summary"] as? [String: Any]
        activity.totalTokens = ZAIActivityMapper.int(summary?["totalTokens"])
            ?? activity.tokensByDay.values.reduce(0, +)
        return activity
    }

    /// The per-model token buckets from a `usageType=MODEL` response: per-day totals, the ranked
    /// per-model split, and the window total. `nil` when the body isn't usable.
    static func parseModelDetail(_ body: Data, calendar: Calendar = .current) -> ZAIModelActivity? {
        guard let data = ZAIActivityMapper.payload(body),
              let modelUsage = data["modelUsage"] as? [String: Any],
              let labels = modelUsage["xTime"] as? [Any] else { return nil }
        let zone = serverZone(from: data)
        let dayKeys = labels.map {
            ($0 as? String).flatMap { ZAITime.dayKey(forBucketLabel: $0, calendar: calendar, serverTimeZone: zone) }
        }
        var activity = ZAIModelActivity(reportsCallCounts: false)
        var modelsByDay: [String: [String: Int]] = [:]
        for entry in (modelUsage["modelDataList"] as? [[String: Any]]) ?? [] {
            guard let name = (entry["modelName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            var perDay: [String: Int] = [:]
            ZAIActivityMapper.accumulate(entry["totalTokensUsage"], into: &perDay, dayKeys: dayKeys)
            for (day, tokens) in perDay where tokens > 0 {
                modelsByDay[day, default: [:]][name, default: 0] += tokens
                activity.tokensByDay[day, default: 0] += tokens
            }
        }
        activity.modelUsage = ZAIActivityMapper.modelSeries(from: modelsByDay)
        let totals = modelUsage["totalUsage"] as? [String: Any]
        activity.totalTokens = ZAIActivityMapper.int(totals?["totalTokens"])
            ?? activity.tokensByDay.values.reduce(0, +)
        return activity
    }

    /// The per-tool MCP call counts from a `usageType=MCP` response. `nil` when the body carries no
    /// usable MCP data (the caller leaves the row absent). A listed tool at zero calls is kept — the
    /// endpoint reports the window's totals authoritatively, like the legacy tool summary.
    static func parseMcpDetail(_ body: Data) -> ZAIToolActivity? {
        guard let data = ZAIActivityMapper.payload(body),
              let mcpUsage = data["mcpUsage"] as? [String: Any] else { return nil }
        let tools = ((mcpUsage["mcpDataList"] as? [[String: Any]]) ?? []).compactMap { entry -> ZAIToolUsageEntry? in
            guard let name = toolName(entry) else { return nil }
            let calls = ((entry["mcpCallCount"] as? [Any]) ?? [])
                .reduce(0) { $0 + (ZAIActivityMapper.int($1) ?? 0) }
            return ZAIToolUsageEntry(name: name, calls: calls)
        }
        guard !tools.isEmpty else { return nil }
        return ZAIToolActivity(webSearches: 0, webReads: 0, zreadCalls: 0, tools: tools)
    }

    /// The 30-day window the credit path feeds to the line builder: the activity endpoint's tokens
    /// (the widest accounting) with the model detail's per-model split folded in for the Last 30 Days
    /// breakdown. Either input may be `nil` on its own — the window then carries whichever half came
    /// through, and both-nil leaves the rows absent.
    static func window(totals: ZAIModelActivity?, breakdown: ZAIModelActivity?) -> ZAIModelActivity? {
        guard var merged = totals else { return breakdown }
        if let breakdown { merged.modelUsage = breakdown.modelUsage }
        return merged
    }

    // MARK: - Private

    /// The zone the payload's bucket labels are wall-clock in. The credit endpoints declare it
    /// (`"timezone": "Asia/Shanghai"`); an absent or unknown value falls back to the Beijing clock the
    /// legacy endpoints have always implied.
    private static func serverZone(from data: [String: Any]) -> TimeZone {
        guard let identifier = data["timezone"] as? String,
              let zone = TimeZone(identifier: identifier) else { return ZAITime.serverTimeZone }
        return zone
    }

    /// An MCP summary entry's display name: the English-localized name Z.ai ships, falling back to its
    /// native name and then to the bare tool code — the same chain the legacy tool summary uses.
    private static func toolName(_ entry: [String: Any]) -> String? {
        for key in ["mcpNameI18n", "mcpName", "mcpCode"] {
            if let name = (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
