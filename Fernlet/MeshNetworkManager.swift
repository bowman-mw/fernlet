import Foundation
import MultipeerConnectivity
import Combine
import Observation
import UIKit

// MARK: - Supporting types

enum SlotKind {
    case active      // full payload routing, up to 3
    case lightweight // heartbeats only, up to 2
}

struct PeerSlot: Identifiable {
    let id: UUID  // == peer.id
    let peer: MultipeerPeer
    let channel: PeerChannelTransport
    let coordinator: ProximityCoordinator
    var kind: SlotKind
    var fingerprint: String?
}

struct LobbyMeshSummary: Identifiable {
    let id: UUID  // meshID
    let name: String
    let knownMemberCount: Int
    let representativePeer: MultipeerPeer
}

struct LobbyIndividual: Identifiable {
    let id: UUID  // peer.id
    let peer: MultipeerPeer
    let isFriend: Bool
}

// MARK: - MeshSlotTrustPolicy

final class MeshSlotTrustPolicy: ProximityTrustPolicy {
    weak var store: FernletStore?

    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        store?.isRevokedProximitySigningKey(publicKey) ?? false
    }

    func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool {
        store?.isBlockedProximitySigningKey(publicKey) ?? false
    }

    // Always auto-confirm identity in mesh context; admission tokens handle authorization.
    func isTrustedProximityPeer(fingerprint: String) -> Bool { true }

    func recordTrainerAudit(_ event: TrainerAuditEvent) {
        store?.recordTrainerAudit(event)
    }
}

// MARK: - NoopRangingSession

@MainActor
private final class NoopRangingSession: RangingProvider {
    var isHardwareSupported: Bool { false }
    var distance: AnyPublisher<RangingDistance, Never> {
        PassthroughSubject<RangingDistance, Never>().eraseToAnyPublisher()
    }
    var state: AnyPublisher<RangingState, Never> {
        PassthroughSubject<RangingState, Never>().eraseToAnyPublisher()
    }
    func myDiscoveryToken() async throws -> Data { Data() }
    func start(with peerToken: Data) async throws {}
    func stop() async {}
}

// MARK: - MeshNetworkManager

@MainActor
@Observable
final class MeshNetworkManager: ProximityPayloadHandling {

    // Published state
    var slots: [PeerSlot] = []
    var currentMesh: MeshDescriptor?
    var pendingAdmissionRequests: [MeshAdmissionRequestPayload] = []
    var lobbyMeshes: [LobbyMeshSummary] = []
    var lobbyIndividuals: [LobbyIndividual] = []
    var meshPhotos: [FriendPhotoPayload] = []
    var isSearching = false
    var meshError: String?

    @ObservationIgnored private unowned let store: FernletStore
    @ObservationIgnored private let meshSession = MeshMultipeerSession()
    @ObservationIgnored private let identity: IdentityService
    @ObservationIgnored private let replayCache = ReplayCache()
    @ObservationIgnored private let photoCacheStore: FriendPhotoCacheStore
    @ObservationIgnored private var slotTrustPolicies: [UUID: MeshSlotTrustPolicy] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    private static let maxActiveSlots = 3
    private static let maxLightweightSlots = 2
    private static let maxTotalSlots = 5

    init(store: FernletStore) {
        self.store = store
        let id = IdentityService()
        try? id.ensureProvisioned()
        self.identity = id
        let cacheURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Fernlet/MeshPhotoCache.json")
        self.photoCacheStore = FriendPhotoCacheStore(fileURL: cacheURL)
        meshPhotos = photoCacheStore.load()
        setupMeshSession()
        startObserving()
    }

    // MARK: - Public API

    func startNewMesh(name: String? = nil) {
        let meshName = name ?? MeshNameGenerator.generate()
        let now = Date()
        let localFP = identity.localFingerprint
        let member = MeshMember(
            fingerprint: localFP,
            displayName: displayName,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            joinedAt: now
        )
        currentMesh = MeshDescriptor(
            meshID: UUID(),
            name: meshName,
            mode: .open,
            members: [member],
            nameSetAt: now,
            nameSetBy: localFP,
            modeSetAt: now,
            modeSetBy: localFP,
            createdAt: now
        )
        startSearching()
    }

