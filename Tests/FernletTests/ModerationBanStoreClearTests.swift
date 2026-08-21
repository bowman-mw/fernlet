// ModerationBanStoreClearTests.swift
// FernletTests
//
// `ModerationBanStore.clearPeerBansForDeleteAll()` — the "Delete everything" split (round
// 2026-08-20 Part 4.2): PEER-ban records name OTHER people's identity fingerprints, so a wiped
// device must not keep them; the shop SELF-ban deliberately survives every wipe (2026-07-17
// decision — a device ban a wipe could clear is a ban-evasion tool).

import XCTest
import FernletFoundation
@testable import ProximityKit

/// Test double: a monotonic clock whose value the test drives directly.
private final class MockMonotonicClock: MonotonicClock, @unchecked Sendable {
    var value: Double
    init(_ start: Double) { value = start }
    var seconds: Double { value }
}

/// Pins the peer/self split of the delete-everything clear: every `peerBan:` keychain row is
/// removed (verified through a fresh store instance, i.e. at the keychain, not in memory), the
/// `selfBan.device` row in the same service is untouched, and an empty service reports success.
@MainActor
final class ModerationBanStoreClearTests: XCTestCase {
    private func uniqueService() -> String { "com.fernlet.moderation.test.\(UUID().uuidString)" }

    func testClearRemovesEveryPeerBanRecord() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100)
        let store = ModerationBanStore(service: service, clock: clock)
        store.applyPeerBan(fingerprint: "abcd1234", durationDays: 30)
        store.applyPeerBan(fingerprint: "ffff0000", durationDays: 30)
        XCTAssertTrue(store.isPeerBanned(fingerprint: "abcd1234"))
        XCTAssertTrue(store.isPeerBanned(fingerprint: "ffff0000"))

        XCTAssertTrue(store.clearPeerBansForDeleteAll(), "every keychain delete should succeed")
        XCTAssertFalse(store.isPeerBanned(fingerprint: "abcd1234"))
        XCTAssertFalse(store.isPeerBanned(fingerprint: "ffff0000"))

        // A fresh store on the SAME service = the keychain rows themselves, not in-memory state.
        let reopened = ModerationBanStore(service: service, clock: clock)
        XCTAssertFalse(reopened.isPeerBanned(fingerprint: "abcd1234"),
                       "a cleared peer ban must be gone from the keychain, not just this instance")
        XCTAssertFalse(reopened.isPeerBanned(fingerprint: "ffff0000"))
        store.clearAllForTesting()
    }

    func testClearPreservesTheSelfBan() {
        let service = uniqueService()
        let clock = MockMonotonicClock(100)
        let store = ModerationBanStore(service: service, clock: clock)
        store.applySelfBan(durationDays: 30)
        store.applyPeerBan(fingerprint: "abcd1234", durationDays: 30)
        XCTAssertTrue(store.isSelfBanned)
        XCTAssertTrue(store.isPeerBanned(fingerprint: "abcd1234"))

        XCTAssertTrue(store.clearPeerBansForDeleteAll())
        XCTAssertTrue(store.isSelfBanned,
                      "the self-ban must survive the delete-everything clear (2026-07-17 decision)")
        XCTAssertFalse(store.isPeerBanned(fingerprint: "abcd1234"))

        // The surviving self-ban is the keychain row, not a cached read.
        let reopened = ModerationBanStore(service: service, clock: clock)
        XCTAssertTrue(reopened.isSelfBanned, "the self-ban row must still be in the keychain")
        store.clearAllForTesting()
    }

    func testClearWithNoPeerBansSucceedsAndTouchesNothing() {
        let service = uniqueService()
        let store = ModerationBanStore(service: service, clock: MockMonotonicClock(100))
        // Entirely empty service: nothing to remove is a clean clear, not a failure.
        XCTAssertTrue(store.clearPeerBansForDeleteAll())

        // Self-ban only: still nothing for the peer clear to remove.
        store.applySelfBan(durationDays: 30)
        XCTAssertTrue(store.clearPeerBansForDeleteAll())
        XCTAssertTrue(store.isSelfBanned)
        store.clearAllForTesting()
    }
}
