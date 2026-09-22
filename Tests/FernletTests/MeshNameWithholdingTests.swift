// MeshNameWithholdingTests.swift
// FernletTests
//
// Stranger-admission Option 1b (the owner's call of 2026-09-22), the MESH half. The coordinator
// withholds this device's display name until it commits (`ProximityCoordinatorTests`), but every
// mesh frame is signed at `MeshNetworkManager.sendEnvelopeCore`, and six broadcasts reach slots this
// device has NOT committed — the coordinator beacon every 20 s, the admission request, rotation sync,
// key rotation and ack, the removal votes, departure and termination frames — plus the QR ceremony.
// The item's blind verify found them all still naming this device to a stranger (BLOCKER), with
// `MeshHostPinTests` asserting the leak as the expected value. The gate now sits at that one door:
// an uncommitted slot gets an empty envelope name, and a `MeshPeerNameRedactable` payload arrives
// with every name blanked — this device's own, and on a relayed vote OTHER members' too.
//
// House rules: no sleeps and no wall clock; the per-slot sends are spawned on the main actor and
// drained with a bounded yield loop, as `MeshHostPinTests` does.

import Foundation
import Testing
import FernletFoundation
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

/// Two committed members and one uncommitted stranger, each on a recording endpoint.
@MainActor
final class MeshNameWithholdingRig {

    /// The host. Held for the rig's life so every send reads a live one.
    let store: FernletStore

    /// The manager under test.
    let manager: MeshNetworkManager

    /// Held strongly: a `FakePeerTransport` points at its fabric weakly.
    private let network: FakePeerNetwork

    /// The two committed members' endpoints, and the stranger's.
    let memberA: FakePeerTransport
    let memberB: FakePeerTransport
    let stranger: FakePeerTransport

    /// The committed members' fingerprints.
    static let fingerprintA = "a1a1a1a1a1a1a1a1"
    static let fingerprintB = "b2b2b2b2b2b2b2b2"

    init() {
        store = makeTestStore()
        network = FakePeerNetwork()
        let a = network.addEndpoint(named: "member-a")
        let b = network.addEndpoint(named: "member-b")
        let s = network.addEndpoint(named: "stranger")
        memberA = a.transport
        memberB = b.transport
        stranger = s.transport
        manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.addSlotForTesting(coordinator: MeshHostPinProbe.throwawayCoordinator(), peer: a.handle,
                                  fingerprint: Self.fingerprintA, channel: a.transport)
        manager.addSlotForTesting(coordinator: MeshHostPinProbe.throwawayCoordinator(), peer: b.handle,
                                  fingerprint: Self.fingerprintB, channel: b.transport)
        manager.addSlotForTesting(coordinator: MeshHostPinProbe.throwawayCoordinator(), peer: s.handle,
                                  fingerprint: nil, channel: s.transport)
    }

    /// Every envelope `endpoint` was sent, decoded.
    func envelopes(on endpoint: FakePeerTransport) throws -> [FernletIdentityEnvelope] {
        try endpoint.sentFrames.map { try JSONDecoder().decode(FernletIdentityEnvelope.self, from: $0.data) }
    }

    /// The removal proposal `endpoint` was sent, decoded out of its (unsealed) envelope.
    func removalProposal(on endpoint: FakePeerTransport) throws -> MeshRemovalProposalPayload? {
        guard let envelope = try envelopes(on: endpoint).first(where: { $0.payloadType == .meshRemovalProposal }) else {
            return nil
        }
        return try JSONDecoder().decode(MeshRemovalProposalPayload.self, from: envelope.payload)
    }

    /// The admission requests `endpoint` was sent, decoded out of their (unsealed) envelopes.
    func admissionRequests(on endpoint: FakePeerTransport) throws -> [MeshAdmissionRequestPayload] {
        try envelopes(on: endpoint).filter { $0.payloadType == .meshAdmissionRequest }
            .map { try JSONDecoder().decode(MeshAdmissionRequestPayload.self, from: $0.payload) }
    }

    /// An open mesh this device is NOT a member of — the joiner's view when a descriptor arrives.
    static func meshToJoin() -> MeshDescriptor {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        return MeshDescriptor(
            meshID: UUID(), name: "Joinable", mode: .open, members: [],
            nameSetAt: instant, nameSetBy: fingerprintA, modeSetAt: instant, modeSetBy: fingerprintA,
            createdAt: instant
        )
    }

    /// Lets the spawned per-slot sends run — bounded, no sleeps.
    func drain() async {
        // R2: bounded.
        for _ in 0..<32 { await Task.yield() }
    }
}

