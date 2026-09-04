// MeshEpochReconciliationTests.swift
// FernletTests
//
// P4 item 3 (plan §10.3, §21.1): **two `coexist` heads become one head.**
//
// Item 2 proved both divergent heads survive a merge. This file proves what retires them: the
// merged view's deterministic coordinator mints `successor(coordinatorFingerprint:meshID:)` at
// counter = max + 1 with `cause = .merge`, and every member ends on that one epoch.
//
// The claims, in the order §10.3 and the launcher's §5(a) make them:
//
//  1. **The successor is minted at max + 1, cause `.merge`.** Two branches that each rotated once
//     while split reconcile onto one head, and the old head is superseded into its grace window.
//  2. **Neither old head wins.** The successor's id is neither old id; there is no tie-break on
//     `epochID`, on "the bigger branch", or on anything else. Swapping which side initiates the
//     merge yields the same counter and the same minter.
//  3. **No wall clock can steer it.** A `MeshEpochRef` carries no timestamp at all, and the frame
//     that ships one binds `sentAt` into its signature but nothing downstream reads it: a head set
//     stamped a century in the future folds to the same heads and mints the same successor.
//  4. **The minter when the merged view's coordinator is absent** is the lowest fingerprint
//     *present among the merging parties* (§3's default, item 1's branch rule), and a later merge
//     that reaches the absent coordinator supersedes with a strictly greater counter.
//  5. **Unequal counters are not a tie-break either.** A branch that rotated twice against one that
//     rotated once merges to `max + 1`, not to the higher head.
//  6. **The cap of 8 is an assertion.** Everyone-alone on a roster of 8 is exactly 8 heads; a ninth
//     is an overflow the writer names (`MeshMergePathTests` claim 7 owns the manager half).
//  7. **The heads actually cross the wire.** `fernlet.mesh.epoch-heads.v1` carries them end to end
//     on `MeshMergeExchangeTests`' rig, and the far end folds what arrived.
//  8. **The `divergent` tunnel gate opens — and only that gate.** Two members on divergent branches
//     introduce so the merge can run; a stranger, a barred member, a foreign mesh and a malformed
//     reference are refused exactly as strictly as before.
//
// **Nothing sleeps.** The rotation a merge asks for is sampled and then disarmed
// (`consumePendingRotationForTesting`) and run by hand (`rotateNowForTesting`), so no scenario
// waits out the 2-second debounce and no armed window can fire a second rotation underneath an
// assertion. Grace is read through `MeshEpochKeyring`'s injected `at:`.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshReconcileFixtures

/// One branch of a split, as a manager: an injected identity, the mesh, the full merged ledger, and
/// the epoch its branch rotated to while it was alone.
@MainActor
enum MeshReconcileFixtures {

    /// Builds a member of `meshID` holding `ledger`, on the branch head `head`.
    ///
    /// The identity is INJECTED for the reason `MeshMergeExchangeTests` records: `IdentityService()`
    /// is keyed on one process-wide keychain service, so two managers built the default way are the
    /// same device and every roster assertion goes vacuous.
    static func member(
        store: FernletStore,
        identity: IdentityService,
        ledger: MeshMembershipLedger,
        founderKey: Data,
        meshID: UUID,
        head: MeshEpochRef?
    ) -> MeshNetworkManager {
        let manager = MeshNetworkManager(
            store: store, transport: FakeMeshTransportSession(), identity: identity
        )
        MeshMergeWire.start(manager, ledger: ledger, founderKey: founderKey, meshID: meshID)
        if let head {
            manager.seedEpochKeyringForTesting(
                head: head,
                key: MeshGroupKey(
                    epoch: Int(head.counter),
                    keyBytes: Data(repeating: 0x2C, count: 32),
                    activeSince: MeshP3Acceptance.base
                )
            )
        }
        return manager
    }

