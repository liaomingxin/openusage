import XCTest
@testable import OpenUsage

@MainActor
final class UsageHistoryClassificationTests: XCTestCase {
    func testEverySpendProviderHasOneExplicitHistoryClassification() {
        let descriptorSets = [
            AntigravityProvider().widgetDescriptors,
            ClaudeProvider().widgetDescriptors,
            CodexProvider().widgetDescriptors,
            CursorProvider().widgetDescriptors,
            GrokProvider().widgetDescriptors,
            OpenCodeProvider().widgetDescriptors
        ]

        for descriptors in descriptorSets {
            XCTAssertTrue(descriptors.contains(where: \.isSpendTile))
            // Exactly one machine-local classification each: that's the one the spend tiles, the
            // last-good history and the iCloud sync document all read, so two of them would let a
            // second source double-count into the same rows.
            XCTAssertEqual(descriptors.compactMap(\.historyResource).count { $0.scope == .machineLocal } <= 1, true,
                           descriptors[0].providerID)
            XCTAssertEqual(descriptors.compactMap(\.historyResource).isEmpty, false)
        }

        // Codex declares a second, account-wide resource beside its local one (OpenAI's own rollup,
        // rendered as its own separate rows). It must never become the provider's classification.
        let codex = CodexProvider().widgetDescriptors.compactMap(\.historyResource)
        XCTAssertEqual(codex.count, 2)
        XCTAssertEqual(codex.count { $0.scope == .accountWide }, 1)
        XCTAssertEqual(codex.first { $0.scope == .accountWide }?.estimatedCost, false)

        let classifications = Dictionary(uniqueKeysWithValues: descriptorSets.compactMap { descriptors in
            let resources = descriptors.compactMap(\.historyResource)
            let resolved = resources.first { $0.scope == .machineLocal } ?? resources.first
            return resolved.map { (descriptors[0].providerID, $0.scope) }
        })
        XCTAssertEqual(classifications, [
            "antigravity": .machineLocal,
            "claude": .machineLocal,
            "codex": .machineLocal,
            "cursor": .accountWide,
            "grok": .machineLocal,
            "opencode": .machineLocal
        ])
    }
}
