// MeshP4AcceptanceTests.swift
// FernletTests
//
// P4 item 10: **the P4 acceptance battery** (plan §10's acceptance line, verbatim).
//
//     Acceptance (P4): deterministic fake-transport suites for §16.2's scenario matrix; the
//     convergence property test; quorum arithmetic table-driven tests (rosters 2–8 × partition
//     shapes); the two worked examples above encoded verbatim as tests.
//
// …and §16.2's own assertion list, which is what "the scenario matrix" has to end in:
//
//     merged state identical on every member (convergence property test over randomized bounded
//     schedules with a fixed seed), exactly one post-merge epoch at every member, quorum arithmetic
//     per §10.4, no content loss, no duplicate ledger commits.
//
// Items 1–9 each shipped their own exhaustive suites, and those remain the fine-grained evidence:
// the whole 80-cell matrix (`MeshConvergencePropertyTests`), the generator's own properties
// (`MeshConvergenceScheduleTests`), §10.4's 2–8 table (`MeshQuorumPartitionTests`), §10.5's worked
// example and its residual (`MeshDepartureRecoveryTests`), §10.6 (`MeshTerminationPartitionTests`),
// the merge path (`MeshMergePathTests`, `MeshMergeExchangeTests`), the epoch mint
// (`MeshEpochReconciliationTests`), the content unions (`MeshContentMergeTests`) and the delivery
// target (`MeshDeliveryTargetTests`).
//
// **This file is deliberately not those suites again, and it is deliberately not a list of their
// names either.** Each suite below is one acceptance clause, run end to end as its own compact
// scenario against the same shipping seams — so the battery fails on its own evidence rather than
// on somebody else's, and CI can gate on it by name. Where the exhaustive file is the full space,
// the suite's doc comment says so and this file runs the canonical corner of it.
//
// **The fixed seed is the battery's, not a run-time draw.** Every scenario that generates a
// schedule generates it from ``MeshConvergenceSeeds/root`` — `0x00F32B1C00090002` — and
// ``MeshP4DeterminismAcceptanceTests`` pins that constant, its eight-seed family, byte-identical
// replay, and a grep-wall proving the two convergence files consult no system RNG and no wall
// clock. A property test on a randomized seed is a flake generator; this is what stops one.
//
// Nothing here sleeps and nothing decides on a wall clock: instants are arguments, the fabric's
// clock is advanced by hand, and the only suite that reads the real clock is the quorum manager
// seam — where the window is five minutes wide against a test that takes milliseconds, and every
// clock claim it could have made is settled on an injected clock in `MeshQuorumPartitionTests`.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshP4AcceptanceFailure

/// A precondition a battery scenario could not meet.
///
/// Thrown rather than force-unwrapped so a broken fixture fails as a named error instead of
/// trapping (Power of 10 rule 5) — and so a scenario that could not be built cannot be mistaken for
/// one that ran and passed.
enum MeshP4AcceptanceFailure: Error {

    /// Fewer distinct provisioned members than the scenario needs.
    case rosterTooSmall

    /// A record the scenario had to sign could not be signed.
    case couldNotSign

    /// A link index named a node the fixture does not have.
    case linkOutOfRange

    /// The pinned cell could not be re-split, so the nested-cut clause would assert nothing.
    case scheduleHasNoResplit

    /// A manager that should hold an epoch head, roster or keyring did not.
    case missingDerivedState
}

// MARK: - MeshP4Branch

/// A roster of real, provisioned members on one fabric, with a chosen subset linked into a branch.
///
/// The unlinked members are the other side of the partition: they exist in every member's ledger
/// (so the *merged* roster — the only thing §10.4 judges on — is the full one) and are reachable by
/// nobody, which is precisely what makes a quorum question interesting.
@MainActor
struct MeshP4Branch {

    /// The medium every frame crosses.
    let fabric: FakePeerNetwork

    /// The mesh all members belong to.
    let meshID: UUID

    /// Every member, in the order they were admitted.
    let nodes: [MeshDepartureNode]

    /// The members at the given indices, skipping any the fixture does not have.
    func members(_ indices: [Int]) -> [MeshDepartureNode] {
        indices.compactMap { nodes.indices.contains($0) ? nodes[$0] : nil }
    }

    /// Ends every live session, so nothing outlives the scenario.
    func teardown() {
        for node in nodes { node.manager.leaveMesh() }
    }
}

// MARK: - MeshP4Acceptance

/// The rig the battery's scenarios share: build, run, read, tear down.
///
/// Thin on purpose. Everything expensive is item 1–9's (`MeshPartitionFixtures`,
/// `MeshDepartureRig`, `MeshConvergenceRun`, `MeshQuorumFixtures`, `MeshContentFixtures`), so a
/// change to any of them is felt in the battery rather than worked around by it.
@MainActor
enum MeshP4Acceptance {

    /// The one seed every scenario in this file replays. Pinned through
    /// ``MeshConvergenceSeeds/root`` rather than copied, so the battery and the matrix cannot drift.
    static var rootSeed: UInt64 { MeshConvergenceSeeds.root }

    /// Builds one schedule's mesh, runs the split's events and heals it — the runner §16.2's whole
    /// matrix uses, with no assertions of its own so each clause can state its own.
    ///
    /// - Parameters:
    ///   - schedule: The seeded, bounded schedule.
    ///   - label: A keychain-row and diagnostic prefix, unique per scenario.
    ///   - resplit: The nested cut to interrupt the heal with, when the clause is that one.
    /// - Returns: The live run, for the caller to assert on and tear down.
    static func converged(
        _ schedule: MeshConvergenceSchedule, label: String, resplit: MeshResplitPlan? = nil
    ) async throws -> MeshConvergenceRun {
        let run = try MeshConvergenceRun.build(schedule, label: label)
        try await run.runSplitEvents()
        try await run.runHeal(interruptedBy: resplit)
        return run
    }

    /// Ends every session a run left open.
    static func teardown(_ run: MeshConvergenceRun) {
        for node in run.livingNodes { node.manager.leaveMesh() }
    }

