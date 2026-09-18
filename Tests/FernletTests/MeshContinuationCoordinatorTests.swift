// MeshContinuationCoordinatorTests.swift
// FernletTests
//
// Network migration P8 item 4: `MeshContinuationCoordinator`'s table over the FULL state × event
// product, and the progress arithmetic beside it. No simulator, no clock, no radio, no task.
//
// The table is the artefact. `MeshContinuationProduct.rows()` enumerates all 6 × 8 = 48 rows from
// the enums' own `allCases`, so a new state or event widens the pinned count deliberately and a
// dropped dimension collapses the set visibly. Over that product the suite states every claim the
// coordinator makes — a delivered task is always adopted, a new mesh resets the claim and completes
// the stale task `false`, a request the system never ran is refused rather than expired, a withdrawn
// request resets to `idle` so a re-committing peer can re-arm it, a foreground return spends the task
// but not the claim, the three quiescent states feed what the run policy already treats as one row —
// and above all the ONE invariant iOS enforces:
//
//     completion != nil  ⟺  (from == .running && next != .running)
//
// The mirror oracle is transposed on purpose: the production table switches state → event, and
// `expectedNext` / `expectedCompletion` / `expectedAudit` switch event → state. Two different
// decompositions of the same 48 cells must agree, so a slip in either is visible rather than
// mirrored.
//
// `everyBoundedPathCompletesOncePerDeliveredTask` is the exactly-once sweep: every event sequence up
// to `maxSweepDepth` events from every starting state (4 680 sequences × 6 starts), asserting
// `completions == entriesIntoRunning - (endsRunning ? 1 : 0)` — one completion per ENTRY INTO
// `running`, no more and no fewer, with at most the in-flight one outstanding. That is what the walk
// counts and what the row oracle proves; it equals one completion per DELIVERED task only because
// item 6 registers one identifier, so a second delivery while one is in hand cannot arrive (and is
// absorbed, uncounted, if it ever does). The cell keeps its older name; this is what it holds.
//
// `-only-testing:` names a SUITE, so this file answers to two names:
// `MeshContinuationCoordinatorTests` and `MeshContinuationProgressTests`.
//
// House rules, from `ProximityRunPolicyTests`: `#expect(_, "one literal")` only, every `allSatisfy`
// bound to a `let` first, no `@Test(arguments: [])`, no rig, no clock, no RNG.

import Foundation
import Testing
@testable import Fernlet

// MARK: - MeshContinuationProduct

/// The whole state × event product, enumerated dimension by dimension so no row can be skipped by a
/// typo, plus the transposed mirror oracles and the bounded path sweep.
enum MeshContinuationProduct {

    /// One row of the product.
    struct Row: Hashable, Sendable {

        /// Where the claim stands.
        let state: MeshContinuationState

        /// What happened.
        let event: MeshContinuationEvent
    }

    /// The size of the product: 6 states × 8 events.
    static let count = 6 * 8

    /// The longest event sequence the exactly-once sweep walks.
    ///
    /// Four is the bound, stated as a constant because Power of 10 rule 2 wants every loop bounded by
    /// one: 8 + 64 + 512 + 4 096 = 4 680 sequences per starting state, 28 080 walks in all. Four
    /// events is enough to leave and re-enter ``MeshContinuationState/running`` twice, which is the
    /// shape the invariant is about.
    static let maxSweepDepth = 4

