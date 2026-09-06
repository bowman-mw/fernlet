// MeshRoutedDrainTests.swift
// FernletTests
//
// Network migration P5 item 6 (plan §11, §10.3, §22.1): the drain, wired onto the ONE merge path.
//
// Tier 1 only — `FakePeerNetwork` + `FakeMeshTransportSession` + an injected clock, no radio and no
// wall-clock sleeps. The rig is a thin facade over `MeshDepartureRig`, not a second rig: nodes,
// links, pumps, settles and rotation samples are item 4's, and only the routed half is new.
//
// Three fixture facts, each of which has cost an iteration somewhere in P5:
//
// - **One pinned install binding.** `MeshP3Acceptance.install` (0x83), never
//   `MeshRoutedStoreFixtures.installA` (0xA7): the routed writes happen inside the manager's receive
//   path, which every rig pump wraps in the former. Mixing them yields a seal refusal, not an empty
//   store.
// - **One time anchor.** `MeshRoutedFixtureClock.createdAt` — exactly `MeshP3Acceptance.base`
//   (1.8e9) until 2026-12-16, a month before that instant falls due, and the wall clock plus that
//   month from the crossover on (item 6a) — with `hardDeadline` derived
//   from `MeshSessionCeiling.ceilingSeconds`, never `MeshRoutedManifestFixtures.hardDeadline`
//   (1.7e9). The same anchor is handed to `MeshDepartureRig.start` so the MESH rolls with it: the
//   manifest verifier demands `expiresAt == floor(hardDeadline) + grace` exactly, and the deadline
//   is the mesh's own `createdAt + ceiling`, so moving one route without the other looks like a
//   signing bug.
// - **The rig's nodes are JOINER-shaped**: `MeshMergeWire.start` applies `.founded`/`.peerCommitted`
//   and never calls `startNewMesh`, so no node has a `sessionCeiling`. That is deliberate — a drain
//   that guarded its ingest on `sessionCeiling?.hardDeadline` would drop every routed frame here,
//   which is exactly what happens to a real joiner for its whole first session.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshRoutedDrainRig

/// An N-manager mesh on `FakePeerNetwork` in which every node ALSO has its own sealed routed store.
///
/// The routed scope is derived from each node's own `FernletStore` (`meshRoutedStorage` →
/// `proximitySupportRoot` + `heartDropKeychainService`, both unique per `makeTestStore()`), so N
/// nodes are N isolated stores with no new injectable seam and no way to reach the production scope
/// (whose spelling this file deliberately never contains — `MeshRoutedStoreIsolationTests` greps
/// every test source for it).
@MainActor
struct MeshRoutedDrainRig {

    /// The mesh's signed creation instant. Every routed instant derives from it — and so does the
    /// mesh itself, which `build` hands the same value (item 6a: the verifier pins the manifest's
    /// expiry to the mesh's own deadline, so the two can never be anchored separately).
    static let createdAt = MeshRoutedFixtureClock.createdAt

    /// The ceiling the manager itself derives — never a literal.
    static var hardDeadline: Date { createdAt.addingTimeInterval(MeshSessionCeiling.ceilingSeconds) }

    /// The injected "now" every routed verb takes: inside the session, far from both edges.
    static var now: Date { createdAt.addingTimeInterval(600) }

    let fabric: FakePeerNetwork
    let meshID: UUID
    /// Every node, in admission order. `nodes[0]` is the founder.
    let nodes: [MeshDepartureNode]
    /// Each node's provisioned identity, in the same order.
    let identities: [IdentityService]
    /// The ledger every node was seeded with — the value side of the SAME mesh.
    let ledger: MeshMembershipLedger
    let sample = MeshRotationSample()

    /// The derived roster, re-derived exactly as shipping code does.
    var roster: MeshDerivedRoster { ledger.derivedRoster }

    /// One node's routed store, on that node's OWN scope, constructed per use.
    func routedStore(_ node: MeshDepartureNode) -> MeshRoutedStore {
        MeshRoutedStore(scope: node.store.meshRoutedStorage)
    }

    /// One node's raw routed load under a chosen install binding — the seam a cell that means to
    /// drive a NON-loaded state asserts against, so "sends nothing" and "which state" are two
    /// separate claims rather than one.
    func routedLoad(_ node: MeshDepartureNode, install: Data) -> MeshRoutedLoad {
        DeviceBindingID.$testOverride.withValue(.identifier(install)) { routedStore(node).load() }
    }

    /// One node's loaded routed index under the rig's one pinned install binding, or nil for every
    /// non-`.loaded` state.
    func routedIndex(_ node: MeshDepartureNode) -> MeshRoutedIndex? {
        let load = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            routedStore(node).load()
        }
        guard case .loaded(let index, _) = load else { return nil }
        return index
    }

    /// Builds `count` provisioned members, seeds one honestly-signed ledger into every manager, and
    /// asserts the preconditions that would otherwise make every later claim vacuous.
    static func build(_ count: Int, label: String) throws -> MeshRoutedDrainRig {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = (0..<count).map { "\(label)-\($0)" }
        let identities = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(identities.map(\.localFingerprint)).count == count,
                "the rig needs distinct provisioned identities")
        guard let founder = identities.first else { throw MeshMergeTestFailure.rosterTooSmall }
        let ledger = try MeshPartitionFixtures.ledger(
            founder: founder, others: Array(identities.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        // R2: bounded by the caller's roster size, itself capped at the fixture roster cap.
        for (label, identity) in zip(labels, identities) {
            let node = MeshDepartureRig.node(label, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: founder.localSigningPublicKey, meshID: meshID,
                createdAt: createdAt
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == count,
                    "the roster size is this rig's hard precondition")
            nodes.append(node)
        }
        return MeshRoutedDrainRig(
            fabric: fabric, meshID: meshID, nodes: nodes, identities: identities, ledger: ledger
        )
    }

    /// Links a pair — ONE `ProximityCoordinator` per link per direction.
    func link(_ near: Int, _ far: Int) { MeshDepartureRig.link(nodes[near], nodes[far], on: fabric) }

    /// One reconnect: both ends commit each other, which is the door the merge exchange opens from.
    func commit(_ near: Int, _ far: Int) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[near].manager.applySessionEvent(.peerCommitted, committedPeer: nodes[far].fingerprint)
            nodes[far].manager.applySessionEvent(.peerCommitted, committedPeer: nodes[near].fingerprint)
        }
    }

    /// Every named node's settle, with the rotation sample taken inside each pump.
    func settle(_ live: [Int]? = nil, until isDone: () -> Bool = { false }) async throws {
        let participants = (live ?? Array(nodes.indices)).map { nodes[$0] }
        try await MeshDepartureRig.settle(participants, on: fabric, sampling: sample, until: isDone)
    }

    /// The payload-type tokens one node received from another, in arrival order.
    func tokens(at receiver: Int, from sender: Int) -> [String] {
        MeshDepartureRig.tokensReceived(by: nodes[receiver], from: nodes[sender].handle)
    }

    /// Ends every session, so nothing outlives the scenario.
    ///
    /// The pending rotation is consumed **before** the session ends, and that order is load-bearing.
    /// A roster move arms a debounce that fires a couple of seconds later; a cell that finishes
    /// sooner leaves it armed, and once `runDebouncedRotation` has started it is past every
    /// cancellation point `leaveMesh` reaches — it goes on to `broadcastCoordinatorBeacon`, which
    /// spawns one un-cancellable send `Task` per slot. Those tasks re-strengthen the manager, which
    /// reads its host store **`unowned`**: one landing after this rig's store has gone traps the whole
    /// test PROCESS, taking every other suite's results with it. `consumePendingRotationForTesting`
    /// is the documented determinism seam for exactly this — it cancels the debounce and resets the
    /// triggers, and nothing after it asserts on either.
    ///
    /// P5 item 1a closed the process-abort hazard described above at the root: every detached spawn
    /// in the manager now PINS its host for the operation's own lifetime (`spawnHostPinned(_:)`,
    /// invariant HP1), so a late-landing send can no longer read a destroyed store. This order is
    /// still the right one — it keeps a stray rotation out of the next cell's observations — but it
    /// is now a determinism discipline rather than the only thing between a rig and a dead test host.
    func teardown() {
        // R2: bounded by the rig's own node count.
        for node in nodes { _ = node.manager.consumePendingRotationForTesting() }
        for node in nodes { node.manager.leaveMesh() }
    }

    /// Ends every session and then lets whatever the teardown could **not** cancel actually run,
    /// while this rig's stores are still alive.
    ///
    /// `teardown()` cancels the armed debounce and empties the slots, but a rotation that had already
    /// started is past every cancellation point it reaches: it goes on to
    /// `broadcastCoordinatorBeacon`, which spawns one send `Task` per slot. Those tasks are not
    /// cancellable, they re-strengthen the manager while they run, and the manager reads its host
    /// store **`unowned`** — one landing after this cell's store has gone traps the whole test
    /// PROCESS and takes every other suite's results with it. Yielding here drains them inside the
    /// cell's own lifetime, which is the only place they can safely land.
    ///
    /// Since P5 item 1a a late send pins its host, so landing outside the cell's lifetime is no
    /// longer fatal (invariant HP1); draining here is still worth doing, because it keeps one cell's
    /// leftover frames out of the next cell's channel recordings.
    ///
    /// Call it at the end of any cell that moved a roster; the `defer { teardown() }` stays as the
    /// failure path, and both are idempotent.
    func quiesce() async {
        teardown()
        // R2: a hard constant ceiling. Each yield lets the main actor run one more queued send.
        for _ in 0..<16 { await Task.yield() }
    }

    /// How many chunk slots one node holds for `key`.
    func heldChunkCount(_ node: Int, _ key: MeshRoutedItemKey) -> Int {
        routedIndex(nodes[node])?.record(for: key)?.chunks.count ?? 0
    }

    /// Delivers one already-minted routed frame from one node to another, through the real envelope
    /// verification and the drain's own dispatch door — on an **injected** clock.
    ///
    /// The clock is the point: every admission, every `isLive(at:)` check and every `deliveredAt`
    /// stamp downstream reads this one instant, and a fixture whose manifests expire on a fixed
    /// calendar date would otherwise turn every hand-driven cell into a claim about the day the
    /// suite ran. The settle-driven cells still take the manager's own `Date()` default.
    ///
    /// Hoisted onto the rig by P5 item 8, which needs it from its own file; `now` is resolved in the
    /// body because a `@MainActor` static cannot be a default-argument value.
    func deliver(
        _ payload: some Encodable,
        type: PayloadType,
        sender: Int,
        receiver: Int,
        now: Date? = nil,
        binding: DeviceBindingID.TestOverride? = nil
    ) async throws {
        try dispatch(payload, type: type, sender: sender, receiver: receiver, now: now, binding: binding)
        // The settle runs under the SAME binding as the dispatch: a cell driving a locked window
        // would otherwise find every store `.loaded` for the pumps that follow its one locked frame.
        try await MeshDepartureRig.settle(nodes, on: fabric, binding: binding)
    }

    /// The same delivery **without** the settle, for a cell that hands over dozens of frames.
    ///
    /// The split is not cosmetic. `deliver` settles after every frame, which is right for a cell
    /// driving one or two; a cell driving thirty-odd would hold the main actor for seconds, and every
    /// other suite sharing this test process runs on it — including their managers' beacon and send
    /// `Task`s, which read the manager's **`unowned` store**. One of those landing after its own rig
    /// has been torn down traps the whole process, not just the cell that starved it. Settle once at
    /// the end instead.
    ///
    /// Hoisted by P5 item 8's review round, which produced exactly that crash.
    ///
    /// `binding` defaults to the rig's one pinned install, which is what every loaded-store cell
    /// wants. P5 item 10 made it a **parameter** because an inner `withValue` shadows an outer one:
    /// a cell that wrapped this call in `.withValue(.readError)` to drive a locked window would
    /// otherwise find the store perfectly `.loaded` for exactly the doors it meant to lock.
    /// `committedSlot: false` seats the frame on the linked-but-**uncommitted** shape — a peer that
    /// has been introduced and has not committed carries no fingerprint on its slot, which is the
    /// pre-commit case `dispatchRoutedPayload` drops by name. The slot is otherwise the real one, so
    /// a cell can hand the same frame both ways and assert the difference.
    func dispatch(
        _ payload: some Encodable,
        type: PayloadType,
        sender: Int,
        receiver: Int,
        now: Date? = nil,
        binding: DeviceBindingID.TestOverride? = nil,
        committedSlot: Bool = true
    ) throws {
        let binding = binding ?? .identifier(MeshP3Acceptance.install)
        let now = now ?? MeshRoutedDrainRig.now
        let frame = try FernletIdentityEnvelope.signed(
            identityService: identities[sender], senderDisplayName: "drain",
            recipientFingerprint: nodes[receiver].fingerprint,
            payloadType: type, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "routed"),
            payload: try JSONEncoder().encode(payload),
            createdAt: now
        )
        let node = nodes[receiver]
        let coordinator = try #require(node.coordinators[nodes[sender].handle.endpoint])
        let plaintext = try frame.verify(
            identityService: node.manager.identityForTesting, replayCache: node.replayCache
        )
        var slot = node.manager.slots.first { $0.coordinator === coordinator }
        if !committedSlot { slot?.fingerprint = nil }
        DeviceBindingID.$testOverride.withValue(binding) {
            node.manager.dispatchRoutedPayload(
                type, plaintext: plaintext, decoder: JSONDecoder(), slot: slot, now: now
            )
        }
    }
}