    /// The head a branch coordinated by `coordinator` is on at `counter`.
    static func head(_ counter: UInt32, _ coordinator: IdentityService, _ meshID: UUID) throws -> MeshEpochRef {
        try #require(MeshEpochRef.minted(
            counter: counter, coordinatorFingerprint: coordinator.localFingerprint, meshID: meshID
        ))
    }

    /// Applies a peer's branch head as a merge offer through the one merge path, then samples and
    /// disarms the rotation it asked for.
    ///
    /// - Returns: The cause the merge requested, so a caller can assert it is `.merge` — read
    ///   synchronously, before anything can suspend and let a debounce window consume it.
    @discardableResult
    static func merge(
        _ manager: MeshNetworkManager, offering heads: [MeshEpochRef], ledger: MeshMembershipLedger = .empty
    ) -> MeshKeyRotationCause? {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.mergeReconnected(
                MeshMergeOffer(ledger: ledger, epochHeads: heads), entry: .partitionHeal
            )
            return manager.consumePendingRotationForTesting()
        }
    }

    /// Runs the rotation a merge asked for, on the device that is the merged view's coordinator.
    static func mint(_ manager: MeshNetworkManager) async -> MeshEpochRef? {
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.rotateNowForTesting(cause: .merge)
        }
        return manager.epochKeyring?.head
    }
}

// MARK: - MeshEpochReconciliationTests

/// Claims 1–6: the mint itself.
@MainActor
@Suite(.serialized)
struct MeshEpochReconciliationTests {

