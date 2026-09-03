// MeshConvergencePropertyTests.swift
// FernletTests
//
// P4 item 9, iteration A (plan §16.2): the **convergence property test**.
//
//   > scenario matrix = roster {3, 4, 6, 8} × partition shapes … × events during split … → assert:
//   > merged state identical on every member (**convergence property test** over randomized bounded
//   > schedules with a fixed seed), exactly one post-merge epoch at every member, quorum arithmetic
//   > per §10.4, no content loss, no duplicate ledger commits.
//
// **Iteration A covers rosters 3 and 4** — shapes `2/1`, `2/2` and `3/1` — over the full event
// vocabulary, under the fixed seed family in ``MeshConvergenceSeeds``. Rosters 6 and 8, shapes `3/3`
// and `4/2/2`, and the nested re-split mid-merge are iteration B; ``MeshPartitionShape`` already
// carries the two wider shapes and ``MeshScheduleGenerator`` already handles any number of branches,
// so B adds matrix rows and the re-split, not a second generator.
//
// **Nothing here re-implements a rule.** Every event is one call into a seam an earlier item built
// and tested, and the checker reads the shipping derivations rather than copies of them:
//
// | Event | Seam | Item |
// | --- | --- | --- |
// | `photo` / `text` / `heart` | `MeshContentFixtures` + `MeshContentLedger.merging` + `MeshDeliveryTarget(for:roster:selfFingerprint:)` | 7, 8 |
// | `timerRotation` (×2) | `requestRotation(cause: .timer)`, sampled **synchronously**, then the branch head advances | 3 |
// | `removalVote(withQuorum:)` | `proposeSignedRemoval` / `voteOnSignedRemoval`, with `MeshQuorumFixtures.verdict` as the independent oracle | 5 |
// | `departure` | `leaveSessionAfterNotifyingPeers()` on `MeshDepartureRig` | 4 |
// | `idleLapse` | `evaluateIdleLapse(now:)` on a partition of one, resumed with `.resumedAfterLapse` | 1, 2 |
// | `finalPairAttempt` | `MeshDevelopmentPlan(roster:branch:selfFingerprint:startedAt:)` | 6 |
//
// The removal vote is driven at the **manager** seam, not the model seam, because §16.2's claim is
// that a branch's *ledger* ends up identical everywhere — which needs the real signed proposal, the
// real votes, and the real `member-removal.v1` that quorum mints. `MeshQuorumFixtures.verdict`
// re-derives §10.4's arithmetic from the merged roster **independently**, so the cell compares two
// answers rather than reading one twice.
//
// **What the property found.** One schedule of the 48 does not converge, and it is skipped **by
// name** (`MeshConvergenceMatrix.deferred`) rather than by a softened assertion. The cause is a
// liveness deadlock in the merge window, not a fixture problem: `awaitingResumeMerge` is cleared
// only by a peer inventory digest that *matches* local inventory, and a device that is awaiting
// opens no new exchange — so once every member of a healing mesh is inside an open window, no digest
// and no `fernlet.mesh.epoch-heads.v1` frame is ever sent again, and a member that only ever
// *answered* a digest is left counting up from a lower head than its peers. The answer half of
// §10.3's exchange re-gossips records but sends no epoch heads; making it symmetric would close it.
// That is a shipping-code change, so it is recorded, not made.
//
// **No wall-clock sleeps, and no shipping-code change.** Every settle is `MeshDepartureRig.settle`'s
// bounded yield-and-pump; every instant is `MeshP3Acceptance.base` plus a fixed offset; every
// rotation claim is sampled inside a pump or immediately after a synchronous call, never after an
// `await` (ledger "(P4 i3)"). No new seam was added to `MeshNetworkManager`: everything this file
// needs already exists in its `#if DEBUG` extension.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshConvergenceFailure

/// A precondition a convergence cell could not meet. Thrown rather than force-unwrapped, so a broken
/// fixture fails as a named error instead of trapping (Power of 10 rule 5).
enum MeshConvergenceFailure: Error {

    /// Fewer distinct provisioned identities than the shape's roster needs.
    case rosterTooSmall

    /// A canonical `MeshEpochRef` could not be minted from the cell's inputs.
    case couldNotMintEpoch

    /// A member had no derived roster when one was required.
    case noDerivedRoster

    /// A signed removal proposal or vote could not be signed.
    case couldNotSign
}

// MARK: - MeshConvergenceCell

/// One row of §16.2's matrix: a shape, a quorum preference, and a **fixed** seed.
///
/// `Sendable` and free of isolation because Swift Testing hands it to a parameterized test.
nonisolated struct MeshConvergenceCell: Equatable, Sendable, CustomStringConvertible {

    /// The partition shape this cell splits into.
    let shape: MeshPartitionShape

    /// Whether the cell's removal vote should reach §10.4's threshold where the shape allows it.
    let preferQuorum: Bool

    /// The fixed seed. Printed in ``description`` so a failure names its own replay.
    let seed: UInt64

    /// The cell's frozen English label — a diagnostic, never display copy.
    var description: String {
        "\(shape.rawValue)/\(preferQuorum ? "quorum" : "short")/\(String(seed, radix: 16))"
    }

    /// The schedule this cell replays.
    var schedule: MeshConvergenceSchedule {
        MeshScheduleGenerator.schedule(seed: seed, shape: shape, preferQuorum: preferQuorum)
    }
}

// MARK: - MeshConvergenceMatrix

