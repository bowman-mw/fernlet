// MeshDepartureRecoveryTests.swift
// FernletTests
//
// P4 item 4 (plan §10.5, and §8.7 finding 2 under §21.3's default): a departure crosses a healed
// partition by **re-gossip**, and a survivor that MISSED one learns it at the next merge.
//
// The owner's worked example, verbatim (§10.5):
//
//   Roster {A, B, C, D}; split into {A, B} and {C, D}. B develops and leaves: B's signed
//   `memberDeparture` reaches A (the only reachable member). Everyone now behaves by their view —
//   A knows roster 3, C/D still assume 4. A later walks over and connects to C: the introduction's
//   record exchange (§10.3) hands C the departure record; C gossips it to D. All three converge on
//   roster {A, C, D}, quorum 2, without B ever meeting C or D. If B had left while completely
//   alone, the record could not propagate — the residual is that C/D carry a phantom member until
//   the ceiling; this is accepted and bounded (no dead-drop side channel for mesh state).
//
// **Nothing here is new machinery.** P3 built the signed departure record and the bounded record
// re-gossip that answers a differing inventory digest; P4 item 2 routed every reconnect through the
// one merge path; item 3 put the epoch heads on the wire. This file is the proof that those parts,
// composed, are the propagation §10.5 describes — and the check confirmed the re-gossip already
// selects **departures** (`MeshNetworkManager.reGossipRecords(to:)` walks admissions, departures,
// removals and terminations), so item 4's permitted widening was not needed and no code moved.
//
// **§8.7 finding 2, and the P4 default it is answered with.** `leaveSessionAfterNotifyingPeers()`
// awaits the local *write* and then the frame reaching the **transport** — not the peer — and then
// stops the transport, so a survivor can miss a clean departure. §21.3's default is **wait for P5;
// make P4's merge path the recovery**: no transport ack and no re-send timer is added here. Both
// halves are asserted below — the durable-before-acknowledged order still holds
// (`MeshSessionStateMachineTests.aDepartureBarsTheMeshItLeft` owns the sealed-mark claim; this file
// asserts it again at the multi-node seam), and *nothing re-sends*: the clock is advanced far past
// any plausible timer and the survivor that missed it is still ignorant until the next merge.
//
// **The rig.** Four managers, one `FakePeerNetwork`, an injected clock, real signed frames.
// `MeshMergeExchangeTests`' two-node rig cannot express this: it holds ONE `ProximityCoordinator`
// per node, and `MeshNetworkManager` resolves an inbound frame's slot by `coordinator ===`, so a
// node with two peers would attribute every frame to whichever slot came first. `MeshDepartureNode`
// therefore keys a coordinator **per link**, which is also what makes "who did D hear it from"
// answerable: the fabric records the sending endpoint on every delivered frame. The session start
// itself is `MeshMergeWire.start`, reused rather than copied.
//
// **Nothing sleeps**, and the rotation claims are sampled *inside* the pump, with no suspension
// between the dispatch and the read — a `Task.yield()` under a loaded suite can span the 2-second
// rotation debounce, which would consume the pending cause before an assertion after a settle could
// see it (the ledger's "(P4 i3)" lesson, applied).
//
// Why the two branches are seeded at **different** epoch counters: item 3 owns the same-counter
// `coexist` case, whose ordering depends on which real fingerprint sorts first and is therefore not
// something this file should re-derive. Distinct counters make `rotationBasisHead` — plan §10.3's
// `max` — the same value at every member no matter how the fixtures' keys happen to sort, so "every
// member ends at exactly one epoch head" is a deterministic claim here rather than a lucky one.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshDepartureNode

/// One node of an N-manager fabric: a manager, the endpoint its slots send over, and **one
/// coordinator per link**.
///
/// A class rather than a struct because ``delivered`` is a cursor the pump advances and
/// ``coordinators`` grows as links are seated — a value type would hand every pump its own copy and
/// re-deliver the whole history each round.
///
/// The per-link coordinator is the load-bearing difference from `MeshMergeWireNode`:
/// `MeshNetworkManager` finds an inbound frame's slot with `slots.first { $0.coordinator === … }`,
/// so a node with three peers needs three coordinators or every frame is attributed to one peer.
@MainActor
final class MeshDepartureNode {

    /// A short frozen label used in diagnostics and to key rotation samples. Never display copy.
    let label: String

    /// The sealed root this manager writes to. Held here because `MeshNetworkManager` keeps its
    /// host `unowned`: a store that only lives as long as the expression that made it traps.
    let store: FernletStore

    /// The manager at this end.
    let manager: MeshNetworkManager

    /// This end's fabric endpoint — what its slots send over and what its peers' frames land in.
    let channel: FakePeerTransport

    /// The handle every other end addresses this one by.
    let handle: PeerHandle

    /// This end's replay cache, so a re-delivered envelope is refused here exactly as on a radio.
    let replayCache = ReplayCache()

    /// How many of ``channel``'s received frames have already been handed to the manager.
    var delivered = 0

    /// The coordinator each peer's frames are dispatched over, keyed by that peer's endpoint.
    var coordinators: [PeerEndpointKey: ProximityCoordinator] = [:]

