//
//  CompanionRefreshCoordinator.swift
//  Fernlet
//
//  Network migration P10 item 3 (plan §17.2, §27.3): the thin object that owns the companion
//  `BGAppRefreshTask` — one registration, the two submission triggers, and **exactly-once**
//  completion of whatever the system delivers.
//
//  **This object HOSTS the handler; it is not the handler.** §17.2's steps — acquire the existing
//  store → roll the day → recompute the companion → diff the snapshot → publish through the widget
//  bridge → reload timelines only on change → complete once — are ``CompanionRefreshPipeline``'s,
//  which speaks values and knows nothing of background tasks. What lives here is the adoption, the
//  chain's next request, the run, and the one completion. Item 3 shipped the frame with the run
//  missing; item 4 filled it in, which is why that arrival was an insertion between two lines that
//  already existed rather than a rewrite.
//
//  **What suspending changed about exactly-once.** Item 3's handler completed synchronously, so a
//  delivered task was never held across a return and the expiration handler could only ever land
//  after the work was over. The pipeline SUSPENDS (its acquisition is `async`), so for the first
//  time a grant can run out mid-run. Two guards answer that, and both are needed: ``taskDidExpire()``
//  cancels the run BEFORE it completes the task, and a run that finishes anyway may complete only
//  the handle it was started for, and only while that handle is still held. The second is the
//  load-bearing one — a cancellation the pipeline never observed still cannot complete a task the
//  expiration door already ended.
//
//  **The schedule policy: at handle + background, never on a timer** (plan §26.3 and §27.3, taken as
//  written). There are exactly two submission triggers and they are both EDGES somebody else already
//  observes:
//    (a) the tail of every handler run — ``taskWasDelivered(_:)`` submits before it completes, which
//        is what keeps the chain alive; a handler that completes without re-submitting is the last
//        refresh the app ever gets;
//    (b) the scene entering `.background` — `FernletApp.handleScenePhaseChange(_:)`, the same edge
//        that flushes the pending snapshot save and locks the app.
//  There is NO third trigger and, emphatically, **no clock**: no `Timer`, no `DispatchQueue`
//  scheduling, no `Task.sleep` loop. The app owns exactly one timer (`ProximitySessionPoller`, whose
//  wall pins its single construction site), and a refresh that polled for its own next submission
//  would be a second one — while buying nothing, because the system, not the app, decides when an
//  opportunistic refresh runs.
//
//  **The background edge asks only when nothing is pending.** `BGTaskScheduler` REPLACES a pending
//  request for an identifier rather than queueing another beside it, so an unconditional submission
//  on every `.background` edge does not schedule a refresh — it pushes the existing request's floor
//  fifteen minutes further out, from the NEW now. A person who opens Fernlet more often than every
//  quarter hour would therefore never be delivered one, and because the only other trigger fires
//  after a delivery, the chain would never start at all. So this object remembers the request it
//  believes the system is holding: the edge asks only when that slot is empty, a delivery empties it
//  (the system has handed over what it was holding), and a refused submission leaves it empty
//  because nothing was accepted. The handler's tail is unconditional — it runs after a delivery, so
//  the slot is empty by the time it asks.
//
//  **No persisted surface.** No `UserDefaults` key, no "last refreshed at", nothing on disk: the
//  counters and the pending slot below live and die with the process, and the only durable state in
//  the whole mechanism is the request the system itself holds. That is the ledger's default (plan
//  §27.3) and it is what keeps this commit out of the wipe wall (plan §17.3) entirely.
//
//  The accepted consequence of an in-memory slot is ONE slide per process launch: a fresh process
//  does not know what its predecessor submitted, so its first `.background` edge replaces that
//  request with `now + 15 min`. One slide per launch is not the defect above, which was one per
//  switch; and buying the difference would cost either a persisted surface or a second door into the
//  scheduler (`getPendingTaskRequests` is `async`, and every fake would have to model it), neither
//  of which is worth a quarter of an hour once per launch.
//
//  **Nothing here names `BackgroundTasks`.** This object speaks ``CompanionRefreshScheduling`` and
//  ``CompanionRefreshTaskHandle``; the framework has exactly one home in this directory, the seam
//  beside it, and `MeshContinuationTaskHostTests` counts the app's homes for the whole target.
//

import FernletFoundation
import Foundation

// MARK: - CompanionRefreshCoordinator