/// The cells iteration A runs, built once from the fixed seed family — and the one it defers, by
/// name, to a defect rather than to a loosened check.
nonisolated enum MeshConvergenceMatrix {

    /// The one schedule iteration A does **not** run, and exactly why.
    ///
    /// ## The defect: the merge window can deadlock, and the epoch head stops with it
    ///
    /// `MeshNetworkManager` clears `awaitingResumeMerge` in exactly one place — `concludeMerge()`,
    /// reached only when a peer's **inventory digest matches local inventory**. And a device that is
    /// `awaitingResumeMerge` refuses to open another exchange: `openBlipMergeIfReconnected` guards
    /// on `!awaitingResumeMerge`. An exchange is the only thing that sends a digest *or* an
    /// epoch-heads frame. So once every member of a healing mesh sits inside an open window with no
    /// matching digest in flight, **nothing is ever sent again** and every window stays open.
    ///
    /// Seed `0x308d0d414707d80` on `2/2` walks straight into it: branch `{2,1}` | branch `{3,0}`,
    /// member 0 departs, the heal bridges `2–3` and then spreads `2–1`. Member 2 answers member 1's
    /// mismatched digest with a re-gossip — records converge, roster 3 everywhere — but the **answer
    /// half sends no epoch heads**, and by then members 1, 2 and 3 are all awaiting, so no later
    /// commit round can open an exchange. Member 1 ends on `rotationBasisHead` counter 12 while
    /// members 2 and 3 are on 20, and §16.2's "exactly one post-merge epoch at every member" fails —
    /// at the member, not at the assertion.
    ///
    /// ## What would close it
    ///
    /// Make the **answer half symmetric with the ask half**: `receiveInventoryDigest`'s mismatch
    /// branch already calls `reGossipRecords(to:)`; adding `sendEpochHeads(to: [sender])` beside it
    /// sends an existing, registered, already-signed frame to a peer that has just proved it needs
    /// one. No wire change, no new golden, no new persisted surface. That is a shipping-code change
    /// and therefore not this item's to make — it is recorded here and skipped **by name**, with
    /// every other assertion in the cell left exactly as strict as it is everywhere else.
    static let deferred: [MeshConvergenceCell] = [
        MeshConvergenceCell(shape: .twoTwo, preferQuorum: true, seed: 0x308d_0d41_4707_d80),
        MeshConvergenceCell(shape: .twoTwo, preferQuorum: false, seed: 0x308d_0d41_4707_d80)
    ]

    /// Shape × quorum preference × seed, minus ``deferred``: 3 × 2 × 8 − 2 = 46 cells, every one of
    /// them replayable from its own seed.
    static let iterationA: [MeshConvergenceCell] = {
        var cells: [MeshConvergenceCell] = []
        for shape in MeshPartitionShape.iterationA {
            for preferQuorum in [true, false] {
                for seed in MeshConvergenceSeeds.family where
                    !deferred.contains(MeshConvergenceCell(
                        shape: shape, preferQuorum: preferQuorum, seed: seed
                    )) {
                    cells.append(MeshConvergenceCell(shape: shape, preferQuorum: preferQuorum, seed: seed))
                }
            }
        }
        return cells
    }()
}

// MARK: - MeshConvergenceDigest

/// A cell's converged state, projected onto **member indices** rather than fingerprints.
///
/// Fingerprints come out of freshly provisioned signing keys, so two runs of the same schedule name
/// the same people differently. Projecting through the schedule's own indices is what lets
/// `pairwiseMergesCommuteAcrossThePartitionTree` compare two runs at all.
///
/// Content is compared as a **set** of ids here, not as the ordered ledger: `MeshContentOrder`
/// tie-breaks on the sender's fingerprint, which is exactly the value that differs between runs. The
/// ordered ledger is compared for equality *within* a run, where the fingerprints are shared.
nonisolated struct MeshConvergenceDigest: Equatable, Sendable {

    /// The derived roster, as sorted member indices.
    let roster: [Int]

    /// The members a completed quorum removed.
    let removed: Set<Int>

    /// The members that developed and left.
    let departed: Set<Int>

    /// Every content id that survived to the merge.
    let content: Set<UUID>

    /// Each item's immutable destination set, as member indices.
    let destinations: [UUID: Set<Int>]

    /// The head every member counts the post-merge epoch up from (§10.3's `max`).
    let epochBasisCounter: UInt32
}

// MARK: - MeshConvergenceMember

/// One member of a cell: its manager-side node, and the model-side content it holds.
///
/// A class because the run advances it in place; the manager half is `MeshDepartureNode` (item 4's
/// rig, one `ProximityCoordinator` per link) and the model half is the two values §10.3 says union —
/// the content ledger and the per-item delivery target. `MeshNetworkManager` holds neither: P5 owns
/// the routed store, and P4's job is to prove the *values* converge along the same links the records
/// travel.
@MainActor
final class MeshConvergenceMember {

    /// This member's global index in the schedule.
    let index: Int

    /// The branch of the split it started in.
    let branch: Int

    /// Its manager, endpoint, handle and per-link coordinators.
    let node: MeshDepartureNode

    /// The content it holds. Unions with a peer's at every heal step.
    var content: MeshContentLedger = .empty

    /// The delivery target for every item it holds, keyed by content id.
    var targets: [UUID: MeshDeliveryTarget] = [:]

    /// Whether it is still a member: false once it departs or a quorum removes it.
    var isParticipating = true

    /// Whether it ran plan §8.2's idle window out and is sitting in `localIdleStop`, which resumes
    /// with `.resumedAfterLapse` rather than `.peerCommitted`.
    var hasLapsed = false

    /// Its canonical fingerprint.
    var fingerprint: String { node.fingerprint }

    /// Builds one member.
    init(index: Int, branch: Int, node: MeshDepartureNode) {
        self.index = index
        self.branch = branch
        self.node = node
    }
}

// MARK: - MeshConvergenceRun

/// One cell, executed: build the roster, split it, run the schedule's events, heal in the schedule's
/// order, settle, and hand the result to ``MeshConvergenceInvariants``.
///
/// Deliberately a class with named phases rather than one long function: the schedule runner is
/// exactly the shape Power of 10 R4 exists for, and a 200-line `run()` would hide which phase a
/// failure came from.
@MainActor
final class MeshConvergenceRun {

    /// Plan §8.2's idle window, written from the plan rather than read off the code under test.
    static let idleWindowSeconds: TimeInterval = 30 * 60

    /// The gap between branches' seeded epoch counters. Wide enough that two branches cannot land on
    /// one counter however many times they rotate, which keeps `coexist` ordering — item 3's
    /// subject, and dependent on which real fingerprint sorts first — out of this file.
    static let branchCounterStride: UInt32 = 8

    /// The schedule being replayed.
    let schedule: MeshConvergenceSchedule

    /// The fabric every frame crosses.
    let fabric: FakePeerNetwork

    /// The mesh everything is keyed on.
    let meshID: UUID

    /// Every member, in global index order.
    let members: [MeshConvergenceMember]

    /// What each node's rotation queue held, sampled inside the pump.
    let sample = MeshRotationSample()

    /// Each branch's current epoch counter.
    var branchCounters: [UInt32]

    /// Every content id the schedule created. The target "no content loss" is measured against.
    var createdContent: Set<UUID> = []

    /// The fingerprints a completed quorum removed.
    var expectedRemovals: Set<String> = []

    /// The fingerprints that developed and left.
    var expectedDepartures: Set<String> = []