    /// This node's canonical fingerprint — the name every roster assertion is written in.
    var fingerprint: String { manager.identityForTesting.localFingerprint }

    /// Builds one node.
    ///
    /// - Parameters:
    ///   - label: The diagnostic label.
    ///   - store: The sealed root.
    ///   - manager: The manager at this end.
    ///   - channel: This end's fabric endpoint.
    ///   - handle: The handle other ends address this one by.
    init(
        label: String,
        store: FernletStore,
        manager: MeshNetworkManager,
        channel: FakePeerTransport,
        handle: PeerHandle
    ) {
        self.label = label
        self.store = store
        self.manager = manager
        self.channel = channel
        self.handle = handle
    }
}

// MARK: - MeshRotationSample

/// What each node's rotation queue held, sampled inside the pump.
///
/// Sampling is separated from asserting on purpose: a `Task.yield()` releases the main actor, and
/// under a loaded suite the 2-second rotation debounce can fire in that gap and take its own
/// pending cause with it. Anything read after a settle is a race; anything recorded here is not.
@MainActor
final class MeshRotationSample {

    /// The causes seen at each node, by label.
    private var causesByLabel: [String: Set<MeshKeyRotationCause>] = [:]

    /// The distinct debounce windows seen at each node, by label. Two values for one merge is a
    /// second rotation.
    private var windowsByLabel: [String: Set<Date>] = [:]

    /// Records whatever `node`'s rotation queue holds right now.
    func record(_ node: MeshDepartureNode) {
        if let cause = node.manager.rotationTriggers.pendingCause {
            causesByLabel[node.label, default: []].insert(cause)
        }
        if let firesAt = node.manager.rotationTriggers.firesAt {
            windowsByLabel[node.label, default: []].insert(firesAt)
        }
    }

    /// The causes recorded at one node.
    func causes(at label: String) -> Set<MeshKeyRotationCause> { causesByLabel[label] ?? [] }

    /// How many distinct debounce windows were recorded at one node.
    func windowCount(at label: String) -> Int { (windowsByLabel[label] ?? []).count }

    /// Forgets everything, so one scenario can assert phase by phase.
    func reset() {
        causesByLabel.removeAll()
        windowsByLabel.removeAll()
    }
}

// MARK: - MeshDepartureRig

/// The N-manager fabric these scenarios run on: build a node, seat a link, pump, settle.
///
/// Deliberately general — items 5 (quorum under partition), 6 (termination under partition) and 9
/// (the §16.2 convergence property over randomized schedules) all want the same shape, and a rig
/// that only knew about departures would be rewritten by each of them.
@MainActor
enum MeshDepartureRig {

    /// The most frames one pump will move: a full re-gossip plus its digests and head frames, with
    /// headroom. A bounded loop (R2) whose ceiling being reached means the fabric is looping.
    static let maxPumpedFrames = MeshNetworkManager.maxReGossipFrames + 16

    /// How many drain rounds one settle runs, and how many yields each round gives the main actor.
    /// None of it is wall-clock time; the `until:` predicate ends most settles in two or three.
    static let settleRounds = 8
    static let yieldsPerRound = 4

    /// Builds one node on `fabric` with an **injected** identity.
    ///
    /// The injection is not hygiene: `IdentityService()` is keyed on one process-wide keychain
    /// service, so four default managers in one process would be the same device four times over
    /// and every roster assertion below would be vacuous rather than wrong.
    static func node(
        _ label: String, identity: IdentityService, on fabric: FakePeerNetwork
    ) -> MeshDepartureNode {
        let store = makeTestStore()
        let manager = MeshNetworkManager(
            store: store, transport: FakeMeshTransportSession(), identity: identity
        )
        let endpoint = fabric.addEndpoint(named: label)
        return MeshDepartureNode(
            label: label, store: store, manager: manager,
            channel: endpoint.transport, handle: endpoint.handle
        )
    }

    /// Puts a node into a live session on a seeded ledger.
    static func start(
        _ node: MeshDepartureNode, ledger: MeshMembershipLedger, founderKey: Data, meshID: UUID
    ) {
        MeshMergeWire.start(node.manager, ledger: ledger, founderKey: founderKey, meshID: meshID)
    }

    /// Puts a node on a named epoch without spending a rotation.
    static func seedEpoch(_ node: MeshDepartureNode, head: MeshEpochRef) {
        node.manager.seedEpochKeyringForTesting(
            head: head,
            key: MeshGroupKey(
                epoch: Int(head.counter),
                keyBytes: Data(repeating: 0x2A, count: 32),
                activeSince: MeshP3Acceptance.base
            )
        )
    }

    /// Connects two nodes on the fabric and seats a committed slot at each end, each with its own
    /// coordinator so inbound frames are attributed to the peer that actually sent them.
    static func link(_ near: MeshDepartureNode, _ far: MeshDepartureNode, on fabric: FakePeerNetwork) {
        fabric.connect(near.handle, far.handle)
        seat(near, toward: far)
        seat(far, toward: near)
    }

