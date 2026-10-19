import XCTest
@testable import OpenUsage

@MainActor
final class SubscriptionExpiryStoreTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.SubscriptionExpiry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func snapshot(providerID: String = "cursor", lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(providerID: providerID, displayName: "Cursor", lines: lines)
    }

    private func expiry(at date: Date) -> SubscriptionExpiryStore.ResolvedExpiry {
        SubscriptionExpiryStore.ResolvedExpiry(providerID: "cursor", date: date, isEnding: false, source: .manual)
    }

    func testManualEntryPersistsAcrossInstancesAndCanBeEdited() throws {
        let defaults = makeScratchDefaults()
        let store = SubscriptionExpiryStore(defaults: defaults)
        let providerID = "claude@b367d9c5"
        let firstDate = date(2026, 11, 19)
        store.setExpiry(firstDate, for: providerID)

        let saved = try XCTUnwrap(store.entry(for: providerID))
        XCTAssertEqual(saved.expiresAt, firstDate)
        XCTAssertFalse(saved.isEnding)
        XCTAssertEqual(SubscriptionExpiryStore(defaults: defaults).entry(for: providerID), saved)
        XCTAssertNotNil(defaults.data(forKey: "openusage.subscriptionExpiries.v1"))

        let updatedDate = date(2027, 1, 19)
        store.setExpiry(updatedDate, isEnding: true, for: providerID)
        let updated = try XCTUnwrap(SubscriptionExpiryStore(defaults: defaults).entry(for: providerID))
        XCTAssertEqual(updated.expiresAt, updatedDate)
        XCTAssertTrue(updated.isEnding)
        XCTAssertGreaterThanOrEqual(updated.updatedAt, saved.updatedAt)
    }

    func testClearAndResetPersistWithoutAffectingOtherAccountEntries() {
        let defaults = makeScratchDefaults()
        let store = SubscriptionExpiryStore(defaults: defaults)
        let expiryDate = date(2026, 11, 19)
        let firstID = "cursor@bb6e42df"
        let secondID = "cursor@1234abcd"
        store.setExpiry(expiryDate, for: firstID)
        store.setExpiry(date(2026, 12, 19), for: secondID)
        store.setExpiry(expiryDate, for: "cursor")
        store.clearExpiry(for: firstID)

        let reloaded = SubscriptionExpiryStore(defaults: defaults)
        XCTAssertNil(reloaded.entry(for: firstID))
        XCTAssertEqual(reloaded.entry(for: secondID)?.expiresAt, date(2026, 12, 19))
        XCTAssertEqual(reloaded.entry(for: "cursor")?.expiresAt, expiryDate)

        reloaded.resetAll()
        let reset = SubscriptionExpiryStore(defaults: defaults)
        XCTAssertNil(reset.entry(for: "cursor"))
        XCTAssertNil(reset.entry(for: secondID))
        XCTAssertNil(defaults.object(forKey: SubscriptionExpiryStore.storageKey))
    }

    func testManualOverrideWinsUntilClearedThenAutomaticDateReturns() throws {
        let store = SubscriptionExpiryStore(defaults: makeScratchDefaults())
        let providerID = "codex@986103e1"
        let automaticDate = date(2026, 10, 25)
        let manualDate = date(2026, 11, 1)
        let automatic = snapshot(providerID: providerID, lines: [.subscription(at: automaticDate)])
        store.setExpiry(manualDate, isEnding: true, for: providerID)

        let overridden = try XCTUnwrap(store.resolvedExpiry(for: providerID, snapshot: automatic))
        XCTAssertEqual(overridden.providerID, providerID)
        XCTAssertEqual(overridden.date, manualDate)
        XCTAssertTrue(overridden.isEnding)
        XCTAssertEqual(overridden.source, .manual)
        XCTAssertEqual(store.resolvedExpiry(for: providerID, snapshot: nil), overridden)

        store.clearExpiry(for: providerID)
        let fallback = try XCTUnwrap(store.resolvedExpiry(for: providerID, snapshot: automatic))
        XCTAssertEqual(fallback.date, automaticDate)
        XCTAssertFalse(fallback.isEnding)
        XCTAssertEqual(fallback.source, .automatic)
    }

    func testAutomaticDatesDistinguishRenewalFromEndingAndSkipNonDateMetrics() throws {
        let store = SubscriptionExpiryStore(defaults: makeScratchDefaults())
        let automaticDate = date(2026, 10, 25)
        for isEnding in [false, true] {
            let automatic = snapshot(lines: [
                .text(label: "Plan", value: "Pro"),
                .progress(label: "Weekly", used: 1, limit: 100, format: .percent, resetsAt: date(2026, 10, 20)),
                .subscription(at: automaticDate, isEnding: isEnding)
            ])
            let resolved = try XCTUnwrap(store.resolvedExpiry(for: "cursor", snapshot: automatic))
            XCTAssertEqual(resolved.providerID, "cursor")
            XCTAssertEqual(resolved.date, automaticDate)
            XCTAssertEqual(resolved.isEnding, isEnding)
            XCTAssertEqual(resolved.source, .automatic)
        }
    }

    func testNoExpiryWithoutManualOrDateLine() {
        let store = SubscriptionExpiryStore(defaults: makeScratchDefaults())
        XCTAssertNil(store.resolvedExpiry(for: "grok@0a863e91", snapshot: nil))
        XCTAssertNil(store.resolvedExpiry(for: "cursor", snapshot: snapshot(lines: [
            .text(label: "Status", value: "Active")
        ])))
    }

    func testCountdownUsesCalendarDaysInsteadOfElapsedTwentyFourHours() {
        let now = date(2026, 10, 19, hour: 23)
        let cases: [(Int, String)] = [
            (-2, "Expired 2d ago"), (0, "Today"), (1, "Tomorrow"), (5, "in 5d")
        ]
        for (days, text) in cases {
            let target = calendar.date(byAdding: .day, value: days, to: date(2026, 10, 19, hour: 0))!
            let resolved = expiry(at: target)
            XCTAssertEqual(resolved.daysRemaining(now: now, calendar: calendar), days)
            XCTAssertEqual(resolved.countdownText(now: now, calendar: calendar), text)
        }
    }

    func testSeverityThresholdsIncludeExpiredTodayThreeAndSevenDays() {
        let now = date(2026, 10, 19)
        let cases: [(Int, WidgetData.MeterSeverity)] = [
            (-1, .critical), (0, .critical), (1, .critical), (3, .critical),
            (4, .warning), (7, .warning), (8, .normal)
        ]
        for (days, severity) in cases {
            let target = calendar.date(byAdding: .day, value: days, to: now)!
            XCTAssertEqual(expiry(at: target).severity(now: now, calendar: calendar), severity)
        }
    }

    func testCalendarDayDeltaAcrossDaylightSavingTime() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = losAngeles.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23))!
        let target = losAngeles.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0))!
        let resolved = expiry(at: target)
        XCTAssertEqual(resolved.daysRemaining(now: now, calendar: losAngeles), 2)
        XCTAssertEqual(resolved.countdownText(now: now, calendar: losAngeles), "in 2d")
    }

    func testExactDateIsZeroPaddedAndUsesRequestedCalendarTimeZone() {
        let instant = date(2026, 1, 2, hour: 0)
        XCTAssertEqual(expiry(at: instant).formattedDate(calendar: calendar), "2026-01-02")
        var west = calendar
        west.timeZone = TimeZone(secondsFromGMT: -8 * 60 * 60)!
        XCTAssertEqual(expiry(at: instant).formattedDate(calendar: west), "2026-01-01")
    }

    func testAccountIdentityAndEmailBindingAndFilePersistence() throws {
        let defaults1 = makeScratchDefaults()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.SubscriptionExpiry.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempFile) }

        let initialProviders = [
            Provider(id: "codex", familyName: "Codex", accountLabel: "dellabiddle1@gmail.com", icon: .providerMark("codex")),
            Provider(id: "codex@986103e1", familyName: "Codex", accountLabel: "other@gmail.com", icon: .providerMark("codex"))
        ]
        let initialKeys = SubscriptionExpiryStore.makeAccountKeys(
            providers: initialProviders,
            identityKeysByCard: ["codex": "2da66dc6-9e1b-4093-8ac3-58b5754a1899"]
        )
        let store = SubscriptionExpiryStore(
            defaults: defaults1,
            fileURL: tempFile,
            accountKeysByProviderID: initialKeys
        )
        let targetDate = date(2026, 11, 20)
        store.setExpiry(targetDate, isEnding: true, for: "codex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        // Simulate the default CLI slot swapping to another account while dellabiddle1 moves to an extra card ID,
        // and loading from the JSON file backup when UserDefaults is fresh.
        let defaults2 = makeScratchDefaults()
        let swappedProviders = [
            Provider(id: "codex", familyName: "Codex", accountLabel: "other@gmail.com", icon: .providerMark("codex")),
            Provider(id: "codex@2da66dc6", familyName: "Codex", accountLabel: "dellabiddle1@gmail.com", icon: .providerMark("codex"))
        ]
        let swappedKeys = SubscriptionExpiryStore.makeAccountKeys(
            providers: swappedProviders,
            identityKeysByCard: ["codex@2da66dc6": "2da66dc6-9e1b-4093-8ac3-58b5754a1899"]
        )
        let reloaded = SubscriptionExpiryStore(
            defaults: defaults2,
            fileURL: tempFile,
            accountKeysByProviderID: swappedKeys
        )
        XCTAssertEqual(reloaded.entry(for: "codex@2da66dc6")?.expiresAt, targetDate)
        XCTAssertEqual(reloaded.entry(for: "codex@2da66dc6")?.isEnding, true)
    }
}
