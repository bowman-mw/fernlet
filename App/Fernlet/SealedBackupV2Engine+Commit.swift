import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation

/// What the prepare produced (§4.2 X7).
enum SealedBackupV2Preparation {
    /// Every chunk sealed; ready to commit.
    case ready(SealedBackupV2PreparedSet)
    /// Nothing written: why (paused, needs a newer build, too large, failed).
    case refused(SealedBackupV2Status)
}

/// Holds a background-task token so its expiry handler can end it.
@MainActor
private final class BackgroundTaskToken {
    var value: Int?
}

extension SealedBackupV2Engine {
    /// X7, the prepare (E3, §4.2): re-checks G, snapshots the ids, computes the generation
    /// (`max(lastSeen, accepted, head) + 1`, persisted only on commit, §5.4), a fresh set tag and
    /// salt, then classifies and seals every chunk IN MEMORY — G re-checked (the live hub key re-read)
    /// before every chunk's decrypt, a yield after each. Suffix chunks first and the head last, so the
    /// head's `total` is the number of records the set really carries. Any undecided row fails, any
    /// row a newer build wrote stops, any dead row pauses — all before a single save.
    func prepare<A: SealedBackupV2Adapter>(
        _ adapter: A,
        service: SealedBackupService,
        floor: Int64,
        epoch: PassEpoch
    ) async throws -> SealedBackupV2Preparation {
        let payload = adapter.payload
        try ensureGate(adapter, epoch: epoch)
        guard let writer = writerTag() else { return .refused(.failed) }
        let ids = try adapter.snapshotIDs()
        guard ids.count <= Self.maxRecords else { return .refused(.tooLarge) }
        let accepted = host.sealedBackupBookkeeping.acceptedHead(payload, installTag: writer)?.stamp.generation ?? 0
        let base = max(service.lastSeenGeneration(for: payload), accepted, floor)
        guard base < Int64.max / 2 else { return .refused(.failed) }
        var set = SealedBackupV2PreparedSet(
            chunks: [:], setTag: SealedBackupSetTag.mint(), keySalt: SealedBackupService.mintKeySalt(),
            generation: base + 1, writer: writer, mutationsBefore: host.sealedBackupMutationEpoch(payload)
        )
        var tally = PrepareTally()
        let count = max(1, (ids.count + Self.chunkSize - 1) / Self.chunkSize)
        for index in stride(from: count - 1, through: 0, by: -1) {  // R2: ≤ 400 chunks (maxRecords / chunkSize).
            try ensureGate(adapter, epoch: epoch)
            guard let key = liveHubKey else { throw SealedBackupV2Stop.gate(.hubClosed) }
            let slice = Array(ids[min(index * Self.chunkSize, ids.count)..<min((index + 1) * Self.chunkSize, ids.count)])
            let page = try adapter.classifiedChunk(slice, hubKey: key)
            tally.absorb(page)
            if tally.isClean {
                let envelope = SealedBackupV2Envelope(writer: writer, set: set.setTag, total: index == 0 ? tally.records : nil, records: page.records)
                let record = try service.sealChunk(
                    try SealedBackupV2Format.encode(envelope), payloadType: payload,
                    chunkIndex: index, chunkCount: count, generation: set.generation, keySalt: set.keySalt
                )
                tally.bytes += record.ciphertext.count
                guard tally.bytes <= Self.maxPreparedBytes else { return .refused(.tooLarge) }
                set.chunks[index] = record
            }
            await Task.yield()
        }
        return tally.verdict(payload, engine: self) ?? .ready(set)
    }

    /// X8, the commit (§4.2, §5.2) inside a background-task assertion: the suffix chunks under their
    /// set-scoped names, then the head — the one commit point — with the commit gate (no wipe, no
    /// reset, the backup and iCloud sync still on, not turned off, not cancelled) checked before EVERY
    /// save; then the verify (the head re-fetched must carry this set's generation and salt) and a
    /// best-effort prune. Nothing is decrypted here, so a closed hub or a hide does not stop it.
    func commit<A: SealedBackupV2Adapter>(
        _ set: SealedBackupV2PreparedSet,
        adapter: A,
        service: SealedBackupService,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch
    ) async throws -> SealedBackupV2ExportResult {
        let payload = adapter.payload
        let token = BackgroundTaskToken()
        let tasks = backgroundTasks
        token.value = tasks.begin("Fernlet Sealed backup") {
            if let value = token.value { tasks.end(value) }
            token.value = nil
        }
        defer {
            if let value = token.value { tasks.end(value) }
            token.value = nil
        }
        for index in set.chunks.keys.sorted(by: >) {  // R2: the prepared chunks; the head (0) last.
            if let stop = workStop(payload, epoch: epoch) { throw SealedBackupV2Stop.gate(stop) }
            guard let record = set.chunks[index] else { continue }
            try await service.save(record, setTag: set.setTag)
        }
        let landed = try await service.fetchHeadRecord(payloadType: payload)
        guard landed?.generation == set.generation, landed?.keySalt == set.keySalt else {
            FernletAuditLog.log("sealedBackup.v2.commitVerifyFailed", context: ["payload": payload.rawValue])
            return finish(.failed, payload)
        }
        do {
            let pruned = try await service.pruneSets(payloadType: payload, keepingSetTag: set.setTag, belowGeneration: set.generation)
            FernletAuditLog.log("sealedBackup.v2.pruned", context: ["payload": payload.rawValue, "records": String(pruned)])
        } catch {
            // Best-effort: orphans of older sets stay until the next commit's prune; nothing a head
            // points at is ever deleted.
            FernletAuditLog.log("sealedBackup.v2.pruneFailed", context: ["payload": payload.rawValue])
        }
        return finishCommit(set, payload: payload, service: service, trigger: trigger, epoch: epoch)
    }