    /// A roster of `size` provisioned members on a fresh fabric, with `connecting` fully linked.
    ///
    /// The roster-size precondition is a hard assertion rather than a comment: an unprovisioned
    /// `IdentityService` reports a placeholder fingerprint, so a fixture that lost one would
    /// silently dedupe and every quorum claim below would be vacuous rather than wrong.
    static func branch(
        size: Int, connecting linked: [Int], label: String
    ) throws -> MeshP4Branch {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let labels = (0..<size).map { "\(label)\($0)" }
        let identities = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(identities.map(\.localFingerprint)).count == size,
                "\(size) DISTINCT provisioned identities, or every claim below is vacuous")
        guard let founder = identities.first, identities.count == size else {
            throw MeshP4AcceptanceFailure.rosterTooSmall
        }
        let ledger = try MeshPartitionFixtures.ledger(
            founder: founder, others: Array(identities.dropFirst()), meshID: meshID
        )
        var nodes: [MeshDepartureNode] = []
        for (name, identity) in zip(labels, identities) {
            let node = MeshDepartureRig.node(name, identity: identity, on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: founder.localSigningPublicKey, meshID: meshID
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == size,
                    "roster \(size) is this scenario's hard precondition")
            nodes.append(node)
        }
        guard linked.allSatisfy(nodes.indices.contains) else {
            throw MeshP4AcceptanceFailure.linkOutOfRange
        }
        for near in linked.indices {
            for far in linked.indices where far > near {
                MeshDepartureRig.link(nodes[linked[near]], nodes[linked[far]], on: fabric)
            }
        }
        return MeshP4Branch(fabric: fabric, meshID: meshID, nodes: nodes)
    }

    /// §10.4's verdict as `node` counts it, re-derived on that node's own merged roster.
    ///
    /// The clock is the real one, as in `MeshQuorumManagerSeamTests`: this reads who counted what,
    /// and the five-minute window is settled on an injected clock over there.
    static func verdict(_ node: MeshDepartureNode, _ proposalID: UUID) -> MeshRemovalQuorumVerdict {
        guard let roster = node.manager.membershipVerifier?.roster else { return .unknown }
        return node.manager.removalQuorum.verdict(for: proposalID, roster: roster, at: Date())
    }

    /// How many removal records `node` has filed.
    static func removalCount(_ node: MeshDepartureNode) -> Int {
        node.manager.membershipVerifier?.ledger.removals.count ?? -1
    }

    /// Opens a proposal at `proposer` and casts every other connected member's vote, settling
    /// between so each vote is cast on a proposal that member actually holds.
    ///
    /// - Returns: The proposal, so the caller can read the verdict it produced.
    static func vote(
        on target: String, proposer: MeshDepartureNode, with others: [MeshDepartureNode],
        on fabric: FakePeerNetwork
    ) async throws -> SignedRemovalProposal {
        guard let proposal = proposer.manager.proposeSignedRemoval(of: target) else {
            throw MeshP4AcceptanceFailure.couldNotSign
        }
        let connected = [proposer] + others
        try await MeshDepartureRig.settle(connected, on: fabric) {
            others.allSatisfy { $0.manager.removalQuorum.proposal(proposal.proposalID) != nil }
        }
        for node in others {
            #expect(node.manager.removalQuorum.proposal(proposal.proposalID) != nil,
                    "\(node.label) must hold the proposal before it can vote on it")
            _ = node.manager.voteOnSignedRemoval(proposal.proposalID)
        }
        try await MeshDepartureRig.settle(connected, on: fabric)
        return proposal
    }

    /// The non-comment lines of a repo-root-relative source file, for the grep-wall.
    ///
    /// Whole-line comments are dropped because the two convergence files *name* the things the wall
    /// forbids — a header that says "no `Date()` here" is the documentation of the rule, not a
    /// violation of it, and a wall that could not tell them apart would be unmaintainable.
    static func codeLines(of relativePath: String) throws -> [String] {
        try RepoRoot.source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}

// MARK: - (a) §16.2's scenario matrix

/// **Clause (a): §16.2's scenario matrix — rosters 3, 4, 6, 8 × the five partition shapes × the
/// event vocabulary, ending in §16.2's five assertions.**
///
/// The full space is `MeshConvergencePropertyTests` (76 cells + 8 nested re-splits + 4 deferred).
/// What runs here is its **canonical corner**: the fixed root seed on every shape §16.2 names, plus
/// one nested re-split mid-merge — five rosters, one seed, the same runner, the same
/// `MeshConvergenceInvariants.check`. A shape that stopped converging, or a matrix that stopped
/// containing one of §16.2's rosters, fails here without waiting for the 80-cell run.
@MainActor
@Suite(.serialized)
struct MeshP4ScenarioMatrixAcceptanceTests {

    /// **Every shape §16.2 names, at the fixed seed.** Split, events, ordered heal, bounded settle,
    /// then all five of §16.2's assertions — and the cell is asserted to be one the matrix runs, so
    /// the corner can never drift out of the space it is a corner of.
    @Test(arguments: MeshPartitionShape.matrix)
    func theFixedSeedConvergesOnEveryShapeOfTheScenarioMatrix(
        shape: MeshPartitionShape
    ) async throws {
        let cell = MeshConvergenceCell(
            shape: shape, preferQuorum: true, seed: MeshP4Acceptance.rootSeed
        )
        #expect(MeshConvergenceMatrix.all.contains(cell),
                "\(cell): the battery's corner must be a cell the matrix itself runs")
        let run = try await MeshP4Acceptance.converged(cell.schedule, label: "p4b-matrix")
        try MeshConvergenceInvariants.check(run)
        #expect(run.executedTokens.contains("timerRotation"), "\(cell): the rotation event ran")
        #expect(run.executedTokens.contains("finalPairAttempt"), "\(cell): the development ran")
        #expect(!run.createdContent.isEmpty, "\(cell): a cell with no content asserts nothing")
        MeshP4Acceptance.teardown(run)
    }

    /// **§16.2's fifth shape: the nested re-split mid-merge.** The heal is interrupted once every
    /// member is inside an open merge window, and the run still owes §16.2's five invariants plus
    /// the re-split's own three (the abandon, the re-plan, and the cap on epoch heads).
    @Test func theFixedSeedsNestedReSplitMidMergeStillConverges() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshP4Acceptance.rootSeed, shape: .threeThree, preferQuorum: false
        )
        guard let plan = MeshScheduleGenerator.resplit(for: schedule) else {
            throw MeshP4AcceptanceFailure.scheduleHasNoResplit
        }
        let run = try await MeshP4Acceptance.converged(
            schedule, label: "p4b-resplit", resplit: plan
        )
        try MeshConvergenceInvariants.check(run)
        MeshResplitInvariants.check(run)
        MeshP4Acceptance.teardown(run)
    }

    /// **The matrix's declared dimensions are §16.2's, not a subset that happens to be green.**
    /// Five shapes, four rosters, and the shape list is closed — a sixth shape would have to be
    /// added here as well as generated.
    @Test func theShapeListIsExactlyTheOneSection162Names() {
        #expect(MeshPartitionShape.matrix.count == 5, "2/1, 2/2, 3/1, 3/3, 4/2/2")
        #expect(Set(MeshPartitionShape.matrix.map(\.rosterSize)) == [3, 4, 6, 8],
                "§16.2's four rosters, and no fifth")
        #expect(MeshPartitionShape.allCases.count == MeshPartitionShape.matrix.count,
                "every shape the type can express is a shape the matrix runs")
        for shape in MeshPartitionShape.matrix {
            #expect(shape.branchSizes.reduce(0, +) == shape.rosterSize, "\(shape.rawValue) partitions")
            #expect(shape.quorumThreshold == shape.rosterSize / 2 + 1, "§10.4's threshold")
        }
    }
}

// MARK: - (b) The convergence property, and "N-way merges need no special case"

/// **Clause (b): the convergence property — one seeded schedule, two valid heal orders, identical
/// merged state.**
///
/// The full space is `MeshConvergencePropertyTests.pairwiseMergesCommuteAcrossThePartitionTree`
/// (every shape) and `theNestedResplitHealCommutes`. What runs here is one roster-6 schedule healed
/// forward and with its intra-branch half reversed: if pairwise merges did not commute across the
/// partition tree, the two digests would differ. The digest is projected onto member *indices*
/// precisely so two runs with different keys are comparable at all.
@MainActor
@Suite(.serialized)
struct MeshP4ConvergencePropertyAcceptanceTests {

