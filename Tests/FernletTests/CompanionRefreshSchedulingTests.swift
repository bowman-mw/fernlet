// CompanionRefreshSchedulingTests.swift
// FernletTests
//
// Network migration P10 item 3 (plan §17.2, §27.1): the companion refresh's scheduling seam, driven
// end to end through two fakes, plus the pins that keep it on its own side of the mesh's.
//
// **Why fakes at all.** Nothing can make iOS deliver a `BGAppRefreshTask` to a unit test, and what a
// Simulator does with an app-refresh SUBMISSION is — per plan §27.2 — an open measurement rather than
// a known quantity: the continued-processing path is refused there outright with
// `BGTaskSchedulerErrorDomain` 1, and the refresh path must not be assumed to answer the same way.
// So `CompanionRefreshScheduling` and `CompanionRefreshTaskHandle` exist for this suite, and
// `SystemCompanionRefreshScheduler` / `SystemCompanionRefreshTaskHandle` are the untested remainder
// and are item 9's device rows.
//
// **What only a device can prove**, and is therefore claimed nowhere below: that the real scheduler
// accepts the registration, that a submission is granted, that iOS ever launches the task, that the
// expiration handler fires, and that a chain survives a cold launch. This suite claims the app's
// half: exactly one registration with exactly the frozen identifier, a request built to the stated
// policy, a chain that re-submits on every handler run, a refusal that is reported rather than
// swallowed, and a task completed exactly once across every order the system can drive.
//
// **The exactly-once cell is a TABLE, not a flag** — P8's shape (`MeshContinuationDriverTests`
// `everyEndingOfAnUnclaimedTaskCompletesOnceAndPresentsNothing`), for P8's reason: the orders that
// break exactly-once are an expiration arriving after a completion, the same twice, and a second
// delivery landing on a held task, and a spot cell over one of them says nothing about the others.
//
// The suite is `.serialized` because it installs `FernletAuditLog` capture handlers; the handler
// registry is token-keyed and accumulates across parallel suites, so every reader below FILTERS on
// the `companionRefresh.` prefix rather than assuming it is the only sink installed.

@testable import Fernlet
import FernletFoundation
import Foundation
import Testing

// MARK: - The fakes

/// A ``CompanionRefreshTaskHandle`` that records rather than talking to `BackgroundTasks`.
@MainActor
final class FakeCompanionRefreshTaskHandle: CompanionRefreshTaskHandle {

    /// Every `setTaskCompleted(success:)` this handle was given, in order. A second entry is the bug
    /// the exactly-once invariant exists to prevent.
    private(set) var completions: [Bool] = []

    /// The expiration handler the coordinator installed, so a test can be the system.
    private(set) var expirationHandler: (@MainActor @Sendable () -> Void)?

    /// Run at the instant this handle is completed, so a test can read the world as the coordinator
    /// leaves it rather than after it returns.
    ///
    /// The ORDER of "ask for the successor" against "end the task" is invisible to a count taken
    /// afterwards — both orders finish with one request in hand — and it is the order that matters:
    /// after `setTaskCompleted(success:)` the system may suspend the app in the same breath, so a
    /// submission made after the completion is the one the chain never gets.
    var atCompletion: (@MainActor () -> Void)?

    func setCompanionRefreshExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        expirationHandler = handler
    }

    func completeCompanionRefreshTask(success: Bool) {
        completions.append(success)
        atCompletion?()
    }
}

/// A handle that runs a closure at the one instant the coordinator is holding a task: while it is
/// installing the expiration handler.
///
/// This exists because item 3's handler completes SYNCHRONOUSLY, so the "a second task arrived while
/// one was in hand" arm is unreachable through the ordinary path — the handle is always dropped
/// before `taskWasDelivered(_:)` returns. Item 4's pipeline makes that window ordinary; this makes it
/// reachable now, so the arm is not shipped untested and then relied on.
@MainActor
final class ReentrantFakeCompanionRefreshTaskHandle: CompanionRefreshTaskHandle {

    /// Every completion this handle was given, in order.
    private(set) var completions: [Bool] = []

