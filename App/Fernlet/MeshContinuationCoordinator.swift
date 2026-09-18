// MeshContinuationCoordinator.swift
// Fernlet
//
// Network migration P8 item 4 (plan §14): the continued-processing task's lifecycle as a pure
// VALUE — six states × eight events → the next state, the ``ProximityContinuationState`` the run
// policy is fed, whether the task's completion fires, and the frozen audit token that names the
// move. `ProximityRunPolicy` is the precedent and the reason: combinatorics belong in a table a
// test can enumerate, not in a control flow only a backgrounded scene can reach.
//
// **This file submits nothing.** No `BackgroundTasks` import, no `BGTaskScheduler`, no timer, no
// radio verb, no store, no clock, no log. Item 5 widens the manager's facts, item 6 owns the
// object that registers the handler, submits the request, drives the progress and calls
// `setTaskCompleted(success:)`, and item 7 owns the copy the person reads. What lives here is the
// part that is hard to get right and easy to test: WHICH move is legal, and exactly WHEN the
// completion fires.
//
// **Exactly once, per ENTRY INTO `running`.** §14's phrase reads as "one completion per session";
// the invariant this table actually holds — and the one that keeps iOS from killing the app — is
// one completion per ENTRY into ``MeshContinuationState/running``. The oracle is a single line:
//
//     outcome.completion != nil  ⟺  (from == .running && outcome.next != .running)
//
// `running` is entered only by a delivered task (``MeshContinuationEvent/taskStarted``) and every
// exit from it fires exactly one completion; no row outside `running` fires any.
//
// "Per entry" and "per delivered task" coincide — but only because one registered identifier yields
// one task at a time and item 6 owns the registration. They are not the same sentence: a second
// `taskStarted` arriving while a task is already in hand is ABSORBED (`fromRunning`), so it is a
// delivery the table neither adopts nor counts. The invariant to hold in mind is therefore the
// entry, not the delivery, and it is the entry the sweep counts.
//
// A session that is continued twice — foreground, background, foreground — completes twice, once per
// entry, which is the probe's `completeBackgroundTask(success:)` idiom generalised
// (`NetworkMeshFeasibilityProbe.swift`: nothing delivered ⇒ record and return; already completed ⇒
// record and return; otherwise flag, drop the handle, complete).
//
// **The NEXT STATE is the instruction; the token is the log.** Item 6 acts on
// ``MeshContinuationOutcome/next`` — entering ``MeshContinuationState/requested`` is what tells it
// to submit, from either in-edge — and ``MeshContinuationOutcome/audit`` only NAMES the event that
// moved the claim, for the log and for item 7's card. Reading the instruction off the token instead
// would strand the coordinator in `requested` on the foreground edge, whose token is an ending.
//
// **The completion is a SIGNAL, never a teardown.** The feasibility probe tears its own tunnel down
// before completing; §25.1 and item 6 are explicit that the production shutdown keeps the tunnel.
// So this value emits `.succeeded` / `.failed` and nothing else — it names no radio and stops none.
//
// **Two events beyond §14's list, deliberately.** The launcher names six; without `taskStarted` and
// `taskRefused` the states `running` and `refused` have no in-edge at all and the table would be
// proving a claim about unreachable rows. They are recorded as a deliberate widening, and
// `MeshContinuationCoordinatorTests.theStateProductIsWholeAndDistinct` pins the eight.
//
// **`idle` is the sixth state.** The value must be constructible before any mesh exists, and
// `requested` as an initial value would be a lie the run policy reads; `MeshSessionState.idle` is
// the house precedent, and `meshStarted` needs a destination that resets a spent coordinator.
//
// **Tokens, not sentences.** Every `rawValue` here is frozen English — audit lines, DEBUG readouts
// and test pins compare them. The two sentences the person sees on the task card live in
// ``MeshContinuationCopy``, as `LocalizedStringResource`, and are rendered at item 6's request site.

import Foundation

// MARK: - MeshContinuationState

