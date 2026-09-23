// MeshSeatTransportProofTests.swift
// FernletTests
//
// 2026-09-23 — the hole the blind reviews of 31fafd6 found, and which predates it. On the QUIC mesh
// radio every tunnel's signed channel introduction is bound to the TLS exporter and proves a signing
// key (`MeshTransportSession.verifiedSigningPublicKey(for:)`). The slot's `ProximityCoordinator`
// runs its own identity introduction on top, and that one is replayable over any tunnel: no
// recipient, a five-minute expiry, no advertised fingerprint to check it against. The coordinator
// accepts a second introduction in ANY state and re-gates to it, and `commitManualProximity()`
// commits whatever identity it holds when it runs. The seat judged that identity only for the
// slots the returning-member re-seat had asked to commit — so a tap on a slot row, the QR
// ceremony or a 15 cm dwell could seat a link as an identity the transport had proven FALSE, and
// every frame on it was then credited to that identity (removal votes cast "as" another member).
//
// The claims walled here:
//
//  1. EVERY seat answers to the tunnel, whoever asked for the commit: a committed key that is not
//     the key the channel introduction proved is refused, audited once with a reason, and the
//     link evicted — a stranger's replay, a member's introduction the re-seat already flagged, and
//     a seated link re-committed as somebody else alike. A link that proved no key is refused too.
//     The test seam that stands in for the seat refuses what the seat refuses.
//  2. An honest first meeting is never refused: a provisional stranger's channel introduction
//     proves exactly the Ed25519 key its coordinator's identity introduction carries, and it seats.
//  3. The payload door credits nothing against the link's proofs: a frame whose signer, or the
//     identity it would be credited to, is not the slot's seated key or the tunnel's proven key is
//     dropped and named — the re-commit window before the seat pass, a replayed identity before
//     any seat, a relayed envelope — and so is a frame from a coordinator that no longer holds a
//     slot. An honest link's frames are still credited.
//
// Every audit count is read through the mesh suites' one reader, `count(of:where:)` scoped by
// `heldBy(_:)`: the capture is process-global, and a second reader is what the P9 ratchet forbids.
//
// The gate is always the manual one (`MockRangingProvider(isHardwareSupported: false)`), so nothing
// commits by itself: every commit below is a tap, or the coordinator's own commit a dwell would run.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshSeatTransportProofTests

/// Every seat answers to the tunnel's proof, an honest first meeting still seats, and the payload
/// door credits no frame against the link's proofs.
@MainActor
@Suite(.serialized)
struct MeshSeatTransportProofTests {

    let store = makeTestStore()

    /// What a scenario needs: the manager, its recording radio, one member of its mesh, and the
    /// mesh id.
    private struct Rig {
        let manager: MeshNetworkManager
        let radio: FakeMeshTransportSession
        let member: IdentityService
        let meshID: UUID
    }

    /// One link: its coordinator, the channel it runs on, and the radio's handle for it.
    private struct Link {
        let coordinator: ProximityCoordinator
        let transport: MockMultipeerTransport
        let peer: PeerHandle
    }

