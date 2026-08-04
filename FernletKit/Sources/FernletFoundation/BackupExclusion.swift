// BackupExclusion.swift
// FernletFoundation
//
// Layer-0 helper for toggling `isExcludedFromBackupKey` across a Core Data
// store file and its sidecars. Shared by the sealed store
// (`PrivatePersistenceController`) and the synced store (`PersistenceController`)
// so the two backup-exclusion loops cannot drift apart again. Operates purely on
// `URL`s (no CoreData import) so it can live below the S3 wall and be reused by
// both modules.

import Foundation

/// Namespace for toggling iOS-backup exclusion across a Core Data store file and its sidecars.
///
/// Shared by both persistence controllers — the sealed store's `PrivatePersistenceController`
/// (PrivateStoreCore) and the synced store's `PersistenceController` (CloudKitSync) — so the two
/// backup-exclusion loops stay identical instead of drifting apart. It operates purely on `URL`s
/// with no CoreData import, which is what lets it live at Layer 0 where modules on both sides of
/// the S3 wall can reach it. The app re-applies the user's
/// ``StoragePreferences/localBackupExcludedFromiOSBackup`` choice through this helper on launch;
/// the re-apply is idempotent, so sidecars that did not exist on an earlier pass self-heal on the
/// next one. `nonisolated`: pure file-attribute writes, callable from any executor.
public nonisolated enum BackupExclusion {
    /// Sets `isExcludedFromBackupKey` to `excluded` on a Core Data store file, its `-wal`/`-shm`
    /// sidecars, and — when `includeSupportDir` is true — the sibling `.<StoreName>_SUPPORT`
    /// external-binary-storage directory (where attributes flagged `allowsExternalBinaryDataStorage`
    /// spill blobs > ~100 KB). A per-URL failure (e.g. a sidecar/dir that does not exist yet) is
    /// logged, not fatal — first-session sidecars self-heal on the next launch's idempotent re-apply.
    ///
    /// - Parameters:
    ///   - storeURL: The `.sqlite` store file URL.
    ///   - excluded: The value to write to `isExcludedFromBackupKey`.
    ///   - includeSupportDir: Whether to also exclude the `.<StoreName>_SUPPORT` directory. Pass
    ///     `true` for stores whose attributes use `allowsExternalBinaryDataStorage`.
    public static func apply(storeURL: URL, excluded: Bool, includeSupportDir: Bool) {
        var urls = [storeURL,
                    URL(fileURLWithPath: storeURL.path + "-wal"),
                    URL(fileURLWithPath: storeURL.path + "-shm")]
        if includeSupportDir {
            let supportDir = storeURL.deletingLastPathComponent()
                .appendingPathComponent(".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
            urls.append(supportDir)
        }
        for url in urls {
            do {
                try (url as NSURL).setResourceValue(excluded, forKey: URLResourceKey.isExcludedFromBackupKey)
            } catch {
                print("[Fernlet] Failed to set backup exclusion (\(excluded)) for \(url.lastPathComponent): \(error)")
            }
        }
    }
}
