import FernletConnections
import FernletProximityUI
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI

/// The session-end KEEP-AS-FRIENDS prompt (`b3-keep-friends`), presented from the root wherever the
/// person is, Home included (owner, 2026-10-24, question 2: "Show it wherever you are, Home
/// included"). It used to be the Album's (``FriendsView``), which asked only when the panel next
/// opened; ContentView now hangs this on its root, once, beside the session-end photo review's
/// triggers (``SessionPhotoReviewTriggers``).
///
/// Driven off OBSERVABLE MODEL STATE (Phase 2, "Session-end review is model-state, not
/// view-events"): it presents whenever a promoted `pendingFriendReview` batch carries candidates and
/// NO photos, run by the deferred check every trigger schedules (``scheduleReviewCheck()``: the
/// batch moving, the session ending, a peer lost, the root appearing, scene activation, a covering
/// presentation going away, the launch finishing, the decoy ending, the overlay going) and confirmed
/// by the landing watchdog. Friend candidates come from the BATCH entries; eligibility is computed at
/// presentation time against the live trust vault, so peers trusted or blocked mid-session never
/// reach the prompt. Shown once per session end: its dismissal mints only the toggled keeps (one-sided,
/// via `keepProximityFriends`) and consumes the presented batch with `completeFriendReview` — never by
/// clearing the live roster, which would clobber the next session's entries.
///
/// **Photos first** (session photos U3, invariant I17). A batch with photos is the overlay's
/// (``SessionPhotoReviewCoordinator``), which answers its candidates inside the photo review, so this
/// returns early while photos are outstanding, while the overlay shows and while the review blocks
/// discovery; a prompt already up is withdrawn unconsumed the moment the overlay shows.
///
/// **Only once the SESSION has ended** (`isSessionLive`, P6 item 2): a founded mesh outlives its
/// links, and a two-second blip must never present a prompt whose dismissal mints friends and
/// consumes the batch mid-session. A session that goes live again while the prompt is up withdraws it
/// unconsumed; the batch re-presents, merged, at the next real teardown.
///
/// **It never requests over a presentation, and a request is not proof** (2026-09-30 fix round,
/// C-F2/L-F2). It waits out the root's own presentations (``isRootSheetUp``), which its request would
/// otherwise REPLACE, and every full-screen cover below the root (``isCoverUp``: Home's camera, the
/// Album's wall photo, a "Just you" set, the session celebration), over which a sheet request is
/// dropped; each schedules a re-check when it goes. A request that still does not land is withdrawn
/// unconsumed and re-asked a bounded number of times by ``confirmSessionEndSheetLanded()``.
///
/// **A decoy never sees it**: a duress session shows and keeps nothing real, so the check refuses
/// while one is open and a prompt that is up is withdrawn, unanswered, when one starts.
struct KeepFriendsPromptHost: ViewModifier {
    var store: FernletStore
    /// Whether one of the root's own presentations covers the tabs (the root sheet, the connection
    /// inspector, a recipe share review, a Messages import…).
    var isRootSheetUp: Bool
    /// Whether the launch screen has finished.
    var launchComplete: Bool
    /// Whether a full-screen cover hangs below the root: the World Home's camera, or one of the
    /// Album's covers (a wall photo, a "Just you" set, the session celebration).
    var isCoverUp: Bool
    /// The prompt's presentation, shared with the Album's heal arm (``FriendsView``), which never
    /// celebrates in the same transaction as this sheet.
    @Binding var keepFriendsPromptPresented: Bool

    /// The promoted batch this host is presenting (consumed via `completeFriendReview` on finalize).
    @State private var reviewBatch: MeshFriendReviewBatch?
    /// The batch's eligible candidates, snapshotted at presentation time.
    @State private var friendCandidates: [MeshSessionRosterEntry] = []
    /// The candidates the person switched on.
    @State private var keptFriendFingerprints: Set<String> = []
    /// Bumped to run a deferred session-end check (``scheduleReviewCheck()``).
    @State private var reviewCheckRequest = 0
    /// Bumped on every request; its task is the landing watchdog (``confirmSessionEndSheetLanded()``).
    @State private var reviewLandingRequest = 0
    /// Set by the prompt's content appearing — the only proof a request landed.
    @State private var sessionEndSheetLanded = false
    /// Watchdog re-requests left for the current trigger (R2: each trigger resets it to the bound).
    @State private var reviewRetriesLeft = 0
    @Environment(\.scenePhase) private var scenePhase

