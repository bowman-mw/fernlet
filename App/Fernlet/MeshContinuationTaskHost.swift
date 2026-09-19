// MeshContinuationTaskHost.swift
// Fernlet
//
// Network migration P8 item 6 (plan §14, §25.1): the thin object that owns the mesh's
// `BGContinuedProcessingTask` — registration, submission, the expiration handler, cancellation and
// **exactly-once** completion — and that feeds the run policy what it learned.
//
// **It is the object item 5's driver deliberately is not.** ``MeshContinuationDriver`` holds the
// claim and the two session-state raises and nothing else;
// `MeshContinuationRaiseWallTests.theDriverIsSessionStateOnly` forbids `BGTaskScheduler`,
// `BGContinuedProcessingTask`, `Task {`, `Timer`, `DispatchQueue` and `UserDefaults` in that file by
// list. This type is the other half, in its own file so that wall stays intact and green: it owns
// the driver, speaks ``BackgroundContinuationScheduling`` / ``ContinuationTaskHandle``, and lets the
// driver keep both raises (`MeshContinuationRaiseWallTests` still counts each at exactly one call
// site under `App/`, in `MeshContinuationDriver.swift`).
//
// **It keeps the tunnel.** The probe's `endProbe` tears its own network down before completing
// (`NetworkMeshFeasibilityProbe.swift:1349` → `stopNetworkOperations()` `:1381`); item 6 must not.
// There is **no radio verb anywhere in this file** — no `startJoin`, `stopJoin`, `holdCommittedLinks`,
// `leaveSession`, `resumeSearchingForPartitionedMesh`, no listener `start`/`stop`, and no routed
// access gate. What the radios do about a running task is the run policy's decision, reached the
// only way P8 allows: this type FEEDS `FernletStore.setMeshContinuation(state:lastAudit:)`, the store
// re-runs `ProximityRunPolicy`, and `ProximityRunSeams.swift` stays the one radio-speaking file.
// `ProximityRunSeamsTests.everyRadioVerbLivesInTheSeamsFile` and this file's own wall cell say so.
//
// **Nothing spins.** No `Timer`, no `DispatchQueue`, no stored `Task` handle (ML1), no `unowned`
// host (ML4). Progress rides `ProximitySessionPoller`'s existing 30-second tick — the one timer the
// app owns — and every other move is an edge somebody else already observes.
//
// **Exactly once, and the debt is never dropped.** ``completeHeldTask()`` is the probe's idiom
// (`:1400–1412`) with the duplicate guard supplied by the driver: `consumePendingCompletion()`
// answers nil on a second read, and the handle is dropped in the same turn it is completed. A
// completion with no handle in hand is audited (`mesh.continuation.completedTwice`) rather than
// swallowed — an app that stops completing the tasks it is given loses the privilege.
//
// **The submission is keyed on ENTRY into `requested`, never on an event.** A mesh founds itself and
// commits its first peer in the same main-actor transaction, and SwiftUI does not order two
// `onChange` closures, so both entry points are level-triggered and both submit through the same
// entry test: whichever arrives second finds the claim already `requested` and submits nothing.
//
// **No persisted surface.** Nothing here is written to disk; the claim starts at
// ``MeshContinuationState/idle`` on every launch, because a claim on a task that no longer exists is
// a lie. The wipe wall is owed nothing.
//
// **The scene fact is the host's, the raise is the driver's** (the fix round's F2). A
// `BGContinuedProcessingTask` is delivered promptly after the submission, normally while the app is
// STILL ON SCREEN — so adopting it and telling the mesh it is being continued in the background are
// two different moments. This type holds the one decided-once foreground fact
// (``appForegroundDidChange(_:)``) and hands it to the driver at the delivery; if the scene is lit,
// the driver raises nothing until the host's own dark edge. What that buys is the thing the first
// draft broke: `mayCommitRoutedHeartLedgerJudgement` stays OPEN while the person is using Fernlet
// with a task in hand, instead of every routed heart deferring until they leave and come back.
//
// **Every refusal is a MOVE, never a silence** (the fix round's F4). A registration the system
// refused, a ninth identifier, a missing identifier and the per-session submission cap all used to
// return quietly, leaving the claim on `requested` — which item 7's card reads as "nothing to say"
// and shows no card at all, while the honest sentence is "this session stays open only while
// Fernlet is on screen". Each arm now audits AND moves the claim through
// ``MeshContinuationDriver/taskWasRefused()``.
//
// **``appForegroundDidChange(_:)`` is LEVEL-triggered, and a Control-Centre peek is a foreground
// edge** (the fix round's F5, recorded rather than fixed). `FernletStore` feeds it from every edge
// carrying a foreground phase — the `.active` scene change, which includes coming back from the
// app switcher or a Control-Centre pull, the launch push and the duress observer. Each one with a
// task in hand completes it `succeeded` and re-submits, spending one of the eight
// ``maxSubmissionsPerSession``; eight peeks in one six-hour session and the mesh spends its
// background claim, lands on `refused` and says so on the Friends card. That is honest but
// wasteful, and whether it happens in practice is a measurement, not an argument: it is §15.3's
// device row F12 in `Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md`. A rising-edge latch
// ("a foreground push that follows a background one") is the fix if the soak shows churn.
//
// **What the mesh's suppressed Live Activity does and does not buy** (the fix round's F1). Passing
// `NoopProximityForegroundAnchor()` at the mesh's channel-ready door removes up to five doomed
// `Activity.request` calls per session; it changes nothing a person can see, because
// `ProximityConnectionActivityAttributes` is internal to ProximityKit and no widget in
// `App/FernletWidgets` declares an `ActivityConfiguration` for it, so none of those activities could
// ever have rendered. **The same is true of the 1:1 recipe-share and presence anchors, which are
// still live** — they are unrenderable dead code in shipping today, and either shipping the widget
// (public attributes plus a configuration) or retiring the anchor is a P9-sized decision this item
// does not take.

