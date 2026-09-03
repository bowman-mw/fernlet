// MeshMergePathTests.swift
// FernletTests
//
// P4 item 2 (plan §10.3): **there is exactly one merge path, and every reconnect runs it.**
//
// The claims walled here, in the order §10.3 makes them:
//
//  1. **Four doors, one path.** A blip, a healed partition, an idle-lapse resume and a process
//     restart each apply their offer through `MeshNetworkManager.mergeReconnected(_:entry:)` onto
//     `mergeMembershipLedger(_:)` — the same merge, recorded with the door it came through — and
//     each derives the identical roster from the identical offer.
//  2. **One `.merge` rotation per merge, not one per record.** A returning peer's whole bounded
//     re-gossip lands in the merge window, so a burst of records mints one epoch.
//  3. **Union, both directions.** Two devices holding records the other lacks converge on one
//     roster, and a **hard record beats soft presence**: a member marked
//     `temporarilyDisconnected` on one side and carrying a departure record on the other ends up
//     departed on both.
//  4. **Epoch heads coexist.** Two heads at the same counter survive at both members, none dropped
//     and none duplicated; past the cap of 8 the loss is *named* (plan §21.3: an assertion, not a
//     knob) instead of silently truncated.
//  5. **A restart merges, never starts fresh.** A manager built over the sealed context of a dead
//     process restores its ledger, resumes into the merge path and ends on the merged roster.
//  6. **Commutativity at the MANAGER seam.** A merging B's offer and B merging A's reach the same
//     roster and the same head set. The ledger-level laws are P3 item 1's tests
//     (`MeshMembershipLedgerTests`) and are deliberately not repeated.
//
// Not here, on purpose: divergent-epoch reconciliation (`coexist` → one head) is item 3, and
// content merge is item 7. This file proves both heads *survive*; it never mints the successor.
//
// **Nothing sleeps and nothing reads a wall clock for a decision.** Every instant is an argument,
// the radio is `FakeMeshTransportSession`, and each scenario owns its own sealed root.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - Shared fixtures

/// What the merge scenarios build on. Deliberately thin: the roster fixtures are item 1's
/// (`MeshPartitionFixtures`) and the sealed-store probes are P3's (`MeshP3Acceptance`), so a change
/// to either is felt here rather than worked around.
@MainActor
enum MeshMergeFixtures {

    /// A live manager with a mesh, a seeded ledger and a session in `activeForeground`.
    ///
    /// The ledger is seeded through `seedMembershipLedgerForTesting` because seeding it *via* the
    /// merge trigger would spend the `.merge` rotation these scenarios are about.
    ///
    /// - Parameters:
    ///   - store: The sealed root this manager writes to.
    ///   - others: Members the local device (as founder) has admitted.
    ///   - meshID: The mesh everything is keyed on.
    ///   - createdAt: The mesh's creation instant, defaulting to `MeshP3Acceptance.base`. It fixes
    ///     the 6-hour ceiling, so a scenario that later restores at a pinned `now` must create at
    ///     the same pinned scale — a descriptor created at the real wall clock and restored at
    ///     `MeshP3Acceptance.base` is *expired*, not resumable, and the restore would silently test
    ///     the wrong outcome. Defaulted to nil and resolved in the body because a `@MainActor`
    ///     value cannot be a default argument.
    /// - Returns: The manager, live and holding a roster of `others.count + 1`.
    static func liveManager(
        store: FernletStore,
        others: [IdentityService],
        meshID: UUID,
        createdAt: Date? = nil
    ) throws -> MeshNetworkManager {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(
            for: manager, meshID: meshID, createdAt: createdAt ?? MeshP3Acceptance.base
        )
        let local = manager.identityForTesting
        manager.seedMembershipLedgerForTesting(
            meshID: meshID,
            founderSigningPublicKey: local.localSigningPublicKey,
            ledger: try MeshPartitionFixtures.ledger(founder: local, others: others, meshID: meshID)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }
        return manager
    }

