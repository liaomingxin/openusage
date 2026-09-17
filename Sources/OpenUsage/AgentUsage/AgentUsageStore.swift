import Foundation
import Observation

/// Owns the Agent Usage screen's data: one machine-wide scan pass per local agent, reduced into the
/// four window reports the screen switches between. Scans reuse the providers' incremental parse
/// caches, so a refresh after the first is cheap; the screen refreshes on appear when the last pass
/// is older than one refresh interval.
@MainActor
@Observable
final class AgentUsageStore {
    /// All four windows' reports from the last scan pass. An empty dictionary means "not scanned yet".
    private(set) var reports: [AgentUsageWindow: AgentUsageReport] = [:]
    private(set) var isLoading = false
    private(set) var lastRefreshAt: Date?

    private let makeSources: () -> [AgentUsageSource]
    private var refreshTask: Task<Void, Never>?

    /// `cursorSnapshot` reads the live provider snapshot store (a MainActor read captured before the
    /// scans detach), so the Cursor agent reuses the provider card's last refreshed history.
    init(cursorSnapshot: @escaping @MainActor () -> ProviderSnapshot?) {
        self.makeSources = {
            let snapshot = cursorSnapshot()
            return AgentUsageCatalog.make(cursorSnapshot: { snapshot })
        }
    }

    /// The report to render for a window: nil only before the first scan completes.
    func report(for window: AgentUsageWindow) -> AgentUsageReport? {
        reports[window]
    }

    /// Refresh when the screen appears with no scan or a stale one (one refresh interval old, the
    /// same cadence the provider cards use).
    func refreshIfNeeded(now: Date = Date()) {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < RefreshSetting.interval { return }
        refresh(now: now)
    }

    /// Runs every agent's scan concurrently, then reduces the results into the window reports. A
    /// pass already in flight is left alone — the await in the UI covers its completion.
    func refresh(now: Date = Date()) {
        guard refreshTask == nil else { return }
        isLoading = true
        let sources = makeSources()
        refreshTask = Task { [weak self] in
            let pricing = await ModelPricingStore.shared.current()
            let results = await withTaskGroup(of: AgentUsageAggregator.SourceResult.self) { group in
                for source in sources {
                    group.addTask { @Sendable in
                        AgentUsageAggregator.SourceResult(source: source, scan: await source.scan(pricing))
                    }
                }
                var results: [AgentUsageAggregator.SourceResult] = []
                results.reserveCapacity(sources.count)
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled else { return }
            self?.reports = AgentUsageAggregator.reports(from: results, now: now)
            self?.lastRefreshAt = now
            self?.isLoading = false
            self?.refreshTask = nil
        }
    }
}
