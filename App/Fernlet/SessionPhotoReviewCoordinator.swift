// SessionPhotoReviewCoordinator.swift
// Fernlet
//
// Session photos U3 (2026-09-30), the owner's words: "the pop up screen for selecting photos should
// be the first thing shown. None of the photos should be saved to the camera roll until this
// selection has been made." Units 1–2 made the second half true in storage: every session photo is
// HELD in the sealed pending corpus until the person's answer, never on the wall and never in the
// camera roll. This file is the first half: ONE app-level presenter for every session-end photo
// review, above whatever tab or sheet the person is on, driven by a pure gate.
//
// Three pieces:
//   * `SessionPhotoReviewGate` — a pure function from twelve facts to present / stay up / hide
//     without answering / wait, exhaustively tested like `ProximityRunPolicy`.
//   * `SessionPhotoReviewCoordinator` — owned by `FernletStore`; snapshots the batch at present,
//     draws it through a `SessionPhotoReviewPresenting` (the overlay window in the app, a recorder in
//     tests), answers it through `MeshNetworkManager.finishReviewedPhotos`, exports to Photos only
//     after the answer and only over what the answer reports landed, and holds the discovery block
//     (`blocksDiscovery`) the run policy reads so no second session forms before the choice.
//   * `SessionPhotoReviewTriggers` — the ContentView modifier that feeds the coordinator its facts
//     and asks for an evaluation on every edge the gate reads.

import SwiftUI
import UIKit
import FernletDomainModel
import FernletFoundation
import ProximityKit
import FernletProximityUI
import FernletConnections

// MARK: - SessionPhotoReviewGate

