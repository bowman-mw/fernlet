// MeshP5AcceptanceTests.swift
// FernletTests
//
// P5 item 14: **the P5 acceptance battery** (plan §11's testing lane, verbatim).
//
//     Custody, receipts, dedup, backpressure and the drain are tier 1. … a property-test extension
//     asserting every outstanding delivery reaches `delivered` or a closed state under a bounded
//     schedule, no content lost, no double-counted receipt. All on `FakePeerNetwork` +
//     `FakeMeshTransportSession` + an injected clock, no wall-clock sleeps.
//
// …and §16.1's routed clauses, which are what "tier 1" has to end in:
//
//     chunk dedup/TTL/caps/backpressure; custody vs final receipts; heart foreground-commit rule;
//     locked/deferred/corrupt sidecars; exactly-once task completion; wipe-wall + delete-all
//     resurrection checks for every new sidecar.
//
// Items 1–13 each shipped their own exhaustive suites, and those remain the fine-grained evidence:
// the manifest and its wraps (`MeshRoutedManifestTests`), chunks and assembly (`MeshChunkTests`),
// the five-state store (`MeshRoutedStoreTests`, `MeshRoutedCustodyTests`), the ack stages
// (`MeshRoutedDeliveryAckTests`, `MeshRecipientReceiptTests`), the inventory and its delta
// (`MeshRoutedInventoryTests`, `MeshRoutedInventoryBuilderTests`, `MeshRoutedInventoryDeltaTests`),
// the drain (`MeshRoutedDrainTests`), the merge window (`MeshMergeWindowTests`), custody transfer
// (`MeshRoutedCustodyHandoffTests`), backpressure (`MeshRoutedBackpressureTests`,
// `MeshRoutedCapacityTests`), the access gate (`MeshRoutedAccessGateTests`), the type registry
// (`MeshRoutedTypeRegistryTests`), the replay window (`MeshFrameReplayWindowTests`) and the sealed
// photo path (`MeshRoutedPhotoDeliveryTests`). The 40-cell routed rectangle is
// `MeshRoutedDrainConvergenceTests`.
//
// **This file is deliberately not those suites again, and it is deliberately not a list of their
// names either.** Each suite below is one acceptance clause, run end to end as its own compact
// scenario against the same shipping seams — so the battery fails on its own evidence rather than
// on somebody else's, and CI can gate on it by name. Where the exhaustive file is the full space,
// the suite's doc comment says so and this file runs the canonical corner of it.
//
// **The fixed seed is the battery's, not a run-time draw.** Every scenario generates its schedule
// from ``MeshConvergenceSeeds/root`` — `0x00F32B1C00090002` — and its routed side-plan from
// `seed ^ MeshScheduleGenerator.routedSalt`. `MeshP5DeterminismAcceptanceTests` pins both
// constants, the eight-seed family, byte-identical overlay replay, one byte-identical run replay, a
// grep-wall over the routed convergence file, and **two literal digests** over the 80 generated
// membership schedules and the 40 generated overlays — which is the only artefact that can go red
// for "a draw was added inside `schedule(…)`".
//
// Nothing here sleeps and nothing decides on a wall clock: instants are arguments and the fabric's
// clock is advanced by hand.
//
// **Publishing caveat.** A `-only-testing` line naming a non-existent suite — or a *file* rather
// than a `@Suite` struct — matches zero tests and still prints `TEST EXECUTE SUCCEEDED`. Every
// name below was verified against a run showing a non-zero per-suite count before it was published.

import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshP5AcceptanceFailure

/// A precondition a battery scenario could not meet.
///
/// Thrown rather than force-unwrapped so a broken fixture fails as a named error instead of
/// trapping (Power of 10 rule 5) — and so a scenario that could not be built cannot be mistaken for
/// one that ran and passed.
enum MeshP5AcceptanceFailure: Error {

    /// No cell of the routed rectangle carries the shape this clause needs.
    case noCellOfThatShape

    /// The scenario needs a survivor in a branch other than the near one and has none.
    case noFarBranchSurvivor

    /// A member that must hold the item's record does not.
    case recordMissing

    /// The pinned cell could not be re-split, so the nested-cut clause would assert nothing.
    case scheduleHasNoResplit

    /// The heart ledger refused to stand behind a gift it had just committed.
    case ledgerRefusedItsOwnJudgement
}

// MARK: - MeshP5Acceptance

/// The rig the battery's scenarios share: build, run, read, tear down.
///
/// Thin on purpose. Everything expensive is items 1–13's (`MeshConvergenceRun`,
/// `MeshRoutedPipeline`, `MeshRoutedPhotoFixtures`, `MeshRoutedBackpressureAuditCapture`), so a
/// change to any of them is felt in the battery rather than worked around by it.
@MainActor
enum MeshP5Acceptance {

    /// The one seed every scenario in this file replays. Pinned through ``MeshConvergenceSeeds/root``
    /// rather than copied, so the battery and the rectangle cannot drift.
    static var rootSeed: UInt64 { MeshConvergenceSeeds.root }

    /// The routed rectangle's cell for one shape at the root seed, or a named error.
    static func rootCell(_ shape: MeshPartitionShape) throws -> MeshRoutedConvergenceCell {
        let cell = MeshRoutedConvergenceCell(shape: shape, seed: rootSeed)
        guard MeshRoutedConvergenceMatrix.all.contains(cell) else {
            throw MeshP5AcceptanceFailure.noCellOfThatShape
        }
        return cell
    }

    /// The first cell of the rectangle whose overlay satisfies `predicate`, cross-pinned to the
    /// rectangle so a corner can never drift out of the space it is a corner of.
    static func cell(
        where predicate: (MeshRoutedScheduleOverlay) -> Bool
    ) throws -> MeshRoutedConvergenceCell {
        guard let cell = MeshRoutedConvergenceMatrix.all.first(where: { predicate($0.overlay) })
        else { throw MeshP5AcceptanceFailure.noCellOfThatShape }
        return cell
    }

    /// Runs one routed cell end to end on pipeline 1 — no assertions of its own, so each clause can
    /// state its own.
    static func converged(
        _ cell: MeshRoutedConvergenceCell, label: String, resplit: MeshResplitPlan? = nil
    ) async throws -> MeshRoutedCellRun {
        try await MeshRoutedPipeline.fullHeal(cell, label: label, resplit: resplit)
    }

    /// The keys `member` may really move to `peer` — the entitled set an inventory delta must be
    /// computed against.
    ///
    /// `MeshNetworkManager.offerableKeys(to:in:at:)` is private, so this mirrors its increment-1
    /// half: destinations still lacking a recipient receipt (`outstandingItems(at:in:)`, plan §11's
    /// partition-agnostic reading), narrowed to items whose chunks this device holds complete. It is
    /// deliberately a **superset** — the shipping set also subtracts a peer's refusals and the
    /// courier rule — so a clause asserting the set is empty asserts something stronger, never
    /// weaker, than the manager would.
    static func offerable(
        from member: MeshConvergenceMember, to peer: MeshConvergenceMember,
        in run: MeshConvergenceRun, at now: Date
    ) -> Set<MeshRoutedItemKey> {
        guard let index = run.routedIndex(of: member),
              let roster = member.node.manager.membershipVerifier?.roster else { return [] }
        let refs = index.outstandingItems(at: now, in: roster)[peer.fingerprint] ?? []
        return Set(refs.lazy.filter { $0.receivedCount == Int($0.chunkCount) }.map(\.key))
    }

