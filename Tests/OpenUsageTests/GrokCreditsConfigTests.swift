import XCTest
@testable import OpenUsage

final class GrokCreditsConfigDecoderTests: XCTestCase {
    func testDecodesLiveCapturedResponse() throws {
        let config = try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.capturedResponseBody)

        XCTAssertEqual(config.periodType, GrokCreditsConfigDecoder.weeklyPeriodType)
        XCTAssertEqual(config.usedPercent, 99.0)
        XCTAssertEqual(config.periodStart.timeIntervalSince1970,
                       GrokCreditsFixtures.capturedPeriodStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(config.periodEnd.timeIntervalSince1970,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(config.periodDurationMs, 7 * 24 * 60 * 60 * 1000)
    }

    func testAbsentZeroValuedFieldsDecodeAsZero() throws {
        // proto-JSON drops zero-valued fields: a fresh weekly period omits `creditUsagePercent`
        // and a disabled cap omits `onDemandCap`. Those are genuine zeros, never schema errors.
        let noPercent = try GrokCreditsConfigDecoder.decode(
            responseBody: GrokCreditsFixtures.responseBody(percent: nil)
        )
        XCTAssertEqual(noPercent.usedPercent, 0)

        let noCap = try GrokCreditsConfigDecoder.decode(
            responseBody: GrokCreditsFixtures.responseBody(onDemandCap: nil)
        )
        XCTAssertEqual(noCap.onDemandCap, 0)
    }

    func testRejectsNonNumericFields() {
        // A present but non-numeric value is a schema change, not a 0 — clamping it to a
        // believable "0" would hide the drift.
        for body in [
            GrokCreditsFixtures.responseBody(percent: "high"),
            GrokCreditsFixtures.responseBody(onDemandCap: "lots")
        ] {
            XCTAssertThrowsError(try GrokCreditsConfigDecoder.decode(responseBody: body)) { error in
                XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
            }
        }
    }

    func testDecodesProductUsageFromLiveCapturedResponse() throws {
        let config = try GrokCreditsConfigDecoder.decode(
            responseBody: GrokCreditsFixtures.capturedResponseBodyWithProductUsage
        )

        XCTAssertEqual(config.productUsage, [
            GrokProductUsage(product: "GrokBuild", usedPercent: 4),
            GrokProductUsage(product: "GrokChat", usedPercent: 1),
            // proto-JSON omits `usagePercent` at 0, so these two are genuine zeros.
            GrokProductUsage(product: "GrokAppBuilder", usedPercent: 0),
            GrokProductUsage(product: "GrokImagine", usedPercent: 0)
        ], "entries decode in API order, names untouched")
    }

    func testDecodesUnknownProductNames() throws {
        // The product set is undocumented and grows; a name nothing has seen before decodes like any
        // other, so it can reach the row without a code change.
        let config = try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(
            productUsage: [GrokCreditsFixtures.productEntry("GrokSomethingNew", percent: 12.5)]
        ))
        XCTAssertEqual(config.productUsage, [GrokProductUsage(product: "GrokSomethingNew", usedPercent: 12.5)])
    }

    func testAbsentProductUsageDecodesAsEmpty() throws {
        // The 2026-07 capture predates the field entirely — an older account shape, not an error.
        let config = try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.capturedResponseBody)
        XCTAssertEqual(config.productUsage, [])
    }

    func testRejectsProductUsageThatIsNotAnArray() {
        // The field is optional, but a present one of the wrong type is real schema drift.
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(
                responseBody: GrokCreditsFixtures.responseBody(productUsage: ["GrokBuild": 4.0])
            )
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testSkipsUnusableProductEntriesWithoutFailingTheResponse() throws {
        // One bad slice must not blank the Weekly meter, so unusable entries drop out (logged) and
        // everything else still decodes: an entry that isn't an object, one with no product name (how
        // proto-JSON expresses a default enum value), one with a non-numeric percent, and one that is
        // non-finite (proto-JSON spells infinity as the string "Infinity").
        let config = try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(
            percent: 6,
            productUsage: [
                "GrokBuild",
                GrokCreditsFixtures.productEntry(nil, percent: 3.0),
                GrokCreditsFixtures.productEntry("GrokChat", percent: "lots"),
                GrokCreditsFixtures.productEntry("GrokImagine", percent: "Infinity"),
                GrokCreditsFixtures.productEntry("GrokBuild", percent: 6.0)
            ]
        ))

        XCTAssertEqual(config.productUsage, [GrokProductUsage(product: "GrokBuild", usedPercent: 6)])
        XCTAssertEqual(config.usedPercent, 6, "the pool percent survives an unusable product entry")
    }

    func testRejectsPeriodThatDoesNotMoveForward() {
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(
                start: "2026-07-07T21:36:52.140114+00:00", end: "2026-06-30T21:36:52.140114+00:00"
            ))
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testRejectsMissingConfigFields() {
        // A well-formed JSON body lacking the fields we map is a schema change, not a blank.
        for body in ["{}", #"{"config":{}}"#, #"{"config":{"currentPeriod":{}}}"#, "not json"] {
            XCTAssertThrowsError(
                try GrokCreditsConfigDecoder.decode(responseBody: Data(body.utf8)),
                "body: \(body)"
            ) { error in
                XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
            }
        }
    }
}