// MARK: - MeshRoutedDrainItem

/// One routed item minted from a drain rig's own identities, roster and ledger — the same mesh the
/// managers hold, which is what keeps the receiver's verifier out of the way of the drain.
@MainActor
struct MeshRoutedDrainItem {
    let manifest: MeshRoutedManifest
    let chunks: [MeshChunk]
    var key: MeshRoutedItemKey { MeshRoutedItemKey(manifest) }

    /// Mints an item at `origin` for the full roster minus itself.
    static func mint(
        _ rig: MeshRoutedDrainRig,
        origin: Int,
        typeToken: String = MeshRoutedTypeToken.photo,
        byteCount: Int = 2_000
    ) throws -> MeshRoutedDrainItem {
        let signer = rig.identities[origin]
        let payload = MeshRoutedCustodyFixtures.blob(byteCount: byteCount)
        let target = MeshDeliveryTarget(
            contentID: UUID(), roster: rig.roster, selfFingerprint: signer.localFingerprint
        )
        let manifest = try MeshRoutedManifest.signed(
            meshID: rig.meshID,
            target: target,
            typeToken: typeToken,
            contentHash: MeshRoutedContentDigest.contentHash(of: payload),
            size: UInt64(payload.count),
            createdAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60),
            hardDeadline: MeshRoutedDrainRig.hardDeadline,
            contentKey: Data(repeating: 0x33, count: 32),
            recipientKeys: Dictionary(uniqueKeysWithValues:
                rig.identities.map { ($0.localFingerprint, $0.localKeyAgreementPublicKey) }),
            identity: signer
        )
        return MeshRoutedDrainItem(
            manifest: manifest,
            chunks: try MeshChunker.chunks(of: payload, for: manifest, identity: signer)
        )
    }

    /// Stages the whole item into one node's routed store under the rig's pinned install binding.
    /// `now` defaults to the rig's anchor, resolved in the body: a `@MainActor` static cannot be a
    /// default-argument value under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    func stage(into rig: MeshRoutedDrainRig, at node: Int, now: Date? = nil) {
        let now = now ?? MeshRoutedDrainRig.now
        let store = rig.routedStore(rig.nodes[node])
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            let admitted = store.admittingManifest(manifest, now: now)
            #expect(admitted.value != nil, "manifest admission")
            // R2: bounded by the item's own chunk count.
            for chunk in chunks {
                #expect(store.stagingChunk(chunk, now: now).value != nil, "chunk staging")
            }
        }
    }
}

// MARK: - The drain

/// The drain riding the one merge path: what moves, what does not, and what it never spends twice.
@MainActor
@Suite(.serialized)
struct MeshRoutedDrainTests {

    private func heldChunkCount(_ rig: MeshRoutedDrainRig, _ node: Int, _ key: MeshRoutedItemKey) -> Int {
        rig.heldChunkCount(node, key)
    }

    /// **The D-6.8 trap, pinned.** `receiveInventoryDigest` returns at its match branch before its
    /// own `Task` whenever the two ledgers already agree — the commonest blip — so a routed answer
    /// piggybacked there would never run in exactly the case the drain exists for.
    @Test func theDrainRunsWhenTheMembershipDigestAlreadyMatches() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-match")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle(until: { rig.routedIndex(rig.nodes[1])?.items.isEmpty == false })

