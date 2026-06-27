import SwiftUI
import UIKit
import FernletDomainModel

// MARK: - FriendsView

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
    @State private var photoSaveError: String? = nil
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
        }
        .onChange(of: manager.isInSession) { wasInSession, nowInSession in
            if !wasInSession && nowInSession {
                connectionPeerName = connectedPeerName()
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                withAnimation { showConnectionAnimation = true }
            } else if wasInSession && !nowInSession {
                sessionReady = false
                showConnectionAnimation = false
                presentDisconnectReviewIfNeeded()
            }
        }
        .sheet(isPresented: $disconnectReviewPresented) {
            FriendPhotoReviewSheet(
                photos: manager.sessionPhotos,
                selectedIDs: $selectedForSave,
                saveSelected: {
                    // Session photos are stored metadata-only to bound memory; rehydrate the
                    // selected ones from the disk cache before saving to the photo library.
                    let toSave = manager.hydratedPhotos(manager.sessionPhotos.filter { selectedForSave.contains($0.id) })
                    do {
                        try await FriendPhotoLibrarySaver.save(toSave)
                        manager.finishSessionPhotos(keeping: selectedForSave)
                        await manager.leaveSessionAfterNotifyingPeers()
                        disconnectReviewPresented = false
                    } catch CocoaError.userCancelled {
                        photoSaveError = "Fernlet needs access to your Photo Library to save photos. Open Settings to grant access."
                    } catch {
                        photoSaveError = "Could not save to your photo library. Please try again."
                    }
                },
                discardAll: {
                    manager.deleteAllSessionPhotos()
                    Task {
                        await manager.leaveSessionAfterNotifyingPeers()
                        disconnectReviewPresented = false
                    }
                },
                loadImageData: { manager.imageData(for: $0) }
            )
            .interactiveDismissDisabled()
            .alert("Couldn't Save Photos", isPresented: Binding(
                get: { photoSaveError != nil },
                set: { if !$0 { photoSaveError = nil } }
            )) {
                if photoSaveError?.contains("Settings") == true {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        photoSaveError = nil
                    }
                }
                Button("OK", role: .cancel) { photoSaveError = nil }
            } message: {
                Text(photoSaveError ?? "")
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedAlbumPostID != nil },
                set: { if !$0 { selectedAlbumPostID = nil } }
            )
        ) {
            FriendPhotoFeedView(
                    posts: filteredPhotoWallPosts,
                    initialPostID: selectedAlbumPostID,
                    manager: manager,
                    onDismiss: { selectedAlbumPostID = nil }
                )
        }
    }

    // MARK: - Photo album

    private var photoAlbumView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Friends", subtitle: "")
                        Spacer()
                        HStack(spacing: 10) {
                            NavigationLink {
                                FriendListView(store: store, isTabBarCompact: $isTabBarCompact, tabResetToken: $tabResetToken)
                            } label: {
                                headerButtonLabel("person.2")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("friends.manageFriends")
                        }
                    }
                    .padding(.top, 4)

                    nearbyStatusBanner
                        .animation(.easeInOut(duration: 0.3), value: manager.isSearching)
                        .animation(.easeInOut(duration: 0.3), value: manager.slots.count)

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

    private func headerButtonLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.bark)
            .frame(width: 58, height: 58)
            .background(Color.cream.opacity(0.9), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.bark.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Nearby status banner

    @ViewBuilder
    private var nearbyStatusBanner: some View {
        if manager.isSearching {
            VStack(spacing: 8) {
                if manager.slots.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(Color.moss).scaleEffect(0.85)
                        Text("Looking for nearby friends…")
                            .font(.footnote)
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
                                onForceConnect: { manager.commitManualProximity(slotID: slot.id) }
                            )
                        }
                    }
                }
            }
        }
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("You're keeping \(manager.meshPhotos.count) of \(PrivateMediaStore.maxCachedPhotos) shared photos. Once it's full, the oldest quietly make room for new ones — save any you'd like to keep.")
                        .font(.caption)
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
                .accessibilityLabel("Dismiss")
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
                albumPhotoCell(post)
                    .onTapGesture {
                        selectedAlbumPostID = post.id
                    }
            }
        }
        .padding(.top, 2)
    }

    private var sessionSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.slate)
            TextField("Search sessions by person or mesh", text: $sessionSearchText)
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
        VStack(spacing: 14) {
            Spacer().frame(height: 48)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(Color.bark.opacity(0.18))
            Text("Photos from your hangouts\nwill appear here")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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

    private func presentDisconnectReviewIfNeeded() {
        guard !manager.sessionPhotos.isEmpty else { return }
        selectedForSave = Set(manager.sessionPhotos.map(\.id))
        disconnectReviewPresented = true
    }

}