    /// Seats one direction of a link.
    private static func seat(_ node: MeshDepartureNode, toward peer: MeshDepartureNode) {
        let coordinator = MeshP3Acceptance.coordinator()
        node.coordinators[peer.handle.endpoint] = coordinator
        node.manager.addSlotForTesting(
            coordinator: coordinator, peer: peer.handle,
            fingerprint: peer.fingerprint, channel: node.channel
        )
    }

    /// Hands whatever the fabric delivered to `node` to its manager, over the coordinator that
    /// belongs to the sending peer, after the real envelope verification.
    ///
    /// - Returns: How many frames were moved.
    @discardableResult
    static func pump(
        _ node: MeshDepartureNode, binding: DeviceBindingID.TestOverride? = nil
    ) throws -> Int {
        var moved = 0
        let binding = binding ?? .identifier(MeshP3Acceptance.install)
        let frames = node.channel.receivedFrames
        while node.delivered < frames.count, moved < maxPumpedFrames {
            let frame = frames[node.delivered]
            node.delivered += 1
            moved += 1
            guard let coordinator = node.coordinators[frame.peer.endpoint] else { continue }
            let envelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: frame.data)
            let plaintext = try envelope.verify(
                identityService: node.manager.identityForTesting, replayCache: node.replayCache
            )
            DeviceBindingID.$testOverride.withValue(binding) {
                node.manager.proximityCoordinator(
                    coordinator, didReceive: envelope, plaintext: plaintext, from: nil
                )
            }
        }
        return moved
    }

    /// Lets the managers' detached sends run, moves the fabric forward, and delivers what arrived.
    ///
    /// - Parameters:
    ///   - nodes: Every end still participating.
    ///   - fabric: The medium to advance.
    ///   - sample: Recorded immediately after each node's pump, before anything can suspend.
    ///   - binding: The install binding every pumped receive runs under; defaults to the rig's one
    ///     pinned install. A **parameter** since P5 item 10: an inner `withValue` shadows an outer
    ///     one, so a cell that meant to drive a LOCKED window would otherwise find every store
    ///     `.loaded` for exactly the receives it meant to lock.
    ///   - isDone: Ends the settle early once the scenario has what it is waiting for.
    static func settle(
        _ nodes: [MeshDepartureNode],
        on fabric: FakePeerNetwork,
        sampling sample: MeshRotationSample? = nil,
        binding: DeviceBindingID.TestOverride? = nil,
        until isDone: () -> Bool = { false }
    ) async throws {
        for _ in 0..<settleRounds {
            for _ in 0..<yieldsPerRound { await Task.yield() }
            fabric.clock.advance(by: .milliseconds(50))
            for node in nodes {
                try pump(node, binding: binding)
                sample?.record(node)
            }
            if isDone() { return }
        }
    }

    /// Disarms every node's debounce window so the next phase starts from a known queue, and
    /// reports what each was holding. Synchronous, so nothing can fire between the sample and the
    /// disarm.
    @discardableResult
    static func consumeRotations(_ nodes: [MeshDepartureNode]) -> [String: MeshKeyRotationCause] {
        var consumed: [String: MeshKeyRotationCause] = [:]
        for node in nodes {
            if let cause = node.manager.consumePendingRotationForTesting() {
                consumed[node.label] = cause
            }
        }
        return consumed
    }

    /// The payload-type tokens `node` received **from one sender**, in arrival order.
    ///
    /// The sender is the whole point: it is what separates "the record travelled by re-gossip" from
    /// "the leaver sent it directly".
    static func tokensReceived(by node: MeshDepartureNode, from sender: PeerHandle) -> [String] {
        node.channel.receivedFrames
            .filter { $0.peer.isSameEndpoint(as: sender) }
            .compactMap { frame in
                try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: frame.data)
                    .payloadTypeToken
            }
    }

    /// The derived roster's quorum threshold at one node — ⌊|roster|/2⌋ + 1, re-derived from the
    /// receiver's own merged roster exactly as §10.4 requires.
    static func quorum(_ node: MeshDepartureNode) -> Int? {
        node.manager.membershipVerifier?.roster.quorumThreshold
    }

    /// The epoch heads this node would present right now, in a comparable order.
    static func heads(_ node: MeshDepartureNode) -> [String] {
        node.manager.presentedEpochHeadsForTesting.map(\.canonicalString).sorted()
    }
}

// MARK: - MeshDepartureWorkedExample

/// Plan §10.5's worked example, wired: {A, B} | {C, D}, B departs to A alone, A meets C, C gossips
/// to D.
///
/// One type per phase would be over-modelled and one 200-line test function would break Power of 10
/// R4; the phases are methods, each carrying the claims that phase is *for*.
@MainActor
struct MeshDepartureWorkedExample {

    /// The counter branch {A, B} is seeded at, and the (higher) counter branch {C, D} is seeded at.
    /// Different on purpose — see this file's header.
    static let branchOneCounter: UInt32 = 5
    static let branchTwoCounter: UInt32 = 6

    /// The fabric every frame crosses.
    let fabric: FakePeerNetwork

    /// The mesh all four are members of.
    let meshID: UUID

    /// The four members, in the worked example's own names.
    let nodeA: MeshDepartureNode
    let nodeB: MeshDepartureNode
    let nodeC: MeshDepartureNode
    let nodeD: MeshDepartureNode