    /// X9: the bookkeeping, only while the epoch is unchanged — the rollback floor, the accepted head
    /// (this install's tag, the generation, the salt prefix), the observation, the marker when E1 was
    /// waived, dirty (cleared ONLY when no mutation landed since the prepare began), the status and
    /// the intent.
    private func finishCommit(
        _ set: SealedBackupV2PreparedSet,
        payload: SealedBackupPayloadType,
        service: SealedBackupService,
        trigger: SealedBackupTrigger,
        epoch: PassEpoch
    ) -> SealedBackupV2ExportResult {
        guard !host.deleteAllInProgress, currentEpoch() == epoch else {
            FernletAuditLog.log("sealedBackup.v2.commitBookkeepingSkipped", context: ["payload": payload.rawValue])
            return SealedBackupV2ExportResult(gateFailure: .workStopped, stopped: true)
        }
        service.recordCommittedOrAccepted(set.generation, for: payload)
        let accepted = SealedBackupAcceptedHead(
            stamp: SealedBackupHeadStamp(writer: set.writer, generation: set.generation),
            saltPrefix: SealedBackupAcceptedHead.saltPrefix(of: set.keySalt)
        )
        host.sealedBackupBookkeeping.recordAcceptedHead(accepted, payload, installTag: set.writer)
        host.sealedBackupBookkeeping.clearObservedHead(payload)
        if Self.waivesE1(trigger) { host.sealedBackupBookkeeping.markRestoreResolved(payload) }
        let clean = host.sealedBackupMutationEpoch(payload) == set.mutationsBefore
        if clean { host.recordSealedBackupReuploadDeferred(false, payloadType: payload) }
        lastExportFailure[payload] = nil
        lastPausedIDs[payload] = nil
        consumeIntent(payload)
        FernletAuditLog.log("sealedBackup.v2.committed", context: [
            "payload": payload.rawValue, "chunks": String(set.chunks.count), "clean": clean ? "true" : "false"
        ])
        return finish(.upToDate, payload)
    }
}

/// The prepare's running classification (§4.2 X7).
private struct PrepareTally {
    /// Records that opened, across every chunk so far.
    var records = 0
    /// Ids that can never open here.
    var dead: [UUID] = []
    /// Ids a newer build wrote.
    var needsNewer: [UUID] = []
    /// Rows this attempt could not decide.
    var transient = 0
    /// Prepared ciphertext so far.
    var bytes = 0

    /// Whether every row so far opened (only then is anything sealed).
    var isClean: Bool { dead.isEmpty && needsNewer.isEmpty && transient == 0 }

    /// Adds one page's classification.
    mutating func absorb<Record>(_ page: SealedBackupChunkPage<Record>) {
        records += page.records.count
        dead += page.deadIDs
        needsNewer += page.needsNewerBuildIDs
        transient += page.transientCount
    }

    /// The refusal the tally amounts to, or nil when every row opened: any undecided row fails, any
    /// newer-build row stops, any dead row pauses (remembering the ids for "Remove them").
    @MainActor
    func verdict(_ payload: SealedBackupPayloadType, engine: SealedBackupV2Engine) -> SealedBackupV2Preparation? {
        guard isClean else {
            if transient > 0 { return .refused(.failed) }
            if !needsNewer.isEmpty { return .refused(.needsNewerFernlet) }
            engine.lastPausedIDs[payload] = Set(dead)
            FernletAuditLog.log("sealedBackup.v2.pausedUnopenable", context: ["payload": payload.rawValue, "dead": String(dead.count)])
            return .refused(.paused(unopenableIDs: dead))
        }
        return nil
    }
}