// MARK: - Full-screen photo feed

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
                        .frame(width: 42, height: 42)
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

private struct FriendPhotoCarouselPostView: View {
    let post: FriendPhotoWallPost
    let manager: MeshNetworkManager
    let width: CGFloat

    @State private var selectedPhotoID: UUID
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var pendingDeletePhotoID: UUID?
    @State private var saveErrorMessage: String?
    @State private var savedPhotoIDs: Set<UUID> = []

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
            .overlay(alignment: .topTrailing) {
                if chromeVisible, post.photos.count > 1 {
                    Text("\(selectedIndex + 1) / \(post.photos.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(14)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
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
        .confirmationDialog(
            "Delete this picture?",
            isPresented: Binding(
                get: { pendingDeletePhotoID != nil },
                set: { if !$0 { pendingDeletePhotoID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeletePhotoID { manager.deletePhoto(id) }
                pendingDeletePhotoID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletePhotoID = nil }
        } message: {
            Text("This removes it from this device. It can't be undone.")
        }
        .alert("Couldn't Save Photo", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            if saveErrorMessage?.contains("Settings") == true {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    saveErrorMessage = nil
                }
            }
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FriendProfilePlaceholder()
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPhoto.senderName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                Text(selectedPhoto.addedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(Color.slate)
            }
            Spacer()
            Color.clear.frame(width: 42, height: 42)
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
                    circleActionButton(
                        systemName: savedPhotoIDs.contains(photo.id) ? "checkmark" : "square.and.arrow.down",
                        tint: savedPhotoIDs.contains(photo.id) ? Color.moss : .white,
                        accessibilityLabel: "Save this picture to your Photos library"
                    ) { savePhoto(photo) }

                    if post.session != nil {
                        circleActionButton(
                            systemName: manager.favoritePhotoID(for: post) == photo.id ? "heart.fill" : "heart",
                            tint: manager.favoritePhotoID(for: post) == photo.id ? Color.dustyRose : .white,
                            accessibilityLabel: "Use this picture as the session cover"
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
    }

    private func savePhoto(_ photo: FriendPhotoPayload) {
        Task {
            // Persistent-gallery photos are stored metadata-only in memory; rehydrate the bytes
            // from the encrypted disk cache before handing them to the photo library.
            let hydrated = manager.hydratedPhotos([photo])
            // If the bytes can't be loaded/decrypted, don't report a false success.
            guard !hydrated.isEmpty else {
                saveErrorMessage = "Could not save to your photo library. Please try again."
                return
            }
            do {
                try await FriendPhotoLibrarySaver.save(hydrated)
                savedPhotoIDs.insert(photo.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch CocoaError.userCancelled {
                saveErrorMessage = "Fernlet needs access to your Photo Library to save photos. Open Settings to grant access."
            } catch {
                saveErrorMessage = "Could not save to your photo library. Please try again."
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
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                chromeVisible = false
            }
        }
    }
}

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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.bark)
                Text(stateLabel)
                    .font(.caption)
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

    @ViewBuilder
    private var trailingControl: some View {
        switch slot.coordinator.state {
        case .awaitingProximityCommit:
            if showDebugOverride {
                Button("Force", action: onForceConnect)
                    .buttonStyle(ChipButtonStyle(selected: true))
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("friends.forceConnect.\(slot.id)")
            } else if let d = distanceMeters {
                Text(String(format: "%.0f cm", d * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.slate)
            }
        case .awaitingManualCommit:
            Button("Connect", action: onForceConnect)
                .buttonStyle(ChipButtonStyle(selected: true))
                .accessibilityIdentifier("friends.manualCommit.\(slot.id)")
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

struct ConnectionSuccessOverlay: View {
    let peerName: String
    let onComplete: () -> Void

    @State private var cardOffset: CGFloat = 100
    @State private var cardOpacity: Double = 0
    @State private var ringsScale: CGFloat = 0.3
    @State private var ringsOpacity: Double = 1

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
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Connected")
                        .font(.footnote.weight(.semibold))
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
    }

    private func runAnimation() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.76)) {
            cardOffset = 0
            cardOpacity = 1
            ringsScale = 1.7
        }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.55)) {
                ringsOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeInOut(duration: 0.4)) {
                cardOffset = -70
                cardOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(400))
            onComplete()
        }
    }
}
