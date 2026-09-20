// MeshContinuationTaskHostTests.swift
// FernletTests
//
// Network migration P8 item 6: the task wiring, driven end to end through two fakes, plus the wall
// that keeps the host on its own side of every P7 boundary.
//
// **Why fakes at all.** `BGTaskScheduler` refuses a continued-processing submission on a Simulator
// outright (error 1) and nothing can make iOS deliver a task to a unit test, so a host written
// against the framework would have zero tier-1 coverage of the five things item 6 IS: register,
// submit, expire, cancel, and complete EXACTLY ONCE. `BackgroundContinuationScheduling` and
// `ContinuationTaskHandle` exist for this suite; `BGTaskSchedulerContinuationScheduler` and
// `BGContinuationTaskHandle` are the untested remainder and are item 9's device rows.
//
// **What only a device can prove**, and is therefore claimed nowhere below: that the registration is
// accepted by the real scheduler, that a `.fail` submission is granted, that the launch handler
// fires, that the expiration handler fires, and that the QUIC tunnel survives the whole of it.
//
// **The fix round adds the scene** (F2). A continued-processing task is delivered promptly after the
// submission, normally while the app is still ON SCREEN, so the host holds the one decided-once
// foreground fact and hands it to the driver at the delivery: adopted at once, raised only once the
// scene is dark. The observable for a raise in this suite is the manager's own refusal latch — the
// mesh here has no session, so a raise that was made is refused by name and a raise that was never
// made leaves it nil — while the COUNT of raises is the driver sweep's.

@testable import Fernlet
import Foundation
@testable import ProximityKit
import Testing

// MARK: - The fakes

/// A `ContinuationTaskHandle` that records rather than talks to `BackgroundTasks`.
@MainActor
final class FakeContinuationTaskHandle: ContinuationTaskHandle {

    /// Every `setTaskCompleted(success:)` this handle was given, in order. A second entry is the
    /// bug the exactly-once invariant exists to prevent.
    private(set) var completions: [Bool] = []

    /// Every progress reading written to it.
    private(set) var progressReadings: [MeshContinuationProgress] = []

    /// Every re-render of the two sentences.
    private(set) var renderedCopy: [String] = []

    /// The expiration handler the host installed, so a test can be the system.
    private(set) var expirationHandler: (@MainActor @Sendable () -> Void)?

    func reportContinuationProgress(_ progress: MeshContinuationProgress) {
        progressReadings.append(progress)
    }

    func updateContinuationCopy(title: String, subtitle: String) {
        renderedCopy.append("\(title)|\(subtitle)")
    }

    func setContinuationExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        expirationHandler = handler
    }

    func completeContinuationTask(success: Bool) {
        completions.append(success)
    }
}

/// A refusal a fake scheduler can be told to answer with.
struct FakeSchedulerRefusal: Error, Equatable {}

/// A `BackgroundContinuationScheduling` that records, and that can be told to refuse.
@MainActor
final class FakeContinuationScheduler: BackgroundContinuationScheduling {

    /// Whether `register` answers `true`.
    var registrationAccepted = true

    /// What `submit` throws, or nil to accept.
    var submitRefusal: FakeSchedulerRefusal?

    private(set) var registered: [String] = []
    private(set) var submitted: [ContinuationTaskRequest] = []
    private(set) var cancelled: [String] = []

    /// The launch handler the host installed, so a test can be the system delivering a task.
    private var launchHandler: (@MainActor (any ContinuationTaskHandle) -> Void)?

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuationTaskHandle) -> Void
    ) -> Bool {
        registered.append(identifier)
        guard registrationAccepted else { return false }
        self.launchHandler = launchHandler
        return true
    }

    func submit(_ request: ContinuationTaskRequest) throws {
        if let submitRefusal { throw submitRefusal }
        submitted.append(request)
    }

    func cancel(identifier: String) {
        cancelled.append(identifier)
    }

    /// Delivers a task the way iOS would.
    ///
    /// - Parameter handle: The handle to deliver.
    func deliver(_ handle: any ContinuationTaskHandle) {
        launchHandler?(handle)
    }
}

// MARK: - The wiring

/// Item 6's five acts — register, submit, expire, cancel, complete once — over the two fakes.
@MainActor
@Suite(.serialized)
struct MeshContinuationTaskHostTests {

