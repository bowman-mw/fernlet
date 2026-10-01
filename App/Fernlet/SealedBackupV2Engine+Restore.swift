import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import ProximityKit

/// What the restore phase ended in (§4.2 R).
struct SealedBackupV2RestoreResult {
    /// The outcome the façades report (recorded on the host only when the restore really ran).
    var outcome: SealedBackupRestoreOutcome?
    /// The gate it stopped at, if any.
    var gateFailure: SealedBackupV2GateFailure?
    /// Whether a wipe, reset, turn-off or cancellation stopped it.
    var stopped = false
    /// Whether the set was merged and accepted (R10): the export follows, skipping spacing.
    var accepted = false

    /// Whether the pass goes on to its export phase: not after a gate stop, and not after a set only a
    /// newer Fernlet reads — the export could only hold behind E1 or name that same set as another
    /// iPhone's, burying the one thing the user can act on: update Fernlet (review B3 fix round 1).
    var continueToExport: Bool { gateFailure == nil && !stopped && outcome != .needsNewerFernlet }
}

/// A head the restore or export opened (§5.5): its record, plaintext and stamp.
struct SealedBackupV2OpenedHead {
    /// The head record as CloudKit holds it.
    let record: SealedBackupRecord
    /// Its decrypted plaintext.
    let plaintext: Data
    /// Its stamp (`v1` writer for a bare array).
    let stamp: SealedBackupHeadStamp
    /// The v2 envelope header; nil for a v1 set.
    let header: SealedBackupV2EnvelopeHeader?
}

extension SealedBackupV2Engine {
    /// The restore phase (§4.2 R1–R10) for one payload: an id-keyed MERGE of the cloud set, opened
    /// under `.forOpening` (never minting), verified (writer, set, salt, total, rollback) and merged
    /// with the live hub key, with G re-checked after every await and before every decrypt and write.
    func restorePhase<A: SealedBackupV2Adapter>(
        _ adapter: A,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch
    ) async -> SealedBackupV2RestoreResult {
        let payload = adapter.payload
        // R1: the owner hold stops every restore trigger — explicit ones and Retry included (R1-BR-15).
        guard !host.sealedBackupRestoreAwaitsOwner else {
            FernletAuditLog.log("sealedBackup.restoreHeldForOwner", context: ["site": "v2." + payload.rawValue])
            return SealedBackupV2RestoreResult(outcome: .deferredTransient, gateFailure: .heldForOwner)
        }
        // R2: ambient spacing.
        guard trigger.skipsSpacing || !restoreIsSpaced(payload) else {
            return SealedBackupV2RestoreResult(outcome: lastRestoreOutcome[payload])
        }
        // R3: the escrow key, never minted. Its absence is decided AFTER the head fetch (review
        // B1-C-B1-1): with no head there is nothing to wait for — the restore resolves and the export's
        // mint rule (§5.6) may mint the first key; only a head that exists waits for the synced key.
        guard let opening = openingService() else { return recordRestore(.deferredTransient, payload, trigger: trigger) }
        restoredThisSession.insert(payload)
        FernletAuditLog.log("sealedBackup.restoreAttempt", context: ["payload": payload.rawValue])
        do {
            return try await fetchAndMerge(
                adapter, service: opening.service, escrowReady: opening.escrowReady, trigger: trigger, epoch: epoch
            )
        } catch let stop as SealedBackupV2Stop {
            return stopResult(stop, payload)
        } catch {
            // A CloudKit call a quiesce cancelled (CancellationError / CKError.operationCancelled), or
            // any failure once G no longer holds, is a stop: nothing recorded, no backoff (B1-C-B1-5).
            if let failure = gateFailure(adapter, epoch: epoch) { return stopResult(.gate(failure), payload) }
            return recordRestore(Self.classifyRestoreFailure(error, payload: payload), payload, trigger: trigger)
        }
    }