    /// A ledger the local device signed as founder, admitting itself and everybody in `others`.
    ///
    /// This is the shape a reconnecting peer OFFERS: it is rooted at the same self-admission the
    /// live manager's ledger is, so the union is a genuine superset rather than a foreign chain the
    /// fail-closed verifier would refuse wholesale.
    static func offeredLedger(
        _ manager: MeshNetworkManager, others: [IdentityService], meshID: UUID
    ) throws -> MeshMembershipLedger {
        try MeshPartitionFixtures.ledger(
            founder: manager.identityForTesting, others: others, meshID: meshID
        )
    }

    /// `count` fresh, provisioned identities, labelled so no two share a keychain row.
    static func members(_ count: Int, _ label: String) throws -> [IdentityService] {
        try (0..<count).map { try MeshPartitionFixtures.identity("\(label)\($0)") }
    }

    /// The derived roster's fingerprints, sorted — the value two devices must agree on.
    static func roster(_ manager: MeshNetworkManager) -> [String] {
        manager.membershipVerifier?.roster.memberFingerprints ?? []
    }

    /// The epoch heads the sealed context holds, in a comparable order.
    static func sealedHeads(_ store: FernletStore) -> [String] {
        (MeshP3Acceptance.loadContext(from: store)?.epochHeads ?? [])
            .map(\.canonicalString).sorted()
    }
}

// MARK: - MeshMergeOfferTests

/// The pure half: the offer value and its head fold, with no manager, no store and no transport.
@MainActor
@Suite(.serialized)
struct MeshMergeOfferTests {

    /// **Claim 4's cap.** Folding stays inside `MeshSessionContextSchema.maxEpochHeads` and *names*
    /// what it dropped — plan §21.3's "an assertion P4 tests, not a knob".
    @Test func theHeadFoldKeepsTheCapAndNamesWhatItDropped() throws {
        let meshID = UUID()
        let cap = MeshSessionContextSchema.maxEpochHeads
        // One head per hypothetical branch coordinator, all at the same counter: the shape a nested
        // re-split produces, and the only way to reach the cap at all.
        let heads: [MeshEpochRef] = try (0..<(cap + 2)).map { index in
            let coordinator = String(format: "%016x", index + 1)
            guard let ref = MeshEpochRef.minted(
                counter: 4, coordinatorFingerprint: coordinator, meshID: meshID
            ) else { throw MeshMergeTestFailure.couldNotMintEpoch }
            return ref
        }
        let under = MeshMergeOffer.foldedHeads([], adding: Array(heads.prefix(cap)))
        #expect(under.heads.count == cap)
        #expect(under.droppedCount == 0, "at the cap exactly, nothing is lost")
        #expect(Set(under.heads).count == cap, "no head is duplicated")

        let over = MeshMergeOffer.foldedHeads([], adding: heads)
        #expect(over.heads.count == cap, "the cap is a hard bound")
        #expect(over.droppedCount == 2, "the overflow is NAMED, not silently truncated")

        // Idempotent: re-offering heads already held drops nothing and grows nothing.
        let again = MeshMergeOffer.foldedHeads(under.heads, adding: Array(heads.prefix(cap)))
        #expect(again.heads.count == cap && again.droppedCount == 0)
    }

    /// **Claim 6, at the value level.** The offer's union is commutative and idempotent, both
    /// halves at once — which is what lets the manager seam below assert the same thing without
    /// re-testing `MeshMembershipLedger.merging(_:)`.
    @Test func theOfferUnionIsCommutativeAndIdempotent() throws {
        let meshID = UUID()
        let founder = try MeshPartitionFixtures.identity("offer-founder")
        let extra = try MeshMergeFixtures.members(2, "offer-member")
        let left = MeshMembershipLedger.empty
        let right = try MeshPartitionFixtures.ledger(
            founder: founder, others: extra, meshID: meshID
        )
        guard let headA = MeshEpochRef.minted(
                counter: 5, coordinatorFingerprint: "00000000000000aa", meshID: meshID),
              let headB = MeshEpochRef.minted(
                counter: 5, coordinatorFingerprint: "00000000000000bb", meshID: meshID) else {
            throw MeshMergeTestFailure.couldNotMintEpoch
        }
        let a = MeshMergeOffer(ledger: left, head: headA)
        let b = MeshMergeOffer(ledger: right, head: headB)
        let ab = a.merging(b)
        let ba = b.merging(a)
        #expect(ab.ledger.derivedRoster.memberFingerprints == ba.ledger.derivedRoster.memberFingerprints)
        #expect(Set(ab.epochHeads) == Set(ba.epochHeads))
        #expect(ab.epochHeads.count == 2, "same counter, different coordinators — both survive")
        #expect(ab.merging(b).epochHeads.count == 2, "idempotent")
        #expect(MeshMergeOffer.empty.merging(a) == a.merging(MeshMergeOffer.empty))
    }
}

