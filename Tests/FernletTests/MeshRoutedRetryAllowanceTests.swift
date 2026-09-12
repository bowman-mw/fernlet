// MeshRoutedRetryAllowanceTests.swift
// FernletTests
//
// Network migration P6 item 5 (plan §23.3, D-13.32): the re-entry pass's allowance discipline —
// the pure planner's whole table, and the starvation it exists to stop, on a rig.
//
// Two halves, deliberately. `MeshRoutedRetryPlanTests` drives `MeshRoutedRetryPlan` and
// `MeshRoutedRetryRotation` as the value types they are: no mesh, no store, no item and no clock,
// which is what lets the split be stated exhaustively rather than sampled. `MeshRoutedRetryAllowance`
// `Tests` then drives the two real lists through `MeshRoutedDrainRig` and the manager's own
// `applyRoutedAccessGate` edge, because a plan nobody spends is not a fix.
//
// Two fixture facts the rig cells rest on, both paid for by earlier suites:
//
// - **One pinned install binding** (`MeshP3Acceptance.install`) around every store-touching call,
//   and one clock anchor (`MeshRoutedFixtureClock` through `MeshRoutedDrainRig.createdAt`).
// - **`MeshRoutedDrainItem.stage(into:at:)` writes the store without the manager seeing a chunk**,
//   so an item staged that way is still waiting for job 4 and job 5 — which is the only way to
//   observe either retry list at all (a chunk that arrives on a link has its receipt filed and its
//   plaintext projected at the live door, before any re-entry pass exists to pace).
//
// Where a population is PLANTED rather than minted, the cell says why in its own doc: the routes
// that are convenient to construct are either unreachable from a registered mint (an over-resident
// blob — the photo row's cap IS the resident bound, D-13.19) or self-healing (a missing chunk file
// is repaired out of completeness on the first read).
//
// **The projection list's retryable population IS reachable in production, and three documents said
// otherwise** (item 5 review, P2-3; the commit message, the ledger row and this header's earlier
// wording all claimed it was structural). Two real routes pass `isProjectableAtThisPass` and reach
// the arm: `routedCanonicalDispatch(_: MeshRoutedTextBody, …)` answers `.refusedForNow` whenever
// `transcriptLiveness` is `.notLiveRightNow` — a session ended by the five-minute give-up door that
// `startSearching()` can un-end, in the right mesh and the right generation — and
// `routedProjectionBlob` answers nil for a store read that is `.unavailable` or `.refused`, which
// repeats at every pass and does not self-heal. The filter only excludes `.endedForGood`. So item 5's
// projection half is load-bearing in production, not merely structural; what the plants buy is a
// population that is easy to place at the HEAD of an index ordered by origin fingerprint.

@testable import ProximityKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

// MARK: - The planner

/// ``MeshRoutedRetryPlan`` and ``MeshRoutedRetryRotation`` as values: the whole split, the
/// round-robin, the two marks and the bound.
@Suite(.serialized)
struct MeshRoutedRetryPlanTests {