    /// R4–R10: fetch, open, verify and merge; throws ``SealedBackupV2Stop`` at a gate. Without an
    /// escrow key only the head's existence is read (no decrypt): none resolves the restore (R5); one
    /// waits for the synced key (`.deferredKeyNotSynced`).
    private func fetchAndMerge<A: SealedBackupV2Adapter>(
        _ adapter: A,
        service: SealedBackupService,
        escrowReady: Bool,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch
    ) async throws -> SealedBackupV2RestoreResult {
        let payload = adapter.payload
        let fetched = try await service.fetchHeadRecord(payloadType: payload)
        try ensureGate(adapter, epoch: epoch)
        guard !host.sealedBackupRestoreAwaitsOwner else { throw SealedBackupV2Stop.gate(.heldForOwner) }
        guard let headRecord = fetched else { return noHead(payload, trigger: trigger) }
        guard escrowReady else { return recordRestore(.deferredKeyNotSynced, payload, trigger: trigger) }
        let head = try adapter.withOpenSeam { try Self.decodingAuthenticated { try openHead(headRecord, service: service) } }
        if case .restoreHere(let chosen, _) = trigger, chosen != head.stamp {
            return heldAgain(payload, stamp: head.stamp)
        }
        try checkRollback(head, payload: payload, service: service, trigger: trigger)
        let suffix = try await service.fetchSuffixRecords(
            payloadType: payload, chunkCount: headRecord.chunkCount, setTag: head.header?.set
        )
        try ensureGate(adapter, epoch: epoch)
        let records = try adapter.withOpenSeam {
            try Self.decodingAuthenticated { try openAndVerify(adapter, head: head, suffix: suffix, service: service) }
        }
        try ensureGate(adapter, epoch: epoch)
        guard let key = liveHubKey else { throw SealedBackupV2Stop.gate(.hubClosed) }
        let merged = try adapter.restoreMerging(records, hubKey: key)
        let followedUp = adapter.didRestore(merged)
        return acceptRestore(adapter, head: head, merged: merged, followedUp: followedUp,
                             service: service, trigger: trigger, epoch: epoch)
    }

    /// R5: no head — nothing to restore. The marker resolves for an ambient restore (even while the
    /// owner hold's pre-reset record remains: there is nothing up there to protect), the observation
    /// clears, and the payload is marked dirty so the export writes this iPhone's set.
    private func noHead(_ payload: SealedBackupPayloadType, trigger: SealedBackupTrigger) -> SealedBackupV2RestoreResult {
        if case .restoreHere = trigger {} else { host.sealedBackupBookkeeping.markRestoreResolved(payload) }
        host.sealedBackupBookkeeping.clearObservedHead(payload)
        host.markSealedBackupDirty(payload)
        FernletAuditLog.log("sealedBackup.restoreNothingToRestore", context: ["payload": payload.rawValue])
        var result = recordRestore(.nothingToRestore, payload, trigger: trigger)
        result.accepted = true
        return result
    }

    /// R6: a "Restore it here" whose set was replaced since — back to the held state with the new
    /// stamp and both choices (R1-BR-4); nothing merged, nothing recorded as an outcome.
    private func heldAgain(_ payload: SealedBackupPayloadType, stamp: SealedBackupHeadStamp) -> SealedBackupV2RestoreResult {
        if let tag = writerTag() { host.sealedBackupBookkeeping.recordObservedHead(stamp, payload, installTag: tag) }
        consumeIntent(payload)
        setStatus(.heldByAnotherDevice(stamp), payload)
        FernletAuditLog.log("sealedBackup.v2.restoreHereSetChanged", context: ["payload": payload.rawValue])
        return SealedBackupV2RestoreResult(outcome: nil)
    }

