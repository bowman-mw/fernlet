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
//
// **P5 item 14 adds a second, salted plan and no new base draw.** `MeshRoutedScheduleOverlay` is
// the routed delivery vocabulary — custody, receipts, capacity, developments, locked windows,
// replays, unknown types — planned from `seed ^ routedSalt`, in the idiom `resplit(for:)` already
// uses. Deliberately **not** a new `MeshScheduleEvent` case (D-14.1): one more element in `kinds`
// is one more swap draw plus one more performer draw, which re-phases `interleave` and `healSteps`
// for every shape and seed and voids P4's §10.10 evidence and its named regression fixtures.
// Everything above `healSteps` is untouched by item 14; `MeshRoutedDrainConvergenceTests` executes
// the overlay.

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

    /// How many times the settle sweeps the healed graph.
    ///
    /// The widest shape §16.2 names is `4/2/2`, whose ordered heal is a chain of three branch stars:
    /// a leaf of the first branch reaches a leaf of the third in four hops. A sweep walks every heal
    /// step in order, so in the worst ordering it advances one hop — four sweeps flood the widest
    /// graph and the last two are headroom. Raised from four in iteration B for exactly that reason:
    /// rosters 6 and 8 are wider than rosters 3 and 4, not because a bound was inconvenient.
    static let maxSettleSweeps = 6

    /// The most events one **sub-branch** of a nested re-split runs: its own branch-local rotation
    /// and one content item. Deliberately tiny — the re-split is about the *merge window*, and a
    /// long event list inside it would only re-run the split phase's own coverage.
    static let maxResplitEventsPerSide = 2

    /// How many sides a nested re-split cuts the survivors into.
    ///
    /// Two, and a third would prove nothing new: `abandonMergeExchange` is a property of **one**
    /// cut (`next == .partitioned`), and the head cap is reached by everyone-alone, which the
    /// original split's branch count already dominates.
    static let maxResplitSides = 2

    /// How many commit rounds the full-mesh phase runs before it gives up.
    ///
    /// **Two, and the number survived P5 item 7 while its justification did not.** P4's argument was
    /// that a device inside an open merge window opens no second exchange and that window closes
    /// only on a matching digest, so the first round closed the ordered heal's windows and the
    /// second delivered the heads they were holding — and that raising the ceiling changed nothing
    /// because a mesh in which *every* member is awaiting opened no exchange at all.
    ///
    /// Both halves are now false in their details. A device inside a window still asks every later
    /// reconnect (`askOneReconnectedPeer`, P4 item 9b), and the responder side *can* close: a fold
    /// that moves the local digest re-advertises it to the peers the window still owes, so a mesh in
    /// which every member is awaiting still makes progress on its own frames (P5 item 7's proof
    /// door). What has not changed is why two is enough: the phase exits the moment §10.3's `max`
    /// agrees at every member, a cell that converges in one round costs one, and the second round is
    /// what carries the heads a first-round exchange could not.
    ///
    /// This is an assertion, not a knob (`everyScheduleStaysInsideItsBounds`). Raising it needs its
    /// own written note, in the idiom P4 used raising `maxSettleSweeps` from 4 to 6.
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
/// for a `3/1` of a roster of six. That is also why the enum is **closed at §16.2's own list**
/// (`2/2, 3/1, 3/3, 4/2/2`, plus ``twoOne`` as roster 3's analogue of `2/2`): §16.2's four rosters
/// map onto it exactly — 3 → `2/1`, 4 → `2/2` and `3/1`, 6 → `3/3`, 8 → `4/2/2` — and a `3/1` of a
/// roster of six would be a shape the plan does not name, invented by the test rather than asked
/// for by it. Iteration A ran ``twoOne``, ``twoTwo`` and ``threeOne``; iteration B adds
/// ``threeThree`` and ``fourTwoTwo``, which needed no generator change (it already handled any
/// number of branches) and no new bound beyond ``MeshScheduleBounds/maxSettleSweeps``.
nonisolated enum MeshPartitionShape: String, Equatable, Sendable, CaseIterable {

    /// Roster 3 split 2/1 — the roster-3 analogue of `2/2`, and the smallest shape with a majority
    /// branch that can reach quorum (3 → quorum 2).
    case twoOne

    /// Roster 4 split 2/2 — §10.4's worked example: quorum 3, so **neither branch can moderate**.
    case twoTwo

    /// Roster 4 split 3/1 — quorum 3, so the majority branch can remove the isolated member.
    case threeOne

    /// Roster 6 split 3/3 — quorum 4, so **neither** branch of three can moderate. **Iteration B.**
    case threeThree

    /// Roster 8 split 4/2/2 — the only three-branch shape. Quorum 5, so the branch of four is still
    /// one vote short: §10.4's arithmetic refuses the largest branch §16.2 names. **Iteration B.**
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

    /// The shapes iteration A ran — rosters 3 and 4. Named so the matrix and this file cannot drift
    /// apart.
    static let iterationA: [MeshPartitionShape] = [.twoOne, .twoTwo, .threeOne]

    /// The shapes iteration B adds — rosters 6 and 8, which is what makes §16.2's roster list whole.
    static let iterationB: [MeshPartitionShape] = [.threeThree, .fourTwoTwo]

    /// Every shape the matrix runs. `allCases` in the order the two iterations added them, asserted
    /// to be exactly `allCases` so a case added later cannot sit outside the matrix.
    static let matrix: [MeshPartitionShape] = iterationA + iterationB
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

    /// The same schedule with the departure moved to **just before** its branch's removal vote.
    ///
    /// The generator forces the departure last for the reason its own documentation gives — a
    /// departed member takes no further part, so a schedule that let it act afterwards would be
    /// asserting on a member that is gone. This transform lifts exactly that one constraint, for
    /// exactly one claim: §10.4's *"after a departure shrinks roster 4 → 3, quorum drops to 2"*,
    /// re-derived at the **manager** seam rather than at the model seam
    /// (`MeshQuorumPartitionTests.rosterTwoCannotModerateAndADepartureRestoresAPairsPower` is the
    /// model half). Nothing downstream moves: the leaver, the target and the heal were all planned
    /// before the events were ordered, so the survivors and the spanning walk are untouched.
    ///
    /// A no-op unless the schedule runs both a departure and a vote, with the vote first.
    func withDepartureBeforeTheVote() -> MeshConvergenceSchedule {
        guard let removal else { return self }
        let voteAt = steps.firstIndex {
            if case .removalVote = $0.event { return $0.branch == removal.proposingBranch }
            return false
        }
        guard let voteAt, let departureAt = steps.firstIndex(where: { $0.event == .departure }),
              departureAt > voteAt else { return self }
        var moved = steps
        moved.insert(moved.remove(at: departureAt), at: voteAt)
        return MeshConvergenceSchedule(
            seed: seed, shape: shape, branches: branches, departingMember: departingMember,
            removal: removal, steps: moved, heal: heal
        )
    }
}

