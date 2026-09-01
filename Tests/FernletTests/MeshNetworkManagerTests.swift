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

    /// Identifier hygiene (L29): the friend radio's cleartext Bonjour TXT must never carry the
    /// user's proximity display name. `sid` is a per-launch random UUID (unlinkable); a display
    /// name is stable across launches and locations, so a passive scanner could link sightings of
    /// one person. A peer learns our name only from the signed identity introduction.
    @Test func discoveryInfo_neverAdvertisesTheDisplayName() {
        store.settings.proximityDisplayName = "Alexandra Quimby"
        let manager = MeshNetworkManager(store: store)

        #expect(Set(manager.currentDiscoveryInfo().keys) == ["v", "sid"],
                "Pairwise advertisement must be version + session id only")

        manager.currentMesh = makeTestMesh(name: "Sunrise Meadow", mode: .open)
        let open = manager.currentDiscoveryInfo()
        #expect(Set(open.keys) == ["v", "sid", "meshID", "meshName", "memberCount"],
                "Open mesh adds only the mesh identifiers — still no display name")
        #expect(!open.values.contains { $0.contains("Alexandra") },
                "No advertised value may contain the user's display name")
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

    /// The friend photo wall follows its store's `proximitySupportDirectory`, not the process.
    ///
    /// The wall's index is re-saved WHOLE on every keep/delete and re-read by every manager at init,
    /// so while the root was a hardcoded `Application Support/Fernlet` path a manager built in one
    /// suite inherited — and then overwrote — the album of every concurrently-live one. (The
    /// `existingAlbumIDs` subset assertions in the two tests above are the scar tissue from that:
    /// they had to tolerate photos this suite never took.) This is the same defect as the own-photo
    /// corpora one root over, and it is pinned the same way.
    ///
    /// The third store is the half that makes this a real test: without it, deleting the wall's
    /// persistence entirely would still pass.
    @Test func theFriendPhotoWallIsIsolatedPerStoreRoot() throws {
        let sharedRoot = uniqueProximityDirectory()
        let storeA = makeTestStore(proximitySupportDirectory: sharedRoot)
        let storeB = makeTestStore()
        let storeC = makeTestStore(proximitySupportDirectory: sharedRoot)

        try withExtendedLifetime((storeA, storeB, storeC)) {
            let managerA = MeshNetworkManager(store: storeA)
            managerA.currentMesh = makeTestMesh()
            managerA.addPhoto(makeTinyJPEG())
            let keptID = try #require(managerA.sessionPhotos.first?.id)
            managerA.finishSessionPhotos(keeping: [keptID])
            #expect(managerA.meshPhotos.contains(where: { $0.id == keptID }))

            // A store on its OWN root sees nothing of A's wall.
            let managerB = MeshNetworkManager(store: storeB)
            #expect(
                managerB.meshPhotos.isEmpty,
                "a store on its own proximity root must start with an empty wall, not another store's album"
            )

            // ...but one on the SAME root does — so the isolation above is the root doing the work,
            // not the wall having quietly stopped persisting.
            let managerC = MeshNetworkManager(store: storeC)
            #expect(
                managerC.meshPhotos.contains(where: { $0.id == keptID }),
                "a store sharing the proximity root must still load the wall persisted under it"
            )
        }
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
    ///
    /// `endpoint` defaults to a fresh key, so two calls are two devices. Passing the same key twice
    /// is the only way to express "one device, two discovery handles" — see `makeReturningDevice`.
    private func makePeer(name: String, endpoint: PeerEndpointKey = PeerEndpointKey()) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            endpoint: endpoint
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

    // MARK: - Committed-slot gate: photos and descriptors (M5)

    /// M5: the friend-photo family reaches the PERSISTENT wall, so it is member business. The
    /// coordinator dispatches with `connectedIdentity ?? pendingPeerIdentity`, so without a
    /// committed-slot gate a peer that has only introduced itself can write the wall.
    @Test func preCommitFriendPhotoIsDropped() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Pending"), fingerprint: nil)

        let payload = makePhotoPayload(author: authorIdentity)
        let plaintext = try! JSONEncoder().encode(payload)
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .friendPhoto, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: peerIdentity(for: authorIdentity))

        #expect(manager.meshPhotos.isEmpty, "An uncommitted slot must never reach the photo wall")
    }

    /// The positive control for the gate above — over-tightening must fail loudly.
    @Test func committedSlotFriendPhotoIsCached() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        let author = authorIdentity
        let fingerprint = IdentityService.fingerprint(of: author.localSigningPublicKey)
        manager.addSlotForTesting(coordinator: coordinator,
                                  peer: makePeer(name: "Committed"),
                                  fingerprint: fingerprint)

        let payload = makePhotoPayload(author: author)
        let plaintext = try! JSONEncoder().encode(payload)
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .friendPhoto, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: peerIdentity(for: author))

        #expect(manager.meshPhotos.contains { $0.id == payload.id },
                "A committed slot's own photo must still reach the wall")
    }

    /// M5: a descriptor adopts a whole mesh identity, so it too requires a committed slot.
    @Test func preCommitMeshDescriptorIsNotAdopted() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Pending"), fingerprint: nil)

        let plaintext = try! JSONEncoder().encode(MeshStateChangePayload(descriptor: makeTestMesh(mode: .open)))
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .meshDescriptor, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: nil)

        #expect(manager.currentMesh == nil, "An uncommitted slot must not be able to hand us a mesh")
    }

    /// The positive control for the descriptor gate — a joiner that never adopts a descriptor
    /// never sends an admission request, so over-tightening this breaks every join.
    @Test func committedSlotMeshDescriptorIsAdopted() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Committed"), fingerprint: "fp-peer")

        let mesh = makeTestMesh(name: "Sunrise Meadow", mode: .open)
        let plaintext = try! JSONEncoder().encode(MeshStateChangePayload(descriptor: mesh))
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .meshDescriptor, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: nil)

        #expect(manager.currentMesh?.meshID == mesh.meshID, "A committed slot's descriptor must still be adopted")
    }

    // MARK: - Peer display-name sanitisation (M15)

    /// M15: `requesterDisplayName` is peer-supplied and reaches the ADMISSION PROMPT — the one
    /// screen where the user decides to admit a stranger. Sanitize at ingest so neither the prompt
    /// nor the admitter's roster can be spoofed by a zero-width homoglyph or reversed by an RLO.
    @Test func admissionRequestDisplayNameIsSanitizedBeforeItReachesThePrompt() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        let requester = makeAdmitter()
        let requesterFP = IdentityService.fingerprint(of: requester.localSigningPublicKey)
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Requester"), fingerprint: requesterFP)
        manager.currentMesh = makeTestMesh(mode: .open)

        deliverAdmissionRequest(named: "Ma\u{200B}ya", from: requester, to: manager,
                                on: coordinator, meshID: manager.currentMesh!.meshID)
        #expect(manager.pendingAdmissionRequests.first?.requesterDisplayName == "Maya",
                "A zero-width joiner must be stripped before the prompt renders the name")

        manager.pendingAdmissionRequests.removeAll()
        deliverAdmissionRequest(named: String(repeating: "A", count: 10_000), from: requester, to: manager,
                                on: coordinator, meshID: manager.currentMesh!.meshID)
        #expect((manager.pendingAdmissionRequests.first?.requesterDisplayName.count ?? 0) <= 24,
                "A multi-kilobyte name must be capped, not queued whole")
    }

    /// `allowAdmission` is `public` and takes an arbitrary payload, so it must not depend on the
    /// queue's copy having been sanitized. (`moderatedPeerDisplayName` is idempotent.)
    @Test func allowAdmissionStoresASanitizedMemberName() {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeTestMesh(mode: .open)
        manager.currentMesh = mesh
        let requester = makeAdmitter()

        manager.allowAdmission(MeshAdmissionRequestPayload(
            meshID: mesh.meshID,
            requesterFingerprint: IdentityService.fingerprint(of: requester.localSigningPublicKey),
            requesterDisplayName: "Ma\u{200B}ya" + String(repeating: "!", count: 100),
            requesterSigningPublicKey: requester.localSigningPublicKey,
            requesterKeyAgreementPublicKey: requester.localKeyAgreementPublicKey))

        let name = manager.currentMesh?.members.last?.displayName ?? ""
        #expect(!name.unicodeScalars.contains { $0.value == 0x200B }, "No zero-width scalar may survive")
        #expect(name.count <= 24, "The stored member name must be capped")
    }

    /// `recordSessionParticipant` is the SINGLE roster ingest, so coercing there covers both the
    /// verified-identity caller and `promoteToMesh`'s raw MC transport name.
    @Test func sessionRosterNamesAreSanitizedAtTheSingleIngest() {
        let manager = MeshNetworkManager(store: store)
        let peer = makeAdmitter()

        manager.recordSessionParticipant(
            displayName: "Ma\u{200B}ya",
            fingerprint: "fp-roster",
            signingPublicKey: peer.localSigningPublicKey,
            keyAgreementPublicKey: peer.localKeyAgreementPublicKey)

        #expect(manager.sessionRoster.first?.displayName == "Maya")
    }

    private func deliverAdmissionRequest(
        named name: String,
        from requester: IdentityService,
        to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator,
        meshID: UUID
    ) {
        let request = MeshAdmissionRequestPayload(
            meshID: meshID,
            requesterFingerprint: IdentityService.fingerprint(of: requester.localSigningPublicKey),
            requesterDisplayName: name,
            requesterSigningPublicKey: requester.localSigningPublicKey,
            requesterKeyAgreementPublicKey: requester.localKeyAgreementPublicKey)
        let plaintext = try! JSONEncoder().encode(request)
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .meshAdmissionRequest, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: peerIdentity(for: requester))
    }

    // MARK: - Admission-grant authorization (H2)

    /// H2: `MeshAdmissionToken` is rooted in the admitter key carried INSIDE it, so a self-signed
    /// token from a total stranger verifies. Without the authorization guards, that stranger's
    /// grant hands us a group key and a joined epoch.
    @Test func selfSignedAdmissionGrantFromNonMemberIsRejected() throws {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Stranger"), fingerprint: "fp-stranger")

        let stranger = makeAdmitter()
        let meshID = UUID()
        let grant = try makeGrant(meshID: meshID, admitter: stranger, manager: manager, epoch: 5)
        deliverGrant(grant, to: manager, on: coordinator, sender: stranger)

        #expect(manager.currentGroupKey == nil, "A grant we never asked for must not install a group key")
        #expect(manager.localJoinedEpoch == 0, "…nor move the joined epoch")
    }

    /// Even a genuine member's grant is only ever the answer to a request WE sent on THAT slot.
    @Test func unsolicitedAdmissionGrantIsRejected() throws {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Member"), fingerprint: "fp-member")

        let admitter = makeAdmitter()
        let mesh = makeMesh(with: admitter)
        manager.currentMesh = mesh        // adopted directly: no admission request was ever sent

        let grant = try makeGrant(meshID: mesh.meshID, admitter: admitter, manager: manager, epoch: 5)
        deliverGrant(grant, to: manager, on: coordinator, sender: admitter)

        #expect(manager.currentGroupKey == nil, "An unsolicited grant must be dropped even from a member")
    }

    /// The positive control: descriptor → request → grant is the real join flow, and it must
    /// still work end to end. This is the test that catches an over-tightened guard.
    @Test func solicitedAdmissionGrantFromMemberIsAccepted() throws {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Member"), fingerprint: "fp-member")

        let admitter = makeAdmitter()
        let mesh = makeMesh(with: admitter)
        deliverDescriptor(mesh, to: manager, on: coordinator)
        #expect(manager.currentMesh?.meshID == mesh.meshID, "precondition: descriptor adopted, request sent")

        let grant = try makeGrant(meshID: mesh.meshID, admitter: admitter, manager: manager, epoch: 5)
        deliverGrant(grant, to: manager, on: coordinator, sender: admitter)

        #expect(manager.currentGroupKey?.epoch == 5, "The real join flow must still install the group key")
        #expect(manager.localJoinedEpoch == 5)
    }

    /// Epochs only move forward — a replayed grant must not roll a joined member back onto a
    /// retired key, exactly as `handleKeyRotation` requires.
    @Test func admissionGrantWithStaleEpochIsRejected() throws {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Member"), fingerprint: "fp-member")

        let admitter = makeAdmitter()
        let mesh = makeMesh(with: admitter)
        deliverDescriptor(mesh, to: manager, on: coordinator)
        deliverGrant(try makeGrant(meshID: mesh.meshID, admitter: admitter, manager: manager, epoch: 5),
                     to: manager, on: coordinator, sender: admitter)
        let established = manager.currentGroupKey
        #expect(established?.epoch == 5, "precondition: epoch 5 established")

        // Re-solicit (the grant above spent the outstanding request), then replay an older epoch.
        deliverDescriptor(mesh, to: manager, on: coordinator)
        deliverGrant(try makeGrant(meshID: mesh.meshID, admitter: admitter, manager: manager, epoch: 3),
                     to: manager, on: coordinator, sender: admitter)

        #expect(manager.currentGroupKey?.epoch == 5, "The epoch-5 key must survive a stale grant")
        #expect(manager.currentGroupKey?.keyBytes == established?.keyBytes)
        #expect(manager.localJoinedEpoch == 5)
    }

    // MARK: - Admission-grant fixtures

    private func makeAdmitter() -> IdentityService {
        let identity = IdentityService(keychainService: "test.mesh.admitter.\(UUID().uuidString)")
        try? identity.ensureProvisioned()
        return identity
    }

    private func makeMesh(with admitter: IdentityService) -> MeshDescriptor {
        let now = Date()
        let member = MeshMember(
            fingerprint: IdentityService.fingerprint(of: admitter.localSigningPublicKey),
            displayName: "Admitter",
            signingPublicKey: admitter.localSigningPublicKey,
            keyAgreementPublicKey: admitter.localKeyAgreementPublicKey,
            joinedAt: now)
        return MeshDescriptor(meshID: UUID(), name: "Joinable", mode: .open, members: [member],
                              nameSetAt: now, nameSetBy: member.fingerprint,
                              modeSetAt: now, modeSetBy: member.fingerprint, createdAt: now)
    }

    private func makeGrant(
        meshID: UUID,
        admitter: IdentityService,
        manager: MeshNetworkManager,
        epoch: Int
    ) throws -> MeshAdmissionGrantPayload {
        let token = try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: manager.localFingerprint,
            joinerSigningPublicKey: manager.localSigningPublicKey,
            admitterIdentity: admitter)
        var keyBytes = Data(count: 32)
        keyBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let bundle = try admitter.encryptGroupKey(keyBytes, for: manager.localKeyAgreementPublicKey)
        return MeshAdmissionGrantPayload(meshID: meshID,
                                         requesterFingerprint: manager.localFingerprint,
                                         token: token,
                                         encryptedCurrentKey: bundle,
                                         currentKeyEpoch: epoch)
    }

    private func deliverDescriptor(_ mesh: MeshDescriptor, to manager: MeshNetworkManager, on coordinator: ProximityCoordinator) {
        let plaintext = try! JSONEncoder().encode(MeshStateChangePayload(descriptor: mesh))
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .meshDescriptor, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: nil)
    }

    private func deliverGrant(
        _ grant: MeshAdmissionGrantPayload,
        to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator,
        sender: IdentityService
    ) {
        let plaintext = try! JSONEncoder().encode(grant)
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .meshAdmissionGrant, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: peerIdentity(for: sender))
    }

    // MARK: - Photo author binding (M6)

    /// The envelope signature authenticates only the RELAYER; the author fields are an unsigned
    /// claim. A photo with no claim at all is un-attributable — it can be neither blocked nor
    /// honestly displayed — so it is rejected rather than displayed under the relayer's name.
    @Test func photoWithNilSenderFingerprintIsRejected() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Relayer"), fingerprint: "fp-relayer")

        let payload = FriendPhotoPayload(imageData: makeTinyJPEG(), senderName: "Mallory",
                                         senderFingerprint: nil, senderSigningPublicKey: nil)
        deliverPhoto(payload, to: manager, on: coordinator, relayer: "fp-relayer")

        #expect(manager.meshPhotos.isEmpty, "An un-attributable photo must never reach the wall")
    }

    /// A relayer must not be able to launder a blocked peer's photo by claiming it for them.
    @Test func photoClaimingABlockedAuthorIsRejected() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Relayer"), fingerprint: "fp-relayer")

        let author = authorIdentity
        store.proximityTrustVault.block(signingPublicKey: author.localSigningPublicKey)

        deliverPhoto(makePhotoPayload(author: author), to: manager, on: coordinator, relayer: "fp-relayer")

        #expect(manager.meshPhotos.isEmpty, "A photo claiming a blocked author must be dropped")
    }

    /// The claim has to be internally consistent, or the block list keys on nothing: the claimed
    /// fingerprint must be the hash of the claimed signing key.
    @Test func photoWhoseClaimedKeyDoesNotHashToItsFingerprintIsRejected() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Relayer"), fingerprint: "fp-relayer")

        let payload = FriendPhotoPayload(imageData: makeTinyJPEG(), senderName: "Mallory",
                                         senderFingerprint: "fp-relayer",
                                         senderSigningPublicKey: authorIdentity.localSigningPublicKey)
        deliverPhoto(payload, to: manager, on: coordinator, relayer: "fp-relayer")

        #expect(manager.meshPhotos.isEmpty, "A fingerprint that does not hash from the claimed key is a forged claim")
    }

    /// A well-formed claim about somebody this session has never heard of is still a claim about
    /// a stranger — there is nothing to attribute it to.
    @Test func photoClaimingAnUnknownAuthorIsRejected() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Relayer"), fingerprint: "fp-relayer")

        deliverPhoto(makePhotoPayload(author: authorIdentity), to: manager, on: coordinator, relayer: "fp-relayer")

        #expect(manager.meshPhotos.isEmpty, "An author absent from the mesh, roster and manifests is unknown")
    }

    /// The relay positive control: A's photo relayed by B is cached WITH A's original attribution,
    /// once A is a roster participant. Stamping the relayer over the fields would be a correctness
    /// regression on the wall, not a fix.
    @Test func relayedPhotoFromAKnownMeshMemberIsCachedWithItsOriginalAttribution() {
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeer(name: "Relayer"), fingerprint: "fp-relayer")

        let author = authorIdentity
        let authorFP = IdentityService.fingerprint(of: author.localSigningPublicKey)
        manager.recordSessionParticipant(displayName: "Author",
                                         fingerprint: authorFP,
                                         signingPublicKey: author.localSigningPublicKey,
                                         keyAgreementPublicKey: author.localKeyAgreementPublicKey)

        let payload = makePhotoPayload(author: author)
        deliverPhoto(payload, to: manager, on: coordinator, relayer: "fp-relayer")

        let cached = manager.meshPhotos.first { $0.id == payload.id }
        #expect(cached != nil, "A relayed photo from a known author must still reach the wall")
        #expect(cached?.senderFingerprint == authorFP,
                "The relay must keep the AUTHOR's attribution, not the relayer's")
    }

    // MARK: - Photo/author test fixtures

    /// A throwaway signing identity used as a photo AUTHOR. Not provisioned through the app's
    /// keychain service, so it leaves nothing behind.
    private var authorIdentity: IdentityService {
        let identity = IdentityService(keychainService: "test.mesh.photoauthor.shared")
        try? identity.ensureProvisioned()
        return identity
    }

    private func peerIdentity(for identity: IdentityService) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Author",
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: IdentityService.fingerprint(of: identity.localSigningPublicKey),
            rangingMode: .rssi,
            firstSeenAt: Date()
        )
    }

    private func makePhotoPayload(author: IdentityService) -> FriendPhotoPayload {
        FriendPhotoPayload(
            imageData: makeTinyJPEG(),
            senderName: "Author",
            senderFingerprint: IdentityService.fingerprint(of: author.localSigningPublicKey),
            senderSigningPublicKey: author.localSigningPublicKey
        )
    }

    private func deliverPhoto(
        _ payload: FriendPhotoPayload,
        to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator,
        relayer: String
    ) {
        let plaintext = try! JSONEncoder().encode(payload)
        let relayerIdentity = ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "Relayer",
            signingPublicKey: Data([0xAA]), keyAgreementPublicKey: Data([0xBB]),
            fingerprint: relayer, rangingMode: .rssi, firstSeenAt: Date())
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(payloadType: .friendPhoto, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: relayerIdentity)
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

    /// Builds the `PeerHandle` the OTHER manager would appear as, carrying the discovery info
    /// it actually broadcasts — so the tie-break is exercised on real wire values.
    private func peerRepresenting(_ manager: MeshNetworkManager) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: "iPhone",
            discoveryInfo: manager.currentDiscoveryInfo(),
            advertisedFingerprint: nil
        )
    }

    private func makePeer(displayName: String, sessionID: String?) -> PeerHandle {
        var info: [String: String] = ["v": "1", "name": displayName]
        if let sessionID { info["sid"] = sessionID }
        return PeerHandle(
            id: UUID(),
            displayHint: displayName,
            discoveryInfo: info,
            advertisedFingerprint: nil
        )
    }

    // MARK: - Identity asymmetries (plan §6.4 findings 1–2, closed with the §6.5 root fix)

    /// One device seen twice under different discovery handles.
    ///
    /// §6.5 made `PeerHandle.id` stable for the life of a transport session, so the transport no
    /// longer produces this pair casually — but it still produces it: the identity map is bounded
    /// (a very old endpoint ages out), a `stop()`/`start()` re-mints deliberately, and the next
    /// transport is free to key identity differently. The gates below are the ones that must
    /// absorb it, and each of them used to compare `id` alone while the disconnect path two lines
    /// away compared endpoints.
    private func makeReturningDevice(named name: String) -> (first: PeerHandle, again: PeerHandle) {
        let endpoint = PeerEndpointKey(UUID())
        return (makePeer(name: name, endpoint: endpoint), makePeer(name: name, endpoint: endpoint))
    }

    /// §6.4 finding 1, mesh half (`MeshNetworkManager` :2051). `shouldAcceptInvitation` admits a
    /// returning device by the endpoint test; the seat gate compared `id`, so the same device was
    /// admitted once and then *appended a second time* — breaking the slot cap from the inside,
    /// with two coordinators, two ranging sessions and two Live Activity anchors for one peer.
    @Test func channelAdmission_returningDeviceIsRecognizedAsAlreadySeated() {
        let manager = MeshNetworkManager(store: store)
        let robin = makeReturningDevice(named: "Robin")
        manager.addSlotForTesting(coordinator: throwawayCoordinator(), peer: robin.first, fingerprint: nil)

        #expect(manager.channelAdmission(for: robin.again) == .alreadySeated,
                "a device that already holds a slot must never be seated twice")
        #expect(manager.channelAdmission(for: makePeer(name: "Stranger")) == .seat,
                "control: a genuinely new device is still seated")
    }

    /// The other two arms of the same decision, pinned so the extraction cannot quietly lose them:
    /// a closed proximity-join session and a session already at the overflow ceiling both kick,
    /// because a connected peer with no slot holds a zombie MC link until the search stops.
    @Test func channelAdmission_kicksWhatItWillNotSeat() {
        let manager = MeshNetworkManager(store: store)
        manager.markProximityJoinForTesting()
        manager.setSessionOpen(false)

        #expect(manager.channelAdmission(for: makePeer(name: "Stranger")) == .kick)

        manager.setSessionOpen(true)
        for index in 0..<6 {
            manager.addSlotForTesting(
                coordinator: throwawayCoordinator(),
                peer: makePeer(name: "Seated \(index)"),
                fingerprint: "fp-\(index)"
            )
        }
        #expect(manager.channelAdmission(for: makePeer(name: "Stranger")) == .kick,
                "at the overflow ceiling there is no seat to give")
    }

    /// §6.4 finding 1, overflow half (`MeshNetworkManager` :2548). A full mesh may evaluate ONE
    /// temporary candidate above the cap. Keyed on `id`, a device that already held a lightweight
    /// slot and came back under a new handle qualified as its own overflow candidate — a second
    /// seat for one device at the exact moment the session is over capacity.
    @Test func overflowCandidate_returningDeviceIsRefusedBySlotItAlreadyHolds() {
        let manager = MeshNetworkManager(store: store)
        let robin = makeReturningDevice(named: "Robin")
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(),
            peer: robin.first,
            fingerprint: "fp-robin",
            kind: .lightweight,
            stableDistanceMeters: 4.2
        )

        #expect(!manager.canEvaluateOverflowCandidate(robin.again),
                "a device already holding a slot is not a candidate for another one")
        #expect(manager.canEvaluateOverflowCandidate(makePeer(name: "Stranger")),
                "control: with a settled lightweight slot to compare against, a new device IS evaluable")
    }

    /// §6.4 finding 2, the local-kick half. `kickEvictedPeer` notes the device so the
    /// `.notConnected` it causes is not read as the transient socket loss the re-invite retry
    /// exists for. Noted by `id`, a device whose handle churned between the kick and the callback
    /// lost that note — and the manager immediately re-invited a peer it had just evicted on
    /// purpose (a moderation removal, an overflow eviction, a closed session).
    @Test func localKick_survivesAHandleChurnAndSuppressesTheReInvite() {
        let manager = MeshNetworkManager(store: store)
        manager.markProximityJoinForTesting()
        let robin = makeReturningDevice(named: "Robin")
        manager.addSlotForTesting(coordinator: throwawayCoordinator(), peer: robin.first, fingerprint: nil)

        manager.evictSlotForTesting(peerID: robin.first.id)
        #expect(manager.locallyKickedEndpointCountForTesting == 1, "the eviction must leave a note")

        manager.multipeerSessionForTesting.onPeerDisconnected?(robin.again, "Peer disconnected")

        #expect(manager.peerRetryEntryCountForTesting == 0,
                "a deliberate eviction must never arm a re-invite retry")
        #expect(manager.locallyKickedEndpointCountForTesting == 0,
                "and the note is consumed by the disconnect it was written for")
    }

    /// §6.4 finding 2, the retry-budget half. `maxPeerRetries` is a budget per DEVICE. Keyed on
    /// `id`, every reconnect opened a fresh entry with a fresh budget, so a peer that flaps forever
    /// is re-invited forever — the bound existed on paper and never bound anything.
    @Test func retryBudget_isSpentPerDeviceNotPerDiscoveryHandle() {
        let manager = MeshNetworkManager(store: store)
        manager.markProximityJoinForTesting()
        let endpoint = PeerEndpointKey(UUID())
        // One more sighting than the budget allows, each under its own discovery handle.
        for _ in 0..<4 {
            manager.multipeerSessionForTesting.onPeerDisconnected?(
                makePeer(name: "Robin", endpoint: endpoint), "Peer disconnected"
            )
        }

        #expect(manager.peerRetryEntryCountForTesting == 1,
                "four sightings of one device must share one budget, not open four")
        #expect(manager.peerRetryCountForTesting(for: makePeer(name: "Robin", endpoint: endpoint)) == 3,
                "and that budget must actually run out")
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
