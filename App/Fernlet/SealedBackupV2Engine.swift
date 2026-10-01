import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import ProximityKit
import UIKit

/// What asks the Sealed backup v2 engine for a pass (design 2026-09-30, §4.2, §4.6).
enum SealedBackupTrigger: Equatable {
    /// The first Private section of a hub session appeared (any section, Worry Box included).
    case hubSettle
    /// A hidden surface was turned back on.
    case unhide
    /// Privacy & Data's Retry, or an owed upload's retry: ambient — it honours the owner hold and E1.
    case retry
    /// The device owner released an app-lock reset's hold (behind the device-owner check).
    case ownerRelease
    /// The backup was just turned on with the Private tab open: an export of what is owed.
    case enable
    /// E2 found a set under this install's own writer tag numbered above everything this install
    /// recorded — an iPhone put back from an older device backup of itself — and reopened the
    /// restore, which runs now so that set is merged before anything is exported over it (review
    /// B1-C-B1-2).
    case restoreReopened
    /// "Restore it here" of exactly `stamp` (`ignoringRollback`: "Restore anyway").
    case restoreHere(SealedBackupHeadStamp, ignoringRollback: Bool)
    /// "Replace it with this iPhone's …" of exactly `stamp`.
    case replace(SealedBackupHeadStamp)
    /// "Start a new backup" over a set this iPhone cannot open.
    case startNew
    /// "Remove them": the shown ids that still cannot open.
    case remove([UUID])

    /// Whether the user chose this explicitly in Privacy & Data (an in-memory intent).
    var isExplicit: Bool {
        switch self {
        case .restoreHere, .replace, .startNew, .remove: return true
        case .hubSettle, .unhide, .retry, .ownerRelease, .enable, .restoreReopened: return false
        }
    }

    /// Whether this trigger skips the once-per-session and 15-minute spacing (§4.5): explicit intents,
    /// the owner's release and turning the backup on are a person's act just now, not an unlock; a
    /// restore E2 just reopened must not wait for the next session (its export waits on it).
    var skipsSpacing: Bool {
        switch self {
        case .ownerRelease, .enable, .restoreReopened: return true
        case .hubSettle, .unhide, .retry: return false
        case .restoreHere, .replace, .startNew, .remove: return true
        }
    }
}

/// One payload's Sealed backup state as the last pass left it (§4.2). In memory; what persists is in
/// ``SealedBackupBookkeeping``.
enum SealedBackupV2Status: Equatable {
    /// The cloud set is this install's and current.
    case upToDate
    /// E1: this install has not pulled its backup yet (the last restore outcome, if any).
    case waitingForRestore(SealedBackupRestoreOutcome?)
    /// The app-lock reset's owner hold keeps this payload's pre-reset copy.
    case heldForOwner
    /// The set in iCloud is another iPhone's (also persisted as the observation).
    case heldByAnotherDevice(SealedBackupHeadStamp)
    /// A set exists but this iPhone has no escrow key yet (iCloud Keychain still syncing).
    case waitingForBackupKey
    /// The set is sealed to an escrow key this iPhone does not hold.
    case headSealedWithOtherKey
    /// The set is tagged with this iPhone's key but will not authenticate.
    case headDamaged
    /// The set's envelope, or a row here, needs a newer build of Fernlet.
    case needsNewerFernlet
    /// Rows this iPhone can never open pause the backup.
    case paused(unopenableIDs: [UUID])
    /// More than the engine's record or byte bound.
    case tooLarge
    /// A transient failure; backed off (§4.5).
    case failed
}

/// Which phases a pass may run (§4.2: at most a restore, then an export).
struct SealedBackupV2Phases: OptionSet, Equatable {
    let rawValue: Int
    /// The restore phase (R).
    static let restore = SealedBackupV2Phases(rawValue: 1)
    /// The export phase (X).
    static let export = SealedBackupV2Phases(rawValue: 2)
    /// Both, in order.
    static let both: SealedBackupV2Phases = [.restore, .export]
}

