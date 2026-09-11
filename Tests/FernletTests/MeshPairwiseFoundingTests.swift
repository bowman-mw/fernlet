// MeshPairwiseFoundingTests.swift
// FernletTests
//
// Network migration P6 item 2 (D-13.18, plan §11.3 item 13(i)): the proximity-join path FOUNDS a
// mesh — with a membership ledger — at the FIRST commit.
//
// Tier 1 only: `FakePeerNetwork` + `FakeMeshTransportSession` + the pinned install binding, no
// radio and no wall-clock sleeps.
//
// Three fixture facts this file rests on, each of which is easy to get wrong here specifically:
//
// - **Nothing is seeded.** Every other mesh rig hand-installs a ledger through
//   `seedMembershipLedgerForTesting` and fakes a commit with `applySessionEvent(.peerCommitted)`.
//   That is exactly what this file must NOT do: the claim under test is that the REAL commit path
//   arms the ledger, so the rig drives `commitSlotForTesting(at:peer:)` — the seam onto
//   `onSlotConnected(at:identity:)`, whose only production caller needs a live coordinator state.
//   A cell that hand-called the founding would prove the founding and never the trigger.
// - **The commit itself writes.** `applySessionEvent(.founded)` seals a `MeshSessionContext`, so
//   every commit and every pump runs inside `DeviceBindingID.$testOverride` under ONE pinned
//   install (`MeshP3Acceptance.install`) — and a cell that means to drive a REFUSED seal passes
//   `.unavailable` instead, which is the only difference between founding and failing to.
// - **Both halves found.** The election is an order, not a gate, so a two-node settle carries two
//   descriptors and one of them is yielded. Assertions about "the" mesh are written as "both sides
//   name the same meshID", never as "node 0 founded".

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshFoundingRig

/// N proximity-join managers on `FakePeerNetwork` with **no** seeded mesh and **no** seeded ledger —
/// the state the app is actually in when two phones meet.
///
/// A thin facade over `MeshDepartureRig`'s nodes, pump and settle (item 4's), because only the
/// founding half is new. What it does not reuse is `MeshDepartureRig.link`, which seats slots that
/// are already COMMITTED: here the commit is the thing under test, so slots are seated uncommitted
/// and committed through the production door.
@MainActor
struct MeshFoundingRig {

    /// The medium.
    let fabric: FakePeerNetwork

    /// Every node, in build order.
    let nodes: [MeshDepartureNode]

    /// Each node's provisioned identity, in the same order.
    let identities: [IdentityService]

