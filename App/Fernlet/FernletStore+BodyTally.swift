import Foundation
import PrivateHealthStore

/// The Bodybuilding tallies on the app store — bathroom visits per day and free-meal tags (World
/// bodybuilding spec §5–§7; round 7 piece B1). The Log panel's Bathroom tile, the Log meal sheet's
/// Free meal chip and the Day calendar call exactly these names.
///
/// Nothing is stored on `FernletStore`: every call goes to the sealed funnel ``bodyTallyStore``
/// (`BodyTallyStore.shared`, on the shared sealed store and the journal device key) with the decoy
/// flag ``duressSessionActive``, so a duress session reads nothing and keeps nothing. Reads are
/// observable — they register on the funnel's change token, so a view that shows a count redraws
/// when a tally changes. Day keys are `yyyy-MM-dd` (``todayKey``'s shape); a malformed key reads as
/// empty and its writes fail with ``BodyTallyWriteFailure/invalidDay``.
///
/// **Sealed iCloud backup** (piece B2). The tallies ride on the head of the journal's Sealed backup
/// set, so every write here that lands marks the JOURNAL's upload owed
/// (``noteBodyTallyWrite(_:)`` → `markSealedBackupDirty(.journalNarratives)`), and the next journal
/// export carries the change. The backup's own two members are in `FernletStore+BodyTallyBackup.swift`.
extension FernletStore {
    /// The sealed body-tally funnel every call below goes through.
    var bodyTallyStore: BodyTallyStore { BodyTallyStore.shared }

    /// Moves whenever a tally changes — for a view that wants to redraw without reading a tally.
    var bodyTallyChangeToken: Int { bodyTallyStore.changeToken }

    /// The most recent tally write that did not land (nil once one lands) — so a tap that could not
    /// be sealed is never silent.
    var bodyTallyLastWriteFailure: BodyTallyWriteFailure? { bodyTallyStore.lastWriteFailure }

    /// The day's bathroom visits (0 when none, and in a decoy).
    func bathroomVisits(on dateKey: String) -> Int {
        bodyTallyStore.tally(on: dateKey, isDecoy: duressSessionActive)?.bathroomVisits ?? 0
    }

    /// Adds one bathroom visit to the day — the Bathroom tile's tap.
    @discardableResult
    func addBathroomVisit(on dateKey: String) -> BodyTallyWriteResult {
        noteBodyTallyWrite(bodyTallyStore.addBathroomVisit(on: dateKey, isDecoy: duressSessionActive))
    }

    /// Sets the day's bathroom visits — the tile's hold-to-fix — clamped to `0...30`.
    @discardableResult
    func setBathroomVisits(_ count: Int, on dateKey: String) -> BodyTallyWriteResult {
        noteBodyTallyWrite(bodyTallyStore.setBathroomVisits(count, on: dateKey, isDecoy: duressSessionActive))
    }

    /// Whether the meal is tagged as a free meal on the day (false in a decoy).
    func isFreeMeal(_ mealID: UUID, on dateKey: String) -> Bool {
        bodyTallyStore.tally(on: dateKey, isDecoy: duressSessionActive)?.isFreeMeal(mealID) ?? false
    }

    /// Tags or untags the meal as a free meal on the day — the Free meal chip.
    @discardableResult
    func setFreeMeal(_ isFree: Bool, mealID: UUID, on dateKey: String) -> BodyTallyWriteResult {
        noteBodyTallyWrite(bodyTallyStore.setFreeMeal(isFree, mealID: mealID, on: dateKey, isDecoy: duressSessionActive))
    }

    /// The tallies of the days `startKey...endKey` inclusive, by day key — the Day calendar's month
    /// and week. Days with nothing are absent; empty in a decoy.
    func bodyTallies(from startKey: String, through endKey: String) -> [String: BodyDayTally] {
        bodyTallyStore.tallies(from: startKey, through: endKey, isDecoy: duressSessionActive)
    }

    /// Clears the day's tally (both its visits and its free-meal tags).
    @discardableResult
    func deleteBodyTally(on dateKey: String) -> BodyTallyWriteResult {
        noteBodyTallyWrite(bodyTallyStore.deleteTally(on: dateKey, isDecoy: duressSessionActive))
    }

    /// Drops every tally row without decrypting — ungated, for a wipe hook. Delete everything, Reset
    /// app lock and the duress wipe already clear the rows without it (the store rebuild and the
    /// journal device key's deletion); this is the explicit leg a hook can call.
    ///
    /// - Returns: Whether the delete succeeded.
    func deleteAllBodyTalliesForWipe() -> Bool {
        bodyTallyStore.deleteAll()
    }
}
