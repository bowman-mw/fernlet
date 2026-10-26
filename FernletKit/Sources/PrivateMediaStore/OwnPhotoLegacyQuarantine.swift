import Foundation
import FernletFoundation

/// Where an own-photo store moves a file that is present but unreadable before a restore writes over
/// it: `LegacyQuarantine/<corpus>/` under the same documents root as the corpora, excluded from
/// backup (W-19, 2026-10-26).
///
/// Why it exists: photos sealed before the `FMA2` marker (2026-08-26) and not re-sealed in the one
/// day the Phase 2.3 migrator lived open under nothing this build ships, yet their bytes are intact.
/// The escrow restore reads a corpus holding only such files as dead bytes and writes the cloud
/// copies over them by id, and the progress-index merge replaces an unreadable index whole. Either
/// would destroy the only local copy a later one-time reader could still open, so the store moves
/// the file here first and writes only once it has.
///
/// Invariants:
/// - **Never deletes, never overwrites.** A name already taken here gets a unique one
///   (`<stem>-<uuid>.<ext>`), and `FileManager.moveItem` itself refuses an existing destination.
///   Only the owning store's `deleteAll()` removes the folder, which Delete everything and the
///   duress silent wipe reach through `FernletStore.deletePhotoCorpora`.
/// - **Never uploaded or synced.** It lies outside every corpus directory, so neither the escrow
///   backup, the format census nor the migration (``OwnPhotoCorpusLayout/sealedLocations(in:)``)
///   enumerates it; the root carries `isExcludedFromBackup`.
/// - **Fail closed.** When the move or the backup exclusion fails, ``moveAside(_:)`` answers false
///   and the caller must not write.
///
/// Concurrency: a `Sendable` value over two URLs; the owning store's isolation serialises its use.
public struct OwnPhotoLegacyQuarantine: Sendable, Equatable {
    /// `LegacyQuarantine/` under the documents directory.
    public let root: URL
    /// This corpus's folder: `LegacyQuarantine/<corpus directory name>/`.
    public let directory: URL

    /// The quarantine for one corpus.
    ///
    /// - Parameters:
    ///   - documentsDirectory: The own-photo root the corpora hang off.
    ///   - corpusDirectoryName: The corpus's directory name in ``OwnPhotoCorpusLayout``
    ///     (`MealPhotos`, `RecipePhotos` or `ProgressPhotos`).
    public init(documentsDirectory: URL, corpusDirectoryName: String) {
        root = documentsDirectory.appendingPathComponent(
            OwnPhotoCorpusLayout.legacyQuarantineDirectoryName, isDirectory: true
        )
        directory = root.appendingPathComponent(corpusDirectoryName, isDirectory: true)
    }

    /// Moves `file` into this corpus's folder under a name no copy here already has.
    ///
    /// R7: not `@discardableResult` — false means the file is still where it was, and the caller
    /// must not write over it.
    /// - Returns: whether the file is now in quarantine.
    public func moveAside(_ file: URL) -> Bool {
        let corpus = directory.lastPathComponent
        do {
            try prepareDirectory()
            try FileManager.default.moveItem(at: file, to: destination(for: file.lastPathComponent))
        } catch {
            FernletAuditLog.log("ownPhoto.quarantineFailed", context: [
                "corpus": corpus, "errorType": String(describing: type(of: error))
            ])
            return false
        }
        FernletAuditLog.log("ownPhoto.quarantined", context: ["corpus": corpus])
        return true
    }

    /// Removes this corpus's folder: the Delete everything half, called by the owning store's
    /// `deleteAll()`. R7: not `@discardableResult` — false means set-aside photos survived it.
    /// - Returns: whether the folder is gone.
    public func deleteAll() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            return false
        }
        return true
    }

    /// Creates the folder (complete file protection, like every sealed write) and marks the root
    /// excluded from backup, which covers everything under it.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = root
        try target.setResourceValues(values)
    }

    /// `name` when it is free here, else `<stem>-<uuid>.<ext>`: never a quarantined copy's name.
    private func destination(for name: String) -> URL {
        let plain = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: plain.path) else { return plain }
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        let unique = "\(stem)-\(UUID().uuidString)"
        return directory.appendingPathComponent(pathExtension.isEmpty ? unique : "\(unique).\(pathExtension)")
    }
}
