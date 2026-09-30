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
/// Set only by the app-lock reset funnel, never by a duress response (those never fire the reset
/// hook). **Kept** by "delete everything": a phone whose lock was reset and whose data was then
/// wiped must not start restoring ambiently either. Standard (device-local) defaults, injected so
/// tests get an isolated suite. One boolean; no content.
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
