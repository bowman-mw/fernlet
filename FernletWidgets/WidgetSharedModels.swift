// WidgetSharedModels.swift
// FernletWidgets
//
// DELIBERATE DUPLICATION (S3 wall): the widget extension is STANDALONE — it must NOT link the
// FernletKit umbrella product, because that single product also carries the sealed Private* stores,
// AIProviders, and CloudKitSync (an S3-wall regression vector and a WidgetKit memory hazard). The
// FernletShareExtension set this precedent (see SharedRecipeImportQueueWriter.swift). The handful of
// types below therefore mirror their app-side twins byte-for-byte:
//
//   - `fernletAppGroupIdentifier`  mirrors SharedRecipeImportQueue.appGroupIdentifier /
//                                  SharedRecipeImportQueueWriter.appGroupIdentifier (documented dup #3)
//   - `WidgetCompanionState`       mirrors CompanionState raw values (FernletDomainModel/CompanionModels.swift)
//   - `WidgetSnapshot`             mirrors Fernlet/WidgetBridge.swift `WidgetSnapshot`
//   - `PendingWidgetAction`        mirrors Fernlet/WidgetBridge.swift `PendingWidgetAction`
//   - `WidgetDayKey`               mirrors FernletFoundation.FernletDate.dayKey ("yyyy-MM-dd", en_US_POSIX)
//   - JSON codecs                  mirror the app-group queue convention (iso8601 dates, sorted keys)
//
// Keep the values literally identical when touching either side — the shared JSON files in the
// `group.MBO.Fernlet` container are the only contract between the two processes.

import Foundation

let fernletAppGroupIdentifier = "group.MBO.Fernlet"

/// Raw-value mirror of the app's `CompanionState`. Raw values are the persisted contract
/// ("Thriving"/"Okay"/"Tired"/"Resting"/"Sick" — note the capitalization).
enum WidgetCompanionState: String {
    case thriving = "Thriving"
    case okay = "Okay"
    case tired = "Tired"
    case resting = "Resting"
    case sick = "Sick"
}

/// The benign outbound snapshot the app mirrors into the app-group container.
/// PRIVACY: wellness score + water + macro grams ONLY — never journal, cycle, stress, or intimacy data.
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

    var companionState: WidgetCompanionState? { WidgetCompanionState(rawValue: companionStateRaw) }

    /// Gallery/placeholder preview content (never rendered from real data).
    static let placeholder = WidgetSnapshot(
        companionStateRaw: WidgetCompanionState.okay.rawValue,
        score: 0.6,
        bottleCount: 2,
        hydrationTarget: 4,
        macroSummary: MacroSummary(protein: 42, carbs: 118, fat: 31),
        dateKey: WidgetDayKey.current(),
        computedAt: Date()
    )
}

/// One inbound action row the widget appends for the app to drain (mirrors SharedRecipeImportQueue's
/// file-based handoff; the app applies it idempotently by row id against the row's OWN dateKey).
struct PendingWidgetAction: Codable, Identifiable, Equatable {
    static let waterPlusOne = "waterPlusOne"

    var id: UUID
    var dateKey: String
    var action: String
    var createdAt: Date
}

/// Canonical "yyyy-MM-dd" day key — duplicate of FernletFoundation.FernletDate.dayKey.
enum WidgetDayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func current(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

/// Pure day-gate shared by the companion entry's water + mood accessors. A mirrored snapshot only
/// "counts" for a given timeline entry when its `dateKey` names the same local day as the entry's
/// date; a stale (previous-day) snapshot therefore reads as a fresh, empty day — zero water and the
/// neutral companion — until the app republishes. Kept as a free static function (no WidgetKit /
/// TimelineEntry types) so the gate is checkable in isolation and reused verbatim by every family.
enum WidgetDayGate {
    static func snapshotReflectsDay(_ dateKey: String, at entryDate: Date) -> Bool {
        dateKey == WidgetDayKey.current(entryDate)
    }
}

enum WidgetBridgeFiles {
    static func containerDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: fernletAppGroupIdentifier)
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

/// Widget-side reader (+ optimistic writer) for the mirrored snapshot. Reads are nil-tolerant: a
/// missing/corrupt/still-protected file simply yields the "open Fernlet" placeholder state.
struct WidgetSnapshotStore {
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

    /// Optimistic +1-water bump so the widget updates instantly after the intent fires; the app is
    /// the source of truth and republishes the real snapshot on its next save/foreground.
    func applyOptimisticWaterPlusOne(dayKey: String) {
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges,
                               writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinatorError) { readURL, writeURL in
            guard fileManager.fileExists(atPath: readURL.path),
                  let data = try? Data(contentsOf: readURL),
                  var snapshot = try? WidgetBridgeFiles.makeDecoder().decode(WidgetSnapshot.self, from: data) else { return }
            if snapshot.dateKey == dayKey {
                snapshot.bottleCount = min(snapshot.bottleCount + 1, 30)
            } else {
                // Day rolled over since the app last published: show the fresh day's first bottle.
                // (Score/macros briefly show yesterday's values — the app corrects on next open.)
                snapshot.dateKey = dayKey
                snapshot.bottleCount = 1
            }
            snapshot.computedAt = Date()
            guard let encoded = try? WidgetBridgeFiles.makeEncoder().encode(snapshot) else { return }
            try? encoded.write(to: writeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

/// Widget-side appender for the pending-action queue (mirrors SharedRecipeImportQueueWriter's
/// coordinated read-modify-write; idempotent by row id).
struct PendingWidgetActionWriter {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = (directory ?? WidgetBridgeFiles.containerDirectory(fileManager: fileManager))
            .appendingPathComponent("PendingWidgetActions.json")
    }

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
            guard let encoded = try? WidgetBridgeFiles.makeEncoder().encode(records) else { return }
            try? fileManager.createDirectory(at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: writeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