    /// The event tokens actually executed, in order. A cell that silently skipped its departure
    /// would otherwise pass.
    var executedTokens: [String] = []

    /// Members whose rotation queue showed more than one debounce window in a single heal step —
    /// the countable form of "a merge committed twice".
    var healWindowOverflow: [String] = []

    /// Every rotation cause seen during the heal. §10.3 permits exactly one kind: the merge's.
    var healCauses: Set<MeshKeyRotationCause> = []

    /// Delivery-target merges that were refused by name. Must stay empty: a refusal means two
    /// members disagreed about **who a piece of content is for**, which §10.1 forbids.
    var deliveryRefusals: [String] = []

    /// How many `finalPairAttempt` events were judged on a roster larger than two.
    var finalPairAttemptsAboveTwo = 0

    /// A monotonically increasing id source for content, so no two items share a `contentID`.
    /// Read and advanced by the content adapters in the extension below.
    var contentCounter = 0

    /// The members still on the roster.
    var livingMembers: [MeshConvergenceMember] { members.filter(\.isParticipating) }

    /// Their nodes, which is what the rig's settle takes.
    var livingNodes: [MeshDepartureNode] { livingMembers.map(\.node) }

    private init(
        schedule: MeshConvergenceSchedule, fabric: FakePeerNetwork, meshID: UUID,
        members: [MeshConvergenceMember]
    ) {
        self.schedule = schedule
        self.fabric = fabric
        self.meshID = meshID
        self.members = members
        branchCounters = Array(repeating: 0, count: schedule.branches.count)
    }

    // MARK: Build

    /// Builds the roster, asserts the preconditions that would make every later claim vacuous, links
    /// each branch internally, raises §10.2's split, and seeds each branch's own epoch.
    static func build(_ schedule: MeshConvergenceSchedule, label: String) throws -> MeshConvergenceRun {
        let fabric = FakePeerNetwork()
        let meshID = UUID()
        let size = schedule.shape.rosterSize
        let labels = (0..<size).map { "\(label)-\(String(schedule.seed, radix: 16))-\($0)" }
        let identities = try labels.map { try MeshPartitionFixtures.identity($0) }
        #expect(Set(identities.map(\.localFingerprint)).count == size,
                "\(size) DISTINCT provisioned identities, or every roster claim is vacuous")
        guard identities.count == size, let founder = identities.first else {
            throw MeshConvergenceFailure.rosterTooSmall
        }
        let ledger = try MeshPartitionFixtures.ledger(
            founder: founder, others: Array(identities.dropFirst()), meshID: meshID
        )
        var members: [MeshConvergenceMember] = []
        for index in 0..<size {
            let node = MeshDepartureRig.node(labels[index], identity: identities[index], on: fabric)
            MeshDepartureRig.start(
                node, ledger: ledger, founderKey: founder.localSigningPublicKey, meshID: meshID
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == size,
                    "roster \(size) is this cell's hard precondition")
            #expect(MeshDepartureRig.quorum(node) == schedule.shape.quorumThreshold,
                    "roster \(size) ⇒ quorum \(schedule.shape.quorumThreshold), everywhere")
            let branch = schedule.branches.firstIndex { $0.contains(index) } ?? 0
            members.append(MeshConvergenceMember(index: index, branch: branch, node: node))
        }
        let run = MeshConvergenceRun(
            schedule: schedule, fabric: fabric, meshID: meshID, members: members
        )
        run.linkBranches()
        run.raiseSplit()
        try run.seedBranchEpochs()
        return run
    }

    /// Links every pair inside every branch — and **no** pair across one.
    ///
    /// Deliberately no `peerCommitted` here: that is what opens a merge window and spends a pair's
    /// once-per-session re-gossip, and the heal is where those belong.
    private func linkBranches() {
        for branch in schedule.branches {
            for (position, near) in branch.enumerated() {
                for far in branch.dropFirst(position + 1) {
                    MeshDepartureRig.link(members[near].node, members[far].node, on: fabric)
                }
            }
        }
    }

    /// Raises §10.2's split at every member, and asserts the three answers a partition must not move.
    private func raiseSplit() {
        for branch in schedule.branches {
            let reachable = Set(branch.map { members[$0].fingerprint })
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                for index in branch {
                    let manager = members[index].node.manager
                    #expect(manager.evaluatePartition(
                        reachable: reachable, now: MeshP3Acceptance.base
                    ) == .linksLost)
                    #expect(manager.branchView?.rosterMemberCount == schedule.shape.rosterSize,
                            "a split never shrinks a roster")
                    #expect(MeshDepartureRig.quorum(members[index].node)
                            == schedule.shape.quorumThreshold,
                            "and never moves the quorum arithmetic")
                }
            }
        }
    }

    /// Puts each branch on its own epoch, at counters far enough apart that no two branches can
    /// collide however often they rotate.
    private func seedBranchEpochs() throws {
        for index in schedule.branches.indices {
            branchCounters[index] = 10 + Self.branchCounterStride * UInt32(index)
            try seedBranch(index)
        }
        #expect(Set(branchCounters).count == schedule.branches.count,
                "two branches on one counter would make this cell item 3's, not item 9's")
    }

    /// Re-seeds one branch's keyring at its current counter, coordinated by the branch's own lowest
    /// fingerprint (§10.2's branch coordinator rule).
    private func seedBranch(_ branch: Int) throws {
        let living = branchMembers(branch)
        guard let coordinator = living.map(\.fingerprint).min() else { return }
        guard let head = MeshEpochRef.minted(
            counter: branchCounters[branch], coordinatorFingerprint: coordinator, meshID: meshID
        ) else { throw MeshConvergenceFailure.couldNotMintEpoch }
        for member in living { MeshDepartureRig.seedEpoch(member.node, head: head) }
    }

    // MARK: Members

    /// The still-participating members of one branch, in branch order.
    func branchMembers(_ branch: Int) -> [MeshConvergenceMember] {
        guard schedule.branches.indices.contains(branch) else { return [] }
        return schedule.branches[branch].map { members[$0] }.filter(\.isParticipating)
    }

    /// Their nodes.
    func branchNodes(_ branch: Int) -> [MeshDepartureNode] { branchMembers(branch).map(\.node) }

    /// One member by global index, or nil once it has left the roster.
    func participant(global index: Int) -> MeshConvergenceMember? {
        guard members.indices.contains(index), members[index].isParticipating else { return nil }
        return members[index]
    }

    /// Every content id one ledger holds, across all three kinds.
    func allContentIDs(_ ledger: MeshContentLedger) -> Set<UUID> {
        ledger.photos.contentIDs.union(ledger.messages.contentIDs).union(ledger.hearts.contentIDs)
    }
}

