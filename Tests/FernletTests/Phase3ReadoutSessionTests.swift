// Phase3ReadoutSessionTests.swift
// FernletTests
//
// The stateful half of the Phase 3 gate readout: `Phase3ReadoutSession` (the sitting's
// process-scoped home for every purchased reading, including the seven-step checklist) and the two
// store-side clears that stand between a wipe and a false PASS.
//
// The fold has `Phase3GateReadoutTests`; this file exists because none of the rules below live in
// the fold. The checklist's done-states, the two fences (`scanGeneration` and `epoch`), the probe
// cap's eviction policy and `clear()` were 300+ lines of untested state — and the one reading that
// reaches a verdict, `FernletStore.lastSealedColumnPassWitness`, deliberately lives OUTSIDE the
// session, which is exactly why clearing the session alone was not enough.
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
        Phase3LatchReadings(sealedColumn: true, mediaAtRest: true,
                            ownPhotoKey: true, heartDropSidecar: true, sealedPhotoBackup: true,
                            lockWrapRow: true)
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

    private func keyedWitness(offset: TimeInterval) -> SealedColumnPassWitness {
        SealedColumnPassWitness(
            stamp: stamp("sealed-column keyed run", offset: offset),
            revalidation: nil,
            latched: true,
            passes: [SealedColumnMigrationResult(columns: [:], rowsScanned: 4, rowsAvailable: 4)]
        )
    }

    // MARK: - The checklist

    /// Step 2 is the one step whose done-state cannot be derived — Auto-Lock is a device setting no
    /// app-side reading answers, and a diagnostic must not mutate one. It must render not-done
    /// permanently and say why, rather than being "fixed" into a claim nobody observed.
    @Test func theAutoLockStepIsNeverMarkedDone() {
        let session = Phase3ReadoutSession()
        let step = session.checklist(lastFullPassCompletedAt: Date(),
                                     sealedColumnWitness: keyedWitness(offset: 0))[1]
        #expect(step.title.hasPrefix("2."))
        #expect(!step.isDone)
        #expect(step.detail.contains("cannot be observed"))
    }

    /// Step 7 flips only for a KEYED witness stamped AFTER this sitting's reset. A passless witness
    /// (the cancelled-grace shape) or a pass that predates the reset must leave it open — it is the
    /// on-screen cross-reference to the freshness rule the sealed-column verdict enforces.
    @Test func theSealedColumnStepFlipsOnlyForAKeyedPassAfterTheReset() {
        let session = Phase3ReadoutSession()
        func step(_ witness: SealedColumnPassWitness?) -> Phase3SittingStep {
            session.checklist(lastFullPassCompletedAt: nil, sealedColumnWitness: witness)[6]
        }
        #expect(!step(keyedWitness(offset: 60)).isDone, "no reset taken: nothing to postdate")

        session.recordSealedColumnReset(at: Self.epoch.addingTimeInterval(30))
        #expect(!step(keyedWitness(offset: 0)).isDone, "a pass predating the reset is not the witness")
        #expect(!step(SealedColumnPassWitness(stamp: stamp("sealed-column revalidation", offset: 60),
                                              revalidation: .confirmed, latched: true, passes: [])).isDone,
                "a KEYLESS revalidation is not the keyed pass step 7 asks for")
        #expect(step(keyedWitness(offset: 60)).isDone)
    }

    /// Step 4 is done only when the full pass landed AFTER probe #1 — a pass that ran before the
    /// pre-Retry probe heals nothing the probe could have seen.
    @Test func theRetryStepRequiresTheFullPassToPostdateTheFirstProbe() {
        let session = Phase3ReadoutSession()
        func step(_ completedAt: Date?) -> Phase3SittingStep {
            session.checklist(lastFullPassCompletedAt: completedAt, sealedColumnWitness: nil)[3]
        }
        #expect(!step(nil).isDone)
        session.recordManifests(manifestReadings(), at: Self.epoch.addingTimeInterval(30))
        #expect(!step(Self.epoch).isDone, "a pass before probe #1 does not tick step 4")
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
        session.recordPreResetSnapshot(latches())
        session.recordManifests(manifestReadings())
        session.recordBodyProbe(.counted(2, truncatedAtPageCap: false), for: .meal)
        session.recordMediaWitness(MediaPassWitness(stamp: stamp("media at-rest pass"),
                                                    result: MediaAtRestFormatMigrationResult(),
                                                    latchBefore: true, latchAfter: true))
        session.recordSealedColumnReset()
        session.recordRefusal("something declined")
        let epochBefore = session.epoch

        session.clear()

        #expect(session.censusReadings == nil)
        #expect(session.censusStamp == nil)
        #expect(session.latches == nil)
        #expect(session.preResetLatchSnapshot == nil)
        #expect(session.manifestProbes.isEmpty)
        #expect(session.bodyProbes.isEmpty)
        #expect(session.mediaWitness == nil)
        #expect(session.sealedColumnResetTakenAt == nil)
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

/// Pins the store-side half: the one retained reading that reaches a VERDICT lives outside the
/// session, so clearing the session alone let a wipe manufacture a discharge.
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

    private func seedKeyedWitness(_ store: FernletStore) {
        store.recordSealedColumnMigrationRun(
            latched: true,
            passResults: [SealedColumnMigrationResult(columns: [:], rowsScanned: 4, rowsAvailable: 4)]
        )
    }

    /// The wipe clears the session so no "gate discharged" reading is left standing over corpora it
    /// is about to destroy. The sealed-column keyed witness lives on the STORE, so the session clear
    /// could not reach it — and the wipe then supplied a census zero over the emptied corpus for
    /// free, manufacturing exactly the reading the hook exists to prevent.
    @Test func clearingPhase3EvidenceDropsTheStoreSideKeyedWitness() {
        let store = makeStore()
        seedKeyedWitness(store)
        #expect(store.lastSealedColumnPassWitness != nil)
        store.phase3ReadoutSession.recordSealedColumnReset()

        store.clearPhase3Evidence()

        #expect(store.lastSealedColumnPassWitness == nil)
        #expect(store.phase3ReadoutSession.sealedColumnResetTakenAt == nil)
    }

    /// A duress engage goes through the same clear. The duress SILENT wipe reaches `deleteAllData`
    /// directly and never through `DeleteEverythingFlow`, so this edge is the only one it gets.
    @Test func engagingDuressClearsEveryPhase3Reading() {
        let store = makeStore()
        seedKeyedWitness(store)
        store.phase3ReadoutSession.recordRefusal("something")

        store.duressSessionActive = true

        #expect(store.lastSealedColumnPassWitness == nil)
        #expect(store.phase3ReadoutSession.refusals.isEmpty)
    }

    /// The reset control clears the standing witness too, so the row cannot fall back on a pass that
    /// never saw the rows this sitting is about.
    @Test func clearingTheSealedColumnWitnessLeavesNothingToFallBackOn() {
        let store = makeStore()
        seedKeyedWitness(store)
        store.clearSealedColumnPassWitness()
        #expect(store.lastSealedColumnPassWitness == nil)
    }
}