    /// How long a trigger waits before presenting: past the dismissal of whatever it fired beside.
    private static let reviewCheckDelay: Duration = .milliseconds(700)
    /// How long a request has to land before the watchdog withdraws it.
    private static let reviewLandingGrace: Duration = .seconds(2)
    /// Re-requests per trigger after a request that did not land (R2).
    private static let maxReviewRetries = 4

    private var manager: MeshNetworkManager { store.meshNetworkManager }
    /// The session photos (`features.photos`): the review batch and its keep-as-friend candidates.
    private var features: FernletMeshFeatures { store.meshFeatures }
    /// The app-level presenter of the session-end photo review (session photos U3).
    private var reviewCoordinator: SessionPhotoReviewCoordinator { store.sessionPhotoReviewCoordinator }

    /// Whether anything is up that the prompt must not be requested over: itself, a root
    /// presentation, or a cover below the root.
    private var aPresentationIsUp: Bool {
        keepFriendsPromptPresented || isRootSheetUp || isCoverUp
    }

    func body(content: Content) -> some View {
        content
            // A review that predates the root (a session that ended before this launch) is model state.
            .onAppear { scheduleReviewCheck() }
            // Every trigger schedules rather than presents (see scheduleReviewCheck).
            .onChange(of: features.photos.pendingFriendReview) { _, _ in scheduleReviewCheck() }
            .onChange(of: manager.isSessionLive) { _, live in if !live { scheduleReviewCheck() } }
            .onChange(of: manager.hasCommittedPeer) { hadPeer, hasPeer in
                handleCommittedPeerChange(hadPeer: hadPeer, hasPeer: hasPeer)
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { scheduleReviewCheck() } }
            .onChange(of: isRootSheetUp) { _, up in if !up { scheduleReviewCheck() } }
            .onChange(of: isCoverUp) { _, up in if !up { scheduleReviewCheck() } }
            .onChange(of: launchComplete) { _, done in if done { scheduleReviewCheck() } }
            .onChange(of: store.duressSessionActive) { _, decoy in handleDecoyChange(decoy) }
            // Photos first (I17): the overlay showing withdraws a prompt that is up, unanswered; the
            // overlay going, or the review's discovery block falling, is when a prompt may be due.
            .onChange(of: reviewCoordinator.isShowing) { _, showing in handleOverlayChange(showing: showing) }
            .onChange(of: reviewCoordinator.blocksDiscovery) { _, blocked in if !blocked { scheduleReviewCheck() } }
            .task(id: reviewCheckRequest) { await runDeferredReviewCheck() }
            .task(id: reviewLandingRequest) { await confirmSessionEndSheetLanded() }
            // Dismissing without choosing = skip all: onDismiss mints only the toggled keeps and
            // consumes the presented batch either way (unless the prompt was withdrawn, in which
            // case the batch survives and re-presents).
            .sheet(isPresented: $keepFriendsPromptPresented, onDismiss: finalizeFriendKeeps) {
                keepFriendsPromptSheet
            }
    }

    /// The compact "keep these as friends?" prompt for a session that produced no photos, in the
    /// one design language (the root's sheets carry it on their content).
    private var keepFriendsPromptSheet: some View {
        KeepFriendsPromptSheet(
            candidates: friendCandidates,
            keptFingerprints: $keptFriendFingerprints,
            done: { keepFriendsPromptPresented = false }
        )
        .fernletSheet()
        .worldDesignLanguage()
        .onAppear { sessionEndSheetLanded = true }
    }

    /// A peer committing while the prompt is up means a session went live again: withdraw it
    /// unconsumed (the heal arm's rule). A peer lost is a trigger.
    private func handleCommittedPeerChange(hadPeer: Bool, hasPeer: Bool) {
        if !hadPeer && hasPeer {
            guard keepFriendsPromptPresented else { return }
            withdrawUnlandedSessionEndSheet()
        } else if hadPeer && !hasPeer {
            scheduleReviewCheck()
        }
    }

    /// A decoy starting takes a standing prompt down, unanswered; a decoy ending is a trigger.
    private func handleDecoyChange(_ decoy: Bool) {
        guard decoy else {
            scheduleReviewCheck()
            return
        }
        guard keepFriendsPromptPresented else { return }
        withdrawUnlandedSessionEndSheet()
    }