    /// The custody summary the leaver's own **signed departure record** carries, read off whichever
    /// member holds that record.
    ///
    /// This is the observable `handedOffItemCount` is written into
    /// (`MeshDevelopmentPlan.handoffSummary(handedOffItemCount:)` at the departure), as opposed to
    /// `MeshCustodyHandoffResult.transferredItemCount`, which is `transferredItemKeys.count` by
    /// definition and can therefore never disagree with itself.
    static func departureSummary(
        of leaver: MeshConvergenceMember, in run: MeshConvergenceRun
    ) -> MeshCustodyHandoffSummary? {
        // R2: bounded by the roster cap.
        for member in run.members {
            guard let ledger = member.node.manager.membershipVerifier?.ledger else { continue }
            guard let record = ledger.departures.all.first(where: {
                $0.memberFingerprint == leaver.fingerprint
            }) else { continue }
            return record.custodyHandoff
        }
        return nil
    }

    /// Ends every session a run left open, rotation consumed first (D-8.42).
    static func teardown(_ run: MeshConvergenceRun) { MeshRoutedPipeline.teardown(run) }

    /// Every living member's routed digest that actually names something, with the 1024-item cap
    /// asserted on the way past.
    ///
    /// The empty ones are dropped rather than compared: `MeshRoutedInventory.init?` answers a valid
    /// inventory with no entries for an empty index, and two empty digests are quiescent against
    /// each other by construction.
    static func nonEmptyDigests(
        in run: MeshConvergenceRun, at now: Date
    ) -> [MeshP5InventorySample] {
        var samples: [MeshP5InventorySample] = []
        // R2: bounded by the roster cap.
        for member in run.livingMembers {
            guard let index = run.routedIndex(of: member),
                  let inventory = MeshRoutedInventory(
                      meshID: run.meshID, index: index,
                      selfFingerprint: member.fingerprint, at: now
                  ) else { continue }
            #expect(inventory.entries.count <= MeshRoutedInventoryFormat.maxEntries,
                    "a digest grew past the 1024-item cap plan §11 names")
            guard inventory.entries.isEmpty == false else { continue }
            samples.append(MeshP5InventorySample(member: member, inventory: inventory))
        }
        return samples
    }

    /// The non-comment lines of a repo-root-relative source file, for the grep-wall.
    ///
    /// Whole-line comments are dropped because the convergence files *name* the things the wall
    /// forbids — a header that says "no `Date()` here" is the documentation of the rule, not a
    /// violation of it.
    static func codeLines(of relativePath: String) throws -> [String] {
        try MeshP4Acceptance.codeLines(of: relativePath)
    }
}

// MARK: - MeshP5InventorySample

/// One survivor's routed digest, kept beside the member it was built from so the pair's entitlement
/// can be computed rather than assumed.
@MainActor
struct MeshP5InventorySample {

    /// The member whose store the digest describes.
    let member: MeshConvergenceMember

    /// That member's inventory at the clause's instant.
    let inventory: MeshRoutedInventory
}

// MARK: - (a) The manifest

/// **Clause (a): `MeshRoutedManifest` — origin-signed, immutable destination set, expiry = the mesh
/// hard deadline plus the 20-minute development grace.**
///
/// The full space is `MeshRoutedManifestTests` + `MeshRoutedManifestVerifierTests`. What runs here is
/// the manifest a **converged run actually delivered**: relays forward the origin's exact signed
/// object and never re-sign it (plan §11), so every survivor's stored copy must be byte-identical to
/// the origin's, verify at each survivor's own verifier, and carry the same destination set.
@MainActor
@Suite(.serialized)
struct MeshP5ManifestAcceptanceTests {

    /// **Relays forward the origin's exact signed object.** Every survivor holding the item holds
    /// the same manifest bytes the origin signed, and each one's own verifier accepts it.
    @Test func theManifestAConvergedRunDeliveredVerifiesAtEverySurvivor() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5a-manifest")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        guard let origin = run.routedIndex(of: outcome.origin)?
            .record(for: outcome.key)?.manifest else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        var checked = 0
        // R2: bounded by the roster cap.
        for member in run.livingMembers {
            guard let held = run.routedIndex(of: member)?.record(for: outcome.key)?.manifest else {
                continue
            }
            #expect(held == origin, "a survivor holds a manifest the origin never signed")
            let verifier = MeshRoutedManifestVerifier(
                meshID: run.meshID,
                hardDeadline: run.anchor
                    .addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
                ledger: member.node.manager.membershipVerifier?.ledger ?? .empty,
                acceptedTypeTokens: MeshRoutedTypeRegistry.increment1.tokens
            )
            #expect(verifier.verify(held) == nil, "a delivered manifest failed its own verifier")
            checked += 1
        }
        #expect(checked > 1, "fewer than two survivors held the manifest, so nothing was compared")
    }

    /// **The destination set is the full derived roster at creation, and never moves.**
    @Test func theDestinationSetIsTheFullRosterAtCreationAndNeverMoves() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5a-destinations")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        guard let manifest = run.routedIndex(of: outcome.origin)?
            .record(for: outcome.key)?.manifest else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        #expect(manifest.destinations.contains(outcome.origin.fingerprint) == false,
                "an origin is never a destination of its own item")
        #expect(manifest.destinations.count == cell.shape.rosterSize - 1,
                "the destination set is the roster at creation, minus the origin")
        // R2: bounded by the roster cap.
        for member in run.livingMembers {
            guard let held = run.routedIndex(of: member)?.record(for: outcome.key)?.manifest else {
                continue
            }
            #expect(held.destinations == manifest.destinations,
                    "a destination set was mutated after the mint")
        }
    }

    /// **The expiry is the hard deadline plus the development grace, on the injected clock.**
    ///
    /// Anchored to the run's own `anchor + MeshSessionCeiling.ceilingSeconds` — the mesh's signed
    /// creation instant plus the ceiling, which is what the verifier pins a manifest's expiry to —
    /// rather than to a literal. A new fixture that re-pins the mint to a fixed date while the mesh
    /// rolls fails the first expectation; a fixture that pins BOTH to a stale date (item 6a's 2027
    /// bomb) fails the last, which is the check that would have caught 6a on the day it landed.
    @Test func theExpiryIsTheHardDeadlinePlusTheDevelopmentGrace() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5a-expiry")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        guard let manifest = outcome.run.routedIndex(of: outcome.origin)?
            .record(for: outcome.key)?.manifest else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        let deadline = outcome.run.anchor.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        #expect(manifest.expiresAt == MeshRoutedManifest.expiry(afterHardDeadline: deadline),
                "the expiry is the injected hard deadline plus the development grace")
        #expect(manifest.expiresAt.timeIntervalSince(MeshRoutedManifest.floored(deadline))
                == MeshRoutedManifestFormat.developmentGraceSeconds,
                "and the grace is exactly the registered twenty minutes")
        #expect(manifest.expiresAt > outcome.run.anchor,
                "the expiry is anchored to the injected clock, not to a stale fixture date")
        #expect(manifest.expiresAt > Date(),
                "the anchor must roll with the wall clock, never sit on a date it walks past")
    }
}

// MARK: - (b) Chunks, custody, receipts and the inventory bound

/// **Clause (b): `MeshChunk` (≤ 256 KiB, explicit index/count), `MeshCustodyReceipt` (relay has
/// durable ciphertext), `MeshRecipientReceipt` (destination-final), `MeshInventoryDigest` bounded by
/// the 1024-item cap.**
///
/// The full space is `MeshChunkTests`, `MeshRoutedCustodyTests`, `MeshRecipientReceiptTests`,
/// `MeshRoutedInventoryTests` and `MeshRoutedInventoryDeltaTests`. What runs here is the corner where
/// all four meet: a **multi-chunk** item — one a single frame cannot finish — carried to convergence,
/// with the bytes re-measured at both populations that claim them and the digest bounded and
/// quiescent for the healed pair.
@MainActor
@Suite(.serialized)
struct MeshP5CustodyAndReceiptAcceptanceTests {

