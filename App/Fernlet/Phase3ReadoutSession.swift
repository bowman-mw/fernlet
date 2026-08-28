// Phase3ReadoutSession.swift
// Fernlet
//
// The process-scoped, non-persisted home for every reading the Phase 3 sitting purchases.
//
// It exists because the sitting spans a sheet DISMISSAL. The sealed-column keyed pass cannot be
// funded from Settings at all — Settings is reached from Home, where the hub is always re-locked, so
// `FernletLockService.contentKey(for: .privateHub)` answers nil there — so the ritual is: reset the
// latch here, dismiss Settings, open the Private tab, unlock (which funds the SHIPPED trigger), and
// come back. A pushed destination's `@State` does not survive that, and neither does the sheet's.
//
// DEBUG-ONLY for the reason stated at CryptoFormatCensus.swift:15-21.

#if DEBUG

import CloudKitSync
import FernletFoundation
import Foundation
import Observation
import PrivateMediaStore

/// One step of the sitting, with a done-state DERIVED from an observation actually taken this
/// process — never from a document the owner is asked to remember.
nonisolated struct Phase3SittingStep: Sendable, Equatable, Identifiable {
    /// The step's one-line instruction.
    let title: String
    /// What it costs and why the order matters.
    let detail: String
    /// Whether an observation taken this process shows the step was performed. One step is
    /// deliberately never derivable — see ``Phase3ReadoutSession/checklist(lastFullPassCompletedAt:sealedColumnWitness:)``.
    let isDone: Bool

    var id: String { title }

    /// Creates a step.
    init(title: String, detail: String, isDone: Bool) {
        self.title = title
        self.detail = detail
        self.isDone = isDone
    }
}

/// Every reading the sitting purchased, held for the life of the process and no longer.
///
/// ## Three invariants
///
/// 1. **It persists NOTHING** — no `UserDefaults` key, no file, no cache. A stored "gate discharged"
///    would be a claim about a subject one write can invalidate, and `Docs/PrivacyWipeCoverage.md`
///    therefore owes no disposition row. The two export routes are how a reading leaves the moment.
/// 2. **It is cleared on a duress engage and on teardown**, and the whole readout refuses to render
///    under duress regardless — the page fetches and decrypts the real owner's iCloud manifests and
///    prints real per-corpus photo counts, and numbers that contradict an apparently empty decoy are
///    exactly the disclosure duress mode exists to prevent.
/// 3. **It is DEBUG evidence only**, read by exactly one surface. No shipping code path may consult
///    it; the D3 capsule's `sealedColumnMigrationStatus` remains the only migration state any
///    user-facing surface reads.
///
/// It holds no closures, no observers, no timers and no capture-handler tokens — deliberately, and
/// it is the reason the sealed-column witness is retained as typed store state rather than through
/// `FernletAuditLog.addCaptureHandler`, which would be a permanent process-lifetime registrant whose
/// token must be held.
@MainActor
@Observable
final class Phase3ReadoutSession {
    /// R2: the sitting takes at most a handful of probes; the cap stops a stuck finger growing the
    /// array without bound.
    static let maxManifestProbes = 8
    /// R2: the same, for refusals.
    static let maxRefusals = 32

