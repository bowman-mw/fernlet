import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import ProximityKit

/// What the export phase ended in (§4.2 X).
struct SealedBackupV2ExportResult {
    /// The status it ended in (nil when it never got past a gate or had nothing to do).
    var status: SealedBackupV2Status?
    /// The gate it stopped at, if any.
    var gateFailure: SealedBackupV2GateFailure?
    /// Whether a wipe, reset, turn-off or cancellation stopped it.
    var stopped = false
}

/// E2's verdict on the head in iCloud (§5.5).
enum SealedBackupV2HeadVerdict {
    /// The export may write: above `floor` (the head's generation, or 0 with no head).
    case pass(floor: Int64, headExists: Bool)
    /// The head is this install's accepted one, unchanged, and nothing is owed: done, no decrypt.
    case upToDate
    /// The export must not write; this is why.
    case stop(SealedBackupV2Status)
}

/// One prepared set, every chunk sealed in memory before the first save (§4.2 X7).
struct SealedBackupV2PreparedSet {
    /// The sealed chunks, by index (0 is the head).
    var chunks: [Int: SealedBackupRecord]
    /// The set's tag.
    let setTag: String
    /// The set's key salt.
    let keySalt: Data
    /// The set's generation.
    let generation: Int64
    /// This install's writer tag.
    let writer: String
    /// The host's mutation epoch for the payload when the prepare began.
    let mutationsBefore: Int
}

extension SealedBackupV2Engine {
    /// The export phase (§4.2 X1–X9): E1, the owner hold, Remove, spacing, E2, the escrow mint rule,
    /// the prepare (every chunk sealed before the first save) and the commit (suffix chunks under
    /// their set-scoped names, then the head, the verify and the prune), with the bookkeeping after.
    func exportPhase<A: SealedBackupV2Adapter>(
        _ adapter: A,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch,
        followThrough: Bool
    ) async -> SealedBackupV2ExportResult {
        let payload = adapter.payload
        let waived = Self.waivesE1(trigger)
        guard waived || host.sealedBackupBookkeeping.isRestoreResolved(payload) else {
            return finish(.waitingForRestore(lastRestoreOutcome[payload]), payload)
        }
        guard !host.sealedBackupKeepsPreResetCopy(of: payload) else {
            FernletAuditLog.log("sealedBackup.reuploadHeldForOwner", context: ["payload": payload.rawValue, "site": "v2"])
            return finish(.heldForOwner, payload)
        }
        do {
            if case .remove(let ids) = trigger { try removeStillDead(adapter, ids: ids, epoch: epoch) }
            let explicit = trigger.skipsSpacing || followThrough
            guard explicit || !exportIsSpaced(payload) else { return SealedBackupV2ExportResult(status: status[payload]) }
            let result = try await runExport(adapter, trigger: trigger, epoch: epoch, explicit: explicit)
            if trigger.isExplicit, let ended = result.status, Self.endsAnIntent(ended) { consumeIntent(payload) }
            return result
        } catch let stop as SealedBackupV2Stop {
            guard case .gate(let failure) = stop else { return SealedBackupV2ExportResult() }
            noteGateFailure(failure, payload)
            return SealedBackupV2ExportResult(gateFailure: failure, stopped: failure == .wiping || failure == .workStopped)
        } catch {
            FernletAuditLog.log("sealedBackup.v2.exportFailed", context: ["payload": payload.rawValue])
            lastExportFailure[payload] = now()
            return finish(.failed, payload)
        }
    }

    /// E2 through X9 for an export that passed E1, the hold and spacing.
    private func runExport<A: SealedBackupV2Adapter>(
        _ adapter: A,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch,
        explicit: Bool
    ) async throws -> SealedBackupV2ExportResult {
        let payload = adapter.payload
        guard let opening = openingService() else { return finish(.failed, payload) }
        // A clean visit is a probe (E2 only, §4.5); it counts as this session's probe either way.
        if !isDirty(payload) {
            probedThisSession.insert(payload)
            lastProbe[payload] = now()
        }
        let verdict = try await headVerdict(adapter, service: opening.service, trigger: trigger, epoch: epoch, explicit: explicit)
        let floor: Int64
        switch verdict {
        case .upToDate: return finish(.upToDate, payload)
        case .stop(let reason): return finish(reason, payload)
        case .pass(let headFloor, let headExists):
            guard isDirty(payload) || explicit || headExists else { return finish(.upToDate, payload) }
            floor = headFloor
        }
        // From here on this is this session's automatic export, whatever it ends in (§4.5).
        exportedThisSession.insert(payload)
        if !opening.escrowReady {
            let mayMint = try await mayMintEscrowKey(trigger: trigger, service: opening.service, epoch: epoch, adapter: adapter)
            guard mayMint, !opening.identity.provisionBackupEscrowKeyForSealing().isEmpty else {
                return finish(.waitingForBackupKey, payload)
            }
        }
        let prepared = try await prepare(adapter, service: opening.service, floor: floor, epoch: epoch)
        guard case .ready(let set) = prepared else {
            if case .refused(let reason) = prepared { return finish(reason, payload) }
            return finish(.failed, payload)
        }
        return try await commit(set, adapter: adapter, service: opening.service, trigger: trigger, epoch: epoch)
    }

