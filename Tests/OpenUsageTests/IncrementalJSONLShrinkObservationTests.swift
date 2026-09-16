import Foundation
import XCTest
@testable import OpenUsage

/// Coverage for the observation-only "log file shrank in place" telemetry: a file smaller than its
/// cached parse means a client rewrote the transcript and dropped counted turns. The scan must
/// report that (once, aggregated) while returning exactly the items it would return without the
/// observation — the repair itself is deliberately not built yet.
final class IncrementalJSONLShrinkObservationTests: XCTestCase {
    private let parse: @Sendable (Data) -> [Int]? = { data in
        String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { Int(String($0)) }
    }

    func testShrunkFileIsReportedOnceAndDoesNotChangeScanResults() async throws {
        let base = try makeDirectory("ShrunkOnce")
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ShrinkObservationRecorder()
        let scanner = IncrementalJSONLScanner<Int>(shrinkWarning: recorder.record)
        let identity = "home"

        let original = try makeFile(named: "a.jsonl", contents: "1\n2\n3\n4", in: base)
        let firstItems = await scanner.items(
            from: [original], since: .distantPast, cacheIdentity: identity, parse: parse
        )
        XCTAssertEqual(firstItems, [1, 2, 3, 4])
        XCTAssertEqual(recorder.observations, [], "nothing has shrunk yet")

        let shrunk = try rewrite(original, to: "1\n2")
        let secondItems = await scanner.items(
            from: [shrunk], since: .distantPast, cacheIdentity: identity, parse: parse
        )
        XCTAssertEqual(secondItems, [1, 2], "a shrunk file is reparsed and returns its current rows")

        // Ground truth: a scanner with no cache parses the same file into the same items, proving
        // the observation leaves scan results identical to a plain full reparse.
        let uncached = IncrementalJSONLScanner<Int>(shrinkWarning: recorder.record)
        let uncachedItems = await uncached.items(
            from: [shrunk], since: .distantPast, cacheIdentity: "uncached", parse: parse
        )
        XCTAssertEqual(uncachedItems, secondItems)

        XCTAssertEqual(recorder.observations.count, 1, "exactly one aggregated observation per scan")
        let observation = try XCTUnwrap(recorder.observations.first)
        XCTAssertEqual(observation, JSONLShrinkObservation(
            cacheIdentity: identity,
            fileCount: 1,
            bytesLost: original.size - shrunk.size,
            recordsLost: 2,
            fileNames: ["a.jsonl"]
        ))

        // Edge-triggered: the rescan caches the smaller size, so repeats stay quiet.
        let thirdItems = await scanner.items(
            from: [shrunk], since: .distantPast, cacheIdentity: identity, parse: parse
        )
        XCTAssertEqual(thirdItems, [1, 2])
        XCTAssertEqual(recorder.observations.count, 1)
    }

    func testMultipleShrunkFilesAggregateIntoOneObservationPerScan() async throws {
        let base = try makeDirectory("ShrunkMany")
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ShrinkObservationRecorder()
        let scanner = IncrementalJSONLScanner<Int>(shrinkWarning: recorder.record)

        let originals = try ["a", "b", "c", "d", "e"].map {
            try makeFile(named: "\($0).jsonl", contents: "1\n2\n3\n4", in: base)
        }
        _ = await scanner.items(
            from: originals, since: .distantPast, cacheIdentity: "home", parse: parse
        )
        XCTAssertEqual(recorder.observations, [])

        let shrunk = try originals.map { try rewrite($0, to: "1") }
        let items = await scanner.items(
            from: shrunk, since: .distantPast, cacheIdentity: "home", parse: parse
        )
        XCTAssertEqual(items, Array(repeating: 1, count: 5))

        XCTAssertEqual(recorder.observations.count, 1, "one aggregated line, not one per file")
        let observation = try XCTUnwrap(recorder.observations.first)
        XCTAssertEqual(observation.fileCount, 5)
        XCTAssertEqual(observation.bytesLost, (originals[0].size - shrunk[0].size) * 5)
        XCTAssertEqual(observation.recordsLost, 15, "each file dropped 3 of its 4 parsed records")
        XCTAssertEqual(observation.fileNames, ["a.jsonl", "b.jsonl", "c.jsonl"], "names are capped")
    }

    func testUnchangedGrownAndNewFilesEmitNoObservation() async throws {
        let base = try makeDirectory("NoShrink")
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ShrinkObservationRecorder()
        let scanner = IncrementalJSONLScanner<Int>(shrinkWarning: recorder.record)

        let firstFile = try makeFile(named: "a.jsonl", contents: "1\n2", in: base)
        let secondFile = try makeFile(named: "b.jsonl", contents: "3", in: base)
        _ = await scanner.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: parse
        )