    /// What each node's rotation queue held, sampled in the pump.
    let sample = MeshRotationSample()

    /// The three members the example ends with.
    var survivors: [MeshDepartureNode] { [nodeA, nodeC, nodeD] }

    /// Builds the roster of four, seeds both branches' epochs, and asserts the preconditions that
    /// would make every later claim vacuous if they did not hold.
    static func build() throws -> MeshDepartureWorkedExample {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = ["worked-a", "worked-b", "worked-c", "worked-d"]
        let ids = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(ids.map(\.localFingerprint)).count == 4,
                "the rig needs four distinct provisioned identities, or every roster claim is vacuous")
        let ledger = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: Array(ids.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (label, identity) in zip(labels, ids) {
            let node = MeshDepartureRig.node(label, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == 4,
                    "roster 4 is this example's hard precondition")
            #expect(MeshDepartureRig.quorum(node) == 3, "roster 4 ⇒ quorum 3, everywhere")
            nodes.append(node)
        }
        guard nodes.count == 4 else { throw MeshMergeTestFailure.rosterTooSmall }
        let scenario = MeshDepartureWorkedExample(
            fabric: fabric, meshID: meshID,
            nodeA: nodes[0], nodeB: nodes[1], nodeC: nodes[2], nodeD: nodes[3]
        )
        try scenario.seedBranchEpochs()
        return scenario
    }

    /// Puts {A, B} on one epoch and {C, D} on a strictly higher one, so the two branches are
    /// genuinely divergent and `rotationBasisHead` is the same value at every member.
    private func seedBranchEpochs() throws {
        guard let headOne = MeshEpochRef.minted(
                counter: Self.branchOneCounter,
                coordinatorFingerprint: min(nodeA.fingerprint, nodeB.fingerprint), meshID: meshID),
              let headTwo = MeshEpochRef.minted(
                counter: Self.branchTwoCounter,
                coordinatorFingerprint: min(nodeC.fingerprint, nodeD.fingerprint), meshID: meshID)
        else { throw MeshMergeTestFailure.couldNotMintEpoch }
        MeshDepartureRig.seedEpoch(nodeA, head: headOne)
        MeshDepartureRig.seedEpoch(nodeB, head: headOne)
        MeshDepartureRig.seedEpoch(nodeC, head: headTwo)
        MeshDepartureRig.seedEpoch(nodeD, head: headTwo)
    }

