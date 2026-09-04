// MeshTerminationPartitionTests.swift
// FernletTests
//
// P4 item 6 (plan §10.6): **termination and development under partition.**
//
// §10.6 is three sentences, and each is a claim here:
//
//   1. Development in a split with merged roster > 2 is a **departure** (§8.3), with the bounded
//      15 s handoff to the *reachable* members — custody transfers to them preserve delivery to the
//      other branch post-merge.
//   2. A "final pair" is judged on the **merged derived roster**, not the connected pair (a 2/2
//      split of a 4-roster is not two final pairs). A wrongly-issued termination downgrades to the
//      signer's departure at every receiver whose roster is larger — the failure mode costs one
//      member, never the mesh.
//   3. Genuine final pair, partner unreachable at development: the terminator ends locally; the
//      partner's idle-stop/ceiling closes their side; on foreground they are offered development of
//      what they hold.
//
// **The downgrade is a read-time derivation, never a merge-time mutation.** That is the wall this
// file guards hardest: `MeshMembershipLedger.merging(_:)` is commutative, associative and
// idempotent *including at the caps*, and a merge that rewrote a termination into a departure would
// break all three at once. So the record is asserted to survive the union **byte-identical**, and
// only ``MeshDerivedRoster`` is allowed to reach a different answer about what it means.
//
// **What item 6 added, and why.** Everything the downgrade needs already existed (P3's
// `applyTermination`, P4 item 1's `MeshBranchView.rosterIsFinalPair`). Two gaps did not:
//   * `leaveSessionAfterNotifyingPeers()` emitted a departure unconditionally, so a genuine final
//     pair could never issue the termination plan §8.2's `handingOff → terminated` edge is for;
//   * nothing stopped a device on a roster of four *issuing* a termination at all.
// ``MeshDevelopmentPlan`` is both answers in one pure value, and it never sees how many peers are
// connected — the mistake §10.6 forbids is not available to make.
//
// **Nothing sleeps.** The 15-second handoff bound is asserted on an injected clock through
// `leaveSessionAfterNotifyingPeers(clock:)`, which reads it twice: once when the window opens and
// once when the sends return. Rotation-queue state is sampled synchronously right after a pump, per
// the ledger's "(P4 i3)" lesson.
//
// The N-manager rig is `MeshDepartureRig` (item 4/5's, one `ProximityCoordinator` per link).

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshTerminationFixtures

/// The shapes item 6's scenarios need, built once.
@MainActor
enum MeshTerminationFixtures {

    /// The pinned instant every scenario measures from. Nothing here reads a wall clock.
    nonisolated static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Plan §8.2's idle window, in seconds — the value item 1 anchors and this file re-uses.
    nonisolated static let idleWindowSeconds: TimeInterval = 30 * 60

    /// A branch view over `roster` in which only `reachable` can be seen.
    static func branch(
        _ roster: MeshDerivedRoster, reachable: [String], selfFingerprint: String
    ) -> MeshBranchView {
        MeshBranchView(
            roster: roster, reachable: Set(reachable), selfFingerprint: selfFingerprint
        )
    }

    /// A real, honestly signed termination record from `signer`.
    static func termination(
        by signer: IdentityService, meshID: UUID, rosterAtSigning: [String]
    ) throws -> SignedTerminationRecord {
        try SignedTerminationRecord.signed(
            meshID: meshID, identity: signer, rosterAtSigning: rosterAtSigning, occurredAt: base
        )
    }

    /// A ledger carrying nothing but one termination record — what a peer offers at a merge.
    static func terminationOnly(_ record: SignedTerminationRecord) -> MeshMembershipLedger {
        var ledger = MeshMembershipLedger.empty
        ledger.terminations = ledger.terminations.inserting(record)
        return ledger
    }

    /// The four record-set sizes of a node's ledger, so "nothing was mutated" is one comparison.
    static func counts(_ node: MeshDepartureNode) -> [Int] {
        MeshPartitionFixtures.recordCounts(node.manager.membershipVerifier?.ledger)
    }

    /// A clock that answers `instants` in order and then repeats the last one, for the injected
    /// handoff window. A class so the manager's **three** reads — window open, custody transfer
    /// (P5 item 8), outcome — advance the same cursor, plus one more per custodian inside the
    /// departure push. Saturation is what keeps a two-instant list honest: a later read simply
    /// re-reads the last instant rather than running off the end.
    final class SteppedClock {

        private let instants: [Date]
        private var index = 0

        /// Builds a clock over a non-empty list of instants.
        init(_ instants: [Date]) {
            self.instants = instants.isEmpty ? [MeshTerminationFixtures.base] : instants
        }

        /// The next instant, saturating at the last.
        func next() -> Date {
            let instant = instants[min(index, instants.count - 1)]
            index += 1
            return instant
        }
    }
}

