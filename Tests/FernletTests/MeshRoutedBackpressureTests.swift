// MeshRoutedBackpressureTests.swift
// FernletTests
//
// Network migration P5 item 9 (plan §11): the MANAGER half — a capacity refusal made visible and
// bounded, the parked-set drop rule at the door that raises it, the sweeps that finally have
// callers, and the app-side copy the hold resolves to.
//
// Tier 1 only, on item 6's existing `MeshRoutedDrainRig` — never a parallel rig. The three fixture
// facts that file states apply verbatim: one pinned install binding (`MeshP3Acceptance.install`), one
// time anchor (`MeshRoutedDrainRig.createdAt` — exactly 1.8e9 until 2026-12-16, a month before
// that instant falls due, and the wall clock plus that month from the crossover on (item 6a); it
// is also the anchor the development instants below take), and joiner-shaped nodes with no session
// ceiling.
//
// **The expiry trap, which is not hypothetical.** `MeshRoutedStoreFixtures.record()` stamps the
// manifest fixtures' anchor (1.7e9), which is already past at this rig's `now` — so a planted hog
// would be freed by item 9's own expiry sweep before the refusal it was planted to cause. Every
// planted record here therefore passes `MeshRoutedDrainRig.expiry` explicitly, except the two cells
// whose whole claim IS that an expired record is swept.

import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

extension MeshRoutedDrainRig {

    /// The expiry every planted record on this rig must carry — the manifest verifier's own
    /// derivation, so a planted record is live at ``MeshRoutedDrainRig/now``.
    static var expiry: Date { MeshRoutedManifest.expiry(afterHardDeadline: hardDeadline) }

    /// Plants records straight into one node's routed store under the rig's pinned install binding.
    func plant(_ records: [MeshRoutedItemRecord], at node: Int) throws {
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: records),
            into: routedStore(nodes[node]),
            install: MeshP3Acceptance.install
        )
    }

    /// A single planted record that spends the whole byte budget — the cheapest possible full store
    /// (`everyCapRefusesByItsOwnName`'s trick: one descriptor, no sealing at all).
    func plantByteHog(at node: Int, expiresAt: Date? = nil) throws {
        try plant(
            [MeshRoutedStoreFixtures.record(
                chunks: [MeshRoutedStoreFixtures.descriptor(
                    index: 0, count: 1, bytes: Int(MeshRoutedStoreFormat.maxContentBytes)
                )],
                expiresAt: expiresAt ?? Self.expiry
            )],
            at: node
        )
    }

    /// Sends one node's signed routed inventory to another — the frame that opens the drain exchange
    /// and, since P5 item 9, spends that peer's one capacity sweep for the session.
    func advertiseInventory(from sender: Int, to receiver: Int, now: Date? = nil) async throws {
        let at = now ?? Self.now
        let index = routedIndex(nodes[sender]) ?? MeshRoutedIndex()
        let payload = try MeshRoutedInventoryPayload.signed(
            meshID: meshID, index: index, sentAt: at, identity: identities[sender]
        )
        try await deliver(
            payload, type: .meshRoutedInventoryDigest, sender: sender, receiver: receiver, now: at
        )
    }
}

/// Captures audit lines for one cell — `MeshRoutedDrainTests`' capture, which is file-private there.
final class MeshRoutedBackpressureAuditCapture {
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

    /// Every value logged under `key` for `event`, in order.
    func values(of event: String, key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == event }.map { $0.context[key] ?? "missing" }
    }

    /// How many times `event` was logged.
    func count(of event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == event }.count
    }
}

// MARK: - The visible refusal

/// A capacity refusal, end to end: refused by name, remembered, published as counts, and readable as
/// copy — with nothing lost at the origin.
@MainActor
@Suite(.serialized)
struct MeshRoutedBackpressureTests {

