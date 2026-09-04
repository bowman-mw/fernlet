// MeshRoutedDrainConvergenceTests.swift
// FernletTests
//
// Network migration P5 item 6 (plan §11, §3 item 14): the routed half of §16.2's convergence
// property — every outstanding delivery reaches `delivered` or a NAMED closed state under a bounded
// schedule, no content lost, no receipt double-counted.
//
// An **extension on `MeshConvergenceRun`**, not a parallel rig: the split, the events, the ordered
// heal, the full-mesh reform and the bounded settles are item 4's, and only the routed seam is new.
// Deliberately **no new `MeshScheduleEvent` case** — the vocabulary is item 14's to grow, and adding
// one here would trip `theMatrixExecutesEveryEventInTheVocabulary`.
//
// Seeds come from `MeshConvergenceSeeds.family` (root `0x00F32B1C00090002`) and nothing is drawn at
// run time: a randomized seed is a flake generator, not a property test.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - The routed seam on the convergence run

@MainActor
extension MeshConvergenceRun {

    /// How many extra commit-and-settle rounds the routed assertions may wait for.
    ///
    /// The drain is exchange-driven — an answer truncated at its per-answer bound leaves the
    /// remainder for the NEXT exchange with that peer, and exchanges happen only as a link opens —
    /// so a bounded number of further rounds is the honest shape of "it converges", not a retry loop
    /// hiding a hang. Bounded (R2), with an early exit the moment the origin owes nobody.
    static var routedDrainRounds: Int { MeshScheduleBounds.maxCommitRounds + 2 }