        let tokens = rig.tokens(at: 1, from: 0)
        #expect(tokens.contains(PayloadType.meshInventoryDigest.rawValue),
                "the membership ask still opens the way P4 left it")
        #expect(tokens.contains(PayloadType.meshRoutedInventoryDigest.rawValue),
                "the routed inventory rode the SAME reconnect door")
        #expect(tokens.contains(PayloadType.meshRoutedManifest.rawValue))
        #expect(tokens.contains(PayloadType.meshRoutedChunk.rawValue))
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) != nil)
    }

    /// The whole ladder over one link: manifest, chunks, custody and the destination's own final
    /// receipt — and the origin learning about all of it.
    @Test func aHealedLinkDeliversManifestChunksAndBothReceipts() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-ladder")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.tempMessage)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let destination = rig.nodes[1].fingerprint
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        rig.commit(0, 1)
        // The origin's own copy is reclaimable the moment its one destination is delivered, so the
        // settle stops on EITHER the receipt landing or the record being reclaimed — waiting only for
        // the receipt would race a drop that has already happened.
        try await rig.settle(until: {
            guard let index = rig.routedIndex(rig.nodes[0]) else { return false }
            guard let record = index.record(for: item.key) else { return true }
            return !record.recipientReceipts.isEmpty
        })

        let atDestination = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        #expect(atDestination.chunks.count == item.chunks.count)
        #expect(atDestination.manifest != nil)
        #expect(atDestination.recipientReceipts.contains { $0.recipientFingerprint == destination })

        // P5 item 9's named consequence: the origin's copy becomes RECLAIMABLE the moment its one
        // destination is positively `delivered` — an origin is never a destination, and its canonical
        // copy lives outside the routed store — so the origin either still holds the receipt or has
        // already reclaimed the record, and the audited drop is what says which.
        let atOrigin = try #require(rig.routedIndex(rig.nodes[0]))
        if let held = atOrigin.record(for: item.key) {
            #expect(held.recipientReceipts.contains { $0.recipientFingerprint == destination })
            #expect(atOrigin.outstandingDestinations(for: item.key, in: rig.roster).contains(destination) == false,
                    "a delivered destination leaves every outstanding enumerator")
        } else {
            #expect(capture.values(of: "mesh.routedStore.itemDropped", key: "reason").contains("delivered"),
                    "the origin's record vanished with no audited reclaim behind it")
        }
    }

    /// A heart has no foreground evidence at the drain, so it stops at custody — the correct
    /// terminal-for-now state. The drain never fakes foregroundness.
    @Test func aHeartStaysPendingWithoutForegroundEvidence() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-heart")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.heart)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.custodiedAt != nil
        })

        let record = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        #expect(record.custodiedAt != nil, "durable ciphertext is custody")
        #expect(record.recipientReceipts.isEmpty, "a heart is not final without a ledger commit")
        #expect(record.deliveredAt == nil)
    }

    /// **D-6.1's deadlock proof.** A fresh member's store is `.absent`; if it advertised nothing the
    /// push-only drain could never offer it anything, so a heart to a new member would never arrive.
    @Test func anAbsentStoreAdvertisesAnEmptyInventoryAndIsThenOffered() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-absent")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        #expect(rig.routedIndex(rig.nodes[1]) == nil, "a fresh node's store is absent, not loaded")

        rig.commit(0, 1)
        try await rig.settle(until: { rig.routedIndex(rig.nodes[1])?.items.isEmpty == false })

        #expect(rig.tokens(at: 0, from: 1).contains(PayloadType.meshRoutedInventoryDigest.rawValue),
                "the absent store advertised an empty inventory")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) != nil,
                "and was then offered the item")
    }

    /// Re-draining a converged pair moves no content frame and grows nothing: receipts are
    /// replace-by-signer and the offer lists are empty once the peer holds everything.
    @Test func aSecondHealMovesNothing() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-idempotent")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, item.key) == item.chunks.count })
        let firstPass = rig.tokens(at: 1, from: 0).filter {
            $0 == PayloadType.meshRoutedChunk.rawValue || $0 == PayloadType.meshRoutedManifest.rawValue
        }.count
        let before = rig.routedIndex(rig.nodes[1])?.record(for: item.key)

        rig.commit(0, 1)
        try await rig.settle()

        let after = rig.tokens(at: 1, from: 0).filter {
            $0 == PayloadType.meshRoutedChunk.rawValue || $0 == PayloadType.meshRoutedManifest.rawValue
        }.count
        #expect(after == firstPass, "a converged pair re-sent content")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.chunks.count
                == before?.chunks.count)
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.recipientReceipts.count
                == before?.recipientReceipts.count, "the evidence array grew")
    }

    /// **The pacing regression.** A five-chunk item is over `maxChunksInFlightPerPeer` (3): under a
    /// per-answer bound re-derived from that constant it could never complete, and under a
    /// once-per-peer boolean it could never be retried either.
    @Test func aFiveChunkItemReachesDelivered() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-pacing")
        defer { rig.teardown() }
        let bytes = MeshChunkFormat.maxChunkPayloadBytes * 4 + 1_000
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, byteCount: bytes)
        #expect(item.chunks.count == 5, "the pacing cell needs a five-chunk item")
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[0])?
                .outstandingDestinations(for: item.key, in: rig.roster).isEmpty == true
        })

        #expect(heldChunkCount(rig, 1, item.key) == 5)
        let atOrigin = try #require(rig.routedIndex(rig.nodes[0]))
        #expect(atOrigin.outstandingDestinations(for: item.key, in: rig.roster).isEmpty,
                "every destination reached delivered")
    }

    /// **The "second heart in one session" case.** An item minted AFTER a non-empty batch still
    /// drains — the case a once-per-peer boolean makes permanently undeliverable.
    @Test func anItemMintedAfterASpentBatchStillDrains() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-second")
        defer { rig.teardown() }
        let first = try MeshRoutedDrainItem.mint(rig, origin: 0)
        first.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, first.key) == first.chunks.count })
        #expect(heldChunkCount(rig, 1, first.key) == first.chunks.count)

        let second = try MeshRoutedDrainItem.mint(rig, origin: 0)
        second.stage(into: rig, at: 0)
        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, second.key) == second.chunks.count })

        #expect(heldChunkCount(rig, 1, second.key) == second.chunks.count,
                "a second item minted mid-session never reached the peer")
    }

    /// An exchange with nothing to move charges nothing, so the budget is still whole when an item
    /// finally exists.
    @Test func anEmptyFirstExchangeDoesNotSpendTheBudget() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-empty")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle()
        #expect(rig.tokens(at: 1, from: 0).contains(PayloadType.meshRoutedChunk.rawValue) == false)

        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, item.key) == item.chunks.count })
        #expect(heldChunkCount(rig, 1, item.key) == item.chunks.count)
    }

    /// **D-6.5, the charge itself.** The per-peer session budget is what replaced the spec map's
    /// once-per-peer answered set, and a budget nothing reads is a budget that can be deleted in
    /// silence: this pins that the frames charged are exactly the frames that went on the wire.
    @Test func theBulkSpendsABoundedPerPeerSessionBudget() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-budget")
        defer { rig.teardown() }
        let bytes = MeshChunkFormat.maxChunkPayloadBytes * 2 + 1_000
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, byteCount: bytes)
        #expect(item.chunks.count == 3, "the budget cell needs an item of several frames")
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let peer = rig.nodes[1].fingerprint
        #expect(rig.nodes[0].manager.routedDrainFramesSpentForTesting[peer] == nil)

        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, item.key) == item.chunks.count })

        let spent = rig.nodes[0].manager.routedDrainFramesSpentForTesting[peer] ?? 0
        #expect(spent > 0, "a non-empty batch charged nothing at all")
        #expect(spent == contentFrames(rig, at: 1, from: 0),
                "the charge and the bulk frames on the wire disagree")
        #expect(spent <= MeshRoutedDrainBounds.sessionFramesPerPeer, "the session budget was exceeded")
    }

    /// **D-6.5's serialisation half**, and the reason the charge is `sendRoutedDrainBatch`'s first
    /// statement: one pump can deliver two of a peer's advertisements, and both are PLANNED before
    /// either `Task` body runs. A charge that landed after the sends would double-spend this
    /// device's bytes and never notice.
    @Test func twoInventoriesInOnePumpChargeSeparately() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-twice")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        #expect(item.chunks.count == 1, "the arithmetic below is one manifest plus one chunk")
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let peer = rig.nodes[1].fingerprint
        let advertisement = try MeshRoutedInventoryPayload.signed(
            meshID: rig.meshID, index: MeshRoutedIndex(),
            sentAt: MeshRoutedDrainRig.now, identity: rig.identities[1]
        )

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.nodes[0].manager.receiveRoutedInventory(
                advertisement, from: peer, now: MeshRoutedDrainRig.now
            )
            rig.nodes[0].manager.receiveRoutedInventory(
                advertisement, from: peer, now: MeshRoutedDrainRig.now
            )
        }
        try await MeshDepartureRig.settle(rig.nodes, on: rig.fabric)

        #expect(rig.nodes[0].manager.routedDrainFramesSpentForTesting[peer] == 4,
                "two batches planned in one pump did not charge twice")
    }

    /// **D-6.5's other half.** The inventory and the answer bit are never charged: a peer whose
    /// session budget is spent still learns what this device holds and still gets its quiescence
    /// answered — only the bulk stops, and the remainder waits for the next session.
    @Test func aSpentPeerStillGetsTheInventoryAndTheAnswerBit() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-spent")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let peer = rig.nodes[1].fingerprint
        rig.nodes[0].manager.routedDrainFramesSpentForTesting =
            [peer: MeshRoutedDrainBounds.sessionFramesPerPeer]

        rig.commit(0, 1)
        try await rig.settle()

        let tokens = rig.tokens(at: 1, from: 0)
        #expect(tokens.contains(PayloadType.meshRoutedInventoryDigest.rawValue),
                "a spent budget silenced the advertisement")
        #expect(tokens.contains(PayloadType.meshRoutedDrainAnswer.rawValue),
                "a spent budget silenced the quiescence bit, so item 7's window could never close")
        #expect(tokens.contains(PayloadType.meshRoutedManifest.rawValue) == false,
                "a spent budget still served the bulk")
        #expect(tokens.contains(PayloadType.meshRoutedChunk.rawValue) == false)
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) == nil)
    }

    /// **D-6.16 at the OTHER door.** A chunk for an item this device has never seen is parked, which
    /// is admissible — but only from the **origin**. Without the clause the harm the manifest door
    /// refuses is reachable one parked chunk set at a time: any admitted member could fill this
    /// device's caps with content nobody asked it to hold.
    @Test func aChunkForAnUnknownItemIsParkedOnlyForItsOrigin() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "drain-park")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(1, 2)
        rig.link(0, 2)
        let first = try #require(item.chunks.first)

        // Node 1 is a destination of the item, not its origin, and node 2 has no manifest for it.
        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 1, receiver: 2
        )
        #expect(rig.routedIndex(rig.nodes[2])?.record(for: item.key) == nil,
                "a third party parked a chunk set on a device that never asked for it")

        // The origin's own chunk, ahead of its manifest, still parks — C10's case is untouched.
        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 2
        )
        let parked = try #require(rig.routedIndex(rig.nodes[2])?.record(for: item.key))
        #expect(parked.manifest == nil, "the set is parked, not bound")
        #expect(parked.chunks.count == 1)
        #expect(parked.custodiedAt == nil, "a parked set is not custody")
    }

    /// **The admission verdict is named.** `MeshRoutedOutcome.completed` means only "the door ran":
    /// a re-sent chunk is `.completed(.duplicate)` and a peer offering different bytes for a slot
    /// this device holds is `.completed(.refused(.conflictingChunk))` — logging either as a plain
    /// admission satisfies "no drop is unnamed" in letter only.
    ///
    /// **P5 item 12 moved which re-sends reach the store, and this cell was re-aimed rather than
    /// relaxed.** A byte-identical re-send from the same author is now answered `replayed` at the
    /// door, before the store, so the store's own duplicate verdict is reached exactly when the
    /// replay window falls through — the deliberate, named degradation at a full axis. The cell
    /// therefore drives a window whose frame axis the manifest alone fills, which is the only path
    /// on which a duplicate still arrives, and keeps all three of its claims: the verdict is
    /// `duplicate`, nothing outside the vocabulary reaches the line, and the slot is not staged
    /// twice.
    @Test func aReSentChunkIsLoggedAsADuplicateNotAnAdmission() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-verdict")
        defer { rig.teardown() }
        rig.nodes[1].manager.routedReplayCapacityForTesting = 1
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let first = try #require(item.chunks.first)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )
        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )
        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )

        let verdicts = capture.verdicts(
            of: "mesh.routedDrain.admitted", type: PayloadType.meshRoutedChunk.rawValue
        )
        // `FernletAuditLog` is PROCESS-GLOBAL and `.serialized` does not isolate across suites, so an
        // exact list here is a claim about whatever else happened to be ingesting chunks in the same
        // process — a latent flake P5 item 8's scenario suite made deterministic. The claim that
        // matters survives whole: a re-sent chunk is NAMED a duplicate, and nothing outside the
        // verdict vocabulary reaches the line. The fix is not an item id in the context: audit
        // context is counts and frozen tokens, never content.
        #expect(verdicts.contains("duplicate"),
                "a re-sent chunk was logged as a plain admission: \(verdicts)")
        let named = verdicts.allSatisfy { $0 == "admitted" || $0 == "duplicate" }
        #expect(named, "an unnamed verdict reached the admission line: \(verdicts)")
        #expect(heldChunkCount(rig, 1, item.key) == 1,
                "the duplicate was named rather than staged a second time")
    }

    /// **D-6.15's negative.** A destination that holds a complete item addressed to {B, C} is not a
    /// courier for its co-destination: `isCustodied` is true at C, and C still offers B nothing.
    @Test func aDestinationIsNotACourierForItsCoDestinations() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "drain-courier")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 2)
        rig.commit(0, 2)
        try await rig.settle([0, 2], until: {
            rig.routedIndex(rig.nodes[2])?.record(for: item.key)?.custodiedAt != nil
        })
        #expect(rig.routedIndex(rig.nodes[2])?.record(for: item.key)?.isCustodied == true,
                "the co-destination really does hold custody")

        rig.link(1, 2)
        rig.commit(1, 2)
        try await rig.settle([1, 2])

        let offered = rig.tokens(at: 1, from: 2)
        #expect(offered.contains(PayloadType.meshRoutedManifest.rawValue) == false,
                "a destination offered a co-destination somebody else's item")
        #expect(offered.contains(PayloadType.meshRoutedChunk.rawValue) == false)
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) == nil)
    }

    /// **D-6.16.** A manifest addressed to neither this device nor forwarded by its origin is refused:
    /// without the clause any member could fill this device's caps with content nobody asked it to
    /// hold, and the drain would then mint a custody receipt for each.
    @Test func aManifestAddressedElsewhereIsRefused() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "drain-stranger")
        defer { rig.teardown() }
        let signer = rig.identities[0]
        // A destination set of ONE, built from a two-member ledger on the same mesh: node 2 is
        // neither the origin nor a destination, which is the state the clause refuses.
        let pair = try MeshPartitionFixtures.ledger(
            founder: signer, others: [rig.identities[1]], meshID: rig.meshID
        )
        let target = MeshDeliveryTarget(
            contentID: UUID(), roster: pair.derivedRoster, selfFingerprint: signer.localFingerprint
        )
        #expect(target.destinations == [rig.nodes[1].fingerprint])
        let payload = MeshRoutedCustodyFixtures.blob(byteCount: 512)
        let narrowed = try MeshRoutedManifest.signed(
            meshID: rig.meshID,
            target: target,
            typeToken: MeshRoutedTypeToken.photo,
            contentHash: MeshRoutedContentDigest.contentHash(of: payload),
            size: UInt64(payload.count),
            createdAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60),
            hardDeadline: MeshRoutedDrainRig.hardDeadline,
            contentKey: Data(repeating: 0x44, count: 32),
            recipientKeys: [rig.nodes[1].fingerprint: rig.identities[1].localKeyAgreementPublicKey],
            identity: signer
        )
        rig.link(1, 2)
        // Node 1 — a destination, not the origin — pushes the manifest at node 2, which is neither.
        try await deliver(
            MeshRoutedManifestPayload(manifest: narrowed), type: .meshRoutedManifest,
            from: rig, sender: 1, receiver: 2
        )

        let key = MeshRoutedItemKey(narrowed)
        #expect(rig.routedIndex(rig.nodes[2])?.record(for: key) == nil,
                "a third party's manifest was admitted")
        #expect(rig.routedIndex(rig.nodes[2]) == nil || rig.routedIndex(rig.nodes[2])?.items.isEmpty == true)
    }

    /// A digest naming another mesh is refused by the verifier, records nothing and answers nothing.
    @Test func aForeignMeshInventoryIsIgnored() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-foreign")
        defer { rig.teardown() }
        rig.link(0, 1)
        let foreign = try MeshRoutedInventoryPayload.signed(
            meshID: UUID(), index: MeshRoutedIndex(),
            sentAt: MeshRoutedDrainRig.now, identity: rig.identities[1]
        )
        try await deliver(foreign, type: .meshRoutedInventoryDigest, from: rig, sender: 1, receiver: 0)

        #expect(rig.nodes[0].manager.peerRoutedInventories[rig.nodes[1].fingerprint]?.inventory == nil,
                "a foreign-mesh digest was recorded")
        #expect(rig.tokens(at: 1, from: 0).contains(PayloadType.meshRoutedDrainAnswer.rawValue) == false)
    }

    /// A manifest whose origin-signed type token nobody registered is refused at the verifier and
    /// never forwarded — plan §11's rule, answered before anything is admitted.
    @Test func anUnknownTypeTokenIsRefusedAndNotForwarded() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-token")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedManifestFixtures.typeToken
        )
        #expect(MeshRoutedAckStageTable.increment1.stage(for: item.manifest.typeToken) == nil,
                "the cell needs a token the table does not know")
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle()

        // The MANIFEST is refused, which is the rule: nothing is bound, no custody is claimed and
        // nothing is forwarded onward. The chunks that rode ahead of it stay PARKED — a parked set
        // whose manifest is refused is item 9's drop rule, named here rather than silently swept.
        let record = rig.routedIndex(rig.nodes[1])?.record(for: item.key)
        #expect(record?.manifest == nil, "an unregistered type token was admitted")
        #expect(record?.custodiedAt == nil, "a refused manifest still produced a custody claim")
        #expect(record?.receipts.isEmpty != false)
        #expect(rig.tokens(at: 0, from: 1).contains(PayloadType.meshCustodyReceipt.rawValue) == false,
                "a refused type token was acknowledged back to the origin")
    }

    /// **D-6.10, both directions.** The quiescence bit round-trips and binds, driven with a
    /// deliberately NON-INTEGRAL `now` so a floored-versus-unfloored `advertisedAt` fails here rather
    /// than silently disabling every bit.
    @Test func theQuiescenceBitRoundTripsAndAnUnboundOneIsDropped() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-quiescent")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.nodes[0].manager.peerRoutedInventories[rig.nodes[1].fingerprint]?.quiescentAsOf != nil
        })

        let state = try #require(
            rig.nodes[0].manager.peerRoutedInventories[rig.nodes[1].fingerprint]
        )
        #expect(state.reportsQuiescent, "two empty stores are quiescent on both sides")
        #expect(state.localQuiescent, "this device's own half is recorded in the same pass")
        #expect(state.quiescentAsOf != nil,
                "only an answer bound to a real advertisement is ever recorded")
        #expect(state.advertisedAt != nil)

        // An answer naming an instant this device never advertised is dropped, not recorded.
        let unbound = try MeshRoutedDrainAnswerPayload.signed(
            meshID: rig.meshID, advertiser: rig.nodes[0].fingerprint,
            advertisedAt: MeshRoutedDrainRig.now.addingTimeInterval(9_999), quiescent: true,
            sentAt: MeshRoutedDrainRig.now, identity: rig.identities[1]
        )
        try await deliver(unbound, type: .meshRoutedDrainAnswer, from: rig, sender: 1, receiver: 0)
        #expect(rig.nodes[0].manager.peerRoutedInventories[rig.nodes[1].fingerprint]?.quiescentAsOf
                == state.quiescentAsOf, "an unbound bit overwrote a bound one")
    }

    /// A store sealed under ANOTHER install is `.corrupt`, not empty: it advertises nothing, answers
    /// nothing and forgets nothing. The cell names the state it drove, because "sends nothing" is
    /// true of four different states and only one of them is this one.
    @Test func aStoreSealedUnderAnotherInstallSendsNothingAndForgetsNothing() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-corrupt")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let before = rig.routedIndex(rig.nodes[0])?.record(for: item.key)
        #expect(rig.routedLoad(rig.nodes[0], install: MeshRoutedStoreFixtures.installB)
                == .corrupt(MeshRoutedCorruption(detail: .authenticationFailed)),
                "the cell means to drive `.corrupt`, and nothing else")

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshRoutedStoreFixtures.installB)) {
            await rig.nodes[0].manager.sendRoutedInventory(
                to: [rig.nodes[1].fingerprint], now: MeshRoutedDrainRig.now
            )
        }
        try await MeshDepartureRig.settle([rig.nodes[0], rig.nodes[1]], on: rig.fabric)

        #expect(rig.tokens(at: 1, from: 0).contains(PayloadType.meshRoutedInventoryDigest.rawValue) == false,
                "a corrupt store advertised anyway")
        #expect(rig.tokens(at: 1, from: 0).contains(PayloadType.meshRoutedDrainAnswer.rawValue) == false)
        #expect(rig.routedIndex(rig.nodes[0])?.record(for: item.key) == before,
                "a corrupt store must forget nothing")
    }

    /// **Invariant 7's own arm.** A `.deferred` store — protected data unavailable, nothing decided —
    /// advertises nothing, answers nothing and forgets nothing. Letting it advertise an empty index
    /// would be a locked device positively claiming "I hold nothing", which is the re-delivery storm
    /// D-6.1 exists to refuse.
    @Test func aDeferredStoreSendsNothingAndForgetsNothing() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-deferred")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let before = rig.routedIndex(rig.nodes[0])?.record(for: item.key)

        await DeviceBindingID.$testOverride.withValue(.readError) {
            await rig.nodes[0].manager.sendRoutedInventory(
                to: [rig.nodes[1].fingerprint], now: MeshRoutedDrainRig.now
            )
        }
        try await MeshDepartureRig.settle([rig.nodes[0], rig.nodes[1]], on: rig.fabric)

        #expect(rig.tokens(at: 1, from: 0).contains(PayloadType.meshRoutedInventoryDigest.rawValue) == false,
                "a deferred store advertised anyway")
        #expect(rig.tokens(at: 1, from: 0).contains(PayloadType.meshRoutedDrainAnswer.rawValue) == false)
        #expect(rig.routedIndex(rig.nodes[0])?.record(for: item.key) == before,
                "a deferred store must forget nothing")
    }

    /// **D-6.6, all three sites driven.** `leaveMesh`, `prepareMembershipLedger` and
    /// `armJoinerLedger`'s adoption each forget every peer's drain state — and the per-peer frame
    /// budget goes with it, which is the field a reset that cleared only the inventories would leave
    /// behind.
    @Test func theDrainStateIsClearedAtTheThreeSessionResets() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "drain-reset")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.link(0, 2)
        rig.commit(0, 1)
        rig.commit(0, 2)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, item.key) == item.chunks.count })
        #expect(rig.nodes[0].manager.peerRoutedInventories.isEmpty == false)
        #expect(rig.nodes[0].manager.routedDrainFramesSpentForTesting.isEmpty == false,
                "the reset claim needs a budget that was actually spent")
        #expect(rig.nodes[2].manager.peerRoutedInventories.isEmpty == false)

        rig.nodes[0].manager.leaveMesh()
        #expect(rig.nodes[0].manager.peerRoutedInventories.isEmpty)
        #expect(rig.nodes[0].manager.routedDrainFramesSpentForTesting.isEmpty,
                "leaveMesh left a spent budget behind")

        rig.nodes[1].manager.prepareMembershipLedger(meshID: UUID(), founderSigningPublicKey: nil)
        #expect(rig.nodes[1].manager.peerRoutedInventories.isEmpty)

        #expect(try Self.armJoiner(rig.nodes[2], as: rig.identities[2]),
                "the adoption branch is the third reset; a refused grant proves nothing")
        #expect(rig.nodes[2].manager.peerRoutedInventories.isEmpty)
        #expect(rig.nodes[2].manager.routedDrainFramesSpentForTesting.isEmpty)
    }

    /// Drives `armJoinerLedger`'s `.adopted` branch: a grant for a DIFFERENT mesh, so the
    /// already-joined early return is not what answers.
    private static func armJoiner(_ node: MeshDepartureNode, as identity: IdentityService) throws -> Bool {
        let admitter = try MeshPartitionFixtures.identity("\(node.label)-admitter")
        let token = try MeshAdmissionToken.signed(
            meshID: UUID(),
            joinerFingerprint: identity.localFingerprint,
            joinerSigningPublicKey: identity.localSigningPublicKey,
            admitterIdentity: admitter
        )
        let bundle = try admitter.encryptGroupKey(
            Data(repeating: 0x2C, count: 32), for: identity.localKeyAgreementPublicKey
        )
        return node.manager.armJoinerLedger(
            MeshAdmissionGrantPayload(
                meshID: token.meshID, requesterFingerprint: identity.localFingerprint,
                token: token, encryptedCurrentKey: bundle, currentKeyEpoch: 0
            )
        )
    }

    /// **D17.** A re-partition is not a new session. `abandonMergeExchange()` drops the merge window
    /// this device was holding and refunds **nothing**: a flapping link would otherwise re-spend this
    /// device's bytes on every flap, which is the failure the session budget exists to prevent.
    @Test func aRePartitionDoesNotRefundTheBudget() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-reflap")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, item.key) == item.chunks.count })
        let peer = rig.nodes[1].fingerprint
        let spent = rig.nodes[0].manager.routedDrainFramesSpentForTesting[peer] ?? 0
        #expect(spent > 0, "the refund claim needs a budget that was actually spent")

        rig.nodes[0].manager.applySessionEvent(.linksLost)

        #expect(rig.nodes[0].manager.sessionState == .partitioned,
                "the cell must really reach the state that abandons the exchange")
        #expect(rig.nodes[0].manager.routedDrainFramesSpentForTesting[peer] == spent,
                "a re-partition refunded the per-peer frame budget")
        #expect(rig.nodes[0].manager.peerRoutedInventories[peer] != nil,
                "a re-partition forgot what the peer holds")
    }

    /// A content exchange must never mint an epoch: the drain raises no rotation of its own.
    @Test func theDrainRaisesNoRotation() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-rotation")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        MeshDepartureRig.consumeRotations(rig.nodes)
        rig.sample.reset()

        rig.commit(0, 1)
        try await rig.settle(until: { self.heldChunkCount(rig, 1, item.key) == item.chunks.count })

        let causes = Set(rig.nodes.flatMap { rig.sample.causes(at: $0.label) })
        #expect(causes.subtracting([.merge]).isEmpty, "the drain raised a rotation of its own")
    }

    // MARK: - P5 item 12: the replay window, wired against routed content ids

    /// **The manifest door answers a replay BEFORE the verifier.** The second frame carries a
    /// tampered signature, so a verifier that ran first would name its own rejection; the window
    /// names `replayed` instead, and the store still holds the first manifest's bytes.
    @Test func aReplayedManifestIsAnsweredBeforeTheVerifier() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-manifest")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )
        let tampered = MeshRoutedManifestTamper.signatureByte.applied(to: item.manifest)
        try await deliver(
            MeshRoutedManifestPayload(manifest: tampered), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshRoutedManifest.rawValue
        )
        #expect(reasons.contains("replayed"),
                "the replay was not answered before the signature check: \(reasons)")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.manifest == item.manifest,
                "the tampered manifest reached the store")
    }

    /// **And a byte-identical replay never reaches the store at all.** The record's admission
    /// instant and chunk set are the state read: only a second store pass could move either.
    @Test func aReplayedManifestNeverReachesTheStore() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-manifest-twice")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )
        let first = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshRoutedManifest.rawValue
        )
        #expect(reasons.contains("replayed"), "the second manifest was not named a replay")
        let second = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        #expect(second.firstSeenAt == first.firstSeenAt, "the store ran a second admission")
        #expect(second.chunks.count == first.chunks.count)
    }

    /// **The chunk door answers before its two SHA-256 passes.** The replayed chunk carries a
    /// tampered payload — same derived `chunkID`, since the id is `H(itemID ‖ index)` — so a
    /// verifier that ran first would answer `chunkHashMismatch` instead.
    @Test func aReplayedChunkIsAnsweredBeforeItsTwoHashes() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-chunk")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)
        let first = try #require(item.chunks.first)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 1
        )
        try rig.dispatch(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, sender: 0, receiver: 1
        )
        var payload = first.payload
        payload[payload.startIndex] ^= 0x01
        try await deliver(
            MeshChunkPayload(chunk: first.replacing(payload: payload)), type: .meshRoutedChunk,
            from: rig, sender: 0, receiver: 1
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshRoutedChunk.rawValue
        )
        #expect(reasons.contains("replayed"), "the replayed chunk paid for its hashes: \(reasons)")
        #expect(heldChunkCount(rig, 1, item.key) == 1)
    }

    /// **A replayed custody receipt is refused before the store.** The receipt is the one the drain
    /// itself minted, replayed verbatim; the evidence set stays at one.
    @Test func aReplayedCustodyReceiptIsRefusedBeforeTheStore() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-custody")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle([0, 1], until: {
            rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.receipts.isEmpty == false
        })
        let receipt = try #require(rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.receipts.first)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await deliver(
            MeshCustodyReceiptPayload(receipt: receipt), type: .meshCustodyReceipt,
            from: rig, sender: 1, receiver: 0
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshCustodyReceipt.rawValue
        )
        #expect(reasons.contains("replayed"), "a re-sent custody receipt reached the store")
        #expect(rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.receipts.count == 1)
    }

    /// **And a replayed recipient receipt likewise.** Three nodes, so the origin still owes node 2
    /// and item 9's reclaim cannot drop the record out from under the claim.
    @Test func aReplayedRecipientReceiptIsRefusedBeforeTheStore() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-recipient")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle([0, 1], until: {
            rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.recipientReceipts.isEmpty == false
        })
        let receipt = try #require(
            rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.recipientReceipts.first
        )
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await deliver(
            MeshRecipientReceiptPayload(receipt: receipt), type: .meshRecipientReceipt,
            from: rig, sender: 1, receiver: 0
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshRecipientReceipt.rawValue
        )
        #expect(reasons.contains("replayed"), "a re-sent recipient receipt reached the store")
        #expect(rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.recipientReceipts.count == 1)
    }

    /// **The axis is the ORIGIN, not the forwarding envelope's sender.** One origin's chunk offered
    /// by two different couriers is one window row, so the second is a replay — which a window keyed
    /// on `context.sender` would have admitted twice and caught never.
    @Test func oneOriginsChunkForwardedByTwoCustodiansIsOneWindowRow() async throws {
        let rig = try MeshRoutedDrainRig.build(4, label: "replay-couriers")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 3)
        rig.link(1, 3)
        rig.link(2, 3)
        let first = try #require(item.chunks.first)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 3
        )
        try rig.dispatch(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, sender: 1, receiver: 3
        )
        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 2, receiver: 3
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshRoutedChunk.rawValue
        )
        #expect(reasons.contains("replayed"), "the second courier's copy was admitted a second time")
        #expect(heldChunkCount(rig, 3, item.key) == 1)
    }

    /// **An epoch rotation does not release a routed frame.** The window knows nothing about epochs
    /// by construction, and this is the cell that says so from the manager's side — item 13's
    /// precondition, asserted rather than asserted-about.
    ///
    /// The rotation is driven so that it actually happens, and every step of that is load-bearing
    /// (the review round that added them found the cell was a byte-identical duplicate of
    /// ``aReplayedManifestNeverReachesTheStore`` in most runs):
    ///
    /// - **The coordinator is looked up, never assumed.** `initiateRotation` returns at
    ///   `plannedRotation()` unless this device *is* `epochCoordinatorFingerprint`, which is the
    ///   presented roster's `min()`; the rig's identities are freshly minted keypairs, so a fixed
    ///   node index is the minimum about one run in three.
    /// - **The mint runs under the rig's one pinned install binding**, the
    ///   `MeshReconcileFixtures.mint` idiom: the rotation is abandoned at
    ///   `persistSessionContext(addingEpochHead:)` — durable before acknowledged — when the seal has
    ///   no `DeviceBindingID` to bind to, and abandons it silently.
    /// - **The coordinator is the UNLINKED third node.** A coordinator holding an active slot spends
    ///   the ten-second rotation ack window waiting on a peer that no pump is answering; this lane
    ///   takes no wall-clock time, so the minted head is folded into the receiver through the same
    ///   seam a merge would (`MeshDepartureRig.seedEpoch`) instead.
    /// - **The receiver's own epoch must move**, from a real predecessor to the real successor, or
    ///   the claim below is about a device whose epoch never changed.
    @Test func anEpochRotationDoesNotReleaseARoutedFrame() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-epoch")
        defer { rig.teardown() }
        let minter = try #require(rig.nodes[0].manager.epochCoordinatorFingerprintForTesting)
        let coordinator = try #require(rig.nodes.firstIndex { $0.fingerprint == minter })
        let others = rig.nodes.indices.filter { $0 != coordinator }
        #expect(others.count == 2, "the two non-coordinator nodes are this cell's link")
        let origin = try #require(others.first)
        let receiver = try #require(others.last)
        let opening = try MeshReconcileFixtures.head(2, rig.identities[coordinator], rig.meshID)
        MeshDepartureRig.seedEpoch(rig.nodes[coordinator], head: opening)
        MeshDepartureRig.seedEpoch(rig.nodes[receiver], head: opening)
        let item = try MeshRoutedDrainItem.mint(rig, origin: origin)
        rig.link(origin, receiver)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: origin, receiver: receiver
        )
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.nodes[coordinator].manager.rotateNowForTesting(cause: .merge)
        }
        let minted = try #require(rig.nodes[coordinator].manager.epochKeyring?.head,
                                  "the elected coordinator must actually mint a successor")
        #expect(minted != opening, "a rotation that did not move the epoch proves nothing")
        MeshDepartureRig.seedEpoch(rig.nodes[receiver], head: minted)
        #expect(rig.nodes[receiver].manager.epochKeyring?.head == minted,
                "the receiver must be on the new epoch, or the claim below is vacuous")

        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: origin, receiver: receiver
        )

        let reasons = capture.reasons(
            of: "mesh.routedDrain.rejected", type: PayloadType.meshRoutedManifest.rawValue
        )
        #expect(reasons.contains("replayed"), "a rotation released a recorded routed frame")
        #expect(rig.nodes[receiver].manager.routedReplayWindowForTesting?
                    .recordedCount(for: rig.nodes[origin].fingerprint) == 1)
    }

    /// **Cleared at a session reset, and only there.** A new session is a new window; a partition
    /// flap is not, which is what the wall asserts from the other side.
    @Test func theWindowIsClearedAtASessionReset() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-reset")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)

        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )
        #expect(rig.nodes[1].manager.routedReplayWindowForTesting != nil,
                "the window must exist before the reset, or the claim is vacuous")

        rig.nodes[1].manager.leaveMesh()

        #expect(rig.nodes[1].manager.routedReplayWindowForTesting == nil)
    }

    /// **A full axis is a named degradation, never a refusal.** Driven to a capacity of one, the
    /// window answers `senderWindowFull` to the next distinct frame — and that frame still lands.
    /// A window that refused here would wedge an origin for the whole session.
    @Test func aFrameArrivingAtAFullWindowStillLands() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-full")
        defer { rig.teardown() }
        rig.nodes[1].manager.routedReplayCapacityForTesting = 1
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)
        let first = try #require(item.chunks.first)
        let capture = MeshRoutedDrainAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 1
        )
        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )

        #expect(heldChunkCount(rig, 1, item.key) == 1,
                "a legitimate frame was dropped by a full replay window")
        #expect(capture.values(of: "mesh.routedDrain.replayWindowFull", key: "axis").contains("frames"),
                "the full axis was not named")
    }

    /// **A frame the store could not take is not recorded.** Otherwise the peer's next honest
    /// re-offer — which is exactly what the drain makes — would be answered `replayed` and the item
    /// could never complete.
    @Test func aFrameTheStoreCouldNotTakeIsNotRecorded() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-deferred")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)
        let first = try #require(item.chunks.first)

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 1
        )
        try rig.dispatch(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, sender: 0, receiver: 1,
            binding: .readError
        )
        #expect(heldChunkCount(rig, 1, item.key) == 0, "the locked pass must have staged nothing")

        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )

        #expect(heldChunkCount(rig, 1, item.key) == 1,
                "the honest re-offer was answered as a replay, so the item could never complete")
    }

    /// **And neither is a capacity-refused one.** Item 9's sweeps and reclaims free capacity
    /// mid-session, so a refused frame must stay re-offerable for the rest of it.
    @Test func aCapacityRefusedFrameStaysReOfferable() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-capacity")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        rig.link(0, 1)
        let hog = MeshRoutedStoreFixtures.record(
            chunks: [MeshRoutedStoreFixtures.descriptor(
                index: 0, count: 1, bytes: Int(MeshRoutedStoreFormat.maxContentBytes)
            )],
            expiresAt: MeshRoutedManifest.expiry(afterHardDeadline: MeshRoutedDrainRig.hardDeadline)
        )
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: [hog]), into: rig.routedStore(rig.nodes[1]),
            install: MeshP3Acceptance.install
        )

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 1
        )
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) == nil,
                "the cell must start with a real capacity refusal")

        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(), into: rig.routedStore(rig.nodes[1]),
            install: MeshP3Acceptance.install
        )
        try await deliver(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            from: rig, sender: 0, receiver: 1
        )

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) != nil,
                "a capacity-refused frame was stranded for the session")
    }

    /// **A repaired slot is re-admittable.** The store gives a chunk slot back when its durable
    /// bytes are gone — the index is authoritative over what this device has — and the drain then
    /// makes a peer re-offer that exact chunk under the identical derived id. Without the un-record
    /// the slot could never be refilled for the rest of the session: no complete item, no witness,
    /// no receipt, no delivery.
    ///
    /// Driven through the production path, not a seam: the commit's own stream finds the missing
    /// file, repairs the index, and `commitLocalCustody` un-records the item's whole derivable id
    /// family on the way out.
    @Test func aRepairedSlotIsReAdmittable() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-repair")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, byteCount: MeshChunkFormat.maxChunkPayloadBytes + 1_000
        )
        #expect(item.chunks.count == 2, "the cell needs a slot that can go missing before the last")
        rig.link(0, 1)
        let origin = rig.nodes[0].fingerprint
        let (first, last) = (try #require(item.chunks.first), try #require(item.chunks.last))

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 1
        )
        try rig.dispatch(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, sender: 0, receiver: 1
        )
        #expect(rig.nodes[1].manager.routedReplayWindowForTesting?.recordedCount(for: origin) == 2,
                "the manifest and the first chunk must really be recorded, or nothing is proved")

        // The durable bytes go. The next commit's stream is what notices and repairs the index.
        Self.removeChunkFiles(of: rig.nodes[1])
        try await deliver(
            MeshChunkPayload(chunk: last), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )
        #expect(heldChunkCount(rig, 1, item.key) == 1, "the cell must start from a real repair")

        try await deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )

        #expect(heldChunkCount(rig, 1, item.key) == 2,
                "a repaired slot could never be refilled — the window outlived what the store gave back")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.custodiedAt != nil,
                "and the refilled item never reached custody")
    }

    /// Every chunk file under one node's routed scope, removed — the durable half of a repair.
    private static func removeChunkFiles(of node: MeshDepartureNode) {
        let root = node.store.meshRoutedStorage.directory
            .appendingPathComponent("MeshRoutedChunks", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        // R2: bounded by the fixture's own chunk count.
        for file in contents.prefix(MeshChunkFormat.maxChunkCount) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// **A completing frame whose rung work did not settle is not recorded**, so the honest re-offer
    /// is still the re-drive. Asserted as a PAIR, because the negative alone holds for a device that
    /// simply never completed the item: the courier — admitted through the origin's own hand-off
    /// disjunct, so not a destination and holding no handed-off leg — records only its manifest,
    /// while the destination beside it records manifest and chunk both.
    @Test func aCompletingFrameWhoseRungWorkDidNotSettleIsNotRecorded() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "replay-settled")
        defer { rig.teardown() }
        let narrowed = try Self.narrowedItem(rig, origin: 0, destination: 1)
        rig.link(0, 1)
        rig.link(0, 2)
        let chunk = try #require(narrowed.chunks.first)
        let origin = rig.nodes[0].fingerprint

        // Node 2: not a destination, admitted only because the ORIGIN forwarded the manifest.
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: narrowed.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 2
        )
        try rig.dispatch(
            MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 0, receiver: 2
        )
        // Node 1: the destination, same two frames.
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: narrowed.manifest), type: .meshRoutedManifest,
            sender: 0, receiver: 1
        )
        try await deliver(
            MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, from: rig, sender: 0, receiver: 1
        )

        #expect(rig.nodes[2].manager.routedReplayWindowForTesting?.recordedCount(for: origin) == 1,
                "a completing frame whose rungs never settled was recorded, so no re-offer can re-drive it")
        #expect(rig.nodes[1].manager.routedReplayWindowForTesting?.recordedCount(for: origin) == 2,
                "and the settled destination must record both, or the pair above proves nothing")
    }

    /// One item addressed to exactly one destination, minted on the rig's own mesh — the shape that
    /// makes a third node a courier rather than a recipient.
    private static func narrowedItem(
        _ rig: MeshRoutedDrainRig, origin: Int, destination: Int
    ) throws -> MeshRoutedDrainItem {
        let signer = rig.identities[origin]
        let pair = try MeshPartitionFixtures.ledger(
            founder: signer, others: [rig.identities[destination]], meshID: rig.meshID
        )
        let target = MeshDeliveryTarget(
            contentID: UUID(), roster: pair.derivedRoster, selfFingerprint: signer.localFingerprint
        )
        let payload = MeshRoutedCustodyFixtures.blob(byteCount: 1_500)
        let manifest = try MeshRoutedManifest.signed(
            meshID: rig.meshID,
            target: target,
            typeToken: MeshRoutedTypeToken.photo,
            contentHash: MeshRoutedContentDigest.contentHash(of: payload),
            size: UInt64(payload.count),
            createdAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60),
            hardDeadline: MeshRoutedDrainRig.hardDeadline,
            contentKey: Data(repeating: 0x55, count: 32),
            recipientKeys: [rig.nodes[destination].fingerprint:
                                rig.identities[destination].localKeyAgreementPublicKey],
            identity: signer
        )
        return MeshRoutedDrainItem(
            manifest: manifest,
            chunks: try MeshChunker.chunks(of: payload, for: manifest, identity: signer)
        )
    }

    /// The routed content frames one node received from another — what the peer's session frame
    /// budget is charged for, counted on the wire.
    private func contentFrames(_ rig: MeshRoutedDrainRig, at receiver: Int, from sender: Int) -> Int {
        let bulk: Set<String> = [
            PayloadType.meshRoutedManifest.rawValue, PayloadType.meshRoutedChunk.rawValue,
            PayloadType.meshCustodyReceipt.rawValue, PayloadType.meshRecipientReceipt.rawValue
        ]
        return rig.tokens(at: receiver, from: sender).filter { bulk.contains($0) }.count
    }

    /// Delivers one already-minted routed frame from one node to another, through the real envelope
    /// verification and the drain's own dispatch door — on an **injected** clock.
    ///
    /// The clock is the point: every admission, every `isLive(at:)` check and every `deliveredAt`
    /// stamp downstream reads this one instant, and a fixture whose manifests expire on a fixed
    /// calendar date would otherwise turn every hand-driven cell into a claim about the day the
    /// suite ran. The settle-driven cells still take the manager's own `Date()` default — the outer
    /// switch's routed case is theirs to cover.
    private func deliver(
        _ payload: some Encodable,
        type: PayloadType,
        from rig: MeshRoutedDrainRig,
        sender: Int,
        receiver: Int,
        now: Date? = nil
    ) async throws {
        try await rig.deliver(payload, type: type, sender: sender, receiver: receiver, now: now)
    }
}