/// Where the app's claim on a `BGContinuedProcessingTask` stands right now.
///
/// Six states, of which ``ProximityContinuationState`` sees four: `idle`, `requested` and
/// `completed` all feed ``ProximityContinuationState/notRequested`` because none of them is a live
/// background claim, and the run policy already treats its three non-running cases as one row. The
/// difference between them is the audit trail and item 7's card, never a radio decision.
///
/// The `rawValue` is a frozen English token — it is compared in audit lines and pinned by tests,
/// and it is never display text.
nonisolated enum MeshContinuationState: String, Equatable, Sendable, CaseIterable {

    /// No mesh is being continued: nothing was asked for, and anything asked for before was spent
    /// and cleared. The state a fresh coordinator starts in, and the state a new mesh resets to.
    case idle

    /// A request was submitted and the system has not answered it yet.
    ///
    /// **Entry into this state IS the submission instruction.** Item 6 submits whenever the claim
    /// enters `requested` with no request in flight — from either in-edge: the first peer committing
    /// (audit ``MeshContinuationAudit/submitted``) and the foreground return that spent a delivered
    /// task (audit ``MeshContinuationAudit/completed``) — under a per-session re-submission cap item
    /// 6 holds (Power of 10 rule 2), never in this enum. The cap is item 6's because a bound needs a
    /// counter and this value holds nothing; nothing in the tree implements it yet.
    case requested

    /// The system delivered the task and it is running: the process is live in the background and
    /// the mesh may keep its links. **The only state that owes a completion.**
    case running

    /// The system refused the request, or ended it without ever running it. The mesh has no claim
    /// on the background; the honest card says the session lasts while Fernlet is on screen.
    case refused

    /// A delivered task ended — expired, or cancelled by the system. The mesh has no claim on the
    /// background, and the completion for that delivery has already fired.
    case expired

    /// The claim's session is over.
    ///
    /// The terminal a ``MeshContinuationEvent/sessionEnded`` reaches from every state but rest —
    /// **whether or not a task ever ran**. A delivered task was completed on the way in; a refused
    /// or an expired claim had nothing to complete and completes nothing here. So this state says
    /// the session ended, never that the work succeeded: item 7's card must read the last audit
    /// token, or the state it was handed before the end, to say WHICH ending this was. A foreground
    /// return does NOT land here — it spends the task and re-arms the claim at `requested`.
    case completed

    /// What ``ProximityRunPolicy`` is fed while the coordinator rests here.
    ///
    /// A function of the state alone, so the fed value can never disagree with the state that
    /// produced it: ``MeshContinuationOutcome/feed`` is this property, not a second field.
    var feed: ProximityContinuationState {
        switch self {
        case .idle, .requested, .completed: return .notRequested
        case .running: return .running
        case .refused: return .refused
        case .expired: return .expired
        }
    }
}

// MARK: - MeshContinuationEvent

/// Everything that can move the continuation claim.
///
/// Six are §14's; ``taskStarted`` and ``taskRefused`` are this item's deliberate widening — without
/// them ``MeshContinuationState/running`` and ``MeshContinuationState/refused`` are unreachable.
/// The `rawValue` is a frozen English token.
nonisolated enum MeshContinuationEvent: String, Equatable, Sendable, CaseIterable {

    /// A mesh started — founded or joined. The registration point (§14: concrete-ID registration at
    /// mesh start), and from any spent state also the reset: a new mesh never inherits the old
    /// mesh's task.
    case meshStarted

    /// The first peer committed, which is where §14 submits the request with the `.fail` strategy.
    ///
    /// Item 6 may raise it on EVERY 0→1 edge of `MeshNetworkManager.hasCommittedPeer`, not only the
    /// mesh's first commit — `hasCommittedPeer` is a live predicate, not a latch, and there is no
    /// once-per-mesh fact for item 6 to key on. Deciding which of those edges matters is the table's
    /// job, not the caller's: from ``MeshContinuationState/idle`` it submits, and from every other
    /// state it is absorbed, so a peer that walks out of range and back re-arms a withdrawn claim
    /// and cannot double-submit a live one.
    case firstPeerCommitted

    /// The system delivered the task: the handler ran and the app owns a `BGContinuedProcessingTask`.
    case taskStarted

    /// The submission threw, or the system refused the request outright.
    case taskRefused

    /// The system's expiration handler fired on a delivered task.
    case taskExpired

    /// The system cancelled a delivered task, or the app cannot serve the delivery it just adopted.
    case taskCancelled

    /// The mesh session ended — the user left, the roster emptied, or the ceiling's hard deadline
    /// was reached.
    case sessionEnded

    /// The app came back to the foreground, where the mesh runs on the scene rather than on a task.
    case appForegrounded
}

