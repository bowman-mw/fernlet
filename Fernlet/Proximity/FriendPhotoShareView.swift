import SwiftUI
import Combine
import Photos
import PhotosUI
import UIKit

struct FriendPhotoPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let imageData: Data
    let addedAt: Date
    let senderName: String
    let senderFingerprint: String?
    let senderSigningPublicKey: Data?

    init(id: UUID = UUID(), imageData: Data, addedAt: Date = Date(), senderName: String,
         senderFingerprint: String? = nil, senderSigningPublicKey: Data? = nil) {
        self.id = id
        self.imageData = imageData
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
    }
}

struct FriendPhotoManifestPayload: Codable, Equatable {
    let photoIDs: [UUID]
}

struct FriendPhotoRequestPayload: Codable, Equatable {
    let missingPhotoIDs: [UUID]
}

struct FriendPhotoCacheStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [FriendPhotoPayload] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return (try? decoder.decode([FriendPhotoPayload].self, from: data)) ?? []
    }

    func save(_ photos: [FriendPhotoPayload]) {
        let capped = Array(photos.sorted { $0.addedAt > $1.addedAt }.prefix(200))
        guard let data = try? encoder.encode(capped) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory
            .appendingPathComponent("Fernlet", isDirectory: true)
            .appendingPathComponent("FriendPhotoCache.json")
    }
}

@MainActor
final class FriendPhotoSharingService: ObservableObject, ProximityPayloadHandling {
    @Published private(set) var sharedPhotos: [FriendPhotoPayload] = []
    @Published var lastError: String?

    let coordinator: ProximityCoordinator
    private let store: FernletStore
    private let identity: IdentityService
    private let cacheStore: FriendPhotoCacheStore
    private var cancellables = Set<AnyCancellable>()
    private var lastSyncedPeerFingerprint: String?

    init(store: FernletStore) {
        let cacheStore = FriendPhotoCacheStore()
        self.store = store
        self.cacheStore = cacheStore
        self.sharedPhotos = cacheStore.load()
        let identity = IdentityService()
        try? identity.ensureProvisioned()
        self.identity = identity
        let name = store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces)
        let coordinator = ProximityCoordinator(
            identity: identity,
            transport: MultipeerSession(),
            ranging: NIRangingSession(),
            inspector: store.connectionInspector,
            trustPolicy: store,
            replayCache: ReplayCache(),
            displayName: name.isEmpty ? UIDevice.current.name : name,
            timeoutSeconds: 180
        )
        self.coordinator = coordinator
        self.coordinator.attachPayloadHandler(self)
        self.coordinator.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var isConnected: Bool {
        if case .connected = coordinator.state { return true }
        if case .transferring = coordinator.state { return true }
        return false
    }

    var statusText: String {
        switch coordinator.state {
        case .idle:
            return "Ready to connect"
        case .starting:
            return "Starting nearby session"
        case .discovering:
            return "Looking for friends nearby"
        case .peerInRange(let peer, _):
            return "Found \(peer.displayName)"
        case .pendingInvite(let invite):
            return "\(invite.peer.displayName) wants to connect"
        case .awaitingTapConfirmation(let peer):
            return "Connecting with \(peer.displayName)"
        case .awaitingIdentityIntroduction(let peer):
            return "Verifying \(peer.displayName)"
        case .awaitingUserConfirmation(let peer):
            return "Add \(peer.displayName) as a friend"
        case .connected(let peer):
            return "Connected with \(peer.displayName)"
        case .transferring(let peer, _):
            return "Sharing with \(peer.displayName)"
        case .ended:
            return "Disconnected"
        case .failed(let reason):
            return "Connection failed: \(reason)"
        }
    }

    func joinGroup() {
        Task { await coordinator.beginFriendJoin() }
    }

    func acceptInvite() {
        Task { await coordinator.acceptPendingInvite() }
    }

    func rejectInvite() {
        Task { await coordinator.rejectPendingInvite() }
    }