    /// Links each branch internally and raises §10.2's split at all four — a partition is presence,
    /// so the roster, the quorum and "final pair" must not move.
    func splitIntoBranches(at now: Date) {
        MeshDepartureRig.link(nodeA, nodeB, on: fabric)
        MeshDepartureRig.link(nodeC, nodeD, on: fabric)
        let branchOne: Set<String> = [nodeA.fingerprint, nodeB.fingerprint]
        let branchTwo: Set<String> = [nodeC.fingerprint, nodeD.fingerprint]
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for node in [nodeA, nodeB] {
                #expect(node.manager.evaluatePartition(reachable: branchOne, now: now) == .linksLost)
            }
            for node in [nodeC, nodeD] {
                #expect(node.manager.evaluatePartition(reachable: branchTwo, now: now) == .linksLost)
            }
        }
        for node in [nodeA, nodeB, nodeC, nodeD] {
            #expect(node.manager.branchView?.isPartitioned == true)
            #expect(node.manager.branchView?.rosterMemberCount == 4, "a split never shrinks a roster")
            #expect(MeshDepartureRig.quorum(node) == 3, "and never moves the quorum arithmetic")
            #expect(node.manager.branchView?.rosterIsFinalPair == false,
                    "a 2/2 split of a four-roster is not two final pairs")
        }
        #expect(nodeA.manager.presence(of: nodeC.fingerprint) == .temporarilyDisconnected)
        #expect(nodeC.manager.presence(of: nodeB.fingerprint) == .temporarilyDisconnected)
    }

    /// B develops and leaves. Its signed departure reaches **A only**; then B's radio is gone.
    func departB(at now: Date) async throws {
        var emitted: [PayloadType] = []
        nodeB.manager.onMembershipEventSentForTesting = { emitted.append($0) }
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await nodeB.manager.leaveSessionAfterNotifyingPeers()
        }
        #expect(emitted == [.meshMemberDeparture], "a real signed departure, not the legacy goodbye")
        #expect(MeshP3Acceptance.loadContext(from: nodeB.store)?.localTermination?.reason
                == .ownDeparture,
                "durable before acknowledged: the mark is sealed before the frame goes out")
        try await MeshDepartureRig.settle(
            [nodeA, nodeC, nodeD], on: fabric, sampling: sample,
            until: { MeshMergeFixtures.roster(nodeA.manager).count == 3 }
        )
        // B's radio stops with it. Nothing from B can reach anybody after this line.
        fabric.partition(nodeB.handle, from: nodeA.handle)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = nodeA.manager.evaluatePartition(reachable: [nodeA.fingerprint], now: now)
        }
        assertEveryoneBehavesByItsOwnView()
    }

    /// A knows roster 3; C and D still assume 4. Each acts on the view it can prove.
    private func assertEveryoneBehavesByItsOwnView() {
        #expect(!MeshMergeFixtures.roster(nodeA.manager).contains(nodeB.fingerprint),
                "the only reachable member filed the departure")
        #expect(MeshMergeFixtures.roster(nodeA.manager).count == 3)
        #expect(MeshDepartureRig.quorum(nodeA) == 2, "roster 3 ⇒ quorum 2 at A")
        #expect(sample.causes(at: nodeA.label) == [.membership],
                "a departure that lands re-keys without the leaver, and it is not a merge")
        for node in [nodeC, nodeD] {
            #expect(MeshMergeFixtures.roster(node.manager).count == 4,
                    "an unreachable branch cannot know, and does not guess")
            #expect(MeshDepartureRig.quorum(node) == 3, "so C/D still moderate at quorum 3")
        }
        MeshDepartureRig.consumeRotations([nodeA, nodeC, nodeD])
        sample.reset()
    }

    /// A walks over and connects to **C only**. The merge path's record exchange hands C the
    /// departure, and the epoch half of the same exchange crosses with it.
    func healAToC(at now: Date) async throws {
        MeshDepartureRig.link(nodeA, nodeC, on: fabric)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = nodeA.manager.evaluatePartition(
                reachable: [nodeA.fingerprint, nodeC.fingerprint], now: now
            )
            _ = nodeC.manager.evaluatePartition(
                reachable: [nodeA.fingerprint, nodeC.fingerprint, nodeD.fingerprint], now: now
            )
            nodeA.manager.applySessionEvent(.peerCommitted, committedPeer: nodeC.fingerprint)
            nodeC.manager.applySessionEvent(.peerCommitted, committedPeer: nodeA.fingerprint)
        }
        #expect(nodeC.manager.awaitingResumeMerge, "the heal opened C's merge window")
        try await MeshDepartureRig.settle(
            [nodeA, nodeC, nodeD], on: fabric, sampling: sample,
            until: { MeshMergeFixtures.roster(nodeC.manager).count == 3 }
        )
        assertCLearnedByReGossip()
    }

    /// C's roster moved, and the record that moved it came over the wire from **A**.
    private func assertCLearnedByReGossip() {
        let fromA = MeshDepartureRig.tokensReceived(by: nodeC, from: nodeA.handle)
        #expect(fromA.contains(PayloadType.meshInventoryDigest.rawValue),
                "the ask half of §10.3's exchange crossed")
        #expect(fromA.contains(PayloadType.meshMemberDeparture.rawValue),
                "and the answer half carried the DEPARTURE, not only admissions")
        #expect(fromA.contains(PayloadType.meshEpochHeads.rawValue),
                "the epoch half of the same exchange crossed too")
        #expect(MeshDepartureRig.tokensReceived(by: nodeC, from: nodeB.handle).isEmpty,
                "B never sent C anything; C learned by re-gossip")
        #expect(!MeshMergeFixtures.roster(nodeC.manager).contains(nodeB.fingerprint))
        #expect(MeshDepartureRig.quorum(nodeC) == 2, "C is now on roster 3, quorum 2")
        #expect(sample.causes(at: nodeC.label) == [.merge],
                "the whole re-gossip burst asked for ONE kind of rotation, and it is the merge's")
        #expect(sample.windowCount(at: nodeC.label) == 1,
                "and for ONE debounce window: a second value here is a second rotation")
        MeshDepartureRig.consumeRotations(survivors)
        sample.reset()
    }

    /// C gossips it to D: D's next exchange with C carries the departure onward.
    func gossipCToD() async throws {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodeD.manager.applySessionEvent(.peerCommitted, committedPeer: nodeC.fingerprint)
        }
        try await MeshDepartureRig.settle(
            [nodeA, nodeC, nodeD], on: fabric, sampling: sample,
            until: { MeshMergeFixtures.roster(nodeD.manager).count == 3 }
        )
        let fromC = MeshDepartureRig.tokensReceived(by: nodeD, from: nodeC.handle)
        #expect(fromC.contains(PayloadType.meshMemberDeparture.rawValue),
                "D's copy came from C — the re-gossip, one hop further")
        #expect(MeshDepartureRig.tokensReceived(by: nodeD, from: nodeB.handle).isEmpty,
                "B never met D, and the fabric never carried a frame between them")
        #expect(fabric.canReach(nodeB.handle, nodeC.handle) == false)
        #expect(fabric.canReach(nodeB.handle, nodeD.handle) == false)
        #expect(sample.causes(at: nodeD.label) == [.merge])
        #expect(sample.windowCount(at: nodeD.label) == 1, "one merge, one rotation")
        MeshDepartureRig.consumeRotations(survivors)
    }

    /// All three converge on {A, C, D} at quorum 2, and all three name the same one successor
    /// epoch — the head both branches' keys are retired in favour of (item 3's mint).
    func assertConvergence() throws {
        let rosters = survivors.map { MeshMergeFixtures.roster($0.manager) }
        let expected = [nodeA.fingerprint, nodeC.fingerprint, nodeD.fingerprint].sorted()
        for roster in rosters { #expect(roster == expected, "all three converged on {A, C, D}") }
        for node in survivors { #expect(MeshDepartureRig.quorum(node) == 2, "and on quorum 2") }
        #expect(MeshDepartureRig.heads(nodeA).count == 2,
                "A folded C's branch head as well as its own")
        var successors: Set<String> = []
        var bases: Set<UInt32> = []
        guard let coordinator = expected.min() else { throw MeshMergeTestFailure.rosterTooSmall }
        for node in survivors {
            guard let basis = node.manager.rotationBasisHeadForTesting else {
                throw MeshMergeTestFailure.couldNotMintEpoch
            }
            bases.insert(basis.counter)
            guard let successor = node.manager.epochRefForTesting(
                counter: Int(basis.counter) + 1, coordinatorFingerprint: coordinator
            ) else { throw MeshMergeTestFailure.couldNotMintEpoch }
            successors.insert(successor.canonicalString)
        }
        #expect(bases == [Self.branchTwoCounter], "one max across the merged view, not one per branch")
        #expect(successors.count == 1, "and therefore exactly ONE post-merge epoch head at every member")
    }

    /// Ends every live session, so nothing outlives the scenario.
    func teardown() {
        for node in [nodeA, nodeB, nodeC, nodeD] { node.manager.leaveMesh() }
    }
}