    /// **An item a single frame cannot finish converges anyway**, and the rectangle really carries
    /// one — the cross-pin is the point.
    @Test func aMultiChunkItemConvergesAndTheRectangleCarriesOne() async throws {
        let cell = try MeshP5Acceptance.cell { !$0.sealed && $0.chunks == 3 }
        #expect(MeshRoutedConvergenceMatrix.all.contains(cell), "the corner is IN the rectangle")
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5b-chunks")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        guard let record = outcome.run.routedIndex(of: outcome.origin)?.record(for: outcome.key)
        else { throw MeshP5AcceptanceFailure.recordMissing }
        #expect(record.chunkCount > 1, "the corner's item must not fit in one frame")
        #expect(record.chunks.count == Int(record.chunkCount), "the origin holds every chunk")
        // R2: bounded by the item's own chunk count.
        for stored in record.chunks {
            #expect(stored.payloadByteCount <= MeshChunkFormat.maxChunkPayloadBytes,
                    "a chunk claims more than the 256 KiB wire bound")
        }
    }

    /// **Custody ≠ delivery, as two distinct receipt kinds on one record** — and the bytes behind
    /// both are re-measurable, at every delivered destination and at every receipted custodian.
    @Test func custodyAndDeliveryAreDistinctReceiptsAndTheBytesAreOnDisk() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5b-receipts")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        outcome.run.routedInvariants(
            outcome.origin, outcome.key, audited: capture,
            overlay: cell.overlay, before: outcome.before
        )
        var read = 0
        // R2: bounded by the roster cap.
        for member in outcome.run.livingMembers where member.index != outcome.origin.index {
            guard let record = outcome.run.routedIndex(of: member)?.record(for: outcome.key) else {
                continue
            }
            let custodians = Set(record.receipts.map(\.custodianFingerprint))
            #expect(custodians.contains(member.fingerprint) == false,
                    "a device stores its OWN custody receipt, which is re-minted, never held")
            // Custody ≠ delivery, as a state rather than as a count: a device can hold durable
            // ciphertext (`isCustodied`) with no ack instant, and the ack instant is what a final
            // receipt is minted from. A build that read one as the other would stamp them together.
            if record.deliveredAt != nil {
                #expect(record.isCustodied,
                        "a delivery was acknowledged for an item this device never held durably")
            }
            if outcome.run.routedAssembledBlob(at: member, key: outcome.key) != nil { read += 1 }
        }
        #expect(read > 0, "no destination could reassemble the item from its own sealed chunk files")
    }

    /// **The inventory is bounded by the 1024-item cap and the healed pair reaches quiescence.**
    ///
    /// The digest's whole space is `MeshRoutedInventoryTests` / `MeshRoutedInventoryDeltaTests`; what
    /// runs here is the digest a converged run actually holds.
    ///
    /// Three things keep it from passing vacuously. The pair is drawn from survivors whose digest
    /// is **non-empty** (`MeshRoutedInventory.init?` answers a valid inventory with no entries for an
    /// empty index, and item 9's reclaim produces exactly that at the members that converged best);
    /// the entitled set is **computed** rather than passed empty, because `manifestsToOffer` and
    /// `chunksToOffer` iterate `where entitled.contains(key)` and an empty fixture set zeroes two of
    /// the six lists `isQuiescent` reads; and the predicate is
    /// `MeshRoutedInventoryDelta.converged(local:peerReportsQuiescent:)` — the one the type documents
    /// as convergence — rather than a single side's strictly local `isQuiescent`.
    @Test func theInventoryStaysInsideItsCapAndTheHealedPairIsQuiescent() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5b-inventory")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        let now = MeshRoutedPipeline.mintInstant
        let digests = MeshP5Acceptance.nonEmptyDigests(in: run, at: now)
        #expect(digests.count >= 2,
                "the clause needs two survivors that actually hold routed content")
        guard let first = digests.first, let second = digests.dropFirst().first else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        let outward = MeshP5Acceptance.offerable(
            from: first.member, to: second.member, in: run, at: now
        )
        let inward = MeshP5Acceptance.offerable(
            from: second.member, to: first.member, in: run, at: now
        )
        #expect(outward.isEmpty && inward.isEmpty,
                "a converged pair still had an entitled item to offer the other")
        let local = MeshRoutedInventoryDelta.between(
            local: first.inventory, remote: second.inventory, offerableToPeer: outward
        )
        let remote = MeshRoutedInventoryDelta.between(
            local: second.inventory, remote: first.inventory, offerableToPeer: inward
        )
        guard let local, let remote else {
            Issue.record("two digests of one mesh must always produce a delta")
            return
        }
        #expect(MeshRoutedInventoryDelta.converged(
            local: local, peerReportsQuiescent: remote.isQuiescent
        ), "a healed pair that converged still had routed work to exchange")
    }
}

// MARK: - (c) The acknowledgement stages

/// **Clause (c): photos and texts are final on durable recipient storage; hearts are final only
/// after a foreground decrypt and a ledger commit; control is immediate.**
///
/// The full space is `MeshRoutedDeliveryAckTests`. What runs here is the stage table's consequence
/// inside a **converging mesh**: no convergence cell mints a heart today, so a heart routed across a
/// partition is new coverage — and it must stop at `custodied` with a NAMED shortfall rather than
/// close on durable ciphertext the way a photo does.
///
/// The closing half is driven at the store's own `committingDelivery` door with real ledger
/// evidence, because the manager's re-entry heart job is a documented, counted no-op until P6
/// (item 10's `reentryHeartStage`) — asserting it through the manager would be asserting P6.
@MainActor
@Suite(.serialized)
struct MeshP5AckStageAcceptanceTests {