    /// **§10.3's "N-way merges need no special case", at the fixed seed.**
    @Test func oneScheduleHealedTwoValidWaysConvergesOnIdenticalState() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshP4Acceptance.rootSeed, shape: .threeThree, preferQuorum: false
        )
        let reordered = schedule.withReversedIntraHeal()
        #expect(reordered.heal != schedule.heal,
                "this cell must actually reorder something, or the claim is vacuous")
        #expect(Set(reordered.heal.map(\.unordered)) == Set(schedule.heal.map(\.unordered)),
                "and it must reorder the SAME links: a different walk would prove nothing")

        let forward = try await MeshP4Acceptance.converged(schedule, label: "p4b-commute-f")
        try MeshConvergenceInvariants.check(forward)
        let forwardDigest = try forward.digest()
        MeshP4Acceptance.teardown(forward)

        let reversed = try await MeshP4Acceptance.converged(reordered, label: "p4b-commute-r")
        try MeshConvergenceInvariants.check(reversed)
        let reversedDigest = try reversed.digest()
        MeshP4Acceptance.teardown(reversed)

        #expect(forwardDigest == reversedDigest,
                "two valid heal orders must converge on identical state")
    }
}

// MARK: - (c) §10.4's quorum arithmetic, at the manager seam

/// **Clause (c): plan §10.4's four named consequences, each run at the manager seam.**
///
/// The table over rosters 2–8 × partition shapes is `MeshQuorumPartitionTests`, and it is judged on
/// a `MeshDerivedRoster` — the right place for arithmetic. What that table cannot show is that the
/// *managers* behave the way the arithmetic says: only the 3/1 consequence had a manager-seam test
/// before this battery. So each of §10.4's four sentences is run here on real managers, over a real
/// fabric, with real signed proposals and votes:
///
/// 1. a 2/2 split of a four-roster removes nobody — neither your partner nor anyone across the cut;
/// 2. a 3/1 split removes the isolated member (votes are valid for an absent target);
/// 3. a roster of two can never remove anybody — quorum 2 with the target abstaining;
/// 4. a departure that shrinks 4 → 3 drops quorum to 2 and gives a connected pair its power back.
@MainActor
@Suite(.serialized)
struct MeshP4QuorumAcceptanceTests {

    /// **(1) A 2/2 split of a four-roster moderates nobody.** Two live managers, both proposals
    /// honestly signed, and both stall one vote short — the partner beside you at one vote, the
    /// pair across the cut at two, against the merged roster's threshold of three. No record is
    /// filed anywhere and no roster moves.
    @Test func aTwoTwoSplitOfAFourRosterRemovesNobodyAtTheManagerSeam() async throws {
        let scenario = try MeshP4Acceptance.branch(size: 4, connecting: [0, 1], label: "p4b-q22-")
        let pair = scenario.members([0, 1])
        guard pair.count == 2 else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        for node in pair {
            #expect(MeshDepartureRig.quorum(node) == 3, "roster 4 ⇒ quorum 3, a split never moves it")
            #expect(node.manager.membershipVerifier?.roster.isFinalPair == false,
                    "a 2/2 split of a four-roster is not two final pairs")
        }
        let partner = try await MeshP4Acceptance.vote(
            on: pair[1].fingerprint, proposer: pair[0], with: [], on: scenario.fabric
        )
        #expect(MeshP4Acceptance.verdict(pair[0], partner.proposalID)
                == .pending(required: 3, counted: 1),
                "the target abstains, so a branch of two cannot remove its own partner")

        let across = try await MeshP4Acceptance.vote(
            on: scenario.nodes[2].fingerprint, proposer: pair[0], with: [pair[1]],
            on: scenario.fabric
        )
        #expect(MeshP4Acceptance.verdict(pair[0], across.proposalID)
                == .pending(required: 3, counted: 2),
                "…nor anyone on the other side of the cut")
        for node in scenario.nodes {
            #expect(MeshP4Acceptance.removalCount(node) == 0, "\(node.label): no record was filed")
            #expect(MeshMergeFixtures.roster(node.manager).count == 4, "\(node.label): no roster moved")
        }
        scenario.teardown()
    }

    /// **(2) A 3/1 split removes the isolated member, at every member of the branch.** The absent
    /// target is never told — §8.3 keeps the record from its subject, who learns of it as a key that
    /// no longer opens anything — and each member of the branch mints its own permanent record.
    @Test func aThreeOneSplitRemovesTheIsolatedMemberAtTheManagerSeam() async throws {
        let scenario = try MeshP4Acceptance.branch(
            size: 4, connecting: [0, 1, 2], label: "p4b-q31-"
        )
        let branch = scenario.members([0, 1, 2])
        guard branch.count == 3 else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        let target = scenario.nodes[3].fingerprint

        let proposal = try await MeshP4Acceptance.vote(
            on: target, proposer: branch[0], with: Array(branch.dropFirst()), on: scenario.fabric
        )
        try await MeshDepartureRig.settle(branch, on: scenario.fabric) {
            branch.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 3 }
        }
        for node in branch {
            #expect(MeshP4Acceptance.removalCount(node) == 1,
                    "\(node.label): exactly one removal record — quorum completed once")
            #expect(node.manager.membershipVerifier?.ledger.removals.all.first?.memberFingerprint
                    == target, "\(node.label): and it names the isolated member")
            #expect(MeshMergeFixtures.roster(node.manager).count == 3, "\(node.label): roster 4 → 3")
            #expect(MeshDepartureRig.quorum(node) == 2, "\(node.label): roster 3 ⇒ quorum 2")
            #expect(node.manager.removalQuorum.proposal(proposal.proposalID) == nil,
                    "\(node.label): a completed proposal is closed, so a late vote cannot re-run it")
        }
        #expect(MeshP4Acceptance.removalCount(scenario.nodes[3]) == 0,
                "the subject is never handed the record about itself")
        scenario.teardown()
    }

    /// **(3) A roster of two is structurally unmoderatable.** Quorum 2 with the target abstaining
    /// leaves exactly one vote, forever — not a special case anybody wrote, just the arithmetic
    /// reaching the manager. What a pair does *instead* is §10.6's business, asserted in clause (d).
    @Test func aRosterOfTwoCannotModerateAtTheManagerSeam() async throws {
        let scenario = try MeshP4Acceptance.branch(size: 2, connecting: [0, 1], label: "p4b-q2-")
        let pair = scenario.members([0, 1])
        guard pair.count == 2 else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        for node in pair {
            #expect(MeshDepartureRig.quorum(node) == 2, "roster 2 ⇒ quorum 2")
            #expect(node.manager.membershipVerifier?.roster.isFinalPair == true, "and it is the pair")
        }
        let proposal = try await MeshP4Acceptance.vote(
            on: pair[1].fingerprint, proposer: pair[0], with: [], on: scenario.fabric
        )
        #expect(MeshP4Acceptance.verdict(pair[0], proposal.proposalID)
                == .pending(required: 2, counted: 1),
                "one vote, and no second one can ever exist")
        for node in pair {
            #expect(MeshP4Acceptance.removalCount(node) == 0, "\(node.label): nothing was filed")
            #expect(MeshMergeFixtures.roster(node.manager).count == 2, "\(node.label): roster intact")
        }
        scenario.teardown()
    }

    /// **(4) A departure shrinks 4 → 3, and the connected pair gets its power back.** The same two
    /// managers that were one vote short before the departure are a quorum after it — because the
    /// threshold is re-derived on each receiver's own merged roster, not remembered from before.
    @Test func aDepartureThatShrinksFourToThreeRestoresTheConnectedPairsPower() async throws {
        let scenario = try MeshP4Acceptance.branch(
            size: 4, connecting: [0, 1, 3], label: "p4b-qshrink-"
        )
        let pair = scenario.members([0, 1])
        let leaver = scenario.nodes[3]
        guard pair.count == 2 else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        let target = scenario.nodes[2].fingerprint

        let short = try await MeshP4Acceptance.vote(
            on: target, proposer: pair[0], with: [pair[1]], on: scenario.fabric
        )
        #expect(MeshP4Acceptance.verdict(pair[0], short.proposalID)
                == .pending(required: 3, counted: 2), "before the departure, a pair is one short")

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await leaver.manager.leaveSessionAfterNotifyingPeers()
        }
        try await MeshDepartureRig.settle(pair, on: scenario.fabric) {
            pair.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 3 }
        }
        MeshDepartureRig.consumeRotations(pair)
        for node in pair { #expect(MeshDepartureRig.quorum(node) == 2, "roster 4 → 3 drops quorum") }

        let restored = try await MeshP4Acceptance.vote(
            on: target, proposer: pair[0], with: [pair[1]], on: scenario.fabric
        )
        try await MeshDepartureRig.settle(pair, on: scenario.fabric) {
            pair.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 2 }
        }
        #expect(MeshP4Acceptance.verdict(pair[0], restored.proposalID) == .unknown,
                "a completed proposal is closed, which is what 'it completed' looks like")
        for node in pair {
            #expect(MeshP4Acceptance.removalCount(node) == 1,
                    "\(node.label): the same two voters are now a quorum, and filed once")
            #expect(MeshMergeFixtures.roster(node.manager).count == 2, "\(node.label): roster 3 → 2")
        }
        scenario.teardown()
    }
}