/// When the session-end photo review may draw — the pure decision behind
/// ``SessionPhotoReviewCoordinator`` (design §4.5, invariant I9).
///
/// A value, not a coordinator: twelve facts in, one ``Verdict`` out, no clock, no store, no
/// manager. `SessionPhotoReviewGateTests` enumerates the whole product (eleven Booleans × a zero and
/// a non-zero count).
///
/// - ``Verdict/present``: photos are outstanding, the session is over, the held photos can be drawn
///   and answered (the manager's decrypt seam is open, its pending index loaded and reconciled), the
///   scene is active, the launch has finished, and nothing the review must yield to is up — no
///   duress session, no delete-all, no crisis surface (First Aid, the stress explainer; owner
///   question Q8), no camera Develop sheet, no answer still in flight — and the person has not said
///   "Not now" this activation.
/// - ``Verdict/hideWithoutAnswer``: showing, and a duress session began, a delete-all began or a
///   crisis surface came up underneath. Nothing is answered; it presents again once that clears.
/// - ``Verdict/stayUp``: showing otherwise. Backgrounding does NOT hide it: the review sheet's
///   snapshot cover keeps the app-switcher image blank (invariant I18).
/// - ``Verdict/wait``: not showing, and ``Verdict/present``'s product does not hold.
///
/// Concurrency: `nonisolated` and stateless; safe from any context.
nonisolated enum SessionPhotoReviewGate {

    /// Every fact the gate reads — the whole input product the gate tests enumerate.
    ///
    /// Concurrency: an immutable `Sendable` value.
    nonisolated struct Input: Equatable, Hashable, Sendable {
        /// `MeshNetworkManager.pendingReviewPhotos.count` — the ended session's photos still held.
        let outstandingPhotoCount: Int
        /// `MeshNetworkManager.isSessionLive`: the review never draws over a live session.
        let sessionIsLive: Bool
        /// `MeshNetworkManager.heldPhotosCanBeShown`: the decrypt seam is open, the pending index is
        /// loaded and the launch reconcile has run (so no photo already kept can be offered again).
        let heldPhotosCanBeShown: Bool
        /// The scene is `.active` (fed from ContentView; the overlay window has no scene phase of
        /// its own).
        let sceneIsActive: Bool
        /// ContentView's launch preparation has finished (it mounts after onboarding).
        let launchComplete: Bool
        /// A duress session is in force (the decoy): the review never draws, nothing is deleted.
        let duressSessionActive: Bool
        /// `FernletStore.deleteAllInProgress`.
        let deleteAllInProgress: Bool
        /// First Aid or the stress explainer is the root sheet (Q8: the one exception to "first").
        let crisisSurfaceUp: Bool
        /// The camera's own Develop review is up AND the camera is still mounted
        /// (`MeshNetworkManager.isInSession`), so a missed clear cannot outlive the camera (I20).
        let cameraDevelopReviewUp: Bool
        /// The person tapped "Not now" and no background-to-active edge or Friends-card tap has
        /// cleared it yet.
        let deferredByUser: Bool
        /// The review is on screen now.
        let isShowing: Bool
        /// An answer from either surface is still running (the overlay's own, taken down under it
        /// by a step-aside, or the camera's Develop answer). The review waits for it: presented
        /// under it, that answer's own hide would take the new review down and its actions would
        /// refuse. It presents once the answer ends (``SessionPhotoReviewCoordinator/endAnswer()``
        /// asks again). Fix round 1, U3-C-U3-R1.
        let answerInFlight: Bool
    }

    /// What the presenter must do.
    ///
    /// Concurrency: an immutable `Sendable` value.
    enum Verdict: Equatable, Sendable {
        /// Take the snapshot and draw the review.
        case present
        /// Leave the review up.
        case stayUp
        /// Take the review down, answering nothing.
        case hideWithoutAnswer
        /// Leave it down.
        case wait
    }

    /// The decision — pure, total, re-run on every edge the coordinator is told about.
    ///
    /// - Parameter input: The facts.
    /// - Returns: The verdict.
    static func verdict(for input: Input) -> Verdict {
        if input.isShowing {
            return mustStepAside(input) ? .hideWithoutAnswer : .stayUp
        }
        return mayPresent(input) ? .present : .wait
    }

    /// Whether something the review must yield to is in force: a duress session, a delete-all, or
    /// a crisis surface. Each hides a showing review without answering and keeps a hidden one down.
    ///
    /// - Parameter input: The facts.
    /// - Returns: Whether the review steps aside.
    static func mustStepAside(_ input: Input) -> Bool {
        input.duressSessionActive || input.deleteAllInProgress || input.crisisSurfaceUp
    }

    /// ``Verdict/present``'s product, for a review that is not showing.
    ///
    /// - Parameter input: The facts.
    /// - Returns: Whether every leg holds.
    static func mayPresent(_ input: Input) -> Bool {
        guard input.outstandingPhotoCount > 0, !input.sessionIsLive, input.heldPhotosCanBeShown else { return false }
        guard input.sceneIsActive, input.launchComplete, !mustStepAside(input) else { return false }
        return !input.cameraDevelopReviewUp && !input.deferredByUser && !input.answerInFlight
    }

    /// Whether `sheet` is a crisis surface the review must never cover (Q8's default): First Aid
    /// and the stress explainer, which links to it.
    ///
    /// - Parameter sheet: ContentView's root sheet, if any.
    /// - Returns: Whether the review waits for it (or steps aside for it).
    static func isCrisisSurface(_ sheet: FernletSheet?) -> Bool {
        switch sheet {
        case .firstAid, .stressExplainer: return true
        default: return false
        }
    }
}

// MARK: - SessionPhotoReviewHost

/// What ``SessionPhotoReviewCoordinator`` reads from, and hands to, the app's store — the trust
/// vault for the keep-as-friend half, two lifecycle facts, and the one-sided mint.
///
/// A protocol rather than a `FernletStore` reference so the coordinator holds its owner WEAKLY
/// (the store owns the coordinator) and so the protocol states exactly the four things it touches.
///
/// Concurrency: `@MainActor` — the store is main-actor state.
@MainActor
protocol SessionPhotoReviewHost: AnyObject {
    /// The trust vault's records, for keep-as-friend eligibility at presentation time.
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { get }
    /// Whether a duress session (the decoy) is in force.
    var duressSessionActive: Bool { get }
    /// Whether a delete-all is between its wipe brackets.
    var deleteAllInProgress: Bool { get }
    /// Mints the kept candidates as one-sided friends.
    ///
    /// - Parameters:
    ///   - candidates: The candidates the review offered.
    ///   - keptFingerprints: The ones the person chose to keep.
    func keepProximityFriends(from candidates: [MeshSessionRosterEntry], keptFingerprints: Set<String>)
}

extension FernletStore: SessionPhotoReviewHost {}

// MARK: - SessionPhotoReviewCoordinator

