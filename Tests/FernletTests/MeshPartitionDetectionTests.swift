// MeshPartitionDetectionTests.swift
// FernletTests
//
// P4 item 1 (plan §10.2): partition detection and branch-local operation.
//
// The claims walled here, in the order the plan makes them:
//
//  1. **A partition is presence, never a record.** Losing a roster member marks them
//     `temporarilyDisconnected` and mints nothing: the derived roster, the quorum threshold and the
//     final-pair test are byte-identical before and after, and the sealed file does not move.
//  2. **Reachability returning is a heal, not a re-admission.** `linksRestored` puts the member's
//     presence back and still writes no record.
//  3. **The branch coordinator is the lowest fingerprint PRESENT**, and it flips when the global
//     lowest goes out of reach and back when it returns — including in the roster the manager would
//     actually present with a rotation, which is what scopes the branch's epochs to the branch.
//  4. **Branch-local rotation still fires**, scoped to the branch: fifteen minutes into a split the
//     branch coordinator plans a strictly greater successor over the branch's roster, and the two
//     branches' refs at the same counter are distinct — the `coexist` shape P4 item 3 reconciles.
//  5. **A partition of one idles out at thirty minutes**; one authenticated external heartbeat
//     inside the window is enough to keep a live branch alive.
//  6. **Presence survives a save/load round trip by not being there.** The schema stays at 2 and a
//     restored manager has looked at nothing.
//  7. **Final pair is judged on the merged roster, not the branch** — the minimal guard; §10.6's
//     full treatment is item 6.
//
// **Nothing here sleeps and nothing reads a wall clock for a decision.** Every instant is an
// argument, exactly as `MeshP3AcceptanceTests` and `MeshEpochKeyring` do it, and reachability is a
// `Set<String>` a test hands to `evaluatePartition(reachable:now:)` rather than a radio it has to
// script. The only real time that passes is whatever a seal takes.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - Shared fixtures

/// The roster fixtures both suites below build on.
///
/// Fingerprints come out of real signing keys, so their *order* is not knowable in advance — every
/// scenario therefore sorts and addresses members by rank ("the lowest", "the second lowest")
/// rather than by name, which is also how the shipping coordinator election reads them.
@MainActor
enum MeshPartitionFixtures {

    /// The most members any scenario here builds — plan §9's roster cap is 8, and four is the
    /// shape §10.4's worked example uses (roster 4 → quorum 3 → a 2/2 split moderates nobody).
    static let maxFixtureMembers = 8

    /// A fresh, **provisioned** identity, keyed per call so no two fixtures share a keychain row.
    ///
    /// The provisioning is load-bearing rather than hygiene: an unprovisioned `IdentityService`
    /// cannot sign (`IdentityError.notProvisioned`) and every one of them reports the same
    /// placeholder fingerprint — so a roster built from them would silently dedupe to one member
    /// and every "roster of four" assertion below would be testing a roster of two.
    static func identity(_ label: String) throws -> IdentityService {
        let service = IdentityService(keychainService: "test.mesh.p4partition.\(label).\(UUID().uuidString)")
        try service.ensureProvisioned()
        return service
    }

    /// A ledger in which `founder` self-admits and then admits everybody else.
    ///
    /// Every record is honestly signed — the derived roster does not verify, but a fixture that
    /// forged one would be a fixture no later phase could reuse.
    static func ledger(
        founder: IdentityService, others: [IdentityService], meshID: UUID
    ) throws -> MeshMembershipLedger {
        var ledger = MeshMembershipLedger.empty
        let joiners = ([founder] + others).prefix(maxFixtureMembers)
        for joiner in joiners {
            ledger.admissions = ledger.admissions.inserting(
                SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                    meshID: meshID,
                    joinerFingerprint: joiner.localFingerprint,
                    joinerSigningPublicKey: joiner.localSigningPublicKey,
                    admitterIdentity: founder
                ))
            )
        }
        return ledger
    }

    /// How many membership records a ledger holds, so "no record was written" is one comparison
    /// over all four kinds rather than four assertions that could each be forgotten.
    static func recordCounts(_ ledger: MeshMembershipLedger?) -> [Int] {
        guard let ledger else { return [] }
        return [
            ledger.admissions.count, ledger.departures.count,
            ledger.removals.count, ledger.terminations.count
        ]
    }
}