/// The app's companion-refresh host: one registration, one held task, two submission triggers.
///
/// ## Why a process-global rather than a `@State`
///
/// `BGTaskScheduler` requires every identifier to be registered before launch finishes, and a SwiftUI
/// `App`'s `init()` is the only hook this app has inside that window — but a `@State` property may not
/// be READ from `init()`, so the registration call needs something that already exists. `.shared` is
/// the tree's established answer for exactly this shape (`FernletStoreAccess.shared`,
/// `FernletNotificationDelegate.shared`): an immutable `static let`, never a mutable global, and one
/// per process because the system delivers one task per identifier per process.
///
/// ``init(scheduler:now:)`` stays internal so a test builds its own over fakes; `.shared` is what
/// production touches.
///
/// ## Concurrency
///
/// `@MainActor`. Both call sites (`FernletApp.init()` and the scene-phase handler) already are, and
/// the seam delivers the system's launch handler already hopped.
@MainActor
final class CompanionRefreshCoordinator {

    /// The process's one coordinator.
    static let shared = CompanionRefreshCoordinator()

    /// How far ahead of now every request's `earliestBeginDate` is set: **fifteen minutes**.
    ///
    /// The number is a floor the app states, not a cadence it gets — iOS budgets opportunistic
    /// refreshes per app against how the person actually uses it, and a task may run much later or not
    /// at all. Fifteen minutes is chosen because it is the shortest interval that asks for nothing the
    /// platform is willing to give: the system does not run app refresh for a typical app more often
    /// than that, so anything smaller is a request that reads as "as soon as possible" while looking
    /// like a measured number, and `nil` says the same thing while making the policy unassertable.
    ///
    /// It is a constant precisely so it can MOVE with an argument. The work this schedules is a day
    /// roll and a companion recompute, whose interesting moment is local midnight; if item 4's soak
    /// shows the chain being spent on refreshes that change nothing, the honest fix is to raise this,
    /// in one place, with the measurement written down.
    static let earliestBeginInterval: TimeInterval = 15 * 60

    /// How many requests the BACKGROUND EDGE may ask for in one launch (Power of 10, R2).
    ///
    /// **The handler's tail is exempt, deliberately.** Every tail submission stands behind a delivery
    /// the SYSTEM chose to make, so iOS is already metering it; counting the tail against a budget
    /// that never resets is how the chain dies for good, because iOS keeps a suspended process alive
    /// for days and the sixty-fifth ask would end it with one audit line and no way back.
    ///
    /// With the pending-slot rule in this file's header, an ordinary launch spends ONE edge
    /// submission however many times the person switches away, so this bounds nothing about normal
    /// use: it bounds a pathological edge STORM, which is what a run of refused submissions looks
    /// like — a refusal leaves nothing pending, so the next edge asks again. Reaching it is audited
    /// rather than silent, and what it means is that the EDGE trigger is off for the rest of this
    /// process while the tail keeps the chain alive.
    ///
    /// **A refused REGISTRATION is not that storm.** An unregistered coordinator's edge never reaches
    /// the seam — ``submitNext(trigger:)`` returns before it asks — so it is charged nothing, and
    /// the audit trail keeps naming the real cause (`registrationRefused`, then
    /// `submitWithoutARegistration` on every edge) instead of, sixty-four edges later,
    /// `edgeSubmissionCapReached` for a budget spent on asks that never happened
    /// (plan §17.2.3 finding 3; fixed 2026-09-21).
    static let maxEdgeSubmissionsPerLaunch = 64

    /// The `BackgroundTasks` seam.
    private let scheduler: any CompanionRefreshScheduling

    /// Reads the current moment. Injected so the schedule policy is assertable to the second.
    private let now: @MainActor () -> Date

    /// §17.2's steps, as values. Injected so a scheduling test can drive the frame with
    /// ``CompanionRefreshPipeline/noOp`` instead of reaching a real store.
    private let pipeline: CompanionRefreshPipeline

    /// The delivered task, until it is completed. Dropped in the same turn it is completed, which is
    /// what makes ``completeHeldTask(success:)`` idempotent.
    private var heldTask: (any CompanionRefreshTaskHandle)?

    /// Whether ``registerAtLaunch()`` has run, accepted or refused.
    ///
    /// Registration is once per process unconditionally: `BGTaskScheduler` treats a duplicate
    /// identifier as a programmer error, and a second attempt after a refusal would be a second
    /// chance at the same answer.
    private(set) var didAttemptRegistration = false

