import ProximityKit
import SwiftUI
import UIKit
import FernletDomainModel
import PrivateMediaStore
import FernletUI

// MARK: - FriendsView

/// The Friends tab root: the shared photo album when idle, the in-session disposable camera when live.
///
/// Swaps to ``DisposableCameraView`` once `MeshNetworkManager.isInSession` flips and the
/// ``ConnectionSuccessOverlay`` completes; otherwise it renders the album layout — the
/// post-session shop-window card, the nearby-peer banner (with the QR verify ceremony on manual
/// commits), and the searchable photo wall. It also owns the session-end review flow:
/// `presentDisconnectReviewIfNeeded()` presents either the full photo review or the compact
/// keep-as-friends prompt off observable model state (`pendingFriendReview` + post-teardown
/// `sessionPhotos`), so a review promoted while no instance existed still presents on the next
/// appearance. Kept friends are minted one-sided via ``FernletStore``'s `keepProximityFriends`,
/// and the presented batch is consumed with `completeFriendReview` — never by clearing the live
/// roster, which would clobber the next session's entries.
struct FriendsView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    @State private var showConnectionAnimation = false
    @State private var connectionPeerName = ""
    @State private var sessionReady = false
    @State private var disconnectReviewPresented = false
    @State private var selectedForSave: Set<UUID> = []
    // Phase 2 friend minting: the promoted batch this instance is presenting (consumed via
    // completeFriendReview on finalize), candidates snapshotted at presentation time, and keeps.
    @State private var reviewBatch: MeshFriendReviewBatch?
    @State private var friendCandidates: [MeshSessionRosterEntry] = []
    @State private var keptFriendFingerprints: Set<String> = []
    @State private var keepFriendsPromptPresented = false
    @State private var photoSaveError: PhotoSaveFailure? = nil
    @State private var selectedAlbumPostID: UUID?
    @State private var sessionSearchText = ""
    @State private var cacheWarningDismissed = false

    private var manager: MeshNetworkManager { store.meshNetworkManager }

    var body: some View {
        ZStack {
            if manager.isInSession && sessionReady {
                DisposableCameraView(store: store)
                    .transition(.opacity)
                    .zIndex(1)
            } else {
                photoAlbumView
                    .zIndex(0)
            }

        }
        .animation(.easeInOut(duration: 0.3), value: sessionReady)
        .fullScreenCover(isPresented: $showConnectionAnimation) {
            ConnectionSuccessOverlay(peerName: connectionPeerName) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    showConnectionAnimation = false
                    sessionReady = true
                }
            }
            .presentationBackground(.clear)
        }
        .onAppear {
            // Already in session when returning to the tab — skip animation.
            if manager.isInSession { sessionReady = true }
            // A freshly created FriendsView instance must present a review that predates it:
            // ContentView's Social-tab layout swap destroys the previous instance in the same
            // transaction as the isInSession flip, so its onChange never fires. The review is
            // model-state (pendingFriendReview / post-teardown sessionPhotos), not a view-event.
            presentDisconnectReviewIfNeeded()
        }
        .onChange(of: manager.pendingFriendReview) { _, _ in
            presentDisconnectReviewIfNeeded()
        }
        .onChange(of: manager.isInSession) { wasInSession, nowInSession in
            handleSessionChange(wasInSession: wasInSession, nowInSession: nowInSession)
        }
        .sheet(isPresented: $disconnectReviewPresented) {
            disconnectReviewSheet
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
                    manager: manager,
                    onDismiss: { selectedAlbumPostID = nil }
                )
        }
    }

    /// The `isInSession` transition handler: a session becoming live either abandons a standing keep
    /// prompt (without consuming its batch) or plays the connection choreography; a session ending
    /// tears the live surface down and presents the review.
    private func handleSessionChange(wasInSession: Bool, nowInSession: Bool) {
        if !wasInSession && nowInSession {
            if keepFriendsPromptPresented {
                // A new session became ready while the compact keep prompt was up: dismiss
                // WITHOUT consuming — the batch persists and re-presents (merged) at the
                // next teardown. Clearing reviewBatch first turns the sheet's onDismiss
                // finalize into a no-op, and skipping the fullScreenCover avoids presenting
                // it in the same transaction as a sheet dismissal (one of the two would drop).
                reviewBatch = nil
                friendCandidates = []
                keptFriendFingerprints = []
                keepFriendsPromptPresented = false
                sessionReady = true
            } else {
                connectionPeerName = connectedPeerName()
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                withAnimation { showConnectionAnimation = true }
            }
        } else if wasInSession && !nowInSession {
            sessionReady = false
            showConnectionAnimation = false
            presentDisconnectReviewIfNeeded()
        }
    }

    /// The end-of-session photo review sheet (keep/discard the session's photos, and the friend
    /// candidates alongside them), using the split (FRND-12) action bar: keeping to the in-app
    /// wall is the primary action and the Photos-library export is a separate, optional button —
    /// so a Photos permission denial can never cost the user the keep.
    private var disconnectReviewSheet: some View {
        FriendPhotoReviewSheet(
            photos: manager.sessionPhotos,
            selectedIDs: $selectedForSave,
            friendCandidates: friendCandidates,
            keptFriendFingerprints: $keptFriendFingerprints,
            saveSelected: { await keepSelectedSessionPhotos() },
            saveToPhotos: { await exportSelectedPhotosToLibrary() },
            discardAll: { discardAllSessionPhotos() },
            loadImageData: { manager.imageData(for: $0) }
        )
        .interactiveDismissDisabled()
        .photoSaveFailureAlert("Couldn't Save Photos", failure: $photoSaveError)
    }

    /// FRND-12: the primary review action of the disconnect flow. Keeps the ticked photos on the
    /// in-app wall, mints the kept friends, and leaves the session — deliberately with NO
    /// Photos-library involvement, so a system-permission denial can never cost the user their
    /// pictures. The optional export is `exportSelectedPhotosToLibrary`.
    private func keepSelectedSessionPhotos() async {
        manager.finishSessionPhotos(keeping: selectedForSave)
        finalizeFriendKeeps()
        await manager.leaveSessionAfterNotifyingPeers()
        disconnectReviewPresented = false
    }

    /// The optional "Also save to Photos" export. Session payloads are held metadata-only to bound
    /// memory, so the ticked ones are rehydrated from the disk cache first — handing them to the
    /// saver directly would skip every payload (`imageData` is nil) and throw `NothingSavedError`.
    /// Purely additive: a failure (including a Photos permission denial) surfaces on the
    /// still-present sheet and never touches the keep flow.
    private func exportSelectedPhotosToLibrary() async {
        let toSave = manager.hydratedPhotos(manager.sessionPhotos.filter { selectedForSave.contains($0.id) })
        // If no bytes could be loaded/decrypted, don't report a false success.
        guard !toSave.isEmpty else {
            photoSaveError = .generic
            return
        }
        do {
            try await FriendPhotoLibrarySaver.save(toSave)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            photoSaveError = FriendPhotoLibrarySaver.userFacingFailure(for: error, photoCount: toSave.count)
        }
    }

    /// Discards every session photo, finalizes keeps, and leaves the session.
    private func discardAllSessionPhotos() {
        manager.deleteAllSessionPhotos()
        finalizeFriendKeeps()
        Task { @MainActor in
            await manager.leaveSessionAfterNotifyingPeers()
            disconnectReviewPresented = false
        }
    }

    /// The compact "keep these as friends?" prompt used when a session produced no photos.
    private var keepFriendsPromptSheet: some View {
        KeepFriendsPromptSheet(
            candidates: friendCandidates,
            keptFingerprints: $keptFriendFingerprints,
            done: { keepFriendsPromptPresented = false }
        )
        .presentationDetents([.medium, .large])
    }

    // MARK: - Photo album

    private var photoAlbumView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Friends", subtitle: "Together, in person.", identifier: "screen.friends")
                        Spacer()
                        HStack(spacing: 10) {
                            NavigationLink {
                                ActivitiesView(store: store)
                            } label: {
                                headerButtonLabel("Activities")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("friends.activities")
                            .accessibilityLabel("Activities")
                            NavigationLink {
                                FriendListView(store: store, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                            } label: {
                                headerButtonLabel("Friends")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("friends.manageFriends")
                            .accessibilityLabel("Friends and blocks")
                        }
                    }
                    .padding(.top, 4)

                    shopWindowCard

                    nearbyStatusBanner
                        .animation(.easeInOut(duration: 0.3), value: manager.isSearching)
                        .animation(.easeInOut(duration: 0.3), value: manager.slots.count)

                    displayNameHint

                    if manager.meshPhotos.isEmpty {
                        emptyAlbumView
                    } else {
                        cacheWarningBanner
                        sessionSearchField
                        photoGrid
                    }
                }
                .padding(20)
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
        }
    }

    // MARK: - Header button label (matches HeaderActionButton visual)

    /// A named header pill matching ``HeaderActionButton``'s title variant — the same cream pill the
    /// Food ("+ meal") and Move ("Log" / "Share") headers use.
    ///
    /// Drawn here rather than composed from `HeaderActionButton` because these two header actions are
    /// `NavigationLink`s, not button actions. They are deliberately **titled**: the old icon-only pair
    /// made the user tap to discover what `figure.2.arms.open` and `person.2` did, and `person.2` was
    /// already doing duty as the searching-pulse glyph and the selected tab icon on the same screen.
    private func headerButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(.fernlet(.label))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color.bark)
            .frame(minWidth: 72, minHeight: 58)
            .padding(.horizontal, 10)
            .background(Color.cream.opacity(0.9), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.bark.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Display-name hint

    /// First-run nudge: with no mesh display name set, nearby friends see this device's name
    /// ("iPhone") — the name rides the discovery broadcast. Say so where the connecting actually
    /// happens rather than leaving it two taps deep in the roster, and link straight to the field.
    @ViewBuilder
    private var displayNameHint: some View {
        if store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
            NavigationLink {
                FriendListView(store: store, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
            } label: {
                HStack(spacing: 8) {
                    Text("You appear as \(store.resolvedProximityDisplayName)")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Text("Change")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends.changeDisplayName")
            .accessibilityLabel("You appear as \(store.resolvedProximityDisplayName). Change the name friends see.")
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
                if let minutesLeft = manager.clothingShop.remainingWindowMinutes(at: context.date) {
                    NavigationLink {
                        FriendShopView(store: store, shop: manager.clothingShop)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bag")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.moss)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Friend shops are open")
                                    .font(.fernlet(.headerMedium))
                                    .foregroundStyle(Color.bark)
                                Text("Shop open — \(minutesLeft) min")
                                    .font(.fernlet(.bodySmall))
                                    .foregroundStyle(Color.slate)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.slate)
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.moss.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("friends.friendShops")
                    .accessibilityLabel("Friend shops open, \(minutesLeft) minutes left")
                }
            }
        }
    }

    // MARK: - Nearby status banner

    @ViewBuilder
    private var nearbyStatusBanner: some View {
        if manager.isSearching {
            VStack(spacing: 8) {
                if let discoveryError = manager.discoveryError {
                    discoveryFailureBanner(discoveryError)
                } else if manager.slots.isEmpty {
                    HStack(spacing: 10) {
                        // Deliberately NOT `person.2`: that glyph is already the (filled) Friends tab
                        // icon on this very screen, so it says "you are on the Friends tab", not
                        // "listening for someone nearby". The radio waves say the second thing.
                        SearchingPulse(tint: Color.moss, size: 32, systemImage: "dot.radiowaves.left.and.right")
                        Text("Looking for nearby friends…")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 6) {
                        ForEach(manager.slots) { slot in
                            NearbySlotRow(
                                slot: slot,
                                showDebugOverride: store.settings.showProximityDebugTools,
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
            }
        }
    }

    /// Shown in place of the "Looking for nearby friends…" pulse when the radios failed to start.
    ///
    /// The transport already detects this (`MeshMultipeerSession`'s `didNotStart*` delegates) and
    /// routes it to `manager.meshError`, but the only view that rendered `meshError` was
    /// `DisposableCameraView` — which exists only *inside* a session. A discovery failure happens
    /// before any session, so the message was set and never seen: the pulse span forever and the
    /// mesh looked simply broken. On device the overwhelmingly likely cause is a declined Local
    /// Network prompt, so lead with that and keep the raw reason as secondary detail.
    private func discoveryFailureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Color.terracotta)
            VStack(alignment: .leading, spacing: 3) {
                Text("Can't look for nearby friends")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text("Fernlet needs Local Network access to find friends in person. Check Settings › Fernlet › Local Network, then come back to this screen.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.terracotta.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("friends.discoveryFailure")
        .accessibilityElement(children: .combine)
    }

    // MARK: - Cache soft-warning (spec §11: 900-photo warning ahead of the 1000 FIFO cap)

    @ViewBuilder
    private var cacheWarningBanner: some View {
        if manager.meshPhotos.count >= PrivateMediaStore.cacheWarningThreshold, !cacheWarningDismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Color.goldenrod)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your photo shelf is nearly full")
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text("You're keeping \(manager.meshPhotos.count) of \(PrivateMediaStore.maxCachedPhotos) shared photos. Once it's full, the oldest quietly make room for new ones — save any you'd like to keep.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    cacheWarningDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.slate)
                }
                .buttonStyle(.plain)
                .fernletIconButton("Dismiss photo shelf notice")
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.goldenrod.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: - Photo grid

    private let columns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 1) {
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
            }
        }
        .padding(.top, 2)
    }

    /// What VoiceOver says for one album cell: who shared it, when, and whether it opens a carousel.
    private func albumCellLabel(_ post: FriendPhotoWallPost) -> String {
        let cover = post.coverPhoto
        let when = cover.addedAt.formatted(date: .abbreviated, time: .omitted)
        if post.isCarousel {
            return "Photo from \(cover.senderName), \(when), carousel, \(post.photos.count) photos"
        }
        return "Photo from \(cover.senderName), \(when)"
    }

    private var sessionSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.slate)
            TextField("Search by friend or session name", text: $sessionSearchText)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    private var filteredPhotoWallPosts: [FriendPhotoWallPost] {
        let posts = manager.photoWallPosts
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

    private func albumPhotoCell(_ post: FriendPhotoWallPost) -> some View {
        Color.cream
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LazyFriendPhotoImage(loadData: { manager.thumbnailData(for: post.coverPhoto) }, contentMode: .fill)
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if post.isCarousel {
                    Image(systemName: "square.on.square")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(8)
                }
            }
    }

    // MARK: - Empty state

    private var emptyAlbumView: some View {
        EmptyState(
            text: "Photos from your hangouts will appear here.",
            systemImage: "photo.on.rectangle.angled"
        )
        .padding(.top, 34)
    }

    // MARK: - Helper

    private func connectedPeerName() -> String {
        for slot in manager.slots where slot.fingerprint != nil {
            switch slot.coordinator.state {
            case .connected(let p), .transferring(let p, _),
                 .awaitingProximityCommit(let p), .awaitingManualCommit(let p),
                 .awaitingUserConfirmation(let p):
                return p.displayName
            default:
                break
            }
        }
        return manager.slots.first?.peer.displayName ?? "Friend"
    }

    /// Session-end review, driven off OBSERVABLE MODEL STATE (Phase 2, "Session-end review is
    /// model-state, not view-events"): presents whenever a promoted `pendingFriendReview` batch
    /// or post-teardown session photos exist, checked from both `.onChange` and `.onAppear`.
    /// Friend candidates come from the BATCH entries; eligibility is computed here — at
    /// presentation time, against the live trust vault — so peers trusted or blocked mid-session
    /// never reach the prompt.
    private func presentDisconnectReviewIfNeeded() {
        guard !manager.isInSession else { return }
        guard !disconnectReviewPresented, !keepFriendsPromptPresented else { return }
        let batch = manager.pendingFriendReview
        let hasPhotos = !manager.sessionPhotos.isEmpty
        guard batch != nil || hasPhotos else { return }
        reviewBatch = batch
        friendCandidates = FriendMintingReview.eligibleCandidates(
            roster: batch?.entries ?? [],
            trustedPeers: store.trustedProximityPeers
        )
        keptFriendFingerprints = []
        switch FriendMintingReview.sessionEndReview(
            hasPhotos: hasPhotos,
            eligibleCandidateCount: friendCandidates.count
        ) {
        case .photoReview:
            selectedForSave = Set(manager.sessionPhotos.map(\.id))
            disconnectReviewPresented = true
        case .friendPromptOnly:
            keepFriendsPromptPresented = true
        case .none:
            // Nothing to review — consume the batch immediately so it can't re-present.
            if let batch { manager.completeFriendReview(batch.id) }
            reviewBatch = nil
            friendCandidates = []
        }
    }

    /// Completes the keep-as-friend flow: mints the kept candidates (one-sided, local-only) and
    /// consumes the PRESENTED batch via completeFriendReview — never clearSessionRoster(), which
    /// clobbered live-roster entries belonging to the next session. Skipped/untoggled candidates
    /// are simply dropped. A no-op when the prompt was abandoned for a new session (batch nil).
    private func finalizeFriendKeeps() {
        if let batch = reviewBatch {
            store.keepProximityFriends(from: friendCandidates, keptFingerprints: keptFriendFingerprints)
            manager.completeFriendReview(batch.id)
        }
        reviewBatch = nil
        friendCandidates = []
        keptFriendFingerprints = []
    }

}

