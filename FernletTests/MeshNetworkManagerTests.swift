@testable import ProximityKit
import Testing
import UIKit
import MultipeerConnectivity
import FernletDomainModel
import ProximityKit
@testable import Fernlet

// MARK: - MeshNetworkManagerTests

// Each @Test function receives a fresh instance of this struct, so `store` is a
// new FernletStore per test. The stored property holds a strong reference that
// keeps the FernletStore alive for the entire test, preventing the `unowned let
// store` in MeshNetworkManager from becoming a dangling reference mid-test.
@Suite(.serialized) @MainActor
struct MeshNetworkManagerTests {
    let store = makeTestStore()

    // MARK: - Closed-mode discovery info

    /// An open mesh advertises meshID and meshName so nearby devices can see it.
    @Test func discoveryInfo_openMeshIncludesMeshIdentifiers() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh(name: "Sunrise Meadow", mode: .open)

        let info = manager.currentDiscoveryInfo()

        #expect(info["meshID"] != nil, "Open mesh must include meshID in discoveryInfo")
        #expect(info["meshName"] != nil, "Open mesh must include meshName in discoveryInfo")
        #expect(info["memberCount"] != nil, "Open mesh must include memberCount in discoveryInfo")
    }

    /// A closed mesh omits all mesh identifiers so it is invisible to non-members.
    @Test func discoveryInfo_closedMeshOmitsMeshIdentifiers() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh(name: "Secret Lair", mode: .closed)

        let info = manager.currentDiscoveryInfo()

        #expect(info["meshID"] == nil, "Closed mesh must not include meshID in discoveryInfo")
        #expect(info["meshName"] == nil, "Closed mesh must not include meshName in discoveryInfo")
        #expect(info["memberCount"] == nil, "Closed mesh must not leak memberCount in discoveryInfo")
    }

    /// Toggling from open to closed removes mesh identifiers from discoveryInfo.
    @Test func discoveryInfo_modeToggleUpdatesAdvertisedIdentifiers() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh(mode: .open)
        #expect(manager.currentDiscoveryInfo()["meshID"] != nil)

        manager.currentMesh = makeTestMesh(mode: .closed)
        #expect(manager.currentDiscoveryInfo()["meshID"] == nil,
                "discoveryInfo must omit meshID after switching to closed mode")
    }

    @Test func sessionAccess_pairwiseSessionCanCloseAndReopen() {
        let manager = MeshNetworkManager(store: store)

        manager.setSessionOpen(false)
        #expect(manager.isSessionOpen == false)
        #expect(manager.currentMesh == nil)

        manager.setSessionOpen(true)
        #expect(manager.isSessionOpen)
    }

    @Test func sessionAccess_meshToggleUpdatesDescriptorAndDiscoveryInfo() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh(mode: .open)

        manager.setSessionOpen(false)
        #expect(manager.isSessionOpen == false)
        #expect(manager.currentMesh?.mode == .closed)
        #expect(manager.currentDiscoveryInfo()["meshID"] == nil)

        manager.setSessionOpen(true)
        #expect(manager.isSessionOpen)
        #expect(manager.currentMesh?.mode == .open)
        #expect(manager.currentDiscoveryInfo()["meshID"] != nil)
    }

    @Test func sessionAccess_leaveMeshResetsOpenState() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh(mode: .open)
        manager.setSessionOpen(false)

        manager.leaveMesh()

        #expect(manager.isSessionOpen)
    }

    // MARK: - Per-sender send quota (film = 10 per session)

    /// The first 10 calls to addPhoto succeed; the 11th sets meshError.
    @Test func photoQuota_blocksEleventhPhoto() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()

        let imageData = makeTinyJPEG()
        for _ in 0..<10 {
            manager.addPhoto(imageData)
        }
        #expect(manager.meshError == nil,
                "First 10 photos should not set meshError")

        manager.addPhoto(imageData)
        #expect(manager.meshError != nil,
                "11th photo must set meshError — quota exceeded")
    }

    /// Regression for prior finding #6: in-session photos must hold metadata only, not
    /// full-resolution bytes (which previously accumulated in memory for the whole session
    /// and could be flooded into an OOM). The bytes live in the disk cache and rehydrate.
    @Test func sessionPhotos_holdMetadataOnlyNotRawBytes() throws {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()

        manager.addPhoto(makeTinyJPEG())

        let cached = try #require(manager.sessionPhotos.first)
        #expect(cached.imageData == nil,
                "Session photo must not retain raw image bytes in memory")
        // Display path (FriendPhotoReviewSheet tile loadImageData closure).
        #expect(manager.imageData(for: cached) != nil,
                "Full-resolution bytes remain available from the disk cache on demand")
        // Library-save path (ConnectView rehydrates the selected session photos before saving).
        let rehydrated = try #require(manager.hydratedPhotos([cached]).first)
        #expect(rehydrated.imageData != nil,
                "hydratedPhotos must repopulate bytes so the save flow does not silently save nothing")
    }

    /// After leaveMesh() the counter resets: the next mesh allows 10 new photos.
    @Test func photoQuota_resetsAfterLeaveMesh() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()

        let imageData = makeTinyJPEG()
        for _ in 0..<10 { manager.addPhoto(imageData) }

        manager.leaveMesh()
        manager.currentMesh = makeTestMesh()   // join a new mesh
        manager.meshError = nil                // clear any previous error

        manager.addPhoto(imageData)
        #expect(manager.meshError == nil,
                "Quota must reset after leaveMesh — first photo in new session should succeed")
    }

    /// Switching to a different mesh ID resets the counter without an explicit leave.
    @Test func photoQuota_resetsWhenMeshIDChanges() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh(name: "Mesh A")

        let imageData = makeTinyJPEG()
        for _ in 0..<10 { manager.addPhoto(imageData) }

        manager.currentMesh = makeTestMesh(name: "Mesh B")  // different UUID
        manager.meshError = nil

        manager.addPhoto(imageData)
        #expect(manager.meshError == nil,
                "Quota must reset when currentMesh changes to a new meshID")
    }

    /// Exactly 10 photos are allowed; error is set only on attempt 11.
    @Test func photoQuota_limitIsExactlyTen() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()
        let imageData = makeTinyJPEG()

        for i in 1...11 {
            manager.addPhoto(imageData)
            if i < 11 {
                #expect(manager.meshError == nil, "Photo \(i) should succeed")
            } else {
                #expect(manager.meshError != nil, "Photo 11 should fail")
            }
        }
    }

    /// filmRemaining starts at 10 and decrements with each photo.
    @Test func filmRemaining_decrementsWithEachPhoto() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()
        let imageData = makeTinyJPEG()

        #expect(manager.filmRemaining == 10, "Full roll should start at 10")
        manager.addPhoto(imageData)
        manager.addPhoto(imageData)
        #expect(manager.filmRemaining == 8, "Two shots used — 8 remaining")
    }

    /// filmRemaining resets to 10 after leaveSession.
    @Test func filmRemaining_resetsAfterLeaveSession() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()
        let imageData = makeTinyJPEG()
        for _ in 0..<5 { manager.addPhoto(imageData) }

        manager.leaveSession()
        manager.currentMesh = makeTestMesh()
        manager.meshError = nil
        #expect(manager.filmRemaining == 10, "Film should reset to 10 after leaveSession")
    }

    @Test func deleteAllSessionPhotosClearsCurrentRollFromAlbum() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()
        let existingAlbumIDs = Set(manager.meshPhotos.map(\.id))
        manager.addPhoto(makeTinyJPEG())
        let sessionPhotoID = manager.sessionPhotos[0].id

        #expect(manager.sessionPhotos.isEmpty == false)

        manager.deleteAllSessionPhotos()

        #expect(manager.meshPhotos.contains(where: { $0.id == sessionPhotoID }) == false)
        #expect(Set(manager.meshPhotos.map(\.id)).isSubset(of: existingAlbumIDs))
        #expect(manager.sessionPhotos.isEmpty)
    }

    @Test func finishSessionPhotosKeepsOnlySelectedCurrentRollPhotos() throws {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeTestMesh()
        let existingAlbumIDs = Set(manager.meshPhotos.map(\.id))
        manager.addPhoto(makeTinyJPEG())
        manager.addPhoto(makeTinyJPEG())
        let keptID = try #require(manager.sessionPhotos.first?.id)
        let discardedID = try #require(manager.sessionPhotos.dropFirst().first?.id)

        manager.finishSessionPhotos(keeping: [keptID])

        #expect(manager.meshPhotos.contains(where: { $0.id == keptID }))
        #expect(manager.meshPhotos.contains(where: { $0.id == discardedID }) == false)
        #expect(Set(manager.meshPhotos.map(\.id)).isSubset(of: existingAlbumIDs.union([keptID])))
        #expect(manager.sessionPhotos.isEmpty)
    }

    // MARK: - Phase 1: payload handler registry

    /// A coordinator the dispatch tests can hand to `proximityCoordinator(_:didReceive:...)` —
    /// the manager only identity-compares it against its slots (mirrors FriendShopTests).
    /// Deliberately NOT provisioned: the coordinator's init never touches the keychain, and
    /// provisioning here would orphan keys under a never-reused UUID service on every run.
    private func throwawayCoordinator() -> ProximityCoordinator {
        let identity = IdentityService(keychainService: "test.mesh.registry.\(UUID().uuidString)")
        return ProximityCoordinator(
            identity: identity,
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    /// A transport peer for `addSlotForTesting` — a non-nil fingerprint on the slot models a
    /// COMMITTED (post-dwell) session member, nil a pre-commit candidate.
    private func makePeer(name: String) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: name)
        )
    }

    /// An inbound envelope shell — `proximityCoordinator(_:didReceive:...)` receives
    /// post-verification envelopes, so dummy keys/signature are fine here.
    private func inboundEnvelope(payloadType: PayloadType, plaintext: Data) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: "Peer",
            recipientFingerprint: nil,
            payloadType: payloadType,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Test"),
            payload: plaintext,
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
    }

    /// A known type outside the core mesh switch dispatches to its registered handler with the
    /// same (envelope, plaintext, peer) the core cases consume — from a COMMITTED slot (the
    /// Phase-3a registry commit gate; feature payloads are for session members only).
    @Test func registry_registeredHandlerReceivesNonCorePayload() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Peer"), fingerprint: "fp-peer")
        let plaintext = Data("feature payload".utf8)
        let envelope = inboundEnvelope(payloadType: .trainerPlan, plaintext: plaintext)
        var received: (PayloadType?, Data)?
        manager.registerPayloadHandler(for: .trainerPlan) { envelope, plaintext, _ in
            received = (envelope.payloadType, plaintext)
        }

        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: nil)

        #expect(received?.0 == .trainerPlan)
        #expect(received?.1 == plaintext)
    }

    /// Phase 3a hardening — the registry commit gate is the security boundary: the coordinator
    /// dispatches known non-core payloads with `connectedIdentity ?? pendingPeerIdentity` and no
    /// state gate, so a pre-dwell (uncommitted) slot and a coordinator that never became a slot
    /// must both be dropped before any registered handler runs.
    @Test func registry_uncommittedSlotAndSlotlessCoordinatorNeverReachHandlers() {
        let manager = MeshNetworkManager(store: store)
        var handlerCalled = false
        manager.registerPayloadHandler(for: .trainerPlan) { _, _, _ in handlerCalled = true }
        let envelope = inboundEnvelope(payloadType: .trainerPlan, plaintext: Data())

        // No slot for this coordinator at all.
        manager.proximityCoordinator(throwawayCoordinator(), didReceive: envelope, plaintext: Data(), from: nil)
        #expect(handlerCalled == false, "A slotless coordinator must never reach a feature handler")

        // A slot exists but is UNCOMMITTED (pre-dwell: fingerprint nil).
        let pending = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: pending, peer: makePeer(name: "Pending"), fingerprint: nil)
        manager.proximityCoordinator(pending, didReceive: envelope, plaintext: Data(), from: nil)
        #expect(handlerCalled == false, "An uncommitted slot must never reach a feature handler")
    }

    /// An unregistered non-core type keeps the pre-registry silent drop — a handler registered
    /// for a DIFFERENT type is not consulted.
    @Test func registry_unregisteredKnownTypeStillDropsSilently() {
        let manager = MeshNetworkManager(store: store)
        var handlerCalled = false
        manager.registerPayloadHandler(for: .trainerPlan) { _, _, _ in handlerCalled = true }

        // Committed slot so the drop is a registry miss, not the Phase-3a commit gate.
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Peer"), fingerprint: "fp-peer")
        let envelope = inboundEnvelope(payloadType: .trainerPlanDelta, plaintext: Data())
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: Data(), from: nil)

        #expect(handlerCalled == false)
    }

    /// Core mesh-control types dispatch through the switch FIRST — a registration for a core type
    /// can never shadow (or double-handle) mesh-control processing.
    @Test func registry_coreMeshTypeIsNotRoutedToRegisteredHandler() {
        let manager = MeshNetworkManager(store: store)
        var handlerCalled = false
        manager.registerPayloadHandler(for: .meshDescriptor) { _, _, _ in handlerCalled = true }

        // Committed slot so the non-dispatch is core-switch precedence, not the commit gate.
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Peer"), fingerprint: "fp-peer")
        let envelope = inboundEnvelope(payloadType: .meshDescriptor, plaintext: Data("not json".utf8))
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: Data("not json".utf8), from: nil)

        #expect(handlerCalled == false)
    }

    /// Belt-and-braces: an unknown-token envelope handed straight to the manager (the coordinator
    /// parks these upstream) is dropped before the switch — no handler runs, no state changes.
    @Test func registry_unknownPayloadTypeNeverDispatches() {
        let manager = MeshNetworkManager(store: store)
        var handlerCalled = false
        manager.registerPayloadHandler(for: .trainerPlan) { _, _, _ in handlerCalled = true }

        let unknown = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: "Peer",
            recipientFingerprint: nil,
            payloadTypeToken: "fernlet.future.sparkle.v1",
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Future"),
            payload: Data(),
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
        manager.proximityCoordinator(throwawayCoordinator(), didReceive: unknown, plaintext: Data(), from: nil)

        #expect(handlerCalled == false)
        #expect(manager.currentMesh == nil)
        #expect(manager.meshError == nil)
    }

    // MARK: - Invite tie-break

    /// The core property: both peers browse AND advertise, so both discover each other, and
    /// EXACTLY ONE must send the MC invitation. Zero invitations strands the pair forever (the
    /// shipped bug); two invitations race and fail one side with errno 61.
    @Test func shouldInitiateInvite_exactlyOneSideOfAPairInvites() {
        let managerA = MeshNetworkManager(store: store)
        let managerB = MeshNetworkManager(store: store)

        let aInvitesB = managerA.shouldInitiateInvite(to: peerRepresenting(managerB))
        let bInvitesA = managerB.shouldInitiateInvite(to: peerRepresenting(managerA))

        #expect(aInvitesB != bInvitesA,
                "Exactly one side of a discovered pair must initiate — got A:\(aInvitesB) B:\(bInvitesA)")
    }

    /// Regression for the mesh-wide deadlock: the tie-break used to compare our 16-char lowercase
    /// hex fingerprint against the PEER'S display name. iOS 16+ reports `UIDevice.current.name` as
    /// the generic "iPhone" without the user-assigned-device-name entitlement, and every hex
    /// fingerprint sorts below "iPhone" ("f" < "i"), so the guard was false on both devices and
    /// `invite` was unreachable. The decision must not consult displayName at all.
    @Test func shouldInitiateInvite_isNotDefeatedByGenericDeviceName() {
        let manager = MeshNetworkManager(store: store)
        let localSessionID = manager.currentDiscoveryInfo()["sid"]!

        // A peer that sorts BELOW us, presenting the generic iOS 16+ device name. The all-zeros
        // UUID is lower than any generated one (v4 puts a "4" in the version nibble, so a real
        // sid can never be all zeros) and is unambiguous about case, unlike a "0"-prefix trick:
        // `UUID().uuidString` is UPPERCASE hex, so its first character ranges over [0-9A-F].
        let lowerPeer = makePeer(displayName: "iPhone", sessionID: "00000000-0000-0000-0000-000000000000")
        #expect(localSessionID > "00000000-0000-0000-0000-000000000000", "test premise")

        #expect(manager.shouldInitiateInvite(to: lowerPeer),
                "A lower-sorting peer must be invited regardless of its display name")
    }

    /// Never deadlock on a peer we cannot rank. A redundant invite is recoverable (errno 61 plus
    /// the disconnect-retry path); mutual silence is not.
    @Test func shouldInitiateInvite_defaultsToInvitingWhenPeerIsUnrankable() {
        let manager = MeshNetworkManager(store: store)

        #expect(manager.shouldInitiateInvite(to: makePeer(displayName: "iPhone", sessionID: nil)))
        #expect(manager.shouldInitiateInvite(to: makePeer(displayName: "iPhone", sessionID: "")))
    }

    /// Builds the `MultipeerPeer` the OTHER manager would appear as, carrying the discovery info
    /// it actually broadcasts — so the tie-break is exercised on real wire values.
    private func peerRepresenting(_ manager: MeshNetworkManager) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: "iPhone",
            discoveryInfo: manager.currentDiscoveryInfo(),
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: "iPhone")
        )
    }

    private func makePeer(displayName: String, sessionID: String?) -> MultipeerPeer {
        var info: [String: String] = ["v": "1", "name": displayName]
        if let sessionID { info["sid"] = sessionID }
        return MultipeerPeer(
            id: UUID(),
            displayName: displayName,
            discoveryInfo: info,
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: displayName)
        )
    }
}

// MARK: - Helpers

@MainActor
private func makeTestMesh(name: String = "Test Mesh", mode: MeshMode = .open) -> MeshDescriptor {
    let now = Date()
    let fp = "test-host-fp"
    return MeshDescriptor(
        meshID: UUID(),
        name: name,
        mode: mode,
        members: [],
        nameSetAt: now,
        nameSetBy: fp,
        modeSetAt: now,
        modeSetBy: fp,
        createdAt: now
    )
}

@MainActor
private func makeTinyJPEG() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
    let image = renderer.image { ctx in
        UIColor.systemBlue.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return image.jpegData(compressionQuality: 0.5)!
}