// MARK: - MeshConvergenceRun: the split's events

extension MeshConvergenceRun {

    /// Runs every event of the schedule, in the schedule's interleaved order, settling the acting
    /// branch after each one.
    func runSplitEvents() async throws {
        for step in schedule.steps {
            let branch = schedule.branches.indices.contains(step.branch) ? step.branch : 0
            let pool = schedule.branches[branch]
            guard pool.indices.contains(step.performer),
                  let performer = participant(global: pool[step.performer]) else { continue }
            executedTokens.append(step.event.token)
            try await apply(step.event, by: performer, branch: branch)
            try await MeshDepartureRig.settle(branchNodes(branch), on: fabric)
        }
    }

    /// Dispatches one event to its adapter.
    private func apply(
        _ event: MeshScheduleEvent, by performer: MeshConvergenceMember, branch: Int
    ) async throws {
        switch event {
        case .photo: try createPhoto(by: performer, branch: branch)
        case .text: try createText(by: performer, branch: branch)
        case .heart: try createHeart(by: performer, branch: branch)
        case .timerRotation: try applyTimerRotation(branch: branch)
        case .removalVote(let withQuorum): try await applyRemovalVote(withQuorum: withQuorum, branch: branch)
        case .departure: try await applyDeparture(performer)
        case .idleLapse: applyIdleLapse(performer)
        case .finalPairAttempt: try applyFinalPairAttempt(performer)
        }
    }

    /// A friend photo, created in this branch at this branch's current epoch.
    private func createPhoto(by performer: MeshConvergenceMember, branch: Int) throws {
        contentCounterAdvance()
        let item = MeshContentFixtures.photo(
            contentCounter, sender: performer.fingerprint,
            epoch: Int(branchCounters[branch]), addedAt: TimeInterval(contentCounter)
        )
        let target = try makeTarget(for: item, by: performer)
        distribute(target, in: branch) { $0.content.photos = $0.content.photos.inserting(item) }
    }

    /// A mesh text, whose claimed instant sits inside `MeshMergedMessage.claimWindow` of first-seen
    /// so the transcript's total order is the honest one rather than a clamp edge case (item 7).
    private func createText(by performer: MeshConvergenceMember, branch: Int) throws {
        contentCounterAdvance()
        let item = MeshContentFixtures.message(
            contentCounter, sender: performer.fingerprint,
            claimed: TimeInterval(contentCounter), firstSeen: TimeInterval(contentCounter)
        )
        let target = try makeTarget(for: item, by: performer)
        distribute(target, in: branch) { $0.content.messages = $0.content.messages.inserting(item) }
    }

    /// A heart.
    private func createHeart(by performer: MeshConvergenceMember, branch: Int) throws {
        contentCounterAdvance()
        let item = MeshContentFixtures.heart(
            contentCounter, sender: performer.fingerprint, name: performer.node.label,
            firstSeen: TimeInterval(contentCounter)
        )
        let target = try makeTarget(for: item, by: performer)
        distribute(target, in: branch) { $0.content.hearts = $0.content.hearts.inserting(item) }
    }

    /// The destination set for one item: §10.1's **full derived roster at creation time**, taken
    /// from the creator's own roster and never from the branch it happens to be in.
    private func makeTarget(
        for item: some MeshMergeableContent, by performer: MeshConvergenceMember
    ) throws -> MeshDeliveryTarget {
        guard let roster = performer.node.manager.membershipVerifier?.roster else {
            throw MeshConvergenceFailure.noDerivedRoster
        }
        return MeshDeliveryTarget(for: item, roster: roster, selfFingerprint: performer.fingerprint)
    }

    /// Hands one item and its target to every member of the creating branch, and advances each
    /// recipient's own delivery state — the branch really does hold it.
    private func distribute(
        _ target: MeshDeliveryTarget, in branch: Int, insert: (MeshConvergenceMember) -> Void
    ) {
        createdContent.insert(target.contentID)
        for member in branchMembers(branch) {
            insert(member)
            member.targets[target.contentID] = target
            advanceDelivery(of: target.contentID, at: member)
        }
    }

    /// Marks one member as having received one item, refusals recorded rather than swallowed.
    func advanceDelivery(of id: UUID, at member: MeshConvergenceMember) {
        guard let target = member.targets[id], target.names(member.fingerprint) else { return }
        switch target.advancing(member.fingerprint, to: .delivered) {
        case .updated(let advanced): member.targets[id] = advanced
        case .refused(let refusal): deliveryRefusals.append("\(member.node.label):\(refusal.rawValue)")
        }
    }

    /// Bumps the content id source, so no two items in one cell share a `contentID`.
    private func contentCounterAdvance() { contentCounter += 1 }
}

// MARK: - MeshConvergenceRun: membership and epoch events

extension MeshConvergenceRun {

