import ProximityKit
import Testing
import UIKit
import FernletDomainModel
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
    /// same (envelope, plaintext, peer) the core cases consume.
    @Test func registry_registeredHandlerReceivesNonCorePayload() {
        let manager = MeshNetworkManager(store: store)
        let plaintext = Data("feature payload".utf8)
        let envelope = inboundEnvelope(payloadType: .trainerPlan, plaintext: plaintext)
        var received: (PayloadType?, Data)?
        manager.registerPayloadHandler(for: .trainerPlan) { envelope, plaintext, _ in
            received = (envelope.payloadType, plaintext)
        }

        manager.proximityCoordinator(throwawayCoordinator(), didReceive: envelope, plaintext: plaintext, from: nil)

        #expect(received?.0 == .trainerPlan)
        #expect(received?.1 == plaintext)
    }

    /// An unregistered non-core type keeps the pre-registry silent drop — a handler registered
    /// for a DIFFERENT type is not consulted.
    @Test func registry_unregisteredKnownTypeStillDropsSilently() {
        let manager = MeshNetworkManager(store: store)
        var handlerCalled = false
        manager.registerPayloadHandler(for: .trainerPlan) { _, _, _ in handlerCalled = true }

        let envelope = inboundEnvelope(payloadType: .trainerPlanDelta, plaintext: Data())
        manager.proximityCoordinator(throwawayCoordinator(), didReceive: envelope, plaintext: Data(), from: nil)

        #expect(handlerCalled == false)
    }

    /// Core mesh-control types dispatch through the switch FIRST — a registration for a core type
    /// can never shadow (or double-handle) mesh-control processing.
    @Test func registry_coreMeshTypeIsNotRoutedToRegisteredHandler() {
        let manager = MeshNetworkManager(store: store)
        var handlerCalled = false
        manager.registerPayloadHandler(for: .meshDescriptor) { _, _, _ in handlerCalled = true }

        let envelope = inboundEnvelope(payloadType: .meshDescriptor, plaintext: Data("not json".utf8))
        manager.proximityCoordinator(throwawayCoordinator(), didReceive: envelope, plaintext: Data("not json".utf8), from: nil)

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
