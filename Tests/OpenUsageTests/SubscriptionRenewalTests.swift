import XCTest
@testable import OpenUsage

/// Covers the subscription renewal row end to end: the three provider mappers that emit it (fixtures
/// are the redacted live payloads in `docs/research/subscription-expiry.md`), the `MetricLine.date`
/// model and its Codable/local-API wire shapes, the Countdown ⟷ Exact Time formatting, and the
/// metric-placement defaults (enabled, On Demand, not pinnable, last).
@MainActor
final class SubscriptionRenewalTests: XCTestCase {

    // MARK: - Fixtures (redacted samples from docs/research/subscription-expiry.md)

    /// `GetCurrentPeriodUsage` — the payload Cursor's main path already maps. Billing-cycle bounds
    /// are epoch milliseconds here.
    private func cursorUsage(cycleStartMs: Double = 1_786_972_261_000,
                             cycleEndMs: Double? = 1_789_564_261_000) -> [String: Any] {
        var usage: [String: Any] = [
            "enabled": true,
            "planUsage": ["limit": 40_000, "totalSpend": 5_140, "totalPercentUsed": 12.85],
            "billingCycleStart": cycleStartMs
        ]
        if let cycleEndMs { usage["billingCycleEnd"] = cycleEndMs }
        return usage
    }

    private let cursorPeriodEnd = Date(timeIntervalSince1970: 1_789_564_261)

    /// `GET cursor.com/api/auth/stripe`, trimmed to the two fields OpenUsage reads.
    private func cursorStripe(status: String = "active", pendingCancellation: Any = NSNull()) -> [String: Any] {
        ["subscriptionStatus": status, "pendingCancellationDate": pendingCancellation, "customerBalance": 0]
    }

    private func zaiSubscription(
        status: String = "VALID",
        nextRenewTime: String = "2026-11-23",
        autoRenew: Int = 1,
        inCurrentPeriod: Bool = true
    ) -> Data {
        let entry: [String: Any] = [
            "productName": "GLM Coding Max",
            "status": status,
            "currentRenewTime": "2026-08-23",
            "nextRenewTime": nextRenewTime,
            "billingCycle": "quarterly",
            "autoRenew": autoRenew,
            "inCurrentPeriod": inCurrentPeriod
        ]
        return try! JSONSerialization.data(withJSONObject: ["code": 200, "success": true, "data": [entry]])
    }

    private let zaiQuota = Data(#"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":15}]}}"#.utf8)

    /// A JWT-shaped id_token carrying the `https://api.openai.com/auth` claim, like `~/.codex/auth.json`.
    private func codexIDToken(activeStart: String?, activeUntil: String?) -> String {
        var claim: [String: Any] = ["chatgpt_plan_type": "pro"]
        if let activeStart { claim["chatgpt_subscription_active_start"] = activeStart }
        if let activeUntil { claim["chatgpt_subscription_active_until"] = activeUntil }
        func segment(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none"])).\(segment(["https://api.openai.com/auth": claim])).sig"
    }

    private func renewalLine(in lines: [MetricLine]) -> (label: String, at: Date, subtitle: String?)? {
        for line in lines {
            if case .date(let label, let at, _, let subtitle) = line { return (label, at, subtitle) }
        }
        return nil
    }

    // MARK: - Cursor

    func testCursorRenewsFromTheUsagePayloadItAlreadyMaps() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: cursorUsage(), planName: "Ultra", creditGrants: nil, stripeBalanceCents: 0,
            subscriptionIsEnding: CursorUsageMapper.subscriptionIsEnding(from: cursorStripe())
        )

        let row = try XCTUnwrap(renewalLine(in: mapped.lines))
        XCTAssertEqual(row.label, "Renews")
        XCTAssertEqual(row.at, cursorPeriodEnd)
        XCTAssertNil(row.subtitle)
        // The row is last: it's account metadata, not a meter.
        XCTAssertEqual(mapped.lines.last?.label, "Renews")
    }