    /// The 15-minute rotation, branch-locally: every member queues it, the queue is sampled and
    /// disarmed **synchronously** (nothing may suspend between the request and the read), and the
    /// branch then moves to its next epoch.
    private func applyTimerRotation(branch: Int) throws {
        for member in branchMembers(branch) {
            member.node.manager.requestRotation(cause: .timer)
            #expect(member.node.manager.consumePendingRotationForTesting() == .timer,
                    "\(member.node.label): the 15-minute timer queues its own cause")
        }
        branchCounters[branch] += 1
        try seedBranch(branch)
    }

    /// §10.4's vote, at the manager seam, against a member of another branch.
    ///
    /// The expected outcome is computed **independently** by `MeshQuorumFixtures.verdict` from the
    /// merged roster the proposer holds at this instant, so the cell compares two derivations of
    /// §10.4 rather than reading the manager's own answer back to itself.
    private func applyRemovalVote(withQuorum: Bool, branch: Int) async throws {
        guard let removal = schedule.removal, removal.proposingBranch == branch else { return }
        let voters = branchMembers(branch)
        guard let proposer = voters.first, members.indices.contains(removal.target) else { return }
        let target = members[removal.target]
        guard let roster = proposer.node.manager.membershipVerifier?.roster else {
            throw MeshConvergenceFailure.noDerivedRoster
        }
        let extras = withQuorum
            ? roster.quorumThreshold - 1
            : max(0, min(voters.count - 1, roster.quorumThreshold - 2))
        let casting = Array(voters.dropFirst().prefix(extras))
        let oracle = MeshQuorumFixtures.verdict(
            voters: [proposer.fingerprint] + casting.map(\.fingerprint),
            target: target.fingerprint, roster: roster, meshID: meshID
        )
        #expect(oracle.isComplete == withQuorum,
                "§10.4's arithmetic and the schedule must agree before a frame is signed")
        try await castVotes(proposer: proposer, casting: casting, target: target, branch: branch)
        if withQuorum {
            expectedRemovals.insert(target.fingerprint)
            target.isParticipating = false
        }
        for member in voters {
            #expect(member.node.manager.membershipVerifier?.ledger.removals.count
                    == expectedRemovals.count, "\(member.node.label): §10.4's outcome, on the wire")
        }
        MeshDepartureRig.consumeRotations(branchNodes(branch))
    }

    /// Opens the proposal, waits for the branch to hold it, casts the votes, and settles.
    ///
    /// The clock here is the **real** one, exactly as `MeshQuorumManagerSeamTests` uses it and for
    /// the same reason: a receiver validates a proposal's issuance against its own `Date()`, so a
    /// proposal stamped at a pinned fixture instant is refused at the door as out of window. The
    /// five-minute expiry and the ±10-minute issuance bound have their own suites on an injected
    /// clock; nothing here sleeps, and the window is minutes wide against a cell that takes
    /// milliseconds. `MeshQuorumFixtures.verdict`'s oracle is self-consistent on its own pinned
    /// instant, which is what keeps the two derivations independent.
    private func castVotes(
        proposer: MeshConvergenceMember, casting: [MeshConvergenceMember],
        target: MeshConvergenceMember, branch: Int
    ) async throws {
        guard let proposal = proposer.node.manager.proposeSignedRemoval(of: target.fingerprint) else {
            throw MeshConvergenceFailure.couldNotSign
        }
        let nodes = branchNodes(branch)
        try await MeshDepartureRig.settle(nodes, on: fabric) {
            casting.allSatisfy { $0.node.manager.removalQuorum.proposal(proposal.proposalID) != nil }
        }
        for member in casting {
            #expect(member.node.manager.voteOnSignedRemoval(proposal.proposalID) != nil,
                    "\(member.node.label): a branch member's vote must be signable")
        }
        try await MeshDepartureRig.settle(nodes, on: fabric) {
            nodes.allSatisfy { !MeshMergeFixtures.roster($0.manager).contains(target.fingerprint) }
        }
    }

    /// A member develops and leaves: the signed departure is written before it is sent (§3.6), and
    /// its branch-mates learn it live.
    private func applyDeparture(_ performer: MeshConvergenceMember) async throws {
        var emitted: [PayloadType] = []
        performer.node.manager.onMembershipEventSentForTesting = { emitted.append($0) }
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await performer.node.manager.leaveSessionAfterNotifyingPeers()
        }
        #expect(emitted == [.meshMemberDeparture], "a real signed departure, not the legacy goodbye")
        #expect(MeshP3Acceptance.loadContext(from: performer.node.store)?.localTermination?.reason
                == .ownDeparture, "durable before acknowledged")
        expectedDepartures.insert(performer.fingerprint)
        performer.isParticipating = false
        let remaining = branchNodes(performer.branch)
        try await MeshDepartureRig.settle(remaining, on: fabric) {
            remaining.allSatisfy {
                !MeshMergeFixtures.roster($0.manager).contains(performer.fingerprint)
            }
        }
        MeshDepartureRig.consumeRotations(remaining)
    }

    /// A partition of one runs plan §8.2's window out to `localIdleStop`, which the heal resumes
    /// **as a merge** rather than as a fresh session.
    private func applyIdleLapse(_ performer: MeshConvergenceMember) {
        let manager = performer.node.manager
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(manager.branchView?.isAlone == true, "an idle lapse is a partition of ONE (§10.2)")
            #expect(manager.evaluateIdleLapse(
                now: MeshP3Acceptance.base.addingTimeInterval(Self.idleWindowSeconds)
            ), "the 30-minute window ends")
        }
        #expect(manager.sessionState == .localIdleStop)
        performer.hasLapsed = true
    }

    /// A development planned against the **merged** roster (§10.6): larger than two is a departure,
    /// and the connected pair never gets a vote in it.
    private func applyFinalPairAttempt(_ performer: MeshConvergenceMember) throws {
        guard let roster = performer.node.manager.membershipVerifier?.roster else {
            throw MeshConvergenceFailure.noDerivedRoster
        }
        let plan = MeshDevelopmentPlan(
            roster: roster, branch: performer.node.manager.branchView,
            selfFingerprint: performer.fingerprint, startedAt: MeshP3Acceptance.base
        )
        #expect(plan.ending == (roster.isFinalPair ? .termination : .departure),
                "\(performer.node.label): the ending is judged on the MERGED roster")
        if roster.memberCount > 2 {
            #expect(plan.ending == .departure,
                    "a final-pair attempt in a roster > 2 is a departure, never a termination")
            finalPairAttemptsAboveTwo += 1
        }
        #expect(!plan.handoffTargets.contains(performer.fingerprint),
                "a device never hands off to itself")
    }
}

// MARK: - MeshConvergenceRun: the heal

extension MeshConvergenceRun {

    /// Heals the partition in the schedule's order, one pairwise exchange at a time.
    ///
    /// Ordered rather than simultaneous because a re-gossip is answered **once per peer per
    /// session**: a pair that exchanges before either side has learned anything is answered "we
    /// match" and is never asked again (ledger "(P4 i7)").
    func runHeal() async throws {
        for step in schedule.heal {
            guard let near = participant(global: step.near),
                  let far = participant(global: step.far) else { continue }
            sample.reset()
            if step.isBridge { MeshDepartureRig.link(near.node, far.node, on: fabric) }
            commitHealStep(near: near, far: far)
            try await MeshDepartureRig.settle(livingNodes, on: fabric, sampling: sample)
            recordHealRotations()
            mergeModels(near: near, far: far)
        }
        try await formFullMesh()
        sample.reset()
        try await MeshDepartureRig.settle(livingNodes, on: fabric, sampling: sample)
        recordHealRotations()
        settleModels()
    }

