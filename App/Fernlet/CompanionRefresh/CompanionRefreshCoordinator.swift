//
//  CompanionRefreshCoordinator.swift
//  Fernlet
//
//  Network migration P10 item 3 (plan §17.2, §27.3): the thin object that owns the companion
//  `BGAppRefreshTask` — one registration, the two submission triggers, and **exactly-once**
//  completion of whatever the system delivers.
//
//  **Item 3's handler is deliberately a placeholder.** §17.2's seven steps — acquire the existing
//  store → roll the day → recompute the companion → diff the snapshot → publish through the widget
//  bridge → reload timelines only on change → complete once — are ITEM 4's. What lands here is the
//  last step and nothing else: the delivered task is adopted, the chain's next request is submitted,
//  and the task is completed once. That ordering is chosen so item 4 is an insertion between two
//  lines that already exist rather than a rewrite of this file, and so the exactly-once contract and
//  §16.4's import wall are both already true of the directory before any work runs inside it.
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
//  **No persisted surface.** No `UserDefaults` key, no "last refreshed at", nothing on disk: the
//  counters below live and die with the process, and the only durable state in the whole mechanism is
//  the pending request the system holds. That is the ledger's default (plan §27.3) and it is what
//  keeps this commit out of the wipe wall (plan §17.3) entirely.
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

    /// How many requests one launch may submit (Power of 10, R2).
    ///
    /// Trigger (b) fires on every `.background` edge, so a person switching in and out of Fernlet all
    /// afternoon submits once per switch. Each submission replaces the pending request rather than
    /// adding one, so this is a bound on churn and not on anything the system holds — which is why it
    /// is generous. Reaching it is audited rather than silent: a launch that has been backgrounded
    /// sixty-four times has something to say.
    static let maxSubmissionsPerLaunch = 64

    /// The `BackgroundTasks` seam.
    private let scheduler: any CompanionRefreshScheduling

    /// Reads the current moment. Injected so the schedule policy is assertable to the second.
    private let now: @MainActor () -> Date

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

    /// How many requests this launch has submitted, refused ones included — it is the R2 counter, so
    /// it counts attempts.
    private(set) var submissions = 0

    /// Whether the app owes the system a `setTaskCompleted(success:)` right now.
    var isHoldingTask: Bool { heldTask != nil }

    /// Builds a coordinator.
    ///
    /// - Parameters:
    ///   - scheduler: The `BackgroundTasks` seam; nil takes the production one. A default ARGUMENT
    ///     cannot be a `@MainActor` value, so the default is resolved here.
    ///   - now: The clock; nil takes the wall clock, for the same reason.
    init(
        scheduler: (any CompanionRefreshScheduling)? = nil,
        now: (@MainActor () -> Date)? = nil
    ) {
        self.scheduler = scheduler ?? SystemCompanionRefreshScheduler()
        self.now = now ?? { Date() }
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
    func appDidEnterBackground() {
        submitNext(trigger: "background")
    }

    // MARK: - The system's own edges

    /// The system delivered a refresh task.
    ///
    /// Two answers, and both complete a handle exactly once:
    /// - **adopted** — hold it, install the expiration handler, submit the chain's next request, and
    ///   complete. Item 4's seven steps go between the submission and the completion.
    /// - **absorbed** — a task is already in hand, so this handle is not this coordinator's to keep.
    ///   Complete it `false` and drop it, rather than overwriting a handle the system is still owed a
    ///   completion for.
    ///
    /// - Parameter delivered: The task the system just handed over.
    func taskWasDelivered(_ delivered: any CompanionRefreshTaskHandle) {
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
        // ITEM 4 INSERTS ITS PIPELINE HERE. Item 3 does nothing between adoption and completion, so
        // §16.4's import wall has nothing to say about this file and the exactly-once contract below
        // is already the only behaviour there is to get wrong.
        completeHeldTask(success: true)
    }

    /// The system's expiration handler fired: the time it granted is spent.
    ///
    /// Idempotent by construction — if the handler already completed, ``completeHeldTask(success:)``
    /// finds no handle and says so instead of completing a second time.
    func taskDidExpire() {
        completeHeldTask(success: false)
    }

    // MARK: - The private half

    /// Asks the system for the next refresh, or reports the refusal.
    ///
    /// - Parameter trigger: Which of the two triggers this is, for the audit trail.
    private func submitNext(trigger: String) {
        guard isRegistered else {
            // Not merely early: an unregistered identifier cannot be submitted at all, and a chain
            // that never started is invisible from the outside without this line.
            FernletAuditLog.log("companionRefresh.submitWithoutARegistration", context: ["trigger": trigger])
            return
        }
        guard submissions < Self.maxSubmissionsPerLaunch else {
            FernletAuditLog.log("companionRefresh.submissionCapReached",
                                context: ["submissions": String(submissions), "trigger": trigger])
            return
        }
        submissions += 1
        do {
            try scheduler.submit(CompanionRefreshRequest(
                identifier: CompanionRefresh.taskIdentifier,
                earliestBeginDate: now().addingTimeInterval(Self.earliestBeginInterval)
            ))
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
