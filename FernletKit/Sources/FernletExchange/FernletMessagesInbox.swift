import Foundation

/// Bounds for the Messages-to-app review handoff. The inbox is intentionally smaller than the
/// catalog and never falls back outside the App Group when protected storage is unavailable.
public nonisolated enum FernletMessagesInboxLimits {
    public static let maxRecords = 20
    public static let maxPacketBytes = 12 * 1024
    public static let maxInboxBytes = 384 * 1024
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
}

/// A validated recipe packet awaiting explicit review in Fernlet's containing app.
public nonisolated struct FernletMessagesInboxRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var packet: RecipeExchangePacket
    public var receivedAt: Date

    public init(id: UUID = UUID(), packet: RecipeExchangePacket, receivedAt: Date = Date()) throws {
        self.id = id
        self.packet = packet
        self.receivedAt = Date(timeIntervalSince1970: receivedAt.timeIntervalSince1970.rounded(.down))
        try validate()
    }

    public func isExpired(at referenceDate: Date = Date()) -> Bool {
        referenceDate.timeIntervalSince(receivedAt) > FernletMessagesInboxLimits.maximumAge
    }

    fileprivate func validate() throws {
        let decoded = try RecipeExchangePacket.decode(packet.encodedData())
        let data = try decoded.encodedData()
        guard decoded == packet else { throw ExchangePacketError.invalidPayload }
        guard data.count <= FernletMessagesInboxLimits.maxPacketBytes else { throw ExchangePacketError.tooLarge }
    }
}

/// The kind of independently validated packet waiting in Fernlet's protected Messages inbox.
public nonisolated enum FernletMessagesInboxDestination: String, Codable, Equatable, Sendable {
    case recipe
    case workoutPlan

    fileprivate var path: String {
        switch self {
        case .recipe: FernletMessagesInboxLink.recipePath
        case .workoutPlan: FernletMessagesInboxLink.workoutPlanPath
        }
    }

    fileprivate static func from(path: String) -> FernletMessagesInboxDestination? {
        switch path {
        case FernletMessagesInboxLink.recipePath: .recipe
        case FernletMessagesInboxLink.workoutPlanPath: .workoutPlan
        default: nil
        }
    }
}

/// The opaque identifier passed from the Messages extension to its containing application.
public nonisolated struct FernletMessagesInboxTarget: Equatable, Sendable {
    public var destination: FernletMessagesInboxDestination
    public var inboxID: UUID

    public init(destination: FernletMessagesInboxDestination, inboxID: UUID) {
        self.destination = destination
        self.inboxID = inboxID
    }
}

/// The app-owned URI shapes the Messages extension can ask its containing application to open.
/// Every link carries only an opaque inbox identifier, never a packet or user-visible title.
public nonisolated enum FernletMessagesInboxLink {
    public static let scheme = "fernlet"
    public static let host = "messages"
    public static let recipePath = "/recipe"
    public static let workoutPlanPath = "/workout"
    private static let maxURLBytes = 256

    public static func url(for inboxID: UUID) -> URL? {
        makeURL(destination: .recipe, inboxID: inboxID)
    }

    public static func url(for target: FernletMessagesInboxTarget) -> URL? {
        makeURL(destination: target.destination, inboxID: target.inboxID)
    }

    private static func makeURL(destination: FernletMessagesInboxDestination, inboxID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = destination.path
        components.queryItems = [URLQueryItem(name: "id", value: inboxID.uuidString)]
        return components.url
    }

    public static func inboxID(from url: URL) -> UUID? {
        guard let target = target(from: url), target.destination == .recipe else { return nil }
        return target.inboxID
    }

    public static func target(from url: URL) -> FernletMessagesInboxTarget? {
        guard url.absoluteString.utf8.count <= maxURLBytes,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1,
              let destination = FernletMessagesInboxDestination.from(path: url.path) else { return nil }
        let identifiers = items.filter { $0.name == "id" }
        guard identifiers.count == 1, let value = identifiers[0].value else { return nil }
        guard let inboxID = UUID(uuidString: value) else { return nil }
        return FernletMessagesInboxTarget(destination: destination, inboxID: inboxID)
    }
}