    /// Every row of the product.
    static func rows() -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for state in MeshContinuationState.allCases {
            for event in MeshContinuationEvent.allCases {
                rows.append(Row(state: state, event: event))
            }
        }
        return rows
    }

    /// The coordinator's answer for a row.
    static func outcome(_ row: Row) -> MeshContinuationOutcome {
        MeshContinuationCoordinator.transition(from: row.state, on: row.event)
    }

    // MARK: The transposed mirror

    /// Where a row lands, re-stated event-first.
    static func expectedNext(_ row: Row) -> MeshContinuationState {
        switch row.event {
        case .meshStarted:
            return .idle
        case .firstPeerCommitted:
            return row.state == .idle ? .requested : row.state
        case .taskStarted:
            return .running
        case .taskRefused:
            return row.state == .requested ? .refused : row.state
        case .taskExpired:
            return expectedAfterExpiry(row.state)
        case .taskCancelled:
            return expectedAfterCancel(row.state)
        case .sessionEnded:
            return row.state == .idle ? .idle : .completed
        case .appForegrounded:
            return row.state == .running ? .requested : row.state
        }
    }

    /// An expiry refuses a request the system never ran and ends a delivered task.
    private static func expectedAfterExpiry(_ state: MeshContinuationState) -> MeshContinuationState {
        switch state {
        case .requested: return .refused
        case .running: return .expired
        case .idle, .refused, .expired, .completed: return state
        }
    }

    /// A cancel WITHDRAWS a pending request — nothing was granted, so the claim resets and may
    /// re-arm — and ends a delivered task.
    private static func expectedAfterCancel(_ state: MeshContinuationState) -> MeshContinuationState {
        switch state {
        case .requested: return .idle
        case .running: return .expired
        case .idle, .refused, .expired, .completed: return state
        }
    }

    /// What the run policy is fed after a row, stated independently of the production `feed`
    /// property: it switches on the MIRROR's landing and spells the mapping out by hand, so a wrong
    /// row and a wrong mapping are both visible here. Only a live delivered task is a background
    /// claim; a refusal and an expiry are fed as themselves, for item 7's card; the rest ask for
    /// nothing.
    static func expectedFeed(_ row: Row) -> ProximityContinuationState {
        switch expectedNext(row) {
        case .running: return .running
        case .refused: return .refused
        case .expired: return .expired
        case .idle, .requested, .completed: return .notRequested
        }
    }

    /// The completion a row owes, re-stated flat: only a delivered task owes one.
    static func expectedCompletion(_ row: Row) -> MeshContinuationCompletion? {
        guard row.state == .running else { return nil }
        switch row.event {
        case .meshStarted, .taskExpired, .taskCancelled: return .failed
        case .sessionEnded, .appForegrounded: return .succeeded
        case .firstPeerCommitted, .taskStarted, .taskRefused: return nil
        }
    }

    /// The token a row records, re-stated event-first.
    static func expectedAudit(_ row: Row) -> MeshContinuationAudit {
        switch row.event {
        case .meshStarted: return row.state == .idle ? .registered : .meshChanged
        case .firstPeerCommitted: return row.state == .idle ? .submitted : .absorbed
        case .taskStarted: return row.state == .running ? .absorbed : .started
        case .taskRefused: return row.state == .requested ? .refused : .absorbed
        case .taskExpired: return pendingOrRunning(row.state) ? .expired : .absorbed
        case .taskCancelled: return pendingOrRunning(row.state) ? .cancelled : .absorbed
        case .sessionEnded: return endedIsAMove(row.state) ? .completed : .absorbed
        case .appForegrounded: return row.state == .running ? .completed : .absorbed
        }
    }

    /// The two states an expiry or a cancel actually moves.
    private static func pendingOrRunning(_ state: MeshContinuationState) -> Bool {
        state == .requested || state == .running
    }

    /// The states a session ending moves — everything but rest and a spent claim.
    private static func endedIsAMove(_ state: MeshContinuationState) -> Bool {
        state != .idle && state != .completed
    }

    // MARK: The bounded sweep

    /// What one walked path did.
    struct Walk: Equatable, Sendable {

        /// How many completions the path fired.
        let completions: Int

        /// How many delivered tasks the path took on, counting a start already in
        /// ``MeshContinuationState/running``.
        let entriesIntoRunning: Int

        /// Whether the path ends with a delivered task still in hand.
        let endsRunning: Bool
    }

    /// Walks one event sequence from one starting state.
    static func walk(from start: MeshContinuationState, events: [MeshContinuationEvent]) -> Walk {
        var state = start
        var completions = 0
        var entries = start == .running ? 1 : 0
        for event in events {
            let outcome = MeshContinuationCoordinator.transition(from: state, on: event)
            if outcome.completion != nil { completions += 1 }
            if state != .running && outcome.next == .running { entries += 1 }
            state = outcome.next
        }
        return Walk(completions: completions, entriesIntoRunning: entries, endsRunning: state == .running)
    }

    /// Every event sequence of exactly `depth` events, as base-8 counting over the alphabet — no
    /// recursion, and both loops bounded by ``maxSweepDepth`` and the alphabet's size.
    static func sequences(depth: Int) -> [[MeshContinuationEvent]] {
        let alphabet = MeshContinuationEvent.allCases
        var total = 1
        for _ in 0..<depth { total *= alphabet.count }
        var out: [[MeshContinuationEvent]] = []
        out.reserveCapacity(total)
        for index in 0..<total {
            var sequence: [MeshContinuationEvent] = []
            sequence.reserveCapacity(depth)
            var remainder = index
            for _ in 0..<depth {
                sequence.append(alphabet[remainder % alphabet.count])
                remainder /= alphabet.count
            }
            out.append(sequence)
        }
        return out
    }
}