    private let store = makeTestStore()
    private let meshID = UUID()

    /// A host over a fresh manager with no session, and the scheduler it speaks to.
    ///
    /// - Returns: The host and its fake scheduler.
    private func hostOverAnIdleMesh() -> (host: MeshContinuationTaskHost, scheduler: FakeContinuationScheduler) {
        let scheduler = FakeContinuationScheduler()
        let host = MeshContinuationTaskHost(
            store: store, meshNetworkManager: store.meshNetworkManager, scheduler: scheduler
        )
        return (host, scheduler)
    }

    /// A host that has founded a mesh and committed its first peer — the state in which the system
    /// may deliver a task.
    ///
    /// - Returns: The host, its scheduler, and the identifier it registered.
    private func hostWithARequestIn() -> (
        host: MeshContinuationTaskHost, scheduler: FakeContinuationScheduler, identifier: String
    ) {
        let (host, scheduler) = hostOverAnIdleMesh()
        host.meshDidStart(meshID: meshID, hasCommittedPeer: false)
        host.committedPeerDidChange(hasPeer: true)
        return (host, scheduler, MeshContinuationTaskHost.identifier(for: meshID))
    }

    // MARK: Registration and submission

    /// A founded mesh registers ITS OWN identifier — the concrete one, inside the plist wildcard —
    /// and asks for nothing yet.
    @Test func aFoundedMeshRegistersItsConcreteIdentifierAndSubmitsNothingYet() {
        let (host, scheduler) = hostOverAnIdleMesh()

        host.meshDidStart(meshID: meshID, hasCommittedPeer: false)

        #expect(scheduler.registered == [MeshContinuationTaskHost.identifier(for: meshID)],
                "the identifier is the mesh's own, so two meshes never share a claim")
        #expect(host.registeredIdentifier == scheduler.registered.first, "and the host holds it")
        #expect(scheduler.submitted.isEmpty,
                "a mesh with nobody on it has nothing to continue — the request waits for a commit")
        #expect(store.meshContinuationState == .idle, "and the card says nothing")
    }

    /// The first committed peer is the submission instruction, and the request carries the rendered
    /// copy — not a `String` literal, which would be English forever with a clean build.
    @Test func theFirstCommittedPeerSubmitsOneRequestCarryingTheRenderedCopy() {
        let (host, scheduler, identifier) = hostWithARequestIn()
        let expected = MeshContinuationCopy.card(friendCount: 0)

        #expect(scheduler.submitted.count == 1, "exactly one request, on the 0 → 1 edge")
        #expect(scheduler.submitted.first?.identifier == identifier, "for this mesh's identifier")
        #expect(scheduler.submitted.first?.title == String(localized: expected.title),
                "the title is rendered from the catalog resource, at the submit site")
        #expect(scheduler.submitted.first?.subtitle == String(localized: expected.subtitle),
                "and so is the subtitle")
        #expect(host.driver.state == .requested, "the claim is in")
        #expect(store.meshContinuationState == .requested, "and the run policy has been fed it")
    }

    /// A second commit edge submits nothing more: the instruction is the ENTRY into `requested`, so
    /// a peer that blipped and came back does not queue a second request.
    @Test func aSecondCommitEdgeSubmitsNothingMore() {
        let (host, scheduler, _) = hostWithARequestIn()

        host.committedPeerDidChange(hasPeer: false)
        host.committedPeerDidChange(hasPeer: true)

        #expect(scheduler.submitted.count == 1, "still one request for one claim")
        #expect(host.submissions == 1, "and the per-session counter agrees")
    }

    /// **Order independence.** A mesh founds itself AT its first commit, so both observers fire in
    /// one transaction and SwiftUI orders neither. Whichever arrives first, exactly one request is
    /// submitted — and the commit-first order is the one that used to lose the claim entirely.
    @Test func aCommitThatArrivesBeforeItsMeshEdgeStillSubmitsExactlyOnce() {
        let (host, scheduler) = hostOverAnIdleMesh()

        host.committedPeerDidChange(hasPeer: true)
        #expect(scheduler.submitted.isEmpty, "nothing can be submitted before an identifier exists")

        host.meshDidStart(meshID: meshID, hasCommittedPeer: true)

        #expect(scheduler.submitted.count == 1, "the mesh edge picks the commit up and asks once")
        #expect(host.driver.state == .requested, "and the claim is in")
    }

    /// A refused registration is named, nothing is submitted against it — an identifier the system
    /// never accepted can never deliver a task — **and the claim is refused OUT LOUD** (the fix
    /// round's F4): leaving it on `requested` showed the person no card at all, when what is true is
    /// that this session stays open only while Fernlet is on screen.
    @Test func aRefusedRegistrationLeavesNothingToSubmitAgainstAndRefusesOutLoud() {
        let (host, scheduler) = hostOverAnIdleMesh()
        scheduler.registrationAccepted = false

        host.meshDidStart(meshID: meshID, hasCommittedPeer: true)

        #expect(scheduler.registered.count == 1, "it was attempted")
        #expect(host.registeredIdentifier == nil, "and refused, so the host holds none")
        #expect(scheduler.submitted.isEmpty, "nothing is asked for against an unregistered identifier")
        #expect(host.driver.state == .refused, "and the claim MOVED rather than returning silently")
        #expect(store.meshContinuationState == .refused, "the run policy is fed the refusal")
        #expect(store.meshContinuationLastAudit == .refused, "named by its own frozen token")
        let card = MeshContinuationCardPresentation.card(
            state: store.meshContinuationState, lastAudit: store.meshContinuationLastAudit
        )
        #expect(card?.kind == .refused, "and the person is told, which is the whole of F4")
    }

    /// The ninth identifier in one process is refused rather than growing the set (Power of 10, R2)
    /// — and that refusal reaches the card too (the fix round's F4).
    @Test func theNinthIdentifierIsRefusedOutLoudRatherThanSilently() {
        let (host, scheduler) = hostOverAnIdleMesh()
        // R2: bounded by the registration cap.
        for _ in 0..<MeshContinuationTaskHost.maxRegisteredIdentifiers {
            host.meshDidStart(meshID: UUID(), hasCommittedPeer: false)
        }
        #expect(scheduler.registered.count == MeshContinuationTaskHost.maxRegisteredIdentifiers,
                "the precondition: the cap is full")

        host.meshDidStart(meshID: UUID(), hasCommittedPeer: true)

        #expect(scheduler.registered.count == MeshContinuationTaskHost.maxRegisteredIdentifiers,
                "the ninth is not even attempted — the set does not grow without bound")
        #expect(host.registeredIdentifier == nil, "so there is nothing to submit against")
        #expect(host.driver.state == .refused,
                "and the person is told the session stays open only while Fernlet is on screen")
        #expect(store.meshContinuationLastAudit == .refused, "with the refusal's own token")
    }

    /// A refused SUBMISSION is a move of the claim, not a swallowed error: the person is owed the
    /// sentence that this session only lasts while Fernlet is on screen.
    @Test func aRefusedSubmissionLandsTheClaimOnRefusedAndReachesTheCard() {
        let (host, scheduler) = hostOverAnIdleMesh()
        scheduler.submitRefusal = FakeSchedulerRefusal()
        host.meshDidStart(meshID: meshID, hasCommittedPeer: false)

        host.committedPeerDidChange(hasPeer: true)

        #expect(host.driver.state == .refused, "the refusal moved the claim")
        #expect(store.meshContinuationState == .refused, "the store carries it")
        #expect(store.meshContinuationLastAudit == .refused, "with the token that names it")
        let card = MeshContinuationCardPresentation.card(
            state: store.meshContinuationState, lastAudit: store.meshContinuationLastAudit
        )
        #expect(card?.kind == .refused, "and item 7's card is the refusal's own")
    }

    /// The per-session submission cap is a real bound (Power of 10, R2) — item 4's
    /// `running + appForegrounded → requested` row re-arms on every foreground return, and a
    /// Control-Centre peek is one of those (the fix round's F5, recorded as device row F12) — **and
    /// reaching it is a refusal, not a silence** (the fix round's F4).
    ///
    /// The loop delivers only while a request is actually in, because the system delivers a task
    /// only against a request that was submitted; past the cap there is none.
    @Test func theSubmissionCapBoundsOneSessionAndRefusesOutLoud() {
        let (host, scheduler, _) = hostWithARequestIn()

        // R2: bounded by the cap plus the overrun this asserts.
        for _ in 0..<(MeshContinuationTaskHost.maxSubmissionsPerSession + 2) {
            guard host.driver.state == .requested else { continue }
            scheduler.deliver(FakeContinuationTaskHandle())
            host.appForegroundDidChange(true)
        }

        #expect(scheduler.submitted.count == MeshContinuationTaskHost.maxSubmissionsPerSession,
                "a person switching in and out of Fernlet all afternoon cannot submit without bound")
        #expect(host.submissions == MeshContinuationTaskHost.maxSubmissionsPerSession,
                "and the per-session counter agrees with what was asked")
        #expect(host.driver.state == .refused,
                "the asking stops OUT LOUD: the claim leaves `requested`, so item 7's card has something to say")
        #expect(store.meshContinuationLastAudit == .refused, "named by the refusal's own frozen token")
    }

    // MARK: Delivery, expiry and the one completion

    /// **Exactly once.** A claimed task is held, completed `true` when the person comes back, and a
    /// second foreground edge completes nothing — the probe's `completeBackgroundTask` idiom, with
    /// the duplicate guard supplied by `consumePendingCompletion()` answering nil on a second read.
    @Test func aClaimedTaskIsCompletedOnceOnTheForegroundReturnAndNeverTwice() {
        let (host, scheduler, _) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()

        scheduler.deliver(handle)
        #expect(host.isHoldingTask, "the task is in hand")
        #expect(host.driver.state == .running, "and the claim says so")
        #expect(store.meshContinuationState == .running, "as does the run policy's input")

        host.appForegroundDidChange(true)
        #expect(handle.completions == [true],
                "the session was carried to the foreground, so the task succeeded")
        #expect(!host.isHoldingTask, "and the handle was dropped in the same turn it was completed")

        host.appForegroundDidChange(true)
        host.appForegroundDidChange(true)
        #expect(handle.completions == [true], "a second ending completes nothing — there is nothing owed")
    }

    /// **The scene gates the raise, not the adoption** (the fix round's F2). A task delivered while
    /// the app is still on screen — the normal shape, since the system answers a submission
    /// promptly — is held at once and tells the mesh NOTHING until the person leaves.
    ///
    /// The observable is the manager's own refusal latch: this host's mesh has no session, so a
    /// raise that reaches the session machine is refused BY NAME (`noSessionYet`) and a raise that
    /// was never made leaves it nil. Two different values, rather than one silence.
    @Test func aTaskDeliveredWhileTheAppIsOnScreenRaisesNothingUntilTheSceneGoesDark() {
        let (host, scheduler, _) = hostWithARequestIn()
        let manager = store.meshNetworkManager
        #expect(manager.lastSessionTransitionRejection == nil,
                "the precondition: the session machine has been offered nothing")

        scheduler.deliver(FakeContinuationTaskHandle())

        #expect(host.isHoldingTask, "the handle is adopted at once — an unadopted one is uncompletable")
        #expect(manager.lastSessionTransitionRejection == nil,
                "but nothing was raised: the person is still looking at Fernlet")

        host.appForegroundDidChange(false)

        #expect(manager.lastSessionTransitionRejection == .noSessionYet,
                "the scene's dark edge is what raises `begin`, and this host feeds that fact")
    }

    /// A delivery that arrives with the scene ALREADY dark — the person left before the system
    /// answered — raises at once, with no second edge needed.
    @Test func aTaskDeliveredIntoADarkSceneRaisesAtOnce() {
        let (host, scheduler, _) = hostWithARequestIn()
        host.appForegroundDidChange(false)
        #expect(store.meshNetworkManager.lastSessionTransitionRejection == nil,
                "the precondition: a dark scene with no task in hand raises nothing")

        scheduler.deliver(FakeContinuationTaskHandle())

        #expect(store.meshNetworkManager.lastSessionTransitionRejection == .noSessionYet,
                "the host held the foreground fact across the gap, so the delivery raises immediately")
        #expect(host.isHoldingTask, "and the task is in hand")
    }

    /// A task that comes and goes while the app is on screen raises NEITHER half of the pair, and
    /// is still completed exactly once: the gating moves the raises, never the debt.
    @Test func aTaskThatEndsBeforeTheSceneWentDarkRaisesNothingAndIsCompletedOnce() {
        let (host, scheduler, identifier) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)

        host.meshDidEnd()

        #expect(handle.completions == [true], "the system is paid exactly once, on the app's terms")
        #expect(store.meshNetworkManager.lastSessionTransitionRejection == nil,
                "and the session machine was never offered either raise")
        #expect(scheduler.cancelled == [identifier], "with nothing left pending for a dead mesh")
    }

    /// An ownerless delivery is completed `false` at once and presents NOTHING: "iOS ended your
    /// background session" is a sentence about a session that never existed.
    @Test func anOwnerlessDeliveryIsCompletedFalseAtOnceAndPresentsNothing() {
        let (host, scheduler) = hostOverAnIdleMesh()
        host.meshDidStart(meshID: meshID, hasCommittedPeer: false)
        let handle = FakeContinuationTaskHandle()

        scheduler.deliver(handle)

        #expect(handle.completions == [false], "ended at once, and exactly once")
        #expect(!host.isHoldingTask, "nothing is still owed")
        #expect(store.meshContinuationState == .idle, "and the projection is back to silence")
        #expect(store.meshContinuationLastAudit == nil, "with no token to build a card from")
    }

    /// A second delivery while a task is in hand is completed `false` and dropped; the first handle
    /// is untouched, because the claim did not move.
    @Test func aSecondDeliveryIsCompletedFalseAndTheHeldTaskIsUntouched() {
        let (host, scheduler, _) = hostWithARequestIn()
        let first = FakeContinuationTaskHandle()
        let second = FakeContinuationTaskHandle()
        scheduler.deliver(first)

        scheduler.deliver(second)

        #expect(second.completions == [false], "the handle this host cannot keep is completed, not leaked")
        #expect(first.completions.isEmpty, "and the one it holds is untouched")
        #expect(host.isHoldingTask, "the claim still owns exactly one task")
    }

    /// The system's expiration handler ends the task `false` and the card names the expiry.
    @Test func theExpirationHandlerCompletesTheTaskFalseAndPresentsTheExpiry() throws {
        let (host, scheduler, _) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)
        let expire = try #require(handle.expirationHandler, "the host installed no expiration handler")

        expire()

        #expect(!host.isHoldingTask, "the handle was dropped in the turn it was completed")
        #expect(handle.completions == [false], "the granted time was spent, so the work did not finish")
        #expect(store.meshContinuationState == .expired, "the claim is spent")
        #expect(store.meshContinuationLastAudit == .expired, "named by its own token")
        let card = MeshContinuationCardPresentation.card(
            state: store.meshContinuationState, lastAudit: store.meshContinuationLastAudit
        )
        #expect(card?.kind == .expired, "and the Friends card is the expiry's")
    }

    /// A session ending completes the task `succeeded` and withdraws any pending request.
    @Test func theSessionEndingCompletesTheTaskSucceededAndWithdrawsTheRequest() {
        let (host, scheduler, identifier) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)

        host.meshDidEnd()

        #expect(handle.completions == [true], "the work the task carried is over on the app's terms")
        #expect(scheduler.cancelled == [identifier], "and nothing is left pending for a dead mesh")
        #expect(store.meshContinuationState == .completed, "the claim is terminal")
    }

    /// A NEW mesh completes the stale task `false` before anything else: the un-completed task of a
    /// dead mesh is the leak exactly-once exists to prevent. The projection resets with it.
    @Test func aNewMeshCompletesTheStaleTaskFalseAndResetsTheProjection() {
        let (host, scheduler, _) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)

        host.meshDidStart(meshID: UUID(), hasCommittedPeer: false)

        #expect(handle.completions == [false], "the previous mesh's task is paid off")
        #expect(scheduler.registered.count == 2, "and the new mesh registers its own identifier")
        #expect(store.meshContinuationState == .idle, "the claim starts over")
        #expect(store.meshContinuationLastAudit == nil,
                "and says nothing about the mesh that is gone")
    }

    /// **The hard stop** (delete-all's leg 0 bracket, leg 7b's continuation half): the debt is paid
    /// FIRST, the request withdrawn, and the card silenced.
    @Test func theHardStopPaysTheDebtWithdrawsTheRequestAndSilencesTheCard() {
        let (host, scheduler, identifier) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)

        host.proximityHardStopWillBegin()

        #expect(handle.completions == [false],
                "a wipe does not excuse the app from completing a task it is holding")
        #expect(scheduler.cancelled == [identifier], "nothing is left pending on an emptied device")
        #expect(store.meshContinuationState == .idle, "and the Friends card says nothing at all")
        #expect(store.meshContinuationLastAudit == nil)
        #expect(host.submissions == 0, "the per-session counter starts over with the next mesh")
    }

    // MARK: Progress

    /// The bar rides the poller's tick and nothing else: no handle, or no live session, and nothing
    /// is written at all.
    @Test func aTickWithNoTaskInHandWritesNoProgress() {
        let (host, _) = hostOverAnIdleMesh()
        host.meshDidStart(meshID: meshID, hasCommittedPeer: true)

        host.sessionPollerDidTick()

        #expect(!host.isHoldingTask, "the precondition")
    }

    /// With a ceiling armed and a task in hand, one tick writes one reading and re-renders the card.
    @Test func oneTickWritesOneReadingAndReRendersTheCard() {
        let (host, scheduler, _) = hostWithARequestIn()
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)
        store.meshNetworkManager.startSessionCeiling(
            hardDeadline: Date().addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            startedAt: Date()
        )

        host.sessionPollerDidTick()

        #expect(handle.progressReadings.count == 1, "one tick, one reading — there is no second clock")
        #expect((handle.progressReadings.first?.fraction ?? 1) < 1,
                "and the bar never claims the work is finished")
        #expect(handle.renderedCopy.count >= 1, "the two sentences are re-rendered with it")
    }

    /// The reading the kit answers is the narrow one, and it is nil with no session to continue.
    @Test func theSessionReadingIsNilWithNoCeilingArmed() {
        #expect(store.meshNetworkManager.sessionContinuationReading == nil,
                "no ceiling, no session to continue, nothing to advance a bar for")
    }
}

