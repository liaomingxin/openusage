import XCTest
@testable import OpenUsage

/// `/api/oauth/usage`'s `limits[]` array drives the Claude usage windows: it carries the same
/// percent and reset the legacy top-level keys do, plus `is_active` (which window is currently
/// binding) and `severity` (Anthropic's own escalation). These cover the array present, the array
/// absent, and the malformed shapes the mapper tolerates.
final class ClaudeLimitsWindowTests: XCTestCase {
    /// Redacted shape of a live Max-plan response: Session and Weekly quiet, the scoped Fable window
    /// at 87% and the one Anthropic marks active. That is the case the dashboard could not show
    /// before — three equal-looking bars with no hint which one actually stops you.
    private static let liveShape = """
    {
      "five_hour":  { "utilization": 21, "resets_at": "2099-01-01T00:00:00.000Z" },
      "seven_day":  { "utilization": 54, "resets_at": "2099-01-08T00:00:00.000Z" },
      "seven_day_sonnet": null,
      "seven_day_opus": null,
      "limits": [
        { "kind": "session", "group": "session", "percent": 21, "severity": "normal",
          "resets_at": "2099-01-01T00:00:00.000Z", "scope": null, "is_active": false },
        { "kind": "weekly_all", "group": "weekly", "percent": 54, "severity": "normal",
          "resets_at": "2099-01-08T00:00:00.000Z", "scope": null, "is_active": false },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 87, "severity": "warning",
          "resets_at": "2099-01-08T00:00:00.000Z",
          "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null },
          "is_active": true }
      ]
    }
    """

