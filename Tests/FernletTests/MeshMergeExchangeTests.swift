// MeshMergeExchangeTests.swift
// FernletTests
//
// P4 item 2 (plan §10.3), second slice: the union exchange driven **end to end over the fabric**.
//
// `MeshMergePathTests` proves the merge PATH — every reconnect reaches `mergeMembershipLedger`, the
// union laws hold, the heads coexist — by handing offers to the manager directly. What it cannot
// show is the exchange that produces those offers on a real reconnect, because both halves of it
// are frames: the signed inventory digest that asks, and the bounded record re-gossip that answers
// (§10.5). Everything here is therefore two managers, one `FakePeerNetwork`, and the actual bytes:
//
//  1. **The ask crosses the wire.** A blip on A puts a `fernlet.mesh.inventory-digest.v1` envelope
//     on the fabric, addressed to the committed member B.
//  2. **The re-gossip answers over the same wire**, and every record frame it sends folds through
//     the ONE merge path while `awaitingResumeMerge` is set — never through the live-record insert.
//  3. **One `.merge` for the burst.** Three record frames, one rotation cause, and it is `.merge`
//     rather than one `.membership` per record.
//  4. **The window closes on a MATCHING digest**, which is the honest completion signal: the two
//     sides hold the same records, so there is nothing left to re-gossip.
//  5. **The ANSWER carries the epoch heads too** (P4 item 2c). A responder already inside its own
//     open window cannot open an exchange for the asker, so an answer of records alone left the
//     asker converged on the ledger and stranded on its own older head — the deadlock the seeded
//     convergence property found.
//
// **What the fabric carries and what this file supplies.** Frames are real: signed by the sending
// manager, encoded, carried by `FakePeerNetwork` on a clock the test owns, and verified on arrival
// through `FernletIdentityEnvelope.verify(identityService:replayCache:)` — the same check
// `ProximityCoordinator` makes, including the recipient gate and the replay cache. The one thing
// supplied here is the ROUTING step the coordinator would do next (`didReceive` → the manager),
// because a coordinator on this fabric would first want the whole identity-introduction ceremony,
// which is not what this file is about. Nothing else is short-circuited: every membership record
// and the digest still carry their own signatures and are still verified by
// `MeshMembershipRecordVerifier`.
//
// **Nothing sleeps.** Delivery happens when the test advances `VirtualClock`, and the managers'
// detached sends are drained with bounded `Task.yield()` rounds — never a wall-clock wait.
//
// **What a yield costs, and why the rotation claims are sampled.** A yield releases the main actor,
// and under a loaded suite whole seconds of wall clock pass there — more than enough for the 2 s
// rotation debounce to fire and consume its own pending cause. Anything read about that window
// AFTER a settle is therefore a race (it was, once). The samples are taken inside `settle`,
// immediately after each pump and before anything can suspend, which is deterministic under any
// load: the repository's wall-clock-deadline flake family, in miniature.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshMergeWireNode

/// One end of the wire: a manager, the fabric endpoint its slot sends over, and the coordinator
/// inbound frames are addressed to.
///
/// A class rather than a struct because ``delivered`` is a cursor into the endpoint's received
/// frames that the pump advances — a value type would hand every pump its own copy and re-deliver
/// the whole history each round.
@MainActor
final class MeshMergeWireNode {

    /// The sealed root this manager writes to. Held here because `MeshNetworkManager` keeps its
    /// host `unowned`: a store that only lives as long as the expression that made it traps.
    let store: FernletStore

    /// The manager under test at this end.
    let manager: MeshNetworkManager

    /// This end's fabric endpoint — what its slot sends over and what its peer's frames land in.
    let channel: FakePeerTransport

    /// The handle the OTHER end addresses this one by.
    let handle: PeerHandle

    /// The coordinator this end's slot was seated with; inbound frames are dispatched over it, and
    /// the manager finds the slot by identity comparison against it.
    let coordinator: ProximityCoordinator

    /// This end's replay cache, so a re-delivered envelope is refused here exactly as it would be
    /// on a real radio.
    let replayCache = ReplayCache()

    /// How many of ``channel``'s received frames have already been handed to the manager.
    var delivered = 0