import FernletFoundation
import Foundation
import ProximityKit

// MARK: - MeshContinuationTaskHost

/// The app's continued-processing task host: one claim, one registered identifier, one handle.
///
/// ## Concurrency
///
/// `@MainActor`. The store and the mesh manager are held **weakly** — the store owns this object, so
/// a strong reference back would be a cycle, and a host that outlived either must do nothing rather
/// than resurrect it.
@MainActor
final class MeshContinuationTaskHost {

    /// The frozen English prefix of every mesh continuation identifier. `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers` carries `MBO.Fernlet.mesh-continuation.*`, so every
    /// `<meshID>` this appends is already permitted; a `UUID`'s `uuidString` is `[0-9A-F-]{36}`,
    /// which a reverse-DNS task identifier accepts.
    nonisolated static let identifierPrefix = "MBO.Fernlet.mesh-continuation."

    /// How many times one mesh may ask the system for a task (Power of 10, R2).
    ///
    /// Item 4's `running + appForegrounded → requested` row re-arms a submission on every foreground
    /// return, so a person switching in and out of Fernlet all afternoon would otherwise submit
    /// without bound. The counter resets when a new mesh starts, never on a foreground.
    static let maxSubmissionsPerSession = 8

    /// How many distinct identifiers one process may register (R2). `BGTaskScheduler.register`
    /// treats a duplicate identifier as a programmer error, so the set is also what stops a second
    /// registration of a mesh this process has already registered.
    static let maxRegisteredIdentifiers = 8

    /// The claim, and the two session-state raises. Owned here; item 5's file.
    let driver: MeshContinuationDriver

    /// The `BackgroundTasks` seam.
    private let scheduler: any BackgroundContinuationScheduling

    /// The store this host feeds. Weak: the store owns the host.
    private weak var store: FernletStore?

    /// The mesh manager the progress reading is taken from. Weak for the same reason.
    private weak var meshNetworkManager: MeshNetworkManager?

    /// The identifier registered for the mesh this device is on, or nil when none is.
    private(set) var registeredIdentifier: String?

