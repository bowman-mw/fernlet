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
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([SharedRecipeImportRecord].self, from: data) else {
            return []
        }
        return records
    }

    func remove(_ record: SharedRecipeImportRecord) {
        save(records().filter { $0.id != record.id })
    }

    func markAttempt(_ record: SharedRecipeImportRecord, errorDescription: String?) {
        var updatedRecords = records()
        guard let index = updatedRecords.firstIndex(where: { $0.id == record.id }) else { return }
        updatedRecords[index].attemptCount += 1
        updatedRecords[index].lastAttemptAt = Date()
        updatedRecords[index].lastErrorDescription = errorDescription
        save(updatedRecords)
    }

    @discardableResult
    private func save(_ records: [SharedRecipeImportRecord]) -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