    /// Whether an explicit intent that ended in `status` is done with: carried out, or answered by a
    /// state the user has to see first (a set that moved since is held again, R1-BR-4). A transient
    /// failure, a missing key, a restore still owed or the owner hold keep it for the next settle.
    static func endsAnIntent(_ status: SealedBackupV2Status) -> Bool {
        switch status {
        case .upToDate, .heldByAnotherDevice, .headSealedWithOtherKey, .headDamaged, .needsNewerFernlet, .paused, .tooLarge:
            return true
        case .failed, .waitingForBackupKey, .waitingForRestore, .heldForOwner:
            return false
        }
    }

    /// Whether `trigger` waives E1 — a confirmed decision to write over the cloud copy (§4.6).
    static func waivesE1(_ trigger: SealedBackupTrigger) -> Bool {
        switch trigger {
        case .replace, .startNew: return true
        default: return false
        }
    }

    /// Whether an automatic export (or probe) of `payload` must wait (§4.5): an export once per hub
    /// session and 15 minutes after a failure; a probe (clean) once per session and 15 minutes after
    /// the last one.
    private func exportIsSpaced(_ payload: SealedBackupPayloadType) -> Bool {
        if isDirty(payload) {
            return exportedThisSession.contains(payload) || isBackingOff(since: lastExportFailure[payload])
        }
        return probedThisSession.contains(payload) || isBackingOff(since: lastProbe[payload])
    }

    /// Ends the export with `newStatus` (recorded) — the failure backoff included.
    func finish(_ newStatus: SealedBackupV2Status, _ payload: SealedBackupPayloadType) -> SealedBackupV2ExportResult {
        if newStatus == .failed { lastExportFailure[payload] = now() }
        setStatus(newStatus, payload)
        return SealedBackupV2ExportResult(status: newStatus)
    }

    /// X3, "Remove them": re-checks G, then removes only the shown ids that are still dead under
    /// every key this iPhone holds (R2-F12), and marks the payload dirty.
    private func removeStillDead<A: SealedBackupV2Adapter>(_ adapter: A, ids: [UUID], epoch: PassEpoch) throws {
        try ensureGate(adapter, epoch: epoch)
        guard let key = liveHubKey else { throw SealedBackupV2Stop.gate(.hubClosed) }
        let shown = ids.filter { lastPausedIDs[adapter.payload]?.contains($0) == true }
        let removed = try adapter.removeStillDead(shown, hubKey: key)
        lastPausedIDs[adapter.payload] = nil
        consumeIntent(adapter.payload)
        host.markSealedBackupDirty(adapter.payload)
        FernletAuditLog.log("sealedBackup.v2.removedUnopenable", context: [
            "payload": adapter.payload.rawValue, "removed": String(removed)
        ])
    }

    // MARK: - E2 (§5.5)

    /// X5: fetches the head and classifies it, writer-first.
    private func headVerdict<A: SealedBackupV2Adapter>(
        _ adapter: A,
        service: SealedBackupService,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch,
        explicit: Bool
    ) async throws -> SealedBackupV2HeadVerdict {
        let payload = adapter.payload
        let fetched = try await service.fetchHeadRecord(payloadType: payload)
        try ensureGate(adapter, epoch: epoch)
        guard let installTag = writerTag() else { return .stop(.failed) }
        guard let head = fetched else {
            // R1-BR-10: no head while on and resolved → the set is owed, written in this pass.
            if !isDirty(payload) { host.markSealedBackupDirty(payload) }
            host.sealedBackupBookkeeping.clearObservedHead(payload)
            return .pass(floor: 0, headExists: false)
        }
        let accepted = host.sealedBackupBookkeeping.acceptedHead(payload, installTag: installTag)
        if accepted?.matchesMetadata(of: head) == true, !Self.waivesE1(trigger) {
            host.sealedBackupBookkeeping.clearObservedHead(payload)
            return isDirty(payload) || explicit ? .pass(floor: head.generation, headExists: true) : .upToDate
        }
        return classifyHead(head, adapter: adapter, service: service, trigger: trigger, installTag: installTag, accepted: accepted)
    }

