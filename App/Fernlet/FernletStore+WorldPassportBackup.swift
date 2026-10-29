import CloudKitSync
import Foundation
import WorldMapStore

/// The World passport in Fernlet's Sealed iCloud backup (round 7; owner 2026-10-29: "so a new phone gets
/// it back", and the passport backup should "have its own switch"): the store's half of
/// `SealedBackupContext`'s two passport members and of the passport payload's Privacy & Data row.
///
/// The passport is a payload of its own (`.worldPassport`, ``PassportBackupAdapter``) behind its own
/// switch (`sealedBackupPassportEnabled`), on the same v2 engine as the journal: sealed through the same
/// content-key path before anything reaches CloudKit, with its own owner hold, compare-and-swap,
/// spacing and deletes.
///
/// Both members go through the ONE `WorldAtlasKeeper` (``worldFog``'s `atlas`), so the book the map shows
/// and the book the backup carries are the same, and a restore shows at once. Both refuse in a decoy.
extension FernletStore {
    /// The passport its backup carries; throws in a decoy and while it can't be read.
    func sealedBackupWorldPassport() throws -> PassportBook {
        try worldFog.atlas.bookForBackup()
    }

    /// Merges a passport the passport backup's restore carried (by token, the earliest date kept) and
    /// saves it; how many entries were added or moved earlier. Throws in a decoy and when it was not
    /// saved.
    func restoreSealedBackupWorldPassport(_ book: PassportBook) throws -> Int {
        try worldFog.atlas.restore(book)
    }

    /// What the passport backup has to tell Privacy & Data (the journal row's rules, round 7): the
    /// engine's status this process, else — after a relaunch — what persists (an unresolved restore,
    /// another iPhone's set, an owed upload). NOTHING during a duress session (the decoy shows an empty
    /// passport: no held, paused, waiting or catch-up row, and no backup action) and nothing while the
    /// owner hold keeps its pre-reset copy (the shared owner line speaks for every kind). The passport
    /// has no hide switch.
    var passportBackupRowState: SealedBackupV2RowState {
        guard !duressSessionActive else { return .none }
        let prefs = sealedBackupPreferences
        let tag = SealedBackupWriterTag.current()
        return SealedBackupV2RowState.derive(
            status: sealedBackupV2Status[.worldPassport],
            intentPending: sealedBackupEngine.intents[.worldPassport] != nil,
            rolledBackStamp: sealedBackupEngine.rolledBackStamps[.worldPassport],
            persisted: SealedBackupV2RowState.Persisted(
                syncAndBackupOn: prefs.iCloudSyncEnabled && prefs.sealedBackupPassportEnabled,
                keptForOwner: sealedBackupRestoreHold.keepsPreResetCopy(of: .worldPassport),
                restoreResolved: sealedBackupBookkeeping.restoreResolvedIsSet(.worldPassport),
                observed: sealedBackupBookkeeping.observedHead(.worldPassport, installTag: tag),
                dirty: isSealedBackupReuploadOwed(.worldPassport)
            )
        )
    }

    /// Whether the passport slot in iCloud was last observed as another iPhone's (the persisted
    /// observation, install-bound) — turning this iPhone's switch off then keeps it (R2-F3), and
    /// Privacy & Data's confirmation says so.
    var passportBackupSlotIsAnotherIPhones: Bool {
        sealedBackupBookkeeping.observedHead(.worldPassport, installTag: SealedBackupWriterTag.current()) != nil
    }
}