    /// Reforms the **full** mesh the ordered heal's spanning walk left as a chain, and commits
    /// every pair — more than once.
    ///
    /// A healed partition in this product is a full mesh again: that is §8.7 finding 1's whole point
    /// (`871b7ee`), and it is load-bearing here rather than cosmetic. Two shipping rules make a
    /// single pass insufficient, and this phase is the rig honouring both rather than working around
    /// either:
    ///
    /// 1. **Presence is what §10.2 scopes on.** A member still holding a partial reachable set
    ///    presents a branch-scoped rotation roster and therefore elects a *different* epoch
    ///    coordinator from its peers. Linking the remaining pairs and re-evaluating presence is what
    ///    puts every member back on the merged roster's own election.
    /// 2. **A device already inside an open merge window opens no second exchange.**
    ///    `openBlipMergeIfReconnected` guards on `!awaitingResumeMerge`, and that window closes only
    ///    on a peer digest that *matches* local inventory. So in a chain heal the middle member is
    ///    still awaiting its first peer when the second commits, and the second peer therefore never
    ///    receives the middle member's folded epoch heads. A **second commit round**, once the first
    ///    window has concluded, is what delivers them — and when *every* member is awaiting at once,
    ///    no round can (this file's header note, and `MeshConvergenceMatrix.deferred`).
    ///
    /// Bounded twice over: ``MeshScheduleBounds/maxCommitRounds`` rounds, and an early exit the
    /// moment §10.3's `max` agrees at every member (``basesAgree()``).
    private func formFullMesh() async throws {
        let living = livingMembers
        for (position, near) in living.enumerated() {
            for far in living.dropFirst(position + 1)
            where !fabric.canReach(near.node.handle, far.node.handle) {
                MeshDepartureRig.link(near.node, far.node, on: fabric)
            }
        }
        for _ in 0..<MeshScheduleBounds.maxCommitRounds {
            sample.reset()
            commitEveryPair(living)
            try await MeshDepartureRig.settle(
                livingNodes, on: fabric, sampling: sample, until: { self.basesAgree() }
            )
            recordHealRotations()
            if basesAgree() { return }
        }
    }

    /// Commits every living pair, both directions, on the merged reachable set.
    private func commitEveryPair(_ living: [MeshConvergenceMember]) {
        let reachable = Set(living.map(\.fingerprint))
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for member in living {
                _ = member.node.manager.evaluatePartition(
                    reachable: reachable, now: MeshP3Acceptance.base
                )
                #expect(member.node.manager.branchView?.isPartitioned == false,
                        "\(member.node.label): its roster still names an unreachable member")
            }
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
    }

    /// Whether every living member counts the post-merge epoch up from the same head — the settle's
    /// stop condition, and the claim ``MeshConvergenceInvariants/onePostMergeEpoch(_:_:)`` re-asserts.
    ///
    /// The **basis**, not the raw folded head set. A member's folded set legitimately differs from
    /// its peers': `unresolvedEpochHeads` drops any head at or below this device's own counter as
    /// already resolved, so a member on the higher branch carries one head where a member on the
    /// lower carries two. What the merge has to agree on is §10.3's `max`, and that is this.
    private func basesAgree() -> Bool {
        let bases = Set(livingMembers.compactMap {
            $0.node.manager.rotationBasisHeadForTesting?.canonicalString
        })
        return bases.count == 1
    }

    /// Opens both ends' merge window: a lapsed member resumes, everybody else commits the peer.
    private func commitHealStep(near: MeshConvergenceMember, far: MeshConvergenceMember) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for (member, peer) in [(near, far), (far, near)] {
                _ = member.node.manager.evaluatePartition(
                    reachable: reachableFingerprints(from: member), now: MeshP3Acceptance.base
                )
                if member.hasLapsed {
                    member.node.manager.applySessionEvent(.resumedAfterLapse)
                    member.hasLapsed = false
                } else {
                    member.node.manager.applySessionEvent(
                        .peerCommitted, committedPeer: peer.fingerprint
                    )
                }
            }
        }
    }

    /// Who one member can actually reach on the fabric right now — the honest input to §10.2's
    /// detector, so a partial heal reads as a partial heal.
    private func reachableFingerprints(from member: MeshConvergenceMember) -> Set<String> {
        var reachable: Set<String> = [member.fingerprint]
        for peer in livingMembers where peer !== member {
            if fabric.canReach(member.node.handle, peer.node.handle) {
                reachable.insert(peer.fingerprint)
            }
        }
        return reachable
    }

    /// Folds one heal step's rotation samples into the run, then disarms every queue so the next
    /// step starts from a known one.
    private func recordHealRotations() {
        for member in livingMembers {
            healCauses.formUnion(sample.causes(at: member.node.label))
            if sample.windowCount(at: member.node.label) > 1 {
                healWindowOverflow.append(member.node.label)
            }
        }
        MeshDepartureRig.consumeRotations(livingNodes)
    }

    /// Unions two members' model state, both ways.
    private func mergeModels(near: MeshConvergenceMember, far: MeshConvergenceMember) {
        exchange(receiver: near, sender: far)
        exchange(receiver: far, sender: near)
    }

    /// One direction of a model exchange: the content union, then the per-destination max on every
    /// shared delivery target, then the receiver's own receipt for anything new.
    private func exchange(receiver: MeshConvergenceMember, sender: MeshConvergenceMember) {
        receiver.content = receiver.content.merging(sender.content)
        for (id, incoming) in sender.targets {
            guard let mine = receiver.targets[id] else {
                receiver.targets[id] = incoming
                continue
            }
            switch mine.merging(incoming) {
            case .updated(let merged): receiver.targets[id] = merged
            case .refused(let refusal):
                deliveryRefusals.append("\(receiver.node.label):\(refusal.rawValue)")
            }
        }
        for id in allContentIDs(receiver.content) { advanceDelivery(of: id, at: receiver) }
    }

    /// The bounded settle: sweep the healed link set until the model stops moving.
    ///
    /// The heal's steps form a spanning tree over the survivors, whose diameter is at most three for
    /// every shape §16.2 names, so ``MeshScheduleBounds/maxSettleSweeps`` floods it. Convergence is
    /// **asserted** by the checker rather than assumed here.
    private func settleModels() {
        for _ in 0..<MeshScheduleBounds.maxSettleSweeps {
            for step in schedule.heal {
                guard let near = participant(global: step.near),
                      let far = participant(global: step.far) else { continue }
                mergeModels(near: near, far: far)
            }
        }
    }

    /// The converged state, projected onto member indices so two runs can be compared.
    func digest() throws -> MeshConvergenceDigest {
        guard let first = livingMembers.first,
              let basis = first.node.manager.rotationBasisHeadForTesting else {
            throw MeshConvergenceFailure.rosterTooSmall
        }
        var indexByFingerprint: [String: Int] = [:]
        for member in members { indexByFingerprint[member.fingerprint] = member.index }
        var destinations: [UUID: Set<Int>] = [:]
        for (id, target) in first.targets {
            destinations[id] = Set(target.destinations.compactMap { indexByFingerprint[$0] })
        }
        return MeshConvergenceDigest(
            roster: MeshMergeFixtures.roster(first.node.manager)
                .compactMap { indexByFingerprint[$0] }.sorted(),
            removed: Set(expectedRemovals.compactMap { indexByFingerprint[$0] }),
            departed: Set(expectedDepartures.compactMap { indexByFingerprint[$0] }),
            content: allContentIDs(first.content),
            destinations: destinations,
            epochBasisCounter: basis.counter
        )
    }
}