// MARK: - MeshContinuationCompletion

/// The one call the system is owed for a delivered task, and the `success` flag it carries.
///
/// A value rather than a `Bool` so "no completion on this edge" is `nil` and cannot be confused
/// with "complete with false".
nonisolated enum MeshContinuationCompletion: String, Equatable, Sendable, CaseIterable {

    /// `setTaskCompleted(success: true)` — the task did what it was submitted to do.
    case succeeded

    /// `setTaskCompleted(success: false)` — the task ended before its work was done.
    case failed

    /// The flag to hand `setTaskCompleted(success:)`.
    var success: Bool { self == .succeeded }
}

// MARK: - MeshContinuationAudit

/// The frozen English token that names a move, for item 6 to emit.
///
/// A pure value does not log — `ProximityRunPolicy` is the precedent: the decision CARRIES the
/// token and the executor emits it. Item 6 decides which of these reach the audit log; every row of
/// the table names exactly one, and ``absorbed`` names every row the coordinator ignores.
///
/// A token is a LOG LINE, never an instruction: it names the event that moved the claim, and item 6
/// acts on ``MeshContinuationOutcome/next`` instead. The foreground edge is the case that proves it
/// — its token is ``completed`` (the task ended) while its next state is
/// ``MeshContinuationState/requested`` (submit again).
nonisolated enum MeshContinuationAudit: String, Equatable, Sendable, CaseIterable {

    /// A mesh started from rest: the handler is registered for the concrete identifier.
    case registered = "mesh.continuation.registered"

    /// The first peer committed: the request goes in.
    case submitted = "mesh.continuation.submitted"

    /// The system delivered the task and the app adopted it.
    case started = "mesh.continuation.started"

    /// The system refused the request.
    case refused = "mesh.continuation.refused"

    /// A request or a delivered task expired.
    case expired = "mesh.continuation.expired"

    /// A request or a delivered task was cancelled.
    case cancelled = "mesh.continuation.cancelled"

    /// The claim ended on the app's terms — the session finished, or the foreground took over.
    case completed = "mesh.continuation.completed"

    /// A new mesh replaced the one the claim belonged to; a stale delivered task is completed first.
    case meshChanged = "mesh.continuation.meshChanged"

    /// The row moved nothing: an event that does not apply in this state, absorbed as a no-op
    /// rather than trapped. **No `fatalError`, no force-unwrap, no impossible row.**
    case absorbed = "mesh.continuation.absorbed"
}

// MARK: - MeshContinuationOutcome

/// One cell of the table: where the claim lands, what the system is owed, and what to record.
nonisolated struct MeshContinuationOutcome: Equatable, Sendable {

    /// The state the coordinator moves to — the same state again for an absorbed row.
    let next: MeshContinuationState

    /// The completion this edge owes the system, or nil when no delivered task ended here.
    let completion: MeshContinuationCompletion?

    /// The frozen token naming the move, for item 6 to emit.
    let audit: MeshContinuationAudit

    /// What ``ProximityRunPolicy`` is fed after this move — ``MeshContinuationState/feed`` of
    /// ``next``, derived rather than stored so the two can never disagree.
    var feed: ProximityContinuationState { next.feed }
}

// MARK: - MeshContinuationCoordinator