    /// R8's rollback check (§5.4): a set below this install's floor is refused as `.rolledBack`,
    /// except exactly the stamp of a "Restore it here" / "Restore anyway" that ignores it, and the set
    /// this install has ACCEPTED (its stamp and salt prefix — once "Restore anyway" merged a set below
    /// the floor, the ambient restore that resolves the marker merges it again rather than refusing it
    /// forever; review B1-D-B1-R1). A refused set is remembered so Privacy & Data can offer both choices.
    private func checkRollback(
        _ head: SealedBackupV2OpenedHead,
        payload: SealedBackupPayloadType,
        service: SealedBackupService,
        trigger: SealedBackupTrigger
    ) throws {
        let floor = service.lastSeenGeneration(for: payload)
        guard head.stamp.generation < floor else { return }
        if case .restoreHere(let chosen, true) = trigger, chosen == head.stamp { return }
        let accepted = host.sealedBackupBookkeeping.acceptedHead(payload, installTag: writerTag())
        if accepted?.matchesMetadata(of: head.record) == true { return }
        rolledBackStamps[payload] = head.stamp
        throw SealedBackupError.staleGeneration(found: head.stamp.generation, lastSeen: floor)
    }

    /// R10: bookkeeping, only while the epoch is unchanged — the accepted head, the rollback floor,
    /// the marker (an ambient restore; "Restore it here" leaves it alone), the observation, dirty, the
    /// outcome, and the intent. A follow-up write that failed keeps the restore unresolved (R1-BR-6).
    private func acceptRestore<A: SealedBackupV2Adapter>(
        _ adapter: A,
        head: SealedBackupV2OpenedHead,
        merged: SealedBackupMergeResult,
        followedUp: Bool,
        service: SealedBackupService,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch
    ) -> SealedBackupV2RestoreResult {
        let payload = adapter.payload
        guard currentEpoch() == epoch else { return stopResult(.gate(.workStopped), payload) }
        host.markSealedBackupDirty(payload)
        guard followedUp else { return recordRestore(.deferredTransient, payload, trigger: trigger) }
        if let tag = writerTag() {
            let accepted = SealedBackupAcceptedHead(stamp: head.stamp, saltPrefix: SealedBackupAcceptedHead.saltPrefix(of: head.record.keySalt))
            host.sealedBackupBookkeeping.recordAcceptedHead(accepted, payload, installTag: tag)
        }
        service.recordCommittedOrAccepted(head.stamp.generation, for: payload)
        if case .restoreHere = trigger {} else { host.sealedBackupBookkeeping.markRestoreResolved(payload) }
        host.sealedBackupBookkeeping.clearObservedHead(payload)
        consumeIntent(payload)
        FernletAuditLog.log("sealedBackup.v2.restoreMerged", context: [
            "payload": payload.rawValue, "changed": String(merged.changedCount)
        ])
        var result = recordRestore(merged.changedAnything ? .restored(merged.changedCount) : .nothingToRestore, payload, trigger: trigger)
        result.accepted = true
        return result
    }

    /// Records a restore outcome that really ran (§4.2): on the host (Privacy & Data's status, and the
    /// owner hold's "nothing pre-reset left to keep" on a landed one), the backoff on a failure, and
    /// — for a terminal outcome of an explicit restore — the intent is consumed.
    func recordRestore(
        _ outcome: SealedBackupRestoreOutcome,
        _ payload: SealedBackupPayloadType,
        trigger: SealedBackupTrigger
    ) -> SealedBackupV2RestoreResult {
        lastRestoreOutcome[payload] = outcome
        host.recordSealedBackupRestoreOutcome(outcome, payloadType: payload)
        let landed = outcome.didRestore || outcome == .nothingToRestore
        if landed {
            host.recordSealedBackupPreResetCopySettled(payload)
            lastRestoreFailure[payload] = nil
            rolledBackStamps[payload] = nil
        } else {
            lastRestoreFailure[payload] = now()
        }
        if trigger.isExplicit, !outcome.isRetryable { consumeIntent(payload) }
        // A set only a newer Fernlet reads is named as such, whatever asked for it — never "will be
        // added the next time you open Private", which this build can never keep (no export follows).
        if outcome == .needsNewerFernlet { setStatus(.needsNewerFernlet, payload) }
        // A "Restore it here" that ended terminally returns to the held state with both choices
        // (R1-BR-4): the user can still replace the set, or restore it anyway. One that found a set
        // only a newer Fernlet reads says so instead (the next visit's E2 names the held set again).
        if case .restoreHere(let stamp, _) = trigger, !landed, !outcome.isRetryable, outcome != .needsNewerFernlet {
            setStatus(.heldByAnotherDevice(stamp), payload)
        }
        return SealedBackupV2RestoreResult(outcome: outcome)
    }

