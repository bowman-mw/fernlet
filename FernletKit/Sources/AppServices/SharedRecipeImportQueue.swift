import Foundation
import os
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

    /// R3: the cap on how many queued imports the app will ever carry, applied where the external
    /// input enters (``records()`` and the read half of `modifyRecords`). The file is written by a
    /// SEPARATE process (the share extension) and can be refilled while the app is backgrounded, so
    /// without this the drain's work — one web fetch per record — is unbounded.
    ///
    /// **Twin note (byte format):** this must equal `SharedRecipeImportQueueWriter.maxQueuedRecords`
    /// in `App/FernletShareExtension/SharedRecipeImportQueueWriter.swift`, and evict the same END.
    /// The extension trims OLDEST-out so the share the user just made always survives; the app
    /// reading a different number — or keeping the opposite end — would drop rows the extension kept
    /// and drain rows the extension considered evicted. `SharedRecipeImportQueueMirrorTests` pins
    /// both halves.
    public static let maxQueuedImports = 100

    /// R2: the named retry cap a record self-destructs at, so a permanently broken page cannot
    /// retry forever. **Twin note:** the extension never writes `attemptCount`, so this constant is
    /// app-side only.
    public static let maxImportAttempts = 5

    /// This module's unified-log sink. `AppServices` deliberately declares no `FernletFoundation`
    /// edge (see `Package.swift`), so `os.Logger` — not `FernletAuditLog` — is the audit surface here.
    private static let logger = Logger(subsystem: "com.fernlet", category: "recipeImportQueue")

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

    /// The current queue contents under a coordinated read, capped at ``maxQueuedImports``
    /// (oldest-OUT, matching the share extension's trim). Missing, unreadable, or corrupt files all
    /// read as an empty queue — the drain never throws — but each of those outcomes is now named in
    /// the log rather than being indistinguishable from "nothing queued".
    public func records() -> [SharedRecipeImportRecord] {
        var result: [SharedRecipeImportRecord] = []
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
            guard fileManager.fileExists(atPath: url.path) else { return }
            guard let decoded = decodeRecords(at: url) else { return }
            // R3: cap where the input enters, oldest-out — the same end the extension trims, so the
            // two processes never disagree about which rows are still queued.
            result = Array(decoded.suffix(Self.maxQueuedImports))
        }
        if let coordinatorError {
            Self.logger.error("recipeImportQueue.coordinateReadFailed: \(coordinatorError.localizedDescription, privacy: .public)")
        }
        return result
    }

    /// Decodes the queue file at `url`, or `nil` when it is unreadable/corrupt (logged once, with
    /// the reason — a corrupt queue file is otherwise silently permanent).
    private func decodeRecords(at url: URL) -> [SharedRecipeImportRecord]? {
        do {
            return try decoder.decode([SharedRecipeImportRecord].self, from: try Data(contentsOf: url))
        } catch {
            Self.logger.error("recipeImportQueue.corrupt: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Removes a record by id — the success path after an import lands in the store.
    ///
    /// - Returns: whether the rewrite landed. Not discardable (R7): a `false` means this record is
    ///   still queued and the next drain re-imports the recipe, so the drain reports it too.
    public func remove(_ record: SharedRecipeImportRecord) -> Bool {
        let didWrite = modifyRecords { $0.removeAll { $0.id == record.id } }
        logIfRewriteFailed(didWrite, operation: "remove")
        return didWrite
    }

    /// R7: names the recovery when a queue rewrite does not land. A failed rewrite after `remove`
    /// re-imports the recipe on the next foreground (a duplicate saved recipe); after `markAttempt`
    /// it means a broken page never reaches its self-destruct. Neither is recoverable here — the
    /// next drain retries — so the recovery is a log line that makes the duplicate diagnosable.
    private func logIfRewriteFailed(_ didWrite: Bool, operation: String) {
        guard !didWrite else { return }
        Self.logger.error("recipeImportQueue.writeFailed: \(operation, privacy: .public)")
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
    ///
    /// R7: the `Bool` is NOT discardable — it is the "the file was actually emptied" signal, and a
    /// wipe that ignores it lets a recipe shared before the wipe import itself back afterwards.
    public func clear() -> Bool { save([]) }

    /// Records a failed import attempt (timestamp + error text). A record that reaches
    /// ``maxImportAttempts`` attempts is removed outright, so a permanently broken page cannot
    /// retry forever.
    ///
    /// - Returns: whether the rewrite landed (see ``remove(_:)`` — same not-discardable reasoning:
    ///   a lost attempt stamp is a broken page that never reaches its self-destruct).
    public func markAttempt(_ record: SharedRecipeImportRecord, errorDescription: String?) -> Bool {
        let didWrite = modifyRecords { records in
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[index].attemptCount += 1
            records[index].lastAttemptAt = Date()
            records[index].lastErrorDescription = errorDescription
            if records[index].attemptCount >= Self.maxImportAttempts {
                records.remove(at: index)
            }
        }
        logIfRewriteFailed(didWrite, operation: "markAttempt")
        return didWrite
    }

    /// Stamps a record as deferred-for-budget on `dayKey` (the drain hit `aiBudgetExhausted`). Unlike
    /// `markAttempt`, this does NOT burn an attempt or remove the record — a budget miss is transient and
    /// not the page's fault; it only tells the drain to stop re-fetching this page today.
    ///
    /// - Returns: whether the rewrite landed (see ``remove(_:)``); a lost stamp only costs a repeat
    ///   fetch today, but it is still reported rather than assumed.
    public func markBudgetDeferred(_ record: SharedRecipeImportRecord, dayKey: String) -> Bool {
        let didWrite = modifyRecords { records in
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[index].budgetDeferredDayKey = dayKey
        }
        logIfRewriteFailed(didWrite, operation: "markBudgetDeferred")
        return didWrite
    }

    /// Applies `transform` to the queue under one coordinated read+write, returning whether the
    /// rewrite actually landed. `false` means the mutation was NOT persisted: the coordinator
    /// refused, the file exists but is corrupt (aborted deliberately, to preserve records it cannot
    /// parse), or the write failed.
    private func modifyRecords(_ transform: (inout [SharedRecipeImportRecord]) -> Void) -> Bool {
        var didWrite = false
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges,
                               writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinatorError) { readURL, writeURL in
            var current: [SharedRecipeImportRecord] = []
            if fileManager.fileExists(atPath: readURL.path) {
                guard let decoded = decodeRecords(at: readURL) else {
                    return  // File exists but corrupt — abort mutation to preserve data.
                }
                current = Array(decoded.suffix(Self.maxQueuedImports))   // R3: cap where the input enters (oldest-out).
            }
            transform(&current)
            didWrite = writeRecords(current, to: writeURL)
        }
        if let coordinatorError {
            Self.logger.error("recipeImportQueue.coordinateWriteFailed: \(coordinatorError.localizedDescription, privacy: .public)")
            return false
        }
        return didWrite
    }

    /// Replaces the whole file with `records` under a coordinated write, ignoring current contents.
    /// Internal: production code mutates via `modifyRecords`; this backs ``clear()`` and tests.
    ///
    /// R7: the write-success `Bool` is not discardable — ``clear()``'s delete-everything contract
    /// rests on it.
    func save(_ records: [SharedRecipeImportRecord]) -> Bool {
        var success = false
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
            success = writeRecords(records, to: url)
        }
        return success && coordinatorError == nil
    }

    /// Encodes and atomically writes `records`, returning whether the write landed.
    ///
    /// R7: the result is not discardable — every caller acts on it. The failure is logged rather
    /// than asserted so it survives Release, where an `assertionFailure` compiles out and left a
    /// failed rewrite with no trace at all.
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
            Self.logger.error("recipeImportQueue.writeRecordsFailed: \(error.localizedDescription, privacy: .public)")
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
                micronutrients: importedRecipe.micronutrients,
                // The page's main-picture URL rides along so user-present paths can download it
                // later (owner decision 2026-08-09); the background drain itself never fetches it.
                imageURLString: importedRecipe.imageURL?.absoluteString
            ),
            // F5: preserve JSON-LD-parsed ordered cooking steps. Persisted per-row via the
            // `SavedRecipeRecord.payloadData` blob (STEP 0), so they survive on this path.
            steps: importedRecipe.steps
        )
    }

    /// Builds the refreshed definition for an explicit "Re-import from source" (owner decision
    /// 2026-08-09): the fresh import's content over the existing row's user-owned state.
    ///
    /// **Fresh** (from `reimported`): name, servings, ingredient lines, macros, micronutrients,
    /// steps, source URL, and the page's image URL. **Preserved** (from `existing`): the `id` —
    /// deliberate, because the sealed recipe photo is keyed by it, so reusing the id carries the
    /// photo across the refresh with no migration — plus the user's `notes` verbatim (the import
    /// summary only seeds notes on FIRST import; a refresh never overwrites what the user may
    /// have edited), `createdAt`, fork provenance, and `webImageSuppressed` (a user who deleted
    /// the web picture, or already has one, must not get a surprise re-download from a refresh).
    /// The caller passes the CURRENT saved row as `existing` — merging over a stale caller-held
    /// snapshot would revert notes edited or suppression stamped while the re-import fetch was in
    /// flight (see `FernletStore.applyReimportedRecipe`, which re-resolves the live row).
    public init(reimported: ImportedRecipe, preserving existing: RecipeDefinition, now: Date = Date()) {
        self.init(importedRecipe: reimported, now: now)
        id = existing.id
        notes = existing.notes
        createdAt = existing.createdAt
        parentRecipeID = existing.parentRecipeID
        webImport?.webImageSuppressed = existing.webImport?.webImageSuppressed
    }
}