    /// **A heart routed across a partition stops at custody.** Durable ciphertext is not enough:
    /// the stage asks for a ledger judgement, and until one exists the destination stays outstanding.
    @Test(arguments: MeshRoutedConvergenceMatrix.corners)
    func aHeartStopsAtCustodyUntilItsLedgerJudgement(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p5c-heart", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP5Acceptance.teardown(run) }
        try await run.runSplitEvents()
        let origin = try #require(run.livingMembers.first, "the clause needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        let key = try run.routedCustodyEvent(
            at: origin, chunks: 1, now: now, typeToken: MeshRoutedTypeToken.heart
        )
        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let owed = Set(run.routedOutstanding(at: origin, key: key))
        #expect(owed.isEmpty == false,
                "a heart closed on durable ciphertext alone — the foreground-commit rule is gone")
        var custodied = 0
        // R2: bounded by the roster cap.
        for member in run.livingMembers where member.index != origin.index {
            guard let record = run.routedIndex(of: member)?.record(for: key) else { continue }
            #expect(record.deliveredAt == nil, "a heart was acknowledged with no ledger judgement")
            if record.isCustodied { custodied += 1 }
        }
        #expect(custodied > 0, "no destination even took custody, so the stage was not exercised")
    }

    /// **And it closes the moment a real ledger judgement stands behind it.** Same item, same store,
    /// the only difference being the evidence — which is what makes the first test a stage claim
    /// rather than an "it never delivers" claim.
    @Test func aHeartClosesOnceItsLedgerJudgementStands() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p5c-heartcommit", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP5Acceptance.teardown(run) }
        try await run.runSplitEvents()
        let origin = try #require(run.livingMembers.first, "the clause needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        let key = try run.routedCustodyEvent(
            at: origin, chunks: 1, now: now, typeToken: MeshRoutedTypeToken.heart
        )
        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: origin, key: key)

        let holder = try #require(run.livingMembers.first {
            $0.index != origin.index
                && run.routedIndex(of: $0)?.record(for: key)?.isCustodied == true
        }, "the clause needs a destination holding durable custody")
        let ledger = MeshRoutedAckFixtures.ledger()
        let outcome = MeshHeartCommit.commit(
            [MeshRoutedAckFixtures.heart(key.itemID, sender: origin.fingerprint)], into: ledger
        )
        guard let ack = MeshRoutedHeartAck(outcome: outcome, giftID: key.itemID, ledger: ledger)
        else { throw MeshP5AcceptanceFailure.ledgerRefusedItsOwnJudgement }
        let committed = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) {
            MeshRoutedStore(scope: holder.node.store.meshRoutedStorage).committingDelivery(
                item: key, recipient: holder.fingerprint,
                stages: MeshRoutedTypeRegistry.increment1.ackStages,
                evidence: .heartLedgerCommit(ack), now: now
            )
        }
        guard case .completed(.acknowledged(let witness)) = committed else {
            Issue.record("the heart stage refused a real ledger judgement: \(committed)")
            return
        }
        #expect(witness.ackStage == .foregroundDecryptAndLedgerCommit,
                "the witness must name the stage that actually gated it")
    }

    /// **A photo is final on durable ciphertext, with no decrypt in the path.** The same converged
    /// run, an item whose gate was never opened, reaching `delivered` at every destination.
    @Test func aPhotoIsFinalOnDurableCiphertextWithNoDecryptInThePath() async throws {
        let cell = try MeshP5Acceptance.cell { !$0.sealed && $0.capacityMember == nil
            && $0.unknownTypeMember == nil }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5c-photo")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        guard let target = run.routedIndex(of: outcome.origin)?
            .record(for: outcome.key)?.deliveryTarget else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        guard let roster = outcome.origin.node.manager.membershipVerifier?.roster else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        var delivered = 0
        // R2: bounded by the roster cap.
        for (destination, disposition) in target.dispositions(in: roster) {
            switch disposition {
            case .delivered: delivered += 1
            case .departed: continue
            case .pending, .custodied:
                Issue.record("a photo destination never reached delivered: \(destination)")
            }
        }
        #expect(delivered > 0, "no destination reached delivered, so the stage proved nothing")
        // R2: bounded by the roster cap.
        for member in run.livingMembers {
            #expect(member.node.manager.meshPhotos.contains { $0.id == outcome.key.itemID } == false,
                    "an opaque item reached a canonical store, so a decrypt was in the ack path")
        }
    }
}

// MARK: - (d) Backpressure

/// **Clause (d): at the 256 MiB / 1024-item caps, refuse new custody with a bounded, user-visible
/// delivery failure. Nothing grows silently.**
///
/// The full space is `MeshRoutedBackpressureTests` + `MeshRoutedCapacityTests`. What runs here is a
/// cap reached **inside a converging mesh**: the refusal is named at the refusing device, the leg
/// stays outstanding rather than closing quietly, and the origin's own copy is untouched.
@MainActor
@Suite(.serialized)
struct MeshP5BackpressureAcceptanceTests {

    /// **A capped destination refuses, says so, and loses nothing.**
    @Test func aCappedDestinationRefusesVisiblyAndTheOriginKeepsItsCopy() async throws {
        let cell = try MeshP5Acceptance.cell { $0.capacityMember != nil }
        #expect(MeshRoutedConvergenceMatrix.all.contains(cell), "the corner is IN the rectangle")
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5d-capacity")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        guard let index = cell.overlay.capacityMember,
              let capped = run.participant(global: index) else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        let hold = capped.node.manager.routedDeliveryHold
        #expect(hold?.cause == .storeFull,
                "a refusal that names no state at all is the silent stall this clause forbids")
        #expect(run.routedIndex(of: outcome.origin)?.record(for: outcome.key) != nil,
                "the origin's own copy is intact — backpressure is not data loss")
        #expect(run.routedOutstanding(at: outcome.origin, key: outcome.key)
                .contains(capped.fingerprint),
                "a capacity refusal must leave the delivery outstanding, never quietly closed")
    }

    /// **The hold is bounded.** Its item count cannot exceed the store's own item cap — the
    /// "bounded growth" half of the same rule.
    @Test func theHoldIsBoundedByTheStoresOwnCaps() async throws {
        let cell = try MeshP5Acceptance.cell { $0.capacityMember != nil }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5d-bounded")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        guard let index = cell.overlay.capacityMember,
              let capped = outcome.run.participant(global: index),
              let hold = capped.node.manager.routedDeliveryHold else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        #expect(hold.itemCount >= 0 && hold.itemCount <= MeshRoutedStoreFormat.maxItems,
                "a hold reported more held items than the store can hold")
    }

    /// **An over-cap admission is refused, not absorbed.** The capped member's index still holds the
    /// planted hog and nothing else: the item never landed there.
    @Test func anOverCapAdmissionIsRefusedRatherThanAbsorbed() async throws {
        let cell = try MeshP5Acceptance.cell { $0.capacityMember != nil }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5d-refused")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        guard let index = cell.overlay.capacityMember,
              let capped = outcome.run.participant(global: index) else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        #expect(outcome.run.routedIndex(of: capped)?.record(for: outcome.key) == nil,
                "a store at its byte cap admitted the item anyway")
    }
}

// MARK: - (e) The locked device

/// **Clause (e): ciphertext-only custody while locked; decryption and canonical-store mutation wait
/// for unlock; the four-state sidecar plus §19.5's fifth wrinkle; the identity key's keychain
/// protection is never weakened for background decryption.**
///
/// The full space is `MeshRoutedAccessGateTests` + `MeshRoutedStoreTests`. What runs here is a lock
/// window **inside a converging mesh**: nothing moves while the gate is shut, `deferred` is visibly
/// distinct from `absent`, and the unlock edge runs its re-entry exactly once.
@MainActor
@Suite(.serialized)
struct MeshP5LockedDeviceAcceptanceTests {

    /// **Nothing moves inside the window, and the audit says why.** The on-disk snapshot is
    /// byte-identical across the window and at least one `readSuppressed` line carries a
    /// `deferred:` state — a window that was silently `.loaded` proves nothing.
    @Test func aLockedWindowMovesNoByteAndSaysItDeferred() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p5e-window", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP5Acceptance.teardown(run) }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try await run.runSplitEvents()
        let origin = try #require(run.livingMembers.first, "the clause needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        let key = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        let before = MeshRoutedStoreFixtures.snapshot(origin.node.store.meshRoutedStorage)
        var sampled = false
        try await run.routedLockWindowEvent(at: origin, closingAfter: key, now: now) {
            sampled = true
            #expect(MeshRoutedStoreFixtures.snapshot(origin.node.store.meshRoutedStorage) == before,
                    "an index was overwritten while every store was deferred")
            #expect(capture.values(of: "mesh.routedStore.readSuppressed", key: "state")
                    .contains { $0.hasPrefix("deferred:") },
                    "the window was silently loaded, so it proved nothing")
        }
        #expect(sampled, "the window never sampled, so the clause asserted nothing")
    }

    /// **`deferred` is not `absent`, and neither is read as "nothing is held".** The same store, one
    /// binding apart, answers two different states — the discrimination invariant 7 is about.
    @Test func aDeferredStoreIsDistinctFromAnAbsentOne() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p5e-deferred", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP5Acceptance.teardown(run) }
        try await run.runSplitEvents()
        let origin = try #require(run.livingMembers.first, "the clause needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        _ = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        let store = MeshRoutedStore(scope: origin.node.store.meshRoutedStorage)
        let loaded = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) { store.load() }
        let deferred = DeviceBindingID.$testOverride.withValue(.readError) { store.load() }
        guard case .loaded = loaded else {
            Issue.record("the origin's own store did not load after its own mint")
            return
        }
        guard case .deferred = deferred else {
            Issue.record("an unreadable binding did not defer, so deferred is indistinguishable")
            return
        }
        var readsAbsent = false
        if case .absent = run.routedLoadState(of: origin) { readsAbsent = true }
        #expect(readsAbsent == false, "a store holding an item must never read as absent")
    }

    /// **The unlock edge runs its re-entry, once, and reports what it did.** The convergence cell
    /// discards the returned report; the clause is what makes "it ran once" a fact.
    @Test func theUnlockEdgeReportsExactlyOneReentryPass() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p5e-reentry", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP5Acceptance.teardown(run) }
        try await run.runSplitEvents()
        let origin = try #require(run.livingMembers.first, "the clause needs a surviving origin")
        let now = MeshRoutedPipeline.mintInstant
        let key = try run.routedCustodyEvent(at: origin, chunks: 1, now: now)
        let report = try await run.routedLockWindowEvent(
            at: origin, closingAfter: key, now: now
        )
        let unwrapped = try #require(report, "the unlock edge ran no re-entry pass at all")
        #expect(unwrapped.legs.isRising, "an unlock is a RISING edge, or it runs no plaintext work")
        #expect(unwrapped.committedCustodyCount >= 0 && unwrapped.acksFiled >= 0)
        let second = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) {
            origin.node.manager.applyRoutedAccessGate(
                MeshRoutedAccessGate(
                    protectedDataAvailable: true, appIsForeground: true, duressActive: false
                ),
                now: now
            )
        }
        #expect(second == nil,
                "the same open gate pushed twice ran a second pass — the edge is not an edge")
    }
}