    /// A deterministic low-sorting key: the index orders by `(originFingerprint, itemID.uuidString)`,
    /// so a decimal-digit id really does sort by `n`.
    private static func key(_ n: Int) throws -> MeshRoutedItemKey {
        let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)))
        return MeshRoutedItemKey(originFingerprint: "fp001", itemID: id)
    }

    /// `range`'s keys, in ascending order.
    private static func keys(_ range: Range<Int>) throws -> [MeshRoutedItemKey] {
        try range.map { try Self.key($0) }
    }

    /// An instant with no clock read in it — the rotation only ever compares, never measures.
    private static let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    /// The per-pass allowance the manager spends, restated here so the table reads as arithmetic.
    private static let allowance = 16

    /// **The split, exhaustively.** Never-attempted work gets its reserved half, a retrying
    /// population is capped at the other half, and an unused slot on either side spills to the
    /// other rather than being wasted.
    ///
    /// The last three rows are the ones a naive implementation gets wrong: `(1, 16)` is the whole
    /// point of the item (one new item behind sixteen retryables must still be tried NOW), `(20, 0)`
    /// and `(0, 20)` are the spill in both directions, and `(12, 20)` is the only row where both
    /// caps bind at once.
    @Test func theAllowanceReservesHalfForNeverAttemptedWorkAndSpillsTheRest() throws {
        let pool = try Self.keys(0..<40)
        let table: [(retryable: Int, fresh: Int, expectedNew: Int, expectedRetried: Int)] = [
            (retryable: 16, fresh: 1, expectedNew: 1, expectedRetried: 15),
            (retryable: 20, fresh: 20, expectedNew: 8, expectedRetried: 8),
            (retryable: 12, fresh: 20, expectedNew: 8, expectedRetried: 8),
            (retryable: 20, fresh: 0, expectedNew: 0, expectedRetried: 16),
            (retryable: 0, fresh: 20, expectedNew: 16, expectedRetried: 0),
            (retryable: 20, fresh: 4, expectedNew: 4, expectedRetried: 12),
            (retryable: 0, fresh: 0, expectedNew: 0, expectedRetried: 0)
        ]
        #expect(table.count == 7, "a table this cell sampled to nothing would be green over nothing")
        // R2: bounded by the table.
        for row in table {
            let retryable = Array(pool.prefix(row.retryable))
            let fresh = Array(pool.dropFirst(row.retryable).prefix(row.fresh))
            let plan = MeshRoutedRetryPlan(
                enumerated: retryable + fresh, attempted: Set(retryable),
                rotation: retryable, allowance: Self.allowance
            )
            #expect(plan.neverTriedCount == row.expectedNew)
            #expect(plan.retriedCount == row.expectedRetried)
            #expect(plan.keysToTry.count == row.expectedNew + row.expectedRetried)
            #expect(plan.deferredRetryCount == row.retryable - row.expectedRetried)
            let headIsFresh = plan.keysToTry.prefix(row.expectedNew)
                .allSatisfy { fresh.contains($0) }
            #expect(headIsFresh, "never-attempted work must be at the HEAD, not merely included")
            let boundedByAllowance = plan.keysToTry.count <= Self.allowance
            #expect(boundedByAllowance, "the plan is the allowance's only spender")
        }
    }

    /// **The round-robin, and why the sub-allowance alone is not enough.** A retrying population
    /// larger than its share is rotated, so the tail is reached — with a plain head-of-list retry a
    /// 24-item population would re-try the same sixteen for ever.
    @Test func everyRetryableGetsATurnBecauseTheRotationMovesOn() throws {
        let held = try Self.keys(0..<24)
        var rotation = MeshRoutedRetryRotation()
        _ = rotation.armed(at: Self.anchor)
        // R2: bounded by the population.
        for key in held {
            // A mutating member cannot be called inside `#expect` — the macro captures its
            // subexpressions immutably — so every one of these binds the answer first.
            let remembered = rotation.noteCarriedOver(key)
            #expect(remembered, "the bound must not refuse twenty-four keys")
        }

        var passes: [[MeshRoutedItemKey]] = []
        // R2: two passes, fixed.
        for _ in 0..<2 {
            let plan = rotation.plan(for: held, allowance: Self.allowance)
            passes.append(plan.keysToTry)
            // R2: bounded by the allowance.
            for key in plan.keysToTry {
                let requeued = rotation.noteRetryable(key)
                #expect(requeued, "a re-queue at no bound must not refuse")
            }
        }

        #expect(passes.first == Array(held.prefix(16)), "the first pass takes the head")
        #expect(passes.last?.first == held[16], """
            the second pass must START where the first stopped — a rotation that restarted at the \
            head is the original defect, one level down
            """)
        let seen = Set(passes.flatMap { $0 })
        #expect(seen.count == held.count, "every retryable gets a turn inside two passes")
    }

    /// **A final leaves BOTH sets**, and says so twice: the tried set stops naming it, and the
    /// rotation stops holding a queue slot for it.
    ///
    /// The last assertion is the one worth stating: a finalised key reads as never-attempted again.
    /// That is correct rather than a leak — job 5's `routedProjectedItems` mark and job 4's durable
    /// stamp are what stop it being enumerated at all, and this set's job is only to pace what IS
    /// enumerated.
    @Test func aFinalKeyLeavesTheTriedSetAndTheRotationTogether() throws {
        var rotation = MeshRoutedRetryRotation()
        let first = try Self.key(1)
        let second = try Self.key(2)
        let firstRemembered = rotation.noteRetryable(first)
        let secondRemembered = rotation.noteRetryable(second)
        #expect(firstRemembered && secondRemembered)
        #expect(rotation.attempted == Set([first, second]))
        #expect(rotation.order == [first, second], "the queue is attempt order")

        rotation.noteFinal(first)
        #expect(rotation.attempted == Set([second]), "a final leaves the tried set")
        #expect(rotation.order == [second], "and the rotation, or it holds a queue slot for ever")
        rotation.noteFinal(first)
        #expect(rotation.order == [second], "and a second final is not an error")

        let plan = rotation.plan(for: [first, second], allowance: Self.allowance)
        #expect(plan.neverTriedCount == 1, "the finalised key is never-attempted work again")
        #expect(plan.keysToTry.first == first, "so it is tried first if it is still enumerated")
    }

    /// **The tried set stops at the store's item cap** — it refuses to remember rather than growing,
    /// and a key it already holds is still re-queueable at the bound.
    ///
    /// Degrading toward "never-attempted" is the safe direction: an unremembered key competes for
    /// the reserved half, which wastes a slot on work that may refuse again. The other direction
    /// would be an unbounded set on the main actor.
    @Test func theTriedSetStopsAtTheStoreItemCapAndRefusesRatherThanGrowing() throws {
        var rotation = MeshRoutedRetryRotation()
        var refusedInsideTheCap = false
        // R2: bounded by the store's item cap.
        for position in 0..<MeshRoutedStoreFormat.maxItems where !refusedInsideTheCap {
            refusedInsideTheCap = !rotation.noteRetryable(try Self.key(position))
        }
        #expect(refusedInsideTheCap == false, "nothing inside the cap may be refused")
        #expect(rotation.attempted.count == MeshRoutedStoreFormat.maxItems)

        let overCap = try Self.key(MeshRoutedStoreFormat.maxItems)
        let refusedOverCap = rotation.noteRetryable(overCap)
        #expect(refusedOverCap == false, "the bound refuses by name")
        #expect(rotation.attempted.count == MeshRoutedStoreFormat.maxItems, "and does not grow")
        #expect(rotation.order.count == MeshRoutedStoreFormat.maxItems)
        let requeuedAtTheBound = rotation.noteRetryable(try Self.key(0))
        #expect(requeuedAtTheBound,
                "a key already remembered is still re-queueable at the bound")
    }

    /// **The restart bound.** The session's cut is the FIRST pass's instant and never moves, and an
    /// item this device already held at that instant competes for the retry share rather than for
    /// the reserved never-attempted half.
    ///
    /// That is what makes the memory-only marks honest: after a restart every held item looks
    /// never-attempted, so without the cut a re-derived backlog of refusals would spend the half a
    /// genuinely new item is entitled to.
    @Test func anItemHeldBeforeTheFirstPassCompetesForTheRetryShare() throws {
        var rotation = MeshRoutedRetryRotation()
        #expect(rotation.armedAt == nil, "unarmed until the first pass")
        let armed = rotation.armed(at: Self.anchor)
        #expect(armed == Self.anchor)
        let rearmed = rotation.armed(at: Self.anchor.addingTimeInterval(600))
        #expect(rearmed == Self.anchor,
                "the cut is the FIRST pass's instant; a later pass must not move it")

        let held = try Self.key(1)
        let arrived = try Self.key(2)
        let carried = rotation.noteCarriedOver(held)
        #expect(carried)
        let plan = rotation.plan(for: [held, arrived], allowance: 2)
        #expect(plan.neverTriedCount == 1)
        #expect(plan.keysToTry == [arrived, held], "the newcomer is tried first, the backlog second")

        var attempted = MeshRoutedRetryRotation()
        let heldAttempt = attempted.noteRetryable(held)
        let arrivedAttempt = attempted.noteRetryable(arrived)
        #expect(heldAttempt && arrivedAttempt)
        let carriedAgain = attempted.noteCarriedOver(held)
        #expect(carriedAgain, "idempotent")
        #expect(attempted.order == [held, arrived], """
            a carried-over note must not re-queue a key the pass genuinely attempted, or an item \
            enumerated at every pass is shuffled to the back on each one and the rotation it feeds \
            never advances
            """)
    }

    /// **The planner is type-agnostic, and that is a wall rather than a claim** (item 5.2).
    ///
    /// Item 6 supplies its heart predicate to `MeshNetworkManager.ackableNow(_:in:)`, the
    /// filter-before-plan seam, and never here: a planner that could see a type token would be a
    /// second per-type source beside the registry, which `noShippingCodeBranchesOnARoutedTypeToken`
    /// exists to forbid. The needles are matched against CODE only, so the file's own doc comments
    /// may name what the code may not.
    @Test func thePlannerNamesNoRoutedTypeNoRegistryAndNoStore() throws {
        let path = "FernletKit/Sources/ProximityKit/Mesh/MeshRoutedRetryPlan.swift"
        let source = try RepoRoot.source(path)
        #expect(source.count > 2_000, "the source scan must not be reading an empty file")
        let code = MeshRoutedSourceScan.codeOnly(source)
        #expect(code.contains("MeshRoutedRetryPlan"), "the scan must be reading the right file")
        // R2: bounded by the needle list.
        for needle in ["MeshRoutedTypeToken", "typeToken", "routedTypes", "canonicalStore",
                       "entry(for:", "requiresForeground", "MeshRoutedManifest",
                       "MeshRoutedStore(", "MeshRoutedIndex(", "FernletAuditLog"] {
            #expect(code.contains(needle) == false, "the planner acquired something it must not see")
        }
    }
}

// MARK: - The two lists, on a rig

/// The allowance spent: what a re-entry pass actually attempts when a retrying population sits at
/// the head of its list.
@MainActor
@Suite(.serialized)
struct MeshRoutedRetryAllowanceTests {

    /// The gate a pass needs. A push of this after ``closedGate`` is the rising edge.
    private static var openGate: MeshRoutedAccessGate { MeshRoutedDrainRig.openGate }

    /// The falling edge, so a second rising one can be produced.
    private static var closedGate: MeshRoutedAccessGate {
        MeshRoutedAccessGate(protectedDataAvailable: false, appIsForeground: true, duressActive: false)
    }

    /// A deterministic low-sorting item id, so a planted population really occupies the head of an
    /// index ordered by `(originFingerprint, itemID.uuidString)`.
    private static func lowID(_ n: Int) throws -> UUID {
        try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)))
    }

    /// The highest-sorting item id there is — the "new" item in every cell, so a plain
    /// head-of-list prefix would never reach it.
    private static func highID() throws -> UUID {
        try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    }

    /// One item on job 5's list that refuses `refusedForNow` at **every** pass and cannot heal.
    ///
    /// Everything about it is real except `manifest.size`, which claims one byte more than
    /// `MeshRoutedItemSealFormat.maxResidentBlobByteCount`. That makes the projection's resident-blob
    /// guard refuse it **before** the store is read, which matters twice: the refusal repeats at
    /// every pass (a missing chunk file would instead be repaired out of completeness on the first
    /// read, taking the item off the list), and no store read means no repair and no seal work.
    ///
    /// A registered mint cannot produce this item — the photo row's cap *is* the resident bound
    /// (D-13.19) — so it is planted, which is `MeshRoutedStoreFixtures.record`'s own stated purpose:
    /// an at-rest state no shipped writer would produce. What it stands in for is item 6's heart
    /// population, whose cooldown, foreground and unloaded-ledger refusals are the real thing.
    private static func stubbornRecord(
        _ manifest: MeshRoutedManifest, firstSeenAt: Date
    ) -> MeshRoutedItemRecord {
        let oversize = MeshRoutedManifest(
            meshID: manifest.meshID,
            itemID: manifest.itemID,
            originFingerprint: manifest.originFingerprint,
            typeToken: manifest.typeToken,
            contentHash: manifest.contentHash,
            size: UInt64(MeshRoutedItemSealFormat.maxResidentBlobByteCount + 1),
            createdAt: manifest.createdAt,
            expiresAt: manifest.expiresAt,
            destinations: manifest.destinations,
            keyWraps: manifest.keyWraps,
            signature: manifest.signature
        )
        return MeshRoutedItemRecord(
            key: MeshRoutedItemKey(oversize),
            contentHash: oversize.contentHash,
            chunkCount: 1,
            expiresAt: oversize.expiresAt,
            manifest: oversize,
            firstSeenAt: firstSeenAt,
            custodiedAt: nil,
            deliveredAt: nil,
            chunks: [MeshRoutedStoreFixtures.descriptor(index: 0, count: 1, bytes: 16)],
            delivery: nil,
            receipts: [],
            recipientReceipts: []
        )
    }

    /// Plants a full allowance of stubborn items into `node`'s store, all sorted ahead of anything
    /// with a random id.
    ///
    /// - Returns: their keys, in index order.
    private static func plantStubbornBacklog(
        _ rig: MeshRoutedDrainRig, at node: Int, firstSeenAt: Date
    ) throws -> [MeshRoutedItemKey] {
        var records: [MeshRoutedItemRecord] = []
        // R2: bounded by the per-pass allowance.
        for position in 0..<MeshRoutedDrainBounds.increment1.maxItems {
            let minted = try MeshRoutedPhotoFixtures.item(
                rig, origin: 0, itemID: try Self.lowID(position + 1)
            )
            records.append(Self.stubbornRecord(minted.manifest, firstSeenAt: firstSeenAt))
        }
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: records),
            into: rig.routedStore(rig.nodes[node]),
            install: MeshP3Acceptance.install
        )
        return records.map(\.key)
    }

    /// One heart on job 4's list: staged into the destination's store, so no live door files its
    /// receipt, and unjudgeable for ever until item 6 lands the ceremony.
    ///
    /// This is the population the P6 ledger measured as the reachable half of D-13.32 — sixteen
    /// hearts from one ground fingerprint hold the whole ack allowance and this device's own photo
    /// and text receipts are never filed.
    private static func stagedHeart(_ rig: MeshRoutedDrainRig, itemID: UUID) throws -> MeshRoutedDrainItem {
        let signer = rig.identities[0]
        let payload = MeshRoutedCustodyFixtures.blob(
            byteCount: MeshRoutedCustodyFixtures.blobByteCount(
                for: MeshRoutedTypeToken.heart, requested: 1_200
            )
        )
        let target = MeshDeliveryTarget(
            contentID: itemID, roster: rig.roster, selfFingerprint: signer.localFingerprint
        )
        let manifest = try MeshRoutedManifest.signed(
            meshID: rig.meshID,
            target: target,
            typeToken: MeshRoutedTypeToken.heart,
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

    /// Writes the custody rung a real delivery would have written, for an item a fixture only
    /// STAGED.
    ///
    /// `MeshRoutedDrainItem.stage(into:at:)` fills the store without the manager ever seeing a
    /// chunk, which is the only way to leave an item waiting for job 4 at all — but it also skips
    /// `commitLocalCustody`, and `MeshRoutedAckStage.durableRecipientStorage`'s shortfall is
    /// `custodyNotCommitted` until that rung exists. So the rung is planted through the index rather
    /// than minted through the commit door: that door's witness initializer is `fileprivate` to its
    /// own file, deliberately, and this cell is about the ALLOWANCE and not about the rung ladder.
    private static func commitCustodyByHand(
        _ rig: MeshRoutedDrainRig, at node: Int, for key: MeshRoutedItemKey
    ) throws {
        var index = try #require(rig.routedIndex(rig.nodes[node]), "the store must be loaded")
        var record = try #require(index.record(for: key), "the item must already be staged")
        record.custodiedAt = MeshRoutedDrainRig.now
        index.upsert(record)
        try MeshRoutedStoreFixtures.plant(
            index, into: rig.routedStore(rig.nodes[node]), install: MeshP3Acceptance.install
        )
    }

    /// Drops planted items out of one node's store, so the next pass's enumeration no longer names
    /// them — what a narrowed enumeration looks like from the rotation's side.
    private static func dropBacklog(
        _ rig: MeshRoutedDrainRig, at node: Int, keys: [MeshRoutedItemKey]
    ) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = rig.routedStore(rig.nodes[node]).dropping(items: keys, reason: "test.narrowed")
        }
    }

    /// Job 5's list at `node`, read from the test's side so a precondition is a fact and not an
    /// inference from the pass's own counters.
    private func awaitingProjection(_ rig: MeshRoutedDrainRig, at node: Int) throws -> [MeshRoutedItemRef] {
        let index = try #require(rig.routedIndex(rig.nodes[node]), "the store must be loaded")
        return index.itemsAwaitingLocalProjection(
            at: MeshRoutedDrainRig.now,
            for: rig.nodes[node].fingerprint,
            types: [MeshRoutedTypeToken.photo]
        )
    }

    /// **The restart bound, on the list.** A backlog this device already held when the session's
    /// first pass ran is charged to the retry share, so a genuinely new item is projected on that
    /// very first pass instead of queueing behind sixteen re-derivations.
    ///
    /// Without the carried-over cut every held item is never-attempted work after a restart, the
    /// sixteen planted items sort first, and the seventeenth is never reached.
    @Test func aBacklogHeldBeforeTheFirstPassIsChargedToTheRetryShare() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "retry-restart")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let backlog = try Self.plantStubbornBacklog(
            rig, at: 1, firstSeenAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60)
        )

        // The newcomer arrives before any gate is pushed at all — the manager's gate starts closed
        // — so the live door refuses it for now, records nothing (a gate refusal is not the item's
        // attempt), and the session's first PASS is still ahead of it.
        let arriving = try MeshRoutedPhotoFixtures.item(rig, origin: 0, itemID: try Self.highID())
        rig.link(0, 1)
        try rig.handOver(arriving, sender: 0, receiver: 1)
        try await rig.settle()

        let awaiting = try awaitingProjection(rig, at: 1)
        #expect(awaiting.count == backlog.count + 1,
                "the precondition: seventeen items really are on job 5's list")
        #expect(awaiting.map(\.key).last == MeshRoutedItemKey(arriving.manifest), """
            and the newcomer really does sort LAST, or the cell would pass under a plain \
            head-of-list prefix
            """)
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "nothing projected behind a closed gate")

        rig.pushGate(Self.openGate, at: 1)

        #expect(rig.wallEntries(at: 1, itemID: arriving.manifest.itemID).count == 1, """
            the session's FIRST pass must reach the newcomer: the sixteen it already held are \
            re-derivations, and they compete for the retry share
            """)
        #expect(rig.nodes[1].manager.meshPhotos.count == 1, "and only it — the backlog refuses")
    }

    /// **D-13.32 itself.** Sixteen items a previous pass attempted and could not finish do not
    /// occupy the next pass: a new item is projected on the first pass at which it could be.
    ///
    /// Two passes, because the population must be *attempted* before it is a retry — which is also
    /// why the newcomer arrives between them, behind a closed gate: a gate refusal is the same
    /// answer for every item, so it is deliberately NOT recorded as the item's attempt.
    @Test func aNewItemProjectsOnItsFirstPassBehindAFullAllowanceOfRetries() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "retry-projection")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let backlog = try Self.plantStubbornBacklog(
            rig, at: 1, firstSeenAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60)
        )

        let first = try #require(rig.pushGate(Self.openGate, at: 1), "the unlock edge owes a pass")
        #expect(first.legs.isRising, "the plaintext pass runs on a rising leg only")
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "an over-resident blob projects nothing")

        rig.pushGate(Self.closedGate, at: 1)
        let arriving = try MeshRoutedPhotoFixtures.item(rig, origin: 0, itemID: try Self.highID())
        rig.link(0, 1)
        try rig.handOver(arriving, sender: 0, receiver: 1)
        try await rig.settle()
        let awaiting = try awaitingProjection(rig, at: 1)
        #expect(awaiting.count == backlog.count + 1, "the precondition: seventeen on the list")
        #expect(awaiting.map(\.key).last == MeshRoutedItemKey(arriving.manifest),
                "and the newcomer sorts last")

        rig.pushGate(Self.openGate, at: 1)

        #expect(rig.wallEntries(at: 1, itemID: arriving.manifest.itemID).count == 1, """
            a retrying population may hold at most half the allowance; the reserved half is what \
            reaches the newcomer on its first pass
            """)
        #expect(rig.nodes[1].manager.meshPhotos.count == 1, "and nothing else was projected")
    }

    /// **The same discipline on job 4's list, where the population is real.** Sixteen unjudgeable
    /// hearts do not hold the ack allowance: this device's own receipt for a new item is filed on
    /// the first pass after it arrives.
    ///
    /// **Since P6 item 6 supplied `ackableNow`'s heart leg the hearts spend NO slot at all**, which
    /// is a strictly stronger statement than the retry share bounding them: this rig wires no heart
    /// ledger, so `routedHeartJudgementReadiness()` is false, and the filter takes all sixteen off
    /// the list before the allowance is planned. `heartsPending` keeps its meaning — "heart-stage
    /// items this pass could not judge" — because the filter counts what it refused a slot to.
    @Test func aNewReceiptIsFiledOnItsFirstPassBehindAFullAllowanceOfHearts() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "retry-acks")
        defer { rig.teardown() }
        let allowance = MeshRoutedDrainBounds.increment1.maxItems
        // R2: bounded by the per-pass allowance.
        for position in 0..<allowance {
            let heart = try Self.stagedHeart(rig, itemID: try Self.lowID(position + 1))
            heart.stage(into: rig, at: 1)
        }
        let first = try #require(rig.pushGate(Self.openGate, at: 1), "the unlock edge owes a pass")
        #expect(first.heartsPending == allowance, "the precondition: sixteen hearts on job 4's list")
        #expect(first.acksFiled == 0, "and nothing else to file yet")

        let arriving = try MeshRoutedPhotoFixtures.item(rig, origin: 0, itemID: try Self.highID())
        MeshRoutedDrainItem(manifest: arriving.manifest, chunks: arriving.chunks)
            .stage(into: rig, at: 1)
        let key = MeshRoutedItemKey(arriving.manifest)
        try Self.commitCustodyByHand(rig, at: 1, for: key)
        let staged = try #require(rig.routedIndex(rig.nodes[1])?.record(for: key))
        #expect(staged.isComplete, "the precondition: the newcomer's bytes really are held")
        #expect(staged.isCustodied, "and its stage really is satisfiable — nothing else is missing")
        #expect(staged.recipientReceipts.isEmpty, "and no live door filed its receipt")

        rig.pushGate(Self.closedGate, at: 1)
        let second = try #require(rig.pushGate(Self.openGate, at: 1), "the second edge owes a pass")

        #expect(second.acksFiled == 1, """
            the reserved half of the ack allowance is what reaches a new receipt; sixteen hearts \
            from one ground fingerprint must not be able to hold the whole pass
            """)
        #expect(second.heartsPending == allowance,
                "and all sixteen are still counted while spending no slot — the filter, not the share")
        let filed = try #require(rig.routedIndex(rig.nodes[1])?.record(for: key))
        #expect(filed.recipientReceipts.isEmpty == false, "the receipt is stored, not merely counted")
    }

    /// **A1 — the restart cut compares two clocks, and only a floored pair agrees.**
    ///
    /// `MeshRoutedItemRecord.firstSeenAt` is written through the record's one initializer as
    /// `MeshRoutedManifest.floored(...)` by both admission doors, so it is a whole second. Before
    /// this fix the pass's own instant was not floored, so an item first seen at `floor(t)` with the
    /// pass armed at `t + 0.5` read as **carried-over**, competed for the retry share, and queued
    /// behind sixteen re-derivations.
    ///
    /// It was green only because `MeshRoutedDrainRig.now` is an integral second — and
    /// `MeshRoutedFixtureClock.createdAt` stops being integral at its own documented 2026-12-16
    /// crossover, at which point three cells in this suite would have gone red for a reason no
    /// commit caused. So the pass's instant is fractional here, deliberately: half a second past the
    /// rig's own.
    ///
    /// It is written against JOB 5's list rather than job 4's, and the reason is item 6: job 4's
    /// blocking population used to be sixteen unjudgeable hearts, and `ackableNow`'s heart leg now
    /// filters those out before the allowance is planned, so they can no longer crowd anything.
    /// Job 5's stubborn backlog is the population that still competes.
    @Test func aFractionalPassInstantStillTreatsAFlooredArrivalAsNew() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "retry-floored")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let backlog = try Self.plantStubbornBacklog(
            rig, at: 1, firstSeenAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60)
        )
        let arriving = try MeshRoutedPhotoFixtures.item(rig, origin: 0, itemID: try Self.highID())
        rig.link(0, 1)
        try rig.handOver(arriving, sender: 0, receiver: 1)
        try await rig.settle()
        let key = MeshRoutedItemKey(arriving.manifest)
        let staged = try #require(rig.routedIndex(rig.nodes[1])?.record(for: key))
        #expect(staged.firstSeenAt == MeshRoutedManifest.floored(staged.firstSeenAt),
                "the precondition: every admission door floors the stamp")
        let awaiting = try awaitingProjection(rig, at: 1)
        #expect(awaiting.count == backlog.count + 1, "the precondition: seventeen on job 5's list")
        #expect(awaiting.map(\.key).last == key, "and the newcomer sorts LAST")

        // The session's FIRST pass, armed half a second past the newcomer's own stamped second.
        rig.pushGate(Self.openGate, at: 1, now: MeshRoutedDrainRig.now.addingTimeInterval(0.5))

        #expect(rig.wallEntries(at: 1, itemID: arriving.manifest.itemID).count == 1, """
            an item stamped in the same second as the first pass is NEW: with the cut unfloored it \
            reads as carried-over, competes for the retry share, and is not reached behind sixteen \
            re-derivations
            """)
    }

    /// **A2 — the rotation is pruned to what the pass enumerated.**
    ///
    /// A key leaves its list without passing this pass's own `noteFinal` in two ways, and both fill
    /// the 1024 bound: the LIVE delivery door files a receipt job 4's loop never attempted, and a
    /// list's enumeration narrows under a remembered key (a heart, which
    /// `projectableRoutedTypeTokens` never names, or a text item after the age gate flips off). At
    /// the bound the rotation refuses to remember and the pacing reverts to a head-of-list prefix —
    /// D-13.32's original defect, silently restored. Asserted on the rotation's own tried set, which
    /// is the thing the bound counts.
    @Test func theRotationDropsKeysThePassNoLongerEnumerates() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "retry-prune")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let backlog = try Self.plantStubbornBacklog(
            rig, at: 1, firstSeenAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60)
        )
        _ = try #require(rig.pushGate(Self.openGate, at: 1), "the unlock edge owes a pass")
        let remembered = rig.nodes[1].manager.routedRetryRotationForTesting(.localProjection)
        #expect(remembered.count == backlog.count,
                "the precondition: the whole refusing backlog is remembered as attempted")

        // The items leave the list — here by leaving the mesh's index behind entirely, which is what
        // a narrowed enumeration looks like from the rotation's side.
        Self.dropBacklog(rig, at: 1, keys: backlog)
        rig.pushGate(Self.closedGate, at: 1)
        _ = try #require(rig.pushGate(Self.openGate, at: 1), "the second edge owes a pass")

        #expect(rig.nodes[1].manager.routedRetryRotationForTesting(.localProjection).isEmpty, """
            a key the pass no longer enumerates must leave the tried set, or the bound fills with \
            keys that cost no slot and the pacing turns itself off at 1024
            """)
    }

}