// MARK: - MeshPartitionBranchViewTests

/// The pure half: ``MeshBranchView`` and ``MeshPartitionDetector``, with no manager, no store and
/// no transport.
@MainActor
@Suite(.serialized)
struct MeshPartitionBranchViewTests {

    /// Four members, their fingerprints in ascending order, and the roster they derive.
    private func fourMemberRoster() throws -> (fingerprints: [String], roster: MeshDerivedRoster) {
        let founder = try MeshPartitionFixtures.identity("founder")
        let others = try (0..<3).map { try MeshPartitionFixtures.identity("member\($0)") }
        let ledger = try MeshPartitionFixtures.ledger(
            founder: founder, others: others, meshID: UUID()
        )
        let roster = ledger.derivedRoster
        return (roster.memberFingerprints, roster)
    }

    /// **Claim 1, at the value level.** An unreachable member is `temporarilyDisconnected` and the
    /// three roster answers a partition must not move are copied through unchanged.
    @Test func anUnreachableMemberIsPresenceAndTheRosterArithmeticDoesNotMove() throws {
        let (names, roster) = try fourMemberRoster()
        let whole = MeshBranchView(
            roster: roster, reachable: Set(names), selfFingerprint: names[0]
        )
        let split = MeshBranchView(
            roster: roster, reachable: [names[0], names[1]], selfFingerprint: names[0]
        )
        #expect(whole.isPartitioned == false)
        #expect(split.isPartitioned)
        #expect(split.presentFingerprints == [names[0], names[1]])
        #expect(split.temporarilyDisconnectedFingerprints == [names[2], names[3]])
        #expect(split.presence(of: names[1]) == .present)
        #expect(split.presence(of: names[3]) == .temporarilyDisconnected)
        #expect(split.presence(of: "not-a-member") == nil, "presence is only defined over the roster")
        // The three answers §10.2/§10.4/§10.6 say a split must not touch.
        #expect(split.rosterMemberCount == 4 && whole.rosterMemberCount == 4)
        #expect(split.rosterQuorumThreshold == 3 && whole.rosterQuorumThreshold == 3)
        #expect(split.rosterIsFinalPair == false)
    }

