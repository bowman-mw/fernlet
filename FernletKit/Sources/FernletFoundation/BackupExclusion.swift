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
    /// The sibling `.<StoreName>_SUPPORT` directory Core Data spills attributes flagged
    /// `allowsExternalBinaryDataStorage` into once their value passes ~100 KB.
    ///
    /// The ONE spelling of that path in the codebase, deliberately: ``apply(storeURL:excluded:includeSupportDir:)``
    /// flags it for backup exclusion and `PrivatePersistenceController.rebuildStore()` deletes it
    /// during the sealed-store rebuild, and the two must never drift onto different directories —
    /// a rebuild aimed at the wrong path would leave standalone ciphertext blob files on disk while
    /// reporting a clean wipe. (It used to be two copies of the same expression; it is now one.)
    ///
    /// - Parameter storeURL: The `.sqlite` store file URL.
    /// - Returns: The support directory URL. Pure path arithmetic — the directory need not exist.
    public static func supportDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
    }

    public static func apply(storeURL: URL, excluded: Bool, includeSupportDir: Bool) {
        var urls = [storeURL,
                    URL(fileURLWithPath: storeURL.path + "-wal"),
                    URL(fileURLWithPath: storeURL.path + "-shm")]
        if includeSupportDir {
            urls.append(supportDirectory(for: storeURL))
        }
        for url in urls {
            apply(fileURL: url, excluded: excluded)
        }
    }

    /// Sets `isExcludedFromBackupKey` to `excluded` on a single standalone file or directory — the
    /// variant for stores with no Core Data sidecars (today: `LocalFernletRepository`'s JSON day
    /// blob, security-hardening Phase 6). Kept separate from
    /// ``apply(storeURL:excluded:includeSupportDir:)`` so a sidecar-less caller does not log a
    /// permanent failure for `-wal`/`-shm` files that can never exist. Same contract otherwise:
    /// idempotent, and a failure (e.g. the file does not exist yet) is logged, never fatal.
    ///
    /// - Important: The flag lives on the file's inode, so an ATOMIC rewrite (temp file + rename)
    ///   silently drops it — callers that rewrite their file must re-apply after every write, the
    ///   way `LocalFernletRepository.saveDatabase` does.
    public static func apply(fileURL: URL, excluded: Bool) {
        do {
            try (fileURL as NSURL).setResourceValue(excluded, forKey: URLResourceKey.isExcludedFromBackupKey)
        } catch {
            print("[Fernlet] Failed to set backup exclusion (\(excluded)) for \(fileURL.lastPathComponent): \(error)")
        }
    }
}
