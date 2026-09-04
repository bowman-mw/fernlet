// MeshMergeWindowTests.swift
// FernletTests
//
// Network migration P5 item 7: the merge-window redesign, which retires P4's deferred defect 2d.
//
// Two suites, and the split is the design:
//
// - `MeshMergeWindowStateTests` drives `MeshMergeWindow` as the pure value it is — no manager, no
//   store, no clock. The closing law is `pending = (asked ∪ answered) ∩ reachable ∖ matched`, and
//   every claim about it is one line here rather than a settle away.
// - `MeshMergeWindowWireTests` drives the same rule through real signed frames on `FakePeerNetwork`.
//   Cells with three managers run on `MeshDepartureRig`, never on `MeshMergeWire`: a
//   `MeshMergeWireNode` holds exactly ONE coordinator, and `MeshNetworkManager` resolves an inbound
//   frame's slot by coordinator identity — so on a node with two peers every frame would be
//   attributed to one of them and an `asked` set of two could not be observed at all.
//
// Window state is sampled **right after a synchronous pump**, never after an `await`: a yield
// releases the main actor and the 2 s rotation debounce can fire in the gap. The rigs' `settle`
// helpers run their `until:` / `sampling:` closures at exactly that point.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshMergeWindowStateTests

/// The closing law, as pure values.
@MainActor
@Suite
struct MeshMergeWindowStateTests {

    /// The mesh every fixture digest names.
    private static let meshID = UUID()

    /// The instant every window records. Recorded, never compared.
    private static let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private static let peerB = "fingerprint-b"
    private static let peerC = "fingerprint-c"
    private static let peerD = "fingerprint-d"
    private static let peerZ = "fingerprint-z"

    /// A digest that differs from every other `byte`, and only in its record hash.
    private static func digest(_ byte: UInt8) -> MeshInventoryDigest {
        MeshInventoryDigest(
            meshID: meshID,
            admissionCount: 2, departureCount: 0, removalCount: 0, terminationCount: 0,
            recordsHash: Data(repeating: byte, count: MeshMembershipEventFormat.digestByteCount)
        )
    }

    /// A freshly armed window.
    private static func opened() -> MeshMergeWindow { .opened(at: instant) }

