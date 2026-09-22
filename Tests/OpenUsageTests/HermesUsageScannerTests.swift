import XCTest
@testable import OpenUsage

/// Row decoding and the carried-cost-else-priced aggregation for the Hermes state.db scanner. The
/// SQLite layer is faked at the `SQLiteAccessing` boundary, mirroring how the OpenCode scanner
/// tests drive query results.
final class HermesUsageScannerTests: XCTestCase {
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "gpt-hermes": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 10, cacheReadPerMillion: 1
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    /// Routes the two queries a fake database: anything mentioning `session_model_usage` is the
    /// per-model query; everything else is the session-totals fallback.
    private struct FakeSQLite: SQLiteAccessing {
        var perModelJSON: String?
        var perModelError: Error?
        var sessionTotalsJSON: String?

        func queryValue(path: String, sql: String) throws -> String? {
            if sql.contains("session_model_usage") {
                if let perModelError { throw perModelError }
                return perModelJSON
            }
            return sessionTotalsJSON
        }

        func execute(path: String, sql: String) throws {}
    }

    /// The scanner checks the database exists; an empty temp file stands in.
    private var databasePath: String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-test-\(UUID().uuidString).db")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url.path
    }

    private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    private func json(_ rows: [[Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return String(decoding: data, as: UTF8.self)
    }

    private func scanner(_ sqlite: FakeSQLite, path: String? = nil) -> HermesUsageScanner {
        let resolved = path ?? databasePath
        return HermesUsageScanner(sqlite: sqlite, databasePath: { resolved })
    }

    // MARK: - Row parsing

    func testParseRowsMapsBucketsAndFoldsReasoningIntoOutput() throws {
        let rows = HermesUsageScanner.parseRows(json([[
            ms(Date()), "gpt-hermes", 100, 40, 10, 20, 60, 1.5,
        ]]))
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.tokens, 230)
        XCTAssertEqual(row.tokensBreakdown.input, 100)
        XCTAssertEqual(row.tokensBreakdown.cacheRead, 10)
        XCTAssertEqual(row.tokensBreakdown.cacheWrite5m, 20)
        // Reasoning (60) rides with output (40) for pricing.
        XCTAssertEqual(row.tokensBreakdown.output, 100)
        XCTAssertEqual(row.cost, 1.5)
    }

    func testOfficialSlicesKeepZAIAndCodexAndDropProxies() throws {
        let now = ms(Date())
        let rows = HermesUsageScanner.parseRows(json([
            [now, "glm-5.3", 10, 1, 0, 0, 0, 0, "zai", "https://api.z.ai/api/coding/paas/v4"],
            [now, "gpt-5.5", 10, 1, 0, 0, 0, 0, "openai-codex", "https://chatgpt.com/backend-api/codex"],
            [now, "claude-opus-4-6", 10, 1, 0, 0, 0, 0, "anthropic", "https://6688ai.xyz"],
            [now, "gpt-5.4", 10, 1, 0, 0, 0, 0, "custom", "http://127.0.0.1:8317/v1"]
        ]))
        XCTAssertEqual(rows.count, 4)
        let slices = HermesUsageScanner.officialSlices(rows)
        XCTAssertEqual(slices.zai.map(\.model), ["glm-5.3"])
        XCTAssertEqual(slices.codex.map(\.model), ["gpt-5.5"])
    }

    func testParseRowsKeepsRowWithoutCostColumn() throws {
        let rows = HermesUsageScanner.parseRows(json([[
            ms(Date()), "gpt-hermes", 1, 2, 0, 0, 0,
        ]]))
        XCTAssertEqual(rows.first?.cost, nil)
    }

    func testParseRowsSkipsMalformedEntries() {
        XCTAssertTrue(HermesUsageScanner.parseRows("not json").isEmpty)
        XCTAssertTrue(HermesUsageScanner.parseRows(json([["only-one-field"]])).isEmpty)
    }

    // MARK: - Scan aggregation

    func testCarriedCostWinsOverEnginePricing() async throws {
        let now = Date()
        let scan = await scanner(FakeSQLite(
            perModelJSON: json([[ms(now), "gpt-hermes", 1_000_000, 0, 0, 0, 0, 0.75]])
        )).scan(daysBack: 30, now: now, pricing: pricing)
        let entry = try XCTUnwrap(scan?.series.daily.first)
        // $0.75 carried, not the $10 a raw 1M-input estimate would give.
        XCTAssertEqual(entry.costUSD ?? 0, 0.75, accuracy: 0.0001)
    }

    func testZeroCostRowPricesThroughEngine() async throws {
        let now = Date()
        let scan = await scanner(FakeSQLite(
            perModelJSON: json([[ms(now), "gpt-hermes", 1_000_000, 0, 0, 0, 0, 0]])
        )).scan(daysBack: 30, now: now, pricing: pricing)
        let entry = try XCTUnwrap(scan?.series.daily.first)
        XCTAssertEqual(entry.costUSD ?? 0, 10.0, accuracy: 0.0001)
        XCTAssertEqual(entry.totalTokens, 1_000_000)
    }

    func testUnpricedModelSurfacesAsUnknown() async throws {
        let now = Date()
        let dayKey = DailyUsageAccumulator.dayKey(from: now)
        let scan = await scanner(FakeSQLite(
            perModelJSON: json([[ms(now), "mystery-model", 500, 0, 0, 0, 0, 0]])
        )).scan(daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.isEmpty, true)
        XCTAssertEqual(scan?.unknownModelsByDay[dayKey], ["mystery-model"])
    }

    func testFallsBackToSessionTotalsWhenPerModelTableMissing() async throws {
        let now = Date()
        let scan = await scanner(FakeSQLite(
            perModelError: NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such table: session_model_usage"]),
            sessionTotalsJSON: json([[ms(now), "gpt-hermes", 10, 0, 0, 0, 0, 2.0]])
        )).scan(daysBack: 30, now: now, pricing: pricing)
        let entry = try XCTUnwrap(scan?.series.daily.first)
        XCTAssertEqual(entry.costUSD ?? 0, 2.0, accuracy: 0.0001)
    }

    func testRowsOutsideWindowExcluded() async throws {
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -40, to: now)!
        let scan = await scanner(FakeSQLite(
            perModelJSON: json([[ms(old), "gpt-hermes", 10, 0, 0, 0, 0, 9.0]])
        )).scan(daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.isEmpty, true)
    }

    func testMissingDatabaseReturnsNil() async {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-absent-\(UUID().uuidString).db").path
        let scan = await scanner(FakeSQLite(perModelJSON: json([])), path: absent)
            .scan(daysBack: 30, pricing: pricing)
        XCTAssertNil(scan)
    }
}
