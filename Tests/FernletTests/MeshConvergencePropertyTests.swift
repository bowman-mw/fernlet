// MeshConvergencePropertyTests.swift
// FernletTests
//
// P4 item 9 (plan §16.2): the **convergence property test**.
//
//   > scenario matrix = roster {3, 4, 6, 8} × partition shapes … × events during split … → assert:
//   > merged state identical on every member (**convergence property test** over randomized bounded
//   > schedules with a fixed seed), exactly one post-merge epoch at every member, quorum arithmetic
//   > per §10.4, no content loss, no duplicate ledger commits.
//
// **The matrix is whole.** Iteration A covered rosters 3 and 4 — shapes `2/1`, `2/2` and `3/1`.
// Iteration B adds rosters 6 and 8 — `3/3` and `4/2/2` — and §16.2's fifth shape, the **nested
// re-split mid-merge**. The wider rosters cost no generator change (``MeshScheduleGenerator``
// already handled any number of branches) and one bound: ``MeshScheduleBounds/maxSettleSweeps``,
// because a `4/2/2` heal is a chain of three branch stars and therefore one hop wider than anything
// rosters 3 and 4 can produce.
//
// **What the nested re-split drives, and why it is not just another shape.** A partition shape cuts
// a mesh that has not merged yet. The re-split cuts one that is **mid-merge**: the survivors have
// re-formed the full mesh, every one of them is inside an open merge window, and then one healing
// branch is cut in two. `MeshNetworkManager.applySessionEvent` answers `next == .partitioned` with
// `abandonMergeExchange()`, and ``MeshResplitInvariants`` is what proves that call does what the
// ledger's "(P4 i11)" liveness residual needs it to: the window this device was holding is dropped,
// and the **next** heal opens a fresh one instead of leaving it silent for the session.
//
// The sub-branches deliberately run content and a branch-local rotation and **no membership
// record**. That is not squeamishness: `reGossipRecords(to:)` answers once per peer per *session*
// and `abandonMergeExchange()` does not reset the answered set, so a record minted after the
// abandon reaches a peer only when something re-opens an exchange with an unspent pair — which is
// the latency finding P4 already recorded ("a merged record is not pushed onward proactively"), not
// a new one. The epoch-heads half of §10.3's exchange carries no such gate, which is exactly why
// the heads still converge across the abandon and why the head cap is the claim worth making here.
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
// **What the property found, and what it cost the shipping code.** On its first run one schedule of
// the 48 did not converge — seed `0x308d0d414707d80` on `2/2` — and it was deferred **by name**
// rather than by a softened assertion. The cause was a liveness deadlock in the merge window, not a
// fixture problem: `awaitingResumeMerge` clears only on a peer inventory digest that *matches* local
// inventory, a device that is awaiting opens no new exchange, and the answer half of §10.3's
// exchange re-gossiped records while sending no epoch heads — so a member that only ever *answered*
// a digest was left counting up from a lower head than its peers, with nothing in flight to correct
// it. **P4 item 2c made the answer symmetric with the ask** (`receiveInventoryDigest`'s mismatch
// branch now sends `sendEpochHeads(to:)` beside `reGossipRecords(to:)` — an existing registered
// frame, no wire change), and all 48 cells run here with every assertion as strict as it ever was.
// `MeshMergeExchangeTests.theAnswerToAMismatchedDigestCarriesTheEpochHeads` is the targeted
// regression for it.
//
// **No wall-clock sleeps.** Every settle is `MeshDepartureRig.settle`'s
// bounded yield-and-pump; every instant is the run's own `anchor` plus a fixed offset (that anchor
// is `MeshP3Acceptance.base` for every membership cell here, and the rolling
// `MeshRoutedFixtureClock.createdAt` for a routed caller — item 6a); every
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

