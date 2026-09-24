// ModerationBanRecoveryTests.swift
// FernletTests
//
// Tracker §3.5 (2026-09-24): the store ban's recovery path. A ban records the evidence it rests on
// and LIFTS when the reporters themselves withdraw enough of it — and nothing the banned person can
// do alone (a wipe, a reinstall, blocking or removing reporters, their own rows, a clock move) counts
// as a withdrawal. Policy note: Docs/Moderation-SelfBan-Recovery-2026-09-23.md.
//
// Every store here runs on its own throwaway keychain service and clears it at the end, like
// `ModerationBanTests`, so nothing reaches the production `com.fernlet.moderation` rows that
// `FernletStore.listCustomItemForSale` reads in other suites.

import Foundation
import Testing
import FernletFoundation
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

/// A monotonic clock the test drives directly (the ban clock's `mach_continuous_time` stand-in).
private final class RecoveryTestClock: MonotonicClock, @unchecked Sendable {
    var value: Double
    init(_ start: Double) { value = start }
    var seconds: Double { value }
}

/// Rows and stores for one scenario: a subject (this device, key `[0]`), foreign reporters `[r]`,
/// artworks `[h]`, and a ban store on a throwaway keychain service.
@MainActor
private struct Scenario {
    let service = "com.fernlet.moderation.test.\(UUID().uuidString)"
    let clock = RecoveryTestClock(1_000)
    let localKey = Data([0])
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func store() -> ModerationBanStore {
        let now = self.now
        return ModerationBanStore(service: service, clock: clock, date: { now })
    }

    func row(_ kind: ModerationEntryKind, reporter: UInt8, hash: UInt8, seq: UInt64,
             subject: Data? = nil, ageDays: Double = 0) -> ModerationLedgerEntry {
        let reporterKey = Data([reporter])
        return ModerationLedgerEntry(
            id: ModerationLedgerEntry.rowID(kind: kind, reporterFingerprint: IdentityService.fingerprint(of: reporterKey),
                                            contentHash: Data([hash])),
            kind: kind, reporterSigningPublicKey: reporterKey, subjectSigningPublicKey: subject ?? localKey,
            itemID: UUID(), contentHash: Data([hash]), reasonToken: "offensive", reporterSeq: seq,
            createdAt: now.addingTimeInterval(-ageDays * 86_400))
    }

    func report(_ reporter: UInt8, _ hash: UInt8, seq: UInt64 = 1, subject: Data? = nil) -> ModerationLedgerEntry {
        row(.report, reporter: reporter, hash: hash, seq: seq, subject: subject)
    }

    func retract(_ reporter: UInt8, _ hash: UInt8, seq: UInt64 = 2, subject: Data? = nil) -> ModerationLedgerEntry {
        row(.retract, reporter: reporter, hash: hash, seq: seq, subject: subject)
    }

    /// The minimal ban: three reporters over three artworks, two each, every one inside the
    /// per-reporter cap — r1 on {1,2}, r2 on {1,3}, r3 on {2,3}. ONE withdrawal takes an artwork
    /// below two reporters, and with it the designer below three qualifying artworks.
    func minimalBan(subject: Data? = nil) -> [ModerationLedgerEntry] {
        [report(1, 1, subject: subject), report(2, 1, subject: subject),
         report(1, 2, subject: subject), report(3, 2, subject: subject),
         report(2, 3, subject: subject), report(3, 3, subject: subject)]
    }
}

// MARK: - Pure decisions