    /// Whether the system accepted the registration. Nothing may be submitted while this is `false`.
    private(set) var isRegistered = false

    /// How many requests this launch has submitted through BOTH triggers, refused ones included —
    /// it counts attempts, not acceptances.
    private(set) var submissions = 0

    /// How many of those came from the background edge — the only trigger
    /// ``maxEdgeSubmissionsPerLaunch`` bounds, and so the R2 counter.
    ///
    /// Never more than ``submissions``: it counts the edge's asks that REACHED the seam, refused
    /// ones included, and an edge on an unregistered coordinator is not an ask at all.
    private(set) var edgeSubmissions = 0

    /// The request this process believes the system is holding, or nil.
    ///
    /// **In memory and nowhere else** — never a `UserDefaults` key, never a file, never a keychain
    /// row — so a wipe has nothing of this to erase and the wipe wall is owed no disposition row.
    /// Set when a submission is accepted, cleared when a task is delivered, and left clear when a
    /// submission is refused, because nothing was accepted. Only the background edge reads it; the
    /// tail does not need to, since it runs after a delivery has already emptied it.
    private(set) var pendingRequest: CompanionRefreshRequest?

    /// The in-flight pipeline run, or nil.
    ///
    /// Stored for exactly one reason: ``taskDidExpire()`` has to CANCEL it. Nothing reads it back
    /// as state, and it is deliberately not cleared when a run finishes — clearing it from inside
    /// the run would race a successor's handle, and cancelling an already-finished task is a no-op.
    ///
    /// `MemoryLifecycleBoundaryTests` allowlists this file under ML1 with the invariant that makes
    /// the missing `deinit` safe: the owner is the process-lifetime ``shared``.
    private(set) var pipelineRun: Task<Void, Never>?

    /// Whether the app owes the system a `setTaskCompleted(success:)` right now.
    var isHoldingTask: Bool { heldTask != nil }

    /// Builds a coordinator.
    ///
    /// - Parameters:
    ///   - scheduler: The `BackgroundTasks` seam; nil takes the production one. A default ARGUMENT
    ///     cannot be a `@MainActor` value, so the default is resolved here.
    ///   - now: The clock; nil takes the wall clock, for the same reason.
    ///   - pipeline: §17.2's steps; nil takes the production wiring, for the same reason again.
    init(
        scheduler: (any CompanionRefreshScheduling)? = nil,
        now: (@MainActor () -> Date)? = nil,
        pipeline: CompanionRefreshPipeline? = nil
    ) {
        self.scheduler = scheduler ?? SystemCompanionRefreshScheduler()
        self.now = now ?? { Date() }
        self.pipeline = pipeline ?? CompanionRefreshWiring.productionPipeline()
    }

    // MARK: - The app's own edges

    /// Registers the companion refresh identifier, once per process, before launch finishes.
    ///
    /// Registering does **not** submit. A launch that registers and is then never backgrounded asks
    /// the system for nothing, which is correct: there is no refresh to schedule for an app that is
    /// still in front of the person.
    func registerAtLaunch() {
        guard !didAttemptRegistration else {
            FernletAuditLog.log("companionRefresh.registerCalledTwice")
            return
        }
        didAttemptRegistration = true
        let accepted = scheduler.register(identifier: CompanionRefresh.taskIdentifier) { [weak self] task in
            self?.taskWasDelivered(task)
        }
        guard accepted else {
            // R7: a refusal is never silent. An identifier the system never accepted can never
            // deliver a task, and the chain below would otherwise fail with no trace at all.
            FernletAuditLog.log("companionRefresh.registrationRefused")
            return
        }
        isRegistered = true
        FernletAuditLog.log("companionRefresh.registered")
    }

