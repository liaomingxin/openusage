import Foundation

/// One scan's aggregate of local usage log files that are smaller than the parse the cache already
/// holds. Some clients rewrite transcripts in place (resume, compaction) and drop turns that were
/// already counted; a rescan then sees fewer rows, so that history and spend silently decrease.
///
/// This is observation-only telemetry: the cached-but-missing rows are deliberately NOT merged back
/// into the scan results yet. The point is to measure how often in-place rewrites actually happen
/// before deciding whether the riskier "re-add rows the cache has but the live file lost" repair is
/// worth building. Until then, spend for a shrunk file stays undercounted and this warning is the
/// only trace of why.
struct JSONLShrinkObservation: Sendable, Equatable {
    typealias Warning = @Sendable (JSONLShrinkObservation) -> Void

    /// How many file names the aggregated warning lists; beyond that only the count is reported.
    static let maxLoggedNames = 3

    /// One shrunk file, with both sides of the comparison. `reparsedItemCount` is nil when this
    /// scan's reparse of the file failed, so the record drop is not measurable.
    struct Candidate: Sendable {
        var path: String
        var cachedSize: Int
        var currentSize: Int
        var cachedItemCount: Int
        var reparsedItemCount: Int?
    }

    /// The provider/home cache identity whose scan observed the shrinks.
    var cacheIdentity: String
    /// How many files were smaller than their cached parse this scan.
    var fileCount: Int
    /// Total bytes the shrunk files lost versus their cached sizes.
    var bytesLost: Int
    /// How many previously parsed records the rescans no longer see. Nil when at least one shrunk
    /// file could not be reparsed, so the drop is only partially measurable.
    var recordsLost: Int?
    /// A few file names — never full paths, which can embed project names.
    var fileNames: [String]

    /// The exact warning text `warning(logTag:)` writes, split out so tests can pin the format
    /// (counts present, no full paths) without capturing the log sink.
    static func message(for observation: JSONLShrinkObservation) -> String {
        let noun = observation.fileCount == 1 ? "file" : "files"
        let listedNames = observation.fileNames.joined(separator: ", ")
        let extra = observation.fileCount > observation.fileNames.count
            ? " +\(observation.fileCount - observation.fileNames.count) more"
            : ""
        var recordsClause = ""
        if let recordsLost = observation.recordsLost {
            recordsClause = " and \(recordsLost) previously parsed records"
        }
        return "cache '\(observation.cacheIdentity)': \(observation.fileCount) local usage log \(noun) "
            + "shrank in place (\(listedNames)\(extra)); \(observation.bytesLost) bytes\(recordsClause) lost "
            + "versus the cached parse; a client rewrote them in place, so spend may be undercounted"
    }

    /// The default sink: one aggregated `AppLog.warn` line per scan that observed shrinks.
    static func warning(logTag: String) -> Warning {
        { observation in
            AppLog.warn(logTag, message(for: observation))
        }
    }
}

/// Aggregates a scan's in-place shrinks into one edge-triggered warning per (identity, path, cached
/// size). Detection is naturally one-shot while the rescan updates the cache to the smaller size,
/// but a scan canceled between detection and the cache update would otherwise re-log the same state
/// on every refresh — so remembered reports are only re-armed once the comparison actually changes.
/// Owned by `IncrementalJSONLScanner`'s actor isolation; no locking of its own.
struct JSONLShrinkObserver {
    /// cache identity -> path -> the cached size whose shrink was last reported.
    private var reportedCachedSizes: [String: [String: Int]] = [:]

    /// Compare this scan's files against the cache as it was before the scan and report the
    /// aggregate. Pure observation: nothing here feeds back into the scan's cache or results.
    /// `reparsedItemCount` is consulted synchronously (non-escaping) for the item count the rescan
    /// actually produced, which is what makes the lost-record count cheap to include.
    mutating func observe<Item: Codable & Sendable>(
        identity: String,
        since: Date,
        files: [JSONLScanning.DiscoveredFile],
        previousCache: [String: JSONLScanCachedFile<Item>],
        reparsedItemCount: (String) -> Int?,
        warning: JSONLShrinkObservation.Warning
    ) {
        var candidates: [String: JSONLShrinkObservation.Candidate] = [:]
        var scannedPaths: Set<String> = []
        for file in files where file.mtime >= since {
            scannedPaths.insert(file.path)
            guard let cached = previousCache[file.path], file.size < cached.size else { continue }
            candidates[file.path] = JSONLShrinkObservation.Candidate(
                path: file.path,
                cachedSize: cached.size,
                currentSize: file.size,
                cachedItemCount: cached.items.count,
                reparsedItemCount: reparsedItemCount(file.path)
            )
        }

        var reportedSizes = reportedCachedSizes[identity] ?? [:]
        // A path rechecked this scan that no longer shrank re-arms its edge, mirroring the
        // read-failure reporter's "only clear what this scan actually checked" rule.
        for path in scannedPaths where candidates[path] == nil {
            reportedSizes[path] = nil
        }
        let newlyShrunk = candidates.filter { reportedSizes[$0.key] != $0.value.cachedSize }
        guard !newlyShrunk.isEmpty else {
            reportedCachedSizes[identity] = reportedSizes.isEmpty ? nil : reportedSizes
            return
        }
        for (path, candidate) in newlyShrunk {
            reportedSizes[path] = candidate.cachedSize
        }
        reportedCachedSizes[identity] = reportedSizes

        var bytesLost = 0
        var recordsLost = 0
        var measurable = true
        var names: [String] = []
        for (path, candidate) in newlyShrunk.sorted(by: { $0.key < $1.key }) {
            bytesLost += candidate.cachedSize - candidate.currentSize
            if names.count < JSONLShrinkObservation.maxLoggedNames {
                names.append((path as NSString).lastPathComponent)
            }
            guard let reparsedCount = candidate.reparsedItemCount else {
                measurable = false
                continue
            }
            recordsLost += max(0, candidate.cachedItemCount - reparsedCount)
        }
        warning(JSONLShrinkObservation(
            cacheIdentity: identity,
            fileCount: newlyShrunk.count,
            bytesLost: bytesLost,
            recordsLost: measurable ? recordsLost : nil,
            fileNames: names
        ))
    }
}
