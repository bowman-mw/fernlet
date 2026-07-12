import XCTest
import FernletFoundation
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
        var now = Date(timeIntervalSince1970: 1_800_000_000)
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

    func testPeerBanIsIndependentOfSelfBan() {
        let service = uniqueService()
        let store = ModerationBanStore(service: service, clock: MockMonotonicClock(100))
        store.applyPeerBan(fingerprint: "abcd1234", durationDays: 30)
        XCTAssertTrue(store.isPeerBanned(fingerprint: "abcd1234"))
        XCTAssertFalse(store.isPeerBanned(fingerprint: "ffff0000"))
        XCTAssertFalse(store.isSelfBanned)
        store.clearAllForTesting()
    }
}