    /// What to run while this handle is held.
    var whileHeld: (@MainActor () -> Void)?

    func setCompanionRefreshExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        whileHeld?()
    }

    func completeCompanionRefreshTask(success: Bool) {
        completions.append(success)
    }
}

/// A refusal a fake scheduler can be told to answer a submission with.
struct FakeCompanionRefreshRefusal: Error, Equatable {}

/// A ``CompanionRefreshScheduling`` that records, and that can be told to refuse.
@MainActor
final class FakeCompanionRefreshScheduler: CompanionRefreshScheduling {

    /// Whether `register` answers `true`.
    var registrationAccepted = true

    /// What `submit` throws, or nil to accept.
    var submitRefusal: FakeCompanionRefreshRefusal?

    /// Every identifier registration was attempted for, in order.
    private(set) var registered: [String] = []

    /// Every request the seam accepted, in order.
    private(set) var submitted: [CompanionRefreshRequest] = []

    /// The launch handler the coordinator installed, so a test can be the system delivering a task.
    private var launchHandler: (@MainActor (any CompanionRefreshTaskHandle) -> Void)?

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any CompanionRefreshTaskHandle) -> Void
    ) -> Bool {
        registered.append(identifier)
        guard registrationAccepted else { return false }
        self.launchHandler = launchHandler
        return true
    }

    func submit(_ request: CompanionRefreshRequest) throws {
        if let submitRefusal { throw submitRefusal }
        submitted.append(request)
    }

    /// Delivers a task the way iOS would.
    ///
    /// - Parameter handle: The handle to deliver.
    func deliver(_ handle: any CompanionRefreshTaskHandle) {
        launchHandler?(handle)
    }
}

// MARK: - The suite

/// Item 3's four acts — register once, submit on two triggers and no others, report every refusal,
/// complete exactly once — over the two fakes, plus the boundary pins.
///
/// This is deliberately NOT a `MeshP10…AcceptanceTests`: item 9 declares those, and
/// `CIGateSelectorBoundaryTests.isMeshBattery` only demands that shape. It is gated instead by being
/// NAMED on the `s3-grep` workflow step, with `measuredSuiteNameCounts["s3-grep"]` raised in the same
/// commit — the pin catches a name LEAVING a line, and adding one passes silently otherwise.
@MainActor
@Suite(.serialized)
struct CompanionRefreshSchedulingTests {