// MARK: - Full-screen photo feed

/// The full-screen, vertically scrolling feed of photo-wall posts, opened from the album grid.
///
/// Scrolls to `initialPostID` on appear and renders each post as a
/// ``FriendPhotoCarouselPostView``. Dismisses itself when the last photo is deleted so the
/// viewer never sits on a blank screen.
private struct FriendPhotoFeedView: View {
    let posts: [FriendPhotoWallPost]
    let initialPostID: UUID?
    let manager: MeshNetworkManager
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(posts) { post in
                            FriendPhotoCarouselPostView(
                                post: post,
                                manager: manager,
                                width: geometry.size.width
                            )
                            .id(post.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(Color.parchment)
                .onAppear {
                    guard let initialPostID else { return }
                    proxy.scrollTo(initialPostID, anchor: .top)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.bark)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .padding(.trailing, 16)
                .accessibilityLabel("Close photo viewer")
            }
        }
        .background(Color.parchment)
        .onChange(of: posts.isEmpty) { _, isEmpty in
            // Deleting the last remaining photo empties the feed; dismiss instead of leaving the
            // viewer on a blank screen.
            if isEmpty { onDismiss() }
        }
    }
}

/// One post in the full-screen feed: a paged carousel of a session's photos with save, favorite,
/// and delete actions.
///
/// Tracks its own selected page and auto-fading chrome (page counter + dots), and re-anchors the
/// selection when a deletion removes the current page — the post id is stable for aggregated
/// sessions, so the view is reused without re-init. Saving rehydrates the metadata-only payload
/// from the encrypted disk cache (`MeshNetworkManager.hydratedPhotos`) before handing bytes to
/// `FriendPhotoLibrarySaver`, and never reports a false success when decryption fails.
private struct FriendPhotoCarouselPostView: View {
    let post: FriendPhotoWallPost
    let manager: MeshNetworkManager
    let width: CGFloat

