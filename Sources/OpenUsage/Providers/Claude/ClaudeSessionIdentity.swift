import Foundation

/// Who a session belongs to. Conflicting ownership must never be treated as an unattributed session.
///
/// Fork: a session can carry a stray ownership record from somewhere else — a remote/bridge attachment
/// stamps the account driving it, a handful of lines among hundreds — so ownership follows the
/// organization that owns most of the session's records. Only a genuine tie is `conflicted`, and a tie
/// is still excluded everywhere: that is a guess, not a gap. See FORK.md.
enum ClaudeSessionIdentity: Equatable, Sendable {
    case owned(organizationID: String, accountID: String?)
    case unattributed
    case conflicted

    /// Search bounded byte ranges instead of materializing an array of every line. Even a huge
    /// single record checks cancellation each megabyte; complete records still cross chunk edges.
    static func parse(
        _ data: Data,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Self? {
        let newline = Data([UInt8(ascii: "\n")])
        let marker = Data(#""ownerOrganizationUuid""#.utf8)
        // Records per organization, and per account within it: the majority owner wins.
        var organizationCounts: [String: Int] = [:]
        var accountCounts: [String: [String: Int]] = [:]
        var lineStart = data.startIndex
        var cursor = lineStart
        while cursor < data.endIndex {
            guard !isCancelled() else { return nil }
            let chunkEnd = min(cursor + 1_048_576, data.endIndex)
            while cursor < chunkEnd {
                let separator = data.range(of: newline, in: cursor..<chunkEnd)
                let end = separator?.lowerBound ?? chunkEnd
                cursor = separator?.upperBound ?? chunkEnd
                guard separator != nil || end == data.endIndex else { continue }
                let line = data[lineStart..<end]
                lineStart = cursor
                guard line.range(of: marker) != nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let value = object["ownerOrganizationUuid"] as? String, !value.isEmpty
                else { continue }
                let organization = value.lowercased()
                organizationCounts[organization, default: 0] += 1
                if let account = object["ownerAccountUuid"] as? String, !account.isEmpty {
                    accountCounts[organization, default: [:]][account.lowercased(), default: 0] += 1
                }
            }
        }
        guard !isCancelled() else { return nil }
        guard let organization = majority(of: organizationCounts) else {
            return organizationCounts.isEmpty ? .unattributed : .conflicted
        }
        return .owned(organizationID: organization, accountID: majority(of: accountCounts[organization] ?? [:]))
    }

    /// The key holding strictly more records than any other; `nil` for an empty tally or a tie.
    private static func majority(of counts: [String: Int]) -> String? {
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        guard counts.filter({ $0.value == best.value }).count == 1 else { return nil }
        return best.key
    }
}