    /// **The item's whole claim in one cell.** Node 1's store is full; node 0 drains one real signed
    /// manifest at it. The refusal is named, remembered, bounded and VISIBLE, and the origin still
    /// holds the item and still owes node 1 — custody outstanding, nothing lost.
    @Test func aCapacityRefusalIsVisibleAndBounded() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-visible")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        try rig.plantByteHog(at: 1)
        rig.link(0, 1)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )

        let manager = rig.nodes[1].manager
        // Containment, never an exact list: `FernletAuditLog` is process-global and suites run in
        // parallel, so a sibling suite's line would otherwise fail this cell (D-8.31).
        #expect(capture.values(of: "mesh.routedDrain.refused", key: "reason")
                .contains(MeshRoutedStoreRefusal.capacityBytes.rawValue),
                "the store refused by name")
        let note = try #require(manager.lastRoutedDrainRefusal, "the diagnostic seam stayed nil")
        #expect(note.peerFingerprint == rig.nodes[0].fingerprint)
        #expect(note.reason == MeshRoutedStoreRefusal.capacityBytes.rawValue)
        let hold = try #require(manager.routedDeliveryHold, "the refusal reached no visible surface")
        #expect(hold.cause == .storeFull)
        #expect(hold.itemCount == 1)
        #expect(RoutedDeliveryHoldCopy.detail(.storeFull, count: hold.itemCount) != nil)
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) == nil, "nothing was written")

        // The same key again is one item, not two: the held-back set is a set.
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        #expect(manager.routedDeliveryHold?.itemCount == 1)

        // Nothing was lost at the origin: no custody receipt came back, and node 1 is still owed.
        let origin = try #require(rig.routedIndex(rig.nodes[0])?.record(for: item.key))
        #expect(origin.receipts.isEmpty, "a refusal is not a custody receipt")
        let roster = try #require(rig.nodes[0].manager.membershipVerifier?.roster)
        #expect(rig.routedIndex(rig.nodes[0])?
            .outstandingDestinations(for: item.key, in: roster) == [rig.nodes[1].fingerprint])
    }

    /// The heal hangs on the fact that means "the content is here", never on "the door ran".
    @Test func anAdmittedItemClearsItsHeldBackEntryOnlyWhenItLands() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-heal")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        try rig.plantByteHog(at: 1)
        rig.link(0, 1)
        let manager = rig.nodes[1].manager

        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        #expect(manager.routedDeliveryHold?.cause == .storeFull)

        // Make room, then let the item actually land.
        try rig.plant([], at: 1)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        for chunk in item.chunks {
            try await rig.deliver(
                MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 0, receiver: 1
            )
        }
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isComplete == true)
        #expect(manager.routedDeliveryHold == nil, "the key landed, so the hold fell away")

        // The negative half: a DUPLICATE chunk means only "the door ran" and heals nothing.
        manager.noteRoutedHeldBack(
            MeshRoutedItemKey(originFingerprint: "fp001", itemID: UUID()), at: MeshRoutedDrainRig.now
        )
        let before = try #require(manager.routedDeliveryHold)
        let first = try #require(item.chunks.first)
        try await rig.deliver(
            MeshChunkPayload(chunk: first), type: .meshRoutedChunk, sender: 0, receiver: 1
        )
        #expect(manager.routedDeliveryHold == before, "a duplicate is not a landing")
    }

    /// A store that cannot say what it holds is NOT "full": the non-loaded states stay distinct, and
    /// nothing sweeps while one of them is the answer (item 10's precondition).
    @Test func aStoreThatCannotSayWhatItHoldsIsNotAHold() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-corrupt")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        let store = rig.routedStore(rig.nodes[1])
        try MeshRoutedStoreFixtures.writeRaw(Data(repeating: 0x5A, count: 96), into: store)
        let sealed = try Data(contentsOf: store.indexURL)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        try await rig.advertiseInventory(from: 0, to: 1)

        let manager = rig.nodes[1].manager
        #expect(manager.routedDeliveryHold == nil, "corrupt is not full")
        #expect(manager.lastRoutedDrainRefusal == nil, "corrupt is not a refusal either")
        #expect(capture.values(of: "mesh.routedDrain.unavailable", key: "state").isEmpty == false,
                "the state was named")
        #expect(try Data(contentsOf: store.indexURL) == sealed,
                "nothing sweeps, repairs or quarantines a store it cannot read")
    }

    /// D-9.8(a): the hold outlives the session that produced it — the Friends tab is where it is
    /// read — and a NEW ledger is what replaces the fact.
    @Test func theHoldSurvivesLeaveMeshAndClearsOnANewLedger() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-clearing")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        try rig.plantByteHog(at: 1)
        rig.link(0, 1)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        let manager = rig.nodes[1].manager
        #expect(manager.routedDeliveryHold?.cause == .storeFull)

        manager.leaveMesh()
        #expect(manager.routedDeliveryHold?.cause == .storeFull,
                "leaving the session must not erase the message at the moment it can be read")

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.prepareMembershipLedger(
                meshID: UUID(), founderSigningPublicKey: nil, now: MeshRoutedDrainRig.now
            )
        }
        #expect(manager.routedDeliveryHold == nil, "a different mesh replaces the fact")
    }

    /// D-9.8(b), the release rule: the sweep frees the store at the drain-exchange entry and the hold
    /// falls away — a surface that keeps asserting a condition the store has escaped is the same
    /// defect as an invisible refusal.
    @Test func theHoldClearsWhenTheSweepFreesTheStore() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-release")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        // The hog is already past its own expiry at this rig's `now`: full at the door, collectable
        // at the sweep.
        try rig.plantByteHog(at: 1, expiresAt: MeshRoutedManifestFixtures.expiresAt)
        rig.link(0, 1)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        let manager = rig.nodes[1].manager
        #expect(manager.routedDeliveryHold?.cause == .storeFull)

        try await rig.advertiseInventory(from: 0, to: 1)

        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 0, "the expired hog was collected")
        #expect(manager.routedDeliveryHold == nil, "the hold was released, not merely left standing")
        #expect(manager.lastRoutedDrainRefusal != nil,
                "the refusal itself is NOT refunded — only the visible condition is released")
    }

    /// The Friends-tab seam: the banner's own screen corrects a hold whose condition has expired,
    /// through the PUBLIC join entry — never a test hook.
    @Test func theFriendsScreenSeamClearsAnExpiredHold() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-search")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        try rig.plantByteHog(at: 1, expiresAt: MeshRoutedManifestFixtures.expiresAt)
        rig.link(0, 1)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        let manager = rig.nodes[1].manager
        #expect(manager.routedDeliveryHold?.cause == .storeFull)

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.startJoin()
        }
        manager.stopJoin()

        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 0)
        #expect(manager.routedDeliveryHold == nil)
    }

    /// The reclaim: bounded per call by an EXISTING constant, and budgeted once per peer per session
    /// in the re-gossip idiom, so the cost is roster-bounded rather than per advertisement.
    @Test func theSweepRunsOncePerPeerPerSessionAndIsBounded() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-sweep")
        defer { rig.teardown() }
        rig.link(0, 1)
        let delivered = MeshDeliveryStateToken.delivered.rawValue
        let courierCopies = (0..<20).map { _ -> MeshRoutedItemRecord in
            let manifest = MeshRoutedCapacityFixtures.manifest(
                for: [rig.nodes[0].fingerprint], expiresAt: MeshRoutedDrainRig.expiry
            )
            return MeshRoutedCapacityFixtures.delivered(
                manifest, to: [rig.nodes[0].fingerprint: delivered]
            )
        }
        try rig.plant(courierCopies, at: 1)
        let batch = MeshRoutedDrainBounds.increment1.maxItems

        try await rig.advertiseInventory(from: 0, to: 1)
        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 20 - batch,
                "one answer reclaims exactly the increment's item allowance")

        try await rig.advertiseInventory(from: 0, to: 1)
        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 20 - batch,
                "the same peer's next advertisement spends no second sweep this session")
    }

    /// The budget is spent only once the store has ANSWERED: an exchange with an unreadable store did
    /// no work, so it must not strand that peer's one reclaim — and its hold release — for the rest
    /// of the session. On a two-node mesh that is the whole session.
    @Test func aStoreThatCouldNotAnswerKeepsItsSweepBudget() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-budget")
        defer { rig.teardown() }
        rig.link(0, 1)
        try MeshRoutedStoreFixtures.writeRaw(
            Data(repeating: 0x5A, count: 96), into: rig.routedStore(rig.nodes[1])
        )

        try await rig.advertiseInventory(from: 0, to: 1)
        #expect(rig.routedIndex(rig.nodes[1]) == nil, "the store is unreadable, so nothing was swept")

        // The store is readable again — a device unlocked, an index rewritten — and the SAME peer
        // advertises again.
        let delivered = MeshDeliveryStateToken.delivered.rawValue
        let courierCopies = (0..<2).map { _ -> MeshRoutedItemRecord in
            let manifest = MeshRoutedCapacityFixtures.manifest(
                for: [rig.nodes[0].fingerprint], expiresAt: MeshRoutedDrainRig.expiry
            )
            return MeshRoutedCapacityFixtures.delivered(
                manifest, to: [rig.nodes[0].fingerprint: delivered]
            )
        }
        try rig.plant(courierCopies, at: 1)
        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 2, "the repair landed")

        try await rig.advertiseInventory(from: 0, to: 1)
        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 0,
                "the exchange that did no work must not have spent this peer's one sweep")
    }

    /// The file cap's recovery route: orphan payload files — the ones every drop verb can leave
    /// behind, because it saves the index before it unlinks — are collected at the same budgeted
    /// seam, and the hold they were holding up falls away.
    @Test func orphanChunkFilesAreCollectedAtTheSweep() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-orphan")
        defer { rig.teardown() }
        rig.link(0, 1)
        let store = rig.routedStore(rig.nodes[1])
        try rig.plant([], at: 1)
        try FileManager.default.createDirectory(
            at: store.chunkDirectory, withIntermediateDirectories: true
        )
        // R2: a hard constant ceiling.
        for _ in 0..<3 {
            try Data([0x01]).write(to: store.chunkFileURL(named: MeshRoutedStore.newChunkFileName()))
        }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await rig.advertiseInventory(from: 0, to: 1)

        #expect(store.chunkDirectoryFileNames()?.isEmpty == true,
                "files the index does not name are the one thing no other sweep can free")
        #expect(capture.values(of: "mesh.routedStore.swept", key: "reason").contains("orphan"),
                "a removal with no audit line is the violation")
    }

    /// D-9.7: the silent over-commit, made visible. Two admitted items neither of which can finish —
    /// no refusal, nothing dropped, and the condition NAMED.
    @Test func anOverCommittedStoreHoldsWithoutRefusing() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-overcommit")
        defer { rig.teardown() }
        rig.link(0, 1)
        let bigger = MeshRoutedStoreFormat.maxContentBytes / 2 + 1_048_576
        let admitted = (0..<2).map { _ -> MeshRoutedItemRecord in
            MeshRoutedCapacityFixtures.delivered(
                MeshRoutedCapacityFixtures.manifest(
                    for: [rig.nodes[0].fingerprint], size: bigger,
                    expiresAt: MeshRoutedDrainRig.expiry
                ),
                to: [:]
            )
        }
        try rig.plant(admitted, at: 1)

        try await rig.advertiseInventory(from: 0, to: 1)

        let manager = rig.nodes[1].manager
        #expect(rig.routedIndex(rig.nodes[1])?.itemCount == 2, "nothing was refused and nothing dropped")
        #expect(manager.lastRoutedDrainRefusal == nil)
        let hold = try #require(manager.routedDeliveryHold, "an over-commit that says nothing is the violation")
        #expect(hold.cause == .storeFull)
        #expect(hold.itemCount == 2)
    }

    /// The held-back set NAMES its own bound rather than passing it in silence, and the published
    /// count saturates rather than lying.
    @Test func theHeldBackSetNamesItsOwnBound() throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "backpressure-bound")
        defer { rig.teardown() }
        let manager = rig.nodes[0].manager
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        // R2: a hard constant ceiling — the store's own item cap, plus one.
        for _ in 0...MeshRoutedStoreFormat.maxItems {
            manager.noteRoutedHeldBack(
                MeshRoutedItemKey(originFingerprint: "fp001", itemID: UUID()),
                at: MeshRoutedDrainRig.now
            )
        }

        #expect(capture.count(of: "mesh.routedDrain.heldBackSetFull") == 1)
        #expect(manager.routedDeliveryHold?.itemCount == MeshRoutedStoreFormat.maxItems,
                "the count saturates at the bound it named")
    }

    /// Item 8's `unplacedItemKeys` — the first honest "content this device could not pass on" —
    /// reaches the observable under its own cause.
    @Test func unplacedItemKeysReachTheObservable() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "backpressure-unplaced")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let orphan = try MeshRoutedDrainItem.mint(scenario.rig, origin: 0, byteCount: 1_500)
        orphan.stage(into: scenario.rig, at: 0)
        let origin = scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager
        #expect(origin.routedDeliveryHold == nil, "no storeFull fact is pending, so precedence is idle")

        try await scenario.developInsideTheWindow(at: base)

        let handoff = try #require(origin.lastDevelopmentHandoff)
        #expect(handoff.unplacedItemKeys == [orphan.key])
        let hold = try #require(origin.routedDeliveryHold, "the unplaced count reached no surface")
        #expect(hold.cause == .notPlaced)
        #expect(hold.itemCount == handoff.unplacedItemKeys.count)
        #expect(RoutedDeliveryHoldCopy.detail(.notPlaced, count: hold.itemCount)
                != RoutedDeliveryHoldCopy.detail(.storeFull, count: hold.itemCount),
                "two different facts must not share one sentence")
    }
}

