import Foundation
import FernletDomainModel
import AIProviders

/// One queued recipe-URL import: the shared URL plus its retry bookkeeping (attempt count, last
/// error, budget-deferral day).
///
/// Written to the App-Group JSON file by the `FernletShareExtension` (which only ever sets `id`,
/// `urlString`, and `queuedAt`) and mutated by the app-side drain through ``SharedRecipeImportQueue``.
/// All optional fields must stay optional so extension-written records keep decoding.
///
/// **DELIBERATE TWIN — keep in sync with `SharedRecipeImportRecord` in
/// `FernletShareExtension/SharedRecipeImportQueueWriter.swift`.** The share extension links NO
/// FernletKit products (that is what keeps a share-sheet launch cheap), so it cannot import this
/// type and hand-copies it instead. The copy is not a read-only view of the schema: every enqueue
/// decodes the whole queue file and rewrites it with the extension's type, so a field declared HERE
/// and missing THERE is silently stripped from every already-queued record on the next share.
/// `budgetDeferredDayKey` was exactly that bug — one share wiped the deferral stamps and the drain
/// re-fetched budget-deferred pages the same day.
///
/// - Important: Add any new field to BOTH definitions in the same commit.
///   `FernletTests/SharedRecipeImportQueueMirrorTests` reads both source files and fails on drift.
public struct SharedRecipeImportRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var urlString: String
    public var queuedAt: Date
    public var attemptCount: Int
    public var lastAttemptAt: Date?
    public var lastErrorDescription: String?
    /// The day-key on which this record last hit the daily AI budget (`aiBudgetExhausted`). The ambient
    /// drain skips a record stamped with TODAY's key so a resting device stops re-fetching the page's HTML
    /// on every foreground for a lookup it already knows the budget can't serve until midnight. A new day
    /// (or a JSON-LD page, which imports with no gate and is never stamped) retries normally. Optional so
    /// a record written by the share extension (which never sets it) decodes to nil. `nil` = never deferred.
    public var budgetDeferredDayKey: String?

    public var url: URL? {
        URL(string: urlString)
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        queuedAt: Date = Date(),
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastErrorDescription: String? = nil,
        budgetDeferredDayKey: String? = nil
    ) {
        self.id = id
        self.urlString = url.absoluteString
        self.queuedAt = queuedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorDescription = lastErrorDescription
        self.budgetDeferredDayKey = budgetDeferredDayKey
    }
}