/// The one app-level presenter of the session-end photo review: first thing shown, above every tab
/// and every sheet, the moment a session ends and at the next launch after a kill (design §4.5).
///
/// **What it owns.** The review's snapshot (the batch id, the photos and keep-as-friend candidates
/// it offers, the ticks, the opt-in "Also save kept photos to Photos" toggle), the answer, the
/// post-answer Photos export, and the three legs of ``blocksDiscovery``. It draws through a
/// ``SessionPhotoReviewPresenting`` — the overlay window in the app — so every SwiftUI sheet of the
/// main window stays intact underneath.
///
/// **When it draws.** ``SessionPhotoReviewGate`` decides, over the facts ``gateInput`` samples:
/// the manager's (outstanding photos, liveness, the decrypt seam, the camera's mount), the host's
/// (duress, delete-all) and the ones ContentView feeds (``scenePhase``, ``launchComplete``,
/// ``crisisSurfaceUp``) and the camera reports (``cameraDevelopReviewUp``), and its own
/// ``answerInFlight`` (it never presents under a running answer). Every edge schedules a settled
/// evaluation (``scheduleEvaluation()``, 500 ms, cancel-and-replace) so a burst of promotions and
/// the foreground re-entry pass land in one snapshot.
///
/// **Invariants it keeps.**
/// - I2: the ONLY function here that reaches the Photos library is
///   ``exportKeptPhotosIfAsked(_:)``, which takes the ``SessionPhotoAnswer`` and saves only
///   `answer.keptOnWall`, hydrated from the WALL. The saver itself is injected by the store.
/// - I10: "Not now", a ``SessionPhotoReviewGate/Verdict/hideWithoutAnswer`` and a backgrounding
///   answer nothing; only ``keepSelected()`` and ``discardAll()`` call the manager's answer.
/// - I17: the keep-as-friend candidates of a batch with photos are answered here, once.
/// - I21: ``blocksDiscovery`` stays up while an answer or a leave this coordinator started is in
///   flight, so the run policy never sees the block fall over a held mesh.
/// - I25: an answer that leaves photos held keeps the review up with the inline failure; it never
///   hides and re-presents on its own.
/// - No answer is ever stranded (fix round 1, U3-C-U3-R1): the wait for a failed export's alert
///   runs only while the review that shows it is open (``PhotoSaveFailureAcknowledgement``), for
///   the overlay and for the camera's Develop review alike, so ``answerInFlight`` always falls; and
///   only the overlay's own answer refuses its actions.
///
/// **Leaving at present.** A review that presents while an ended mesh is still held (door 3's
/// give-up) leaves it at once (``leaveEndedMeshIfHeld()``), so the Friends tab swaps to the album
/// under the overlay and no answer can run over a mesh the policy might resume.
///
/// Concurrency: `@MainActor @Observable` — every stored fact is main-actor state the screen and the
/// Friends card read. Its two stored tasks (the settle and the leave) capture `self` weakly and are
/// cancelled in the `isolated deinit` (memory-lifecycle rule ML1); the store owns it for the
/// process lifetime.
@MainActor
@Observable
final class SessionPhotoReviewCoordinator {

    // MARK: Fed facts

    /// The app's scene phase, fed by ContentView. The overlay window's hosting controller sits
    /// outside the SwiftUI scene that supplies `\.scenePhase`, so the screen injects this one.
    /// Starts `.inactive` (never presents before the first feed). A background-to-active edge ends
    /// a "Not now".
    var scenePhase: ScenePhase = .inactive {
        didSet { noteScenePhase(from: oldValue, to: scenePhase) }
    }

    /// Whether ContentView's launch preparation has finished.
    var launchComplete = false {
        didSet { if launchComplete != oldValue { scheduleEvaluation() } }
    }

    /// Whether First Aid or the stress explainer is ContentView's root sheet.
    var crisisSurfaceUp = false {
        didSet { if crisisSurfaceUp != oldValue { scheduleEvaluation() } }
    }