    /// **Claims 1 and 2.** Two branches at one counter reconcile onto a strictly greater successor
    /// minted by the merged view's coordinator, with `cause = .merge` — and the successor is
    /// neither old head.
    @Test func twoCoexistingHeadsBecomeOneSuccessorAtMaxPlusOne() async throws {
        let meshID = UUID()
        let alice = try MeshPartitionFixtures.identity("reconcile-a")
        let bob = try MeshPartitionFixtures.identity("reconcile-b")
        #expect(alice.localFingerprint != bob.localFingerprint, "the rig needs two distinct devices")
        let ledger = try MeshPartitionFixtures.ledger(founder: alice, others: [bob], meshID: meshID)
        let headA = try MeshReconcileFixtures.head(2, alice, meshID)
        let headB = try MeshReconcileFixtures.head(2, bob, meshID)
        #expect(headA != headB, "two branch coordinators cannot mint the same ref")

        let storeA = makeTestStore()
        let storeB = makeTestStore()
        let managerA = MeshReconcileFixtures.member(
            store: storeA, identity: alice, ledger: ledger,
            founderKey: alice.localSigningPublicKey, meshID: meshID, head: headA
        )
        let managerB = MeshReconcileFixtures.member(
            store: storeB, identity: bob, ledger: ledger,
            founderKey: alice.localSigningPublicKey, meshID: meshID, head: headB
        )
        let minter = try #require(managerA.epochCoordinatorFingerprintForTesting)
        #expect(minter == [alice.localFingerprint, bob.localFingerprint].min(),
                "the minter is the merged roster's lowest fingerprint — a pure function of the roster")
        #expect(managerB.epochCoordinatorFingerprintForTesting == minter,
                "and both members elect the same one from the same merged roster")

        #expect(MeshReconcileFixtures.merge(managerA, offering: [headB]) == .merge,
                "a divergence asks for the merge's rotation")
        #expect(MeshReconcileFixtures.merge(managerB, offering: [headA]) == .merge)
        #expect(managerA.rotationBasisHeadForTesting?.counter == 2, "max over the folded heads")

        let coordinator = minter == alice.localFingerprint ? managerA : managerB
        let follower = minter == alice.localFingerprint ? managerB : managerA
        let minted = try #require(await MeshReconcileFixtures.mint(coordinator))

        #expect(minted.counter == 3, "counter = max + 1")
        #expect(minted.coordinatorFingerprint == minter)
        #expect(minted.epochID != headA.epochID && minted.epochID != headB.epochID,
                "neither coexisting head wins — the successor is a new minting")
        #expect(coordinator.lastRotationCause == .merge)
        // The follower re-derives the identical ref from the two values the rotation frame carries,
        // through the SHIPPING derivation rather than a copy of it.
        #expect(follower.epochRefForTesting(
            counter: Int(minted.counter), coordinatorFingerprint: minter
        ) == minted, "both members land on exactly one post-merge epoch")
        // Grace: the old head is superseded, readable for the window and dead after it.
        let keyring = try #require(coordinator.epochKeyring)
        let oldHead = minter == alice.localFingerprint ? headA : headB
        #expect(keyring.head == minted)
        #expect(keyring.canOpen(oldHead, at: Date().addingTimeInterval(1)))
        #expect(!keyring.canOpen(
            oldHead, at: Date().addingTimeInterval(MeshEpochBounds.predecessorGraceSeconds + 1)
        ), "both old keys die at grace expiry")

        managerA.leaveMesh()
        managerB.leaveMesh()
    }

    /// **Claim 2, commutativity.** Swapping which branch initiates the merge changes neither the
    /// successor's counter nor the minter: the choice is a pure function of the merged roster and
    /// the counters, and of nothing about arrival order.
    @Test func theMintIsCommutativeInWhichBranchInitiates() async throws {
        let meshID = UUID()
        let alice = try MeshPartitionFixtures.identity("commute-mint-a")
        let bob = try MeshPartitionFixtures.identity("commute-mint-b")
        let ledger = try MeshPartitionFixtures.ledger(founder: alice, others: [bob], meshID: meshID)
        let headA = try MeshReconcileFixtures.head(2, alice, meshID)
        let headB = try MeshReconcileFixtures.head(2, bob, meshID)
        let minter = try #require([alice.localFingerprint, bob.localFingerprint].min())
        var minted: [MeshEpochRef] = []

        for offeredFirst in [[headB], [headA]] {
            let store = makeTestStore()
            let identity = minter == alice.localFingerprint ? alice : bob
            let own = minter == alice.localFingerprint ? headA : headB
            let manager = MeshReconcileFixtures.member(
                store: store, identity: identity, ledger: ledger,
                founderKey: alice.localSigningPublicKey, meshID: meshID, head: own
            )
            MeshReconcileFixtures.merge(manager, offering: offeredFirst)
            if let head = await MeshReconcileFixtures.mint(manager) { minted.append(head) }
            manager.leaveMesh()
        }

        #expect(minted.count == 2)
        #expect(minted[0] == minted[1],
                "A∪B and B∪A mint the identical successor — same counter, same minter, same id")
        #expect(minted[0].counter == 3)
        #expect(minted[0].coordinatorFingerprint == minter)
    }

    /// **Claim 3.** A head set stamped a century in the future changes nothing. The stamp is bound
    /// into the frame's signature — so it cannot be stripped — and is read by nothing that decides
    /// anything: a `MeshEpochRef` has no time component for a forged clock to reach.
    @Test func aForgedFarFutureStampChangesNeitherTheMinterNorTheOutcome() async throws {
        let meshID = UUID()
        let alice = try MeshPartitionFixtures.identity("clock-a")
        let bob = try MeshPartitionFixtures.identity("clock-b")
        let ledger = try MeshPartitionFixtures.ledger(founder: alice, others: [bob], meshID: meshID)
        let minter = try #require([alice.localFingerprint, bob.localFingerprint].min())
        let ownIdentity = minter == alice.localFingerprint ? alice : bob
        let peerIdentity = minter == alice.localFingerprint ? bob : alice
        let ownHead = try MeshReconcileFixtures.head(2, ownIdentity, meshID)
        let peerHead = try MeshReconcileFixtures.head(2, peerIdentity, meshID)

        // The two frames differ ONLY in `sentAt`, and the difference reaches the signed bytes.
        let honest = try MeshEpochHeadsPayload.signed(
            meshID: meshID, heads: [peerHead], identity: peerIdentity, sentAt: MeshP3Acceptance.base
        )
        let forged = try MeshEpochHeadsPayload.signed(
            meshID: meshID, heads: [peerHead], identity: peerIdentity,
            sentAt: MeshP3Acceptance.base.addingTimeInterval(60 * 60 * 24 * 365 * 100)
        )
        #expect(canonicalBytes(for: honest) != canonicalBytes(for: forged),
                "the stamp IS bound into the signature — it just decides nothing")
        #expect(honest.heads == forged.heads)

        var minted: [MeshEpochRef] = []
        for payload in [honest, forged] {
            let store = makeTestStore()
            let manager = MeshReconcileFixtures.member(
                store: store, identity: ownIdentity, ledger: ledger,
                founderKey: alice.localSigningPublicKey, meshID: meshID, head: ownHead
            )
            let verifier = try #require(manager.membershipVerifier)
            #expect(verifier.verify(payload) == nil, "both frames verify — neither is malformed")
            MeshReconcileFixtures.merge(manager, offering: payload.heads)
            if let head = await MeshReconcileFixtures.mint(manager) { minted.append(head) }
            manager.leaveMesh()
        }
        #expect(minted.count == 2)
        #expect(minted[0] == minted[1], "a wall clock cannot pick a winner because none is picked")
        #expect(minted[0].coordinatorFingerprint == minter)
    }

    /// **Claim 4.** Three members {A, B, C}, A the global lowest. B and C merge without A: the
    /// minter is `min(B, C)` — the lowest fingerprint PRESENT among the merging parties, not the
    /// absent coordinator — and the two-member reconnect is not blocked waiting for A. When A
    /// returns, the merged view's coordinator is A again and a later merge supersedes with a
    /// strictly greater counter.
    @Test func anAbsentCoordinatorDoesNotBlockTheMergeAndIsSupersededLater() async throws {
        let meshID = UUID()
        let trio = try (0..<3).map { try MeshPartitionFixtures.identity("absent-\($0)") }
            .sorted { $0.localFingerprint < $1.localFingerprint }
        #expect(Set(trio.map(\.localFingerprint)).count == 3, "three distinct provisioned devices")
        let (absent, first, second) = (trio[0], trio[1], trio[2])
        let ledger = try MeshPartitionFixtures.ledger(
            founder: absent, others: [first, second], meshID: meshID
        )
        let branchHead = try MeshReconcileFixtures.head(2, second, meshID)
        let store = makeTestStore()
        let manager = MeshReconcileFixtures.member(
            store: store, identity: first, ledger: ledger,
            founderKey: absent.localSigningPublicKey, meshID: meshID,
            head: try MeshReconcileFixtures.head(2, first, meshID)
        )
        #expect(MeshMergeFixtures.roster(manager).count == 3)

        // The split: A is unreachable, so the branch is {B, C} and its coordinator is min(B, C).
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.evaluatePartition(
                reachable: [first.localFingerprint, second.localFingerprint],
                now: MeshP3Acceptance.base.addingTimeInterval(60)
            )
        }
        #expect(manager.epochCoordinatorFingerprintForTesting == first.localFingerprint,
                "the minter is the lowest fingerprint PRESENT, never the absent global lowest")
        MeshReconcileFixtures.merge(manager, offering: [branchHead])
        let branchSuccessor = try #require(await MeshReconcileFixtures.mint(manager))
        #expect(branchSuccessor.counter == 3)
        #expect(branchSuccessor.coordinatorFingerprint == first.localFingerprint)

        // A returns. The merged view's coordinator is A again, and A's own merge counts up from the
        // branch's successor — strictly greater, so it supersedes rather than colliding.
        let storeA = makeTestStore()
        let managerA = MeshReconcileFixtures.member(
            store: storeA, identity: absent, ledger: ledger,
            founderKey: absent.localSigningPublicKey, meshID: meshID,
            head: try MeshReconcileFixtures.head(2, absent, meshID)
        )
        #expect(managerA.epochCoordinatorFingerprintForTesting == absent.localFingerprint)
        MeshReconcileFixtures.merge(managerA, offering: [branchSuccessor, branchHead])
        let healed = try #require(await MeshReconcileFixtures.mint(managerA))
        #expect(healed.counter == branchSuccessor.counter + 1,
                "a later merge supersedes with a strictly greater counter")
        #expect(healed.coordinatorFingerprint == absent.localFingerprint)
        #expect(managerA.epochKeyring?.head == healed, "exactly one head at the end")

        manager.leaveMesh()
        managerA.leaveMesh()
    }

    /// **Claim 5.** One branch rotated twice while the other rotated once. The merge does not adopt
    /// the higher head — that would be a tie-break — it mints `max + 1` above it.
    @Test func unequalCountersMintAboveTheHighestRatherThanAdoptingIt() async throws {
        let meshID = UUID()
        let alice = try MeshPartitionFixtures.identity("unequal-a")
        let bob = try MeshPartitionFixtures.identity("unequal-b")
        let ledger = try MeshPartitionFixtures.ledger(founder: alice, others: [bob], meshID: meshID)
        let minter = try #require([alice.localFingerprint, bob.localFingerprint].min())
        let ownIdentity = minter == alice.localFingerprint ? alice : bob
        let peerIdentity = minter == alice.localFingerprint ? bob : alice
        // This side rotated once (counter 2); the other rotated twice (counters 2 and 3).
        let ownHead = try MeshReconcileFixtures.head(2, ownIdentity, meshID)
        let peerLower = try MeshReconcileFixtures.head(2, peerIdentity, meshID)
        let peerHigher = try MeshReconcileFixtures.head(3, peerIdentity, meshID)

        let store = makeTestStore()
        let manager = MeshReconcileFixtures.member(
            store: store, identity: ownIdentity, ledger: ledger,
            founderKey: alice.localSigningPublicKey, meshID: meshID, head: ownHead
        )
        #expect(MeshReconcileFixtures.merge(manager, offering: [peerLower, peerHigher]) == .merge)
        #expect(manager.rotationBasisHeadForTesting?.counter == 3, "max is 3, not this side's 2")

        let minted = try #require(await MeshReconcileFixtures.mint(manager))
        #expect(minted.counter == 4, "max + 1 — the higher head is not adopted, it is superseded")
        #expect(minted != peerHigher)
        #expect(minted.coordinatorFingerprint == minter)
        manager.leaveMesh()
    }

    /// **Claim 1, the coalescing half.** A merge that moves the roster *and* reconciles a
    /// divergence asks for **one** rotation, not two: the mint goes through `requestRotation`, so
    /// its request lands in the window `mergeMembershipLedger` already opened. One armed window,
    /// one cause, and it is `.merge`.
    ///
    /// And once the successor is adopted, the same merge offered again asks for **nothing** — the
    /// old heads sit below the keyring's and are no longer unresolved. Without that, every later
    /// reconnect would re-mint forever.
    @Test func aMergeThatMovesTheRosterAndDivergesStillRotatesExactlyOnce() async throws {
        let meshID = UUID()
        let alice = try MeshPartitionFixtures.identity("once-a")
        let bob = try MeshPartitionFixtures.identity("once-b")
        let newcomer = try MeshPartitionFixtures.identity("once-new")
        #expect(Set([alice, bob, newcomer].map(\.localFingerprint)).count == 3)
        let seeded = try MeshPartitionFixtures.ledger(founder: alice, others: [bob], meshID: meshID)
        let grown = try MeshPartitionFixtures.ledger(
            founder: alice, others: [bob, newcomer], meshID: meshID
        )
        let minter = try #require([alice.localFingerprint, bob.localFingerprint,
                                   newcomer.localFingerprint].min())
        // Run the scenario on whichever of the two founding members is the merged coordinator, so
        // the mint actually happens here rather than at an absent device.
        let ownIdentity = minter == bob.localFingerprint ? bob : alice
        let peerIdentity = ownIdentity === alice ? bob : alice
        let ownHead = try MeshReconcileFixtures.head(2, ownIdentity, meshID)
        let peerHead = try MeshReconcileFixtures.head(2, peerIdentity, meshID)

        let store = makeTestStore()
        let manager = MeshReconcileFixtures.member(
            store: store, identity: ownIdentity, ledger: seeded,
            founderKey: alice.localSigningPublicKey, meshID: meshID, head: ownHead
        )
        #expect(MeshMergeFixtures.roster(manager).count == 2)

        // Sampled synchronously, inside the merge's own turn: a window read after a suspension is
        // a race with the 2-second debounce.
        var cause: MeshKeyRotationCause?
        var windows: Set<Date> = []
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.mergeReconnected(
                MeshMergeOffer(ledger: grown, epochHeads: [peerHead]), entry: .partitionHeal
            )
            cause = manager.rotationTriggers.pendingCause
            if let firesAt = manager.rotationTriggers.firesAt { windows.insert(firesAt) }
            manager.consumePendingRotationForTesting()
        }
        #expect(MeshMergeFixtures.roster(manager).count == 3, "the roster moved AND the heads diverged")
        #expect(cause == .merge, "one cause for both, and it is the merge's")
        #expect(windows.count == 1, "ONE armed window — a second value here is a second rotation")

        guard minter == ownIdentity.localFingerprint else {
            // The newcomer is the merged coordinator, so this device mints nothing — which is
            // itself the rule, and the scenario's rotation claims above still hold.
            manager.leaveMesh()
            return
        }
        let minted = try #require(await MeshReconcileFixtures.mint(manager))
        #expect(minted.counter == 3)

        // Offered again after the mint: already reconciled, so nothing is asked for.
        #expect(MeshReconcileFixtures.merge(manager, offering: [peerHead, ownHead]) == nil,
                "a divergence the successor already retired must not re-mint on every reconnect")
        manager.leaveMesh()
    }

    /// **Claim 6.** The cap of 8 is an assertion about what a partition shape can produce, not a
    /// knob: everyone-alone on a full roster is exactly 8 heads, and a ninth is an overflow the
    /// fold NAMES. (`MeshMergePathTests` claim 7 owns the manager-level half, counted at the
    /// writer against the heads that actually sealed.)
    @Test func theHeadCapIsExactlyEveryoneAloneAndAtNinthItIsNamed() throws {
        let meshID = UUID()
        let cap = MeshSessionContextSchema.maxEpochHeads
        #expect(cap == MeshMembershipBounds.maxRosterMembers,
                "the head cap IS the roster cap: a nested re-split cannot exceed everyone-alone")
        let everyoneAlone: [MeshEpochRef] = try (0..<cap).map { index in
            try #require(MeshEpochRef.minted(
                counter: 4, coordinatorFingerprint: String(format: "%016x", index + 1), meshID: meshID
            ))
        }
        let atCap = MeshMergeOffer.foldedHeads([], adding: everyoneAlone)
        #expect(atCap.heads.count == cap)
        #expect(atCap.droppedCount == 0, "exactly everyone-alone fits, with nothing lost")
        #expect(MeshEpochAcceptance.isDivergent(atCap.heads), "eight branches at one counter diverge")
        #expect(MeshEpochAcceptance.highestHead(atCap.heads)?.counter == 4)

        let ninth = try #require(MeshEpochRef.minted(
            counter: 4, coordinatorFingerprint: String(format: "%016x", cap + 1), meshID: meshID
        ))
        let overflow = MeshMergeOffer.foldedHeads(atCap.heads, adding: [ninth])
        #expect(overflow.heads.count == cap, "the cap is a hard bound")
        #expect(overflow.droppedCount == 1, "and the ninth is NAMED, never silently truncated")

        // A lineage is not a divergence: one branch's own rotation history must not mint a merge.
        let lineage: [MeshEpochRef] = try (1...3).map { counter in
            try #require(MeshEpochRef.minted(
                counter: counter, coordinatorFingerprint: "00000000000000aa", meshID: meshID
            ))
        }
        #expect(!MeshEpochAcceptance.isDivergent(lineage))
    }
}