    /// Builds one end.
    ///
    /// - Parameters:
    ///   - store: The sealed root.
    ///   - manager: The manager at this end.
    ///   - channel: This end's fabric endpoint.
    ///   - handle: The handle the other end addresses this one by.
    ///   - coordinator: The slot's coordinator.
    init(
        store: FernletStore,
        manager: MeshNetworkManager,
        channel: FakePeerTransport,
        handle: PeerHandle,
        coordinator: ProximityCoordinator
    ) {
        self.store = store
        self.manager = manager
        self.channel = channel
        self.handle = handle
        self.coordinator = coordinator
    }
}

// MARK: - MeshMergeWire

/// The rig: two managers of one mesh, wired to each other across a `FakePeerNetwork`.
@MainActor
enum MeshMergeWire {

    /// The most frames one pump will move. A bounded loop (Power of 10 R2) whose ceiling is a full
    /// re-gossip plus its digests, so hitting it means the fabric is looping rather than converging.
    static let maxPumpedFrames = MeshNetworkManager.maxReGossipFrames + 8

    /// How many drain rounds one settle runs, and how many yields each round gives the main actor.
    /// Four rounds cover the longest chain here (send → deliver → dispatch → answer → deliver);
    /// the rest is headroom, and none of it is time.
    static let settleRounds = 8
    static let yieldsPerRound = 4

    /// Puts a manager into a live session on a seeded ledger — the shape both ends start from.
    ///
    /// Deliberately *not* `MeshMergeFixtures.liveManager`: this rig needs one end that is a MEMBER
    /// of somebody else's mesh (its ledger rooted at the other device's founder key), which that
    /// fixture cannot express.
    ///
    /// - Parameters:
    ///   - manager: The manager to start.
    ///   - ledger: The records it begins with.
    ///   - founderKey: The signing key its verifier will bootstrap from.
    ///   - meshID: The mesh both ends are in.
    ///   - createdAt: The mesh's signed creation instant, which is also what
    ///     `MeshNetworkManager.routedHardDeadline` derives the session ceiling from. `nil` — the
    ///     default — is the pinned membership anchor; a routed rig passes
    ///     `MeshRoutedFixtureClock.createdAt` so its manifests' expiry and its mesh's deadline roll
    ///     together (P5 item 6a). Spelled `nil` rather than defaulted to the anchor itself because
    ///     a default argument is evaluated in the CALLER's isolation, and the anchor is
    ///     `@MainActor`.
    static func start(
        _ manager: MeshNetworkManager,
        ledger: MeshMembershipLedger,
        founderKey: Data,
        meshID: UUID,
        createdAt: Date? = nil
    ) {
        manager.currentMesh = MeshP3Acceptance.mesh(
            for: manager, meshID: meshID, createdAt: createdAt ?? MeshP3Acceptance.base
        )
        manager.seedMembershipLedgerForTesting(
            meshID: meshID, founderSigningPublicKey: founderKey, ledger: ledger
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }
    }

    /// Hands whatever the fabric has delivered to `node` to its manager, through the real receive
    /// entry point and after the real envelope verification.
    ///
    /// - Returns: How many frames were moved.
    @discardableResult
    static func pump(_ node: MeshMergeWireNode) throws -> Int {
        var moved = 0
        let frames = node.channel.receivedFrames
        while node.delivered < frames.count, moved < maxPumpedFrames {
            let frame = frames[node.delivered]
            node.delivered += 1
            moved += 1
            let envelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: frame.data)
            let plaintext = try envelope.verify(
                identityService: node.manager.identityForTesting, replayCache: node.replayCache
            )
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                node.manager.proximityCoordinator(
                    node.coordinator, didReceive: envelope, plaintext: plaintext, from: nil
                )
            }
        }
        return moved
    }

    /// Lets both managers' detached sends run, moves the fabric forward, and delivers what arrived.
    ///
    /// Bounded on both axes and free of wall-clock waits: the yields drain the main actor's queue
    /// and the clock advance is the only thing that makes a frame arrive.
    ///
    /// `observe` runs **immediately after each pump, with no suspension in between**, which is the
    /// only way to read state a debounce window can consume: `await Task.yield()` releases the main
    /// actor, and under a loaded suite seconds of wall clock pass there — long enough for the 2 s
    /// rotation window to fire and take its cause with it. Anything read after a settle is a race;
    /// anything read here is not.
    ///
    /// - Parameters:
    ///   - nodes: Both ends.
    ///   - fabric: The medium to advance.
    ///   - observe: Called after each node's pump, before anything can suspend.
    ///   - isDone: Ends the settle early once the scenario has what it is waiting for.
    static func settle(
        _ nodes: [MeshMergeWireNode],
        on fabric: FakePeerNetwork,
        observing observe: (MeshMergeWireNode) -> Void = { _ in },
        until isDone: () -> Bool = { false }
    ) async throws {
        for _ in 0..<settleRounds {
            for _ in 0..<yieldsPerRound { await Task.yield() }
            fabric.clock.advance(by: .milliseconds(50))
            for node in nodes {
                try pump(node)
                observe(node)
            }
            if isDone() { return }
        }
    }

    /// The payload-type tokens an endpoint has received, in arrival order.
    static func receivedTypes(_ channel: FakePeerTransport) -> [String] {
        channel.receivedFrames.compactMap { frame in
            try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: frame.data).payloadTypeToken
        }
    }
}