    /// **Claim 3.** The branch coordinator is the lowest fingerprint present, and it flips when the
    /// global lowest becomes unreachable and back when reachability returns.
    @Test func theBranchCoordinatorIsTheLowestFingerprintPresentAndFlipsBothWays() throws {
        let (names, roster) = try fourMemberRoster()
        let observer = names[3]
        let whole = MeshBranchView(roster: roster, reachable: Set(names), selfFingerprint: observer)
        #expect(whole.branchCoordinatorFingerprint == names[0], "unsplit, the branch is the roster")
        let withoutLowest = MeshBranchView(
            roster: roster, reachable: [names[1], names[2], observer], selfFingerprint: observer
        )
        #expect(withoutLowest.branchCoordinatorFingerprint == names[1],
                "the lowest PRESENT coordinates the branch, not the lowest admitted")
        let healed = MeshBranchView(roster: roster, reachable: Set(names), selfFingerprint: observer)
        #expect(healed.branchCoordinatorFingerprint == names[0], "the flip is reversible")
        // A branch of one coordinates itself, and knows it is alone.
        let alone = MeshBranchView(roster: roster, reachable: [observer], selfFingerprint: observer)
        #expect(alone.branchCoordinatorFingerprint == observer)
        #expect(alone.isLocalBranchCoordinator)
        #expect(alone.isAlone)
        #expect(withoutLowest.isAlone == false, "a branch of three is not a partition of one")
    }

    /// **The detector is an edge-detector.** Only entering a partition raises `linksLost`, and only
    /// a full heal raises `linksRestored`; deepening a split and partially healing one raise
    /// nothing, so the session neither re-arms a window nor prematurely re-activates.
    @Test func onlyTheBoundaryOfAPartitionRaisesAnEvent() throws {
        let (names, roster) = try fourMemberRoster()
        func view(_ reachable: [String]) -> MeshBranchView {
            MeshBranchView(roster: roster, reachable: Set(reachable), selfFingerprint: names[0])
        }
        let whole = view(names)
        let half = view([names[0], names[1]])
        let alone = view([names[0]])
        #expect(MeshPartitionDetector.verdict(previous: nil, current: whole) == .unchanged)
        #expect(MeshPartitionDetector.verdict(previous: nil, current: half) == .linksLost,
                "a device that has never looked and finds itself split has lost links")
        #expect(MeshPartitionDetector.verdict(previous: whole, current: half) == .linksLost)
        #expect(MeshPartitionDetector.verdict(previous: half, current: alone) == .unchanged,
                "a deepening split is already partitioned")
        #expect(MeshPartitionDetector.verdict(previous: alone, current: half) == .unchanged,
                "a partial heal leaves a member the roster still names out of reach")
        #expect(MeshPartitionDetector.verdict(previous: half, current: whole) == .linksRestored)
        #expect(MeshPartitionDetector.verdict(previous: whole, current: whole) == .unchanged)
        #expect(MeshPartitionVerdict.linksLost.sessionEvent == .linksLost)
        #expect(MeshPartitionVerdict.linksRestored.sessionEvent == .linksRestored)
        #expect(MeshPartitionVerdict.unchanged.sessionEvent == nil)
    }

    /// **Claim 7, at the value level.** A 2/2 split of a roster of four is not two final pairs, and
    /// neither branch can moderate anybody — the quorum is still 3 (§10.4's worked example).
    @Test func aBranchOfTwoInARosterOfFourIsNeitherAFinalPairNorAQuorum() throws {
        let (names, roster) = try fourMemberRoster()
        let left = MeshBranchView(
            roster: roster, reachable: [names[0], names[1]], selfFingerprint: names[0]
        )
        let right = MeshBranchView(
            roster: roster, reachable: [names[2], names[3]], selfFingerprint: names[2]
        )
        for branch in [left, right] {
            #expect(branch.branchMemberCount == 2)
            #expect(branch.rosterIsFinalPair == false, "final pair is judged on the MERGED roster")
            #expect(branch.rosterQuorumThreshold > branch.branchMemberCount,
                    "a 2/2 split of a four-roster moderates nobody")
        }
        #expect(roster.isFinalPair == false)
        #expect(roster.memberCount == 4)
    }

    /// **Claim 4, at the value level.** Fifteen minutes into a split, each branch's coordinator
    /// plans a strictly greater successor over **its own** roster — and the two branches' refs at
    /// the same counter are distinct, which is the `coexist` state item 3 reconciles.
    @Test func branchLocalRotationPlansAStrictlyGreaterSuccessorScopedToTheBranch() throws {
        let meshID = UUID()
        let founder = try MeshPartitionFixtures.identity("rot-founder")
        let others = try (0..<3).map { try MeshPartitionFixtures.identity("rot-member\($0)") }
        let roster = try MeshPartitionFixtures.ledger(
            founder: founder, others: others, meshID: meshID
        ).derivedRoster
        let names = roster.memberFingerprints
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // The 15-minute timer, injected: the trigger is requested a quarter of an hour into the
        // split and coalesces into one rotation two seconds later.
        var queue = MeshRotationTriggerQueue()
        let firesAt = start.addingTimeInterval(15 * 60)
        let debounce = MeshRotationTriggerBounds.debounceWindowSeconds
        #expect(queue.request(.timer, at: firesAt)
                == .scheduled(at: firesAt.addingTimeInterval(debounce), cause: .timer))
        #expect(queue.claim(at: firesAt.addingTimeInterval(debounce)) == .timer)
        guard let head = MeshEpochRef.minted(
            counter: 7, coordinatorFingerprint: names[0], meshID: meshID
        ) else {
            Issue.record("could not mint the shared pre-split epoch")
            return
        }
        var minted: [MeshEpochRef] = []
        for branch in [[names[0], names[1]], [names[2], names[3]]] {
            let view = MeshBranchView(
                roster: roster, reachable: Set(branch), selfFingerprint: branch[0]
            )
            guard let coordinator = view.branchCoordinatorFingerprint else {
                Issue.record("a branch of two must elect a coordinator")
                return
            }
            #expect(coordinator == branch[0])
            let plan = MeshRotationPolicy.plan(
                head: head, coordinatorFingerprint: coordinator, meshID: meshID,
                presentedRoster: view.presentFingerprints
            )
            guard case .rotate(let next) = plan else {
                Issue.record("a branch coordinator must be able to rotate its own branch: \(plan)")
                return
            }
            #expect(next.counter == 8, "each branch increments its own head")
            minted.append(next)
        }
        #expect(minted.count == 2)
        #expect(minted[0] != minted[1],
                "same counter, different branch coordinators — two refs that coexist until a merge")
    }
}