    /// The marker-bytes census readings, or nil when the scan has not landed (or was invalidated).
    private(set) var censusReadings: CryptoFormatCensus.Readings?
    /// When the census landed.
    private(set) var censusStamp: Phase3Stamp?
    /// The seven latch bits.
    private(set) var latches: Phase3LatchReadings?
    /// When the latches were read.
    private(set) var latchStamp: Phase3Stamp?
    /// The seven bits as they read BEFORE the one reset this design offers.
    private(set) var preResetLatchSnapshot: Phase3LatchReadings?
    /// Every manifest probe taken this sitting, KEPT rather than overwritten: Retry forces
    /// `generation` and `deviceHighWater` into agreement, so a second probe structurally cannot show
    /// the stale-manifest disagreement the first exists to capture.
    private(set) var manifestProbes: [Phase3ManifestProbe] = []
    /// Body-record probes, by corpus.
    private(set) var bodyProbes: [SealedPhotoCorpus: BodyProbeReading] = [:]
    /// The retained media pass witness.
    private(set) var mediaWitness: MediaPassWitness?
    /// Whether a media pass is running right now (the control's in-flight guard).
    private(set) var mediaPassInFlight = false
    /// Whether a manifest probe is running right now.
    private(set) var manifestProbeInFlight = false
    /// When the sealed-column latch was reset this sitting, if it was.
    private(set) var sealedColumnResetTakenAt: Date?
    /// Refusals recorded this sitting — a control that declined, a probe that could not run.
    private(set) var refusals: [String] = []
    /// Whether a keyed sealed-column pass overlapped the scan that produced ``censusReadings``.
    private(set) var censusOverlappedKeyedPass = false

    /// The scan fence. Bumped by ``invalidateCensus()`` and ``clear()``; a landing whose captured
    /// generation no longer matches is DROPPED (with a recorded refusal) rather than stamped fresh.
    ///
    /// `CryptoFormatCensus.takeReadings` does not observe cancellation, so a sweep that started
    /// before an invalidation cannot be stopped — only fenced. Without this, an orphaned scan that
    /// sampled the corpus BEFORE a keyed pass lands afterwards carrying a stamp taken after it, and
    /// the sealed-column ordering guard passes on stamps ordered opposite to reality.
    ///
    /// It is also the view's `.task(id:)` key, so an invalidation re-arms the scan on its own rather
    /// than leaving six blank rows until the owner happens to navigate away and back.
    private(set) var scanGeneration = 0
    /// The session fence. Bumped by ``clear()`` only. Work that started in an earlier epoch — a
    /// manifest probe in flight across a duress engage or a delete-all — is dropped instead of
    /// re-populating the session the clear just emptied.
    private(set) var epoch = 0
    /// How many manifest probes have EVER been taken this sitting, so the `#N` labels stay
    /// monotonic across an eviction.
    private var manifestProbesTaken = 0

    /// Creates an empty session.
    init() {}

    // MARK: Mutators

    /// Records a landed census scan and the latch bits taken beside it, or drops it when the fence
    /// has moved. Returns whether the reading was kept.
    ///
    /// `takenAt` is the moment the census sweep STARTED, not the moment it landed: the sealed-column
    /// gate consumes this stamp as a SAMPLING-order proof ("a marker zero taken at or after the pass
    /// that could have changed it"), and a landing time over a multi-second sweep would let a census
    /// read entirely before a keyed pass claim to postdate it.
    ///
    /// `latchesAt` is separate because the seven bits are read AFTER the sweep, not beside it: one
    /// stamp over two observations minutes apart is the thing this whole model refuses.
    @discardableResult
    func recordScan(
        census: CryptoFormatCensus.Readings,
        latches: Phase3LatchReadings,
        at takenAt: Date = Date(),
        latchesAt: Date? = nil,
        generation: Int? = nil,
        overlappedKeyedPass: Bool = false
    ) -> Bool {
        if let generation, generation != scanGeneration {
            recordRefusal("A local scan landed against a stale fence (generation \(generation), now"
                + " \(scanGeneration)) and was DROPPED: it sampled a corpus that has since been"
                + " invalidated. Re-take the local scan.")
            return false
        }
        censusReadings = census
        censusStamp = Phase3Stamp(label: "marker census (stamped at sweep START)", takenAt: takenAt)
        self.latches = latches
        latchStamp = Phase3Stamp(label: "completion latches", takenAt: latchesAt ?? takenAt)
        censusOverlappedKeyedPass = overlappedKeyedPass
        return true
    }

    /// Records the seven bits as they read before a reset, so the destroyed reading survives in the
    /// export.
    func recordPreResetSnapshot(_ snapshot: Phase3LatchReadings) {
        preResetLatchSnapshot = snapshot
    }