// MARK: - MeshMergeExchangeTests

/// The merge exchange over the fake radio: the digest ask, the re-gossip answer, and the window
/// that closes on convergence.
@MainActor
@Suite(.serialized)
struct MeshMergeExchangeTests {

    /// **Claims 1–4.** A reconnect asks over the wire, the answer folds through the one merge path
    /// as a single `.merge`, and the matching digest that follows closes the window.
    @Test func aReconnectAsksOverTheWireAndTheReGossipFoldsAsOneMerge() async throws {
        let fabric = FakePeerNetwork()
        let left = fabric.addEndpoint(named: "merge-left")
        let right = fabric.addEndpoint(named: "merge-right")
        fabric.connect(left.handle, right.handle)
        fabric.clock.advance(by: .milliseconds(50))

        // The identities are INJECTED. A device holds one proximity identity, so the default
        // `IdentityService` is keyed on one process-wide keychain service — two managers built here
        // would otherwise share a fingerprint and the whole scenario would be one device talking to
        // itself. This is also a hard precondition rather than one expectation among many: three
        // ends that collided would make every assertion below vacuous rather than wrong.
        let storeA = makeTestStore()
        let storeB = makeTestStore()
        let idA = try MeshPartitionFixtures.identity("wire-a")
        let idB = try MeshPartitionFixtures.identity("wire-b")
        let newcomer = try MeshPartitionFixtures.identity("wire-newcomer")
        #expect(
            Set([idA.localFingerprint, idB.localFingerprint, newcomer.localFingerprint]).count == 3,
            "the rig needs three distinct provisioned identities"
        )
        let managerA = MeshNetworkManager(
            store: storeA, transport: FakeMeshTransportSession(), identity: idA
        )
        let managerB = MeshNetworkManager(
            store: storeB, transport: FakeMeshTransportSession(), identity: idB
        )

        // B's branch admitted somebody A never saw. A's ledger is B's minus that one record — the
        // SAME signed bytes, so a converged A and B hold an identical inventory and their digests
        // can actually match (two independently minted admissions for one member would not).
        let meshID = UUID()
        let full = try MeshPartitionFixtures.ledger(
            founder: idA, others: [idB, newcomer], meshID: meshID
        )
        var partial = MeshMembershipLedger.empty
        for record in full.admissions.all where record.memberFingerprint != newcomer.localFingerprint {
            partial.admissions = partial.admissions.inserting(record)
        }
        #expect(partial.admissions.count == 2 && full.admissions.count == 3)