    func testDrivesEveryWindowFromLimitsAndCaptionsTheBindingOne() throws {
        let mapped = try map(Self.liveShape)

        XCTAssertEqual(progress(mapped, "Session")?.used, 21)
        XCTAssertEqual(progress(mapped, "Weekly")?.used, 54)
        XCTAssertEqual(progress(mapped, "Fable")?.used, 87)
        XCTAssertEqual(progress(mapped, "Session")?.periodDurationMs, ClaudeUsageMapper.sessionPeriodMs)
        XCTAssertEqual(progress(mapped, "Weekly")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
        XCTAssertEqual(
            progress(mapped, "Fable")?.resetsAt,
            OpenUsageISO8601.date(from: "2099-01-08T00:00:00.000Z")
        )

        // Only the window Anthropic marks active is captioned, and its caption carries Anthropic's own
        // severity for that same window.
        XCTAssertEqual(progress(mapped, "Fable")?.detail, "Binding limit · Anthropic warning")
        XCTAssertNil(progress(mapped, "Session")?.detail)
        XCTAssertNil(progress(mapped, "Weekly")?.detail)
    }

    /// The array is read generically, so a model-scoped weekly window for a model this build has never
    /// heard of still becomes a row named after the model. (Only Fable and Sonnet have a dashboard
    /// widget today, so a brand-new model still needs a descriptor before it renders — but the usage
    /// itself is no longer dropped.)
    func testPicksUpEveryModelScopedWindowIncludingUnknownModels() throws {
        let mapped = try map("""
        {
          "seven_day_sonnet": { "utilization": 5 },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 87, "severity": "warning",
              "scope": { "model": { "display_name": "Fable" } }, "is_active": true },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 12, "severity": "normal",
              "scope": { "model": { "display_name": "Sonnet" } }, "is_active": false },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 3, "severity": "normal",
              "scope": { "model": { "display_name": "Cinder Cove" } }, "is_active": false }
          ]
        }
        """)

        XCTAssertEqual(progress(mapped, "Fable")?.used, 87)
        XCTAssertEqual(progress(mapped, "Cinder Cove")?.used, 3)
        // Sonnet comes from the array, not from the legacy `seven_day_sonnet` key, and only once.
        XCTAssertEqual(progress(mapped, "Sonnet")?.used, 12)
        XCTAssertEqual(mapped.lines.filter { $0.label == "Sonnet" }.count, 1)
    }

    /// The field absent: no `limits[]` at all. The legacy top-level keys still carry Session, Weekly
    /// and Sonnet, so the rows stand — they just have nothing to say about which one binds.
    func testFallsBackToLegacyWindowKeysWhenLimitsIsAbsent() throws {
        let mapped = try map("""
        {
          "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
          "seven_day": { "utilization": 20, "resets_at": "2099-01-08T00:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 5, "resets_at": "2099-01-08T00:00:00.000Z" }
        }
        """)

        XCTAssertEqual(progress(mapped, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped, "Weekly")?.used, 20)
        XCTAssertEqual(progress(mapped, "Sonnet")?.used, 5)
        for label in ["Session", "Weekly", "Sonnet"] {
            XCTAssertNil(progress(mapped, label)?.detail)
        }
    }

    /// A `limits[]` that lists only the scoped window still leaves Session and Weekly to the legacy
    /// keys, so a partial array can't blank the two headline meters.
    func testLegacyKeysCoverWindowsTheArrayOmits() throws {
        let mapped = try map("""
        {
          "five_hour": { "utilization": 33 },
          "seven_day": { "utilization": 44 },
          "limits": [
            { "kind": "weekly_scoped", "percent": 71,
              "scope": { "model": { "display_name": "Fable" } }, "is_active": true }
          ]
        }
        """)

        XCTAssertEqual(progress(mapped, "Session")?.used, 33)
        XCTAssertEqual(progress(mapped, "Weekly")?.used, 44)
        XCTAssertEqual(progress(mapped, "Fable")?.detail, "Binding limit")
    }

    /// `is_active` is undocumented, so nothing assumes exactly one active window — every entry is
    /// judged on its own flag and each active one is captioned.
    func testCaptionsEveryActiveWindowIndependently() throws {
        let mapped = try map("""
        {
          "limits": [
            { "kind": "session", "percent": 96, "severity": "warning", "is_active": true },
            { "kind": "weekly_all", "percent": 91, "severity": "warning", "is_active": true }
          ]
        }
        """)

        XCTAssertEqual(progress(mapped, "Session")?.detail, "Binding limit · Anthropic warning")
        XCTAssertEqual(progress(mapped, "Weekly")?.detail, "Binding limit · Anthropic warning")
    }

    func testBindingCaptionWording() {
        XCTAssertNil(ClaudeUsageMapper.bindingDetail(isActive: false, severity: "warning"))
        XCTAssertEqual(ClaudeUsageMapper.bindingDetail(isActive: true, severity: nil), "Binding limit")
        XCTAssertEqual(ClaudeUsageMapper.bindingDetail(isActive: true, severity: "normal"), "Binding limit")
        XCTAssertEqual(ClaudeUsageMapper.bindingDetail(isActive: true, severity: "NORMAL"), "Binding limit")
        XCTAssertEqual(
            ClaudeUsageMapper.bindingDetail(isActive: true, severity: "warning"),
            "Binding limit · Anthropic warning"
        )
        // An unfamiliar severity is reported as Anthropic worded it rather than being swallowed.
        XCTAssertEqual(
            ClaudeUsageMapper.bindingDetail(isActive: true, severity: "spend_limit_reached"),
            "Binding limit · Anthropic spend limit reached"
        )
    }

    /// Malformed shapes: `limits` that isn't an array, elements that aren't objects, entries with no
    /// `kind` or no numeric `percent`, a null scope, a null model, a non-boolean `is_active`, and a
    /// blank `severity`. None of these is an error — each just means "no window here" — so the good
    /// entry and the legacy keys still map.
    func testToleratesMalformedLimitsShapes() throws {
        let notAnArray = try map(#"{"five_hour":{"utilization":7},"limits":{"kind":"session"}}"#)
        XCTAssertEqual(progress(notAnArray, "Session")?.used, 7)
        XCTAssertNil(progress(notAnArray, "Session")?.detail)

        let mapped = try map("""
        {
          "five_hour": { "utilization": 7 },
          "limits": [
            "weekly_all",
            { "percent": 50, "is_active": true },
            { "kind": "weekly_all", "percent": null, "is_active": true },
            { "kind": "weekly_scoped", "percent": 60, "scope": null, "is_active": true },
            { "kind": "weekly_scoped", "percent": 61, "scope": { "model": null }, "is_active": true },
            { "kind": "weekly_scoped", "percent": 62, "scope": { "model": { "display_name": "  " } } },
            { "kind": "session", "percent": 40, "severity": "", "is_active": "yes" }
          ]
        }
        """)

        // The array named no usable weekly window, so Weekly has no row at all.
        XCTAssertNil(progress(mapped, "Weekly"))
        // A scoped entry with no readable model name can't be titled, so it produces no row either.
        XCTAssertEqual(mapped.lines.filter { $0.label.hasPrefix("weekly") }.count, 0)
        // The session entry is well-formed apart from a non-boolean `is_active` and a blank severity:
        // it maps, and reads as "not binding" rather than throwing.
        XCTAssertEqual(progress(mapped, "Session")?.used, 40)
        XCTAssertNil(progress(mapped, "Session")?.detail)
    }

    private func map(_ json: String) throws -> ClaudeMappedUsage {
        try ClaudeUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)),
            credentials: ClaudeOAuth(subscriptionType: "max")
        )
    }

    private func progress(
        _ mapped: ClaudeMappedUsage,
        _ label: String
    ) -> (used: Double, resetsAt: Date?, periodDurationMs: Int?, detail: String?)? {
        guard case .progress(_, let used, _, _, let resetsAt, let periodDurationMs, _, let detail) =
                mapped.lines.first(where: { $0.label == label })
        else {
            return nil
        }
        return (used, resetsAt, periodDurationMs, detail)
    }
}