// MARK: - The parked-set drop rule, at the door

/// The one clause that turns a refused manifest into dropped bytes, driven through the real ingest.
@MainActor
@Suite(.serialized)
struct MeshRoutedParkedDropDoorTests {

    /// Parks a chunk set for `item` at `node` by delivering its chunks from the ORIGIN — the only
    /// party the chunk door lets park a set.
    private func park(
        _ item: MeshRoutedDrainItem, into rig: MeshRoutedDrainRig, at node: Int, from origin: Int
    ) async throws {
        for chunk in item.chunks {
            try await rig.deliver(
                MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: origin, receiver: node
            )
        }
        #expect(rig.routedIndex(rig.nodes[node])?.record(for: item.key)?.isParked == true,
                "the set did not park")
    }

    /// The origin's own refusal is terminal for the item, so the bytes that rode ahead of it go.
    @Test func aRefusedTypeTokenFromTheOriginDropsItsParkedSet() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "parked-drop")
        defer { rig.teardown() }
        rig.link(0, 1)
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedManifestFixtures.typeToken, byteCount: 1_500
        )
        try await park(item, into: rig, at: 1, from: 0)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) == nil, "the parked set stayed")
        #expect(capture.values(of: "mesh.routedStore.itemDropped", key: "reason")
                .contains(MeshRoutedParkedDrop.Reason.unknownTypeToken.rawValue),
                "the drop was not named")
        #expect(rig.routedIndex(rig.nodes[1])?.heldChunkFileCount == 0)
    }

    /// The delete lever, closed: the SAME rejection from a third party drops nothing.
    @Test func aRefusedTypeTokenFromAThirdPartyDropsNothing() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "parked-lever")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.link(2, 1)
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedManifestFixtures.typeToken, byteCount: 1_500
        )
        try await park(item, into: rig, at: 1, from: 0)
        let held = rig.heldChunkCount(1, item.key)

        // Node 2 holds the origin's genuine, signature-valid manifest and forwards it at node 1.
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 2, receiver: 1
        )

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isParked == true,
                "any admitted member could delete a custodian's ciphertext")
        #expect(rig.heldChunkCount(1, item.key) == held)
    }

    /// An origin cannot RETRACT content this device already holds complete: only a parked record is
    /// ever dropped, and the caller is that guard.
    @Test func aCompleteItemIsNeverDroppedByTheParkedRule() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "parked-complete")
        defer { rig.teardown() }
        rig.link(0, 1)
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, byteCount: 1_500)
        item.stage(into: rig, at: 0)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        for chunk in item.chunks {
            try await rig.deliver(
                MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 0, receiver: 1
            )
        }
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isComplete == true)

        // The type token is checked BEFORE the signature, so a re-tokened manifest reaches the same
        // rejection the drop rule fires on — and the record is not parked, so nothing is dropped.
        try await rig.deliver(
            MeshRoutedManifestPayload(
                manifest: item.manifest.replacing(typeToken: MeshRoutedManifestFixtures.typeToken)
            ),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isComplete == true,
                "an origin retracted content this device had already received")
    }

    /// The structural half: the drop has EXACTLY one call site, and it is the verifier-rejection
    /// branch — so neither the `notADestinationOrHandoff` guard nor a capacity refusal can ever
    /// reach it, whatever a future edit intends.
    @Test func theDropHasOneCallSiteAndItIsTheVerifierBranch() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let calls = lines.enumerated().filter { $0.element.contains("dropParkedSetIfTerminal(") }
        #expect(calls.count == 2, "one definition and one call site")
        let callSite = try #require(calls.first)
        let window = lines[max(0, callSite.offset - 8)..<callSite.offset].joined(separator: "\n")
        #expect(window.contains("door.verify(manifest)"),
                "the drop must hang off the verifier's rejection and nothing else")
        #expect(source.contains("dropParkedSet(key:") )
    }
}

