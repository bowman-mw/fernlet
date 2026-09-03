// MeshConvergenceSchedule.swift
// FernletTests
//
// P4 item 9, iteration A (plan §16.2): the **deterministic schedule generator** the convergence
// property test replays.
//
// §16.2 asks for a "convergence property test over randomized bounded schedules with a fixed seed".
// Every word of that is a constraint, and this file is where each one is paid for:
//
//   * **randomized** — the split's membership, the interleaving of events across branches, which
//     member acts, and the order the partition heals in are all drawn from a generator.
//   * **bounded** — every list here has a hard ceiling (``MeshScheduleBounds``) and every loop is
//     bounded by it (Power of 10 R2). A schedule cannot grow with the seed.
//   * **fixed seed** — the generator is SplitMix64 over a `UInt64` state passed `inout`. There is no
//     `SystemRandomNumberGenerator`, no `Date()`, and no static mutable state anywhere in this file,
//     so the same seed produces a byte-identical schedule on any machine, in any suite order, under
//     any load. `sameSeedReplaysAnIdenticalSchedule` asserts exactly that, because a property test
//     whose failures cannot be replayed is a flake generator (launcher §6).
//
// **The generator decides the whole cell up front — including who leaves and who is removed.** That
// is deliberate: the heal is an *ordered* sequence of pairwise exchanges, and
// `MeshNetworkManager.reGossipRecords(to:)` answers **once per peer per session** (ledger "(P4 i7)").
// A heal planned over members that turn out to be gone would either strand a survivor or spend a
// pair's single exchange on a device that cannot answer. Planning the departures and removals before
// the heal is what lets the heal be a spanning walk over the **survivors**.
//
// Nothing here touches a manager, a store, a transport or a clock; `MeshConvergencePropertyTests`
// executes what this file plans.

import Foundation
import Testing

// MARK: - MeshScheduleBounds

/// Every ceiling a schedule is bounded by. One place, so "bounded" is checkable rather than claimed.
///
/// These are **assertions, not knobs**: `everyScheduleStaysInsideItsBounds` fails if a generated
/// schedule reaches one, which means the generator grew a case that can run away rather than that a
/// bound was too small.
nonisolated enum MeshScheduleBounds {

    /// The most branches a partition shape may have. `4/2/2` is the widest §16.2 names.
    static let maxBranches = 4

    /// The most events one branch may run during the split.
    static let maxEventsPerBranch = 10

    /// The most steps a whole schedule may run during the split.
    static let maxSteps = maxBranches * maxEventsPerBranch

    /// The most pairwise exchanges a heal may take. A spanning walk over ≤ 8 survivors needs 7.
    static let maxHealSteps = 12

    /// How many times the settle sweeps the healed graph. The healed link graph has diameter ≤ 3
    /// for every shape §16.2 names, so three sweeps flood it and the fourth is headroom.
    static let maxSettleSweeps = 4

    /// How many commit rounds the full-mesh phase runs before it gives up.
    ///
    /// Two, and the second is not headroom: a device inside an open merge window opens no second
    /// exchange (`openBlipMergeIfReconnected` guards on `!awaitingResumeMerge`), and that window
    /// closes only on a peer digest that *matches* local inventory. So the first round closes the
    /// windows the ordered heal left open and the second is what actually delivers the epoch heads
    /// they were holding. The phase exits the moment §10.3's `max` agrees at every member, so a cell
    /// that converges in one round costs one — and raising this past two changes nothing, because a
    /// mesh in which *every* member is awaiting opens no exchange at all. That last case is why the
    /// digest ANSWER now carries the heads as well (P4 item 2c): a round it cannot open is a round
    /// no ceiling here can supply.
    static let maxCommitRounds = 2

    /// The most content items one branch creates — one photo, one text, one heart. Far below the
    /// smallest ``MeshContentSet`` capacity, which is what makes "no content loss" an unconditional
    /// claim rather than one that has to reason about the caps (the caps have their own suite in
    /// `MeshContentMergeTests`).
    static let maxContentPerBranch = 3
}

// MARK: - MeshScheduleRandom