final class GrokCreditsConfigMapperTests: XCTestCase {
    func testMapsWeeklyLineAndBadgeFromCapturedResponse() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody
        ))

        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, _, _)? =
                mapped.lines.first(where: { $0.label == "Weekly limit" }) else {
            return XCTFail("expected a Weekly limit progress line, got \(mapped.lines)")
        }
        XCTAssertEqual(label, "Weekly limit")
        XCTAssertEqual(used, 99.0)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(resetsAt?.timeIntervalSince1970 ?? 0,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        guard case .badge(_, let text, let colorHex, _)? =
                mapped.lines.first(where: { $0.label == "Pay as you go" }) else {
            return XCTFail("expected a Pay as you go badge")
        }
        XCTAssertEqual(text, "Disabled", "captured cap is 0")
        XCTAssertEqual(colorHex, "#a3a3a3")
    }

    func testMapsEnabledPayAsYouGoCap() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(onDemandCap: 2500)
        ))
        guard case .badge(_, let text, let colorHex, _)? =
                mapped.lines.first(where: { $0.label == "Pay as you go" }) else {
            return XCTFail("expected a Pay as you go badge")
        }
        XCTAssertEqual(text, "2500 cap")
        XCTAssertEqual(colorHex, "#22c55e")
    }

    func testMapsProductUsageRowFromCapturedResponse() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBodyWithProductUsage
        ))

        guard case .values(_, let values, _, _, _, _)? =
                mapped.lines.first(where: { $0.label == "Product Usage" }) else {
            return XCTFail("expected a Product Usage row, got \(mapped.lines)")
        }
        // Only the products actually consuming the pool, biggest share first, with the repeated
        // "Grok" prefix dropped: "4% Build · 1% Chat".
        XCTAssertEqual(values, [
            MetricValue(number: 4, kind: .percent, label: "Build"),
            MetricValue(number: 1, kind: .percent, label: "Chat")
        ])
    }

    func testProductUsageRowRanksByShareThenName() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(productUsage: [
                GrokCreditsFixtures.productEntry("GrokChat", percent: 2.0),
                GrokCreditsFixtures.productEntry("GrokImagine", percent: 9.0),
                GrokCreditsFixtures.productEntry("GrokAppBuilder", percent: 2.0)
            ])
        ))

        guard case .values(_, let values, _, _, _, _)? =
                mapped.lines.first(where: { $0.label == "Product Usage" }) else {
            return XCTFail("expected a Product Usage row")
        }
        XCTAssertEqual(values.map(\.label), ["Imagine", "App Builder", "Chat"],
                       "ranked by share, ties broken by the API's own name so the order is stable")
    }

    func testProductUsageRowIsAbsentWithoutUsage() throws {
        // No field at all (the older account shape) and an all-zero week both mean there is nothing
        // to attribute — the tile reads "No data" rather than a row of zeros.
        for body in [
            GrokCreditsFixtures.capturedResponseBody,
            GrokCreditsFixtures.responseBody(productUsage: [
                GrokCreditsFixtures.productEntry("GrokBuild"),
                GrokCreditsFixtures.productEntry("GrokChat", percent: 0)
            ])
        ] {
            let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
                statusCode: 200, headers: [:], body: body
            ))
            XCTAssertNil(mapped.lines.first(where: { $0.label == "Product Usage" }))
        }
    }

    func testProductDisplayNameLeavesUnfamiliarNamesReadable() {
        XCTAssertEqual(GrokUsageMapper.productDisplayName("GrokAppBuilder"), "App Builder")
        XCTAssertEqual(GrokUsageMapper.productDisplayName("GrokBuild"), "Build")
        // Nothing to strip or split — rendered exactly as the API sent it.
        XCTAssertEqual(GrokUsageMapper.productDisplayName("Grok"), "Grok")
        XCTAssertEqual(GrokUsageMapper.productDisplayName("grok-imagine"), "grok-imagine")
        XCTAssertEqual(GrokUsageMapper.productDisplayName("  GrokChat  "), "Chat")
    }

    func testClampsOutOfRangeProductPercent() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(productUsage: [
                GrokCreditsFixtures.productEntry("GrokBuild", percent: 150)
            ])
        ))
        guard case .values(_, let values, _, _, _, _)? =
                mapped.lines.first(where: { $0.label == "Product Usage" }) else {
            return XCTFail("expected a Product Usage row")
        }
        XCTAssertEqual(values.first?.number, 100)
    }

    // The non-weekly (monthly) period shape is covered end-to-end by
    // GrokProviderTests.testNonWeeklyPeriodShowsNoWeeklyLineAndNoWarning.

    func testClampsOutOfRangePercent() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(percent: 150)
        ))
        guard case .progress(_, let used, _, _, _, _, _, _)? =
                mapped.lines.first(where: { $0.label == "Weekly limit" }) else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(used, 100)
    }

    func testAuthStatusesThrowAuthExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
                statusCode: status, headers: [:], body: Data()
            ))) { error in
                XCTAssertEqual(error as? GrokAuthError, .expired, "HTTP \(status)")
            }
        }
    }

    func testOtherHTTPFailuresThrowRequestFailed() {
        XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 503, headers: [:], body: Data()
        ))) { error in
            XCTAssertEqual(error as? GrokUsageError, .requestFailed(503))
        }
    }
}