    /// **1.** A window waits on every peer it asked — and a window that asked nobody (the pre-guard
    /// arming) closes at its first evaluation.
    @Test func anOpenedWindowWaitsOnEveryPeerItAsked() {
        let window = Self.opened().asking([Self.peerB, Self.peerC])
        #expect(window.verdict(reachable: [Self.peerB, Self.peerC]) == .open(outstanding: 2))
        #expect(Self.opened().verdict(reachable: [Self.peerB]) == .closed(.nothingOutstanding),
                "an idle window has nothing to wait for")
    }

    /// **2. 2d, in one line.** One match of two does not close the window.
    @Test func oneMatchOfTwoDoesNotClose() {
        let window = Self.opened().asking([Self.peerB, Self.peerC]).matching(Self.peerB)
        #expect(window.verdict(reachable: [Self.peerB, Self.peerC]) == .open(outstanding: 1))
    }

    /// **3.** Every asked peer matched closes it, and says why.
    @Test func everyAskedPeerMatchedCloses() {
        let window = Self.opened()
            .asking([Self.peerB, Self.peerC]).matching(Self.peerB).matching(Self.peerC)
        #expect(window.verdict(reachable: [Self.peerB, Self.peerC]) == .closed(.converged))
    }

    /// **4. The 2c deadlock, unrepresentable.** Answering alone never closes anything.
    @Test func answeringAloneNeverCloses() {
        let window = Self.opened().answering(Self.peerB)
        #expect(window.verdict(reachable: [Self.peerB]) == .open(outstanding: 1))
        #expect(window.role == .responder)
    }

    /// **5.** An answered peer closes only when it matches back.
    @Test func anAnsweredPeerClosesOnlyWhenItMatchesBack() {
        let window = Self.opened().answering(Self.peerB).matching(Self.peerB)
        #expect(window.verdict(reachable: [Self.peerB]) == .closed(.converged))
    }

    /// **6.** A late ask joins the same window and re-opens nothing *another* peer already proved.
    @Test func aLateAskJoinsTheSameWindowAndReopensNothing() {
        let window = Self.opened().asking([Self.peerB]).matching(Self.peerB).reAsking(Self.peerD)
        #expect(window.verdict(reachable: [Self.peerB, Self.peerD]) == .open(outstanding: 1))
        #expect(window.matched.contains(Self.peerB),
                "re-asking D did not un-prove B — the un-match is per peer, not per window")
    }

    /// **6a.** But a late ask **does** un-prove the peer it re-asks (D-7.32): a late ask exists
    /// because that peer's link dropped and re-formed, and while it was gone it may have linked to
    /// the other branch of a split — so a match recorded before it left proves nothing now.
    @Test func aLateAskToAMatchedPeerReopensThatPeersObligation() {
        let reAsked = Self.opened()
            .asking([Self.peerB, Self.peerC]).matching(Self.peerC).reAsking(Self.peerC)
        #expect(reAsked.asked == [Self.peerB, Self.peerC], "still one window, one peer wider")
        #expect(!reAsked.matched.contains(Self.peerC))
        #expect(reAsked.verdict(reachable: [Self.peerB, Self.peerC]) == .open(outstanding: 2))
        let bMatched = reAsked.matching(Self.peerB)
        #expect(bMatched.verdict(reachable: [Self.peerB, Self.peerC]) == .open(outstanding: 1),
                "the other peer's match cannot close a window on the re-asked peer's behalf")
        #expect(bMatched.matching(Self.peerC)
            .verdict(reachable: [Self.peerB, Self.peerC]) == .closed(.converged),
                "and its own fresh digest still closes it")
    }

    /// **7.** A mismatching digest un-matches its sender: the obligation an answer creates cannot be
    /// discharged by the match it just contradicted.
    @Test func aMismatchingDigestUnMatchesItsSender() {
        let window = Self.opened().asking([Self.peerB]).matching(Self.peerB).answering(Self.peerB)
        #expect(window.verdict(reachable: [Self.peerB]) == .open(outstanding: 1))
        #expect(!window.matched.contains(Self.peerB))
    }

    /// **7a.** The monotonicity that IS kept, and the one way back into `matched`: the peer's own
    /// evidence, re-evaluated against a ledger that has since grown.
    @Test func onlyThePeersOwnEvidenceMovesItBackToMatched() {
        let reAsked = Self.opened().asking([Self.peerB]).matching(Self.peerB).asking([Self.peerB])
        #expect(reAsked.verdict(reachable: [Self.peerB]) == .closed(.converged),
                "the OPENING ask cannot un-match; the LATE ask has its own transition (test 6a)")
        let local = Self.digest(0x11)
        let recovered = Self.opened()
            .asking([Self.peerB]).matching(Self.peerB).answering(Self.peerB)
            .recording(local, from: Self.peerB)
            .reEvaluated(against: local, reachable: [Self.peerB])
        #expect(recovered.verdict(reachable: [Self.peerB]) == .closed(.converged))
    }

    /// **8.** A matching digest from a peer the window never asked is recorded and asks nothing.
    @Test func anUnaskedPeersMatchIsRecordedAndAsksNothing() {
        let window = Self.opened().asking([Self.peerB]).matching(Self.peerZ)
        #expect(window.verdict(reachable: [Self.peerB, Self.peerZ]) == .open(outstanding: 1))
        #expect(window.matched.contains(Self.peerZ))
        #expect(!window.asked.contains(Self.peerZ), "recorded, never promoted into the ask")
    }

    /// **9.** An unreachable peer is not waited for — the departure rule, with no fourth state.
    @Test func anUnreachablePeerIsNotWaitedFor() {
        let matched = Self.opened().asking([Self.peerB, Self.peerC]).matching(Self.peerB)
        #expect(matched.verdict(reachable: [Self.peerB]) == .closed(.converged))
        let unmatched = Self.opened().asking([Self.peerB, Self.peerC])
        #expect(unmatched.verdict(reachable: []) == .closed(.nothingOutstanding),
                "a window whose peers all left closes honestly, and says which closure it was")
    }

    /// **10.** Every set is bounded by the roster cap.
    @Test func everySetIsBoundedByTheRosterCap() {
        let cap = MeshMembershipBounds.maxRosterMembers
        let peers = (0..<(cap + 3)).map { "over-\($0)" }
        var window = Self.opened().asking(Set(peers))
        for peer in peers {
            window = window.answering(peer).matching(peer)
                .recording(Self.digest(0x22), from: peer)
        }
        #expect(window.asked.count <= cap)
        #expect(window.answered.count <= cap)
        #expect(window.matched.count <= cap)
        #expect(window.evidence.count <= cap)
    }

    /// **11.** A proof is sent once per distinct digest.
    @Test func aProofIsSentOncePerDistinctDigest() {
        let first = Self.digest(0x31)
        let second = Self.digest(0x32)
        let window = Self.opened()
        #expect(window.needsProof(of: first))
        let advertised = window.advertised(first)
        #expect(!advertised.needsProof(of: first), "the state already on the wire needs no frame")
        #expect(advertised.needsProof(of: second))
    }

    /// **12.** The proof cap is derived from the ledger's own bounds, equals the re-gossip budget,
    /// and cannot bite before the ledger is full.
    @Test func theProofCapIsDerivedAndCannotBiteBeforeTheLedgerIsFull() {
        #expect(MeshMergeWindow.maxProofs
                == MeshMembershipBounds.maxRecordsPerKind * 3
                + MeshMembershipBounds.maxTerminationRecords)
        #expect(MeshMergeWindow.maxProofs == MeshNetworkManager.maxReGossipFrames,
                "re-deriving the re-gossip budget must not silently leave the proof cap behind")
        var window = Self.opened()
        for index in 0..<MeshMergeWindow.maxProofs {
            window = window.advertised(Self.digest(UInt8(index % 251)))
        }
        #expect(!window.needsProof(of: Self.digest(0xFE)), "the budget is spent")
    }

    /// **13.** The role is derived from the sets, never stored.
    @Test func roleIsDerivedFromTheSets() {
        #expect(Self.opened().asking([Self.peerB]).role == .initiator)
        #expect(Self.opened().answering(Self.peerB).role == .responder)
        #expect(Self.opened().asking([Self.peerB]).answering(Self.peerB).role == .both)
        #expect(Self.opened().role == .idle)
    }

    /// **14.** `openedAt` is recorded and never branched on: two windows differing only in it give
    /// identical verdicts everywhere. The value-level proof that no timer exists.
    @Test func openedAtIsRecordedAndNeverBranchedOn() {
        let early = MeshMergeWindow.opened(at: Self.instant)
            .asking([Self.peerB, Self.peerC]).matching(Self.peerB)
        let late = MeshMergeWindow.opened(at: Self.instant.addingTimeInterval(86_400))
            .asking([Self.peerB, Self.peerC]).matching(Self.peerB)
        let sets: [Set<String>] = [[], [Self.peerB], [Self.peerC], [Self.peerB, Self.peerC]]
        for reachable in sets {
            #expect(early.verdict(reachable: reachable) == late.verdict(reachable: reachable))
        }
        #expect(early.openedAt != late.openedAt, "the instant is still recorded")
    }

    /// **15.** The closure and role vocabularies are frozen English tokens.
    @Test func theClosureVocabularyIsFrozenEnglish() {
        #expect(MeshMergeWindowClosure.allCases.map(\.rawValue)
                == ["converged", "nothingOutstanding"])
        #expect(MeshMergeWindowRole.initiator.rawValue == "initiator")
        #expect(MeshMergeWindowRole.responder.rawValue == "responder")
        #expect(MeshMergeWindowRole.both.rawValue == "both")
        #expect(MeshMergeWindowRole.idle.rawValue == "idle")
    }

    /// **15a.** The evidence is the window's own, bounded, and cannot pre-date it.
    @Test func evidenceIsWindowScopedAndBounded() {
        let local = Self.digest(0x41)
        let cap = MeshMembershipBounds.maxRosterMembers
        var recorded = Self.opened()
        for index in 0..<(cap + 3) { recorded = recorded.recording(local, from: "ev-\(index)") }
        #expect(recorded.evidence.count <= cap)
        let fresh = MeshMergeWindow.opened(at: Self.instant).asking([Self.peerB])
        #expect(fresh.reEvaluated(against: local, reachable: [Self.peerB])
                .verdict(reachable: [Self.peerB]) == .open(outstanding: 1),
                "a window with no evidence of its own matches nobody, whatever another window saw")
    }

    /// **39. The mechanical half of "recorded, never compared".** The value type holds no clock.
    @Test func theWindowTypeHasNoClock() throws {
        let source = try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshMergeWindow.swift")
        let code = MeshRoutedSourceScan.codeOnly(source)
        #expect(!code.contains("Date()"), "the manager supplies `now`; the window never reads a clock")
        #expect(!code.contains("timeIntervalSince"), "and never compares one")
    }
}