// MARK: - Audit capture

/// Collects the drain's audit lines WITH their context for one test, installed on entry and removed
/// by token on teardown so it never outlives the test that installed it.
///
/// A lock-guarded class rather than a captured local: the sink is a plain non-`Sendable` closure the
/// log invokes outside its own lock, so the only safe place for the collected lines is behind one.
private final class MeshRoutedDrainAuditCapture {
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

    /// Every `verdict` value logged under `event` for one payload type, in order.
    func verdicts(of event: String, type: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines
            .filter { $0.event == event && $0.context["type"] == type }
            .map { $0.context["verdict"] ?? "missing" }
    }

    /// Every `reason` value logged under `event` for one payload type, in order — the refusal lines
    /// key on `reason`, not on `verdict`, so P5 item 12's `"replayed"` needs its own reader.
    func reasons(of event: String, type: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines
            .filter { $0.event == event && $0.context["type"] == type }
            .map { $0.context["reason"] ?? "missing" }
    }

    /// Every value logged under `event` for one context key, whatever the payload type — the reader
    /// the replay window's own `axis` token needs.
    func values(of event: String, key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == event }.compactMap { $0.context[key] }
    }
}

// MARK: - The walls

/// The mechanical halves of "no second reconnect path", "no epoch on the routed path" and "item 12
/// inherits a clean seam" — grep-walls over the manager's own source.
@MainActor
@Suite(.serialized)
struct MeshRoutedDrainWallTests {