// MARK: - MeshEpochHeadsWireTests

/// Claim 7: the heads cross a real fabric and the far end folds them.
@MainActor
@Suite(.serialized)
struct MeshEpochHeadsWireTests {

    /// A reconnect puts a signed `fernlet.mesh.epoch-heads.v1` frame on the wire, the far end
    /// verifies and folds it, and both ends then hold the same head set — which is what makes their
    /// `max + 1` the same number.
    @Test func epochHeadsCrossTheWireAndTheFarEndFoldsThem() async throws {
        let fabric = FakePeerNetwork()
        let left = fabric.addEndpoint(named: "heads-left")
        let right = fabric.addEndpoint(named: "heads-right")
        fabric.connect(left.handle, right.handle)
        fabric.clock.advance(by: .milliseconds(50))

        let storeA = makeTestStore()
        let storeB = makeTestStore()
        let idA = try MeshPartitionFixtures.identity("heads-a")
        let idB = try MeshPartitionFixtures.identity("heads-b")
        #expect(idA.localFingerprint != idB.localFingerprint, "the rig needs two distinct devices")
        let meshID = UUID()
        let ledger = try MeshPartitionFixtures.ledger(founder: idA, others: [idB], meshID: meshID)
        let headA = try MeshReconcileFixtures.head(2, idA, meshID)
        let headB = try MeshReconcileFixtures.head(2, idB, meshID)

        let managerA = MeshReconcileFixtures.member(
            store: storeA, identity: idA, ledger: ledger,
            founderKey: idA.localSigningPublicKey, meshID: meshID, head: headA
        )
        let managerB = MeshReconcileFixtures.member(
            store: storeB, identity: idB, ledger: ledger,
            founderKey: idA.localSigningPublicKey, meshID: meshID, head: headB
        )
        #expect(managerA.presentedEpochHeadsForTesting == [headA])
        #expect(managerB.presentedEpochHeadsForTesting == [headB])

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

        // The reconnect on each side opens the exchange, whose epoch half is the new frame.
        managerA.applySessionEvent(.peerCommitted, committedPeer: idB.localFingerprint)
        managerB.applySessionEvent(.peerCommitted, committedPeer: idA.localFingerprint)
        try await MeshMergeWire.settle([nodeA, nodeB], on: fabric, until: {
            managerA.knownEpochHeads.contains(headB) && managerB.knownEpochHeads.contains(headA)
        })

        #expect(MeshMergeWire.receivedTypes(right.transport)
            .contains(PayloadType.meshEpochHeads.rawValue),
                "the signed head set actually travelled the wire")
        #expect(MeshMergeWire.receivedTypes(left.transport)
            .contains(PayloadType.meshEpochHeads.rawValue), "and in the other direction too")
        #expect(managerA.knownEpochHeads.contains(headB), "A folded the branch it had never seen")
        #expect(managerB.knownEpochHeads.contains(headA), "and B folded A's")
        #expect(Set(managerA.presentedEpochHeadsForTesting)
                == Set(managerB.presentedEpochHeadsForTesting),
                "both members converged on the same head set BEFORE the mint")
        #expect(managerA.rotationBasisHeadForTesting?.counter
                == managerB.rotationBasisHeadForTesting?.counter,
                "so both would take the same `max`")

        // Both ends now end on ONE head: the merged coordinator mints it.
        let minter = try #require(managerA.epochCoordinatorFingerprintForTesting)
        let coordinator = minter == idA.localFingerprint ? managerA : managerB
        let follower = minter == idA.localFingerprint ? managerB : managerA
        coordinator.consumePendingRotationForTesting()
        follower.consumePendingRotationForTesting()
        // Sampled immediately before the mint rather than pinned to a literal: `settle` yields, and
        // a yield under a loaded suite can outlast the 2-second debounce this reconnect armed, so
        // the *relationship* is the claim — `max + 1` over whatever the fold reached.
        let basis = try #require(coordinator.rotationBasisHeadForTesting)
        let minted = try #require(await MeshReconcileFixtures.mint(coordinator))
        #expect(minted.counter == basis.counter + 1, "counter = max + 1 over the folded heads")
        #expect(minted.counter >= 3, "and strictly above both branches' counter of 2")
        #expect(follower.epochRefForTesting(
            counter: Int(minted.counter), coordinatorFingerprint: minter
        ) == minted, "one post-merge epoch, at both members")

        managerA.leaveMesh()
        managerB.leaveMesh()
    }
}

