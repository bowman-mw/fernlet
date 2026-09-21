//
//  CompanionRefreshScheduling.swift
//  Fernlet
//
//  Network migration P10 item 3 (plan §17.2, §27.1): the companion refresh's OWN `BackgroundTasks`
//  seam — two protocols the coordinator speaks, one request value, and the two production conformers
//  that turn them into `BGTaskScheduler` / `BGAppRefreshTask` calls.
//
//  **Why a second seam rather than a widened first one.** `App/Fernlet/MeshContinuationScheduling.swift`
//  is the shape this copies, and copying is the point: the launcher's decision row is explicit that the
//  mesh's seam must NOT be widened to carry a second task, because two tasks through one seam is how a
//  fake stops modelling either. The mesh's protocols speak progress, a two-sentence card and four
//  ending reasons; a refresh task has none of those. A single protocol covering both would have to
//  make every one of them optional, and a fake over it would then be silent about which task it was
//  pretending to be.
//
//  **Why a seam at all.** Nothing can make iOS deliver a background task to a unit test, and the
//  Simulator's answer to a submission is not knowable from a test either — the mesh's
//  continued-processing submission is refused there outright (`BGTaskSchedulerErrorDomain` 1), and
//  §27.2 is explicit that an app-refresh submission must be MEASURED rather than assumed to behave the
//  same way. With these protocols, registration, submission, the refusal path, delivery, expiration
//  and exactly-once completion are all driven by a fake in `CompanionRefreshSchedulingTests`, and the
//  two conformers below are the only part that needs a device (item 9's tier-3 row).
//
//  **Three places the mesh's shape did NOT transfer, each deliberate.**
//  1. *No pre-register cancel.* The mesh conformer withdraws any pending request before registering,
//     because its identifiers are per-mesh UUIDs and a request left over from a previous run refers to
//     a session that no longer exists. The refresh identifier is process-stable and a request
//     submitted in a PREVIOUS launch is exactly the thing this launch wants delivered — cancelling at
//     registration would break the chain every cold launch, silently.
//  2. *No pre-submit cancel either.* The mesh cancels-then-submits so a stale request cannot outlive a
//     refused one. Here the pending request IS the fallback: if `submit` throws, a request already
//     pending is better than none, so it is left standing and the refusal is reported. The system
//     replaces a pending request for the same identifier on its own.
//  3. *No submission strategy and no progress.* `strategy = .fail` is a continued-processing property
//     and `BGAppRefreshTaskRequest` has neither it nor a `progress` nor an `updateTitle`. An app
//     refresh is opportunistic by construction: the only thing to ask for is `earliestBeginDate`, and
//     the only thing to report is that it finished.
//
//  **No persisted surface.** Nothing here writes `UserDefaults`, a file or a keychain row. The chain's
//  whole memory is the pending request the system holds, which is the honest lifetime of a claim on a
//  refresh that no longer exists after the system drops it (plan §27.3: new persisted surface = none).
//

import BackgroundTasks
import Foundation

// MARK: - CompanionRefreshRequest

/// What the app asks the system for: one app-refresh task, no earlier than a stated moment.
///
/// A value rather than two parameters so a fake records exactly what a real submission would carry,
/// and so the scheduling policy is assertable as one thing. `Equatable` for that reason; `Sendable`
/// and `nonisolated` because it is two scalars and is read wherever the seam is.
nonisolated struct CompanionRefreshRequest: Equatable, Sendable {

    /// The task identifier — always ``CompanionRefresh/taskIdentifier``, which `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers` carries literally.
    let identifier: String

    /// The earliest moment the system may run the task.
    ///
    /// A floor, never a promise: iOS decides when (and whether) an opportunistic refresh actually
    /// runs. See ``CompanionRefreshCoordinator/earliestBeginInterval``.
    let earliestBeginDate: Date
}

// MARK: - CompanionRefreshTaskHandle

/// One delivered app-refresh task, as the coordinator drives it.
///
/// Two verbs and no getters, for the mesh handle's reason: the coordinator never reads state back out
/// of a task, so a fake cannot drift from the real thing by answering a question differently.
/// Exactly-once completion is the COORDINATOR's invariant — it drops its reference in the same turn it
/// completes — and a conformer is not asked to police it.
///
/// ## Concurrency
///
/// `@MainActor`, because the coordinator is, and because the store the handler will acquire in item 4
/// is too. The system invokes a real `BGAppRefreshTask`'s expiration handler from no actor at all, so
/// the hop lives in ``SystemCompanionRefreshTaskHandle`` with a name on it.
@MainActor
protocol CompanionRefreshTaskHandle: AnyObject {