    /// Whether the camera's Develop review is up — written by the camera from its presentation
    /// flag and cleared in BOTH the camera's and the review sheet's `.onDisappear`. The gate reads it
    /// ANDed with `isInSession` (``gateInput``), so a missed clear cannot outlive the camera (I20).
    /// It also opens and closes ``developSaveFailureAcknowledgement``, so the Develop answer's wait
    /// for a failed export's alert ends with the review however it goes.
    var cameraDevelopReviewUp = false {
        didSet {
            guard cameraDevelopReviewUp != oldValue else { return }
            if cameraDevelopReviewUp {
                developSaveFailureAcknowledgement.reviewDidOpen()
            } else {
                developSaveFailureAcknowledgement.reviewDidClose()
            }
            scheduleEvaluation()
        }
    }

    // MARK: The snapshot the screen renders

    /// Whether the review is on screen.
    private(set) var isShowing = false
    /// The batch the snapshot was taken from; nil while hidden.
    private(set) var batchID: UUID?
    /// The held photos the review offers — exactly what an answer is scoped to.
    private(set) var photos: [FriendPhotoPayload] = []
    /// The keep-as-friend candidates, eligibility computed at presentation against the live vault.
    private(set) var candidates: [MeshSessionRosterEntry] = []
    /// The ticked photos (all of them at present).
    var selectedIDs: Set<UUID> = []
    /// The candidates the person chose to keep.
    var keptFriendFingerprints: Set<String> = []
    /// The opt-in camera-roll toggle, off each time the review presents; memory-only.
    var alsoSaveToPhotos = false
    /// Whether the wall can take a keep (refreshed at every evaluation while showing).
    private(set) var canKeep = true
    /// What the review is busy with (the Photos export, the leave).
    private(set) var workingMessage: FriendPhotoReviewWorkingMessage?
    /// Why the last answer did not apply in full.
    private(set) var answerFailure: SessionPhotoAnswerFailure?
    /// Kept photos the last answer removed because their held bytes could not be opened.
    private(set) var unreadableCount = 0
    /// A failed Photos export, shown as an alert inside the review before it hides.
    var photoSaveError: PhotoSaveFailure?

    // MARK: The discovery block's legs

    /// Answers in flight from either surface (the overlay's own, the camera's Develop through
    /// ``beginAnswer()`` / ``endAnswer()``) — the block's answer leg and the gate's wait.
    private(set) var answersInFlight = 0
    /// The overlay's OWN Keep or Delete all is running — the only thing that refuses its three
    /// actions. The camera's Develop answer counts toward ``answerInFlight`` but never disables this
    /// review, so a leg that outlived its surface can never leave a review nobody can dismiss (fix
    /// round 1, U3-C-U3-R1).
    private(set) var ownAnswerInFlight = false
    /// A leave this coordinator started is running.
    private(set) var leaveInFlight = false
    /// "Not now" this activation.
    private(set) var deferredByUser = false

    // MARK: Collaborators

    /// The mesh manager whose batch this presents and answers.
    @ObservationIgnored let manager: MeshNetworkManager
    /// Where the review draws.
    @ObservationIgnored let presenter: any SessionPhotoReviewPresenting
    /// The store, held weakly (it owns this coordinator).
    @ObservationIgnored private weak var host: (any SessionPhotoReviewHost)?
    /// The Photos-library export, injected by the store (`FriendPhotoLibrarySaver.save`) — called
    /// only from ``exportKeptPhotosIfAsked(_:)``.
    @ObservationIgnored private let saveKeptPhotosToLibrary: @MainActor ([FriendPhotoPayload]) async throws -> Void
    /// Leaves an ended mesh (`leaveSessionAfterNotifyingPeers()` in the app; a controllable seam in
    /// tests, so the block can be observed while the leave runs).
    @ObservationIgnored private let leaveEndedMesh: @MainActor (MeshNetworkManager) async -> Void
    /// Where the overlay's answer waits for a failed export's alert to be closed — open while the
    /// review is on screen (``present()`` opens it, both hides close it).
    @ObservationIgnored let saveFailureAcknowledgement = PhotoSaveFailureAcknowledgement(host: "overlay")
    /// Where the camera's Develop answer waits for the same alert — open while
    /// ``cameraDevelopReviewUp``. Held here, on the store-owned coordinator, rather than in the
    /// camera's `@State`: a termination tears the camera down under a running answer, and that
    /// answer must still reach the object whose close resumes it (fix round 1, U3-C-U3-R1).
    @ObservationIgnored let developSaveFailureAcknowledgement = PhotoSaveFailureAcknowledgement(host: "develop")
    /// A "Not now" whose deferral ends at the next activation (the scene went to the background).
    @ObservationIgnored private var deferralEndsOnActivation = false
    /// The settle before an evaluation.
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    /// The leave started at present (or at an answer), awaited before any hide.
    @ObservationIgnored private var leaveTask: Task<Void, Never>?

