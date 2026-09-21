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
// **The two fixes the verify asked for, in one line each.** The frozen identifier is compared
// against the LITERAL rather than against `CompanionRefresh.taskIdentifier`, because the constant on
// both sides of an `==` is a cell that cannot fail; and the clock-and-persistence prohibition lives
// on `BackgroundRefreshBoundaryTests` rather than in a path list here, because that wall walks the
// directory and this suite's list only ever covered three named files.
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

/// A clock a test can move between edges.
///
/// The frozen clock most cells use cannot see the defect the pending-slot rule fixes: three
/// submissions built from the SAME instant are indistinguishable from one, so "the floor slid"
/// only becomes a readable claim once `now()` advances between the asks.
@MainActor
final class MovableCompanionRefreshClock {

    /// The moment `now()` answers with, until a test moves it.
    var now: Date

    /// Starts the clock.
    ///
    /// - Parameter start: The first moment.
    init(_ start: Date) {
        self.now = start
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

    /// Every protocol `App/Fernlet/MeshContinuationScheduling.swift` declares, with its body frozen
    /// as of P10 item 3 — normalised by ``normalisedBody(_:)``.
    ///
    /// The mesh's seam is the one this one was copied from rather than carved out of, and the whole
    /// decision rests on it not quietly growing a member for the refresh task.
    private static let frozenMeshProtocols: [(signature: String, body: String)] = [
        ("protocol ContinuationTaskHandle",
         "{ func reportContinuationProgress(_ progress: MeshContinuationProgress) func updateContinuationCopy(title: String, subtitle: String) func setContinuationExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) func completeContinuationTask(success: Bool) }"),
        ("protocol BackgroundContinuationScheduling",
         "{ func register( identifier: String, launchHandler: @escaping @MainActor (any ContinuationTaskHandle) -> Void ) -> Bool func submit(_ request: ContinuationTaskRequest) throws func cancel(identifier: String) }")
    ]

    /// A brace-matched body reduced to one line: trailing `//` comments cut, blank lines dropped,
    /// each remaining line trimmed and joined by single spaces.
    ///
    /// So the frozen strings above are about the DECLARATIONS rather than about how they happen to
    /// be wrapped or where a reviewer put a comment. Whole-line comments are already gone by the
    /// time this runs — its input is `MeshRoutedSourceScan.codeOnly(_:)` output.
    ///
    /// - Parameter body: The brace-matched body.
    /// - Returns: The normalised one-liner.
    private static func normalisedBody(_ body: String) -> String {
        var parts: [String] = []
        // R2: bounded by the body's line count.
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let code = line.range(of: "//").map { String(line[line.startIndex..<$0.lowerBound]) }
                ?? String(line)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: " ")
    }