// MARK: - MeshResplitPlan

/// §16.2's fifth shape: a **nested re-split mid-merge**.
///
/// Not a partition shape — a partition shape splits a *whole* mesh before anything has merged. This
/// is the cut that lands **while §10.3's exchange is open**: the survivors have re-formed the full
/// mesh, every member is inside a merge window it has not concluded, and one healing branch is then
/// cut in two. `MeshNetworkManager.applySessionEvent` answers that with `abandonMergeExchange()` on
/// `next == .partitioned`, which is the behaviour this plan exists to drive.
///
/// The two sides are ``holdouts`` (a sub-branch of one original branch, cut off from everybody) and
/// ``rest`` (every other survivor, which stays internally whole). Two sides and no more —
/// ``MeshScheduleBounds/maxResplitSides``.
nonisolated struct MeshResplitPlan: Equatable, Sendable {

    /// Which branch of the original split is the one that re-splits.
    let branch: Int

    /// The members cut off from everybody else, as global indices. Never empty, never everybody.
    let holdouts: [Int]

    /// Every other survivor, as global indices. Never empty.
    let rest: [Int]

    /// The re-planned heal: one bridge between the two sides' anchors, then each side's remaining
    /// members hanging off their own anchor, in a seeded order.
    ///
    /// Planned fresh rather than replayed, because the first heal's walk is over the *branches* and
    /// this one is over the two **sides** — a different partition of the same survivors.
    let heal: [MeshHealStep]

    /// Both sides, in a fixed order, so a phase that has to act "once per side" is one loop.
    var sides: [[Int]] { [holdouts, rest] }

    /// Every survivor the re-split touches.
    var members: [Int] { holdouts + rest }

    /// The same plan with the intra-side half of its heal reversed — still a valid order, for the
    /// same reason ``MeshConvergenceSchedule/withReversedIntraHeal()`` is.
    func withReversedIntraHeal() -> MeshResplitPlan {
        let bridges = heal.filter(\.isBridge)
        let intra = heal.filter { !$0.isBridge }
        return MeshResplitPlan(
            branch: branch, holdouts: holdouts, rest: rest, heal: bridges + intra.reversed()
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

    // MARK: The nested re-split (iteration B)

    /// The salt the re-split's own generator is seeded from.
    ///
    /// A **separate** generator rather than more draws from the schedule's, so adding a re-split
    /// cannot re-phase a single draw of the base schedule: iteration A's 48 cells have to stay
    /// byte-identical, and one extra `random.next()` in `schedule(seed:shape:preferQuorum:)` would
    /// quietly rewrite all of them. Frozen constant, never displayed.
    static let resplitSalt: UInt64 = 0x5245_5350_4C49_5400

    /// Plans a nested re-split for an already-generated schedule.
    ///
    /// - Returns: nil when no branch has two survivors left to cut apart, which is the honest answer
    ///   for a schedule whose departures and removals emptied its wide branch.
    static func resplit(for schedule: MeshConvergenceSchedule) -> MeshResplitPlan? {
        var random = MeshScheduleRandom(seed: schedule.seed ^ resplitSalt)
        return resplit(for: schedule, using: &random)
    }

    /// The seeded half of ``resplit(for:)``.
    private static func resplit(
        for schedule: MeshConvergenceSchedule, using random: inout MeshScheduleRandom
    ) -> MeshResplitPlan? {
        let survivors = Set(schedule.survivors)
        func living(_ branch: Int) -> [Int] { schedule.branches[branch].filter(survivors.contains) }
        let candidates = schedule.branches.indices.filter { living($0).count >= 2 }
        guard let branch = candidates.max(by: { living($0).count < living($1).count }) else {
            return nil
        }
        let pool = living(branch)
        let cutSize = 1 + random.index(below: max(1, pool.count - 1))
        let holdouts = Array(random.shuffled(pool).prefix(cutSize)).sorted()
        let rest = schedule.survivors.filter { !holdouts.contains($0) }
        guard !holdouts.isEmpty, !rest.isEmpty else { return nil }
        return MeshResplitPlan(
            branch: branch, holdouts: holdouts, rest: rest,
            heal: resplitHeal(
                holdouts: holdouts, rest: rest, spent: Set(schedule.heal.map(\.unordered)),
                using: &random
            )
        )
    }

    /// The re-planned heal: bridge first, then each side's own star, in a seeded order.
    private static func resplitHeal(
        holdouts: [Int], rest: [Int], spent: Set<Set<Int>>, using random: inout MeshScheduleRandom
    ) -> [MeshHealStep] {
        let anchors = bridgeAnchors(holdouts: holdouts, rest: rest, spent: spent, using: &random)
        var intra: [MeshHealStep] = []
        for member in holdouts where member != anchors.near {
            intra.append(MeshHealStep(near: anchors.near, far: member, isBridge: false))
        }
        for member in rest where member != anchors.far {
            intra.append(MeshHealStep(near: anchors.far, far: member, isBridge: false))
        }
        let bridge = MeshHealStep(near: anchors.near, far: anchors.far, isBridge: true)
        return Array(([bridge] + random.shuffled(intra)).prefix(MeshScheduleBounds.maxHealSteps))
    }

    /// The pair that bridges the two sides, preferring one the **first** heal never used.
    ///
    /// `MeshNetworkManager.reGossipRecords(to:)` answers once per peer per *session*, and
    /// `abandonMergeExchange()` does not reset that (it clears the window, not the answered set).
    /// So where a fresh pair exists the re-plan spends it, and where none does the re-plan leans on
    /// the half of §10.3's exchange that has **no** once-per-peer gate — the epoch heads — which is
    /// why the sub-branch events mint no membership record. Both draws are taken unconditionally so
    /// the presence of a fresh pair cannot re-phase the rest of the plan.
    private static func bridgeAnchors(
        holdouts: [Int], rest: [Int], spent: Set<Set<Int>>, using random: inout MeshScheduleRandom
    ) -> (near: Int, far: Int) {
        let fallback = (
            near: holdouts[random.index(below: holdouts.count)],
            far: rest[random.index(below: rest.count)]
        )
        var fresh: [MeshHealStep] = []
        for near in holdouts.prefix(MeshPartitionFixtureBounds.maxMembers) {
            for far in rest.prefix(MeshPartitionFixtureBounds.maxMembers)
            where !spent.contains([near, far]) {
                fresh.append(MeshHealStep(near: near, far: far, isBridge: true))
            }
        }
        let pick = fresh.isEmpty ? nil : fresh[random.index(below: fresh.count)]
        guard let pick else { return fallback }
        return (pick.near, pick.far)
    }

    // MARK: The routed overlay (P5 item 14)

    /// The salt P5's **routed overlay** is seeded from.
    ///
    /// A separate generator rather than more draws from the schedule's, for the reason
    /// ``resplitSalt`` gives and one more of its own (D-14.1): P4's 80 membership cells and their
    /// named regression fixtures are byte-identical to the seed they were found on, and one extra
    /// `random.next()` inside `schedule(seed:shape:preferQuorum:)` would quietly rewrite all of
    /// them. So the routed events are an overlay on the **same** seeds and the same five shapes,
    /// never a new ``MeshScheduleEvent`` case. Frozen constant, never displayed.
    static let routedSalt: UInt64 = 0x524F_5554_4544_0000

    /// Plans P5's routed side-schedule for an already-generated schedule.
    ///
    /// - Parameter schedule: The cell the overlay hangs off. Its survivors and branches decide
    ///   every resolution; its seed (salted) decides every draw.
    /// - Returns: the resolved overlay — never a raw draw, so ``MeshRoutedScheduleOverlay/plannedTokens``
    ///   is a pure function of the value.
    static func routedOverlay(for schedule: MeshConvergenceSchedule) -> MeshRoutedScheduleOverlay {
        var random = MeshScheduleRandom(
            seed: schedule.seed ^ routedSalt ^ routedShapeSalt(schedule.shape)
        )
        return routedOverlay(for: schedule, using: &random)
    }

    /// The shape's own contribution to the overlay seed.
    ///
    /// **Load-bearing, and it was found by a probe rather than reasoned out.** `resplit(for:)` can
    /// salt on the seed alone because its *resolution* is a function of the branches, so five shapes
    /// of one seed give five different plans out of one draw sequence. The routed overlay's first
    /// three fields — the chunk count and the sealed flag especially — are **not** functions of the
    /// branches, so seeding on the seed alone gave the 40-cell rectangle only **8 distinct plans**
    /// and the first probe found no cell at all carrying a multi-chunk opaque mint. Folding the
    /// shape in restores 40. Frozen constant, never displayed.
    private static func routedShapeSalt(_ shape: MeshPartitionShape) -> UInt64 {
        let ordinal = MeshPartitionShape.matrix.firstIndex(of: shape) ?? 0
        return 0x0101_0101_0101_0101 &* UInt64(ordinal + 1)
    }

    /// The seeded half of ``routedOverlay(for:)``.
    ///
    /// **Every draw is unconditional and every stored field is resolved.** A gate that passes with
    /// no legal subject stores nil; a `Bool` whose precondition the schedule cannot meet stores
    /// false. That is what stops a later field from re-phasing an earlier one, and what makes the
    /// coverage wall arithmetic over the built overlays rather than a second execution of them.
    private static func routedOverlay(
        for schedule: MeshConvergenceSchedule, using random: inout MeshScheduleRandom
    ) -> MeshRoutedScheduleOverlay {
        let survivors = schedule.survivors
        let originSlot = random.index(below: survivors.count)
        let origin = survivors.isEmpty ? 0 : survivors[originSlot]
        let chunks = 1 + random.index(below: 3)
        let sealed = random.index(below: 2) == 0
        let others = survivors.filter { $0 != origin }
        let capacity = routedSubject(others, gateBelow: 4, using: &random)
        let lock = routedSubject(others, gateBelow: 2, using: &random)
        let replayGate = random.index(below: 2) == 0
        let develops = random.index(below: 2) == 0 && routedCanDevelop(schedule, origin: origin)
        let unknown = routedSubject(others, gateBelow: 4, using: &random)
        // A replay needs a receiver that ALREADY admitted the manifest. Where this cell plants a
        // refusal at every one of its own live destinations, no receiver ever admits anything, and
        // a re-presented frame would be a FIRST admission dressed up as a replay — it would move
        // bytes and rungs legitimately, and I-11 would red for the one reason that is not a defect.
        // Resolved here rather than skipped at run time, so `plannedTokens` stays a pure function
        // of the overlay and the skip is visible in the coverage wall instead of in a cell.
        let blocked = !others.isEmpty
            && others.allSatisfy { $0 == capacity || $0 == unknown }
        let replays = replayGate && survivors.count >= 2 && !blocked
        return MeshRoutedScheduleOverlay(
            seed: schedule.seed, origin: origin, chunks: chunks, sealed: sealed,
            capacityMember: capacity, lockMember: lock, replays: replays, develops: develops,
            unknownTypeMember: unknown,
            farBranchMint: routedIsFarBranch(schedule, origin: origin)
        )
    }

    /// One optional subject over `pool`, drawn as **two** unconditional draws — one subject, one
    /// gate — and resolved to nil when the gate is shut or the pool is empty.
    private static func routedSubject(
        _ pool: [Int], gateBelow bound: Int, using random: inout MeshScheduleRandom
    ) -> Int? {
        let slot = random.index(below: pool.count)
        let open = random.index(below: bound) == 0
        guard open, !pool.isEmpty, pool.indices.contains(slot) else { return nil }
        return pool[slot]
    }

    /// Whether the ORIGIN can develop: only a device's own items are handed over at a departure
    /// (`MeshCustodyHandoffPlan`'s `originatedBy:`), so a drawn non-origin developer would transfer
    /// nothing and every hand-off claim would hold with the mechanism deleted.
    ///
    /// Its branch needs a second living member, because the branch drain that makes the transfer
    /// non-vacuous is what puts the ciphertext at a partner.
    private static func routedCanDevelop(_ schedule: MeshConvergenceSchedule, origin: Int) -> Bool {
        guard schedule.departingMember != origin else { return false }
        let survivors = Set(schedule.survivors)
        guard let branch = schedule.branches.first(where: { $0.contains(origin) }) else { return false }
        return branch.filter(survivors.contains).count >= 2
    }

    /// Whether the mint lands in a branch **other** than the lowest-indexed survivor's.
    ///
    /// The rig's own "first survivor" is `livingMembers.first`, i.e. the lowest global index, so
    /// that member's branch is the near one and any other is a far-branch mint — the shape clause
    /// (k) is about, reached by field 1's own draw rather than by a second field.
    private static func routedIsFarBranch(_ schedule: MeshConvergenceSchedule, origin: Int) -> Bool {
        let survivors = schedule.survivors
        guard let near = survivors.first,
              let nearBranch = schedule.branches.firstIndex(where: { $0.contains(near) }),
              let originBranch = schedule.branches.firstIndex(where: { $0.contains(origin) })
        else { return false }
        return nearBranch != originBranch
    }
}

// MARK: - MeshRoutedEventToken

/// One event of **P5's own delivery vocabulary** — the overlay's counterpart to
/// ``MeshScheduleEvent``, kept deliberately separate from it (D-14.1).
///
/// §16.2's vocabulary is "events during split" for the *membership* property; custody, receipts,
/// backpressure, locked devices and replays are §11's *delivery* property, and folding them into
/// ``MeshScheduleEvent`` would re-phase every one of P4's 80 seeded cells. Frozen English tokens:
/// logged and compared verbatim, never display copy.
nonisolated enum MeshRoutedEventToken: String, CaseIterable, Equatable, Sendable {

    /// An opaque routed item minted at the origin (`routedCustodyEvent`).
    case custody

    /// A REAL sealed photo item minted at the origin (`routedSealedPhotoEvent`, item 13).
    case sealedItem

    /// The bounded full-mesh drain rounds (`runRoutedDrainRounds`, item 6).
    case receiptDrain

    /// One destination filled to its byte cap before the drain reaches it (item 9).
    case capacity

    /// The origin develops and hands custody on, mid-branch-drain (item 8).
    case development

    /// A gate closed across a drain and re-opened (`routedLockWindowEvent`, item 10).
    case lockWindow

    /// An already-admitted frame re-presented on a live link (`routedReplayEvent`, item 12).
    case replay

    /// One receiver whose registry does not know the item's type token (item 11).
    case unknownType

    /// The mint happened in a branch other than the lowest-indexed survivor's.
    case farBranchMint

    /// Every token an overlay can plan — the coverage target the rectangle asserts it reached.
    static let vocabulary: [String] = allCases.map(\.rawValue)
}

// MARK: - MeshRoutedScheduleOverlay

/// P5's routed side-plan for one already-generated ``MeshConvergenceSchedule`` — the whole of item
/// 14's event vocabulary, salted away from the base schedule so not one membership draw moves.
///
/// Every field is **resolved**, never raw: a gate that passed with no legal subject is nil, and a
/// flag whose precondition the schedule cannot meet is false. That is what makes ``plannedTokens``
/// a pure function of this value, which in turn is what lets the coverage wall be arithmetic over
/// the 40 built overlays instead of a second execution of them.
nonisolated struct MeshRoutedScheduleOverlay: Hashable, Sendable, CustomStringConvertible {

    /// The seed the overlay was salted from — carried so a failure names its own replay.
    let seed: UInt64

    /// The survivor that mints the item, as a global member index.
    let origin: Int

    /// How many chunks an opaque mint is sliced into, 1…3. Meaningless when ``sealed``, whose
    /// fixture does its own chunking.
    let chunks: Int

    /// Whether the mint is item 13's real sealed photo rather than an opaque blob.
    let sealed: Bool

    /// A non-origin survivor filled to its byte cap before the drain reaches it, or nil.
    let capacityMember: Int?

    /// A non-origin survivor whose access gate closes across a drain and re-opens, or nil.
    let lockMember: Int?

    /// Whether the cell re-presents one already-admitted frame after the heal.
    let replays: Bool

    /// Whether the origin develops mid-branch-drain (pipeline 2 only).
    let develops: Bool

    /// A non-origin survivor whose type registry does not know the item's token, or nil.
    let unknownTypeMember: Int?

    /// Whether the mint lands outside the lowest-indexed survivor's branch.
    let farBranchMint: Bool

    /// A replayable label: the seed and the resolved plan, in frozen English.
    var description: String {
        var text = "routed \(String(seed, radix: 16)) o\(origin) x\(chunks)"
        text += sealed ? " sealed" : " blob"
        if let capacityMember { text += " cap\(capacityMember)" }
        if let lockMember { text += " lock\(lockMember)" }
        if replays { text += " replay" }
        if develops { text += " develops" }
        if let unknownTypeMember { text += " unknown\(unknownTypeMember)" }
        if farBranchMint { text += " far" }
        return text
    }

    /// The tokens the **full-heal** pipeline executes — rectangles A, B, D, E and F.
    ///
    /// The development is deliberately absent: a development after a full heal and drain has no
    /// outstanding leg to hand, so it runs on its own pipeline and its own cells.
    var fullHealTokens: Set<String> {
        var tokens: Set<String> = [mintToken, MeshRoutedEventToken.receiptDrain.rawValue]
        if capacityMember != nil { tokens.insert(MeshRoutedEventToken.capacity.rawValue) }
        if lockMember != nil { tokens.insert(MeshRoutedEventToken.lockWindow.rawValue) }
        if replays { tokens.insert(MeshRoutedEventToken.replay.rawValue) }
        if unknownTypeMember != nil { tokens.insert(MeshRoutedEventToken.unknownType.rawValue) }
        if farBranchMint { tokens.insert(MeshRoutedEventToken.farBranchMint.rawValue) }
        return tokens
    }

    /// The tokens the **development** pipeline executes — rectangle C: mint, branch drain, depart.
    var developmentTokens: Set<String> {
        var tokens: Set<String> = [mintToken, MeshRoutedEventToken.development.rawValue]
        if farBranchMint { tokens.insert(MeshRoutedEventToken.farBranchMint.rawValue) }
        return tokens
    }

    /// Every token this overlay plans, across both pipelines — the coverage wall's generated side.
    var plannedTokens: Set<String> {
        develops ? fullHealTokens.union(developmentTokens) : fullHealTokens
    }

    /// Which mint this overlay plans.
    private var mintToken: String {
        sealed ? MeshRoutedEventToken.sealedItem.rawValue : MeshRoutedEventToken.custody.rawValue
    }
}

// MARK: - MeshPartitionFixtureBounds

/// The roster ceiling every loop over members is bounded by (Power of 10 R2), written from plan §9's
/// cap rather than from whatever a caller happened to pass.
nonisolated enum MeshPartitionFixtureBounds {

    /// Plan §9's roster cap, and the widest roster §16.2 names.
    static let maxMembers = 8
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

    /// Every (shape, quorum-preference, seed) cell the whole matrix generates — both iterations.
    private func allCells() -> [MeshConvergenceSchedule] {
        var cells: [MeshConvergenceSchedule] = []
        for shape in MeshPartitionShape.matrix {
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

    /// **The vocabulary is covered.** Every event in §16.2's list is emitted somewhere in the
    /// matrix — a cell family that quietly stopped producing departures would otherwise pass.
    @Test func theMatrixEmitsEveryEventInTheVocabulary() {
        var seen: Set<String> = []
        for cell in allCells() { seen.formUnion(cell.steps.map(\.event.token)) }
        for event in MeshScheduleEvent.vocabulary {
            #expect(seen.contains(event.token), "the matrix never emits \(event.token)")
        }
    }

    /// **The matrix is the whole enum.** A shape added to ``MeshPartitionShape`` and forgotten in
    /// ``MeshPartitionShape/matrix`` would be a row §16.2 asks for and nothing runs.
    @Test func everyDeclaredShapeIsInTheMatrix() {
        #expect(Set(MeshPartitionShape.matrix) == Set(MeshPartitionShape.allCases))
        #expect(MeshPartitionShape.matrix.count == MeshPartitionShape.allCases.count,
                "no shape is listed twice")
        #expect(MeshPartitionShape.iterationB.map(\.rosterSize) == [6, 8],
                "§16.2's rosters 6 and 8 are exactly 3/3 and 4/2/2")
        #expect(Set(MeshPartitionShape.matrix.map(\.rosterSize)) == [3, 4, 6, 8],
                "and the four rosters §16.2 names are all covered")
    }

    /// **The nested re-split is a valid second partition.** Two non-empty sides that together are
    /// the survivors, a heal that is a spanning walk over them, and every pair spent once.
    @Test func theNestedResplitCutsTheSurvivorsInTwoAndHealsThemBack() {
        var planned = 0
        for cell in allCells() {
            guard let plan = MeshScheduleGenerator.resplit(for: cell) else { continue }
            planned += 1
            let survivors = Set(cell.survivors)
            #expect(!plan.holdouts.isEmpty && !plan.rest.isEmpty, "a cut has two sides")
            #expect(Set(plan.members) == survivors, "and together they are the survivors, exactly")
            #expect(plan.members.count == survivors.count, "with nobody counted twice")
            #expect(Set(plan.holdouts).isSubset(of: Set(cell.branches[plan.branch])),
                    "seed \(cell.seed): the holdouts come out of ONE branch (§16.2's 'nested')")
            #expect(plan.heal.count <= MeshScheduleBounds.maxHealSteps)
            #expect(plan.heal.filter(\.isBridge).count == 1, "two sides need exactly one bridge")
            var pairs: Set<Set<Int>> = []
            var reached: Set<Int> = plan.heal.first.map { [$0.near] } ?? []
            for step in plan.heal {
                #expect(pairs.insert(step.unordered).inserted, "each pair once per heal window")
                #expect(step.near != step.far)
                if reached.contains(step.near) || reached.contains(step.far) {
                    reached.formUnion([step.near, step.far])
                }
            }
            #expect(reached == survivors || survivors.count <= 1,
                    "seed \(cell.seed): the re-plan must reach every survivor in order")
        }
        #expect(planned > 0, "no cell could be re-split, so the plan asserts nothing")
    }

    /// **The re-split is replayable and does not re-phase the base schedule.** Same seed, same
    /// plan; and the schedule the plan was taken from is byte-identical to one generated without it.
    @Test func theResplitPlanIsReplayableAndSaltedAwayFromTheSchedule() {
        for shape in MeshPartitionShape.matrix {
            let cell = MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: false
            )
            #expect(MeshScheduleGenerator.resplit(for: cell)
                    == MeshScheduleGenerator.resplit(for: cell), "one seed, one re-split")
            #expect(MeshScheduleGenerator.schedule(
                seed: MeshConvergenceSeeds.root, shape: shape, preferQuorum: false
            ) == cell, "\(shape.rawValue): planning a re-split moved no draw of the base schedule")
        }
    }

    /// **The departure-before-the-vote transform reorders and nothing else.** Same multiset of
    /// steps, same heal, same survivors — only the position of the departure moves.
    @Test func movingTheDepartureAheadOfTheVoteChangesOnlyTheOrder() {
        var moved = 0
        for cell in allCells() {
            let reordered = cell.withDepartureBeforeTheVote()
            #expect(reordered.steps.count == cell.steps.count)
            #expect(reordered.steps.map(\.event.token).sorted()
                    == cell.steps.map(\.event.token).sorted(), "the same events, reordered")
            #expect(reordered.heal == cell.heal && reordered.survivors == cell.survivors)
            guard reordered.steps != cell.steps,
                  let departureAt = reordered.steps.firstIndex(where: { $0.event == .departure }),
                  let voteAt = reordered.steps.firstIndex(where: {
                      if case .removalVote = $0.event { return true }
                      return false
                  }) else { continue }
            moved += 1
            #expect(departureAt < voteAt, "seed \(cell.seed): the departure now runs first")
        }
        #expect(moved > 0, "no cell was reordered, so the transform asserts nothing")
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
