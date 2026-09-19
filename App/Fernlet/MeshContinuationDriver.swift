// MeshContinuationDriver.swift
// Fernlet
//
// Network migration P8 item 5 (plan §14, §24.1, §25.1): the app-target driver's SESSION-STATE half
// — the only thing in the whole app that tells the mesh its scene has gone dark behind a
// `BGContinuedProcessingTask`, and the only thing that tells it the scene is back.
//
// **What this file is, in one sentence.** It holds item 4's pure claim (`MeshContinuationState`),
// moves it through `MeshContinuationCoordinator.transition(from:on:)` on the two edges the system
// gives it — a task delivered, a task ending — and on exactly those moves raises
// `MeshNetworkManager.beginBackgroundContinuation()` / `endBackgroundContinuation()`, the narrow
// public pair item 5 added to ProximityKit.
//
// **What it deliberately is NOT.** It registers nothing, submits nothing, schedules nothing and
// completes nothing: `BGTaskScheduler`, the `BGContinuedProcessingTaskRequest`, the expiration
// handler, the progress ratchet and `setTaskCompleted(success:)` are item 6's, and item 6 adds them
// to THIS type. It also speaks no radio verb, writes no routed access gate and calls no store
// setter — `MeshContinuationRaiseWallTests.theDriverIsSessionStateOnly` scans this file for every
// one of those needles, the manager is held behind a TWO-VERB seam
// (`MeshContinuationRaising`) that makes the rest of it unspellable from here, and
// `ProximityRunSeamsTests` / `MeshRoutedLockedDeviceTests` (W8) would redden anyway.
//
// **Nothing spins here** (Power of 10 R2, and the memory-lifecycle wall's ML1/ML4). The type stores
// no `Task` handle, no `Timer` and no `unowned` host: it holds the manager WEAKLY and reacts to
// calls. The clock the continuation needs is the one the app already owns — item 6 rides
// `ProximitySessionPoller`'s tick, which a CPT-continued mesh keeps running by keeping the process
// alive.
//
// **The completion is a value the caller collects, never a teardown.** `taskDidEnd(_:)` records
// what the system is owed in `pendingCompletion`; item 6 consumes it with
// `consumePendingCompletion()` and calls `setTaskCompleted(success:)` with it. Exactly-once is item
// 4's oracle — `completion != nil ⟺ (from == .running && next != .running)` — and this file adds no
// second path to either raise: every `begin` sits behind an ENTRY into `running`, and every `end`
// behind a completion the table produced. `anEndingWithNoTaskInHandRaisesNothing` is that claim as a
// cell.
//
// **The PROJECTION is a rule, not a raw token** (item 7's adversarial verify, obligation 1). The
// driver carries `lastAudit` beside `state` because item 7's Friends card needs both — `completed`
// is item 4's terminal after ANY session end, so the state alone cannot say which ending it was.
// The token is therefore assigned through `MeshContinuationCardPresentation.projectedAudit(
// previous:outcome:)` — item 7's own rule, in item 7's file, rather than a second copy here — never
// from `outcome.audit`: an ABSORBED row is not a move and keeps the previous token, a move INTO
// `completed` keeps the previous token (so a refusal or an expiry survives the session ending on
// top of it), and every other moving row records its own. Item 6 feeds the store from this value.
//
// **An ending only explains something if the claim was ever made** (obligation 2). A task nobody
// asked for is still ADOPTED — an unadopted handle is uncompletable — and still completed exactly
// once, so `taskCancelled` is still the transition. But when the completion fires the projection is
// RESET to `idle` / no token, because "iOS ended your background session" is a sentence about a
// session that never existed. `reset()` is the same act, exposed: item 6 calls it on the proximity
// hard stop (delete-all's leg 7b) and on a new mesh start. It never clears `pendingCompletion` — a
// wipe does not excuse the app from completing the task it holds — and, since the fix round's F1,
// it ENDS a task that is still running before it clears anything, because a projection cleared out
// from under a live claim would strand `continuingInBackground` forever with nothing left to raise
// the foreground edge. `resetProjection()` is the field-clearing half, private, and the two callers
// that may reach it have both just ended a task.
//
// **The disagreement is the point, not a side effect** (plan §24.1/§25.1). A continued mesh moves
// to `MeshSessionState.continuingInBackground`, which CLOSES
// `MeshNetworkManager.mayCommitRoutedHeartLedgerJudgement`: a mesh carrying on in the background
// custodies ciphertext and judges no heart. The routed access gate's own foreground leg is pushed
// separately, by the run policy, from `ScenePhase` — the two legs never read each other, and
// `MeshContinuationDisagreementTests` reads all four corners of the pair.