    @State private var selectedPhotoID: UUID
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var pendingDeletePhotoID: UUID?
    @State private var saveErrorMessage: PhotoSaveFailure?
    @State private var savedPhotoIDs: Set<UUID> = []
    /// Photos with a save Task already running — the per-photo in-flight cap (R3).
    @State private var inFlightSaveIDs: Set<UUID> = []

    init(post: FriendPhotoWallPost, manager: MeshNetworkManager, width: CGFloat) {
        self.post = post
        self.manager = manager
        self.width = width
        self._selectedPhotoID = State(initialValue: post.photos.first?.id ?? post.coverPhoto.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

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
        }
        .background(Color.parchment)
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

    /// The "n / total" capsule, shown with the auto-fading chrome on multi-photo posts.
    @ViewBuilder
    private var pageCounterOverlay: some View {
        if chromeVisible, post.photos.count > 1 {
            Text("\(selectedIndex + 1) / \(post.photos.count)")
                .font(.fernlet(.stat))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.58), in: Capsule())
                .padding(14)
                .transition(.opacity)
        }
    }

    /// The page dots, shown with the auto-fading chrome on multi-photo posts.
    @ViewBuilder
    private var pageDotsOverlay: some View {
        if chromeVisible, post.photos.count > 1 {
            HStack(spacing: 6) {
                ForEach(post.photos) { photo in
                    Circle()
                        .fill(photo.id == selectedPhotoID ? Color.white : Color.white.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(10)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.bottom, 14)
            .transition(.opacity)
        }
    }

    /// Actions of the per-photo delete confirmation dialog.
    @ViewBuilder
    private var deleteConfirmationButtons: some View {
        Button("Delete", role: .destructive) {
            if let id = pendingDeletePhotoID { manager.deletePhoto(id) }
            pendingDeletePhotoID = nil
        }
        Button("Cancel", role: .cancel) { pendingDeletePhotoID = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FriendProfilePlaceholder()
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPhoto.senderName)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text(selectedPhoto.addedAt, style: .date)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Spacer()
            // Balances the 44pt close button that floats over this row.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func carouselPhoto(_ photo: FriendPhotoPayload) -> some View {
        Color.parchment
            .overlay {
                LazyFriendPhotoImage(
                    loadData: { manager.imageData(for: photo) },
                    contentMode: .fit,
                    shouldLoad: shouldLoad(photo)
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: width * 1.25)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 10) {
                    let isSaved = savedPhotoIDs.contains(photo.id)
                    circleActionButton(
                        systemName: isSaved ? "checkmark" : "square.and.arrow.down",
                        tint: isSaved ? Color.moss : .white,
                        // The glyph turns into a checkmark when it's done — the label has to say the
                        // same thing, or VoiceOver keeps offering a save that already happened.
                        accessibilityLabel: isSaved ? "Saved to Photos" : "Save this picture to your Photos library"
                    ) { savePhoto(photo) }

                    if post.session != nil {
                        let isFavorite = manager.favoritePhotoID(for: post) == photo.id
                        circleActionButton(
                            systemName: isFavorite ? "heart.fill" : "heart",
                            tint: isFavorite ? Color.dustyRose : .white,
                            accessibilityLabel: "Favorite this photo",
                            selected: isFavorite
                        ) { manager.toggleFavorite(photoID: photo.id, in: post) }
                    }

                    circleActionButton(
                        systemName: "trash",
                        tint: .white,
                        accessibilityLabel: "Delete this picture"
                    ) { pendingDeletePhotoID = photo.id }
                }
                .padding(14)
            }
    }

    private func circleActionButton(
        systemName: String,
        tint: Color,
        accessibilityLabel: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.38), in: Circle())
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
            let hydrated = manager.hydratedPhotos([photo])
            // If the bytes can't be loaded/decrypted, don't report a false success.
            guard !hydrated.isEmpty else {
                saveErrorMessage = .generic
                return
            }
            do {
                try await FriendPhotoLibrarySaver.save(hydrated)
                savedPhotoIDs.insert(photo.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        chromeTask = Task {
            // The sleep result IS the cancellation check: `Task.sleep` throws exactly when the task
            // is cancelled, so a cancelled fade simply returns (R7 — no swallowed error).
            do {
                try await Task.sleep(for: .seconds(5))
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

/// The little moss-leaf circle standing in for a friend's avatar in the feed header.
///
/// Purely decorative — friend photos carry no profile pictures, so every post gets the same
/// placeholder mark.
private struct FriendProfilePlaceholder: View {
    var body: some View {
        Circle()
            .fill(Color.moss.opacity(0.16))
            .overlay {
                Image(systemName: "leaf.fill")
                    .font(.caption)
                    .foregroundStyle(Color.moss)
            }
            .frame(width: 38, height: 38)
            .overlay(Circle().stroke(Color.bark.opacity(0.08), lineWidth: 1))
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
            Image(systemName: stateIcon)
                .font(.title3)
                .foregroundStyle(stateColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(peerName)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text(stateLabel)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
            Spacer()

            trailingControl
        }
        .padding(12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
        )
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
                Text(String(format: "%.0f cm", d * 100))
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
                VerifyQRDisplaySheet(url: verifyQRURL, peerName: peerName)
            }
            .sheet(isPresented: $showVerifyScanner, onDismiss: {
                // Raise the alert only once the scanner has actually gone away.
                if pendingScanFailed {
                    pendingScanFailed = false
                    verifyMissed = true
                }
            }) {
                VerifyQRScanSheet { url in
                    pendingScanFailed = !onScanVerified(url)
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

    private var peerName: String {
        switch slot.coordinator.state {
        case .awaitingProximityCommit(let p), .awaitingManualCommit(let p),
             .awaitingUserConfirmation(let p), .connected(let p), .transferring(let p, _):
            return p.displayName
        default:
            return slot.peer.displayName
        }
    }

    private var stateLabel: String {
        switch slot.coordinator.state {
        case .awaitingIdentityIntroduction: return "Exchanging identity…"
        case .awaitingProximityCommit:
            if let d = distanceMeters { return String(format: "Move closer — %.0f cm away", d * 100) }
            return "Tap phones together to connect"
        case .awaitingManualCommit: return "Tap to confirm connection"
        case .connected, .transferring: return "Connected"
        default: return "Connecting…"
        }
    }

    private var stateIcon: String {
        switch slot.coordinator.state {
        case .connected, .transferring: return "checkmark.circle.fill"
        case .awaitingManualCommit: return "hand.tap.fill"
        case .awaitingProximityCommit: return "wave.3.right"
        default: return "circle.dotted"
        }
    }

    private var stateColor: Color {
        switch slot.coordinator.state {
        case .connected, .transferring: return Color.moss
        case .awaitingManualCommit: return Color.goldenrod
        default: return Color.slate
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
    let peerName: String
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

                VStack(spacing: 6) {
                    Text(peerName)
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
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 32, x: 0, y: 10)
            .offset(y: cardOffset)
            .opacity(cardOpacity)
        }
        .onAppear { runAnimation() }
        .onDisappear { animationTask?.cancel() }
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
            // flip the parent's `sessionReady` behind a dismissed view.
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