// MARK: - MeshDivergentTunnelGateTests

/// Claim 8: the `divergent` gate opens for a merge — and nothing else moves.
@MainActor
@Suite(.serialized)
struct MeshDivergentTunnelGateTests {

    /// The authority's answer is what opens the gate: a device holding a mesh AND a ledger can run
    /// the merge a reconciling tunnel exists for; one holding neither cannot, and keeps the refusal.
    @Test func onlyADeviceThatCanActuallyMergeMayReconcile() throws {
        // The host must be held for the manager's whole life (invariant HP0): `store` is
        // `unowned`, so an inline `makeTestStore()` would die at the end of this expression
        // and leave `bare` born with a dangling reference. Rule ML5 keeps this hoisted.
        let bareHost = makeTestStore()
        let bare = MeshNetworkManager(store: bareHost, transport: FakeMeshTransportSession())
        #expect(!bare.mayReconcileDivergentEpochs, "no mesh, nothing to reconcile with")

        let meshID = UUID()
        let seeded = try MeshMergeFixtures.members(1, "gate-seed")
        let store = makeTestStore()
        let manager = try MeshMergeFixtures.liveManager(store: store, others: seeded, meshID: meshID)
        #expect(manager.mayReconcileDivergentEpochs, "a mesh with a ledger can run the merge")
        manager.leaveMesh()
        bare.leaveMesh()
    }