/// ``ModerationBanRecovery`` alone: what counts as a withdrawal, how evidence merges and stays
/// bounded, and the monotone threshold.
struct ModerationBanRecoveryRuleTests {
    private let tag: (Data) -> Data = { $0 }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ kind: ModerationEntryKind, _ reporter: UInt8, _ hash: UInt8, seq: UInt64) -> ModerationLedgerEntry {
        ModerationLedgerEntry(id: "\(kind.rawValue):\(reporter):\(hash)", kind: kind,
                              reporterSigningPublicKey: Data([reporter]), subjectSigningPublicKey: Data([0]),
                              itemID: UUID(), contentHash: Data([hash]), reasonToken: "offensive",
                              reporterSeq: seq, createdAt: now)
    }

    private func evidence(_ reporter: UInt8, _ hash: UInt8, seq: UInt64 = 1) -> BanEvidence {
        BanEvidence(reporterTag: Data([reporter]), contentHash: Data([hash]), reporterSeq: seq)
    }

    /// Absence is never a withdrawal: the ledger is exactly what a wipe, a reinstall or an eviction
    /// empties, and a banned person controls all three.
    @Test func anAbsentRowIsNeverAWithdrawal() {
        let recorded = [evidence(1, 1), evidence(2, 1)]
        #expect(ModerationBanRecovery.withdrawn(recorded, in: [], excludingReporter: nil, tag: tag).isEmpty)
        let unrelated = [entry(.retract, 9, 9, seq: 5)]
        #expect(ModerationBanRecovery.withdrawn(recorded, in: unrelated, excludingReporter: nil, tag: tag).isEmpty)
    }

    /// Only a retract that WINS for its (reporter, artwork) and beats the recorded seq withdraws.
    @Test func onlyAWinningNewerRetractWithdraws() {
        let recorded = [evidence(1, 1, seq: 3)]
        let stale = [entry(.retract, 1, 1, seq: 3)]
        #expect(ModerationBanRecovery.withdrawn(recorded, in: stale, excludingReporter: nil, tag: tag).isEmpty,
                "a retract no newer than the recorded report withdraws nothing")
        let reReported = [entry(.retract, 1, 1, seq: 4), entry(.report, 1, 1, seq: 5)]
        #expect(ModerationBanRecovery.withdrawn(recorded, in: reReported, excludingReporter: nil, tag: tag).isEmpty,
                "a re-report after the retract supersedes it")
        let withdrawn = [entry(.report, 1, 1, seq: 3), entry(.retract, 1, 1, seq: 4)]
        #expect(ModerationBanRecovery.withdrawn(recorded, in: withdrawn, excludingReporter: nil, tag: tag)
                == [evidence(1, 1, seq: 3)])
    }

    /// The banned device's own rows withdraw nothing — not even its own recorded evidence.
    @Test func theExcludedReportersRowsWithdrawNothing() {
        let recorded = [evidence(0, 1)]
        let own = [entry(.retract, 0, 1, seq: 9)]
        #expect(ModerationBanRecovery.withdrawn(recorded, in: own, excludingReporter: Data([0]), tag: tag).isEmpty)
    }

    /// The threshold counts WITHOUT the per-reporter cap, so it is monotone and never below the
    /// capped count: two reporters spamming three artworks is "no ban" to the capped rule and still
    /// "meets the threshold" here — the direction that can only keep a ban, never lift one early.
    @Test func thresholdIsTheMonotoneUncappedCount() {
        let minimal = [evidence(1, 1), evidence(2, 1), evidence(1, 2), evidence(3, 2), evidence(2, 3), evidence(3, 3)]
        #expect(ModerationBanRecovery.reachesBanThreshold(minimal))
        #expect(!ModerationBanRecovery.reachesBanThreshold(Array(minimal.dropFirst())))
        let twoSpammers = [evidence(1, 1), evidence(2, 1), evidence(1, 2), evidence(2, 2), evidence(1, 3), evidence(2, 3)]
        #expect(ModerationBanRecovery.reachesBanThreshold(twoSpammers))
    }

    /// Merging keeps one entry per (reporter, artwork) at its highest seq, in a canonical order, and
    /// never more than `maxEvidence` — preferring the artworks with the most reporters.
    @Test func mergeDedupesBoundsAndKeepsTheMostReportedArtworks() {
        let merged = ModerationBanRecovery.merged([evidence(1, 1, seq: 1)], with: [evidence(1, 1, seq: 4), evidence(2, 1)])
        #expect(merged == [evidence(1, 1, seq: 4), evidence(2, 1)])
        #expect(ModerationBanRecovery.merged(merged.reversed(), with: []) == merged, "canonical order")

        // 100 single-reporter artworks from one flooder, plus the three qualifying artworks.
        let flood = (0..<100).map { BanEvidence(reporterTag: Data([0xEE]), contentHash: Data([0xF0, UInt8($0)]), reporterSeq: 1) }
        let real = [evidence(1, 1), evidence(2, 1), evidence(1, 2), evidence(3, 2), evidence(2, 3), evidence(3, 3)]
        let bounded = ModerationBanRecovery.merged(flood, with: real)
        #expect(bounded.count == ModerationBanRecovery.maxEvidence)
        #expect(Set(real).isSubset(of: Set(bounded)), "a flood of one-reporter artworks never evicts the ban's evidence")
        #expect(ModerationBanRecovery.reachesBanThreshold(bounded))
    }
}

