import Foundation
import AIContext
import FernletFoundation

/// The device-local, NON-SYNCED persistence sink for the AI audit log (Ladder §7.2), backed by a
/// single JSON file in Application Support — the same "per-device ledger" stance as
/// `UserDefaultsAICallQuotaStore`. It deliberately lives in the app target, not in any module
/// `AIProviders` imports: the walled AI module can only reach the log through the `AIAuditLog` actor +
/// the injected `AIAuditLogPersisting` protocol (declared in `AIContext`), never by naming this type.
///
/// DEVICE-LOCAL ONLY, by construction:
/// - It writes to Application Support, which Fernlet never syncs (iCloud is CloudKit-CoreData, not a
///   ubiquity file container). Application Support would otherwise ride the encrypted device backup
///   (iCloud / Finder), so the directory is marked `isExcludedFromBackup` — this file therefore cannot
///   leave the device even through a device backup, matching the "what left my device" semantics.
/// - It is NOT part of `FernletSnapshot`, CloudKit, or the sealed backup — `AIContext` depends only on
///   `FernletDomainModel`, so no synced/sealed type can even name `AIAuditEntry`.
/// - It lives OUTSIDE `DataExportBuilder.dataExportsDirectory` (a tmp/ subfolder) and the export is an
///   explicit allowlist projection, never a directory walk — so a data export never picks it up.
/// - `FernletStore.deleteAllData` clears it (via `AIAuditLog.clear()` and a direct `clear()`).
final class FileAIAuditLogStore: AIAuditLogPersisting {
    private let fileURL: URL
    /// The protocol is `Sendable`; serialize file access so a `save` from the audit actor can't race a
    /// `clear` from the delete-all funnel.
    private let lock = NSLock()

    /// - Parameter fileURL: override for tests. Defaults to
    ///   `<AppSupport>/FernletAIAudit/ai-audit-log.json`.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("FernletAIAudit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Benign: `save` re-creates the directory on every write, so a failure here only delays
            // the first persist. Logged so a permanently uncreatable directory is visible.
            FernletAuditLog.log("aiAudit.directoryCreateFailed",
                                context: ["stage": "init", "errorType": "\(type(of: error))"])
        }
        if !Self.excludeFromBackup(&directory) {
            FernletAuditLog.log("aiAudit.backupExclusionFailed", context: ["stage": "init"])
        }
        self.fileURL = directory.appendingPathComponent("ai-audit-log.json")
    }

    /// Keeps the audit directory out of the encrypted iCloud / Finder device backup so a "what left my
    /// device" ledger cannot itself leave the device via a backup. Best-effort (a failure to set the
    /// flag never blocks logging); re-applied after any directory recreate in `save`.
    /// - Returns: `false` when the exclusion flag could not be written — the caller logs it.
    private static func excludeFromBackup(_ directory: inout URL) -> Bool {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try directory.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    func load() -> [AIAuditEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A single unknown enum token parks (tolerant per-entry decode); a wholly corrupt file yields
        // an empty log rather than propagating a throw — either way the log never fails the caller.
        guard let entries = try? decoder.decode([AIAuditEntry].self, from: data) else { return [] }
        return Array(entries.suffix(AIAuditLog.entryLimit))
    }

    func save(_ entries: [AIAuditEntry]) {
        lock.lock(); defer { lock.unlock() }
        let capped = Array(entries.suffix(AIAuditLog.entryLimit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(capped) else { return }
        var directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            // The write below cannot succeed without the directory: give up this round (the next
            // `save` retries the whole capped array, which the in-memory actor still holds).
            FernletAuditLog.log("aiAudit.directoryCreateFailed",
                                context: ["stage": "save", "errorType": "\(type(of: error))"])
            return
        }
        // Re-assert the backup exclusion in case the directory was just recreated (post delete-all).
        if !Self.excludeFromBackup(&directory) {
            FernletAuditLog.log("aiAudit.backupExclusionFailed", context: ["stage": "save"])
        }
        // Metadata only (no prompt text / user values), but written with file protection anyway; the
        // "until first user authentication" class keeps it writable from background AI work.
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Benign: the `AIAuditLog` actor still holds this session's entries and the next `save`
            // rewrites the whole capped array; only survival across relaunch is lost.
            FernletAuditLog.log("aiAudit.saveFailed", context: ["errorType": "\(type(of: error))"])
        }
    }

    func clear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Nothing on disk is a clean sweep, not a failure — and it is the common case here because the
        // delete-all funnel clears this sink directly AND the `AIAuditLog` actor clears the same file,
        // so the second removal legitimately finds no file.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            // The file is still on disk — report the failure so delete-all doesn't claim a clean wipe.
            return false
        }
    }
}