    /// Two members on divergent branches introduce, derive a transcript, and reach the merge. This
    /// is the deadlock item 3 exists to break: the merge runs OVER this tunnel.
    @Test func twoDivergentMembersMayIntroduceSoTheMergeCanRun() {
        let meshID = UUID()
        let ours = MeshIntroductionHarness.epoch(7, coordinator: "00000000000000aa")
        let theirs = MeshIntroductionHarness.epoch(7, coordinator: "00000000000000bb")
        let local = MeshIntroductionHarness.endpoint(meshID: meshID, epochRef: ours, sessionID: "local")
        let peer = MeshIntroductionHarness.endpoint(meshID: meshID, epochRef: theirs, sessionID: "peer")
        var exchange = MeshChannelIntroductionExchange(role: .initiator, localHello: local.hello)
        var nonces = MeshIntroductionNonceCache()

        let rejection = exchange.receive(
            peer.hello, roster: MeshIntroductionHarness.roster(local, peer), nonces: &nonces,
            mayReconcileDivergentEpochs: true
        )
        #expect(rejection == nil, "a divergent branch is a merge to run, not a stranger to refuse")
        #expect(exchange.bind(channelBindingHash: MeshIntroductionHarness.binding) != nil)
        #expect(exchange.derivedTranscript != nil)
        // Different counters reconcile too — plan §10.3 mints above both.
        let later = MeshIntroductionHarness.epoch(9, coordinator: "00000000000000bb")
        let laterPeer = MeshIntroductionHarness.endpoint(
            meshID: meshID, epochRef: later, sessionID: "later"
        )
        var second = MeshChannelIntroductionExchange(role: .initiator, localHello: local.hello)
        var secondNonces = MeshIntroductionNonceCache()
        #expect(second.receive(
            laterPeer.hello, roster: MeshIntroductionHarness.roster(local, laterPeer),
            nonces: &secondNonces, mayReconcileDivergentEpochs: true
        ) == nil)
    }

    /// Everything the gate did NOT relax. Each case is refused with reconciliation switched fully
    /// ON, so the refusal is the identity rule doing its job and not the epoch rule doing it by
    /// accident.
    @Test func identityRosterAndMeshRefusalsAreUnchangedWhenReconciling() {
        let meshID = UUID()
        let ours = MeshIntroductionHarness.epoch(7, coordinator: "00000000000000aa")
        let theirs = MeshIntroductionHarness.epoch(7, coordinator: "00000000000000bb")
        let local = MeshIntroductionHarness.endpoint(meshID: meshID, epochRef: ours, sessionID: "local")

        // 1. A stranger: divergent epoch, not on the roster.
        let stranger = MeshIntroductionHarness.endpoint(
            meshID: meshID, epochRef: theirs, sessionID: "stranger"
        )
        #expect(refusal(local: local, peer: stranger,
                        roster: MeshIntroductionHarness.roster(local)) == .unknownIdentity)

        // 2. A departed or removed member: known, and explicitly out.
        let barred = MeshIntroductionHarness.endpoint(
            meshID: meshID, epochRef: theirs, sessionID: "barred"
        )
        #expect(refusal(
            local: local, peer: barred,
            roster: MeshIntroductionHarness.roster(local, barred, barred: [barred.publicKey])
        ) == .barredMember)

        // 3. Another mesh: refused before the epoch rule is even asked.
        let foreign = MeshIntroductionHarness.endpoint(
            meshID: UUID(), epochRef: theirs, sessionID: "foreign"
        )
        #expect(refusal(local: local, peer: foreign,
                        roster: MeshIntroductionHarness.roster(local, foreign)) == .foreignMesh)

        // 4. A malformed head: not a canonical `MeshEpochRef`, so never a divergence to reconcile.
        let malformed = MeshIntroductionHarness.endpoint(
            meshID: meshID, epochRef: "7", sessionID: "malformed"
        )
        #expect(refusal(local: local, peer: malformed,
                        roster: MeshIntroductionHarness.roster(local, malformed)) == .malformedHello)
    }

    /// Runs one hello through an exchange with reconciliation ON, and returns what it answered.
    private func refusal(
        local: MeshIntroductionHarness.Endpoint,
        peer: MeshIntroductionHarness.Endpoint,
        roster: MeshIntroductionRoster
    ) -> MeshIntroductionRejection? {
        var exchange = MeshChannelIntroductionExchange(role: .initiator, localHello: local.hello)
        var nonces = MeshIntroductionNonceCache()
        let rejection = exchange.receive(
            peer.hello, roster: roster, nonces: &nonces, mayReconcileDivergentEpochs: true
        )
        if rejection != nil { #expect(exchange.derivedTranscript == nil, "a refusal leaves nothing") }
        return rejection
    }
}