    /// **One call into the drain's seam**: the member mints a routed item for the full roster minus
    /// itself and stages it into its own routed store, exactly as an origin does.
    ///
    /// - Returns: the item's signed pair, which every routed assertion is written against.
    func routedCustodyEvent(
        at member: MeshConvergenceMember, chunks: Int, now: Date
    ) throws -> MeshRoutedItemKey {
        let identity = member.node.manager.identityForTesting
        guard let roster = member.node.manager.membershipVerifier?.roster else {
            throw MeshMergeTestFailure.rosterTooSmall
        }
        let payload = MeshRoutedCustodyFixtures.blob(
            byteCount: MeshChunkFormat.maxChunkPayloadBytes * (chunks - 1) + 1_000
        )
        let target = MeshDeliveryTarget(
            contentID: UUID(), roster: roster, selfFingerprint: identity.localFingerprint
        )
        let manifest = try MeshRoutedManifest.signed(
            meshID: meshID,
            target: target,
            typeToken: MeshRoutedTypeToken.photo,
            contentHash: MeshRoutedContentDigest.contentHash(of: payload),
            size: UInt64(payload.count),
            createdAt: MeshP3Acceptance.base.addingTimeInterval(60),
            hardDeadline: MeshP3Acceptance.base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            contentKey: Data(repeating: 0x51, count: 32),
            recipientKeys: Dictionary(uniqueKeysWithValues: members.map {
                ($0.fingerprint, $0.node.manager.identityForTesting.localKeyAgreementPublicKey)
            }),
            identity: identity
        )
        let store = MeshRoutedStore(scope: member.node.store.meshRoutedStorage)
        try DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(store.admittingManifest(manifest, now: now).value != nil)
            // R2: bounded by the item's own chunk count.
            for chunk in try MeshChunker.chunks(of: payload, for: manifest, identity: identity) {
                #expect(store.stagingChunk(chunk, now: now).value != nil)
            }
        }
        return MeshRoutedItemKey(manifest)
    }

    /// **P5 item 8's seam into the battery**: one member develops, on an injected clock, with no
    /// randomness of its own.
    ///
    /// Deliberately **not** a new `MeshScheduleEvent` case — the vocabulary is item 14's to grow, and
    /// adding one here would trip `theMatrixExecutesEveryEventInTheVocabulary`. The schedule already
    /// carries `departure`; this is the routed half of what one costs.
    ///
    /// - Returns: what the development's custody transfer actually did.
    @discardableResult
    func routedDevelopmentEvent(
        at member: MeshConvergenceMember, now: Date
    ) async -> MeshCustodyHandoffResult {
        let clock = MeshTerminationFixtures.SteppedClock(
            [now, now.addingTimeInterval(3), now.addingTimeInterval(3)]
        )
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await member.node.manager.leaveSessionAfterNotifyingPeers(clock: { clock.next() })
        }
        return member.node.manager.lastDevelopmentHandoff ?? .none
    }

    /// **The hop invariant** — the property a plausible-looking widening would silently remove — and
    /// the positive fact every part of it depends on.
    ///
    /// Every device that carries a `custodied(by: self)` rung for an item it did not originate is a
    /// device the leaver's own signed record **named** and one the origin **served the manifest to
    /// directly** (§4.2a). There is no third courier, at any distance from the origin.
    ///
    /// The count is pinned first, and at least one courier is required to exist: a subset claim over
    /// an empty set proves nothing, so a regression that suppressed the transfer entirely has to
    /// fail here rather than pass vacuously.
    func routedHandoffInvariants(
        origin: MeshConvergenceMember, key: MeshRoutedItemKey, handoff: MeshCustodyHandoffResult
    ) {
        #expect(handoff.transferredItemCount == 1,
                "the development transferred nothing, so every claim below would be vacuous")
        let named = Set(origin.node.manager.lastDevelopmentPlan?.handoffTargets ?? [])
        var couriers: Set<String> = []
        // R2: bounded by the roster cap.
        for member in members where member.index != origin.index {
            guard let target = routedIndex(of: member)?.record(for: key)?.deliveryTarget else {
                continue
            }
            let holders = Set(target.destinations.compactMap {
                target.state(of: $0)?.custodianFingerprint
            })
            #expect(holders.subtracting(named).isEmpty,
                    "a courier the leaver's own departure record never named: \(holders)")
            if holders.contains(member.fingerprint) {
                #expect(member.node.manager.originServedItemsForTesting.contains(key),
                        "a courier the origin never served the manifest to — that is a second hop")
            }
            couriers.formUnion(holders)
        }
        #expect(couriers.isEmpty == false,
                "no survivor carries a courier rung at all, so the subset claims proved nothing")
    }

    /// Drains `key` inside the ORIGIN's own branch only — the shape a development actually needs.
    ///
    /// The branch partner ends up holding the ciphertext and the origin holding its signed custody
    /// receipt, while every destination on the far side of the split is still `pending`. Draining
    /// the **whole** mesh first is what makes a development vacuous: with nothing outstanding the
    /// transfer has no candidates at all, and every hand-off assertion then holds with the entire
    /// mechanism removed.
    ///
    /// Bounded (R2), with an early exit the moment the origin holds a custody receipt.
    func runBranchDrainRounds(origin: MeshConvergenceMember, key: MeshRoutedItemKey) async throws {
        let branch = livingMembers.filter { $0.branch == origin.branch }
        // R2: a hard constant ceiling.
        for _ in 0..<Self.routedDrainRounds {
            if routedIndex(of: origin)?.record(for: key)?.receipts.isEmpty == false { return }
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                // R2: bounded by the branch size, squared.
                for (position, near) in branch.enumerated() {
                    for far in branch.dropFirst(position + 1) {
                        near.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: far.fingerprint
                        )
                        far.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: near.fingerprint
                        )
                    }
                }
            }
            try await MeshDepartureRig.settle(branch.map(\.node), on: fabric)
        }
    }

    /// One living member's routed index, or nil for every non-`.loaded` state.
    func routedIndex(of member: MeshConvergenceMember) -> MeshRoutedIndex? {
        let load = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            MeshRoutedStore(scope: member.node.store.meshRoutedStorage).load()
        }
        guard case .loaded(let index, _) = load else { return nil }
        return index
    }

    /// Commits every living pair again and settles, up to ``routedDrainRounds`` times, stopping the
    /// moment the origin owes nobody.
    func runRoutedDrainRounds(origin: MeshConvergenceMember, key: MeshRoutedItemKey) async throws {
        // R2: a hard constant ceiling.
        for _ in 0..<Self.routedDrainRounds {
            if routedOutstanding(at: origin, key: key).isEmpty { return }
            let living = livingMembers
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                // R2: bounded by the roster cap, squared.
                for (position, near) in living.enumerated() {
                    for far in living.dropFirst(position + 1) {
                        near.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: far.fingerprint
                        )
                        far.node.manager.applySessionEvent(
                            .peerCommitted, committedPeer: near.fingerprint
                        )
                    }
                }
            }
            try await MeshDepartureRig.settle(livingNodes, on: fabric)
        }
    }

    /// The destinations the origin still owes, derived from its own index.
    func routedOutstanding(at origin: MeshConvergenceMember, key: MeshRoutedItemKey) -> [String] {
        guard let index = routedIndex(of: origin),
              let roster = origin.node.manager.membershipVerifier?.roster else { return [] }
        return index.outstandingDestinations(for: key, in: roster)
    }

    /// The routed half of §16.2's invariants, over the same survivors: nothing lost, nothing
    /// double-counted, and every outstanding delivery closed.
    func routedInvariants(_ origin: MeshConvergenceMember, _ key: MeshRoutedItemKey) {
        let living = livingMembers
        let owed = Set(routedOutstanding(at: origin, key: key))
        // R2: bounded by the roster cap.
        for member in living where member.index != origin.index {
            let record = routedIndex(of: member)?.record(for: key)
            let holdsSomething = (record?.chunks.isEmpty == false)
            #expect(holdsSomething || owed.contains(member.fingerprint),
                    "a destination neither holds the item nor is still owed it")
            guard let record else { continue }
            let custodians = record.receipts.map(\.custodianFingerprint)
            #expect(Set(custodians).count == custodians.count, "a custody receipt was double-counted")
            let recipients = record.recipientReceipts.map(\.recipientFingerprint)
            #expect(Set(recipients).count == recipients.count, "a recipient receipt was double-counted")
        }
        let refused = origin.node.manager.lastRoutedDrainRefusal
        #expect(owed.isEmpty || refused != nil,
                "an outstanding delivery closed in no named state at all")
    }
}