/// SplitMix64: a deterministic, seekable generator, as a **value**.
///
/// Not a `RandomNumberGenerator` conformance and not a `static var` on purpose. Power of 10 R8 bans
/// mutable globals, and a schedule that drew from shared state would stop being a pure function of
/// its seed the moment two suites ran in one process. Every draw here goes through an `inout`
/// parameter, so the whole generator is one expression `schedule(seed:…)` can be re-evaluated from.
///
/// The constants are Vigna's published SplitMix64; the arithmetic is wrapping on purpose (`&+`,
/// `&*`), which is the algorithm rather than an overflow being swallowed.
nonisolated struct MeshScheduleRandom: Equatable, Sendable {

    /// The 64-bit state. Advancing is the whole algorithm: state += γ, then a finalizing mix.
    private var state: UInt64

    /// Starts a generator at `seed`.
    init(seed: UInt64) { state = seed }

    /// The next 64 bits.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// A value in `0..<bound`, or 0 when `bound` is not positive.
    ///
    /// A draw is consumed even when `bound` is 1, so adding or removing a one-way choice does not
    /// silently re-phase every later draw in the same schedule.
    mutating func index(below bound: Int) -> Int {
        let drawn = next()
        guard bound > 0 else { return 0 }
        return Int(drawn % UInt64(bound))
    }

    /// A Fisher-Yates shuffle of `items`. Bounded by `items.count` (R2).
    mutating func shuffled<Element>(_ items: [Element]) -> [Element] {
        var result = items
        guard result.count > 1 else { return result }
        for position in stride(from: result.count - 1, through: 1, by: -1) {
            result.swapAt(position, index(below: position + 1))
        }
        return result
    }
}

// MARK: - MeshPartitionShape

/// One of §16.2's partition shapes, as the branch sizes it splits a roster into.
///
/// The roster size is derived from the shape rather than passed alongside it, so a cell cannot ask
/// for a `3/1` of a roster of six. Iteration A exercises ``twoOne``, ``twoTwo`` and ``threeOne``;
/// ``threeThree`` and ``fourTwoTwo`` are declared here — the generator already handles any number of
/// branches — and are iteration B's matrix rows.
nonisolated enum MeshPartitionShape: String, Equatable, Sendable, CaseIterable {

    /// Roster 3 split 2/1 — the roster-3 analogue of `2/2`, and the smallest shape with a majority
    /// branch that can reach quorum (3 → quorum 2).
    case twoOne

    /// Roster 4 split 2/2 — §10.4's worked example: quorum 3, so **neither branch can moderate**.
    case twoTwo

    /// Roster 4 split 3/1 — quorum 3, so the majority branch can remove the isolated member.
    case threeOne

    /// Roster 6 split 3/3. **Iteration B.**
    case threeThree

    /// Roster 8 split 4/2/2 — the only three-branch shape. **Iteration B.**
    case fourTwoTwo

    /// How many members each branch holds, in branch order.
    var branchSizes: [Int] {
        switch self {
        case .twoOne: return [2, 1]
        case .twoTwo: return [2, 2]
        case .threeOne: return [3, 1]
        case .threeThree: return [3, 3]
        case .fourTwoTwo: return [4, 2, 2]
        }
    }

    /// The roster this shape splits.
    var rosterSize: Int { branchSizes.reduce(0, +) }

    /// §10.4's threshold for this shape's roster: ⌊|roster|/2⌋ + 1, written from the plan.
    var quorumThreshold: Int { rosterSize / 2 + 1 }

    /// The shapes iteration A runs. Named so the matrix and this file cannot drift apart.
    static let iterationA: [MeshPartitionShape] = [.twoOne, .twoTwo, .threeOne]
}

// MARK: - MeshScheduleEvent