// MARK: - MeshDevelopmentPlanTests

/// The pure half of §10.6: the development decision, with no manager, no store and no transport.
@MainActor
@Suite(.serialized)
struct MeshDevelopmentPlanTests {

    /// **A 2/2 split of a four-roster is not two final pairs.**
    ///
    /// Both branches hold a *connected pair* of two and a *merged roster* of four. The roster's own
    /// answer, the branch view's copied answer and the development plan's ending must all read the
    /// merged roster; the connected count is asserted to be two precisely to show it is the number
    /// that must NOT be used.
    @Test func aFinalPairIsJudgedOnTheMergedRosterAndNeverOnTheConnectedPair() throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "t6-split-")
        let names = four.fingerprints
        #expect(four.roster.isFinalPair == false, "roster 4 is not a final pair")
        for pair in [[names[0], names[1]], [names[2], names[3]]] {
            let view = MeshTerminationFixtures.branch(
                four.roster, reachable: pair, selfFingerprint: pair[0]
            )
            #expect(view.branchMemberCount == 2, "the connected pair really is two…")
            #expect(view.rosterIsFinalPair == false, "…and it is not what 'final pair' reads")
            #expect(view.rosterMemberCount == 4, "a split never shrinks the merged roster")
            #expect(view.rosterQuorumThreshold == 3, "nor moves its quorum arithmetic")
            let plan = MeshDevelopmentPlan(
                roster: four.roster, branch: view, selfFingerprint: pair[0],
                startedAt: MeshTerminationFixtures.base
            )
            #expect(plan.ending == .departure, "development in a split of a 4-roster is a departure")
            #expect(plan.handoffTargets == view.externalPresentFingerprints,
                    "the handoff goes to the REACHABLE members, and to nobody else")
            #expect(plan.handoffTargets == [pair[1]])
        }
    }

    /// **A genuine final pair plans a termination — reachable partner or not.** The ending is a
    /// function of the merged roster alone, so unreachability changes only who custody is offered
    /// to, never what the ending is.
    @Test func aGenuineFinalPairPlansATerminationWhicheverWayReachabilityFalls() throws {
        let pair = try MeshQuorumFixtures.roster(size: 2, label: "t6-pair-")
        let names = pair.fingerprints
        let together = MeshTerminationFixtures.branch(
            pair.roster, reachable: names, selfFingerprint: names[0]
        )
        let alone = MeshTerminationFixtures.branch(
            pair.roster, reachable: [names[0]], selfFingerprint: names[0]
        )
        #expect(pair.roster.isFinalPair)
        for view in [together, alone] {
            let plan = MeshDevelopmentPlan(
                roster: pair.roster, branch: view, selfFingerprint: names[0],
                startedAt: MeshTerminationFixtures.base
            )
            #expect(plan.ending == .termination, "merged roster 2 ⇒ the mesh ends")
            #expect(plan.ending.membershipEvent == .meshTerminated)
            #expect(plan.ending.requestedEvent == .terminationRequested(.finalPairTermination))
            #expect(plan.ending.sentEvent == .terminationSent)
        }
        #expect(together.externalPresentFingerprints == [names[1]])
        #expect(alone.externalPresentFingerprints.isEmpty,
                "an unreachable partner is not a custodian, and nothing waits on them")
    }

    /// **The handoff window is fifteen seconds, and both ways out of it are named.** A pure
    /// comparison on an injected clock: no timer, no sleep, and "gave up" is a value rather than a
    /// silence.
    @Test func theHandoffWindowIsFifteenSecondsAndEveryOutcomeIsNamed() throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "t6-window-")
        let names = four.fingerprints
        let base = MeshTerminationFixtures.base
        let view = MeshTerminationFixtures.branch(
            four.roster, reachable: [names[0], names[1]], selfFingerprint: names[0]
        )
        let plan = MeshDevelopmentPlan(
            roster: four.roster, branch: view, selfFingerprint: names[0], startedAt: base
        )
        #expect(MeshDevelopmentPlan.handoffWindowSeconds == 15)
        #expect(plan.handoffDeadline == base.addingTimeInterval(15))
        #expect(plan.handoffHasExpired(at: base.addingTimeInterval(14.9)) == false)
        #expect(plan.handoffHasExpired(at: base.addingTimeInterval(15)))
        #expect(plan.handoffOutcome(finishedAt: base.addingTimeInterval(3)) == .completed)
        #expect(plan.handoffOutcome(finishedAt: base.addingTimeInterval(15)) == .windowExpired,
                "the bound is the bound: at 15 s the handoff gives up rather than waiting")
        let solo = MeshDevelopmentPlan(
            roster: four.roster,
            branch: MeshTerminationFixtures.branch(
                four.roster, reachable: [names[0]], selfFingerprint: names[0]
            ),
            selfFingerprint: names[0], startedAt: base
        )
        #expect(solo.handoffOutcome(finishedAt: base.addingTimeInterval(3)) == .noReachableCustodian)
        #expect(plan.handoffSummary.custodianFingerprints == [names[1]])
        #expect(plan.handoffSummary.handedOffItemCount == 0,
                "the zero-argument summary is the nothing-transferred answer")
    }

    /// **Issuance is gated on the merged derived roster.** Two or fewer members may sign a
    /// termination; three or more may not. A device with no ledger at all still may — the ceiling
    /// and the epoch-counter cap end sessions that never had one, and refusing there would silence
    /// an ending rather than prevent a wrong one.
    @Test func onlyARosterOfTwoOrFewerMayIssueATermination() throws {
        #expect(MeshDevelopmentPlan.permitsTermination(nil), "no ledger is not a larger roster")
        #expect(MeshDevelopmentPlan.permitsTermination(.empty))
        for size in 1...4 {
            let built = try MeshQuorumFixtures.roster(size: size, label: "t6-gate-\(size)-")
            #expect(MeshDevelopmentPlan.permitsTermination(built.roster) == (size <= 2),
                    "roster \(size) may issue a termination: \(size <= 2)")
        }
    }

    /// The plan degrades to a departure when there is no membership ledger at all (the legacy
    /// pairwise session), and assumes every roster member reachable when reachability has never
    /// been evaluated. A departure costs one member; a termination costs a mesh — so the fail-safe
    /// default is the cheaper mistake.
    @Test func noLedgerAndNoBranchViewFallBackToADepartureOverTheWholeRoster() throws {
        let empty = MeshDevelopmentPlan(
            roster: .empty, branch: nil, selfFingerprint: "self",
            startedAt: MeshTerminationFixtures.base
        )
        #expect(empty.ending == .departure)
        #expect(empty.handoffTargets.isEmpty)
        let three = try MeshQuorumFixtures.roster(size: 3, label: "t6-nobranch-")
        let names = three.fingerprints
        let plan = MeshDevelopmentPlan(
            roster: three.roster, branch: nil, selfFingerprint: names[0],
            startedAt: MeshTerminationFixtures.base
        )
        #expect(plan.ending == .departure)
        #expect(plan.handoffTargets == [names[1], names[2]],
                "no branch view means nothing is known to be unreachable")
    }
}

