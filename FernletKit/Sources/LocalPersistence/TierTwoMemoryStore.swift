//
//  TierTwoMemoryStore.swift
//  LocalPersistence
//
//  The device-local home of the Tier-2 behavioral memories (owner decision 2026-09-23).
//

import Foundation
import FernletFoundation
import FernletDomainModel

/// The device-local, never-mirrored, never-backed-up home of the Tier-2 behavioral memories that
/// `TierTwoMemoryEngine` infers — one small JSON file beside the local database.
///
/// **Owner decision 2026-09-23: "Tier 2 sensitive notes shouldn't be backed up to iCloud at all."**
/// Until then the engine's output was a slice of ``LocalFernletDatabase`` — the aggregate blob
/// `CoreDataFernletRepository` writes into the CloudKit-mirrored `FernletDatabaseRecord`, in
/// plaintext, whenever iCloud sync is on. The slice is gone from the blob (a pre-decision blob's key
/// is ignored on decode and absent from the next encode, which is what scrubs the mirrored record),
/// and the records live here instead. Three properties make this file device-local rather than
/// merely "somewhere else":
/// - **Never mirrored.** A plain Application Support file, not a Core Data store — no
///   `NSPersistentCloudKitContainer` can export it, and no synced type has a field it could ride in.
/// - **Never in a device backup.** `isExcludedFromBackup` is set after EVERY write (an atomic rewrite
///   replaces the inode the flag lives on) and at `init`, unconditionally. That is deliberately
///   stronger than the preference-driven exclusion of the sealed store and the day-blob file: iCloud
///   Backup is iCloud too, and nothing is lost by it — the records are derived, so after a restore
///   the next save re-derives them from the restored day history (only first-seen dates reset).
/// - **Encrypted at rest** with `.completeFileProtection`, like the day-blob file beside it.
///
/// Persisted rather than recomputed per read because the engine is change-driven: a record's
/// `extractedDate` is when its verdict was FIRST seen — `MemoryAgent`'s 30-day recency filter keys on
/// it — and superseded verdicts stay behind as inactive history. A from-scratch recompute of the
/// 14-day window reproduces neither, so the previous records are an input the engine genuinely needs.
///
/// Failure policy — derived data, so best-effort, never silent: ``refresh(from:goals:)`` audits a
/// failed write and the NEXT save retries it (the engine re-derives from whatever is on disk); it
/// never fails the caller's save. A file that exists but cannot be READ (protected data unavailable)
/// is never overwritten from an empty base; one that reads but will not DECODE is corrupt derived
/// data, treated as empty, and replaced by the next refresh.
///
/// Wiped by "delete everything" through the owning repository's `purgeAllPersistedData()` (see
/// ``purge()``); the Core Data repository reuses its legacy repository's store, so both backends
/// agree on one file per install.
///
/// Concurrency: a nonisolated value type over an immutable URL with a synchronous API, like
/// ``LocalFernletRepository`` (this target declares no default actor isolation); each owner confines
/// its instance to its own actor.
public struct TierTwoMemoryStore: Sendable {
    /// The sidecar file. Exposed for diagnostics and for tests that assert on the bytes.
    public let fileURL: URL

    /// Creates a store over `fileURL` and re-asserts its backup exclusion when the file already exists
    /// (idempotent — heals a flag an earlier write failed to set).
    public init(fileURL: URL) {
        assert(fileURL.isFileURL, "Tier-2 store must be a file URL")
        self.fileURL = fileURL
        BackupExclusion.apply(fileURL: fileURL, excluded: true)
    }

    /// The sidecar location for a local database file: `<stem>-TierTwoMemories.json` in the same
    /// directory. Derived from the database file rather than fixed, so every repository location —
    /// the production `FernletDatabase.json`, or a test's unique temporary file — gets its own sidecar
    /// and no two test repositories share one.
    public static func sidecarURL(besideDatabaseAt databaseURL: URL) -> URL {
        assert(databaseURL.isFileURL, "database location must be a file URL")
        let stem = databaseURL.deletingPathExtension().lastPathComponent
        return databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-TierTwoMemories")
            .appendingPathExtension("json")
    }

    /// The persisted records — empty when none were ever inferred, and when the file cannot be read
    /// or decoded (both audited by the read).
    public func load() -> [TierTwoMemoryRecord] {
        switch read() {
        case .records(let records):
            return records
        case .unreadable:
            return []
        }
    }

    /// Runs `TierTwoMemoryEngine` over `days` (oldest-first) against the persisted records and writes
    /// the result back when — and only when — it changed. Called by both repositories after every
    /// SUCCESSFUL save, with the same day window the derived tables were rebuilt from.
    ///
    /// Best-effort by design (see the type's failure policy): a skipped or failed write is audited and
    /// retried by the next save, and nothing here can fail the save that called it.
    public func refresh(from days: [(String, FernletDay)], goals: [FitnessGoal]) {
        guard case .records(let existing) = read() else {
            FernletAuditLog.log("tierTwo.refresh.skippedUnreadable")
            return
        }
        let updated = TierTwoMemoryEngine.updateInferences(existing: existing, from: days, goals: goals)
        guard updated != existing else { return }
        if !write(updated) {
            FernletAuditLog.log("tierTwo.refresh.writeFailed", context: ["count": String(updated.count)])
        }
    }

    /// Deletes the sidecar. Removing the file (rather than writing an empty list) leaves nothing on
    /// disk, and an absent file already reads as "no records".
    ///
    /// - Returns: `false` only when a file existed and could not be removed. Not discardable (R7):
    ///   "delete everything" reports the store it could not clear.
    public func purge() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            PersistenceFailureAudit.record("tierTwo.purge.failed", error: error)
            return false
        }
    }

    /// What a read of the sidecar produced. `unreadable` is kept apart from "no records" so a
    /// refresh can refuse to overwrite a file it merely could not open.
    private enum ReadOutcome {
        case records([TierTwoMemoryRecord])
        case unreadable
    }

    /// Reads and decodes the sidecar: absent → no records; unreadable → `.unreadable`; undecodable →
    /// no records (corrupt derived data the next refresh replaces).
    private func read() -> ReadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .records([]) }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            PersistenceFailureAudit.record("tierTwo.read.failed", error: error)
            return .unreadable
        }
        do {
            return .records(try RowPayloadCoders.makeDecoder().decode([TierTwoMemoryRecord].self, from: data))
        } catch {
            PersistenceFailureAudit.record("tierTwo.decode.failed", error: error)
            return .records([])
        }
    }

    /// Encodes and atomically writes the records with `.completeFileProtection`, then re-flags the NEW
    /// inode as excluded from device backups.
    private func write(_ records: [TierTwoMemoryRecord]) -> Bool {
        assert(fileURL.isFileURL, "Tier-2 store must be a file URL")
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try RowPayloadCoders.makeEncoder().encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            PersistenceFailureAudit.record("tierTwo.write.failed", error: error)
            return false
        }
        // The atomic write replaced the inode, dropping the exclusion the previous file carried.
        BackupExclusion.apply(fileURL: fileURL, excluded: true)
        return true
    }
}