// MARK: - MeshPartitionDetectionTests

/// The integrated half: `MeshNetworkManager.evaluatePartition(reachable:now:)`, its state machine,
/// its ledger, its rotation roster and its sealed store, all on the fake radio.
@MainActor
@Suite(.serialized)
struct MeshPartitionDetectionTests {

    let store = makeTestStore()

    /// What a scenario needs to talk about a partitioned mesh: the manager, the roster's
    /// fingerprints in ascending order, and the mesh id everything is keyed on.
    private struct Rig {
        let manager: MeshNetworkManager
        let names: [String]
        let meshID: UUID
    }

    /// A manager holding a live session and a seeded roster of `memberCount` members, this device
    /// among them.
    ///
    /// The ledger is seeded through `seedMembershipLedgerForTesting`, deliberately: seeding it via
    /// the merge trigger would spend the `.merge` rotation these scenarios must not see fire.
    private func makeRig(memberCount: Int) throws -> Rig {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        let meshID = UUID()
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID)
        let local = manager.identityForTesting
        let others = try (0..<max(0, memberCount - 1)).map { try MeshPartitionFixtures.identity("rig\($0)") }
        manager.seedMembershipLedgerForTesting(
            meshID: meshID,
            founderSigningPublicKey: local.localSigningPublicKey,
            ledger: try MeshPartitionFixtures.ledger(founder: local, others: others, meshID: meshID)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }
        #expect(manager.sessionState == .activeForeground)
        let names = manager.membershipVerifier?.roster.memberFingerprints ?? []
        // A short roster would make every assertion below vacuous rather than wrong, so it is a
        // hard requirement of the rig rather than one more expectation among many.
        #expect(names.count == memberCount, "the seeded roster must hold \(memberCount) distinct members")
        return Rig(manager: manager, names: names, meshID: meshID)
    }

    /// **Claims 1 and 2.** A roster member going out of reach raises `linksLost` and partitions the
    /// session; the derived roster, the quorum and every record set are identical before and after,
    /// the sealed file does not move, and reachability returning raises `linksRestored` and still
    /// writes nothing.
    @Test func aLostRosterMemberPartitionsWithoutMintingAnythingAndHealsTheSameWay() throws {
        let rig = try makeRig(memberCount: 3)
        let local = rig.manager.identityForTesting.localFingerprint
        let absent = rig.names.first { $0 != local } ?? ""
        let before = rig.manager.membershipVerifier?.roster
        let recordsBefore = MeshPartitionFixtures.recordCounts(rig.manager.membershipVerifier?.ledger)
        let diskBefore = MeshP3Acceptance.diskState(of: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let lost = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.evaluatePartition(reachable: Set(rig.names.filter { $0 != absent }), now: now)
        }
        #expect(lost == .linksLost)
        #expect(rig.manager.sessionState == .partitioned)
        #expect(rig.manager.presence(of: absent) == .temporarilyDisconnected)
        #expect(rig.manager.presence(of: local) == .present)
        #expect(rig.manager.membershipVerifier?.roster == before, "a disconnect is not a removal")
        #expect(MeshPartitionFixtures.recordCounts(rig.manager.membershipVerifier?.ledger)
                == recordsBefore, "no membership record may be minted by a partition")
        #expect(rig.manager.membershipVerifier?.roster.quorumThreshold == before?.quorumThreshold)
        #expect(MeshP3Acceptance.diskState(of: store) == diskBefore,
                "presence is not durable, so a partition writes no bytes")
        #expect(rig.manager.idleLapseDeadline == now.addingTimeInterval(30 * 60),
                "the window is anchored to the instant the loss was judged")

        let healed = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.evaluatePartition(reachable: Set(rig.names), now: now.addingTimeInterval(60))
        }
        #expect(healed == .linksRestored)
        #expect(rig.manager.sessionState == .activeForeground)
        #expect(rig.manager.awaitingResumeMerge, "a heal is a merge, never a fresh session")
        #expect(rig.manager.presence(of: absent) == .present)
        #expect(rig.manager.idleLapseDeadline == nil)
        #expect(rig.manager.membershipVerifier?.roster == before)
        #expect(MeshPartitionFixtures.recordCounts(rig.manager.membershipVerifier?.ledger)
                == recordsBefore)
        #expect(MeshP3Acceptance.diskState(of: store) == diskBefore)
        rig.manager.leaveMesh()
    }

    /// **Claim 3, integrated.** The roster the manager would present with a rotation — and
    /// therefore the coordinator every epoch it mints is named after — narrows to the branch while
    /// split and widens back on the heal.
    @Test func theRotationRosterAndCoordinatorFollowTheBranchAndComeBack() throws {
        let rig = try makeRig(memberCount: 4)
        let manager = rig.manager
        #expect(manager.rotationRosterForTesting == rig.names)
        #expect(manager.epochCoordinatorFingerprintForTesting == rig.names[0])
        let local = manager.identityForTesting.localFingerprint
        // Drop the globally lowest member (unless that is this device, which is always present:
        // then drop the lowest that is not).
        let dropped = rig.names.first { $0 != local } ?? ""
        let branch = rig.names.filter { $0 != dropped }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.evaluatePartition(reachable: Set(branch), now: Date())
        }
        #expect(manager.sessionState == .partitioned)
        #expect(manager.rotationRosterForTesting == branch, "the rotation is scoped to the branch")
        #expect(manager.epochCoordinatorFingerprintForTesting == branch[0])
        #expect(manager.branchView?.branchCoordinatorFingerprint == branch[0],
                "the presented roster and the coordinator must be derived from the same set")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.evaluatePartition(reachable: Set(rig.names), now: Date())
        }
        #expect(manager.rotationRosterForTesting == rig.names)
        #expect(manager.epochCoordinatorFingerprintForTesting == rig.names[0])
        manager.leaveMesh()
    }

    /// **Claim 5.** A partition of one runs the thirty-minute window to `localIdleStop`; one
    /// authenticated heartbeat from a current member inside the window pushes it out, and neither
    /// this device's own fingerprint nor a non-member can do that.
    @Test func aPartitionOfOneIdlesOutAndOneExternalHeartbeatKeepsABranchAlive() throws {
        let alone = try makeRig(memberCount: 3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window: TimeInterval = 30 * 60
        let selfOnly = Set([alone.manager.identityForTesting.localFingerprint])
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = alone.manager.evaluatePartition(reachable: selfOnly, now: start)
            #expect(alone.manager.branchView?.isAlone == true)
            #expect(alone.manager.evaluateIdleLapse(now: start.addingTimeInterval(window - 1)) == false)
            #expect(alone.manager.evaluateIdleLapse(now: start.addingTimeInterval(window)))
        }
        #expect(alone.manager.sessionState == .localIdleStop)
        alone.manager.leaveMesh()

        let live = try makeRig(memberCount: 3)
        let localFP = live.manager.identityForTesting.localFingerprint
        let partner = live.names.first { $0 != localFP } ?? ""
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = live.manager.evaluatePartition(reachable: [localFP, partner], now: start)
            #expect(live.manager.branchView?.isAlone == false)
            #expect(live.manager.noteExternalHeartbeat(from: localFP, at: start) == false,
                    "this device's own heartbeat is not external")
            #expect(live.manager.noteExternalHeartbeat(from: "stranger", at: start) == false,
                    "only a current member may hold the window open")
            #expect(live.manager.noteExternalHeartbeat(
                from: partner, at: start.addingTimeInterval(window - 60)
            ))
            #expect(live.manager.evaluateIdleLapse(now: start.addingTimeInterval(window)) == false,
                    "a live branch of two does not idle out")
            #expect(live.manager.evaluateIdleLapse(
                now: start.addingTimeInterval(2 * window - 60)
            ), "the window still ends, measured from the last heartbeat")
        }
        #expect(live.manager.sessionState == .localIdleStop)
        live.manager.leaveMesh()
    }

    /// **Claim 6.** `temporarilyDisconnected` survives a save/load round trip **by not being
    /// there**: the sealed context still stamps schema 2, its bytes name nothing about presence,
    /// and a manager restored from it has looked at nothing.
    @Test func presenceIsNotPersistedAndTheSchemaStaysAtTwo() throws {
        let rig = try makeRig(memberCount: 3)
        let localFP = rig.manager.identityForTesting.localFingerprint
        let saved = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = rig.manager.evaluatePartition(reachable: [localFP], now: Date())
            return rig.manager.persistSessionContext(addingEpochHead: nil)
        }
        #expect(saved, "the partitioned device must still be able to seal its context")
        #expect(rig.manager.branchView?.isPartitioned == true)
        guard let context = MeshP3Acceptance.loadContext(from: store) else {
            Issue.record("the sealed context must load back")
            return
        }
        #expect(MeshSessionContextSchema.current == 2, "this item persists nothing new")
        #expect(context.schemaVersion == 2)
        let text = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        for token in ["temporarilyDisconnected", "present", "branch", "reachable", "unreachable"] {
            #expect(text.contains(token) == false, "the sealed shape must not name \(token)")
        }
        rig.manager.leaveMesh()
        // A second manager over the same sealed root restores membership and no presence at all.
        let restored = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = restored.restoreSessionContextAtLaunch(now: Date())
        }
        #expect(restored.branchView == nil, "presence is never restored, because it is never written")
        #expect(restored.lastExternalHeartbeatAt == nil)
        restored.leaveMesh()
    }

    /// **Claim 7, integrated.** The termination derivation reads the **roster**, not the reachable
    /// set: a branch of two inside a merged roster of four is not a final pair and cannot reach a
    /// quorum. (§10.6's full treatment — the handoff, the downgrade — is item 6.)
    @Test func aBranchOfTwoDoesNotBecomeAFinalPair() throws {
        let rig = try makeRig(memberCount: 4)
        let localFP = rig.manager.identityForTesting.localFingerprint
        let partner = Array(rig.names.filter { $0 != localFP }.prefix(1))
        let branch = ([localFP] + partner).sorted()
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = rig.manager.evaluatePartition(reachable: Set(branch), now: Date())
        }
        #expect(rig.manager.branchView?.branchMemberCount == 2)
        #expect(rig.manager.membershipVerifier?.roster.isFinalPair == false,
                "a 2/2 split of a four-roster is not two final pairs")
        #expect(rig.manager.membershipVerifier?.roster.memberCount == 4)
        #expect(rig.manager.membershipVerifier?.roster.quorumThreshold == 3)
        #expect(rig.manager.branchView?.rosterIsFinalPair == false)
        rig.manager.leaveMesh()
    }
}