    func testCursorEndsOnPendingCancellationOrInactiveStatus() throws {
        let endingBodies: [[String: Any]] = [
            cursorStripe(pendingCancellation: "2026-09-16T13:11:01.000Z"),
            cursorStripe(status: "canceled")
        ]

        for body in endingBodies {
            XCTAssertTrue(CursorUsageMapper.subscriptionIsEnding(from: body))
            let mapped = try CursorUsageMapper.mapUsage(
                usage: cursorUsage(), planName: "Ultra", creditGrants: nil, stripeBalanceCents: 0,
                subscriptionIsEnding: CursorUsageMapper.subscriptionIsEnding(from: body)
            )
            XCTAssertEqual(renewalLine(in: mapped.lines)?.label, "Ends")
        }

        // An unreadable / absent stripe response is not evidence of a cancellation.
        XCTAssertFalse(CursorUsageMapper.subscriptionIsEnding(from: nil))
        XCTAssertFalse(CursorUsageMapper.subscriptionIsEnding(from: ["customerBalance": 0]))
    }

    func testCursorFallsBackToPlanInfoAndOmitsTheRowWithNoDate() throws {
        // `GetPlanInfo.billingCycleEnd` is epoch milliseconds *as a string* in that response.
        let planEnd = CursorUsageMapper.planBillingCycleEnd(from: ["billingCycleEnd": "1789564261000"])
        XCTAssertEqual(planEnd, cursorPeriodEnd)

        let withFallback = try CursorUsageMapper.mapUsage(
            usage: cursorUsage(cycleEndMs: nil), planName: "Ultra", creditGrants: nil,
            stripeBalanceCents: 0, planBillingCycleEnd: planEnd
        )
        XCTAssertEqual(renewalLine(in: withFallback.lines)?.at, cursorPeriodEnd)

        let withoutAnyDate = try CursorUsageMapper.mapUsage(
            usage: cursorUsage(cycleEndMs: nil), planName: "Ultra", creditGrants: nil, stripeBalanceCents: 0
        )
        XCTAssertNil(renewalLine(in: withoutAnyDate.lines))
    }

    func testCursorSummaryFallbackUsesTheReportedCycleEndOnly() throws {
        let summary: [String: Any] = [
            "billingCycleStart": "2026-08-16T13:11:01.000Z",
            "billingCycleEnd": "2026-09-16T13:11:01.000Z",
            "membershipType": "ultra",
            "individualUsage": ["plan": ["totalPercentUsed": 12.85]]
        ]
        let mapped = try CursorUsageSummaryMapper.map(
            summary: summary, requestUsage: nil, planName: "Ultra", unavailableMessage: "unavailable"
        )
        let row = try XCTUnwrap(renewalLine(in: mapped.lines))
        XCTAssertEqual(row.label, "Renews")
        XCTAssertEqual(row.at, OpenUsageISO8601.date(from: "2026-09-16T13:11:01.000Z"))

        // Without a reported cycle end the meters still infer a monthly reset — the renewal row must
        // not borrow that inferred date.
        let inferred = try CursorUsageSummaryMapper.map(
            summary: ["individualUsage": ["plan": ["totalPercentUsed": 12.85]]],
            requestUsage: ["startOfMonth": "2026-08-01T00:00:00.000Z"],
            planName: "Ultra", unavailableMessage: "unavailable"
        )
        XCTAssertNil(renewalLine(in: inferred.lines))
    }

    // MARK: - Z.ai

