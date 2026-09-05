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
// - **One time anchor.** `MeshP3Acceptance.base` (1.8e9), with `hardDeadline` derived from
//   `MeshSessionCeiling.ceilingSeconds` — never `MeshRoutedManifestFixtures.hardDeadline` (1.7e9).
//   The manifest verifier demands `expiresAt == floor(hardDeadline) + grace` exactly, so getting
//   this wrong looks like a signing bug.
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

    /// The mesh's signed creation instant. Every routed instant derives from it.
    static let createdAt = MeshP3Acceptance.base

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
                node, ledger: ledger, founderKey: founder.localSigningPublicKey, meshID: meshID
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
    func dispatch(
        _ payload: some Encodable,
        type: PayloadType,
        sender: Int,
        receiver: Int,
        now: Date? = nil,
        binding: DeviceBindingID.TestOverride? = nil
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
        let slot = node.manager.slots.first { $0.coordinator === coordinator }
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
    @Test func aReSentChunkIsLoggedAsADuplicateNotAnAdmission() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "drain-verdict")
        defer { rig.teardown() }
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
        #expect(source.components(separatedBy: "sendRoutedBulk(").count - 1 == 3,
                "one declaration plus exactly two call sites: the drain answer and the hand-off push")
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
    }

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

    /// **Item 13's precondition.** The routed section names no epoch, group key, branch or partition
    /// symbol: the routed path's authorisation is the origin's signature plus the per-recipient key
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

    /// **Item 12 inherits a clean seam.** The replay window is still unwired: item 6 adds no property
    /// and calls `admit(…)` nowhere.
    @Test func theReplayWindowIsStillUnwired() throws {
        #expect(try managerSource().contains("MeshFrameReplayWindow") == false)
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