    /// Records one manifest probe, keeping earlier ones.
    ///
    /// The eviction at the cap drops the SECOND-oldest, never the first: probe #1 is the pre-Retry
    /// reading, and Retry destroys the state that produced it, so it is the one probe in the array
    /// that cannot be re-taken. An eviction is recorded as a refusal rather than being silent.
    @discardableResult
    func recordManifests(
        _ readings: [SealedPhotoCorpus: SealedPhotoManifestReading],
        at takenAt: Date = Date(),
        epoch capturedEpoch: Int? = nil
    ) -> Bool {
        guard isCurrent(capturedEpoch, work: "A manifest probe") else { return false }
        manifestProbesTaken += 1
        let label = "iCloud manifest probe #\(manifestProbesTaken)"
        manifestProbes.append(Phase3ManifestProbe(stamp: Phase3Stamp(label: label, takenAt: takenAt),
                                                  readings: readings))
        guard manifestProbes.count > Self.maxManifestProbes else { return true }
        let evicted = manifestProbes.remove(at: 1)
        recordRefusal("The probe cap (\(Self.maxManifestProbes)) evicted \(evicted.stamp.printed)."
            + " Probe #1 is kept deliberately — it is the only reading Retry makes unrepeatable.")
        return true
    }

    /// Records one corpus's body-record probe.
    @discardableResult
    func recordBodyProbe(
        _ reading: BodyProbeReading,
        for corpus: SealedPhotoCorpus,
        epoch capturedEpoch: Int? = nil
    ) -> Bool {
        guard isCurrent(capturedEpoch, work: "A body-record probe") else { return false }
        bodyProbes[corpus] = reading
        return true
    }

    /// Records a funded media pass.
    @discardableResult
    func recordMediaWitness(_ witness: MediaPassWitness, epoch capturedEpoch: Int? = nil) -> Bool {
        guard isCurrent(capturedEpoch, work: "A media at-rest pass") else { return false }
        mediaWitness = witness
        return true
    }

    /// Whether work that started in `capturedEpoch` may still write to this session.
    ///
    /// `clear()` is a point-in-time wipe, and the network probes it races take seconds. Without this
    /// fence a probe in flight across a duress engage — or across the top of a delete-all — lands
    /// afterwards and writes the real owner's per-corpus readings straight back into the session the
    /// clear just emptied, defeating both the fail-closed duress rule and the wipe's own stated
    /// reason for clearing ("a reading left standing over corpora this wipe is about to destroy
    /// would be the same lie a persisted one would be").
    private func isCurrent(_ capturedEpoch: Int?, work: String) -> Bool {
        guard let capturedEpoch, capturedEpoch != epoch else { return true }
        recordRefusal("\(work) that started before this session was cleared landed afterwards and was"
            + " DROPPED (epoch \(capturedEpoch), now \(epoch)).")
        return false
    }

    /// Sets the media pass in-flight flag.
    func setMediaPassInFlight(_ inFlight: Bool) {
        mediaPassInFlight = inFlight
    }

    /// Sets the manifest probe in-flight flag.
    func setManifestProbeInFlight(_ inFlight: Bool) {
        manifestProbeInFlight = inFlight
    }

    /// Records that the sealed-column latch was cleared, arming the next hub unlock.
    func recordSealedColumnReset(at takenAt: Date = Date()) {
        sealedColumnResetTakenAt = takenAt
    }

    /// Records a refusal. Bounded (R2).
    func recordRefusal(_ refusal: String) {
        guard !refusal.isEmpty else { return }
        refusals.append("\(Date().ISO8601Format()): \(refusal)")
        if refusals.count > Self.maxRefusals { refusals.removeFirst() }
    }

    /// Drops the census half so it is re-taken.
    ///
    /// The store calls this when a KEYED sealed-column pass lands, so the census reading quoted
    /// beside that pass is always one taken AFTER the pass that could have changed it. Without it the
    /// two halves of that gate would be quoted out of order and a stale zero would discharge.
    func invalidateCensus() {
        censusReadings = nil
        censusStamp = nil
        latches = nil
        latchStamp = nil
        censusOverlappedKeyedPass = false
        scanGeneration += 1
    }

