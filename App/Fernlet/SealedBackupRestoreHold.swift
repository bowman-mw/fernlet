import CloudKitSync
import FernletFoundation
import Foundation

/// "An app-lock reset destroyed the key every sealed row here was written under; the next Sealed
/// backup restore waits for the device owner" — the persisted `fernlet.sealedBackup.restoreAwaitsOwner`
/// bit (period-data design 2026-09-30, §5.3, owner question Q14), plus the per-payload record of which
/// pre-reset iCloud copies that bit is keeping (`fernlet.sealedBackup.preResetCopies`).
///
/// **Why it exists.** A reset leaves an empty sealed store, and the reset funnel clears the three
/// divergence latches (they spoke for the destroyed key). Without this hold, the next ambient restore
/// — the launch pass, the Private tab's settle, an un-hide — would pull the whole cloud history back
/// onto a phone whose passcode was just reset, with nobody proving they are the owner. While the bit
/// is set, every AMBIENT restore skips every payload; the explicit restores (the user's Retry, and
/// the owner-checked "Restore Sealed backup" action in Privacy & Data that design unit 5 adds and
/// that releases the hold) still run.
///
/// **It holds the re-uploads that would replace a pre-reset copy** (review C-U2-R1). After the reset
/// the local stores hold only what was written since; re-sealing them would REPLACE the pre-reset
/// history in iCloud — the very copy this bit keeps for the owner. So for each payload whose backup
/// was on at the reset, the deferred re-uploads (the Private tab's settle, the launch follow-through,
/// the Retry pass) and the escrow adopt's re-seal leave their deferral flags set and write nothing.
///
/// **Scoped to the copies that exist** (review N-1). The re-upload hold covers only the payloads
/// recorded at the reset (their backup switch was on), and a payload leaves that record the moment
/// its iCloud chunk set is deleted — the user turning that backup off, or "delete everything"'s
/// delete leg — because from then on there is no pre-reset copy left to keep, and holding its uploads
/// would only stop the user's new entries from ever being backed up. A delete that FAILED leaves the
/// payload recorded: the copy may still be up there. The ambient-restore half stays whole: it is
/// about who may pull history down, not about what is up there.
///
/// **Nothing releases it in this build.** The release is design unit 5's owner-checked restore; until
/// then no copy may promise a restore after a reset (pinned by `LocalizationBoundaryTests`, which
/// looks for a releasing member here).
///
/// Set only by the app-lock reset funnel, never by a duress response (those never fire the reset
/// hook). **Kept** by "delete everything" (both keys): a phone whose lock was reset and whose data was
/// then wiped must not start restoring ambiently either, and a copy whose delete failed must stay
/// protected. Standard defaults, injected so tests get an isolated suite — so, like the divergence
/// latches, it travels inside an iCloud or Finder device backup, and a new iPhone set up from one
/// arrives held (fail closed: that iPhone's restore then also waits for the owner's explicit action).
/// One boolean and up to three payload tokens; no content.
struct SealedBackupRestoreHold {
    /// The frozen persisted key of the hold itself.
    static let defaultsKey = "fernlet.sealedBackup.restoreAwaitsOwner"

    /// The frozen persisted key of the per-payload half: the raw values (frozen tokens) of the payloads
    /// whose pre-reset iCloud copy the hold keeps. Absent while the hold is set reads as "every
    /// payload" — fail closed: a hold without its record never lets an upload through.
    static let preResetCopiesKey = "fernlet.sealedBackup.preResetCopies"

    /// The payloads a re-upload can write. The retired `.sensitiveNotes` is never sealed again, so it
    /// never has a copy to keep.
    static let reuploadablePayloads: [SealedBackupPayloadType] = [.periodData, .journalNarratives, .intimacyLogs]

    /// Where the bits live.
    let defaults: UserDefaults

    /// Whether ambient restores must wait for the device owner.
    var isHeld: Bool { defaults.bool(forKey: Self.defaultsKey) }

    /// The payloads whose pre-reset iCloud copy the hold keeps right now (empty while not held).
    var payloadsKeepingPreResetCopy: Set<SealedBackupPayloadType> {
        Set(Self.reuploadablePayloads.filter(keepsPreResetCopy(of:)))
    }

    /// Sets the hold (the app-lock reset funnel), recording as kept the payloads whose backup switch is
    /// on in `preferences` — the ones that can have a copy in iCloud. The record is written before the
    /// bit, so a set hold never reads a record older than the latest reset.
    ///
    /// - Parameter preferences: The storage preferences at the moment of the reset.
    func hold(keepingCopiesFrom preferences: StoragePreferences) {
        let kept = Self.reuploadablePayloads.filter { Self.isBackedUp($0, in: preferences) }
        defaults.set(kept.map(\.rawValue), forKey: Self.preResetCopiesKey)
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Whether a re-upload of `payload` must wait: the hold is set and that payload's pre-reset copy is
    /// still kept.
    ///
    /// - Parameter payload: The payload about to be re-sealed.
    func keepsPreResetCopy(of payload: SealedBackupPayloadType) -> Bool {
        guard isHeld, Self.reuploadablePayloads.contains(payload) else { return false }
        guard let kept = defaults.stringArray(forKey: Self.preResetCopiesKey) else { return true }
        return kept.contains(payload.rawValue)
    }

    /// Records that `payload`'s iCloud chunk set was deleted, so there is no pre-reset copy of it left
    /// to keep and its re-uploads may run again. Writes nothing while the hold is not set.
    ///
    /// - Parameter payload: The payload whose backup was deleted from iCloud.
    func forgetPreResetCopy(of payload: SealedBackupPayloadType) {
        guard isHeld else { return }
        let kept = defaults.stringArray(forKey: Self.preResetCopiesKey)
            ?? Self.reuploadablePayloads.map(\.rawValue)
        defaults.set(kept.filter { $0 != payload.rawValue }, forKey: Self.preResetCopiesKey)
    }

    /// Whether `payload`'s backup switch is on in `preferences`.
    private static func isBackedUp(_ payload: SealedBackupPayloadType, in preferences: StoragePreferences) -> Bool {
        switch payload {
        case .periodData: return preferences.sealedBackupPeriodEnabled
        case .journalNarratives: return preferences.sealedBackupJournalEnabled
        case .intimacyLogs: return preferences.sealedBackupIntimacyEnabled
        case .sensitiveNotes: return false
        }
    }
}
