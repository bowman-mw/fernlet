// Phase3ReadoutSessionTests.swift
// FernletTests
//
// The stateful half of the Phase 3 gate readout: `Phase3ReadoutSession` (the sitting's
// process-scoped home for every purchased reading, including the five-step checklist) and the
// store-side clear that stands between a wipe and a stale reading.
//
// The fold has `Phase3GateReadoutTests`; this file exists because none of the rules below live in
// the fold. The checklist's done-states, the two fences (`scanGeneration` and `epoch`), the probe
// cap's eviction policy and `clear()` were 300+ lines of untested state.
//
// It used to also pin a store-side keyed sealed-column witness that lived OUTSIDE the session, so
// that clearing the session alone could not manufacture a discharge. That witness, the migrator
// that produced it and the store properties that held it all went with `ColumnCrypto`'s legacy read
// rung; the session is now the whole of what a wipe has to reach, and the duress test below is what
// pins that it still does.
//
// Deliberately NOT wrapped in `#if DEBUG`, for the reason `CryptoFormatCensusTests` states: the
// scheme pins the test action to Debug, so guarding the suite would trade a compile error nobody
// can miss for a suite that evaporates silently.

import CloudKitSync
import Foundation
import Testing
import FernletFoundation
import FernletLock
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit
@testable import Fernlet

/// Pins ``Phase3ReadoutSession`` — the checklist, the fences, the caps, and the clear.
@MainActor
@Suite(.serialized)
struct Phase3ReadoutSessionTests {

    private static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    private func stamp(_ label: String, offset: TimeInterval = 0) -> Phase3Stamp {
        Phase3Stamp(label: label, takenAt: Self.epoch.addingTimeInterval(offset))
    }

    private func latches() -> Phase3LatchReadings {
        Phase3LatchReadings(mediaAtRest: true, sealedPhotoBackup: true)
    }

    private func readings() -> CryptoFormatCensus.Readings {
        CryptoFormatCensus.Readings(
            sealedColumns: .counted(SealedColumnFormatCensusResult(
                columns: [:], rowsScanned: 0, rowsAvailable: 0, truncated: false, rowCap: 20_000)),
            pendingNarrative: PendingNarrativeBufferFormatCensus(
                format: .absent,
                fileURL: URL(fileURLWithPath: "/tmp/phase3-session/PendingNarratives.bin")),
            media: MediaAtRestFormatCensusReport(locations: []),
            lockWrap: LockWrapFormatCensusReport(keychainService: "com.fernlet.lock.test.session",
                                                 account: LockWrapFormatCensus.account,
                                                 state: .v2Marked),
            heartDrop: HeartDropSidecarFormatCensus.Report(
                directory: URL(fileURLWithPath: "/tmp/phase3-session"), files: [])
        )
    }

    private func manifestReadings() -> [SealedPhotoCorpus: SealedPhotoManifestReading] {
        [.meal: .noManifestReturned]
    }

    // MARK: - The checklist

    /// The checklist is FIVE steps, and every one of them derives its done-state from an observation
    /// actually taken. It was seven: the reset → unlock ritual that funded the keyed sealed-column
    /// pass, and the "turn Auto-Lock off" step that existed only because that pass re-vended the hub
    /// key per page. Both went with the migrator. The Auto-Lock step is the one this pins by
    /// absence — it was the single step whose done-state could never be derived, so leaving it would
    /// have meant a permanently unticked instruction to prepare for work nothing can now do.
    @Test func theChecklistIsFiveDerivableSteps() {
        let session = Phase3ReadoutSession()
        let steps = session.checklist(lastFullPassCompletedAt: nil)
        #expect(steps.count == 5)
        #expect(steps.map { String($0.title.prefix(2)) } == ["1.", "2.", "3.", "4.", "5."])
        #expect(steps.allSatisfy { !$0.title.contains("Auto-Lock") })
        #expect(steps.allSatisfy { !$0.title.contains("sealed-column") })
    }

    /// Step 3 is done only when the full pass landed AFTER probe #1 — a pass that ran before the
    /// pre-Retry probe heals nothing the probe could have seen.
    @Test func theRetryStepRequiresTheFullPassToPostdateTheFirstProbe() {
        let session = Phase3ReadoutSession()
        func step(_ completedAt: Date?) -> Phase3SittingStep {
            session.checklist(lastFullPassCompletedAt: completedAt)[2]
        }
        #expect(step(nil).title.hasPrefix("3."))
        #expect(!step(nil).isDone)
        session.recordManifests(manifestReadings(), at: Self.epoch.addingTimeInterval(30))
        #expect(!step(Self.epoch).isDone, "a pass before probe #1 does not tick step 3")
        #expect(step(Self.epoch.addingTimeInterval(60)).isDone)
    }

    // MARK: - The scan fence

