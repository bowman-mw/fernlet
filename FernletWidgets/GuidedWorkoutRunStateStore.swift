// GuidedWorkoutRunStateStore.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// Coordinated app-group reader/writer for the single in-progress GuidedWorkoutRunState. Mirrors the
// file-handoff convention already used by WidgetSnapshotStore / PendingWidgetActionWriter: an
// NSFileCoordinator guards each access, dates are ISO-8601, and reads are nil-tolerant (a missing /
// corrupt / still-protected file simply means "no active guided run"). Two writers exist — the app
// (in-app "Done set"/"Skip rest") and the App Intent (Lock Screen buttons) — but never concurrently:
// the app writes only while foregrounded, the intent only while the app isn't driving the UI.
//
// SELF-CONTAINED (documented app-group dup #4): the container URL is computed here from the literal
// group id rather than through WidgetBridgeFiles (widget-target only) or WidgetBridge (app-target
// only), so this one file compiles identically in both targets. Keep the id literally identical to
// `fernletAppGroupIdentifier` / SharedRecipeImportQueue.appGroupIdentifier.

import Foundation

/// Coordinated app-group reader/writer for the single in-progress ``GuidedWorkoutRunState`` JSON
/// file.
///
/// The persistence seam between the two guided-workout drivers: `FernletStore` (in-app transitions
/// and the foreground reconcile, which also logs a Lock-Screen-only finish) and
/// ``GuidedWorkoutIntentRunner`` (the Lock Screen buttons). Every access runs inside an
/// `NSFileCoordinator` block; dates are ISO-8601 with sorted keys; writes are atomic with
/// `.completeFileProtectionUntilFirstUserAuthentication`. Reads are nil-tolerant — a missing,
/// corrupt, or still-protected file reads as "no active guided run" — and every failure mode is
/// silent by design (`try?` throughout): losing one write never crashes an intent. `write(_:)`
/// re-stamps `updatedAt` so the app's reconcile can age-out an abandoned run. Self-contained
/// (literal app-group id, own codecs) so this one file compiles identically in both targets;
/// ``CookingRunStateStore`` is its byte-for-byte sibling.
struct GuidedWorkoutRunStateStore {
    /// Documented duplicate of `fernletAppGroupIdentifier` — see file header.
    private static let appGroupIdentifier = "group.MBO.Fernlet"

    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        let dir = directory ?? {
            let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return base.appendingPathComponent("FernletWidgets", isDirectory: true)
        }()
        self.fileURL = dir.appendingPathComponent("GuidedWorkoutRunState.json")
    }

    /// Sorted-keys + ISO-8601 encoder — the file-format half of the cross-process contract.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// ISO-8601 decoder matching ``makeEncoder()``.
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The active guided run, or nil when there is none (missing/corrupt/protected file).
    func read() -> GuidedWorkoutRunState? {
        var result: GuidedWorkoutRunState?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? makeDecoder().decode(GuidedWorkoutRunState.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    /// Replace the active guided run. Stamps `updatedAt` so reconcile can age-out an abandoned run.
    func write(_ state: GuidedWorkoutRunState) {
        var stamped = state
        stamped.updatedAt = Date()
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            guard let encoded = try? makeEncoder().encode(stamped) else { return }
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Clear the active guided run (finished, abandoned, or a new run replacing it).
    func clear() {
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            try? fileManager.removeItem(at: url)
        }
    }
}