// MARK: - MeshTerminationDowngradeTests

/// §8.3's downgrade rule, at the layer that owns it: the ledger and the derived roster.
@MainActor
@Suite(.serialized)
struct MeshTerminationDowngradeTests {

    /// **A wrongly-issued termination costs one member, never the mesh — and the record is stored
    /// verbatim.**
    ///
    /// The union is unchanged: one termination record in, one termination record out, byte-equal,
    /// and no departure record invented anywhere. Only the *derivation* reaches a different answer.
    @Test func aTerminationFromALargerRostersMemberDowngradesAtReadAndTheRecordIsUntouched() throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "t6-downgrade-")
        guard let signer = four.identities.first else { throw MeshQuorumTestFailure.rosterTooSmall }
        let record = try MeshTerminationFixtures.termination(
            by: signer, meshID: four.meshID, rosterAtSigning: [signer.localFingerprint]
        )
        let merged = four.ledger.merging(MeshTerminationFixtures.terminationOnly(record))

        #expect(merged.terminations.count == 1)
        #expect(merged.terminations.earliest == record, "stored VERBATIM: the merge mutates nothing")
        #expect(merged.departures.isEmpty, "and invents no departure record to stand in for it")
        #expect(merged.admissions == four.ledger.admissions)
        let roster = merged.derivedRoster
        #expect(roster.status == .active, "the mesh survives a termination its roster contradicts")
        #expect(roster.memberFingerprints == four.fingerprints.filter { $0 != signer.localFingerprint },
                "read as the signer's departure: one member lost, three left")
        #expect(roster.quorumThreshold == 2, "roster 3 ⇒ quorum 2")
        #expect(roster.barred.map(\.fingerprint) == [signer.localFingerprint])
    }

    /// The three union laws still hold with a termination in the mix — the reason the downgrade had
    /// to be a derivation and not a mutation.
    @Test func theUnionLawsSurviveATerminationInTheLedger() throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "t6-laws-")
        guard let signer = four.identities.first, four.identities.count == 4 else {
            throw MeshQuorumTestFailure.rosterTooSmall
        }
        let record = try MeshTerminationFixtures.termination(
            by: signer, meshID: four.meshID, rosterAtSigning: []
        )
        let terminationOnly = MeshTerminationFixtures.terminationOnly(record)
        var departureOnly = MeshMembershipLedger.empty
        departureOnly.departures = departureOnly.departures.inserting(
            try SignedDepartureRecord.signed(
                meshID: four.meshID, identity: four.identities[1],
                occurredAt: MeshTerminationFixtures.base
            )
        )

        let left = four.ledger.merging(terminationOnly)
        let right = terminationOnly.merging(four.ledger)
        #expect(left == right, "commutative")
        #expect(left.merging(terminationOnly) == left, "idempotent")
        #expect(left.merging(departureOnly) == four.ledger.merging(terminationOnly.merging(departureOnly)),
                "associative")
        #expect(left.derivedRoster == right.derivedRoster)
    }

    /// **The asymmetry, stated rather than papered over.**
    ///
    /// Termination is derived at read, so the derivation is *stateless*: a receiver whose roster
    /// was genuinely two derives `terminated`, and if a later merge hands it admissions it had
    /// never seen, the very same records derive an ACTIVE roster of three with the signer downgraded
    /// to a departure. That is not a contradiction — it is the rule "at every receiver whose roster
    /// is larger" applied to a roster that grew.
    ///
    /// The one-way half is the **local session**, not the derivation: a device that ended is barred
    /// forever (asserted at the manager seam in ``MeshTerminationUnderPartitionTests``). Records
    /// converge; endings do not un-happen.
    @Test func aTwoRosterReceiverTerminatesAndTheDerivationFollowsTheRecordsWhenTheRosterGrows()
        throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "t6-asymmetry-")
        guard four.identities.count == 4 else { throw MeshQuorumTestFailure.rosterTooSmall }
        let signer = four.identities[0]
        let pairLedger = try MeshPartitionFixtures.ledger(
            founder: signer, others: [four.identities[1]], meshID: four.meshID
        )
        let record = try MeshTerminationFixtures.termination(
            by: signer, meshID: four.meshID, rosterAtSigning: pairLedger.derivedRoster.memberFingerprints
        )
        let terminated = pairLedger.merging(MeshTerminationFixtures.terminationOnly(record))
        #expect(terminated.derivedRoster.status == .terminated, "a genuine pair ends the mesh")
        #expect(terminated.derivedRoster.members.isEmpty)

        let grown = terminated.merging(four.ledger)
        #expect(grown.terminations.earliest == record, "the record itself never moved")
        #expect(grown.derivedRoster.status == .active,
                "the SAME record on a larger roster reads as the signer's departure")
        #expect(grown.derivedRoster.memberCount == 3)
        #expect(grown.derivedRoster.contains(fingerprint: signer.localFingerprint) == false)
    }

    /// **Item 5's deferred cell, closed.** A roster of two can never remove anybody — quorum 2 with
    /// the target abstaining leaves exactly one vote — so the only exit a pair has is development,
    /// and development on a merged roster of two is the termination that ends the mesh.
    @Test func aPairCannotModerateSoItsOnlyExitIsDevelopmentEndingTheMesh() throws {
        let pair = try MeshQuorumFixtures.roster(size: 2, label: "t6-exit-")
        let names = pair.fingerprints
        #expect(pair.roster.quorumThreshold == 2)
        #expect(MeshQuorumFixtures.verdict(
            voters: [names[0]], target: names[1], roster: pair.roster, meshID: pair.meshID
        ) == .pending(required: 2, counted: 1), "removal is structurally impossible for a pair")
        let plan = MeshDevelopmentPlan(
            roster: pair.roster,
            branch: MeshTerminationFixtures.branch(
                pair.roster, reachable: names, selfFingerprint: names[0]
            ),
            selfFingerprint: names[0], startedAt: MeshTerminationFixtures.base
        )
        #expect(plan.ending == .termination, "the exit that DOES exist ends the mesh")
        #expect(MeshDevelopmentPlan.permitsTermination(pair.roster))
    }
}

