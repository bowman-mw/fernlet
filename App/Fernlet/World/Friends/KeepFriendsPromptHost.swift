import FernletConnections
import FernletProximityUI
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI
import UIKit

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
/// dropped; each schedules a re-check when it goes. Since the owner's form answer 47 (2026-10-25) it
/// also waits out any sheet or cover a panel has up (Food's meal sheet, Move's runner…), read from
/// UIKit's presentation chain in its own window (``KeepFriendsWindowAnchor``), and asks as soon as that closes,
/// with no giving up after a few tries. A request that still does not land with nothing covering it
/// is withdrawn unconsumed and re-asked a bounded number of times by ``confirmSessionEndSheetLanded()``.
///
/// **A decoy never sees it**: a duress session shows and keeps nothing real, so the check refuses
/// while one is open and a prompt that is up is withdrawn, unanswered, when one starts.
struct KeepFriendsPromptHost: ViewModifier {
    var store: FernletStore
    /// Whether one of the root's other presentations covers the tabs (the root sheet, the connection
    /// inspector, a recipe share review, a Messages import…). Never this prompt itself: its watchdog's
    /// withdrawal would then read as a covering sheet going away and re-arm the check without bound.
    var isRootSheetUp: Bool
    /// Whether the launch screen has finished.
    var launchComplete: Bool
    /// Whether a full-screen cover hangs below the root: the World Home's camera, or one of the
    /// Album's covers (a wall photo, a "Just you" set, the session celebration).
    var isCoverUp: Bool
    /// The prompt's presentation, shared with the Album's heal arm (``FriendsView``), which never
    /// celebrates in the same transaction as this sheet.
    @Binding var keepFriendsPromptPresented: Bool
    /// Whether the hangout being asked about began with two phones tapped together on Home, so each
    /// name says "met by tapping phones" under it (World Friends spec §1.3, `fr-tap-keep`). False until
    /// the tap's hangout says so; the tap lane sets it where the host is applied.
    var metByTapping = false

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
    /// Watchdog re-requests left for the current trigger, for a request that missed with nothing covering
    /// it (R2: each trigger resets it to the bound). A covering sheet costs none: the check waits it out.
    @State private var reviewRetriesLeft = 0
    @Environment(\.scenePhase) private var scenePhase
    /// The window this host lives in, so it waits only for what that window presents (form answer 47).
    @State private var windowAnchor = KeepFriendsWindowAnchor()

    /// How long a trigger waits before presenting: past the dismissal of whatever it fired beside.
    private static let reviewCheckDelay: Duration = .milliseconds(700)
    /// How long a request has to land before the watchdog withdraws it.
    private static let reviewLandingGrace: Duration = .seconds(2)
    /// Re-requests per trigger after a request that did not land with nothing covering it (R2).
    private static let maxReviewRetries = 4
    /// How often the check looks again while another sheet or cover is up (form answer 47).
    private static let coverPollInterval: Duration = .milliseconds(500)
    /// The most looks one wait takes: twelve hours at ``coverPollInterval`` (R2: bounded). A longer
    /// cover is waited out by the next trigger instead (the app coming back, a root sheet closing).
    private static let maxCoverPolls = 86_400

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
            .background { KeepFriendsWindowReader(anchor: windowAnchor).frame(width: 0, height: 0) }
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
            metByTapping: metByTapping,
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

    /// The deferred half of ``scheduleReviewCheck()``: waits out ``reviewCheckDelay`` and, while a
    /// review waits, any sheet or cover still up (form answer 47: the prompt shows as soon as the other
    /// sheet closes), then presents if the prompt is still due.
    private func runDeferredReviewCheck() async {
        do {
            try await Task.sleep(for: Self.reviewCheckDelay)
        } catch {
            return   // superseded by a newer request (R7: nothing owed)
        }
        if features.photos.pendingFriendReview != nil, !keepFriendsPromptPresented {
            guard await waitUntilNothingIsPresented() else { return }
        }
        presentDisconnectReviewIfNeeded()
    }

    /// Looks every ``coverPollInterval`` until nothing is presented over the root; false when the task
    /// was superseded or the wait reached ``maxCoverPolls``.
    private func waitUntilNothingIsPresented() async -> Bool {
        for _ in 0..<Self.maxCoverPolls {
            guard windowAnchor.somethingIsPresented else { return true }
            do {
                try await Task.sleep(for: Self.coverPollInterval)
            } catch {
                return false   // superseded by a newer request (R7: nothing owed)
            }
        }
        return false
    }

    /// Marks a request unlanded and arms its watchdog.
    private func noteSessionEndSheetRequested() {
        sessionEndSheetLanded = false
        reviewLandingRequest &+= 1
    }

    /// The landing watchdog. A prompt whose content has not appeared within ``reviewLandingGrace``
    /// was dropped (or queued behind a sheet below the root), and its flag, left true, would latch
    /// ``aPresentationIsUp`` shut. So it is withdrawn WITHOUT consuming anything and re-requested
    /// through the deferred check. A sheet or cover that came up over it costs no retry: the deferred
    /// check waits for it to close and asks again at once (form answer 47). A miss with nothing
    /// covering it is re-asked at most ``maxReviewRetries`` times per trigger (R2).
    private func confirmSessionEndSheetLanded() async {
        guard keepFriendsPromptPresented else { return }
        do {
            try await Task.sleep(for: Self.reviewLandingGrace)
        } catch {
            return   // a newer request re-armed the watchdog (R7)
        }
        guard keepFriendsPromptPresented, !sessionEndSheetLanded else { return }
        withdrawUnlandedSessionEndSheet()
        if !windowAnchor.somethingIsPresented {
            guard reviewRetriesLeft > 0 else { return }
            reviewRetriesLeft -= 1
        }
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

/// The window the keep-as-friends host lives in, and whether that window presents anything now: a sheet
/// or a full-screen cover from any panel, or the root's own (form answer 47). Read from UIKit's
/// presentation chain, so the prompt waits for whatever is up to close instead of being dropped under
/// it. Before the host is in a window, nothing counts as presented (the host asks as it always has).
/// Main actor, as UIKit is.
final class KeepFriendsWindowAnchor {
    /// The host's window, set by ``KeepFriendsWindowReader`` as it moves in and out of one.
    weak var window: UIWindow?

    /// True while the window's root view controller is presenting something.
    var somethingIsPresented: Bool {
        window?.rootViewController?.presentedViewController != nil
    }
}

/// A zero-size, untouchable view behind the host's content that tells its ``KeepFriendsWindowAnchor``
/// which window it is in.
struct KeepFriendsWindowReader: UIViewRepresentable {
    let anchor: KeepFriendsWindowAnchor

    func makeUIView(context: Context) -> KeepFriendsWindowView {
        let view = KeepFriendsWindowView()
        view.anchor = anchor
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: KeepFriendsWindowView, context: Context) {
        uiView.anchor = anchor
        anchor.window = uiView.window
    }
}

/// The UIKit half of ``KeepFriendsWindowReader``: hands its window to the anchor whenever it moves.
final class KeepFriendsWindowView: UIView {
    /// Where the window goes.
    var anchor: KeepFriendsWindowAnchor?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        anchor?.window = window
    }
}