/// The cells the matrix runs, built once from the fixed seed family — and the one it defers, by
/// name, to a defect rather than to a loosened check.
nonisolated enum MeshConvergenceMatrix {

    /// The schedules iteration A does **not** run. **Empty, and it stays empty.**
    ///
    /// ## History: it held one seed, and the seed held a real defect (P4 items 9a → 2c)
    ///
    /// `MeshNetworkManager` cleared `awaitingResumeMerge` in exactly one place — `concludeMerge()`,
    /// reached only when a peer's **inventory digest matches local inventory**. And a device that is
    /// `awaitingResumeMerge` refuses to open another exchange: `openBlipMergeIfReconnected` guards
    /// on `!awaitingResumeMerge`. An exchange was the only thing that sent a digest *or* an
    /// epoch-heads frame. So once every member of a healing mesh sat inside an open window with no
    /// matching digest in flight, **nothing was ever sent again**.
    ///
    /// Seed `0x308d0d414707d80` on `2/2` walked straight into it: branch `{2,1}` | branch `{3,0}`,
    /// member 0 departs, the heal bridges `2–3` and then spreads `2–1`. Member 2 answered member 1's
    /// mismatched digest with a re-gossip — records converged, roster 3 everywhere — but the
    /// **answer half sent no epoch heads**, and by then members 1, 2 and 3 were all awaiting, so no
    /// later commit round could open an exchange. Member 1 ended on `rotationBasisHead` counter 12
    /// while members 2 and 3 were on 20, and §16.2's "exactly one post-merge epoch at every member"
    /// failed — at the member, not at the assertion.
    ///
    /// **P4 item 2c closed it** by making the answer half symmetric with the ask half:
    /// `receiveInventoryDigest`'s mismatch branch now sends `sendEpochHeads(to: [sender])` beside
    /// `reGossipRecords(to:)` — an existing, registered, already-signed frame to a peer that has
    /// just proved it needs one. No wire change, no new golden, no new persisted surface. Both cells
    /// run here now, with every assertion exactly as strict as it is everywhere else.
    ///
    /// ## History: it held four more, and P5 item 7 closed those too (P4 item 9b → 2d)
    ///
    /// §16.2's roster-8 row found the next one. P4's `concludeMerge()` closed the merge window on
    /// the **first** peer inventory digest that matched local inventory. Between two devices that is
    /// convergence. Across eight it is not: a device re-forming a full mesh asks every peer at
    /// once, and the answers come back over several pumps — so the first match closed the window
    /// while other peers' re-gossips were still in flight. Those records then arrived **outside** a
    /// merge window, took the live-record path, and asked for a `.membership` rotation instead of
    /// the merge's. Everything else about those cells was correct: the state converged, the roster
    /// and the heads were identical at every member, and nothing was committed twice — the record
    /// was applied once, under the other name. Four cells reached it: `4/2/2` × {quorum, short} ×
    /// the two seeds now named ``windowRedesignSeeds``.
    ///
    /// **P5 item 7 closed it** by redesigning what a window *is*. It is now an explicit value
    /// (`MeshMergeWindow`) that closes only when `pending = (asked ∪ answered) ∩ reachable ∖
    /// matched` is empty — every asked peer matched — with the responder-side rule "answered **and**
    /// the peer's next digest matched", never "answered" alone, which would have reopened the 2c
    /// deadlock from the other side. The occasion that rule needs is one post-merge proof: a fold
    /// that moves this device's digest re-advertises it to the peers the window still owes. The four
    /// cells run here again, at full strictness, and
    /// ``MeshConvergencePropertyTests/theFourCellsThatWereDeferredRunAtFullStrictness(cell:)`` names
    /// them as the regression fixture.
    ///
    /// A schedule may be deferred again only the same way: **by name**, with the defect written
    /// down. ``MeshConvergencePropertyTests/everyDeferralIsNamedAndTheRestOfTheMatrixIsWhole()`` is
    /// what makes a silent one impossible, and the empty list plus its ``cells(for:)`` filter is the
    /// mechanism that rule rides on.
    static let deferred: [MeshConvergenceCell] = []

    /// The two fixed seeds whose `4/2/2` schedule reached the window-closes-early defect above.
    ///
    /// Values unchanged from when they were the deferral: they are the named regression fixture
    /// now, exactly as `deadlockSeed` is P4 item 2c's.
    static let windowRedesignSeeds: [UInt64] = [0x308d_0d41_4707_d80, 0xace0_7337_d1bd_4fcc]

    /// The four cells P4 item 2d deferred, built from ``windowRedesignSeeds`` — the regression
    /// fixture item 7's redesign has to keep green.
    static let windowRedesignCells: [MeshConvergenceCell] = {
        var cells: [MeshConvergenceCell] = []
        for seed in windowRedesignSeeds {
            for preferQuorum in [true, false] {
                cells.append(MeshConvergenceCell(
                    shape: .fourTwoTwo, preferQuorum: preferQuorum, seed: seed
                ))
            }
        }
        return cells
    }()

    /// Rosters 3 and 4 — shapes `2/1`, `2/2`, `3/1`: 3 × 2 × 8 = 48 cells.
    static let iterationA: [MeshConvergenceCell] = cells(for: MeshPartitionShape.iterationA)

    /// Rosters 6 and 8 — shapes `3/3` and `4/2/2`: 2 × 2 × 8 = 32 cells.
    static let iterationB: [MeshConvergenceCell] = cells(for: MeshPartitionShape.iterationB)

    /// The whole of §16.2's matrix: shape × quorum preference × seed, minus ``deferred``.
    static let all: [MeshConvergenceCell] = iterationA + iterationB

    /// The cells the **nested re-split** runs, on top of their own flat heal.
    ///
    /// Deliberately a short list rather than a fourth matrix dimension. The re-split is a shape, and
    /// what it exercises — the abandon, the re-plan and the head cap — does not vary with the seed
    /// the way the flat matrix's arithmetic does; every extra cell is a whole roster-6-or-8 build
    /// run twice over. Rosters 6 and 8 on purpose: they are where a nested cut produces more branch
    /// heads than any flat split of the same roster can.
    static let resplit: [MeshConvergenceCell] = {
        var cells: [MeshConvergenceCell] = []
        for shape in MeshPartitionShape.iterationB {
            for preferQuorum in [true, false] {
                for seed in MeshConvergenceSeeds.family.prefix(resplitSeedCount) {
                    cells.append(MeshConvergenceCell(
                        shape: shape, preferQuorum: preferQuorum, seed: seed
                    ))
                }
            }
        }
        return cells
    }()

    /// How many of the fixed seeds the re-split cells replay.
    static let resplitSeedCount = 2

    /// Shape × quorum preference × seed, minus ``deferred``, for one list of shapes.
    private static func cells(for shapes: [MeshPartitionShape]) -> [MeshConvergenceCell] {
        var cells: [MeshConvergenceCell] = []
        for shape in shapes {
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
    }
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

    /// The ingestion gates **this member** re-runs over the merged union (item 7, §21.3's decision).
    ///
    /// `.open` unless a cell deliberately blocks a sender at one member. Local by construction: the
    /// union is shared and identical everywhere, the *view* over it is not — which is the half
    /// `aBlockedSenderChangesOnlyThatMembersView` exists to prove is really per-member.
    var gates: MeshContentGates = .open

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

    /// The instant this run's mesh was created at, and the base every instant it injects is written
    /// as an offset from.
    ///
    /// A membership cell keeps `MeshP3Acceptance.base`. A **routed** caller passes
    /// `MeshRoutedFixtureClock.createdAt` and gets the same value today — but one that starts
    /// rolling with the wall clock on 2026-12-16, a month BEFORE the old literal falls due, so its
    /// manifests never expire out from under it (item 6a). Mesh and manifest must share it: the
    /// verifier pins a manifest's expiry to the mesh's own `createdAt + ceiling`.
    let anchor: Date

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

    /// The members that queued a `.membership` rotation during the heal, in the order they did.
    /// Named rather than merely counted: a heal that rotates `.membership` is a record that reached
    /// somebody outside a merge window, and *which* member that was is the whole diagnosis.
    var healMembershipAt: [String] = []

    /// Delivery-target merges that were refused by name. Must stay empty: a refusal means two
    /// members disagreed about **who a piece of content is for**, which §10.1 forbids.
    var deliveryRefusals: [String] = []

    /// How many `finalPairAttempt` events were judged on a roster larger than two.
    var finalPairAttemptsAboveTwo = 0

    /// A monotonically increasing id source for content, so no two items share a `contentID`.
    /// Read and advanced by the content adapters in the extension below.
    var contentCounter = 0

    /// §10.4's threshold the **manager** re-derived at the instant the removal vote was opened.
    ///
    /// Recorded rather than re-computed so a cell can assert that a departure which ran *first*
    /// really shrank the arithmetic the vote was judged against.
    var quorumAtVote: Int?

    /// Every epoch head this cell minted, canonically, in mint order. Distinctness is asserted:
    /// two branches or two sides that landed on one head would make a divergence claim vacuous.
    var mintedHeads: [String] = []

    /// How many heads had been minted before the nested re-split's own rotations.
    var mintedHeadsBeforeResplit = 0

    /// The nested re-split this run was interrupted by, if any.
    var resplit: MeshResplitPlan?

    /// Members inside an open merge window at the instant the re-split cut the fabric. Non-empty is
    /// the precondition that makes the cut a **mid-merge** one rather than a second flat split.
    var awaitingBeforeResplit: [String] = []

    /// Members still inside one immediately after the cut. Must be empty — `abandonMergeExchange`.
    var awaitingAfterResplit: [String] = []

    /// Members that opened a **fresh** exchange on the first commit of the re-planned heal. Must be
    /// non-empty, or the abandon narrowed the window into silence (ledger "(P4 i11)").
    var awaitingAfterReheal: [String] = []

    /// The members still on the roster.
    var livingMembers: [MeshConvergenceMember] { members.filter(\.isParticipating) }

    /// Their nodes, which is what the rig's settle takes.
    var livingNodes: [MeshDepartureNode] { livingMembers.map(\.node) }

    private init(
        schedule: MeshConvergenceSchedule, fabric: FakePeerNetwork, meshID: UUID,
        members: [MeshConvergenceMember], anchor: Date
    ) {
        self.schedule = schedule
        self.fabric = fabric
        self.meshID = meshID
        self.members = members
        self.anchor = anchor
        branchCounters = Array(repeating: 0, count: schedule.branches.count)
    }

    // MARK: Build

    /// Builds the roster, asserts the preconditions that would make every later claim vacuous, links
    /// each branch internally, raises §10.2's split, and seeds each branch's own epoch.
    ///
    /// - Parameter anchor: The mesh's creation instant, and the base every injected instant offsets
    ///   from. Routed callers pass `MeshRoutedFixtureClock.createdAt` (item 6a); membership cells
    ///   omit it, keep the pinned anchor, and are byte-identical. `Date?` because a default
    ///   argument is evaluated in the caller's isolation and the anchor is `@MainActor`.
    static func build(
        _ schedule: MeshConvergenceSchedule, label: String, anchor: Date? = nil
    ) throws -> MeshConvergenceRun {
        let anchor = anchor ?? MeshP3Acceptance.base
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
                node, ledger: ledger, founderKey: founder.localSigningPublicKey, meshID: meshID,
                createdAt: anchor
            )
            #expect(MeshMergeFixtures.roster(node.manager).count == size,
                    "roster \(size) is this cell's hard precondition")
            #expect(MeshDepartureRig.quorum(node) == schedule.shape.quorumThreshold,
                    "roster \(size) ⇒ quorum \(schedule.shape.quorumThreshold), everywhere")
            let branch = schedule.branches.firstIndex { $0.contains(index) } ?? 0
            members.append(MeshConvergenceMember(index: index, branch: branch, node: node))
        }
        let run = MeshConvergenceRun(
            schedule: schedule, fabric: fabric, meshID: meshID, members: members, anchor: anchor
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
                        reachable: reachable, now: anchor
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

    /// Re-seeds one branch's keyring at its current counter.
    private func seedBranch(_ branch: Int) throws {
        guard branchCounters.indices.contains(branch) else { return }
        try seedEpoch(for: branchMembers(branch), counter: branchCounters[branch])
    }

    /// Puts one **set of members** on a freshly minted head at `counter`, coordinated by that set's
    /// own lowest fingerprint (§10.2's branch coordinator rule, which reads presence).
    ///
    /// Shared by the flat split's branches and by a nested re-split's sides, because §10.2 makes no
    /// distinction between them: a side is a branch that appeared later.
    func seedEpoch(for members: [MeshConvergenceMember], counter: UInt32) throws {
        guard let coordinator = members.map(\.fingerprint).min() else { return }
        guard let head = MeshEpochRef.minted(
            counter: counter, coordinatorFingerprint: coordinator, meshID: meshID
        ) else { throw MeshConvergenceFailure.couldNotMintEpoch }
        mintedHeads.append(head.canonicalString)
        for member in members { MeshDepartureRig.seedEpoch(member.node, head: head) }
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
        distribute(target, to: branchMembers(branch), insert: insert)
    }

    /// The same, to an explicit set of members — what a nested re-split's **side** is.
    func distribute(
        _ target: MeshDeliveryTarget, to members: [MeshConvergenceMember],
        insert: (MeshConvergenceMember) -> Void
    ) {
        createdContent.insert(target.contentID)
        for member in members {
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
        quorumAtVote = roster.quorumThreshold
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
                now: anchor.addingTimeInterval(Self.idleWindowSeconds)
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
            selfFingerprint: performer.fingerprint, startedAt: anchor
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
    /// - Parameter plan: A nested re-split to interrupt the heal with, §16.2's fifth shape. The cut
    ///   lands after the ordered walk and **before** the merge it opened has concluded.
    func runHeal(interruptedBy plan: MeshResplitPlan? = nil) async throws {
        try await runOrderedHeal()
        if let plan {
            resplit = plan
            try await runNestedResplit(plan)
        }
        try await formFullMesh()
        sample.reset()
        try await MeshDepartureRig.settle(livingNodes, on: fabric, sampling: sample)
        recordHealRotations()
        settleModels()
    }

    /// The schedule's own ordered walk: bridges first, then the intra-branch spread.
    private func runOrderedHeal() async throws {
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
    ///    receives the middle member's folded epoch heads *from an exchange of its own*. A **second
    ///    commit round**, once the first window has concluded, is what delivers them — and when
    ///    *every* member is awaiting at once, no round can, which is the deadlock P4 item 2c fixed
    ///    by making the digest ANSWER carry the heads too (this file's header note).
    ///
    /// Bounded twice over: ``MeshScheduleBounds/maxCommitRounds`` rounds, and an early exit the
    /// moment §10.3's `max` agrees at every member (``basesAgree()``).
    private func formFullMesh() async throws {
        linkEveryPair()
        for _ in 0..<MeshScheduleBounds.maxCommitRounds {
            sample.reset()
            commitEveryPair(livingMembers)
            try await MeshDepartureRig.settle(
                livingNodes, on: fabric, sampling: sample, until: { self.mergeIsDone() }
            )
            recordHealRotations()
            if mergeIsDone() { break }
        }
        fullMeshIsWhole()
    }

    /// Whether the merge this phase is driving has actually finished: §10.3's `max` agrees **and**
    /// every member derives the same roster.
    ///
    /// Both halves, because they converge by different routes and at different speeds. Epoch heads
    /// ride a frame with no once-per-peer gate, so they agree early; records ride §10.5's re-gossip,
    /// which answers a given peer once per session — a member whose peers all answered it before
    /// any of them had learned a departure has to be asked again, and the second commit round is
    /// what asks. Stopping on the heads alone left exactly that member a record short, with the
    /// phase declaring itself done.
    private func mergeIsDone() -> Bool { basesAgree() && rostersAgree() }

    /// Whether every living member's derived roster is the survivors, exactly.
    private func rostersAgree() -> Bool {
        let expected = Set(livingMembers.map(\.fingerprint))
        return livingMembers.allSatisfy {
            Set(MeshMergeFixtures.roster($0.node.manager)) == expected
        }
    }

    /// The healed mesh really is a **full** mesh, on the merged roster: nobody's derived roster
    /// still names a member it cannot reach, so §10.2's branch scoping elects one coordinator
    /// rather than one per stale view (§8.7 finding 1, `871b7ee`).
    private func fullMeshIsWhole() {
        let living = livingMembers
        let reachable = Set(living.map(\.fingerprint))
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for member in living {
                _ = member.node.manager.evaluatePartition(
                    reachable: reachable, now: anchor
                )
                #expect(member.node.manager.branchView?.isPartitioned == false,
                        "\(member.node.label): roster names an unreachable member: \(diagnostic(member))")
            }
        }
    }

    /// What one member is missing, as a frozen diagnostic line. A bare "still partitioned" says
    /// nothing about *which* record never arrived, and that is the only interesting half.
    private func diagnostic(_ member: MeshConvergenceMember) -> String {
        let ledger = member.node.manager.membershipVerifier?.ledger
        let stranded = member.node.manager.branchView?.temporarilyDisconnectedFingerprints ?? []
        return "unreachable=\(stranded.count) adm=\(ledger?.admissions.count ?? -1) "
            + "dep=\(ledger?.departures.count ?? -1)/\(expectedDepartures.count) "
            + "rem=\(ledger?.removals.count ?? -1)/\(expectedRemovals.count) "
            + "awaiting=\(member.node.manager.awaitingResumeMerge) "
            + "merges=\(member.node.manager.mergeApplicationCount) "
            + "digestsSeen=\(member.node.manager.peerInventoryDigests.count) "
            + "answered=\(member.node.manager.reGossipDiagnosticsForTesting.answered.count) "
            + "slots=\(member.node.manager.reGossipDiagnosticsForTesting.slots)"
    }

    /// Seats a link for every living pair that cannot currently reach its partner.
    ///
    /// Only pairs the fabric says are unreachable, because seating a second slot for a peer that
    /// already has one would give one link two coordinators. A link a re-split merely **cut**
    /// (`FakePeerNetwork.partition`) is restored with `heal`, not re-seated, for the same reason.
    private func linkEveryPair() {
        let living = livingMembers
        for (position, near) in living.enumerated() {
            for far in living.dropFirst(position + 1)
            where !fabric.canReach(near.node.handle, far.node.handle) {
                MeshDepartureRig.link(near.node, far.node, on: fabric)
            }
        }
    }

    /// Commits every living pair, both directions, on the merged reachable set.
    ///
    /// Presence is re-evaluated first and **not** asserted on here. At the start of the first round
    /// a member's roster may still name somebody it cannot reach — on a three-branch shape the
    /// ordered walk genuinely can leave one member a record short, and this phase is what fixes it.
    /// The claim belongs where it is true and load-bearing: ``fullMeshIsWhole()``, run once the
    /// rounds are done, where every member must be on the merged roster's own election.
    private func commitEveryPair(_ living: [MeshConvergenceMember]) {
        let reachable = Set(living.map(\.fingerprint))
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for member in living {
                _ = member.node.manager.evaluatePartition(
                    reachable: reachable, now: anchor
                )
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
                    reachable: reachableFingerprints(from: member), now: anchor
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
            let causes = sample.causes(at: member.node.label)
            if causes.contains(.membership) { healMembershipAt.append(member.node.label) }
            healCauses.formUnion(causes)
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
        let walk = schedule.heal + (resplit?.heal ?? [])
        for _ in 0..<MeshScheduleBounds.maxSettleSweeps {
            for step in walk {
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

// MARK: - MeshConvergenceRun: the nested re-split mid-merge

extension MeshConvergenceRun {

    /// §16.2's fifth shape, in four named phases.
    ///
    /// Split into phases rather than written as one function because each of them carries a claim
    /// the others do not, and a single 100-line runner would break Power of 10 R4 *and* hide which
    /// phase a failure came from — the same reason ``MeshConvergenceRun`` itself is phased.
    func runNestedResplit(_ plan: MeshResplitPlan) async throws {
        openMergeWindows()
        cutResplit(plan)
        try await runResplitEvents(plan)
        try await reHealAfterResplit(plan)
    }

    /// **Phase 1 — get mid-merge.** Re-form the full mesh and commit every pair, which is what puts
    /// every member inside an open merge window (`beginMergeExchange`, via the `.linksRestored`
    /// effect list or the `peerCommitted` blip).
    ///
    /// Nothing is settled first, and nothing may suspend before the sample: `awaitingResumeMerge` is
    /// set **synchronously** inside `beginMergeExchange`, while the digest and head frames it queued
    /// are still unsent tasks. Reading it here is therefore a fact, not a race (ledger "(P4 i3)").
    private func openMergeWindows() {
        linkEveryPair()
        commitEveryPair(livingMembers)
        awaitingBeforeResplit = livingMembers
            .filter(\.node.manager.awaitingResumeMerge).map(\.node.label)
    }

    /// **Phase 2 — cut, mid-merge.** Every link between the two sides is dropped silently (a radio
    /// that stopped reaching, not a disconnect anybody is told about), and each member re-evaluates
    /// §10.2 against what it can *actually* reach.
    ///
    /// The three claims here are the whole point of the shape: the cut is a **new** partition
    /// (`.linksLost`, not `.unchanged`), it lands in `MeshSessionState.partitioned`, and
    /// `abandonMergeExchange()` therefore drops the window this device was holding.
    private func cutResplit(_ plan: MeshResplitPlan) {
        for near in plan.holdouts {
            guard let holdout = participant(global: near) else { continue }
            for far in plan.rest {
                guard let other = participant(global: far) else { continue }
                fabric.partition(holdout.node.handle, from: other.node.handle)
            }
        }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for member in livingMembers {
                let verdict = member.node.manager.evaluatePartition(
                    reachable: reachableFingerprints(from: member), now: anchor
                )
                #expect(verdict == .linksLost,
                        "\(member.node.label): a re-split is a NEW partition, not an unchanged one")
                #expect(member.node.manager.sessionState == .partitioned,
                        "\(member.node.label): and it lands in `partitioned`, which is what abandons")
            }
        }
        awaitingAfterResplit = livingMembers
            .filter(\.node.manager.awaitingResumeMerge).map(\.node.label)
    }

    /// **Phase 3 — bounded events in the new sub-branches.** One branch-local rotation and one
    /// content item per side, and no membership record (this file's header says why).
    private func runResplitEvents(_ plan: MeshResplitPlan) async throws {
        mintedHeadsBeforeResplit = mintedHeads.count
        let base = (branchCounters.max() ?? 0) + 1
        for (offset, side) in plan.sides.prefix(MeshScheduleBounds.maxResplitSides).enumerated() {
            let living = side.compactMap { participant(global: $0) }
            guard !living.isEmpty else { continue }
            try rotateSide(living, counter: base + Self.branchCounterStride * UInt32(offset + 1))
            try createSideText(by: living)
            try await MeshDepartureRig.settle(living.map(\.node), on: fabric)
            MeshDepartureRig.consumeRotations(living.map(\.node))
        }
    }

    /// One side's 15-minute rotation, sampled and disarmed synchronously, then re-seeded on the
    /// side's **own** lowest-fingerprint coordinator — §10.2's branch rule, applied to a side.
    private func rotateSide(_ side: [MeshConvergenceMember], counter: UInt32) throws {
        for member in side {
            member.node.manager.requestRotation(cause: .timer)
            #expect(member.node.manager.consumePendingRotationForTesting() == .timer,
                    "\(member.node.label): a sub-branch queues its own timer cause, like any branch")
        }
        try seedEpoch(for: side, counter: counter)
    }

    /// One text per side, so the re-split has content of its own to lose if the re-heal drops it.
    private func createSideText(by side: [MeshConvergenceMember]) throws {
        guard let author = side.first else { return }
        contentCounter += 1
        let item = MeshContentFixtures.message(
            contentCounter, sender: author.fingerprint,
            claimed: TimeInterval(contentCounter), firstSeen: TimeInterval(contentCounter)
        )
        let target = try makeTarget(for: item, by: author)
        distribute(target, to: side) { $0.content.messages = $0.content.messages.inserting(item) }
    }

    /// **Phase 4 — re-plan and heal.** The cut links are restored (healed, never re-seated), and the
    /// re-planned walk over the two *sides* runs bridge-first, each pair spent once in this window.
    ///
    /// The sample right after the first commit is the ledger's "(P4 i11)" residual, walked: a
    /// window that `abandonMergeExchange` had merely narrowed rather than cleared would leave this
    /// empty, because `openBlipMergeIfReconnected` guards on `!awaitingResumeMerge`.
    private func reHealAfterResplit(_ plan: MeshResplitPlan) async throws {
        restoreResplitLinks(plan)
        var spent: Set<Set<Int>> = []
        for step in plan.heal {
            guard let near = participant(global: step.near),
                  let far = participant(global: step.far) else { continue }
            #expect(spent.insert(step.unordered).inserted,
                    "a re-planned heal spends each pair once inside its own window")
            sample.reset()
            commitHealStep(near: near, far: far)
            if awaitingAfterReheal.isEmpty {
                awaitingAfterReheal = livingMembers
                    .filter(\.node.manager.awaitingResumeMerge).map(\.node.label)
            }
            try await MeshDepartureRig.settle(livingNodes, on: fabric, sampling: sample)
            recordHealRotations()
            mergeModels(near: near, far: far)
        }
    }

    /// Puts every cut link back. `heal`, not `link`: the sockets were never told they had gone, so
    /// re-seating would give one link a second coordinator and split its inbound frames in two.
    private func restoreResplitLinks(_ plan: MeshResplitPlan) {
        for near in plan.holdouts {
            guard let holdout = participant(global: near) else { continue }
            for far in plan.rest {
                guard let other = participant(global: far) else { continue }
                fabric.heal(holdout.node.handle, from: other.node.handle)
            }
        }
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
    ///
    /// There is deliberately **no relaxed entry point.** P4 carried a
    /// `checkExceptTheHealsRotationCause` for the cells 2d deferred; P5 item 7 closed that defect,
    /// leaving a public checker that silently dropped one §16.2 claim with no caller — a loosened
    /// assertion lying in the open for the next person to reach for. A future deferral re-introduces
    /// its own relaxation with its own written note, which is the discipline
    /// ``MeshConvergenceMatrix/deferred`` demands.
    static func check(_ run: MeshConvergenceRun) throws {
        let survivors = run.livingMembers
        #expect(survivors.count >= 2, "\(run.schedule.seed): a cell must end with a mesh")
        try identicalMergedState(run, survivors)
        try onePostMergeEpoch(run, survivors)
        quorumArithmetic(run, survivors)
        noContentLoss(run, survivors)
        noDuplicateCommits(run, survivors)
        oneRotationCauseAcrossTheHeal(run)
    }

    /// **(e·ii) One rotation cause across the heal**, and it is the merge's.
    ///
    /// Separated from ``noDuplicateCommits(_:_:)`` because it is a different claim: that one counts
    /// commits, this one says every record a *reconnect* carried went down the merge path. A
    /// `.membership` here means one did not — the shape P4 item 2 found as the `peerCommitted`
    /// self-edge bypass, and the shape §16.2's roster-8 row found again in
    /// ``MeshConvergenceMatrix/deferred``.
    static func oneRotationCauseAcrossTheHeal(_ run: MeshConvergenceRun) {
        #expect(run.healCauses.isSubset(of: [.merge]),
                "a heal asks for ONE rotation kind, the merge's: \(run.healCauses) at \(run.healMembershipAt)")
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

// MARK: - MeshResplitInvariants

/// What a **nested re-split mid-merge** adds on top of §16.2's five, over the members a cell ends
/// with.
///
/// Three claims, none of them re-implemented here: the merge window's own lifecycle across the
/// abandon, the epoch head cap under a cut that produces more heads than a flat split can, and the
/// evidence that the re-split really diverged rather than quietly doing nothing.
@MainActor
enum MeshResplitInvariants {

    /// Runs all three.
    static func check(_ run: MeshConvergenceRun) {
        theWindowIsOpenedAbandonedAndReopened(run)
        theHeadCapHolds(run)
        theResplitReallyDiverged(run)
    }

    /// **(f) The merge window across the abandon** — the ledger's "(P4 i11)" liveness residual,
    /// walked end to end rather than reasoned about.
    ///
    /// `abandonMergeExchange()` is the whole of the bound on that residual, and it is only a bound
    /// if all three of these hold: the cut landed while windows were **open**, it **cleared** them,
    /// and the next heal **re-opened** one. Miss the middle claim and a device sits awaiting for the
    /// rest of the session; miss the last and the abandon has traded a stuck window for a silent one.
    static func theWindowIsOpenedAbandonedAndReopened(_ run: MeshConvergenceRun) {
        #expect(!run.awaitingBeforeResplit.isEmpty,
                "seed \(String(run.schedule.seed, radix: 16)): the cut must land MID-merge")
        #expect(run.awaitingBeforeResplit.count == run.livingMembers.count,
                "every member re-forming a full mesh opens an exchange: \(run.awaitingBeforeResplit)")
        #expect(run.awaitingAfterResplit.isEmpty,
                "a re-split abandons the merge in flight: \(run.awaitingAfterResplit) still awaiting")
        #expect(!run.awaitingAfterReheal.isEmpty,
                "the next heal must open a FRESH exchange: openBlipMergeIfReconnected guards on !awaitingResumeMerge")
    }

    /// **(g) The epoch head cap, under the re-split.** A nested cut mints branch heads a flat split
    /// of the same roster cannot, and the folded set still never exceeds
    /// ``MeshSessionContextSchema/maxEpochHeads``.
    ///
    /// The second claim is the one worth stating carefully: a head is only ever dropped from a
    /// **full** set, and every drop is counted at the one context writer (P4 item 2b), never
    /// truncated in silence. `MeshMergePathTests.theHeadOverflowIsCountedAtTheWriterAgainstWhatSealed`
    /// drives that counter at its exact boundary (cap seals, cap + 1 is named); this asserts the
    /// same property holds in a live mesh that reached the cap by re-splitting rather than by being
    /// handed nine heads.
    static func theHeadCapHolds(_ run: MeshConvergenceRun) {
        let cap = MeshSessionContextSchema.maxEpochHeads
        for member in run.livingMembers {
            let manager = member.node.manager
            let label = "\(member.node.label) (seed \(String(run.schedule.seed, radix: 16)))"
            #expect(manager.knownEpochHeads.count <= cap,
                    "\(label): the sealed head set is bounded by the cap, always")
            #expect(manager.presentedEpochHeadsForTesting.count <= cap,
                    "\(label): and so is what it presents on the wire")
            #expect(manager.droppedEpochHeadCount == 0 || manager.knownEpochHeads.count == cap,
                    "\(label): dropped \(manager.droppedEpochHeadCount) at \(manager.knownEpochHeads.count) — heads only fall off a FULL set")
            #expect(Set(manager.knownEpochHeads.map(\.canonicalString)).count
                    == manager.knownEpochHeads.count, "\(label): no head is folded twice")
        }
    }

    /// **(h) The re-split really diverged.** One fresh head per side, all of them distinct, so the
    /// cap claim above is not being made about a set that never grew.
    static func theResplitReallyDiverged(_ run: MeshConvergenceRun) {
        #expect(run.mintedHeads.count == run.mintedHeadsBeforeResplit + MeshScheduleBounds.maxResplitSides,
                "a nested re-split mints exactly one head per side on top of the flat split's")
        #expect(Set(run.mintedHeads).count == run.mintedHeads.count,
                "two branches or two sides that landed on ONE head would make divergence vacuous")
        #expect(run.mintedHeads.count > run.schedule.branches.count,
                "and strictly more heads than the flat split alone produced")
    }
}