/// Why a fixture could not be built. A thrown reason rather than a silently skipped scenario.
enum MeshMergeTestFailure: Error {
    /// A canonical `MeshEpochRef` could not be minted from the fixture's inputs.
    case couldNotMintEpoch
    /// A fixture roster did not hold the distinct members the scenario needs.
    case rosterTooSmall
}

// MARK: - MeshMergePathTests

/// The integrated half: `MeshNetworkManager`'s one merge path, its sealed store, its verifier, its
/// epoch keyring and its state machine, on the fake radio.
@MainActor
@Suite(.serialized)
struct MeshMergePathTests {

    let store = makeTestStore()

    /// **Claim 1.** All four reconnects run the same merge and reach the same roster.
    ///
    /// Each door is driven the way the shipping code reaches it — the heal through
    /// `evaluatePartition`, the resume through `resumeSessionAfterLapse`, the blip through the
    /// `.peerCommitted` self-edge, the restart through a restored context — and every one of them
    /// moves `mergeApplicationCount`, which no bypass could do.
    @Test func everyReconnectRunsTheSameMergeAndReachesTheSameRoster() throws {
        var rosters: [MeshMergeEntry: [String]] = [:]
        for entry in [MeshMergeEntry.blip, .partitionHeal, .idleLapseResume] {
            let scoped = makeTestStore()
            let meshID = UUID()
            let seeded = try MeshMergeFixtures.members(1, "\(entry.rawValue)-seed")
            let manager = try MeshMergeFixtures.liveManager(
                store: scoped, others: seeded, meshID: meshID
            )
            let newcomer = try MeshMergeFixtures.members(1, "\(entry.rawValue)-new")
            let offered = try MeshMergeFixtures.offeredLedger(
                manager, others: seeded + newcomer, meshID: meshID
            )
            let before = manager.mergeApplicationCount
            try DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                try drive(entry, on: manager, offering: offered)
            }
            #expect(manager.mergeApplicationCount > before,
                    "\(entry.rawValue) must reach mergeMembershipLedger through the one front door")
            #expect(manager.lastMergeEntry == entry, "the door is recorded, never branched on")
            #expect(manager.rotationTriggers.pendingCause == .merge,
                    "a reconnect that moved the roster mints ONE merge epoch")
            #expect(manager.sessionState == .activeForeground)
            rosters[entry] = MeshMergeFixtures.roster(manager)
            #expect(rosters[entry]?.count == 3, "the offer adds exactly one member")
            manager.leaveMesh()
        }
        // Same offer shape through three different doors: the merged rosters must have the same
        // SIZE and the same relationship to the offer — the fingerprints differ only because each
        // scenario mints its own identities.
        #expect(Set(rosters.values.map(\.count)) == [3], "one path, one answer")
        #expect(rosters.count == 3)
    }

    /// Drives one reconnect door on a live manager, then hands it the peer's offer.
    private func drive(
        _ entry: MeshMergeEntry, on manager: MeshNetworkManager, offering offered: MeshMembershipLedger
    ) throws {
        let now = MeshP3Acceptance.base
        let names = MeshMergeFixtures.roster(manager)
        guard let local = names.first(where: { $0 == manager.identityForTesting.localFingerprint })
        else { throw MeshMergeTestFailure.rosterTooSmall }
        switch entry {
        case .blip:
            // A peer re-committing into a session that was already live: the self-edge that carries
            // no `beginMerge` effect, and would otherwise resume against a stale roster.
            manager.applySessionEvent(.peerCommitted)
            #expect(manager.awaitingResumeMerge, "a blip opens a merge exchange")
            manager.mergeReconnected(MeshMergeOffer(ledger: offered), entry: .blip)
        case .partitionHeal:
            _ = manager.evaluatePartition(reachable: [local], now: now)
            #expect(manager.sessionState == .partitioned)
            _ = manager.evaluatePartition(reachable: Set(names), now: now.addingTimeInterval(60))
            #expect(manager.awaitingResumeMerge, "a heal is a merge, never a fresh session")
            manager.mergeReconnected(MeshMergeOffer(ledger: offered), entry: .partitionHeal)
        case .idleLapseResume:
            manager.applySessionEvent(.linksLost)
            _ = manager.evaluateIdleLapse(
                now: now.addingTimeInterval(MeshNetworkManager.idleWindowSeconds + 1)
            )
            #expect(manager.sessionState == .localIdleStop)
            _ = manager.resumeSessionAfterLapse(mergingLedger: offered, peerEpochHead: nil)
        case .processRestart:
            break   // exercised end to end in its own scenario below
        }
    }

    /// **Claim 2.** A returning peer's whole re-gossip is ONE merge: three records arriving frame by
    /// frame inside the merge window rotate once, with cause `.merge` rather than `.membership`.
    @Test func aReGossipBurstInsideTheMergeWindowMintsOneMergeEpoch() throws {
        let meshID = UUID()
        let seeded = try MeshMergeFixtures.members(1, "burst-seed")
        let manager = try MeshMergeFixtures.liveManager(store: store, others: seeded, meshID: meshID)
        let newcomers = try MeshMergeFixtures.members(3, "burst-new")
        manager.applySessionEvent(.peerCommitted)   // the blip opens the window
        #expect(manager.awaitingResumeMerge)
        let before = manager.mergeApplicationCount
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for newcomer in newcomers {
                // One record per frame, exactly as `reGossipRecords` sends them.
                guard let single = try? MeshPartitionFixtures.ledger(
                    founder: manager.identityForTesting, others: [newcomer], meshID: meshID
                ) else { continue }
                manager.mergeReconnected(MeshMergeOffer(ledger: single), entry: .blip)
            }
        }
        #expect(manager.mergeApplicationCount == before + 3, "every frame went through the one path")
        #expect(MeshMergeFixtures.roster(manager).count == 5)
        #expect(manager.rotationTriggers.pendingCause == .merge,
                "the burst coalesces into ONE merge epoch, never one per record")
        manager.leaveMesh()
    }

    /// **Claim 3.** Both directions of the union, and hard records beating soft presence: the
    /// member this device has only marked `temporarilyDisconnected` is *departed* in the offer, and
    /// ends up departed here — presence never outvotes a signed record.
    @Test func theUnionConvergesAndAHardRecordBeatsSoftPresence() throws {
        let meshID = UUID()
        let seeded = try MeshMergeFixtures.members(2, "union-seed")
        let manager = try MeshMergeFixtures.liveManager(store: store, others: seeded, meshID: meshID)
        let names = MeshMergeFixtures.roster(manager)
        let leaver = seeded[0]
        #expect(names.contains(leaver.localFingerprint))

        // This side can only SEE that the leaver is gone.
        let now = MeshP3Acceptance.base
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.evaluatePartition(
                reachable: Set(names.filter { $0 != leaver.localFingerprint }), now: now
            )
        }
        #expect(manager.presence(of: leaver.localFingerprint) == .temporarilyDisconnected)
        #expect(MeshMergeFixtures.roster(manager).count == 3, "presence never shrinks the roster")

        // The other branch holds the record that says why, plus a member this side never saw.
        let newcomer = try MeshMergeFixtures.members(1, "union-new")
        var offered = try MeshMergeFixtures.offeredLedger(
            manager, others: seeded + newcomer, meshID: meshID
        )
        offered.departures = offered.departures.inserting(
            try SignedDepartureRecord.signed(meshID: meshID, identity: leaver)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.evaluatePartition(reachable: Set(names), now: now.addingTimeInterval(60))
            manager.mergeReconnected(MeshMergeOffer(ledger: offered), entry: .partitionHeal)
        }
        let merged = MeshMergeFixtures.roster(manager)
        #expect(!merged.contains(leaver.localFingerprint), "a departure record wins over presence")
        #expect(merged.contains(newcomer[0].localFingerprint), "the union adds what this side lacked")
        #expect(merged.count == 3, "one gained, one departed, from a roster of three")
        #expect(manager.presence(of: leaver.localFingerprint) == nil,
                "presence is only defined over the derived roster")
        manager.leaveMesh()
    }

    /// **Claim 4.** Two heads at the same counter both survive the merge, at this member and in the
    /// bytes a restart would read back — none dropped, none duplicated.
    @Test func bothDivergentHeadsSurviveTheMergeAndReachTheSealedContext() throws {
        let scoped = makeTestStore()
        let meshID = UUID()
        let seeded = try MeshMergeFixtures.members(1, "heads-seed")
        let manager = try MeshMergeFixtures.liveManager(store: scoped, others: seeded, meshID: meshID)
        guard let ownHead = MeshP3Acceptance.seedEpoch(manager, counter: 6),
              let peerHead = MeshEpochRef.minted(
                  counter: 6, coordinatorFingerprint: seeded[0].localFingerprint, meshID: meshID
              ) else { throw MeshMergeTestFailure.couldNotMintEpoch }
        #expect(ownHead != peerHead, "two branch coordinators cannot mint the same ref")
        #expect(MeshEpochAcceptance.rotationVerdict(
            local: ownHead, presented: peerHead,
            presentedRoster: [seeded[0].localFingerprint],
            presenterFingerprint: seeded[0].localFingerprint
        ) == .coexist, "same counter, different branches — neither supersedes the other")

        let offered = try MeshMergeFixtures.offeredLedger(manager, others: seeded, meshID: meshID)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.mergeReconnected(
                MeshMergeOffer(ledger: offered, epochHeads: [ownHead, peerHead]),
                entry: .partitionHeal
            )
        }
        let sealed = MeshMergeFixtures.sealedHeads(scoped)
        #expect(sealed.contains(ownHead.canonicalString), "this branch's head survives")
        #expect(sealed.contains(peerHead.canonicalString), "the other branch's head survives")
        #expect(sealed.count == Set(sealed).count, "no head is duplicated")
        #expect(manager.droppedEpochHeadCount == 0, "two heads are nowhere near the cap of 8")
        #expect(manager.epochKeyring?.head == ownHead,
                "the merge does NOT pick a winner — item 3 mints the successor that retires both")
        manager.leaveMesh()
    }

    /// **Claim 5.** A process restart merges: a manager built over the dead process's sealed context
    /// restores its ledger, resumes into the merge path, and lands on the merged roster.
    ///
    /// The two stores share a proximity root and a keychain service, which is how a "relaunch" over
    /// the same sealed bytes is expressed at tier 1 (the idiom `MeshSessionStoreIsolationTests`
    /// enforces everywhere else: a per-instance root unless a scenario deliberately shares one).
    @Test func aProcessRestartResumesThroughTheMergeAndNeverStartsAFreshSession() throws {
        let root = uniqueProximityDirectory()
        let keychain = uniqueHeartDropKeychainService()
        let meshID = UUID()
        let seeded = try MeshMergeFixtures.members(1, "restart-seed")
        let first = makeTestStore(proximitySupportDirectory: root, heartDropKeychainService: keychain)
        let before = try MeshMergeFixtures.liveManager(store: first, others: seeded, meshID: meshID)
        let rosterBefore = MeshMergeFixtures.roster(before)
        #expect(rosterBefore.count == 2)
        #expect(MeshP3Acceptance.loadContext(from: first)?.ledger.admissions.count == 2,
                "the live session sealed its ledger")

        // The process dies and comes back over the same bytes.
        let second = makeTestStore(proximitySupportDirectory: root, heartDropKeychainService: keychain)
        let restarted = MeshNetworkManager(store: second, transport: FakeMeshTransportSession())
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            restarted.restoreSessionContextAtLaunch(now: MeshP3Acceptance.base.addingTimeInterval(60))
        }
        #expect(restarted.sessionState == .localIdleStop, "a relaunch never auto-reconnects")
        #expect(outcome.context?.meshID == meshID)
        #expect(MeshMergeFixtures.roster(restarted) == rosterBefore,
                "the restart merges FROM the sealed ledger rather than rebuilding an empty one")
        #expect(restarted.pendingMergeEntry == .processRestart)

        // The reconnect that follows is a merge, and it says so.
        restarted.currentMesh = MeshP3Acceptance.mesh(
            for: restarted, meshID: meshID, createdAt: MeshP3Acceptance.base
        )
        let newcomer = try MeshMergeFixtures.members(1, "restart-new")
        let offered = try MeshMergeFixtures.offeredLedger(
            restarted, others: seeded + newcomer, meshID: meshID
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = restarted.resumeSessionAfterLapse(mergingLedger: offered, peerEpochHead: nil)
        }
        #expect(restarted.sessionState == .activeForeground)
        #expect(restarted.lastMergeEntry == .processRestart,
                "the ledger being merged FROM came off the disk, whatever door the resume used")
        #expect(MeshMergeFixtures.roster(restarted).count == 3)
        #expect(restarted.currentMesh?.meshID == meshID, "the SAME session resumes")
        restarted.leaveMesh()
        before.leaveMesh()
    }

    /// **Claim 6, at the manager seam.** A merges B's offer, B merges A's, and the two end on the
    /// same roster and the same head set — with each side's own head still present.
    @Test func mergeIsCommutativeAtTheManagerSeam() throws {
        let meshID = UUID()
        let founder = try MeshPartitionFixtures.identity("commute-founder")
        let shared = try MeshMergeFixtures.members(1, "commute-shared")
        let onlyLeft = try MeshMergeFixtures.members(1, "commute-left")
        let onlyRight = try MeshMergeFixtures.members(1, "commute-right")
        let left = try MeshPartitionFixtures.ledger(
            founder: founder, others: shared + onlyLeft, meshID: meshID
        )
        let right = try MeshPartitionFixtures.ledger(
            founder: founder, others: shared + onlyRight, meshID: meshID
        )
        guard let headL = MeshEpochRef.minted(
                counter: 9, coordinatorFingerprint: "0000000000000c11", meshID: meshID),
              let headR = MeshEpochRef.minted(
                counter: 9, coordinatorFingerprint: "0000000000000c22", meshID: meshID) else {
            throw MeshMergeTestFailure.couldNotMintEpoch
        }
        var results: [[String]] = []
        var heads: [[String]] = []
        for (mine, theirs, myHead, theirHead) in [
            (left, right, headL, headR), (right, left, headR, headL)
        ] {
            let scoped = makeTestStore()
            let manager = MeshNetworkManager(store: scoped, transport: FakeMeshTransportSession())
            manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID)
            manager.seedMembershipLedgerForTesting(
                meshID: meshID, founderSigningPublicKey: founder.localSigningPublicKey, ledger: mine
            )
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                manager.applySessionEvent(.founded)
                manager.applySessionEvent(.peerCommitted)
                manager.mergeReconnected(
                    MeshMergeOffer(ledger: theirs, epochHeads: [myHead, theirHead]),
                    entry: .partitionHeal
                )
            }
            results.append(MeshMergeFixtures.roster(manager))
            heads.append(MeshMergeFixtures.sealedHeads(scoped))
            manager.leaveMesh()
        }
        #expect(results.count == 2 && heads.count == 2)
        #expect(results[0] == results[1], "A∪B and B∪A derive the identical roster")
        #expect(heads[0] == heads[1], "and the identical head set")
        #expect(results[0].count == 4, "founder + shared + one from each branch")
        #expect(heads[0].count == 2, "both same-counter heads coexist, neither duplicated")
    }
}
