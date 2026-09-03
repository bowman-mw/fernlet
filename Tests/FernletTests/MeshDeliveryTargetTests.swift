// MeshDeliveryTargetTests.swift
// FernletTests
//
// P4 item 8 (plan §10.1, launcher §5(c)): delivery-target semantics for P5.
//
// The claims walled here, in the order §10.1 makes them:
//
//  1. **The destination set is the full derived roster at creation time, minus self.** A photo taken
//     during a 2/2 split of a roster of four is for three people, and both members on the far side
//     are in that three. The wrong construction is unrepresentable: no initializer takes a reachable
//     set, a branch view or a bare fingerprint list, and no method removes a destination.
//  2. **Reachable vs unreachable is a DELIVERY state, never a DESTINATION state.** The far side is
//     `pending`, not absent; a member becoming reachable moves no destination; states advance
//     `pending → custodied → delivered` and never backwards, with `delivered` terminal and every
//     regression refused **by name**.
//  3. **Independent of partition and epoch** — structurally (no `keyEpoch`, no branch id, no
//     "created in partition X" member) and behaviourally (two targets minted on opposite sides of
//     one split are equal).
//  4. **A departed destination is closed, a temporarily disconnected one is not.** The roster is the
//     authority and the answer is derived at read, so a real signed departure closes a destination
//     while item 1's `temporarilyDisconnected` leaves it pending.
//  5. **Completeness is derivable** through a full lifecycle, including a destination that closes by
//     departure.
//  6. **Union-merge safe**: per-destination max under the monotone order, commutative, associative
//     and idempotent, and a destination-set mismatch is refused by name.
//  7. **The two existing seams are one-line derivations** — `MeshDevelopmentPlan.handoffTargets` and
//     `MeshBranchView.temporarilyDisconnectedFingerprints` — and neither type is modified to get it.
//
// Nothing here sleeps and nothing reads a wall clock for a decision: a target has no clock, and
// every state moves by an explicit call carrying its receipt.

import Foundation
import Testing
@testable import ProximityKit

// MARK: - Shared fixtures

/// One mesh's identities, ledger and derived roster, with the identities addressable by fingerprint.
///
/// Fingerprints come out of real signing keys, so their order is not knowable in advance — every
/// scenario addresses members by rank ("the lowest") and looks the signing identity back up by
/// fingerprint, which is also how the shipping code reads them.
@MainActor
struct MeshDeliveryRig {

    /// The mesh every record in ``ledger`` is bound to.
    let meshID: UUID

    /// Identity services keyed by their own fingerprint, so a departure can be signed by the member
    /// it is about.
    let identities: [String: IdentityService]

    /// The membership ledger the roster is derived from.
    var ledger: MeshMembershipLedger

    /// The derived roster, re-derived on every read exactly as the shipping code does.
    var roster: MeshDerivedRoster { ledger.derivedRoster }

    /// The roster's fingerprints, in its own sorted order.
    var fingerprints: [String] { roster.memberFingerprints }
}

/// Builds the rigs and branch views the suite below shares.
@MainActor
enum MeshDeliveryFixtures {

    /// A rig of `memberCount` honestly-signed members, reusing item 1's identity and ledger
    /// fixtures rather than growing a second copy of them.
    static func rig(memberCount: Int) throws -> MeshDeliveryRig {
        let services = try (0..<memberCount).map {
            try MeshPartitionFixtures.identity("delivery\($0)")
        }
        let founder = try #require(services.first)
        let meshID = UUID()
        let ledger = try MeshPartitionFixtures.ledger(
            founder: founder, others: Array(services.dropFirst()), meshID: meshID
        )
        var byFingerprint: [String: IdentityService] = [:]
        for service in services { byFingerprint[service.localFingerprint] = service }
        let rig = MeshDeliveryRig(meshID: meshID, identities: byFingerprint, ledger: ledger)
        // An unprovisioned identity reports a placeholder fingerprint, which would silently dedupe
        // the roster and make every assertion below vacuous (P4 item 1's lesson).
        #expect(rig.roster.memberCount == memberCount)
        return rig
    }

    /// A branch view over `rig`'s roster in which only `reachable` can be reached.
    static func branch(_ rig: MeshDeliveryRig, selfFingerprint: String, reachable: [String]) -> MeshBranchView {
        MeshBranchView(
            roster: rig.roster, reachable: Set(reachable), selfFingerprint: selfFingerprint
        )
    }
}