import FernletFoundation
import Foundation
import ProximityKit

// MARK: - MeshContinuationEndReason

/// Why a `BGContinuedProcessingTask` this device holds is ending.
///
/// Four endings, and the alphabet is deliberately narrower than ``MeshContinuationEvent``'s eight:
/// an ENDING is not a claim move, so a caller cannot spell `taskStarted` here by accident. The
/// `rawValue` is a frozen English token — it names the ending in the audit trail and is compared by
/// tests — and is never display text.
nonisolated enum MeshContinuationEndReason: String, Equatable, Sendable, CaseIterable {

    /// The system called the task's expiration handler: the time it granted is spent.
    case expired

    /// The system cancelled the task, or the app cannot serve a delivery it just adopted.
    case cancelled

    /// The mesh session itself is over, so the work the task was continuing is done.
    case sessionEnded

    /// The person came back to Fernlet, so the foreground is carrying the session again.
    case appForegrounded

    /// The claim event this ending offers ``MeshContinuationCoordinator``.
    var event: MeshContinuationEvent {
        switch self {
        case .expired: return .taskExpired
        case .cancelled: return .taskCancelled
        case .sessionEnded: return .sessionEnded
        case .appForegrounded: return .appForegrounded
        }
    }
}

// MARK: - MeshContinuationAdoption

/// How a delivered `BGContinuedProcessingTask` was taken on, which is the caller's instruction.
///
/// Item 4 adopts a delivered task from EVERY state on purpose — a task nobody owns is a task nobody
/// completes — so "adopted" alone does not say whether this device asked for it. This does.
nonisolated enum MeshContinuationAdoption: String, Equatable, Sendable, CaseIterable {

    /// The claim had asked for this task and the system delivered it: serve it.
    case claimed

    /// Nobody asked for it — the claim was idle, refused, spent or already completed.
    /// **End it at once**, with ``MeshContinuationDriver/taskDidEnd(_:)`` and
    /// ``MeshContinuationEndReason/cancelled``: adoption is what makes the handle completable at
    /// all, and leaving it adopted until the system's own expiry is not a plan. That ending
    /// completes the task and then RESETS the projection — there is nothing to tell the person
    /// about a background session they never had.
    case ownerless

    /// A second delivery arriving while a task is already in hand. Item 4 absorbs it, so the claim
    /// did not move and nothing was raised; the handle the caller was just given is not this
    /// driver's and must be completed by whoever holds it.
    case absorbed
}

// MARK: - MeshContinuationDriver

/// The app's continuation driver — item 5's half: the claim, and the two session-state raises.
///
/// Item 6 grows this type with the `BackgroundTasks` half (register, submit, progress, expiration,
/// completion) and with the remaining claim edges (`meshStarted`, `firstPeerCommitted`,
/// `taskRefused`); the two entry points here stay the only place either raise is spoken.
///
/// ## Concurrency
///
/// `@MainActor`, because ``ProximityKit/MeshNetworkManager`` is: every raise is a main-actor call
/// on the manager the composition root owns. The manager is held **weakly** — the store owns both,
/// and a driver that outlived it must raise nothing rather than resurrect it.
@MainActor
final class MeshContinuationDriver {

    /// Where the claim on a continued-processing task stands, per item 4's table.
    private(set) var state: MeshContinuationState = MeshContinuationCoordinator.initialState