/// Why a pass stopped at a gate (§4.2 G) — nothing was written, and only `surfaceClosed` changes a
/// status (it drops it).
nonisolated enum SealedBackupV2GateFailure: Equatable, Sendable {
    /// "Delete everything" is running.
    case wiping
    /// The work epoch moved (a wipe, an app-lock reset, a backup turned off, a cloud delete).
    case workStopped
    /// A duress session is active.
    case duress
    /// The payload's surface is hidden (or under age).
    case surfaceClosed
    /// The Private tab is closed (no hub key).
    case hubClosed
    /// iCloud sync or this payload's backup is off (or being turned off).
    case backupOff
    /// The sealed store is not attached.
    case storeUnhealthy
    /// The app-lock reset's owner hold stopped a restore (R1).
    case heldForOwner
}

/// What one pass did — what the coordinator's façades report to their callers.
struct SealedBackupV2PassReport: Equatable {
    /// The restore phase's outcome (recorded on the host only when the restore really ran).
    var restoreOutcome: SealedBackupRestoreOutcome?
    /// The status the export phase ended in, when it ran.
    var exportStatus: SealedBackupV2Status?
    /// The gate the pass stopped at, if any.
    var gateFailure: SealedBackupV2GateFailure?
    /// Whether the pass was stopped by a wipe, a reset, a turn-off or a cancellation (or dropped).
    var stopped = false

    /// A pass that never ran.
    static let dropped = SealedBackupV2PassReport(stopped: true)
}

/// A `UIApplication` background-task assertion, injectable so tests need no UIKit app state.
@MainActor
protocol SealedBackupBackgroundTaskAsserting: AnyObject {
    /// Begins an assertion; `onExpiry` runs if the system expires it first.
    func begin(_ name: String, onExpiry: @escaping @MainActor () -> Void) -> Int
    /// Ends the assertion `token` (a no-op for an ended one).
    func end(_ token: Int)
}

/// The production assertion: `UIApplication.beginBackgroundTask` (R2-F6), so a commit that started
/// while the app was in front can finish uploading its sealed set after the user leaves it.
@MainActor
final class SealedBackupUIKitBackgroundTasks: SealedBackupBackgroundTaskAsserting {
    func begin(_ name: String, onExpiry: @escaping @MainActor () -> Void) -> Int {
        UIApplication.shared.beginBackgroundTask(withName: name) { onExpiry() }.rawValue
    }

    func end(_ token: Int) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: token)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// The ONE engine every Sealed backup v2 pass runs on (design 2026-09-30, §3, §4.2) — the period,
/// intimate-log and journal backups' (``CycleRecordBackupAdapter``, ``IntimacyBackupAdapter``,
/// ``JournalBackupAdapter``).
///
/// **One serial worker.** A single held `Task` drains a FIFO holding at most one pass per payload, so
/// no two passes ever run at once, for any payload or trigger (R2-F15). A later explicit intent
/// replaces an earlier ambient one; their callers all receive the one report.
///
/// **The gates (G).** A pass captures the host's work epoch (and this engine's own) at its start; G
/// holds while: no wipe is running and both epochs are unchanged; no duress session and the surface is
/// open; the hub key is live (re-read every time); iCloud sync and this payload's backup are on (the
/// in-memory preferences, and not being turned off); the store is attached. G is checked at the start
/// of a pass, **after every await**, and **immediately before every decrypt and every local write**. A
/// failed G aborts the pass with nothing written and nothing recorded (a hidden surface drops its
/// status).
///
/// **The commit** (the uploads) decrypts nothing, so it outlives a closed hub, a hide and a duress
/// session — stopping it part-way would orphan its chunks, never damage the previous set (set-scoped
/// names, §5.2) — but it is stopped before every save by a wipe, an app-lock reset, the backup being
/// turned off, iCloud sync being turned off and a cloud delete (``quiesce()``), so no set is ever
/// written after its cloud copy was deleted (review U5 finding on 8f808232).
@MainActor
final class SealedBackupV2Engine {
    /// The most records one set may carry (§4.2 X7, R3).
    static let maxRecords = 100_000
    /// The most ciphertext one prepared set may hold in memory (§4.2 X7, R3).
    static let maxPreparedBytes = 64 * 1_024 * 1_024
    /// Records per chunk — one size for every payload (the v1 exports' too).
    static let chunkSize = 250
    /// How long a failed automatic restore, export or probe waits before the next (§4.5).
    static let failureBackoff: TimeInterval = 15 * 60
    /// The most passes one worker drains before handing over to a fresh one (R2).
    static let maxPassesPerDrain = 8