    /// Every identifier this process has registered, so none is registered twice.
    private var registeredIdentifiers: Set<String> = []

    /// The delivered task, until it is completed.
    private var heldTask: (any ContinuationTaskHandle)?

    /// Whether the app owes the system a `setTaskCompleted(success:)` right now.
    var isHoldingTask: Bool { heldTask != nil }

    /// How many requests this mesh has submitted.
    private(set) var submissions = 0

    /// The last reading handed to the system, so the next one can ratchet on top of it.
    private var progress: MeshContinuationProgress?

    /// Whether the scene is backgrounded right now, as ``appForegroundDidChange(_:)`` last said.
    ///
    /// A host is born LIT: the app is on screen when it launches, and a task delivered before any
    /// scene edge has been seen is a task delivered to a visible app. It is recorded on every
    /// foreground edge, including the ones that hold no task, precisely so a delivery arriving after
    /// the person has left finds the right answer here.
    private var sceneIsDark = false

    /// Builds a host.
    ///
    /// - Parameters:
    ///   - store: The store this host feeds.
    ///   - meshNetworkManager: The manager the driver raises to and the reading is taken from.
    ///   - scheduler: The `BackgroundTasks` seam; nil takes the production one. A default ARGUMENT
    ///     cannot be a `@MainActor` value, so the default is resolved here.
    init(
        store: FernletStore,
        meshNetworkManager: MeshNetworkManager,
        scheduler: (any BackgroundContinuationScheduling)? = nil
    ) {
        self.store = store
        self.meshNetworkManager = meshNetworkManager
        self.driver = MeshContinuationDriver(meshNetworkManager: meshNetworkManager)
        self.scheduler = scheduler ?? SystemContinuationScheduler()
    }

    /// The concrete identifier for one mesh.
    ///
    /// `nonisolated`, with the prefix, so the source wall — which is not on the main actor — can
    /// check a minted identifier against the `Info.plist` wildcard.
    ///
    /// - Parameter meshID: The mesh's id.
    /// - Returns: `MBO.Fernlet.mesh-continuation.<meshID>`.
    nonisolated static func identifier(for meshID: UUID) -> String {
        identifierPrefix + meshID.uuidString
    }

    // MARK: - The mesh's own edges

    /// This device is on a new mesh: pay whatever the old one owed, clear the projection, register
    /// the new mesh's identifier, and ask for a task if a peer is already committed.
    ///
    /// Item 4's `meshStarted` row completes a task still running for the PREVIOUS mesh (`failed`) —
    /// the un-completed task of a dead mesh is the leak exactly-once exists to prevent — and the
    /// projection is then RESET, which is item 7's obligation: a sentence about the previous mesh's
    /// background session has nothing to say about this one. The `reset()` that follows finds the
    /// claim already off `running`, so it ends nothing a second time.
    ///
    /// The trailing commit check is what makes this order-independent: a mesh founds itself AT its
    /// first commit, so both of the view's observers fire in one transaction and SwiftUI orders
    /// neither. The commit fact is a PARAMETER rather than a read of the manager so the two call
    /// sites carry the same fact the observer saw, and so a test can state both orders.
    ///
    /// - Parameters:
    ///   - meshID: The mesh this device is now on.
    ///   - hasCommittedPeer: `MeshNetworkManager.hasCommittedPeer` at this edge.
    func meshDidStart(meshID: UUID, hasCommittedPeer: Bool) {
        driver.meshDidStart()
        completeHeldTask()
        cancelPendingRequest()
        driver.reset()
        submissions = 0
        progress = nil
        registerIfNeeded(Self.identifier(for: meshID))
        let before = driver.state
        if hasCommittedPeer { driver.firstPeerDidCommit() }
        submitOnEntry(from: before)
        feedStore()
    }

    /// The mesh is over: end the task the session was being continued for, and withdraw any request
    /// the system has not answered.
    func meshDidEnd() {
        driver.taskDidEnd(.sessionEnded)
        completeHeldTask()
        cancelPendingRequest()
        feedStore()
    }