    /// What the system is owed for the task that just ended, until a caller consumes it.
    ///
    /// Non-nil means `setTaskCompleted(success:)` has NOT been called yet for a task that is over.
    /// Item 6 takes it with ``consumePendingCompletion()`` at the one site that holds the handle.
    private(set) var pendingCompletion: MeshContinuationCompletion?

    /// The frozen token naming the last move the claim made — the audit line, and what item 7's
    /// card reads to tell a refusal from an expiry when both have landed on the same state.
    ///
    /// Assigned through ``MeshContinuationCardPresentation/projectedAudit(previous:outcome:)`` and
    /// never from `outcome.audit` directly: an absorbed row is not a move, and a session ending on
    /// top of a refusal must not erase the refusal the person has not seen yet.
    private(set) var lastAudit: MeshContinuationAudit?

    /// Whether the task in hand was adopted with no claim behind it. Read once, at the completion
    /// that ends it, to decide whether the ending is presentable at all.
    private var adoptedWithoutAClaim = false

    /// The manager whose session state these raises move, held as the two-door seam it conforms to.
    ///
    /// The type is ``ProximityKit/MeshContinuationRaising`` rather than `MeshNetworkManager`
    /// because the manager is `final`: without the seam the exhaustive sweep in
    /// `MeshContinuationDriverTests` could not COUNT the raises against the entries into and exits
    /// from `running`. It also narrows this file's reach to exactly two verbs — from behind it the
    /// radio verbs, the store and the routed access gate are unspellable, which is the type-system
    /// half of `theDriverIsSessionStateOnly`. Weak on purpose: see the type's note.
    private weak var meshNetworkManager: (any MeshContinuationRaising)?

    /// Builds a driver over one manager.
    ///
    /// - Parameter meshNetworkManager: The mesh manager the raises are spoken to, as the two-door
    ///   seam it conforms to.
    init(meshNetworkManager: any MeshContinuationRaising) {
        self.meshNetworkManager = meshNetworkManager
    }

    /// The system delivered a `BGContinuedProcessingTask`: adopt it, and — on the entry into
    /// `running` — tell the mesh its scene is now dark.
    ///
    /// The raise is behind the ENTRY, not behind the event: a second delivery while a task is in
    /// hand is absorbed by item 4's table and re-raises nothing, because nothing moved.
    ///
    /// - Returns: Whether the delivery was claimed, ownerless or absorbed. An ownerless one is
    ///   ``MeshContinuationEndReason/cancelled``'s job, on the caller's next turn.
    @discardableResult
    func taskDidStart() -> MeshContinuationAdoption {
        let previous = state
        let outcome = apply(.taskStarted)
        guard outcome.next == .running, previous != .running else { return .absorbed }
        adoptedWithoutAClaim = previous != .requested
        raiseBackgroundContinuationBegan()
        return adoptedWithoutAClaim ? .ownerless : .claimed
    }

    /// The task in hand is over: move the claim, and — on exactly the edges item 4 says complete a
    /// delivered task — record what the system is owed and tell the mesh the scene is back.
    ///
    /// The two acts are one branch on purpose. A completion the table did not produce is an ending
    /// of nothing, and an ending of nothing must not tell a live foreground mesh it has just
    /// returned from the background.
    ///
    /// - Parameter reason: Why the task is ending.
    func taskDidEnd(_ reason: MeshContinuationEndReason) {
        let wasUnclaimed = adoptedWithoutAClaim
        let outcome = apply(reason.event)
        guard let completion = outcome.completion else { return }
        pendingCompletion = completion
        raiseBackgroundContinuationEnded()
        guard wasUnclaimed else { return }
        resetProjection()
    }

