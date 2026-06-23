import Foundation

struct SharedRecipeImportRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var urlString: String
    var queuedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastErrorDescription: String?

    var url: URL? {
        URL(string: urlString)
    }

    init(
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

struct SharedRecipeImportQueue {
    static let appGroupIdentifier = "group.MBO.Fernlet"

    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    func records() -> [SharedRecipeImportRecord] {
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

    func remove(_ record: SharedRecipeImportRecord) {
        modifyRecords { $0.removeAll { $0.id == record.id } }
    }

    func markAttempt(_ record: SharedRecipeImportRecord, errorDescription: String?) {
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

extension SavedRecipe {
    init(importedRecipe: ImportedRecipe) {
        self.init(
            sourceURL: importedRecipe.sourceURL,
            name: importedRecipe.name,
            ingredients: importedRecipe.ingredients,
            summary: importedRecipe.summary,
            servings: importedRecipe.servings,
            protein: importedRecipe.protein,
            carbs: importedRecipe.carbs,
            fat: importedRecipe.fat,
            micronutrients: importedRecipe.micronutrients
        )
    }
}
