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

    /// Re-seats ONE direction of an already-connected pair, for the cell that stands one end's
    /// radios down (`stopJoin()` empties `slots`) and brings them back while the other end never
    /// moved. `link` would double-seat the end that still holds its slot.
    func reseat(_ index: Int, toward peer: Int) { seat(index, toward: peer) }

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

    // MARK: The routed content path, on a mesh nothing seeded

    /// Captures one photo at `node` through the real public API, under the pinned install binding.
    ///
    /// The whole point of the delivery cells: `addPhoto` → `shareRoutedPhoto` →
    /// `originateRoutedItem` is the app's own path, and before item 2 its first guard
    /// (`membershipVerifier?.roster`) skipped every capture a proximity session ever made.
    func capturePhoto(at node: Int) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.addPhoto(MeshRoutedPhotoFixtures.tinyJPEG())
        }
    }

    /// One node's loaded routed index under the pinned install binding, or nil for every
    /// non-`.loaded` state. Built per use, exactly as the manager builds its own.
    func routedIndex(_ node: Int) -> MeshRoutedIndex? {
        let load = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            MeshRoutedStore(scope: nodes[node].store.meshRoutedStorage).load()
        }
        guard case .loaded(let index, _) = load else { return nil }
        return index
    }

    /// Opens one node's routed access gate, which is what lets a delivered item be decrypted and
    /// projected onto the wall.
    func openGate(at node: Int) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = nodes[node].manager.applyRoutedAccessGate(
                MeshRoutedDrainRig.openGate, now: Date()
            )
        }
    }

    /// How many wall entries `node` holds for one item id — the assertion made at the RECIPIENT,
    /// which is the only one that separates a delivery from a successful mint.
    func wallEntries(at node: Int, itemID: UUID) -> Int {
        nodes[node].manager.meshPhotos.filter { $0.id == itemID }.count
    }

    /// The item id of the routed item `node` staged as its OWN origin, or nil.
    ///
    /// Keyed on the origin fingerprint rather than `items.first`: once delivery starts, a node's
    /// index holds inbound items too, and "the item I minted" is the only one a sender claim is
    /// about.
    func stagedOwnItemID(at node: Int) -> UUID? {
        let fingerprint = nodes[node].fingerprint
        return routedIndex(node)?.items.first { $0.key.originFingerprint == fingerprint }?.key.itemID
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
        // "An abandoned founding is never silent" (P3 item 6) — and the unwind must not erase its
        // own diagnosis. `clearGroupKeyState()` nils this field, so `unwindNewbornMesh()` carries
        // it across; without that carry, the seal refusal that abandoned the founding is
        // unexplainable and `MeshSessionStateMachineTests.aRefusedSealAbandonsTheFounding` goes red.
        #expect(founder.lastRotationBlockReason != nil,
                "and the reason the founding was abandoned survives the unwind that abandoned it")
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

    /// The yield, and the **whole** unwind — over a yielder that really is carrying key state.
    ///
    /// Pass A's version of this cell asserted `localJoinedEpoch == 0` in a rig where no rotation can
    /// fire (the first one is scheduled 15 minutes out on the real clock while the rig advances only
    /// `fabric.clock`), so it was green over nothing: deleting `clearGroupKeyState()` from
    /// `unwindNewbornMesh()` failed no assertion in the file. The newborn mesh is now put on a real
    /// epoch **before** the settle, which is what a yielder whose 15-minute rotation had already
    /// fired looks like — and `roster(yielder).count == 2` becomes the failing assertion, because
    /// the winner's keyless grant carries epoch 0 and `handleAdmissionGrant`'s monotonicity guard
    /// drops it `droppedStaleEpoch` against a standing epoch-1 key. The device could then never join
    /// anything for the rest of the session.
    @Test func aSymmetricCommitLeavesOneMeshIDAndFullyUnwindsTheYielder() async throws {
        let rig = try MeshFoundingRig.build(2, label: "pair-yield")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        let minted = [rig.nodes[0].manager.currentMesh?.meshID, rig.nodes[1].manager.currentMesh?.meshID]
        #expect(Set(minted.compactMap { $0 }).count == 2, "both halves really did mint a mesh")

        // Roles, not indices: the identities are freshly provisioned, so the election decides which
        // half yields per run.
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let winner = lowerFounds ? 0 : 1
        let yielder = lowerFounds ? 1 : 0
        MeshDepartureRig.seedEpoch(rig.nodes[yielder], head: MeshEpochRef(
            counter: 1, epochID: UUID(),
            coordinatorFingerprint: rig.identities[yielder].localFingerprint
        ))
        #expect(rig.nodes[yielder].manager.currentGroupKey?.epoch == 1,
                "the newborn mesh the yield is about to unwind really holds a key")

        try await rig.settle(until: {
            rig.roster(0).count == 2 && rig.roster(1).count == 2
        })

        #expect(rig.nodes[yielder].manager.currentMesh?.meshID == minted[winner],
                "the side the order names keeps its mesh and the other adopts it")
        // The unwind, in full: a yielder carrying a stale epoch is refused droppedStaleEpoch by the
        // grant it then needs, so this assertion is the one that fails without clearGroupKeyState().
        #expect(rig.roster(yielder).count == 2,
                "which is only observable because the yielder went on to be admitted")
        #expect(rig.nodes[yielder].manager.localJoinedEpoch == 0,
                "the yielded mesh's epoch state went with it")
        #expect(rig.nodes[yielder].manager.currentGroupKey == nil,
                "and so did its group key, which is what let the keyless grant through")
        // P6 item 6 fix review, P1-1: the unwind reset the machine to `.idle` and the admission
        // re-entered at `.joining`, whose ONLY edge out is a `.peerCommitted` this pair will never
        // raise again — the yielder's slot committed BEFORE the yield. It sat there for the rest of
        // the session, and the one routed predicate that reads the session (the heart stage) was
        // false throughout. `recordVerifiedAdmissionDurably` now re-asserts that commit.
        #expect(rig.nodes[yielder].manager.sessionState == .activeForeground,
                "a yielder that adopted a mesh over a COMMITTED slot is live, not still joining")
        #expect(rig.nodes[winner].manager.sessionState == .activeForeground,
                "and the winner never left it")
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
        let capture = MeshFoundingAuditCapture()
        capture.install()
        defer { capture.uninstall() }

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
        let queued = try #require(rig.nodes[1].manager.pendingAdmissionRequests.first,
                                  "the prompt queue must hold the third device's request")
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
        #expect(capture.count(of: "mesh.keyAgreement.parked") > 0, """
            named as the MECHANISM, not inferred from the row: a row that was never sent would \
            satisfy the assertion above, and a row that verified straight away would mean the \
            refusal this scenario exists for never happened
            """)
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
        #expect(manager.isInSession, "all three predicates agree while the link is up")
        #expect(manager.isSessionLive, "including the lifecycle one")

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)
        #expect(!manager.hasCommittedPeer, "the last committed slot going away loses the peer")
        #expect(manager.isInSession,
                "while `isInSession` stays true, because the founded mesh outlived the link")
        #expect(manager.isSessionLive, """
            and so does `isSessionLive`: a lost slot is a BLIP, not a session end — the mesh, its \
            ledger and its ceiling are all still here and the pair can resume
            """)
    }

    /// **The P1 of pass A's review.** A founded pair whose link dropped can get its radios back —
    /// and gets them back without re-founding, re-resetting or re-arming anything.
    ///
    /// The outage the seam closes is three moves long and every move ships: a link drop deletes the
    /// committed slot outright (no re-invite retry — that path is guarded on the slot never having
    /// committed), a tab exit or a scene change then runs `stopJoin()` → `stopSearching()` (radios
    /// off, `isProximityJoin` false, slots emptied), and on return `startFriendsDiscovery`'s
    /// `!isInSession` guard passes over it because the founded mesh outlived the link. There was no
    /// other shipping re-arm: `startSearching()` is private. The user was left looking at a live
    /// camera over a session with no radios, with End Session the only escape.
    ///
    /// What the cell pins is why the answer is not "point that guard at `hasCommittedPeer`":
    /// `startJoin()` nils the session ceiling (through `resetSessionStateMachine`) on a mesh that
    /// can never re-found — `promoteToMesh()` fires only on `currentMesh == nil` — which is a
    /// session that can no longer expire, and it also clears `sessionPhotos`, the film quota and the
    /// removal set. So the ceiling, the ledger, the meshID and the photo count are all asserted
    /// AFTER the resume, and a re-formed link is asserted to MERGE rather than found.
    ///
    /// Driven on the election's **winner**, by role and never by index, because the ceiling claim
    /// belongs to the side that kept the mesh it founded. The yielder's `unwindNewbornMesh()` nils
    /// its ceiling and, since P7 item 4, the adoption re-arms one from the winner's mesh
    /// (`armSessionCeilingFromAdoptedMeshIfNeeded(now:)`) — asserted below as the closed residual
    /// it now is; `MeshSessionPollTests` drives that ceiling to its end. Written as `nodes[0]` this
    /// cell passed or failed on which of two random fingerprints was lower.
    @Test func aPartitionedPairReArmsItsRadiosWithoutReFoundingItsMesh() async throws {
        let rig = try MeshFoundingRig.build(2, label: "re-arm")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let winner = lowerFounds ? 0 : 1
        let yielder = lowerFounds ? 1 : 0
        let manager = rig.nodes[winner].manager
        #expect(rig.nodes[yielder].manager.sessionCeiling != nil, """
            P6's named residual, closed by P7 item 4: a yielder now arms a ceiling from the mesh it \
            adopted, exactly as every proximity joiner does — and `pollSession(now:)` enforces it
            """)
        rig.capturePhoto(at: winner)
        let founded = try #require(manager.currentMesh?.meshID)
        let ceiling = try #require(manager.sessionCeiling)
        #expect(manager.photosAddedThisSession == 1, "the session has a spent film shot to lose")

        // The link drops, and then the user leaves the tab: exactly the shipping sequence.
        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)
        manager.stopJoin()
        #expect(!manager.isSearching, "the radios really are down")
        #expect(manager.isInSession, "while the mesh outlived the link, which is the trap")
        #expect(!manager.hasCommittedPeer, "and no peer is committed, which is the way out of it")
        #expect(manager.currentGroupKey == nil, """
            the loss the resume cannot avoid, named because the doc enumerates `startJoin`'s \
            resets and this one is `stopSearching`'s: `clearGroupKeyState()` has already taken the \
            group key, the epoch keyring and the rotation/beacon timers, so the resumed session is \
            keyless until the heal's merge or the next rotation re-keys it
            """)

        manager.resumeSearchingForPartitionedMesh()

        #expect(manager.isSearching, "the radios come back")
        #expect(manager.isProximityJoin, "in proximity-join mode, so a discovered peer is invited")
        #expect(manager.currentMesh?.meshID == founded, "over the SAME mesh — nothing re-founded")
        #expect(rig.roster(winner).count == 2, "with the membership ledger untouched")
        #expect(manager.sessionCeiling?.hardDeadline == ceiling.hardDeadline,
                "and the ceiling still armed, which `startJoin()` would have nilled for good")
        #expect(manager.photosAddedThisSession == 1, "the film quota is not handed back")
        #expect(manager.sessionPhotos.count == 1, "and the session's photos are still there")

        // The peer comes back. `onSlotConnected` must fall through the founding, not re-enter it.
        rig.reseat(winner, toward: yielder)
        rig.commit(winner, yielder)
        #expect(manager.currentMesh?.meshID == founded,
                "a re-formed link merges into the mesh it left, it does not found a second one")
        #expect(manager.hasCommittedPeer, "and the session is live again")
        #expect(rig.roster(winner).count == 2, "on the same derived roster")
    }

    /// The edge each half of `ConnectView`'s split transition handler hangs off (review finding
    /// P2-4): `hasCommittedPeer` moves in BOTH directions across a blip and a heal while
    /// `isInSession` never moves at all.
    ///
    /// That asymmetry is why the two readers at that one `.onChange` had to be split. The layout
    /// swap and the camera chrome read `isInSession`, so a blipped pair keeps its camera — it still
    /// holds a mesh with a ledger, and a capture during the blip is sealed into custody and drained
    /// at the heal. The keep-as-friend ceremony and the connection choreography read
    /// `hasCommittedPeer`, because on `isInSession` their `!was && now` arm is **dead** for a
    /// founded pair: a standing keep prompt would never be abandoned across a heal, and
    /// `finalizeFriendKeeps` would mint friends and consume the batch mid-session on dismissal.
    @Test func aBlipAndAHealMoveTheCommittedPeerEdgeWhileIsInSessionNeverMoves() async throws {
        let rig = try MeshFoundingRig.build(2, label: "blip-edge")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        #expect(manager.isInSession && manager.hasCommittedPeer, "both true at the first commit")

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)
        #expect(manager.isInSession, "the blip does not move the layout predicate")
        #expect(!manager.hasCommittedPeer, "and does move the peer-presence one")
        #expect(manager.isSessionLive, "and does NOT move the lifecycle one — a blip is not an end")

        rig.reseat(0, toward: 1)
        rig.commit(0, 1)
        #expect(manager.isInSession, "the heal does not move the layout predicate either")
        #expect(manager.hasCommittedPeer, """
            so the heal's edge exists ONLY on the peer-presence predicate — the arm that abandons \
            a standing session-end sheet has to read this one or it never fires for a pair
            """)
    }

    // MARK: Session end means MESH end (the pass-B review's P1)

    /// **The P1 of pass B's review.** A link BLIP runs no part of the session-end ceremony.
    ///
    /// Before the fix every slot loss did: `removeSlot` fired all three hooks on
    /// `!hasCommittedPeer` alone, so a two-second drop promoted the keep-as-friend batch, cleared
    /// the live chat transcript and opened the post-session shop window — and `ConnectView`'s
    /// committed-peer arm presented the photo-review sheet over the still-live camera, whose BOTH
    /// actions call `leaveSessionAfterNotifyingPeers()`. For a pair that is
    /// `MeshDevelopmentPlan.ending == .termination`: a signed termination plus a permanent rejoin
    /// bar, on a mesh item 2 deliberately keeps alive so the pair can resume — asymmetric,
    /// irreversible, one tap, and the peer (unreachable at that instant) never hears about it.
    ///
    /// The ceremony now fires from ``MeshNetworkManager/isSessionLive`` going false, which for a
    /// mesh-holding session means the MESH ended. The three hooks keep their call sites: slot loss
    /// still ends a session that has no mesh to outlive it.
    @Test func aBlipPresentsNothingAndClearsNothing() async throws {
        let rig = try MeshFoundingRig.build(2, label: "blip-quiet")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)

        #expect(manager.isSessionLive, "the mesh is untouched, so the session did not end")
        #expect(manager.pendingFriendReview == nil, """
            nothing to present: the review sheet is gated on `isSessionLive`, and its primary \
            action would have signed a termination on a mesh this pair can still resume
            """)
        #expect(!manager.sessionMessages.messages.isEmpty, "the live transcript is still the room's")
        #expect(manager.clothingShop.window == nil, "and the post-session shop window stays shut")
        #expect(!manager.sessionRoster.isEmpty, "with the review candidate still in the live roster")
    }

    /// The other half of the blip: what the pair gets back. The transcript the blip did not clear is
    /// still there after the radios come back and the link re-forms.
    @Test func aBlipAResumeAndAReLinkKeepThePreBlipTranscript() async throws {
        let rig = try MeshFoundingRig.build(2, label: "blip-resume")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")
        let before = manager.sessionMessages.messages.map(\.text)

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)
        manager.stopJoin()
        manager.resumeSearchingForPartitionedMesh()
        rig.reseat(0, toward: 1)
        rig.commit(0, 1)

        #expect(manager.hasCommittedPeer, "the pair is linked again")
        #expect(manager.isSessionLive, "on the session it never left")
        #expect(manager.sessionMessages.messages.map(\.text) == before, """
            and the room's messages are the pre-blip ones: a tab bounce over a live mesh runs \
            `stopSearching()`, whose transcript hook is now gated on the session having ENDED
            """)
        #expect(manager.pendingFriendReview == nil, "with no batch promoted along the way")
        #expect(manager.clothingShop.window == nil, "and no shop window opened along the way")
    }

    /// Gives all three session-end hooks something to do, so a cell asserting they did not fire is
    /// not green over nothing: a live transcript, a held shop catalog, and a review candidate (the
    /// commit itself records that one).
    private static func armTheThreeHooks(
        on manager: MeshNetworkManager, peer: IdentityService, label: String
    ) throws {
        manager.sessionMessages.appendOutgoing(
            id: UUID(), senderFingerprint: manager.localFingerprint,
            senderDisplayName: "Local", text: "hello", sentAt: Date()
        )
        manager.clothingShop.isSharingEnabledProvider = { true }
        let catalog = try Self.catalogEnvelope(displayName: label)
        manager.clothingShop.receiveCatalog(
            catalog.envelope, plaintext: catalog.plaintext,
            verifiedFingerprint: peer.localFingerprint, now: Date()
        )
        #expect(!manager.sessionRoster.isEmpty, "the commit recorded a review candidate")
        #expect(!manager.sessionMessages.messages.isEmpty, "there is a transcript to clear")
        #expect(manager.clothingShop.window == nil, "and no shop window while the session is live")
    }

    /// A second entry into the founding for one session is refused and named, rather than minting a
    /// second descriptor over a live mesh (review finding P3-7).
    ///
    /// The refusal matters because `prepareMembershipLedger` replaces the verifier outright for a
    /// different meshID: a second founding would take the session's whole ledger with it, silently.
    /// Driven through the real trigger — a second slot committing on a mesh this device founded —
    /// which is the shape a third device joining a pair actually produces.
    @Test func aSecondFoundingForOneSessionIsRefusedAndNamed() async throws {
        let capture = MeshFoundingAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let rig = try MeshFoundingRig.build(3, label: "promote-once")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        let founded = try #require(manager.currentMesh?.meshID)
        let verifier = try #require(manager.membershipVerifier)

        rig.link(0, 2)
        rig.commit(0, 2)

        #expect(manager.currentMesh?.meshID == founded, "the founding fired exactly once")
        #expect(manager.membershipVerifier?.meshID == verifier.meshID,
                "and the session's ledger is the one the founding armed")
        #expect(rig.roster(0) == [rig.identities[0].localFingerprint],
                "a second commit is not an admission, so the derived roster did not move")
        #expect(capture.count(of: "mesh.promotion.refusedExistingMesh") == 0,
                "the caller's own `currentMesh == nil` gate is what kept it out")
        // And the guard inside the function refuses when it IS reached directly.
        #expect(!manager.promoteToMeshForTesting(),
                "the invariant lives with the function, not only with its one caller")
        #expect(capture.count(of: "mesh.promotion.refusedExistingMesh") == 1, "and it is named")
        #expect(manager.currentMesh?.meshID == founded, "with nothing touched")
    }

    /// A user who CLOSED the session and then LOST the founder election keeps their choice (review
    /// finding P2-5).
    ///
    /// Before the fix `handleMeshDescriptor`'s `isSessionOpen = currentMesh?.mode == .open` simply
    /// replaced it with the winner's, and an open mesh's TXT publishes `meshID` / `meshName` /
    /// `memberCount` — which is precisely what closing opts out of. Whether the choice survived was
    /// a coin flip on two fingerprints. Re-applying it is a legitimate member act: `setMeshMode` is
    /// `public`, gates on nothing but holding a mesh, and the descriptor merge resolves `mode` by
    /// last-write-wins with no founder check.
    @Test func aYielderThatHadClosedItsSessionStaysClosedAfterAdopting() async throws {
        let rig = try MeshFoundingRig.build(2, label: "yield-closed")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let yielder = lowerFounds ? 1 : 0
        let winner = lowerFounds ? 0 : 1
        rig.nodes[yielder].manager.setSessionOpen(false)
        #expect(rig.nodes[yielder].manager.currentMesh?.mode == .closed,
                "the user closed the mesh they founded")
        #expect(rig.nodes[winner].manager.currentMesh?.mode == .open, "the other side did not")

        try await rig.settle(until: {
            rig.nodes[yielder].manager.currentMesh?.meshID
                == rig.nodes[winner].manager.currentMesh?.meshID
        })

        #expect(rig.nodes[yielder].manager.currentMesh?.meshID
                == rig.nodes[winner].manager.currentMesh?.meshID, "the yield happened")
        #expect(rig.nodes[yielder].manager.currentMesh?.mode == .closed,
                "and the yielder re-applied its own closed choice to the mesh it adopted")
        #expect(!rig.nodes[yielder].manager.isSessionOpen,
                "so the control the user touched still reads closed")
        #expect(rig.nodes[yielder].manager.currentDiscoveryInfo()["meshID"] == nil,
                "and the TXT publishes no mesh identifiers, which is what closing is for")

        // The other device, which is where pass B's fix stopped (review findings P2-2 and P2-3).
        try await rig.settle(until: { rig.nodes[winner].manager.currentMesh?.mode == .closed })
        #expect(rig.nodes[winner].manager.currentMesh?.mode == .closed, """
            the WINNER goes closed too — which needs the re-assert's stamp to be monotonic in the \
            descriptor it answers: on a bare `Date()` the yielder stamps in the past of the \
            winner's own clock and the close is discarded at the winner's merge door
            """)
        #expect(!rig.nodes[winner].manager.isSessionOpen, "and its own control reads closed")
        let winnerRadio = try #require(
            rig.nodes[winner].manager.transportForTesting as? FakeMeshTransportSession
        )
        #expect(winnerRadio.republishedDiscoveryInfo.last?["meshID"] == nil, """
            and its RADIO stopped advertising the mesh: `handleMeshDescriptor` published nothing at \
            all before the fix, so the winner's model said closed while its Bonjour TXT kept \
            carrying meshID / meshName / memberCount for the rest of the session
            """)
        #expect(winnerRadio.republishedDiscoveryInfo.last?["memberCount"] == nil,
                "nor the member count")
    }

    /// A session the user CLOSED is not re-opened by a later descriptor, however it is stamped
    /// (review finding P2-3).
    ///
    /// The mode merges last-write-wins on `modeSetAt`, and an incoming stamp is clamped only from
    /// ABOVE (`Date() + 60`) — so a peer whose clock runs ahead wins every merge, and the very next
    /// descriptor after a close silently re-opens the mesh on the device whose user closed it. A
    /// monotonic local stamp cannot fix that half: the peer's next descriptor is honestly later
    /// still. The choice is therefore a sticky LOCAL policy, re-applied after every merge.
    @Test func aSessionTheUserClosedIsNotReOpenedByASkewedDescriptor() async throws {
        let rig = try MeshFoundingRig.build(2, label: "sticky-closed")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        let mesh = try #require(manager.currentMesh, "the commit founds the mesh under test")
        manager.setSessionOpen(false)
        #expect(manager.currentMesh?.mode == .closed, "the user closed this session")

        // The peer's descriptor for the SAME mesh, re-opening it with a stamp 50 s in this device's
        // future — inside `sanitizedDescriptor`'s +60 s clamp, so it wins LWW outright.
        var reopened = mesh
        reopened.mode = .open
        reopened.modeSetAt = Date().addingTimeInterval(50)
        reopened.modeSetBy = rig.identities[1].localFingerprint
        let coordinator = try #require(rig.nodes[0].coordinators[rig.nodes[1].handle.endpoint])
        try Self.deliverDescriptor(
            reopened, to: manager, from: rig.identities[1], over: coordinator
        )

        #expect(manager.currentMesh?.mode == .closed, """
            the merge took the skewed stamp and the sticky local choice took it back — a device \
            whose user closed the session never re-opens by gossip, it re-broadcasts its close
            """)
        #expect(!manager.isSessionOpen, "so the control the user touched still reads closed")
        #expect(manager.currentDiscoveryInfo()["meshID"] == nil, "and nothing is advertised")
        let radio = try #require(manager.transportForTesting as? FakeMeshTransportSession)
        #expect(radio.republishedDiscoveryInfo.last?["meshID"] == nil,
                "on the radio as well as in the model")
        let stamp = try #require(manager.currentMesh?.modeSetAt)
        #expect(stamp > reopened.modeSetAt, """
            and the re-assert is stamped STRICTLY LATER than the descriptor it answers, which is \
            the half a sticky flag cannot carry: on a bare `Date()` this device's close is behind \
            the skewed stamp it is answering, every other member's merge door discards it by LWW, \
            and the choice never leaves the device that made it. One rig, one clock — so this \
            assertion is the only thing here that can see a non-monotonic stamp at all
            """)

        // And the user's own re-open is honoured: the flag is the same control, not a latch.
        manager.setSessionOpen(true)
        #expect(manager.currentMesh?.mode == .open, "re-opening is that user's own tap")
    }

    /// Delivers one signed `.meshDescriptor` through the production receive door with the sender's
    /// verified `PeerIdentity`, so a cell can hand a committed peer's descriptor any shape it likes
    /// — a stamp in this device's future, in particular.
    private static func deliverDescriptor(
        _ descriptor: MeshDescriptor,
        to manager: MeshNetworkManager,
        from sender: IdentityService,
        over coordinator: ProximityCoordinator
    ) throws {
        let plaintext = try JSONEncoder().encode(MeshStateChangePayload(descriptor: descriptor))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Peer",
            payloadType: .meshDescriptor,
            payloadSummary: PayloadSummary(title: "Mesh"),
            payload: plaintext
        )
        let identity = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Peer",
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

    /// Door 1: **End Session**. The ceremony fires, and fires exactly once.
    ///
    /// `leaveMesh()` is the teardown funnel every End Session path reaches (`beginDevelop` →
    /// `leaveSessionAfterNotifyingPeers()` → `leaveSession()` → here), and it nils the mesh before
    /// `stopSearching()` runs the hooks — so the ledgerless leg of ``MeshNetworkManager/isSessionLive``
    /// is what answers, and answers "ended".
    ///
    /// The "exactly once" half is load-bearing: the app runs the same three hooks again on the very
    /// next tab exit, so "the session ended" must not be answerable twice. The mechanism is
    /// `sessionRoster.removeAll()` — the promotion is once per POPULATION, not once per predicate
    /// edge.
    @Test func endingTheSessionFiresTheReviewShopAndTranscriptHooksExactlyOnce() async throws {
        let rig = try MeshFoundingRig.build(2, label: "session-end")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        #expect(manager.currentMesh != nil, "the founding is the precondition for the regression")
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")

        manager.leaveMesh()

        #expect(!manager.isSessionLive, "End Session is the ending")
        #expect(manager.pendingFriendReview != nil, "the keep-as-friend batch promoted")
        #expect(manager.sessionMessages.messages.isEmpty, "the transcript vanished at session end")
        #expect(manager.clothingShop.window != nil, "and the post-session shop window opened")

        let batchID = try #require(manager.pendingFriendReview?.id)
        let window = manager.clothingShop.window
        manager.stopJoin()
        #expect(manager.pendingFriendReview?.id == batchID,
                "the second run promotes no second batch — the roster it drained is empty")
        #expect(manager.clothingShop.window == window, "and re-opens no second shop window")
        #expect(manager.sessionMessages.messages.isEmpty, "the transcript stays cleared")

        // The routed half is sane too: this session minted nothing, so there is nothing held and
        // nothing refused — a session-end ceremony must not invent either.
        #expect(manager.routedDeliveryHold == nil, "no delivery hold is raised by a session ending")
        #expect(manager.routedShareRefusal == nil, "and no share refusal")
        #expect(rig.routedIndex(0) == nil,
                "with the routed store never written, because nothing was ever staged")
    }

    /// Door 2: **a termination record**, with the mesh still held.
    ///
    /// Driven through the machine, which is where the door actually is: every terminal edge
    /// (`departed` / `terminated` / `expired`, this device's own signed ending or a peer's verified
    /// `terminated.v1`) carries `.stopParticipation`, and `applySessionEvent` assigns
    /// `sessionState` BEFORE it performs the effects — so `stopSearching()`'s hooks see an ended
    /// session while `currentMesh` is still set. That ordering is the whole reason no new hook call
    /// site was needed for this door.
    @Test func aTerminationRecordEndsTheSessionForTheCeremony() async throws {
        let rig = try MeshFoundingRig.build(2, label: "terminated")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.terminationVerified)
        }

        #expect(manager.sessionState == .terminated, "the machine took the terminal edge")
        #expect(manager.currentMesh != nil, """
            with the mesh object still held — so this really is the mesh-end leg answering and not \
            the ledgerless one
            """)
        #expect(!manager.isSessionLive, "a terminated mesh is an ended session")
        #expect(manager.pendingFriendReview != nil, "the keep-as-friend batch promoted")
        #expect(manager.sessionMessages.messages.isEmpty, "the transcript vanished")
        #expect(manager.clothingShop.window != nil, "and the shop window opened")
    }

    /// Door 3: **the five-minute discovery timeout with no committed peer**.
    ///
    /// The app's timeout used to call `stopJoin()`, which stands the radios down and leaves
    /// everything else alone — so once the ceremony moved off slot loss, a pair whose peer never
    /// came back would have sat on a mesh with no radios, no peer and no review. The door says the
    /// ending out loud instead, and refuses outright while a peer is committed.
    @Test func theDiscoveryTimeoutWithNoPeerEndsTheSession() async throws {
        let rig = try MeshFoundingRig.build(2, label: "gave-up")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")

        // The negative first, on the same shape: a timeout that fires while the pair is linked is
        // not an ending at all.
        manager.endSessionAfterDiscoveryTimeout()
        #expect(manager.isSessionLive, "a committed peer refuses the door by name")
        #expect(manager.pendingFriendReview == nil, "so nothing promoted")

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)
        manager.endSessionAfterDiscoveryTimeout()

        #expect(!manager.isSessionLive, "five minutes of finding nobody ends the session")
        #expect(!manager.isSearching, "with the radios down")
        #expect(manager.currentMesh != nil, "and the mesh still held, for the review's own action")
        #expect(manager.pendingFriendReview != nil, "the keep-as-friend batch promoted")
        #expect(manager.sessionMessages.messages.isEmpty, "the transcript vanished")
        #expect(manager.clothingShop.window != nil, "and the shop window opened")

        // Re-entering the tab re-arms the radios over the same mesh, which un-ends it: otherwise a
        // resumed pair would be permanently "ended" and its healed link would project into a
        // transcript nothing keeps.
        manager.resumeSearchingForPartitionedMesh()
        #expect(manager.isSessionLive, "the resume un-ends a search this device gave up on")
    }

    /// Door 3's CLOCK, armed where the peer is actually lost (fix review finding P2-1).
    ///
    /// Before this, `armDiscoveryTimeout()` was the only arm and it fires once per visit from
    /// `startFriendsDiscovery()` (tab entry / scene-active, bailing on `isSearching`). So a pair
    /// that blipped more than five minutes into a visit had **no** door 3 at all, and
    /// `isSessionLive` stayed true for the rest of the process unless the user bounced the Social
    /// tab and then stayed on it for five uninterrupted minutes — the review, the shop window and
    /// the transcript clear all deferred that whole time.
    ///
    /// Driven with an injected instant and **no sleep**: the deadline is the decision and
    /// `evaluateSessionGiveUp(now:)` is the only thing that reads it, so a wake that never comes
    /// and a wake that comes late are the same cell.
    @Test func aBlipArmsTheGiveUpClockInTheManagerAndEndsTheSessionFiveMinutesLater() async throws {
        let rig = try MeshFoundingRig.build(2, label: "give-up-clock")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")
        #expect(!manager.isSessionGiveUpClockArmed, "a linked pair is not counting down to anything")

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        let blipAt = Date()
        manager.evictSlotForTesting(peerID: slot.id)

        #expect(manager.isSessionLive, "a blip is still not an ending — that is item 2's fix")
        #expect(manager.isSessionGiveUpClockArmed, """
            but the give-up clock is now running, armed by the manager at the slot-loss door and \
            NOT by a tab the user may never re-enter
            """)
        #expect(manager.pendingFriendReview == nil, "and nothing has promoted yet")

        // Four minutes in — no tab bounce, no ending.
        manager.evaluateSessionGiveUp(now: blipAt.addingTimeInterval(4 * 60))
        #expect(manager.isSessionLive, "four minutes of searching is not five")
        #expect(!manager.sessionMessages.messages.isEmpty, "and the transcript is untouched")

        // Six minutes in: the deadline passed, so the session ends here with no tab involvement.
        manager.evaluateSessionGiveUp(now: blipAt.addingTimeInterval(6 * 60))
        #expect(!manager.isSessionLive, "five minutes of finding nobody ends the session")
        #expect(!manager.isSessionGiveUpClockArmed, "and the clock stands down with it")
        #expect(manager.pendingFriendReview != nil, "the keep-as-friend batch promoted")
        #expect(manager.sessionMessages.messages.isEmpty, "the transcript vanished")
        #expect(manager.clothingShop.window != nil, "and the shop window opened")
    }

    /// The other half of the same clock: a re-link INSIDE the window cancels the ending outright
    /// rather than deferring it — the session never ended, so nothing downstream may see an ending.
    @Test func aReLinkInsideTheGiveUpWindowCancelsTheEnding() async throws {
        let rig = try MeshFoundingRig.build(2, label: "give-up-cancel")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        try Self.armTheThreeHooks(on: manager, peer: rig.identities[1], label: "Peer")

        let slot = try #require(manager.slots.first, "the commit must have seated a slot")
        let blipAt = Date()
        manager.evictSlotForTesting(peerID: slot.id)
        #expect(manager.isSessionGiveUpClockArmed, "the blip armed the clock")

        rig.reseat(0, toward: 1)
        rig.commit(0, 1)
        #expect(manager.hasCommittedPeer, "the link healed")
        #expect(!manager.isSessionGiveUpClockArmed, "so the clock is cancelled, not deferred")

        // And a wake that arrives after the original deadline finds nothing to end.
        manager.evaluateSessionGiveUp(now: blipAt.addingTimeInterval(6 * 60))
        #expect(manager.isSessionLive, "a healed session is not ended by the clock it outran")
        #expect(manager.pendingFriendReview == nil, "and nothing promoted")
    }

    /// Door 4: **slot loss, and only with no mesh** — the legacy pairwise ceremony, kept.
    ///
    /// Reachable by any session that never founded (and by every rig that seats a committed slot
    /// without driving the founding): there is no mesh to outlive the link, so the last committed
    /// slot going away is the session ending, exactly as it was before item 2.
    @Test func aLedgerlessPairKeepsItsLegacySlotLossCeremony() async throws {
        let store = makeTestStore()
        let local = try MeshPartitionFixtures.identity("ledgerless-local")
        let peer = try MeshPartitionFixtures.identity("ledgerless-peer")
        let manager = MeshNetworkManager(
            store: store, transport: FakeMeshTransportSession(), identity: local
        )
        defer { manager.leaveMesh() }
        manager.addSlotForTesting(
            coordinator: MeshP3Acceptance.coordinator(),
            peer: PeerHandle(
                id: UUID(), displayHint: "iPhone", discoveryInfo: ["v": "1"],
                advertisedFingerprint: nil, endpoint: PeerEndpointKey()
            ),
            fingerprint: peer.localFingerprint
        )
        #expect(manager.currentMesh == nil, "the ledgerless shape: a committed slot and no mesh")
        #expect(manager.hasCommittedPeer, "with a peer")
        #expect(manager.isSessionLive, "which is the whole of this session's liveness")
        manager.sessionMessages.appendOutgoing(
            id: UUID(), senderFingerprint: local.localFingerprint,
            senderDisplayName: "Local", text: "hello", sentAt: Date()
        )
        manager.clothingShop.isSharingEnabledProvider = { true }
        let catalog = try Self.catalogEnvelope(displayName: "Peer")
        manager.clothingShop.receiveCatalog(
            catalog.envelope, plaintext: catalog.plaintext,
            verifiedFingerprint: peer.localFingerprint, now: Date()
        )

        let committed = try #require(manager.slots.first, "the seated slot")
        manager.evictSlotForTesting(peerID: committed.id)

        #expect(!manager.isSessionLive, "no mesh, no peer, no session")
        #expect(manager.sessionMessages.messages.isEmpty, "so the transcript vanishes on slot loss")
        #expect(manager.clothingShop.window != nil, "and the shop window opens on slot loss")
    }

    /// The app's discovery entry, as a table rather than as two private lines nothing could redden
    /// (review finding P2-5). `ContentView.startFriendsDiscovery()` switches on this value and
    /// arms its five-minute timeout off `armsDiscoveryTimeout`.
    @Test func theFriendsDiscoveryEntryTableIsTotal() {
        #expect(FriendsDiscoveryEntry.entry(isInSession: false, hasCommittedPeer: false) == .fresh,
                "no session at all is a fresh `startJoin()` cycle")
        #expect(FriendsDiscoveryEntry.entry(isInSession: true, hasCommittedPeer: false) == .resume,
                "a mesh that outlived its links resumes — `startJoin()` would nil its ceiling")
        #expect(FriendsDiscoveryEntry.entry(isInSession: true, hasCommittedPeer: true) == .none,
                "a live session's radios are already up")
        #expect(FriendsDiscoveryEntry.entry(isInSession: false, hasCommittedPeer: true) == .none, """
            the unrepresentable row (`hasCommittedPeer ⇒ isInSession`) is ANSWERED, not trapped: a \
            committed peer means the radios have somebody
            """)
        #expect(FriendsDiscoveryEntry.fresh.armsDiscoveryTimeout, "a fresh search can find nobody")
        #expect(FriendsDiscoveryEntry.resume.armsDiscoveryTimeout, """
            and so can a resumed one — the timeout rides the resume arm too, which is the half \
            that had no failing mutation at all
            """)
        #expect(!FriendsDiscoveryEntry.none.armsDiscoveryTimeout,
                "while a no-op must not arm a second timeout behind the first")
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
        let peer = try #require(others.first, "the union must hold the committed peer")
        manager.proposeRemoval(of: peer)
        #expect(manager.pendingRemovalProposals.isEmpty,
                "so removing the only peer ends the session instead of opening a vote nobody can win")
        #expect(!manager.sessionRoster.contains { $0.fingerprint == peer.fingerprint },
                "and the peer the user asked to remove is never offered by the keep prompt")
    }

    // MARK: The headline — the app's own content path, measured at the recipient

    /// **The item's headline, and the one claim pass A could only argue.** A photo captured on a
    /// dwell-founded pair is DELIVERED, in both directions, with nothing seeded anywhere.
    ///
    /// Every door is the shipping one: `startJoin`-mode managers with no mesh and no ledger, the
    /// real dwell commit, the founding, the one auto-granted admission, the digest re-gossip that
    /// rebases the joiner's bootstrap root — and then `addPhoto` → `shareRoutedPhoto` →
    /// `originateRoutedItem` → the drain → the recipient's access gate → the recipient's wall.
    ///
    /// The assertions are made at the RECIPIENT, which is the only place that separates a delivery
    /// from a successful mint. A staged own item plus no refusal is also the observation that
    /// excludes `.skipped(.noDestinations)`: before item 2 this path returned it on the very first
    /// guard (`membershipVerifier?.roster` was nil for every proximity session ever made), leaving
    /// the store `.absent` and the user's capture shared with nobody, silently — D-13.18, and the
    /// whole reason the item exists.
    ///
    /// Both directions, because the two sides are not symmetric: one founded and admitted, the other
    /// yielded its own newborn mesh and was admitted into this one, and only the second has been
    /// through `MeshLedgerAdoption`'s rebase.
    @Test func aPairwisePhotoIsDeliveredBothWaysThroughTheAppPath() async throws {
        let rig = try MeshFoundingRig.build(2, label: "pair-deliver")
        defer { rig.teardown() }
        rig.openGate(at: 0)
        rig.openGate(at: 1)
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        #expect(rig.roster(0).count == 2 && rig.roster(1).count == 2,
                "the destination set the mint needs is the derived roster, and it must be 2 here")

        rig.capturePhoto(at: 0)
        let outbound = try #require(rig.stagedOwnItemID(at: 0), """
            the capture staged nothing — which is exactly what `.skipped(.noDestinations)` looks \
            like, and what every proximity session did before item 2
            """)
        #expect(rig.nodes[0].manager.routedShareRefusal == nil, "and it was not refused either")
        #expect(rig.nodes[0].manager.meshPhotos.count == 1, "the sender's own echo is unconditional")
        try await rig.settle(until: { rig.wallEntries(at: 1, itemID: outbound) == 1 })
        #expect(rig.wallEntries(at: 1, itemID: outbound) == 1,
                "the peer's wall holds the photo — DELIVERED, not merely minted")

        rig.capturePhoto(at: 1)
        let inbound = try #require(rig.stagedOwnItemID(at: 1),
                                   "and the other half of the pair can mint too")
        #expect(inbound != outbound, "its own item, not the one it received")
        #expect(rig.nodes[1].manager.routedShareRefusal == nil, "with no refusal")
        try await rig.settle(until: { rig.wallEntries(at: 0, itemID: inbound) == 1 })
        #expect(rig.wallEntries(at: 0, itemID: inbound) == 1,
                "and it reaches the founder's wall, so the pair delivers BOTH ways")
    }

    /// A third device joins the founded pair **by request** and the founder's photo reaches all
    /// three — including the device that founded its own mesh first and yielded it.
    ///
    /// Two claims in one scenario, because they are one scenario. The admission is the PROMPT path:
    /// the auto-grant is latched at `mesh.members.count == 1`, so a third device is a stranger
    /// joining an established mesh and `allowAdmission` is a tap. And the delivery happens after the
    /// yield, which is the shape that would break if `unwindNewbornMesh()` left anything standing —
    /// the third device's own ledger, group key and advertisement set all belonged to a mesh it no
    /// longer holds.
    ///
    /// The photo is captured AFTER the third admission so the destination set is all three: a
    /// `MeshDeliveryTarget` is the roster at creation, which is the rule that makes a late joiner
    /// not a destination of an earlier item. The origin is linked to both destinations before it
    /// captures, deliberately: a destination never forwards an item it holds (relay increment 2 is
    /// not built), so an unlinked third member is a successful MINT whose delivery waits for a link
    /// — which `MeshRoutedPhotoAddressingTests`' star cell is the claim for, not this one.
    @Test func aPhotoReachesBothDestinationsAfterAYieldWhenTheOriginIsLinkedToBoth() async throws {
        let rig = try MeshFoundingRig.build(3, label: "trio-deliver")
        defer { rig.teardown() }
        for node in 0..<3 { rig.openGate(at: node) }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle([0, 1], until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let founded = try #require(rig.nodes[0].manager.currentMesh?.meshID)

        // C commits to node 1, founds its own mesh, then yields it when node 1's descriptor lands.
        rig.link(1, 2)
        rig.commit(2, 1)
        rig.commit(1, 2)
        #expect(rig.nodes[2].manager.currentMesh?.meshID != founded, "C really did found its own")
        try await rig.settle(until: { rig.nodes[1].manager.pendingAdmissionRequests.count == 1 })
        #expect(rig.nodes[1].manager.pendingAdmissionRequests.count == 1,
                "the third device is PROMPTED — the auto-grant is latched at one member")
        let queued = try #require(rig.nodes[1].manager.pendingAdmissionRequests.first)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.nodes[1].manager.allowAdmission(queued)
        }
        try await rig.settle(until: { rig.roster(2).count >= 3 && rig.roster(0).count >= 3 })
        #expect(rig.nodes[2].manager.currentMesh?.meshID == founded, "C is on the pair's mesh")
        #expect(Set(rig.roster(0)).count == 3, "and every side derives a roster of three")
        #expect(Set(rig.roster(1)).count == 3)
        #expect(Set(rig.roster(2)).count == 3)

        // The origin links its second destination before capturing — see the note above.
        rig.link(0, 2)
        rig.commit(0, 2)
        rig.commit(2, 0)
        try await rig.settle(until: { false })
        #expect(rig.nodes[0].manager.currentMesh?.meshID == founded,
                "a commit onto a device that already holds the mesh founds nothing new")

        rig.capturePhoto(at: 0)
        let itemID = try #require(rig.stagedOwnItemID(at: 0),
                                  "a three-member roster is two destinations, so the mint stages")
        #expect(rig.nodes[0].manager.routedShareRefusal == nil, """
            and no destination refused it — including the yielder, whose addressing was unwound with \
            the mesh it gave up and re-armed at the admission it was granted
            """)
        try await rig.settle(until: {
            rig.wallEntries(at: 1, itemID: itemID) == 1 && rig.wallEntries(at: 2, itemID: itemID) == 1
        })
        #expect(rig.wallEntries(at: 1, itemID: itemID) == 1, "the admitter's wall holds it")
        #expect(rig.wallEntries(at: 2, itemID: itemID) == 1, "and so does the yielder's")
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
