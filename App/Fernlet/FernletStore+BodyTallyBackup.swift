import CloudKitSync
import Foundation
import PrivateHealthStore

/// The body tallies in Fernlet's Sealed iCloud backup (World bodybuilding spec §7, owner's answer 2:
/// "Store them encrypted like the journal, inside the sealed iCloud backup"; round 7 piece B2): the
/// store's half of `SealedBackupContext`'s two body-tally members, and the mutation hook.
///
/// The tallies are not a payload of their own. They ride on the head of the JOURNAL's Sealed backup
/// set (`JournalBackupAdapter`, `SealedBackupV2Envelope.bodyTally`), so they are sealed by the
/// journal's own content-key path before anything reaches CloudKit, never plain, and they follow the
/// journal's switch (`sealedBackupJournalEnabled`), owner hold, compare-and-swap and deletes. No new
/// screen, setting, `UserDefaults` key or CloudKit field.
///
/// Every member goes through the ONE sealed funnel (``bodyTallyStore``) with ``duressSessionActive``,
/// so a decoy hands out nothing and merges nothing (both throw).
extension FernletStore {
    /// Every tally the journal's backup carries, in day order; throws in a decoy and while the
    /// tallies can't be read right now (never an empty list in their place).
    func sealedBackupBodyTallies() throws -> [BodyDayTally] {
        try bodyTallyStore.tallyBackupExport(isDecoy: duressSessionActive)
    }

    /// Merges the tallies a journal restore carried (per day: the higher count, the union of the
    /// tags, never a delete) and saves them; throws in a decoy and when they were not saved.
    func restoreSealedBackupBodyTallies(_ tallies: [BodyDayTally]) throws {
        try bodyTallyStore.mergeRestoredTallies(tallies, isDecoy: duressSessionActive)
    }

    /// The tally writes' mutation hook: a write that LANDED marks the journal's upload owed, since the
    /// journal set's head carries the tallies — the next journal export (behind its switch and gates)
    /// writes the change. Anything else (unchanged, at a limit, dropped in a decoy, failed) owes
    /// nothing. `markSealedBackupDirty` sets no flag during "Delete everything". Returns `result`.
    @discardableResult
    func noteBodyTallyWrite(_ result: BodyTallyWriteResult) -> BodyTallyWriteResult {
        if result == .saved { markSealedBackupDirty(.journalNarratives) }
        return result
    }
}