    /// Installs the handler the system calls when the time it granted is spent.
    ///
    /// - Parameter handler: What to run, on the main actor. A conformer over a real task hops for it.
    func setCompanionRefreshExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void)

    /// Ends the task.
    ///
    /// - Parameter success: Whether the work the task carried finished on the app's terms. A task the
    ///   app never completes costs it the privilege of being given another.
    func completeCompanionRefreshTask(success: Bool)
}

// MARK: - CompanionRefreshScheduling

/// The scheduler the coordinator asks for a refresh, as one seam.
///
/// **Two members, and no `cancel`.** The mesh's seam has one because a mesh ends — a request for a
/// session that is over must be withdrawn. A refresh chain has no such edge in item 3, and this phase
/// opened by deleting a callerless `install(_:)` (item 1); adding a callerless `cancel` back in item 3
/// would be the same defect with a newer date. If item 4's delete-all leg turns out to owe the system
/// a withdrawal, it arrives with its caller.
///
/// ## Concurrency
///
/// `@MainActor`; the launch handler is delivered already hopped, so the coordinator never leaves its
/// actor.
@MainActor
protocol CompanionRefreshScheduling: AnyObject {

    /// Registers the launch handler for the companion refresh identifier.
    ///
    /// The identifier is a parameter rather than baked in so a fake can state WHICH identifier was
    /// registered — the one fact that, if it drifted from `Info.plist`, would make iOS simply stop
    /// delivering the task with no error anywhere.
    ///
    /// - Parameters:
    ///   - identifier: The task identifier to register.
    ///   - launchHandler: What to run when the system delivers a task for it.
    /// - Returns: Whether the system accepted the registration. `false` is a refusal the caller must
    ///   name rather than assume away — an unregistered identifier can never be submitted.
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any CompanionRefreshTaskHandle) -> Void
    ) -> Bool

    /// Submits a request, or throws the system's refusal.
    ///
    /// - Parameter request: What to ask for.
    /// - Throws: Whatever the scheduler refused with. Never swallowed: the refusal is the only
    ///   observable a refresh chain that has stopped ever produces.
    func submit(_ request: CompanionRefreshRequest) throws
}

// MARK: - SystemCompanionRefreshTaskHandle

/// ``CompanionRefreshTaskHandle`` over a real `BGAppRefreshTask`.
///
/// An adapter rather than a conformance on the framework type, for `SystemContinuationTaskHandle`'s
/// reason: `BGTask` carries no actor isolation and the `expirationHandler` the system invokes arrives
/// on no actor at all, so the hop belongs in one place with a name on it.
///
/// ## Concurrency
///
/// `@MainActor`. The wrapped task is touched only from here.
@MainActor
final class SystemCompanionRefreshTaskHandle: CompanionRefreshTaskHandle {

    /// The delivered task.
    private let task: BGAppRefreshTask

    /// Wraps a delivered task.
    ///
    /// - Parameter task: The task the system just delivered.
    init(_ task: BGAppRefreshTask) {
        self.task = task
    }

    func setCompanionRefreshExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        task.expirationHandler = { Task { @MainActor in handler() } }
    }

    func completeCompanionRefreshTask(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

// MARK: - SystemCompanionRefreshScheduler

/// ``CompanionRefreshScheduling`` over `BGTaskScheduler.shared` — the production conformer, and the
/// only part of item 3 that a unit test cannot exercise.
///
/// Every tier-1 cell drives the coordinator with a fake; this type is proved on a device in item 9:
/// the registration accepted, a submission granted, the launch handler firing, and the expiration
/// handler firing. §27.2's open lane question — whether a Simulator will launch a registered
/// `BGAppRefreshTask` at all — is a MEASUREMENT against this type, recorded either way; it is not
/// assumed to answer like the continued-processing path.
///
/// ## Concurrency
///
/// `@MainActor`. The registration closure the framework invokes is not, so it hops before it reaches
/// the handler.
@MainActor
final class SystemCompanionRefreshScheduler: CompanionRefreshScheduling {

    /// Builds the production scheduler.
    init() {}

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any CompanionRefreshTaskHandle) -> Void
    ) -> Bool {
        // NO pre-register cancel — see this file's header, point 1. A request submitted by a previous
        // launch is precisely what this launch wants delivered, and withdrawing it here would break
        // the chain on every cold start with nothing to show for it.
        return BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                // A task of another class for this identifier is not ours to run, and an adopted task
                // nobody completes is the leak exactly-once exists to prevent.
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in launchHandler(SystemCompanionRefreshTaskHandle(refresh)) }
        }
    }

    func submit(_ request: CompanionRefreshRequest) throws {
        let system = BGAppRefreshTaskRequest(identifier: request.identifier)
        system.earliestBeginDate = request.earliestBeginDate
        // NO pre-submit cancel — see this file's header, point 2. The pending request IS the fallback
        // when this throws, and the system replaces a same-identifier request on its own.
        try BGTaskScheduler.shared.submit(system)
    }
}