    /// Builds `count` provisioned, proximity-join managers and asserts the precondition that would
    /// otherwise make every roster claim below vacuous.
    ///
    /// - Parameters:
    ///   - count: How many nodes.
    ///   - label: The diagnostic prefix, also the endpoint names.
    /// - Returns: The rig.
    static func build(_ count: Int, label: String) throws -> MeshFoundingRig {
        let fabric = FakePeerNetwork()
        let labels = (0..<count).map { "\(label)-\($0)" }
        let identities = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(identities.map(\.localFingerprint)).count == count,
                "the rig needs distinct provisioned identities")
        var nodes: [MeshDepartureNode] = []
        // R2: bounded by the caller's node count.
        for (label, identity) in zip(labels, identities) {
            let node = MeshDepartureRig.node(label, identity: identity, on: fabric)
            node.manager.markProximityJoinForTesting()
            #expect(node.manager.currentMesh == nil, "a founding rig starts with no mesh")
            #expect(node.manager.membershipVerifier == nil, "a founding rig starts with no ledger")
            nodes.append(node)
        }
        return MeshFoundingRig(fabric: fabric, nodes: nodes, identities: identities)
    }

    /// Connects two nodes and seats an UNCOMMITTED slot at each end, each with its own coordinator
    /// so inbound frames are attributed to the peer that actually sent them.
    func link(_ near: Int, _ far: Int) {
        fabric.connect(nodes[near].handle, nodes[far].handle)
        seat(near, toward: far)
        seat(far, toward: near)
    }

    /// Seats one direction: a slot with **no** fingerprint, which is what a pre-dwell candidate is.
    private func seat(_ index: Int, toward peer: Int) {
        let node = nodes[index]
        let coordinator = MeshP3Acceptance.coordinator()
        node.coordinators[nodes[peer].handle.endpoint] = coordinator
        node.manager.addSlotForTesting(
            coordinator: coordinator, peer: nodes[peer].handle,
            fingerprint: nil, channel: node.channel
        )
    }

    /// Drives the REAL dwell commit at `near` for the slot facing `far`.
    ///
    /// - Parameters:
    ///   - near: The committing device.
    ///   - far: The peer whose dwell committed.
    ///   - binding: The install binding the founding's own seal runs under; `.unavailable` is how a
    ///     cell drives a founding the store refuses.
    func commit(_ near: Int, _ far: Int, binding: DeviceBindingID.TestOverride? = nil) {
        let node = nodes[near]
        guard let index = node.manager.slots.firstIndex(where: {
            $0.peer.isSameEndpoint(as: nodes[far].handle)
        }) else {
            #expect(Bool(false), "the rig must seat a slot before it commits one")
            return
        }
        DeviceBindingID.$testOverride.withValue(binding ?? .identifier(MeshP3Acceptance.install)) {
            node.manager.commitSlotForTesting(
                at: index, peer: identities[far], displayName: nodes[far].label,
                capabilities: ProximityCapability.allCases.map(\.rawValue)
            )
        }
    }

    /// Lets the managers' detached sends run, moves the fabric forward, and delivers what arrived.
    ///
    /// It cannot be `MeshDepartureRig.settle`, and the reason is the whole membership family: that
    /// pump dispatches with `from: nil`, and `dispatchMembershipPayload` reads the SENDER off that
    /// `PeerIdentity` — so a descriptor arrives with no sender fingerprint, an admission request is
    /// dropped by its `senderFP == request.requesterFingerprint` guard, and a grant has no
    /// authenticated admitter. Every existing rig only ever exercised the `dispatchMembershipEvent`
    /// family, which attributes off the SLOT. This one hands each frame the identity of the node
    /// that actually sent it, which is what the real `ProximityCoordinator` does after a verified
    /// introduction.
    func settle(_ live: [Int]? = nil, until isDone: () -> Bool = { false }) async throws {
        let participants = live ?? Array(nodes.indices)
        // R2: two bounded loops, both over the rig's own constants.
        for _ in 0..<MeshDepartureRig.settleRounds {
            for _ in 0..<MeshDepartureRig.yieldsPerRound { await Task.yield() }
            fabric.clock.advance(by: .milliseconds(50))
            for index in participants { try pump(nodes[index]) }
            if isDone() { return }
        }
    }

    /// Hands whatever the fabric delivered to `node` to its manager, over the coordinator that
    /// belongs to the sending peer and WITH that peer's verified identity, after the real envelope
    /// verification.
    ///
    /// - Parameter node: The receiving end.
    /// - Returns: How many frames were moved.
    @discardableResult
    private func pump(_ node: MeshDepartureNode) throws -> Int {
        var moved = 0
        let frames = node.channel.receivedFrames
        while node.delivered < frames.count, moved < MeshDepartureRig.maxPumpedFrames {
            let frame = frames[node.delivered]
            node.delivered += 1
            moved += 1
            guard let coordinator = node.coordinators[frame.peer.endpoint],
                  let sender = nodes.firstIndex(where: { $0.handle.isSameEndpoint(as: frame.peer) })
            else { continue }
            let envelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: frame.data)
            let plaintext = try envelope.verify(
                identityService: node.manager.identityForTesting, replayCache: node.replayCache
            )
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                node.manager.proximityCoordinator(
                    coordinator, didReceive: envelope, plaintext: plaintext,
                    from: peerIdentity(of: sender)
                )
            }
        }
        return moved
    }

    /// The handshake-verified identity a receiving manager sees for one node.
    private func peerIdentity(of index: Int) -> ProximityCoordinator.PeerIdentity {
        let identity = identities[index]
        return ProximityCoordinator.PeerIdentity(
            id: nodes[index].handle.id,
            displayName: nodes[index].label,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: identity.localFingerprint,
            rangingMode: .rssi,
            firstSeenAt: Date(),
            capabilities: ProximityCapability.allCases.map(\.rawValue)
        )
    }

    /// The derived roster at one node, re-derived exactly as shipping code does.
    func roster(_ index: Int) -> [String] {
        nodes[index].manager.membershipVerifier?.roster.memberFingerprints ?? []
    }

    /// Ends every session, so nothing outlives the scenario. Same order and same reason as
    /// `MeshRoutedDrainRig.teardown()`: the pending rotation is consumed BEFORE the session ends.
    func teardown() {
        // R2: bounded by the rig's own node count.
        for node in nodes { _ = node.manager.consumePendingRotationForTesting() }
        for node in nodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshFoundingAuditCapture

/// The audit lines one cell saw, so a NAMED refusal can be asserted as named.
///
/// Existence, never absence: `FernletAuditLog`'s capture handler is process-global, so `== 0` over
/// a token any other suite might emit is a per-cell claim on a process-wide signal (D-6a.10).
private final class MeshFoundingAuditCapture {
    private let lock = NSLock()
    private var storedLines: [(event: String, context: [String: String])] = []
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedLines.append((event, context))
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// How many lines carried `event`.
    func count(of event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == event }.count
    }
}