/// The mesh door withholds every name from a slot this device has not committed — and only from it.
@MainActor
@Suite(.serialized)
struct MeshNameWithholdingTests {

    /// **The verify's BLOCKER, pinned through the real door.** The beacon and a removal vote reach
    /// all three slots; the stranger's copies carry no envelope name and a vote with both names
    /// blanked (the proposer's — this device — and the target's — another member), while the two
    /// members receive them named. The vote itself survives the blanking.
    @Test func nothingTheMeshSendsToAnUncommittedSlotCarriesAName() async throws {
        let rig = MeshNameWithholdingRig()
        let localName = rig.store.resolvedProximityDisplayName
        #expect(!localName.isEmpty, "the fixture has a name to withhold")
        rig.manager.broadcastCoordinatorBeaconForTesting()
        let target = try #require(
            rig.manager.sessionParticipants.first { $0.fingerprint == MeshNameWithholdingRig.fingerprintA },
            "the committed member is a participant the vote can target"
        )
        rig.manager.proposeRemoval(of: target)
        await rig.drain()

        let toStranger = try rig.envelopes(on: rig.stranger)
        #expect(toStranger.count >= 2, "the beacon and the vote both reached the stranger — the claim is not vacuous")
        #expect(toStranger.allSatisfy { $0.senderDisplayName.isEmpty }, "and no frame to it names this device")
        let strangerVote = try #require(try rig.removalProposal(on: rig.stranger), "the vote reached the stranger")
        #expect(strangerVote.proposerDisplayName.isEmpty && strangerVote.targetDisplayName.isEmpty,
                "the vote's payload names nobody — not this device, not the member it targets")
        #expect(strangerVote.targetFingerprint == MeshNameWithholdingRig.fingerprintA,
                "and the vote itself survives the blanking")

        let toMember = try rig.envelopes(on: rig.memberB)
        #expect(!toMember.isEmpty && toMember.allSatisfy { $0.senderDisplayName == localName },
                "a committed member still receives every frame under this device's name")
        let memberVote = try #require(try rig.removalProposal(on: rig.memberB), "the vote reached the member")
        #expect(memberVote.proposerDisplayName == localName, "and its vote names the proposer — the gate is per slot")
    }

    /// The disclosure subscriber RENAMES a seated peer's roster entry and never mints one: a stranger
    /// the closed-mesh check refused is torn down asynchronously, and its named frame processed in
    /// that window must not land it in the keep-as-friend prompt (the item's blind verify).
    @Test func aDisclosureRenamesASeatedEntryAndNeverMintsOne() {
        let rig = MeshNameWithholdingRig()
        let seated = MeshNameWithholdingRig.fingerprintA
        rig.manager.recordSessionParticipant(
            displayName: seated, fingerprint: seated,
            signingPublicKey: Data([1, 2, 3]), keyAgreementPublicKey: Data([4, 5, 6])
        )
        rig.manager.renameSessionParticipant(fingerprint: seated, to: "Alex")
        #expect(rig.manager.sessionRoster.first { $0.fingerprint == seated }?.displayName == "Alex",
                "a seated peer's fingerprint row takes the disclosed name")
        let rows = rig.manager.sessionRoster.count
        rig.manager.renameSessionParticipant(fingerprint: "f0f0f0f0f0f0f0f0", to: "Refused Stranger")
        #expect(rig.manager.sessionRoster.count == rows, "a fingerprint the seat never recorded gets no row")
        #expect(!rig.manager.sessionRoster.contains { $0.displayName == "Refused Stranger" }, "and its name lands nowhere")
    }

    // MARK: - The owner-calls re-verify (2026-09-22): the receiving side and the missing pins

    /// **The join request asks committed slots only.** A blanked request made the admitter mint "A
    /// friend" into the descriptor (the re-verify's FIX); now the stranger gets no request at all,
    /// and both committed members get one that names this device.
    @Test func aJoinRequestGoesOnlyToSlotsThisDeviceCommitted() async throws {
        let rig = MeshNameWithholdingRig()
        let localName = rig.store.resolvedProximityDisplayName
        rig.manager.currentMesh = MeshNameWithholdingRig.meshToJoin()
        #expect(rig.manager.requestAdmissionForHarness(), "the joiner holds a committed slot, so it asks")
        await rig.drain()
        #expect(try rig.admissionRequests(on: rig.stranger).isEmpty, "the uncommitted stranger is not asked at all")
        let toA = try rig.admissionRequests(on: rig.memberA)
        let toB = try rig.admissionRequests(on: rig.memberB)
        #expect(toA.count == 1 && toB.count == 1, "each committed member is asked once")
        #expect((toA + toB).allSatisfy { $0.requesterDisplayName == localName },
                "and the request names this device — a committed admitter is owed the name, never \"A friend\"")
    }

    /// **A withheld vote is filled on receipt** from what this device already knows: the target from
    /// the descriptor, the proposer from the session roster, an unknown member by fingerprint — and a
    /// name the sender disclosed is kept as sent. Before, the card read " asked to remove ." with a
    /// live "Second Removal" button for the vote's whole 60 s (the re-verify's FIX).
    @Test func aWithheldVoteIsFilledFromWhatThisDeviceAlreadyKnows() {
        let rig = MeshNameWithholdingRig()
        let instant = Date()
        var mesh = MeshNameWithholdingRig.meshToJoin()
        mesh.members = [MeshMember(
            fingerprint: MeshNameWithholdingRig.fingerprintA, displayName: "Alex",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]), joinedAt: instant
        )]
        rig.manager.currentMesh = mesh
        rig.manager.recordSessionParticipant(
            displayName: "Blair", fingerprint: MeshNameWithholdingRig.fingerprintB,
            signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4])
        )
        let withheld = MeshRemovalProposalPayload(
            id: UUID(), targetFingerprint: MeshNameWithholdingRig.fingerprintA, targetDisplayName: "",
            proposerFingerprint: MeshNameWithholdingRig.fingerprintB, proposerDisplayName: "",
            createdAt: instant, expiresAt: instant.addingTimeInterval(60)
        )
        rig.manager.ingestRemovalProposalForTesting(withheld)
        let stored = rig.manager.pendingRemovalProposals.first(where: { $0.id == withheld.id })
        #expect(stored != nil, "the withheld vote was stored")
        #expect(stored?.targetDisplayName == "Alex", "the target's name comes from the descriptor")
        #expect(stored?.proposerDisplayName == "Blair", "the proposer's from the session roster")
        #expect(stored?.targetFingerprint == withheld.targetFingerprint, "and the vote is the same vote")

        let unknown = "0f0f0f0f0f0f0f0f"
        let fromAStranger = MeshRemovalProposalPayload(
            id: UUID(), targetFingerprint: MeshNameWithholdingRig.fingerprintA, targetDisplayName: "Named As Sent",
            proposerFingerprint: unknown, proposerDisplayName: "",
            createdAt: instant, expiresAt: instant.addingTimeInterval(60)
        )
        rig.manager.ingestRemovalProposalForTesting(fromAStranger)
        let second = rig.manager.pendingRemovalProposals.first(where: { $0.id == fromAStranger.id })
        #expect(second?.proposerDisplayName == unknown, "an unknown member is shown by fingerprint, never blank")
        #expect(second?.targetDisplayName == "Named As Sent", "and a name the sender disclosed is kept as sent")
    }

    /// **The QR ceremony's challenge withholds the name** — the ceremony runs BEFORE the commit by
    /// design, and it is the one mesh send whose `fingerprint:` argument is non-nil while the slot's
    /// own is nil. The door must key on the SLOT; keyed on the argument it would name this device on
    /// every ceremony (the re-verify's FIX: that mutation survived every suite).
    @Test func theQRCeremonysChallengeToAnUncommittedSlotCarriesNoName() async throws {
        let rig = MeshNameWithholdingRig()
        let bobService = "com.fernlet.test.name-withholding.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: bobService) }
        let bob = IdentityService(keychainService: bobService)
        try bob.ensureProvisioned()
        let network = FakePeerNetwork()
        let endpoint = network.addEndpoint(named: "bob")
        let coordinator = try await Self.coordinatorAtManualCommit(remote: bob, peer: endpoint.handle)
        rig.manager.addSlotForTesting(coordinator: coordinator, peer: endpoint.handle,
                                      fingerprint: nil, channel: endpoint.transport)
        let qr = try ProximityVerifyQR.makeURL(identity: bob)
        #expect(rig.manager.beginQRVerification(with: qr.url, slotID: endpoint.handle.id), "the ceremony started")
        await rig.drain()
        let challenges = try endpoint.transport.sentFrames
            .map { try JSONDecoder().decode(FernletIdentityEnvelope.self, from: $0.data) }
            .filter { $0.payloadType == .verifyChallenge }
        #expect(challenges.count == 1, "the challenge really went out on the uncommitted slot")
        #expect(challenges.allSatisfy { $0.senderDisplayName.isEmpty }, "and it names nobody — the door keys on the slot")
        withExtendedLifetime(network) {}
    }

    /// A friend-mode coordinator at the manual-commit gate for `remote` — the QR ceremony's
    /// precondition — on its own mock radio, so only the slot's channel carries mesh frames.
    private static func coordinatorAtManualCommit(remote: IdentityService, peer: PeerHandle) async throws -> ProximityCoordinator {
        let transport = MockMultipeerTransport()
        let local = IdentityService(keychainService: "com.fernlet.test.name-withholding.local.\(UUID().uuidString)")
        try local.ensureProvisioned()
        let coordinator = ProximityCoordinator(
            identity: local, transport: transport, ranging: MockRangingProvider(isHardwareSupported: false),
            inspector: nil, replayCache: ReplayCache(), foregroundAnchor: nil, displayName: "Local", timeoutSeconds: 0
        )
        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        let introduction = try FernletIdentityEnvelope.signed(
            identityService: remote, senderDisplayName: "", payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"), payload: Data()
        )
        // R2: bounded settle for the coordinator's fire-and-forget hops.
        for _ in 0..<50 {
            if case .awaitingIdentityIntroduction = coordinator.state { break }
            await Task.yield()
        }
        transport.simulateInboundData(try JSONEncoder().encode(introduction), from: peer)
        // R2: bounded settle.
        for _ in 0..<200 {
            if case .awaitingManualCommit = coordinator.state { break }
            await Task.yield()
        }
        guard case .awaitingManualCommit = coordinator.state else {
            Issue.record("Expected the manual-commit gate, got \(coordinator.state)")
            throw CancellationError()
        }
        return coordinator
    }

    /// **The disclosure subscriber stays rename-only** — the WIRING, not just the helper: rewiring it
    /// back to `recordSessionParticipant` (which appends) passed every suite (the re-verify's FIX).
    /// A refused stranger's named frame in the teardown window must not mint it a roster row.
    @Test func theDisclosureSubscriberIsWiredToRenameOnly() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        let closure = try #require(
            MeshRoutedSourceScan.bracedBody(after: "coordinator.onPeerDisplayNameDisclosed =", in: source),
            "the manager no longer subscribes to the coordinator's disclosure"
        )
        #expect(closure.contains("renameSessionParticipant("), "the subscriber renames")
        #expect(!closure.contains("recordSessionParticipant("), "and never records — recording appends a row")
    }

    /// Each name-bearing payload blanks exactly its names: every key, id, fingerprint and instant
    /// is untouched, so a blanked copy is the same vote or request.
    @Test func eachNameBearingPayloadBlanksItsNamesAndNothingElse() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let request = MeshAdmissionRequestPayload(
            meshID: UUID(), requesterFingerprint: "f1f1f1f1f1f1f1f1", requesterDisplayName: "Robin",
            requesterSigningPublicKey: Data([1, 2, 3]), requesterKeyAgreementPublicKey: Data([4, 5, 6])
        )
        let blankRequest = request.withNamesWithheld()
        #expect(blankRequest.requesterDisplayName.isEmpty, "the requester's name is withheld")
        #expect(blankRequest.meshID == request.meshID
                    && blankRequest.requesterFingerprint == request.requesterFingerprint
                    && blankRequest.requesterSigningPublicKey == request.requesterSigningPublicKey
                    && blankRequest.requesterKeyAgreementPublicKey == request.requesterKeyAgreementPublicKey,
                "and everything the grant runs on is unchanged")

        let proposal = MeshRemovalProposalPayload(
            id: UUID(), targetFingerprint: "a1a1a1a1a1a1a1a1", targetDisplayName: "Alex",
            proposerFingerprint: "c3c3c3c3c3c3c3c3", proposerDisplayName: "Casey",
            createdAt: instant, expiresAt: instant.addingTimeInterval(60)
        )
        let blankProposal = proposal.withNamesWithheld()
        #expect(blankProposal.targetDisplayName.isEmpty && blankProposal.proposerDisplayName.isEmpty,
                "both names on a vote are withheld")
        #expect(blankProposal.id == proposal.id && blankProposal.targetFingerprint == proposal.targetFingerprint
                    && blankProposal.proposerFingerprint == proposal.proposerFingerprint
                    && blankProposal.createdAt == proposal.createdAt && blankProposal.expiresAt == proposal.expiresAt,
                "and the vote is the same vote")

        let second = MeshRemovalSecondPayload(proposal: proposal, seconderFingerprint: "d4d4d4d4d4d4d4d4")
        let blankSecond = second.withNamesWithheld()
        #expect(blankSecond.proposal == blankProposal, "a second carries the blanked proposal")
        #expect(blankSecond.seconderFingerprint == second.seconderFingerprint, "and the same seconder")
    }
}