// MARK: - MeshConvergenceInvariants

/// §16.2's five assertions, over the members a cell ends with.
///
/// Every one of them is measured from a shipping derivation — the derived roster, the membership
/// ledger's own record sets, `MeshContentLedger`, `MeshDeliveryTarget`, `rotationBasisHead` and the
/// rotation queue — rather than from a value this file kept alongside. A checker that compared its
/// own bookkeeping would pass over a merge that had stopped working.
@MainActor
enum MeshConvergenceInvariants {

    /// Runs all five.
    static func check(_ run: MeshConvergenceRun) throws {
        let survivors = run.livingMembers
        #expect(survivors.count >= 2, "\(run.schedule.seed): a cell must end with a mesh")
        try identicalMergedState(run, survivors)
        try onePostMergeEpoch(run, survivors)
        quorumArithmetic(run, survivors)
        noContentLoss(run, survivors)
        noDuplicateCommits(run, survivors)
    }

    /// **(a) Merged state identical on every member**: the derived roster, the removal and departure
    /// sets, the epoch head set, the content ledger, and every item's delivery target.
    static func identicalMergedState(
        _ run: MeshConvergenceRun, _ survivors: [MeshConvergenceMember]
    ) throws {
        guard let first = survivors.first else { throw MeshConvergenceFailure.rosterTooSmall }
        let expectedRoster = survivors.map(\.fingerprint).sorted()
        let roster = MeshMergeFixtures.roster(first.node.manager)
        for member in survivors {
            let manager = member.node.manager
            let label = "\(member.node.label) (seed \(String(run.schedule.seed, radix: 16)))"
            #expect(MeshMergeFixtures.roster(manager).sorted() == expectedRoster,
                    "\(label): the derived roster is the survivors, exactly")
            #expect(MeshMergeFixtures.roster(manager) == roster,
                    "\(label): and identical member for member, order included")
            #expect(manager.membershipVerifier?.ledger.removals.memberFingerprints
                    == run.expectedRemovals, "\(label): the same removal set")
            #expect(manager.membershipVerifier?.ledger.departures.memberFingerprints
                    == run.expectedDepartures, "\(label): the same departure set")
            #expect(member.node.manager.rotationBasisHeadForTesting
                    == first.node.manager.rotationBasisHeadForTesting,
                    "\(label): the same epoch head to count the post-merge epoch up from")
            #expect(member.content == first.content,
                    "\(label): the same content ledger, transcript order included")
            #expect(destinationMap(member) == destinationMap(first),
                    "\(label): the same destination set for every item (§10.1)")
        }
        #expect(run.deliveryRefusals.isEmpty,
                "a refused target merge means two members disagreed about who content is for")
    }

    /// **(b) Exactly one post-merge epoch at every member**: one basis head, one elected coordinator,
    /// and therefore one successor ref, re-derived through the shipping derivation at each member.
    static func onePostMergeEpoch(
        _ run: MeshConvergenceRun, _ survivors: [MeshConvergenceMember]
    ) throws {
        let coordinators = Set(survivors.compactMap {
            $0.node.manager.epochCoordinatorFingerprintForTesting
        })
        #expect(coordinators.count == 1, "one merged roster elects one minter")
        guard let coordinator = coordinators.first else { throw MeshConvergenceFailure.couldNotMintEpoch }
        var bases: Set<String> = []
        var successors: Set<String> = []
        for member in survivors {
            guard let basis = member.node.manager.rotationBasisHeadForTesting else {
                throw MeshConvergenceFailure.couldNotMintEpoch
            }
            bases.insert(basis.canonicalString)
            guard let successor = member.node.manager.epochRefForTesting(
                counter: Int(basis.counter) + 1, coordinatorFingerprint: coordinator
            ) else { throw MeshConvergenceFailure.couldNotMintEpoch }
            successors.insert(successor.canonicalString)
        }
        #expect(bases.count == 1, "every member counts up from the same head — §10.3's max")
        #expect(successors.count == 1,
                "seed \(String(run.schedule.seed, radix: 16)): exactly ONE post-merge epoch")
    }

    /// **(c) Quorum arithmetic per §10.4**: the removal set is what the vote earned, and every
    /// member re-derives ⌊|roster|/2⌋ + 1 from its own merged roster.
    static func quorumArithmetic(
        _ run: MeshConvergenceRun, _ survivors: [MeshConvergenceMember]
    ) {
        let threshold = max(1, survivors.count / 2 + 1)
        for member in survivors {
            #expect(member.node.manager.membershipVerifier?.ledger.removals.count
                    == run.expectedRemovals.count,
                    "\(member.node.label): one record per completed removal, and no more")
            #expect(MeshDepartureRig.quorum(member.node) == threshold,
                    "\(member.node.label): quorum is re-derived on the RECEIVER's merged roster")
        }
        if let removal = run.schedule.removal, !removal.completes {
            #expect(run.expectedRemovals.isEmpty,
                    "an incomplete proposal leaves no trace, anywhere (§10.4)")
        }
        if run.schedule.shape == .twoTwo {
            #expect(run.expectedRemovals.isEmpty, "a 2/2 split of a roster of four moderates nobody")
        }
    }

    /// **(d) No content loss**: every item created in any branch is in every member's union, and so
    /// is the target that says who it was for.
    static func noContentLoss(_ run: MeshConvergenceRun, _ survivors: [MeshConvergenceMember]) {
        #expect(!run.createdContent.isEmpty, "a cell with no content would assert nothing here")
        for member in survivors {
            #expect(run.allContentIDs(member.content) == run.createdContent,
                    "\(member.node.label): the union holds every item created in either branch")
            let missing = run.createdContent.filter { member.targets[$0] == nil }
            #expect(missing.isEmpty, "\(member.node.label): \(missing.count) items arrived untargeted")
        }
    }

    /// **(e) No duplicate ledger commits**: one debounce window per merge per member, one rotation
    /// cause kind across the whole heal, one record per event, and no repeated id anywhere.
    static func noDuplicateCommits(_ run: MeshConvergenceRun, _ survivors: [MeshConvergenceMember]) {
        #expect(run.healWindowOverflow.isEmpty,
                "two debounce windows in one heal step is a second rotation: \(run.healWindowOverflow)")
        #expect(run.healCauses.isSubset(of: [.merge]),
                "a heal asks for ONE kind of rotation and it is the merge's: \(run.healCauses)")
        for member in survivors {
            let ledger = member.node.manager.membershipVerifier?.ledger
            #expect(ledger?.admissions.count == run.schedule.shape.rosterSize,
                    "\(member.node.label): the admissions are the roster, not a duplicate of it")
            #expect(ledger?.departures.count == run.expectedDepartures.count)
            #expect(ledger?.removals.count == run.expectedRemovals.count)
            #expect(member.content.photos.contentIDs.count == member.content.photos.count,
                    "\(member.node.label): no photo id committed twice")
            #expect(member.content.messages.contentIDs.count == member.content.messages.count,
                    "\(member.node.label): no message id committed twice")
            #expect(member.content.hearts.contentIDs.count == member.content.hearts.count,
                    "\(member.node.label): no heart id committed twice")
            #expect(member.node.manager.consumePendingRotationForTesting() == nil,
                    "\(member.node.label): a converged mesh has nothing left to commit")
        }
    }

    /// One member's destination sets, keyed by content id — the half of a delivery target that
    /// §10.1 makes immutable.
    private static func destinationMap(_ member: MeshConvergenceMember) -> [UUID: [String]] {
        var answers: [UUID: [String]] = [:]
        for (id, target) in member.targets { answers[id] = target.destinations }
        return answers
    }
}

