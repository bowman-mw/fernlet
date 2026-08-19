import XCTest
import FernletFoundation
import FernletDomainModel
@testable import ProximityKit

/// Test double: a monotonic clock whose value the test drives directly.
private final class MockMonotonicClock: MonotonicClock, @unchecked Sendable {
    var value: Double
    init(_ start: Double) { value = start }
    var seconds: Double { value }
}

@MainActor
final class ModerationBanTests: XCTestCase {
    private func uniqueService() -> String { "com.fernlet.moderation.test.\(UUID().uuidString)" }

    func testNotBannedByDefault() {
        let store = ModerationBanStore(service: uniqueService(), clock: MockMonotonicClock(100))
        XCTAssertFalse(store.isSelfBanned)
    }

    func testBanSurvivesFreshStoreInstance_reinstall() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store1 = ModerationBanStore(service: service, clock: clock, date: { now })
        store1.applySelfBan(durationDays: 30)
        XCTAssertTrue(store1.isSelfBanned)

        // A brand-new store on the SAME keychain service = the app reinstalled reading the surviving record.
        let store2 = ModerationBanStore(service: service, clock: clock, date: { now })
        XCTAssertTrue(store2.isSelfBanned, "the ban must survive delete + reinstall (keychain persistence)")
        _ = now
        store2.clearAllForTesting()
    }

    func testClockRollbackDoesNotLiftTheBanAndIsFlagged() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ModerationBanStore(service: service, clock: clock, date: { now })
        store.applySelfBan(durationDays: 30)
        XCTAssertTrue(store.isSelfBanned)

        // Roll the wall clock back 10 days; monotonic time is unchanged (same boot).
        now = now.addingTimeInterval(-10 * 86_400)
        XCTAssertTrue(store.isSelfBanned, "rolling the clock back must not shorten the ban")
        XCTAssertGreaterThan(store.selfBanTamperCount(), 0, "the backward clock move is detected")
        store.clearAllForTesting()
    }

    func testMonotonicTimeExpiresTheBan() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ModerationBanStore(service: service, clock: clock, date: { now })
        store.applySelfBan(durationDays: 30)
        XCTAssertTrue(store.isSelfBanned)

        // 30 days + a second of real (sleep-counting monotonic) time elapses, wall advancing with it.
        clock.value += 30 * 86_400 + 1
        now = now.addingTimeInterval(30 * 86_400 + 1)
        XCTAssertFalse(store.isSelfBanned, "the ban is served once real time has elapsed")
        store.clearAllForTesting()
    }

    func testForwardJumpPlusRebootCannotInstantServeTheBan() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100_000)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ModerationBanStore(service: service, clock: clock, date: { now })
        store.applySelfBan(durationDays: 30)
        XCTAssertTrue(store.isSelfBanned)

        // Attack: set the clock 40 days ahead and reboot (mach_continuous_time resets → the reboot
        // branch runs). The per-reboot wall-credit cap (2 days) must keep the 30-day ban active.
        clock.value = 5
        now = now.addingTimeInterval(40 * 86_400)
        XCTAssertTrue(store.isSelfBanned, "a single forward-jump + reboot must not serve the ban")
        store.clearAllForTesting()
    }

    func testPeerBanIsIndependentOfSelfBan() {
        let service = uniqueService()
        let store = ModerationBanStore(service: service, clock: MockMonotonicClock(100))
        store.applyPeerBan(fingerprint: "abcd1234", durationDays: 30)
        XCTAssertTrue(store.isPeerBanned(fingerprint: "abcd1234"))
        XCTAssertFalse(store.isPeerBanned(fingerprint: "ffff0000"))
        XCTAssertFalse(store.isSelfBanned)
        store.clearAllForTesting()
    }

    /// The self-ban's ONLY evidence source is foreign rows naming this device's own key as subject.
    ///
    /// L21 anti-regression. Because the relay is strictly one-hop (`verifiedRows` forces
    /// `reporterSigningPublicKey == senderSigningKey`), no third party ever forwards such a row — the
    /// reporter hands it to the person reported directly, which is why
    /// `ModerationReportRelay.buildPayload` deliberately does NOT filter rows whose subject is the
    /// recipient. A reviewer proposing that "obvious" privacy filter deletes the 30-day shop pause
    /// with nothing else in the build to notice; this test is what fails instead. The peer branch is
    /// covered by `testServedBanDoesNotReMintFromSameEvidenceButNewArtworkReArms` (subject != localKey).
    func testForeignRowsNamingLocalKeySelfBanTheShop() {
        let service = uniqueService()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ModerationBanStore(service: service, clock: MockMonotonicClock(100), date: { now })
        let localKey = Data([0])
        func foreignReport(_ reporter: UInt8, _ hash: UInt8) -> ModerationLedgerEntry {
            ModerationLedgerEntry(
                id: "report:\(reporter):\(hash)", kind: .report,
                reporterSigningPublicKey: Data([reporter]), subjectSigningPublicKey: localKey,
                itemID: UUID(), contentHash: Data([hash]), reasonToken: "offensive",
                reporterSeq: 1, createdAt: now)
        }
        XCTAssertFalse(store.isSelfBanned)
        // 3 of OUR items, each flagged by 2 distinct foreign reporters, spread within the per-reporter cap.
        let rows = [foreignReport(1, 1), foreignReport(2, 1),
                    foreignReport(1, 2), foreignReport(3, 2),
                    foreignReport(2, 3), foreignReport(3, 3)]
        store.reconcile(rows: rows, localSigningKey: localKey)
        XCTAssertTrue(store.isSelfBanned,
                      "rows naming the local key as subject must self-ban — they are its only evidence")
        store.clearAllForTesting()
    }

    /// A served 30-day ban must NOT re-mint from the same still-non-decayed reports (reports live 180d).
    /// Only a genuinely new offending artwork re-arms it. Regression for the ~210-day runaway ban.
    func testServedBanDoesNotReMintFromSameEvidenceButNewArtworkReArms() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ModerationBanStore(service: service, clock: clock, date: { now })
        let localKey = Data([0])
        let subject = Data([5])
        let fingerprint = IdentityService.fingerprint(of: subject)
        func report(_ reporter: UInt8, _ hash: UInt8) -> ModerationLedgerEntry {
            ModerationLedgerEntry(
                id: "report:\(reporter):\(hash)", kind: .report,
                reporterSigningPublicKey: Data([reporter]), subjectSigningPublicKey: subject,
                itemID: UUID(), contentHash: Data([hash]), reasonToken: "offensive",
                reporterSeq: 1, createdAt: now)
        }
        // 3 items, each with 2 distinct reporters spread within the per-reporter cap → designer ban warranted.
        let rows = [report(1, 1), report(2, 1), report(1, 2), report(3, 2), report(2, 3), report(3, 3)]

        store.reconcile(rows: rows, localSigningKey: localKey)
        XCTAssertTrue(store.isPeerBanned(fingerprint: fingerprint), "spread reports ban the designer")

        // Serve the 30-day ban (monotonic time, counting sleep, advances past the duration).
        clock.value += 30 * 86_400 + 1
        now = now.addingTimeInterval(30 * 86_400 + 1)
        XCTAssertFalse(store.isPeerBanned(fingerprint: fingerprint), "the 30-day ban serves out")

        // Same reports, still inside their 180-day window: reconcile must NOT re-mint the ban.
        store.reconcile(rows: rows, localSigningKey: localKey)
        XCTAssertFalse(store.isPeerBanned(fingerprint: fingerprint),
                       "a served ban must not re-mint from unchanged evidence")

        // A brand-new offending artwork (new content hash, fresh reporters) re-arms the ban.
        let withNewItem = rows + [report(6, 4), report(7, 4)]
        store.reconcile(rows: withNewItem, localSigningKey: localKey)
        XCTAssertTrue(store.isPeerBanned(fingerprint: fingerprint),
                      "a genuinely new offending item re-arms the ban")
        store.clearAllForTesting()
    }
}