/// Coordinated App Group storage for reviewable Messages recipes. App and extension both use this
/// portable type; neither gets a repository handle from it.
public nonisolated struct FernletMessagesInboxStore {
    public static let appGroupIdentifier = FernletMessagesCatalogFileStore.appGroupIdentifier
    private static let filename = "MessagesRecipeInbox.json"

    private let fileManager: FileManager
    private let fileURL: URL

    public init(fileManager: FileManager = .default, directory: URL) {
        self.fileManager = fileManager
        fileURL = directory.appendingPathComponent(Self.filename)
    }

    public static func productionDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("FernletMessages", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    public func enqueue(_ packet: RecipeExchangePacket, receivedAt: Date = Date()) throws -> FernletMessagesInboxRecord {
        let record = try FernletMessagesInboxRecord(packet: packet, receivedAt: receivedAt)
        return try coordinatedMutation { inbox in
            inbox.records.removeAll { $0.isExpired(at: receivedAt) }
            guard inbox.records.count < FernletMessagesInboxLimits.maxRecords else {
                throw ExchangePacketError.tooLarge
            }
            inbox.records.append(record)
            return record
        }
    }

    public func record(id: UUID, at referenceDate: Date = Date()) throws -> FernletMessagesInboxRecord? {
        let inbox = try coordinatedRead()
        guard let record = inbox.records.first(where: { $0.id == id }) else { return nil }
        guard !record.isExpired(at: referenceDate) else {
            guard remove(id) else { return nil }
            return nil
        }
        return record
    }

    public func remove(_ id: UUID) -> Bool {
        do {
            return try coordinatedMutation { inbox in
                let oldCount = inbox.records.count
                inbox.records.removeAll { $0.id == id }
                return inbox.records.count < oldCount
            }
        } catch {
            return false
        }
    }

    /// Runs at app launch as well as before enqueueing, so an untouched review request cannot
    /// outlive its explicit retention window merely because its original deep link was never used.
    public func purgeExpired(at referenceDate: Date = Date()) -> Bool {
        do {
            return try coordinatedMutation { inbox in
                inbox.records.removeAll { $0.isExpired(at: referenceDate) }
                return true
            }
        } catch {
            return false
        }
    }

    public func clear() -> Bool {
        do {
            return try coordinatedMutation { inbox in
                inbox.records = []
                return true
            }
        } catch {
            return false
        }
    }

    private func coordinatedRead() throws -> FernletMessagesInboxDocument {
        var result = FernletMessagesInboxDocument()
        var accessError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinationError) { url in
            do {
                result = try readDocument(at: url)
            } catch {
                accessError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
        return result
    }

    private func coordinatedMutation<T>(
        _ mutation: @escaping (inout FernletMessagesInboxDocument) throws -> T
    ) throws -> T {
        var result: T?
        var accessError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { url in
            do {
                var inbox = try readDocument(at: url)
                result = try mutation(&inbox)
                try writeDocument(inbox, to: url)
            } catch {
                accessError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
        guard let result else { throw ExchangePacketError.invalidPayload }
        return result
    }

    private func readDocument(at url: URL) throws -> FernletMessagesInboxDocument {
        guard fileManager.fileExists(atPath: url.path) else { return FernletMessagesInboxDocument() }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue >= 0, size.intValue <= FernletMessagesInboxLimits.maxInboxBytes else {
            throw ExchangePacketError.tooLarge
        }
        let inbox = try FernletMessagesInboxCoder.decode(FernletMessagesInboxDocument.self, from: Data(contentsOf: url))
        try inbox.validate()
        return inbox
    }

    private func writeDocument(_ inbox: FernletMessagesInboxDocument, to url: URL) throws {
        try inbox.validate()
        let data = try FernletMessagesInboxCoder.encode(inbox)
        guard data.count <= FernletMessagesInboxLimits.maxInboxBytes else { throw ExchangePacketError.tooLarge }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

private nonisolated struct FernletMessagesInboxDocument: Codable {
    static let format = "fernlet.messages.recipe-inbox"
    static let formatVersion = 1

    var format = Self.format
    var formatVersion = Self.formatVersion
    var records: [FernletMessagesInboxRecord] = []

    func validate() throws {
        guard format == Self.format, formatVersion == Self.formatVersion,
              records.count <= FernletMessagesInboxLimits.maxRecords else {
            throw ExchangePacketError.unsupportedFormat
        }
        let identifiers = Set(records.map(\.id))
        guard identifiers.count == records.count else { throw ExchangePacketError.invalidPayload }
        try records.forEach { try $0.validate() }
    }
}

private nonisolated enum FernletMessagesInboxCoder {
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
