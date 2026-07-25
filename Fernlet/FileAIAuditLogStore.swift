import Foundation
import AIContext

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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(&directory)
        self.fileURL = directory.appendingPathComponent("ai-audit-log.json")
    }

    /// Keeps the audit directory out of the encrypted iCloud / Finder device backup so a "what left my
    /// device" ledger cannot itself leave the device via a backup. Best-effort (a failure to set the
    /// flag never blocks logging); re-applied after any directory recreate in `save`.
    private static func excludeFromBackup(_ directory: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
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
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Re-assert the backup exclusion in case the directory was just recreated (post delete-all).
        Self.excludeFromBackup(&directory)
        // Metadata only (no prompt text / user values), but written with file protection anyway; the
        // "until first user authentication" class keeps it writable from background AI work.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
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