// MARK: - MeshTerminationSplitScenario

/// The four-member fabric §10.6's first two rules run on: {A, B} | {C, D}, A develops.
///
/// Phases are methods rather than one long test function — Power of 10 rule 4, and each phase
/// carries the claims it is *for*.
@MainActor
struct MeshTerminationSplitScenario {

    /// The fabric every frame crosses.
    let fabric: FakePeerNetwork

    /// The mesh all four belong to.
    let meshID: UUID

    /// The four members. A develops; B is the reachable custodian; C and D are the far branch.
    let nodeA: MeshDepartureNode
    let nodeB: MeshDepartureNode
    let nodeC: MeshDepartureNode
    let nodeD: MeshDepartureNode

    /// The three the mesh ends with.
    var survivors: [MeshDepartureNode] { [nodeB, nodeC, nodeD] }

    /// Builds the roster of four and asserts the preconditions that would otherwise make every
    /// later claim vacuous.
    static func build(label: String) throws -> MeshTerminationSplitScenario {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = (0..<4).map { "\(label)\($0)" }
        let ids = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(ids.map(\.localFingerprint)).count == 4,
                "four DISTINCT provisioned identities, or every roster claim is vacuous")
        let ledger = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: Array(ids.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (name, identity) in zip(labels, ids) {
            let node = MeshDepartureRig.node(name, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == 4,
                    "roster 4 is this scenario's hard precondition")
            nodes.append(node)
        }
        guard nodes.count == 4 else { throw MeshMergeTestFailure.rosterTooSmall }
        return MeshTerminationSplitScenario(
            fabric: fabric, meshID: meshID,
            nodeA: nodes[0], nodeB: nodes[1], nodeC: nodes[2], nodeD: nodes[3]
        )
    }