// MARK: - MeshContinuationCoordinatorTests

/// The table, whole.
@Suite struct MeshContinuationCoordinatorTests {

    /// The product and its helpers, shortened.
    private typealias Product = MeshContinuationProduct

    // MARK: The product

    /// The product is the size it says, no dimension collapsed into another, and the vocabulary is
    /// pinned — including the two events §14's list lacks and the fed enum's four cases.
    @Test func theStateProductIsWholeAndDistinct() {
        let rows = Product.rows()
        #expect(Product.count == 48, "6 states × 8 events — a new state or event must move this deliberately")
        #expect(rows.count == 48, "every row was built")
        #expect(Set(rows).count == 48, "and no two rows are the same pair — no dimension collapsed")
        #expect(MeshContinuationState.allCases.count == 6,
                "idle, requested, running, refused, expired, completed — idle is the sixth, deliberately")
        #expect(MeshContinuationEvent.allCases.count == 8,
                "§14's six plus taskStarted and taskRefused, without which running and refused are unreachable")
        #expect(MeshContinuationCompletion.allCases.count == 2, "succeeded and failed")
        #expect(MeshContinuationAudit.allCases.count == 9, "the eight named moves plus absorbed")
        #expect(ProximityContinuationState.allCases.count == 4,
                "not requested, running, refused, expired — a fifth fed case is a widening of the run policy too")
    }

    /// The transition is total over the product and traps on no row, every state is reachable as a
    /// landing, and the fed value is what an independent oracle says it should be.
    ///
    /// Both claims are stated against something OTHER than the outcome itself, deliberately: an
    /// `allCases.contains(anEnum)` is true of any non-optional return, and comparing `outcome.feed`
    /// to `outcome.next.feed` compares a computed property to its own definition — two green lights
    /// whatever the table says.
    @Test func everyRowIsAnsweredAndTheFedStateFollowsTheState() {
        let rows = Product.rows()
        let landings = Set(rows.map { Product.outcome($0).next })
        #expect(landings.count == 6,
                "all 48 rows answer, and between them they land on every state — none is unreachable")
        let feedFollows = rows.allSatisfy { Product.outcome($0).feed == Product.expectedFeed($0) }
        #expect(feedFollows, "and each row feeds the run policy what the hand-written oracle says it must")
    }

    // MARK: Exactly once

    /// The one invariant iOS enforces, as one line over all 48 rows.
    @Test func completionFiresExactlyOnTheEdgesOutOfRunning() {
        let rows = Product.rows()
        let oracle = rows.allSatisfy { row in
            let outcome = Product.outcome(row)
            return (outcome.completion != nil) == (row.state == .running && outcome.next != .running)
        }
        #expect(oracle, "a completion fires on exactly the edges OUT of running, and on no other row")
        let noneOutsideRunning = rows.filter { $0.state != .running }
            .allSatisfy { Product.outcome($0).completion == nil }
        #expect(noneOutsideRunning, "no state but running ever completes a task the system did not deliver")
        let everyExitCompletes = rows.filter { $0.state == .running }
            .filter { Product.outcome($0).next != .running }
            .allSatisfy { Product.outcome($0).completion != nil }
        #expect(everyExitCompletes, "and every exit from running completes, so no delivered task is left owing")
        let exits = rows.filter { $0.state == .running && Product.outcome($0).next != .running }
        #expect(exits.count == 5,
                "five exits: a new mesh, an expiry, a cancel, the session ending, and the foreground returning")
    }

    /// The exactly-once sweep: over every bounded event path from every starting state, the number of
    /// completions equals the number of delivered tasks, less the one still in hand at the end.
    @Test func everyBoundedPathCompletesOncePerDeliveredTask() {
        var walked = 0
        var balanced = true
        for depth in 1...Product.maxSweepDepth {
            for sequence in Product.sequences(depth: depth) {
                for start in MeshContinuationState.allCases {
                    let walk = Product.walk(from: start, events: sequence)
                    let outstanding = walk.endsRunning ? 1 : 0
                    if walk.completions != walk.entriesIntoRunning - outstanding { balanced = false }
                    walked += 1
                }
            }
        }
        #expect(walked == 28_080, "4 680 sequences up to the bound, from each of the six starting states")
        #expect(balanced, "one completion per entry into running on every path — never two, never none")
    }

    // MARK: The mirror

    /// The transposed re-statement agrees on every row — two decompositions of the same 48 cells.
    @Test func theMirrorOracleAgreesOnEveryRow() {
        let rows = Product.rows()
        let nextAgrees = rows.allSatisfy { Product.outcome($0).next == Product.expectedNext($0) }
        #expect(nextAgrees, "the event-first re-statement lands where the state-first table lands")
        let completionAgrees = rows.allSatisfy { Product.outcome($0).completion == Product.expectedCompletion($0) }
        #expect(completionAgrees, "and owes the same completion on the same rows")
    }

    /// The audit token names the move, and absorbs every row that moves nothing.
    @Test func theAuditTokenNamesTheMoveAndAbsorbsTheRest() {
        let rows = Product.rows()
        let auditAgrees = rows.allSatisfy { Product.outcome($0).audit == Product.expectedAudit($0) }
        #expect(auditAgrees, "every row records the token the event-first re-statement names")
        let absorbedIsStill = rows.allSatisfy { row in
            let outcome = Product.outcome(row)
            let moved = outcome.next != row.state || outcome.completion != nil
            return (outcome.audit == .absorbed) == (!moved && row.event != .meshStarted)
        }
        #expect(absorbedIsStill,
                "absorbed is exactly the rows that move nothing — a mesh start is never absorbed, it registers")
        let prefixed = MeshContinuationAudit.allCases.allSatisfy { $0.rawValue.hasPrefix("mesh.continuation.") }
        #expect(prefixed, "and every token is frozen English under one namespace")
    }

    // MARK: §14's load-bearing rows, by hand

    /// A delivered task nobody owns is a task nobody completes, so every state adopts one.
    @Test func aDeliveredTaskIsAlwaysAdopted() {
        let adopted = MeshContinuationState.allCases.allSatisfy {
            MeshContinuationCoordinator.transition(from: $0, on: .taskStarted).next == .running
        }
        #expect(adopted, "a delivered task is adopted from every state — item 6 cancels what it cannot serve")
        let noCompletionOnAdoption = MeshContinuationState.allCases.allSatisfy {
            MeshContinuationCoordinator.transition(from: $0, on: .taskStarted).completion == nil
        }
        #expect(noCompletionOnAdoption, "and adopting one completes nothing, including from running itself")
        let second = MeshContinuationCoordinator.transition(from: .running, on: .taskStarted)
        #expect(second.audit == .absorbed,
                "a delivery arriving while one is in hand is absorbed — item 6 completes that handle false itself")
    }

    /// A new mesh cannot inherit the old mesh's task: the claim resets, and a delivered task is
    /// completed `false` on the way out.
    @Test func aNewMeshResetsTheClaimAndCompletesTheStaleTask() {
        let reset = MeshContinuationState.allCases.allSatisfy {
            MeshContinuationCoordinator.transition(from: $0, on: .meshStarted).next == .idle
        }
        #expect(reset, "a mesh start lands on idle from every state")
        let stale = MeshContinuationCoordinator.transition(from: .running, on: .meshStarted)
        #expect(stale.completion == .failed, "and a running task is completed false first — the leak this prevents")
        #expect(stale.completion?.success == false, "false, because the work it was submitted for is not done")
        #expect(stale.audit == .meshChanged, "recorded as the mesh changing, not as an expiry")
        let fresh = MeshContinuationCoordinator.transition(from: .idle, on: .meshStarted)
        #expect(fresh.completion == nil, "a mesh start from rest completes nothing — there is nothing in hand")
        #expect(fresh.audit == .registered, "it is the registration point, so it is never absorbed")
    }

    /// A request the system never ran was never granted: it is refused, not expired.
    @Test func aRequestTheSystemNeverRanIsRefusedRatherThanExpired() {
        let expired = MeshContinuationCoordinator.transition(from: .requested, on: .taskExpired)
        #expect(expired.next == .refused, "an un-delivered request that ends is refused — the honest card")
        #expect(expired.completion == nil, "and completes nothing, because nothing was delivered")
        #expect(expired.audit == .expired, "while the token still says which event ended it")
        let refused = MeshContinuationCoordinator.transition(from: .requested, on: .taskRefused)
        #expect(refused.next == .refused, "an outright refusal lands in the same place")
        let cancelled = MeshContinuationCoordinator.transition(from: .requested, on: .taskCancelled)
        #expect(cancelled.next == .idle, "a withdrawn request was never granted — the claim resets and may re-arm")
        #expect(cancelled.completion == nil, "and still completes no task, because nothing was delivered")
        #expect(cancelled.audit == .cancelled, "while the token still names the event that withdrew it")
        let rearmed = MeshContinuationCoordinator.transition(from: cancelled.next, on: .firstPeerCommitted)
        #expect(rearmed.next == .requested,
                "so a peer that re-commits gets a request again, rather than a mesh with no claim for its whole life")
    }

    /// The foreground spends the task but not the session's claim, so item 6 may submit again.
    @Test func aForegroundReturnSpendsTheTaskButNotTheClaim() {
        let returned = MeshContinuationCoordinator.transition(from: .running, on: .appForegrounded)
        #expect(returned.next == .requested, "a foreground glance should not spend the session's background claim")
        #expect(returned.completion == .succeeded, "the task did its job, so it completes true")
        #expect(returned.feed == .notRequested, "and the run policy is told no task is running any more")
        let read = MeshContinuationCoordinator.transition(from: .refused, on: .appForegrounded)
        #expect(read.next == .refused, "a refused claim survives the foreground — the card is READ there")
        let readExpired = MeshContinuationCoordinator.transition(from: .expired, on: .appForegrounded)
        #expect(readExpired.next == .expired, "and so does an expired one")
    }

    /// The fed value is a function of the state alone, and the three quiescent states feed exactly
    /// what `ProximityRunPolicy` already treats as one row.
    @Test func theQuiescentStatesFeedWhatTheRunPolicyTreatsAsOneRow() {
        #expect(MeshContinuationState.running.feed == .running, "only a delivered, running task feeds running")
        let onlyRunning = MeshContinuationState.allCases.filter { $0.feed == .running }
        #expect(onlyRunning == [.running], "and it is the only state that does")
        #expect(MeshContinuationState.idle.feed == .notRequested, "rest is not a request")
        #expect(MeshContinuationState.requested.feed == .notRequested, "a pending request is not a running task")
        #expect(MeshContinuationState.completed.feed == .notRequested, "and a spent claim asks for nothing")
        #expect(MeshContinuationState.refused.feed == .refused, "a refusal is fed as itself, for item 7's card")
        #expect(MeshContinuationState.expired.feed == .expired, "and so is an expiry")
    }

    // MARK: What is not here

    /// The grep half of "no task submission in this commit": neither new file speaks
    /// `BackgroundTasks`, a scheduler, a radio, a clock, a log or a defaults key in CODE — the prose
    /// that explains why is stripped before the scan, so the claim is about the code.
    @Test func thisItemSubmitsNoTaskAndSpeaksNoRadio() throws {
        let coordinator = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/MeshContinuationCoordinator.swift"))
        let progress = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/MeshContinuationProgress.swift"))
        #expect(coordinator.count > 800, "the coordinator's code was read, so the scan is not vacuous")
        #expect(progress.count > 400, "and so was the progress value's")
        let banned = ["BackgroundTasks", "BGTaskScheduler", "BGContinuedProcessingTask", "ProximityKit",
                      "MeshNetworkManager", "FernletAuditLog", "UserDefaults", "Timer", "Task {", "Date("]
        let coordinatorClean = banned.allSatisfy { !coordinator.contains($0) }
        #expect(coordinatorClean, "the coordinator submits no task, holds no clock, logs nothing and persists nothing")
        let progressClean = banned.allSatisfy { !progress.contains($0) }
        #expect(progressClean, "and the progress value reads no clock and no ceiling — it takes scalars")
        #expect(coordinator.contains("import Foundation"), "Foundation is the coordinator's only import")
        #expect(!coordinator.contains("import SwiftUI"), "no view layer reaches this value")
    }

    /// What this table does not claim: nothing is registered, submitted, driven or completed here;
    /// no radio is spoken and no clock is read; the friend count is passed in, never derived; and
    /// "exactly once" is per ENTRY INTO `running`, not per session — a session continued twice
    /// completes twice, which the sweep states positively.
    @Test func whatThisTableDoesNotClaim() {
        #expect(MeshContinuationCoordinator.initialState == .idle, "a fresh claim rests at idle, asking for nothing")
        #expect(MeshContinuationCompletion.succeeded.success, "succeeded is setTaskCompleted(success: true)")
        #expect(!MeshContinuationCompletion.failed.success, "and failed is its false")
        let twice = Product.walk(from: .idle, events: [.taskStarted, .appForegrounded, .taskStarted, .sessionEnded])
        #expect(twice.completions == 2, "two deliveries in one session complete twice — once per ENTRY into running")
        #expect(twice.entriesIntoRunning == 2, "because the claim entered running twice, on two deliveries")
        #expect(!twice.endsRunning, "and nothing is left in hand at the end")
    }
}