    func confirmTap() {
        Task { await coordinator.tapToConfirm() }
    }

    func trustPeer(_ peer: ProximityCoordinator.PeerIdentity) {
        store.trustProximityPeer(peer, mode: .friend)
        Task { await coordinator.confirmPeerIdentity() }
    }

    func rejectPeer() {
        Task { await coordinator.rejectPendingInvite() }
    }

    func disconnect() {
        Task { await coordinator.cancel() }
    }

    func addPhotoData(_ data: Data) {
        guard let image = UIImage(data: data),
              let normalizedData = image.resizedForFriendSharing().jpegData(compressionQuality: 0.82) else {
            lastError = "That image could not be prepared."
            return
        }
        let photo = FriendPhotoPayload(
            imageData: normalizedData,
            senderName: UIDevice.current.name,
            senderFingerprint: identity.localFingerprint,
            senderSigningPublicKey: identity.localSigningPublicKey
        )
        cache(photo)
        guard isConnected else { return }
        Task { await send(photo) }
    }

    func saveSelectedAndClear(ids selectedIDs: Set<UUID>) async {
        let selectedPhotos = sharedPhotos.filter { selectedIDs.contains($0.id) }
        do {
            try await FriendPhotoLibrarySaver.save(selectedPhotos)
            sharedPhotos.removeAll()
            persistCache()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAllCachedPhotos() {
        sharedPhotos.removeAll()
        persistCache()
    }

    func syncCacheIfConnected(_ state: ProximityCoordinator.State) {
        guard markCacheSyncNeeded(for: state) else { return }
        Task { await sendManifest() }
    }

    @discardableResult
    func markCacheSyncNeeded(for state: ProximityCoordinator.State) -> Bool {
        switch state {
        case .connected(let peer):
            guard lastSyncedPeerFingerprint != peer.fingerprint else { return false }
            lastSyncedPeerFingerprint = peer.fingerprint
            return true
        case .transferring:
            return false
        case .idle, .starting, .discovering, .peerInRange, .pendingInvite,
             .awaitingTapConfirmation, .awaitingIdentityIntroduction, .awaitingUserConfirmation,
             .ended, .failed:
            lastSyncedPeerFingerprint = nil
            return false
        }
    }

    func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    ) {
        do {
            switch envelope.payloadType {
            case .friendPhoto:
                let photo = try JSONDecoder().decode(FriendPhotoPayload.self, from: plaintext)
                cache(photo)
            case .friendPhotoManifest:
                let manifest = try JSONDecoder().decode(FriendPhotoManifestPayload.self, from: plaintext)
                requestMissingPhotos(from: manifest)
            case .friendPhotoRequest:
                let request = try JSONDecoder().decode(FriendPhotoRequestPayload.self, from: plaintext)
                Task { await sendRequestedPhotos(request.missingPhotoIDs) }
            default:
                return
            }
        } catch {
            lastError = "A friend photo sync message could not be opened."
        }
    }

    private func sendManifest() async {
        do {
            let data = try JSONEncoder().encode(FriendPhotoManifestPayload(photoIDs: sharedPhotos.map(\.id)))
            try await coordinator.sendPayload(
                type: .friendPhotoManifest,
                summary: PayloadSummary(title: "Photo cache", itemCount: sharedPhotos.count),
                payload: data
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func requestMissingPhotos(from manifest: FriendPhotoManifestPayload) {
        let localIDs = Set(sharedPhotos.map(\.id))
        let missingIDs = manifest.photoIDs.filter { !localIDs.contains($0) }
        guard !missingIDs.isEmpty else { return }
        Task { await sendPhotoRequest(missingIDs) }
    }

    private func sendPhotoRequest(_ missingIDs: [UUID]) async {
        do {
            let data = try JSONEncoder().encode(FriendPhotoRequestPayload(missingPhotoIDs: missingIDs))
            try await coordinator.sendPayload(
                type: .friendPhotoRequest,
                summary: PayloadSummary(title: "Missing photos", itemCount: missingIDs.count),
                payload: data
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendRequestedPhotos(_ ids: [UUID]) async {
        let requestedIDs = Set(ids)
        let photos = sharedPhotos.filter { requestedIDs.contains($0.id) }
        for photo in photos {
            await send(photo)
        }
    }

    private func send(_ photo: FriendPhotoPayload) async {
        do {
            let data = try JSONEncoder().encode(photo)
            try await coordinator.sendPayload(
                type: .friendPhoto,
                summary: PayloadSummary(title: "Shared photo", itemCount: 1),
                payload: data
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func cache(_ photo: FriendPhotoPayload) {
        guard !sharedPhotos.contains(where: { $0.id == photo.id }) else { return }
        sharedPhotos.insert(photo, at: 0)
        sharedPhotos = Array(sharedPhotos.sorted { $0.addedAt > $1.addedAt }.prefix(200))
        persistCache()
    }

    private func persistCache() {
        cacheStore.save(sharedPhotos)
    }
}

struct FriendPhotoShareView: View {
    @ObservedObject var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false

    @StateObject private var service: FriendPhotoSharingService
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var reviewPresented = false
    @State private var selectedForSave: Set<UUID> = []

    init(store: FernletStore, activeSheet: Binding<FernletSheet?>, isInHub: Bool = false) {
        self.store = store
        self._activeSheet = activeSheet
        self.isInHub = isInHub
        self._service = StateObject(wrappedValue: FriendPhotoSharingService(store: store))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Friends", subtitle: "Nearby photo sharing.")
                        Spacer()
                        if store.settings.connectionInspectorMode != .disabled {
                            HeaderActionButton(systemImage: "antenna.radiowaves.left.and.right") {
                                store.showConnectionInspector = true
                            }
                        }
                        HeaderActionButton(systemImage: service.isConnected ? "xmark" : "person.2.badge.plus") {
                            handleHeaderAction()
                        }
                    }
                    .padding(.top, 4)

                    FernletScrollSection("Connection") {
                        connectionControls
                    }

                    FernletScrollSection("Shared pictures") {
                        photoCache
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("")
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
        }
        .onChange(of: pickerItems) { _, newValue in
            loadPickerItems(newValue)
        }
        .onChange(of: service.coordinator.state) { _, newState in
            service.syncCacheIfConnected(newState)
            if shouldReviewAfterDisconnect(newState) {
                selectedForSave = Set(service.sharedPhotos.map(\.id))
                reviewPresented = true
            }
        }
        .sheet(isPresented: $reviewPresented) {
            FriendPhotoReviewSheet(
                photos: service.sharedPhotos,
                selectedIDs: $selectedForSave,
                saveSelected: {
                    await service.saveSelectedAndClear(ids: selectedForSave)
                    service.disconnect()
                    reviewPresented = false
                },
                discardAll: {
                    service.deleteAllCachedPhotos()
                    service.disconnect()
                    reviewPresented = false
                }
            )
        }
        .alert("Friends", isPresented: Binding(
            get: { service.lastError != nil },
            set: { if !$0 { service.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(service.lastError ?? "")
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(service.statusText, systemImage: statusIcon)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()

            if let distanceText = proximityDistanceText {
                Label(distanceText, systemImage: "dot.radiowaves.up.forward")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.slate)
            }

            switch service.coordinator.state {
            case .idle, .ended, .failed:
                Button("Join") { service.joinGroup() }
                    .buttonStyle(ChipButtonStyle(selected: true))
            case .pendingInvite(let invite):
                VStack(alignment: .leading, spacing: 10) {
                    Text(invite.peer.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    HStack(spacing: 10) {
                        Button("Accept") { service.acceptInvite() }
                            .buttonStyle(ChipButtonStyle(selected: true))
                        Button("Decline") { service.rejectInvite() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            case .awaitingTapConfirmation:
                ProgressView()
                    .tint(Color.moss)
            case .awaitingUserConfirmation(let peer):
                VStack(alignment: .leading, spacing: 10) {
                    Text(peer.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("Fingerprint \(peer.fingerprint)")
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                    HStack(spacing: 10) {
                        Button("Add friend") { service.trustPeer(peer) }
                            .buttonStyle(ChipButtonStyle(selected: true))
                        Button("Reject") { service.rejectPeer() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            case .connected(let peer), .transferring(let peer, _):
                VStack(alignment: .leading, spacing: 10) {
                    Text(peer.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                            Label("Add pictures", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(ChipButtonStyle(selected: true))

                        Button("Disconnect") {
                            beginReviewOrDisconnect()
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            default:
                Button("Cancel") { service.disconnect() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
        }
        .padding(.vertical, 4)
    }

    private var proximityDistanceText: String? {
        guard let distance = service.coordinator.lastKnownDistance,
              case .meters(let m, _) = distance else { return nil }
        if m < 1.0 {
            return String(format: "%.0f cm away", m * 100)
        } else {
            return String(format: "%.1f m away", m)
        }
    }

    @ViewBuilder
    private var photoCache: some View {
        if service.sharedPhotos.isEmpty {
            EmptyState(text: "No shared pictures yet.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(service.sharedPhotos) { photo in
                    FriendPhotoTile(photo: photo, selected: false)
                }
            }
        }
    }

    private var statusIcon: String {
        service.isConnected ? "person.2.fill" : "dot.radiowaves.left.and.right"
    }

    private func handleHeaderAction() {
        if service.isConnected {
            beginReviewOrDisconnect()
        } else {
            service.joinGroup()
        }
    }

    private func beginReviewOrDisconnect() {
        guard !service.sharedPhotos.isEmpty else {
            service.disconnect()
            return
        }
        selectedForSave = Set(service.sharedPhotos.map(\.id))
        reviewPresented = true
    }

    private func shouldReviewAfterDisconnect(_ state: ProximityCoordinator.State) -> Bool {
        guard !reviewPresented, !service.sharedPhotos.isEmpty else { return false }
        switch state {
        case .ended, .failed:
            return true
        default:
            return false
        }
    }

    private func loadPickerItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    service.addPhotoData(data)
                }
            }
            pickerItems = []
        }
    }
}

struct FriendPhotoTile: View {
    let photo: FriendPhotoPayload
    let selected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: photo.imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(height: 112)
                    .overlay(Image(systemName: "photo").foregroundStyle(Color.slate))
            }

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.moss)
                    .background(Color.cream, in: Circle())
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.moss : Color.bark.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
    }
}

struct FriendPhotoReviewSheet: View {
    let photos: [FriendPhotoPayload]
    @Binding var selectedIDs: Set<UUID>
    let saveSelected: () async -> Void
    let discardAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Review pictures")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    Text("Choose which shared pictures to save. Everything else is deleted from this device's temporary cache.")
                        .font(.callout)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(photos) { photo in
                            Button {
                                toggle(photo.id)
                            } label: {
                                FriendPhotoTile(photo: photo, selected: selectedIDs.contains(photo.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                Button("Delete all", role: .destructive, action: discardAll)
                    .buttonStyle(ChipButtonStyle(selected: false))
                Button("Save selected") {
                    Task { await saveSelected() }
                }
                .buttonStyle(ChipButtonStyle(selected: true))
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
            .background(Color.parchment)
        }
        .background(Color.parchment)
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

enum FriendPhotoLibrarySaver {
    static func save(_ photos: [FriendPhotoPayload]) async throws {
        guard !photos.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CocoaError(.userCancelled)
        }

        try await PHPhotoLibrary.shared().performChanges {
            for photo in photos {
                guard let image = UIImage(data: photo.imageData) else { continue }
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }
}

private extension UIImage {
    func resizedForFriendSharing(maxDimension: CGFloat = 1400) -> UIImage {
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return self }
        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