// MARK: - The cells

/// One cell of the routed progress property: a fixed seed, and how many chunks its item carries.
nonisolated struct MeshRoutedDrainCell: Sendable, CustomStringConvertible {
    /// The fixed seed from ``MeshConvergenceSeeds/family``.
    let seed: UInt64
    /// How many chunks the cell's routed item is sliced into. One cell carries more than one, so the
    /// progress claim has something that cannot complete in a single frame.
    let chunks: Int

    /// A replayable label: the seed is what a failure is re-run from.
    var description: String { "seed \(String(seed, radix: 16)) x \(chunks)" }
}

/// The fixed cell list — the whole seed family, nothing drawn at run time.
nonisolated enum MeshRoutedDrainCells {
    /// Every cell, in the seed family's own order.
    static let all: [MeshRoutedDrainCell] = MeshConvergenceSeeds.family.enumerated().map {
        MeshRoutedDrainCell(seed: $0.element, chunks: $0.offset == 0 ? 3 : 1)
    }
}

// MARK: - The property

/// **The routed progress property.** One seeded, bounded schedule per cell: split, events, mint,
/// ordered heal, bounded drain rounds — then the safety pair and the progress claim.
///
/// The progress half is what the safety pair cannot express: an item that never moves satisfies
/// "still named by `outstandingDestinations`" forever, so without it the whole pacing family would
/// be invisible to the battery. One cell carries a **multi-chunk** item for exactly that reason.
@MainActor
@Suite(.serialized)
struct MeshRoutedDrainConvergenceTests {