// MARK: - The display

/// The app-side copy the hold resolves to: localized by construction, frozen where it must be, and
/// never one sentence for two different facts.
@MainActor
@Suite struct RoutedDeliveryHoldCopyTests {

    /// Every claim the copy owes, for BOTH causes.
    @Test func theDeliveryHoldCopyIsLocalizedAndFrozen() {
        for cause in MeshRoutedDeliveryHoldCause.allCases {
            let one: LocalizedStringKey? = RoutedDeliveryHoldCopy.detail(cause, count: 1)
            let many: LocalizedStringKey? = RoutedDeliveryHoldCopy.detail(cause, count: 2)
            #expect(one != nil)
            #expect(one != many, "English reads badly without the singular fork")
            #expect(RoutedDeliveryHoldCopy.detail(cause, count: 0) == nil)
            let headline: LocalizedStringKey = RoutedDeliveryHoldCopy.headline(cause)
            #expect(headline != RoutedDeliveryHoldCopy.headline(
                cause == .storeFull ? .notPlaced : .storeFull
            ))
        }
        #expect(RoutedDeliveryHoldCopy.detail(.storeFull, count: 1)
                != RoutedDeliveryHoldCopy.detail(.notPlaced, count: 1))
        #expect(RoutedDeliveryHoldCopy.accessibilityIdentifier == "friends.deliveryHold")
        #expect(MeshRoutedDeliveryHoldCause.allCases.map(\.rawValue) == ["storeFull", "notPlaced"])
    }

    /// One tap must not silence a LATER, different refusal — the wall's own failure mode ("a queue
    /// that grows past its cap without telling anyone") re-introduced one layer above the manager.
    ///
    /// The rule is a pure function precisely so this can be asserted: the banner's `@State` survives
    /// every change of the hold, so a bare `Bool` would hide every later hold for the life of the
    /// process.
    @Test func aDismissalNeverSilencesADifferentHold() {
        let at = Date()
        let full = MeshRoutedDeliveryHold(cause: .storeFull, itemCount: 1, at: at)

        #expect(RoutedDeliveryHoldDismissal.hides(full, dismissed: nil) == false,
                "nothing dismissed, nothing hidden")
        #expect(RoutedDeliveryHoldDismissal.hides(full, dismissed: full),
                "the reader dismissed exactly this")
        #expect(RoutedDeliveryHoldDismissal.hides(
            full, dismissed: MeshRoutedDeliveryHold(
                cause: .storeFull, itemCount: 1, at: at.addingTimeInterval(90)
            )
        ), "the manager re-derives the hold on every event, so the instant cannot be the identity")

        let later = MeshRoutedDeliveryHold(cause: .notPlaced, itemCount: 1, at: at)
        #expect(RoutedDeliveryHoldDismissal.hides(later, dismissed: full) == false,
                "a dismissed storeFull must not hide a later notPlaced — different fact, different copy")
        let grown = MeshRoutedDeliveryHold(cause: .storeFull, itemCount: 40, at: at)
        #expect(RoutedDeliveryHoldDismissal.hides(grown, dismissed: full) == false,
                "one held-back item dismissed is not forty")
    }

    /// The render gate itself, asserted where it lives: the body shows the card only for a hold the
    /// dismissal does not cover, and the mount is unconditional in `ConnectView`.
    ///
    /// A value-level cell cannot reach `body`, so this is a source wall rather than a claim the
    /// memberwise initialiser satisfies by existing.
    @Test func theBannerGateAndItsMountAreBothReal() throws {
        let banner = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/RoutedDeliveryHoldBanner.swift")
        )
        #expect(banner.contains(
            "if let hold, !RoutedDeliveryHoldDismissal.hides(hold, dismissed: dismissedHold) {"
        ), "the body must gate on BOTH the hold and the dismissal rule")
        #expect(banner.contains("dismissedHold = hold"), "the dismissal stores the fact, not a flag")
        #expect(banner.contains(".accessibilityElement(children: .combine)") == false,
                "combining would strip the dismiss Button's trait, focus and label")

        let connect = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        let lines = connect.split(separator: "\n", omittingEmptySubsequences: false)
        let mounts = lines.enumerated().filter {
            $0.element.contains("RoutedDeliveryHoldBanner(hold: manager.routedDeliveryHold)")
        }
        #expect(mounts.count == 1, "exactly one mount")
        let mount = try #require(mounts.first)
        let album = try #require(
            lines.firstIndex(where: { $0.contains("if manager.meshPhotos.isEmpty") }),
            "the album branch moved; re-check where the banner is mounted"
        )
        #expect(mount.offset < album,
                "held custody outlives the album — the banner must not sit inside that branch")
    }
}