// MARK: - (d) The two worked examples

/// **Clause (d): the plan's two worked examples, encoded verbatim.**
///
/// §10.5 is run end to end on four real managers and one fabric — `MeshDepartureWorkedExample` is
/// the wiring, and it is the same object `MeshDepartureRecoveryTests` drives, so the battery and
/// the exhaustive suite cannot disagree about what the example *is*. §10.6's two sentences are pure
/// derivations and are run as such: a final pair is judged on the merged roster, and a
/// wrongly-issued termination downgrades to its signer's departure at every receiver whose roster
/// is larger — costing one member, never the mesh.
@MainActor
@Suite(.serialized)
struct MeshP4WorkedExampleAcceptanceTests {

    /// **§10.5, verbatim.** {A, B} | {C, D}; B develops and leaves to A alone; A walks over and
    /// meets C; C gossips it to D. All three converge on {A, C, D} at quorum 2, with B never
    /// meeting C or D and no dead-drop side channel carrying mesh state.
    @Test func theDeparturePropagationWorkedExampleRunsVerbatim() async throws {
        let scenario = try MeshDepartureWorkedExample.build()
        let base = MeshP3Acceptance.base
        scenario.splitIntoBranches(at: base)
        try await scenario.departB(at: base.addingTimeInterval(60))
        try await scenario.healAToC(at: base.addingTimeInterval(120))
        try await scenario.gossipCToD()
        try scenario.assertConvergence()
        scenario.teardown()
    }

    /// **§10.6, verbatim.** A 2/2 split of a four-roster is not two final pairs, so development
    /// there is a departure handed to the reachable members; a genuine merged roster of two plans a
    /// termination whichever way reachability falls; and a roster above two may not even *issue*
    /// one.
    @Test func developmentIsJudgedOnTheMergedRosterAndNeverOnTheConnectedPair() throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "p4b-t6-split-")
        let names = four.fingerprints
        guard names.count == 4 else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        #expect(MeshDevelopmentPlan.permitsTermination(four.roster) == false,
                "a roster above two may not spend its membership on a termination")
        for pair in [[names[0], names[1]], [names[2], names[3]]] {
            let view = MeshTerminationFixtures.branch(
                four.roster, reachable: pair, selfFingerprint: pair[0]
            )
            #expect(view.branchMemberCount == 2, "the connected pair really is two…")
            #expect(view.rosterIsFinalPair == false, "…and it is not what 'final pair' reads")
            let plan = MeshDevelopmentPlan(
                roster: four.roster, branch: view, selfFingerprint: pair[0],
                startedAt: MeshTerminationFixtures.base
            )
            #expect(plan.ending == .departure, "development in a split of a 4-roster is a departure")
            #expect(plan.handoffTargets == [pair[1]], "custody goes to the REACHABLE members only")
        }

        let two = try MeshQuorumFixtures.roster(size: 2, label: "p4b-t6-pair-")
        let pairNames = two.fingerprints
        guard let first = pairNames.first else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        #expect(MeshDevelopmentPlan.permitsTermination(two.roster), "a genuine pair may end the mesh")
        for reachable in [pairNames, [first]] {
            let plan = MeshDevelopmentPlan(
                roster: two.roster,
                branch: MeshTerminationFixtures.branch(
                    two.roster, reachable: reachable, selfFingerprint: first
                ),
                selfFingerprint: first, startedAt: MeshTerminationFixtures.base
            )
            #expect(plan.ending == .termination, "merged roster 2 ⇒ the mesh ends, reachable or not")
            #expect(plan.ending.membershipEvent == .meshTerminated)
        }
    }

    /// **§10.6's failure mode costs one member, never the mesh.** A termination signed by a member
    /// of a larger roster is stored byte-for-byte and *read* as that signer's departure: the mesh
    /// stays active, three members remain, the signer is barred, and no departure record is
    /// invented to stand in for it.
    @Test func aWronglyIssuedTerminationDowngradesAtReadAndTheRecordIsUntouched() throws {
        let four = try MeshQuorumFixtures.roster(size: 4, label: "p4b-t6-downgrade-")
        guard let signer = four.identities.first else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        let record = try MeshTerminationFixtures.termination(
            by: signer, meshID: four.meshID, rosterAtSigning: [signer.localFingerprint]
        )
        let merged = four.ledger.merging(MeshTerminationFixtures.terminationOnly(record))
        #expect(merged.terminations.earliest == record, "stored VERBATIM: the merge mutates nothing")
        #expect(merged.departures.isEmpty, "and invents no departure record to stand in for it")

        let roster = merged.derivedRoster
        #expect(roster.status == .active, "the mesh survives a termination its roster contradicts")
        #expect(roster.memberCount == 3, "the cost is one member")
        #expect(roster.contains(fingerprint: signer.localFingerprint) == false)
        #expect(roster.quorumThreshold == 2, "roster 3 ⇒ quorum 2 — §10.4 follows the derivation")
    }
}

// MARK: - (e) Exactly one post-merge epoch

