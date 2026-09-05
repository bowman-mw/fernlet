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

    /// **P5 item 13's seam into the battery**: one member mints a REAL sealed photo item — framed
    /// body, item seal, signed manifest, chunks — and stages it into its own routed store.
    ///
    /// Deliberately not ``routedCustodyEvent(at:chunks:now:)``: that stages an opaque fixture blob,
    /// which every rung above the plaintext seam is happy with and no delivery projection can open.
    /// A convergence claim about the WALL needs bytes a receiver can really decrypt.
    ///
    /// - Parameters:
    ///   - member: The origin.
    ///   - now: The injected instant the two store doors are charged at.
    /// - Returns: the item's signed pair.
    func routedSealedPhotoEvent(
        at member: MeshConvergenceMember, now: Date
    ) throws -> MeshRoutedItemKey {
        let identity = member.node.manager.identityForTesting
        guard let roster = member.node.manager.membershipVerifier?.roster else {
            throw MeshMergeTestFailure.rosterTooSmall
        }
        let item = try MeshRoutedPhotoFixtures.item(
            meshID: meshID,
            roster: roster,
            signer: identity,
            recipientKeys: Dictionary(uniqueKeysWithValues: members.map {
                ($0.fingerprint, $0.node.manager.identityForTesting.localKeyAgreementPublicKey)
            }),
            createdAt: MeshP3Acceptance.base.addingTimeInterval(60),
            hardDeadline: MeshP3Acceptance.base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let store = MeshRoutedStore(scope: member.node.store.meshRoutedStorage)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(store.admittingManifest(item.manifest, now: now).value != nil)
            // R2: bounded by the item's own chunk count.
            for chunk in item.chunks {
                #expect(store.stagingChunk(chunk, now: now).value != nil)
            }
        }
        return MeshRoutedItemKey(item.manifest)
    }

    /// Opens every living member's access gate, which is what a device that is unlocked and
    /// foregrounded looks like — and the precondition for any plaintext claim at all.
    func openEveryRoutedGate(now: Date) {
        // R2: bounded by the roster cap.
        for member in livingMembers {
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                member.node.manager.applyRoutedAccessGate(
                    MeshRoutedAccessGate(
                        protectedDataAvailable: true, appIsForeground: true, duressActive: false
                    ),
                    now: now
                )
            }
        }
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

    /// **One call into item 9's seam**: fills one member's routed store to the byte cap, so the next
    /// admission at that member must refuse.
    ///
    /// One planted descriptor claiming the whole budget — no sealing at all — carrying the schedule's
    /// own expiry, so the hog is live at the run's `now` and the refusal it exists to cause really
    /// happens rather than being swept away first.
    func routedCapacityEvent(at member: MeshConvergenceMember, now: Date) throws {
        let deadline = MeshP3Acceptance.base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        let hog = MeshRoutedStoreFixtures.record(
            chunks: [MeshRoutedStoreFixtures.descriptor(
                index: 0, count: 1, bytes: Int(MeshRoutedStoreFormat.maxContentBytes)
            )],
            expiresAt: MeshRoutedManifest.expiry(afterHardDeadline: deadline)
        )
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: [hog]),
            into: MeshRoutedStore(scope: member.node.store.meshRoutedStorage),
            install: MeshP3Acceptance.install
        )
    }

    /// One member's state for `key` — the deletion-proof reading of "the origin owes nobody".
    ///
    /// P5 item 9's reclaim means a fully delivered item can DISAPPEAR from the origin's own index,
    /// and `outstandingDestinations` answers `[]` for a missing record. A progress claim written
    /// against that predicate alone is therefore satisfied by a deletion, which is exactly what a
    /// property battery must not accept.
    func routedDeliveryState(
        at member: MeshConvergenceMember, key: MeshRoutedItemKey
    ) -> MeshRoutedDeliveryProgressState {
        guard let index = routedIndex(of: member) else { return .outstanding([]) }
        guard index.record(for: key) != nil else { return .reclaimed }
        guard let roster = member.node.manager.membershipVerifier?.roster else {
            return .outstanding([])
        }
        let owed = index.outstandingDestinations(for: key, in: roster)
        return owed.isEmpty ? .closed : .outstanding(owed)
    }

    /// Commits every living pair again and settles, up to ``routedDrainRounds`` times, stopping the
    /// moment the origin's copy is closed **or has been reclaimed**.
    ///
    /// `binding` is a **parameter** (P5 item 10): an inner `withValue` shadows an outer one, so a
    /// caller that wrapped this in `.withValue(.readError)` to drive a locked window would otherwise
    /// find every store `.loaded` for exactly the commit pumps the routed work happens in — the
    /// window would be vacuous and the cell would pass for the wrong reason. It defaults to `nil`
    /// rather than to the install itself because a `@MainActor` static cannot be a default-argument
    /// value — the rig's own `dispatch(_:type:sender:receiver:now:binding:)` resolves it the same way.
    func runRoutedDrainRounds(
        origin: MeshConvergenceMember,
        key: MeshRoutedItemKey,
        binding: DeviceBindingID.TestOverride? = nil
    ) async throws {
        let binding = binding ?? .identifier(MeshP3Acceptance.install)
        // R2: a hard constant ceiling.
        for _ in 0..<Self.routedDrainRounds {
            if routedDeliveryState(at: origin, key: key).isSettled { return }
            let living = livingMembers
            DeviceBindingID.$testOverride.withValue(binding) {
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
            try await MeshDepartureRig.settle(livingNodes, on: fabric, binding: binding)
        }
    }

    /// **P5 item 10's seam into the battery**: a locked window, sampled, then the unlock edge.
    ///
    /// 1. the member's gate is pushed **closed** and the drain runs with every store unreadable
    ///    (`.readError` ⇒ `deferred`, the state a device is in before its first post-boot unlock);
    /// 2. `sample` runs while the window is still shut — the only place the "nothing moved" half can
    ///    honestly be read, and the rig's own "sample right after a synchronous pump" discipline;
    /// 3. the device unlocks: the open gate is pushed under the pinned install binding, which is the
    ///    re-entry's own edge.
    ///
    /// The binding is a **parameter** of the rounds rather than a wrapper around them: an inner
    /// `withValue` shadows an outer one, so wrapping would leave every store `.loaded` for exactly
    /// the commit pumps the routed work happens in, and the window would be vacuous.
    ///
    /// - Parameters:
    ///   - member: The device that locks.
    ///   - key: The item whose progress the window is judged against.
    ///   - now: The injected instant.
    ///   - sample: Read inside the window, before the unlock.
    /// - Returns: what the unlock's re-entry did.
    @discardableResult
    func routedLockWindowEvent(
        at member: MeshConvergenceMember,
        closingAfter key: MeshRoutedItemKey,
        now: Date,
        sampling sample: () -> Void = {}
    ) async throws -> MeshRoutedReentryReport? {
        member.node.manager.applyRoutedAccessGate(.closed, now: now)
        try await runRoutedDrainRounds(origin: member, key: key, binding: .readError)
        sample()
        return DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            member.node.manager.applyRoutedAccessGate(
                MeshRoutedAccessGate(
                    protectedDataAvailable: true, appIsForeground: true, duressActive: false
                ),
                now: now
            )
        }
    }

    /// **P5 item 12's seam into the battery**: one already-delivered routed frame, re-presented.
    ///
    /// Deliberately **not** a new `MeshScheduleEvent` case — the vocabulary is item 14's to grow, and
    /// adding one here would change every seeded draw and trip
    /// `theMatrixExecutesEveryEventInTheVocabulary`. Exactly the shape items 8 and 10 left.
    ///
    /// The frame is the SENDER's own stored manifest for `key`, re-dispatched through the real
    /// envelope verification and the drain's own door on an injected clock — i.e. a replay of a
    /// frame the receiver has already admitted, which is what an attacker on this link can mount.
    ///
    /// - Returns: whether a frame actually **reached the ingest door**, so a cell can refuse to pass
    ///   vacuously. The committed slot is part of that contract, not an afterthought: a manifest and
    ///   a coordinator are not enough, because `dispatchRoutedPayload` returns at its very first
    ///   guard (`slot?.fingerprint`, `droppedUncommittedSlot`) when the receiver holds no committed
    ///   slot for that coordinator — and a `true` returned over that return is exactly the vacuous
    ///   pass the flag exists to prevent. So the slot is resolved with the manifest, before any
    ///   signing work, and a missing one answers false.
    @discardableResult
    func routedReplayEvent(
        at receiver: MeshConvergenceMember,
        from sender: MeshConvergenceMember,
        frame key: MeshRoutedItemKey,
        now: Date
    ) throws -> Bool {
        guard let manifest = routedIndex(of: sender)?.record(for: key)?.manifest,
              let coordinator = receiver.node.coordinators[sender.node.handle.endpoint],
              let slot = receiver.node.manager.slots.first(where: { $0.coordinator === coordinator }),
              slot.fingerprint != nil
        else { return false }
        let identity = sender.node.manager.identityForTesting
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: identity, senderDisplayName: "replay",
            recipientFingerprint: receiver.fingerprint,
            payloadType: .meshRoutedManifest, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "routed"),
            payload: try JSONEncoder().encode(MeshRoutedManifestPayload(manifest: manifest)),
            createdAt: now
        )
        let plaintext = try envelope.verify(
            identityService: receiver.node.manager.identityForTesting,
            replayCache: receiver.node.replayCache
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            receiver.node.manager.dispatchRoutedPayload(
                .meshRoutedManifest, plaintext: plaintext, decoder: JSONDecoder(),
                slot: slot, now: now
            )
        }
        return true
    }

    /// The destinations the origin still owes, derived from its own index.
    func routedOutstanding(at origin: MeshConvergenceMember, key: MeshRoutedItemKey) -> [String] {
        guard let index = routedIndex(of: origin),
              let roster = origin.node.manager.membershipVerifier?.roster else { return [] }
        return index.outstandingDestinations(for: key, in: roster)
    }

    /// The routed half of §16.2's invariants, over the same survivors: nothing lost, nothing
    /// double-counted, and every outstanding delivery closed.
    ///
    /// - Parameters:
    ///   - origin: The member that minted the item.
    ///   - key: The item.
    ///   - capture: The run's audit capture. The third disjunct is read **through** it: a missing
    ///     record is otherwise indistinguishable from a record that was never written, so an
    ///     un-corroborated `.reclaimed` would satisfy "nothing lost" for any deletion at all.
    func routedInvariants(
        _ origin: MeshConvergenceMember,
        _ key: MeshRoutedItemKey,
        audited capture: MeshRoutedBackpressureAuditCapture
    ) {
        let living = livingMembers
        let owed = Set(routedOutstanding(at: origin, key: key))
        let audited = capture.values(of: "mesh.routedStore.itemDropped", key: "reason")
            .contains("delivered")
        // R2: bounded by the roster cap.
        for member in living where member.index != origin.index {
            let record = routedIndex(of: member)?.record(for: key)
            let holdsSomething = (record?.chunks.isEmpty == false)
            // The third disjunct is P5 item 9's: a PURE COURIER — a custodian that is not a
            // destination — loses its copy at the first exchange after every destination delivered,
            // so it holds nothing and is owed nothing, and both earlier disjuncts are false for a
            // device that did exactly the right thing. It is accepted ONLY together with the audited
            // drop that is the only thing allowed to have produced it — exactly the corroboration
            // the origin's own progress claim requires — so a regression that deletes a record for
            // any other reason still fails here.
            let reclaimed = audited && routedDeliveryState(at: member, key: key) == .reclaimed
            #expect(holdsSomething || owed.contains(member.fingerprint) || reclaimed,
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

/// How far one member's copy of a routed item has got — the deletion-proof reading of the progress
/// claim (P5 item 9).
///
/// `.closed` is a record that is present with nothing outstanding; `.reclaimed` is no record at all,
/// which the reclaim can produce for the origin's own copy and for a pure courier's. `.outstanding`
/// also covers "this device cannot say" (a store that is not `.loaded`), so an unreadable store keeps
/// the rounds loop going and fails the final assertion rather than passing it vacuously.
nonisolated enum MeshRoutedDeliveryProgressState: Equatable, Sendable {
    /// Still owed to these destinations, or unreadable.
    case outstanding([String])
    /// The record is held and nothing is outstanding.
    case closed
    /// The record is gone — reclaimed, expired or dropped.
    case reclaimed

    /// Whether the drain has nothing further to do for this copy.
    var isSettled: Bool {
        switch self {
        case .outstanding: return false
        case .closed, .reclaimed: return true
        }
    }
}

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
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let key = try run.routedCustodyEvent(
            at: origin, chunks: cell.chunks, now: MeshP3Acceptance.base.addingTimeInterval(600)
        )
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        run.routedInvariants(origin, key, audited: capture)
        // P5 item 9: `outstandingDestinations` answers `[]` for a MISSING record, so the old
        // assertion was satisfiable by a deletion. `.reclaimed` now passes only together with the
        // audited drop that is the only thing allowed to have produced it.
        switch run.routedDeliveryState(at: origin, key: key) {
        case .closed:
            break
        case .reclaimed:
            #expect(capture.values(of: "mesh.routedStore.itemDropped", key: "reason")
                    .contains("delivered"),
                    "the record vanished with no audited reclaim behind it")
        case .outstanding(let owed):
            Issue.record("a reachable survivor destination never reached delivered: \(owed)")
        }
    }

    /// **P-1 — P5 item 13 in the battery.** One REAL sealed photo, minted before the heal, reaches
    /// every destination's wall exactly once under the fixed root seed.
    ///
    /// The property the earlier cells cannot state: they end at custody and receipts, which are
    /// ciphertext facts, while this one ends at the canonical store the whole feature exists to
    /// fill. Every instant is anchored to the injected clock rather than to a wall clock, and the
    /// seed is the family's fixed root — a randomized seed is a flake generator, not a property test.
    @Test func aSealedPhotoConvergesOnTheRootSeed() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(schedule, label: "routed-photo")
        defer { for node in run.livingNodes { node.manager.leaveMesh() } }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let now = MeshP3Acceptance.base.addingTimeInterval(600)
        run.openEveryRoutedGate(now: now)
        let key = try run.routedSealedPhotoEvent(at: origin, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let destinations = run.livingMembers.filter { $0.index != origin.index }
        #expect(destinations.isEmpty == false, "the cell needs at least one destination")
        // R2: bounded by the roster cap.
        for member in destinations {
            #expect(member.node.manager.meshPhotos.filter { $0.id == key.itemID }.count == 1,
                    "every destination's wall holds exactly one entry for the delivered item")
        }
    }

    /// **P5 item 9 in the battery.** One survivor is at its byte cap when the drain reaches it, and a
    /// capacity refusal is a **named closed state** rather than a silent stall: the item stays
    /// outstanding at the origin, the origin's own record is intact, and the capped member says why.
    ///
    /// The hog carries the schedule's own expiry, so item 9's expiry sweep cannot free it before the
    /// refusal happens — the fixture trap that would turn this cell green for the wrong reason.
    @Test func aMemberAtCapacityLosesNoContent() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(schedule, label: "routed-capacity")
        defer { for node in run.livingNodes { node.manager.leaveMesh() } }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let capped = try #require(
            run.livingMembers.dropFirst().first, "the cell needs a second survivor to fill"
        )
        let now = MeshP3Acceptance.base.addingTimeInterval(600)
        try run.routedCapacityEvent(at: capped, now: now)
        let key = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).contains(capped.fingerprint),
                "the cell must start with the capped member actually owed the item")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        #expect(run.routedOutstanding(at: origin, key: key).contains(capped.fingerprint),
                "a capacity refusal must leave the delivery outstanding, never quietly closed")
        #expect(run.routedIndex(of: origin)?.record(for: key) != nil,
                "the origin's own copy is intact — backpressure is not data loss")
        #expect(capped.node.manager.routedDeliveryHold?.cause == .storeFull,
                "a refusal that names no state at all is the silent stall this battery exists to catch")
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

    /// **P5 item 10 in the battery.** A locked window loses nothing, and the unlock converges it.
    ///
    /// Inside the window every store answers `deferred`, which is the state a device is in before
    /// its first post-boot unlock: no index is overwritten, no receipt and no `delivered` rung
    /// appears anywhere, and nothing is dropped. After the unlock edge the whole routed progress
    /// property holds again — every outstanding delivery reaches `delivered` or a **named** closed
    /// state, with `.reclaimed` still accepted only alongside its audited drop.
    ///
    /// **Non-vacuity is asserted inside the window**: at least one audited line must carry a
    /// `deferred:` token, so a window that was silently `.loaded` fails rather than passes.
    @Test(arguments: MeshRoutedDrainCells.all)
    func aLockedWindowLosesNothingAndConvergesAfterTheUnlock(cell: MeshRoutedDrainCell) async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: cell.seed, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(schedule, label: "routed-lock")
        defer { for node in run.livingNodes { node.manager.leaveMesh() } }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let now = MeshP3Acceptance.base.addingTimeInterval(600)
        let key = try run.routedCustodyEvent(at: origin, chunks: cell.chunks, now: now)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false,
                "the cell must start with work actually outstanding")
        let window = MeshRoutedBackpressureAuditCapture()
        window.install()
        defer { window.uninstall() }
        let before = MeshRoutedStoreFixtures.snapshot(origin.node.store.meshRoutedStorage)

        try await run.routedLockWindowEvent(at: origin, closingAfter: key, now: now) {
            #expect(MeshRoutedStoreFixtures.snapshot(origin.node.store.meshRoutedStorage) == before,
                    "an index was overwritten while every store was deferred")
            #expect(window.values(of: "mesh.routedStore.readSuppressed", key: "state")
                    .contains { $0.hasPrefix("deferred:") },
                    "the window was silently loaded, so it proved nothing")
            // R2: bounded by the roster cap.
            for member in run.livingMembers where member.index != origin.index {
                #expect(run.routedIndex(of: member)?.record(for: key) == nil,
                        "content moved to a peer whose store could not say what it holds")
            }
            #expect(run.routedIndex(of: origin)?.record(for: key)?.recipientReceipts.isEmpty == true,
                    "a receipt was emitted for state a restart would have lost")
        }
        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        run.routedInvariants(origin, key, audited: capture)
        switch run.routedDeliveryState(at: origin, key: key) {
        case .closed:
            break
        case .reclaimed:
            #expect(capture.values(of: "mesh.routedStore.itemDropped", key: "reason")
                    .contains("delivered"),
                    "the record vanished with no audited reclaim behind it")
        case .outstanding(let owed):
            Issue.record("a delivery never closed after the unlock: \(owed)")
        }
    }

    /// **P5 item 12 in the battery.** A replayed frame changes no rung and no receipt count: the
    /// routed progress invariants still hold after one already-admitted manifest is re-presented on
    /// a live link, and the receiver's index is byte-identical across the replay.
    ///
    /// One fixed seed, one replay, no new schedule-event case — item 14 decides whether a replay
    /// becomes part of the vocabulary, which is a matrix-wide change.
    @Test func aReplayedFrameChangesNoRungAndNoReceiptCount() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .twoTwo, preferQuorum: false
        )
        let run = try MeshConvergenceRun.build(schedule, label: "routed-replay")
        defer { for node in run.livingNodes { node.manager.leaveMesh() } }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try await run.runSplitEvents()

        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let now = MeshP3Acceptance.base.addingTimeInterval(600)
        let key = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let victim = try #require(
            run.livingMembers.first { $0.index != origin.index && run.routedIndex(of: $0) != nil },
            "the cell needs a survivor whose store can be read"
        )
        let before = MeshRoutedStoreFixtures.snapshot(victim.node.store.meshRoutedStorage)
        let dispatched = try run.routedReplayEvent(
            at: victim, from: origin, frame: key, now: now.addingTimeInterval(60)
        )
        #expect(dispatched, "the replay never reached the door, so the claim below is vacuous")

        #expect(MeshRoutedStoreFixtures.snapshot(victim.node.store.meshRoutedStorage) == before,
                "a replayed manifest moved a rung or a receipt count")
        run.routedInvariants(origin, key, audited: capture)
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
