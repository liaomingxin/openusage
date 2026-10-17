import XCTest
@testable import OpenUsage

final class KimiQuotaResponseTests: XCTestCase {
    func testCurrentResponseKeepsMonthlyPoolsSeparateAndUsesPreciseSessionRatio() throws {
        let mapped = try map(#"""
        {
          "limits": [{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                      "detail":{"limit":"100","used":"49","remaining":"51"}}],
          "usages": {
            "limit_5h":{"used_ratio":0.4929,"reset_time":"2026-10-17T19:25:50Z"},
            "limit_month_total":{"used_ratio":0.8966,"reset_time":"2026-10-21T00:00:00Z"},
            "limit_month_code":{"used_ratio":0.8333,"reset_time":"2026-10-21T00:00:00Z"}
          },
          "booster_wallet":{"status":"STATUS_DISABLED","balance":{"type":"BOOSTER"}}
        }
        """#)

        let session = try progress(mapped, label: "Session")
        let total = try progress(mapped, label: "Monthly Total")
        let coding = try progress(mapped, label: "Monthly Coding")
        XCTAssertEqual(session.used, 49.29, accuracy: 0.0001)
        XCTAssertEqual(total.used, 89.66, accuracy: 0.0001)
        XCTAssertEqual(coding.used, 83.33, accuracy: 0.0001)
        XCTAssertEqual(total.reset, OpenUsageISO8601.date(from: "2026-10-21T00:00:00Z"))
        // Only a reset instant is supplied: don't invent a 30-day period for quota pacing.
        XCTAssertNil(total.period)
        XCTAssertNil(mapped.lines.first { $0.label == "Weekly" })
        XCTAssertNil(mapped.lines.first { $0.label == "Booster" })
    }

    func testZeroedSummaryCannotEraseNonzeroLegacyCounters() throws {
        let mapped = try map(#"""
        {
          "usage":{"limit":"100","used":"85","remaining":"15"},
          "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                     "detail":{"limit":"100","used":"8","remaining":"92"}}],
          "usages":{"limit_5h":{"used_ratio":0},"limit_7d":{"used_ratio":0}}
        }
        """#)

        XCTAssertEqual(try progress(mapped, label: "Session").used, 8)
        XCTAssertEqual(try progress(mapped, label: "Weekly").used, 85)
    }

    func testWrappedQuotaResponsePreservesResetAndAbsentMonthlyPools() throws {
        let mapped = try map(#"""
        {"code":0,"data":{"kind":"ok","quota":{"usages":{
          "limit5h":{"usedRatio":0.25,"resetAt":"2026-10-18T01:00:00Z"},
          "limit7d":{"usedRatio":0.5,"resetAt":"2026-10-21T01:00:00Z"}
        }}}}
        """#)

        let session = try progress(mapped, label: "Session")
        XCTAssertEqual(session.used, 25)
        XCTAssertEqual(session.reset, OpenUsageISO8601.date(from: "2026-10-18T01:00:00Z"))
        XCTAssertEqual(try progress(mapped, label: "Weekly").used, 50)
        XCTAssertNil(mapped.lines.first { $0.label == "Monthly Total" })
        XCTAssertNil(mapped.lines.first { $0.label == "Monthly Coding" })
    }

    func testUnusableRatioDoesNotCreateAnUnusedMonthlyAllowance() throws {
        let mapped = try map(#"""
        {"usages":{
          "limit_5h":{"used_ratio":0.75},
          "limit_month_total":{"used_ratio":-1},
          "limit_month_code":{"reset_time":"2026-10-21T00:00:00Z"}
        }}
        """#)

        XCTAssertEqual(try progress(mapped, label: "Session").used, 75)
        XCTAssertNil(mapped.lines.first { $0.label == "Monthly Total" })
        XCTAssertNil(mapped.lines.first { $0.label == "Monthly Coding" })
    }

    private func map(_ json: String) throws -> KimiMappedUsage {
        try KimiUsageMapper.map(HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)))
    }

    private func progress(
        _ mapped: KimiMappedUsage, label: String
    ) throws -> (used: Double, reset: Date?, period: Int?) {
        let line = try XCTUnwrap(mapped.lines.first { $0.label == label })
        guard case .progress(_, let used, _, _, let reset, let period, _, _) = line else {
            XCTFail("Expected a quota meter for \(label)")
            throw KimiUsageError.invalidResponse
        }
        return (used, reset, period)
    }
}
