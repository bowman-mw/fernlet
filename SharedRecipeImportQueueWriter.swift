import Foundation

struct SharedRecipeImportRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var urlString: String
    var queuedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastErrorDescription: String?

    init(url: URL) {
        self.id = UUID()
        self.urlString = url.absoluteString
        self.queuedAt = Date()
        self.attemptCount = 0
    }
}

struct SharedRecipeImportQueueWriter {
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

    func enqueue(_ url: URL) throws {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw QueueWriterError.invalidURL
        }

        var records = existingRecords()
        let urlString = url.absoluteString
        records.removeAll { $0.urlString == urlString }
        records.append(SharedRecipeImportRecord(url: url))
        try save(records)
    }

    private func existingRecords() -> [SharedRecipeImportRecord] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([SharedRecipeImportRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func save(_ records: [SharedRecipeImportRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
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

private enum QueueWriterError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Fernlet can only import web recipe URLs."
    }
}
