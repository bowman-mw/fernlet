// WidgetBridge.swift
// Fernlet
//
// App side of the FernletWidgets bridge (two JSON files in the group.MBO.Fernlet container):
//
//   OUT  FernletWidgets/WidgetSnapshot.json        — benign snapshot the widget renders, written by
//        `WidgetSnapshotMirror` from the SnapshotSaveCoordinator after-save hook + at store-ready,
//        followed by WidgetCenter.reloadTimelines.
//   IN   FernletWidgets/PendingWidgetActions.json  — action rows the widget's "+1 water" App Intent
//        appends; drained by `FernletStore.processPendingWidgetActions()` at the same two
//        ContentView points as the shared-recipe import queue.
//
// The widget-extension twins of these types live in FernletWidgets/WidgetSharedModels.swift as a
// DELIBERATE standalone duplication (S3 wall: the widget must not link the FernletKit umbrella,
// which carries the sealed Private* stores). Keep both sides byte-identical: iso8601 dates,
// sorted keys, same field names.
//
// PRIVACY: the snapshot carries the wellness score, water count, and macro grams ONLY — never
// journal text, cycle data, stress baselines, or intimacy data (those are sealed by design).

import Foundation
import WidgetKit

/// The benign outbound snapshot mirrored to the app-group container for the widget.
struct WidgetSnapshot: Codable, Equatable {
    struct MacroSummary: Codable, Equatable {
        var protein: Double
        var carbs: Double
        var fat: Double
    }

    var companionStateRaw: String
    var score: Double
    var bottleCount: Int
    var hydrationTarget: Int
    var macroSummary: MacroSummary
    var dateKey: String
    var computedAt: Date
}

/// One inbound action row appended by the widget's App Intent.
struct PendingWidgetAction: Codable, Identifiable, Equatable {
    static let waterPlusOne = "waterPlusOne"

    var id: UUID
    var dateKey: String
    var action: String
    var createdAt: Date
}

/// Shared file locations + codecs for both bridge files.
enum WidgetBridgeFiles {
    /// Documented duplicate of SharedRecipeImportQueue.appGroupIdentifier (and the share-extension
    /// writer's copy) — keep all literals identical.
    static let appGroupIdentifier = "group.MBO.Fernlet"

    static func containerDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FernletWidgets", isDirectory: true)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Coordinated read/write of the mirrored snapshot file. Directory is injectable for tests.
struct WidgetSnapshotFileStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = (directory ?? WidgetBridgeFiles.containerDirectory(fileManager: fileManager))
            .appendingPathComponent("WidgetSnapshot.json")
    }

    func read() -> WidgetSnapshot? {
        var result: WidgetSnapshot?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? WidgetBridgeFiles.makeDecoder().decode(WidgetSnapshot.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    @discardableResult
    func write(_ snapshot: WidgetSnapshot) -> Bool {
        var success = false
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try WidgetBridgeFiles.makeEncoder().encode(snapshot)
                // Same protection class as SharedRecipeImportQueue: readable by the Lock-Screen
                // widget after first unlock despite the app's NSFileProtectionComplete default.
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                success = true
            } catch {
                // Best-effort mirror — a failed write only means a stale widget, never data loss.
            }
        }
        return success && coordinatorError == nil
    }

    /// Removes the mirrored snapshot file. Called by "delete everything": the widget renders straight
    /// off these bytes, so without this the user's score, water count and macros keep glowing on the
    /// Home and Lock Screen after they were told the data was deleted.
    ///
    /// Deleting is not the same as republishing an empty snapshot. The republish only happens ~1s later
    /// via the debounced save, and the wipe CANCELS that save — but even without the cancel, a user who
    /// swipes the app away right after confirming (the expected behavior) would never reach it. These
    /// bytes also sit at `.completeFileProtectionUntilFirstUserAuthentication`, a weaker class than the
    /// app's own data, which is what makes leaving them behind worse than it looks.
    @discardableResult
    func delete() -> Bool {
        var success = false
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                success = true
            } catch {
                // Reported, not swallowed: a surviving snapshot file is the visible leak this exists to close.
            }
        }
        return success && coordinatorError == nil
    }
}