// MARK: - MeshContinuationProgressTests

/// The arithmetic and the copy.
@Suite struct MeshContinuationProgressTests {

    /// The bar never retreats, whatever the caller feeds it — the property §14 says the system kills
    /// the task for losing.
    @Test func progressNeverDecreasesAcrossSuccessiveReadings() {
        let budget: TimeInterval = 6 * 60 * 60
        let first = MeshContinuationProgress.advancing(from: nil, elapsed: 60 * 60, budget: budget)
        let backwards = MeshContinuationProgress.advancing(from: first, elapsed: 10, budget: budget)
        #expect(backwards.fraction == first.fraction, "a clock that went backwards does not move the bar down")
        let stalled = MeshContinuationProgress.advancing(from: backwards, elapsed: -500, budget: budget)
        #expect(stalled.fraction == first.fraction, "and neither does a negative elapsed")
        let onward = MeshContinuationProgress.advancing(from: stalled, elapsed: 2 * 60 * 60, budget: budget)
        #expect(onward.fraction > first.fraction, "while real progress still advances")
        let shrunkBudget = MeshContinuationProgress.advancing(from: onward, elapsed: 2 * 60 * 60, budget: 60)
        #expect(shrunkBudget.fraction >= onward.fraction, "a re-read, smaller budget cannot make the bar retreat")
    }