// MARK: - (f) The partition drain

/// **Clause (f): the routed store is the source for §10.3's drain — delivery targets are
/// "destinations lacking a `MeshRecipientReceipt`", which is partition-agnostic by construction.**
///
/// The full space is the 40-cell routed rectangle. What runs here is its widest corner (roster 8,
/// `4/2/2`), §16.2's fifth shape (a nested re-split mid-merge), and the merge window's own closure
/// reason — which is what makes "it converged" different from "the peers it waited on went away".
@MainActor
@Suite(.serialized)
struct MeshP5PartitionDrainAcceptanceTests {

    /// **The widest shape §16.2 names drains to convergence** under all twelve routed invariants.
    @Test func theWidestPartitionShapeDrainsToConvergence() async throws {
        let cell = try MeshP5Acceptance.rootCell(.fourTwoTwo)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5f-widest")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        outcome.run.routedInvariants(
            outcome.origin, outcome.key, audited: capture,
            overlay: cell.overlay, before: outcome.before
        )
        #expect(outcome.run.schedule.shape.rosterSize == 8, "the corner is roster 8, three branches")
    }

    /// **A routed item survives a nested re-split mid-merge** — §16.2's fifth shape, with the cut
    /// landing while §10.3's exchange is still open.
    @Test func aRoutedItemSurvivesANestedResplitMidMerge() async throws {
        let cell = try MeshP5Acceptance.rootCell(.fourTwoTwo)
        guard let plan = MeshScheduleGenerator.resplit(for: cell.schedule) else {
            throw MeshP5AcceptanceFailure.scheduleHasNoResplit
        }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let outcome = try await MeshP5Acceptance.converged(
            cell, label: "p5f-resplit", resplit: plan
        )
        defer { MeshP5Acceptance.teardown(outcome.run) }
        outcome.run.routedInvariants(
            outcome.origin, outcome.key, audited: capture,
            overlay: cell.overlay, before: outcome.before
        )
        #expect(outcome.run.resplit != nil, "the cut never landed, so the clause asserted nothing")
    }

    /// **A merge window that closed says WHY it closed** (D-7.20). At least one survivor closed
    /// `.converged`; a `.nothingOutstanding` closure is honest only where the roster really shrank.
    ///
    /// The battery deliberately does **not** claim every window closes: D-7.15 leaves three residual
    /// shapes — an asked, reachable, silent peer; a peer un-matched under D-7.27 that stopped
    /// speaking; a pair whose per-session re-gossip budget is spent — and a window still open after
    /// the heal is recorded here, never failed.
    @Test func aClosedMergeWindowNamesItsOwnReason() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5f-window")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        var converged = 0
        // R2: bounded by the roster cap.
        for member in outcome.run.livingMembers {
            switch member.node.manager.lastMergeClosureForTesting {
            case .converged: converged += 1
            case .nothingOutstanding:
                #expect(outcome.run.livingMembers.count < cell.shape.rosterSize,
                        "a window closed on unreachable peers in a mesh that lost nobody")
            case nil:
                // A window that stayed open is one of D-7.15's three residual shapes and is never
                // failed for staying open — but it is still held to its own proof cap, so this arm
                // asserts a bound that CAN break rather than one it cannot exceed by construction.
                guard let window = member.node.manager.mergeWindowForTesting else { continue }
                #expect(window.proofCount <= MeshMergeWindow.maxProofs,
                        "an open merge window advertised more digests than its own cap allows")
            }
        }
        #expect(converged > 0, "no survivor's merge window closed on a matching digest")
    }
}

// MARK: - (g) The type-token registry

/// **Clause (g): unknown type tokens are rejected, not forwarded.**
///
/// The full space is `MeshRoutedTypeRegistryTests`. What runs here is a receiver whose registry does
/// not know the item's token **inside a converging run**: it refuses the item, the leg stays
/// outstanding under I-1's planted-excuse arm, nothing is forwarded, and the rest of the mesh still
/// converges.
@MainActor
@Suite(.serialized)
struct MeshP5TypeRegistryAcceptanceTests {

    /// **An unregistered token is refused at the drain and the run still converges.**
    @Test func anUnregisteredTokenIsRefusedAndTheRunStillConverges() async throws {
        let cell = try MeshP5Acceptance.cell { $0.unknownTypeMember != nil }
        #expect(MeshRoutedConvergenceMatrix.all.contains(cell), "the corner is IN the rectangle")
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5g-unknown")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        outcome.run.routedInvariants(
            outcome.origin, outcome.key, audited: capture,
            overlay: cell.overlay, before: outcome.before
        )
        guard let index = cell.overlay.unknownTypeMember,
              let receiver = outcome.run.participant(global: index) else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        #expect(receiver.node.manager.routedTypeRegistryForTesting?
            .entry(for: MeshRoutedTypeToken.photo) == nil,
                "the corner's receiver still knows the token, so nothing was refused")
    }

    /// **A refusal is not a delivery, and nothing is forwarded.** The narrowed receiver holds no
    /// record for the item, and the origin still owes it.
    @Test func aRefusedTypeIsNeitherDeliveredNorForwarded() async throws {
        let cell = try MeshP5Acceptance.cell { $0.unknownTypeMember != nil }
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5g-notforwarded")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        guard let index = cell.overlay.unknownTypeMember,
              let receiver = outcome.run.participant(global: index) else {
            throw MeshP5AcceptanceFailure.recordMissing
        }
        #expect(outcome.run.routedIndex(of: receiver)?.record(for: outcome.key) == nil,
                "a custodian that does not recognise the type admitted the item anyway")
        #expect(outcome.run.routedOutstanding(at: outcome.origin, key: outcome.key)
            .contains(receiver.fingerprint),
                "an unknown-type refusal was read as a delivery")
    }
}

// MARK: - (h) The relay scope

/// **Clause (h): increment 1 ships origin-retains plus custody-transfer-on-departure. There is no
/// live third-party relay of in-flight chunks.**
///
/// The full space is `MeshRoutedCustodyHandoffTests`. What runs here is a development taken **while
/// the far branch is still owed the item** — the only shape in which the transfer has candidates at
/// all — with both of its preconditions asserted per cell, so the suite cannot become vacuous.
@MainActor
@Suite(.serialized)
struct MeshP5RelayScopeAcceptanceTests {