/// **Clause (e): exactly one post-merge epoch at every member.**
///
/// The exhaustive claims are `MeshEpochReconciliationTests` (the mint, its commutativity, the
/// absent coordinator, the forged stamp) and `MeshMergePathTests` (the overflow counted at the
/// writer against what sealed). What runs here is the shape §16.2 asks for: two branches that
/// rotated apart, coexisting, folded into **one** successor at `max + 1` minted by the merged
/// roster's own coordinator, with `cause = .merge` — and the head cap asserted as a cap rather than
/// exercised as a knob.
@MainActor
@Suite(.serialized)
struct MeshP4EpochAcceptanceTests {

    /// **Coexist → one head.** Both branches ask for the merge's rotation, the merged view's lowest
    /// fingerprint mints the successor at `max + 1`, the follower re-derives the identical ref
    /// through the shipping derivation, and the minter's superseded head is readable for its grace
    /// window and dead after it.
    @Test func twoCoexistingBranchHeadsBecomeExactlyOnePostMergeEpoch() async throws {
        let meshID = UUID()
        let alice = try MeshPartitionFixtures.identity("p4b-epoch-a")
        let bob = try MeshPartitionFixtures.identity("p4b-epoch-b")
        #expect(alice.localFingerprint != bob.localFingerprint, "two distinct devices, or vacuous")
        let ledger = try MeshPartitionFixtures.ledger(founder: alice, others: [bob], meshID: meshID)
        let headA = try MeshReconcileFixtures.head(2, alice, meshID)
        let headB = try MeshReconcileFixtures.head(2, bob, meshID)
        #expect(headA != headB, "two branch coordinators cannot mint the same ref")

        // The stores are held in named bindings, not built inline: `MeshNetworkManager` keeps its
        // host `unowned`, so a store that only lives as long as the expression that made it traps
        // the whole test process the moment the manager reads it back.
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
        #expect(MeshReconcileFixtures.merge(managerA, offering: [headB]) == .merge,
                "a divergence asks for the merge's rotation, not the membership's")
        #expect(MeshReconcileFixtures.merge(managerB, offering: [headA]) == .merge)
        guard let minter = managerA.epochCoordinatorFingerprintForTesting else {
            throw MeshP4AcceptanceFailure.missingDerivedState
        }
        #expect(minter == [alice.localFingerprint, bob.localFingerprint].min(),
                "the minter is a pure function of the merged roster")
        #expect(managerB.epochCoordinatorFingerprintForTesting == minter, "and both elect the same")

        let coordinator = minter == alice.localFingerprint ? managerA : managerB
        let follower = minter == alice.localFingerprint ? managerB : managerA
        let ownHead = minter == alice.localFingerprint ? headA : headB
        try Self.assertOneSuccessor(
            coordinator: coordinator, follower: follower, minter: minter,
            ownHead: ownHead, heads: [headA, headB],
            minted: await MeshReconcileFixtures.mint(coordinator)
        )
        managerA.leaveMesh()
        managerB.leaveMesh()
    }

    /// The successor's claims, split out so the scenario above stays inside Power of 10 rule 4.
    ///
    /// The grace window is measured from `Date()` because the supersession the rotation performed
    /// stamped itself on that clock — the *boundary* is a value this test states, not a duration it
    /// waits out, which is why nothing here sleeps.
    private static func assertOneSuccessor(
        coordinator: MeshNetworkManager,
        follower: MeshNetworkManager,
        minter: String,
        ownHead: MeshEpochRef,
        heads: [MeshEpochRef],
        minted: MeshEpochRef?
    ) throws {
        guard let minted, let keyring = coordinator.epochKeyring else {
            throw MeshP4AcceptanceFailure.missingDerivedState
        }
        #expect(minted.counter == 3, "counter = max + 1 over the folded heads")
        #expect(minted.coordinatorFingerprint == minter)
        #expect(!heads.contains(minted), "neither coexisting head wins — the successor is new")
        #expect(coordinator.lastRotationCause == .merge)
        #expect(follower.epochRefForTesting(
            counter: Int(minted.counter), coordinatorFingerprint: minter
        ) == minted, "both members land on EXACTLY ONE post-merge epoch")
        #expect(keyring.head == minted)
        let now = Date()
        #expect(keyring.canOpen(ownHead, at: now.addingTimeInterval(1)),
                "the superseded branch head is readable for its grace window")
        #expect(!keyring.canOpen(
            ownHead, at: now.addingTimeInterval(MeshEpochBounds.predecessorGraceSeconds + 1)
        ), "and dead after it — an old branch key opens nothing once grace expires")
        for foreign in heads where foreign != ownHead {
            #expect(!keyring.canOpen(foreign, at: now.addingTimeInterval(1)),
                    "the OTHER branch's key was never adopted, so it opens nothing either")
        }
    }

    /// **The eight-head cap is an assertion, not a knob** (plan §21.3). Everyone-alone fits exactly;
    /// a ninth is *named* rather than silently truncated; and a single branch's own rotation history
    /// is a lineage, not a divergence, so it mints no merge.
    @Test func theEpochHeadCapIsExactlyEveryoneAloneAndTheNinthIsNamed() throws {
        let meshID = UUID()
        let cap = MeshSessionContextSchema.maxEpochHeads
        #expect(cap == MeshMembershipBounds.maxRosterMembers,
                "the head cap IS the roster cap: a nested re-split cannot exceed everyone-alone")
        #expect(cap == 8, "and §9's roster cap is eight — pinned, so a widening is a decision")
        let everyoneAlone: [MeshEpochRef] = try (0..<cap).map { index in
            try #require(MeshEpochRef.minted(
                counter: 4, coordinatorFingerprint: String(format: "%016x", index + 1), meshID: meshID
            ))
        }
        let atCap = MeshMergeOffer.foldedHeads([], adding: everyoneAlone)
        #expect(atCap.heads.count == cap)
        #expect(atCap.droppedCount == 0, "exactly everyone-alone fits, with nothing lost")
        #expect(MeshEpochAcceptance.isDivergent(atCap.heads), "eight branches at one counter diverge")

        let ninth = try #require(MeshEpochRef.minted(
            counter: 4, coordinatorFingerprint: String(format: "%016x", cap + 1), meshID: meshID
        ))
        let overflow = MeshMergeOffer.foldedHeads(atCap.heads, adding: [ninth])
        #expect(overflow.heads.count == cap, "the cap is a hard bound")
        #expect(overflow.droppedCount == 1, "and the ninth is NAMED, never silently truncated")
    }
}

// MARK: - (f) No content loss

/// **Clause (f): no content loss — the three unions across a 4/2/2, and the gates as a view.**
///
/// The exhaustive space is `MeshContentMergeTests` (the union laws, the caps, the clamped stamps,
/// the arrival orders, the heart ledger's dedup) and the live invariant is
/// `MeshConvergenceInvariants.noContentLoss`, which asserts it at real managers over the whole
/// matrix. What runs here is the §16.2 shape: three branches, six valid link orders, one union —
/// and one member's gates filtering only that member's *view*, never what was stored, which is
/// §21.3's decision and the reason re-opening a gate needs no second merge.
@MainActor
@Suite(.serialized)
struct MeshP4ContentAcceptanceTests {

