// ModerationBanStoreClearTests.swift
// FernletTests
//
// `ModerationBanStore.clearPeerBansForDeleteAll()` — the "Delete everything" split (round
// 2026-08-20 Part 4.2): PEER-ban records name OTHER people's identity fingerprints, so a wiped
// device must not keep them; the shop SELF-ban deliberately survives every wipe (2026-07-17
// decision — a device ban a wipe could clear is a ban-evasion tool).

import XCTest
import Security
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

    // MARK: - Enumeration honesty

    /// A service that holds no rows is a CLEAN clear, not a failure: `SecItemCopyMatching` answers
    /// `errSecItemNotFound`, and the status-reporting enumeration must map that to an empty row set
    /// rather than to `.unreadable`. This is the case the wipe funnel hits on most devices, so
    /// getting it wrong would turn every honest wipe into a reported-incomplete one.
    func testServiceHoldingNoRowsEnumeratesAsACleanEmptySlot() {
        let service = uniqueService()
        guard case .rows(let rows) = KeychainItem.loadAllDistinguishingFailure(service: service) else {
            XCTFail("errSecItemNotFound must read as an empty slot, never as an unreadable one")
            return
        }
        XCTAssertTrue(rows.isEmpty)
        let store = ModerationBanStore(service: service, clock: MockMonotonicClock(100))
        XCTAssertTrue(store.clearPeerBansForDeleteAll(),
                      "nothing to remove is a clean clear, not an incomplete store")
    }

    /// The point of the variant, asserted side by side over one failing input: `loadAll` collapses a
    /// refused enumeration into `[]` — deliberately, and unchanged, because its escrow caller wants
    /// exactly that — while the reporting variant surfaces the status. An unnamed service is the one
    /// enumeration failure provokable without a locked device: `KeychainItem` refuses it as a caller
    /// bug (`errSecParam`) instead of pretending the slot is empty.
    func testEnumerationFailureIsDistinctWhereLoadAllCollapsesIt() {
        XCTAssertTrue(KeychainItem.loadAll(service: "").isEmpty,
                      "loadAll's documented error collapse must not change")
        guard case .unreadable(let status) = KeychainItem.loadAllDistinguishingFailure(service: "") else {
            XCTFail("a refused enumeration must not be presented as an empty slot")
            return
        }
        XCTAssertEqual(status, errSecParam)
    }

    /// The residual this closes: under the collapsing `loadAll`, a failed enumeration yielded zero
    /// peer accounts, therefore zero delete failures, therefore `true` — a clean-wipe promise made
    /// over records that may still be sitting in the keychain. The clear now fails closed, and
    /// `FernletStore` names "nearby designer bans" among the incomplete stores.
    func testClearReportsIncompleteWhenTheEnumerationItselfFails() {
        let store = ModerationBanStore(service: "", clock: MockMonotonicClock(100))
        XCTAssertFalse(store.clearPeerBansForDeleteAll(),
                       "an enumeration that failed must never be reported as a clean clear")
    }

    /// The statuses that actually threaten the promise — `errSecInteractionNotAllowed` (rows exist
    /// but are sealed before first unlock) and `errSecNotAvailable` — cannot be provoked against a
    /// simulator keychain, so the pure classification seam is driven directly with them.
    func testEnumerationResultMapsNotFoundToEmptyAndRealFailuresToUnreadable() {
        guard case .rows(let empty) = KeychainItem.enumerationResult(status: errSecItemNotFound, matches: nil) else {
            XCTFail("errSecItemNotFound must map to an empty row set")
            return
        }
        XCTAssertTrue(empty.isEmpty)

        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            guard case .unreadable(let reported) = KeychainItem.enumerationResult(status: status, matches: nil) else {
                XCTFail("a keychain that could not be read must never read as an empty one (\(status))")
                return
            }
            XCTAssertEqual(reported, status, "the failing status must survive to the audit log")
        }

        // Success carrying no attribute array is a shape we cannot read — unreadable, never empty.
        guard case .unreadable = KeychainItem.enumerationResult(status: errSecSuccess, matches: nil) else {
            XCTFail("a success with no rows array must not be presented as an empty slot")
            return
        }
    }

    /// A successful enumeration returns its rows, dropping only the ones missing the attributes the
    /// query asked for (not ours) — the behavior `clearPeerBansForDeleteAll` filters by prefix.
    func testEnumerationResultParsesRowsAndDropsUnusableOnes() {
        let matches: [[String: Any]] = [
            [kSecAttrAccount as String: "peerBan:abcd1234", kSecValueData as String: Data([1, 2, 3])],
            [kSecAttrAccount as String: "selfBan.device"],                 // no data
            [kSecValueData as String: Data([4])]                           // no account
        ]
        guard case .rows(let rows) = KeychainItem.enumerationResult(status: errSecSuccess, matches: matches) else {
            XCTFail("a successful enumeration must return its rows")
            return
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.account, "peerBan:abcd1234")
        XCTAssertEqual(rows.first?.data, Data([1, 2, 3]))
    }
}
