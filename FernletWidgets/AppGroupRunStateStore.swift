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
/// nil-tolerant — a missing, corrupt, or still-protected file reads as "no active run" — and every
/// failure mode is silent by design (`try?` throughout): losing one write never crashes an intent.
/// ``write(_:)`` re-stamps `updatedAt` so the app's reconcile can age-out an abandoned run.
/// Self-contained (literal app-group id, own codecs) so this one file compiles identically in both
/// targets. The two concrete stores are ``CookingRunStateStore`` and ``GuidedWorkoutRunStateStore``.
struct AppGroupRunStateStore<State: AppGroupRunStatePersistable> {
    /// Documented duplicate of `fernletAppGroupIdentifier` — see file header.
    /// (Computed, not stored: generic types cannot carry static stored properties.)
    private static var appGroupIdentifier: String { "group.MBO.Fernlet" }

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
        return result
    }

    /// Replace the active run. Stamps `updatedAt` so reconcile can age-out an abandoned run.
    func write(_ state: State) {
        var stamped = state
        stamped.updatedAt = Date()
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            guard let encoded = try? makeEncoder().encode(stamped) else { return }
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Clear the active run (finished, abandoned/discarded, or a new run replacing it).
    func clear() {
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
            try? fileManager.removeItem(at: url)
        }
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