/// One event from §16.2's "events during split" list.
///
/// Each case is one call into an existing seam — no rule is re-implemented here, and the adapter
/// that performs it is named in ``MeshScheduleEvent/token``'s documentation in
/// `MeshConvergencePropertyTests`.
nonisolated enum MeshScheduleEvent: Equatable, Sendable {

    /// A friend photo created in this branch (`MeshMergedPhoto`).
    case photo

    /// A mesh text created in this branch (`MeshMergedMessage`).
    case text

    /// A heart sent in this branch (`MeshMergedHeart`).
    case heart

    /// The 15-minute key rotation, fired branch-locally.
    case timerRotation

    /// A signed removal vote opened in this branch, against a member of another branch.
    ///
    /// - Parameter withQuorum: Whether the branch casts enough distinct votes to reach §10.4's
    ///   threshold **on the merged roster**. `false` is the incomplete proposal that must leave no
    ///   trace anywhere.
    case removalVote(withQuorum: Bool)

    /// A member of this branch develops and leaves (`leaveSessionAfterNotifyingPeers`).
    case departure

    /// A partition of one runs plan §8.2's 30-minute window out to `localIdleStop`.
    case idleLapse

    /// A development is planned against the **merged** roster (`MeshDevelopmentPlan`), which in a
    /// roster larger than two must be a departure and never a termination.
    case finalPairAttempt

    /// This event's frozen English token. Logged and compared verbatim; never display copy.
    var token: String {
        switch self {
        case .photo: return "photo"
        case .text: return "text"
        case .heart: return "heart"
        case .timerRotation: return "timerRotation"
        case .removalVote(let withQuorum): return withQuorum ? "removalVoteQuorum" : "removalVoteShort"
        case .departure: return "departure"
        case .idleLapse: return "idleLapse"
        case .finalPairAttempt: return "finalPairAttempt"
        }
    }

    /// Every event a schedule can emit — the coverage target the matrix asserts it reached.
    static let vocabulary: [MeshScheduleEvent] = [
        .photo, .text, .heart, .timerRotation,
        .removalVote(withQuorum: true), .removalVote(withQuorum: false),
        .departure, .idleLapse, .finalPairAttempt
    ]
}

// MARK: - MeshScheduleStep

/// One event, in one branch, performed by one member.
nonisolated struct MeshScheduleStep: Equatable, Sendable {

    /// Which branch of the split runs it.
    let branch: Int

    /// Which member of that branch performs it, as an index into the branch's member list.
    let performer: Int

    /// What happens.
    let event: MeshScheduleEvent
}

// MARK: - MeshHealStep

/// One pairwise exchange of the heal, in the order the schedule heals in.
///
/// Order is part of the schedule rather than an implementation detail: a re-gossip is answered
/// **once per peer per session**, so a pair that exchanges before the other side has learned
/// anything is answered "we match" and is never asked again (ledger "(P4 i7)").
nonisolated struct MeshHealStep: Equatable, Sendable {

    /// One end, as a global member index.
    let near: Int

    /// The other end, as a global member index.
    let far: Int

    /// Whether this step joins two branches (as opposed to spreading inside one).
    ///
    /// Bridges come first and are never reordered; the intra-branch steps hang off a bridge anchor
    /// and may run in any order, which is what
    /// `MeshConvergencePropertyTests.pairwiseMergesCommuteAcrossThePartitionTree` exploits.
    let isBridge: Bool

    /// The unordered pair, so "each pair is used at most once" is one comparison.
    var unordered: Set<Int> { [near, far] }
}

// MARK: - MeshRemovalPlan

/// The removal vote a schedule runs: who proposes it, who it targets, and whether it completes.
nonisolated struct MeshRemovalPlan: Equatable, Sendable {

    /// The branch that opens the proposal — always a branch of at least two, so votes can be cast.
    let proposingBranch: Int

    /// The member proposed for removal, as a global index. **Never** in ``proposingBranch``:
    /// §10.4's "votes are valid for absent targets".
    let target: Int

    /// Whether the branch casts §10.4's ⌊|roster|/2⌋ + 1 distinct votes on the merged roster.
    let completes: Bool
}

// MARK: - MeshConvergenceSchedule