// MARK: - MeshConvergencePropertyTests

/// §16.2's convergence property, over the whole matrix: rosters 3, 4, 6 and 8 × shapes `2/1`, `2/2`,
/// `3/1`, `3/3` and `4/2/2` × the full event vocabulary, under the fixed seed family — plus §16.2's
/// fifth shape, the nested re-split mid-merge.
@MainActor
@Suite(.serialized)
struct MeshConvergencePropertyTests {

    /// **The property.** One seeded, bounded schedule per cell: split, events, ordered heal, bounded
    /// settle, then all five of §16.2's assertions.
    @Test(arguments: MeshConvergenceMatrix.all)
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

    /// **Nothing is skipped, and a deferral cannot reappear silently.** The matrix is whole: every
    /// shape × quorum preference × seed runs, including the two cells P4 item 2c un-deferred once
    /// the merge-window deadlock they found was fixed. An entry back in
    /// ``MeshConvergenceMatrix/deferred`` means somebody re-opened the exception instead of fixing
    /// what it points at, and this fails until the defect note beside it is written down.
    @Test func everyDeferralIsNamedAndTheRestOfTheMatrixIsWhole() {
        let whole = MeshPartitionShape.matrix.count * 2 * MeshConvergenceSeeds.derivedCount
        #expect(whole == 80, "5 shapes × 2 preferences × 8 seeds is the matrix §16.2 asks for")
        #expect(MeshConvergenceMatrix.deferred.isEmpty,
                "nothing is deferred: a re-entry needs its own written-down defect note")
        #expect(MeshConvergenceMatrix.all.count == whole)
        #expect(MeshConvergenceMatrix.all.count == 80, "and every cell runs, at full strength")
        #expect(MeshConvergenceMatrix.iterationA.count == 48, "rosters 3 and 4")
        #expect(MeshConvergenceMatrix.iterationB.count == 32, "rosters 6 and 8, the four restored")
        #expect(Set(MeshConvergenceMatrix.all.map(\.shape.rosterSize)) == [3, 4, 6, 8],
                "§16.2's four rosters all run")
        #expect(!MeshConvergenceMatrix.resplit.isEmpty, "and §16.2's fifth shape runs too")
        // 2c's cell is IN the matrix, on both preferences: the deadlock stays fixed.
        for preferQuorum in [true, false] {
            #expect(MeshConvergenceMatrix.all.contains(MeshConvergenceCell(
                shape: .twoTwo, preferQuorum: preferQuorum, seed: 0x308d_0d41_4707_d80
            )), "the cell that found the deadlock runs, at full strictness")
        }
        // And so are 2d's four, which P5 item 7's window redesign retired.
        for cell in MeshConvergenceMatrix.windowRedesignCells {
            #expect(MeshConvergenceMatrix.all.contains(cell),
                    "\(cell): the cell 2d deferred is back IN the matrix, not beside it")
        }
    }

    /// **The four cells P4 item 2d deferred, at full strictness.** They are not merely back in the
    /// matrix; they are named here as the regression fixture for P5 item 7's window redesign, so a
    /// window that went back to closing on the first matching digest fails on the cells that found
    /// that defect rather than on a count somewhere else.
    ///
    /// Built locally from ``MeshConvergenceMatrix/windowRedesignCells`` rather than from
    /// ``MeshConvergenceMatrix/deferred``: a `@Test(arguments:)` over an empty array runs zero cases
    /// and reports green.
    @Test(arguments: MeshConvergenceMatrix.windowRedesignCells)
    func theFourCellsThatWereDeferredRunAtFullStrictness(cell: MeshConvergenceCell) async throws {
        let run = try MeshConvergenceRun.build(cell.schedule, label: "window7")
        try await run.runSplitEvents()
        try await run.runHeal()
        try MeshConvergenceInvariants.check(run)
        #expect(run.healCauses == [.merge],
                "\(cell): every reconnect-carried record takes the merge path: \(run.healMembershipAt)")
        for node in run.livingNodes { node.manager.leaveMesh() }
    }

    /// **The full vocabulary really fires.** Every event in §16.2's list is executed somewhere in
    /// the matrix — asserted over the schedules the matrix actually runs, so a generator that
    /// stopped emitting departures could not hide behind 80 green cells.
    @Test func theMatrixExecutesEveryEventInTheVocabulary() {
        var seen: Set<String> = []
        for cell in MeshConvergenceMatrix.all {
            seen.formUnion(cell.schedule.steps.map(\.event.token))
        }
        for event in MeshScheduleEvent.vocabulary {
            #expect(seen.contains(event.token), "the matrix never runs \(event.token)")
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
        for shape in MeshPartitionShape.matrix {
            let schedule = MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: false
            )
            let forward = try await converge(schedule, label: "commute-f")
            let reversed = try await converge(schedule.withReversedIntraHeal(), label: "commute-r")
            #expect(forward == reversed,
                    "\(shape.rawValue): two valid heal orders must converge on identical state")
        }
    }

    // MARK: §16.2's fifth shape — the nested re-split mid-merge

    /// **The property, interrupted.** The same seeded schedule, healed until every member is inside
    /// an open merge window, then cut in two again — and it still ends with §16.2's five invariants
    /// plus ``MeshResplitInvariants``' three.
    ///
    /// The interruption is not a second flat split: `openMergeWindows` re-forms the whole mesh and
    /// commits it, so the cut lands on devices that are *awaiting a re-gossip they will never get*.
    /// That is the state the ledger's "(P4 i11)" residual is about, and the only thing bounding it
    /// is `abandonMergeExchange()`.
    @Test(arguments: MeshConvergenceMatrix.resplit)
    func aNestedResplitMidMergeStillConverges(cell: MeshConvergenceCell) async throws {
        let schedule = cell.schedule
        guard let plan = MeshScheduleGenerator.resplit(for: schedule) else {
            Issue.record("\(cell): no branch left to re-split — the cell asserts nothing")
            return
        }
        let run = try MeshConvergenceRun.build(schedule, label: "resplit")
        try await run.runSplitEvents()
        try await run.runHeal(interruptedBy: plan)
        try MeshConvergenceInvariants.check(run)
        MeshResplitInvariants.check(run)
        #expect(run.createdContent.count > run.schedule.branches.count,
                "\(cell): the sides' own content is part of what must not be lost")
        for node in run.livingNodes { node.manager.leaveMesh() }
    }

    /// **§10.3's "N-way merges need no special case", under the nested cut.** The same schedule and
    /// the same re-split, healed in two valid link orders, converge on identical state.
    ///
    /// Both halves are reordered — the flat heal's intra steps and the re-plan's — because after the
    /// cut the re-plan is the walk that actually delivers, and reversing only the first would leave
    /// the interesting half in one order.
    @Test func theNestedResplitHealCommutes() async throws {
        let schedule = MeshScheduleGenerator.schedule(
            seed: MeshConvergenceSeeds.root, shape: .threeThree, preferQuorum: false
        )
        guard let plan = MeshScheduleGenerator.resplit(for: schedule) else {
            Issue.record("the commute cell must be re-splittable")
            return
        }
        let forward = try await converge(schedule, label: "rs-commute-f", resplit: plan)
        let reversed = try await converge(
            schedule.withReversedIntraHeal(), label: "rs-commute-r",
            resplit: plan.withReversedIntraHeal()
        )
        #expect(forward == reversed,
                "two valid orders of an interrupted heal must converge on identical state")
    }

    // MARK: The rig gaps iteration A left open

    /// The seed of the fixed family whose `3/1` schedule opens with the removal vote **and** still
    /// creates content after the departure is moved ahead of it.
    ///
    /// Pinned by value rather than taken as "the first that works", and checked against the family,
    /// because a cell chosen at run time is not a fixed seed. Most of the family puts every content
    /// event in the departing member's hands, which after the reorder would leave a cell with no
    /// content to assert convergence over at all.
    private static let departureFirstSeed: UInt64 = 0xace0_7337_d1bd_4fcc

    /// **The gates are per member; the union is not.** One member blocks one sender: every member
    /// still holds the identical merged ledger, and the *visible* transcript, photo list and heart
    /// list differ at exactly that member.
    ///
    /// §10.3's merge re-runs the ingestion gates, and §21.3's decision is that they are re-run **as
    /// a view**, never as a filter on what was stored — so a member that lifts a block sees the
    /// content again without a second merge. That is a property of `MeshContentGates` over an
    /// unmutated union, and iteration A never exercised two members holding different gates.
    @Test func aBlockedSenderChangesOnlyThatMembersView() async throws {
        let run = try await convergedRun(shape: .twoTwo, label: "gates")
        let survivors = run.livingMembers
        guard let blocker = survivors.first, let union = survivors.first?.content,
              let blocked = union.senders.sorted().first(where: { $0 != blocker.fingerprint })
        else { throw MeshConvergenceFailure.rosterTooSmall }
        blocker.gates = MeshContentGates(chatAllowed: true, blockedFingerprints: [blocked])
        #expect(union.senders.count >= 2, "a gate cell needs content from at least two authors")

        for member in survivors {
            #expect(member.content == union, "the UNION is identical at every member, gates or not")
        }
        let mine = blocker.content
        #expect(mine.visibleTranscript(gates: blocker.gates).allSatisfy { $0.senderFingerprint != blocked },
                "the blocker sees none of that sender's messages")
        #expect(mine.visiblePhotos(gates: blocker.gates).allSatisfy { $0.senderFingerprint != blocked },
                "nor photos")
        #expect(mine.visibleHearts(gates: blocker.gates).allSatisfy { $0.senderFingerprint != blocked },
                "nor hearts")
        let hidden = mine.messages.all.count - mine.visibleTranscript(gates: blocker.gates).count
            + mine.photos.all.count - mine.visiblePhotos(gates: blocker.gates).count
            + mine.hearts.all.count - mine.visibleHearts(gates: blocker.gates).count
        #expect(hidden > 0, "a gate that hid nothing would make this cell vacuous")
        for member in survivors where member !== blocker {
            #expect(member.content.visibleTranscript(gates: member.gates) == mine.messages.all,
                    "\(member.node.label): every OTHER member's view is the whole union")
            #expect(member.content.visiblePhotos(gates: member.gates) == mine.photos.all)
            #expect(member.content.visibleHearts(gates: member.gates) == mine.hearts.all)
        }
        for node in run.livingNodes { node.manager.leaveMesh() }
    }

    /// **§10.4 at the manager seam: a departure shrinks the roster, and the quorum with it.**
    ///
    /// The generator forces the departure last, so iteration A could never run one *before* the vote
    /// it changes the arithmetic of. `withDepartureBeforeTheVote()` lifts exactly that constraint on
    /// one cell: roster 4, branch of three. Run in the generator's own order the branch needs three
    /// votes; with the departure first the roster is three, the threshold is two, and the two voters
    /// left are a quorum — which is the plan's own worked consequence, re-derived by the manager on
    /// its merged roster rather than asserted from a table.
    @Test func aDepartureBeforeTheVoteReDerivesQuorumOnTheShrunkRoster() async throws {
        #expect(MeshConvergenceSeeds.family.contains(Self.departureFirstSeed),
                "the pinned cell must still be one of the fixed seeds")
        let schedule = MeshScheduleGenerator.schedule(
            seed: Self.departureFirstSeed, shape: .threeOne, preferQuorum: true
        )
        let ordered = schedule.withDepartureBeforeTheVote()
        #expect(ordered.steps != schedule.steps, "this cell must actually reorder something")

        let control = try MeshConvergenceRun.build(schedule, label: "order-control")
        try await control.runSplitEvents()
        #expect(control.quorumAtVote == 3, "roster 4 ⇒ quorum 3 when the vote runs first")
        for node in control.livingNodes { node.manager.leaveMesh() }

        let shrunk = try MeshConvergenceRun.build(ordered, label: "order-shrunk")
        try await shrunk.runSplitEvents()
        #expect(shrunk.expectedDepartures.count == 1, "the departure really ran first")
        #expect(shrunk.quorumAtVote == 2, "roster 4 → 3 drops quorum to 2 (§10.4), at the manager")
        #expect(shrunk.expectedRemovals.count == 1, "and two voters are now a quorum")
        try await shrunk.runHeal()
        try MeshConvergenceInvariants.check(shrunk)
        for node in shrunk.livingNodes { node.manager.leaveMesh() }
    }

    /// Runs one schedule end to end and returns its digest.
    private func converge(
        _ schedule: MeshConvergenceSchedule, label: String, resplit: MeshResplitPlan? = nil
    ) async throws -> MeshConvergenceDigest {
        let run = try MeshConvergenceRun.build(schedule, label: label)
        try await run.runSplitEvents()
        try await run.runHeal(interruptedBy: resplit)
        let digest = try run.digest()
        for node in run.livingNodes { node.manager.leaveMesh() }
        return digest
    }

    /// Runs the root seed of one shape end to end and hands back the live run, for the cells that
    /// assert on the members rather than on the digest.
    private func convergedRun(
        shape: MeshPartitionShape, label: String
    ) async throws -> MeshConvergenceRun {
        let run = try MeshConvergenceRun.build(
            MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: false
            ),
            label: label
        )
        try await run.runSplitEvents()
        try await run.runHeal()
        try MeshConvergenceInvariants.check(run)
        return run
    }
}