// MARK: - Lifting

/// The store's two-directional reconcile: withdrawals lift, and only withdrawals.
@MainActor
struct ModerationBanRecoveryLiftTests {

    /// One reporter withdrawing ONE report takes the minimal ban below the threshold, and the ban
    /// lifts: not banned, nothing left to wait for.
    @Test func aWithdrawalBelowTheThresholdLiftsTheSelfBan() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan()
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)

        store.reconcile(rows: rows + [scenario.retract(1, 1)], localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned, "r1 withdrew artwork 1's report: two artworks left, below three")
        #expect(store.selfBanRemainingSeconds() == 0)
    }

    /// A withdrawal that leaves the threshold met changes nothing the user can see.
    @Test func aWithdrawalThatLeavesTheThresholdMetKeepsTheBan() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan() + [scenario.report(4, 1)]   // artwork 1 has a third reporter
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)

        store.reconcile(rows: rows + [scenario.retract(1, 1)], localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned, "artwork 1 still has two reporters (r2, r4)")
    }

    /// Withdrawals accumulate across reconciles and SURVIVE a wipe of the ledger that proved them:
    /// the second one lifts even though the first one's retract row is gone by then.
    @Test func withdrawalsAccumulateAndOutliveTheirLedgerRows() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan() + [scenario.report(4, 1), scenario.report(4, 2)]
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)

        store.reconcile(rows: rows + [scenario.retract(4, 1)], localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned, "one withdrawal of a spare report does not lift")
        store.reconcile(rows: [], localSigningKey: scenario.localKey)          // the ledger is wiped
        #expect(store.isSelfBanned)
        store.reconcile(rows: [scenario.retract(1, 1)], localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned, "r4's earlier withdrawal still counts: artwork 1 is down to r2 alone")
    }

    /// A reporter who withdraws and then reports AGAIN re-arms the ban — the lift handed the
    /// artworks back rather than filing them as "already served".
    @Test func aReReportAfterALiftReArmsTheBan() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan()
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        store.reconcile(rows: rows + [scenario.retract(1, 1)], localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned)

        store.reconcile(rows: rows + [scenario.retract(1, 1), scenario.report(1, 1, seq: 3)],
                        localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned, "the same artworks, re-reported, must be able to ban again")
    }

    /// A lift does not bounce straight back: the evidence that is left does not warrant a ban.
    @Test func aLiftedBanDoesNotReArmFromTheEvidenceThatIsLeft() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan() + [scenario.retract(1, 1)]
        store.reconcile(rows: scenario.minimalBan(), localSigningKey: scenario.localKey)
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned)
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned)
        #expect(store.selfBanRemainingSeconds() == 0)
    }

    /// A ban written without evidence — every record from before 2026-09-24, and the direct
    /// `applySelfBan` path — has nothing to withdraw, so it can only serve out.
    @Test func aBanWithoutRecordedEvidenceNeverLifts() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        store.applySelfBan(durationDays: 30)
        let everythingWithdrawn = scenario.minimalBan().map { scenario.retract($0.reporterSigningPublicKey[0], $0.contentHash[0]) }
        store.reconcile(rows: scenario.minimalBan() + everythingWithdrawn, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)
    }

    /// Peer bans answer to the same rule: this device's own ban on a designer lifts when the
    /// reporters behind it withdraw.
    @Test func aPeerBanLiftsWhenItsReportersWithdraw() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let designer = Data([0x5A])
        let fingerprint = IdentityService.fingerprint(of: designer)
        let rows = scenario.minimalBan(subject: designer)
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(store.isPeerBanned(fingerprint: fingerprint))

        store.reconcile(rows: rows + [scenario.retract(2, 3, subject: designer)], localSigningKey: scenario.localKey)
        #expect(!store.isPeerBanned(fingerprint: fingerprint))
    }
}

// MARK: - Adversarial: nothing the banned person does alone lifts a ban

/// Each cell drives one thing a legitimately banned person controls and requires the ban to stand.
/// The minimal ban is used throughout, so ONE genuine withdrawal would lift it — the cells prove that
/// none of these is mistaken for one. The last line of each cell then delivers a real withdrawal and
/// requires the lift, so a cell cannot pass by breaking lifting altogether.
@MainActor
struct ModerationBanRecoveryAdversarialTests {