/// A whole cell of §16.2's matrix, decided by one seed: the split, the events, and the heal.
///
/// `Equatable` because replayability is asserted by comparing two generations of the same seed —
/// which is the only honest form of "the fixed seed is fixed".
nonisolated struct MeshConvergenceSchedule: Equatable, Sendable {

    /// The seed this schedule was generated from. Carried so a failure names its own replay.
    let seed: UInt64

    /// The partition shape.
    let shape: MeshPartitionShape

    /// The members of each branch, as global indices. A partition of `0..<shape.rosterSize`.
    let branches: [[Int]]

    /// The member that develops and leaves during the split, if the schedule runs a departure.
    let departingMember: Int?

    /// The removal vote, if the schedule runs one.
    let removal: MeshRemovalPlan?

    /// The events during the split, interleaved across branches.
    let steps: [MeshScheduleStep]

    /// The heal, as an ordered sequence of pairwise exchanges over the survivors.
    let heal: [MeshHealStep]

    /// The members still on the roster when the heal finishes — everybody minus the departed member
    /// and minus a completed removal's target.
    var survivors: [Int] {
        let gone = Set([departingMember, removal.flatMap { $0.completes ? $0.target : nil }].compactMap { $0 })
        return (0..<shape.rosterSize).filter { !gone.contains($0) }
    }

    /// The same schedule with the intra-branch half of the heal reversed.
    ///
    /// Still a **valid** heal: every intra step hangs off the same bridge anchor, so any order of
    /// them spreads the same records to the same members. Two valid orders converging on identical
    /// state is §10.3's "N-way merges need no special case", asserted rather than assumed.
    func withReversedIntraHeal() -> MeshConvergenceSchedule {
        let bridges = heal.filter(\.isBridge)
        let intra = heal.filter { !$0.isBridge }
        return MeshConvergenceSchedule(
            seed: seed, shape: shape, branches: branches, departingMember: departingMember,
            removal: removal, steps: steps, heal: bridges + intra.reversed()
        )
    }
}

// MARK: - MeshScheduleGenerator

