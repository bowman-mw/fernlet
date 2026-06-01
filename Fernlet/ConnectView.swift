import SwiftUI

// MARK: - FriendsView

struct FriendsView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    @State private var showConnectionAnimation = false
    @State private var connectionPeerName = ""
    @State private var sessionReady = false

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

            if showConnectionAnimation {
                ConnectionSuccessOverlay(peerName: connectionPeerName) {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        showConnectionAnimation = false
                        sessionReady = true
                    }
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: sessionReady)
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
            }
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
                            if store.settings.showProximityDebugTools {
                                HeaderActionButton(systemImage: "dot.radiowaves.left.and.right") {
                                    store.showConnectionInspector = true
                                }
                                .accessibilityIdentifier("friends.inspectorButton")
                            }
                            NavigationLink {
                                FriendListView(store: store)
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
                        photoGrid
                    }
                }
                .padding(20)
            }
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

    // MARK: - Photo grid

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(manager.meshPhotos) { photo in
                if let data = photo.imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                } else {
                    Color.cream.aspectRatio(1, contentMode: .fill)
                }
            }
        }
        .padding(.top, 2)
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