    /// The unit is elapsed session time toward the ceiling's budget.
    @Test func progressTracksElapsedTimeTowardTheBudget() {
        let budget: TimeInterval = 100
        let quarter = MeshContinuationProgress.advancing(from: nil, elapsed: 25, budget: budget)
        #expect(quarter.fraction == 0.25, "a quarter of the budget is a quarter of the bar")
        #expect(quarter.completedUnitCount == 25, "which is 25 of the probe's 100 units")
        let start = MeshContinuationProgress.advancing(from: nil, elapsed: 0, budget: budget)
        #expect(start.fraction == 0, "a session that just started has spent none of its ceiling")
        #expect(start.completedUnitCount == 0, "and shows an empty bar")
        #expect(MeshContinuationProgress.totalUnitCount == 100, "the scale is the probe's 100")
        #expect(MeshContinuationProgress.zero.fraction == 0, "and the resting reading is empty")
    }

    /// The bar never reaches its total: a `Progress` that completes says the work is done.
    @Test func progressNeverReachesTheTotal() {
        let full = MeshContinuationProgress.advancing(from: nil, elapsed: 100, budget: 100)
        #expect(full.fraction == 1, "a session at its ceiling is at the top of the fraction")
        #expect(full.completedUnitCount == 99, "but the bar stops one short of the total, as the probe's does")
        let over = MeshContinuationProgress.advancing(from: nil, elapsed: 10_000, budget: 100)
        #expect(over.fraction == 1, "an elapsed past the budget clamps rather than overflowing")
        #expect(over.completedUnitCount == 99, "and still never reaches the total")
        #expect(MeshContinuationProgress(fraction: 4.5).completedUnitCount == 99, "a hand-built reading clamps too")
        #expect(MeshContinuationProgress(fraction: -3).fraction == 0, "and a negative one reads as empty")
    }