// MARK: - The wall

/// **Item 6's wall.** The `BackgroundTasks` framework has one home, the host speaks no radio verb and
/// no gate, the feed is its only route to a radio, the funnel never calls it back, the mesh raises no
/// Live Activity, and the concrete identifier is inside the plist's wildcard.
///
/// P9 item 5 added cell (g): the mesh's door was only half the claim, and the other half — the
/// coordinator's DEFAULT anchor, which the 1:1 paths take — is now the no-op too, so the app raises
/// no proximity Live Activity anywhere.
struct MeshContinuationTaskHostWallTests {

    /// The one app file allowed to name the framework, outside the DEBUG feasibility probe.
    private static let seam = "MeshContinuationScheduling.swift"

    /// The DEBUG spike, exempt by name — it is `#if DEBUG`-walled and registers its own identifier.
    private static let probe = "NetworkMeshFeasibilityProbe.swift"

    /// The host.
    private static let host = "MeshContinuationTaskHost.swift"

    /// Every `.swift` file under one repo-relative directory, comment-stripped.
    ///
    /// Reused from `MeshP7Acceptance`, as `MeshContinuationRaiseWallTests` already does — a sixth
    /// copy of the same walker would be a sixth thing to keep in step.
    private static func codeSources(under relativePath: String) throws -> [(name: String, code: String)] {
        try MeshP7Acceptance.sources(under: relativePath)
    }