    /// The mesh's committed-peer count crossed zero.
    ///
    /// The 0 → 1 edge is the submission instruction (plan §14: "on the user's start/join action once
    /// the first peer commits"). Losing the last peer is NOT an ending: a pair that blipped is still
    /// a session, and `MeshNetworkManager.isSessionLive` — not this — is what says one has ended.
    ///
    /// - Parameter hasPeer: Whether any peer is committed right now.
    func committedPeerDidChange(hasPeer: Bool) {
        guard hasPeer else { return }
        let before = driver.state
        driver.firstPeerDidCommit()
        submitOnEntry(from: before)
        feedStore()
    }

    // MARK: - The system's own edges

    /// The system delivered a task for this device's registered identifier.
    ///
    /// Three answers, all of which complete the handle exactly once:
    /// - **claimed** — this device asked for it: hold it, install the expiration handler, render the
    ///   card and let the run policy hear that the mesh has the background.
    /// - **ownerless** — nobody asked: end it AT ONCE (item 4's instruction, and item 5's contract),
    ///   which completes it `false` and resets the projection to silence.
    /// - **absorbed** — a task is already in hand: the claim did not move, so this handle is not
    ///   this host's to keep. Complete it `false` and drop it — the probe's "already completed ⇒
    ///   record and return" arm, one turn earlier.
    ///
    /// The scene fact rides along (the fix round's F2): the delivery normally arrives while the app
    /// is still on screen, and only a dark scene may raise `MeshSessionState.continuingInBackground`
    /// — a lit one waits for ``appForegroundDidChange(_:)``'s dark edge.
    ///
    /// - Parameter delivered: The task the system just handed over.
    func taskWasDelivered(_ delivered: any ContinuationTaskHandle) {
        let adoption = driver.taskDidStart(sceneIsDark: sceneIsDark)
        guard adoption != .absorbed, heldTask == nil else {
            FernletAuditLog.log("mesh.continuation.deliveryAbsorbed",
                                context: ["adoption": adoption.rawValue])
            delivered.completeContinuationTask(success: false)
            feedStore()
            return
        }
        heldTask = delivered
        progress = nil
        delivered.setContinuationExpirationHandler { [weak self] in self?.taskDidExpire() }
        guard adoption == .claimed else {
            endHeldTask(.cancelled)
            return
        }
        renderCard()
        feedStore()
    }

    /// The system's expiration handler fired: the time it granted is spent.
    func taskDidExpire() {
        endHeldTask(.expired)
    }

    // MARK: - The app's own edges

    /// The scene's foreground fact changed — **both ways**.
    ///
    /// The fact is `ProximityRunPolicy.isForeground(_:)`'s — `FernletApp.routedGateForeground(for:)`
    /// decided once — never a second `ScenePhase` read, and it is recorded here whether or not a
    /// task is in hand, because the next delivery needs it.
    ///
    /// **Dark**, with a task in hand: this is the moment the mesh may be told it is being continued
    /// in the background (the fix round's F2 — a task delivered to an app still on screen raised
    /// that far too early, closing the heart stage while the person was using Fernlet).
    /// ``MeshContinuationDriver/sceneDidGoDark()`` is idempotent, which is what makes this
    /// level-triggered call safe.
    ///
    /// **Lit**, with a task in hand: item 4's `running + appForegrounded → requested` row completes
    /// the task `succeeded` and re-arms the claim, so this also submits again, under
    /// ``maxSubmissionsPerSession``. It is idempotent for the opposite reason — the second call
    /// finds no held task. See the header on F5: a Control-Centre peek is one of these.
    ///
    /// - Parameter isForeground: Whether the scene is not backgrounded.
    func appForegroundDidChange(_ isForeground: Bool) {
        sceneIsDark = !isForeground
        guard heldTask != nil else { return }
        guard isForeground else {
            driver.sceneDidGoDark()
            return
        }
        let before = driver.state
        driver.taskDidEnd(.appForegrounded)
        completeHeldTask()
        submitOnEntry(from: before)
        feedStore()
    }