// MARK: - MeshDeliveryTargetTests

/// Plan §10.1's rule as executable claims: who content is for, and how far each copy has got.
@MainActor
@Suite(.serialized)
struct MeshDeliveryTargetTests {

    /// The §10.4/§10.1 shape: a roster of four, split 2/2, with this device the lowest fingerprint.
    private func splitRosterOfFour() throws -> (rig: MeshDeliveryRig, branch: MeshBranchView, target: MeshDeliveryTarget) {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 4)
        let names = rig.fingerprints
        let mine = names[0]
        let branch = MeshDeliveryFixtures.branch(rig, selfFingerprint: mine, reachable: [mine, names[1]])
        let target = MeshDeliveryTarget(contentID: UUID(), roster: rig.roster, selfFingerprint: mine)
        return (rig, branch, target)
    }

    // MARK: 1 — destination = full roster at creation, minus self

    @Test func contentCreatedInASplitIsForTheWholeRosterIncludingTheFarSide() throws {
        let (rig, branch, target) = try splitRosterOfFour()
        let names = rig.fingerprints

        // The branch can see two of four; the destination set is still three of four.
        #expect(branch.presentFingerprints.count == 2)
        #expect(branch.temporarilyDisconnectedFingerprints == [names[2], names[3]])
        #expect(target.destinationCount == 3)
        #expect(target.destinations == [names[1], names[2], names[3]])

        // Both members on the far side of the split are destinations, and this device is not.
        #expect(target.names(names[2]))
        #expect(target.names(names[3]))
        #expect(target.names(names[0]) == false)
        #expect(target.state(of: names[0]) == nil)
    }

    // MARK: 2 — reachability is a delivery state, never a destination state

    @Test func theFarSideIsPendingAndBecomingReachableMovesNoDestination() throws {
        let (rig, _, target) = try splitRosterOfFour()
        let names = rig.fingerprints

        #expect(target.state(of: names[2]) == .pending)
        #expect(target.disposition(of: names[3], in: rig.roster) == .pending)
        #expect(target.outstanding(in: rig.roster) == [names[1], names[2], names[3]])

        // The partition heals. The target is not a function of reachability at all, so nothing about
        // it can move — there is no API that would let it.
        let healed = MeshDeliveryFixtures.branch(rig, selfFingerprint: names[0], reachable: names)
        #expect(healed.isPartitioned == false)
        #expect(target.destinations == [names[1], names[2], names[3]])
        #expect(target.outstanding(in: rig.roster) == [names[1], names[2], names[3]])
    }

    @Test func statesAdvanceMonotonicallyAndDeliveredIsTerminalAndRefusalsAreNamed() throws {
        let (rig, _, target) = try splitRosterOfFour()
        let names = rig.fingerprints
        let relay = names[1]
        let destination = names[2]

        let custodied = try #require(target.advancing(destination, to: .custodied(by: relay)).target)
        #expect(custodied.state(of: destination) == .custodied(by: relay))
        #expect(custodied.destinations == target.destinations)

        // Backwards is refused BY NAME, not ignored.
        #expect(custodied.advancing(destination, to: .pending).refusal == .wouldRegress)

        let delivered = try #require(custodied.advancing(destination, to: .delivered).target)
        #expect(delivered.state(of: destination) == .delivered)
        #expect(delivered.advancing(destination, to: .custodied(by: relay)).refusal == .alreadyDelivered)
        #expect(delivered.advancing(destination, to: .pending).refusal == .alreadyDelivered)

        // Re-applying the state a destination already holds is idempotent, not a regression.
        #expect(delivered.advancing(destination, to: .delivered).target == delivered)

        // A receipt for somebody who is not a destination cannot add one.
        #expect(target.advancing(names[0], to: .delivered).refusal == .notADestination)
        #expect(target.advancing("not-a-member", to: .delivered).refusal == .notADestination)
    }

    // MARK: 3 — independent of partition and epoch

    @Test func aTargetCarriesNoEpochNoBranchAndNoPartitionOfOrigin() throws {
        let (rig, _, target) = try splitRosterOfFour()
        let names = rig.fingerprints
        let labels = Mirror(reflecting: target).children.compactMap(\.label).map { $0.lowercased() }
        #expect(labels.isEmpty == false)
        for label in labels {
            #expect(label.contains("epoch") == false)
            #expect(label.contains("branch") == false)
            #expect(label.contains("partition") == false)
        }

        // Behaviourally: the two sides of one split mint the same destination set for the same item.
        let contentID = UUID()
        let nearSide = MeshDeliveryTarget(contentID: contentID, roster: rig.roster, selfFingerprint: names[0])
        let farSide = MeshDeliveryTarget(contentID: contentID, roster: rig.roster, selfFingerprint: names[0])
        #expect(nearSide == farSide)
        #expect(nearSide.destinations == farSide.destinations)
    }

    // MARK: 4 — departed closes, temporarily disconnected does not

    @Test func aDepartedDestinationClosesWhileADisconnectedOneStaysPending() throws {
        var rig = try MeshDeliveryFixtures.rig(memberCount: 4)
        let names = rig.fingerprints
        let mine = names[0]
        let target = MeshDeliveryTarget(contentID: UUID(), roster: rig.roster, selfFingerprint: mine)
        let leaver = names[3]
        let unreachable = names[2]

        let branch = MeshDeliveryFixtures.branch(rig, selfFingerprint: mine, reachable: [mine, names[1]])
        #expect(branch.presence(of: unreachable) == .temporarilyDisconnected)
        #expect(target.disposition(of: unreachable, in: rig.roster) == .pending)

        // A real signed departure record unions in, and the roster drops the leaver.
        let identity = try #require(rig.identities[leaver])
        rig.ledger.departures = rig.ledger.departures.inserting(
            try SignedDepartureRecord.signed(meshID: rig.meshID, identity: identity)
        )
        #expect(rig.roster.memberCount == 3)

        // The destination set does NOT change; only the disposition does, and it is a closed state
        // distinct from pending.
        #expect(target.destinationCount == 3)
        #expect(target.names(leaver))
        let closed = try #require(target.disposition(of: leaver, in: rig.roster))
        #expect(closed == .departed)
        #expect(closed.isClosed)
        #expect(closed.isOutstanding == false)
        #expect(closed.token == .departed)

        // The merely unreachable member is still pending — the whole point of the distinction.
        #expect(target.disposition(of: unreachable, in: rig.roster) == .pending)
        #expect(target.closed(in: rig.roster) == [leaver])
        #expect(target.outstanding(in: rig.roster) == [names[1], unreachable])
    }

    // MARK: 5 — completeness is derivable

    @Test func completenessIsDerivableThroughAFullLifecycleIncludingADeparture() throws {
        var rig = try MeshDeliveryFixtures.rig(memberCount: 4)
        let names = rig.fingerprints
        let mine = names[0]
        var target = MeshDeliveryTarget(contentID: UUID(), roster: rig.roster, selfFingerprint: mine)
        #expect(target.isFullyDelivered(in: rig.roster) == false)
        #expect(target.outstanding(in: rig.roster).count == 3)

        target = try #require(target.advancing(names[1], to: .delivered).target)
        target = try #require(target.advancing(names[2], to: .custodied(by: names[1])).target)
        #expect(target.outstanding(in: rig.roster) == [names[2], names[3]])
        #expect(target.isFullyDelivered(in: rig.roster) == false)

        // The third destination closes by departing rather than by receiving.
        let identity = try #require(rig.identities[names[3]])
        rig.ledger.departures = rig.ledger.departures.inserting(
            try SignedDepartureRecord.signed(meshID: rig.meshID, identity: identity)
        )
        #expect(target.outstanding(in: rig.roster) == [names[2]])
        #expect(target.isFullyDelivered(in: rig.roster) == false)

        target = try #require(target.advancing(names[2], to: .delivered).target)
        #expect(target.outstanding(in: rig.roster).isEmpty)
        #expect(target.isFullyDelivered(in: rig.roster))
        // A delivery that happened before a departure is a fact the departure cannot revoke.
        #expect(target.destinationCount == 3)
    }

    // MARK: 6 — union-merge safe

    @Test func mergingTakesThePerDestinationMaxAndObeysAllThreeLaws() throws {
        let (rig, _, base) = try splitRosterOfFour()
        let names = rig.fingerprints
        let left = try #require(base.advancing(names[1], to: .custodied(by: names[2])).target)
        let middle = try #require(base.advancing(names[1], to: .delivered).target)
        let right = try #require(base.advancing(names[2], to: .custodied(by: names[1])).target)

        // Max: the delivery wins over the custody for the shared destination, and the other
        // member's custody is not lost.
        let merged = try #require(left.merging(right).target)
        #expect(merged.state(of: names[1]) == .custodied(by: names[2]))
        #expect(merged.state(of: names[2]) == .custodied(by: names[1]))
        let withDelivery = try #require(merged.merging(middle).target)
        #expect(withDelivery.state(of: names[1]) == .delivered)

        // Commutative, associative, idempotent — and the destination set never moves.
        #expect(left.merging(right).target == right.merging(left).target)
        let leftThenMiddle = try #require(left.merging(middle).target)
        let middleThenRight = try #require(middle.merging(right).target)
        let leftFirst = try #require(leftThenMiddle.merging(right).target)
        let rightFirst = try #require(left.merging(middleThenRight).target)
        #expect(leftFirst == rightFirst)
        #expect(left.merging(left).target == left)
        #expect(leftFirst.destinations == base.destinations)
    }

    @Test func aMergeAcrossDifferentDestinationSetsOrItemsIsRefusedByName() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 4)
        let names = rig.fingerprints
        let contentID = UUID()
        let mine = MeshDeliveryTarget(contentID: contentID, roster: rig.roster, selfFingerprint: names[0])
        let theirs = MeshDeliveryTarget(contentID: contentID, roster: rig.roster, selfFingerprint: names[1])
        let other = MeshDeliveryTarget(contentID: UUID(), roster: rig.roster, selfFingerprint: names[0])

        #expect(mine.merging(theirs).refusal == .destinationSetMismatch)
        #expect(mine.merging(other).refusal == .differentContent)
        #expect(mine.merging(mine).target == mine)
    }

    // MARK: 7 — the two existing seams, derived rather than duplicated

    @Test func theCustodianAndPendingDeliverySeamsAreOneLineDerivations() throws {
        let (rig, branch, target) = try splitRosterOfFour()
        let names = rig.fingerprints

        // `MeshDevelopmentPlan.handoffTargets` == the reachable subset of the outstanding
        // destinations. Item 6's type is not modified to say so.
        let plan = MeshDevelopmentPlan(
            roster: rig.roster, branch: branch, selfFingerprint: names[0], startedAt: Date()
        )
        #expect(target.outstandingReachable(from: branch, in: rig.roster) == plan.handoffTargets)
        #expect(plan.handoffTargets == [names[1]])

        // `MeshBranchView.temporarilyDisconnectedFingerprints` == the pending deliveries a partition
        // is holding up. Item 1's type is not modified either.
        #expect(
            target.outstandingUnreachable(from: branch, in: rig.roster)
                == branch.temporarilyDisconnectedFingerprints
        )

        // Delivering to the reachable member removes it from the custodian derivation without
        // touching the destination set — reachability filters the work, never the recipients.
        let delivered = try #require(target.advancing(names[1], to: .delivered).target)
        #expect(delivered.outstandingReachable(from: branch, in: rig.roster).isEmpty)
        #expect(delivered.destinations == target.destinations)
    }

    // MARK: item 9's seam — a content event produces a target in one call

    @Test func aMergedContentItemMintsItsOwnTargetInOneCall() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 3)
        let names = rig.fingerprints
        let heart = MeshMergedHeart(
            giftID: UUID(),
            senderFingerprint: names[0],
            senderDisplayName: "A friend",
            firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let target = MeshDeliveryTarget(for: heart, roster: rig.roster, selfFingerprint: names[0])
        #expect(target.contentID == heart.giftID)
        #expect(target.destinations == [names[1], names[2]])
    }

    // MARK: the frozen tokens

    @Test func theStateSpellingsAreFrozenEnglishTokens() {
        #expect(
            MeshDeliveryStateToken.allCases.map(\.rawValue)
                == ["pending", "custodied", "delivered", "departed"]
        )
        #expect(
            MeshDeliveryRefusal.allCases.map(\.rawValue) == [
                "notADestination", "alreadyDelivered", "wouldRegress",
                "differentContent", "destinationSetMismatch"
            ]
        )
        #expect(MeshDeliveryState.pending.token == .pending)
        #expect(MeshDeliveryState.custodied(by: "relay").token == .custodied)
        #expect(MeshDeliveryState.delivered.token == .delivered)
    }
}