    /// How long an edge waits before the gate is read.
    static let settleDelay: Duration = .milliseconds(500)
    /// How long the "couldn't be opened" notice stays before the review hides.
    static let unreadableNoticeDuration: Duration = .milliseconds(1_800)

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - manager: The mesh manager.
    ///   - host: The store (held weakly).
    ///   - presenter: Where the review draws.
    ///   - saveKeptPhotosToLibrary: The Photos-library export for kept, wall-hydrated photos.
    ///   - leaveEndedMesh: How an ended mesh is left; defaults to the signed departure/termination.
    init(
        manager: MeshNetworkManager,
        host: (any SessionPhotoReviewHost)?,
        presenter: any SessionPhotoReviewPresenting,
        saveKeptPhotosToLibrary: @escaping @MainActor ([FriendPhotoPayload]) async throws -> Void,
        leaveEndedMesh: @escaping @MainActor (MeshNetworkManager) async -> Void = { await $0.leaveSessionAfterNotifyingPeers() }
    ) {
        self.manager = manager
        self.host = host
        self.presenter = presenter
        self.saveKeptPhotosToLibrary = saveKeptPhotosToLibrary
        self.leaveEndedMesh = leaveEndedMesh
    }

    /// Ends the two stored tasks if the coordinator is released (today it never is — the store owns
    /// it for the process lifetime). `isolated`: the handles are main-actor state.
    isolated deinit {
        evaluationTask?.cancel()
        leaveTask?.cancel()
    }

    // MARK: Derived

    /// Whether an answer is in flight from either surface.
    var answerInFlight: Bool { answersInFlight > 0 }

    /// Whether the session-photo review is what must keep discovery stopped — the run policy's
    /// `sessionPhotoReviewBlocksDiscovery` input (design §4.5, invariants I11 and I21).
    ///
    /// True while an ended session's photos are outstanding, and while an answer or a leave started
    /// here is still running, so the block cannot fall over a held mesh (which the policy would
    /// resume). **Never true while a session is live** — the whole disjunction is ANDed with
    /// `!isSessionLive` — so a live session's discovery is never changed by it, even while the
    /// camera's Develop answer (which raises ``beginAnswer()`` whatever the liveness) runs.
    var blocksDiscovery: Bool {
        guard !manager.isSessionLive else { return false }
        return manager.hasOutstandingPhotoReview || answerInFlight || leaveInFlight
    }

    /// The facts the gate reads right now.
    var gateInput: SessionPhotoReviewGate.Input {
        SessionPhotoReviewGate.Input(
            outstandingPhotoCount: manager.pendingReviewPhotos.count,
            sessionIsLive: manager.isSessionLive,
            heldPhotosCanBeShown: manager.heldPhotosCanBeShown,
            sceneIsActive: scenePhase == .active,
            launchComplete: launchComplete,
            // Fail closed without a host: no store means no decoy fact, so assume the decoy.
            duressSessionActive: host?.duressSessionActive ?? true,
            deleteAllInProgress: host?.deleteAllInProgress ?? true,
            crisisSurfaceUp: crisisSurfaceUp,
            cameraDevelopReviewUp: cameraDevelopReviewUp && manager.isInSession,
            deferredByUser: deferredByUser,
            isShowing: isShowing,
            answerInFlight: answerInFlight
        )
    }

    /// The launch restore's presentation as the Friends tab may show it: the resume OFFER is
    /// withheld while the review blocks discovery, because its promise ("keep this tab open and
    /// you'll reconnect") is false until the person has chosen. Endings and the could-not-reopen
    /// card are unaffected.
    ///
    /// - Parameter presentation: `MeshNetworkManager.sessionResumePresentation`.
    /// - Returns: The presentation, or `.nothing` in place of a blocked offer.
    func resumePresentation(_ presentation: MeshSessionResumePresentation) -> MeshSessionResumePresentation {
        guard presentation == .offerResume, blocksDiscovery else { return presentation }
        return .nothing
    }

    // MARK: Evaluation