    @Test(arguments: MeshRoutedDrainCells.all)
    func everyOutstandingDeliveryClosesUnderASeededSchedule(cell: MeshRoutedDrainCell) async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: cell.seed, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(schedule, label: "routed-drain")
        defer { for node in run.livingNodes { node.manager.leaveMesh() } }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let key = try run.routedCustodyEvent(
            at: origin, chunks: cell.chunks, now: MeshP3Acceptance.base.addingTimeInterval(600)
        )
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        run.routedInvariants(origin, key)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty,
                "a reachable survivor destination never reached delivered")
    }

    /// **P5 item 8 in the battery.** The origin drains **inside its own branch**, develops there, and
    /// the hop invariant holds across every survivor: exactly one item transfers, the courier is one
    /// the leaver named and served directly, and nothing else couriers anything.
    ///
    /// The development happens while the far branch is still owed the item, deliberately: a
    /// development after a full heal-and-drain has no outstanding leg to hand, so the transfer would
    /// have nothing to do and every assertion would hold with the mechanism deleted.
    @Test func aDevelopmentHandsCustodyOnlyToTheCustodiansItNamed() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(schedule, label: "routed-handoff")
        // The rotation is consumed BEFORE the sessions end: a development arms a debounce that fires
        // seconds later, and once it has started it runs on to `broadcastCoordinatorBeacon`, which
        // spawns un-cancellable send tasks that re-strengthen a manager whose host store has already
        // gone. That traps the whole test process, not just this cell.
        defer {
            for node in run.livingNodes { _ = node.manager.consumePendingRotationForTesting() }
            for node in run.livingNodes { node.manager.leaveMesh() }
        }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first { member in
            run.livingMembers.filter { $0.branch == member.branch }.count >= 2
        }, "the cell needs a branch of at least two survivors to hand custody inside")
        let key = try run.routedCustodyEvent(
            at: origin, chunks: 1, now: MeshP3Acceptance.base.addingTimeInterval(600)
        )
        try await run.runBranchDrainRounds(origin: origin, key: key)
        #expect(run.routedIndex(of: origin)?.record(for: key)?.receipts.isEmpty == false,
                "the branch partner must have taken the bytes and receipted for them")
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "and the far branch must still be owed the item, or there is nothing to hand over")
        let handoff = await run.routedDevelopmentEvent(
            at: origin, now: MeshP3Acceptance.base.addingTimeInterval(900)
        )
        try await MeshDepartureRig.settle(run.livingNodes, on: run.fabric)
        // A second pump, so anything the first one's rotation spawned runs INSIDE this cell.
        try await MeshDepartureRig.settle(run.livingNodes, on: run.fabric)

        run.routedHandoffInvariants(origin: origin, key: key, handoff: handoff)
        // Ends the sessions and then lets whatever the teardown could not cancel actually run, while
        // these stores are still alive — see `MeshRoutedDrainRig.quiesce()`.
        for node in run.livingNodes { _ = node.manager.consumePendingRotationForTesting() }
        for node in run.livingNodes { node.manager.leaveMesh() }
        // R2: a hard constant ceiling.
        for _ in 0..<16 { await Task.yield() }
    }

    /// The seed family is fixed and derived from the one root — never drawn at run time.
    @Test func theSeedFamilyIsTheFixedOne() {
        #expect(MeshConvergenceSeeds.root == 0x00F3_2B1C_0009_0002)
        #expect(MeshRoutedDrainCells.all.count == MeshConvergenceSeeds.derivedCount)
        #expect(MeshRoutedDrainCells.all.first?.seed == MeshConvergenceSeeds.root)
        #expect(MeshRoutedDrainCells.all.filter { $0.chunks > 1 }.count == 1,
                "at least one cell must carry an item that cannot complete in one frame")
    }
}