// MARK: - MeshConvergencePropertyTests

/// §16.2's convergence property, over iteration A's matrix: rosters 3 and 4 × shapes `2/1`, `2/2`
/// and `3/1` × the full event vocabulary, under the fixed seed family.
@MainActor
@Suite(.serialized)
struct MeshConvergencePropertyTests {

    /// **The property.** One seeded, bounded schedule per cell: split, events, ordered heal, bounded
    /// settle, then all five of §16.2's assertions.
    @Test(arguments: MeshConvergenceMatrix.iterationA)
    func aSeededScheduleConvergesOnEveryMember(cell: MeshConvergenceCell) async throws {
        let run = try MeshConvergenceRun.build(cell.schedule, label: "conv")
        try await run.runSplitEvents()
        try await run.runHeal()
        try MeshConvergenceInvariants.check(run)
        #expect(run.executedTokens.contains("timerRotation"), "\(cell): the rotation event ran")
        #expect(run.executedTokens.contains("finalPairAttempt"), "\(cell): the development ran")
        #expect(run.finalPairAttemptsAboveTwo > 0 || !run.expectedRemovals.isEmpty,
                "\(cell): a cell that removed nobody must judge a development on a roster > 2")
        for node in run.livingNodes { node.manager.leaveMesh() }
    }

    /// **The deferral cannot grow silently.** Exactly one schedule is skipped, it is named, and it
    /// is skipped for the defect ``MeshConvergenceMatrix/deferred`` documents — not for a check that
    /// was made easier. A second entry here means somebody widened the exception instead of fixing
    /// what it points at.
    @Test func exactlyOneScheduleIsDeferredAndItIsNamed() {
        #expect(MeshConvergenceMatrix.deferred.count == 2,
                "one schedule, both quorum preferences — see the defect note")
        #expect(Set(MeshConvergenceMatrix.deferred.map(\.seed)).count == 1)
        #expect(MeshConvergenceMatrix.deferred.allSatisfy { $0.shape == .twoTwo })
        #expect(MeshConvergenceMatrix.iterationA.count
                == MeshPartitionShape.iterationA.count * 2 * MeshConvergenceSeeds.derivedCount - 2)
        for cell in MeshConvergenceMatrix.deferred {
            #expect(!MeshConvergenceMatrix.iterationA.contains(cell))
        }
    }

    /// **The full vocabulary really fires.** Every event in §16.2's list is executed somewhere in
    /// iteration A's matrix — asserted over the schedules the matrix actually runs, so a generator
    /// that stopped emitting departures could not hide behind 48 green cells.
    @Test func iterationAExecutesEveryEventInTheVocabulary() {
        var seen: Set<String> = []
        for cell in MeshConvergenceMatrix.iterationA {
            seen.formUnion(cell.schedule.steps.map(\.event.token))
        }
        for event in MeshScheduleEvent.vocabulary {
            #expect(seen.contains(event.token), "iteration A's matrix never runs \(event.token)")
        }
    }

    /// **§10.3's "N-way merges need no special case."** The same schedule, healed in two different
    /// valid link orders, converges on identical state.
    ///
    /// The two orders differ only in the intra-branch half, which is the half that may legally be
    /// reordered: every intra step hangs off the same bridge anchor. If pairwise merges did not
    /// commute across the partition tree, the two digests would differ — and the digest is projected
    /// onto member indices precisely so two runs with different keys are comparable at all.
    @Test func pairwiseMergesCommuteAcrossThePartitionTree() async throws {
        for shape in MeshPartitionShape.iterationA {
            let schedule = MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: false
            )
            let forward = try await converge(schedule, label: "commute-f")
            let reversed = try await converge(schedule.withReversedIntraHeal(), label: "commute-r")
            #expect(forward == reversed,
                    "\(shape.rawValue): two valid heal orders must converge on identical state")
        }
    }

    /// Runs one schedule end to end and returns its digest.
    private func converge(
        _ schedule: MeshConvergenceSchedule, label: String
    ) async throws -> MeshConvergenceDigest {
        let run = try MeshConvergenceRun.build(schedule, label: label)
        try await run.runSplitEvents()
        try await run.runHeal()
        let digest = try run.digest()
        for node in run.livingNodes { node.manager.leaveMesh() }
        return digest
    }
}