    /// Presents the prompt when it is due (see the type's notes: the session over, nothing up, the
    /// launch done, no decoy, photos first, a batch with eligible candidates and no photos).
    private func presentDisconnectReviewIfNeeded() {
        guard !manager.isSessionLive else { return }
        // ``aPresentationIsUp``: a `.sheet` requested over a cover is dropped, and one requested over
        // a root presentation replaces it.
        guard !aPresentationIsUp else { return }
        // Not under the launch screen, and never in a decoy.
        guard launchComplete, !store.duressSessionActive else { return }
        // Photos first (I17): the overlay answers a photo batch's candidates, once.
        guard !features.photos.hasOutstandingPhotoReview, !reviewCoordinator.isShowing,
              !reviewCoordinator.blocksDiscovery else { return }
        guard let batch = features.photos.pendingFriendReview else { return }
        reviewBatch = batch
        friendCandidates = FriendMintingReview.eligibleCandidates(
            roster: batch.entries,
            trustedPeers: store.trustedProximityPeers
        )
        keptFriendFingerprints = []
        switch FriendMintingReview.sessionEndReview(hasPhotos: false, eligibleCandidateCount: friendCandidates.count) {
        case .friendPromptOnly:
            keepFriendsPromptPresented = true
            noteSessionEndSheetRequested()
        case .none:
            // Nothing to review — consume the batch immediately so it can't re-present.
            features.photos.completeFriendReview(batch.id)
            reviewBatch = nil
            friendCandidates = []
        case .photoReview:
            // Unreachable with `hasPhotos: false`; answered, not trapped, and answering nothing.
            reviewBatch = nil
            friendCandidates = []
        }
    }

    /// Completes the keep-as-friend flow: mints the kept candidates (one-sided, local-only) and
    /// consumes the PRESENTED batch via completeFriendReview. A no-op when the prompt was withdrawn
    /// (batch nil).
    private func finalizeFriendKeeps() {
        if let batch = reviewBatch {
            store.keepProximityFriends(from: friendCandidates, keptFingerprints: keptFriendFingerprints)
            features.photos.completeFriendReview(batch.id)
        }
        reviewBatch = nil
        friendCandidates = []
        keptFriendFingerprints = []
    }

    /// The overlay's edges (invariant I17). Rising: a prompt that is up is withdrawn WITHOUT minting or
    /// consuming, `reviewBatch` cleared first so the sheet's `onDismiss` finalize is a no-op, because a
    /// late photo can have turned a candidates-only batch into a photo batch under it. Falling: a
    /// prompt may be due.
    private func handleOverlayChange(showing: Bool) {
        guard showing else {
            scheduleReviewCheck()
            return
        }
        guard keepFriendsPromptPresented else { return }
        reviewBatch = nil
        friendCandidates = []
        keptFriendFingerprints = []
        keepFriendsPromptPresented = false
    }

    // MARK: - Scheduling and the landing watchdog

    /// Asks for a check a moment from now (``runDeferredReviewCheck()``), with a fresh watchdog
    /// budget. Every trigger schedules; none presents on the spot, so the prompt is never requested
    /// in the same transaction as another presentation coming or going.
    private func scheduleReviewCheck() {
        reviewRetriesLeft = Self.maxReviewRetries
        reviewCheckRequest &+= 1
    }

    /// The deferred half of ``scheduleReviewCheck()``: waits out ``reviewCheckDelay``, then presents
    /// if the prompt is still due.
    private func runDeferredReviewCheck() async {
        do {
            try await Task.sleep(for: Self.reviewCheckDelay)
        } catch {
            return   // superseded by a newer request (R7: nothing owed)
        }
        presentDisconnectReviewIfNeeded()
    }

    /// Marks a request unlanded and arms its watchdog.
    private func noteSessionEndSheetRequested() {
        sessionEndSheetLanded = false
        reviewLandingRequest &+= 1
    }

    /// The landing watchdog. A prompt whose content has not appeared within ``reviewLandingGrace``
    /// was dropped (or queued behind a sheet below the root), and its flag, left true, would latch
    /// ``aPresentationIsUp`` shut. So it is withdrawn WITHOUT consuming anything and re-requested
    /// through the deferred check, at most ``maxReviewRetries`` times per trigger (R2).
    private func confirmSessionEndSheetLanded() async {
        guard keepFriendsPromptPresented else { return }
        do {
            try await Task.sleep(for: Self.reviewLandingGrace)
        } catch {
            return   // a newer request re-armed the watchdog (R7)
        }
        guard keepFriendsPromptPresented, !sessionEndSheetLanded else { return }
        withdrawUnlandedSessionEndSheet()
        guard reviewRetriesLeft > 0 else { return }
        reviewRetriesLeft -= 1
        reviewCheckRequest &+= 1
    }

    /// Lowers the prompt's flag without answering anything. `reviewBatch` goes first so the prompt's
    /// `onDismiss` finalize is a no-op.
    private func withdrawUnlandedSessionEndSheet() {
        reviewBatch = nil
        friendCandidates = []
        keptFriendFingerprints = []
        keepFriendsPromptPresented = false
    }
}