    /// Drops every purchased reading. Called on a duress engage and on teardown: fail-closed, on the
    /// principle that a decoy session must not be able to read numbers about the real owner's data.
    ///
    /// Both fences move, so work already in flight lands into a dropped refusal rather than back
    /// into the emptied session, and both in-flight flags are reset so a control cannot be left
    /// permanently disabled by a probe whose result was discarded.
    func clear() {
        censusReadings = nil
        censusStamp = nil
        latches = nil
        latchStamp = nil
        censusOverlappedKeyedPass = false
        preResetLatchSnapshot = nil
        manifestProbes = []
        manifestProbesTaken = 0
        bodyProbes = [:]
        mediaWitness = nil
        mediaPassInFlight = false
        manifestProbeInFlight = false
        sealedColumnResetTakenAt = nil
        refusals = []
        scanGeneration += 1
        epoch += 1
    }

    // MARK: Derived

    /// The sitting checklist, in the order source forces.
    ///
    /// Two facts live on `FernletStore` rather than here (the own-photo pass's completion time and
    /// the sealed-column witness), so they are passed in rather than reached for — the session holds
    /// no reference to its owner.
    ///
    /// - Note: step 2 is the one step whose done-state cannot be derived. Auto-Lock is a device
    ///   setting no app-side reading answers, and a diagnostic must not mutate one, so it renders as
    ///   not-done permanently and says why rather than claiming an observation it never took.
    func checklist(
        lastFullPassCompletedAt: Date?,
        sealedColumnWitness: SealedColumnPassWitness?
    ) -> [Phase3SittingStep] {
        [
            skipRestoreStep(),
            autoLockStep(),
            firstProbeStep(),
            retryStep(lastFullPassCompletedAt: lastFullPassCompletedAt),
            secondProbeStep(),
            mediaWitnessStep(),
            sealedColumnStep(sealedColumnWitness)
        ]
    }