    /// Branch content: photos, messages and hearts under one tag, at deterministic instants.
    private func branch(_ tag: String, ids: [Int]) -> MeshContentLedger {
        MeshContentLedger(
            photos: MeshContentSet(ids.map {
                MeshContentFixtures.photo($0, sender: tag, addedAt: TimeInterval($0))
            }),
            messages: MeshContentSet(ids.map {
                MeshContentFixtures.message(
                    $0, sender: tag, claimed: TimeInterval($0), firstSeen: TimeInterval($0)
                )
            }),
            hearts: MeshContentSet(ids.map {
                MeshContentFixtures.heart($0, sender: tag, firstSeen: TimeInterval($0))
            })
        )
    }

    /// **A 4/2/2 loses nothing in any link order.** Six orders — pairwise merges only, no special
    /// case for N — and all six agree, on all three surfaces, with every id present exactly once.
    @Test func aFourTwoTwoContentMergeConvergesWithNothingLostAndNothingDoubled() {
        let big = branch("big", ids: [10, 11, 12, 13])
        let left = branch("left", ids: [20, 21])
        let right = branch("right", ids: [30, 31])
        let orders: [MeshContentLedger] = [
            big.merging(left).merging(right),
            big.merging(right).merging(left),
            left.merging(right).merging(big),
            right.merging(left).merging(big),
            big.merging(left.merging(right)),
            left.merging(big.merging(right))
        ]
        guard let converged = orders.first else { return }
        for ledger in orders { #expect(ledger == converged, "every valid order lands on one union") }
        #expect(converged.photos.count == 8, "four + two + two, none lost")
        #expect(converged.messages.count == 8)
        #expect(converged.hearts.count == 8)
        #expect(converged.photos.contentIDs.count == converged.photos.count, "and none doubled")
        #expect(converged.messages.contentIDs.count == converged.messages.count)
        #expect(converged.hearts.contentIDs.count == converged.hearts.count)
        #expect(converged.senders == ["big", "left", "right"], "three branches, three authors")
    }

    /// **The gates are a view over an unmutated union.** One member blocks one sender: the stored
    /// union is byte-identical at every member, all three of that member's *visible* surfaces drop
    /// the blocked sender, every other member still sees the whole union, and lifting the block
    /// reveals the records again without a second merge.
    @Test func aBlockedSenderChangesOnlyThatMembersViewAndNeverTheUnion() {
        let union = branch("big", ids: [10, 11])
            .merging(branch("left", ids: [20, 21]))
            .merging(branch("right", ids: [30]))
        let gates = MeshContentGates(chatAllowed: true, blockedFingerprints: ["left"])

        #expect(union.visibleTranscript(gates: gates).allSatisfy { $0.senderFingerprint != "left" },
                "the blocker sees none of that sender's messages")
        #expect(union.visiblePhotos(gates: gates).allSatisfy { $0.senderFingerprint != "left" },
                "nor photos")
        #expect(union.visibleHearts(gates: gates).allSatisfy { $0.senderFingerprint != "left" },
                "nor hearts")
        let hidden = union.messages.all.count - union.visibleTranscript(gates: gates).count
        #expect(hidden == 2, "a gate that hid nothing would make this clause vacuous")

        #expect(union.visibleTranscript(gates: .open) == union.messages.all,
                "every other member's view is the whole union — the record was never filtered")
        #expect(union.visiblePhotos(gates: .open) == union.photos.all)
        #expect(union.visibleHearts(gates: .open) == union.hearts.all)
        #expect(union.senders.contains("left"), "and the blocked sender is still IN the union")
    }
}

// MARK: - (g) No duplicate ledger commits

/// **Clause (g): no duplicate ledger commits.**
///
/// Three separate claims, run here rather than delegated: a heal asks for **one** kind of rotation
/// and it is the merge's, in **one** debounce window per member; the ledger holds **one** record
/// per event at every member; and two independent quorum completions on one target converge on
/// **one** removal record with nothing left to commit.
///
/// The third is also where P4's one scheduled gap is closed as far as it can honestly be closed —
/// see ``twoIndependentCompletionsOnOneTargetDedupToOneRemoval()`` and
/// ``noTwoBranchesOfOnePartitionCanBothReachQuorum()``.
@MainActor
@Suite(.serialized)
struct MeshP4LedgerCommitAcceptanceTests {

