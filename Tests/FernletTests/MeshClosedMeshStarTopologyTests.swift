import Foundation
import Testing
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshClosedMeshStarTopologyTests

// The tier-1 reproduction of plan §8.7 finding 1 — "three Simulators form a spanning star, never a
// full mesh" (runbook "Lane C — THREE nodes").
//
// The defect is not in the transport and not in the tie-break: it is that `isSessionOpen` carries
// the mesh-wide "this mesh admits new MEMBERS" rule and was being used as the gate on opening a
// LINK at all, on both the outbound side (`handlePeerDiscovered`) and the inbound one
// (`shouldAcceptInvitation`, which is the QUIC radio's `invitationGate`). `handleMeshDescriptor`
// re-derives `isSessionOpen` from the *gossiped* descriptor's mode, so on a `.closed` mesh the
// first committed peer's descriptor latched it false on every node — and from that instant a node
// neither dialed nor accepted anybody, its own co-members included. Whichever node happened to have
// both of its edges in flight before that merge kept two tunnels and became the hub, which is why
// the hub was a different Simulator every run and why a pair (whose only edge is up before any
// descriptor crosses it) always converged.
//
// Everything below is three managers over three `FakeMeshTransportSession`s, driven by hand: no
// radios, no clock, no randomness beyond each manager's own per-launch `sid`, which is read back
// rather than assumed.
/// Three members of a **closed** mesh must still propose every pair — the star reproduction.
@Suite(.serialized) @MainActor
struct MeshClosedMeshStarTopologyTests {

    /// A suite-lived store for the managers built without a ``Node``. `MeshNetworkManager` keeps its
    /// host `unowned`, so a store that only lives as long as the `let` that made it traps.
    let store = makeTestStore()

    // MARK: - Fixtures

    /// One node: its store, its manager, the radio underneath it, and the advertisement its peers
    /// browse.
    ///
    /// The store is held **here** and not created inline: `MeshNetworkManager` keeps its host
    /// `unowned`, so a manager built over a temporary store traps the moment anything reaches
    /// through it.
    struct Node {
        let store: FernletStore
        let transport: FakeMeshTransportSession
        let manager: MeshNetworkManager
        /// The handle the OTHER two nodes see for this one, carrying this manager's real `sid`.
        let advertisement: PeerHandle
    }

    /// The mesh every node in these tests is already a member of. Mode `.closed` is the whole
    /// point: it is the Lane C harness's seeded shape, and it is also what a user gets by tapping
    /// "close this mesh" on a real one.
    static let meshID = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()

    /// Builds one node already in the state a Lane C Simulator reaches a few seconds in: a member
    /// of a closed mesh, searching, with `isSessionOpen` false because a peer's descriptor said so.
    ///
    /// `setSessionOpen(false)` is the honest public spelling of that merge — it is what
    /// `handleMeshDescriptor` leaves behind for a `.closed` descriptor, and it additionally closes
    /// the mesh mode, which the merge had already done on the way in.
    static func makeNode() -> Node {
        let transport = FakeMeshTransportSession()
        let store = makeTestStore()
        let manager = MeshNetworkManager(store: store, transport: transport)
        manager.markProximityJoinForTesting()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        manager.currentMesh = MeshDescriptor(
            meshID: meshID,
            name: "matrix",
            mode: .closed,
            // A real closed mesh names its members, and the roster is what the seat gate asks. An
            // EMPTY member list is fail-closed — it refuses everybody, this device included — which
            // is the right posture but not the state under test here.
            members: [MeshMember(
                fingerprint: manager.localFingerprint,
                displayName: "self",
                signingPublicKey: manager.localSigningPublicKey,
                keyAgreementPublicKey: manager.localKeyAgreementPublicKey,
                joinedAt: now
            )],
            nameSetAt: now,
            nameSetBy: manager.localFingerprint,
            modeSetAt: now,
            modeSetBy: manager.localFingerprint,
            createdAt: now
        )
        manager.setSessionOpen(false)
        return Node(
            store: store,
            transport: transport,
            manager: manager,
            advertisement: PeerHandle(
                id: UUID(),
                displayHint: "fernlet-mesh-\(manager.localFingerprint.prefix(12))",
                discoveryInfo: manager.currentDiscoveryInfo(),
                advertisedFingerprint: nil
            )
        )
    }

    // MARK: - The star