    /// Links each branch internally and raises §10.2's split at all four.
    func splitIntoBranches(at now: Date) {
        MeshDepartureRig.link(nodeA, nodeB, on: fabric)
        MeshDepartureRig.link(nodeC, nodeD, on: fabric)
        let one: Set<String> = [nodeA.fingerprint, nodeB.fingerprint]
        let two: Set<String> = [nodeC.fingerprint, nodeD.fingerprint]
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for node in [nodeA, nodeB] {
                #expect(node.manager.evaluatePartition(reachable: one, now: now) == .linksLost)
            }
            for node in [nodeC, nodeD] {
                #expect(node.manager.evaluatePartition(reachable: two, now: now) == .linksLost)
            }
        }
        for node in [nodeA, nodeB, nodeC, nodeD] {
            #expect(node.manager.branchView?.rosterIsFinalPair == false,
                    "a 2/2 split of a four-roster is not two final pairs")
            #expect(MeshDepartureRig.quorum(node) == 3)
        }
    }

    /// Ends every live session so nothing outlives the scenario.
    func teardown() {
        for node in [nodeA, nodeB, nodeC, nodeD] { node.manager.leaveMesh() }
    }
}

// MARK: - MeshTerminationUnderPartitionTests

/// §10.6 at the manager seam, on `MeshDepartureRig`'s N-manager fabric.
@MainActor
@Suite(.serialized)
struct MeshTerminationUnderPartitionTests {

    /// **Rule 1.** A develops inside a 2/2 split of a four-roster: it issues a signed **departure**,
    /// the 15-second handoff names exactly the reachable branch, nothing is sent towards or waited
    /// on for the far branch, and the record carries B as its custodian.
    @Test func developingInASplitAboveTwoIsADepartureHandedOnlyToTheReachableBranch() async throws {
        let scenario = try MeshTerminationSplitScenario.build(label: "t6-split-a")
        let base = MeshTerminationFixtures.base
        scenario.splitIntoBranches(at: base)
        let nodeA = scenario.nodeA
        var emitted: [PayloadType] = []
        nodeA.manager.onMembershipEventSentForTesting = { emitted.append($0) }
        let clock = MeshTerminationFixtures.SteppedClock(
            [base, base.addingTimeInterval(3)]
        )
        let reachable = nodeA.manager.branchView?.externalPresentFingerprints ?? []

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await nodeA.manager.leaveSessionAfterNotifyingPeers(clock: { clock.next() })
        }

