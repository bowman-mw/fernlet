import ProximityKit
import FernletConnections
import FernletSocial
import SwiftUI
import UIKit
import FernletDomainModel
import PrivateMediaStore
import FernletUI
import FernletProximityUI
import FernletConnections

/// The pages the Friends album pushes onto its own `NavigationStack`, as path values.
///
/// A path — rather than the view-destination links these used to be — is what lets a re-tap of the
/// Friends tab pop them back to the album (``TabReselectModifier``). Pages pushed from these in turn
/// (Friends & Blocks → Safety & reporting) stay their own navigation and come off with them.
///
/// `friendShop` is pushed from the post-session shop-window card, and closes with its window: the
/// view-destination link it replaced vanished with the card when the one-hour window lapsed (or
/// closed early, or sharing was turned off) and popped the shop, so the album now pops it itself at
/// that moment (``shopClosesAt(sharingEnabled:windowExpiresAt:)``, ``closingShop(_:)``).
nonisolated enum FriendsRoute: Hashable {
    /// Group Activities.
    case activities
    /// Friends & Blocks — from the header, and from the "You appear as" display-name hint.
    case friendList
    /// The friend shops exchanged during the last session.
    case friendShop
    /// Your own shop (`b2-shop-editor`): what friends nearby can buy from you. Pushed from Friend
    /// shops, so it closes with the shop window too (``closingShop(_:)`` drops what sits above it).
    case yourShop

    /// When a pushed friend shop has to close: its window's expiry, or `.distantPast` — at once —
    /// when no window is open or nearby clothing sharing is off (the two conditions under which the
    /// shop-window card, the shop's only entry point, is not drawn).
    static func shopClosesAt(sharingEnabled: Bool, windowExpiresAt: Date?) -> Date {
        guard sharingEnabled, let windowExpiresAt else { return .distantPast }
        return windowExpiresAt
    }

    /// `path` with the friend shop, and anything pushed above it, taken off. Unchanged when the
    /// shop is not pushed.
    static func closingShop(_ path: [FriendsRoute]) -> [FriendsRoute] {
        guard let shop = path.firstIndex(of: .friendShop) else { return path }
        return Array(path[..<shop])
    }
}

// MARK: - FriendsView