    /// **The regression.** Three members of a closed mesh, each shown the other two, must between
    /// them propose all three edges — one proposal per pair, from whichever side the `sid`
    /// tie-break makes the dialer, and accepted by the other.
    ///
    /// Before the fix this asserted zero edges: every node had `isSessionOpen == false`, so the
    /// outbound gate returned before the tie-break and the inbound gate answered false. N−1 edges
    /// survived on the radio only because the first edge of each node predates the descriptor that
    /// closes it — an ordering this test does not need to model to pin the rule.
    @Test func threeMembersOfAClosedMeshProposeEveryPair() {
        let nodes = [Self.makeNode(), Self.makeNode(), Self.makeNode()]

        var edges = 0
        for first in 0..<nodes.count {
            for second in (first + 1)..<nodes.count {
                let forward = Self.proposal(from: nodes[first], to: nodes[second])
                let backward = Self.proposal(from: nodes[second], to: nodes[first])
                #expect(forward != backward,
                        "exactly one side of a pair dials: \(first)→\(second) and \(second)→\(first) agreed")
                let dialer = forward ? nodes[first] : nodes[second]
                let listener = forward ? nodes[second] : nodes[first]
                #expect(listener.transport.offerInboundConnection(from: dialer.advertisement),
                        "the listening member of a closed mesh refused its own co-member's link")
                edges += 1
            }
        }
        #expect(edges == 3, "three members make three edges — a full mesh, not a spanning star")
    }

    /// The outbound half on its own, so a regression names the gate rather than the topology: a
    /// closed mesh must still hand its radio an invite for a co-member it outranks.
    @Test func aClosedMeshStillInvitesAMemberItOutranks() {
        let node = Self.makeNode()
        #expect(!node.manager.isSessionOpen, "test premise: the merged descriptor closed the session")
        let lower = Self.peer(sessionID: "00000000-0000-0000-0000-000000000000")
        #expect(node.manager.shouldInitiateInvite(to: lower), "test premise: we outrank this peer")

        node.transport.discover(lower)

        #expect(node.transport.invitedPeers.map(\.id) == [lower.id],
                "a closed mesh must still dial its own members — otherwise it can never heal a link")
    }

    /// The inbound half: the same closure the QUIC radio calls as its `invitationGate`. A false
    /// answer here is `NetworkMeshSession.admitVerifiedInbound` returning nil, which the dialer
    /// sees only as its control stream dying — the silent drop the three-node runs recorded.
    @Test func aClosedMeshStillAcceptsAnInboundLink() {
        let node = Self.makeNode()
        #expect(!node.manager.isSessionOpen, "test premise: the merged descriptor closed the session")

        #expect(node.transport.offerInboundConnection(from: Self.peer(sessionID: "ffffffff-ffff-ffff-ffff-ffffffffffff")),
                "a closed mesh must still accept a link; membership is refused at the introduction")
    }

    /// The seat decision, which is the gate that survived the other two being fixed and turned the
    /// star into a flap: a member of a closed mesh dialed its co-member, finished the signed
    /// introduction, and was then evicted here — which the dialer read as its control stream dying
    /// mid-frame, re-dialed, and was evicted again, forever.
    @Test func aClosedMeshSeatsAChannelInsteadOfEvictingIt() {
        let node = Self.makeNode()
        #expect(!node.manager.isSessionOpen, "test premise: the merged descriptor closed the session")

        #expect(node.manager.channelAdmission(for: Self.peer(sessionID: "00000000-0000-0000-0000-000000000000")) == .seat,
                "a closed mesh must seat a connected co-member; a kick here is a re-dial loop")
    }

    /// The rule this change did **not** relax: with no mesh at all, a closed session still refuses.
    /// `isSessionOpen` is the only gate there is before a descriptor exists, and "I am not forming a
    /// session with anybody" has to keep meaning that.
    @Test func aClosedSessionWithNoMeshStillRefusesEveryLink() {
        let transport = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: transport)
        manager.markProximityJoinForTesting()
        manager.setSessionOpen(false)
        #expect(manager.currentMesh == nil, "test premise: no descriptor exists yet")
        let lower = Self.peer(sessionID: "00000000-0000-0000-0000-000000000000")

        transport.discover(lower)

        #expect(transport.invitedPeers.isEmpty, "a closed pre-mesh session dials nobody")
        #expect(!transport.offerInboundConnection(from: lower), "a closed pre-mesh session accepts nobody")
        #expect(manager.channelAdmission(for: lower) == .kick, "a closed pre-mesh session seats nobody")
    }

    // MARK: - The MC half: a closed mesh must still refuse a verified STRANGER

    /// **The 0b review's finding 1.** Relaxing the three link gates is safe on the QUIC radio
    /// because its signed channel introduction is members-only before any app frame. **MC has no
    /// such stage** — and MC is the shipping default. So the membership decision has to be taken
    /// where MC *does* know the identity: the moment the slot's coordinator verifies it, before
    /// `onSlotConnected` sends the mesh descriptor, the photo manifest or the vouch list.
    ///
    /// This pins the decision itself; the ordering is structural — `checkCoordinatorStates`
    /// `continue`s past `onSlotConnected` for a refused slot and leaves its `fingerprint` nil, so
    /// nothing downstream reads it as committed, and the commit gate below is the second lock.
    @Test func aClosedMeshRefusesToSeatAVerifiedStranger() {
        let node = Self.makeNode()
        #expect(!node.manager.isSessionOpen, "test premise: the merged descriptor closed the session")

        #expect(!node.manager.maySeatVerifiedPeer(signingPublicKey: Data(repeating: 0x5A, count: 32)),
                "a closed mesh must not seat a peer its own roster does not name")
        #expect(node.manager.maySeatVerifiedPeer(signingPublicKey: node.manager.localSigningPublicKey),
                "a roster member still seats — this gate must not close the mesh to itself")
    }

    /// The rule is about **closed** meshes only: admitting strangers is what an open mesh is for,
    /// and a device with no mesh has no roster to judge anybody against.
    @Test func anOpenMeshAndANoMeshDeviceSeatAnybodyAsBefore() {
        let openNode = Self.makeNode()
        openNode.manager.setSessionOpen(true)
        #expect(openNode.manager.maySeatVerifiedPeer(signingPublicKey: Data(repeating: 0x5A, count: 32)),
                "an open mesh admits strangers — that is the join flow")

        let bare = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        bare.markProximityJoinForTesting()
        bare.setSessionOpen(false)
        #expect(bare.maySeatVerifiedPeer(signingPublicKey: Data(repeating: 0x5A, count: 32)),
                "with no mesh there is no roster to judge against; the link gates already refused")
    }

    /// Admit-by-prompt still works on a closed mesh: ``MeshNetworkManager/allowAdmission(_:)``
    /// appends the member to `currentMesh` **before** it grants, so the requester is a member by
    /// the time it re-connects. What it no longer gets is a seat it can hold — and a descriptor —
    /// while the prompt sits unanswered.
    @Test func admittingByPromptMakesTheRequesterSeatable() {
        let node = Self.makeNode()
        let stranger = Data(repeating: 0x77, count: 32)
        #expect(!node.manager.maySeatVerifiedPeer(signingPublicKey: stranger), "test premise: a stranger")

        node.manager.allowAdmission(MeshAdmissionRequestPayload(
            meshID: Self.meshID,
            requesterFingerprint: IdentityService.fingerprint(of: stranger),
            requesterDisplayName: "Ada",
            requesterSigningPublicKey: stranger,
            requesterKeyAgreementPublicKey: Data(repeating: 0x11, count: 32)
        ))

        #expect(node.manager.maySeatVerifiedPeer(signingPublicKey: stranger),
                "an admitted member seats, on a closed mesh, as soon as the prompt is answered")
    }

    /// The second lock: the mesh descriptor is a **plaintext** envelope naming the mesh, every
    /// member's fingerprint, display name and both public keys. `broadcastMeshDescriptor` used to
    /// walk every slot — on MC, any device that had merely connected.
    @Test func anUncommittedSlotIsNeverSentTheMeshDescriptor() async {
        let node = Self.makeNode()
        let uncommitted = node.transport.makeChannel(named: "uncommitted")
        let committed = node.transport.makeChannel(named: "committed")
        node.manager.addSlotForTesting(
            coordinator: Self.throwawayCoordinator(), peer: uncommitted.handle,
            fingerprint: nil, channel: uncommitted.channel
        )
        node.manager.addSlotForTesting(
            coordinator: Self.throwawayCoordinator(), peer: committed.handle,
            fingerprint: "d996bc564a17da2d", channel: committed.channel
        )

        node.manager.setMeshMode(.closed)
        var yields = 0
        while committed.channel.sentFrames.isEmpty, yields < 400 {
            await Task.yield()
            yields += 1
        }

        #expect(!committed.channel.sentFrames.isEmpty, "test premise: a committed slot does get the descriptor")
        #expect(uncommitted.channel.sentFrames.isEmpty,
                "a pre-commit slot must never be sent the roster in plaintext")
    }

    /// A never-begun coordinator, so a slot can be seeded without a live radio or ranging session.
    static func throwawayCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.mesh.closedstar.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    // MARK: - Helpers

    /// Whether `node` hands its radio an invite when it is shown `other`'s advertisement.
    static func proposal(from node: Node, to other: Node) -> Bool {
        let before = node.transport.invitedPeers.count
        node.transport.discover(other.advertisement)
        return node.transport.invitedPeers.count > before
    }

    /// A peer handle carrying exactly the advertisement under test.
    static func peer(sessionID: String) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: "iPhone",
            discoveryInfo: ["v": "1", "sid": sessionID],
            advertisedFingerprint: nil,
            endpoint: PeerEndpointKey()
        )
    }
}
