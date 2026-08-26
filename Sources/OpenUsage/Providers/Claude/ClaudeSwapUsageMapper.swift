import Foundation

/// What one claude-swap slot's cache row renders as.
enum ClaudeSwapMappedUsage: Equatable, Sendable {
    /// Usable, in-date measurements. `warning` carries claude-swap's failed last poll when the stored
    /// numbers are still fresh enough to show (the amber header triangle, not an error card).
    case usage(lines: [MetricLine], warning: String?)
    /// Nothing trustworthy to show: no row, no measurement yet, or the measurement aged out. The card
    /// shows the shared "No usage data" status instead of a stale percent.
    case noData(reason: String)
    /// claude-swap's own poll failed and there is no in-date measurement behind it.
    case failure(ClaudeSwapUsageError)
}

enum ClaudeSwapUsageMapper {
    /// How long a stored measurement stays showable. claude-swap re-polls every managed account about
    /// every three minutes whenever any of its surfaces runs, so anything this old means nothing has
    /// run for hours — a percent from then is no longer worth showing as current. Matches claude-swap's
    /// own `RATE_LIMIT_TRUST_MAX_AGE_S` ceiling.
    static let freshnessWindow: TimeInterval = 2 * 60 * 60

    /// The model whose per-model weekly window OpenUsage shows, matching the Claude card's Fable row.
    static let scopedModelName = "Fable"

    /// Map one slot's row. `entry` is `nil` when claude-swap has never written the slot.
    /// `expectedOrganizationUUID` fences the row against a slot renumbering: claude-swap keys its cache
    /// by slot number, so a re-added account can inherit a number whose stored measurement belongs to a
    /// different organization. A mismatch reads as no data rather than another account's percentages.
    static func map(
        _ entry: ClaudeSwapUsageEntry?,
        expectedOrganizationUUID: String?,
        now: Date
    ) -> ClaudeSwapMappedUsage {
        guard let entry else {
            return .noData(reason: "claude-swap has not polled this account yet")
        }
        if let expected = expectedOrganizationUUID?.lowercased(),
           let stored = entry.organizationUUID?.lowercased(),
           stored != expected {
            return .noData(reason: "claude-swap's cached row belongs to another organization")
        }

        let lines = usageLines(entry)
        let isFresh = entry.fetchedAt.map { now.timeIntervalSince($0) <= freshnessWindow } ?? false
        guard entry.hasLastGood, isFresh, !lines.isEmpty else {
            if let token = entry.lastError {
                return .failure(.pollFailed(token))
            }
            guard entry.hasLastGood else {
                return .noData(reason: "claude-swap has no measurement for this account yet")
            }
            return .noData(reason: isFresh
                ? "claude-swap's stored measurement has no usage windows"
                : "claude-swap's stored measurement is more than \(Int(freshnessWindow / 3600))h old")
        }
        // Fresh numbers plus a failed last poll: claude-swap keeps the last-good measurement across a
        // failure, so the meters still stand — the failure rides along as the header's amber notice.
        return .usage(lines: lines, warning: entry.lastError.map(warningText))
    }

    static func warningText(_ token: String) -> String {
        "claude-swap's last update for this account failed. \(ClaudeSwapUsageError.pollFailed(token).localizedDescription)"
    }

    private static func usageLines(_ entry: ClaudeSwapUsageEntry) -> [MetricLine] {
        var lines: [MetricLine] = []
        if let session = entry.fiveHour {
            lines.append(progress(label: "Session", session, periodDurationMs: MetricPeriod.sessionMs))
        }
        if let weekly = entry.sevenDay {
            lines.append(progress(label: "Weekly", weekly, periodDurationMs: MetricPeriod.weekMs))
        }
        // The per-model weekly window is only present while the account has one, so an account without
        // a Fable limit simply has no Fable row.
        if let scoped = entry.scoped.first(where: { $0.name == scopedModelName }) {
            lines.append(progress(
                label: scoped.name,
                ClaudeSwapUsageEntry.Window(pct: scoped.pct, resetsAt: scoped.resetsAt),
                periodDurationMs: MetricPeriod.weekMs
            ))
        }
        return lines
    }

    private static func progress(
        label: String,
        _ window: ClaudeSwapUsageEntry.Window,
        periodDurationMs: Int
    ) -> MetricLine {
        .progress(
            label: label,
            used: window.pct,
            limit: 100,
            format: .percent,
            resetsAt: window.resetsAt,
            periodDurationMs: periodDurationMs
        )
    }
}