        MeshMergeWire.start(
            managerA, ledger: partial, founderKey: idA.localSigningPublicKey, meshID: meshID
        )
        MeshMergeWire.start(
            managerB, ledger: full, founderKey: idA.localSigningPublicKey, meshID: meshID
        )
        let coordinatorA = MeshP3Acceptance.coordinator()
        let coordinatorB = MeshP3Acceptance.coordinator()
        managerA.addSlotForTesting(
            coordinator: coordinatorA, peer: right.handle,
            fingerprint: idB.localFingerprint, channel: left.transport
        )
        managerB.addSlotForTesting(
            coordinator: coordinatorB, peer: left.handle,
            fingerprint: idA.localFingerprint, channel: right.transport
        )
        let nodeA = MeshMergeWireNode(
            store: storeA, manager: managerA, channel: left.transport,
            handle: left.handle, coordinator: coordinatorA
        )
        let nodeB = MeshMergeWireNode(
            store: storeB, manager: managerB, channel: right.transport,
            handle: right.handle, coordinator: coordinatorB
        )
        #expect(MeshMergeFixtures.roster(managerA).count == 2, "A is short one member")
        #expect(MeshMergeFixtures.roster(managerB).count == 3, "B holds the record A lacks")

        // The reconnect: B — already a member — commits into A's live session.
        managerA.applySessionEvent(.peerCommitted, committedPeer: idB.localFingerprint)
        #expect(managerA.awaitingResumeMerge, "the blip opened a merge window")
        #expect(managerA.pendingMergeEntry == .blip)
        // Sampled after every pump, because the 2 s debounce window can fire in the yields between
        // them: what a rotation asked for is only knowable while it is still pending.
        var causes: Set<MeshKeyRotationCause> = []
        var windows: Set<Date> = []
        try await MeshMergeWire.settle([nodeA, nodeB], on: fabric, observing: { node in
            guard node === nodeA else { return }
            if let cause = node.manager.rotationTriggers.pendingCause { causes.insert(cause) }
            if let firesAt = node.manager.rotationTriggers.firesAt { windows.insert(firesAt) }
        }, until: { managerA.mergeApplicationCount >= 3 })