        #expect(emitted == [.meshMemberDeparture], "merged roster 4 ⇒ a departure, not a termination")
        let plan = nodeA.manager.lastDevelopmentPlan
        #expect(plan?.ending == .departure)
        #expect(plan?.handoffTargets == reachable, "custody goes to presentFingerprints − self")
        #expect(plan?.handoffTargets == [scenario.nodeB.fingerprint])
        #expect(plan?.handoffDeadline == base.addingTimeInterval(15), "bounded at 15 s")
        #expect(nodeA.manager.lastDevelopmentHandoffOutcome == .completed,
                "it finished inside the window rather than waiting on the far branch")
        #expect(!nodeA.channel.sentFrames.isEmpty, "the departure really did reach the transport")
        #expect(nodeA.channel.sentFrames.allSatisfy { $0.peer.isSameEndpoint(as: scenario.nodeB.handle) },
                "nothing was sent towards the unreachable branch")
        try await scenario.assertTheFarBranchLearnsAtTheMerge()
        scenario.teardown()
    }

    /// **Rule 2, issuance half.** No branch whose merged roster is larger than two can even *issue*
    /// a termination: the signer's own roster refuses it, before any receiver has to downgrade it.
    @Test func aBranchOfAFourRosterCannotIssueATerminationAtAll() async throws {
        let scenario = try MeshTerminationSplitScenario.build(label: "t6-split-b")
        scenario.splitIntoBranches(at: MeshTerminationFixtures.base)
        let nodeA = scenario.nodeA
        var emitted: [PayloadType] = []
        nodeA.manager.onMembershipEventSentForTesting = { emitted.append($0) }

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await nodeA.manager.sendMembershipEvent(.meshTerminated)
        }

        #expect(emitted.isEmpty, "the roster it can prove refuses the record it was asked to sign")
        #expect(nodeA.channel.sentFrames.isEmpty)
        #expect(MeshDepartureRig.tokensReceived(by: scenario.nodeB, from: nodeA.handle).isEmpty)
        #expect(nodeA.manager.developmentPlan(startedAt: MeshTerminationFixtures.base).ending
                == .departure, "and the development path would not have asked for one")
        scenario.teardown()
    }

    /// **Rule 2, receiver half.** A termination that *was* wrongly issued — constructed directly,
    /// as a peer on an older build or a confused branch would — is stored verbatim at B, C and D
    /// and read as A's departure. The mesh does not end anywhere; one member is lost.
    @Test func aWronglyIssuedTerminationIsStoredVerbatimAndReadAsTheSignersDeparture() async throws {
        let scenario = try MeshTerminationSplitScenario.build(label: "t6-wrong-")
        scenario.splitIntoBranches(at: MeshTerminationFixtures.base)
        let record = try MeshTerminationFixtures.termination(
            by: scenario.nodeA.manager.identityForTesting, meshID: scenario.meshID,
            rosterAtSigning: [scenario.nodeA.fingerprint, scenario.nodeB.fingerprint]
        )
        let offered = MeshTerminationFixtures.terminationOnly(record)
        let expected = scenario.survivors.map(\.fingerprint).sorted()

        for node in scenario.survivors {
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                #expect(node.manager.mergeMembershipLedger(offered).isEmpty,
                        "a well-signed termination from a member is ACCEPTED, then downgraded at read")
            }
            #expect(MeshMergeFixtures.roster(node.manager) == expected, "{B, C, D} at every receiver")
            #expect(node.manager.sessionState != .terminated, "the mesh did not end anywhere")
            #expect(node.manager.rejoinRefusal(for: scenario.meshID) == nil)
            #expect(MeshTerminationFixtures.counts(node) == [4, 0, 0, 1],
                    "one termination record stored, and no departure invented to replace it")
            #expect(node.manager.membershipVerifier?.ledger.terminations.earliest == record,
                    "byte-identical: the merge mutated nothing")
            #expect(MeshDepartureRig.quorum(node) == 2)
        }
        scenario.assertReOfferingItIsRefusedAndChangesNothing(offered)
        scenario.teardown()
    }

    /// **Rule 3.** Roster two, partner unreachable. A ends locally with a genuine termination; B —
    /// alone — runs the thirty-minute window to `localIdleStop`, is offered a resume on foreground,
    /// and mints nothing. When B finally reads the termination it ends too, still without minting.
    @Test func aGenuineFinalPairEndsLocallyAndTheUnreachablePartnerIdlesOutThenReadsIt() async throws {
        let pair = try MeshTerminationPairScenario.build(label: "t6-final-")
        try await pair.developWhilePartnerIsUnreachable()
        try pair.assertThePartnerIdlesOutAndIsOfferedDevelopment()
        try pair.assertThePartnerReadsTheTerminationWithoutMintingAnything()
        pair.teardown()
    }
}

// MARK: - MeshTerminationSplitScenario phases

extension MeshTerminationSplitScenario {