/// Turns a seed into a ``MeshConvergenceSchedule``. Pure, bounded, and free of any clock.
nonisolated enum MeshScheduleGenerator {

    /// Generates the cell for one seed.
    ///
    /// - Parameters:
    ///   - seed: The fixed seed. Same seed ⇒ byte-identical schedule.
    ///   - shape: Which of §16.2's partition shapes to split into.
    ///   - preferQuorum: Whether the removal vote should reach §10.4's threshold where the shape
    ///     allows it. A `2/2` of a roster of four never can, whatever this says — which is the
    ///     arithmetic the cell is there to assert.
    static func schedule(
        seed: UInt64, shape: MeshPartitionShape, preferQuorum: Bool
    ) -> MeshConvergenceSchedule {
        var random = MeshScheduleRandom(seed: seed)
        let branches = partition(shape: shape, using: &random)
        let removal = planRemoval(branches: branches, shape: shape, preferQuorum: preferQuorum, using: &random)
        let departing = planDeparture(branches: branches, shape: shape, removal: removal, using: &random)
        var lists: [[MeshScheduleStep]] = []
        for index in branches.indices {
            lists.append(events(
                branch: index, members: branches[index], shape: shape,
                removal: removal, departing: departing, using: &random
            ))
        }
        let steps = interleave(lists, using: &random)
        let gone = Set([departing, removal.flatMap { $0.completes ? $0.target : nil }].compactMap { $0 })
        let survivors = (0..<shape.rosterSize).filter { !gone.contains($0) }
        return MeshConvergenceSchedule(
            seed: seed, shape: shape, branches: branches, departingMember: departing,
            removal: removal, steps: steps,
            heal: healSteps(branches: branches, survivors: Set(survivors), using: &random)
        )
    }

    /// Shuffles the roster and deals it into the shape's branch sizes.
    private static func partition(
        shape: MeshPartitionShape, using random: inout MeshScheduleRandom
    ) -> [[Int]] {
        let shuffled = random.shuffled(Array(0..<shape.rosterSize))
        var branches: [[Int]] = []
        var cursor = 0
        for size in shape.branchSizes.prefix(MeshScheduleBounds.maxBranches) {
            let upper = min(cursor + size, shuffled.count)
            branches.append(Array(shuffled[cursor..<upper]))
            cursor = upper
        }
        return branches
    }

    /// Picks the branch that proposes, and the member of another branch it proposes against.
    ///
    /// The proposer is the **largest** branch, and the target sits in the **smallest** other branch,
    /// which is what makes a `3/1` propose against the isolated member — §10.4's own consequence.
    private static func planRemoval(
        branches: [[Int]], shape: MeshPartitionShape, preferQuorum: Bool,
        using random: inout MeshScheduleRandom
    ) -> MeshRemovalPlan? {
        let candidates = branches.indices.filter { branches[$0].count >= 2 }
        guard let largest = candidates.max(by: { branches[$0].count < branches[$1].count }) else {
            return nil
        }
        let others = branches.indices.filter { $0 != largest && !branches[$0].isEmpty }
        guard let smallest = others.min(by: { branches[$0].count < branches[$1].count }) else {
            return nil
        }
        let pool = branches[smallest]
        let target = pool[random.index(below: pool.count)]
        let completes = preferQuorum && branches[largest].count >= shape.quorumThreshold
        return MeshRemovalPlan(proposingBranch: largest, target: target, completes: completes)
    }

    /// Picks the member that leaves, or nil when a departure would take the roster below three.
    ///
    /// Below three there is no honest departure left to test: `MeshDevelopmentPlan` turns a final
    /// pair's development into a **termination**, which is item 6's subject and not this one's.
    private static func planDeparture(
        branches: [[Int]], shape: MeshPartitionShape, removal: MeshRemovalPlan?,
        using random: inout MeshScheduleRandom
    ) -> Int? {
        let afterRemoval = shape.rosterSize - ((removal?.completes ?? false) ? 1 : 0)
        guard afterRemoval - 1 >= 2 else { return nil }
        let eligible = branches.indices.filter { branches[$0].count >= 2 }
        guard !eligible.isEmpty else { return nil }
        let branch = eligible[random.index(below: eligible.count)]
        // The proposer never leaves mid-vote: its branch's first member opens the proposal, and a
        // proposer that departs would make the vote's own arithmetic the subject instead.
        let pool = branch == removal?.proposingBranch
            ? Array(branches[branch].dropFirst())
            : branches[branch]
        guard !pool.isEmpty else { return nil }
        return pool[random.index(below: pool.count)]
    }

    /// One branch's events: a seeded permutation of everything applicable to it, with the departure
    /// forced last because a departed member takes no further part.
    private static func events(
        branch: Int, members: [Int], shape: MeshPartitionShape,
        removal: MeshRemovalPlan?, departing: Int?, using random: inout MeshScheduleRandom
    ) -> [MeshScheduleStep] {
        var kinds: [MeshScheduleEvent] = []
        if producesContent(members: members, removal: removal) { kinds += [.photo, .text, .heart] }
        kinds += [.timerRotation, .timerRotation]
        if let removal, removal.proposingBranch == branch {
            kinds.append(.removalVote(withQuorum: removal.completes))
        }
        if members.count == 1 { kinds.append(.idleLapse) }
        kinds.append(.finalPairAttempt)
        var ordered = random.shuffled(kinds)
        let leaver = departing.flatMap { members.firstIndex(of: $0) }
        if leaver != nil { ordered.append(.departure) }
        return ordered.prefix(MeshScheduleBounds.maxEventsPerBranch).map { event in
            MeshScheduleStep(
                branch: branch,
                performer: performer(for: event, members: members, leaver: leaver, using: &random),
                event: event
            )
        }
    }

    /// Which member of the branch performs one event.
    private static func performer(
        for event: MeshScheduleEvent, members: [Int], leaver: Int?,
        using random: inout MeshScheduleRandom
    ) -> Int {
        let drawn = random.index(below: members.count)
        switch event {
        case .departure: return leaver ?? drawn
        case .removalVote: return 0   // the branch's first member opens every proposal
        default: return drawn
        }
    }

    /// Whether a branch creates content: everything except a branch the schedule removes whole.
    ///
    /// A lone member that a quorum removes never merges with anybody, so content created there
    /// could not reach a survivor — and "no content loss" would become a claim with an exception in
    /// it. The generator declines to create the exception instead of the checker excusing it.
    private static func producesContent(members: [Int], removal: MeshRemovalPlan?) -> Bool {
        guard let removal, removal.completes else { return true }
        return members != [removal.target]
    }

    /// Interleaves the branches' event lists into one bounded, seeded sequence.
    private static func interleave(
        _ lists: [[MeshScheduleStep]], using random: inout MeshScheduleRandom
    ) -> [MeshScheduleStep] {
        var queues = lists
        var merged: [MeshScheduleStep] = []
        let total = min(lists.reduce(0) { $0 + $1.count }, MeshScheduleBounds.maxSteps)
        for _ in 0..<total {
            let ready = queues.indices.filter { !queues[$0].isEmpty }
            guard !ready.isEmpty else { break }
            let pick = ready[random.index(below: ready.count)]
            merged.append(queues[pick].removeFirst())
        }
        return merged
    }

    /// The heal: one bridge between consecutive branches, then every branch's remaining survivors
    /// hanging off their own branch's anchor, in a seeded order.
    private static func healSteps(
        branches: [[Int]], survivors: Set<Int>, using random: inout MeshScheduleRandom
    ) -> [MeshHealStep] {
        var anchors: [(branch: Int, member: Int)] = []
        for index in branches.indices {
            let living = branches[index].filter { survivors.contains($0) }
            guard !living.isEmpty else { continue }
            anchors.append((index, living[random.index(below: living.count)]))
        }
        var bridges: [MeshHealStep] = []
        for position in anchors.indices.dropFirst() {
            bridges.append(MeshHealStep(
                near: anchors[position - 1].member, far: anchors[position].member, isBridge: true
            ))
        }
        var intra: [MeshHealStep] = []
        for anchor in anchors {
            for member in branches[anchor.branch]
            where member != anchor.member && survivors.contains(member) {
                intra.append(MeshHealStep(near: anchor.member, far: member, isBridge: false))
            }
        }
        return Array((bridges + random.shuffled(intra)).prefix(MeshScheduleBounds.maxHealSteps))
    }
}