    /// No budget, a bad budget or a bad clock yields no progress rather than a division by zero — and
    /// nothing traps on the way.
    @Test func aZeroOrNegativeOrNonFiniteBudgetDoesNotTrap() {
        let previous = MeshContinuationProgress(fraction: 0.4)
        #expect(MeshContinuationProgress.advancing(from: previous, elapsed: 10, budget: 0) == previous,
                "a zero budget holds the last reading — there is no ceiling to be a fraction of")
        #expect(MeshContinuationProgress.advancing(from: nil, elapsed: 10, budget: 0) == .zero,
                "and a first reading with no budget is empty, not full")
        #expect(MeshContinuationProgress.advancing(from: previous, elapsed: 10, budget: -60) == previous,
                "a negative budget is no budget")
        #expect(MeshContinuationProgress.advancing(from: previous, elapsed: 10, budget: .infinity) == previous,
                "an infinite budget is not a fraction anything can advance through")
        #expect(MeshContinuationProgress.advancing(from: previous, elapsed: .nan, budget: 100) == previous,
                "and a NaN clock moves nothing")
        #expect(MeshContinuationProgress(fraction: .nan).completedUnitCount == 0,
                "a NaN fraction reads as empty rather than trapping the Int64 conversion")
    }

    /// The subtitle counts what it is given — the count is item 6's to compute, never this value's.
    @Test func theCardCountsWhatItIsGivenAndNeverGoesNegative() {
        let three = MeshContinuationCopy.card(friendCount: 3)
        #expect(String(localized: three.title) == "Fernlet mesh", "§14's title, verbatim")
        #expect(String(localized: three.subtitle) == "3 friends connected", "§14's subtitle, with the count in it")
        let none = MeshContinuationCopy.card(friendCount: 0)
        #expect(String(localized: none.subtitle) == "0 friends connected", "a mesh of one has no friends connected")
        #expect(MeshContinuationCopy.card(friendCount: -5) == none, "and a negative count reads as none, not as a lie")
    }

    /// The copy is display and the states are tokens — the localization wall's fork, both halves.
    @Test func theCopyIsDisplayAndTheStatesAreTokens() {
        #expect(MeshContinuationState.running.rawValue == "running", "the state's rawValue is frozen English")
        #expect(MeshContinuationEvent.taskStarted.rawValue == "taskStarted", "and so is the event's")
        #expect(MeshContinuationAudit.absorbed.rawValue == "mesh.continuation.absorbed", "and the audit token's")
        #expect(MeshContinuationCompletion.succeeded.rawValue == "succeeded", "and the completion's")
        let card = MeshContinuationCopy.card(friendCount: 1)
        #expect(card.title != card.subtitle, "while the two sentences are resources a translator may change")
    }
}