// MARK: - MeshDepartureRecoveryTests

/// §10.5's worked example and its stated residual.
@MainActor
@Suite(.serialized)
struct MeshDepartureRecoveryTests {

    /// **The owner's worked example, verbatim.** {A, B} | {C, D}; B departs to A alone; A meets C;
    /// C gossips to D; all three converge on {A, C, D} at quorum 2, with B never meeting C or D.
    @Test func aDepartureCrossesAHealedPartitionByReGossipWithoutTheLeaverEverMeetingTheFarBranch()
        async throws {
        let scenario = try MeshDepartureWorkedExample.build()
        let base = MeshP3Acceptance.base
        scenario.splitIntoBranches(at: base)
        try await scenario.departB(at: base.addingTimeInterval(60))
        try await scenario.healAToC(at: base.addingTimeInterval(120))
        try await scenario.gossipCToD()
        try scenario.assertConvergence()
        scenario.teardown()
    }

    /// **The residual, asserted rather than assumed.** A leaver with nobody reachable seals its own
    /// departure and propagates nothing: the far branch carries a phantom member until the ceiling,
    /// and no merge that excludes the leaver invents the record. There is no dead-drop side channel
    /// for mesh state, and this is what "bounded and accepted" looks like in bytes.
    @Test func aDepartureWithNobodyReachableStaysAtTheLeaverAndNothingInventsIt() async throws {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = ["alone-a", "alone-b", "alone-c", "alone-d"]
        let ids = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(ids.map(\.localFingerprint)).count == 4)
        let ledger = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: Array(ids.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (label, identity) in zip(labels, ids) {
            let node = MeshDepartureRig.node(label, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            nodes.append(node)
        }
        guard nodes.count == 4 else { throw MeshMergeTestFailure.rosterTooSmall }
        let (alone, first, second, third) = (nodes[1], nodes[0], nodes[2], nodes[3])
        // The leaver is linked to nobody: a partition of one, which is the whole premise.
        MeshDepartureRig.link(first, second, on: fabric)
        MeshDepartureRig.link(second, third, on: fabric)

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await alone.manager.leaveSessionAfterNotifyingPeers()
        }
        #expect(MeshP3Acceptance.loadContext(from: alone.store)?.localTermination?.reason
                == .ownDeparture, "the record is sealed at the leaver, as durability requires")
        #expect(alone.channel.sentFrames.isEmpty, "with no reachable member there is nobody to tell")

        // A merge that does not include the leaver: the survivors reconcile with each other.
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            first.manager.applySessionEvent(.peerCommitted, committedPeer: second.fingerprint)
            second.manager.applySessionEvent(.peerCommitted, committedPeer: first.fingerprint)
            third.manager.applySessionEvent(.peerCommitted, committedPeer: second.fingerprint)
        }
        try await MeshDepartureRig.settle([first, second, third], on: fabric)

        for node in [first, second, third] {
            #expect(MeshMergeFixtures.roster(node.manager).count == 4,
                    "the phantom member is still on the roster — bounded, and until the ceiling")
            #expect(MeshDepartureRig.quorum(node) == 3, "so the quorum arithmetic does not move")
            #expect(MeshPartitionFixtures.recordCounts(node.manager.membershipVerifier?.ledger)
                    == [4, 0, 0, 0], "no departure record was invented anywhere")
            #expect(MeshDepartureRig.tokensReceived(by: node, from: alone.handle).isEmpty,
                    "and nothing reached them from the leaver by any channel")
        }
        for node in nodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshMissedDepartureRecoveryTests

/// Plan §8.7 finding 2 under §21.3's default: the merge path **is** the recovery, and no ack or
/// re-send timer is added in P4.
@MainActor
@Suite(.serialized)
struct MeshMissedDepartureRecoveryTests {

