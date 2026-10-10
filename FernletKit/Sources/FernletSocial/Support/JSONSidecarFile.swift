// JSONSidecarFile.swift
// FernletSocial/Support
//
// The shared best-effort JSON sidecar idiom used by FernletSocial's device-local stores: the activity
// manager, the mesh photo-wall preferences (the photo object's), the moderation ledger, the closeness
// ledger and the friend-state cache. One home for the load/save/remove plumbing those stores share;
// each store keeps its own PersistedState shape and post-decode mapping. Every store that persists
// through it is this module's, so its doors are internal: no other module persists through it.

import FernletFoundation
import Foundation

/// Best-effort JSON file persistence for a device-local sidecar in Application Support
/// (`.completeFileProtection`, never synced) — the shared plumbing behind
/// ``ProximityActivityManager``, the mesh photo-wall preferences in ``MeshSessionPhotos``, and the
/// `ModerationLedger`, `ClosenessLedger` and `FriendStateCache`.
///
/// Internal, with ``init(fileURL:)``, ``fileURL(in:name:)``, ``load()``, ``save(_:)`` and
/// ``removeFile()``: every store that persists through it is FernletSocial's. Every failure it
/// audits goes to `FernletAuditLog` under its `sidecar.*` name, whichever store it serves.
///
/// This is deliberately the *naive* idiom: no failure is recoverable here — writes and removals
/// are best-effort (they audit-log and move on) and a read failure is indistinguishable from
/// "absent". A `load()` that fails for
/// ANY reason — file absent, transient I/O error, or a `.completeFileProtection` file touched
/// while the device is locked — returns `nil`, which callers treat as "no data"; the next
/// `save(_:)` then overwrites the real file with that near-empty state (the documented clobber
/// hazard). That trade-off is acceptable only for reconstructible convenience state. Anything
/// that is data of record must load through ProximityKit's `ProtectedSidecar` instead, which
/// classifies read failures so a locked-device read can never be mistaken for "empty".
///
/// `save(_:)` preserves the stores' exact operation order — encode (bail + log on failure), create the
/// parent directory, then an atomic `.completeFileProtection` write — and, unlike
/// `ProtectedSidecar`'s writer, does NOT exclude the file from backup.
struct JSONSidecarFile<State: Codable> {
    /// The on-disk location of the sidecar. Owners resolve it with `fileURL(in:name:)` against
    /// their host's ``ProximityHost/proximitySupportDirectory``; tests inject their own.
    let fileURL: URL

    /// A sidecar at `fileURL`, which its owner always states (there is no default root).
    ///
    /// - Parameter fileURL: The sidecar's file: `fileURL(in:name:)` of the owner's sidecar root, or a
    ///   test's own file.
    init(fileURL: URL) {
        self.fileURL = fileURL
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
        }
    }

    /// Deletes the sidecar file — the `clearAll` / reset-everything path. Best-effort, but an
    /// "already gone" removal is the expected case and everything else is audit-logged (R7): a
    /// silently-failed removal would leave device-local social state on disk after a wipe.
    func removeFile() {
        do {
            try FileManager.default.removeItem(at: fileURL)
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