    /// "Delete everything": the moderation ledger is cleared, the identity rotates (a new local key),
    /// and the peer bans are swept — the self-ban row and its evidence survive all three.
    @Test func deleteEverythingDoesNotLiftTheSelfBan() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("ban-recovery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let ledger = ModerationLedger(fileURL: ledgerURL, now: { scenario.now })
        ledger.ingestForeign(scenario.minimalBan())
        store.reconcile(rows: ledger.rows, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)
        let before = store.selfBanRemainingSeconds()

        ledger.clearAll()                                        // resetAll
        #expect(store.clearPeerBansForDeleteAll())               // the funnel's peer sweep
        let rotatedKey = Data([0x77])                            // the wipe mints a fresh identity
        store.reconcile(rows: ledger.rows, localSigningKey: rotatedKey)
        #expect(store.isSelfBanned)
        #expect(store.selfBanRemainingSeconds() >= before - 1)

        store.reconcile(rows: [scenario.retract(1, 1)], localSigningKey: rotatedKey)
        #expect(!store.isSelfBanned, "a real withdrawal still lifts after the wipe")
    }

    /// A reinstall: a brand-new store over the SAME keychain service (the row survives uninstall)
    /// and an empty ledger (the sidecar does not).
    @Test func aReinstallDoesNotLiftTheSelfBan() {
        let scenario = Scenario()
        let first = scenario.store()
        defer { first.clearAllForTesting() }
        first.reconcile(rows: scenario.minimalBan(), localSigningKey: scenario.localKey)
        #expect(first.isSelfBanned)

        let reinstalled = scenario.store()
        reinstalled.reconcile(rows: [], localSigningKey: scenario.localKey)
        #expect(reinstalled.isSelfBanned)

        reinstalled.reconcile(rows: [scenario.retract(3, 2)], localSigningKey: scenario.localKey)
        #expect(!reinstalled.isSelfBanned, "the evidence rode the keychain row across the reinstall")
    }

    /// Blocking or removing a reporter: their rows stop arriving (the mesh drops a blocked or
    /// untrusted sender) and the ledger can later lose the ones it has. Absence is not withdrawal.
    @Test func blockingOrRemovingTheReportersDoesNotLiftTheSelfBan() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan()
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)

        let withoutR1 = rows.filter { $0.reporterSigningPublicKey != Data([1]) }
        store.reconcile(rows: withoutR1, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned, "r1's rows are gone, not withdrawn")
        store.reconcile(rows: [], localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned, "every reporter blocked and every row gone is still not a withdrawal")

        store.reconcile(rows: [scenario.retract(2, 1)], localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned)
    }

    /// The banned device's own rows never count for or against its own ban — only the people who
    /// reported it can withdraw. The sharp case: a ban the capped rule reached only WITH the device's
    /// own reports of itself (r1 {1,2}, r2 {1,3}, self {2,3}). Were its own rows evidence, retracting
    /// them would be the banned person lifting their ban by their own hand.
    @Test func theBannedDevicesOwnRowsNeverLiftItsBan() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let own: (ModerationEntryKind, UInt8) -> ModerationLedgerEntry = { kind, hash in
            ModerationLedgerEntry(
                id: "\(kind.rawValue):self:\(hash)", kind: kind, reporterSigningPublicKey: scenario.localKey,
                subjectSigningPublicKey: scenario.localKey, itemID: UUID(), contentHash: Data([hash]),
                reasonToken: "other", reporterSeq: kind == .report ? 1 : 99, createdAt: scenario.now)
        }
        let rows = [scenario.report(1, 1), scenario.report(2, 1), scenario.report(1, 2),
                    scenario.report(2, 3), own(.report, 2), own(.report, 3)]
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)

        let ownRetracts = [own(.retract, 1), own(.retract, 2), own(.retract, 3)]
        store.reconcile(rows: rows + ownRetracts, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned, "the device's own retractions are not withdrawals")

        store.reconcile(rows: rows + ownRetracts + [scenario.retract(1, 1)], localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned, "a reporter's withdrawal still lifts it")
    }

    /// A retract signed by someone who never reported (a friend of the banned person, or a Sybil
    /// they made) matches no recorded evidence and withdraws nothing — including after a wipe, when
    /// the reporters' own rows are no longer in the ledger to vouch for themselves.
    @Test func aRetractFromSomeoneWhoNeverReportedWithdrawsNothing() {
        let scenario = Scenario()
        let store = scenario.store()
        defer { store.clearAllForTesting() }
        let rows = scenario.minimalBan()
        store.reconcile(rows: rows, localSigningKey: scenario.localKey)
        let strangers = (1...3).map { scenario.retract(0x40, UInt8($0), seq: 50) }
        store.reconcile(rows: rows + strangers, localSigningKey: scenario.localKey)
        #expect(store.isSelfBanned)
        store.reconcile(rows: strangers, localSigningKey: scenario.localKey)   // the ledger was wiped first
        #expect(store.isSelfBanned, "a stranger's retract is not the reporter's")

        store.reconcile(rows: strangers + [scenario.retract(1, 2)], localSigningKey: scenario.localKey)
        #expect(!store.isSelfBanned)
    }

    /// Clock moves: a far-forward wall clock DECAYS every report in the ledger (reports stop
    /// counting after 180 days) and a reboot tries to bank the jump; rolling it back is the
    /// tamper trap. Neither decay nor either jump is a withdrawal.
    @Test func clockChangesDoNotLiftTheSelfBan() {
        var scenario = Scenario()
        let rows = scenario.minimalBan()
        let start = scenario.store()
        defer { start.clearAllForTesting() }
        start.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(start.isSelfBanned)

        scenario.now = scenario.now.addingTimeInterval(200 * 86_400)   // every report has decayed
        scenario.clock.value = 5                                        // …and the device rebooted
        let forward = scenario.store()
        forward.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(forward.isSelfBanned, "decay and a forward jump are not withdrawals")

        scenario.now = scenario.now.addingTimeInterval(-400 * 86_400)  // then rolled far back
        let backward = scenario.store()
        backward.reconcile(rows: rows, localSigningKey: scenario.localKey)
        #expect(backward.isSelfBanned)

        backward.reconcile(rows: rows + [scenario.retract(2, 3)], localSigningKey: scenario.localKey)
        #expect(!backward.isSelfBanned, "a real withdrawal lifts whatever the clock says")
    }
}