    /// **A survivor that missed a departure learns it at the next merge.**
    ///
    /// {A, B, C} connected; B departs; the frame reaches A and is dropped for C — the shape
    /// `leaveSessionAfterNotifyingPeers()` cannot rule out, because it awaits the frame reaching
    /// the *transport* and then stops it. B is gone, so nobody re-sends. The clock is then run far
    /// past any timer a fix might have added, and C is *still* ignorant: that is P4's default said
    /// out loud. The A↔C blip that follows is what teaches C.
    @Test func aSurvivorThatMissedADepartureLearnsItAtTheNextMergeAndNothingReSendsIt() async throws {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = ["missed-a", "missed-b", "missed-c"]
        let ids = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(ids.map(\.localFingerprint)).count == 3)
        let ledger = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: Array(ids.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (label, identity) in zip(labels, ids) {
            let node = MeshDepartureRig.node(label, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            nodes.append(node)
        }
        guard nodes.count == 3 else { throw MeshMergeTestFailure.rosterTooSmall }
        let (nodeA, nodeB, nodeC) = (nodes[0], nodes[1], nodes[2])
        MeshDepartureRig.link(nodeA, nodeB, on: fabric)
        MeshDepartureRig.link(nodeA, nodeC, on: fabric)
        MeshDepartureRig.link(nodeB, nodeC, on: fabric)
        let sample = MeshRotationSample()

        // The write that never flushed: B's departure reaches A's link and is lost on C's.
        fabric.partition(nodeB.handle, from: nodeC.handle)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await nodeB.manager.leaveSessionAfterNotifyingPeers()
        }
        #expect(MeshP3Acceptance.loadContext(from: nodeB.store)?.localTermination?.reason
                == .ownDeparture,
                "the local write is still awaited before the transport stops (§3.6 unchanged)")
        #expect(!nodeB.channel.droppedFrames.isEmpty,
                "the fabric refused the frame bound for C — the losing run, made observable")
        try await MeshDepartureRig.settle(
            [nodeA, nodeC], on: fabric, sampling: sample,
            until: { MeshMergeFixtures.roster(nodeA.manager).count == 2 }
        )
        #expect(MeshMergeFixtures.roster(nodeA.manager).count == 2, "A got it")
        #expect(MeshMergeFixtures.roster(nodeC.manager).count == 3, "C did not")
        MeshDepartureRig.consumeRotations([nodeA, nodeC])
        sample.reset()

        // The P4 default, explicit: no ack, no re-send timer. Two minutes of fabric time and a full
        // settle later, C is exactly as ignorant as it was.
        fabric.clock.advance(by: .seconds(120))
        try await MeshDepartureRig.settle([nodeA, nodeC], on: fabric)
        #expect(MeshMergeFixtures.roster(nodeC.manager).count == 3,
                "nothing re-sent the departure: the merge path IS the recovery (§21.3)")
        #expect(MeshDepartureRig.tokensReceived(by: nodeC, from: nodeB.handle).isEmpty,
                "and no frame from the leaver ever reached C")

        // The next merge is the recovery. A blip on the link A and C already have is enough.
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodeC.manager.applySessionEvent(.peerCommitted, committedPeer: nodeA.fingerprint)
        }
        #expect(nodeC.manager.awaitingResumeMerge)
        try await MeshDepartureRig.settle(
            [nodeA, nodeC], on: fabric, sampling: sample,
            until: { MeshMergeFixtures.roster(nodeC.manager).count == 2 }
        )
        #expect(MeshMergeFixtures.roster(nodeC.manager) == MeshMergeFixtures.roster(nodeA.manager),
                "C converged on A's roster at the next merge")
        #expect(MeshDepartureRig.quorum(nodeC) == 2)
        #expect(MeshDepartureRig.tokensReceived(by: nodeC, from: nodeA.handle)
                .contains(PayloadType.meshMemberDeparture.rawValue),
                "and the copy it folded came from A's re-gossip, never from the departed B")
        #expect(sample.causes(at: nodeC.label) == [.merge])
        MeshDepartureRig.consumeRotations([nodeA, nodeC])
        for node in nodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshDepartureMergeLawTests

/// The union laws, re-asserted with a **departure** in the union: a record that *removes* a member
/// must be as commutative, associative and idempotent as one that adds one.
@MainActor
@Suite(.serialized)
struct MeshDepartureMergeLawTests {

    /// A live manager on `ledger`, with its own sealed root.
    private func manager(
        founder: IdentityService, ledger: MeshMembershipLedger, meshID: UUID
    ) -> (manager: MeshNetworkManager, store: FernletStore) {
        let scoped = makeTestStore()
        let manager = MeshNetworkManager(store: scoped, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID)
        manager.seedMembershipLedgerForTesting(
            meshID: meshID, founderSigningPublicKey: founder.localSigningPublicKey, ledger: ledger
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }
        return (manager, scoped)
    }

