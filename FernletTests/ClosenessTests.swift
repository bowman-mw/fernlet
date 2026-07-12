import XCTest
import FernletDomainModel
@testable import ProximityKit

@MainActor
final class ClosenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func firstAccepted(_ keys: [String]) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, self.now) })
    }

    // MARK: - Day points

    func testInPersonSessionsOutweighHearts() {
        var oneSession = FriendInteractionDayCounts(); oneSession.sessions = 1
        XCTAssertEqual(oneSession.points, 5)

        var manyHearts = FriendInteractionDayCounts(); manyHearts.heartSent = 5; manyHearts.heartReceived = 5
        XCTAssertEqual(manyHearts.points, 3, "hearts count ≤1/direction/day + mutuality bonus")
        XCTAssertGreaterThan(oneSession.points, manyHearts.points, "one meeting outranks a pile of hearts")

        var everything = FriendInteractionDayCounts()
        everything.sessions = 2; everything.photoSessions = 1; everything.sharesAccepted = 1
        everything.heartSent = 1; everything.heartReceived = 1
        XCTAssertEqual(everything.points, 10, "a single day is capped at 10")
    }

    // MARK: - Closeness formula

    func testClosenessDecaysAcrossTheWindowAndExcludesOldDays() {
        var day = FriendInteractionDayCounts(); day.sessions = 1   // 5 points
        XCTAssertEqual(ClosenessMath.closeness(daily: [(ageDays: 0, counts: day)]), 5.0, accuracy: 1e-9)
        XCTAssertEqual(ClosenessMath.closeness(daily: [(ageDays: 30, counts: day)]), 5.0 / 31.0, accuracy: 1e-9)
        XCTAssertEqual(ClosenessMath.closeness(daily: [(ageDays: 31, counts: day)]), 0, "outside the 30-day window")
    }

    // MARK: - Close-slot assignment

    func testTopFourFillCloseSlots() {
        let eligible = ["a": 10.0, "b": 8.0, "c": 6.0, "d": 4.0, "e": 2.0]
        let s = CloseSlotAssignment.evaluate(
            eligible: eligible, firstAcceptedAt: firstAccepted(Array(eligible.keys)),
            state: CloseSlotState(), now: now, todayKey: "d0")
        XCTAssertEqual(Set(s.closeFingerprints), ["a", "b", "c", "d"])
    }

    func testChallengerBelowMarginDoesNotEvictIncumbent() {
        var state = CloseSlotState()
        state.closeFingerprints = ["a", "b", "c", "d"]
        let entered = now.addingTimeInterval(-5 * 86_400)   // past the 3-day dwell
        state.enteredAt = ["a": entered, "b": entered, "c": entered, "d": entered]
        // e (20) leads incumbent d (14) by only 6 < the 8-pt margin → no swap.
        let eligible = ["a": 20.0, "b": 18.0, "c": 16.0, "d": 14.0, "e": 20.0]
        let s = CloseSlotAssignment.evaluate(
            eligible: eligible, firstAcceptedAt: firstAccepted(Array(eligible.keys)),
            state: state, now: now, todayKey: "d1")
        XCTAssertTrue(s.closeFingerprints.contains("d"))
        XCTAssertFalse(s.closeFingerprints.contains("e"))

        // e now clears the margin (25 ≥ 14 + 8) → exactly one swap.
        var eligible2 = eligible; eligible2["e"] = 25.0
        let s2 = CloseSlotAssignment.evaluate(
            eligible: eligible2, firstAcceptedAt: firstAccepted(Array(eligible2.keys)),
            state: state, now: now, todayKey: "d1")
        XCTAssertTrue(s2.closeFingerprints.contains("e"))
        XCTAssertFalse(s2.closeFingerprints.contains("d"))
        XCTAssertEqual(s2.closeFingerprints.count, 4)
    }

    func testDwellProtectsAFreshlyPromotedCloseFriend() {
        var state = CloseSlotState()
        state.closeFingerprints = ["a", "b", "c", "d"]
        state.enteredAt = ["a": now, "b": now, "c": now, "d": now]   // all just entered → within dwell
        let eligible = ["a": 20.0, "b": 18.0, "c": 16.0, "d": 14.0, "e": 30.0]
        let s = CloseSlotAssignment.evaluate(
            eligible: eligible, firstAcceptedAt: firstAccepted(Array(eligible.keys)),
            state: state, now: now, todayKey: "d1")
        XCTAssertFalse(s.closeFingerprints.contains("e"), "no incumbent past dwell → no swap despite a big lead")
        XCTAssertTrue(s.closeFingerprints.contains("d"))
    }

    func testBlockedFriendVacatesTheSlotWhichRefillsFreely() {
        var state = CloseSlotState()
        state.closeFingerprints = ["a", "b", "c", "d"]
        state.enteredAt = ["a": now, "b": now, "c": now, "d": now]
        // d is no longer eligible (blocked → absent); e is a fresh eligible friend.
        let eligible = ["a": 10.0, "b": 8.0, "c": 6.0, "e": 4.0]
        let s = CloseSlotAssignment.evaluate(
            eligible: eligible, firstAcceptedAt: firstAccepted(Array(eligible.keys)),
            state: state, now: now, todayKey: "d1")
        XCTAssertFalse(s.closeFingerprints.contains("d"))
        XCTAssertTrue(s.closeFingerprints.contains("e"))
    }

    // MARK: - Ledger

    func testLedgerClosenessFromSessions() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let ledger = ClosenessLedger(fileURL: url, now: { self.now })
        ledger.recordSession(fingerprint: "abcd1234")
        XCTAssertGreaterThan(ledger.closeness(fingerprint: "abcd1234"), 0)
        XCTAssertEqual(ledger.closeness(fingerprint: "unknown"), 0)
        try? FileManager.default.removeItem(at: url)
    }
}
