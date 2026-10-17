// JSONSidecarFile.swift
// FernletSocial/Support
//
// The shared best-effort JSON sidecar idiom used by FernletSocial's device-local stores: the activity
// manager, the mesh photo-wall preferences (the photo object's), the moderation ledger, the closeness
// ledger and the friend-state cache. One home for the load/save/remove plumbing those stores share;
// each store keeps its own PersistedState shape and post-decode mapping. Every store that persists
// through it is this module's, so its doors are internal: no other module persists through it.
// Each owner states whether its file is kept out of iCloud device backups (bug confirmation
// 2026-10-15 §5), and a store whose file is data of record reads it through the classified `read()`
// and quarantines an undecodable one (§4) instead of the naive `load()`.

import FernletFoundation
import Foundation

/// Best-effort JSON file persistence for a device-local sidecar in Application Support
/// (`.completeFileProtection`, never synced) — the shared plumbing behind
/// ``ProximityActivityManager``, the mesh photo-wall preferences in ``MeshSessionPhotos``, and the
/// `ModerationLedger`, `ClosenessLedger` and `FriendStateCache`.
///
/// Internal, with ``init(fileURL:excludedFromBackup:)``, ``fileURL(in:name:)``, ``load()``,
/// ``read()``, ``quarantine()``, ``save(_:)`` and ``removeFile()``: every store that persists
/// through it is FernletSocial's. Every failure it audits goes to `FernletAuditLog` under its
/// `sidecar.*` name, whichever store it serves.
///
/// ``load()`` is deliberately the *naive* idiom: a read failure is indistinguishable from "absent".
/// A `load()` that fails for ANY reason — file absent, transient I/O error, or a
/// `.completeFileProtection` file touched while the device is locked — returns `nil`, which callers
/// treat as "no data"; the next `save(_:)` then overwrites the real file with that near-empty state
/// (the documented clobber hazard). That trade-off is acceptable only for reconstructible
/// convenience state (the activity, closeness and friend-state ledgers and the photo wall's
/// preferences). A store whose file is data of record reads it through ``read()`` instead, which
/// tells absent, unreadable and undecodable apart: it refuses to save while its file is unreadable
/// and moves an undecodable one aside with ``quarantine()`` (`ModerationLedger`, bug confirmation
/// 2026-10-15 §4). Writes and removals stay best-effort either way (they audit-log and move on).
///
/// `save(_:)` preserves the stores' exact operation order — encode (bail + log on failure), create the
/// parent directory, then an atomic `.completeFileProtection` write — and then, for an owner that
/// asked (``excludedFromBackup``), re-marks the file excluded from iCloud device backups, because the
/// atomic write's new inode drops the flag the old file carried (the `TierTwoMemoryStore` precedent).
struct JSONSidecarFile<State: Codable> {
    /// The on-disk location of the sidecar. Owners resolve it with `fileURL(in:name:)` against
    /// their host's ``ProximityHost/proximitySupportDirectory``; tests inject their own.
    let fileURL: URL

    /// Whether the file (and its quarantine) is kept out of iCloud device backups. Every owner states
    /// it: the ledgers say yes — a dated co-presence log, friends' wellbeing states, who reported whom
    /// and the activities joined are device-local social data that must not ride a backup Apple holds
    /// the keys to without Advanced Data Protection (bug confirmation 2026-10-15 §5). The photo wall's
    /// preferences say no until the owner decides whether they should (spec, the photo wall).
    let excludedFromBackup: Bool

    /// A sidecar at `fileURL`, which its owner always states (there is no default root), re-marking an
    /// existing file excluded from backup when the owner asks — idempotent, and it heals a file an
    /// earlier build wrote without the flag. A missing file is a no-op.
    ///
    /// - Parameters:
    ///   - fileURL: The sidecar's file: `fileURL(in:name:)` of the owner's sidecar root, or a test's
    ///     own file.
    ///   - excludedFromBackup: Whether the file stays out of iCloud device backups (no default: every
    ///     owner decides).
    init(fileURL: URL, excludedFromBackup: Bool) {
        self.fileURL = fileURL
        self.excludedFromBackup = excludedFromBackup
        guard excludedFromBackup else { return }
        BackupExclusion.apply(fileURL: fileURL, excluded: true)
    }

    /// Where ``quarantine()`` moves an undecodable file: `<name>.corrupt` beside it (the heart-drop
    /// outbox's `.json.corrupt` precedent). ``removeFile()`` removes it with the file.
    var quarantineURL: URL {
        fileURL.appendingPathExtension("corrupt")
    }

