import Foundation

/// Limits for the deliberately small, privacy-filtered catalog the containing app publishes for
/// the Messages extension. These values are independent from file and message-envelope limits.
public nonisolated enum FernletMessagesCatalogLimits {
    public static let maxRecipes = 100
    public static let maxWorkouts = 100
    public static let maxWorkoutDays = 90
    public static let maxCatalogBytes = 1_024 * 1_024
}

/// Selection and search rules shared by the catalog reader and the Messages composer. The helper
/// operates only on the bounded catalog, so browsing can never expand access to a repository.
public nonisolated enum FernletMessagesRecipePicker {
    public static let compactRecipeLimit = 4
    public static let maxSearchCharacters = ExchangeLimits.maxCardTitleCharacters

    public static func compactEntries(
        in catalog: FernletMessagesCatalog,
        lastSelectedRecipeID: UUID?
    ) -> [FernletMessagesRecipeCatalogEntry] {
        var entries: [FernletMessagesRecipeCatalogEntry] = []
        if let lastSelectedRecipeID,
           let selected = catalog.recipes.first(where: { $0.packet.originContentID == lastSelectedRecipeID }) {
            entries.append(selected)
        }
        for entry in catalog.recipes.prefix(FernletMessagesCatalogLimits.maxRecipes) {
            guard entries.count < compactRecipeLimit,
                  entry.packet.originContentID != lastSelectedRecipeID else { continue }
            entries.append(entry)
        }
        return entries
    }

    public static func entries(
        matching query: String,
        in catalog: FernletMessagesCatalog
    ) -> [FernletMessagesRecipeCatalogEntry] {
        let normalized = String(query.prefix(maxSearchCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return catalog.recipes }
        return catalog.recipes.filter {
            $0.card.title.localizedCaseInsensitiveContains(normalized)
        }
    }
}

/// Workout selection follows the same bounded compact/search rules as recipes, without granting
/// the extension access to Fernlet's canonical planned-workout repository.
public nonisolated enum FernletMessagesWorkoutPicker {
    public static let compactWorkoutLimit = 4

    public static func compactEntries(in catalog: FernletMessagesCatalog) -> [FernletMessagesWorkoutCatalogEntry] {
        Array(catalog.workouts.prefix(compactWorkoutLimit))
    }

    public static func entries(
        matching query: String,
        in catalog: FernletMessagesCatalog
    ) -> [FernletMessagesWorkoutCatalogEntry] {
        let normalized = String(query.prefix(ExchangeLimits.maxCardTitleCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return catalog.workouts }
        return catalog.workouts.filter { $0.card.title.localizedCaseInsensitiveContains(normalized) }
    }
}

/// The versioned App Group document used only for Messages composition. It contains prebuilt
/// exchange packets and their derived picker metadata; it never gives the extension a repository.
public nonisolated struct FernletMessagesCatalog: Codable, Equatable, Sendable {
    public static let format = "fernlet.messages.catalog"
    public static let formatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var generatedAt: Date
    public var recipes: [FernletMessagesRecipeCatalogEntry]
    public var workouts: [FernletMessagesWorkoutCatalogEntry]

    public init(
        generatedAt: Date = Date(),
        recipes: [FernletMessagesRecipeCatalogEntry],
        workouts: [FernletMessagesWorkoutCatalogEntry]
    ) throws {
        format = Self.format
        formatVersion = Self.formatVersion
        // JSON's ISO-8601 strategy has second precision. Normalize at construction so a decoded
        // catalog is equal to the document that was written and its timestamp stays portable.
        self.generatedAt = Date(timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down))
        self.recipes = recipes
        self.workouts = workouts
        try validate()
    }

    public func encodedData() throws -> Data {
        try validate()
        let data = try FernletMessagesCatalogCoder.encode(self)
        guard data.count <= FernletMessagesCatalogLimits.maxCatalogBytes else {
            throw ExchangePacketError.tooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> FernletMessagesCatalog {
        guard data.count <= FernletMessagesCatalogLimits.maxCatalogBytes else {
            throw ExchangePacketError.tooLarge
        }
        let catalog = try FernletMessagesCatalogCoder.decode(FernletMessagesCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }

    private func validate() throws {
        guard format == Self.format, formatVersion == Self.formatVersion,
              recipes.count <= FernletMessagesCatalogLimits.maxRecipes,
              workouts.count <= FernletMessagesCatalogLimits.maxWorkouts else {
            throw ExchangePacketError.unsupportedFormat
        }
        try recipes.forEach { try $0.validate() }
        try workouts.forEach { try $0.validate() }
    }
}

/// A recipe the Messages extension may display and insert. Notes are always excluded in V1.
public nonisolated struct FernletMessagesRecipeCatalogEntry: Codable, Equatable, Sendable {
    public var packet: RecipeExchangePacket
    public var card: ExchangeCardMetadata

    public init(packet: RecipeExchangePacket) throws {
        self.packet = packet
        card = try ExchangeCardMetadata.recipe(from: packet)
        try validate()
    }

    fileprivate func validate() throws {
        let decoded = try RecipeExchangePacket.decode(packet.encodedData())
        let expectedCard = try ExchangeCardMetadata.recipe(from: decoded)
        guard !decoded.includesNotes, decoded.recipe.notes.isEmpty,
              card == expectedCard else {
            throw ExchangePacketError.invalidPayload
        }
    }
}

/// A one-day planned-workout packet the Messages extension may display and insert.
public nonisolated struct FernletMessagesWorkoutCatalogEntry: Codable, Equatable, Sendable {
    public var dayKey: String
    public var packet: WorkoutPlanExchangePacket
    public var card: ExchangeCardMetadata

    public init(dayKey: String, packet: WorkoutPlanExchangePacket) throws {
        self.dayKey = dayKey
        self.packet = packet
        card = try ExchangeCardMetadata.workoutPlan(from: packet, scheduledStartDayKey: dayKey)
        try validate()
    }

    fileprivate func validate() throws {
        let decoded = try WorkoutPlanExchangePacket.decode(packet.encodedData())
        let expectedCard = try ExchangeCardMetadata.workoutPlan(from: decoded, scheduledStartDayKey: dayKey)
        let legacyCard = try ExchangeCardMetadata.workoutPlan(from: decoded)
        guard dayKey.count == 10, dayKey.allSatisfy({ $0.isNumber || $0 == "-" }),
              card == expectedCard || card == legacyCard else {
            throw ExchangePacketError.invalidPayload
        }
    }
}

/// Coordinated App Group access for the Messages catalog. Production never falls back to less
/// protected storage: an unavailable group is a failure, not a reason to use Application Support.
public nonisolated struct FernletMessagesCatalogFileStore {
    public static let appGroupIdentifier = "group.MBO.Fernlet"
    private static let filename = "MessagesCatalog.json"

    private let fileManager: FileManager
    private let fileURL: URL

    public init(fileManager: FileManager = .default, directory: URL) {
        self.fileManager = fileManager
        fileURL = directory.appendingPathComponent(Self.filename)
    }

    public static func productionDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("FernletMessages", isDirectory: true)
    }

    public func read() throws -> FernletMessagesCatalog? {
        let data = try coordinatedRead()
        guard let data else { return nil }
        return try FernletMessagesCatalog.decode(data)
    }

    public func write(_ catalog: FernletMessagesCatalog) throws {
        try coordinatedWrite(catalog.encodedData())
    }

    public func clear() -> Bool {
        var succeeded = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
            do {
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
                succeeded = true
            } catch {
                succeeded = false
            }
        }
        return succeeded && coordinationError == nil
    }

    private func coordinatedRead() throws -> Data? {
        var result: Data?
        var accessError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinationError) { url in
            guard fileManager.fileExists(atPath: url.path) else { return }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard let size = attributes[.size] as? NSNumber,
                      size.intValue <= FernletMessagesCatalogLimits.maxCatalogBytes else {
                    accessError = ExchangePacketError.tooLarge
                    return
                }
                result = try Data(contentsOf: url)
            } catch {
                accessError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
        return result
    }

    private func coordinatedWrite(_ data: Data) throws {
        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { url in
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

private nonisolated enum FernletMessagesCatalogCoder {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
