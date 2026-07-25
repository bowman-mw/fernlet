import Foundation
import FernletDomainModel
import AIProviders

public struct SharedRecipeImportRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var urlString: String
    public var queuedAt: Date
    public var attemptCount: Int
    public var lastAttemptAt: Date?
    public var lastErrorDescription: String?

    public var url: URL? {
        URL(string: urlString)
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        queuedAt: Date = Date(),
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.urlString = url.absoluteString
        self.queuedAt = queuedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorDescription = lastErrorDescription
    }
}

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
