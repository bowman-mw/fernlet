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
//
// Since the re-pin to ProximityKit 0.1.1 (2026-10-17) the pure half, `MeshPartitionBranchViewTests`
// (`MeshBranchView` and `MeshPartitionDetector` with no manager, no store and no transport), is
// ProximityKit's package suite of the same name and cells, which its own CI runs; the integrated half
// stays here.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import FernletSocial
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

// MARK: - MeshPartitionDetectionTests

/// The integrated half: `MeshNetworkManager.evaluatePartition(reachable:now:)`, its state machine,
/// its ledger, its rotation roster and its sealed store, all on the fake radio.
@MainActor
@Suite(.serialized)
struct MeshPartitionDetectionTests {

    let store = makeTestStore()

    /// What a scenario needs to talk about a partitioned mesh: the manager with the mesh composition
    /// that owns it, the roster's fingerprints in ascending order, and the mesh id everything is keyed
    /// on.
    private struct Rig {
        /// Fernlet's mesh composition, which built ``manager`` and owns it; kept for the rig's lifetime.
        let features: FernletMeshFeatures
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
        let features = FernletMeshRig.features(store: store, transport: FakeMeshTransportSession())
        let manager = features.mesh
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
        return Rig(features: features, manager: manager, names: names, meshID: meshID)
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
        #expect(
            MeshSessionContextSchema.current == 3,
            "P6 item 1 bumped it; partition detection itself still persists nothing new"
        )
        #expect(context.schemaVersion == 3)
        let text = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        for token in ["temporarilyDisconnected", "present", "branch", "reachable", "unreachable"] {
            #expect(text.contains(token) == false, "the sealed shape must not name \(token)")
        }
        rig.manager.leaveMesh()
        // A second manager over the same sealed root restores membership and no presence at all.
        let restoredFeatures = FernletMeshRig.features(store: store, transport: FakeMeshTransportSession())
        let restored = restoredFeatures.mesh
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