    /// The far branch learns A's departure through the ordinary merge path (item 4's road), and all
    /// three converge on {B, C, D} at quorum 2.
    func assertTheFarBranchLearnsAtTheMerge() async throws {
        try await MeshDepartureRig.settle(
            [nodeB, nodeC, nodeD], on: fabric,
            until: { MeshMergeFixtures.roster(nodeB.manager).count == 3 }
        )
        #expect(MeshMergeFixtures.roster(nodeB.manager).count == 3, "the custodian filed it")
        let departure = nodeB.manager.membershipVerifier?.ledger.departures.earliest
        #expect(departure?.custodyHandoff.custodianFingerprints == [nodeB.fingerprint],
                "the record names the custodian the 15 s handoff went to")
        #expect(departure?.custodyHandoff.handedOffItemCount == 0,
                "an empty routed store hands over nothing, and says so")
        #expect(nodeA.manager.lastDevelopmentHandoff?.suppression == nil,
                "held nothing is not the same claim as could not read, and this is the former")

        // B meets C, and only then C gossips onward to D. The order is load-bearing:
        // `reGossipRecords(to:)` answers a differing digest ONCE per peer per session, so a D that
        // asked C before C had learned would be answered "we match" and never ask again.
        MeshDepartureRig.link(nodeB, nodeC, on: fabric)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodeB.manager.applySessionEvent(.peerCommitted, committedPeer: nodeC.fingerprint)
            nodeC.manager.applySessionEvent(.peerCommitted, committedPeer: nodeB.fingerprint)
        }
        try await MeshDepartureRig.settle(
            [nodeB, nodeC, nodeD], on: fabric,
            until: { MeshMergeFixtures.roster(nodeC.manager).count == 3 }
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodeD.manager.applySessionEvent(.peerCommitted, committedPeer: nodeC.fingerprint)
        }
        try await MeshDepartureRig.settle(
            [nodeB, nodeC, nodeD], on: fabric,
            until: { MeshMergeFixtures.roster(nodeD.manager).count == 3 }
        )
        let expected = survivors.map(\.fingerprint).sorted()
        for node in survivors {
            #expect(MeshMergeFixtures.roster(node.manager) == expected, "converged on {B, C, D}")
            #expect(MeshDepartureRig.quorum(node) == 2, "roster 3 ⇒ quorum 2")
            #expect(node.manager.sessionState != .terminated, "a departure never ends a mesh")
        }
    }

    /// Offering the same termination a second time changes nothing at every survivor.
    ///
    /// **The verifier now REFUSES it, and that is the fail-closed direction.** The downgrade has
    /// barred the signer, so `insert(_: SignedTerminationRecord)`'s "a stranger, a departed member
    /// or a removed member must not be able to end a mesh they are not in" rule answers
    /// ``MeshMembershipRecordRejection/signerNotAMember`` on the re-offer. The refusal is named
    /// rather than silent and costs nothing: the record is already in the ledger, so the *ledger's*
    /// idempotence (asserted directly in ``MeshTerminationDowngradeTests``) is untouched — no
    /// duplicate commit, no second rotation, no roster movement.
    func assertReOfferingItIsRefusedAndChangesNothing(_ offered: MeshMembershipLedger) {
        for node in survivors {
            let before = MeshMergeFixtures.roster(node.manager)
            let counts = MeshTerminationFixtures.counts(node)
            MeshDepartureRig.consumeRotations([node])
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                #expect(node.manager.mergeMembershipLedger(offered) == [.signerNotAMember],
                        "the barred signer cannot end the mesh on a second try either")
            }
            #expect(MeshMergeFixtures.roster(node.manager) == before)
            #expect(MeshTerminationFixtures.counts(node) == counts, "no duplicate commit")
            #expect(node.manager.rotationTriggers.pendingCause == nil,
                    "a merge that moved nothing spends no rotation")
        }
    }
}

// MARK: - MeshTerminationPairScenario

/// §10.6's third rule: a genuine final pair whose partner is unreachable at development.
///
/// A and B are a roster of two. They are linked so a frame *can* be written, then the fabric is cut
/// so it cannot arrive — which is exactly "partner unreachable" rather than "partner absent".
@MainActor
struct MeshTerminationPairScenario {

    /// The fabric.
    let fabric: FakePeerNetwork

    /// The mesh both belong to.
    let meshID: UUID

    /// The terminator, and the partner it cannot reach.
    let nodeA: MeshDepartureNode
    let nodeB: MeshDepartureNode

    /// The epoch B holds throughout: it must never move.
    let seededHead: MeshEpochRef