    unowned let host: any SealedBackupContext
    /// The adapters, one per payload on v2.
    let adapters: [SealedBackupPayloadType: any SealedBackupV2Adapter]
    let identityFactory: () -> IdentityService
    let serviceFactory: (IdentityService) -> SealedBackupService
    let preferences: () -> StoragePreferences
    let writerTag: () -> String?
    let now: () -> Date
    let backgroundTasks: any SealedBackupBackgroundTaskAsserting

    /// The current status per payload (mirrored on the host for the UI).
    private(set) var status: [SealedBackupPayloadType: SealedBackupV2Status] = [:]
    /// The pending explicit intents (in memory: a relaunch only forgets a request, §4.6).
    private(set) var intents: [SealedBackupPayloadType: SealedBackupTrigger] = [:]
    /// The last restore outcome per payload (`.waitingForRestore`'s detail).
    var lastRestoreOutcome: [SealedBackupPayloadType: SealedBackupRestoreOutcome] = [:]
    /// The ids the last pause named, per payload — "Remove them" removes only ids in here (R2-F12).
    var lastPausedIDs: [SealedBackupPayloadType: Set<UUID>] = [:]
    /// The set the last restore refused as older than this iPhone's rollback floor, per payload — what
    /// Privacy & Data's "Restore it here" and "Replace" name for `.waitingForRestore(.rolledBack)`
    /// (design §4.6, review B1-D-B1-R1). Cleared when a restore lands.
    var rolledBackStamps: [SealedBackupPayloadType: SealedBackupHeadStamp] = [:]
    /// Spacing: what ran (with network) this hub session, and when the last failure or probe was.
    var restoredThisSession: Set<SealedBackupPayloadType> = []
    var exportedThisSession: Set<SealedBackupPayloadType> = []
    var probedThisSession: Set<SealedBackupPayloadType> = []
    var lastRestoreFailure: [SealedBackupPayloadType: Date] = [:]
    var lastExportFailure: [SealedBackupPayloadType: Date] = [:]
    var lastProbe: [SealedBackupPayloadType: Date] = [:]
    /// Payloads being turned off: G fails for them until a later enable.
    private(set) var disabling: Set<SealedBackupPayloadType> = []
    /// This engine's own epoch, moved by ``quiesce()``.
    private(set) var quiesceEpoch = 0
    /// How many sealed backup records this engine has decrypted — the "nothing was decrypted" witness
    /// the gate and probe tests read (BV3, BV18, the metadata-only probe). In memory; diagnostic only.
    var decryptCount = 0

    /// One queued pass: its payload, trigger, phases and the callers waiting for its report.
    private struct PendingPass {
        let payload: SealedBackupPayloadType
        var trigger: SealedBackupTrigger
        var phases: SealedBackupV2Phases
        var waiters: [CheckedContinuation<SealedBackupV2PassReport, Never>]
    }

    private var queue: [PendingPass] = []
    private var worker: Task<Void, Never>?

    /// Creates the engine (built by `SealedBackupCoordinator`, which `FernletStore` owns).
    init(
        host: any SealedBackupContext,
        adapters: [SealedBackupPayloadType: any SealedBackupV2Adapter],
        identityFactory: @escaping () -> IdentityService,
        serviceFactory: @escaping (IdentityService) -> SealedBackupService,
        preferences: @escaping () -> StoragePreferences,
        writerTag: @escaping () -> String?,
        now: @escaping () -> Date,
        backgroundTasks: any SealedBackupBackgroundTaskAsserting
    ) {
        self.host = host
        self.adapters = adapters
        self.identityFactory = identityFactory
        self.serviceFactory = serviceFactory
        self.preferences = preferences
        self.writerTag = writerTag
        self.now = now
        self.backgroundTasks = backgroundTasks
    }

    /// The worker does not outlive the engine (memory-lifecycle wall ML1): it captures the engine
    /// weakly, and a released engine cancels it — a pass then fails its next gate.
    isolated deinit {
        worker?.cancel()
    }

    // MARK: - Requests

    /// Enqueues a pass of both phases for each payload on v2. Dropped, not queued, while "Delete
    /// everything" runs.
    func request(_ payloads: [SealedBackupPayloadType], trigger: SealedBackupTrigger) {
        guard !host.deleteAllInProgress else { return }
        for payload in payloads where adapters[payload] != nil {
            enqueue(payload, trigger: trigger, phases: .both, waiter: nil)
        }
        startWorkerIfNeeded()
    }