    /// Whether an ambient restore of `payload` must wait (§4.5): once per hub session, 15 minutes
    /// after a failed one — and for the rest of this process after one that found a set only a newer
    /// Fernlet can read (it would download and decrypt the whole set again to fail the same way; an
    /// update relaunches, and an explicit choice still runs).
    private func restoreIsSpaced(_ payload: SealedBackupPayloadType) -> Bool {
        restoredThisSession.contains(payload) || isBackingOff(since: lastRestoreFailure[payload])
            || lastRestoreOutcome[payload] == .needsNewerFernlet
    }

    /// Runs a step that decodes an AUTHENTICATED set's plaintext (the head's envelope, every chunk's
    /// records): a `DecodingError` there can only be a shape a newer Fernlet wrote, so it becomes
    /// ``SealedBackupV2FormatError/unreadableRecords`` — kept apart from any error a store's own merge
    /// throws later, which stays a retry.
    static func decodingAuthenticated<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch is DecodingError {
            throw SealedBackupV2FormatError.unreadableRecords
        }
    }

    /// A restore stopped at a gate: nothing written, nothing recorded (a hidden surface drops its
    /// status).
    func stopResult(_ stop: SealedBackupV2Stop, _ payload: SealedBackupPayloadType) -> SealedBackupV2RestoreResult {
        switch stop {
        case .gate(let failure):
            noteGateFailure(failure, payload)
            let stopped = failure == .wiping || failure == .workStopped
            return SealedBackupV2RestoreResult(outcome: Self.outcome(forGate: failure), gateFailure: failure, stopped: stopped)
        }
    }

    /// Throws ``SealedBackupV2Stop`` when G no longer holds.
    func ensureGate(_ adapter: some SealedBackupV2Adapter, epoch: PassEpoch) throws {
        if let failure = gateFailure(adapter, epoch: epoch) { throw SealedBackupV2Stop.gate(failure) }
    }

    /// The outcome a façade reports for a restore stopped at `gate` (never recorded).
    static func outcome(forGate gate: SealedBackupV2GateFailure) -> SealedBackupRestoreOutcome {
        gate == .hubClosed ? .deferredLocked : .deferredTransient
    }

    /// Maps a restore error to its outcome (§5.6): a key mismatch is a retryable wait for the key
    /// (`.deferredKeyNotSynced`, never the terminal `.notRecognized`), a record of ours that will not
    /// authenticate is `.notRecognized`, a set below the floor is `.rolledBack`, and a set that
    /// authenticated but whose envelope or records this build cannot read is `.needsNewerFernlet` —
    /// the restore's half of §5.5's "never overwritten automatically" (review B3 fix round 1);
    /// everything else — a transport error, a set whose chunks do not belong together — retries.
    static func classifyRestoreFailure(_ error: Error, payload: SealedBackupPayloadType) -> SealedBackupRestoreOutcome {
        switch error {
        case SealedBackupV2FormatError.unsupportedVersion, SealedBackupV2FormatError.malformedEnvelope,
             SealedBackupV2FormatError.unreadableRecords:
            FernletAuditLog.log("sealedBackup.restoreNeedsNewerFernlet", context: ["payload": payload.rawValue])
            return .needsNewerFernlet
        case SealedBackupError.keyAgreementIdentityMismatch, IdentityError.notProvisioned:
            FernletAuditLog.log("sealedBackup.restoreDeferredKeyNotSynced", context: ["payload": payload.rawValue])
            return .deferredKeyNotSynced
        case SealedBackupError.malformedRecord:
            FernletAuditLog.log("sealedBackup.restoreNotRecognized", context: ["payload": payload.rawValue])
            return .notRecognized
        case SealedBackupError.staleGeneration(let found, let lastSeen):
            FernletAuditLog.log("sealedBackup.restoreRolledBack", context: [
                "payload": payload.rawValue, "found": String(found), "lastSeen": String(lastSeen)
            ])
            return .rolledBack
        default:
            FernletAuditLog.log("sealedBackup.restoreFailed", context: ["payload": payload.rawValue])
            return .deferredTransient
        }
    }

    // MARK: - Opening and verifying a set

    /// Opens `record` as a set's head (inside the adapter's seam): its plaintext, stamp and — for a
    /// v2 envelope — its header. Throws the open error, or ``SealedBackupV2FormatError``.
    func openHead(_ record: SealedBackupRecord, service: SealedBackupService) throws -> SealedBackupV2OpenedHead {
        decryptCount += 1
        let plaintext = try service.open(record)
        guard !SealedBackupV2Format.isV1(plaintext) else {
            return SealedBackupV2OpenedHead(
                record: record, plaintext: plaintext,
                stamp: SealedBackupHeadStamp(writer: SealedBackupHeadStamp.v1Writer, generation: record.generation),
                header: nil
            )
        }
        let header = try SealedBackupV2Format.header(of: plaintext)
        guard header.total != nil else { throw SealedBackupV2FormatError.malformedEnvelope }
        return SealedBackupV2OpenedHead(
            record: record, plaintext: plaintext,
            stamp: SealedBackupHeadStamp(writer: header.writer, generation: record.generation),
            header: header
        )
    }

    /// R8: opens every suffix chunk, verifies the set (§5.3) and decodes it, reduced by id and capped.
    private func openAndVerify<A: SealedBackupV2Adapter>(
        _ adapter: A,
        head: SealedBackupV2OpenedHead,
        suffix: [SealedBackupRecord],
        service: SealedBackupService
    ) throws -> [A.Record] {
        guard suffix.allSatisfy({ $0.generation == head.record.generation && $0.chunkCount == head.record.chunkCount }) else {
            throw SealedBackupError.malformedRecord
        }
        var records: [A.Record] = []
        decryptCount += suffix.count
        for (offset, plaintext) in try ([head.plaintext] + suffix.map { try service.open($0) }).enumerated() {
            let chunk = try decodeChunk(adapter, plaintext, head: head, record: offset == 0 ? head.record : suffix[offset - 1])
            records += chunk
            guard records.count <= Self.maxRecords else { throw SealedBackupError.malformedRecord }
        }
        if let total = head.header?.total, records.count != total { throw SealedBackupV2FormatError.setMismatch }
        return reducedByID(adapter, records)
    }

    /// One chunk's records, after the §5.3 checks: a v1 set's chunks must all be v1; a v2 chunk's
    /// writer, set and salt must be the head's.
    private func decodeChunk<A: SealedBackupV2Adapter>(
        _ adapter: A,
        _ plaintext: Data,
        head: SealedBackupV2OpenedHead,
        record: SealedBackupRecord
    ) throws -> [A.Record] {
        guard let headHeader = head.header else {
            guard SealedBackupV2Format.isV1(plaintext) else { throw SealedBackupV2FormatError.setMismatch }
            return try adapter.decodeV1Chunk(plaintext)
        }
        guard !SealedBackupV2Format.isV1(plaintext), record.keySalt == head.record.keySalt else {
            throw SealedBackupV2FormatError.setMismatch
        }
        let envelope = try JSONDecoder().decode(SealedBackupV2Envelope<A.Record>.self, from: plaintext)
        guard envelope.writer == headHeader.writer, envelope.set == headHeader.set else {
            throw SealedBackupV2FormatError.setMismatch
        }
        return envelope.records
    }

    /// The records with one copy per id — the first in set order (a set built from one snapshot has
    /// unique ids; this only guards a hostile set).
    private func reducedByID<A: SealedBackupV2Adapter>(_ adapter: A, _ records: [A.Record]) -> [A.Record] {
        var seen = Set<UUID>()
        return records.filter { seen.insert(adapter.recordID($0)).inserted }
    }
}

/// A pass stopped at a gate (thrown out of the phases' inner steps).
enum SealedBackupV2Stop: Error, Equatable {
    /// G failed.
    case gate(SealedBackupV2GateFailure)
}