        // 1. The ask crossed.
        #expect(MeshMergeWire.receivedTypes(right.transport)
            .contains(PayloadType.meshInventoryDigest.rawValue),
                "the signed inventory digest actually travelled the wire to the committed member")
        // 2. The answer crossed, and every record frame folded through the merge path.
        let answered = MeshMergeWire.receivedTypes(left.transport)
            .filter { $0 == PayloadType.meshMemberAdmission.rawValue }
        #expect(answered.count == 3, "the bounded re-gossip sent B's whole ledger back")
        #expect(managerA.mergeApplicationCount == answered.count,
                "every record frame went through mergeReconnected — none took the live-record path")
        #expect(managerA.lastMergeEntry == .blip, "and each recorded the door the merge came through")
        #expect(MeshMergeFixtures.roster(managerA).count == 3, "A folded the member it lacked")
        // 3. One cause for the burst, and it is the merge's.
        #expect(causes == [.merge],
                "the burst asked for ONE kind of rotation and it is the merge's, never one per record")
        #expect(windows.count == 1,
                "and for ONE debounce window: a second value here is a second rotation")

        // 4. B now asks in its turn; the digest matches, which is what ends A's merge.
        #expect(managerA.awaitingResumeMerge, "the window is still open until convergence is proven")
        managerB.applySessionEvent(.peerCommitted, committedPeer: idA.localFingerprint)
        try await MeshMergeWire.settle(
            [nodeA, nodeB], on: fabric, until: { !managerA.awaitingResumeMerge }
        )
        #expect(!managerA.awaitingResumeMerge,
                "a peer digest that MATCHES local inventory is the merge, finished")
        #expect(managerA.pendingMergeEntry == nil, "and the door it came through is forgotten with it")
        #expect(MeshMergeFixtures.roster(managerA) == MeshMergeFixtures.roster(managerB),
                "both ends converged on one roster")

        managerA.leaveMesh()
        managerB.leaveMesh()
    }

    /// **Claim 5 (P4 item 2c): the answer to a MISMATCHED digest carries the epoch heads too.**
    ///
    /// The ask half sends both frames — the digest and `fernlet.mesh.epoch-heads.v1`. The answer
    /// half used to send only records, and that asymmetry deadlocks a healing mesh: a device inside
    /// an open merge window opens no second exchange (`openBlipMergeIfReconnected` guards on
    /// `!awaitingResumeMerge`) and an exchange was the only other sender of a head, so a member that
    /// only ever *answered* a digest converged on the responder's ledger while still counting up
    /// from its own older `rotationBasisHead` — with nothing left in flight to correct it, ever.
    /// The seeded convergence property found it (`MeshConvergencePropertyTests`, seed
    /// `0x308d0d414707d80` on `2/2`); this is that shape at two managers and one wire.
    ///
    /// The responder is **already** inside a window opened by a third member, which is what makes
    /// the scenario the defect and not the happy path: B opens no *second exchange* for A, so what
    /// carries B's head to A is B's answer — and, since P4 item 9b, B's one-shot ask of the peer
    /// that has just committed (`askOneReconnectedPeer`, which arms no window). Both are asserted
    /// below, because the answer half is still the only one a responder that never sees a commit
    /// event can send. Both halves of the answer are one merge:
    /// the records ask for `.merge` through `mergeMembershipLedger`, the folded head asks for
    /// `.merge` through `requestMergeRotationForDivergentHeads`, and the two coalesce in one 2 s
    /// window rather than opening a second.
    @Test func theAnswerToAMismatchedDigestCarriesTheEpochHeads() async throws {
        let fabric = FakePeerNetwork()
        let left = fabric.addEndpoint(named: "deadlock-left")
        let right = fabric.addEndpoint(named: "deadlock-right")
        let bystander = fabric.addEndpoint(named: "deadlock-bystander")
        fabric.connect(left.handle, right.handle)
        fabric.connect(right.handle, bystander.handle)
        fabric.clock.advance(by: .milliseconds(50))

        let storeA = makeTestStore()
        let storeB = makeTestStore()
        let idA = try MeshPartitionFixtures.identity("deadlock-a")
        let idB = try MeshPartitionFixtures.identity("deadlock-b")
        let idC = try MeshPartitionFixtures.identity("deadlock-c")
        #expect(Set([idA.localFingerprint, idB.localFingerprint, idC.localFingerprint]).count == 3,
                "the rig needs three distinct provisioned identities")

        // A's ledger is B's minus C's admission — the same signed bytes, so the digests differ only
        // because one record is missing. The heads differ too, and by more than one: A must end on
        // B's, which it can only learn from the answer.
        let meshID = UUID()
        let full = try MeshPartitionFixtures.ledger(founder: idA, others: [idB, idC], meshID: meshID)
        var partial = MeshMembershipLedger.empty
        for record in full.admissions.all where record.memberFingerprint != idC.localFingerprint {
            partial.admissions = partial.admissions.inserting(record)
        }
        #expect(partial.admissions.count == 2 && full.admissions.count == 3)
        let headA = try MeshReconcileFixtures.head(2, idA, meshID)
        let headB = try MeshReconcileFixtures.head(5, idB, meshID)
        let managerA = MeshReconcileFixtures.member(
            store: storeA, identity: idA, ledger: partial,
            founderKey: idA.localSigningPublicKey, meshID: meshID, head: headA
        )
        let managerB = MeshReconcileFixtures.member(
            store: storeB, identity: idB, ledger: full,
            founderKey: idA.localSigningPublicKey, meshID: meshID, head: headB
        )
        #expect(managerA.rotationBasisHeadForTesting == headA, "A starts on the lower branch head")
        #expect(managerB.rotationBasisHeadForTesting == headB, "and B on the higher one")

        // B is ALREADY awaiting, on a window opened by C. Its ask went to C and to nobody else, so
        // nothing B holds has ever been offered to A — and B will now refuse to open a second
        // exchange however often A commits. This is the deadlock's precondition, made explicit.
        let coordinatorBC = MeshP3Acceptance.coordinator()
        managerB.addSlotForTesting(
            coordinator: coordinatorBC, peer: bystander.handle,
            fingerprint: idC.localFingerprint, channel: right.transport
        )
        managerB.applySessionEvent(.peerCommitted, committedPeer: idC.localFingerprint)
        #expect(managerB.awaitingResumeMerge, "B's merge window is open, and only C was asked")

        let coordinatorA = MeshP3Acceptance.coordinator()
        let coordinatorBA = MeshP3Acceptance.coordinator()
        managerA.addSlotForTesting(
            coordinator: coordinatorA, peer: right.handle,
            fingerprint: idB.localFingerprint, channel: left.transport
        )
        managerB.addSlotForTesting(
            coordinator: coordinatorBA, peer: left.handle,
            fingerprint: idA.localFingerprint, channel: right.transport
        )
        let nodeA = MeshMergeWireNode(
            store: storeA, manager: managerA, channel: left.transport,
            handle: left.handle, coordinator: coordinatorA
        )
        let nodeB = MeshMergeWireNode(
            store: storeB, manager: managerB, channel: right.transport,
            handle: right.handle, coordinator: coordinatorBA
        )

        // A reconnects and asks. Only the answer can come back.
        managerA.applySessionEvent(.peerCommitted, committedPeer: idB.localFingerprint)
        #expect(managerA.awaitingResumeMerge, "the blip opened A's window")
        var causes: Set<MeshKeyRotationCause> = []
        var windows: Set<Date> = []
        try await MeshMergeWire.settle([nodeA, nodeB], on: fabric, observing: { node in
            guard node === nodeA else { return }
            if let cause = node.manager.rotationTriggers.pendingCause { causes.insert(cause) }
            if let firesAt = node.manager.rotationTriggers.firesAt { windows.insert(firesAt) }
        }, until: {
            managerA.knownEpochHeads.contains(headB) && managerA.mergeApplicationCount >= 3
        })

        // 1. The defect itself: the answer carried a head, and it was the ONLY thing that could.
        let toA = MeshMergeWire.receivedTypes(left.transport)
        #expect(toA.contains(PayloadType.meshEpochHeads.rawValue),
                "the answer to a mismatched digest carries the responder's epoch heads")
        #expect(managerB.awaitingResumeMerge,
                "B stayed awaiting throughout: it never opened a second exchange of its own")
        #expect(managerB.rotationBasisHeadForTesting == headB,
                "and nothing it received moved the head it was already counting up from")

        // 2. The asker ends on the RESPONDER's basis head, not on its own older one.
        #expect(managerA.knownEpochHeads.contains(headB), "A folded the branch head it had not seen")
        #expect(managerA.rotationBasisHeadForTesting == headB,
                "A counts the post-merge epoch up from B's head, not from its own stranded one")
        #expect(managerA.rotationBasisHeadForTesting == managerB.rotationBasisHeadForTesting,
                "so §10.3's `max` is one number across the merge")

        // 3. The records converged in the same answer, and the whole answer is ONE `.merge`.
        #expect(MeshMergeFixtures.roster(managerA) == MeshMergeFixtures.roster(managerB),
                "both ends converged on one roster")
        #expect(managerA.mergeApplicationCount == 3,
                "every record frame went through mergeReconnected — none took the live-record path")
        #expect(causes == [.merge],
                "the records and the folded head asked for ONE kind of rotation, and it is the merge's")
        #expect(windows.count == 1,
                "and for ONE debounce window: a second value here is a second rotation")

        managerA.consumePendingRotationForTesting()
        managerB.consumePendingRotationForTesting()
        managerA.leaveMesh()
        managerB.leaveMesh()
    }

    /// **Claim 6 (P4 item 9b): a device already inside a merge window still ASKS a peer that
    /// commits later — without opening a second window.**
    ///
    /// Claim 5 closed the answer half. This is the ask half of the same asymmetry, one party wider,
    /// and §16.2's roster-8 row is what found it: on a `4/2/2` heal a member acquires most of its
    /// slots *after* its first reconnect, and `beginMergeExchange` only ever asked the slots that
    /// existed when it ran. A peer seated afterwards was therefore never asked — and when it was
    /// awaiting too, never told either, because an exchange is the only unprompted sender of a
    /// digest or a head. Both sides then counted the post-merge epoch up from different heads, for
    /// good; §16.2's "exactly one post-merge epoch at every member" failed at the member.
    ///
    /// `openBlipMergeIfReconnected` now answers that with a one-shot ask of exactly the committing
    /// peer. The three claims: the two frames reach the new peer, the window is **not** re-armed
    /// (one merge stays one merge), and a peer that is not on the roster still gets nothing.
    @Test func aDeviceAlreadyAwaitingStillAsksAPeerThatCommitsLater() async throws {
        let fabric = FakePeerNetwork()
        let left = fabric.addEndpoint(named: "late-left")
        let right = fabric.addEndpoint(named: "late-right")
        let bystander = fabric.addEndpoint(named: "late-bystander")
        fabric.connect(left.handle, right.handle)
        fabric.connect(right.handle, bystander.handle)
        fabric.clock.advance(by: .milliseconds(50))

        let storeA = makeTestStore()
        let storeB = makeTestStore()
        let idA = try MeshPartitionFixtures.identity("late-a")
        let idB = try MeshPartitionFixtures.identity("late-b")
        let idC = try MeshPartitionFixtures.identity("late-c")
        #expect(Set([idA.localFingerprint, idB.localFingerprint, idC.localFingerprint]).count == 3,
                "the rig needs three distinct provisioned identities")
        let meshID = UUID()
        let ledger = try MeshPartitionFixtures.ledger(founder: idA, others: [idB, idC], meshID: meshID)
        let headA = try MeshReconcileFixtures.head(2, idA, meshID)
        let headB = try MeshReconcileFixtures.head(9, idB, meshID)
        let managerA = MeshReconcileFixtures.member(
            store: storeA, identity: idA, ledger: ledger,
            founderKey: idA.localSigningPublicKey, meshID: meshID, head: headA
        )
        let managerB = MeshReconcileFixtures.member(
            store: storeB, identity: idB, ledger: ledger,
            founderKey: idA.localSigningPublicKey, meshID: meshID, head: headB
        )

        // B's window is opened by C, and only C is in its slot set at that moment.
        managerB.addSlotForTesting(
            coordinator: MeshP3Acceptance.coordinator(), peer: bystander.handle,
            fingerprint: idC.localFingerprint, channel: right.transport
        )
        managerB.applySessionEvent(.peerCommitted, committedPeer: idC.localFingerprint)
        #expect(managerB.awaitingResumeMerge, "B is mid-merge with C before A is ever seated")
        let entryBeforeA = managerB.pendingMergeEntry

        // A is seated afterwards — the late slot a branch-by-branch heal really produces.
        let coordinatorA = MeshP3Acceptance.coordinator()
        let coordinatorBA = MeshP3Acceptance.coordinator()
        managerA.addSlotForTesting(
            coordinator: coordinatorA, peer: right.handle,
            fingerprint: idB.localFingerprint, channel: left.transport
        )
        managerB.addSlotForTesting(
            coordinator: coordinatorBA, peer: left.handle,
            fingerprint: idA.localFingerprint, channel: right.transport
        )
        let nodeA = MeshMergeWireNode(
            store: storeA, manager: managerA, channel: left.transport,
            handle: left.handle, coordinator: coordinatorA
        )
        let nodeB = MeshMergeWireNode(
            store: storeB, manager: managerB, channel: right.transport,
            handle: right.handle, coordinator: coordinatorBA
        )

        // A stranger commits first: not on the roster, so it is told nothing at all.
        managerB.applySessionEvent(.peerCommitted, committedPeer: "0000000000000000")
        try await MeshMergeWire.settle([nodeA, nodeB], on: fabric)
        #expect(MeshMergeWire.receivedTypes(left.transport).isEmpty,
                "a commit from a peer that is not on the roster asks nobody anything")

        managerB.applySessionEvent(.peerCommitted, committedPeer: idA.localFingerprint)
        #expect(managerB.awaitingResumeMerge && managerB.pendingMergeEntry == entryBeforeA,
                "the ask arms no second window: one merge stays one merge")
        try await MeshMergeWire.settle([nodeA, nodeB], on: fabric, until: {
            managerA.knownEpochHeads.contains(headB)
        })

        let toA = MeshMergeWire.receivedTypes(left.transport)
        #expect(toA.contains(PayloadType.meshInventoryDigest.rawValue),
                "the late peer is ASKED, though B was awaiting when it committed")
        #expect(toA.contains(PayloadType.meshEpochHeads.rawValue),
                "and told which branch head B is on — the half that convergence needs")
        #expect(managerA.rotationBasisHeadForTesting == headB,
                "so A counts the post-merge epoch up from B's head, not its own stranded one")
        #expect(managerB.awaitingResumeMerge && managerB.pendingMergeEntry == entryBeforeA,
                "and B's original window is still the only one")

        managerA.consumePendingRotationForTesting()
        managerB.consumePendingRotationForTesting()
        managerA.leaveMesh()
        managerB.leaveMesh()
    }
}
