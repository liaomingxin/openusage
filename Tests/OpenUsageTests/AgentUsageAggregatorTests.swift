import XCTest
@testable import OpenUsage

/// Window filtering, per-model aggregation, and ordering for the Agent Usage screen's report
/// builder. Fixtures go through `DailyUsageAccumulator` so the day-key contract is the same one
/// production scans use.
final class AgentUsageAggregatorTests: XCTestCase {
    private let now = Date()

    private func source(_ id: String, name: String = "Agent") -> AgentUsageSource {
        AgentUsageSource(id: id, displayName: name, icon: .providerMark(id)) { _ in nil }
    }

    /// A scan with one day of priced models `daysAgo` (plus optional unpriced models that day).
    private func scan(daysAgo: Int, models: [(String, Int, Double)], unknown: [String] = []) -> LogUsageScan {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let key = DailyUsageAccumulator.dayKey(from: day)
        var accumulator = DailyUsageAccumulator()
        for model in models {
            accumulator.add(day: key, tokens: model.1, cost: model.2, model: model.0)
        }
        for model in unknown {
            accumulator.addUnknownModel(day: key, model: model)
        }
        return accumulator.build()
    }

    private func result(
        _ id: String, name: String = "Agent", scan: LogUsageScan?
    ) -> AgentUsageAggregator.SourceResult {
        AgentUsageAggregator.SourceResult(source: source(id, name: name), scan: scan)
    }

    private func model(_ agent: AgentUsageSummary, _ name: String) throws -> AgentModelUsage {
        try XCTUnwrap(agent.models.first { $0.model == name })
    }

    // MARK: - Window filtering

    func testTodayWindowExcludesYesterday() throws {
        let report = AgentUsageAggregator.report(
            window: .today,
            from: [result("a", scan: scan(daysAgo: 0, models: [("m1", 10, 0.1)])),
                   result("b", scan: scan(daysAgo: 1, models: [("m1", 99, 9.9)]))],
            now: now
        )
        XCTAssertEqual(report.agents.map(\.agentID), ["a"])
        XCTAssertEqual(report.totalTokens, 10)
    }

    func testYesterdayWindowIncludesOnlyYesterday() throws {
        let report = AgentUsageAggregator.report(
            window: .yesterday,
            from: [result("a", scan: scan(daysAgo: 0, models: [("m1", 10, 0.1)])),
                   result("b", scan: scan(daysAgo: 1, models: [("m1", 20, 0.2)]))],
            now: now
        )
        XCTAssertEqual(report.agents.map(\.agentID), ["b"])
        XCTAssertEqual(report.totalTokens, 20)
    }

    func testLast7DaysExcludesDaySeven() {
        let report = AgentUsageAggregator.report(
            window: .last7Days,
            from: [result("a", scan: scan(daysAgo: 6, models: [("m1", 10, 0.1)])),
                   result("b", scan: scan(daysAgo: 7, models: [("m1", 99, 9.9)]))],
            now: now
        )
        XCTAssertEqual(report.agents.map(\.agentID), ["a"])
    }

    func testLast30DaysExcludesDayThirty() {
        let report = AgentUsageAggregator.report(
            window: .last30Days,
            from: [result("a", scan: scan(daysAgo: 29, models: [("m1", 10, 0.1)])),
                   result("b", scan: scan(daysAgo: 30, models: [("m1", 99, 9.9)]))],
            now: now
        )
        XCTAssertEqual(report.agents.map(\.agentID), ["a"])
    }

    // MARK: - Aggregation

    func testSumsOneAgentsModelAcrossDays() throws {
        // The real shape: one agent whose scan holds two days of the same model.
        var accumulator = DailyUsageAccumulator()
        for offset in [0, 1] {
            let key = DailyUsageAccumulator.dayKey(
                from: Calendar.current.date(byAdding: .day, value: -offset, to: now)!
            )
            accumulator.add(day: key, tokens: 100, cost: 1.25, model: "sonnet")
        }
        let report = AgentUsageAggregator.report(
            window: .last7Days,
            from: [result("claude", scan: accumulator.build())],
            now: now
        )
        let agent = try XCTUnwrap(report.agents.first)
        let sonnet = try model(agent, "sonnet")
        XCTAssertEqual(sonnet.totalTokens, 200)
        XCTAssertEqual(sonnet.costUSD ?? 0, 2.5, accuracy: 0.0001)
    }

    func testAgentsSortByCostDescending() {
        let report = AgentUsageAggregator.report(
            window: .last30Days,
            from: [
                result("cheap", scan: scan(daysAgo: 0, models: [("m", 1_000, 0.01)])),
                result("pricey", name: "Pricey", scan: scan(daysAgo: 0, models: [("m", 10, 5.0)])),
            ],
            now: now
        )
        XCTAssertEqual(report.agents.map(\.agentID), ["pricey", "cheap"])
    }

    func testModelsSortByCostThenTokens() throws {
        let report = AgentUsageAggregator.report(
            window: .last30Days,
            from: [result("a", scan: scan(daysAgo: 0, models: [
                ("small-cost", 10, 0.1), ("big-cost", 10, 1.0), ("tie-tokens", 20, 1.0),
            ]))],
            now: now
        )
        XCTAssertEqual(report.agents.first?.models.map(\.model), ["tie-tokens", "big-cost", "small-cost"])
    }

    // MARK: - Absent data

    func testNilScanDropsAgent() {
        let report = AgentUsageAggregator.report(
            window: .today,
            from: [result("installed", scan: scan(daysAgo: 0, models: [("m", 1, 0.1)])),
                   result("not-installed", scan: nil)],
            now: now
        )
        XCTAssertEqual(report.agents.map(\.agentID), ["installed"])
    }

    func testWindowEmptyScanDropsAgent() {
        let report = AgentUsageAggregator.report(
            window: .today,
            from: [result("a", scan: scan(daysAgo: 5, models: [("m", 1, 0.1)]))],
            now: now
        )
        XCTAssertTrue(report.agents.isEmpty)
        XCTAssertEqual(report.totalCostUSD, 0)
    }

    func testUnpricedModelsSurfaceScopedToWindow() throws {
        let report = AgentUsageAggregator.report(
            window: .today,
            from: [result("a", scan: scan(daysAgo: 0, models: [("m", 1, 0.1)], unknown: ["mystery", "enigma"])),
                   result("b", scan: scan(daysAgo: 9, models: [("m", 1, 0.1)], unknown: ["outside-window"]))],
            now: now
        )
        let agent = try XCTUnwrap(report.agents.first { $0.agentID == "a" })
        XCTAssertEqual(agent.unpricedModels, ["enigma", "mystery"])
        // Day 9 is outside the Today window, so its agent (priced and unpriced alike) drops entirely.
        XCTAssertNil(report.agents.first { $0.agentID == "b" })
    }

    func testUnpricedOnlyAgentStillListed() throws {
        let report = AgentUsageAggregator.report(
            window: .today,
            from: [result("a", scan: scan(daysAgo: 0, models: [], unknown: ["mystery"]))],
            now: now
        )
        let agent = try XCTUnwrap(report.agents.first)
        XCTAssertEqual(agent.unpricedModels, ["mystery"])
        XCTAssertEqual(agent.totalCostUSD, 0)
    }
}