    /// Returns the PROJECTION to where a driver is born — `idle`, with no token — **ending the task
    /// in hand first**, and forgets nothing else.
    ///
    /// The ending is not a courtesy, it is the whole safety of this door (the fix round's F1). A
    /// reset that merely cleared the fields while a task was `running` would leave three wrongs at
    /// once: no `pendingCompletion`, so the handle the app is holding is never completed and the
    /// system takes the privilege away; `MeshSessionState.continuingInBackground` standing
    /// **permanently**, because `endBackgroundContinuation()` is the only shipping raiser of
    /// `.foregrounded` and this driver has just forgotten the task that would have raised it; and
    /// therefore `mayCommitRoutedHeartLedgerJudgement` closed for the life of that mesh, every
    /// routed heart deferring silently and forever. So a live claim goes through
    /// ``taskDidEnd(_:)`` with ``MeshContinuationEndReason/cancelled`` — the app cannot serve a task
    /// it is wiping — which completes it exactly once and raises `end` exactly once, and only then
    /// is the projection returned.
    ///
    /// `pendingCompletion` deliberately survives: a wipe or a new mesh does not excuse the app from
    /// calling `setTaskCompleted(success:)` for a handle it is still holding, and dropping that debt
    /// is precisely what gets an app's continuation privilege taken away. **It is not a queue** —
    /// a completion nobody consumed is overwritten by the next one, so item 6 consumes the handle it
    /// holds before it resets.
    ///
    /// Item 6 wires the two calls: the proximity hard stop (delete-all, leg 7b) and a new mesh
    /// start. It is the harder form of item 4's `meshStarted` row, which resets the STATE and still
    /// names a token.
    func reset() {
        if state == .running { taskDidEnd(.cancelled) }
        resetProjection()
    }

    /// Takes the pending completion, leaving none behind.
    ///
    /// The handle is the caller's, so the success flag is read exactly once by whoever calls
    /// `setTaskCompleted(success:)`; a second read answers nil rather than completing twice.
    ///
    /// - Returns: The completion owed, or nil when none is.
    func consumePendingCompletion() -> MeshContinuationCompletion? {
        let owed = pendingCompletion
        pendingCompletion = nil
        return owed
    }

    /// Returns the projection alone — `idle`, no token, no unclaimed flag — offering item 4's table
    /// nothing and raising nothing.
    ///
    /// The ONE site that moves those three fields, shared by ``reset()`` (after it has ended any
    /// task in hand) and by ``taskDidEnd(_:)``'s unclaimed arm (which has just ended one). It is
    /// private because that is the whole point: reaching it with `state == .running` is the hole
    /// ``reset()``'s first line closes, and no caller outside this file can.
    private func resetProjection() {
        state = MeshContinuationCoordinator.initialState
        lastAudit = nil
        adoptedWithoutAClaim = false
    }

    /// Offers one event to item 4's table, records the move, and audits it.
    ///
    /// - Parameter event: What happened.
    /// - Returns: The outcome, for the caller's own branch.
    private func apply(_ event: MeshContinuationEvent) -> MeshContinuationOutcome {
        let outcome = MeshContinuationCoordinator.transition(from: state, on: event)
        lastAudit = MeshContinuationCardPresentation.projectedAudit(
            previous: lastAudit, outcome: outcome
        )
        state = outcome.next
        FernletAuditLog.log(
            outcome.audit.rawValue,
            context: ["event": event.rawValue, "state": outcome.next.rawValue]
        )
        return outcome
    }

    /// The ONE site that tells the mesh a continued task now carries it.
    private func raiseBackgroundContinuationBegan() {
        guard let meshNetworkManager else {
            noteRaiseWithoutAManager("begin")
            return
        }
        meshNetworkManager.beginBackgroundContinuation()
    }

    /// The ONE site that tells the mesh the foreground carries it again.
    private func raiseBackgroundContinuationEnded() {
        guard let meshNetworkManager else {
            noteRaiseWithoutAManager("end")
            return
        }
        meshNetworkManager.endBackgroundContinuation()
    }

    /// A raise that reached no manager, named rather than swallowed.
    ///
    /// - Parameter edge: A frozen English token, `"begin"` or `"end"`.
    private func noteRaiseWithoutAManager(_ edge: String) {
        FernletAuditLog.log("mesh.continuation.raiseWithoutAManager", context: ["edge": edge])
    }
}
