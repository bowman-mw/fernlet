import Foundation
import WorldMapStore

/// The World passport in Fernlet's Sealed iCloud backup (round 7; owner 2026-10-29: "so a new phone gets
/// it back"): the store's half of `SealedBackupContext`'s two passport members.
///
/// The passport is not a payload of its own. It rides on the head of the JOURNAL's Sealed backup set
/// (`JournalBackupAdapter`, `SealedBackupV2Envelope.passport`), so it is sealed by the journal's own
/// content-key path before anything reaches CloudKit, and it follows the journal's switch
/// (`sealedBackupJournalEnabled`), owner hold, compare-and-swap and deletes. There is no new screen or
/// settings row: whether the passport gets a switch of its own is the design session's call.
///
/// Both members go through the ONE `WorldAtlasKeeper` (``worldFog``'s `atlas`), so the book the map shows
/// and the book the backup carries are the same, and a restore shows at once. Both refuse in a decoy.
extension FernletStore {
    /// The passport the journal's backup carries; throws in a decoy and while it can't be read.
    func sealedBackupWorldPassport() throws -> PassportBook {
        try worldFog.atlas.bookForBackup()
    }

    /// Merges a passport the journal's restore carried (by token, the earliest date kept) and saves it;
    /// throws in a decoy and when it was not saved.
    func restoreSealedBackupWorldPassport(_ book: PassportBook) throws {
        try worldFog.atlas.restore(book)
    }
}