    /// **Commutative, with a departure in the union.** A merges the branch holding the departure,
    /// the branch merges A's, and the two land on the identical derived roster and head set.
    @Test func aDepartureUnionIsCommutativeAtTheManagerSeam() throws {
        let meshID = UUID()
        let founder = try MeshPartitionFixtures.identity("law-founder")
        let members = try MeshMergeFixtures.members(2, "law-member")
        let base = try MeshPartitionFixtures.ledger(founder: founder, others: members, meshID: meshID)
        var withDeparture = base
        withDeparture.departures = withDeparture.departures.inserting(
            try SignedDepartureRecord.signed(meshID: meshID, identity: members[0])
        )
        var results: [[String]] = []
        var heads: [[String]] = []
        for (mine, theirs) in [(base, withDeparture), (withDeparture, base)] {
            let built = manager(founder: founder, ledger: mine, meshID: meshID)
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                built.manager.mergeReconnected(MeshMergeOffer(ledger: theirs), entry: .partitionHeal)
            }
            results.append(MeshMergeFixtures.roster(built.manager))
            heads.append(MeshMergeFixtures.sealedHeads(built.store))
            built.manager.leaveMesh()
        }
        #expect(results.count == 2 && results[0] == results[1],
                "L ∪ (L + departure) and (L + departure) ∪ L derive the identical roster")
        #expect(heads[0] == heads[1], "and the identical head set")
        #expect(results[0].count == 2 && !results[0].contains(members[0].localFingerprint),
                "three admitted, one departed")
    }

    /// **Idempotent, and no duplicate commit.** Merging the same offer twice moves nothing: the
    /// record counts do not grow and the second merge asks for no rotation at all.
    @Test func mergingADepartureTwiceIsANoOpAndCommitsNothingASecondTime() throws {
        let meshID = UUID()
        let founder = try MeshPartitionFixtures.identity("idem-founder")
        let members = try MeshMergeFixtures.members(2, "idem-member")
        let base = try MeshPartitionFixtures.ledger(founder: founder, others: members, meshID: meshID)
        var withDeparture = base
        withDeparture.departures = withDeparture.departures.inserting(
            try SignedDepartureRecord.signed(meshID: meshID, identity: members[0])
        )
        let built = manager(founder: founder, ledger: base, meshID: meshID)
        let offer = MeshMergeOffer(ledger: withDeparture)
        var firstCause: MeshKeyRotationCause?
        var secondCause: MeshKeyRotationCause?
        var counts: [[Int]] = []
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            built.manager.mergeReconnected(offer, entry: .partitionHeal)
            firstCause = built.manager.consumePendingRotationForTesting()
            counts.append(MeshPartitionFixtures.recordCounts(built.manager.membershipVerifier?.ledger))
            built.manager.mergeReconnected(offer, entry: .partitionHeal)
            secondCause = built.manager.consumePendingRotationForTesting()
            counts.append(MeshPartitionFixtures.recordCounts(built.manager.membershipVerifier?.ledger))
        }
        #expect(firstCause == .merge, "the first merge moved the roster and asked for its one epoch")
        #expect(secondCause == nil, "the second moved nothing, so it committed nothing and rotated nothing")
        #expect(counts.count == 2 && counts[0] == counts[1], "and the record sets did not grow")
        #expect(counts[0] == [3, 1, 0, 0])
        #expect(MeshMergeFixtures.roster(built.manager).count == 2)
        built.manager.leaveMesh()
    }

    /// **Associative, with a departure in the middle.** Folding a departure and then an admission
    /// reaches the same place as folding their union in one go.
    @Test func aDepartureUnionIsAssociativeAtTheManagerSeam() throws {
        let meshID = UUID()
        let founder = try MeshPartitionFixtures.identity("assoc-founder")
        let members = try MeshMergeFixtures.members(2, "assoc-member")
        let newcomer = try MeshMergeFixtures.members(1, "assoc-new")
        let base = try MeshPartitionFixtures.ledger(founder: founder, others: members, meshID: meshID)
        var departureOnly = MeshMembershipLedger.empty
        departureOnly.departures = departureOnly.departures.inserting(
            try SignedDepartureRecord.signed(meshID: meshID, identity: members[0])
        )
        let admissionOnly = try MeshPartitionFixtures.ledger(
            founder: founder, others: newcomer, meshID: meshID
        )
        let stepwise = manager(founder: founder, ledger: base, meshID: meshID)
        let combined = manager(founder: founder, ledger: base, meshID: meshID)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            stepwise.manager.mergeReconnected(
                MeshMergeOffer(ledger: departureOnly), entry: .partitionHeal
            )
            stepwise.manager.mergeReconnected(
                MeshMergeOffer(ledger: admissionOnly), entry: .partitionHeal
            )
            combined.manager.mergeReconnected(
                MeshMergeOffer(ledger: departureOnly.merging(admissionOnly)), entry: .partitionHeal
            )
        }
        #expect(MeshMergeFixtures.roster(stepwise.manager) == MeshMergeFixtures.roster(combined.manager),
                "(L ∪ D) ∪ A and L ∪ (D ∪ A) derive the identical roster")
        #expect(MeshMergeFixtures.sealedHeads(stepwise.store)
                == MeshMergeFixtures.sealedHeads(combined.store), "and the identical head set")
        #expect(MeshMergeFixtures.roster(combined.manager).count == 3,
                "founder + one original + the newcomer, with the leaver gone")
        stepwise.manager.leaveMesh()
        combined.manager.leaveMesh()
    }
}