    /// The one session poller ticked: advance the bar and re-render the card.
    ///
    /// The API's termination rule is that progress must advance monotonically or the system ends the
    /// task, so the unit is elapsed session time toward the ceiling's budget
    /// (``MeshContinuationProgress/advancing(from:elapsed:budget:)``, which ratchets on top of it).
    /// **No second clock**: this rides the tick `ProximitySessionPoller` already owns.
    func sessionPollerDidTick() {
        guard let handle = heldTask,
              let reading = meshNetworkManager?.sessionContinuationReading else { return }
        let advanced = MeshContinuationProgress.advancing(
            from: progress, elapsed: reading.elapsedSeconds, budget: reading.budgetSeconds
        )
        progress = advanced
        handle.reportContinuationProgress(advanced)
        renderCard(friendCount: reading.connectedFriendCount)
    }

    /// The proximity hard stop is beginning (delete-all's leg 0 bracket, whose leg 7b this is the
    /// continuation half of): complete whatever is in hand, withdraw any pending request, and reset
    /// the claim to silence.
    ///
    /// The debt is paid FIRST, and by the driver's own door: ``MeshContinuationDriver/reset()`` ends
    /// a task that is still `running` (`cancelled`) before it returns the projection, precisely so a
    /// wipe cannot leave the handle uncompleted and `MeshSessionState.continuingInBackground`
    /// standing forever. All this adds is taking the completion it produced and paying it.
    func proximityHardStopWillBegin() {
        driver.reset()
        completeHeldTask()
        cancelPendingRequest()
        submissions = 0
        progress = nil
        feedStore()
    }

    // MARK: - The private half

    /// Registers one identifier, once per process, and **moves the claim** on both refusals.
    ///
    /// The fix round's F4: an identifier the system never accepted can never deliver a task, so the
    /// person is owed "this session stays open only while Fernlet is on screen" rather than silence.
    /// From `idle` — which is where ``meshDidStart(meshID:hasCommittedPeer:)``'s own `reset()`
    /// always leaves the claim before this runs — item 4 ABSORBS `taskRefused`, so what the person
    /// actually sees comes from ``submitIfRequested()``'s missing-identifier guard the moment the
    /// first peer commits. The move is made here anyway, so that a refusal is never silent from any
    /// state this door is ever reached in.
    ///
    /// - Parameter identifier: The concrete identifier to register.
    private func registerIfNeeded(_ identifier: String) {
        guard !registeredIdentifiers.contains(identifier) else {
            registeredIdentifier = identifier
            return
        }
        registeredIdentifier = nil
        guard registeredIdentifiers.count < Self.maxRegisteredIdentifiers else {
            FernletAuditLog.log("mesh.continuation.registrationCapReached",
                                context: ["registered": String(registeredIdentifiers.count)])
            driver.taskWasRefused()
            return
        }
        let accepted = scheduler.register(identifier: identifier) { [weak self] handle in
            self?.taskWasDelivered(handle)
        }
        guard accepted else {
            FernletAuditLog.log("mesh.continuation.registrationRefused", context: ["id": identifier])
            driver.taskWasRefused()
            return
        }
        registeredIdentifiers.insert(identifier)
        registeredIdentifier = identifier
        FernletAuditLog.log(MeshContinuationAudit.registered.rawValue, context: ["id": identifier])
    }

    /// Submits only when the claim has just ENTERED `requested` — item 4's instruction, spelled as
    /// the entry it is rather than as the event that caused it.
    ///
    /// - Parameter previous: The claim's state before the edge that just ran.
    private func submitOnEntry(from previous: MeshContinuationState) {
        guard previous != .requested, driver.state == .requested else { return }
        submitIfRequested()
    }

