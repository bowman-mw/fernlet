import Foundation

/// A validated workout-plan packet awaiting Fernlet's foreground collision and safety review.
/// The sender's date remains a suggestion: the containing app always derives a fresh preview.
public nonisolated struct FernletMessagesWorkoutInboxRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var packet: WorkoutPlanExchangePacket
    public var suggestedStartDayKey: String?
    public var receivedAt: Date

    public init(
        id: UUID = UUID(),
        packet: WorkoutPlanExchangePacket,
        suggestedStartDayKey: String?,
        receivedAt: Date = Date()
    ) throws {
        self.id = id
        self.packet = packet
        self.suggestedStartDayKey = suggestedStartDayKey
        self.receivedAt = Date(timeIntervalSince1970: receivedAt.timeIntervalSince1970.rounded(.down))
        try validate()
    }

    public func isExpired(at referenceDate: Date = Date()) -> Bool {
        referenceDate.timeIntervalSince(receivedAt) > FernletMessagesInboxLimits.maximumAge
    }

    fileprivate func validate() throws {
        let data = try packet.encodedData()
        guard data.count <= FernletMessagesInboxLimits.maxPacketBytes else { throw ExchangePacketError.tooLarge }
        let card = try ExchangeCardMetadata.workoutPlan(from: packet, scheduledStartDayKey: suggestedStartDayKey)
        guard card.kind == .workoutPlan else { throw ExchangePacketError.invalidPayload }
    }
}

/// Coordinated App Group storage for Messages workout plans. This owns transport-only records and
/// intentionally never opens a repository or the containing app's persistence stack.
public nonisolated struct FernletMessagesWorkoutInboxStore {
    public static let appGroupIdentifier = FernletMessagesCatalogFileStore.appGroupIdentifier
    private static let filename = "MessagesWorkoutInbox.json"

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

    public func enqueue(
        _ packet: WorkoutPlanExchangePacket,
        suggestedStartDayKey: String?,
        receivedAt: Date = Date()
    ) throws -> FernletMessagesWorkoutInboxRecord {
        let record = try FernletMessagesWorkoutInboxRecord(
            packet: packet, suggestedStartDayKey: suggestedStartDayKey, receivedAt: receivedAt
        )
        return try coordinatedMutation { inbox in
            inbox.records.removeAll { $0.isExpired(at: receivedAt) }
            guard inbox.records.count < FernletMessagesInboxLimits.maxRecords else {
                throw ExchangePacketError.tooLarge
            }
            inbox.records.append(record)
            return record
        }
    }

    public func record(id: UUID, at referenceDate: Date = Date()) throws -> FernletMessagesWorkoutInboxRecord? {
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

    /// Used by Fernlet's delete-everything funnel. An empty protected document is written instead
    /// of leaving a removable file race with the Messages extension.
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

    private func coordinatedRead() throws -> FernletMessagesWorkoutInboxDocument {
        var result = FernletMessagesWorkoutInboxDocument()
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
        _ mutation: @escaping (inout FernletMessagesWorkoutInboxDocument) throws -> T
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

    private func readDocument(at url: URL) throws -> FernletMessagesWorkoutInboxDocument {
        guard fileManager.fileExists(atPath: url.path) else { return FernletMessagesWorkoutInboxDocument() }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue >= 0, size.intValue <= FernletMessagesInboxLimits.maxInboxBytes else {
            throw ExchangePacketError.tooLarge
        }
        let data = try Data(contentsOf: url)
        let inbox = try FernletMessagesWorkoutInboxCoder.decode(FernletMessagesWorkoutInboxDocument.self, from: data)
        try inbox.validate()
        return inbox
    }

    private func writeDocument(_ inbox: FernletMessagesWorkoutInboxDocument, to url: URL) throws {
        try inbox.validate()
        let data = try FernletMessagesWorkoutInboxCoder.encode(inbox)
        guard data.count <= FernletMessagesInboxLimits.maxInboxBytes else { throw ExchangePacketError.tooLarge }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

private nonisolated struct FernletMessagesWorkoutInboxDocument: Codable {
    static let format = "fernlet.messages.workout-inbox"
    static let formatVersion = 1

    var format = Self.format
    var formatVersion = Self.formatVersion
    var records: [FernletMessagesWorkoutInboxRecord] = []

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

private nonisolated enum FernletMessagesWorkoutInboxCoder {
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