    func startLobby() {
        startSearching()
    }

    func stopLobby() {
        stopSearching()
    }

    func joinMesh(_ summary: LobbyMeshSummary) {
        if !isSearching { startSearching() }
        meshSession.invite(summary.representativePeer)
    }

    func leaveMesh() {
        for slot in slots {
            Task { await slot.coordinator.cancel() }
        }
        slots.removeAll()
        slotTrustPolicies.removeAll()
        currentMesh = nil
        pendingAdmissionRequests.removeAll()
    }

    func renameMesh(_ name: String) {
        guard var mesh = currentMesh else { return }
        let now = Date()
        mesh.name = name
        mesh.nameSetAt = now
        mesh.nameSetBy = identity.localFingerprint
        currentMesh = mesh
        broadcastMeshDescriptor()
    }

    func setMeshMode(_ mode: MeshMode) {
        guard var mesh = currentMesh else { return }
        let now = Date()
        mesh.mode = mode
        mesh.modeSetAt = now
        mesh.modeSetBy = identity.localFingerprint
        currentMesh = mesh
        updateDiscoveryInfo()
        broadcastMeshDescriptor()
    }

    func addPhoto(_ data: Data) {
        guard let image = UIImage(data: data),
              let normalized = image.resizedForFriendSharing().jpegData(compressionQuality: 0.82) else { return }
        let photo = FriendPhotoPayload(
            imageData: normalized,
            senderName: displayName,
            senderFingerprint: identity.localFingerprint,
            senderSigningPublicKey: identity.localSigningPublicKey
        )
        cachePhoto(photo)
        for slot in activeSlots {
            Task { [weak self] in
                await self?.sendEnvelope(.friendPhoto, encodable: photo, via: slot)
            }
        }
    }

    func allowAdmission(_ request: MeshAdmissionRequestPayload) {
        pendingAdmissionRequests.removeAll { $0.requesterFingerprint == request.requesterFingerprint }
        guard var mesh = currentMesh, mesh.meshID == request.meshID else { return }
        let newMember = MeshMember(
            fingerprint: request.requesterFingerprint,
            displayName: request.requesterDisplayName,
            signingPublicKey: request.requesterSigningPublicKey,
            keyAgreementPublicKey: request.requesterKeyAgreementPublicKey,
            joinedAt: Date()
        )
        if !mesh.members.contains(where: { $0.fingerprint == request.requesterFingerprint }) {
            mesh.members.append(newMember)
        }
        currentMesh = mesh
        Task { [weak self] in
            guard let self else { return }
            guard let token = try? MeshAdmissionToken.signed(
                meshID: mesh.meshID,
                joinerFingerprint: request.requesterFingerprint,
                admitterIdentity: self.identity
            ) else { return }
            let grant = MeshAdmissionGrantPayload(
                meshID: mesh.meshID,
                requesterFingerprint: request.requesterFingerprint,
                token: token
            )
            if let slot = self.slots.first(where: { $0.fingerprint == request.requesterFingerprint }) {
                await self.sendEnvelope(.meshAdmissionGrant, encodable: grant, via: slot)
            }
            self.broadcastMeshDescriptor()
        }
    }

    func declineAdmission(_ request: MeshAdmissionRequestPayload) {
        pendingAdmissionRequests.removeAll { $0.requesterFingerprint == request.requesterFingerprint }
    }

    // MARK: - ProximityPayloadHandling