    /// **One merge, one rotation, one record per event.** Spelled out rather than delegated to
    /// `MeshConvergenceInvariants`, so this clause fails on its own assertions: every record a
    /// reconnect carried went down the merge path, no member opened a second debounce window, the
    /// admissions are the roster rather than a duplicate of it, and a converged mesh has nothing
    /// left queued.
    ///
    /// The cause set may legitimately be **empty** here: on this cell the branch of three removes
    /// the isolated member, so the survivors already agree and the heal has nothing to carry. What
    /// the clause forbids is a *second* kind — a reconnect-carried record that took the live path
    /// and asked for `.membership`. The positive case, a heal that really does rotate once as a
    /// merge, is `MeshP4DeferralAcceptanceTests.theCellThatFoundTheMergeWindowDeadlockRunsAtFullStrictness()`.
    @Test func aHealCommitsOneMergeRotationAndOneRecordPerEvent() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshP4Acceptance.rootSeed, shape: .threeOne, preferQuorum: true
        )
        let run = try await MeshP4Acceptance.converged(schedule, label: "p4b-commits")
        #expect(run.healCauses.isSubset(of: [.merge]),
                "a heal asks for ONE rotation kind: \(run.healCauses) at \(run.healMembershipAt)")
        #expect(run.healMembershipAt.isEmpty,
                "no member took the live record path during the heal: \(run.healMembershipAt)")
        #expect(!run.expectedRemovals.isEmpty,
                "this cell completes a quorum, or its removal-count claim below is vacuous")
        #expect(run.healWindowOverflow.isEmpty,
                "two debounce windows in one heal step is a second rotation: \(run.healWindowOverflow)")
        for member in run.livingMembers {
            let ledger = member.node.manager.membershipVerifier?.ledger
            #expect(ledger?.admissions.count == schedule.shape.rosterSize,
                    "\(member.node.label): the admissions ARE the roster, not a duplicate of it")
            #expect(ledger?.departures.count == run.expectedDepartures.count,
                    "\(member.node.label): one departure record per departure")
            #expect(ledger?.removals.count == run.expectedRemovals.count,
                    "\(member.node.label): one removal record per completed quorum")
            #expect(member.content.messages.contentIDs.count == member.content.messages.count,
                    "\(member.node.label): no content id committed twice")
            #expect(member.node.manager.consumePendingRotationForTesting() == nil,
                    "\(member.node.label): a converged mesh has nothing left to commit")
        }
        MeshP4Acceptance.teardown(run)
    }

    /// **Two independent completions on one target converge on one removal.**
    ///
    /// Nothing coordinates the talliers, so two proposals on the same member can both reach quorum
    /// — and each completing device mints its *own* signed record. Convergence therefore has to be
    /// a property of the record set (at most one record of a kind per member, earliest wins under
    /// the set's own total order) rather than of anybody's restraint. After both, every member
    /// holds exactly one removal, the union of two members' ledgers holds exactly one, and merging
    /// again queues no rotation — which is the countable form of "nothing committed a second time".
    @Test func twoIndependentCompletionsOnOneTargetDedupToOneRemoval() async throws {
        let scenario = try MeshP4Acceptance.branch(
            size: 4, connecting: [0, 1, 2], label: "p4b-double-"
        )
        let branch = scenario.members([0, 1, 2])
        guard branch.count == 3 else { throw MeshP4AcceptanceFailure.rosterTooSmall }
        let target = scenario.nodes[3].fingerprint

        let first = try await MeshP4Acceptance.vote(
            on: target, proposer: branch[0], with: Array(branch.dropFirst()), on: scenario.fabric
        )
        try await MeshDepartureRig.settle(branch, on: scenario.fabric) {
            branch.allSatisfy { MeshMergeFixtures.roster($0.manager).count == 3 }
        }
        let second = try await MeshP4Acceptance.vote(
            on: target, proposer: branch[2], with: [branch[0], branch[1]], on: scenario.fabric
        )
        #expect(first.proposalID != second.proposalID, "two genuinely independent proposals")
        MeshDepartureRig.consumeRotations(branch)

        for node in branch {
            #expect(MeshP4Acceptance.removalCount(node) == 1,
                    "\(node.label): two completions, ONE record — dedup is by member")
            #expect(MeshMergeFixtures.roster(node.manager).count == 3, "\(node.label): roster 4 → 3")
        }
        try Self.assertUnionKeepsOneRemoval(branch)
        scenario.teardown()
    }

    /// The union half of the claim: A ∪ C and C ∪ A agree, the removal count stays one, and a
    /// second merge queues nothing.
    private static func assertUnionKeepsOneRemoval(_ branch: [MeshDepartureNode]) throws {
        guard branch.count == 3,
              let ledgerA = branch[0].manager.membershipVerifier?.ledger,
              let ledgerC = branch[2].manager.membershipVerifier?.ledger else {
            throw MeshP4AcceptanceFailure.missingDerivedState
        }
        let before = MeshMergeFixtures.roster(branch[0].manager)
        branch[0].manager.mergeMembershipLedger(ledgerC)
        branch[2].manager.mergeMembershipLedger(ledgerA)
        #expect(MeshMergeFixtures.roster(branch[0].manager) == before, "commutative at the seam")
        #expect(MeshMergeFixtures.roster(branch[2].manager) == before)
        #expect(branch[0].manager.membershipVerifier?.ledger.removals.all
                == branch[2].manager.membershipVerifier?.ledger.removals.all,
                "one effective removal, byte-identical on both devices")
        #expect(MeshP4Acceptance.removalCount(branch[0]) == 1)
        #expect(branch[0].manager.consumePendingRotationForTesting() == nil,
                "a merge that moved no roster queues no rotation, so it committed nothing")
        branch[0].manager.mergeMembershipLedger(ledgerC)
        #expect(MeshP4Acceptance.removalCount(branch[0]) == 1, "twice is a no-op")
        #expect(branch[0].manager.consumePendingRotationForTesting() == nil)
    }

    /// **Why the concurrent-vote case is bounded rather than open** (P4 item 10's recorded gap).
    ///
    /// The generator plans one removal per cell, so the property test never *schedules* two
    /// branches voting on one target. This is the arithmetic that says how much that can hide: with
    /// quorum `⌊n/2⌋ + 1`, two **disjoint** branches of one partition can never both reach it —
    /// `2q > n` for every roster 2–8 — so the unscheduled case is not "two branches remove the same
    /// member twice" but "one branch completes, and a second completion can only be a *second
    /// proposal among members that can already see each other*", which
    /// ``twoIndependentCompletionsOnOneTargetDedupToOneRemoval()`` runs at the manager seam.
    ///
    /// Anchored on two real derived rosters so the formula is checked against the shipping
    /// derivation, not only against itself.
    @Test func noTwoBranchesOfOnePartitionCanBothReachQuorum() throws {
        for size in 2...MeshPartitionFixtureBounds.maxMembers {
            let quorum = size / 2 + 1
            #expect(2 * quorum > size,
                    "roster \(size): two disjoint branches cannot both reach quorum \(quorum)")
            #expect(2 * quorum > size - 1,
                    "roster \(size): nor when the target itself is in neither branch")
        }
        for size in [4, 8] {
            let fixture = try MeshQuorumFixtures.roster(size: size, label: "p4b-bound\(size)-")
            #expect(fixture.roster.quorumThreshold == size / 2 + 1,
                    "roster \(size): the shipping derivation agrees with §10.4's formula")
        }
    }
}

// MARK: - (h) The deferrals are named and bounded

/// **Clause (h): the battery's honesty clause — every deferral is named, bounded, and still run.**
///
/// A battery that could quietly shrink its own matrix would prove nothing. So: the matrix is whole
/// at 76 of 80 declared cells; the four that are not are exactly the ones the defect note beside
/// `MeshConvergenceMatrix.deferred` describes; each of them still runs and still owes §16.2's other
/// four invariants in full, with the defect asserted to be *exactly* the named one at exactly one
/// member; and the cell that found P4 item 2c's merge-window deadlock runs here at full strictness,
/// so the fix cannot regress unnoticed.
@MainActor
@Suite(.serialized)
struct MeshP4DeferralAcceptanceTests {

    /// The two fixed seeds whose `4/2/2` schedules reach the window-closes-early defect (2d).
    private static let deferredSeeds: [UInt64] = [0x308d_0d41_4707_d80, 0xace0_7337_d1bd_4fcc]

    /// The seed whose `2/2` schedule found the merge-window deadlock item 2c fixed.
    private static let deadlockSeed: UInt64 = 0x308d_0d41_4707_d80