    private func skipRestoreStep() -> Phase3SittingStep {
        Phase3SittingStep(
            title: "1. Confirm the run scheme does not set FERNLET_SKIP_SEALED_RESTORE=1",
            detail: "That DEBUG guard fronts the UPLOAD path as well as the restore, so a sitting"
                + " taken with it set would silently no-op the sealed-photo pass and read every"
                + " manifest as absent.",
            isDone: ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] != "1"
        )
    }

    private func autoLockStep() -> Phase3SittingStep {
        Phase3SittingStep(
            title: "2. Turn Auto-Lock off (Settings › Display & Brightness)",
            detail: "The keyed sealed-column pass re-vends the hub key per page, so a screen lock"
                + " ends it fail-closed as stoppedOnlyByKeyRevocation — a clean stop that is NOT a"
                + " witness. This step cannot be observed from inside the app and is deliberately"
                + " never marked done; it is the one item the owner confirms themselves.",
            isDone: false
        )
    }

    private func firstProbeStep() -> Phase3SittingStep {
        Phase3SittingStep(
            title: "3. Fetch manifests BEFORE any healing pass",
            detail: "Captures the pre-pass minima and any generation-vs-deviceHighWater disagreement"
                + " while they can still disagree. Costs three CloudKit fetches and three AES-GCM"
                + " opens; writes nothing. This probe CANNOT be re-taken after step 4, and nothing"
                + " here survives a relaunch — do not stop or re-run the app until the report is"
                + " exported.",
            isDone: !manifestProbes.isEmpty
        )
    }

    private func retryStep(lastFullPassCompletedAt: Date?) -> Phase3SittingStep {
        let firstProbeAt = manifestProbes.first?.stamp.takenAt
        let done = lastFullPassCompletedAt.map { completed in
            firstProbeAt.map { completed > $0 } ?? true
        } ?? false
        return Phase3SittingStep(
            title: "4. Run Privacy & Data → Retry to completion",
            detail: "Its FULL payload, not one clause: restoreSealedBackupsIfNeeded(userInitiated:"
                + " true) restores sealed narratives into the local stores FIRST, then runs"
                + " synchronizeFullyVerified(), which rewrites all three manifests and mints"
                + " generations — which also forces generation and deviceHighWater into agreement"
                + " and destroys the disagreement step 3 exists to capture.",
            isDone: done
        )
    }

    private func secondProbeStep() -> Phase3SittingStep {
        Phase3SittingStep(
            title: "5. Fetch manifests a SECOND time",
            detail: "Kept as its own labelled reading rather than overwriting the first. Only the"
                + " rungs that read the plaintext stamp version 2, so a full-verification pass must"
                + " run between the two probes.",
            isDone: manifestProbes.count >= 2
        )
    }

    private func mediaWitnessStep() -> Phase3SittingStep {
        Phase3SittingStep(
            title: "6. Fund a media at-rest pass",
            detail: "MediaAtRestFormatMigrator.performPass() produces unopenableUnprefixed — the"
                + " plan's own residue evidence — and NEVER touches the latch, in either direction."
                + " On a latched device it should convert nothing; if it converts something, that is"
                + " the finding and the gate refuses. On an UNLATCHED device this gate cannot"
                + " discharge in this sitting at all: gate part (a) is the latch, and only a shipped"
                + " launch pass may set it — relaunch, let that pass run, and take the sitting again.",
            isDone: mediaWitness != nil
        )
    }

    private func sealedColumnStep(_ witness: SealedColumnPassWitness?) -> Phase3SittingStep {
        let done = sealedColumnResetTakenAt.map { resetAt in
            guard let witness, witness.isKeyedWitness else { return false }
            return witness.stamp.takenAt > resetAt
        } ?? false
        return Phase3SittingStep(
            title: "7. Reset the sealed-column latch, dismiss Settings, open the Private tab, unlock",
            detail: "The reset only ARMS. The shipped trigger funds the keyed pass ~300 ms after the"
                + " unlock, with a live per-page key vend Settings can never supply. Come back here"
                + " afterwards: the witness lands on FernletStore, which outlives the sheet, and the"
                + " census is re-taken so the two halves of that gate are never quoted out of order.",
            isDone: done
        )
    }

    /// Assembles the fold's input value from everything purchased so far.
    func inputs(
        environment: Phase3GateEnvironment,
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL,
        sealedColumnWitness: SealedColumnPassWitness?,
        sealedColumnPassInFlight: Bool,
        mediaLaunchPass: MediaLaunchPassRecord? = nil,
        sealedPhotoFullPassVerdicts: [SealedPhotoCorpusFormatVerdict]? = nil
    ) -> Phase3GateReadoutInputs {
        Phase3GateReadoutInputs(
            environment: environment,
            ownPhotoDocumentsDirectory: ownPhotoDocumentsDirectory,
            friendWallSupportDirectory: friendWallSupportDirectory,
            census: censusReadings,
            censusStamp: censusStamp,
            latches: latches,
            latchStamp: latchStamp,
            preResetLatchSnapshot: preResetLatchSnapshot,
            manifestProbes: manifestProbes,
            bodyProbes: bodyProbes,
            mediaWitness: mediaWitness,
            mediaPassInFlight: mediaPassInFlight,
            mediaLaunchPass: mediaLaunchPass,
            censusOverlappedKeyedPass: censusOverlappedKeyedPass,
            sealedPhotoFullPassVerdicts: sealedPhotoFullPassVerdicts,
            sealedColumnWitness: sealedColumnWitness,
            sealedColumnPassInFlight: sealedColumnPassInFlight,
            sealedColumnResetTakenAt: sealedColumnResetTakenAt,
            checklist: checklist(lastFullPassCompletedAt: environment.lastFullPassCompletedAt,
                                 sealedColumnWitness: sealedColumnWitness),
            refusals: refusals
        )
    }
}

#endif