    /// The §5.5 table for a head whose metadata is not this install's accepted one: opened inside
    /// the adapter's seam; unopenable heads classified by why.
    private func classifyHead<A: SealedBackupV2Adapter>(
        _ head: SealedBackupRecord,
        adapter: A,
        service: SealedBackupService,
        trigger: SealedBackupTrigger,
        installTag: String,
        accepted: SealedBackupAcceptedHead?
    ) -> SealedBackupV2HeadVerdict {
        let payload = adapter.payload
        let opened: SealedBackupV2OpenedHead
        do {
            opened = try adapter.withOpenSeam { try openHead(head, service: service) }
        } catch {
            return unopenableVerdict(error, head: head, service: service, trigger: trigger)
        }
        let own = (opened.header != nil && opened.stamp.writer == installTag)
            || (opened.header == nil && !head.signingPublicKey.isEmpty && head.signingPublicKey == service.localSigningPublicKey)
        let explicitlyReplaced = trigger == .startNew || trigger == .replace(opened.stamp)
        guard own || accepted?.stamp == opened.stamp || explicitlyReplaced else {
            host.sealedBackupBookkeeping.recordObservedHead(opened.stamp, payload, installTag: installTag)
            FernletAuditLog.log("sealedBackup.v2.heldByAnotherDevice", context: ["payload": payload.rawValue])
            return .stop(.heldByAnotherDevice(opened.stamp))
        }
        host.sealedBackupBookkeeping.clearObservedHead(payload)
        return .pass(floor: head.generation, headExists: true)
    }

    /// The §5.5 rows for a head that does not open (or whose envelope this build cannot read).
    private func unopenableVerdict(
        _ error: Error,
        head: SealedBackupRecord,
        service: SealedBackupService,
        trigger: SealedBackupTrigger
    ) -> SealedBackupV2HeadVerdict {
        let ownSigning = !head.signingPublicKey.isEmpty && head.signingPublicKey == service.localSigningPublicKey
        let reason: SealedBackupV2Status
        switch error {
        case SealedBackupV2FormatError.unsupportedVersion, SealedBackupV2FormatError.malformedEnvelope, is DecodingError:
            // It opened, but its envelope is a shape this build cannot read: never overwritten
            // automatically (§5.5).
            reason = .needsNewerFernlet
        case IdentityError.notProvisioned:
            reason = .waitingForBackupKey
        case SealedBackupError.keyAgreementIdentityMismatch:
            // Sealed by this install under an escrow key it has since replaced (WS-3 adopt): its own.
            if ownSigning { return .pass(floor: head.generation, headExists: true) }
            reason = host.sealedBackupEscrowConflict ? .waitingForBackupKey : .headSealedWithOtherKey
        case SealedBackupError.malformedRecord:
            reason = .headDamaged
        default:
            reason = .failed
        }
        // "Start a new backup" writes over every unopenable head (never over a newer-format one).
        if trigger == .startNew, reason != .needsNewerFernlet, reason != .failed {
            return .pass(floor: head.generation, headExists: true)
        }
        return .stop(reason)
    }

    /// X6's mint rule (§5.6, R2-F1): a missing escrow key may be minted only for an explicit "Start a
    /// new backup", or when NO enabled v2 payload has a head in iCloud — checked by head-existence
    /// fetches (no decrypt; at most one per v2 payload) — so a new iPhone never mints a divergent key
    /// while the synced one is on its way. G is re-checked after the fetches; a fetch that fails
    /// throws (the export fails transiently, it never mints on a read that did not answer).
    private func mayMintEscrowKey<A: SealedBackupV2Adapter>(
        trigger: SealedBackupTrigger,
        service: SealedBackupService,
        epoch: PassEpoch,
        adapter: A
    ) async throws -> Bool {
        guard trigger != .startNew else { return true }
        let prefs = preferences()
        let others = adapters.keys.filter { $0 != adapter.payload && prefs.isSealedBackupEnabled(for: $0) }.sorted { $0.rawValue < $1.rawValue }
        var anyHead = false
        for other in others {  // R2: at most the v2 payloads (three).
            if try await service.fetchHeadRecord(payloadType: other) != nil { anyHead = true }
        }
        try ensureGate(adapter, epoch: epoch)
        return !anyHead
    }
}