    /// A frozen moment, so the schedule policy is assertable to the second rather than to a window.
    private static let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// A coordinator over a fake scheduler and a frozen clock.
    ///
    /// - Returns: The coordinator and its fake.
    private func coordinator() -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let scheduler = FakeCompanionRefreshScheduler()
        let subject = CompanionRefreshCoordinator(scheduler: scheduler, now: { Self.fixedNow })
        return (subject, scheduler)
    }

    /// A registered coordinator — the state in which the system may deliver a task.
    ///
    /// **Bind the coordinator at every call site, even where the cell never names it.** The launch
    /// handler the seam holds captures it WEAKLY — production's owner is the `.shared` static let,
    /// not the scheduler — so a `_` binding deallocates the subject the moment this returns, and
    /// `deliver(_:)` then calls into nothing: the handle is never adopted, nothing is submitted, and
    /// a cell that only counted what the FAKE saw would pass over a coordinator that never ran.
    ///
    /// - Returns: The coordinator and its fake.
    private func registeredCoordinator() -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let (subject, scheduler) = coordinator()
        subject.registerAtLaunch()
        return (subject, scheduler)
    }

    /// Every `companionRefresh.` audit event emitted while `body` runs, in order.
    ///
    /// Filtered on the prefix on purpose: the capture registry accumulates across suites, so an
    /// unfiltered reader would see whatever else the process logged.
    ///
    /// - Parameter body: What to run.
    /// - Returns: The event names, in order.
    private func auditedEvents(during body: () -> Void) -> [String] {
        let capture = CompanionRefreshAuditCapture()
        capture.install()
        body()
        capture.uninstall()
        return capture.events
    }

    // MARK: - Registration

    /// Registration happens exactly once, with exactly the frozen identifier.
    ///
    /// Both halves matter. The identifier is what `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers` carries literally, and a drift between the two is an
    /// error nowhere — iOS simply stops delivering the task. And `BGTaskScheduler` treats a second
    /// registration of one identifier as a programmer error, so "once per process" is not a
    /// preference.
    @Test func registrationHappensOnceWithTheFrozenIdentifier() {
        let (subject, scheduler) = coordinator()

        subject.registerAtLaunch()
        subject.registerAtLaunch()

        #expect(scheduler.registered == [CompanionRefresh.taskIdentifier],
                "one registration, and the identifier the plist permits — not a second, not a variant")
        #expect(subject.isRegistered, "the system accepted it")
        #expect(subject.didAttemptRegistration, "and the once-per-process latch is down")
        #expect(scheduler.submitted.isEmpty,
                "registering asks the system for nothing — submitting is a trigger's job, not launch's")
    }

    /// A second `registerAtLaunch()` is named rather than silently ignored.
    @Test func aSecondRegistrationIsReported() {
        let (subject, _) = coordinator()
        subject.registerAtLaunch()

        let events = auditedEvents { subject.registerAtLaunch() }

        #expect(events == ["companionRefresh.registerCalledTwice"],
                "a duplicate registration attempt is a wiring bug, and a silent one is unfindable")
    }

    /// A refused registration is reported, and nothing is ever submitted against it.
    @Test func aRefusedRegistrationIsReportedAndClosesTheChain() {
        let (subject, scheduler) = coordinator()
        scheduler.registrationAccepted = false

        let events = auditedEvents {
            subject.registerAtLaunch()
            subject.appDidEnterBackground()
        }

        #expect(subject.isRegistered == false, "a refusal is not a registration")
        #expect(scheduler.submitted.isEmpty, "an unregistered identifier can never be submitted")
        #expect(events == ["companionRefresh.registrationRefused",
                           "companionRefresh.submitWithoutARegistration"],
                "both halves say so out loud: the refusal, and every submission it then blocks")
    }

    // MARK: - The schedule policy

    /// Trigger (b): the background edge submits ONE request, at the policy's earliest begin date.
    @Test func theBackgroundEdgeSubmitsOneRequestAtThePolicysEarliestBeginDate() {
        let (subject, scheduler) = registeredCoordinator()

        subject.appDidEnterBackground()

        #expect(scheduler.submitted == [CompanionRefreshRequest(
            identifier: CompanionRefresh.taskIdentifier,
            earliestBeginDate: Self.fixedNow
                .addingTimeInterval(CompanionRefreshCoordinator.earliestBeginInterval)
        )], "one request, the permitted identifier, and the stated floor — not nil, not now")
        #expect(CompanionRefreshCoordinator.earliestBeginInterval == 15 * 60,
                "the policy is fifteen minutes; moving it is a decision with a measurement behind it, not an edit")
    }

    /// Trigger (a): every handler run re-submits, so the chain continues.
    ///
    /// The ordering is the claim: the next request is asked for while the task is still running, so a
    /// handler that later fails still leaves a successor behind.
    @Test func everyHandlerRunResubmitsBeforeItCompletes() {
        let (subject, scheduler) = registeredCoordinator()

        let first = FakeCompanionRefreshTaskHandle()
        var submittedWhenCompleted: Int?
        first.atCompletion = { submittedWhenCompleted = scheduler.submitted.count }
        scheduler.deliver(first)
        #expect(scheduler.submitted.count == 1, "the first run left a successor")
        #expect(submittedWhenCompleted == 1, """
            the successor was asked for while the task was still running. Read at the completion \
            rather than after the handler returned, because the other order ends with the same one \
            request in hand and a count taken afterwards cannot tell them apart — and it is the \
            order that decides whether the chain survives a suspension that lands on the \
            completion.
            """)

        scheduler.deliver(FakeCompanionRefreshTaskHandle())
        #expect(scheduler.submitted.count == 2, "and so did the second — a chain, not a one-shot")
        #expect(scheduler.submitted.allSatisfy { $0.identifier == CompanionRefresh.taskIdentifier },
                "every request in the chain names the one permitted identifier")
        #expect(subject.submissions == 2,
                "and the coordinator's own R2 counter agrees with the seam — two asks, two requests")
    }

    /// A refused submission is reported through the seam's error path, never swallowed.
    ///
    /// There is no card and no screen for a refresh that stopped — unlike the mesh's continuation —
    /// so this audit line is the ONLY observable a dead chain ever produces.
    @Test func aRefusedSubmissionIsReportedAndNeverSwallowed() {
        let (subject, scheduler) = registeredCoordinator()
        scheduler.submitRefusal = FakeCompanionRefreshRefusal()

        let events = auditedEvents { subject.appDidEnterBackground() }

        #expect(scheduler.submitted.isEmpty, "the seam threw, so nothing was accepted")
        #expect(events == ["companionRefresh.submitRefused"], "and the refusal is a line, not a `try?`")
        #expect(subject.submissions == 1,
                "the attempt still counts against the R2 bound — a refused ask is an ask")
    }

    /// The submission bound is real, and reaching it is audited rather than silent (R2).
    @Test func theSubmissionBoundHoldsAndSaysSoWhenItIsReached() {
        let (subject, scheduler) = registeredCoordinator()
        let cap = CompanionRefreshCoordinator.maxSubmissionsPerLaunch

        // R2: bounded by the cap.
        for _ in 0..<cap { subject.appDidEnterBackground() }
        let events = auditedEvents { subject.appDidEnterBackground() }

        #expect(scheduler.submitted.count == cap, "the bound is the bound")
        #expect(events == ["companionRefresh.submissionCapReached"],
                "and a launch that hit it has something to say")
    }

    // MARK: - Exactly once

    /// **The table.** One delivered task is completed exactly once, whatever order the system drives.
    ///
    /// Five rows, each an order that really happens: the ordinary run; the coordinator's own expiry
    /// door after the run; that door twice; the SYSTEM's installed expiration handler firing after the
    /// run (the common one — the grant is spent while the app is tearing down); and that twice. Every
    /// row asserts the WHOLE completion list rather than its count, so a row that completed `false`
    /// where it owed `true` is a red rather than a pass.
    @Test func theDeliveredTaskIsCompletedExactlyOnceOverTheWholeTable() {
        let rows: [(
            name: String,
            drive: @MainActor (CompanionRefreshCoordinator, FakeCompanionRefreshTaskHandle) -> Void
        )] = [
            ("nothing after the run", { _, _ in }),
            ("the expiry door once", { subject, _ in subject.taskDidExpire() }),
            ("the expiry door twice", { subject, _ in subject.taskDidExpire(); subject.taskDidExpire() }),
            ("the system's own handler once", { _, handle in handle.expirationHandler?() }),
            ("the system's own handler twice", { _, handle in
                handle.expirationHandler?()
                handle.expirationHandler?()
            })
        ]
        // R2: bounded by the row list.
        for row in rows {
            let (subject, scheduler) = registeredCoordinator()
            let handle = FakeCompanionRefreshTaskHandle()

            scheduler.deliver(handle)
            row.drive(subject, handle)

            #expect(handle.completions == [true],
                    "\(row.name): completed once, successfully — a second entry is the leak, a missing one is the debt")
            #expect(subject.isHoldingTask == false, "\(row.name): and nothing is still owed")
        }
    }

    /// The expiration handler is installed at adoption, so a task the app cannot finish still ends.
    @Test func theExpirationHandlerIsInstalledAtAdoption() {
        let (subject, scheduler) = registeredCoordinator()
        let handle = FakeCompanionRefreshTaskHandle()

        scheduler.deliver(handle)

        #expect(handle.expirationHandler != nil,
                "the system is given a way to reclaim the task; without it a slow handler is killed outright")
        #expect(subject.isHoldingTask == false,
                "installed by the run that has already ended the task, not left owing the system one")
    }

    /// A delivery arriving while a task is held is ENDED rather than adopted over the held one.
    ///
    /// Driven re-entrantly, because at item 3 the handler completes synchronously and this arm is
    /// otherwise unreachable — which is itself worth stating: the first assertion below is that the
    /// ORDINARY path never holds a task across a return.
    @Test func aDeliveryArrivingWhileATaskIsHeldIsEndedRatherThanAdopted() {
        let (subject, scheduler) = registeredCoordinator()
        scheduler.deliver(FakeCompanionRefreshTaskHandle())
        #expect(subject.isHoldingTask == false,
                "item 3's handler holds nothing across a return; item 4's pipeline is what opens this window")

        let intruder = FakeCompanionRefreshTaskHandle()
        let holder = ReentrantFakeCompanionRefreshTaskHandle()
        holder.whileHeld = { subject.taskWasDelivered(intruder) }

        let events = auditedEvents { subject.taskWasDelivered(holder) }

        #expect(holder.completions == [true], "the held task ran and completed once")
        #expect(intruder.completions == [false],
                "and the arrival nobody could adopt is ENDED, not dropped uncompleted")
        #expect(events == ["companionRefresh.deliveryAbsorbed", "companionRefresh.submitted"],
                "named, not silent — and the held run's own submission still happened")
    }

    /// A completion with nothing in hand is named rather than ignored.
    @Test func aCompletionWithNothingInHandIsNamed() {
        let (subject, _) = registeredCoordinator()

        let events = auditedEvents { subject.taskDidExpire() }

        #expect(events == ["companionRefresh.completedWithNoTaskInHand"],
                "completing twice and completing never are only distinguishable if the first one says so")
    }

    // MARK: - The two seams stay two

    /// The mesh's seam gained no member for the refresh task.
    ///
    /// This is the mechanical half of "do not widen the mesh's seam to carry a second task". A widened
    /// protocol would compile, every mesh test would stay green, and the fake over it would quietly
    /// stop modelling either task — which is the whole reason the decision row exists. Counted from
    /// the brace-matched protocol BODIES, so a member added anywhere in either one reds.
    @Test func theMeshSeamGainedNoMemberForTheRefreshTask() throws {
        let mesh = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/MeshContinuationScheduling.swift"))
        let handle = try #require(
            MeshRoutedSourceScan.bracedBody(after: "protocol ContinuationTaskHandle", in: mesh),
            "the mesh's handle protocol is gone")
        let scheduling = try #require(
            MeshRoutedSourceScan.bracedBody(after: "protocol BackgroundContinuationScheduling", in: mesh),
            "the mesh's scheduling protocol is gone")

        // MEASURED at P10 item 3 from the P8 shapes: four handle verbs (progress, copy, expiration
        // handler, complete) and three scheduling verbs (register, submit, cancel).
        #expect(handle.components(separatedBy: "func ").count - 1 == 4,
                "`ContinuationTaskHandle` grew or lost a member; the companion refresh must not be why")
        #expect(scheduling.components(separatedBy: "func ").count - 1 == 3,
                "`BackgroundContinuationScheduling` grew or lost a member; the companion refresh must not be why")
        #expect(!mesh.contains("CompanionRefresh"),
                "and the mesh's seam names the companion refresh nowhere at all")
    }

    /// The refresh seam is the app's one home for the app-refresh task class, and its coordinator
    /// names the framework nowhere.
    ///
    /// `BackgroundRefreshBoundaryTests` already forbids `BGContinuedProcessingTask` under the refresh
    /// directory; this is the positive twin — the refresh seam speaks `BGAppRefreshTask` and is the
    /// only file in the app that does — so the two tasks cannot be conflated in either direction.
    @Test func theRefreshSeamIsTheOneHomeOfTheAppRefreshTask() throws {
        let seam = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/CompanionRefresh/CompanionRefreshScheduling.swift"))
        let coordinator = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/CompanionRefresh/CompanionRefreshCoordinator.swift"))

        #expect(seam.contains("BGAppRefreshTaskRequest(") && seam.contains("BGTaskScheduler.shared.submit"),
                "the production conformer is real, untested code — item 9's device row, claimed by nothing above")
        #expect(!seam.contains("BGContinuedProcessingTask"), "and it is not the mesh's task class")
        // R2: bounded by the literal list.
        for needle in ["BGTaskScheduler", "BackgroundTasks", "BGAppRefreshTask"] {
            #expect(!coordinator.contains(needle),
                    "the coordinator speaks the seam's protocols, never the framework (`\(needle)`)")
        }
    }

    /// **Nothing spins, and nothing persists.** No refresh file holds a clock or a store, so
    /// "schedule at handle + background, never on a timer" and "no new persisted surface" are
    /// properties of the code rather than of this commit's good intentions.
    ///
    /// The app owns exactly one timer and `ProximitySessionPollerTests` pins ITS construction site by
    /// spelling — which forbids a second one nowhere. This is the cell that forbids it here. `Task {`
    /// is deliberately NOT on the list: the seam's one use of it is the actor hop the system's
    /// off-actor callbacks require, which is a jump, not a loop.
    @Test func theRefreshDirectoryHoldsNoClockAndNoPersistedSurface() throws {
        // R2: bounded by the three-file list.
        for path in ["App/Fernlet/CompanionRefresh/CompanionRefreshIdentifier.swift",
                     "App/Fernlet/CompanionRefresh/CompanionRefreshScheduling.swift",
                     "App/Fernlet/CompanionRefresh/CompanionRefreshCoordinator.swift"] {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            #expect(!code.isEmpty, "\(path) is gone")
            // R2: bounded by the literal list. `DispatchSource` and `RunLoop` are here because
            // "no timer" is a claim about CLOCKS, not about one spelling of one: a
            // `DispatchSourceTimer` contains neither `Timer` as a whole word nor `DispatchQueue`,
            // and a `RunLoop`-scheduled block is a third way to the same place.
            for needle in ["Timer", "DispatchQueue", "DispatchSource", "RunLoop", "Task.sleep",
                           "Task.detached", "scheduledTimer",
                           "UserDefaults", "FileManager", "Keychain"] {
                #expect(!code.contains(needle), "\(path) must not contain `\(needle)`")
            }
        }
    }

    // MARK: - The plist

    /// The plist permits the identifier and declares the `fetch` background mode.
    ///
    /// Parsed rather than grepped, because iOS reads the parsed values and a malformed array is a
    /// silent non-delivery. Pinned in BOTH directions for the reason the Bonjour cell is: a missing
    /// entry kills the task on device with no log and no observable state, and the surviving mesh
    /// entry is what proves this commit ADDED rather than replaced.
    @Test func thePlistPermitsTheIdentifierAndDeclaresTheFetchMode() throws {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/Info.plist"))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(parsed as? [String: Any], "the app Info.plist was not a dictionary")

        let identifiers = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        #expect(identifiers.contains(CompanionRefresh.taskIdentifier),
                "iOS matches this literally; without the entry the task registers and is never delivered")
        #expect(identifiers.contains("MBO.Fernlet.mesh-continuation.*"),
                "and the mesh's wildcard is still there — this commit adds, it does not replace")

        let modes = plist["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("fetch"), "a `BGAppRefreshTask` is never delivered without the `fetch` mode")
        #expect(modes.contains("remote-notification"), "and the mode that was already there stays")
        #expect(!modes.contains("processing"),
                "no `BGProcessingTask` mode was added in passing — neither task in this app is one")
    }
}

// MARK: - Audit capture

/// Collects `companionRefresh.` audit events for one test, installed on entry and removed by token, so
/// it never outlives the test that installed it.
///
/// A lock-guarded reference box in `MeshAuthorityAuditCapture`'s shape rather than a captured `var`:
/// `addCaptureHandler` takes an `@escaping` closure, the registry accumulates across parallel suites,
/// and the handler runs on whatever executor logged.
private final class CompanionRefreshAuditCapture {

    /// Guards ``storedEvents`` — handlers are invoked outside the log's own lock, from any executor.
    private let lock = NSLock()

    /// Every matching event seen, in order.
    private var storedEvents: [String] = []

    /// The registry token, until it is removed.
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, _ in
            guard let self, event.hasPrefix("companionRefresh.") else { return }
            self.lock.lock()
            self.storedEvents.append(event)
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// Every event captured, in order.
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }
}