// MARK: - MeshMergeWindowStar

/// A three-manager star on `MeshDepartureRig`: A in the middle, B and C on their own links and
/// their own coordinators.
///
/// The rig is not a preference. `MeshMergeWireNode` holds one coordinator, and the manager resolves
/// an inbound frame's slot by coordinator identity, so a two-peer node on that rig attributes every
/// frame to one peer — and an `asked` set of `{B, C}` is exactly what these cells are about.
@MainActor
struct MeshMergeWindowStar {

    /// The fabric every frame crosses.
    let fabric: FakePeerNetwork

    /// The mesh all three are members of.
    let meshID: UUID

    /// The centre of the star.
    let nodeA: MeshDepartureNode

    /// The leaf that is always linked.
    let nodeB: MeshDepartureNode

    /// The leaf whose link and slot kind the scenarios vary.
    let nodeC: MeshDepartureNode

    /// A fourth roster member with no device — the record one branch can hold and another cannot.
    let extraIdentity: IdentityService

    /// What each node's rotation queue held, sampled inside the pump.
    let sample = MeshRotationSample()

    /// Builds the star.
    ///
    /// - Parameters:
    ///   - label: A frozen diagnostic prefix, distinct per scenario.
    ///   - centreHoldsExtra: Whether A and B start with the fourth admission C also holds. `false`
    ///     is the divergent shape: A and B are one record short of C.
    ///   - linkC: Whether A–C is seated at build time. `false` leaves A's opening ask at `{B}`.
    ///   - seatCAsLightweight: Seats C's slot at A with `kind: .lightweight`, so the opening ask —
    ///     which reaches only `activeSlots` — cannot reach it.
    /// - Returns: The built star, links seated.
    static func build(
        _ label: String,
        centreHoldsExtra: Bool = true,
        linkC: Bool = true,
        seatCAsLightweight: Bool = false
    ) throws -> MeshMergeWindowStar {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = ["\(label)-a", "\(label)-b", "\(label)-c"]
        let ids = try labels.map { try MeshPartitionFixtures.identity($0) }
        let extra = try MeshPartitionFixtures.identity("\(label)-x")
        #expect(Set((ids + [extra]).map(\.localFingerprint)).count == 4,
                "the rig needs four distinct provisioned identities, or every claim is vacuous")
        let full = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: [ids[1], ids[2], extra], meshID: meshID
        )
        let short = MeshMergeWindowLedgers.dropping(extra.localFingerprint, from: full)
        #expect(full.admissions.count == 4 && short.admissions.count == 3,
                "the short ledger is the full one minus exactly the fourth admission")
        var nodes: [MeshDepartureNode] = []
        for (index, pair) in zip(labels, ids).enumerated() {
            let node = MeshDepartureRig.node(pair.0, identity: pair.1, on: fabric)
            MeshDepartureRig.start(
                node, ledger: (centreHoldsExtra || index == 2) ? full : short,
                founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            nodes.append(node)
        }
        guard nodes.count == 3 else { throw MeshMergeTestFailure.rosterTooSmall }
        let star = MeshMergeWindowStar(
            fabric: fabric, meshID: meshID,
            nodeA: nodes[0], nodeB: nodes[1], nodeC: nodes[2], extraIdentity: extra
        )
        MeshDepartureRig.link(star.nodeA, star.nodeB, on: fabric)
        star.seatC(linked: linkC, lightweight: seatCAsLightweight)
        return star
    }

    /// Seats the A–C link, or leaves it unseated.
    private func seatC(linked: Bool, lightweight: Bool) {
        guard linked else { return }
        guard lightweight else {
            MeshDepartureRig.link(nodeA, nodeC, on: fabric)
            return
        }
        fabric.connect(nodeA.handle, nodeC.handle)
        let toC = MeshP3Acceptance.coordinator()
        nodeA.coordinators[nodeC.handle.endpoint] = toC
        nodeA.manager.addSlotForTesting(
            coordinator: toC, peer: nodeC.handle, fingerprint: nodeC.fingerprint,
            kind: .lightweight, channel: nodeA.channel
        )
        let toA = MeshP3Acceptance.coordinator()
        nodeC.coordinators[nodeA.handle.endpoint] = toA
        nodeC.manager.addSlotForTesting(
            coordinator: toA, peer: nodeA.handle, fingerprint: nodeA.fingerprint,
            channel: nodeC.channel
        )
    }

    /// Re-seats the centre's slot toward C, with a **fresh** coordinator, after
    /// `evictSlotForTesting` dropped it.
    ///
    /// The transport half of "the link dropped and re-formed" — the only shape a late ask exists
    /// for. A new coordinator is what the production path would hand a re-formed link, and the
    /// manager resolves an inbound frame's slot by coordinator identity, so the node's map is
    /// re-pointed with it.
    func reseatCAtCentre() {
        let toC = MeshP3Acceptance.coordinator()
        nodeA.coordinators[nodeC.handle.endpoint] = toC
        nodeA.manager.addSlotForTesting(
            coordinator: toC, peer: nodeC.handle, fingerprint: nodeC.fingerprint,
            channel: nodeA.channel
        )
    }

    /// Every node in the scenario.
    var nodes: [MeshDepartureNode] { [nodeA, nodeB, nodeC] }

    /// Raises a reconnect at `node` naming `peer` — the blip that opens, or widens, a window.
    func commit(_ node: MeshDepartureNode, toward peer: MeshDepartureNode) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            node.manager.applySessionEvent(.peerCommitted, committedPeer: peer.fingerprint)
        }
    }

    /// Folds one more admission into `node` through the LIVE record path, so its ledger grows
    /// without any exchange having carried it.
    ///
    /// - Parameters:
    ///   - node: The node whose ledger grows.
    ///   - joiner: The member it admits.
    ///   - sender: The node whose identity signs the carrying envelope.
    func growLedger(
        of node: MeshDepartureNode, admitting joiner: IdentityService, from sender: MeshDepartureNode
    ) throws {
        guard let coordinator = node.coordinators[sender.handle.endpoint] else {
            throw MeshMergeTestFailure.rosterTooSmall
        }
        let record = SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: node.manager.identityForTesting
        ))
        try MeshP3Acceptance.deliver(
            encoding: MeshMemberAdmissionPayload(record: record),
            type: .meshMemberAdmission, to: node.manager,
            from: sender.manager.identityForTesting, over: coordinator
        )
    }

    /// Leaves every mesh, so the managers stop holding sessions open.
    func teardown() {
        for node in nodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshMergeWindowLedgers

/// The one ledger surgery both rigs need: the same signed bytes, minus one admission.
///
/// Re-minting a second admission for the same member would produce a *different* record, so two
/// "converged" devices would never hold an identical inventory and no digest could ever match.
enum MeshMergeWindowLedgers {

    /// `full` without the admission naming `fingerprint`.
    ///
    /// - Parameters:
    ///   - fingerprint: The member to drop.
    ///   - full: The ledger to copy.
    /// - Returns: The shortened ledger.
    static func dropping(
        _ fingerprint: String, from full: MeshMembershipLedger
    ) -> MeshMembershipLedger {
        var short = MeshMembershipLedger.empty
        for record in full.admissions.all where record.memberFingerprint != fingerprint {
            short.admissions = short.admissions.inserting(record)
        }
        return short
    }

    /// `full` reduced to the ONE admission naming `fingerprint` — a joiner's bootstrap ledger,
    /// exactly as `armJoinerLedger(_:)` leaves it: one record, its own, signed by its admitter,
    /// rooted at the admitter's key rather than the mesh's founder.
    ///
    /// - Parameters:
    ///   - fingerprint: The joiner.
    ///   - full: The ledger to copy the record out of.
    /// - Returns: The one-record bootstrap ledger.
    static func bootstrap(
        for fingerprint: String, from full: MeshMembershipLedger
    ) -> MeshMembershipLedger {
        var provisional = MeshMembershipLedger.empty
        for record in full.admissions.all where record.memberFingerprint == fingerprint {
            provisional.admissions = provisional.admissions.inserting(record)
        }
        return provisional
    }
}

// MARK: - MeshMergeWindowPair

/// Two managers of one mesh on `MeshMergeWire` — the rig whose one-coordinator node is exactly right
/// for a pair, and whose settle already takes an `until:`.
@MainActor
struct MeshMergeWindowPair {

    /// The fabric every frame crosses.
    let fabric: FakePeerNetwork

    /// The mesh both ends are in.
    let meshID: UUID

    /// The end that starts one record behind, unless the scenario asked otherwise.
    let nodeA: MeshMergeWireNode

    /// The end that holds the full ledger.
    let nodeB: MeshMergeWireNode

    /// A third roster member with no device, whose admission is the record A lacks.
    let extraIdentity: IdentityService

    /// The ledger B started on when it was built as a bootstrap joiner, empty otherwise — the
    /// bytes ``deliverJoinerDigest()`` signs its grant reply over.
    let bootstrapLedger: MeshMembershipLedger

    /// Builds the pair, seated and live.
    ///
    /// - Parameters:
    ///   - label: A frozen diagnostic prefix, distinct per scenario.
    ///   - aIsBehind: `true` gives A the ledger minus one admission B holds.
    ///   - bIsBootstrapJoiner: `true` starts B on the one-record ledger `armJoinerLedger(_:)`
    ///     leaves a freshly admitted device on, rooted at A's key because A admitted it. A then
    ///     holds the whole mesh and B holds only its own admission, which is the state a grant
    ///     reply is sent from.
    /// - Returns: The built pair.
    static func build(
        _ label: String, aIsBehind: Bool = true, bIsBootstrapJoiner: Bool = false
    ) throws -> MeshMergeWindowPair {
        let fabric = FakePeerNetwork()
        let left = fabric.addEndpoint(named: "\(label)-left")
        let right = fabric.addEndpoint(named: "\(label)-right")
        fabric.connect(left.handle, right.handle)
        fabric.clock.advance(by: .milliseconds(50))
        let idA = try MeshPartitionFixtures.identity("\(label)-a")
        let idB = try MeshPartitionFixtures.identity("\(label)-b")
        let extra = try MeshPartitionFixtures.identity("\(label)-x")
        #expect(Set([idA, idB, extra].map(\.localFingerprint)).count == 3,
                "the rig needs three distinct provisioned identities")
        let meshID = UUID()
        let full = try MeshPartitionFixtures.ledger(
            founder: idA, others: [idB, extra], meshID: meshID
        )
        let short = MeshMergeWindowLedgers.dropping(extra.localFingerprint, from: full)
        #expect(full.admissions.count == 3 && short.admissions.count == 2)
        let storeA = makeTestStore()
        let storeB = makeTestStore()
        let managerA = MeshNetworkManager(
            store: storeA, transport: FakeMeshTransportSession(), identity: idA
        )
        let managerB = MeshNetworkManager(
            store: storeB, transport: FakeMeshTransportSession(), identity: idB
        )
        MeshMergeWire.start(
            managerA, ledger: aIsBehind ? short : full,
            founderKey: idA.localSigningPublicKey, meshID: meshID
        )
        let bootstrap = MeshMergeWindowLedgers.bootstrap(
            for: idB.localFingerprint, from: full
        )
        #expect(bootstrap.admissions.count == 1, "a bootstrap ledger is exactly one record long")
        MeshMergeWire.start(
            managerB, ledger: bIsBootstrapJoiner ? bootstrap : full,
            founderKey: idA.localSigningPublicKey, meshID: meshID
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
        return MeshMergeWindowPair(
            fabric: fabric, meshID: meshID,
            nodeA: MeshMergeWireNode(
                store: storeA, manager: managerA, channel: left.transport,
                handle: left.handle, coordinator: coordinatorA
            ),
            nodeB: MeshMergeWireNode(
                store: storeB, manager: managerB, channel: right.transport,
                handle: right.handle, coordinator: coordinatorB
            ),
            extraIdentity: extra,
            bootstrapLedger: bIsBootstrapJoiner ? bootstrap : .empty
        )
    }

    /// Both ends.
    var nodes: [MeshMergeWireNode] { [nodeA, nodeB] }

    /// Delivers the digest a freshly admitted joiner sends in reply to its grant.
    ///
    /// `handleAdmissionGrant` answers a verified grant with one `sendInventoryDigest(to:[admitter])`
    /// over the link it was admitted on; this is that frame, signed by B over its one-record
    /// bootstrap ledger and handed to A through the real receive door.
    func deliverJoinerDigest() throws {
        try MeshP3Acceptance.deliver(
            encoding: try MeshInventoryDigestPayload.signed(
                meshID: meshID, ledger: bootstrapLedger,
                identity: nodeB.manager.identityForTesting
            ),
            type: .meshInventoryDigest, to: nodeA.manager,
            from: nodeB.manager.identityForTesting, over: nodeA.coordinator
        )
    }

    /// Raises a reconnect at `node` naming the other end.
    func commit(_ node: MeshMergeWireNode) {
        let peer = node === nodeA ? nodeB : nodeA
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            node.manager.applySessionEvent(
                .peerCommitted, committedPeer: peer.manager.identityForTesting.localFingerprint
            )
        }
    }

    /// How many frames of `type` have landed at `node`.
    ///
    /// - Parameters:
    ///   - type: The payload token to count.
    ///   - node: The end whose endpoint received them.
    /// - Returns: The count.
    func received(_ type: PayloadType, at node: MeshMergeWireNode) -> Int {
        MeshMergeWire.receivedTypes(node.channel).filter { $0 == type.rawValue }.count
    }

    /// Folds one more admission into `node` through the LIVE record path.
    ///
    /// - Parameters:
    ///   - node: The node whose ledger grows.
    ///   - joiner: The member it admits.
    func growLedger(of node: MeshMergeWireNode, admitting joiner: IdentityService) throws {
        let sender = node === nodeA ? nodeB : nodeA
        let record = SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: node.manager.identityForTesting
        ))
        try MeshP3Acceptance.deliver(
            encoding: MeshMemberAdmissionPayload(record: record),
            type: .meshMemberAdmission, to: node.manager,
            from: sender.manager.identityForTesting, over: node.coordinator
        )
    }

    /// Raises §10.2's split at both ends, which is what abandons a window in flight.
    func partitionBothEnds(at now: Date) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for node in nodes {
                _ = node.manager.evaluatePartition(
                    reachable: [node.manager.identityForTesting.localFingerprint], now: now
                )
            }
        }
    }

    /// Heals both ends against their own rosters, which is what re-opens a window.
    func healBothEnds(at now: Date) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for node in nodes {
                _ = node.manager.evaluatePartition(
                    reachable: Set(MeshMergeFixtures.roster(node.manager)), now: now
                )
            }
        }
    }

    /// Leaves both meshes.
    func teardown() {
        for node in nodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshMergeWindowWireTests

/// The closing rule over real signed frames.
@MainActor
@Suite(.serialized)
struct MeshMergeWindowWireTests {

    // MARK: Three managers — the cells an `asked` set of two needs

    /// **16. 2d at the wire seam.** The first matching digest does not close a window that asked
    /// two peers — which is the whole of the defect P4 deferred by name.
    @Test func aFirstMatchingDigestDoesNotCloseAWindowThatAskedTwo() async throws {
        let star = try MeshMergeWindowStar.build("m7-16")
        star.commit(star.nodeA, toward: star.nodeB)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked
                == [star.nodeB.fingerprint, star.nodeC.fingerprint],
                "the opening ask reached both seated peers")
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched.isEmpty == false }
        )
        #expect(star.nodeA.manager.awaitingResumeMerge,
                "one match of two is not convergence: the window stays open")
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched == [star.nodeB.fingerprint])
        star.teardown()
    }

    /// **17.** And it closes when the LAST asked peer matches, saying why.
    @Test func theWindowClosesWhenTheLastAskedPeerMatches() async throws {
        let star = try MeshMergeWindowStar.build("m7-17")
        star.commit(star.nodeA, toward: star.nodeB)
        star.commit(star.nodeB, toward: star.nodeA)
        star.commit(star.nodeC, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { !star.nodeA.manager.awaitingResumeMerge }
        )
        #expect(!star.nodeA.manager.awaitingResumeMerge)
        #expect(star.nodeA.manager.lastMergeClosureForTesting == .converged)
        #expect(star.nodeA.manager.pendingMergeEntry == nil,
                "and the door it came through is forgotten with it")
        star.teardown()
    }

    /// **18. The 2d consequence, gone.** A record from the second peer, arriving after the first
    /// peer already matched, still takes the merge path and still asks for the merge's rotation.
    @Test func aRecordFromTheSecondPeerAfterTheFirstMatchStillTakesTheMergePath() async throws {
        let star = try MeshMergeWindowStar.build("m7-18", centreHoldsExtra: false)
        #expect(MeshMergeFixtures.roster(star.nodeA.manager).count == 3, "A is one member short")
        #expect(MeshMergeFixtures.roster(star.nodeC.manager).count == 4, "C holds the record")
        MeshDepartureRig.consumeRotations(star.nodes)
        let before = star.nodeA.manager.mergeApplicationCount
        star.commit(star.nodeA, toward: star.nodeB)
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric, sampling: star.sample,
            until: { MeshMergeFixtures.roster(star.nodeA.manager).count == 4 }
        )
        #expect(MeshMergeFixtures.roster(star.nodeA.manager).count == 4,
                "C's re-gossip reached A although B had already matched")
        #expect(star.nodeA.manager.mergeApplicationCount > before,
                "and folded through the ONE merge path")
        #expect(star.sample.causes(at: star.nodeA.label) == [.merge],
                "asking for the merge's rotation, never `.membership`")
        star.teardown()
    }

    /// **23.** A partition mid-window abandons it, and the heal opens a fresh one over the links
    /// that actually exist now.
    @Test func aPartitionMidWindowAbandonsItAndAHealOpensAFreshOne() async throws {
        let star = try MeshMergeWindowStar.build("m7-23")
        star.commit(star.nodeA, toward: star.nodeB)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked.count == 2)
        let names = Set(MeshMergeFixtures.roster(star.nodeA.manager))
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = star.nodeA.manager.evaluatePartition(
                reachable: [star.nodeA.fingerprint], now: MeshP3Acceptance.base
            )
        }
        #expect(star.nodeA.manager.sessionState == .partitioned)
        #expect(star.nodeA.manager.mergeWindowForTesting == nil,
                "the asks in flight were to links that no longer exist")
        star.nodeA.manager.evictSlotForTesting(peerID: star.nodeC.handle.id)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = star.nodeA.manager.evaluatePartition(
                reachable: names, now: MeshP3Acceptance.base.addingTimeInterval(60)
            )
        }
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked == [star.nodeB.fingerprint],
                "the fresh window asks the slot set it has NOW")
        star.teardown()
    }

    /// **24.** A peer that departs mid-window is no longer waited for — no fourth state, no hook.
    @Test func aPeerThatDepartsMidWindowIsNoLongerWaitedFor() async throws {
        let star = try MeshMergeWindowStar.build("m7-24")
        star.commit(star.nodeA, toward: star.nodeB)
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched.isEmpty == false }
        )
        #expect(star.nodeA.manager.awaitingResumeMerge, "still waiting on C")
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await star.nodeC.manager.leaveSessionAfterNotifyingPeers()
        }
        try await MeshDepartureRig.settle(
            [star.nodeA, star.nodeB], on: star.fabric,
            until: { !star.nodeA.manager.awaitingResumeMerge }
        )
        #expect(!star.nodeA.manager.awaitingResumeMerge,
                "a departed member leaves the reach set, so it leaves the pending set")
        #expect(star.nodeA.manager.lastMergeClosureForTesting == .converged)
        star.teardown()
    }

    /// **25.** A peer whose link drops mid-window is no longer waited for either, and a window that
    /// proved nothing says so.
    @Test func aPeerWhoseLinkDropsMidWindowIsNoLongerWaitedFor() async throws {
        let star = try MeshMergeWindowStar.build("m7-25")
        star.commit(star.nodeA, toward: star.nodeB)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked.count == 2)
        star.nodeA.manager.evictSlotForTesting(peerID: star.nodeB.handle.id)
        #expect(star.nodeA.manager.awaitingResumeMerge, "C is still outstanding")
        star.nodeA.manager.evictSlotForTesting(peerID: star.nodeC.handle.id)
        #expect(!star.nodeA.manager.awaitingResumeMerge)
        #expect(star.nodeA.manager.lastMergeClosureForTesting == .nothingOutstanding,
                "nothing matched, so it is an emptied window and not a convergence")
        star.teardown()
    }

    /// **26.** A digest from a peer the window never asked closes nothing.
    @Test func aDigestFromAPeerTheWindowNeverAskedClosesNothing() async throws {
        let star = try MeshMergeWindowStar.build("m7-26", linkC: false)
        star.commit(star.nodeA, toward: star.nodeB)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked == [star.nodeB.fingerprint])
        MeshDepartureRig.link(star.nodeA, star.nodeC, on: star.fabric)
        star.commit(star.nodeC, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched
                .contains(star.nodeC.fingerprint) == true }
        )
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched
            .contains(star.nodeC.fingerprint) == true, "recorded, because it is signed and verified")
        #expect(star.nodeA.manager.awaitingResumeMerge,
                "but it was never asked, so it discharges nothing")
        star.teardown()
    }

    /// **29. A matched peer that proves a greater ledger re-opens the obligation.** `.converged`
    /// must never be claimed while holding verified evidence of a record this device lacks.
    @Test func aMatchedPeerThatProvesAGreaterLedgerReopensTheObligation() async throws {
        let star = try MeshMergeWindowStar.build("m7-29")
        star.commit(star.nodeA, toward: star.nodeB)
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched
                .contains(star.nodeB.fingerprint) == true }
        )
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched
            .contains(star.nodeB.fingerprint) == true, "B proved its half")
        let newcomer = try MeshPartitionFixtures.identity("m7-29-newcomer")
        try star.growLedger(of: star.nodeB, admitting: newcomer, from: star.nodeA)
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched
                .contains(star.nodeB.fingerprint) == false }
        )
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched
            .contains(star.nodeB.fingerprint) == false,
                "a verified, present-tense digest that differs un-matches its sender")
        #expect(star.nodeA.manager.awaitingResumeMerge)
        star.teardown()
    }

    /// **30. The reach set is every committed slot, not the distance rank.** A `.lightweight` slot
    /// cannot be reached by the opening ask, must be reached by the late one, and is waited for. On
    /// an `activeSlots`-derived reach set this window closes at B — the regression this cell catches.
    @Test func aLightweightSlotsPeerIsAskedAndWaitedFor() async throws {
        let star = try MeshMergeWindowStar.build("m7-30", seatCAsLightweight: true)
        star.commit(star.nodeA, toward: star.nodeB)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked == [star.nodeB.fingerprint],
                "the opening ask reaches only the ACTIVE slots")
        star.commit(star.nodeA, toward: star.nodeC)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked
                == [star.nodeB.fingerprint, star.nodeC.fingerprint],
                "the late ask widened the SAME window")
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched.isEmpty == false }
        )
        #expect(star.nodeA.manager.awaitingResumeMerge,
                "a lightweight peer sends and receives like an active one, so it is waited for")
        star.nodeA.manager.evictSlotForTesting(peerID: star.nodeC.handle.id)
        #expect(!star.nodeA.manager.awaitingResumeMerge)
        #expect(star.nodeA.manager.lastMergeClosureForTesting == .converged)
        star.teardown()
    }

    /// **31. A late ask un-matches the peer it re-asks** (D-7.32). The one peer a late ask exists
    /// for is a peer whose link dropped and re-formed — which is precisely the peer that may have
    /// been on the other branch in between, so its match from before it left may not close this
    /// window. Without the un-match the third peer's later digest closes A `.converged` although
    /// the peer A had just deliberately re-asked has proved nothing since.
    @Test func aReAskedPeersEarlierMatchNoLongerClosesTheWindow() async throws {
        let star = try MeshMergeWindowStar.build("m7-31")
        star.commit(star.nodeA, toward: star.nodeB)
        #expect(star.nodeA.manager.mergeWindowForTesting?.asked.count == 2)
        star.commit(star.nodeC, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched
                .contains(star.nodeC.fingerprint) == true }
        )
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched == [star.nodeC.fingerprint],
                "C proved its half while its link was up")
        star.nodeA.manager.evictSlotForTesting(peerID: star.nodeC.handle.id)
        #expect(star.nodeA.manager.awaitingResumeMerge, "B is still outstanding")
        star.reseatCAtCentre()
        star.commit(star.nodeA, toward: star.nodeC)
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched.isEmpty == true,
                "the late ask dropped the match recorded before C's link went")
        star.commit(star.nodeB, toward: star.nodeA)
        try await MeshDepartureRig.settle(
            star.nodes, on: star.fabric,
            until: { star.nodeA.manager.mergeWindowForTesting?.matched
                .contains(star.nodeB.fingerprint) == true }
        )
        #expect(star.nodeA.manager.mergeWindowForTesting?.matched == [star.nodeB.fingerprint])
        #expect(star.nodeA.manager.awaitingResumeMerge,
                "B's match cannot close a window whose other peer was just re-asked")
        star.teardown()
    }

    // MARK: Two managers — the responder clause and the proof

    /// **19.** A responder that only answered keeps its window open: "answered" adds an obligation
    /// on both sides, and this is the 2c deadlock staying shut by construction.
    @Test func aResponderThatOnlyAnsweredKeepsItsWindowOpen() async throws {
        let pair = try MeshMergeWindowPair.build("m7-19")
        pair.commit(pair.nodeA)
        pair.commit(pair.nodeB)
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric,
            until: { pair.nodeA.manager.mergeWindowForTesting?.role == .both }
        )
        #expect(pair.nodeA.manager.mergeWindowForTesting?.role == .both)
        #expect(pair.nodeA.manager.awaitingResumeMerge,
                "it asked and it answered, and neither of those is a match")
        #expect(pair.nodeA.manager.mergeWindowForTesting?.matched.isEmpty == true)
        pair.teardown()
    }

    /// **20.** And it closes on the answered peer's next matching digest.
    @Test func andClosesOnTheAnsweredPeersNextMatchingDigest() async throws {
        let pair = try MeshMergeWindowPair.build("m7-20")
        pair.commit(pair.nodeA)
        pair.commit(pair.nodeB)
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric, until: { !pair.nodeA.manager.awaitingResumeMerge }
        )
        #expect(!pair.nodeA.manager.awaitingResumeMerge)
        #expect(pair.nodeA.manager.lastMergeClosureForTesting == .converged)
        pair.teardown()
    }

    /// **21.** A post-merge proof is sent once per distinct digest to every outstanding peer.
    @Test func aPostMergeProofIsSentOncePerDistinctDigestToEveryOutstandingPeer() async throws {
        let pair = try MeshMergeWindowPair.build("m7-21")
        pair.commit(pair.nodeA)
        // The proof is sent from a `Task` the fold schedules, so the settle must run past the fold
        // itself: `until:` fires synchronously inside the pump that folds, before anything sends.
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric,
            until: { pair.received(.meshInventoryDigest, at: pair.nodeB) >= 2 }
        )
        #expect(MeshMergeFixtures.roster(pair.nodeA.manager).count == 3, "A folded B's re-gossip")
        #expect(pair.received(.meshInventoryDigest, at: pair.nodeB) == 2,
                "the opening ask, then ONE post-merge proof of the state the fold produced")
        let offer = MeshMergeOffer(ledger: pair.nodeB.manager.membershipVerifier?.ledger ?? .empty)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            pair.nodeA.manager.mergeReconnected(offer, entry: .blip)
        }
        try await MeshMergeWire.settle(pair.nodes, on: pair.fabric)
        #expect(pair.received(.meshInventoryDigest, at: pair.nodeB) == 2,
                "re-folding the same records moves no digest, so it costs no third frame")
        pair.teardown()
    }

    /// **22.** A digest that mismatched on arrival is rescued by re-evaluation after the fold — the
    /// one-directional case closes with no second frame from the peer.
    @Test func aStaleDigestIsRescuedByReEvaluationWithNoNewFrame() async throws {
        let pair = try MeshMergeWindowPair.build("m7-22")
        pair.commit(pair.nodeA)
        pair.commit(pair.nodeB)
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric, until: { !pair.nodeA.manager.awaitingResumeMerge }
        )
        #expect(!pair.nodeA.manager.awaitingResumeMerge)
        #expect(pair.nodeA.manager.lastMergeClosureForTesting == .converged)
        #expect(pair.received(.meshInventoryDigest, at: pair.nodeA) == 1,
                "B sent exactly one digest: the match was re-earned from evidence, not from a frame")
        pair.teardown()
    }

    /// **27. §6.9's precondition, asserted as the behaviour it is.** The membership re-gossip budget
    /// is once per peer per session and is deliberately **not** refunded by a flap, so a second heal
    /// of the same pair inside one session crosses no records and both windows stay open. Pinned
    /// here so a future reader fixes the *budget* rather than loosening the closing rule.
    @Test func theSecondHealOfAReSplitPairExchangesNoRecordsAndBothWindowsStayOpen() async throws {
        let pair = try MeshMergeWindowPair.build("m7-27")
        pair.commit(pair.nodeA)
        pair.commit(pair.nodeB)
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric, until: { !pair.nodeA.manager.awaitingResumeMerge }
        )
        #expect(!pair.nodeA.manager.awaitingResumeMerge, "the first heal converged")
        try pair.growLedger(of: pair.nodeA, admitting: try MeshPartitionFixtures.identity("m7-27-p"))
        try pair.growLedger(of: pair.nodeB, admitting: try MeshPartitionFixtures.identity("m7-27-q"))
        pair.partitionBothEnds(at: MeshP3Acceptance.base)
        let recordsBefore = pair.nodes.map { pair.received(.meshMemberAdmission, at: $0) }
        pair.healBothEnds(at: MeshP3Acceptance.base.addingTimeInterval(60))
        try await MeshMergeWire.settle(pair.nodes, on: pair.fabric)
        #expect(pair.nodes.map { pair.received(.meshMemberAdmission, at: $0) } == recordsBefore,
                "the once-per-peer-per-session budget is spent: no record can cross")
        #expect(pair.nodeA.manager.awaitingResumeMerge && pair.nodeB.manager.awaitingResumeMerge,
                "so neither digest can move, and neither window can close")
        pair.partitionBothEnds(at: MeshP3Acceptance.base.addingTimeInterval(120))
        #expect(pair.nodeA.manager.mergeWindowForTesting == nil)
        #expect(pair.nodeB.manager.mergeWindowForTesting == nil,
                "and both are bounded by the abandon, exactly as the residual says")
        pair.teardown()
    }

    /// **28. The proof is owed to the set that existed BEFORE the close.** A device strictly behind
    /// its peer converges on the fold *and still* proves its new state — the ordering the un-revised
    /// design got wrong, which left the ahead device holding an open window for the session.
    @Test func aBehindDeviceProvesItsNewStateEvenAsItConverges() async throws {
        let pair = try MeshMergeWindowPair.build("m7-28")
        pair.commit(pair.nodeA)
        pair.commit(pair.nodeB)
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric, until: { !pair.nodeA.manager.awaitingResumeMerge }
        )
        #expect(!pair.nodeA.manager.awaitingResumeMerge, "the behind device converged")
        #expect(pair.nodeA.manager.lastMergeClosureForTesting == .converged)
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric, until: { !pair.nodeB.manager.awaitingResumeMerge }
        )
        #expect(pair.received(.meshInventoryDigest, at: pair.nodeB) == 2,
                "and it still told its peer, which is the only way that peer can ever close")
        #expect(!pair.nodeB.manager.awaitingResumeMerge)
        #expect(pair.nodeB.manager.lastMergeClosureForTesting == .converged)
        pair.teardown()
    }

    /// **32. A joiner's grant reply must not strand the admitter's window** (D-7.33). A device that
    /// admits somebody mid-heal gets a digest of a one-record BOOTSTRAP ledger back, mismatches it
    /// and answers it — so the joiner enters `answered`, i.e. `pending`. The joiner then rebases
    /// through `MeshLedgerAdoption`, which is not `mergeMembershipLedger(_:)`, so the post-merge
    /// proof door never fires there: without the adoption digest the joiner has no second occasion
    /// to speak and the admitter's window survives to the next partition or session reset.
    @Test func aJoinersGrantReplyDoesNotStrandTheAdmittersWindow() async throws {
        let pair = try MeshMergeWindowPair.build(
            "m7-32", aIsBehind: false, bIsBootstrapJoiner: true
        )
        #expect(MeshMergeFixtures.roster(pair.nodeA.manager).count == 3, "A holds the whole mesh")
        #expect(MeshMergeFixtures.roster(pair.nodeB.manager).count < 3,
                "B is on its provisional root, one record long")
        pair.commit(pair.nodeA)
        #expect(pair.nodeA.manager.mergeWindowForTesting?.asked.count == 1)
        try pair.deliverJoinerDigest()
        #expect(pair.nodeA.manager.mergeWindowForTesting?.answered.count == 1,
                "the admitter answered the joiner's mismatch, so the joiner is in `pending`")
        try await MeshMergeWire.settle(
            pair.nodes, on: pair.fabric, until: { !pair.nodeA.manager.awaitingResumeMerge }
        )
        #expect(MeshMergeFixtures.roster(pair.nodeB.manager).count == 3,
                "the admitter's re-gossip let the joiner rebase off its bootstrap ledger")
        #expect(!pair.nodeA.manager.awaitingResumeMerge,
                "and the joiner said so, which is the only thing that can discharge the obligation")
        #expect(pair.nodeA.manager.lastMergeClosureForTesting == .converged)
        pair.teardown()
    }
}
