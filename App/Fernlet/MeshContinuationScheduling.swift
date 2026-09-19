// MeshContinuationScheduling.swift
// Fernlet
//
// Network migration P8 item 6 (plan §14, §25.1): the `BackgroundTasks` SEAM — two protocols the
// continuation host speaks, and the one production conformer that turns them into
// `BGTaskScheduler` / `BGContinuedProcessingTask` calls.
//
// **Why a seam at all.** `BGTaskScheduler` refuses a continued-processing submission on a Simulator
// outright (error 1), and no unit test can make iOS deliver a task. A host written directly against
// the framework would therefore have exactly zero tier-1 coverage of the thing item 6 IS: register,
// submit, expire, cancel, complete exactly once. With these two protocols every one of those paths
// is driven by a fake in `MeshContinuationTaskHostTests`, and the conformer below is the only part
// that needs a device (item 9, tier 3).
//
// **This is the only file in the app target outside the DEBUG feasibility probe that names
// `BGTaskScheduler` or `BGContinuedProcessingTask`**, and `MeshContinuationTaskHostTests` pins that.
// The host above it speaks protocols; the driver beside it
// (``MeshContinuationDriver``) speaks neither, and `MeshContinuationRaiseWallTests
// .theDriverIsSessionStateOnly` forbids all three names there by list.
//
// **What is copied from the probe** (`App/Fernlet/Proximity/Feasibility/
// NetworkMeshFeasibilityProbe.swift`, the shape that actually ran on hardware — plan §15.1,
// 2026-09-02): the pre-register `cancel(taskRequestWithIdentifier:)` (`:550`), `register(
// forTaskWithIdentifier:using: nil)` with the non-`BGContinuedProcessingTask` arm completing
// `false` and a `Task { @MainActor }` hop (`:551–560`), `BGContinuedProcessingTaskRequest(
// identifier:title:subtitle:)` with `strategy = .fail` (`:760–765`), the pre-submit cancel (`:768`),
// `progress.totalUnitCount` (`:787`), the `expirationHandler` hop (`:789–791`) and
// `updateTitle(_:subtitle:)` (`:792`).
//
// **What is deliberately NOT copied.** The probe's `endProbe` (`:1349`) calls
// `stopNetworkOperations()` (`:1381`) — it tears its own tunnel down before completing. §25.1 and
// item 6 are explicit that the product must not: the shutdown here completes a task and touches no
// radio, no listener and no connection. And `requiredResources` is not set, because the probe never
// set it either — the default is what the hardware run used.
//
// **No persisted surface.** Nothing here writes `UserDefaults`, a file or a keychain item; the
// registered identifier and the handle live for the life of the process, which is the honest
// lifetime of a claim on a task that no longer exists after a relaunch.

import BackgroundTasks
import Foundation

// MARK: - ContinuationTaskRequest

/// What the app asks the system for: one continued-processing task, named and described.
///
/// The two sentences are already-rendered `String`s because `BGContinuedProcessingTaskRequest` takes
/// `String`s. They are rendered from ``MeshContinuationCopy``'s `LocalizedStringResource`s at the
/// one submit site, never written as literals here — a `String` literal in this value would be
/// English forever with a clean build, which is the localization wall's failure mode (A).
nonisolated struct ContinuationTaskRequest: Equatable, Sendable {

    /// The concrete task identifier — `MBO.Fernlet.mesh-continuation.<meshID>`, inside the
    /// `Info.plist` wildcard at `BGTaskSchedulerPermittedIdentifiers`.
    let identifier: String

    /// The card's title, rendered.
    let title: String

    /// The card's subtitle, rendered.
    let subtitle: String
}

// MARK: - ContinuationTaskHandle

/// One delivered continued-processing task, as the host drives it.
///
/// Four verbs and no getters: the host never reads state back out of a task, so a fake cannot drift
/// from the real thing by answering a question differently. Exactly-once completion is the HOST's
/// invariant (it drops its reference the moment it completes, and
/// ``MeshContinuationDriver/consumePendingCompletion()`` answers nil on a second read); a conformer
/// is not asked to police it.
///
/// ## Concurrency
///
/// `@MainActor`, because everything that drives it is: the driver, the host and the store all are.
@MainActor
protocol ContinuationTaskHandle: AnyObject {

    /// Reports the ratcheted reading to the system.
    ///
    /// - Parameter progress: The reading, already clamped one short of the total by
    ///   ``MeshContinuationProgress/completedUnitCount`` — a bar that reached its total would claim
    ///   the work had finished.
    func reportContinuationProgress(_ progress: MeshContinuationProgress)