// MARK: - MeshConvergenceSeeds

/// The **fixed** seeds §16.2's property test runs. Nothing here is drawn at run time.
///
/// Launcher §6: *"the convergence property test must run its fixed seed in CI — a randomized seed is
/// a flake generator, not a property test."* One root constant, and a small family derived from it
/// by the same SplitMix64 mix the generator uses, so the family is itself replayable from the root.
nonisolated enum MeshConvergenceSeeds {

    /// The root seed. Change it and every cell changes; a failure is replayed by pinning it.
    static let root: UInt64 = 0x00F3_2B1C_0009_0002

    /// How many derived seeds the matrix runs per cell.
    static let derivedCount = 8

    /// The fixed family: `root`, then `derivedCount - 1` successors of the same generator.
    static let family: [UInt64] = {
        var random = MeshScheduleRandom(seed: root)
        var seeds: [UInt64] = [root]
        for _ in 1..<derivedCount { seeds.append(random.next()) }
        return seeds
    }()
}

// MARK: - MeshConvergenceScheduleTests

/// The generator's own properties: replayable, bounded, and a heal that is a valid spanning walk.
///
/// These run with no manager, no store and no transport — if any of them fails, every cell in
/// `MeshConvergencePropertyTests` is testing something other than what it says it is.
@MainActor
@Suite(.serialized)
struct MeshConvergenceScheduleTests {

    /// Every (shape, quorum-preference, seed) cell iteration A generates.
    private func allCells() -> [MeshConvergenceSchedule] {
        var cells: [MeshConvergenceSchedule] = []
        for shape in MeshPartitionShape.iterationA {
            for preferQuorum in [true, false] {
                for seed in MeshConvergenceSeeds.family {
                    cells.append(MeshScheduleGenerator.schedule(
                        seed: seed, shape: shape, preferQuorum: preferQuorum
                    ))
                }
            }
        }
        return cells
    }

