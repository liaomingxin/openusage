import XCTest
@testable import OpenUsage

/// The Desktop session index is read as a fixed 512-byte prefix. Decoding that prefix strictly means a
/// multi-byte character straddling the cut — a CJK path or an emoji in a title, which is ordinary — makes
/// the whole file decode to nil, and the session silently loses its account. The bytes are a prefix of a
/// valid document, never a whole one, so the read has to be lossy.
@MainActor
final class ClaudeDesktopSessionIndexTests: XCTestCase {
    func testIndexSurvivesAMultiByteCharacterStraddlingThe512ByteCut() async throws {
        let now = Date()
        let sessionID = "11111111-1111-4111-8111-111111111111"
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            // No ownership records: only the Desktop index can attribute this session.
            "workspace/\(sessionID).jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50
            )
        ])

        let head = #"{"cliSessionId":"\#(sessionID)","title":""#
        // Pad with 3-byte characters so byte 512 lands inside one of them.
        let padding = String(repeating: "中", count: (512 - head.utf8.count) / 3 + 1)
        XCTAssertLessThan(head.utf8.count + padding.utf8.count - 3, 512, "the cut must fall mid-character")
        XCTAssertGreaterThan(head.utf8.count + padding.utf8.count, 512)
        let directory = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions/user-a/org-a"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (head + padding + #""}"#).write(
            to: directory.appendingPathComponent("local_\(sessionID).json"),
            atomically: true, encoding: .utf8
        )

        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            accountUUID: "user-a", organizationUUID: "org-a"
        )
        let result = await scanner.scan(now: now, pricing: TestPricing.bundled)

        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150, "the indexed session must still be found")
    }
}
