import Foundation

/// "An app-lock reset destroyed the key every sealed row here was written under; the next Sealed
/// backup restore waits for the device owner" — the persisted `fernlet.sealedBackup.restoreAwaitsOwner`
/// bit (period-data design 2026-09-30, §5.3, owner question Q14).
///
/// **Why it exists.** A reset leaves an empty sealed store, and the reset funnel clears the three
/// divergence latches (they spoke for the destroyed key). Without this hold, the next ambient restore
/// — the launch pass, the Private tab's settle, an un-hide — would pull the whole cloud history back
/// onto a phone whose passcode was just reset, with nobody proving they are the owner. While the bit
/// is set, every AMBIENT restore skips every payload; the explicit restores (the user's Retry, and
/// the owner-checked "Restore Sealed backup" action in Privacy & Data that design unit 5 adds and
/// that releases the hold) still run.
///
/// **It holds every re-upload too** (review C-U2-R1). After the reset the local stores hold only
/// what was written since; re-sealing them would REPLACE the pre-reset history in iCloud — the very
/// copy this bit keeps for the owner. So the deferred re-uploads (the Private tab's settle, the launch
/// follow-through, the Retry pass) and the escrow adopt's re-seal leave their deferral flags set and
/// write nothing until the hold is released. Together: the cloud copy stays exactly as it was.
///
/// **Nothing releases it in this build.** The release is design unit 5's owner-checked restore; until
/// then no copy may promise a restore after a reset (pinned by `LocalizationBoundaryTests`, which
/// looks for a releasing member here).
///
/// Set only by the app-lock reset funnel, never by a duress response (those never fire the reset
/// hook). **Kept** by "delete everything": a phone whose lock was reset and whose data was then
/// wiped must not start restoring ambiently either. Standard defaults, injected so tests get an
/// isolated suite — so, like the divergence latches, it travels inside an iCloud or Finder device
/// backup, and a new iPhone set up from one arrives held (fail closed: that iPhone's restore then
/// also waits for the owner's explicit action). One boolean; no content.
struct SealedBackupRestoreHold {
    /// The frozen persisted key.
    static let defaultsKey = "fernlet.sealedBackup.restoreAwaitsOwner"

    /// Where the bit lives.
    let defaults: UserDefaults

    /// Whether ambient restores must wait for the device owner.
    var isHeld: Bool { defaults.bool(forKey: Self.defaultsKey) }

    /// Sets the hold (the app-lock reset funnel).
    func hold() {
        defaults.set(true, forKey: Self.defaultsKey)
    }
}