    /// Builds the pair, splits it, and asserts the roster-2 precondition.
    static func build(label: String) throws -> MeshTerminationPairScenario {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let ids = try (0..<2).map { try MeshPartitionFixtures.identity("\(label)\($0)") }
        #expect(Set(ids.map(\.localFingerprint)).count == 2, "two DISTINCT provisioned identities")
        let ledger = try MeshPartitionFixtures.ledger(
            founder: ids[0], others: [ids[1]], meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (offset, identity) in ids.enumerated() {
            let node = MeshDepartureRig.node("\(label)\(offset)", identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: ids[0].localSigningPublicKey, meshID: meshID
            )
            nodes.append(node)
        }
        guard nodes.count == 2, let head = MeshEpochRef.minted(
            counter: 5, coordinatorFingerprint: nodes[0].fingerprint, meshID: meshID
        ) else { throw MeshMergeTestFailure.couldNotMintEpoch }
        for node in nodes {
            #expect(MeshMergeFixtures.roster(node.manager).count == 2, "roster 2 is the premise")
            #expect(node.manager.membershipVerifier?.roster.isFinalPair == true)
            MeshDepartureRig.seedEpoch(node, head: head)
        }
        return MeshTerminationPairScenario(
            fabric: fabric, meshID: meshID, nodeA: nodes[0], nodeB: nodes[1], seededHead: head
        )
    }

    /// A develops while B is out of reach: a genuine termination, ending A locally, reaching nobody.
    func developWhilePartnerIsUnreachable() async throws {
        MeshDepartureRig.link(nodeA, nodeB, on: fabric)
        fabric.partition(nodeA.handle, from: nodeB.handle)
        let base = MeshTerminationFixtures.base
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(nodeA.manager.evaluatePartition(
                reachable: [nodeA.fingerprint], now: base) == .linksLost)
            #expect(nodeB.manager.evaluatePartition(
                reachable: [nodeB.fingerprint], now: base) == .linksLost)
        }
        #expect(nodeA.manager.presence(of: nodeB.fingerprint) == .temporarilyDisconnected)
        var emitted: [PayloadType] = []
        nodeA.manager.onMembershipEventSentForTesting = { emitted.append($0) }
        let clock = MeshTerminationFixtures.SteppedClock([base, base.addingTimeInterval(2)])

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await nodeA.manager.leaveSessionAfterNotifyingPeers(clock: { clock.next() })
        }

        #expect(emitted == [.meshTerminated], "merged roster 2 ⇒ a genuine termination")
        #expect(nodeA.manager.lastDevelopmentPlan?.ending == .termination)
        #expect(nodeA.manager.lastDevelopmentHandoffOutcome == .noReachableCustodian,
                "there was nobody to hand custody to, and that is a named answer")
        #expect(nodeA.manager.sessionState == .terminated, "the terminator ends locally")
        #expect(nodeA.manager.rejoinRefusal(for: meshID) == .finalPairTermination)
        #expect(MeshP3Acceptance.loadContext(from: nodeA.store)?.localTermination?.reason
                == .finalPairTermination, "durable before acknowledged")
        try await MeshDepartureRig.settle([nodeB], on: fabric)
        #expect(MeshMergeFixtures.roster(nodeB.manager).count == 2, "and B heard none of it")
    }

    /// B, alone, runs the thirty-minute window to `localIdleStop` and is offered a resume on
    /// foreground — plan §10.6's "on foreground they are offered development of what they hold".
    ///
    /// **`localIdleStop` ends participation, not membership** (§8.2): the mesh and the ledger are
    /// still there, while the group keyring — which is never persisted — is dropped with the
    /// radios. Nothing is minted, and no rotation is queued behind the stop.
    func assertThePartnerIdlesOutAndIsOfferedDevelopment() throws {
        let base = MeshTerminationFixtures.base
        let window = MeshTerminationFixtures.idleWindowSeconds
        #expect(nodeB.manager.branchView?.isAlone == true)
        #expect(nodeB.manager.epochKeyring?.head == seededHead, "the seed is where the branch left it")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(nodeB.manager.evaluateIdleLapse(now: base.addingTimeInterval(window - 1)) == false)
            #expect(nodeB.manager.evaluateIdleLapse(now: base.addingTimeInterval(window)))
            nodeB.manager.applySessionEvent(.foregrounded)
        }
        #expect(nodeB.manager.sessionState == .localIdleStop)
        #expect(nodeB.manager.currentMesh != nil, "participation stopped; membership did not")
        #expect(MeshMergeFixtures.roster(nodeB.manager).count == 2, "and the roster it holds is two")
        #expect(nodeB.manager.offersForegroundResume,
                "the foreground offer is the seam §18.2's copy will hang from")
        #expect(nodeB.manager.epochKeyring == nil,
                "the keyring never outlives participation, and is never persisted")
        #expect(nodeB.manager.consumePendingRotationForTesting() == nil, "nothing was minted alone")
    }

    /// B finally reads A's termination — the roster it can prove is two, so the mesh really did end.
    ///
    /// It ends without minting an epoch and without continuing anything: the verified termination
    /// tears the session down (`applyVerifiedTermination` → `leaveSession`), so the mesh, the ledger
    /// and the keyring are gone and only the **durable** ending mark and the permanent rejoin bar
    /// remain. That asymmetry is the point — records converge; endings do not un-happen.
    func assertThePartnerReadsTheTerminationWithoutMintingAnything() throws {
        let record = try MeshTerminationFixtures.termination(
            by: nodeA.manager.identityForTesting, meshID: meshID,
            rosterAtSigning: [nodeA.fingerprint, nodeB.fingerprint]
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(nodeB.manager.mergeMembershipLedger(
                MeshTerminationFixtures.terminationOnly(record)).isEmpty,
                    "a genuine final pair's termination verifies")
        }
        #expect(nodeB.manager.sessionState == .terminated, "the mesh is over for the partner too")
        #expect(nodeB.manager.rejoinRefusal(for: meshID) == .verifiedTerminationRecord,
                "and it can never be rejoined")
        #expect(MeshP3Acceptance.loadContext(from: nodeB.store)?.localTermination?.reason
                == .verifiedTerminationRecord, "the ending is durable, not just in memory")
        #expect(nodeB.manager.currentMesh == nil, "an ended mesh is not continued")
        #expect(nodeB.manager.consumePendingRotationForTesting() == nil,
                "an ended mesh asks for no new epoch")
        #expect(nodeB.manager.epochKeyring == nil, "and mints none")
    }

    /// Ends both sessions so nothing outlives the scenario.
    func teardown() {
        for node in [nodeA, nodeB] { node.manager.leaveMesh() }
    }
}