    /// Enqueues one pass and waits for its report (the coordinator's façades and the tests).
    func perform(
        _ payload: SealedBackupPayloadType,
        trigger: SealedBackupTrigger,
        phases: SealedBackupV2Phases
    ) async -> SealedBackupV2PassReport {
        guard !host.deleteAllInProgress, adapters[payload] != nil, !phases.isEmpty else { return .dropped }
        return await withCheckedContinuation { waiter in
            enqueue(payload, trigger: trigger, phases: phases, waiter: waiter)
            startWorkerIfNeeded()
        }
    }

    /// Records an explicit intent (§4.6): the next pass for `payload` — now, if the Private tab is
    /// open, else the next hub settle — carries it out. Nothing persists.
    func recordIntent(_ trigger: SealedBackupTrigger, for payload: SealedBackupPayloadType) {
        guard trigger.isExplicit, adapters[payload] != nil else { return }
        intents[payload] = trigger
        setStatus(nil, payload)
    }

    /// Drops `payload`'s pending intent (it was carried out, or it can no longer be).
    func consumeIntent(_ payload: SealedBackupPayloadType) {
        intents[payload] = nil
    }

    /// The app-lock reset and the "can't open" check (review B1-C-B1-3): every pending explicit
    /// choice, the ids a pause named and the set a restore refused are forgotten — they were made
    /// over bookkeeping, a key and a hold that no longer exist. A "Replace" or "Start a new backup"
    /// left pending would otherwise take the owner's release's place, skip the restore it is waiting
    /// for and write the post-reset store over the pre-reset copy.
    func dropPendingChoices() {
        intents.removeAll()
        lastPausedIDs.removeAll()
        rolledBackStamps.removeAll()
    }