/// P8's continuation claim as a pure state table: states × events → the next state, the fed run-policy
/// input, the completion the system is owed, and the token that names the move.
///
/// Holds nothing, starts nothing and completes nothing itself; ``transition(from:on:)`` is total over
/// the whole 48-row product and traps on no row. `MeshContinuationCoordinatorTests` is the table.
nonisolated enum MeshContinuationCoordinator {

    /// The state a coordinator begins in, before any mesh exists.
    static let initialState: MeshContinuationState = .idle

    /// Offers `event` to the claim.
    ///
    /// - Parameters:
    ///   - state: Where the claim stands.
    ///   - event: What happened.
    /// - Returns: The next state, the completion owed (nil on every row that ends no delivered
    ///   task), and the frozen audit token.
    static func transition(
        from state: MeshContinuationState,
        on event: MeshContinuationEvent
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return fromIdle(event)
        case .requested: return fromRequested(event)
        case .running: return fromRunning(event)
        // `refused` and `expired` take the same edges: they differ only in what they feed the run
        // policy and in the sentence item 7 shows, never in what an event does to them.
        case .refused, .expired: return fromSpentClaim(state, event)
        case .completed: return fromCompleted(event)
        }
    }

    /// No claim: nothing asked for, nothing owed.
    ///
    /// ``MeshContinuationEvent/taskStarted`` is adopted here as it is everywhere — a delivered task
    /// nobody owns is a task nobody completes, and the run policy grants nothing for a `.running`
    /// state with no session to continue.
    ///
    /// **A task delivered with no mesh is still adopted, and item 6 must end it AT ONCE** rather
    /// than resting in `running` until the system's own expiry: raise
    /// ``MeshContinuationEvent/taskCancelled`` on the next turn for a delivery it cannot serve,
    /// which completes `false` and lands on ``MeshContinuationState/expired`` — or
    /// ``MeshContinuationEvent/sessionEnded`` when the mesh is simply over, which completes `true`.
    /// Adoption is what makes the handle completable at all; leaving it adopted is not a plan.
    private static func fromIdle(_ event: MeshContinuationEvent) -> MeshContinuationOutcome {
        switch event {
        case .meshStarted: return outcome(.idle, .registered)
        case .firstPeerCommitted: return outcome(.requested, .submitted)
        case .taskStarted: return outcome(.running, .started)
        case .taskRefused, .taskExpired, .taskCancelled, .sessionEnded, .appForegrounded:
            return outcome(.idle, .absorbed)
        }
    }

    /// A request is in and the system has not answered.
    ///
    /// An expiry here lands on ``MeshContinuationState/refused``, not `expired`: a request the
    /// system never ran was never granted, and the honest card is the one that says the session
    /// lasts while Fernlet is on screen. A cancel or a session ending completes NOTHING — nothing
    /// was delivered, so item 6 cancels the pending request rather than completing a task.
    ///
    /// They part on where they LAND. A cancel withdraws a request that was never granted: nothing
    /// was delivered and nothing was spent, so the claim resets to ``MeshContinuationState/idle``
    /// and the next ``MeshContinuationEvent/firstPeerCommitted`` re-arms it. Landing it on
    /// ``MeshContinuationState/completed`` would strand the mesh, because `completed` absorbs
    /// `firstPeerCommitted` — a peer that walked out of range and back would never get a background
    /// claim again for the life of that mesh, with no audit line saying so. A session ending is the
    /// mesh itself finishing, and lands on `completed` as it does from every other state.
    private static func fromRequested(_ event: MeshContinuationEvent) -> MeshContinuationOutcome {
        switch event {
        case .meshStarted: return outcome(.idle, .meshChanged)
        case .taskStarted: return outcome(.running, .started)
        case .taskRefused: return outcome(.refused, .refused)
        case .taskExpired: return outcome(.refused, .expired)
        case .taskCancelled: return outcome(.idle, .cancelled)
        case .sessionEnded: return outcome(.completed, .completed)
        case .firstPeerCommitted, .appForegrounded: return outcome(.requested, .absorbed)
        }
    }

    /// A delivered task is running — **the only state that owes a completion**, and every exit fires
    /// exactly one.
    ///
    /// A new mesh completes the stale task `false` before resetting: the un-completed task of a dead
    /// mesh is precisely the leak exactly-once exists to prevent. A foreground return spends the
    /// task but not the session's claim, so it lands back on ``MeshContinuationState/requested`` —
    /// and entry into `requested` IS the submission instruction, so item 6 submits again on that
    /// edge exactly as it does on the first peer committing, under the per-session re-submission cap
    /// item 6 holds (Power of 10 rule 2), never here. The row's token is
    /// ``MeshContinuationAudit/completed`` because a token names the event that moved the claim —
    /// the delivered task ending — and never what to do next.
    ///
    /// A second ``MeshContinuationEvent/taskStarted`` while a task is in hand is ABSORBED:
    /// `BGTaskScheduler` does not deliver two tasks for one registered identifier at once, and this
    /// value tracks ONE claim rather than a stack. The state not moving is item 6's instruction for
    /// the handle it just received and could not hand over — complete it `false` and drop it, the
    /// probe's "already completed ⇒ record and return" arm. This row is also why the invariant is
    /// one completion per ENTRY into `running` rather than per delivery: the two coincide only under
    /// item 6's single registered identifier.
    private static func fromRunning(_ event: MeshContinuationEvent) -> MeshContinuationOutcome {
        switch event {
        case .meshStarted: return outcome(.idle, .meshChanged, completing: .failed)
        case .taskExpired: return outcome(.expired, .expired, completing: .failed)
        case .taskCancelled: return outcome(.expired, .cancelled, completing: .failed)
        case .sessionEnded: return outcome(.completed, .completed, completing: .succeeded)
        case .appForegrounded: return outcome(.requested, .completed, completing: .succeeded)
        case .firstPeerCommitted, .taskStarted, .taskRefused: return outcome(.running, .absorbed)
        }
    }

    /// A spent claim — refused, or a delivered task that ended.
    ///
    /// Both absorb ``MeshContinuationEvent/appForegrounded``: the card is READ in the foreground, and
    /// clearing the state on a foreground edge would make it unreachable.
    ///
    /// ``MeshContinuationEvent/sessionEnded`` lands on ``MeshContinuationState/completed`` here as it
    /// does everywhere else, and no completion fires: `completed` is the terminal after a session
    /// END, not a claim that a task ran. A refused request and an ended delivery both finish their
    /// session having completed nothing. Item 7's card must therefore read the LAST AUDIT TOKEN
    /// (``MeshContinuationAudit/refused`` / ``MeshContinuationAudit/expired``) or the pre-end state
    /// it was handed, never `completed` alone — otherwise the moment the 6-hour ceiling raises
    /// `sessionEnded`, the card loses the only thing it had to tell the person.
    ///
    /// - Parameters:
    ///   - state: ``MeshContinuationState/refused`` or ``MeshContinuationState/expired``; any other
    ///     state rests where it is, which is unreachable from ``transition(from:on:)``'s switch.
    ///   - event: What happened.
    /// - Returns: The edge taken.
    private static func fromSpentClaim(
        _ state: MeshContinuationState,
        _ event: MeshContinuationEvent
    ) -> MeshContinuationOutcome {
        switch event {
        case .meshStarted: return outcome(.idle, .meshChanged)
        case .taskStarted: return outcome(.running, .started)
        case .sessionEnded: return outcome(.completed, .completed)
        case .firstPeerCommitted, .taskRefused, .taskExpired, .taskCancelled, .appForegrounded:
            return outcome(state, .absorbed)
        }
    }

    /// The claim ended on the app's terms; everything the system was owed has been paid.
    private static func fromCompleted(_ event: MeshContinuationEvent) -> MeshContinuationOutcome {
        switch event {
        case .meshStarted: return outcome(.idle, .meshChanged)
        case .taskStarted: return outcome(.running, .started)
        case .firstPeerCommitted, .taskRefused, .taskExpired, .taskCancelled, .sessionEnded,
             .appForegrounded:
            return outcome(.completed, .absorbed)
        }
    }

    /// One cell, spelled once.
    private static func outcome(
        _ next: MeshContinuationState,
        _ audit: MeshContinuationAudit,
        completing completion: MeshContinuationCompletion? = nil
    ) -> MeshContinuationOutcome {
        MeshContinuationOutcome(next: next, completion: completion, audit: audit)
    }
}