    func testZAIRenewsFromNextRenewTimeOfTheValidEntry() throws {
        let mapped = try ZAIUsageMapper.map(quotaBody: zaiQuota, subscriptionBody: zaiSubscription())

        let row = try XCTUnwrap(renewalLine(in: mapped.lines))
        XCTAssertEqual(row.label, "Renews")
        // The bare calendar string is read in the Mac's own calendar, so the row shows Z.ai's own day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: row.at),
                       DateComponents(year: 2026, month: 11, day: 23))
        XCTAssertEqual(mapped.lines.last?.label, "Renews")
    }

    func testZAIEndsWhenAutoRenewIsOffAndHidesTheRowWithoutAValidEntry() throws {
        let ending = try ZAIUsageMapper.map(quotaBody: zaiQuota,
                                            subscriptionBody: zaiSubscription(autoRenew: 0))
        XCTAssertEqual(renewalLine(in: ending.lines)?.label, "Ends")

        let expired = try ZAIUsageMapper.map(quotaBody: zaiQuota,
                                             subscriptionBody: zaiSubscription(status: "EXPIRED"))
        XCTAssertNil(renewalLine(in: expired.lines))

        // No subscription call this refresh (it's best-effort) → no row, meters unaffected.
        let noSubscription = try ZAIUsageMapper.map(quotaBody: zaiQuota, subscriptionBody: nil)
        XCTAssertNil(renewalLine(in: noSubscription.lines))
        XCTAssertEqual(noSubscription.lines.map(\.label), ["Session"])
    }

    func testZAIPrefersTheEntryInTheCurrentPeriod() throws {
        let entries: [[String: Any]] = [
            ["status": "VALID", "nextRenewTime": "2027-02-23", "inCurrentPeriod": false, "autoRenew": 1],
            ["status": "VALID", "nextRenewTime": "2026-11-23", "inCurrentPeriod": true, "autoRenew": 1]
        ]
        let body = try JSONSerialization.data(withJSONObject: ["data": entries])
        let row = try XCTUnwrap(ZAIUsageMapper.renewalLine(from: body))

        guard case .date(_, let at, _, _) = row else { return XCTFail("expected a date line") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: at),
                       DateComponents(year: 2026, month: 11, day: 23))
    }

    // MARK: - Codex

    func testCodexReadsThePeriodFromTheIDTokenClaimOnly() {
        let auth = CodexAuth(tokens: CodexTokens(
            accessToken: "at",
            idToken: codexIDToken(activeStart: "2026-07-26T17:13:33+00:00",
                                  activeUntil: "2026-08-26T17:14:28+00:00")
        ))
        let period = CodexAuthStore.subscriptionPeriod(from: auth)

        XCTAssertEqual(period?.end, OpenUsageISO8601.date(from: "2026-08-26T17:14:28Z"))
        XCTAssertEqual(period?.start, OpenUsageISO8601.date(from: "2026-07-26T17:13:33Z"))
        // An API-key login has no id_token at all, so it gets no row.
        XCTAssertNil(CodexAuthStore.subscriptionPeriod(from: CodexAuth(tokens: nil, apiKey: "sk-test")))
        // A token whose claim omits the period is equally row-less.
        XCTAssertNil(CodexAuthStore.subscriptionPeriod(from: CodexAuth(tokens: CodexTokens(
            idToken: codexIDToken(activeStart: "2026-07-26T17:13:33+00:00", activeUntil: nil)
        ))))
    }

    func testCodexRollsAStalePeriodForwardAndMarksItEstimated() throws {
        let start = OpenUsageISO8601.date(from: "2026-07-26T17:13:33Z")!
        let end = OpenUsageISO8601.date(from: "2026-08-26T17:14:28Z")!
        let period = CodexSubscriptionPeriod(start: start, end: end)
        let length = end.timeIntervalSince(start)

        // Fresh claim: shown verbatim, no estimate note.
        let fresh = try XCTUnwrap(CodexUsageMapper.subscriptionLine(
            period: period, now: end.addingTimeInterval(-24 * 3600)
        ))
        guard case .date(let freshLabel, let freshAt, _, let freshSubtitle) = fresh else {
            return XCTFail("expected a date line")
        }
        XCTAssertEqual(freshLabel, "Renews")
        XCTAssertEqual(freshAt, end)
        XCTAssertNil(freshSubtitle)

        // Stale claim (the live sample was already past): rolled forward by whole periods.
        for elapsedPeriods in [0.5, 1.2, 3.7] {
            let now = end.addingTimeInterval(length * elapsedPeriods)
            let rolled = try XCTUnwrap(CodexUsageMapper.subscriptionLine(period: period, now: now))
            guard case .date(let label, let at, _, let subtitle) = rolled else {
                return XCTFail("expected a date line")
            }
            XCTAssertEqual(label, "Renews")
            XCTAssertEqual(subtitle, "Estimated")
            XCTAssertGreaterThan(at, now)
            XCTAssertLessThanOrEqual(at.timeIntervalSince(now), length)
            // Always a whole number of periods past the claimed end.
            let periodsAdded = at.timeIntervalSince(end) / length
            XCTAssertEqual(periodsAdded, periodsAdded.rounded(), accuracy: 0.0001)
        }
    }

    func testCodexHidesAPastDateWithNoDerivablePeriod() {
        let end = OpenUsageISO8601.date(from: "2026-08-26T17:14:28Z")!
        let noStart = CodexSubscriptionPeriod(start: nil, end: end)
        XCTAssertNil(CodexUsageMapper.subscriptionLine(period: noStart, now: end.addingTimeInterval(3600)))

        let zeroLength = CodexSubscriptionPeriod(start: end, end: end)
        XCTAssertNil(CodexUsageMapper.subscriptionLine(period: zeroLength, now: end.addingTimeInterval(3600)))
    }

    // MARK: - Display: Countdown ⟷ Exact Time

    func testRowFollowsTheGlobalCountdownExactTimeMode() throws {
        // The Mac's own calendar, because the day a date falls on — and how it prints — is local.
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let renewsAt = now.addingTimeInterval(20 * 24 * 3600 + 6 * 3600)

        XCTAssertEqual(Formatters.subscriptionDateLabel(at: renewsAt, mode: .relative, now: now,
                                                        calendar: calendar), "in 20d 6h")

        // Exact Time stops at the day: a billing date is day-grained, so no wall-clock time is shown
        // (unlike a reset label, which reads "Feb 15 at 3:45 PM").
        let exact = try XCTUnwrap(Formatters.subscriptionDateLabel(at: renewsAt, mode: .absolute,
                                                                   now: now, calendar: calendar))
        XCTAssertEqual(exact, Formatters.monthDayLabel(renewsAt))
        XCTAssertFalse(exact.contains(TimeFormatSetting.current.shortTime(renewsAt)))

        // A date in another calendar year carries the year, so a yearly plan isn't ambiguous.
        let nextYear = try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: renewsAt))
        let yearLabel = try XCTUnwrap(Formatters.subscriptionDateLabel(at: nextYear, mode: .absolute,
                                                                       now: now, calendar: calendar))
        XCTAssertNotEqual(yearLabel, Formatters.monthDayLabel(nextYear))
        XCTAssertTrue(yearLabel.contains(String(calendar.component(.year, from: nextYear))))

        // Past due collapses to the shared "soon", like every other deadline.
        XCTAssertEqual(Formatters.subscriptionDateLabel(at: now.addingTimeInterval(-3600),
                                                        mode: .relative, now: now, calendar: calendar),
                       Formatters.imminent)
    }

    func testWidgetDataRendersTheRowFromTheRawDate() throws {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let descriptor = WidgetDescriptor.subscriptionRenewal(provider: provider)
        let store = try makeStore(provider: provider, descriptor: descriptor, lines: [
            .subscription(at: Date().addingTimeInterval(20 * 24 * 3600 + 6 * 3600))
        ])

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.title, "Renews")
        XCTAssertEqual(data.unboundedDetail, "in 20d 6h")

        // The "Ends" wording rides on the line, so the same tile keeps rendering it.
        let ending = try makeStore(provider: provider, descriptor: descriptor, lines: [
            .subscription(at: Date().addingTimeInterval(20 * 24 * 3600 + 6 * 3600), isEnding: true)
        ])
        XCTAssertEqual(ending.data(for: descriptor).title, "Ends")

        // Codex's rolled-forward date carries its note under the value.
        let estimated = try makeStore(provider: provider, descriptor: descriptor, lines: [
            .subscription(at: Date().addingTimeInterval(3 * 24 * 3600), subtitle: "Estimated")
        ])
        XCTAssertEqual(estimated.data(for: descriptor).unboundedSubtitle, "Estimated")

        // No line at all → the placeholder never leaks a made-up date.
        let empty = try makeStore(provider: provider, descriptor: descriptor, lines: [])
        XCTAssertFalse(empty.data(for: descriptor).hasData)
        XCTAssertEqual(empty.data(for: descriptor).unboundedDetail, WidgetData.noDataSubtitle)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        lines: [MetricLine]
    ) throws -> WidgetDataStore {
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let store = WidgetDataStore(registry: registry, providers: [], defaults: makeDefaults())
        store.snapshots[provider.id] = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName, lines: lines, refreshedAt: Date()
        )
        return store
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.SubscriptionRenewal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Model + wire shapes

    func testDateLineSurvivesACodableRoundTrip() throws {
        let line = MetricLine.date(label: "Ends", at: Date(timeIntervalSince1970: 1_789_564_261),
                                   colorHex: "#EF4444", subtitle: "Estimated")
        let decoded = try JSONDecoder().decode(MetricLine.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded, line)

        let minimal = MetricLine.subscription(at: Date(timeIntervalSince1970: 1_789_564_261))
        XCTAssertEqual(try JSONDecoder().decode(
            MetricLine.self, from: JSONEncoder().encode(minimal)
        ), minimal)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(line)
        ) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "date")
        XCTAssertEqual(json["label"] as? String, "Ends")
    }

    func testLocalUsageAPIExportsTheRowAsAnISO8601DateLine() throws {
        let snapshot = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.subscription(at: OpenUsageISO8601.date(from: "2026-09-16T13:11:01.000Z")!)],
            refreshedAt: OpenUsageISO8601.date(from: "2026-03-26T11:16:29.000Z")!
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["cursor"], knownIDs: ["cursor"], snapshots: ["cursor": snapshot]
        )

        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state)
        let array = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [[String: Any]]
        )
        let lines = try XCTUnwrap(array.first?["lines"] as? [[String: Any]])
        let row = try XCTUnwrap(lines.first { $0["type"] as? String == "date" })

        XCTAssertEqual(row["label"] as? String, "Renews")
        XCTAssertEqual(row["at"] as? String, "2026-09-16T13:11:01.000Z")
        XCTAssertTrue(row.keys.contains("color"))       // explicit null, like every other line type
        XCTAssertTrue(row.keys.contains("subtitle"))
    }

    // MARK: - Metric-placement defaults

    func testDefaultsAreEnabledOnDemandUnpinnableAndLast() {
        for provider in [CursorProvider().provider, ZAIProvider().provider, CodexProvider().provider] {
            let id = "\(provider.id).renews"
            let descriptors: [WidgetDescriptor]
            switch provider.id {
            case "cursor": descriptors = CursorProvider().widgetDescriptors
            case "zai": descriptors = ZAIProvider().widgetDescriptors
            default: descriptors = CodexProvider().widgetDescriptors
            }
            let descriptor = descriptors.first { $0.id == id }

            XCTAssertEqual(descriptors.last?.id, id, "\(id) must be declared last")
            XCTAssertEqual(descriptor?.pinnable, false, "\(id) must not be pinnable")
            XCTAssertEqual(descriptor?.title, "Renews")
            XCTAssertEqual(descriptor?.metricLabel, "Renews")
            XCTAssertEqual(descriptor?.alternateMetricLabels, ["Ends"])
            XCTAssertTrue(descriptor?.limitResources.isEmpty ?? false, "\(id) stays out of /v1/limits")
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) must be enabled by default")
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) must start On Demand")
            XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(id), "\(id) must not be pinned")
        }
    }

    /// The row's label switches with plan state while its widget id doesn't, so the tile has to match
    /// either word — otherwise an "Ends" row would silently read "No data".
    func testTileMatchesBothRenewsAndEnds() {
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))
        let descriptor = WidgetDescriptor.subscriptionRenewal(provider: provider)
        let at = Date(timeIntervalSince1970: 1_789_564_261)

        for line in [MetricLine.subscription(at: at), .subscription(at: at, isEnding: true)] {
            let snapshot = ProviderSnapshot(providerID: "zai", displayName: "Z.ai",
                                            lines: [line], refreshedAt: Date())
            XCTAssertEqual(snapshot.line(for: descriptor), line)
        }
    }
}