/// The Friends panel's root: the shared photo album, idle or in a session (World Review `b2-friends-root`
/// draft 3 and `b3-friends-session` draft 2).
///
/// **The album never swaps for the camera any more** (owner, 2026-10-24). Idle, the slim row under the
/// two header buttons says whether this phone is looking for nearby friends (with the QR verify
/// ceremony on manual commits, and "Change name" while no name is set); in a session the same slot is
/// one slim session row with a Camera button, which presents ``DisposableCameraView`` full screen over
/// the panel. The ``ConnectionSuccessOverlay`` — played off `hasCommittedPeer`, the "is there a peer
/// right now" predicate (P6 item 2) — still celebrates a session's commit, and the album stays under
/// it. The camera is also offered from Home's blue button, and Messages, Session info and Leave live
/// on Home's session button (``WorldSessionButton``).
///
/// **The session-end PHOTO review is not this view's** (session photos U3, 2026-09-30: "the pop up
/// screen for selecting photos should be the first thing shown"). ``SessionPhotoReviewCoordinator``
/// presents it app-wide in its own overlay window, above whatever tab or sheet is up. This view
/// keeps two pieces of it: the ``PendingPhotoReviewCard`` in the album's nearby-status slot while
/// photos are waiting (its "Choose photos" re-presents a review put off with "Not now"), and the
/// launch restore's resume OFFER withheld while the review blocks discovery.
///
/// It still owns the compact keep-as-friends prompt for a session that produced NO photos:
/// `presentDisconnectReviewIfNeeded()` presents it off observable model state
/// (`pendingFriendReview`'s candidates), gated on `isSessionLive` so it presents once the SESSION
/// has ended and never on a link blip, and — photos first (invariant I17) — never while photos are
/// outstanding, the overlay is up or the review blocks discovery; a prompt already up is withdrawn
/// unconsumed the moment the overlay shows, so a batch that turned into a photo batch under it has
/// its candidates answered once, by the overlay. Every trigger schedules a short-deferred check
/// rather than presenting on the spot, the check never requests over the camera's own sheets or the
/// root sheet, and a request whose sheet never appears is withdrawn unconsumed and re-asked by a
/// bounded landing watchdog. Kept friends are minted one-sided via ``FernletStore``'s
/// `keepProximityFriends`, and the candidate half is consumed with `completeFriendReview` — never by
/// clearing the live roster, which would clobber the next session's entries.
struct FriendsView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    @State private var showConnectionAnimation = false
    /// The name the celebration shows: sampled at commit, and adopted once if it arrives while the
    /// overlay is still up (Option 1b withholds it until the peer's first post-commit envelope).
    /// Nil shows "Connected" alone, never an identifier in its place.
    @State private var connectionPeerName: String?
    /// The session camera, presented full screen from the session row's Camera button.
    @State private var cameraPresented = false
    /// Whether the album is on screen (the Friends panel is open): only then does it host the
    /// session's prompts.
    @State private var albumIsVisible = false
    /// The removal proposal this panel is asking about, if any.
    @State private var activeRemovalProposal: MeshRemovalProposalPayload?
    /// "Your friend's here" is felt on a session's first commit only; a link that blips and heals
    /// replays the overlay in silence (report B20, ``SessionConnectCue``).
    @State private var connectCue = SessionConnectCue()
    // Phase 2 friend minting: the promoted batch this instance is presenting (consumed via
    // completeFriendReview on finalize), candidates snapshotted at presentation time, and keeps.
    @State private var reviewBatch: MeshFriendReviewBatch?
    @State private var friendCandidates: [MeshSessionRosterEntry] = []
    @State private var keptFriendFingerprints: Set<String> = []
    @State private var keepFriendsPromptPresented = false
    @State private var selectedAlbumPostID: UUID?
    @State private var sessionSearchText = ""
    @State private var cacheWarningDismissed = false
    /// P7 item 5: the restore card is dismissable for this instance of the surface; the value it
    /// presents is the manager's, sampled on appear.
    @State private var sessionResumeDismissed = false
    /// The album stack's pushed pages. Cleared in one write when the Friends tab is re-tapped, and
    /// when a session that had swapped the album out for the camera ends (see
    /// ``handleSessionSurfaceChange(wasInSession:nowInSession:)``).
    @State private var path: [FriendsRoute] = []
    /// The album root's own scroll-to-top token; `tabReselect` bumps it only when nothing is pushed.
    @State private var scrollToTopToken = 0

    /// Whether the live camera (this surface's own child) has a sheet or alert of its own up,
    /// reported by `DisposableCameraView`. A session-end sheet requested over one queues behind it
    /// with a snapshot taken before the person answered the camera's own review, so the presenter
    /// waits for this to go false and snapshots then (2026-09-30 fix round, findings C-F1/C-F2).
    @State private var cameraPresentsOwnSheet = false
    /// Bumped to run a deferred session-end check (``scheduleReviewCheck()``).
    @State private var reviewCheckRequest = 0
    /// Bumped on every session-end sheet request; its task is the landing watchdog
    /// (``confirmSessionEndSheetLanded()``).
    @State private var reviewLandingRequest = 0
    /// Set by either session-end sheet's content appearing — the only proof a request landed.
    @State private var sessionEndSheetLanded = false
    /// Watchdog re-requests left for the current trigger (R2: each trigger resets it to the bound).
    @State private var reviewRetriesLeft = 0

    @Environment(\.scenePhase) private var scenePhase

    /// How long a trigger waits before presenting: past the dismissal of whatever it fired beside —
    /// the camera leaving with its sheet, a root sheet closing, the scene's own activation routing.
    private static let reviewCheckDelay: Duration = .milliseconds(700)
    /// How long a session-end sheet request has to land before the watchdog withdraws it.
    private static let reviewLandingGrace: Duration = .seconds(2)
    /// Re-requests per trigger after a request that did not land (R2).
    private static let maxReviewRetries = 4

    private var manager: MeshNetworkManager { store.meshNetworkManager }
    /// Fernlet's mesh features over ``manager``: the clothing shop and its post-session window live there,
    /// and the session photos (`features.photos`): the friend-photo wall, the review batch and its
    /// keep-as-friend candidates.
    private var features: FernletMeshFeatures { store.meshFeatures }
    /// The app-level presenter of the session-end photo review (session photos U3).
    private var reviewCoordinator: SessionPhotoReviewCoordinator { store.sessionPhotoReviewCoordinator }

    var body: some View {
        photoAlbumView
        // F4: the harness proved `.fullScreenCover` does NOT remove the presenting content from
        // the accessibility tree on its own — VoiceOver/Switch Control could still reach the
        // album underneath while the celebration overlay plays. This is the covered-content
        // half; see the overlay's own `.isModal` note below for why that trait alone wasn't enough.
        .accessibilityHidden(showConnectionAnimation)
        .fullScreenCover(isPresented: $showConnectionAnimation) {
            ConnectionSuccessOverlay(peerName: connectionPeerName) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    showConnectionAnimation = false
                }
            }
            .presentationBackground(.clear)
        }
        .onAppear {
            // Already in session when returning to the panel: no celebration, and no haptic.
            connectCue.surfaceAppeared(inSession: manager.isInSession)
            // A freshly created FriendsView instance must present a review that predates it:
            // ContentView's Social-tab layout swap destroys the previous instance in the same
            // transaction as the isInSession flip, so its onChange never fires. The review is
            // model-state (pendingFriendReview, photos included), not a view-event.
            scheduleReviewCheck()
        }
        // Every session-end trigger schedules rather than presents (see scheduleReviewCheck): the
        // batch moving, the session ending, the scene coming back (a session that ended in the dark
        // is answered on return, after ContentView's own activation routing), and whatever covered
        // the surface — the camera's own sheets, the root sheet — going away.
        .onChange(of: features.photos.pendingFriendReview) { _, _ in scheduleReviewCheck() }
        .onChange(of: manager.isSessionLive) { _, live in
            guard !live else { return }
            connectCue.sessionEnded()
            scheduleReviewCheck()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { scheduleReviewCheck() } }
        .onChange(of: cameraPresentsOwnSheet) { _, up in if !up { scheduleReviewCheck() } }
        .onChange(of: cameraPresented) { _, up in if !up { scheduleReviewCheck() } }
        .onChange(of: activeSheet == nil) { _, clear in if clear { scheduleReviewCheck() } }
        // Photos first (I17): the overlay showing withdraws a keep prompt that is up, unanswered; the
        // overlay going, or the review's discovery block falling, is when a prompt may be due.
        .onChange(of: reviewCoordinator.isShowing) { _, showing in handleOverlayChange(showing: showing) }
        .onChange(of: reviewCoordinator.blocksDiscovery) { _, blocked in if !blocked { scheduleReviewCheck() } }
        .task(id: reviewCheckRequest) { await runDeferredReviewCheck() }
        .task(id: reviewLandingRequest) { await confirmSessionEndSheetLanded() }
        .onChange(of: manager.isInSession) { wasInSession, nowInSession in
            handleSessionSurfaceChange(wasInSession: wasInSession, nowInSession: nowInSession)
        }
        .onChange(of: manager.hasCommittedPeer) { hadPeer, hasPeer in
            handleCommittedPeerChange(hadPeer: hadPeer, hasPeer: hasPeer)
        }
        .onChange(of: connectedPeerName()) { _, name in
            adoptDisclosedPeerName(name)
        }
        // Sessions with no photos but eligible new-friend candidates get the compact prompt.
        // Dismissing without choosing = skip all: onDismiss mints only the toggled keeps and
        // consumes the presented batch either way (unless a new session abandoned the prompt,
        // in which case the batch survives and re-presents merged at the next teardown).
        .sheet(isPresented: $keepFriendsPromptPresented, onDismiss: finalizeFriendKeeps) {
            keepFriendsPromptSheet
        }
        .fullScreenCover(isPresented: $selectedAlbumPostID.isPresent()) {
            FriendPhotoFeedView(
                    posts: filteredPhotoWallPosts,
                    initialPostID: selectedAlbumPostID,
                    photos: features.photos,
                    store: store,
                    onDismiss: { selectedAlbumPostID = nil }
                )
        }
    }

    /// Whether ANY of this surface's presenters is up right now — the one predicate that stands
    /// between "a cover is showing" and a second presentation request SwiftUI silently drops (P6
    /// item 2 fix review, finding P2-2).
    ///
    /// **Two now, and the photo review is not one of them.** `body` hangs a celebration
    /// `fullScreenCover` (`$showConnectionAnimation`), the keep-friends `.sheet`
    /// (`$keepFriendsPromptPresented`) and the album photo feed's `fullScreenCover`
    /// (`$selectedAlbumPostID`) off ONE anchor. The session-end PHOTO review used to be a fourth; it
    /// moved to ``SessionPhotoReviewCoordinator``'s overlay window (session photos U3), which draws
    /// above this surface without presenting from it. The heal arm once special-cased only the sheets, so a
    /// commit while a wall photo was open took the celebrate branch: two `fullScreenCover`s cannot
    /// both present from one anchor, the celebration never appeared, nothing reset
    /// `showConnectionAnimation`, and `.accessibilityHidden(showConnectionAnimation)` on the whole
    /// `ZStack` latched VoiceOver and Switch Control out of the entire Friends surface until the
    /// next peer loss or session end. The celebration's own flag is deliberately absent from the
    /// list: it is what the heal arm is deciding whether to raise, so including it would make the
    /// predicate read its own output.
    ///
    /// Read by the heal arm and by ``presentDisconnectReviewIfNeeded()``, which is the other site
    /// that requests a presentation and therefore the other site that can lose one.
    private var aPresentationIsUp: Bool {
        keepFriendsPromptPresented || selectedAlbumPostID != nil || cameraPresented
    }

    /// The **layout** half of the session transition: what surface the Social tab draws.
    ///
    /// `isInSession`, because that is the predicate `body`'s own swap reads and the predicate
    /// `ContentView.isDisposableCameraSessionActive` dresses the tab in camera chrome for. A founded
    /// mesh outlives its links by design (P6 item 2), so a blip deliberately does **not** take the
    /// camera down: the pair still holds a mesh with a ledger, a capture during the blip is sealed
    /// into custody and drained when the link heals, and the radios come back through
    /// `startFriendsDiscovery`'s resume arm. Only a session that is really over — End Session, or a
    /// launch with no mesh — swaps back to the album.
    ///
    /// The swap is also a review trigger (2026-09-30 fix round, finding L-F2): an ending that does
    /// not move the batch — one already pending from an earlier give-up, with nothing new to add —
    /// fires no other edge once the session is over, and the camera leaving takes its sheets with it.
    private func handleSessionSurfaceChange(wasInSession: Bool, nowInSession: Bool) {
        guard wasInSession, !nowInSession else { return }
        connectCue.sessionEnded()
        // The album never swapped out, so its pushed pages stay; the camera this panel presented
        // has no session left to shoot for (the camera also closes itself on this edge).
        cameraPresented = false
        showConnectionAnimation = false
        scheduleReviewCheck()
    }

    /// The **lifecycle** half: the keep-as-friend ceremony and the connection choreography.
    ///
    /// `hasCommittedPeer`, because that is the predicate the manager's three session-end hooks and
    /// `presentDisconnectReviewIfNeeded()` read (P6 item 2) — and because for a founded pair
    /// `isInSession` never dips, so hanging either half off it leaves a dead arm: the standing keep
    /// prompt would never be abandoned across a heal and `finalizeFriendKeeps` would mint friends
    /// and consume the batch mid-session on dismissal, while a healed link would replay no
    /// choreography at all. The model half and the presenting half must read the SAME predicate or
    /// the ceremony is only half re-pointed.
    ///
    /// The review sheet no longer presents on a blip at all — `presentDisconnectReviewIfNeeded()`
    /// gates on `isSessionLive`, so it presents only once the session has really ended (the fix for
    /// this commit's P1). This arm is still the right TRIGGER for it: every door that ends a
    /// session also loses the committed peer, because every terminal transition carries
    /// `.stopParticipation`.
    ///
    /// The heal arm reads ``aPresentationIsUp`` — all THREE presenters, not the two session-end
    /// sheets (fix review finding P2-2) — and both non-celebrating exits clear
    /// `showConnectionAnimation` (review finding P2-4). Both halves are load-bearing: a heal is
    /// seconds away in the same room, the photo review is the blip's common case and not the keep
    /// prompt, and nothing else ever resets `showConnectionAnimation` once the cover fails to
    /// present — the flag is lowered inside the cover's own completion — so
    /// `.accessibilityHidden(showConnectionAnimation)` would latch VoiceOver and Switch Control out
    /// of the whole Friends surface for the rest of the session.
    private func handleCommittedPeerChange(hadPeer: Bool, hasPeer: Bool) {
        if !hadPeer && hasPeer {
            // B20: the session's first commit is felt; a heal is not. Either arm below may be the
            // first: a wall photo or a session-end sheet that is up when a session's first commit
            // lands takes the presentation arm, with no overlay — the haptic still answers it.
            if let cue = connectCue.committed() { FernletFeedback.system.play(cue) }
            if aPresentationIsUp {
                // A session became live again while a session-end sheet was up: dismiss WITHOUT
                // consuming — the batch persists and re-presents (merged) at the next real teardown.
                // Clearing reviewBatch first turns the keep sheet's onDismiss finalize into a no-op,
                // and skipping the fullScreenCover avoids presenting it in the same transaction as a
                // sheet dismissal (one of the two would drop). The photo review is the overlay's,
                // which never presents over a live session.
                reviewBatch = nil
                friendCandidates = []
                keptFriendFingerprints = []
                keepFriendsPromptPresented = false
                showConnectionAnimation = false
            } else {
                connectionPeerName = connectedPeerName()
                withAnimation { showConnectionAnimation = true }
            }
        } else if hadPeer && !hasPeer {
            // A celebration cover still up over a session that just lost its peer has nothing left
            // to celebrate: take it down and hand the surface to what is behind it — for a blipped
            // pair the camera it keeps, and `handleSessionSurfaceChange` owns the ended case.
            // Leaving the flag set is the a11y latch above.
            if showConnectionAnimation {
                showConnectionAnimation = false
            }
            scheduleReviewCheck()
        }
    }

    /// The compact "keep these as friends?" prompt used when a session produced no photos.
    private var keepFriendsPromptSheet: some View {
        KeepFriendsPromptSheet(
            candidates: friendCandidates,
            keptFingerprints: $keptFriendFingerprints,
            done: { keepFriendsPromptPresented = false }
        )
        .fernletSheet()
        .onAppear { sessionEndSheetLanded = true }
    }

    // MARK: - Photo album

    /// Everything above the album: the subtitle, the two header buttons, the cards that come and go
    /// (the restore card, the shop window, photos waiting), the one slim row (looking for friends, or
    /// the session), the held-delivery banner, and the search field over a non-empty album.
    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Friends", subtitle: "Together, in person.", identifier: "screen.friends")
            FriendsHeaderButtons()
            // P7 item 5: what the launch restore found, on the Friends surface and nothing
            // modal — an offer, an ending named as ended, or a file set aside; silent for a
            // deferral. Sampled from the manager, dismissable, gone once a session surface is up.
            // P8 item 7 shares the slot and takes it first: a refused, expired or
            // system-ended background continuation is news about the session running NOW.
            sessionResumeBanner
            shopWindowCard
            // Session photos U3: photos from the last session waiting for the choice. Discovery
            // is stopped meanwhile, so the nearby row below is empty and this takes its slot.
            pendingPhotoReviewCard
            statusSlot
                .animation(.easeInOut(duration: 0.3), value: manager.isSearching)
                .animation(.easeInOut(duration: 0.3), value: manager.slots.count)
            RoutedDeliveryHoldBanner(hold: manager.routedDeliveryHold)
            if !features.photos.meshPhotos.isEmpty {
                cacheWarningBanner
                FriendsSearchField(prompt: "Search by friend or session name", text: $sessionSearchText)
            }
        }
    }

    private var photoAlbumView: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    albumHeader
                        .padding(.horizontal, 16)
                    if features.photos.meshPhotos.isEmpty {
                        emptyAlbumView
                            .padding(.horizontal, 16)
                    } else {
                        // Edge to edge, three across, 2-pt gaps (b2-friends-root draft 3).
                        photoGrid
                    }
                }
                .padding(.top, 10)
                .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $scrollToTopToken)
            .fernletPageBackground()
            .navigationTitle("")
            .navigationDestination(for: FriendsRoute.self) { friendsDestination($0) }
        }
        // Re-tapping Friends pops everything pushed here back to the album; at the album it scrolls up.
        .tabReselect(token: $tabResetToken, scrollToTopToken: $scrollToTopToken, isAtRoot: { path.isEmpty }) {
            path.removeAll()
        }
        .task(id: friendShopClosesAt) { await closeFriendShopWhenWindowLapses() }
        // DEBUG screenshots (nil in Release): open one page deep.
        .task { if let route = FriendsUITestHooks.initialRoute, path.isEmpty { path = [route] } }
        // The session camera (b3-friends-session): full screen over the panel, the album untouched
        // beneath it. It closes itself when the session ends, and this presenter lowers it too.
        .fullScreenCover(isPresented: $cameraPresented) {
            DisposableCameraView(store: store, presentsOwnSheet: $cameraPresentsOwnSheet)
        }
        // The session's prompts (join requests, the session alert, removal requests) while this
        // panel is the surface on screen; Home's session button and the camera host them otherwise.
        .modifier(SessionPromptsModifier(
            manager: manager,
            isActive: albumIsVisible && manager.isInSession && !cameraPresented && !aPresentationIsUp,
            activeRemovalProposal: $activeRemovalProposal,
            leaveSessionConfirm: .constant(false),
            onConfirmEnd: {}
        ))
        .onChange(of: manager.pendingRemovalProposals) { _, pending in
            activeRemovalProposal = SessionRemovalQueue.next(current: activeRemovalProposal, pending: pending,
                                                             localFingerprint: manager.localFingerprint)
        }
        .onAppear { albumIsVisible = true }
        .onDisappear { albumIsVisible = false }
    }

    /// When the pushed friend shop has to close: `nil` while the shop is not pushed. Keys the album's
    /// close-the-shop watch, so the watch restarts when the shop is pushed or popped and whenever the
    /// window changes (a later session reopening it, or closing it early).
    private var friendShopClosesAt: Date? {
        // The DEBUG screenshot hook opens the shop with no window; it stays open for the shot.
        guard path.contains(.friendShop), FriendsUITestHooks.initialRoute != .friendShop else { return nil }
        return FriendsRoute.shopClosesAt(
            sharingEnabled: store.settings.allowNearbyClothingShares,
            windowExpiresAt: features.clothingShop.window?.expiresAt
        )
    }

    /// Pops the friend shop when its post-session window lapses, which the shop-window card's
    /// view-destination link used to do by vanishing at the minute tick; without it the pushed shop
    /// kept its catalogs browsable, and buyable, past the hour.
    private func closeFriendShopWhenWindowLapses() async {
        guard let closesAt = friendShopClosesAt else { return }
        let wait = closesAt.timeIntervalSinceNow
        if wait > 0 {
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                // Superseded: the shop was left, or the window changed and a newer watch owns it.
                return
            }
        }
        path = FriendsRoute.closingShop(path)
    }

    /// Resolves a ``FriendsRoute`` pushed from the album to its page, each handing its title to the
    /// panel's plate (`b1-frame-push`: ‹ Friends, the title, ✕).
    @ViewBuilder private func friendsDestination(_ route: FriendsRoute) -> some View {
        switch route {
        case .activities:
            ActivitiesView(store: store)
                .fernletPushedPage("Activities")
        case .friendList:
            FriendListView(store: store, isTabBarCompact: $isTabBarCompact, tabResetToken: $scrollToTopToken)
                .fernletPushedPage("Friends & Blocks")
        case .friendShop:
            FriendShopView(store: store, shop: features.clothingShop)
                .fernletPushedPage("Friend shops")
        case .yourShop:
            YourShopView(store: store)
                .fernletPushedPage("Your shop")
        }
    }

    // MARK: - The slim row (looking for friends, or the session)

    /// The one slot under the header buttons (b2-friends-root, b3-friends-session): in a session the
    /// session row; otherwise what discovery is doing — a failure, the looking row, or the nearby
    /// rows — with "Change name" while no name is set.
    @ViewBuilder
    private var statusSlot: some View {
        if manager.isInSession {
            FriendsSessionRow(names: sessionFriendNames) { cameraPresented = true }
        } else if manager.isSearching, let discoveryError = manager.discoveryError {
            discoveryFailureBanner(discoveryError)
        } else if manager.isSearching, !manager.slots.isEmpty {
            nearbySlotRows
            displayNameHint
        } else {
            lookingRow
        }
    }

    /// The other people in this session, first names only, never an identifier (2026-09-29).
    private var sessionFriendNames: [String] {
        manager.sessionParticipants.filter { !$0.isLocal }.map {
            PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet)
        }
    }

    /// "Looking for nearby friends…" with the companion's face while discovery runs; with no search
    /// running, the name hint alone (or nothing, once a name is set).
    @ViewBuilder
    private var lookingRow: some View {
        if manager.isSearching {
            FriendsSlimRow {
                // Not `person.2` (the Friends icon): the pulse says "listening", the face says who.
                WorldSpriteView(sprite: WorldSprites.face, scale: 2)
                Text("Looking for nearby friends…")
                    .font(FernletFramedFont.notice)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                changeNameLink
            }
        } else {
            displayNameHint
        }
    }

    /// The nearby peers, one framed row each, with this row's QR ceremony.
    private var nearbySlotRows: some View {
        VStack(spacing: 8) {
            ForEach(manager.slots) { slot in
                NearbySlotRow(
                    slot: slot,
                    showDebugOverride: store.proximityDebugToolsEnabled,
                    onForceConnect: { manager.commitManualProximity(slotID: slot.id) },
                    // The QR is minted FOR THIS ROW: only a challenge arriving on this
                    // slot may answer it, so the manager binds the nonce to slot.id.
                    onMakeVerifyQR: { manager.makeLocalVerifyQRURL(slotID: slot.id) },
                    onDismissVerifyQR: { manager.clearActiveVerifyQR() },
                    // Bound to THIS row, exactly like the QR we mint above: a valid
                    // code belonging to a different nearby peer is refused, not
                    // searched for.
                    onScanVerified: { url in manager.beginQRVerification(with: url, slotID: slot.id) }
                )
            }
        }
    }

    // MARK: - Display-name hint

    /// "Change name" at the end of the looking row, while no name is set: nearby friends see this
    /// device's name ("iPhone") — the name rides the discovery broadcast — so say so where the
    /// connecting happens, and link straight to the field.
    @ViewBuilder
    private var changeNameLink: some View {
        if store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
            NavigationLink(value: FriendsRoute.friendList) {
                Text("Change name")
                    .font(FernletFramedFont.buttonSmall)
                    // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                    .foregroundStyle(WorldPalette.mossInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends.changeDisplayName")
            .accessibilityLabel("You appear as \(store.resolvedProximityDisplayName). Change the name friends see.")
            // Voice Control: the row's drawn action word, not the two-sentence label.
            .accessibilityInputLabels([Text("Change"), Text("Change name")])
        }
    }

    /// First-run nudge with no search running, or under the nearby rows: "You appear as iPhone" and
    /// Change, in a slim row.
    @ViewBuilder
    private var displayNameHint: some View {
        if store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
            NavigationLink(value: FriendsRoute.friendList) {
                FriendsSlimRow {
                    Text("You appear as \(store.resolvedProximityDisplayName)")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Text("Change")
                        .font(FernletFramedFont.buttonSmall)
                        .foregroundStyle(WorldPalette.mossInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends.changeDisplayName")
            .accessibilityLabel("You appear as \(store.resolvedProximityDisplayName). Change the name friends see.")
            // Voice Control: the row's drawn action word, not the two-sentence label.
            .accessibilityInputLabels([Text("Change"), Text("Change name")])
        }
    }

    // MARK: - Post-session shop window (Phase 3a)

    /// After a friends session ends, any shop catalogs exchanged during it stay browsable for one hour
    /// (`MeshClothingShop.windowDuration`) — this card is the window's only entry point, visible on the
    /// normal (post-session) Friends layout while the window is open and sharing isn't opted out. The
    /// minute-tick TimelineView is all the "timer" the window needs: expiry itself is lazy
    /// (`remainingWindowMinutes` returns nil once lapsed, hiding the card), and each tick refreshes the
    /// countdown. Closes early on the next session start or app quit (memory-only state).
    @ViewBuilder
    private var shopWindowCard: some View {
        if store.settings.allowNearbyClothingShares {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let minutesLeft = features.clothingShop.remainingWindowMinutes(at: context.date) {
                    NavigationLink(value: FriendsRoute.friendShop) {
                        FriendsLinkCard(title: Text("Friend shops are open"),
                                        detail: Text("Shop open — \(minutesLeft) min"),
                                        sprite: FriendsSprites.shop, spriteScale: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("friends.friendShops")
                    .accessibilityLabel("Friend shops open, \(minutesLeft) minutes left")
                    // Voice Control: the drawn title, without the countdown that changes by the minute.
                    .accessibilityInputLabels([Text("Friend shops"), Text("Friend shops are open")])
                }
            }
        }
    }

    // MARK: - Pending photo review card (session photos U3)

    /// "Photos waiting for you" while an ended session's photos wait for the choice — never over a
    /// live session, and never under a duress decoy (hide, never delete: the corpus is untouched,
    /// and a dead "Choose photos" would make the decoy distinguishable).
    @ViewBuilder
    private var pendingPhotoReviewCard: some View {
        if features.photos.hasOutstandingPhotoReview && !manager.isSessionLive && !store.duressSessionActive {
            PendingPhotoReviewCard(count: features.photos.pendingReviewPhotos.count) { reviewCoordinator.reopen() }
        }
    }

    /// The launch restore's card (network migration P7 item 5): `SessionResumeCopy.card(for:)` over
    /// `manager.sessionResumePresentation`, which is `.nothing` — no card — for a green field, a
    /// deferral or refusal the re-entry will retry, an offer already consumed, or a session surface
    /// up. Not modal, dismissable for this instance, and the same visual grammar as the discovery
    /// failure banner below.
    ///
    /// P8 item 7 shares the slot, and `MeshContinuationCardPresentation.slotDecision(continuation:resume:)`
    /// is the precedence — a value, not an `if` chain here: a LIVE spent claim (iOS refused this
    /// session background time, or ended the time it had) outranks a card about the last session,
    /// and once the claim's own session has ENDED it yields, because a session the person can pick
    /// back up is the more useful truth. The table answers nil for every claim that is idle, asked
    /// for or running, so nothing changes until item 6 feeds the claim.
    ///
    /// Both presentations are sampled exactly ONCE, above the decision, so the two arms cannot read
    /// different values of the same fact.
    @ViewBuilder
    private var sessionResumeBanner: some View {
        let continuation = MeshContinuationCardPresentation.card(
            state: store.meshContinuationState,
            lastAudit: store.meshContinuationLastAudit
        )
        // The resume OFFER is withheld while the session-photo review blocks discovery: its promise
        // ("keep this tab open … you'll reconnect") is false until the person has chosen.
        let resume: SessionResumeCard? = sessionResumeDismissed
            ? nil
            : SessionResumeCopy.card(for: reviewCoordinator.resumePresentation(manager.sessionResumePresentation))
        switch MeshContinuationCardPresentation.slotDecision(continuation: continuation, resume: resume) {
        case .continuation:
            if let continuation { continuationBanner(continuation) }
        case .resume:
            if let resume { resumeBanner(resume) }
        case .nothing:
            EmptyView()
        }
    }

    /// The launch restore's card itself, dismissable for this instance.
    ///
    /// - Parameter card: `SessionResumeCopy`'s answer for the manager's presentation.
    /// - Returns: The card.
    private func resumeBanner(_ card: SessionResumeCard) -> some View {
        FriendsNoticeCard(tone: .warn, symbolName: card.symbolName) {
            Text(card.title)
                .font(FernletFramedFont.rowTitle.weight(.semibold))
                .foregroundStyle(WorldPalette.bark)
            Text(card.message)
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Button(SessionResumeCopy.dismiss) { sessionResumeDismissed = true }
                .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                .accessibilityIdentifier("friends.sessionResume.dismiss")
        }
        .accessibilityIdentifier("friends.sessionResume")
        // Owner-calls item 3 (2026-09-22): an ending is news ONCE. Appearing marks it shown in the
        // sealed context, so the next cold start is silent about it; this launch's card stays up
        // (the manager's presentation reads the copy loaded at launch). Offers and the
        // could-not-reopen card are not marked — the manager only writes for an ending.
        .onAppear { manager.acknowledgeSessionEndingPresented() }
    }

    /// The background continuation's card (network migration P8 item 7): what a refusal, an expiry
    /// or a system end means for the session the person is in.
    ///
    /// Same grammar as the resume card above and the discovery banner below, with no dismissal —
    /// it describes the session running right now (or, for a claim whose session has since ended and
    /// has no resume card to yield to, says so in the past tense), and it goes when the claim does.
    /// Combined into one accessibility element so VoiceOver reads the card as one thing and the UI
    /// suite can match its frozen identifier; there is nothing interactive inside it to swallow.
    ///
    /// - Parameter card: The table's answer for the store's claim.
    /// - Returns: The card.
    private func continuationBanner(_ card: MeshContinuationCard) -> some View {
        FriendsNoticeCard(tone: .warn, symbolName: card.symbolName) {
            Text(card.title)
                .font(FernletFramedFont.rowTitle.weight(.semibold))
                .foregroundStyle(WorldPalette.bark)
            Text(card.message)
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(card.accessibilityIdentifier)
    }

    /// Shown in place of the "Looking for nearby friends…" row when the radios failed to start.
    ///
    /// The transport already detects this (`NetworkMeshSession`'s `onTransportError`; the retired
    /// MultipeerConnectivity session's `didNotStart*` delegates did before it) and routes it to
    /// `manager.meshError`, but the only view that rendered `meshError` was
    /// `DisposableCameraView` — which exists only *inside* a session. A discovery failure happens
    /// before any session, so the message was set and never seen: the pulse span forever and the
    /// mesh looked simply broken. On device the overwhelmingly likely cause is a declined Local
    /// Network prompt, so lead with that. The raw reason is secondary detail for developers, shown
    /// only with the proximity debug tools on.
    private func discoveryFailureBanner(_ message: String) -> some View {
        FriendsNoticeCard(tone: .warn, symbolName: "wifi.exclamationmark") {
            Text("Can't look for nearby friends")
                .font(FernletFramedFont.rowTitle.weight(.semibold))
                .foregroundStyle(WorldPalette.bark)
            Text("Fernlet needs Local Network access to find friends in person. Check Settings › Fernlet › Local Network, then come back to this screen.")
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
            // The transport's own words are developer text: frozen English that can name a
            // tunnel, an error and its identifiers (2026-09-29). Debug tools only.
            if store.proximityDebugToolsEnabled {
                Text(verbatim: message)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("friends.discoveryFailure")
        .accessibilityElement(children: .combine)
    }

    // MARK: - Cache soft-warning (spec §11: 900-photo warning ahead of the 1000 FIFO cap)

    @ViewBuilder
    private var cacheWarningBanner: some View {
        if features.photos.meshPhotos.count >= PrivateMediaStore.cacheWarningThreshold, !cacheWarningDismissed {
            FriendsNoticeCard(tone: .info, symbolName: "exclamationmark.circle") {
                Text("Your photo shelf is nearly full")
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(WorldPalette.bark)
                Text("You're keeping \(features.photos.meshPhotos.count) of \(PrivateMediaStore.maxCachedPhotos) shared photos. Once it's full, the oldest quietly make room for new ones — save any you'd like to keep.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    cacheWarningDismissed = true
                } label: {
                    FernletIcon(.close, scale: 2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .fernletIconButton("Dismiss photo shelf notice")
            }
        }
    }

    // MARK: - Photo grid

    /// Three across with 2-pt gaps, square tiles edge to edge, no frames (b2-friends-root draft 3).
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(filteredPhotoWallPosts) { post in
                // A real Button, not a tap gesture on a colour: VoiceOver could neither name nor
                // activate the old cells, so the album was unopenable without sight.
                Button {
                    selectedAlbumPostID = post.id
                } label: {
                    albumPhotoCell(post)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(albumCellLabel(post))
                .accessibilityInputLabels(albumCellInputLabels(post))
            }
        }
    }

    /// Short spoken alternatives for one album cell — the Voice Control half of T2-12.
    ///
    /// ``albumCellLabel(_:)`` is a whole SENTENCE ending in a date and a photo count, so a Voice
    /// Control user had to say "tap Photo from Alex, 12 Aug 2026, carousel, 4 photos" to open one
    /// cell. Input labels are ADDITIVE — the spoken VoiceOver label is unchanged, and it stays a
    /// sentence deliberately: a photo cell has no other text, so the sender and date are the only
    /// thing distinguishing one grey square from the next.
    ///
    /// The friend's name leads because it is the only short candidate that DIFFERS between cells,
    /// and the first input label is what Voice Control's numbered overlay shows (the same reason
    /// ``MoveView``'s calendar leads with "Day 4" rather than "Day"). It is `verbatim` — a person's
    /// name is never localized — and an empty name is dropped rather than offered as a blank
    /// command. "Photo" is kept as the generic fallback: duplicates across the grid are what the
    /// numbered overlay is for.
    private func albumCellInputLabels(_ post: FriendPhotoWallPost) -> [Text] {
        let sender = post.coverPhoto.senderName
        guard !sender.isEmpty else {
            return post.isCarousel ? [Text("Photo"), Text("Carousel")] : [Text("Photo")]
        }
        guard post.isCarousel else {
            return [Text(verbatim: sender), Text("Photo"), Text("Photo from \(sender)")]
        }
        return [Text(verbatim: sender), Text("Photo"), Text("Carousel"), Text("Photo from \(sender)")]
    }

    /// What VoiceOver says for one album cell: who shared it, when, and whether it opens a carousel.
    private func albumCellLabel(_ post: FriendPhotoWallPost) -> Text {
        let cover = post.coverPhoto
        let when = cover.addedAt.formatted(date: .abbreviated, time: .omitted)
        if post.isCarousel {
            return Text("Photo from \(cover.senderName), \(when), carousel, \(post.photos.count) photos")
        }
        return Text("Photo from \(cover.senderName), \(when)")
    }

    private var filteredPhotoWallPosts: [FriendPhotoWallPost] {
        let posts = features.photos.photoWallPosts
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return posts }
        return posts.filter { post in
            guard let session = post.session else { return false }
            return session.meshName?.lowercased().contains(query) == true
                || session.participants.contains {
                    $0.displayName.lowercased().contains(query) || $0.fingerprint.lowercased().contains(query)
                }
        }
    }

    /// One square tile: the cover photo filling it, and the pixel stack mark on a carousel.
    private func albumPhotoCell(_ post: FriendPhotoWallPost) -> some View {
        WorldPalette.paperShade
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LazyFriendPhotoImage(loadData: { features.photos.thumbnailData(for: post.coverPhoto) }, contentMode: .fill)
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if post.isCarousel {
                    WorldSpriteView(sprite: FriendsSprites.stack, scale: 2)
                        .padding(8)
                }
            }
    }

    // MARK: - Empty state

    private var emptyAlbumView: some View {
        FriendsEmptyNote(text: Text("Photos from your hangouts will appear here."),
                         systemImage: "photo.on.rectangle.angled")
            .padding(.top, 24)
    }

    // MARK: - Helper

    /// The committed peer's chosen name, or nil while it is withheld (or when nothing on hand is a
    /// name). Never the fingerprint and never the transport's instance name: the celebration shows
    /// "Connected" alone rather than an identifier (2026-09-29).
    private func connectedPeerName() -> String? {
        for slot in manager.slots where slot.fingerprint != nil {
            switch slot.coordinator.state {
            case .connected(let p), .transferring(let p, _),
                 .awaitingProximityCommit(let p), .awaitingManualCommit(let p),
                 .awaitingUserConfirmation(let p):
                return PeerNameDisplay.personName(p.displayName, fingerprint: p.fingerprint, in: .fernlet)
            default:
                break
            }
        }
        return nil
    }

    /// Hands the celebration the peer's name when it arrives after the commit it celebrates.
    ///
    /// The commit happens with the name still withheld, and the peer's first post-commit envelope
    /// (usually a heartbeat, well inside the overlay's two seconds) discloses it. Adopted once:
    /// only while the overlay is up, and only over a missing name.
    ///
    /// - Parameter name: ``connectedPeerName()``'s new answer.
    private func adoptDisclosedPeerName(_ name: String?) {
        guard showConnectionAnimation, connectionPeerName == nil, let name else { return }
        connectionPeerName = name
    }

    /// The session-end KEEP-AS-FRIENDS prompt, driven off OBSERVABLE MODEL STATE (Phase 2,
    /// "Session-end review is model-state, not view-events"): presents whenever a promoted
    /// `pendingFriendReview` batch carries candidates and NO photos, run by the deferred check every
    /// trigger schedules (``scheduleReviewCheck()``: the batch moving, the session ending, the
    /// surface swapping or appearing, scene activation, a covering presentation going away, the
    /// overlay going) and confirmed by the landing watchdog. Friend candidates come from the BATCH
    /// entries; eligibility is computed here — at presentation time, against the live trust vault —
    /// so peers trusted or blocked mid-session never reach the prompt.
    ///
    /// **Photos first** (session photos U3, invariant I17). A batch with photos is the overlay's
    /// (``SessionPhotoReviewCoordinator``), which answers its candidates inside the photo review, so
    /// this returns early while photos are outstanding, while the overlay shows, and while the
    /// review blocks discovery (an answer or a leave still running); the photo half is never decided
    /// here — `sessionEndReview` is asked with `hasPhotos: false` only.
    ///
    /// The gate is `isSessionLive` — neither `isInSession` nor `hasCommittedPeer` (P6 item 2 and
    /// its fix): a founded mesh outlives its links, so on `isInSession` this prompt would never
    /// present again for a proximity pair, and on `hasCommittedPeer` a two-second blip presented it
    /// **over a live session**, whose dismissal mints friends and consumes the batch mid-session.
    /// The model half (the manager's three hooks) and this presenting half must read the SAME
    /// predicate or the ceremony is only half re-pointed.
    ///
    /// **It never requests over a presentation, and a request is not proof** (2026-09-30 fix round,
    /// findings C-F2/L-F2). Besides this surface's own presenters it waits out the root sheet — which
    /// its request would otherwise REPLACE (a First Aid route consumed on the same activation, a
    /// meal log, Settings' Delete everything) — and the camera's sheets and alerts, which it would
    /// otherwise queue behind with a stale snapshot; each schedules a re-check when it goes. A
    /// request that still does not land — a presenter this view cannot see — is withdrawn
    /// unconsumed and re-asked by ``confirmSessionEndSheetLanded()`` rather than latching
    /// ``aPresentationIsUp`` shut.
    private func presentDisconnectReviewIfNeeded() {
        guard !manager.isSessionLive else { return }
        // ``aPresentationIsUp``, not the sheet flag alone: a `.sheet` requested while the album's
        // `fullScreenCover` is up is one of the two presentations SwiftUI drops (fix review P2-2),
        // and a prompt that silently never appears is a batch the user never gets to answer.
        guard !aPresentationIsUp else { return }
        // Nor over a presentation this surface does not own (fix round C-F2/L-F2): the camera's own
        // sheets and alerts, or the root sheet. Each re-checks here the moment it goes away.
        guard activeSheet == nil, !cameraPresentsOwnSheet else { return }
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

    /// The overlay's edges (invariant I17). Rising: a keep prompt that is up is withdrawn WITHOUT
    /// minting or consuming — the heal arm's pattern, `reviewBatch` cleared first so the sheet's
    /// `onDismiss` finalize is a no-op — because a late photo can have turned a candidates-only batch
    /// into a photo batch under it, whose candidates the overlay now offers. Falling: a prompt may be
    /// due.
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

    /// Completes the keep-as-friend flow: mints the kept candidates (one-sided, local-only) and
    /// consumes the PRESENTED batch via completeFriendReview — never clearSessionRoster(), which
    /// clobbered live-roster entries belonging to the next session. Skipped/untoggled candidates
    /// are simply dropped. A no-op when the prompt was abandoned for a new session (batch nil).
    private func finalizeFriendKeeps() {
        if let batch = reviewBatch {
            store.keepProximityFriends(from: friendCandidates, keptFingerprints: keptFriendFingerprints)
            features.photos.completeFriendReview(batch.id)
        }
        reviewBatch = nil
        friendCandidates = []
        keptFriendFingerprints = []
    }

    // MARK: - Session-end review: scheduling and the landing watchdog

    /// Asks for a session-end check a moment from now (``runDeferredReviewCheck()``), with a fresh
    /// watchdog budget.
    ///
    /// **Every trigger schedules; none presents on the spot** (2026-09-30 fix round, findings
    /// C-F2/L-F2). Most of them fire in the same transaction as another presentation — the camera
    /// leaving the hierarchy with its chat, info or Develop sheet, a root sheet closing, the scene
    /// coming back while ContentView routes a notification into the root sheet — and what SwiftUI
    /// does with a second sheet depends on who asked. Measured on the iOS 26.5 simulator: this
    /// surface's request REPLACES a standing sheet of a view above it (ContentView's root sheet
    /// vanished under the review), while a request made over a sheet of a view below it (the
    /// camera's) queues behind it and presents when that one closes — a review snapshotted before
    /// the person answered the camera's own. Neither dropped the request in the shapes tried; the
    /// reviewers' latch is covered anyway by the landing watchdog. Waiting out
    /// ``reviewCheckDelay``, and refusing while either kind of sheet is up (see the presenter), makes
    /// the review the only presentation asking.
    private func scheduleReviewCheck() {
        reviewRetriesLeft = Self.maxReviewRetries
        reviewCheckRequest &+= 1
    }

    /// The deferred half of ``scheduleReviewCheck()``: waits out ``reviewCheckDelay``, then presents
    /// if the review is still due. `.task` semantics also run it on every appearance and cancel it
    /// when a newer request or a disappearance supersedes it — a review for a surface that is not on
    /// screen waits for the surface.
    private func runDeferredReviewCheck() async {
        do {
            try await Task.sleep(for: Self.reviewCheckDelay)
        } catch {
            return   // superseded by a newer request, or the surface went away (R7: nothing owed)
        }
        presentDisconnectReviewIfNeeded()
    }

    /// Marks a session-end sheet request unlanded and arms its watchdog.
    private func noteSessionEndSheetRequested() {
        sessionEndSheetLanded = false
        reviewLandingRequest &+= 1
    }

    /// The landing watchdog. A keep prompt whose content has not appeared within
    /// ``reviewLandingGrace`` was dropped — and its flag, left true, would latch
    /// ``aPresentationIsUp`` shut until the next peer commit. So it is withdrawn WITHOUT consuming
    /// anything (the batch stays pending) and re-requested through the deferred check, at most
    /// ``maxReviewRetries`` times per trigger (R2).
    private func confirmSessionEndSheetLanded() async {
        guard keepFriendsPromptPresented else { return }
        do {
            try await Task.sleep(for: Self.reviewLandingGrace)
        } catch {
            return   // a newer request re-armed the watchdog, or the surface went away (R7)
        }
        guard keepFriendsPromptPresented, !sessionEndSheetLanded else { return }
        withdrawUnlandedSessionEndSheet()
        guard reviewRetriesLeft > 0 else { return }
        reviewRetriesLeft -= 1
        reviewCheckRequest &+= 1
    }

    /// Lowers an unlanded keep prompt's flag without answering anything. `reviewBatch` goes first
    /// so the keep prompt's `onDismiss` finalize is a no-op — the heal arm's rule.
    private func withdrawUnlandedSessionEndSheet() {
        reviewBatch = nil
        friendCandidates = []
        keptFriendFingerprints = []
        keepFriendsPromptPresented = false
    }

}

// MARK: - Full-screen photo feed

/// The full-screen, vertically scrolling feed of photo-wall posts, opened from the album grid
/// (`b2-album-post`): under the Friends panel's wooden plate, which names the hangout on screen, each
/// post is its photos at 4:5 with the counter and pixel dots, then a paper card with the friend's name,
/// the date and the four framed actions. Scrolling down moves to the next hangout.
///
/// Scrolls to `initialPostID` on appear and renders each post as a
/// ``FriendPhotoCarouselPostView``. Dismisses itself when the last photo is deleted (or reported)
/// so the viewer never sits on a blank screen.
///
/// Hosts the people-report flow for every post's flag (App Review guideline 1.2, 2026-10-15) — here
/// rather than on a post, so a post emptied by its report does not take the "Reported" note with it.
private struct FriendPhotoFeedView: View {
    let posts: [FriendPhotoWallPost]
    let initialPostID: UUID?
    /// The session photos whose wall the feed shows (the composition's `photos`).
    let photos: MeshSessionPhotos
    /// The store a photo's Report… files through (App Review guideline 1.2).
    let store: FernletStore
    let onDismiss: () -> Void

    /// The photo sender the report flow is open for, if any.
    @State private var reportSubject: PeerReportSubject?
    /// The post at the top of the feed now: the plate names its hangout.
    @State private var visiblePostID: UUID?

    var body: some View {
        WorldPanelFrame(panel: .friends, title: plateTitle, onClose: onDismiss) {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(posts) { post in
                            FriendPhotoCarouselPostView(
                                post: post,
                                photos: photos,
                                width: geometry.size.width,
                                reportSubject: { PeerReportSubject.photo($0, senderKey: store.reportableSenderKey(of: $0)) },
                                requestReport: { reportSubject = $0 }
                            )
                            .id(post.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollPosition(id: $visiblePostID, anchor: .top)
                .onAppear { visiblePostID = initialPostID ?? posts.first?.id }
            }
        }
        .peerReportFlow($reportSubject) { subject, reason in store.reportWallPhoto(subject, reason: reason) }
        .onChange(of: posts.isEmpty) { _, isEmpty in
            // Deleting the last remaining photo empties the feed; dismiss instead of leaving the
            // viewer on a blank screen.
            if isEmpty { onDismiss() }
        }
    }

    /// The plate's title: the visible hangout's session name, else the friend's name, else Friends.
    private var plateTitle: String? {
        let post = posts.first { $0.id == visiblePostID } ?? posts.first
        guard let post else { return nil }
        if let name = post.session?.meshName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let sender = post.coverPhoto.senderName
        return sender.isEmpty ? nil : sender
    }
}

/// One post in the full-screen feed: a paged carousel of a session's photos with save, favorite,
/// delete and — on another person's photo — report actions, in a paper card under the photo.
///
/// The flag (App Review guideline 1.2, 2026-10-15) asks the feed to open the app's people-report
/// flow for the photo's sender; filing it blocks them on this phone and deletes the photo from the
/// wall (`FernletStore.reportWallPhoto(_:reason:)`). This device's own photos carry no flag.
///
/// Tracks its own selected page and auto-fading chrome (page counter + dots), and re-anchors the
/// selection when a deletion removes the current page — the post id is stable for aggregated
/// sessions, so the view is reused without re-init. Saving rehydrates the metadata-only payload
/// from the encrypted disk cache (`MeshSessionPhotos.hydratedPhotos`) before handing bytes to
/// `FriendPhotoLibrarySaver`, and never reports a false success when decryption fails.
private struct FriendPhotoCarouselPostView: View {
    let post: FriendPhotoWallPost
    /// The session photos whose wall holds this post (the composition's `photos`).
    let photos: MeshSessionPhotos
    let width: CGFloat
    /// A photo's sender as a report subject; nil for this device's own photo (no flag).
    let reportSubject: (FriendPhotoPayload) -> PeerReportSubject?
    /// Opens the feed's report flow for a subject.
    let requestReport: (PeerReportSubject) -> Void

    @State private var selectedPhotoID: UUID
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var pendingDeletePhotoID: UUID?
    @State private var saveErrorMessage: PhotoSaveFailure?
    @State private var savedPhotoIDs: Set<UUID> = []
    /// Photos with a save Task already running — the per-photo in-flight cap (R3).
    @State private var inFlightSaveIDs: Set<UUID> = []

    init(
        post: FriendPhotoWallPost, photos: MeshSessionPhotos, width: CGFloat,
        reportSubject: @escaping (FriendPhotoPayload) -> PeerReportSubject?,
        requestReport: @escaping (PeerReportSubject) -> Void
    ) {
        self.post = post
        self.photos = photos
        self.width = width
        self.reportSubject = reportSubject
        self.requestReport = requestReport
        self._selectedPhotoID = State(initialValue: post.photos.first?.id ?? post.coverPhoto.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedPhotoID) {
                ForEach(post.photos) { photo in
                    carouselPhoto(photo)
                        .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: width * 1.25)
            .overlay(alignment: .topTrailing) { pageCounterOverlay }
            .overlay(alignment: .bottom) { pageDotsOverlay }

            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .onAppear { scheduleChromeFade() }
        .onChange(of: selectedPhotoID) { _, _ in scheduleChromeFade() }
        .onChange(of: post.photos) { _, newPhotos in
            // A deleted photo can leave selectedPhotoID pointing at a now-missing page (the post id
            // is stable for aggregated sessions, so this view is reused without re-init). Re-anchor
            // to a surviving photo so the TabView page and indicators stay consistent.
            if !newPhotos.contains(where: { $0.id == selectedPhotoID }) {
                selectedPhotoID = newPhotos.first?.id ?? post.coverPhoto.id
            }
        }
        .onDisappear { chromeTask?.cancel() }
        // An `alert`, not a `confirmationDialog`: on iOS 26 the dialog renders as a popover that
        // suppresses the `.cancel`-role button, so the user saw a lone red "Delete" and no way out —
        // and the popover anchored to the view root rather than the picture being deleted.
        .alert(
            "Delete this picture?",
            isPresented: $pendingDeletePhotoID.isPresent()
        ) {
            deleteConfirmationButtons
        } message: {
            Text("This removes it from this device. It can't be undone.")
        }
        .photoSaveFailureAlert("Couldn't Save Photo", failure: $saveErrorMessage)
    }

    /// The "n / total" pill, shown with the auto-fading chrome on multi-photo posts.
    @ViewBuilder
    private var pageCounterOverlay: some View {
        if chromeVisible, post.photos.count > 1 {
            Text("\(selectedIndex + 1) / \(post.photos.count)")
                .font(FernletFramedFont.buttonSmall)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(14)
                .transition(.opacity)
        }
    }

    /// The page marks: one small framed square per photo, the current one filled white (the pixel
    /// dots of `b2-album-post`), shown with the auto-fading chrome on multi-photo posts.
    @ViewBuilder
    private var pageDotsOverlay: some View {
        if chromeVisible, post.photos.count > 1 {
            HStack(spacing: 4) {
                ForEach(post.photos) { photo in
                    Rectangle()
                        .fill(photo.id == selectedPhotoID ? Color.white : Color.white.opacity(0.45))
                        .frame(width: 10, height: 10)
                        .overlay(Rectangle().strokeBorder(WorldPalette.ink, lineWidth: 1.5))
                }
            }
            .padding(.bottom, 14)
            .transition(.opacity)
        }
    }

    /// Actions of the per-photo delete confirmation dialog.
    @ViewBuilder
    private var deleteConfirmationButtons: some View {
        Button("Delete", role: .destructive) {
            if let id = pendingDeletePhotoID { photos.deletePhoto(id) }
            pendingDeletePhotoID = nil
        }
        Button("Cancel", role: .cancel) { pendingDeletePhotoID = nil }
    }

    /// The paper card under the photo: the friend's name and the date, then Save, Favorite, Delete and
    /// Report as framed pixel-icon buttons for the photo on screen (`b2-album-post`).
    private var header: some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                nameAndDate
                Spacer(minLength: 6)
                photoActions(selectedPhoto)
            }
            VStack(alignment: .leading, spacing: 10) {
                nameAndDate
                photoActions(selectedPhoto)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 12))
        .background(WorldPalette.paper, in: shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(WorldPalette.ink.opacity(0.22)).offset(y: 3) }
    }

    /// The sender's name over the date the photo was added.
    private var nameAndDate: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: selectedPhoto.senderName)
                .font(FernletFramedFont.cardTitle)
                .foregroundStyle(WorldPalette.bark)
            Text(selectedPhoto.addedAt, style: .date)
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func carouselPhoto(_ photo: FriendPhotoPayload) -> some View {
        Color.clear
            .overlay {
                LazyFriendPhotoImage(
                    loadData: { photos.imageData(for: photo) },
                    contentMode: .fit,
                    shouldLoad: shouldLoad(photo)
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: width * 1.25)
    }

    /// Save, Favorite (a session's post only), Delete and Report (another person's photo only).
    private func photoActions(_ photo: FriendPhotoPayload) -> some View {
        HStack(spacing: 8) {
            let isSaved = savedPhotoIDs.contains(photo.id)
            // The glyph turns into a tick when it's done — the label has to say the same thing, or
            // VoiceOver keeps offering a save that already happened.
            framedActionButton(sprite: isSaved ? WorldSprites.check : FriendsSprites.download,
                               accessibilityLabel: isSaved ? "Saved to Photos" : "Save this picture to your Photos library") {
                savePhoto(photo)
            }
            if post.session != nil {
                let isFavorite = photos.favoritePhotoID(for: post) == photo.id
                framedActionButton(sprite: isFavorite ? WorldSprites.heartSm : FriendsSprites.heartOutline,
                                   accessibilityLabel: "Favorite this photo", selected: isFavorite) {
                    photos.toggleFavorite(photoID: photo.id, in: post)
                    // The heart filling (or emptying) is the visual; the button only shows
                    // on a session's post, where a toggle always changes the favorite.
                    FernletFeedback.system.play(.tick)
                }
            }
            framedActionButton(sprite: FriendsSprites.trash, accessibilityLabel: "Delete this picture") {
                pendingDeletePhotoID = photo.id
            }
            if let subject = reportSubject(photo) {
                framedActionButton(sprite: FriendsSprites.flag, accessibilityLabel: "Report this picture") {
                    requestReport(subject)
                }
            }
        }
    }

    /// One framed 44-pt pixel-icon button on raised paper.
    ///
    /// - Parameter accessibilityLabel: `LocalizedStringKey`, not `String` — the argument's STATIC
    ///   TYPE is what picks SwiftUI's localizing `accessibilityLabel(_:)` overload, and a `String`
    ///   parameter silently opted all three call sites out (review T2-1).
    private func framedActionButton(
        sprite: WorldSprite,
        accessibilityLabel: LocalizedStringKey,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Button(action: action) {
            WorldSpriteView(sprite: sprite, scale: 2)
                .frame(width: 44, height: 44)
                .background(WorldPalette.paperLight, in: shape)
                .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        // A filled heart is the ONLY thing that said "favorited"; the trait says it out loud.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func savePhoto(_ photo: FriendPhotoPayload) {
        // R3 (bounded task fan-out): at most one in-flight save per photo. Without this, a double
        // tap writes the same image to the Photos library twice — the second Task starts long
        // before the first has updated `savedPhotoIDs`.
        guard !savedPhotoIDs.contains(photo.id), !inFlightSaveIDs.contains(photo.id) else { return }
        inFlightSaveIDs.insert(photo.id)
        Task {
            defer { inFlightSaveIDs.remove(photo.id) }
            // Persistent-gallery photos are stored metadata-only in memory; rehydrate the bytes
            // from the encrypted disk cache before handing them to the photo library.
            let hydrated = photos.hydratedPhotos([photo])
            // If the bytes can't be loaded/decrypted, don't report a false success.
            guard !hydrated.isEmpty else {
                saveErrorMessage = .generic
                return
            }
            do {
                try await FriendPhotoLibrarySaver.save(hydrated)
                savedPhotoIDs.insert(photo.id)
                // A failure's cue is the shared failure alert's (`photoSaveFailureAlert`).
                FernletFeedback.system.play(.done)
            } catch {
                saveErrorMessage = FriendPhotoLibrarySaver.userFacingFailure(for: error, photoCount: 1)
            }
        }
    }

    private var selectedIndex: Int {
        post.photos.firstIndex(where: { $0.id == selectedPhotoID }) ?? 0
    }

    private func shouldLoad(_ photo: FriendPhotoPayload) -> Bool {
        guard let index = post.photos.firstIndex(where: { $0.id == photo.id }) else { return false }
        return abs(index - selectedIndex) <= 1
    }

    private var selectedPhoto: FriendPhotoPayload {
        post.photos[selectedIndex]
    }

    private func scheduleChromeFade() {
        chromeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible = true
        }
        // `assistive: nil` — this fade REMOVES CONTROLS from the accessibility tree rather than
        // retiring a notice: the close, save and share buttons go with the chrome. A stretched
        // timer would only delay deleting the screen's only controls out from under a VoiceOver
        // user mid-swipe, so while an assistive technology is running the chrome simply stays.
        guard let window = FernletDismissalWindow.system
            .windowUnlessAssistive(standard: .seconds(5)) else { return }
        chromeTask = Task {
            // The sleep result IS the cancellation check: `Task.sleep` throws exactly when the task
            // is cancelled, so a cancelled fade simply returns (R7 — no swallowed error).
            do {
                try await Task.sleep(for: window)
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                chromeVisible = false
            }
        }
    }
}

/// Loads a photo's bytes lazily through a closure and shows a placeholder glyph until decoded.
///
/// `shouldLoad` lets the carousel defer decoding to the current page ± 1 so a long post never
/// decodes every image at once; the load task re-fires when the flag flips to true.
private struct LazyFriendPhotoImage: View {
    let loadData: () -> Data?
    let contentMode: ContentMode
    var shouldLoad = true

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // T2-10: a friend photo inverted is a colour negative of a person's face. The
                    // `photo` placeholder below is a tinted glyph and is left to invert normally.
                    .accessibilityIgnoresInvertColors()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .task(id: shouldLoad) {
            guard shouldLoad, image == nil, let data = loadData() else { return }
            image = UIImage(data: data)
        }
    }
}

// MARK: - Nearby slot row

/// One row of the "nearby friends" banner: a discovered peer slot with its handshake state and
/// commit affordances.
///
/// Renders `PeerSlot.coordinator.state` as icon + label, shows the live UWB distance while
/// `awaitingProximityCommit`, and in `awaitingManualCommit` offers the plain Connect button plus
/// the QR verification ceremony (show my code / scan theirs), whose closures reach
/// `MeshNetworkManager` through the parent ``FriendsView``. The failed-scan alert is raised from
/// the scan sheet's `onDismiss` — presenting it from the scanner callback landed in the same
/// update that tore the sheet down, and SwiftUI silently dropped it.
private struct NearbySlotRow: View {
    let slot: PeerSlot
    let showDebugOverride: Bool
    let onForceConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            WorldSpriteView(sprite: stateSprite, scale: 2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: peerName)
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(WorldPalette.bark)
                Text(stateLabel)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
            }
            Spacer()

            trailingControl
        }
        .padding(12)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
        .onChange(of: approachMeters) { _, meters in
            if let cue = approachCue.observe(meters) { FernletFeedback.system.play(cue) }
        }
    }

    /// B19: one `tick` as the phones come inside the commit distance, re-armed only past 30 cm
    /// (``ProximityApproachCue``). The "Hold still…" line in ``stateLabel`` is its visual twin.
    @State private var approachCue = ProximityApproachCue()

    /// The distance the approach cue reads: the live reading while this row waits for the phones
    /// to come together, and nothing in any other state, so a connected pair that touches again
    /// never ticks.
    private var approachMeters: Double? {
        guard case .awaitingProximityCommit = slot.coordinator.state else { return nil }
        return distanceMeters
    }

    // QR verification ceremony (bitchat adoptions Increment 4): row-local sheet state; the
    // closures reach MeshNetworkManager through the parent. Defaults keep other construction
    // sites source-compatible.
    var onMakeVerifyQR: () -> URL? = { nil }
    /// Fires whenever the display sheet goes away (Done, swipe-down, or the sheet dismissing
    /// itself on backgrounding) so the manager stops honoring challenges for the shown QR.
    var onDismissVerifyQR: () -> Void = {}
    var onScanVerified: (URL) -> Bool = { _ in false }
    @State private var verifyQRURL: URL?
    @State private var showVerifyScanner = false
    @State private var verifyMissed = false
    /// Set by the scanner callback, converted into `verifyMissed` only in the scan sheet's
    /// `onDismiss`. Raising the alert from the callback flipped `isPresented` in the same update
    /// that tore the sheet down, and SwiftUI drops an alert presented on a view whose sheet is
    /// mid-dismiss — so a failed scan closed the scanner and said nothing at all.
    @State private var pendingScanFailed = false
    /// Set by the scanner callback when the code matched this row, so the "friend's here" cue plays
    /// as the scanner goes away — a beat after the scanner's own "got it", never stacked on it (A10).
    @State private var pendingScanMatched = false

    /// The scanner has gone away. Raise the alert only now, and give each result its own cue here
    /// (A10): the error beside "That code didn't match", or the friend cue for a code that matched.
    /// A Cancel sets neither, so it stays silent.
    private func verifyScannerDismissed() {
        if pendingScanFailed {
            pendingScanFailed = false
            verifyMissed = true
            FernletFeedback.system.play(.failed)
        } else if pendingScanMatched {
            pendingScanMatched = false
            FernletFeedback.system.play(.friendHere)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch slot.coordinator.state {
        case .awaitingProximityCommit:
            if showDebugOverride {
                Button("Force", action: onForceConnect)
                    .buttonStyle(ChipButtonStyle(selected: true))
                    .font(.fernlet(.label))
                    .accessibilityIdentifier("friends.forceConnect.\(slot.id)")
            } else if let d = distanceMeters {
                Text("\(Self.wholeCentimeters(d)) cm")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
        case .awaitingManualCommit:
            // Both of these ACT (they commit a connection), so they take the 44pt action pill rather
            // than the 34pt selection chip — and the bare "Verify" text label now matches Connect.
            AdaptiveStack(spacing: 8) {
                // Ceremony-grade alternative to the bare tap (Increment 4): scan proves the
                // person holds the key; a successful round commits BOTH sides.
                Menu {
                    Button {
                        verifyQRURL = onMakeVerifyQR()
                    } label: {
                        Label("Show my code", systemImage: "qrcode")
                    }
                    Button {
                        showVerifyScanner = true
                    } label: {
                        Label("Scan their code", systemImage: "qrcode.viewfinder")
                    }
                } label: {
                    Text("Verify")
                }
                .menuStyle(.button)
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("friends.verifyQR.menu.\(slot.id)")
                Button("Connect", action: onForceConnect)
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityIdentifier("friends.manualCommit.\(slot.id)")
            }
            .sheet(isPresented: $verifyQRURL.isPresent(), onDismiss: onDismissVerifyQR) {
                VerifyQRDisplaySheet(url: verifyQRURL)
            }
            .sheet(isPresented: $showVerifyScanner, onDismiss: verifyScannerDismissed) {
                VerifyQRScanSheet { url in
                    let matched = onScanVerified(url)
                    pendingScanFailed = !matched
                    pendingScanMatched = matched
                }
            }
            .alert("That code didn't match", isPresented: $verifyMissed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Ask your friend to show their code again — codes expire after a few minutes — and make sure you're scanning the person shown in this row.")
            }
        default:
            EmptyView()
        }
    }

    /// The row's title: the peer's chosen name once this device has it, else "Someone nearby".
    ///
    /// Never an identifier (owner decision 2026-09-29, reversing the fingerprint title of
    /// stranger-admission Option 1b). Until this device commits, the peer has disclosed no name,
    /// and the only other strings on hand are its fingerprint and, before the identity
    /// introduction, the QUIC transport's random Bonjour instance name (`slot.peer.displayHint`,
    /// `fernlet-mesh-…`). Both were debugging aids. The name replaces the placeholder once the
    /// peer's first post-commit envelope discloses it; the row-bound QR ceremony is how two people
    /// tell rows apart before that.
    private var peerName: String {
        switch slot.coordinator.state {
        case .awaitingProximityCommit(let p), .awaitingManualCommit(let p),
             .awaitingUserConfirmation(let p), .connected(let p), .transferring(let p, _):
            return PeerNameDisplay.shown(p.displayName, fingerprint: p.fingerprint, in: .fernlet)
        default:
            return PeerNameDisplay.text(for: .nearby)
        }
    }

    private var stateLabel: String {
        switch slot.coordinator.state {
        case .awaitingIdentityIntroduction:
            return String(localized: "friends.nearby.exchangingIdentity", defaultValue: "Exchanging identity…",
                          comment: "A nearby-friend row's status while the two phones confirm who each other is")
        case .awaitingProximityCommit:
            if let d = distanceMeters, ProximityApproachCue.isWithinCommitDistance(d) {
                return String(localized: "friends.nearby.holdStill",
                              defaultValue: "Close enough — hold still…",
                              comment: "A nearby-friend row's status once the two phones are within the 15 cm connect distance, while the connection settles (under a second). Pairs with a light haptic tick.")
            }
            if let d = distanceMeters {
                let centimeters = Self.wholeCentimeters(d)
                return String(localized: "friends.nearby.moveCloser", defaultValue: "Move closer — \(centimeters) cm away",
                              comment: "A nearby-friend row's status while the phones are too far apart to connect. %lld is the distance in centimetres.")
            }
            return String(localized: "friends.nearby.tapPhones", defaultValue: "Tap phones together to connect",
                          comment: "A nearby-friend row's status before the phones are close: bring them together to connect")
        case .awaitingManualCommit:
            return String(localized: "friends.nearby.tapToConfirm", defaultValue: "Tap to confirm connection",
                          comment: "A nearby-friend row's status when a tap on this phone completes the connection")
        case .connected, .transferring:
            return String(localized: "friends.nearby.connected", defaultValue: "Connected",
                          comment: "A nearby-friend row's status once the two phones are connected")
        default:
            return String(localized: "friends.nearby.connecting", defaultValue: "Connecting…",
                          comment: "A nearby-friend row's status while the connection is being set up")
        }
    }

    /// A ranging distance in whole centimetres, rounded exactly as `String(format: "%.0f")` rounds
    /// (to nearest, ties to even), so the drawn number is the one the row always showed.
    static func wholeCentimeters(_ meters: Double) -> Int {
        Int((meters * 100).rounded(.toNearestOrEven))
    }

    /// The row's pixel mark: a tick once connected, the two-people mark while the phones meet.
    private var stateSprite: WorldSprite {
        switch slot.coordinator.state {
        case .connected, .transferring: return WorldSprites.check
        default: return FriendsSprites.people
        }
    }

    private var distanceMeters: Double? {
        if case .meters(let d, _) = slot.coordinator.lastKnownDistance { return d }
        return nil
    }
}

// MARK: - Connection success overlay

/// The full-screen "Connected" celebration shown the moment a session commits.
///
/// Runs a fixed spring-and-fade choreography (card rise, expanding rings, auto-exit) and calls
/// `onComplete` when finished so ``FriendsView`` can flip into the in-session camera.
struct ConnectionSuccessOverlay: View {
    /// The peer's chosen name, or nil while it is withheld: then "Connected" is the headline on its
    /// own. Never an identifier in a name's place (2026-09-29: the fingerprint in display type was
    /// the "large string of characters" at the moment of connecting).
    let peerName: String?
    let onComplete: () -> Void

    @State private var cardOffset: CGFloat = 100
    @State private var cardOpacity: Double = 0
    @State private var ringsScale: CGFloat = 0.3
    @State private var ringsOpacity: Double = 1
    /// The choreography task, held so `onDisappear` can cancel it (and so a cancelled overlay never
    /// calls `onComplete`).
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.moss.opacity(0.35 - Double(i) * 0.10), lineWidth: 1.5)
                        .frame(
                            width: 100 + CGFloat(i) * 70,
                            height: 100 + CGFloat(i) * 70
                        )
                }
            }
            .scaleEffect(ringsScale)
            .opacity(ringsOpacity)

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.moss.opacity(0.15))
                        .frame(width: 84, height: 84)
                    Image(systemName: "person.fill.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.moss)
                }

                headline
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 32, x: 0, y: 10)
            .offset(y: cardOffset)
            .opacity(cardOpacity)
        }
        // T1-4: a blocking celebration overlay — nothing behind it should be reachable while it
        // runs its fixed choreography. F4 correction: the harness proved `.isModal` alone is a
        // no-op here — this view has no covered SIBLING for the trait to scope against, it is
        // presented through `.fullScreenCover`, so the real fix is `FriendsView`'s
        // `.accessibilityHidden(showConnectionAnimation)` on the covered content. Left in place
        // (harmless, and correct if this view is ever composed into a sibling-bearing container
        // instead) rather than removed.
        .accessibilityAddTraits(.isModal)
        .onAppear { runAnimation() }
        .onDisappear { animationTask?.cancel() }
    }

    /// The name over a small "Connected" caption, or "Connected" as the headline while there is no
    /// name. The existing "Connected" key serves both, so the nameless state adds no string.
    @ViewBuilder
    private var headline: some View {
        if let peerName {
            VStack(spacing: 6) {
                Text(verbatim: peerName)
                    .font(.fernlet(.display))
                    .foregroundStyle(Color.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Connected")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
                    .textCase(.uppercase)
                    .tracking(1.4)
            }
        } else {
            Text("Connected")
                .font(.fernlet(.display))
                .foregroundStyle(Color.bark)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func runAnimation() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.76)) {
            cardOffset = 0
            cardOpacity = 1
            ringsScale = 1.7
        }
        animationTask?.cancel()
        animationTask = Task {
            // Every step's sleep result feeds the decision to continue (R7): `Task.sleep` throws
            // exactly on cancellation, and an overlay that went away has nothing to complete — so a
            // cancelled choreography returns WITHOUT calling `onComplete`, which would otherwise
            // change the parent's state behind a dismissed view.
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.55)) {
                ringsOpacity = 0
            }
            do {
                try await Task.sleep(for: .milliseconds(1400))
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.4)) {
                cardOffset = -70
                cardOpacity = 0
            }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            onComplete()
        }
    }
}