// MARK: - The honest remaining time (the shop-closed alert)

/// `ShopBanRemainingTime` — the alert used to say the shop reopens "after a while"; it now names
/// the time, rounded UP to one friendly unit, in the user's locale.
@MainActor
struct ShopBanRemainingTimeTests {
    private let english = Locale(identifier: "en_US")

    @Test func roundsUpToOneFriendlyUnit() {
        let cases: [(seconds: Double, count: Int64, unit: ShopBanRemainingTime.Unit)] = [
            (30 * 86_400, 30, .days),
            (29.5 * 86_400, 30, .days),          // never promises the shop back early
            (2 * 86_400, 2, .days),
            (36 * 3_600, 36, .hours),            // under two days reads in hours, not "2 days"
            (90 * 60, 2, .hours),
            (3_600, 1, .hours),
            (59 * 60, 59, .minutes),
            (20, 1, .minutes)
        ]
        for testCase in cases {
            let rounded = ShopBanRemainingTime.roundedUp(testCase.seconds)
            #expect(rounded.count == testCase.count && rounded.unit == testCase.unit,
                    "\(testCase.seconds)s → \(rounded.count) \(rounded.unit)")
        }
    }

    /// A reading that is zero, negative or not a number still answers the smallest honest value
    /// (the caller only asks while the ban is on), and nothing traps.
    @Test func degenerateReadingsFloorAtOneMinute() {
        for seconds in [0, -5, .nan, .infinity, -.infinity] as [Double] {
            let rounded = ShopBanRemainingTime.roundedUp(seconds)
            #expect(rounded.count == 1 && rounded.unit == .minutes)
        }
        #expect(ShopBanRemainingTime.roundedUp(1e300).unit == .days, "an impossible reading clamps rather than trapping")
    }

    @Test func formatsInTheUsersLocale() {
        #expect(ShopBanRemainingTime.text(seconds: 30 * 86_400, locale: english) == "30 days")
        #expect(ShopBanRemainingTime.text(seconds: 3_600, locale: english) == "1 hour")
        #expect(ShopBanRemainingTime.text(seconds: 59 * 60, locale: english) == "59 minutes")
        let german = ShopBanRemainingTime.text(seconds: 30 * 86_400, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("30") && german.contains("Tage"), "the unit word is Foundation's, per locale: \(german)")
    }
}