    /// Asks for an evaluation a moment from now, replacing any pending one.
    ///
    /// A showing review that must step aside (a duress session, a delete-all, a crisis surface) is
    /// taken down at once rather than after the settle — only presenting waits for the burst to
    /// land.
    func scheduleEvaluation() {
        if isShowing, SessionPhotoReviewGate.mustStepAside(gateInput) { hideWithoutAnswer() }
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: SessionPhotoReviewCoordinator.settleDelay)
            } catch {
                return   // superseded by a newer edge (R7: nothing owed)
            }
            self?.evaluateNow()
        }
    }

    /// Reads the gate and acts on its verdict at once (tests call this directly; the app goes
    /// through ``scheduleEvaluation()``).
    func evaluateNow() {
        if isShowing { canKeep = manager.wallCanTakeKeeps }
        switch SessionPhotoReviewGate.verdict(for: gateInput) {
        case .present:
            present()
        case .hideWithoutAnswer:
            hideWithoutAnswer()
        case .stayUp, .wait:
            break
        }
    }

    /// Forwards the scene ContentView lives in to the presenter (the overlay window's scene), and
    /// asks the gate again: a review that could not draw before a scene existed draws now.
    ///
    /// - Parameter windowScene: The scene.
    func attach(to windowScene: UIWindowScene) {
        presenter.attach(to: windowScene)
        scheduleEvaluation()
    }

    /// The Friends card's "Choose photos": ends a "Not now" and evaluates at once.
    func reopen() {
        deferredByUser = false
        deferralEndsOnActivation = false
        evaluateNow()
    }

    /// Marks the start of an answer from either surface (the camera's Develop review raises it
    /// around its finish-and-leave with `defer`), before the manager is touched.
    func beginAnswer() {
        answersInFlight += 1
    }

    /// Marks the end of an answer, after that surface's leave has returned.
    func endAnswer() {
        guard answersInFlight > 0 else { return }
        answersInFlight -= 1
        scheduleEvaluation()
    }

    /// Resumes an answer waiting on a failed export's alert (the alert closed, or the screen went).
    func acknowledgeSaveFailure() {
        saveFailureAcknowledgement.acknowledge()
    }

    // MARK: Presenting and hiding

    /// Takes the snapshot and draws it; then leaves an ended mesh still held.
    private func present() {
        guard let batch = manager.pendingFriendReview else { return }
        let shown = manager.pendingReviewPhotos
        guard !shown.isEmpty else { return }
        batchID = batch.id
        photos = shown
        candidates = FriendMintingReview.eligibleCandidates(
            roster: batch.entries, trustedPeers: host?.trustedProximityPeers ?? []
        )
        selectedIDs = Set(shown.map(\.id))
        keptFriendFingerprints = []
        alsoSaveToPhotos = false
        canKeep = manager.wallCanTakeKeeps
        workingMessage = nil
        answerFailure = nil
        unreadableCount = 0
        photoSaveError = nil   // a failure from an earlier review never opens this one
        guard presenter.show(self) else {
            clearSnapshot()
            return
        }
        isShowing = true
        saveFailureAcknowledgement.reviewDidOpen()
        FernletAuditLog.log("sessionPhotoReview.presented", context: ["photos": String(shown.count)])
        leaveEndedMeshIfHeld()
    }

    /// Takes the review down answering nothing (a duress session, a delete-all, a crisis surface).
    /// The batch, photos and candidates, stays in the manager; the review presents again once the
    /// cause clears — and once an answer still running under it has ended (the gate's
    /// `answerInFlight` leg). A leave already running keeps running (and keeps the block up). An
    /// answer waiting on a failed export's alert is released, and one whose export fails later
    /// does not wait: the alert went with the review.
    private func hideWithoutAnswer() {
        presenter.hide()
        isShowing = false
        clearSnapshot()
        saveFailureAcknowledgement.reviewDidClose()
        FernletAuditLog.log("sessionPhotoReview.hiddenWithoutAnswer")
    }

    /// Takes the review down after an answer or a "Not now", and asks the gate again — a photo
    /// promoted while the review was up was not in the snapshot, so it is presented next.
    private func hide() {
        presenter.hide()
        isShowing = false
        clearSnapshot()
        saveFailureAcknowledgement.reviewDidClose()
        scheduleEvaluation()
    }

    /// Empties the snapshot.
    private func clearSnapshot() {
        batchID = nil
        photos = []
        candidates = []
        selectedIDs = []
        keptFriendFingerprints = []
        alsoSaveToPhotos = false
        workingMessage = nil
        answerFailure = nil
        unreadableCount = 0
    }

    /// Records a background edge after a "Not now", and ends the deferral on the next activation.
    private func noteScenePhase(from old: ScenePhase, to new: ScenePhase) {
        guard old != new else { return }
        if new == .background, deferredByUser { deferralEndsOnActivation = true }
        if new == .active, deferralEndsOnActivation {
            deferredByUser = false
            deferralEndsOnActivation = false
        }
        scheduleEvaluation()
    }

    // MARK: The leave

    /// Starts leaving the mesh this device still holds for an ended session (door 3's give-up keeps
    /// it for exactly this), unless a leave is already running. Bounded by the manager's own
    /// 15-second handoff. Never over a live session.
    private func leaveEndedMeshIfHeld() {
        guard leaveTask == nil, manager.currentMesh != nil, !manager.isSessionLive else { return }
        leaveInFlight = true
        let manager = self.manager
        let leave = leaveEndedMesh
        FernletAuditLog.log("sessionPhotoReview.leavingEndedMesh")
        leaveTask = Task { [weak self] in
            await leave(manager)
            self?.leaveDidReturn()
        }
    }

    /// The leave returned: the block's leave leg falls.
    private func leaveDidReturn() {
        leaveTask = nil
        leaveInFlight = false
        scheduleEvaluation()
    }

    /// Waits for a running leave, showing "Ending the session..." with the buttons disabled.
    private func awaitLeave() async {
        guard let leaveTask else { return }
        workingMessage = .endingSession
        await leaveTask.value
        if workingMessage == .endingSession { workingMessage = nil }
    }

    // MARK: Answering

    /// "Not now": waits for a running leave, then hides answering nothing. The review comes back
    /// at the next background-to-active edge or a tap on the Friends card; nothing is written.
    /// Refused only while this review's own answer runs, never for another surface's.
    func notNow() async {
        guard isShowing, !ownAnswerInFlight else { return }
        await awaitLeave()
        guard isShowing else { return }
        deferredByUser = true
        deferralEndsOnActivation = false
        FernletAuditLog.log("sessionPhotoReview.deferred")
        hide()
    }

    /// Keep selected: keeps the ticked shown photos (the unticked shown ones are deleted), answers
    /// the friend half, exports what the answer reports kept if the toggle is on, waits for the
    /// leave, and hides — or stays up with the inline failure when photos were left held.
    func keepSelected() async {
        guard isShowing, let batchID, !ownAnswerInFlight else { return }
        ownAnswerInFlight = true
        beginAnswer()
        let answer = manager.finishReviewedPhotos(Set(photos.map(\.id)), keeping: selectedIDs, in: batchID)
        answerFriendHalf(of: batchID)
        await exportKeptPhotosIfAsked(answer)
        if photoSaveError != nil { await saveFailureAcknowledgement.wait() }
        await finish(after: answer)
        ownAnswerInFlight = false
        endAnswer()
    }

    /// Delete all (after the sheet's own confirmation): deletes every shown photo and answers the
    /// friend half. Needs only the pending index, so it works while the wall cannot be read.
    func discardAll() async {
        guard isShowing, let batchID, !ownAnswerInFlight else { return }
        ownAnswerInFlight = true
        beginAnswer()
        let answer = manager.finishReviewedPhotos(Set(photos.map(\.id)), keeping: [], in: batchID)
        answerFriendHalf(of: batchID)
        await finish(after: answer)
        ownAnswerInFlight = false
        endAnswer()
    }

    /// The friend half: mints the kept candidates and consumes the batch's candidates — once; the
    /// section leaves the review with it, so a retry after an unapplied photo answer cannot mint
    /// twice.
    private func answerFriendHalf(of batchID: UUID) {
        host?.keepProximityFriends(from: candidates, keptFingerprints: keptFriendFingerprints)
        manager.completeFriendReview(batchID)
        candidates = []
        keptFriendFingerprints = []
    }

    /// The camera-roll half of the answer, and the ONLY place this coordinator reaches the Photos
    /// library (I2): the photos the answer reports landed on the wall
    /// (`SessionPhotoAnswer.keptOnWall`), hydrated from the WALL — never a pending byte, never
    /// before the answer. Purely additive: a failure (a Photos denial included) sets
    /// ``photoSaveError``, whose alert the still-present review shows, and never touches the keep.
    ///
    /// - Parameter answer: What the keep just did.
    private func exportKeptPhotosIfAsked(_ answer: SessionPhotoAnswer) async {
        guard alsoSaveToPhotos, !answer.keptOnWall.isEmpty else { return }
        let toSave = manager.hydratedPhotos(manager.meshPhotos.filter { answer.keptOnWall.contains($0.id) })
        // If no bytes could be loaded/decrypted, don't report a false success.
        guard !toSave.isEmpty else {
            photoSaveError = .generic
            return
        }
        workingMessage = .savingToPhotos
        defer { workingMessage = nil }
        do {
            try await saveKeptPhotosToLibrary(toSave)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            photoSaveError = FriendPhotoLibrarySaver.userFacingFailure(for: error, photoCount: toSave.count)
        }
    }

    /// After an answer: stay up when it left photos held (the snapshot shrinks to exactly those,
    /// the ticks are trimmed, the inline line says why — I25), or show the "couldn't be opened"
    /// notice when there is one, wait for the leave (starting it if an ended mesh is still held),
    /// and hide.
    private func finish(after answer: SessionPhotoAnswer) async {
        guard answer.notApplied.isEmpty else {
            answerFailure = answer.failure
            photos = photos.filter { answer.notApplied.contains($0.id) }
            selectedIDs.formIntersection(Set(photos.map(\.id)))
            return
        }
        answerFailure = nil
        if !answer.unreadable.isEmpty {
            unreadableCount = answer.unreadable.count
            await pauseForUnreadableNotice()
        }
        leaveEndedMeshIfHeld()
        await awaitLeave()
        hide()
    }

    /// Holds the review on screen long enough to read the "couldn't be opened" line (it is also
    /// announced). Cancellation just ends the pause early — the hide still runs.
    private func pauseForUnreadableNotice() async {
        do {
            try await Task.sleep(for: SessionPhotoReviewCoordinator.unreadableNoticeDuration)
        } catch {
            return   // cancelled: hide at once (R7: nothing owed)
        }
    }
}