    /// **A development hands custody only to custodians it named AND served.**
    @Test func aDevelopmentHandsCustodyOnlyToCustodiansItNamedAndServed() async throws {
        guard let cell = MeshRoutedConvergenceMatrix.developing.first else {
            throw MeshP5AcceptanceFailure.noCellOfThatShape
        }
        let outcome = try await MeshRoutedPipeline.development(cell, label: "p5h-handoff")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        outcome.run.routedHandoffBound(
            origin: outcome.origin, key: outcome.key, developing: true
        )
        MeshP5Acceptance.teardown(outcome.run)
        // R2: a hard constant ceiling.
        for _ in 0..<16 { await Task.yield() }
    }

    /// **`handedOffItemCount` is real**: the transferred keys are the item, and the number the
    /// **signed departure record** carries is that list's own length rather than a tally of intent.
    ///
    /// Read off the record, never off `MeshCustodyHandoffResult.transferredItemCount`: that property
    /// *is* `transferredItemKeys.count`, so comparing the two is a compile-time tautology no
    /// mutation of the shipping seam can break. What can be wrong is the number
    /// `MeshDevelopmentPlan.handoffSummary(handedOffItemCount:)` was handed at the departure.
    @Test func theHandedOffCountIsTheTransferredListItself() async throws {
        guard let cell = MeshRoutedConvergenceMatrix.developing.first else {
            throw MeshP5AcceptanceFailure.noCellOfThatShape
        }
        let outcome = try await MeshRoutedPipeline.development(cell, label: "p5h-count")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let handoff = outcome.origin.node.manager.lastDevelopmentHandoff ?? .none
        #expect(handoff.transferredItemKeys == [outcome.key],
                "the transfer named an item other than the one the cell minted")
        let signed = MeshP5Acceptance.departureSummary(of: outcome.origin, in: outcome.run)
        #expect(signed?.handedOffItemCount == handoff.transferredItemKeys.count,
                "the count the departure record signs is not the transferred list's own length")
        MeshP5Acceptance.teardown(outcome.run)
        // R2: a hard constant ceiling.
        for _ in 0..<16 { await Task.yield() }
    }

    /// **No live third-party relay while the origin is alive.** On a converged, non-developing cell
    /// no survivor carries a `custodied(by:)` rung naming anybody but the destination itself —
    /// increment 2 is not shipped, and a plausible-looking widening would remove exactly this.
    @Test func noThirdPartyCourierAppearsWhileTheOriginIsAlive() async throws {
        let cell = try MeshP5Acceptance.rootCell(.threeThree)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5h-nohop")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        outcome.run.routedHandoffBound(
            origin: outcome.origin, key: outcome.key, developing: false
        )
    }
}

// MARK: - (i) Replay and dedup

/// **Clause (i): `MeshFrameReplayWindow` against content ids — a re-presented frame changes nothing.**
///
/// The full space is `MeshFrameReplayWindowTests` + item 12's four door suites. What runs here is a
/// replay **inside a converged run**: the receiver's sealed store, its rung ladder and both receipt
/// counts are byte-identical across the dispatch, and the window holds both of its axes.
@MainActor
@Suite(.serialized)
struct MeshP5ReplayAcceptanceTests {

    /// **A replayed manifest moves no byte, no rung and no receipt count.**
    @Test func aReplayedManifestMovesNothingAtAll() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5i-replay")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        let victim = try #require(run.livingMembers.first {
            $0.index != outcome.origin.index
                && run.routedIndex(of: $0)?.record(for: outcome.key)?.manifest != nil
        }, "the clause needs a survivor that already admitted the manifest")
        try run.routedReplayChangesNothing(
            at: victim, from: outcome.origin, frame: outcome.key, captured: outcome.manifest,
            now: MeshRoutedPipeline.mintInstant.addingTimeInterval(120)
        )
    }

    /// **The window holds both of its axes**: frames per sender and distinct senders.
    @Test func theReplayWindowStaysInsideBothOfItsCaps() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let outcome = try await MeshP5Acceptance.converged(cell, label: "p5i-caps")
        defer { MeshP5Acceptance.teardown(outcome.run) }
        let run = outcome.run
        let victim = try #require(run.livingMembers.first {
            $0.index != outcome.origin.index
                && run.routedIndex(of: $0)?.record(for: outcome.key)?.manifest != nil
        }, "the clause needs a survivor that already admitted the manifest")
        try run.routedReplayChangesNothing(
            at: victim, from: outcome.origin, frame: outcome.key, captured: outcome.manifest,
            now: MeshRoutedPipeline.mintInstant.addingTimeInterval(180)
        )
        let window = try #require(victim.node.manager.routedReplayWindowForTesting,
                                  "the receiver recorded no frame at all")
        #expect(window.trackedSenderCount <= window.maxSenders,
                "the window tracks more senders than its own cap")
        #expect(window.recordedCount(for: outcome.origin.fingerprint) <= window.framesPerSender,
                "the window remembers more frames than its per-sender cap")
        #expect(window.trackedSenderCount > 0, "an empty window would prove nothing")
    }
}

// MARK: - (k) Other-branch content

/// **Clause (k): content minted in one branch reaches the other branch's canonical store after the
/// heal — the clause the three `keyEpoch` gates were retired FOR.**
///
/// The full space is `MeshRoutedPhotoDeliveryTests`. What runs here is its property-level form: a
/// **real sealed photo**, minted at a survivor in a branch other than the near one, reaching the near
/// branch's `meshPhotos` wall exactly once after the heal. Before item 13 the direct-decrypt path's
/// `keyEpoch` gates refused exactly this; nothing else in the battery would notice their return.
@MainActor
@Suite(.serialized)
struct MeshP5OtherBranchDeliveryAcceptanceTests {

    /// **A far-branch sealed photo reaches the near branch's wall, exactly once.**
    @Test func aFarBranchSealedPhotoReachesTheNearBranchWallExactlyOnce() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p5k-farbranch", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP5Acceptance.teardown(run) }
        try await run.runSplitEvents()
        let near = try #require(run.livingMembers.first, "the clause needs a near-branch survivor")
        guard let far = run.livingMembers.first(where: { $0.branch != near.branch }) else {
            throw MeshP5AcceptanceFailure.noFarBranchSurvivor
        }
        let now = MeshRoutedPipeline.mintInstant
        run.openEveryRoutedGate(now: now)
        let key = try run.routedSealedPhotoEvent(at: far, now: now)
        #expect(near.node.manager.meshPhotos.isEmpty,
                "the precondition: the near branch was away when the photo was minted")

        try await run.runHeal()
        try await run.runRoutedDrainRounds(origin: far, key: key)

        #expect(near.node.manager.meshPhotos.filter { $0.id == key.itemID }.count == 1,
                "the branch that was away shows the photo exactly once after the heal")
    }

    /// **The cell is one the sealed rectangle really runs**, and the tree carries a far-branch mint
    /// of its own — the cross-pin, so this corner cannot drift out of its space.
    @Test func theSealedRectangleCoversTheWholeTree() {
        #expect(MeshRoutedConvergenceMatrix.sealedTree.count == MeshPartitionShape.matrix.count,
                "one sealed cell per shape §16.2 names")
        #expect(MeshRoutedConvergenceMatrix.sealedTree.allSatisfy { $0.seed == MeshConvergenceSeeds.root },
                "the sealed tree runs the pinned root seed")
        #expect(MeshRoutedConvergenceMatrix.all.contains(
            MeshRoutedConvergenceCell(shape: .twoTwo, seed: MeshConvergenceSeeds.root)
        ), "the corner is IN the rectangle")
        #expect(MeshRoutedConvergenceMatrix.all.contains { $0.overlay.farBranchMint },
                "no cell of the rectangle mints outside the near branch at all")
    }
}

