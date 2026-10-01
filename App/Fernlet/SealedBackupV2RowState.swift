import CloudKitSync
import Foundation

/// What Privacy & Data says about one Sealed backup v2 payload's backup (journal and intimacy Sealed
/// backup v2 design 2026-09-30, §10.1) — the ONE mapping from the engine's in-memory status and the
/// persisted bookkeeping to a row, shared by `FernletStore` and the tests. The intimate-log rows
/// (unit B2) and the journal rows (unit B3) use it; the period card keeps its own
/// ``PeriodBackupExportState`` (period design §10.6).
///
/// Nothing here is decrypted or fetched: it reads what the last pass left (``SealedBackupV2Status``)
/// and, after a relaunch, what persists — the owner hold, an unresolved restore marker, the observed
/// foreign head, the owed upload — in that order (§10.1, R2-F13b). The first hub visit refines it.
enum SealedBackupV2RowState: Equatable {
    /// Nothing to say: the backup is current, off, held for the owner (the shared owner line speaks)
    /// or iCloud sync is off (the switches speak for themselves, R2-F13d).
    case none
    /// The user made a choice here; the next Private visit carries it out ("Open Private to finish.").
    case finishing
    /// This install has not pulled its backup yet; the next Private visit will (E1 holds the export).
    case waitingForRestore
    /// Waiting for the backup key from iCloud Keychain. `restoring`: a restore waits for it (new
    /// entries are not backed up until it arrives); else an export does. "Start a new backup" is
    /// offered behind its confirmation.
    case waitingForKey(restoring: Bool)
    /// The set in iCloud was saved from another iPhone (or by an earlier Fernlet that named no
    /// iPhone): "Restore it here" or "Replace", each for exactly this set.
    case heldByAnotherDevice(SealedBackupHeadStamp)
    /// The restore refused the set as older than one this iPhone has seen: "Restore anyway" or
    /// "Replace" for exactly this set.
    case olderThanSeen(SealedBackupHeadStamp)
    /// The set is sealed with a backup key this iPhone does not have: "Start a new backup".
    case sealedWithOtherKey
    /// The set is tagged with this iPhone's key but will not authenticate: "Start a new backup".
    case damaged
    /// The set's envelope, or a row here, needs a newer version of Fernlet. No action.
    case needsNewerFernlet
    /// Entries this iPhone can never open pause the backup: "Remove them" for exactly these ids.
    case paused([UUID])
    /// More than the backup's record or byte bound. No action.
    case tooLarge
    /// The last export did not finish; the next Private visit retries it. No action.
    case failed
    /// New entries are owed and the next Private visit adds them (true when shown, R1-BR-14).
    case catchUp

    /// The persisted inputs a row reads after a relaunch (and the switches that silence it).
    struct Persisted: Equatable {
        /// Whether iCloud sync and this payload's backup are both on.
        var syncAndBackupOn: Bool
        /// Whether the app-lock reset's owner hold keeps this payload's pre-reset copy.
        var keptForOwner: Bool
        /// Whether this install's restore marker reads resolved (never seeded from here).
        var restoreResolved: Bool
        /// The persisted observation of another iPhone's set, if any (install-bound).
        var observed: SealedBackupHeadStamp?
        /// Whether the upload is owed (the persisted re-upload flag).
        var dirty: Bool
    }

    /// The row for `status` (nil: none this process) — see the type's documentation for the order.
    ///
    /// - Parameters:
    ///   - status: The engine's status for the payload this process, if any.
    ///   - intentPending: Whether an explicit choice waits for the next Private visit.
    ///   - rolledBackStamp: The set the last restore refused as older than this iPhone's floor.
    ///   - persisted: The persisted inputs.
    static func derive(
        status: SealedBackupV2Status?,
        intentPending: Bool,
        rolledBackStamp: SealedBackupHeadStamp?,
        persisted: Persisted
    ) -> SealedBackupV2RowState {
        guard persisted.syncAndBackupOn, !persisted.keptForOwner else { return .none }
        guard !intentPending else { return .finishing }
        guard let status else {
            if !persisted.restoreResolved { return .waitingForRestore }
            if let observed = persisted.observed { return .heldByAnotherDevice(observed) }
            return persisted.dirty ? .catchUp : .none
        }
        return fromStatus(status, rolledBackStamp: rolledBackStamp, dirty: persisted.dirty)
    }

    /// The row for a status the engine recorded this process.
    private static func fromStatus(
        _ status: SealedBackupV2Status,
        rolledBackStamp: SealedBackupHeadStamp?,
        dirty: Bool
    ) -> SealedBackupV2RowState {
        switch status {
        case .upToDate: return dirty ? .catchUp : .none
        case .waitingForRestore(.deferredKeyNotSynced?): return .waitingForKey(restoring: true)
        case .waitingForRestore(.notRecognized?): return .damaged
        case .waitingForRestore(.rolledBack?): return rolledBackStamp.map(SealedBackupV2RowState.olderThanSeen) ?? .waitingForRestore
        case .waitingForRestore: return .waitingForRestore
        case .heldForOwner: return .none
        case .heldByAnotherDevice(let stamp): return .heldByAnotherDevice(stamp)
        case .waitingForBackupKey: return .waitingForKey(restoring: false)
        case .headSealedWithOtherKey: return .sealedWithOtherKey
        case .headDamaged: return .damaged
        case .needsNewerFernlet: return .needsNewerFernlet
        case .paused(let ids): return .paused(ids)
        case .tooLarge: return .tooLarge
        case .failed: return .failed
        }
    }
}