// MARK: - SessionPhotoReviewTriggers

/// ContentView's half of the coordinator: the window-scene reader, the facts only the root view
/// has (the scene phase, the launch, the root sheet), and an evaluation on every manager and store
/// edge the gate reads (design §4.5 "Triggers").
///
/// A modifier rather than a dozen `onChange`s in ContentView's `body`, which is held to 60 code
/// lines like every other.
struct SessionPhotoReviewTriggers: ViewModifier {
    /// The store that owns the coordinator and the manager.
    let store: FernletStore
    /// ContentView's root sheet.
    let activeSheet: FernletSheet?
    /// ContentView's `launcher.isDone`.
    let launchComplete: Bool
    /// ContentView's scene phase.
    let scenePhase: ScenePhase

    private var coordinator: SessionPhotoReviewCoordinator { store.sessionPhotoReviewCoordinator }
    private var manager: MeshNetworkManager { store.meshNetworkManager }

    func body(content: Content) -> some View {
        content
            .background(WindowSceneReader { coordinator.attach(to: $0) })
            .onChange(of: scenePhase, initial: true) { _, phase in coordinator.scenePhase = phase }
            .onChange(of: launchComplete, initial: true) { _, done in coordinator.launchComplete = done }
            .onChange(of: SessionPhotoReviewGate.isCrisisSurface(activeSheet), initial: true) { _, up in
                coordinator.crisisSurfaceUp = up
            }
            .onChange(of: manager.pendingFriendReview) { _, _ in coordinator.scheduleEvaluation() }
            .onChange(of: manager.isSessionLive) { _, _ in coordinator.scheduleEvaluation() }
            .onChange(of: manager.heldPhotosCanBeShown) { _, _ in coordinator.scheduleEvaluation() }
            .onChange(of: manager.isInSession) { _, _ in coordinator.scheduleEvaluation() }
            .onChange(of: store.duressSessionActive) { _, _ in coordinator.scheduleEvaluation() }
            .onChange(of: store.deleteAllInProgress) { _, _ in coordinator.scheduleEvaluation() }
    }
}