        let grown = try rewrite(firstFile, to: "1\n2\n9")
        let newFile = try makeFile(named: "c.jsonl", contents: "5", in: base, mtime: Date())
        let items = await scanner.items(
            from: [grown, secondFile, newFile], since: .distantPast, cacheIdentity: "home", parse: parse
        )
        XCTAssertEqual(items, [1, 2, 9, 3, 5])
        XCTAssertEqual(recorder.observations, [], "growth, cache hits, and new files are not shrinks")

        _ = await scanner.items(
            from: [grown, secondFile, newFile], since: .distantPast, cacheIdentity: "home", parse: parse
        )
        XCTAssertEqual(recorder.observations, [])
    }

    func testUnreadableShrunkFileReportsBytesWithoutRecordCount() async throws {
        let base = try makeDirectory("ShrunkUnreadable")
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = ShrinkObservationRecorder()
        let scanner = IncrementalJSONLScanner<Int>(shrinkWarning: recorder.record)

        let original = try makeFile(named: "a.jsonl", contents: "1\n2\n3", in: base)
        _ = await scanner.items(
            from: [original], since: .distantPast, cacheIdentity: "home", parse: parse
        )

        // A shrunk file that can no longer be read still counts as a shrink, but the record drop is
        // not measurable, so the observation must omit rather than guess it.
        let url = URL(fileURLWithPath: original.path)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let unreadable = JSONLScanning.DiscoveredFile(
            path: original.path, size: 2, mtime: original.mtime.addingTimeInterval(1)
        )
        let items = await scanner.items(
            from: [unreadable], since: .distantPast, cacheIdentity: "home", parse: parse
        )
        XCTAssertEqual(items, [])

        XCTAssertEqual(recorder.observations.count, 1)
        let observation = try XCTUnwrap(recorder.observations.first)
        XCTAssertEqual(observation.fileCount, 1)
        XCTAssertEqual(observation.bytesLost, original.size - 2)
        XCTAssertNil(observation.recordsLost)
        XCTAssertEqual(observation.fileNames, ["a.jsonl"])
    }

    func testWarningMessageCarriesCountsAndNeverFullPaths() {
        let measurable = JSONLShrinkObservation(
            cacheIdentity: "home",
            fileCount: 2,
            bytesLost: 4_096,
            recordsLost: 57,
            fileNames: ["a1b2.jsonl", "c3d4.jsonl"]
        )
        XCTAssertEqual(
            JSONLShrinkObservation.message(for: measurable),
            "cache 'home': 2 local usage log files shrank in place (a1b2.jsonl, c3d4.jsonl); "
                + "4096 bytes and 57 previously parsed records lost versus the cached parse; "
                + "a client rewrote them in place, so spend may be undercounted"
        )

        let unmeasurable = JSONLShrinkObservation(
            cacheIdentity: "home",
            fileCount: 5,
            bytesLost: 8_192,
            recordsLost: nil,
            fileNames: ["a.jsonl", "b.jsonl", "c.jsonl"]
        )
        let message = JSONLShrinkObservation.message(for: unmeasurable)
        XCTAssertTrue(message.contains("(a.jsonl, b.jsonl, c.jsonl +2 more)"))
        XCTAssertTrue(message.contains("8192 bytes lost"))
        XCTAssertFalse(message.contains("/Users"), "full paths can embed project names")
    }

    // MARK: - Helpers

    private func makeDirectory(_ suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageShrink\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFile(
        named name: String,
        contents: String,
        in directory: URL,
        mtime: Date = Date()
    ) throws -> JSONLScanning.DiscoveredFile {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate)
        )
    }

    /// Overwrite with different contents and a strictly newer mtime, mirroring a client that
    /// rewrites (and shrinks) its transcript in place between two scans.
    private func rewrite(_ file: JSONLScanning.DiscoveredFile, to contents: String) throws
        -> JSONLScanning.DiscoveredFile
    {
        let url = URL(fileURLWithPath: file.path)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: file.mtime.addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JSONLScanning.DiscoveredFile(
            path: file.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate)
        )
    }
}

private final class ShrinkObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [JSONLShrinkObservation] = []

    var observations: [JSONLShrinkObservation] {
        lock.withLock { recorded }
    }

    func record(_ observation: JSONLShrinkObservation) {
        lock.withLock { recorded.append(observation) }
    }
}