    private func enqueue(
        _ payload: SealedBackupPayloadType,
        trigger: SealedBackupTrigger,
        phases: SealedBackupV2Phases,
        waiter: CheckedContinuation<SealedBackupV2PassReport, Never>?
    ) {
        if let index = queue.firstIndex(where: { $0.payload == payload }) {
            // A later explicit intent replaces an ambient request; an ambient request never takes the
            // place of one that skips spacing (the owner's release, an enable, a reopened restore).
            let queued = queue[index].trigger
            if trigger.isExplicit || (!queued.isExplicit && (trigger.skipsSpacing || !queued.skipsSpacing)) {
                queue[index].trigger = trigger
            }
            queue[index].phases.formUnion(phases)
            if let waiter { queue[index].waiters.append(waiter) }
        } else {
            queue.append(PendingPass(payload: payload, trigger: trigger, phases: phases, waiters: waiter.map { [$0] } ?? []))
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    /// The worker: runs queued passes one at a time, then hands over (a fresh task) if more arrived.
    private func drain() async {
        for _ in 0..<Self.maxPassesPerDrain {  // R2: bounded; a fresh worker picks up the rest.
            guard !Task.isCancelled, !queue.isEmpty else { break }
            let next = queue.removeFirst()
            let report = await runPass(next.payload, trigger: next.trigger, phases: next.phases)
            for waiter in next.waiters { waiter.resume(returning: report) }
        }
        worker = nil
        if Task.isCancelled {
            dropPending()
        } else {
            startWorkerIfNeeded()
        }
    }

    /// Answers every queued request as stopped and empties the queue.
    private func dropPending() {
        let dropped = queue
        queue.removeAll()
        for pass in dropped {
            for waiter in pass.waiters { waiter.resume(returning: .dropped) }
        }
    }

    // MARK: - Stopping (§4.7)

    /// Stops the worker and waits until it has stopped: moves this engine's epoch (a pass resuming
    /// from any await fails G before it decrypts or writes, and a commit stops before its next save),
    /// cancels the worker and drops every queued pass. Delete-all awaits it before its cloud leg; so
    /// do turning a backup off and "Stop syncing and delete iCloud data", so no set is written after
    /// the delete.
    func quiesce() async {
        quiesceEpoch &+= 1
        let running = worker
        running?.cancel()
        dropPending()
        await running?.value
        dropPending()
    }

    /// Delete-all's quiesce (§4.7): ``quiesce()``, named for the funnel.
    func quiesceForWipe() async {
        await quiesce()
    }

    /// Turning `payload`'s backup off: from now until ``endDisabling(_:keepOff:)`` G fails for it, and
    /// any pass already running stops before its next save. Awaited BEFORE the cloud delete.
    func beginDisabling(_ payload: SealedBackupPayloadType) async {
        disabling.insert(payload)
        intents[payload] = nil
        await quiesce()
    }

    /// Ends a turn-off: `keepOff` (the delete landed and the switch goes off) keeps G failing for the
    /// payload until it is turned on again (``endDisabling(_:keepOff:)`` with false, from the enable).
    func endDisabling(_ payload: SealedBackupPayloadType, keepOff: Bool) {
        if keepOff {
            disabling.insert(payload)
            setStatus(nil, payload)
        } else {
            disabling.remove(payload)
        }
    }

    /// The hub closed: the per-session spacing sets clear (§4.5).
    func hubSessionEnded() {
        restoredThisSession.removeAll()
        exportedThisSession.removeAll()
        probedThisSession.removeAll()
    }

    // MARK: - Gates

    /// The epochs a pass captured at its start.
    struct PassEpoch: Equatable {
        let host: Int
        let local: Int
    }

    /// The epochs right now.
    func currentEpoch() -> PassEpoch {
        PassEpoch(host: host.sealedBackupWorkEpoch, local: quiesceEpoch)
    }

    /// G (§4.2): the first gate that fails for `adapter` under `epoch`, or nil when G holds.
    func gateFailure(_ adapter: some SealedBackupV2Adapter, epoch: PassEpoch) -> SealedBackupV2GateFailure? {
        if let stop = workStop(adapter.payload, epoch: epoch) { return stop }
        guard !host.duressSessionActive else { return .duress }
        guard adapter.isSurfaceOpen else { return .surfaceClosed }
        guard host.sealedBackupContentKey != nil else { return .hubClosed }
        guard adapter.isStoreHealthy else { return .storeUnhealthy }
        return nil
    }

    /// The part of G a commit needs before each save (it decrypts nothing): no wipe, both epochs
    /// unchanged, the task not cancelled, and iCloud sync and the backup still on.
    func workStop(_ payload: SealedBackupPayloadType, epoch: PassEpoch) -> SealedBackupV2GateFailure? {
        guard !host.deleteAllInProgress else { return .wiping }
        guard !Task.isCancelled, currentEpoch() == epoch else { return .workStopped }
        let prefs = preferences()
        guard prefs.iCloudSyncEnabled, prefs.isSealedBackupEnabled(for: payload), !disabling.contains(payload) else {
            return .backupOff
        }
        return nil
    }

    /// The live hub key, or nil (G re-reads it every time).
    var liveHubKey: SymmetricKey? { host.sealedBackupContentKey }

    // MARK: - Status

    /// Records `status` for `payload` (and mirrors it on the host); nil drops it.
    func setStatus(_ newValue: SealedBackupV2Status?, _ payload: SealedBackupPayloadType) {
        status[payload] = newValue
        host.recordSealedBackupV2Status(newValue, payloadType: payload)
    }

    /// Records a gate failure's status effect: a hidden surface drops the status; nothing else
    /// records anything (§4.2).
    func noteGateFailure(_ failure: SealedBackupV2GateFailure, _ payload: SealedBackupPayloadType) {
        if failure == .surfaceClosed || failure == .duress { setStatus(nil, payload) }
        FernletAuditLog.log("sealedBackup.v2.gateStopped", context: [
            "payload": payload.rawValue, "gate": String(describing: failure)
        ])
    }

    // MARK: - The pass

    /// One pass for `payload`: G, then at most the restore phase, then the export phase (§4.2).
    private func runPass(
        _ payload: SealedBackupPayloadType,
        trigger requested: SealedBackupTrigger,
        phases: SealedBackupV2Phases
    ) async -> SealedBackupV2PassReport {
        guard let adapter = adapters[payload] else { return .dropped }
        // A pending explicit intent replaces an ambient request (§4.6) — when the pass runs the phase
        // the intent needs ("Restore it here" a restore, the others an export).
        var trigger = requested
        if !requested.isExplicit, let intent = intents[payload], phases.contains(Self.phase(of: intent)) {
            trigger = intent
        }
        return await runOpenedPass(adapter, trigger: trigger, phases: phases)
    }

    /// The phase an explicit intent is carried out by.
    private static func phase(of intent: SealedBackupTrigger) -> SealedBackupV2Phases {
        if case .restoreHere = intent { return .restore }
        return .export
    }

    /// The generic half of ``runPass(_:trigger:phases:)`` (the existential opened).
    private func runOpenedPass<A: SealedBackupV2Adapter>(
        _ adapter: A,
        trigger: SealedBackupTrigger,
        phases: SealedBackupV2Phases
    ) async -> SealedBackupV2PassReport {
        let epoch = currentEpoch()
        var report = SealedBackupV2PassReport()
        if let failure = gateFailure(adapter, epoch: epoch) {
            noteGateFailure(failure, adapter.payload)
            report.gateFailure = failure
            report.stopped = failure == .wiping || failure == .workStopped
            return report
        }
        var followThrough = false
        if phases.contains(.restore), restoreIsDue(adapter.payload, trigger: trigger) {
            let restore = await restorePhase(adapter, trigger: trigger, epoch: epoch)
            report.restoreOutcome = restore.outcome
            report.gateFailure = restore.gateFailure
            report.stopped = restore.stopped
            guard restore.continueToExport else { return report }
            followThrough = restore.accepted
            // The restore awaited: G again before the export's first network call (review B1-C-B1-5).
            if phases.contains(.export), let failure = gateFailure(adapter, epoch: epoch) {
                noteGateFailure(failure, adapter.payload)
                report.gateFailure = failure
                report.stopped = failure == .wiping || failure == .workStopped
                return report
            }
        } else if phases.contains(.restore), !phases.contains(.export) {
            report.restoreOutcome = .skippedStoreNotEmpty
        }
        guard phases.contains(.export) else { return report }
        let export = await exportPhase(adapter, trigger: trigger, epoch: epoch, followThrough: followThrough)
        report.exportStatus = export.status
        report.gateFailure = report.gateFailure ?? export.gateFailure
        report.stopped = report.stopped || export.stopped
        return report
    }

    /// Whether the restore phase runs: "Restore it here"; never for "Replace" or "Start a new backup"
    /// (confirmed writes over the cloud copy, which waive E1); otherwise — "Remove them" included,
    /// which does not waive E1 (review B1-C-B1-3) — while this install's restore is unresolved.
    private func restoreIsDue(_ payload: SealedBackupPayloadType, trigger: SealedBackupTrigger) -> Bool {
        switch trigger {
        case .restoreHere: return true
        case .replace, .startNew: return false
        case .remove, .hubSettle, .unhide, .retry, .ownerRelease, .enable, .restoreReopened:
            return !host.sealedBackupBookkeeping.isRestoreResolved(payload)
        }
    }

    // MARK: - Shared steps

    /// A service over a freshly provisioned identity, with whether an escrow key is present — never
    /// minting one (`.forOpening`, §5.6). Nil when the device identity cannot be provisioned.
    func openingService() -> (identity: IdentityService, service: SealedBackupService, escrowReady: Bool)? {
        let identity = identityFactory()
        do {
            try identity.ensureProvisioned()
        } catch {
            FernletAuditLog.log("sealedBackup.v2.notProvisioned")
            return nil
        }
        let ready = identity.loadBackupEscrowKeyForOpen()
        return (identity, serviceFactory(identity), ready)
    }

    /// Whether `payload` is dirty (an upload is owed).
    func isDirty(_ payload: SealedBackupPayloadType) -> Bool {
        host.isSealedBackupReuploadOwed(payload)
    }

    /// Whether `last` is within the failure backoff of now.
    func isBackingOff(since last: Date?) -> Bool {
        guard let last else { return false }
        return now().timeIntervalSince(last) < Self.failureBackoff
    }
}

extension StoragePreferences {
    /// Whether `payload`'s Sealed backup switch is on — the one payload-to-switch helper the engine,
    /// the store, the owner hold and Privacy & Data share (design 2026-09-30 §4.4, R2-F14).
    func isSealedBackupEnabled(for payload: SealedBackupPayloadType) -> Bool {
        switch payload {
        case .periodData: return sealedBackupPeriodEnabled
        case .journalNarratives: return sealedBackupJournalEnabled
        case .intimacyLogs: return sealedBackupIntimacyEnabled
        // Retired: the flag now means "a copy may still be up there", never "back this up".
        case .sensitiveNotes: return false
        }
    }
}