    /// Re-renders the two sentences on the system's card.
    ///
    /// - Parameters:
    ///   - title: The rendered title.
    ///   - subtitle: The rendered subtitle.
    func updateContinuationCopy(title: String, subtitle: String)

    /// Installs the handler the system calls when the time it granted is spent.
    ///
    /// - Parameter handler: What to run, on the main actor. A conformer over a real `BGTask` hops
    ///   for it — the system calls its handler from no actor at all.
    func setContinuationExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void)

    /// Ends the task.
    ///
    /// - Parameter success: Whether the work the task carried finished on the app's terms.
    func completeContinuationTask(success: Bool)
}

// MARK: - BackgroundContinuationScheduling

/// The scheduler the host asks for a task, as one seam.
///
/// ## Concurrency
///
/// `@MainActor`; the launch handler is delivered already hopped, so the host never leaves its actor.
@MainActor
protocol BackgroundContinuationScheduling: AnyObject {

    /// Registers the launch handler for one concrete identifier.
    ///
    /// - Parameters:
    ///   - identifier: The concrete task identifier.
    ///   - launchHandler: What to run when the system delivers a task for it.
    /// - Returns: Whether the system accepted the registration. `false` is a refusal the caller
    ///   must name rather than assume away — an unregistered identifier can never be submitted.
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuationTaskHandle) -> Void
    ) -> Bool

    /// Submits a request, or throws the system's refusal.
    ///
    /// - Parameter request: What to ask for.
    /// - Throws: Whatever the scheduler refused with. Never swallowed: the refusal is a move of the
    ///   continuation claim (``MeshContinuationEvent/taskRefused``) and a sentence the person reads.
    func submit(_ request: ContinuationTaskRequest) throws

    /// Withdraws any pending request for one identifier.
    ///
    /// - Parameter identifier: The concrete task identifier.
    func cancel(identifier: String)
}

// MARK: - SystemContinuationTaskHandle

/// ``ContinuationTaskHandle`` over a real `BGContinuedProcessingTask`.
///
/// An adapter rather than a conformance on the framework type: `BGTask` carries no actor isolation,
/// and the `expirationHandler` the system invokes arrives on no actor at all, so the hop belongs in
/// one place with a name on it.
///
/// ## Concurrency
///
/// `@MainActor`. The wrapped task is touched only from here.
@MainActor
final class SystemContinuationTaskHandle: ContinuationTaskHandle {

    /// The delivered task.
    private let task: BGContinuedProcessingTask

    /// Wraps a delivered task and sets its progress scale once.
    ///
    /// - Parameter task: The task the system just delivered.
    init(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = MeshContinuationProgress.totalUnitCount
    }

    func reportContinuationProgress(_ progress: MeshContinuationProgress) {
        task.progress.completedUnitCount = progress.completedUnitCount
    }

    func updateContinuationCopy(title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setContinuationExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        task.expirationHandler = { Task { @MainActor in handler() } }
    }

    func completeContinuationTask(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

// MARK: - SystemContinuationScheduler

/// ``BackgroundContinuationScheduling`` over `BGTaskScheduler.shared` — the production conformer,
/// and the only part of item 6 a Simulator cannot exercise.
///
/// `BGTaskScheduler` refuses a continued-processing submission on a Simulator (error 1), so every
/// tier-1 cell drives the host with a fake and this type is proved on a device in item 9: the
/// registration accepted, the submission with `.fail`, the launch handler firing, the expiration
/// handler firing, and the tunnel surviving the whole of it.
///
/// ## Concurrency
///
/// `@MainActor`. The registration closure the framework invokes is not, so it hops before it reaches
/// the handler — the probe's own shape.
@MainActor
final class SystemContinuationScheduler: BackgroundContinuationScheduling {

    /// Builds the production scheduler.
    init() {}

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuationTaskHandle) -> Void
    ) -> Bool {
        // The probe's launch cleanup (`:550`): a request left pending by a previous run of this
        // process's install would otherwise be delivered against a claim that no longer exists.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        return BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                // A task of another class for this identifier is not ours to run, and an adopted
                // task nobody completes is the leak exactly-once exists to prevent.
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in launchHandler(SystemContinuationTaskHandle(continued)) }
        }
    }

    func submit(_ request: ContinuationTaskRequest) throws {
        let system = BGContinuedProcessingTaskRequest(
            identifier: request.identifier,
            title: request.title,
            subtitle: request.subtitle
        )
        // `.fail` (plan §14, and the probe at `:765`): a request the system cannot grant right now
        // is refused NOW and presented as a refusal, rather than queued against a session that will
        // be over before it is answered.
        system.strategy = .fail
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier)
        try BGTaskScheduler.shared.submit(system)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