// MARK: - MeshPairwiseFoundingTests

/// P6 item 2: a mesh with a ledger at the first commit, the newborn-yield repair, the founding
/// pair's one auto-granted admission, and the lifecycle predicate the founding forced apart from
/// `isInSession`.
///
/// Serialized: every cell drives real seals and a shared process-global audit log.
@MainActor
@Suite(.serialized)
struct MeshPairwiseFoundingTests {

    // MARK: The election

    @Test func foundsPairwiseMeshIsATotalOrderWithExactlyOneWinner() {
        let low = "0000000000000001"
        let high = "ffffffffffffffff"
        #expect(MeshNetworkManager.foundsPairwiseMesh(local: low, peer: high),
                "the lower fingerprint keeps its mesh")
        #expect(!MeshNetworkManager.foundsPairwiseMesh(local: high, peer: low),
                "and the higher one yields, so exactly one of the two sides survives")
        #expect(!MeshNetworkManager.foundsPairwiseMesh(local: low, peer: low),
                "equal fingerprints mean one signing key, so neither side claims the mesh")
        // A chosen ordering over real provisioned fingerprints, which is the only form that can
        // assert the property at all — the instance form always has THIS device on the left.
        let pairs = [("aaaaaaaaaaaaaaa0", "aaaaaaaaaaaaaaa1"), ("0f0f0f0f0f0f0f0f", "f0f0f0f0f0f0f0f0")]
        for (first, second) in pairs {
            let winners = [
                MeshNetworkManager.foundsPairwiseMesh(local: first, peer: second),
                MeshNetworkManager.foundsPairwiseMesh(local: second, peer: first)
            ].filter { $0 }
            #expect(winners.count == 1, "exactly one side of a distinct pair keeps its mesh")
        }
    }

    // MARK: The founding

    @Test func aSingleCommittedPeerFoundsAMeshWithAnArmedLedger() async throws {
        let rig = try MeshFoundingRig.build(2, label: "found-one")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)

        let founder = rig.nodes[0].manager
        #expect(founder.currentMesh != nil, "one commit is a mesh")
        #expect(founder.membershipVerifier?.roster.memberCount == 1,
                "and an armed ledger holding this device's own admission")
        #expect(rig.roster(0) == [rig.identities[0].localFingerprint],
                "the founder is on its own derived roster from the first instant")
        #expect(founder.sessionCeiling != nil, "the session ceiling is armed at the founding")
        #expect(founder.sessionState == .activeForeground,
                "founded and then committed, exactly as startNewMesh plus a commit would be")
        #expect(founder.keyAdvertisements.advertisement(
            for: rig.identities[0].localFingerprint
        ) != nil, "seedFounderAdmission mints the addressing with the admission it is signed under")
    }

    @Test func aFoundingWhoseContextCannotBeSealedLeavesNoMesh() async throws {
        let rig = try MeshFoundingRig.build(2, label: "found-refused")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1, binding: .unavailable)

        let founder = rig.nodes[0].manager
        #expect(founder.currentMesh == nil, "a founding the store refused leaves no mesh")
        #expect(founder.membershipVerifier == nil, "and no ledger")
        #expect(founder.sessionCeiling == nil, "and no ceiling")
        #expect(founder.currentGroupKey == nil, "and no group key")
        #expect(founder.keyAdvertisements.all.isEmpty, "and no addressing")
        #expect(founder.hasCommittedPeer, "the SLOT is still committed — only the mesh is gone")
    }

    // MARK: The pair, end to end through the real doors

    @Test func aFoundingPairDerivesARosterOfTwoOnBothSides() async throws {
        let rig = try MeshFoundingRig.build(2, label: "pair-roster")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)

        try await rig.settle(until: {
            rig.roster(0).count == 2 && rig.roster(1).count == 2
        })

        let both = Set([rig.identities[0].localFingerprint, rig.identities[1].localFingerprint])
        #expect(Set(rig.roster(0)) == both, "the admitter's derived roster names both devices")
        #expect(Set(rig.roster(1)) == both,
                "and so does the joiner's, after the digest re-gossip rebases its bootstrap root")
        #expect(rig.nodes[0].manager.currentMesh?.meshID == rig.nodes[1].manager.currentMesh?.meshID,
                "one mesh, not two")
        #expect(rig.nodes[0].manager.pendingAdmissionRequests.isEmpty,
                "the founding pair's one admission needed no tap")
    }

    @Test func aSymmetricCommitLeavesOneMeshIDAndFullyUnwindsTheYielder() async throws {
        let rig = try MeshFoundingRig.build(2, label: "pair-yield")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        let minted = [rig.nodes[0].manager.currentMesh?.meshID, rig.nodes[1].manager.currentMesh?.meshID]
        #expect(Set(minted.compactMap { $0 }).count == 2, "both halves really did mint a mesh")

        try await rig.settle(until: {
            rig.roster(0).count == 2 && rig.roster(1).count == 2
        })

        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let winner = lowerFounds ? 0 : 1
        let yielder = lowerFounds ? 1 : 0
        #expect(rig.nodes[yielder].manager.currentMesh?.meshID == minted[winner],
                "the side the order names keeps its mesh and the other adopts it")
        // The unwind, in full: a yielder carrying a stale epoch would be refused droppedStaleEpoch
        // by the grant it then needs, and could never join anything for the rest of the session.
        #expect(rig.roster(yielder).count == 2,
                "which is only observable because the yielder went on to be admitted")
        #expect(rig.nodes[yielder].manager.localJoinedEpoch == 0,
                "the yielded mesh's epoch state went with it")
    }

    @Test func aMeshWithARosterOfTwoNeverYields() async throws {
        let rig = try MeshFoundingRig.build(3, label: "no-yield")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle([0, 1], until: {
            rig.roster(0).count == 2 && rig.roster(1).count == 2
        })
        let settled = rig.nodes[0].manager.currentMesh?.meshID

        // A third device founds its own mesh and offers its descriptor to the established pair.
        rig.link(0, 2)
        rig.commit(2, 0)
        try await rig.settle(until: { false })

        #expect(rig.nodes[0].manager.currentMesh?.meshID == settled,
                "a roster of two is a mesh somebody has joined, so it is never yielded")
        #expect(Set(rig.roster(0)).count == 2, "and its ledger is untouched by the offer")
    }

    @Test func aForeignDescriptorDropIsNamed() async throws {
        let capture = MeshFoundingAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let rig = try MeshFoundingRig.build(2, label: "foreign-drop")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: {
            rig.roster(0).count == 2 && rig.roster(1).count == 2
        })

        #expect(capture.count(of: "mesh.descriptor.yieldedNewbornMesh") > 0,
                "the yield is named")
        #expect(capture.count(of: "mesh.descriptor.droppedForeignMesh") > 0,
                "and so is the drop on the side that did NOT yield, which used to be silent")
    }

    @Test func aThirdCommitMergesIntoTheFoundedMeshAndInheritsItsAdvertisements() async throws {
        let rig = try MeshFoundingRig.build(3, label: "third-commit")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle([0, 1], until: {
            rig.roster(0).count == 2 && rig.roster(1).count == 2
        })
        let settled = rig.nodes[0].manager.currentMesh?.meshID

        // C's first commit lands on node 1, which is already a member of the pair's mesh. C founds
        // its own mesh first (nobody waits), then yields it when node 1's descriptor arrives.
        rig.link(1, 2)
        rig.commit(2, 1)
        rig.commit(1, 2)
        #expect(rig.nodes[2].manager.currentMesh?.meshID != settled, "C really did found its own")
        // The settle runs to C's ASK, not merely to its adoption: the yield, the adoption and
        // `sendAdmissionRequest` are one synchronous receive, but the send itself is a detached
        // task, so a settle that stopped at the adopted meshID would end a round too early.
        try await rig.settle(until: { rig.nodes[1].manager.pendingAdmissionRequests.count == 1 })

        #expect(rig.nodes[2].manager.currentMesh?.meshID == settled,
                "a third commit merges into the mesh that already exists")
        // The prompt is KEPT for the third device: the admitter's roster is 2, not 1.
        #expect(rig.nodes[1].manager.pendingAdmissionRequests.count == 1,
                "a third device is a stranger joining an established mesh, so it is prompted")
        guard let queued = rig.nodes[1].manager.pendingAdmissionRequests.first else { return }
        // Inside the pinned install: `allowAdmission` SPAWNS the grant, and the spawned task
        // inherits the task-local binding from here — the grant files a record durably, so a bare
        // call would seal against whatever the simulator's real install row happens to be.
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.nodes[1].manager.allowAdmission(queued)
        }
        try await rig.settle(until: { rig.roster(2).count >= 2 })

        #expect(Set(rig.roster(1)).count == 3, "the admitter files the third admission")
        // Item 1's residual, FLIPPED by item 1's fix commit (this cell pinned it as a negative so
        // the fix would have to flip it). A row relayed at the GRANT door arrives while the
        // joiner's ledger is still the one-record bootstrap its admitter rooted, in which the
        // admitter itself is not an admitted member — so the fold refuses it `signerNotAdmitted`
        // and the joiner now PARKS it until a widening can prove it. `attemptLedgerAdoption` is
        // that widening: it rebases the joiner off its bootstrap root and re-offers the park, so
        // both halves of a first grant hold each other's row with NO merge exchange anywhere.
        // Roles, never indices: the rig's identities are freshly provisioned, so WHICH half of the
        // pair founds is decided per run by the election. (Two counts written as `nodes[0]` and
        // `nodes[1]` swapped between runs of this file, which is how this was caught.)
        let zeroFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let pairFounder = zeroFounds ? 0 : 1
        let pairJoiner = zeroFounds ? 1 : 0
        #expect(rig.nodes[pairFounder].manager.keyAdvertisements.advertisement(
            for: rig.identities[pairJoiner].localFingerprint
        ) != nil, "the pair's founder folded its joiner's row, re-stated after the adoption")
        #expect(rig.nodes[pairJoiner].manager.keyAdvertisements.advertisement(
            for: rig.identities[pairFounder].localFingerprint
        ) != nil, "and the joiner holds its admitter's, parked at the grant and proved at adoption")
        #expect(rig.nodes[2].manager.keyAdvertisements.advertisement(
            for: rig.identities[2].localFingerprint
        ) != nil, "a third device arms its own row at its join")
        #expect(rig.nodes[2].manager.keyAdvertisements.advertisement(
            for: rig.identities[0].localFingerprint
        ) != nil, "and can address the member it never linked — D-13.22's star, closed on this path")
    }

    // MARK: The auto-grant, and every gate it must not bypass

    @Test func theAdmissionPromptIsKeptExceptForTheFoundingPair() throws {
        // Positive: a founded mesh with a derived roster of one, a dwell-committed requester, an
        // open proximity-join session ⇒ granted without a tap.
        let granted = try Self.admissionOutcome(label: "auto-yes")
        #expect(granted.members == 2, "the founding pair's admission is granted synchronously")
        #expect(granted.pending == 0, "so nothing is queued for a prompt")

        // Every negative, one at a time, against the same shape.
        let closed = try Self.admissionOutcome(label: "auto-closed", closeSession: true)
        #expect(closed.members == 1, "a session the user closed keeps the prompt")
        #expect(closed.pending == 1, "and queues the request instead")

        let notJoin = try Self.admissionOutcome(label: "auto-nonjoin", proximityJoin: false)
        #expect(notJoin.members == 1, "a non-proximity-join founding keeps the prompt")
        #expect(notJoin.pending == 1, "there was no 15 cm dwell to stand in for the tap")

        // The block-list gate, tested through the mechanism that actually enforces it: a blocked
        // signing key never reaches `.connected` (`ProximityCoordinator.isRejectedByTrustPolicy`
        // drops every envelope from a revoked key), so it never holds a COMMITTED slot — and an
        // uncommitted requester is exactly the stranger the prompt exists for.
        let stranger = try Self.admissionOutcome(label: "auto-uncommitted", requesterCommitted: false)
        #expect(stranger.members == 1, "a requester with no committed slot is never auto-granted")
        #expect(stranger.pending == 1, "it is queued for the prompt like any stranger")
    }

    /// Founds a mesh at one commit, then delivers ONE signed admission request through the
    /// production receive door, and reports what the admitter did.
    ///
    /// - Parameters:
    ///   - label: The diagnostic prefix.
    ///   - proximityJoin: `false` founds through ``MeshNetworkManager/startNewMesh(name:)``
    ///     instead, which is a mesh with no dwell behind it.
    ///   - closeSession: `true` closes the session before the request arrives.
    ///   - requesterCommitted: `false` has a THIRD device ask from an uncommitted slot, which is
    ///     the shape a blocked peer is permanently stuck in.
    /// - Returns: The descriptor's member count and the prompt queue's depth, both read
    ///   synchronously (`allowAdmission` appends the member before it spawns the grant).
    private static func admissionOutcome(
        label: String,
        proximityJoin: Bool = true,
        closeSession: Bool = false,
        requesterCommitted: Bool = true
    ) throws -> (members: Int, pending: Int) {
        let store = makeTestStore()
        let local = try MeshPartitionFixtures.identity("\(label)-local")
        let peer = try MeshPartitionFixtures.identity("\(label)-peer")
        let stranger = try MeshPartitionFixtures.identity("\(label)-stranger")
        let manager = MeshNetworkManager(
            store: store, transport: FakeMeshTransportSession(), identity: local
        )
        defer { manager.leaveMesh() }
        let coordinator = Self.seatUncommittedSlot(on: manager)
        let strangerCoordinator = Self.seatUncommittedSlot(on: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            if proximityJoin {
                manager.markProximityJoinForTesting()
                manager.commitSlotForTesting(at: 0, peer: peer, displayName: "Peer")
            } else {
                manager.startNewMesh(name: "Acceptance Meadow")
            }
        }
        #expect(manager.currentMesh != nil, "the setup needs a founded mesh to admit into")
        #expect(manager.membershipVerifier?.roster.memberCount == 1,
                "and a derived roster of exactly one, which is the gate under test")
        if closeSession { manager.setSessionOpen(false) }
        guard let mesh = manager.currentMesh else { return (0, 0) }
        let requester = requesterCommitted ? peer : stranger
        try Self.deliverAdmissionRequest(
            MeshAdmissionRequestPayload(
                meshID: mesh.meshID,
                requesterFingerprint: requester.localFingerprint,
                requesterDisplayName: "Requester",
                requesterSigningPublicKey: requester.localSigningPublicKey,
                requesterKeyAgreementPublicKey: requester.localKeyAgreementPublicKey
            ),
            to: manager, from: requester,
            over: requesterCommitted ? coordinator : strangerCoordinator
        )
        return (manager.currentMesh?.members.count ?? 0, manager.pendingAdmissionRequests.count)
    }

    /// Delivers one signed admission request through the production receive door **with** the
    /// sender's verified `PeerIdentity`, which `dispatchMembershipPayload` reads the requester's
    /// authenticated fingerprint off (`MeshP3Acceptance.deliver` passes `nil` and the request would
    /// be dropped unattributed).
    private static func deliverAdmissionRequest(
        _ request: MeshAdmissionRequestPayload,
        to manager: MeshNetworkManager,
        from sender: IdentityService,
        over coordinator: ProximityCoordinator
    ) throws {
        let plaintext = try JSONEncoder().encode(request)
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Requester",
            payloadType: .meshAdmissionRequest,
            payloadSummary: PayloadSummary(title: "Admission"),
            payload: plaintext
        )
        let identity = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Requester",
            signingPublicKey: sender.localSigningPublicKey,
            keyAgreementPublicKey: sender.localKeyAgreementPublicKey,
            fingerprint: sender.localFingerprint,
            rangingMode: .rssi,
            firstSeenAt: Date(),
            capabilities: ProximityCapability.allCases.map(\.rawValue)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.proximityCoordinator(
                coordinator, didReceive: envelope, plaintext: plaintext, from: identity
            )
        }
    }

    /// Seats one pre-dwell candidate slot and returns the coordinator its frames arrive over.
    private static func seatUncommittedSlot(on manager: MeshNetworkManager) -> ProximityCoordinator {
        let coordinator = MeshP3Acceptance.coordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: PeerHandle(
                id: UUID(), displayHint: "iPhone", discoveryInfo: ["v": "1"],
                advertisedFingerprint: nil, endpoint: PeerEndpointKey()
            ),
            fingerprint: nil
        )
        return coordinator
    }

    // MARK: The lifecycle predicate

    @Test func hasCommittedPeerTracksTheSlotsAndNotTheMesh() async throws {
        let rig = try MeshFoundingRig.build(2, label: "predicate")
        defer { rig.teardown() }
        let manager = rig.nodes[0].manager
        #expect(!manager.hasCommittedPeer, "no slot, no committed peer")
        #expect(!manager.isInSession, "and no session")
        rig.link(0, 1)
        #expect(!manager.hasCommittedPeer, "a seated, uncommitted slot is not a committed peer")
        rig.commit(0, 1)
        #expect(manager.hasCommittedPeer, "the dwell commit is what makes it one")
        #expect(manager.isInSession, "both predicates agree while the link is up")

        guard let slot = manager.slots.first else { return }
        manager.evictSlotForTesting(peerID: slot.id)
        #expect(!manager.hasCommittedPeer, "the last committed slot going away ends the session")
        #expect(manager.isInSession,
                "while `isInSession` stays true, because the founded mesh outlived the link")
    }

    @Test func theOnlyPeerLeavingEndsTheSessionForTheReviewShopAndTranscript() async throws {
        let rig = try MeshFoundingRig.build(2, label: "session-end")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        #expect(manager.currentMesh != nil, "the founding is the precondition for the regression")

        // The three hooks each need something to do, or the cell is green over nothing.
        manager.sessionMessages.appendOutgoing(
            id: UUID(), senderFingerprint: rig.identities[0].localFingerprint,
            senderDisplayName: "Local", text: "hello", sentAt: Date()
        )
        manager.clothingShop.isSharingEnabledProvider = { true }
        let catalog = try Self.catalogEnvelope(displayName: "Peer")
        manager.clothingShop.receiveCatalog(
            catalog.envelope, plaintext: catalog.plaintext,
            verifiedFingerprint: rig.identities[1].localFingerprint, now: Date()
        )
        #expect(!manager.sessionRoster.isEmpty, "the commit recorded a review candidate")
        #expect(!manager.sessionMessages.messages.isEmpty, "there is a transcript to clear")
        #expect(manager.clothingShop.window == nil, "and no shop window while the session is live")

        guard let slot = manager.slots.first else { return }
        manager.evictSlotForTesting(peerID: slot.id)

        #expect(manager.currentMesh != nil,
                "the mesh is STILL there — which is the whole reason `isInSession` cannot be the test")
        #expect(manager.pendingFriendReview != nil, "the keep-as-friend batch promoted")
        #expect(manager.sessionMessages.messages.isEmpty, "the transcript vanished at session end")
        #expect(manager.clothingShop.window != nil, "and the post-session shop window opened")
    }

    @Test func aCommittedPeerAppearsInSessionParticipantsBeforeItIsAdmitted() async throws {
        let rig = try MeshFoundingRig.build(2, label: "participants")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)

        let manager = rig.nodes[0].manager
        #expect(manager.currentMesh?.members.count == 1,
                "a freshly founded descriptor holds exactly this device")
        let others = manager.sessionParticipants.filter { !$0.isLocal }
        #expect(others.map(\.fingerprint) == [rig.identities[1].localFingerprint],
                "and the committed peer is a participant anyway — the list is a union, not a choice")
        #expect(manager.sessionParticipants.count == 2, "with no duplicate of the local user")

        // A11: the pairwise removal shortcut fires only with exactly one other participant, so the
        // union is what keeps "remove the only other person" reachable at all.
        guard let peer = others.first else { return }
        manager.proposeRemoval(of: peer)
        #expect(manager.pendingRemovalProposals.isEmpty,
                "so removing the only peer ends the session instead of opening a vote nobody can win")
        #expect(!manager.sessionRoster.contains { $0.fingerprint == peer.fingerprint },
                "and the peer the user asked to remove is never offered by the keep prompt")
    }

    /// A minimal signed-shape clothing catalog, so the shop has something to keep a window for.
    ///
    /// The envelope's signature fields are empty because `receiveCatalog` is handed an
    /// ALREADY-verified fingerprint — this cell is about the session-end hook, not the wire.
    private static func catalogEnvelope(
        displayName: String
    ) throws -> (envelope: FernletIdentityEnvelope, plaintext: Data) {
        let item = CustomizationItem(
            name: "Star Cape",
            slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: UUID()),
            isShareable: true,
            price: 7
        )
        let payload = ClothingCatalogPayload(
            designerID: UUID(), displayName: displayName, items: [item]
        )
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: displayName,
            recipientFingerprint: nil,
            payloadType: .clothingCatalog,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Clothing shop"),
            payload: plaintext,
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
        return (envelope, plaintext)
    }
}