// MARK: - (j) Honesty

/// **The rectangle is whole and nothing is deferred.**
///
/// A battery that could quietly shrink its own matrix would prove nothing. So: 40 of 40 declared
/// routed cells run, `deferred` is asserted **empty as a positive claim** rather than counted to
/// zero, and each sub-rectangle is pinned to the arithmetic that derives it.
@MainActor
@Suite(.serialized)
struct MeshP5HonestyAcceptanceTests {

    /// **40 of 40, nothing deferred, every sub-rectangle derived rather than drawn.**
    @Test func theRoutedRectangleIsWholeAndNothingIsDeferred() {
        let declared = MeshPartitionShape.matrix.count * MeshConvergenceSeeds.derivedCount
        #expect(declared == 40, "5 shapes × 8 fixed seeds is the routed rectangle")
        #expect(MeshRoutedConvergenceMatrix.deferred.isEmpty,
                "a positive claim, not a zero count: nothing may be deferred without its own note")
        #expect(MeshRoutedConvergenceMatrix.all.count == declared, "and every cell runs")
        #expect(Set(MeshRoutedConvergenceMatrix.all.map(\.shape.rosterSize)) == [3, 4, 6, 8],
                "§16.2's four rosters all carry routed cells")
        #expect(MeshRoutedConvergenceMatrix.developing.count >= 8,
                "the development rectangle must not shrink to nothing")
        #expect(MeshRoutedConvergenceMatrix.developing
            .allSatisfy { MeshRoutedConvergenceMatrix.all.contains($0) },
                "the development cells are selected from the rectangle, never drawn beside it")
        #expect(MeshRoutedConvergenceMatrix.corners.count == 2,
                "the corner list is the root seed and its first successor")
    }

    /// **What the battery deliberately does NOT claim, named rather than implied.**
    ///
    /// Tier 2 is owed, not run: real QUIC chunk pacing at 256 KiB across 3–6 Simulators, whether a
    /// large transfer starves the control stream, whether relay increment 2 is needed at all, item
    /// 6b's main-actor drain I/O and item 9's cap re-measurement. And D-7.15's liveness: after the
    /// post-merge proof door a merge window is not guaranteed to close, so the battery asserts
    /// progress under its own bounded schedule and why a window that closed closed — never "every
    /// window closes".
    ///
    /// **P5's own deferrals, named so no reader takes a bound that does not exist.** D-12.14 left
    /// three **pre-store refusal channels** — `notADestinationOrHandoff`,
    /// `unknownItemNotFromOrigin` and `unregisteredTypeChunk` — unbounded in count; the P5 review's
    /// correction bounded them per authenticated sender (`MeshRoutedRefusalBudget`, asserted in
    /// `MeshRoutedRefusalBudgetTests`, not here), and the three names still stand in the source as
    /// the refusals that budget charges. D-12.15 leaves a receipt re-mint staleness (a re-minted
    /// custody receipt can quote an instant older than the frame that prompted it). Item 9's
    /// reclaim never fires for an item **all** of whose destinations departed, so such an item is
    /// held to its expiry rather than dropped. Neither of those two is asserted here, and neither
    /// is asserted away either.
    @Test func theBatteryNamesWhatItDoesNotClaim() throws {
        #expect(MeshRoutedEventToken.vocabulary.count == 9,
                "the routed vocabulary is nine tokens; a tenth needs its own planned draw")
        #expect(MeshRoutedEventToken.allCases.contains(.development),
                "custody transfer on departure is increment 1's load-bearing relay case")
        #expect(MeshRoutedTypeRegistry.increment1.tokens.count == 3,
                "increment 1 registers three routed types, and the fourth is P6's")
        #expect(MeshRoutedTypeRegistry.increment1.entry(for: MeshRoutedTypeToken.control) == nil,
                "the control token is reserved and deliberately unregistered")
        // The three refusal channels are named in the shipping source, not in an enum this file can
        // read, so the record is pinned the way the grep-wall pins the other unassertable facts:
        // a rename or a deletion moves this line, and the doc comment above stops being true. Since
        // the P5 review's correction each is charged to the sender's budget, whose spend line is
        // pinned beside them.
        let source = try MeshP5Acceptance.codeLines(
            of: "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift"
        ).joined(separator: "\n")
        // R2: a fixed three-element list.
        for reason in ["notADestinationOrHandoff", "unknownItemNotFromOrigin",
                       "unregisteredTypeChunk"] {
            #expect(source.contains(reason),
                    "a pre-store refusal D-12.14 named is no longer named")
        }
        #expect(source.contains("mesh.routedDrain.refusalBudgetSpent"),
                "the per-sender bound the review added to D-12.14's channels is gone")
    }
}

// MARK: - The fixed seed, and the walls that keep it fixed

/// **The fixed seed is what CI runs, and the generator it rides on is pinned by value.**
///
/// Launcher §6: *"a randomized seed is a flake generator, not a property test."* Four halves make
/// that true and keep it true here: the routed overlay replays byte-identically from its salted
/// seed; one whole routed cell replays byte-identically as an ordered token trace and a rung digest;
/// the routed convergence file **and the fixture anchor it reads its instants from** consult no
/// system RNG and no wall clock, bar that anchor's one named `Date()` whose contract is pinned by
/// assertion rather than left to a comment; and **two literal digests** pin the 80 generated
/// membership schedules and the 40 generated overlays.
///
/// The digests are the only artefact that can go red for "a draw was added inside `schedule(…)`".
/// `MeshP4DeterminismAcceptanceTests.everyCellOfTheMatrixReplaysIdentically` cannot: it generates
/// each cell twice in one process and compares the two, so a re-phased generator produces two
/// identical re-phased schedules and stays green. It is a self-consistency check, and it is cited as
/// one. **A failure here is a decision, not a re-pin:** the literal moves only with a ledger row
/// saying which generator change moved it.
@MainActor
@Suite(.serialized)
struct MeshP5DeterminismAcceptanceTests {

    /// The files this suite greps, each with the floor on non-comment lines that proves the scan
    /// actually read something. P4's two convergence files are walled by P4's own suite.
    ///
    /// The fixture anchor joined the list in item 6a's review: the convergence file stopped
    /// spelling `Date()` by **reading a symbol that does**, and a wall satisfied by indirection is
    /// not a wall. It is a fourteen-line file, so it carries its own floor rather than inheriting
    /// the thousand-line file's.
    private static let scannedFiles = [
        (path: "Tests/FernletTests/MeshRoutedDrainConvergenceTests.swift", minimumCodeLines: 100),
        (path: "Tests/FernletTests/MeshRoutedFixtureClock.swift", minimumCodeLines: 10)
    ]

    /// The ONE code line in the walled set allowed to spell a banned token, and the file it may
    /// appear in: the routed fixture anchor's single wall-clock read, matched whole and trimmed.
    ///
    /// Named by its exact code rather than waved through by file, and asserted to appear exactly
    /// once — so a **second** clock read in that file, or this one rewritten into some other
    /// expression, fails the wall instead of passing silently behind the exception.
    private static let allowedTokenLines = [
        "Tests/FernletTests/MeshRoutedFixtureClock.swift":
            "MeshP3Acceptance.base, Date().addingTimeInterval(aheadMarginSeconds)"
    ]

    /// Tokens that would make a cell irreproducible. Spelled as they appear in source.
    private static let bannedTokens = [
        "SystemRandomNumberGenerator", "arc4random", "Date()", "Date.now",
        ".randomElement", ".random(", ".shuffled()"
    ]

    /// The SHA-256 of the canonical transcript of all **80** generated membership schedules.
    private static let pinnedScheduleDigest =
        "ca898bcc9ec7eb099c20bf0b1557e8d450d2d6747d103d899883aef06d466930"