    /// A scan that started before an invalidation is DROPPED rather than landing under a fresh
    /// stamp. `CryptoFormatCensus.takeReadings` does not observe cancellation, so the orphan cannot
    /// be stopped — only fenced — and a drop is recorded rather than silent.
    @Test func aScanLandingAgainstAStaleFenceIsDroppedAndRecorded() {
        let session = Phase3ReadoutSession()
        let generation = session.scanGeneration
        session.invalidateCensus()
        #expect(!session.recordScan(census: readings(), latches: latches(), generation: generation))
        #expect(session.censusReadings == nil)
        #expect(session.refusals.contains { $0.contains("stale fence") })

        #expect(session.recordScan(census: readings(), latches: latches(),
                                   generation: session.scanGeneration))
        #expect(session.censusReadings != nil)
    }

    /// `invalidateCensus()` drops the latch half too — the bit is read beside the census and a pass
    /// that could move one could move the other — and bumps the fence the view's `.task(id:)` keys
    /// on, so the page re-arms its own scan instead of sitting blank.
    @Test func invalidatingTheCensusDropsTheLatchesAndBumpsTheScanFence() {
        let session = Phase3ReadoutSession()
        session.recordScan(census: readings(), latches: latches())
        let before = session.scanGeneration
        session.invalidateCensus()
        #expect(session.censusReadings == nil)
        #expect(session.latches == nil)
        #expect(session.latchStamp == nil)
        #expect(session.scanGeneration == before + 1)
    }

    // MARK: - The session fence

    /// `clear()` is a point-in-time wipe and the probes it races take seconds. Work that started in
    /// an earlier epoch must be DROPPED, or a probe in flight across a duress engage lands
    /// afterwards and writes the real owner's per-corpus readings back into the emptied session.
    @Test func workStartedBeforeAClearIsDroppedRatherThanRepopulatingTheSession() {
        let session = Phase3ReadoutSession()
        let captured = session.epoch
        session.setManifestProbeInFlight(true)
        session.clear()
        #expect(!session.recordManifests(manifestReadings(), epoch: captured))
        #expect(session.manifestProbes.isEmpty)
        #expect(!session.recordBodyProbe(.counted(412, truncatedAtPageCap: false),
                                         for: .progress, epoch: captured))
        #expect(session.bodyProbes.isEmpty)
        #expect(session.refusals.contains { $0.contains("before this session was cleared") })
        #expect(!session.manifestProbeInFlight, "a cleared session must not leave a control disabled")
    }

    /// `clear()` empties every purchased field and moves both fences.
    @Test func clearEmptiesEveryPurchasedReading() {
        let session = Phase3ReadoutSession()
        session.recordScan(census: readings(), latches: latches())
        session.recordManifests(manifestReadings())
        session.recordBodyProbe(.counted(2, truncatedAtPageCap: false), for: .meal)
        session.recordMediaWitness(MediaPassWitness(stamp: stamp("media at-rest pass"),
                                                    result: MediaAtRestFormatMigrationResult(),
                                                    latchBefore: true, latchAfter: true))
        session.recordRefusal("something declined")
        let epochBefore = session.epoch

        session.clear()

        #expect(session.censusReadings == nil)
        #expect(session.censusStamp == nil)
        #expect(session.latches == nil)
        #expect(session.latchStamp == nil)
        #expect(session.manifestProbes.isEmpty)
        #expect(session.bodyProbes.isEmpty)
        #expect(session.mediaWitness == nil)
        #expect(session.refusals.isEmpty)
        #expect(session.epoch == epochBefore + 1)
    }

    // MARK: - The probe cap

    /// The cap evicts the SECOND-oldest, never probe #1: Retry destroys the state that produced the
    /// pre-Retry reading, so it is the one probe in the array that cannot be re-taken. The eviction
    /// is recorded rather than silent, and the `#N` labels stay monotonic across it.
    @Test func theProbeCapEvictsTheSecondOldestAndKeepsProbeOne() {
        let session = Phase3ReadoutSession()
        // R2: bounded by the cap plus two.
        for index in 0..<(Phase3ReadoutSession.maxManifestProbes + 2) {
            session.recordManifests(manifestReadings(), at: Self.epoch.addingTimeInterval(Double(index)))
        }
        #expect(session.manifestProbes.count == Phase3ReadoutSession.maxManifestProbes)
        #expect(session.manifestProbes.first?.stamp.takenAt == Self.epoch, "probe #1 must survive")
        #expect(session.manifestProbes.first?.stamp.label == "iCloud manifest probe #1")
        #expect(session.manifestProbes.last?.stamp.label
            == "iCloud manifest probe #\(Phase3ReadoutSession.maxManifestProbes + 2)")
        #expect(session.refusals.contains { $0.contains("evicted") })
    }
}

/// Pins the store-side clear: a wipe must not leave a Phase 3 reading standing over corpora it is
/// about to destroy.
@MainActor
@Suite(.serialized)
struct Phase3StoreEvidenceClearTests {

    /// Built through the shared helper rather than by hand, so every process-global scope this
    /// suite could collide with another one on — the app-group container, the heart-drop seal key,
    /// the AI quota suite, the proximity root — is isolated per store, per
    /// `PhotoDirectoryIsolationTests`.
    private func makeStore() -> FernletStore {
        makeTestStore()
    }

    /// A duress engage clears the whole sitting. It is the edge with the least other coverage: the
    /// duress SILENT wipe reaches `deleteAllData` directly and never through `DeleteEverythingFlow`,
    /// so nothing else stands between a decoy session and a reading about the real owner's corpora.
    ///
    /// The session is now the WHOLE subject of that clear. Until Phase 3 deleted the sealed-column
    /// migrator, one reading that reached a verdict — the keyed pass witness — lived on the store
    /// instead, and clearing the session alone left it standing while the wipe supplied a census
    /// zero over the emptied corpus for free.
    @Test func engagingDuressClearsEveryPhase3Reading() {
        let store = makeStore()
        store.phase3ReadoutSession.recordRefusal("something")
        store.phase3ReadoutSession.recordBodyProbe(.counted(412, truncatedAtPageCap: false),
                                                   for: .progress)

        store.duressSessionActive = true

        #expect(store.phase3ReadoutSession.refusals.isEmpty)
        #expect(store.phase3ReadoutSession.bodyProbes.isEmpty)
    }
}