    func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    ) {
        let slot = slots.first { $0.coordinator === coordinator }
        let decoder = JSONDecoder()

        switch envelope.payloadType {
        case .meshDescriptor:
            if let payload = try? decoder.decode(MeshStateChangePayload.self, from: plaintext) {
                handleMeshDescriptor(payload.descriptor, from: peer?.fingerprint)
            }
        case .meshAdmissionRequest:
            if let payload = try? decoder.decode(MeshAdmissionRequestPayload.self, from: plaintext) {
                handleAdmissionRequest(payload)
            }
        case .meshAdmissionGrant:
            if let payload = try? decoder.decode(MeshAdmissionGrantPayload.self, from: plaintext) {
                handleAdmissionGrant(payload)
            }
        case .friendPhoto:
            if let payload = try? decoder.decode(FriendPhotoPayload.self, from: plaintext) {
                if let fp = payload.senderFingerprint, store.isBlockedFingerprint(fp) { return }
                cachePhoto(payload)
            }
        case .friendPhotoManifest:
            if let payload = try? decoder.decode(FriendPhotoManifestPayload.self, from: plaintext),
               let slot {
                handlePhotoManifest(payload, from: slot)
            }
        case .friendPhotoRequest:
            if let payload = try? decoder.decode(FriendPhotoRequestPayload.self, from: plaintext),
               let slot {
                sendRequestedPhotos(payload.missingPhotoIDs, to: slot)
            }
        case .sessionGoodbye:
            if let slot { removeSlot(slot) }
        default:
            break
        }
    }

    // MARK: - Private helpers

    private var displayName: String {
        let name = store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? UIDevice.current.name : name
    }

    private var activeSlots: [PeerSlot] {
        slots.filter { $0.kind == .active }
    }

    private func setupMeshSession() {
        meshSession.onPeerDiscovered = { [weak self] peer in
            self?.handlePeerDiscovered(peer)
        }
        meshSession.onPeerLost = { [weak self] peer in
            self?.handlePeerLost(peer)
        }
        meshSession.onPeerChannelReady = { [weak self] channel in
            self?.handleChannelReady(channel)
        }
        meshSession.onPeerDisconnected = { [weak self] peer, _ in
            guard let self else { return }
            if let slot = self.slots.first(where: { $0.peer.id == peer.id }) {
                self.removeSlot(slot)
            }
        }
        meshSession.shouldAcceptInvitation = { [weak self] peer in
            guard let self else { return false }
            if self.slots.count >= Self.maxTotalSlots { return false }
            if let fp = peer.advertisedFingerprint, self.store.isBlockedFingerprint(fp) { return false }
            return true
        }
    }

    private func startSearching() {
        isSearching = true
        meshSession.start(discoveryInfo: currentDiscoveryInfo())
    }

    private func stopSearching() {
        isSearching = false
        meshSession.stop()
        lobbyMeshes.removeAll()
        lobbyIndividuals.removeAll()
        for slot in slots { Task { await slot.coordinator.cancel() } }
        slots.removeAll()
        slotTrustPolicies.removeAll()
    }

    private func currentDiscoveryInfo() -> [String: String] {
        var info: [String: String] = [
            "v": "1",
            "fp": identity.localFingerprint,
            "name": String(displayName.prefix(32))
        ]
        if let mesh = currentMesh {
            info["meshID"] = mesh.meshID.uuidString
            info["meshName"] = String(mesh.name.prefix(40))
            info["meshMode"] = mesh.mode.rawValue
            info["memberCount"] = "\(mesh.members.count)"
        }
        return info
    }

    private func updateDiscoveryInfo() {
        meshSession.updateDiscoveryInfo(currentDiscoveryInfo())
    }

    private func handlePeerDiscovered(_ peer: MultipeerPeer) {
        let info = peer.discoveryInfo ?? [:]
        if let meshIDStr = info["meshID"],
           let meshID = UUID(uuidString: meshIDStr),
           let meshName = info["meshName"],
           let modeStr = info["meshMode"],
           modeStr == MeshMode.open.rawValue {
            let memberCount = Int(info["memberCount"] ?? "1") ?? 1
            if !lobbyMeshes.contains(where: { $0.id == meshID }) {
                lobbyMeshes.append(LobbyMeshSummary(
                    id: meshID,
                    name: meshName,
                    knownMemberCount: memberCount,
                    representativePeer: peer
                ))
            }
        } else {
            let fp = peer.advertisedFingerprint ?? ""
            if !lobbyIndividuals.contains(where: { $0.id == peer.id }) {
                lobbyIndividuals.append(LobbyIndividual(
                    id: peer.id,
                    peer: peer,
                    isFriend: store.isTrustedProximityPeer(fingerprint: fp)
                ))
            }
        }

        // Auto-invite peers into our open mesh if we have capacity
        if let mesh = currentMesh, mesh.mode == .open, slots.count < Self.maxTotalSlots {
            if !slots.contains(where: { $0.peer.id == peer.id }) {
                meshSession.invite(peer)
            }
        }
    }

    private func handlePeerLost(_ peer: MultipeerPeer) {
        lobbyIndividuals.removeAll { $0.id == peer.id }
        if let info = meshSession.peerInfoCache[peer.underlying],
           let meshIDStr = info["meshID"],
           let meshID = UUID(uuidString: meshIDStr) {
            lobbyMeshes.removeAll { $0.id == meshID }
        }
    }

    private func handleChannelReady(_ channel: PeerChannelTransport) {
        guard slots.count < Self.maxTotalSlots else { return }
        guard !slots.contains(where: { $0.peer.id == channel.peer.id }) else { return }

        let kind: SlotKind = activeSlots.count < Self.maxActiveSlots ? .active : .lightweight
        let trustPolicy = MeshSlotTrustPolicy()
        trustPolicy.store = store

        let coordinator = ProximityCoordinator(
            identity: identity,
            transport: channel,
            ranging: NoopRangingSession(),
            payloadHandler: self,
            trustPolicy: trustPolicy,
            replayCache: replayCache,
            displayName: displayName,
            timeoutSeconds: 60
        )

        let slot = PeerSlot(
            id: channel.peer.id,
            peer: channel.peer,
            channel: channel,
            coordinator: coordinator,
            kind: kind,
            fingerprint: nil
        )
        slotTrustPolicies[slot.id] = trustPolicy
        slots.append(slot)

        Task { await coordinator.begin(role: .browser, mode: .friend) }
    }

    private func removeSlot(_ slot: PeerSlot) {
        Task { await slot.coordinator.cancel() }
        slots.removeAll { $0.id == slot.id }
        slotTrustPolicies.removeValue(forKey: slot.id)
    }

    private func onSlotConnected(at index: Int, identity peerIdentity: ProximityCoordinator.PeerIdentity) {
        let slot = slots[index]
        if currentMesh != nil {
            Task { [weak self] in
                guard let self else { return }
                await self.sendMeshDescriptor(to: slot)
                await self.syncPhotoManifest(to: slot)
            }
        }
        // If we have no mesh, wait for a descriptor from this peer
    }

    // MARK: - Mesh descriptor

    private func handleMeshDescriptor(_ descriptor: MeshDescriptor, from senderFingerprint: String?) {
        if let existing = currentMesh {
            mergeMeshDescriptor(existing, incoming: descriptor)
        } else {
            currentMesh = descriptor
        }
        let localFP = identity.localFingerprint
        if let mesh = currentMesh, !mesh.members.contains(where: { $0.fingerprint == localFP }) {
            sendAdmissionRequest(for: mesh)
        }
    }

    private func mergeMeshDescriptor(_ existing: MeshDescriptor, incoming: MeshDescriptor) {
        guard existing.meshID == incoming.meshID else { return }
        var merged = existing
        if incoming.nameSetAt > existing.nameSetAt {
            merged.name = incoming.name
            merged.nameSetAt = incoming.nameSetAt
            merged.nameSetBy = incoming.nameSetBy
        }
        if incoming.modeSetAt > existing.modeSetAt {
            merged.mode = incoming.mode
            merged.modeSetAt = incoming.modeSetAt
            merged.modeSetBy = incoming.modeSetBy
        }
        for member in incoming.members where !merged.members.contains(where: { $0.fingerprint == member.fingerprint }) {
            merged.members.append(member)
        }
        currentMesh = merged
    }

    private func broadcastMeshDescriptor() {
        guard let mesh = currentMesh else { return }
        let payload = MeshStateChangePayload(descriptor: mesh)
        for slot in slots {
            Task { [weak self] in await self?.sendEnvelope(.meshDescriptor, encodable: payload, via: slot) }
        }
        updateDiscoveryInfo()
    }

    private func sendMeshDescriptor(to slot: PeerSlot) async {
        guard let mesh = currentMesh else { return }
        await sendEnvelope(.meshDescriptor, encodable: MeshStateChangePayload(descriptor: mesh), via: slot)
    }

    // MARK: - Admission

    private func sendAdmissionRequest(for mesh: MeshDescriptor) {
        let request = MeshAdmissionRequestPayload(
            meshID: mesh.meshID,
            requesterFingerprint: identity.localFingerprint,
            requesterDisplayName: displayName,
            requesterSigningPublicKey: identity.localSigningPublicKey,
            requesterKeyAgreementPublicKey: identity.localKeyAgreementPublicKey
        )
        for slot in slots {
            Task { [weak self] in await self?.sendEnvelope(.meshAdmissionRequest, encodable: request, via: slot) }
        }
    }

    private func handleAdmissionRequest(_ request: MeshAdmissionRequestPayload) {
        guard let mesh = currentMesh, mesh.meshID == request.meshID else { return }
        guard !mesh.members.contains(where: { $0.fingerprint == request.requesterFingerprint }) else { return }
        if !pendingAdmissionRequests.contains(where: { $0.requesterFingerprint == request.requesterFingerprint }) {
            pendingAdmissionRequests.append(request)
        }
    }

    private func handleAdmissionGrant(_ grant: MeshAdmissionGrantPayload) {
        guard currentMesh == nil || currentMesh?.meshID == grant.meshID else { return }
        // Token verification; mesh descriptor broadcast by the admitter follows shortly
        _ = try? grant.token.verify()
    }

    // MARK: - Photo handling

    private func cachePhoto(_ photo: FriendPhotoPayload) {
        guard !meshPhotos.contains(where: { $0.id == photo.id }) else { return }
        meshPhotos.insert(photo, at: 0)
        meshPhotos = Array(meshPhotos.prefix(200))
        photoCacheStore.save(meshPhotos)
    }

    private func syncPhotoManifest(to slot: PeerSlot) async {
        let manifest = FriendPhotoManifestPayload(photoIDs: meshPhotos.map { $0.id })
        await sendEnvelope(.friendPhotoManifest, encodable: manifest, via: slot)
    }

    private func handlePhotoManifest(_ manifest: FriendPhotoManifestPayload, from slot: PeerSlot) {
        let haveIDs = Set(meshPhotos.map { $0.id })
        let missing = manifest.photoIDs.filter { !haveIDs.contains($0) }
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            await self?.sendEnvelope(.friendPhotoRequest, encodable: FriendPhotoRequestPayload(missingPhotoIDs: missing), via: slot)
        }
    }

    private func sendRequestedPhotos(_ ids: [UUID], to slot: PeerSlot) {
        let requested = meshPhotos.filter { ids.contains($0.id) }
        for photo in requested {
            Task { [weak self] in await self?.sendEnvelope(.friendPhoto, encodable: photo, via: slot) }
        }
    }

    // MARK: - Envelope sending

    private func sendEnvelope(_ type: PayloadType, encodable: some Encodable, via slot: PeerSlot) async {
        guard let payloadData = try? JSONEncoder().encode(encodable) else { return }
        guard let envelope = try? FernletIdentityEnvelope.signed(
            identityService: identity,
            senderDisplayName: displayName,
            recipientFingerprint: slot.fingerprint,
            payloadType: type,
            payloadSummary: PayloadSummary(title: type.rawValue),
            payload: payloadData
        ) else { return }
        guard let envelopeData = try? JSONEncoder().encode(envelope) else { return }
        try? await slot.channel.send(envelopeData, to: slot.peer, mode: .reliable)
    }

    // MARK: - Observation loop for coordinator state changes

    private func startObserving() {
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.slots.count
                        for slot in self.slots { _ = slot.coordinator.state }
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.checkCoordinatorStates()
            }
        }
    }

    private func checkCoordinatorStates() {
        for index in slots.indices {
            if case .connected(let peerIdentity) = slots[index].coordinator.state {
                let fp = peerIdentity.fingerprint
                if slots[index].fingerprint != fp {
                    slots[index].fingerprint = fp
                    onSlotConnected(at: index, identity: peerIdentity)
                }
            }
        }
    }
}