    /// The SHA-256 of the canonical transcript of all **40** generated routed overlays.
    private static let pinnedOverlayDigest =
        "f1cc626d4421a8845839ac41be3c4fa418e98dd2047ad92865306e40d1693ff9"

    /// **The salt is a pinned constant and the overlay replays from it.**
    @Test func theRoutedOverlayIsReplayableAndSaltedAwayFromTheSchedule() {
        #expect(MeshScheduleGenerator.routedSalt == 0x524F_5554_4544_0000, "the pinned routed salt")
        #expect(MeshConvergenceSeeds.root == 0x00F3_2B1C_0009_0002, "the pinned root seed")
        var overlays: Set<MeshRoutedScheduleOverlay> = []
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all {
            let first = MeshScheduleGenerator.routedOverlay(for: cell.schedule)
            let second = MeshScheduleGenerator.routedOverlay(for: cell.schedule)
            #expect(first == second, "one seed, one overlay")
            #expect(MeshScheduleGenerator.schedule(
                seed: cell.seed, shape: cell.shape, preferQuorum: false
            ) == cell.schedule, "planning an overlay moved no draw of the base schedule")
            overlays.insert(first)
        }
        #expect(overlays.count > 1, "forty cells that produced one overlay would be no property test")
    }

    /// **One whole routed cell replays byte-identically** — the ordered token trace and the rung
    /// digest, both projected onto member indices so two runs are comparable at all.
    @Test func oneRoutedCellReplaysIdentically() async throws {
        let cell = try MeshP5Acceptance.rootCell(.twoTwo)
        let first = try await MeshP5Acceptance.converged(cell, label: "p5det-replay")
        let firstTokens = first.executedTokens
        let firstDigest = first.run.routedDigest(key: first.key)
        MeshP5Acceptance.teardown(first.run)

        let second = try await MeshP5Acceptance.converged(cell, label: "p5det-replay")
        defer { MeshP5Acceptance.teardown(second.run) }
        #expect(second.executedTokens == firstTokens,
                "the same cell executed a different ordered trace on its second run")
        #expect(second.run.routedDigest(key: second.key) == firstDigest,
                "the same cell converged on a different routed state on its second run")
        #expect(firstDigest.isEmpty == false, "an empty digest would compare nothing")
    }

    /// **The grep-wall, on the third convergence file and on the anchor it reads.** A `Date()` or a
    /// `.randomElement()` slipped into the routed cells would keep every one of them green and
    /// quietly make the rectangle unreplayable — and so would a second one slipped into the fixture
    /// anchor, which is why the anchor's own file is scanned with one exactly-named exception
    /// rather than trusted for being small.
    @Test func theRoutedConvergenceFileConsultsNoSystemRNGOrWallClock() throws {
        // R2: bounded by the scanned-file list.
        for file in Self.scannedFiles {
            let lines = try MeshP5Acceptance.codeLines(of: file.path)
            #expect(lines.count > file.minimumCodeLines,
                    "\(file.path): an empty scan is a wall that stopped looking")
            let allowed = Self.allowedTokenLines[file.path]
            if let allowed {
                let excused = lines.filter { $0.trimmingCharacters(in: .whitespaces) == allowed }
                #expect(excused.count == 1,
                        "\(file.path): the excused clock line appears \(excused.count)×, not once")
            }
            // R2: bounded by the banned-token list.
            for token in Self.bannedTokens {
                let offenders = lines.filter {
                    $0.contains(token) && $0.trimmingCharacters(in: .whitespaces) != allowed
                }
                #expect(offenders.isEmpty,
                        "\(file.path) uses `\(token)`, which makes a cell unreplayable: \(offenders)")
            }
        }
    }

    /// **The routed fixture anchor's own contract, pinned positively.**
    ///
    /// The grep-wall above can only say the walled files spell no clock of their own. These lines
    /// are what keep item 6a's remedy honest, and each is a property the anchor's header claims:
    ///
    /// - the **`max` floor** — an anchor below `MeshP3Acceptance.base` inverts the sibling P4
    ///   fixtures pinned at 1.8e9 (`MeshDepartureRig.seedEpoch`, `MeshTerminationFixtures.base`),
    ///   measured at seven red custody cells, not assumed;
    /// - the **forward roll** — the whole routed family is `anchor + offset` while the settle path
    ///   reads the shipping `Date()` default, so the injected instants must LEAD the wall clock;
    /// - **one instant per process** — a `static let`, never a computed `var`, or
    ///   `oneRoutedCellReplaysIdentically` would be comparing two different clocks.
    ///
    /// `MeshRoutedDrainRig.createdAt` is asserted beside it because that is the routed family's
    /// entry point: re-pinning it to a literal is exactly how the 2027 bomb was planted, and this
    /// is the line that catches that for every routed suite, not only the convergence route.
    @Test func theRoutedFixtureAnchorHoldsItsContract() {
        #expect(MeshRoutedFixtureClock.createdAt >= MeshP3Acceptance.base,
                "the max floor: an anchor below 1.8e9 inverts the P4 fixtures pinned there")
        #expect(MeshRoutedFixtureClock.createdAt > Date(),
                "the anchor must lead the wall clock, never sit on a date it has walked past")
        #expect(MeshRoutedDrainRig.createdAt > Date(),
                "and the routed family's own anchor with it, not just the convergence route")
        let first = MeshRoutedFixtureClock.createdAt
        let second = MeshRoutedFixtureClock.createdAt
        #expect(first == second, "one instant per process: a static let, never a computed var")
        #expect(MeshRoutedDrainRig.createdAt == first, "and the rig reads that same one instant")
        #expect(MeshRoutedFixtureClock.aheadMarginSeconds >= 24 * 60 * 60,
                "a margin one run could outlive would flip regime halfway through that run")
    }

    /// **The two pinned digests.** A draw added anywhere inside `schedule(…)` re-phases every base
    /// cell and fails the first literal; a draw added to the overlay fails the second.
    @Test func theGeneratedMatricesMatchTheirPinnedDigests() {
        #expect(Self.scheduleDigest() == Self.pinnedScheduleDigest,
                "the 80 generated membership schedules moved — that is a generator decision")
        #expect(Self.overlayDigest() == Self.pinnedOverlayDigest,
                "the 40 generated routed overlays moved — that is an overlay decision")
    }

    /// The canonical transcript digest of the whole 80-cell membership matrix, in matrix order.
    private static func scheduleDigest() -> String {
        var transcript = ""
        // R2: bounded by the shape list × two preferences × the fixed seed family.
        for shape in MeshPartitionShape.matrix {
            for preferQuorum in [true, false] {
                for seed in MeshConvergenceSeeds.family {
                    let cell = MeshScheduleGenerator.schedule(
                        seed: seed, shape: shape, preferQuorum: preferQuorum
                    )
                    transcript += "\(shape.rawValue)|\(preferQuorum)|\(String(seed, radix: 16))|"
                    transcript += cell.steps
                        .map { "\($0.branch).\($0.performer).\($0.event.token)" }
                        .joined(separator: ",")
                    transcript += "|"
                    transcript += cell.heal
                        .map { "\($0.near)-\($0.far)-\($0.isBridge)" }
                        .joined(separator: ",")
                    transcript += "\n"
                }
            }
        }
        return hex(of: transcript)
    }

    /// The canonical transcript digest of the 40 routed overlays, in rectangle order.
    private static func overlayDigest() -> String {
        var transcript = ""
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all {
            transcript += "\(cell.description)|\(cell.overlay.description)\n"
        }
        return hex(of: transcript)
    }

    /// Lowercase hex SHA-256 of a UTF-8 transcript.
    private static func hex(of transcript: String) -> String {
        SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