    private func managerSource() throws -> String {
        try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
    }

    /// **The mechanical form of "do NOT add a second reconnect path".** The routed ask rides exactly
    /// the three **ask** doors; the membership digest has two additional, non-ask doors — the
    /// post-merge **proof** and the joiner's post-**adoption** digest — each of which opens no
    /// window, asks nothing and carries no routed bulk.
    ///
    /// **This claim was amended by P5 item 7, deliberately, and strengthened in the same commit.**
    /// Before item 7 both counts were four and equal. The window redesign added
    /// `readvertiseMergeProof(to:)` — a fourth `sendInventoryDigest(` call that is the *occasion*
    /// the strict closing rule needs, since nothing else ever sends a second digest inside one
    /// session — and then `attemptLedgerAdoption(ownAdmission:meshID:)`, a fifth, which is the same
    /// missing occasion for a **joiner**: its grant-reply digest is a one-record bootstrap ledger,
    /// so the admitter answers it and carries the obligation, and adoption rebases without going
    /// through `mergeMembershipLedger(_:)`, so the proof door never fires there. Routing either
    /// through a private helper to keep the textual count at four was rejected on purpose: that
    /// would have left the wall green while the property it protects had changed. So the counts
    /// moved and the wall became **per function** instead — it now names WHICH functions may send
    /// each ask, which a count never could.
    ///
    /// **P5 item 13 moved the BULK count, not the ask count.** All three ask doors fire as a link
    /// OPENS, so an item minted mid-session with the links already open would wait for the next
    /// reconnect — in a stable session, forever. The fix is a fourth `sendRoutedBulk(` site,
    /// `pushOriginatedItem(_:to:now:)`, and deliberately **not** a fourth `sendRoutedInventory(`
    /// one: an advertisement asks the PEER to push to this device, which is the opposite of what an
    /// origination needs, and recording one would overwrite the `advertisedAt` an inbound quiescence
    /// answer has to quote. So `sendRoutedInventory(` stands at four, `sendRoutedBulk(` at four, and
    /// the new door gets its own class below beside item 8's hand-off.
    ///
    /// Counted on the SYMBOL, not on a spelling: a call written `await sendRoutedInventory(…)` —
    /// the natural form for any same-actor caller, and the one the signature invites — would leave a
    /// `self?.`-prefixed count at three and the wall green.
    @Test func theDrainFiresOnlyFromTheMergeDoor() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let routed = source.components(separatedBy: "sendRoutedInventory(").count - 1
        let membership = source.components(separatedBy: "sendInventoryDigest(").count - 1
        #expect(routed == 4, "one declaration plus three ask sites, found \(routed)")
        #expect(membership == 6,
                "those three plus the proof and adoption doors, found \(membership)")
        for door in Self.askDoors {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            #expect(body.components(separatedBy: "sendInventoryDigest(").count - 1 == 1,
                    "\(door) asks with exactly one membership digest")
            #expect(body.components(separatedBy: "sendRoutedInventory(").count - 1 == 1,
                    "\(door) carries exactly one routed twin")
        }
        for door in Self.nonAskDoors {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            #expect(body.components(separatedBy: "sendInventoryDigest(").count - 1 == 1,
                    "\(door) sends exactly one membership digest")
            #expect(!body.contains("sendRoutedInventory("),
                    "\(door) is not an ask: it must never carry routed bulk")
        }
        #expect(source.components(separatedBy: "sendRoutedBulk(").count - 1 == 4,
                "one declaration plus three sites: drain answer, hand-off push, origination push")
        for door in Self.handoffDoors {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            #expect(!body.contains("sendInventoryDigest("),
                    "\(door) asks nothing: a departure is not a merge exchange")
            #expect(!body.contains("sendRoutedInventory("),
                    "\(door) asks nothing: a departure is not a merge exchange")
            #expect(body.components(separatedBy: "sendRoutedBulk(").count - 1 == 1,
                    "\(door) moves bytes through the one extracted sender")
        }
        for door in Self.originationDoors {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            #expect(!body.contains("sendInventoryDigest("),
                    "\(door) asks nothing: an origination is not a merge exchange")
            #expect(!body.contains("sendRoutedInventory("),
                    "\(door) asks nothing: an advertisement would ask the PEER to push to us")
            #expect(!body.contains("recordRoutedAdvertisement("),
                    "\(door) records nothing: recording would unbind an open exchange's answer")
            #expect(body.components(separatedBy: "sendRoutedBulk(").count - 1 == 1,
                    "\(door) moves bytes through the one extracted sender")
        }
    }

    /// The **fourth** door class, added by P5 item 13: the origination push. Like item 8's hand-off
    /// it is neither an ask door nor a non-ask membership door — it opens no exchange, sends no
    /// digest of either kind and records no advertisement — and it is the only routed send that
    /// fires on a USER ACTION rather than on a link opening, which is exactly why it must not touch
    /// the advertisement binding an open merge exchange is waiting on.
    private static let originationDoors = ["private func pushOriginatedItem("]

    /// The **third** door class, added by P5 item 8: the one-moment hand-off. It is neither an ask
    /// door (it opens no exchange and sends no digest of either kind) nor a non-ask membership door
    /// (it carries routed bulk, which those may never do), so it needs its own row rather than a
    /// count that would stay green by accident. Increment 1 has exactly one of them.
    private static let handoffDoors = ["private func pushCustodyToCustodians("]

    /// The two doors that send a membership digest WITHOUT opening an exchange: the post-merge proof
    /// (P5 item 7, D-7.8) and the joiner's post-adoption digest (D-7.33).
    private static let nonAskDoors = [
        "private func readvertiseMergeProof(to peers:",
        "private func attemptLedgerAdoption(ownAdmission:"
    ]

    /// The three doors that open an exchange, and therefore carry both halves of it.
    private static let askDoors = [
        "private func beginMergeExchange(entry:",
        "private func askOneReconnectedPeer(_ peer:",
        "private func handleAdmissionGrant("
    ]

    /// **P5 item 7's own asymmetries, asserted from both sides.** The merge window is cleared at its
    /// three sites and nowhere else; the drain's per-peer budget is still refunded by the three
    /// session resets and still **not** by `abandonMergeExchange`; the membership re-gossip
    /// budget is not refunded by a flap either (D-7.30) — a flapping link must not let a peer
    /// re-spend this device's bytes; and **`pendingMergeEntry` is not folded into the window's
    /// clear** (D-7.23/D-7.29), which is the asymmetry `clearMergeWindow()`'s own doc comment
    /// claims and this is the wall that makes the claim true. Folding `pendingMergeEntry = nil`
    /// into either `clearMergeWindow()` or `resetSessionStateMachine` would silently destroy the
    /// launch restore's `.processRestart` arming, which is set with no window at all.
    @Test func theMergeWindowIsClearedAtExactlyItsOwnSites() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let cleared = "clearMergeWindow()"
        #expect(source.components(separatedBy: cleared).count - 1 == 4,
                "one declaration plus three call sites")
        for declaration in [
            "private func concludeMergeIfConverged() {",
            "private func abandonMergeExchange() {",
            "private func resetSessionStateMachine(keepingTerminalState: Bool) {"
        ] {
            let body = try #require(Self.functionBody(declaration, in: source),
                                    "\(declaration) is gone from MeshNetworkManager.swift")
            #expect(body.components(separatedBy: cleared).count - 1 == 1,
                    "\(declaration) must clear the merge window exactly once")
        }
        let abandon = try #require(
            Self.functionBody("private func abandonMergeExchange() {", in: source)
        )
        #expect(!abandon.contains("clearRoutedDrainState()"),
                "a partition is not a new session: the drain's budget is not refunded")
        #expect(!abandon.contains("reGossipedToFingerprints"),
                "and neither is the membership re-gossip budget (D-7.30)")
        for declaration in [
            "private func clearMergeWindow() {",
            "private func resetSessionStateMachine(keepingTerminalState: Bool) {"
        ] {
            let body = try #require(Self.functionBody(declaration, in: source),
                                    "\(declaration) is gone from MeshNetworkManager.swift")
            #expect(!body.contains("pendingMergeEntry"),
                    "\(declaration) must not fold in the pre-window arming slot (D-7.23/D-7.29)")
        }
    }

    /// **The reach set is a transport fact, not a traffic class.** `reachableMergePeers()` reads
    /// every committed slot, never `activeSlots` and never the `activeSlots`-based
    /// `reachableRosterFingerprints()`, which is the obvious wrong reuse.
    ///
    /// Only a source wall can catch this: `rerankSlots()` re-assigns a slot's `kind` from ranging
    /// samples that `FakePeerNetwork` never produces, so the demotion half of the bug is invisible
    /// to tier 1 — a demoted-but-linked peer would silently leave the pending set and 2d would
    /// return, triggered by a distance sample with no membership meaning.
    @Test func theMergeWindowsReachSetIsEveryCommittedSlot() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let reach = try #require(
            Self.functionBody("private func reachableMergePeers() -> Set<String> {", in: source)
        )
        #expect(reach.contains("slots.compactMap"), "every committed slot is the reach set")
        #expect(!reach.contains("activeSlots"), "`.active` is a distance rank, not a reach")
        #expect(!reach.contains("reachableRosterFingerprints"), "and neither is the partition helper")
        for declaration in [
            "private func concludeMergeIfConverged() {",
            "private func clearMergeWindow() {",
            "private func recordMergeMatch(_ peer: String) {",
            "private func recordMergeAnswer(_ peer: String) {",
            "private func advanceMergeWindowAfterFold(previousDigest: MeshInventoryDigest?) {",
            "private func readvertiseMergeProof(to peers: Set<String>) {"
        ] {
            let body = try #require(Self.functionBody(declaration, in: source),
                                    "\(declaration) is gone from MeshNetworkManager.swift")
            #expect(!body.contains(".active"), "\(declaration) must not read a slot rank")
            #expect(!body.contains("kind"), "\(declaration) must not read a slot kind")
        }
    }

    /// One function's body found from a declaration **prefix**, brace-matched from the first `{`
    /// after it — so a declaration whose parameters wrap onto several lines can still be named.
    ///
    /// - Parameters:
    ///   - prefix: The declaration's opening text, unique in the file.
    ///   - source: The source to search.
    /// - Returns: The body, or nil when the declaration is gone.
    private static func body(startingWith prefix: String, in source: String) -> String? {
        guard let start = source.range(of: prefix),
              let open = source.range(of: "{", range: start.upperBound..<source.endIndex)
        else { return nil }
        return functionBody(String(source[start.lowerBound..<open.upperBound]), in: source)
    }

    /// The drain state is refunded by the three session resets and by nothing else — not by
    /// `abandonMergeExchange`, where a flapping link would re-spend this device's bytes on every flap.
    ///
    /// Asserted per SITE rather than by counting: a count of four is satisfied by three calls in the
    /// wrong three functions, and `abandonMergeExchange` is exactly the function the count cannot
    /// speak about.
    @Test func theDrainStateIsClearedAtExactlyThreeSites() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let cleared = "clearRoutedDrainState()"
        #expect(source.components(separatedBy: cleared).count - 1 == 4,
                "one declaration plus three call sites")
        for declaration in [
            "public func leaveMesh() {",
            "func prepareMembershipLedger(meshID: UUID, founderSigningPublicKey: Data?, now: Date = Date()) {",
            "func armJoinerLedger(_ grant: MeshAdmissionGrantPayload, now: Date = Date()) -> Bool {"
        ] {
            guard let body = Self.functionBody(declaration, in: source) else {
                Issue.record("\(declaration) is gone from MeshNetworkManager.swift")
                continue
            }
            #expect(body.components(separatedBy: cleared).count - 1 == 1,
                    "\(declaration) must clear the drain state exactly once")
        }
        let abandon = try #require(
            Self.functionBody("private func abandonMergeExchange() {", in: source)
        )
        #expect(abandon.contains(cleared) == false,
                "a partition is not a new session: abandonMergeExchange must refund nothing")
    }

    /// One function's body, by brace matching from its declaration — so a wall can say WHICH
    /// function holds a call rather than only how many the file holds.
    private static func functionBody(_ declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        var depth = 1
        var index = start.upperBound
        var scanned = 0
        // R2: bounded by the file's own length.
        while index < source.endIndex, scanned < source.count {
            scanned += 1
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// **W1 — the retired gates are gone and the survivors are pinned by count** (P5 item 13).
    ///
    /// A pin table, not a zero list, and the difference is the whole design. Two of the three
    /// `keyEpoch` gates retired WITH the path that made them necessary and are pinned at zero. The
    /// third — `handleEncryptedMetadata`'s compare — is deliberately RETAINED: its two content arms
    /// retired, but its door survives with two control arms that have no routed successor, and
    /// deleting the compare over those would be loosening a gate in place, which is the one move the
    /// wall forbids. `decryptPayload` authenticates the metadata purpose alone, so a wrapper sealed
    /// under the current key but stamped with a foreign epoch would otherwise open and dispatch;
    /// `MeshEncryptionTests.aCurrentKeyWrapperStampedWithAForeignEpochIsRefused` is that case.
    ///
    /// The surviving `keyEpoch` occurrences are named line by line so a new one has to move a
    /// number rather than hide in a total: `sanitizedIncomingPhoto`'s legacy-shape check
    /// (`payload.keyEpoch > 0`) and its re-mint (the `keyEpoch:` label plus `payload.keyEpoch`, two
    /// occurrences on one line), and the retained compare. `currentKeyEpoch` spells `KeyEpoch` and
    /// does not match. `localJoinedEpoch` stands at seven: its declaration, two resets, the grant's
    /// monotonicity compare, two assignments and the rotation fallback — the control plane, which
    /// item 13 never touched.
    ///
    /// A zero list was tried first and could not pass: `.keyEpoch >` is literally contained in
    /// `payload.keyEpoch > 0`, so the wall would have gone red on its own commit and the obvious
    /// green-making move — widening the exemption — would quietly re-admit
    /// `if x.keyEpoch > localJoinedEpoch` anywhere in the manager.
    @Test func theRetiredEpochGatesAreGoneAndTheSurvivorsArePinned() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let pins: [(needle: String, pinned: Int)] = [
            ("key.epoch == photo.keyEpoch", 0),
            ("keyEpoch >= localJoinedEpoch", 0),
            ("manifestAnnouncedPhotoAuthors", 0),
            ("wrapper.keyEpoch == currentGroupKey?.epoch", 1),
            ("keyEpoch", 4),
            ("localJoinedEpoch", 7)
        ]
        // R2: six needles over one file.
        for pin in pins {
            let found = source.components(separatedBy: pin.needle).count - 1
            #expect(found == pin.pinned,
                    "\(pin.needle) stands at \(found), pinned at \(pin.pinned)")
        }
    }

    /// **W2 — the retired photo transport is gone**, symbol by symbol (P5 item 13).
    ///
    /// Eleven names, one flow: the group-key photo decrypt and its author claim, the manifest pull
    /// and its request answer, the closed-mode metadata SEAL half whose only two call sites were
    /// that pull, and the two public statics that sealed and opened a photo under the group key.
    /// A count is not enough here — a re-introduction under any of these names is the regression —
    /// so each is pinned at zero by name.
    @Test func theRetiredPhotoTransportIsGone() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let retired = [
            "handleFriendPhotoEnvelope", "decryptedIncomingPhoto", "dispatchPhotoPayload",
            "photoAuthorIsAcceptable", "handlePhotoManifest", "syncPhotoManifest",
            "sendRequestedPhotos", "sendEncryptedMetadata", "encryptPhoto", "decryptPhoto",
            "encryptPayload",
            // The legacy per-sender RECEIVE quota and the two fields that served it. Its routed
            // twin `allowIncomingRoutedPhoto` keys on the ITEM's mesh (D-13.23) where this one
            // keyed on the live one, so a re-introduction would put two per-sender quotas with
            // opposite mesh-keying in one file with nothing saying which is live.
            "allowIncomingPhoto", "receivedPhotoIDsByFingerprint", "receiveQuotaMeshID"
        ]
        var scanned = 0
        // R2: fourteen names over one file.
        for symbol in retired {
            scanned += 1
            #expect(!source.contains(symbol), "\(symbol) came back to MeshNetworkManager.swift")
        }
        #expect(scanned == retired.count, "the retired-transport scan lost a symbol")
    }

    /// **Item 13's precondition, still green after item 13.** The routed section names no epoch,
    /// group key, branch or partition symbol — and it now carries the sender door, the projection
    /// and the re-entry projection pass, so the claim is about real content code rather than about
    /// plumbing with nothing to gate: the routed path's authorisation is the origin's signature plus the per-recipient key
    /// wrap, which is what lets item 13 delete the three `keyEpoch` gates rather than loosen them.
    @Test func theRoutedPathNamesNoEpochSymbol() throws {
        let source = try managerSource()
        guard let start = source.range(of: "// MARK: - Routed drain (network migration P5 item 6") else {
            Issue.record("the routed drain section is gone from MeshNetworkManager.swift")
            return
        }
        let rest = String(source[start.upperBound...])
        let body = rest.range(of: "// MARK: -").map { String(rest[..<$0.lowerBound]) } ?? rest
        let section = MeshRoutedSourceScan.codeOnly(body)
        #expect(section.count > 5_000, "the routed drain section is suspiciously short")
        for forbidden in ["keyEpoch", "currentGroupKey", "branchView", "partition"] {
            #expect(section.contains(forbidden) == false, "the routed drain names a forbidden symbol")
        }
    }

    // MARK: - P5 item 12: the replay window, wired

    /// The four routed CONTENT doors, by declaration prefix — the only four the window is wired at.
    private static let contentDoors = [
        "private func ingestRoutedManifest(",
        "private func ingestRoutedChunk(",
        "private func ingestCustodyReceipt(",
        "private func ingestRecipientReceipt("
    ]

    /// The two DIGEST doors, which are deliberately outside the window (D-5.12, D-6.10).
    private static let digestDoors = [
        "func receiveRoutedInventory(",
        "private func receiveRoutedDrainAnswer("
    ]

    /// **W1 — the window is wired at every routed content door, and nowhere else.**
    ///
    /// Per door, so a count of four satisfied by four calls in the wrong four functions fails; and
    /// manager-wide, so a fifth call site anywhere in the ~10 400-line file — including inside a
    /// helper a digest door reaches, which the per-door half cannot see — fails here rather than in
    /// the field. Five of each: four call sites plus one declaration.
    @Test func theReplayWindowIsWiredAtEveryRoutedContentDoor() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        for door in Self.contentDoors {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            #expect(body.components(separatedBy: "routedFrameIsReplayed(").count - 1 == 1,
                    "\(door) probes the replay window exactly once")
            #expect(body.components(separatedBy: "noteRoutedFrame(").count - 1 == 1,
                    "\(door) records into the replay window exactly once")
        }
        #expect(source.components(separatedBy: "routedFrameIsReplayed").count - 1 == 5,
                "one declaration plus exactly the four content doors")
        #expect(source.components(separatedBy: "noteRoutedFrame").count - 1 == 5,
                "one declaration plus exactly the four content doors")
    }

    /// **W2 — the probe precedes the verifier AND the first store read**, which is the whole point:
    /// a replayed frame must be refused before the signature work and before any sealed-index load.
    @Test func theReplayProbePrecedesTheVerifierAndTheStore() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        for door in Self.contentDoors {
            let body = try #require(Self.body(startingWith: door, in: source))
            let probe = try #require(body.range(of: "routedFrameIsReplayed("),
                                     "\(door) does not probe the window at all")
            let expensive = ["Verifier(", "routedStore(", "store."]
                .compactMap { body.range(of: $0)?.lowerBound }
            #expect(expensive.isEmpty == false, "\(door) reads neither a verifier nor the store?")
            for offset in expensive {
                #expect(probe.lowerBound < offset,
                        "\(door) pays for a verify or a store read before the replay probe")
            }
        }
    }

    /// **W3 — the digest family is not admitted** (D-5.12: an inventory digest's replay defence is
    /// its slot binding and the per-peer frame budget, never a freshness check; D-6.10: a drain
    /// answer is already bound to advertiser + `advertisedAt`). W1's manager-wide count is what
    /// closes the helper-shaped escape from this one.
    @Test func theDigestFamilyIsNotAdmittedToTheWindow() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        for door in Self.digestDoors {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            #expect(!body.contains("routedFrameIsReplayed("), "\(door) must not probe the window")
            #expect(!body.contains("noteRoutedFrame("), "\(door) must not record into the window")
        }
    }

    /// **W4 — cleared at the session resets and nowhere else.** Clearing on a partition flap would
    /// hand an attacker the eviction primitive the window refuses to offer (D-6.6's argument, only
    /// stronger here).
    @Test func theReplayWindowIsClearedOnlyAtTheSessionResets() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let cleared = "routedReplayWindow = nil"
        #expect(source.components(separatedBy: cleared).count - 1 == 1,
                "the window is cleared at exactly one place in the manager")
        let clear = try #require(
            Self.functionBody("private func clearRoutedDrainState() {", in: source)
        )
        #expect(clear.contains(cleared), "and that place is the three session resets' one helper")
        let abandon = try #require(
            Self.functionBody("private func abandonMergeExchange() {", in: source)
        )
        #expect(!abandon.contains(cleared), "a partition is not a new session")
        #expect(!abandon.contains("forget("), "and a flap is not an eviction primitive either")
    }

    /// **W5 — the frame axis is DERIVED, and carries a maximal item.** Aimed at the property rather
    /// than the call, because the call can only name the property: the testing override lives there.
    @Test func theRoutedReplayFrameBoundIsDerived() throws {
        #expect(MeshRoutedDrainBounds.sessionFramesPerPeer >= MeshChunkFormat.maxChunkCount + 1,
                "the routed replay window must hold a maximal item's chunks plus its manifest")
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let capacity = try #require(
            Self.body(startingWith: "private var routedReplayCapacity: Int", in: source),
            "routedReplayCapacity is gone from MeshNetworkManager.swift"
        )
        #expect(capacity.contains("MeshRoutedDrainBounds.sessionFramesPerPeer"),
                "the frame cap must be derived from the session budget it mirrors")
        #expect(capacity.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) == nil,
                "a literal here is a second, undocumented bound")
        let arguments = MeshSessionStoreIsolationTests.constructionArguments(
            of: "MeshFrameReplayWindow(", in: source
        )
        #expect(arguments.count == 1, "the manager builds exactly one replay window")
        #expect(arguments.first?.contains("framesPerSender: routedReplayCapacity") == true,
                "the construction must take the derived capacity, not a literal")
    }

    /// **W6 — the routed window never forgets an AUTHOR.** A departed origin's content is exactly
    /// what a custodian keeps forwarding after a departure hand-off, so releasing that axis would
    /// hand an attacker a free replay of the content custody transfer exists to keep moving.
    /// `forget(frameID:from:)` — the repaired-slot un-record — is a different verb and is permitted.
    @Test func theRoutedWindowNeverForgetsASender() throws {
        let section = try #require(Self.routedSection(in: try managerSource()))
        #expect(section.contains("forget(senderFingerprint:") == false,
                "the routed path must never release an author's axis")
        #expect(section.contains("forget("), "and it must still un-record a repaired slot")
    }

    /// **W7 — the author axis is the ADMISSION cap, not the roster cap.** Every routed verifier
    /// resolves its author's key from the admission set, whose capacity is `maxRecordsPerKind`; a
    /// departed origin is not a roster member at all, so at the roster cap the ninth author's every
    /// frame would answer `senderWindowFull` and never be caught on repeat.
    @Test func theRoutedReplayAuthorBoundIsTheAdmissionCap() throws {
        #expect(MeshMembershipBounds.maxRecordsPerKind >= MeshMembershipBounds.maxRosterMembers,
                "the admission set is the wider population, and the window is sized on it")
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let arguments = MeshSessionStoreIsolationTests.constructionArguments(
            of: "MeshFrameReplayWindow(", in: source
        )
        #expect(arguments.first?.contains("maxSenders: MeshMembershipBounds.maxRecordsPerKind") == true,
                "the author cap must name the admission-set bound, never a literal or the roster cap")
    }

    /// **W8 — item 8's hop bound survives a replayed manifest.** The probe is sender-blind, so the
    /// `originServedItems` write runs on the replayed path too; without it a courier's copy followed
    /// by the origin's own would strand that leg at the origin's next departure.
    @Test func theHopBoundSurvivesAReplayedManifest() throws {
        let source = MeshRoutedSourceScan.codeOnly(try managerSource())
        let door = try #require(
            Self.body(startingWith: "private func ingestRoutedManifest(", in: source)
        )
        #expect(door.components(separatedBy: "noteOriginServed(").count - 1 == 2,
                "the replayed path and the admitted path each write the hop bound")
        let first = try #require(door.range(of: "noteOriginServed("))
        let admitting = try #require(door.range(of: "admittingManifest("))
        #expect(first.lowerBound < admitting.lowerBound,
                "the replayed path's write must come first — it is the early return's own line")
    }

    /// The routed drain section's own source, sliced exactly as `theRoutedPathNamesNoEpochSymbol`
    /// slices it, with whole-line comments removed.
    private static func routedSection(in source: String) -> String? {
        guard let start = source.range(of: "// MARK: - Routed drain (network migration P5 item 6")
        else { return nil }
        let rest = String(source[start.upperBound...])
        let body = rest.range(of: "// MARK: -").map { String(rest[..<$0.lowerBound]) } ?? rest
        return MeshRoutedSourceScan.codeOnly(body)
    }

    /// Every routed store site in the manager names an explicit scope — the host's, never the
    /// production one.
    ///
    /// The forbidden spelling is assembled at run time on purpose: `MeshRoutedStoreIsolationTests`
    /// greps every test source for it, so writing it as a literal here would fail that wall from
    /// inside the test that exists to enforce the same rule.
    @Test func theDrainNamesItsStoreScopeExplicitly() throws {
        let source = try managerSource()
        let production = "MeshRoutedStorageScope" + "." + "production"
        #expect(source.contains("MeshRoutedStore(scope: store.meshRoutedStorage)"))
        #expect(source.contains(production) == false)
    }
}
