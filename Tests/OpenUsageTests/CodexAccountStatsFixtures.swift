import Foundation
@testable import OpenUsage

/// Payloads for Codex's `GET /backend-api/wham/profiles/me`, shared by the parser/mapper tests and the
/// provider-level tests.
enum CodexAccountStatsFixtures {
    /// The identity fields the real payload carries and OpenUsage must never read. Kept as constants so
    /// a test can assert they don't appear anywhere in the mapped rows.
    static let redactedUsername = "redacted-username"
    static let redactedDisplayName = "Redacted Person"
    static let redactedAvatarURL = "https://example.invalid/redacted-avatar.png"

    /// The shape of a real response, redacted: the `profile` block's identity fields are placeholders,
    /// and the token counts are scaled-down stand-ins. Structure, key names and field types match what
    /// the live endpoint returned on 2026-08-26, including blocks OpenUsage doesn't read
    /// (`top_invocations`, the cumulative and weekly buckets), which exercises unknown-field tolerance.
    ///
    /// Days are sparse on purpose: 08-20 and 08-23 are missing inside the covered range.
    static func responseBody(
        statsAsOf: String? = "2026-08-26",
        statsError: String? = nil,
        lifetimeTokens: Any? = 1_588_515_077,
        currentStreakDays: Any? = 11,
        totalThreads: Any? = 514,
        dailyBuckets: [Any]? = nil
    ) -> Data {
        var stats: [String: Any] = [
            "peak_daily_tokens": 208_441_148,
            "longest_streak_days": 11,
            "longest_running_turn_sec": 5373,
            "fast_mode_usage_percentage": 63.92,
            "total_skills_used": 322,
            "unique_skills_used": 58,
            "most_used_reasoning_effort": "xhigh",
            "most_used_reasoning_effort_percentage": 41.45,
            "daily_usage_buckets": dailyBuckets ?? defaultDailyBuckets,
            "cumulative_daily_usage_buckets": [["start_date": "2026-08-19", "tokens": 1_737_922]],
            "weekly_usage_buckets": [["start_date": "2026-08-24", "tokens": 9_000_000]],
            "top_invocations": [["type": "skill", "skill_name": "redacted-skill", "usage_count": 51]],
            "workspace_rank": NSNull(),
            "workspace_total_user_count": NSNull()
        ]
        if let lifetimeTokens { stats["lifetime_tokens"] = lifetimeTokens }
        if let currentStreakDays { stats["current_streak_days"] = currentStreakDays }
        if let totalThreads { stats["total_threads"] = totalThreads }

        var metadata: [String: Any] = [
            "generated_at": "2026-08-26T21:20:01Z",
            "stats_error": statsError ?? NSNull()
        ]
        if let statsAsOf { metadata["stats_as_of"] = statsAsOf }

        let body: [String: Any] = [
            "profile": [
                "username": redactedUsername,
                "display_name": redactedDisplayName,
                "profile_picture_url": redactedAvatarURL
            ],
            "stats": stats,
            "metadata": metadata
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func response(
        statusCode: Int = 200,
        statsAsOf: String? = "2026-08-26",
        statsError: String? = nil,
        lifetimeTokens: Any? = 1_588_515_077,
        currentStreakDays: Any? = 11,
        totalThreads: Any? = 514,
        dailyBuckets: [Any]? = nil
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: [:],
            body: responseBody(
                statsAsOf: statsAsOf,
                statsError: statsError,
                lifetimeTokens: lifetimeTokens,
                currentStreakDays: currentStreakDays,
                totalThreads: totalThreads,
                dailyBuckets: dailyBuckets
            )
        )
    }

    /// Buckets around the fixed 2026-08-26 `stats_as_of`, with two covered days deliberately absent.
    static var defaultDailyBuckets: [Any] { [
        ["start_date": "2026-08-19", "tokens": 4_000_000],
        ["start_date": "2026-08-21", "tokens": 6_500_000],
        ["start_date": "2026-08-22", "tokens": 1_200_000],
        ["start_date": "2026-08-24", "tokens": 9_800_000],
        ["start_date": "2026-08-25", "tokens": 3_300_000],
        ["start_date": "2026-08-26", "tokens": 7_100_000]
    ] }
}