/// The App-Group file queue that carries recipe URLs from the share extension into the app.
///
/// Persistence is a single JSON array of ``SharedRecipeImportRecord`` at
/// `SharedRecipeImports/PendingRecipeURLs.json` inside the `group.MBO.Fernlet` container (falling
/// back to Application Support, then tmp, when the group container is unavailable — e.g. unit
/// tests). Every read and write goes through `NSFileCoordinator`, because two processes touch the
/// file: `ShareViewController` appends via its own writer while the app may be draining. Writes are
/// atomic with `completeFileProtectionUntilFirstUserAuthentication` (ISO-8601 dates, sorted keys).
///
/// The app-side consumer is `FernletStore.processSharedRecipeImportQueue()`, run on launch and on
/// each foreground from `ContentView`; it imports each URL, then calls ``remove(_:)`` on success,
/// ``markAttempt(_:errorDescription:)`` on failure (records self-destruct after 5 attempts), or
/// ``markBudgetDeferred(_:dayKey:)`` when the daily AI budget is exhausted. ``clear()`` is the
/// "delete everything" hook and deliberately bypasses the corrupt-file-preserving `modifyRecords`
/// path so a wipe always empties the file. The struct itself is stateless (a file URL + JSON
/// coders), so instances are cheap and interchangeable; edits are last-writer-wins per coordinated
/// write, and a corrupt file silently aborts mutations (but not ``clear()``) to avoid destroying
/// records it cannot parse.
///
/// **DELIBERATE TWIN — keep in sync with `SharedRecipeImportQueueWriter` in
/// `FernletShareExtension/SharedRecipeImportQueueWriter.swift`.** That type is the write half of
/// the same file protocol, hand-copied because the extension links no FernletKit products. Four
/// things must match on both sides or the hand-off breaks silently rather than loudly: the file
/// path, the container fallback chain (App Group → Application Support → tmp — diverge and the two
/// processes end up on different files), the JSON coder configuration, and the `NSFileCoordinator`
/// coordination (without it a share racing a drain is last-writer-wins). The one intentional
/// difference is the corrupt-file policy: this side aborts a mutation to preserve records it cannot
/// parse; the extension replaces the file rather than failing the user's share.
public struct SharedRecipeImportQueue {
    static let appGroupIdentifier = "group.MBO.Fernlet"

    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    /// The current queue contents under a coordinated read. Missing, unreadable, or corrupt files
    /// all read as an empty queue — the drain never throws.
    public func records() -> [SharedRecipeImportRecord] {
        var result: [SharedRecipeImportRecord] = []
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode([SharedRecipeImportRecord].self, from: data) else { return }
            result = decoded
        }
        return result
    }

    /// Removes a record by id — the success path after an import lands in the store.
    public func remove(_ record: SharedRecipeImportRecord) {
        modifyRecords { $0.removeAll { $0.id == record.id } }
    }

    /// Discards every queued import without running it. Called by "delete everything".
    ///
    /// The queue is drained on the next foreground (and on launch), so a recipe shared into Fernlet
    /// before a wipe would otherwise import itself back into the just-emptied store — carrying its name,
    /// servings, ingredients and source URL. The share extension can also refill this file while the app
    /// is backgrounded, which is why the drain has to find it empty rather than the app remembering not
    /// to drain.
    ///
    /// Deliberately does NOT go through `modifyRecords`: that helper aborts on a corrupt file to avoid
    /// destroying records it cannot parse, which is right for an edit and exactly wrong for a wipe. Here
    /// an unreadable file must still be cleared — unparseable is not the same as absent, and the drain
    /// would keep retrying it.
    @discardableResult
    public func clear() -> Bool { save([]) }

    /// Records a failed import attempt (timestamp + error text). A record that reaches 5 attempts
    /// is removed outright, so a permanently broken page cannot retry forever.
    public func markAttempt(_ record: SharedRecipeImportRecord, errorDescription: String?) {
        modifyRecords { records in
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[index].attemptCount += 1
            records[index].lastAttemptAt = Date()
            records[index].lastErrorDescription = errorDescription
            if records[index].attemptCount >= 5 {
                records.remove(at: index)
            }
        }
    }

    /// Stamps a record as deferred-for-budget on `dayKey` (the drain hit `aiBudgetExhausted`). Unlike
    /// `markAttempt`, this does NOT burn an attempt or remove the record — a budget miss is transient and
    /// not the page's fault; it only tells the drain to stop re-fetching this page today.
    public func markBudgetDeferred(_ record: SharedRecipeImportRecord, dayKey: String) {
        modifyRecords { records in
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[index].budgetDeferredDayKey = dayKey
        }
    }

    private func modifyRecords(_ transform: (inout [SharedRecipeImportRecord]) -> Void) {
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges,
                               writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinatorError) { readURL, writeURL in
            var current: [SharedRecipeImportRecord] = []
            if fileManager.fileExists(atPath: readURL.path) {
                guard let data = try? Data(contentsOf: readURL),
                      let decoded = try? decoder.decode([SharedRecipeImportRecord].self, from: data) else {
                    return  // File exists but corrupt — abort mutation to preserve data.
                }
                current = decoded
            }
            transform(&current)
            writeRecords(current, to: writeURL)
        }
    }

    /// Replaces the whole file with `records` under a coordinated write, ignoring current contents.
    /// Internal: production code mutates via `modifyRecords`; this backs ``clear()`` and tests.
    @discardableResult
    func save(_ records: [SharedRecipeImportRecord]) -> Bool {
        var success = false
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            success = writeRecords(records, to: url)
        }
        return success && coordinatorError == nil
    }

    @discardableResult
    private func writeRecords(_ records: [SharedRecipeImportRecord], to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(records)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            assertionFailure("shared recipe import queue write failed")
            return false
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory
            .appendingPathComponent("SharedRecipeImports", isDirectory: true)
            .appendingPathComponent("PendingRecipeURLs.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension RecipeDefinition {
    /// Builds the canonical recipe model from a freshly web-imported recipe. The free-text
    /// ingredient lines and precomputed nutrition are preserved verbatim under `webImport`; the
    /// structured `ingredients` array stays empty (web imports aren't resolved to food items).
    public init(importedRecipe: ImportedRecipe, now: Date = Date()) {
        self.init(
            name: importedRecipe.name,
            servings: max(importedRecipe.servings, 1),
            ingredients: [],
            notes: importedRecipe.summary,
            source: MealLogSource.webImport,
            createdAt: now,
            updatedAt: now,
            webImport: RecipeWebImport(
                sourceURLString: importedRecipe.sourceURL.absoluteString,
                ingredientLines: importedRecipe.ingredients,
                macros: Macros(
                    protein: max(importedRecipe.protein, 0),
                    carbs: max(importedRecipe.carbs, 0),
                    fat: max(importedRecipe.fat, 0)
                ),
                micronutrients: importedRecipe.micronutrients
            ),
            // F5: preserve JSON-LD-parsed ordered cooking steps. Persisted per-row via the
            // `SavedRecipeRecord.payloadData` blob (STEP 0), so they survive on this path.
            steps: importedRecipe.steps
        )
    }
}