    /// **The fixed seed is fixed.** Generating twice from one seed yields an identical schedule,
    /// and different seeds do not all collapse onto one.
    @Test func sameSeedReplaysAnIdenticalSchedule() {
        for shape in MeshPartitionShape.allCases {
            let first = MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: true
            )
            let second = MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: true
            )
            #expect(first == second, "\(shape.rawValue): one seed, one schedule")
        }
        let variants = Set(MeshConvergenceSeeds.family.map {
            MeshScheduleGenerator.schedule(seed: $0, shape: .twoTwo, preferQuorum: false).steps
                .map(\.event.token).joined(separator: ",")
        })
        #expect(variants.count > 1, "eight seeds that produced one schedule would be no property test")
        #expect(Set(MeshConvergenceSeeds.family).count == MeshConvergenceSeeds.derivedCount,
                "the derived family must not repeat a seed")
    }

    /// **Bounded (R2).** Every list stays inside ``MeshScheduleBounds``, and the branches are a
    /// genuine partition of the roster.
    @Test func everyScheduleStaysInsideItsBounds() {
        for cell in allCells() {
            #expect(cell.steps.count <= MeshScheduleBounds.maxSteps)
            #expect(cell.heal.count <= MeshScheduleBounds.maxHealSteps)
            #expect(cell.branches.count <= MeshScheduleBounds.maxBranches)
            let members = cell.branches.flatMap { $0 }
            #expect(Set(members).count == cell.shape.rosterSize, "no member is in two branches")
            #expect(members.sorted() == Array(0..<cell.shape.rosterSize), "and none is missing")
            #expect(cell.branches.map(\.count) == cell.shape.branchSizes,
                    "\(cell.shape.rawValue): the deal matches the shape")
            let contentTokens = Set([MeshScheduleEvent.photo, .text, .heart].map(\.token))
            for index in cell.branches.indices {
                let mine = cell.steps.filter { $0.branch == index }
                #expect(mine.count <= MeshScheduleBounds.maxEventsPerBranch)
                #expect(mine.filter { contentTokens.contains($0.event.token) }.count
                        <= MeshScheduleBounds.maxContentPerBranch,
                        "a branch stays far below the smallest content-set capacity")
            }
        }
    }

    /// **The heal is an ordered spanning walk over the survivors**, and no pair is used twice —
    /// which is what a once-per-peer-per-session re-gossip requires of it.
    @Test func theHealSpansEverySurvivorAndSpendsEachPairOnce() {
        for cell in allCells() {
            var pairs: Set<Set<Int>> = []
            for step in cell.heal {
                #expect(pairs.insert(step.unordered).inserted,
                        "seed \(cell.seed): a pair may be asked once per session")
                #expect(step.near != step.far)
            }
            let bridgeCount = cell.heal.prefix { $0.isBridge }.count
            #expect(cell.heal.filter(\.isBridge).count == bridgeCount, "bridges come first")
            var reached: Set<Int> = cell.heal.first.map { [$0.near] } ?? []
            for step in cell.heal where reached.contains(step.near) || reached.contains(step.far) {
                reached.formUnion([step.near, step.far])
            }
            let survivors = Set(cell.survivors)
            #expect(reached == survivors || survivors.count <= 1,
                    "seed \(cell.seed) \(cell.shape.rawValue): every survivor must be reached in order")
        }
    }

    /// **The vocabulary is covered.** Every event in §16.2's list is emitted somewhere in iteration
    /// A's matrix — a cell family that quietly stopped producing departures would otherwise pass.
    @Test func iterationAsMatrixEmitsEveryEventInTheVocabulary() {
        var seen: Set<String> = []
        for cell in allCells() { seen.formUnion(cell.steps.map(\.event.token)) }
        for event in MeshScheduleEvent.vocabulary {
            #expect(seen.contains(event.token), "iteration A never emits \(event.token)")
        }
    }

    /// **§10.4's arithmetic, at the plan level.** A quorum is only ever claimed where the branch
    /// really holds ⌊|roster|/2⌋ + 1 members, so `2/2` of a roster of four can never complete one.
    @Test func aRemovalOnlyCompletesWhereTheBranchActuallyHoldsAQuorum() {
        for cell in allCells() {
            guard let removal = cell.removal else { continue }
            let branch = cell.branches[removal.proposingBranch]
            #expect(!branch.contains(removal.target), "the target is never in the proposing branch")
            if removal.completes {
                #expect(branch.count >= cell.shape.quorumThreshold,
                        "\(cell.shape.rawValue): a completing vote needs a real quorum")
            }
            if cell.shape == .twoTwo {
                #expect(!removal.completes, "roster 4 split 2/2 moderates nobody (§10.4)")
            }
        }
        #expect(MeshPartitionShape.allCases.allSatisfy { $0.branchSizes.reduce(0, +) == $0.rosterSize })
        #expect(MeshPartitionShape.fourTwoTwo.branchSizes.count == 3, "the only three-branch shape")
    }
}