    /// **The matrix is whole and the deferrals are counted.** 5 shapes × 2 preferences × 8 seeds is
    /// 80; four are deferred, by name, to one written-down defect on one shape; 76 run at full
    /// strength. A fifth deferral fails here until its own note exists.
    @Test func theMatrixIsWholeAndTheFourDeferralsAreNamedAndBounded() {
        let declared = MeshPartitionShape.matrix.count * 2 * MeshConvergenceSeeds.derivedCount
        #expect(declared == 80, "5 shapes × 2 preferences × 8 seeds is the matrix §16.2 asks for")
        #expect(MeshConvergenceMatrix.deferred.count == 4,
                "exactly the four cells the defect note describes; a fifth needs its own note")
        #expect(MeshConvergenceMatrix.all.count == declared - 4)
        #expect(MeshConvergenceMatrix.all.count == 76, "and every other cell runs, at full strength")
        #expect(MeshConvergenceMatrix.deferred.allSatisfy { $0.shape == .fourTwoTwo },
                "the deferral is roster 8's, which is where an N-way window closes early")
        #expect(Set(MeshConvergenceMatrix.deferred.map(\.seed)) == Set(Self.deferredSeeds),
                "and it is these two fixed seeds, pinned here as well as beside the deferral")
        for seed in Self.deferredSeeds {
            #expect(MeshConvergenceSeeds.family.contains(seed),
                    "a deferred seed must be one the matrix would otherwise run")
        }
        #expect(Set(MeshConvergenceMatrix.all.map(\.shape.rosterSize)) == [3, 4, 6, 8],
                "§16.2's four rosters all still run")
        #expect(!MeshConvergenceMatrix.resplit.isEmpty, "and §16.2's fifth shape runs too")
    }

    /// **Every deferred cell still runs.** Four of §16.2's five invariants in full, plus a positive
    /// assertion that the defect is the named one: one member takes the live path and labels one
    /// reconnect-carried record `.membership`, the state converges anyway, and nothing is committed
    /// twice. A cell that broke for another reason, a defect that spread to a second member, or a
    /// fix that landed and made the note stale all fail here rather than passing quietly.
    @Test(arguments: MeshConvergenceMatrix.deferred)
    func eachDeferredCellConvergesAndFailsOnlyOnTheNamedDefect(
        cell: MeshConvergenceCell
    ) async throws {
        let run = try await MeshP4Acceptance.converged(cell.schedule, label: "p4b-deferred")
        try MeshConvergenceInvariants.checkExceptTheHealsRotationCause(run)
        #expect(run.healCauses.contains(.membership),
                "\(cell): the named defect is gone — un-defer this cell and delete the note")
        #expect(run.healCauses.isSubset(of: [.merge, .membership]),
                "\(cell): a heal still asks for no OTHER kind of rotation")
        #expect(run.healMembershipAt.count == 1,
                "\(cell): exactly one member takes the live path: \(run.healMembershipAt)")
        #expect(run.healWindowOverflow.isEmpty,
                "\(cell): and it is still ONE commit, under the other name")
        MeshP4Acceptance.teardown(run)
    }

    /// **The cell that found the merge-window deadlock runs at full strictness.** P4 item 2c made
    /// the answer to a mismatched digest carry the epoch heads as well as the records; before that,
    /// this schedule stranded a member on its own older `rotationBasisHead` with nothing left in
    /// flight to correct it. It is a matrix cell again, on both quorum preferences, and one of them
    /// is run here with every §16.2 assertion.
    @Test func theCellThatFoundTheMergeWindowDeadlockRunsAtFullStrictness() async throws {
        for preferQuorum in [true, false] {
            #expect(MeshConvergenceMatrix.all.contains(MeshConvergenceCell(
                shape: .twoTwo, preferQuorum: preferQuorum, seed: Self.deadlockSeed
            )), "2c's cell must be IN the matrix, not beside it")
        }
        let cell = MeshConvergenceCell(
            shape: .twoTwo, preferQuorum: true, seed: Self.deadlockSeed
        )
        let run = try await MeshP4Acceptance.converged(cell.schedule, label: "p4b-2c")
        try MeshConvergenceInvariants.check(run)
        #expect(run.healCauses == [.merge], "the deadlock's shape now heals as one merge")
        MeshP4Acceptance.teardown(run)
    }
}

// MARK: - The fixed seed, and the wall that keeps it fixed

/// **The fixed seed is what CI runs.**
///
/// Launcher §6: *"the convergence property test must run its fixed seed in CI — a randomized seed
/// is a flake generator, not a property test."* Two halves make that true and keep it true: the
/// seed family is a compile-time constant derived from one root by the generator's own mix and
/// replays byte-identically, and neither convergence file may consult a system RNG or a wall clock
/// — checked by a grep-wall, because that is the failure mode with no compiler half. A `Date()` or
/// a `.randomElement()` slipped into the generator would keep every cell green and quietly make the
/// suite unreplayable.
@MainActor
@Suite(.serialized)
struct MeshP4DeterminismAcceptanceTests {

    /// The two files the property test's determinism lives in.
    private static let scannedFiles = [
        "Tests/FernletTests/MeshConvergenceSchedule.swift",
        "Tests/FernletTests/MeshConvergencePropertyTests.swift"
    ]

    /// Tokens that would make a cell irreproducible. Spelled as they appear in source.
    private static let bannedTokens = [
        "SystemRandomNumberGenerator", "arc4random", "Date()", "Date.now",
        ".randomElement", ".random(", ".shuffled()"
    ]

    /// **The root seed is a pinned constant and the family is derived from it, not drawn.**
    /// The literal is asserted by value — changing it changes every cell, and that has to be a
    /// decision somebody makes on purpose — and the family is re-derived here by the same three
    /// lines that build it, so the derivation rule is pinned as well as the result.
    @Test func theSeedFamilyIsTheFixedConstantFamily() {
        #expect(MeshConvergenceSeeds.root == 0x00F3_2B1C_0009_0002, "the pinned root seed")
        #expect(MeshConvergenceSeeds.derivedCount == 8, "eight seeds per cell")
        #expect(MeshConvergenceSeeds.family.count == 8)
        #expect(MeshConvergenceSeeds.family.first == MeshConvergenceSeeds.root, "root leads")
        #expect(Set(MeshConvergenceSeeds.family).count == 8, "and no seed repeats")

        var random = MeshScheduleRandom(seed: MeshConvergenceSeeds.root)
        var rederived: [UInt64] = [MeshConvergenceSeeds.root]
        for _ in 1..<MeshConvergenceSeeds.derivedCount { rederived.append(random.next()) }
        #expect(rederived == MeshConvergenceSeeds.family,
                "the family is SplitMix64 from the root — replayable from one constant")
    }

    /// **The whole matrix replays byte-identically.** Every cell generated twice yields an
    /// identical schedule, and the eight seeds do not collapse onto one — a generator that ignored
    /// its seed would pass the first claim and fail the second.
    @Test func everyCellOfTheMatrixReplaysIdentically() {
        var digests: Set<String> = []
        for shape in MeshPartitionShape.matrix {
            for preferQuorum in [true, false] {
                for seed in MeshConvergenceSeeds.family {
                    let first = MeshScheduleGenerator.schedule(
                        seed: seed, shape: shape, preferQuorum: preferQuorum
                    )
                    let second = MeshScheduleGenerator.schedule(
                        seed: seed, shape: shape, preferQuorum: preferQuorum
                    )
                    #expect(first == second,
                            "\(shape.rawValue)/\(preferQuorum)/\(String(seed, radix: 16)): one seed, one schedule")
                    digests.insert(first.steps.map(\.event.token).joined(separator: ","))
                }
            }
        }
        #expect(digests.count > 1, "eighty cells that produced one schedule would be no property test")
    }

    /// **The grep-wall: no system RNG and no wall clock in either convergence file.**
    ///
    /// Whole-line comments are skipped, because both files *document* the rule in prose — the
    /// header of `MeshConvergenceSchedule.swift` says "no `SystemRandomNumberGenerator`, no
    /// `Date()`" in as many words, and a wall that could not tell documentation from a violation
    /// would be deleted the first time it fired.
    @Test func neitherConvergenceFileConsultsASystemRNGOrAWallClock() throws {
        for path in Self.scannedFiles {
            let lines = try MeshP4Acceptance.codeLines(of: path)
            #expect(lines.count > 100, "\(path): an empty scan is a wall that stopped looking")
            for token in Self.bannedTokens {
                let offenders = lines.filter { $0.contains(token) }
                #expect(offenders.isEmpty,
                        "\(path) uses `\(token)`, which makes a seeded cell unreplayable: \(offenders)")
            }
        }
    }
}