/// Coordinated reader/claimer of the widget's pending-action queue. `append` exists for tests and
/// documents the byte format the widget-side writer produces.
struct PendingWidgetActionQueue {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = (directory ?? WidgetBridgeFiles.containerDirectory(fileManager: fileManager))
            .appendingPathComponent("PendingWidgetActions.json")
    }

    func records() -> [PendingWidgetAction] {
        var result: [PendingWidgetAction] = []
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? WidgetBridgeFiles.makeDecoder().decode([PendingWidgetAction].self, from: data) else { return }
            result = decoded
        }
        return result
    }

    /// Idempotent by row id (a duplicate id is dropped) — mirrors the widget-side writer.
    func append(_ action: PendingWidgetAction) {
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges,
                               writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinatorError) { readURL, writeURL in
            var records: [PendingWidgetAction] = []
            if fileManager.fileExists(atPath: readURL.path),
               let data = try? Data(contentsOf: readURL),
               let decoded = try? WidgetBridgeFiles.makeDecoder().decode([PendingWidgetAction].self, from: data) {
                records = decoded
            }
            guard !records.contains(where: { $0.id == action.id }) else { return }
            records.append(action)
            write(records, to: writeURL)
        }
    }

    /// Atomically takes every queued row and clears the file in ONE coordinated read+write, so a
    /// row can never be applied twice across overlapping drains (idempotency by removal). A crash
    /// between claim and apply loses at most a bottle tap — preferred over double-logging.
    func claimAll() -> [PendingWidgetAction] {
        var claimed: [PendingWidgetAction] = []
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges,
                               writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinatorError) { readURL, writeURL in
            guard fileManager.fileExists(atPath: readURL.path) else { return }
            guard let data = try? Data(contentsOf: readURL),
                  let decoded = try? WidgetBridgeFiles.makeDecoder().decode([PendingWidgetAction].self, from: data) else {
                // Corrupt file: clear it so it can't wedge the queue forever (nothing recoverable).
                write([], to: writeURL)
                return
            }
            claimed = decoded
            write([], to: writeURL)
        }
        return claimed
    }

    /// Discards every queued row without applying it. Called by "delete everything": a widget "+1 cup"
    /// tapped before the wipe would otherwise drain on the next foreground and re-create a day record —
    /// silently rebuilding data the user just deleted, from a tap they made before deleting it.
    func clear() {
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            write([], to: url)
        }
    }

    private func write(_ records: [PendingWidgetAction], to url: URL) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try WidgetBridgeFiles.makeEncoder().encode(records)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Best-effort: an unwritable queue file degrades to "widget taps apply on next drain".
        }
    }
}

/// Publishes the mirrored snapshot + pokes WidgetKit. Wired onto `FernletStore` from ContentView at
/// store-ready (nil in unit tests unless a test injects one, keeping the suite hermetic).
@MainActor
final class WidgetSnapshotMirror {
    static let widgetKind = "FernletCompanion"

    private let fileStore: WidgetSnapshotFileStore
    private let reloadTimelines: () -> Void

    init(directory: URL? = nil, reloadTimelines: (() -> Void)? = nil) {
        self.fileStore = WidgetSnapshotFileStore(directory: directory)
        self.reloadTimelines = reloadTimelines ?? { WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind) }
    }

    func publish(_ snapshot: WidgetSnapshot) {
        guard fileStore.write(snapshot) else { return }
        reloadTimelines()
    }

    /// Removes the mirrored snapshot and reloads the timelines so the widget re-renders from nothing.
    /// The reload runs even if the delete failed — a widget showing its placeholder is a better outcome
    /// than one still showing deleted data, and the caller reports the failure either way.
    @discardableResult
    func clear() -> Bool {
        let deleted = fileStore.delete()
        reloadTimelines()
        return deleted
    }

    /// Test/inspection hook.
    func currentSnapshot() -> WidgetSnapshot? { fileStore.read() }
}