    /// A manager holding a founded, OPEN mesh whose signed roster names this device and `member`,
    /// partitioned by the member's link dropping — `MeshReturningMemberReseatTests`' rig, so a
    /// member's identity is one the re-seat would act on.
    private func makeRig() throws -> Rig {
        let radio = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: radio)
        let meshID = UUID()
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID)
        let member = try MeshPartitionFixtures.identity("seatproof-member")
        let local = manager.identityForTesting
        manager.seedMembershipLedgerForTesting(
            meshID: meshID, founderSigningPublicKey: local.localSigningPublicKey,
            ledger: try MeshPartitionFixtures.ledger(founder: local, others: [member], meshID: meshID)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.applySessionEvent(.linksLost)
        }
        #expect(manager.sessionState == .partitioned, "the rig must start partitioned")
        return Rig(manager: manager, radio: radio, member: member, meshID: meshID)
    }

    /// Ends a rig's session and drops whatever rotation it asked for.
    private func teardown(_ rig: Rig) {
        _ = rig.manager.consumePendingRotationForTesting()
        rig.manager.leaveMesh()
    }

    /// `remote`'s signed identity introduction, encoded as it crosses a link — a device's own, or a
    /// copy another device replays. It carries no recipient, as on the QUIC radio.
    private func introduction(from remote: IdentityService) throws -> Data {
        try JSONEncoder().encode(FernletIdentityEnvelope.signed(
            identityService: remote, senderDisplayName: "",
            payloadType: .identityIntroduction, payloadSummary: PayloadSummary(title: "Hello"), payload: Data()
        ))
    }

    /// One mesh frame carrying `payload`, signed by `sender` — whoever that is, which is the point.
    private func frame(_ payload: some Encodable, type: PayloadType, signedBy sender: IdentityService) throws -> Data {
        try JSONEncoder().encode(FernletIdentityEnvelope.signed(
            identityService: sender, senderDisplayName: "",
            payloadType: type, payloadSummary: PayloadSummary(title: type.rawValue),
            payload: try JSONEncoder().encode(payload)
        ))
    }

    /// Seats a fresh slot the way a channel does, over a link whose tunnel proved `provenKey` (nil:
    /// the radio proved nothing), and drives its coordinator through `introduction` to the MANUAL
    /// proximity gate. The handle advertises no fingerprint, as every QUIC-radio handle does.
    private func gate(_ rig: Rig, provenKey: Data?, introduction: Data) async throws -> Link {
        let transport = MockMultipeerTransport()
        let peer = PeerHandle(
            id: UUID(), displayHint: "Nearby", discoveryInfo: ["v": "1"],
            advertisedFingerprint: nil, endpoint: PeerEndpointKey()
        )
        if let provenKey { rig.radio.verifiedSigningKeys[peer.endpoint] = provenKey }
        let coordinator = rig.manager.makeRetainedSlotCoordinatorForTesting(
            peer: peer, transport: transport, ranging: MockRangingProvider(isHardwareSupported: false)
        )
        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil {
            if case .awaitingIdentityIntroduction = coordinator.state { return true }
            return false
        }
        transport.simulateInboundData(introduction, from: peer)
        await waitUntil { MeshNetworkManager.gatedPeer(of: coordinator.state) != nil }
        if case .awaitingManualCommit = coordinator.state {} else {
            Issue.record("precondition: the link must wait at the manual gate, got \(coordinator.state)")
        }
        return Link(coordinator: coordinator, transport: transport, peer: peer)
    }

    /// ``gate(_:provenKey:introduction:)`` for a device whose tunnel proved `holder`'s key and whose
    /// coordinator was sent `introduced`'s identity introduction — its own, or a replayed one.
    private func gate(
        _ rig: Rig, tunnelProvedFor holder: IdentityService, introducing introduced: IdentityService
    ) async throws -> Link {
        try await gate(rig, provenKey: holder.localSigningPublicKey, introduction: try introduction(from: introduced))
    }

    /// A person's tap on the slot's row — the Friends tab's `commitManualProximity(slotID:)` — and
    /// the commit it lands.
    private func tap(_ rig: Rig, _ link: Link) async {
        rig.manager.commitManualProximity(slotID: link.peer.id)
        await waitUntil { isConnected(link.coordinator) }
        #expect(isConnected(link.coordinator), "precondition: the tap's commit landed")
    }

    /// The observation pass a live loop runs on a coordinator's state change: the seat.
    private func seatPass(_ rig: Rig) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.checkCoordinatorStatesForTesting()
        }
    }

    private func isConnected(_ coordinator: ProximityCoordinator) -> Bool {
        if case .connected = coordinator.state { return true }
        return false
    }

    /// The `reason` of every line this rig's mesh logged under `event`, in order.
    private func reasons(_ event: String, _ capture: MeshRoutedBackpressureAuditCapture, _ rig: Rig) -> [String?] {
        capture.records(withEventPrefix: event)
            .filter { $0.event == event && heldBy(rig.meshID)($0.context) }
            .map { $0.context["reason"] }
    }

    /// The seat's transport refusals this rig logged.
    private func seatRefusals(_ capture: MeshRoutedBackpressureAuditCapture, _ rig: Rig) -> [String?] {
        reasons("mesh.slot.refusedUnprovenIdentityAtSeat", capture, rig)
    }

    /// The payload door's refusals this rig logged.
    private func doorRefusals(_ capture: MeshRoutedBackpressureAuditCapture, _ rig: Rig) -> [String?] {
        reasons("mesh.dispatch.droppedUnattributable", capture, rig)
    }

    /// A legacy two-party removal proposal naming `proposer` — the unsigned payload whose sender the
    /// door's `peer` IS, which is why it is the frame that shows a misattribution.
    private func proposal(by proposer: IdentityService) -> MeshRemovalProposalPayload {
        MeshRemovalProposalPayload(
            id: UUID(), targetFingerprint: "seatproof-target-0011", targetDisplayName: "",
            proposerFingerprint: proposer.localFingerprint, proposerDisplayName: "",
            createdAt: Date(), expiresAt: Date().addingTimeInterval(60)
        )
    }

    /// An admission request in `requester`'s name for the rig's mesh.
    private func admissionRequest(as requester: IdentityService, _ rig: Rig) -> MeshAdmissionRequestPayload {
        MeshAdmissionRequestPayload(
            meshID: rig.meshID, requesterFingerprint: requester.localFingerprint, requesterDisplayName: "",
            requesterSigningPublicKey: requester.localSigningPublicKey,
            requesterKeyAgreementPublicKey: requester.localKeyAgreementPublicKey
        )
    }

    // MARK: Claim 1 — every seat answers to the tunnel

    /// A stranger's device replays another stranger's identity introduction over its own tunnel,
    /// and a person taps the row the replayed identity is shown on. The re-seat has no opinion (not
    /// a member), so before this fix nothing checked the tunnel and the link was seated as the
    /// identity it never proved.
    @Test func aTapCommittingAnIdentityTheTunnelDidNotProveIsRefusedAndEvictedAtTheSeat() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-holder")
        let claimed = try MeshPartitionFixtures.identity("seatproof-claimed")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: claimed)
        seatPass(rig)
        #expect(rig.manager.slots.first?.returningMemberReseat == .open,
                "precondition: not a member, so the re-seat has no opinion about it")

        await tap(rig, link)
        seatPass(rig)

        #expect(!rig.manager.slots.contains { $0.fingerprint == claimed.localFingerprint },
                "never seated as an identity the tunnel did not prove")
        #expect(rig.manager.slots.isEmpty, "the link is evicted, not left half-seated")
        #expect(rig.radio.disconnectedPeers.contains { $0.isSameEndpoint(as: link.peer) }, "and its tunnel freed")
        #expect(!rig.manager.sessionRoster.contains { $0.fingerprint == claimed.localFingerprint },
                "and no roster row was written for it")
        #expect(capture.count(of: "mesh.slot.refusedUnprovenIdentityAtSeat", where: heldBy(rig.meshID)) == 1,
                "refused out loud, once")
        #expect(seatRefusals(capture, rig) == ["transportKeyMismatch"])
        #expect(rig.manager.sessionState == .partitioned, "no heal was raised for a seat that never happened")
    }

    /// A member's introduction replayed over another key's tunnel: the re-seat already refused it
    /// (`refusedMismatchedKey`) and left it at the gate — where only a gesture could commit it. The
    /// gesture used to succeed: the re-seat's seat check skips a slot it never asked for.
    @Test func aMemberIdentityTheReseatRefusedIsRefusedAgainWhenAPersonCommitsIt() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-replayer")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: rig.member)
        seatPass(rig)
        #expect(rig.manager.slots.first?.returningMemberReseat == .refusedMismatchedKey,
                "precondition: the re-seat saw the borrowed identity and refused it")
        #expect(capture.count(of: "mesh.slot.returningMemberRefusedMismatchedKey", where: heldBy(rig.meshID)) == 1)

        await tap(rig, link)
        seatPass(rig)

        #expect(!rig.manager.slots.contains { $0.fingerprint == rig.member.localFingerprint },
                "a tap does not seat what the tunnel disproved")
        #expect(rig.manager.slots.isEmpty, "evicted")
        #expect(seatRefusals(capture, rig) == ["transportKeyMismatch"])
        #expect(capture.count(of: "mesh.slot.returningMemberRefusedAtSeat", where: heldBy(rig.meshID)) == 0,
                "the re-seat never asked for this commit: the refusal is the seat's own")
        #expect(rig.manager.sessionState == .partitioned, "the partition did not 'heal' onto a borrowed identity")
    }

    /// `handleIdentityEnvelope` accepts a second introduction on a `.connected` coordinator and
    /// re-gates to it; a commit then moves the SEATED link to the replayed identity. The seat path
    /// runs again for it (the committed fingerprint no longer matches) and used to overwrite the
    /// seat with the new identity.
    @Test func aSeatedLinkReCommittedAsSomebodyElseIsEvictedNotReSeated() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-seated")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: holder)
        await tap(rig, link)
        seatPass(rig)
        #expect(rig.manager.slots.first?.fingerprint == holder.localFingerprint,
                "precondition: an honest first meeting, seated as itself")

        link.transport.simulateInboundData(try introduction(from: rig.member), from: link.peer)
        await waitUntil {
            MeshNetworkManager.gatedPeer(of: link.coordinator.state)?.signingPublicKey == rig.member.localSigningPublicKey
        }
        #expect(MeshNetworkManager.gatedPeer(of: link.coordinator.state)?.fingerprint == rig.member.localFingerprint,
                "precondition: the replay re-gated a seated link")
        await link.coordinator.commitManualProximity()
        #expect(isConnected(link.coordinator), "precondition: a commit landed on the swapped identity")
        seatPass(rig)

        #expect(!rig.manager.slots.contains { $0.fingerprint == rig.member.localFingerprint },
                "a seated link is never re-seated as an identity its tunnel did not prove")
        #expect(rig.manager.slots.isEmpty, "the link is evicted")
        #expect(seatRefusals(capture, rig) == ["transportKeyMismatch"])
    }

    /// A seat ADOPTS an identity, so it needs a proof, not the absence of a contradiction: a link
    /// whose radio proved no key is refused even for an identity nothing contradicts. (On the QUIC
    /// radio that answer means the slot's tunnel is gone.)
    @Test func aSeatOverALinkWhoseRadioProvedNoKeyIsRefused() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let peer = try MeshPartitionFixtures.identity("seatproof-unproven")
        let link = try await gate(rig, provenKey: nil, introduction: try introduction(from: peer))

        await tap(rig, link)
        seatPass(rig)

        #expect(rig.manager.slots.isEmpty, "refused and evicted")
        #expect(!rig.manager.hasCommittedPeer)
        #expect(seatRefusals(capture, rig) == ["noTransportKey"])
    }

    /// The rule itself, over the two keys it compares.
    @Test func theSeatsTransportRuleIsAgreementWithAProof() {
        let committed = Data(repeating: 0x11, count: 32)
        let other = Data(repeating: 0x22, count: 32)
        #expect(MeshNetworkManager.seatTransportRefusal(committedKey: committed, provenKey: committed) == nil)
        #expect(MeshNetworkManager.seatTransportRefusal(committedKey: committed, provenKey: other)
                    == "transportKeyMismatch")
        #expect(MeshNetworkManager.seatTransportRefusal(committedKey: committed, provenKey: nil)
                    == "noTransportKey")
    }

    /// `commitSlotForTesting` stands in for the whole handshake, so a radio that proved nothing is
    /// read as having proved the peer's own key — every tier-1 rig commits that way — while a radio
    /// that proved a DIFFERENT key is refused exactly as the production seat refuses it.
    @Test func theSeatSeamRefusesWhatTheSeatRefuses() throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let peer = try MeshPartitionFixtures.identity("seatproof-seam")
        func seat(proven: Data?) -> PeerHandle {
            let handle = PeerHandle(
                id: UUID(), displayHint: "Seam", discoveryInfo: nil, advertisedFingerprint: nil, endpoint: PeerEndpointKey()
            )
            if let proven { rig.radio.verifiedSigningKeys[handle.endpoint] = proven }
            rig.manager.addSlotForTesting(coordinator: MeshP3Acceptance.coordinator(), peer: handle, fingerprint: nil)
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                rig.manager.commitSlotForTesting(at: rig.manager.slots.count - 1, peer: peer)
            }
            return handle
        }

        let disproved = seat(proven: Data(repeating: 0x42, count: 32))
        #expect(!rig.manager.slots.contains { $0.peer.isSameEndpoint(as: disproved) }, "refused and evicted")
        #expect(seatRefusals(capture, rig) == ["transportKeyMismatch"])

        let unproven = seat(proven: nil)
        #expect(rig.manager.slots.first { $0.peer.isSameEndpoint(as: unproven) }?.fingerprint == peer.localFingerprint,
                "a radio that proved nothing is the seam's own handshake: seated")
        #expect(seatRefusals(capture, rig) == ["transportKeyMismatch"], "and nothing more refused")
    }

    // MARK: Claim 2 — an honest first meeting is never refused

    /// The first meeting end to end at tier 1: the stranger's device, as a manager of its own, runs
    /// the signed channel introduction against this device's open doors; its OWN slot coordinator
    /// then sends its identity introduction; the key the tunnel proved and the key that introduction
    /// carries are one key, and a person's tap seats it.
    ///
    /// The hellos are built from each authority's own answers, exactly as `NetworkMeshSession`'s
    /// `localHello(from:)` builds them, and each transcript is signed by the authority itself — so
    /// the exchange accepts only if a manager's channel signature verifies under the key its hello
    /// names, and the equality below fails if the coordinator's envelope key ever moved off it.
    @Test func anHonestStrangerProvesTheKeyItIntroducesAndIsSeated() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let stranger = try MeshPartitionFixtures.identity("seatproof-stranger")
        let device = MeshDepartureRig.node("seatproof-stranger", identity: stranger, on: FakePeerNetwork())
        let local = rig.manager
        let remote = device.manager
        func hello(_ authority: MeshNetworkManager, sid: String) -> MeshChannelHello {
            MeshChannelHello(
                protocolVersion: MeshChannelIntroductionFormat.protocolVersion, meshID: authority.meshID,
                epochRef: authority.epochRef, signingPublicKey: authority.localSigningPublicKey,
                nonce: MeshChannelIntroductionFormat.randomNonce(), sessionID: sid
            )
        }
        var responder = MeshChannelIntroductionExchange(role: .responder, localHello: hello(local, sid: "local-sid"))
        var initiator = MeshChannelIntroductionExchange(role: .initiator, localHello: hello(remote, sid: "remote-sid"))
        var localNonces = MeshIntroductionNonceCache()
        var remoteNonces = MeshIntroductionNonceCache()
        #expect(local.roster.verdict(for: stranger.localSigningPublicKey) == .stranger, "precondition: a first meeting")
        #expect(responder.receive(initiator.localHello, roster: local.roster, nonces: &localNonces,
                                  mayReconcileDivergentEpochs: local.mayReconcileDivergentEpochs) == nil,
                "the open doors admit the stranger provisionally")
        #expect(initiator.receive(responder.localHello, roster: remote.roster, nonces: &remoteNonces,
                                  mayReconcileDivergentEpochs: remote.mayReconcileDivergentEpochs) == nil)
        let binding = Data(repeating: 0x5C, count: MeshChannelIntroductionFormat.channelBindingByteCount)
        let initiatorTranscript = initiator.bind(channelBindingHash: binding)
        let responderTranscript = responder.bind(channelBindingHash: binding)
        let transcript = try #require(initiatorTranscript, "the stranger derives the transcript it must sign")
        #expect(responderTranscript == transcript, "both ends derive one transcript")
        let proven = try #require(responder.review(MeshChannelIntroduction(
            channelBindingHash: binding, signature: try remote.signChannelIntroduction(transcript)
        )).verifiedPeer, "the stranger's tunnel proves a key")

        let toward = PeerHandle(
            id: UUID(), displayHint: "Local", discoveryInfo: ["v": "1"], advertisedFingerprint: nil, endpoint: PeerEndpointKey()
        )
        let wire = MockMultipeerTransport()
        let theirs = remote.makeRetainedSlotCoordinatorForTesting(
            peer: toward, transport: wire, ranging: MockRangingProvider(isHardwareSupported: false)
        )
        await theirs.begin(role: .browser, mode: .friend)
        wire.simulateConnected(peer: toward)
        await waitUntil { !wire.sentData.isEmpty }
        let sent = try #require(wire.sentData.first?.0, "their coordinator introduces itself on connect")
        let envelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: sent)
        #expect(envelope.payloadType == .identityIntroduction)
        #expect(envelope.senderSigningPublicKey == proven.signingPublicKey,
                "one device, one key: the identity introduction carries exactly the key its tunnel proved")

        let link = try await gate(rig, provenKey: proven.signingPublicKey, introduction: sent)
        await tap(rig, link)
        seatPass(rig)

        #expect(rig.manager.slots.first?.fingerprint == stranger.localFingerprint, "an honest first meeting is seated")
        #expect(capture.count(of: "mesh.slot.refusedUnprovenIdentityAtSeat", where: heldBy(rig.meshID)) == 0)
        await theirs.cancel()
    }

    // MARK: Claim 3 — the payload door credits nothing against the link's proofs

    /// The re-commit window. A seated link is re-gated by a replayed member introduction and a
    /// commit lands on it; until the next seat pass evicts the link, every frame on it used to be
    /// credited to the MEMBER — here a removal proposal filed as the member's own.
    @Test func aSeatedLinkReCommittedAsAMemberCannotProposeARemovalAsThem() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-swapper")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: holder)
        await tap(rig, link)
        seatPass(rig)
        #expect(rig.manager.slots.first?.fingerprint == holder.localFingerprint, "precondition: seated as itself")
        link.transport.simulateInboundData(try introduction(from: rig.member), from: link.peer)
        await waitUntil { MeshNetworkManager.gatedPeer(of: link.coordinator.state) != nil }
        await link.coordinator.commitManualProximity()
        #expect(isConnected(link.coordinator), "precondition: re-committed as the member, no seat pass yet")

        link.transport.simulateInboundData(
            try frame(proposal(by: rig.member), type: .meshRemovalProposal, signedBy: holder), from: link.peer
        )
        await waitUntil { !doorRefusals(capture, rig).isEmpty || !rig.manager.pendingRemovalProposals.isEmpty }

        #expect(rig.manager.pendingRemovalProposals.isEmpty, "no proposal was filed in the member's name")
        #expect(doorRefusals(capture, rig) == ["creditedNotSeated"],
                "the frame was credited to an identity that is not the seat's, and dropped by name")
    }

    /// Before any seat, the identity a frame is credited to is the coordinator's PENDING one — a
    /// replayed introduction. The admission request is the one member-family frame taken from an
    /// uncommitted slot, so a device used to be able to ask to join in the replayed identity's name.
    @Test func aReplayedIdentityCannotAskToJoinInItsOwnersNameBeforeAnySeat() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-asker")
        let claimed = try MeshPartitionFixtures.identity("seatproof-named")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: claimed)

        link.transport.simulateInboundData(
            try frame(admissionRequest(as: claimed, rig), type: .meshAdmissionRequest, signedBy: holder), from: link.peer
        )
        await waitUntil { !doorRefusals(capture, rig).isEmpty || !rig.manager.pendingAdmissionRequests.isEmpty }

        #expect(rig.manager.pendingAdmissionRequests.isEmpty, "no request queued in the replayed identity's name")
        #expect(doorRefusals(capture, rig) == ["creditedNotProven"])
    }

    /// An envelope signed by another device, carried over a seated link, is not the link's to be
    /// credited with — whatever it claims. (The mesh relays content inside its own envelopes, never
    /// another device's envelope, so nothing honest sends one.)
    @Test func aFrameSignedByAnotherKeyIsNotCreditedToTheSeatedLink() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-carrier")
        let signer = try MeshPartitionFixtures.identity("seatproof-signer")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: holder)
        await tap(rig, link)
        seatPass(rig)
        #expect(rig.manager.slots.first?.fingerprint == holder.localFingerprint, "precondition: seated as itself")

        link.transport.simulateInboundData(
            try frame(proposal(by: holder), type: .meshRemovalProposal, signedBy: signer), from: link.peer
        )
        await waitUntil { !doorRefusals(capture, rig).isEmpty || !rig.manager.pendingRemovalProposals.isEmpty }

        #expect(rig.manager.pendingRemovalProposals.isEmpty, "another device's envelope was not filed as the link's")
        #expect(doorRefusals(capture, rig) == ["signerNotSeated"])
    }

    /// The seat evicts a link it refused synchronously, while the slot's coordinator is cancelled a
    /// hop later — so a frame already queued behind the eviction reached the door with no slot, and
    /// the admission request, the one family that accepts a slotless frame, took it in the name the
    /// seat had just refused.
    @Test func aFrameQueuedBehindAnEvictionIsCreditedToNobody() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let holder = try MeshPartitionFixtures.identity("seatproof-stale")
        let claimed = try MeshPartitionFixtures.identity("seatproof-evicted")
        let link = try await gate(rig, tunnelProvedFor: holder, introducing: claimed)
        await tap(rig, link)
        seatPass(rig)
        #expect(rig.manager.slots.isEmpty, "precondition: the seat refused the replayed identity and evicted it")

        link.transport.simulateInboundData(
            try frame(admissionRequest(as: claimed, rig), type: .meshAdmissionRequest, signedBy: holder), from: link.peer
        )
        await waitUntil { !doorRefusals(capture, rig).isEmpty || !rig.manager.pendingAdmissionRequests.isEmpty }

        #expect(rig.manager.pendingAdmissionRequests.isEmpty, "a slotless frame is credited to nobody")
        #expect(doorRefusals(capture, rig) == ["noSlot"])
    }

    /// The positive control that separates "the door refused a misattributed frame" from "the door
    /// refuses frames": an honest link's own frames are credited, before the seat and after it.
    @Test func anHonestLinksFramesAreStillCreditedBeforeAndAfterItsSeat() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let peer = try MeshPartitionFixtures.identity("seatproof-honest")
        let link = try await gate(rig, tunnelProvedFor: peer, introducing: peer)

        link.transport.simulateInboundData(
            try frame(admissionRequest(as: peer, rig), type: .meshAdmissionRequest, signedBy: peer), from: link.peer
        )
        await waitUntil { !rig.manager.pendingAdmissionRequests.isEmpty }
        #expect(rig.manager.pendingAdmissionRequests.map(\.requesterFingerprint) == [peer.localFingerprint],
                "before the seat: its own request, in its own name, is queued")

        await tap(rig, link)
        seatPass(rig)
        link.transport.simulateInboundData(
            try frame(proposal(by: peer), type: .meshRemovalProposal, signedBy: peer), from: link.peer
        )
        await waitUntil { !rig.manager.pendingRemovalProposals.isEmpty }
        #expect(rig.manager.pendingRemovalProposals.map(\.proposerFingerprint) == [peer.localFingerprint],
                "after the seat: its own proposal is filed as its own")
        #expect(doorRefusals(capture, rig).isEmpty, "and nothing was refused")
    }

    /// The door's rule over the four keys it compares. Each anchor that exists — the seated key, the
    /// proven key — must equal the signer and the credited identity; with neither, nothing is judged.
    @Test func theDoorsAttributionRuleIsAgreementWithEveryAnchor() {
        let own = Data(repeating: 0x11, count: 32)
        let other = Data(repeating: 0x22, count: 32)
        let rule = MeshNetworkManager.frameAttributionRefusal
        #expect(rule(own, own, own, own) == nil, "an honest seated link")
        #expect(rule(own, own, nil, own) == nil, "an honest link before its seat")
        #expect(rule(own, nil, own, own) == nil, "no credited identity contradicts nothing")
        #expect(rule(other, other, nil, nil) == nil, "no anchor: the families' own gates stand")
        #expect(rule(other, own, own, own) == "signerNotSeated")
        #expect(rule(own, other, own, own) == "creditedNotSeated")
        #expect(rule(other, other, nil, own) == "signerNotProven")
        #expect(rule(own, other, nil, own) == "creditedNotProven")
        #expect(rule(own, own, own, other) == "signerNotProven", "a seat the tunnel no longer proves")
    }

    // MARK: - Waiting

    /// Gives up only once the deadline has passed AND `minimumPolls` observations have been made
    /// (wall-clock alone expires while a `@MainActor` suite is starved in a loaded full-suite run).
    private func waitUntil(
        timeout: Duration = .seconds(2),
        minimumPolls: Int = 400,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            // A cancelled sleep ends the wait; the cell's own expectation then reports the state.
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
}