    /// The file names in which `needle` occurs, one entry per occurrence.
    private static func homes(of needle: String, in sources: [(name: String, code: String)]) -> [String] {
        MeshP7Acceptance.homes(of: needle, in: sources)
    }

    /// **(a)** `BackgroundTasks` is reachable from exactly two files: item 6's seam and the DEBUG
    /// probe. A third would mean something other than the host is scheduling work.
    @Test func theBackgroundTasksFrameworkHasTwoHomesInTheApp() throws {
        let app = try Self.codeSources(under: "App")
        #expect(app.count >= 100, "the app-target scan lost its files")
        #expect(Set(Self.homes(of: "import BackgroundTasks", in: app)) == [Self.seam, Self.probe],
                "the framework is imported by the seam and by the DEBUG probe, and by nothing else")
        #expect(Set(Self.homes(of: "BGTaskScheduler", in: app)) == [Self.seam, Self.probe],
                "and the scheduler is named in the same two places")
        #expect(Set(Self.homes(of: "BGContinuedProcessingTask", in: app)) == [Self.seam, Self.probe],
                "as is the task type")
        #expect(Self.homes(of: "BGTaskScheduler", in: app).filter { $0 == Self.host }.isEmpty,
                "the host speaks the seam's protocols, never the framework")
    }

    /// **(b)** The host is wiring, not a radio: no verb, no gate, no listener, no clock, no
    /// persisted surface — and neither raise, which stays in the driver beside it.
    @Test func theHostSpeaksNoRadioVerbNoGateAndNoRaise() throws {
        let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/\(Self.host)"))
        #expect(!code.isEmpty, "the host is gone")
        let forbidden = [
            "applyRoutedAccessGate(", "MeshRoutedAccessGate(",          // W8: the gate has one writer
            ".startJoin(", ".stopJoin(", ".resumeSearchingForPartitionedMesh(",
            ".holdCommittedLinks(", ".leaveSession()", ".endSessionAfterDiscoveryTimeout(",
            "presenceManager.", "recipeShareManager.",                  // the retirement wall's listeners
            "beginBackgroundContinuation", "endBackgroundContinuation", // item 5's pair, driver-only
            "applySessionEvent(",                                       // and its internal spelling
            "Timer", "DispatchQueue",                                   // nothing spins (ML1/ML4, R2)
            "UserDefaults",                                             // no persisted surface
            "reapplyProximityRunPolicy("                                // it FEEDS; the store re-runs
        ]
        // R2: bounded by the literal list.
        for needle in forbidden {
            #expect(!code.contains(needle), "the continuation host must not contain `\(needle)`")
        }
    }

    /// **(c)** The feed is the host's only route to a radio, and it has exactly one call site.
    @Test func theFeedIsTheHostsOnlyRouteToARadio() throws {
        let app = try Self.codeSources(under: "App")
        #expect(app.count >= 100, "the app-target scan lost its files")
        #expect(Self.homes(of: "setMeshContinuation(", in: app).sorted()
                == ["FernletStore.swift", Self.host],
                "declared once by the store, called once by the host, and by nobody else")
    }

    /// **(d)** The funnel never calls the host back.
    ///
    /// `setMeshContinuation(state:lastAudit:)` re-runs `runProximityPolicy`, so a host call from
    /// inside that body would re-enter it — and the OUTER pass would then diff its verdict against a
    /// `previous` the inner pass had already replaced, standing down a radio the inner pass had just
    /// started. Every edge into the host is outside the funnel, and this is what keeps it so.
    @Test func theFunnelNeverCallsTheHostBack() throws {
        let store = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletStore.swift"))
        let funnel = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func runProximityPolicy(", in: store),
            "the run-policy core is gone from the store")
        #expect(!funnel.contains("meshContinuationHost"),
                "the funnel reads the projection; it never drives the thing that writes it")
        #expect(funnel.contains("continuation: meshContinuationState.feed"),
                "and it IS fed the claim — P8 item 6's one line in this body")
    }

    /// **(e)** The mesh's shipping slot coordinator raises no `ProximityForegroundAnchor` Live
    /// Activity (plan §14: no duplicate UI beside the continued task's own system card).
    ///
    /// Brace-matched on the door that seats a channel, because the `Noop` injection two thousand
    /// lines away at `makeRetainedSlotCoordinatorForTesting` is a TEST seam and proves nothing about
    /// what a real session raises — which is exactly the reading that made this look already done.
    ///
    /// **What it buys is honest and small** (the fix round's F1): the requests were never renderable
    /// — the proximity attributes type is internal to ProximityKit and no widget in
    /// `App/FernletWidgets` declares an `ActivityConfiguration` for it — so a person sees no change
    /// on a phone. What goes away is up to five doomed `Activity.request` calls per session, each of
    /// which either threw or spent one of the per-app Live Activity slots a workout or cooking
    /// activity needs.
    ///
    /// Since P9 item 5 the coordinator's DEFAULT anchor is the no-op too (cell (g)), so this
    /// argument is belt to that braces. It is deliberately kept: the mesh's door should say what it
    /// raises without the reader having to know a default two files away.
    @Test func theMeshsSlotCoordinatorRaisesNoLiveActivity() throws {
        let manager = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift"))
        let door = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func handleChannelReady(", in: manager),
            "the channel-ready door is gone")
        #expect(door.contains("foregroundAnchor: NoopProximityForegroundAnchor()"),
                """
                a mesh seats up to five coordinators, and each was ATTEMPTING one `Activity.request` \
                — the duplicate §14 forbids, and, since none of them can render in this app, five \
                doomed calls rather than a card anyone ever saw
                """)
        let loader = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/FernletStoreLoader.swift"))
        #expect(loader.contains("endOrphans()"), "and the once-per-launch orphan reaper stays")
    }

    /// **(g)** P9 item 5: the 1:1 foreground anchors are RETIRED. Nothing in the app requests a
    /// proximity Live Activity; the once-per-launch orphan reaper is the only code that still names
    /// the attributes type.
    ///
    /// Cell (e) pinned the mesh's door. This pins the half P8 left open — the coordinator's
    /// DEFAULT anchor, which three shipping construction sites take by omitting the argument
    /// (`ProximityRecipeShareManager.handleChannelOpened`, `PresenceManager`'s heart door, and its
    /// teardown seam). Until P9 that default was the ActivityKit conformer, whose every request was
    /// doomed: the attributes type is internal to ProximityKit and
    /// `App/FernletWidgets/FernletWidgetsBundle.swift` declares no `ActivityConfiguration` for it,
    /// so each call either threw (audited) or spent a per-app Live Activity slot on something
    /// nothing draws.
    ///
    /// Four independently reddenable needles: re-adding a request reddens (1); restoring the class
    /// reddens (2); restoring the `#if canImport` default reddens (3); declaring a proximity
    /// configuration in the widget bundle reddens (4) — which is the honest signal that "retire"
    /// has been reversed and this cell must be rewritten rather than deleted.
    @Test func theOneToOneForegroundAnchorsAreRetired() throws {
        let anchorPath = "FernletKit/Sources/ProximityKit/ForegroundAnchor/ProximityForegroundAnchor.swift"
        let anchor = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(anchorPath))
        // (1) Nothing requests one any more; the reaper still ends what a prior process stranded.
        #expect(!anchor.contains("Activity.request"),
                "the retired 1:1 anchor was the only requester of a proximity Live Activity")
        #expect(anchor.contains("Activity<ProximityConnectionActivityAttributes>.activities"),
                "the orphan reaper stays — it is the one remaining reader of the attributes type")

        // (2) Neither the retired conformer nor the attributes type is spelled anywhere else in
        // shipping source, so no other file can construct or request one.
        let coordinatorPath = "FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift"
        let others = [
            coordinatorPath,
            "FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift",
            "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift",
            "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift"
        ]
        for path in others {
            let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path))
            #expect(!source.contains("ActivityKitProximityForegroundAnchor"),
                    "\(path) still names the retired ActivityKit anchor")
            #expect(!source.contains("ProximityConnectionActivityAttributes"),
                    "\(path) still names the proximity activity attributes; only the reaper may")
        }

        // (3) The coordinator's default is the no-op unconditionally — no ActivityKit branch left.
        let coordinator = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(coordinatorPath))
        #expect(!coordinator.contains("ActivityKit"),
                "the default anchor is unconditional; no `#if canImport` branch remains")
        #expect(coordinator.contains("foregroundAnchor ?? NoopProximityForegroundAnchor()"),
                "and the default it falls back to is the no-op")

        // (4) The widget bundle still declares no proximity configuration — "ship the widget"
        // cannot land half-done while this cell reads as passing.
        let bundle = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/FernletWidgets/FernletWidgetsBundle.swift"))
        #expect(!bundle.contains("Proximity"),
                "a proximity Live Activity configuration appeared; retire is no longer the decision")
    }

    /// **(f)** The concrete identifier is inside the plist's permitted wildcard, and no background
    /// mode was added for it.
    @Test func theConcreteIdentifierIsInsideThePlistWildcard() throws {
        let plist = try RepoRoot.source("App/Fernlet/Info.plist")
        #expect(plist.contains("<string>MBO.Fernlet.mesh-continuation.*</string>"),
                "the wildcard `BGTaskSchedulerPermittedIdentifiers` entry is still there")
        let identifier = MeshContinuationTaskHost.identifier(for: UUID())
        #expect(identifier.hasPrefix("MBO.Fernlet.mesh-continuation."),
                "and every identifier the host mints is under it — a UUID's characters are legal in one")
        #expect(!plist.contains("<string>processing</string>"),
                "a continued-processing task needs no `UIBackgroundModes` entry, and none was added")
    }
}