    /// This sidecar's file inside a given proximity-sidecar root — the ONE definition of the layout,
    /// so a scoped (per-store) root and the production root can never disagree.
    ///
    /// Every store here is shared MUTABLE on-disk state that some wipe reaches, and the test runner
    /// puts many stores in one process, so the root has to be per-instance rather than constant —
    /// see ``ProximityHost/proximitySupportDirectory`` for the full reasoning.
    nonisolated static func fileURL(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // There is deliberately NO argument-less `defaultFileURL(name:)` any more. Every owner states its
    // root, exactly as every heart-drop caller states FernletSocial's `HeartDropStorageScope` — a
    // default that silently resolves to the process-wide `Application Support/Fernlet` is precisely
    // how a store rejoins the shared-root race, and the omission compiles.

    /// Reads + decodes the sidecar. `nil` on ANY failure — absent, unreadable (including a
    /// locked-device read of a protected file), or undecodable.
    func load() -> State? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return state
    }

    /// What a classified ``read()`` found — the three failures ``load()`` folds into one `nil`.
    enum ReadResult {
        /// No file: nothing has been written yet, or a wipe removed it. Saving is safe.
        case absent
        /// The file decoded.
        case loaded(State)
        /// The file exists but could not be read — an I/O error, or a `.completeFileProtection` file
        /// read while the device is locked. Its contents are unknown, so a save would clobber them.
        case unreadable
        /// The bytes were read but are not this state: corruption, or a shape no build can decode.
        case undecodable
    }

    /// Reads + decodes the sidecar, saying which of absent, unreadable or undecodable a failure was.
    /// Each failure is audited (`sidecar.readFailed`, `sidecar.decodeFailed`) with the file's name and
    /// the error, never the contents.
    func read() -> ReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logFailure("sidecar.readFailed", error)
            return .unreadable
        }
        do {
            return .loaded(try JSONDecoder().decode(State.self, from: data))
        } catch {
            logFailure("sidecar.decodeFailed", error)
            return .undecodable
        }
    }

    /// Moves an undecodable sidecar aside to ``quarantineURL`` (replacing an older quarantine), so the
    /// next save starts a fresh file instead of overwriting the only copy of what was there. Audited
    /// as `sidecar.quarantined`, or `sidecar.quarantineFailed` with the error.
    ///
    /// - Returns: whether the file is out of the way. `false` means it is still at ``fileURL``, and a
    ///   caller that refuses to clobber it must keep refusing. R7: not `@discardableResult`.
    func quarantine() -> Bool {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: quarantineURL.path) {
                try manager.removeItem(at: quarantineURL)
            }
            try manager.moveItem(at: fileURL, to: quarantineURL)
        } catch {
            logFailure("sidecar.quarantineFailed", error)
            return false
        }
        if excludedFromBackup {
            BackupExclusion.apply(fileURL: quarantineURL, excluded: true)
        }
        FernletAuditLog.log("sidecar.quarantined", context: ["file": fileURL.lastPathComponent])
        return true
    }

    /// Encodes + writes the sidecar: encode, ensure the parent directory exists, then an atomic
    /// `.completeFileProtection` write. Still best-effort — the state is reconstructible
    /// convenience state and the next mutation retries the write — but every failure is NAMED in
    /// the audit log (R7) instead of vanishing, since a `.completeFileProtection` write on a
    /// locked device is the common silent case.
    func save(_ state: State) {
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            logFailure("sidecar.encodeFailed", error)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // Without the parent directory the write below cannot succeed — stop here rather than
            // reporting a second, derived failure.
            logFailure("sidecar.createDirectoryFailed", error)
            return
        }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            logFailure("sidecar.saveFailed", error)
            return
        }
        // The atomic write replaced the inode, dropping the exclusion the previous file carried.
        if excludedFromBackup {
            BackupExclusion.apply(fileURL: fileURL, excluded: true)
        }
    }

    /// Deletes the sidecar file and its ``quarantineURL`` — the `clearAll` / reset-everything path.
    /// Best-effort, but an "already gone" removal is the expected case and everything else is
    /// audit-logged (R7): a silently-failed removal would leave device-local social state on disk
    /// after a wipe.
    func removeFile() {
        remove(fileURL)
        remove(quarantineURL)
    }

    /// Removes one file, treating "already gone" as done and auditing anything else.
    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Nothing to remove — the post-condition ("no file") already holds.
        } catch {
            logFailure("sidecar.removeFailed", error)
        }
    }

    /// One audit line per sidecar failure. Carries the sidecar's file NAME (a fixed constant per
    /// store, never user content) and the error description — no path, no state.
    private func logFailure(_ event: String, _ error: Error) {
        FernletAuditLog.log(
            event,
            context: ["file": fileURL.lastPathComponent, "error": String(describing: error)]
        )
    }
}

/// One element of a sidecar's persisted array that decodes to `nil` instead of failing the whole
/// array — the per-row tolerance a persisted shape opts into (freeze/park: one row only a newer build
/// can read must not drop the file). `FriendStateCache` and `ModerationLedger` decode their rows
/// through it.
///
/// `nonisolated` (like the stores' persisted shapes) so its `Decodable` conformance is usable from the
/// nonisolated decode path.
nonisolated struct LenientSidecarRow<Element: Decodable>: Decodable {
    /// The decoded element, or nil when this one row would not decode.
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