    /// A coordinator over a fake scheduler and a frozen clock.
    ///
    /// - Returns: The coordinator and its fake.
    private func coordinator() -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let scheduler = FakeCompanionRefreshScheduler()
        let subject = CompanionRefreshCoordinator(scheduler: scheduler, now: { Self.fixedNow })
        return (subject, scheduler)
    }

    /// A coordinator over a fake scheduler and a clock the test can move.
    ///
    /// - Parameter clock: The clock to read.
    /// - Returns: The coordinator and its fake.
    private func coordinator(
        clock: MovableCompanionRefreshClock
    ) -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let scheduler = FakeCompanionRefreshScheduler()
        let subject = CompanionRefreshCoordinator(scheduler: scheduler, now: { clock.now })
        return (subject, scheduler)
    }

    /// A registered coordinator over a clock the test can move.
    ///
    /// - Parameter clock: The clock to read.
    /// - Returns: The coordinator and its fake.
    private func registeredCoordinator(
        clock: MovableCompanionRefreshClock
    ) -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let (subject, scheduler) = coordinator(clock: clock)
        subject.registerAtLaunch()
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

        #expect(scheduler.registered == ["MBO.Fernlet.companion-refresh"], """
            one registration, and the identifier the plist permits — not a second, not a variant. \
            The expected value is the LITERAL rather than `CompanionRefresh.taskIdentifier`: with \
            the constant on both sides this cell compares a value to itself and stays green while \
            the constant drifts away from the plist, which is the one drift iOS answers by simply \
            never delivering the task.
            """)
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

    /// **Trigger (b) asks only when nothing is pending.** Three background edges, no delivery
    /// between them, one request — at the FIRST edge's floor.
    ///
    /// `BGTaskScheduler` replaces a pending request for an identifier rather than queueing another,
    /// so an unconditional ask on every edge does not schedule anything: it moves the existing
    /// request's floor forward, from the new now, every time the person switches away. Someone who
    /// opens Fernlet more often than every fifteen minutes is then never delivered a refresh, and
    /// since the only other trigger fires AFTER a delivery, the chain never starts. The clock moves
    /// between the edges here because a frozen one cannot tell one ask from three.
    @Test func theBackgroundEdgeAsksOnlyWhenNothingIsPending() {
        let clock = MovableCompanionRefreshClock(Self.fixedNow)
        let (subject, scheduler) = registeredCoordinator(clock: clock)

        subject.appDidEnterBackground()
        clock.now = Self.fixedNow.addingTimeInterval(60)
        subject.appDidEnterBackground()
        clock.now = Self.fixedNow.addingTimeInterval(120)
        let events = auditedEvents { subject.appDidEnterBackground() }

        #expect(scheduler.submitted == [CompanionRefreshRequest(
            identifier: "MBO.Fernlet.companion-refresh",
            earliestBeginDate: Self.fixedNow
                .addingTimeInterval(CompanionRefreshCoordinator.earliestBeginInterval)
        )], """
            one request, and it still carries the FIRST edge's floor. Two more entries — or one \
            entry dated from the third edge — is the floor sliding a quarter of an hour further \
            out with every switch.
            """)
        #expect(events == ["companionRefresh.edgeFoundARequestAlreadyPending"],
                "and an edge that asked for nothing says why, rather than looking like an edge that never fired")
        #expect(subject.edgeSubmissions == 1, "one ask charged to the edge's budget, not three")
        #expect(subject.pendingRequest == scheduler.submitted.first,
                "and the slot holds exactly what the system was given — in memory, nowhere else")
    }

    /// The tail's own request silences the next background edge: one chain, not two asks.
    @Test func theTailsRequestSilencesTheNextBackgroundEdge() {
        let clock = MovableCompanionRefreshClock(Self.fixedNow)
        let (subject, scheduler) = registeredCoordinator(clock: clock)

        subject.appDidEnterBackground()
        clock.now = Self.fixedNow.addingTimeInterval(60)
        scheduler.deliver(FakeCompanionRefreshTaskHandle())
        clock.now = Self.fixedNow.addingTimeInterval(120)
        let events = auditedEvents { subject.appDidEnterBackground() }

        #expect(scheduler.submitted.count == 2, "the edge's ask and the tail's — and not a third")
        #expect(scheduler.submitted.last?.earliestBeginDate == Self.fixedNow
            .addingTimeInterval(60 + CompanionRefreshCoordinator.earliestBeginInterval),
            "the pending request is the TAIL's, dated from the delivery, and the later edge left it alone")
        #expect(events == ["companionRefresh.edgeFoundARequestAlreadyPending"],
                "the edge found the tail's request already pending and said so")
        #expect(subject.edgeSubmissions == 1, "only the first edge ever spent the edge budget")
    }

    /// A refused tail leaves nothing pending, so the next background edge asks again.
    ///
    /// The other half of the rule, and the half that keeps it from being a silencer: the slot means
    /// "the system accepted one", so a refusal must leave it empty. If a refused ask latched the
    /// slot shut, one bad submission would end the chain for the whole launch.
    @Test func aRefusedTailLeavesNothingPendingAndTheNextEdgeAsksAgain() {
        let clock = MovableCompanionRefreshClock(Self.fixedNow)
        let (subject, scheduler) = registeredCoordinator(clock: clock)

        subject.appDidEnterBackground()
        scheduler.submitRefusal = FakeCompanionRefreshRefusal()
        clock.now = Self.fixedNow.addingTimeInterval(60)
        scheduler.deliver(FakeCompanionRefreshTaskHandle())
        scheduler.submitRefusal = nil
        clock.now = Self.fixedNow.addingTimeInterval(120)
        subject.appDidEnterBackground()

        #expect(scheduler.submitted.count == 2, "the first edge's ask, and the one after the refused tail")
        #expect(scheduler.submitted.last?.earliestBeginDate == Self.fixedNow
            .addingTimeInterval(120 + CompanionRefreshCoordinator.earliestBeginInterval),
            "dated from the edge that asked, because the refused tail left nothing standing")
        #expect(subject.edgeSubmissions == 2, "both edges spent the budget; neither was silenced")
        #expect(subject.pendingRequest == scheduler.submitted.last, "and the slot holds the accepted one")
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

    /// The EDGE bound is real, and reaching it is audited rather than silent (R2).
    ///
    /// Driven through refusals, because with the pending-slot rule that is the only way an edge
    /// storm exists at all: an accepted ask latches the slot until a delivery, so sixty-four
    /// ACCEPTED edge submissions in one launch cannot happen. A refused ask leaves nothing pending
    /// and the next edge asks again — which is exactly the pathological shape this cap is for, and
    /// no longer the ordinary one it used to bound.
    @Test func theEdgeSubmissionBoundHoldsAndSaysSoWhenItIsReached() {
        let (subject, scheduler) = registeredCoordinator()
        scheduler.submitRefusal = FakeCompanionRefreshRefusal()
        let cap = CompanionRefreshCoordinator.maxEdgeSubmissionsPerLaunch

        // R2: bounded by the cap.
        for _ in 0..<cap { subject.appDidEnterBackground() }
        let events = auditedEvents { subject.appDidEnterBackground() }

        #expect(subject.edgeSubmissions == cap, "the bound is the bound")
        #expect(subject.submissions == cap, "and every one of them was a real ask through the seam")
        #expect(scheduler.submitted.isEmpty, "all refused, which is why the edge kept asking")
        #expect(events == ["companionRefresh.edgeSubmissionCapReached"],
                "and a launch that hit it has something to say")
    }

    /// **The handler's tail is exempt from the edge cap**, so a spent edge budget does not kill the
    /// chain.
    ///
    /// The cap it used to share was a lifetime budget over BOTH triggers, and that is fatal rather
    /// than merely wrong: iOS keeps a suspended process alive for days, so the sixty-fifth ask ends
    /// the chain permanently with one audit line and no way back. Every tail submission stands
    /// behind a delivery the system chose to make, so it is already metered by iOS — and this drives
    /// one more delivery than the cap to prove the budget is not consulted.
    @Test func theHandlerTailKeepsTheChainAliveAfterTheEdgeBudgetIsSpent() {
        let (subject, scheduler) = registeredCoordinator()
        let cap = CompanionRefreshCoordinator.maxEdgeSubmissionsPerLaunch
        scheduler.submitRefusal = FakeCompanionRefreshRefusal()
        // R2: bounded by the cap.
        for _ in 0..<cap { subject.appDidEnterBackground() }
        scheduler.submitRefusal = nil

        subject.appDidEnterBackground()
        #expect(scheduler.submitted.isEmpty, "the edge trigger is off for this process now")

        // R2: bounded by the cap.
        for delivery in 0..<(cap + 1) {
            scheduler.deliver(FakeCompanionRefreshTaskHandle())
            #expect(scheduler.submitted.count == delivery + 1, """
                delivery \(delivery + 1) of \(cap + 1) re-submitted from the tail. A tail that \
                counted against the edge budget would have stopped at the first one and the chain \
                would be over for the life of the process.
                """)
        }
        #expect(subject.edgeSubmissions == cap, "and not one tail submission was charged to the edge")
    }

    // MARK: - Exactly once

    /// **The table.** One delivered task is completed exactly once, whatever order the system drives.
    ///
    /// Five rows, each an order that really happens: the ordinary run; the coordinator's own expiry
    /// door after the run; that door twice; the SYSTEM's installed expiration handler firing after the
    /// run (the common one — the grant is spent while the app is tearing down); and that twice. Every
    /// row asserts the WHOLE completion list rather than its count, so a row that completed `false`
    /// where it owed `true` is a red rather than a pass.
    ///
    /// The sixth order — an expiration landing while the task is still HELD, before the tail — needs
    /// a differently typed handle to drive, so it is
    /// ``anExpirationBeforeTheTailCompletesOnceAndTheChainStillContinues()`` rather than a row here.
    /// All five below meet a coordinator that is already holding nothing.
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

    /// **An expiration that lands BEFORE the tail** completes once, and the chain still continues.
    ///
    /// The sixth order, and the one the table above cannot carry: its five rows all expire after the
    /// handler has returned, so every one of them meets a coordinator holding nothing. This is the
    /// row where the grant runs out while the task is still in hand — the shape item 4's pipeline
    /// makes ordinary — and it is driven through the re-entrant fake for the same reason the
    /// absorbed-delivery cell is, which is why it is a cell of its own rather than a sixth row over
    /// a differently typed handle.
    ///
    /// Two claims. The expiry completes the task `false` and the tail must NOT complete it again.
    /// And the tail still ASKS: a run that expired is exactly a run whose successor matters, so the
    /// re-submission is unconditional on the outcome.
    @Test func anExpirationBeforeTheTailCompletesOnceAndTheChainStillContinues() {
        let (subject, scheduler) = registeredCoordinator()
        let holder = ReentrantFakeCompanionRefreshTaskHandle()
        holder.whileHeld = { subject.taskDidExpire() }

        let events = auditedEvents { subject.taskWasDelivered(holder) }

        #expect(holder.completions == [false], """
            completed once, by the expiry, and unsuccessfully — a second entry is the leak the \
            exactly-once invariant exists to prevent, and it is the tail that would add it.
            """)
        #expect(subject.isHoldingTask == false, "and nothing is still owed")
        #expect(scheduler.submitted.count == 1,
                "the tail re-submits whatever the run's outcome was — a run that expired is a run whose successor matters")
        #expect(events == ["companionRefresh.submitted", "companionRefresh.completedWithNoTaskInHand"],
                "and the tail's own completion, finding the handle already gone, says so rather than completing twice")
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
    /// stop modelling either task — which is the whole reason the decision row exists.
    ///
    /// **Frozen BODIES rather than a count of `func `.** The first shape of this cell counted the
    /// word `func` in each brace-matched body, which sees exactly one kind of growth: a
    /// `var companionRefreshIsPending: Bool { get }` added to `ContinuationTaskHandle` is a new
    /// requirement every conformer must answer, and that cell stayed green over it — no rebuild
    /// needed to find out, since a count of one word cannot notice another. A frozen body reds on
    /// ANY change to either protocol, and prints the two strings so the reader can see which. The
    /// protocol COUNT is pinned beside them for the same reason the bodies are: a third protocol in
    /// that file would otherwise be an unwatched seam.
    ///
    /// Re-freezing is a decision, not an edit: the string below is what the mesh's seam looked like
    /// when the refresh got its own, and a deliberate change to the mesh updates it in the commit
    /// that makes the change, with the argument in the message.
    @Test func theMeshSeamGainedNoMemberForTheRefreshTask() throws {
        let mesh = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/MeshContinuationScheduling.swift"))

        #expect(mesh.components(separatedBy: "protocol ").count - 1 == Self.frozenMeshProtocols.count,
                """
                the mesh's seam declares a number of protocols this pin does not name. Freeze the \
                new one here in the same commit, or it is a seam nothing watches.
                """)

        // R2: bounded by the frozen list.
        for frozen in Self.frozenMeshProtocols {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: frozen.signature, in: mesh),
                                    "`\(frozen.signature)` is gone from the mesh's seam")
            #expect(Self.normalisedBody(body) == frozen.body, """
                `\(frozen.signature)`'s body is not the one frozen at P10 item 3.
                frozen: \(frozen.body)
                found:  \(Self.normalisedBody(body))
                A member added here — a `func`, a `var`, a `subscript`, anything — is the mesh's \
                seam being widened, and the companion refresh must not be why.
                """)
        }

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

    /// **Nothing spins, and nothing persists — and the WALL is where that is enforced.**
    ///
    /// This cell used to carry its own ten-needle list, which is how the prohibition was true of
    /// three named files and of nothing else: item 4's handler lands in the same directory and was
    /// outside it, because a hand-listed path list is a wall over those paths. The needles now live
    /// in `BackgroundRefreshBoundaryTests.forbiddenSpellings` as their own family, beside the mesh /
    /// HealthKit / CloudKit ones, where the scan walks the DIRECTORY and covers a file the moment it
    /// exists.
    ///
    /// One home, so the two suites cannot drift: what is pinned here is that the family EXISTS by
    /// name and still has its measured size, and that the wall's own walk really does reach this
    /// seam's files — a family over a directory nothing scans would be as vacuous as the list it
    /// replaced. `Task {` is deliberately not a needle in it: the seam's one use is the actor hop
    /// the system's off-actor callbacks require, which is a jump, not a loop. Neither is `Date()` —
    /// reading the clock is not scheduling on one, and ``CompanionRefreshCoordinator`` has to read
    /// it to state a floor at all.
    @Test func theClockAndPersistenceWallCoversThisSeamsOwnFiles() throws {
        let scanned = try BackgroundRefreshBoundaryTests.swiftFiles().map(\.path)
        // R2: bounded by the three-file list.
        for path in ["App/Fernlet/CompanionRefresh/CompanionRefreshIdentifier.swift",
                     "App/Fernlet/CompanionRefresh/CompanionRefreshScheduling.swift",
                     "App/Fernlet/CompanionRefresh/CompanionRefreshCoordinator.swift"] {
            #expect(scanned.contains(path), """
                \(path) is outside `BackgroundRefreshBoundaryTests`' walk, so every needle it \
                holds passes vacuously over this seam.
                """)
        }

        let family = BackgroundRefreshBoundaryTests.forbiddenSpellings
            .filter { $0.why.hasPrefix(BackgroundRefreshBoundaryTests.clockAndPersistenceReasonPrefix) }
        #expect(family.count == BackgroundRefreshBoundaryTests.measuredClockAndPersistenceCount, """
            the clock-and-persistence family holds \(family.count) needle(s), measured \
            \(BackgroundRefreshBoundaryTests.measuredClockAndPersistenceCount). This seam's "no \
            clock, no persisted surface" claim is that family; retiring a row from it is a \
            decision with an argument, not an edit.
            """)
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
        #expect(identifiers.contains("MBO.Fernlet.companion-refresh"),
                "iOS matches this literally; without the entry the task registers and is never delivered")
        #expect(CompanionRefresh.taskIdentifier == "MBO.Fernlet.companion-refresh",
                "and the constant the app registers is that same literal — the two are pinned apart on purpose")
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