    /// Asks the system for a task, or **refuses the claim out loud** and records why.
    ///
    /// The fix round's F4. Both guards used to return silently from `requested`, which item 7's
    /// card reads as "nothing to say" — so a person whose session was never going to survive the
    /// lock screen was told nothing at all. Each is now a refusal: the claim lands on
    /// ``MeshContinuationState/refused`` and the Friends card says the session stays open only
    /// while Fernlet is on screen, which is exactly what is true when nothing was asked for.
    private func submitIfRequested() {
        guard let identifier = registeredIdentifier else {
            FernletAuditLog.log("mesh.continuation.submitWithoutARegistration")
            driver.taskWasRefused()
            return
        }
        guard submissions < Self.maxSubmissionsPerSession else {
            FernletAuditLog.log("mesh.continuation.submissionCapReached",
                                context: ["submissions": String(submissions)])
            driver.taskWasRefused()
            return
        }
        let copy = MeshContinuationCopy.card(friendCount: connectedFriendCount())
        submissions += 1
        do {
            try scheduler.submit(ContinuationTaskRequest(
                identifier: identifier,
                title: String(localized: copy.title),
                subtitle: String(localized: copy.subtitle)
            ))
            FernletAuditLog.log(MeshContinuationAudit.submitted.rawValue, context: ["id": identifier])
        } catch {
            // R7: a refusal is never silent, and it is a MOVE of the claim — the Friends card owes
            // the person the sentence "this session stays on screen".
            FernletAuditLog.log("mesh.continuation.submitRefused",
                                context: ["error": String(describing: error)])
            driver.taskWasRefused()
        }
    }

    /// Ends the task in hand for one reason, and pays what the ending produced.
    ///
    /// - Parameter reason: Why it is ending.
    private func endHeldTask(_ reason: MeshContinuationEndReason) {
        driver.taskDidEnd(reason)
        completeHeldTask()
        feedStore()
    }

    /// **The idempotent shutdown** — the probe's `completeBackgroundTask(success:)` idiom
    /// (`NetworkMeshFeasibilityProbe.swift:1400–1412`), and the ONLY site that completes a task.
    ///
    /// Two guards, the probe's two. Nothing owed ⇒ return (the common case: most moves of the claim
    /// end no delivered task). Something owed with no handle in hand ⇒ the completion has already
    /// been paid, or was produced for a task this host never held; name it and return. The handle is
    /// dropped BEFORE it is completed, so a re-entrant call finds nothing. **It tears nothing down**
    /// — no radio, no listener, no connection: the one thing the probe's version does that the
    /// product must not.
    private func completeHeldTask() {
        guard let completion = driver.consumePendingCompletion() else { return }
        guard let handle = heldTask else {
            FernletAuditLog.log("mesh.continuation.completedTwice",
                                context: ["completion": completion.rawValue])
            return
        }
        heldTask = nil
        progress = nil
        handle.completeContinuationTask(success: completion.success)
    }

    /// Withdraws a request the system has not answered.
    private func cancelPendingRequest() {
        guard let identifier = registeredIdentifier else { return }
        scheduler.cancel(identifier: identifier)
    }

    /// Re-renders the system card's two sentences.
    ///
    /// - Parameter friendCount: How many friends are connected, or nil to read it now.
    private func renderCard(friendCount: Int? = nil) {
        guard let handle = heldTask else { return }
        let copy = MeshContinuationCopy.card(friendCount: friendCount ?? connectedFriendCount())
        handle.updateContinuationCopy(
            title: String(localized: copy.title), subtitle: String(localized: copy.subtitle)
        )
    }

    /// How many friends this mesh is connected to right now, excluding self.
    ///
    /// - Returns: The branch's external present count, or zero when no session is live.
    private func connectedFriendCount() -> Int {
        meshNetworkManager?.sessionContinuationReading?.connectedFriendCount ?? 0
    }

    /// **The feed** — the one way this host reaches the radios, and it is not a verb.
    ///
    /// The store assigns the projection and re-runs `ProximityRunPolicy`, which decides what each
    /// radio does about a task that is running, refused or spent. Nothing here calls a radio, and
    /// `ProximityRunSeamsTests`' retirement wall is what proves it.
    private func feedStore() {
        store?.setMeshContinuation(state: driver.state, lastAudit: driver.lastAudit)
    }
}