    /// The scene entered `.background` — submission trigger (b).
    ///
    /// Asks only when the system is not already holding a request of ours. A submission REPLACES a
    /// pending one rather than adding to it, so an unconditional ask here would slide the floor
    /// forward every time the person switched away and the chain would never start; see this file's
    /// header. The cap below is this trigger's alone.
    func appDidEnterBackground() {
        guard pendingRequest == nil else {
            FernletAuditLog.log("companionRefresh.edgeFoundARequestAlreadyPending")
            return
        }
        guard edgeSubmissions < Self.maxEdgeSubmissionsPerLaunch else {
            FernletAuditLog.log("companionRefresh.edgeSubmissionCapReached",
                                context: ["edgeSubmissions": String(edgeSubmissions)])
            return
        }
        // Charged AFTER the ask, and only for one that reached the seam. The counter used to move
        // first, so a launch whose registration was refused spent its whole edge budget on asks
        // that were never made, and its sixty-fifth switch-away was audited as the cap rather
        // than as the refusal sixty-four lines up (plan §17.2.3 finding 3). A refused SUBMISSION
        // still counts — it reached the seam and was answered — which is the storm the cap is for.
        // Two consequences, both deliberate: an unregistered launch says `submitWithoutARegistration`
        // on EVERY edge rather than on sixty-four of them (person-bounded, and the uncapped
        // `edgeFoundARequestAlreadyPending` above set that precedent); and because the cap guard
        // reads the counter BEFORE the ask, a scheduler that delivered synchronously from inside
        // `submit` and re-entered this method could overshoot the cap by its recursion depth — none
        // does (the system seam is a straight `BGTaskScheduler.submit`; the fake records or throws),
        // and a delivering fake would have to keep it that way.
        guard submitNext(trigger: "background") else { return }
        edgeSubmissions += 1
    }

    // MARK: - The system's own edges

    /// The system delivered a refresh task.
    ///
    /// Two answers, and both complete a handle exactly once:
    /// - **adopted** — hold it, install the expiration handler, submit the chain's next request, and
    ///   start the pipeline, which completes the task when it ends.
    /// - **absorbed** — a task is already in hand, so this handle is not this coordinator's to keep.
    ///   Complete it `false` and drop it, rather than overwriting a handle the system is still owed a
    ///   completion for. This arm became ORDINARY at item 4: a run is in flight across a suspension,
    ///   so a second delivery landing on a held task is a window the system can really hit, where at
    ///   item 3 it was only reachable re-entrantly.
    ///
    /// - Parameter delivered: The task the system just handed over.
    func taskWasDelivered(_ delivered: any CompanionRefreshTaskHandle) {
        // The system has handed over what it was holding, so the slot is empty whatever happens next
        // — including for a delivery this coordinator cannot adopt.
        pendingRequest = nil
        guard heldTask == nil else {
            FernletAuditLog.log("companionRefresh.deliveryAbsorbed")
            delivered.completeCompanionRefreshTask(success: false)
            return
        }
        heldTask = delivered
        delivered.setCompanionRefreshExpirationHandler { [weak self] in self?.taskDidExpire() }
        // The chain continues FIRST, while the task is still running — the system's own guidance, and
        // the only ordering under which a handler that later fails still leaves a successor behind.
        submitNext(trigger: "handle")
        runPipeline(for: delivered)
    }

    /// The system's expiration handler fired: the time it granted is spent.
    ///
    /// **Cancel first, complete second.** The run is stopped before the task is ended so a pipeline
    /// suspended in its acquisition cannot come back and do work for a task that no longer exists.
    /// Cancelling is not by itself enough — a run already past its last cancellation check would
    /// still return normally — which is why ``finishRun(_:for:)`` refuses a handle this coordinator
    /// is no longer holding.
    ///
    /// Idempotent by construction — if the run already completed, ``completeHeldTask(success:)``
    /// finds no handle and says so instead of completing a second time.
    func taskDidExpire() {
        pipelineRun?.cancel()
        completeHeldTask(success: false)
    }

    // MARK: - The handler

    /// Starts §17.2's steps for the task just adopted.
    ///
    /// Refuses outright when nothing is held, which is not a hypothetical: an expiration handler
    /// that fires DURING adoption (the system may install-and-fire in one breath, and the re-entrant
    /// fake drives exactly that) completes and drops the task before this line is reached, and
    /// starting a pipeline then would acquire a store and publish a snapshot on behalf of a task
    /// that is already over.
    ///
    /// - Parameter delivered: The task the run may complete — and the only one it may.
    private func runPipeline(for delivered: any CompanionRefreshTaskHandle) {
        guard heldTask != nil else {
            FernletAuditLog.log("companionRefresh.runSkippedWithNoTaskInHand")
            return
        }
        let pipeline = self.pipeline
        // `Task { @MainActor … }`, never `Task.detached`: this inherits the coordinator's actor, so
        // the store the pipeline acquires is touched from the one place it may be. The handle is
        // stored so the expiration door can cancel it.
        pipelineRun = Task { @MainActor [weak self] in
            let run = await pipeline.run()
            self?.finishRun(run, for: delivered)
        }
    }

