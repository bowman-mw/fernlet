// AppGroupRunStateStore.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The single coordinated app-group reader/writer behind both Live Activity run-state files
// (CookingRunState.json and GuidedWorkoutRunState.json), generic over the state type. Mirrors the
// file-handoff convention already used by WidgetSnapshotStore / PendingWidgetActionWriter: an
// NSFileCoordinator guards each access, dates are ISO-8601, and reads are nil-tolerant (a missing /
// corrupt / still-protected file simply means "no active run"). Each concrete run state has two
// writers — the app (in-app controls and the foreground reconcile) and its App Intent (Lock Screen
// buttons, Siri) — but never concurrently: the app writes only while foregrounded, the intent only
// while the app isn't driving the UI.
//
// SELF-CONTAINED (documented app-group dup): the container URL is computed here from the literal
// group id rather than through WidgetBridgeFiles (widget-target only) or WidgetBridge (app-target
// only), so this one file compiles identically in both targets. Keep the id literally identical to
// `fernletAppGroupIdentifier` / SharedRecipeImportQueue.appGroupIdentifier.

import Foundation
import os

/// Subsystem log for the app-group run-state files: every persistence failure is named here rather
/// than swallowed (R7). A `let` at file scope, shared by both concrete stores.
private let runStateLog = Logger(subsystem: "com.fernlet", category: "widget-runstate")

/// A run-state value that ``AppGroupRunStateStore`` can persist to its app-group JSON file.
///
/// Requirements are the two seams the store touches: `updatedAt` is re-stamped on every
/// ``AppGroupRunStateStore/write(_:)`` so the app's foreground reconcile can age-out an abandoned
/// run, and ``runStateFileName`` names the state's JSON file inside the shared `FernletWidgets/`
/// app-group directory.
protocol AppGroupRunStatePersistable: Codable {
    /// Last-write timestamp, re-stamped by ``AppGroupRunStateStore/write(_:)`` on every save.
    var updatedAt: Date { get set }
    /// File name of this state's JSON file inside the shared app-group directory
    /// (e.g. `CookingRunState.json`).
    static var runStateFileName: String { get }
}

/// Coordinated app-group reader/writer for a single in-progress run-state JSON file.
///
/// The persistence seam between a run's two drivers: `FernletStore` (in-app transitions and the
/// foreground reconcile) and the corresponding `LiveActivityIntent` runner (Lock Screen buttons,
/// Siri). Every access runs inside an `NSFileCoordinator` block; dates are ISO-8601 with sorted
/// keys; writes are atomic with `.completeFileProtectionUntilFirstUserAuthentication`. Reads are
/// nil-tolerant — a missing, corrupt, or still-protected file reads as "no active run" — and no
/// failure mode is fatal: losing one write never crashes an intent, it is logged (``log``) and the
/// caller carries on. ``write(_:)`` re-stamps `updatedAt` so the app's reconcile can age-out an
/// abandoned run.
/// Self-contained (literal app-group id, own codecs) so this one file compiles identically in both
/// targets. The two concrete stores are ``CookingRunStateStore`` and ``GuidedWorkoutRunStateStore``.
struct AppGroupRunStateStore<State: AppGroupRunStatePersistable> {
    /// Documented duplicate of `fernletAppGroupIdentifier` — see file header.
    /// (Computed, not stored: generic types cannot carry static stored properties.)
    private static var appGroupIdentifier: String { "group.MBO.Fernlet" }

    /// Where every run-state persistence failure is named (R7: no silent `try?`).
    /// (Computed over the file-scope constant: generic types cannot carry static stored properties.)
    private static var log: Logger { runStateLog }

    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        let dir = directory ?? {
            let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return base.appendingPathComponent("FernletWidgets", isDirectory: true)
        }()
        self.fileURL = dir.appendingPathComponent(State.runStateFileName)
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

    /// The active run, or nil when there is none (missing/corrupt/protected file).
    func read() -> State? {
        var result: State?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? makeDecoder().decode(State.self, from: data) else { return }
            result = decoded
        }
        // Coordination failure means the block never ran: report it rather than let "no coordination"
        // masquerade as "no active run".
        if let coordinatorError {
            Self.logCoordinationFailure("read", coordinatorError)
        }
        return result
    }

    /// Replace the active run. Stamps `updatedAt` so reconcile can age-out an abandoned run.
    ///
    /// A failed write is not fatal — the caller's next transition rewrites the file and the app's
    /// foreground reconcile re-reads it — but it is never silent: encode / directory / write / file
    /// coordination failures are all logged with the file they were for.
    func write(_ state: State) {
        var stamped = state
        stamped.updatedAt = Date()
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                let encoded = try makeEncoder().encode(stamped)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // Recovery: leave the previous file in place — a stale run is recoverable, a torn one is not.
                Self.log.error("""
                    run-state write failed for \(State.runStateFileName, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        if let coordinatorError {
            Self.logCoordinationFailure("write", coordinatorError)
        }
    }

    /// Clear the active run (finished, abandoned/discarded, or a new run replacing it).
    ///
    /// An already-absent file is the desired end state, not a failure; anything else is logged so a
    /// finished run that survives on disk (and gets re-adopted by the next reconcile) leaves a trace.
    func clear() {
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — exactly what clear() is for.
            } catch {
                Self.log.error("""
                    run-state clear failed for \(State.runStateFileName, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        if let coordinatorError {
            Self.logCoordinationFailure("clear", coordinatorError)
        }
    }

    /// Names an `NSFileCoordinator` failure: coordination never ran the block, so nothing happened.
    private static func logCoordinationFailure(_ operation: String, _ error: NSError) {
        log.error("""
            run-state \(operation, privacy: .public) coordination failed for \
            \(State.runStateFileName, privacy: .public): \(error.localizedDescription, privacy: .public)
            """)
    }
}

extension CookingRunState: AppGroupRunStatePersistable {
    /// The cooking run's app-group JSON file, under the shared `FernletWidgets/` directory.
    static let runStateFileName = "CookingRunState.json"
}

extension GuidedWorkoutRunState: AppGroupRunStatePersistable {
    /// The guided run's app-group JSON file, under the shared `FernletWidgets/` directory.
    static let runStateFileName = "GuidedWorkoutRunState.json"
}