    /// Reports one finished run and completes the task it was started for.
    ///
    /// **The exactly-once guard lives here.** A run may complete only the handle it was started for,
    /// and only while that handle is still the held one. Everything that could otherwise complete a
    /// task twice fails this test: a run the expiration door cancelled (the handle was dropped by
    /// that door), a run whose cancellation the pipeline never observed, and a run that outlived its
    /// own task and returned while a SUCCESSOR was in hand.
    ///
    /// - Parameters:
    ///   - run: What the pipeline produced.
    ///   - handle: The task this run was started for.
    private func finishRun(_ run: CompanionRefreshRun, for handle: any CompanionRefreshTaskHandle) {
        guard let heldTask, heldTask === handle else {
            // R7: never silent. This is the ordinary end of an expired run, and it is also what a
            // genuine double-completion bug would look like on its way to being prevented.
            FernletAuditLog.log("companionRefresh.runEndedAfterItsTaskDid",
                                context: ["outcome": run.outcome.rawValue])
            return
        }
        FernletAuditLog.log("companionRefresh.runFinished", context: [
            "outcome": run.outcome.rawValue,
            "steps": run.steps.map(\.rawValue).joined(separator: ","),
            "dayAdvanced": String(run.dayAdvanced)
        ])
        completeHeldTask(success: run.outcome.completesSuccessfully)
    }

    // MARK: - The private half

    /// Asks the system for the next refresh, or reports the refusal.
    ///
    /// Unconditional: whether an ask is DUE is each trigger's own question — the edge answers it
    /// with ``pendingRequest`` and ``maxEdgeSubmissionsPerLaunch``, and the tail's answer is always
    /// yes, because a tail runs after a delivery.
    ///
    /// - Parameter trigger: Which of the two triggers this is, for the audit trail.
    /// - Returns: Whether the ask reached the seam at all — `false` only on an unregistered
    ///   coordinator, where nothing was asked. A refused submission is an ask that was answered and
    ///   returns `true`; it is the edge's budget that reads this, and the tail has no budget to keep.
    @discardableResult
    private func submitNext(trigger: String) -> Bool {
        guard isRegistered else {
            // Not merely early: an unregistered identifier cannot be submitted at all, and a chain
            // that never started is invisible from the outside without this line.
            FernletAuditLog.log("companionRefresh.submitWithoutARegistration", context: ["trigger": trigger])
            return false
        }
        submissions += 1
        let request = CompanionRefreshRequest(
            identifier: CompanionRefresh.taskIdentifier,
            earliestBeginDate: now().addingTimeInterval(Self.earliestBeginInterval)
        )
        // Nothing is pending until the system has accepted something. Cleared FIRST so the `catch`
        // below cannot leave a slot standing for a request that was refused — which would silence
        // the background edge for the rest of the launch, the failure this guard exists to prevent
        // in the other direction.
        pendingRequest = nil
        do {
            try scheduler.submit(request)
            pendingRequest = request
            FernletAuditLog.log("companionRefresh.submitted", context: ["trigger": trigger])
        } catch {
            // R7: never a `try?`. A refused submission is the ONLY observable a stopped chain ever
            // produces — there is no card and no screen for it, unlike the mesh's continuation — so
            // swallowing it would make "the companion stopped updating" unattributable on a device.
            FernletAuditLog.log("companionRefresh.submitRefused", context: [
                "trigger": trigger,
                "error": String(describing: error)
            ])
        }
        return true
    }

    /// **The idempotent shutdown** — the only site that completes a task.
    ///
    /// The handle is dropped BEFORE it is completed, so a re-entrant call (an expiration that lands
    /// after the handler finished, a completion driven twice) finds nothing. Nothing in hand is named
    /// rather than ignored: an app that stops completing the tasks it is given loses the privilege of
    /// being given more, and the two ways that happens — completing twice and completing never — are
    /// distinguishable only if the first one says so.
    ///
    /// - Parameter success: What to tell the system.
    private func completeHeldTask(success: Bool) {
        guard let handle = heldTask else {
            FernletAuditLog.log("companionRefresh.completedWithNoTaskInHand",
                                context: ["success": String(success)])
            return
        }
        heldTask = nil
        handle.completeCompanionRefreshTask(success: success)
    }
}
