import Foundation

/// A bounded, local-only replay ledger for file-based exchange imports.
///
/// The file uses complete data protection and is cleared by Fernlet's normal reset/delete funnel.
/// It is intentionally metadata-only: packet identifiers and result identifiers never carry recipe
/// notes, journal text, or a file payload.
@MainActor
final class ExchangeImportLedger {
    static let shared = ExchangeImportLedger()
    static let maxEntries = 200

    private let fileManager: FileManager
    private let fileURL: URL?

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultURL(fileManager: fileManager)
    }

    func result(for packetID: UUID, hash: String) throws -> ExchangeImportLedgerEntry? {
        try readEntries().first { $0.packetID == packetID && $0.hash == hash }
    }

    func record(packetID: UUID, hash: String, resultID: String, kind: ExchangeImportLedgerKind) throws {
        guard hash.count == 64, !resultID.isEmpty else { throw ExchangeIntentServiceError.invalidPacket }
        var entries = try readEntries()
        entries.removeAll { $0.packetID == packetID && $0.hash == hash }
        entries.insert(ExchangeImportLedgerEntry(packetID: packetID, hash: hash, resultID: resultID,
                                                 kind: kind, importedAt: Date()), at: 0)
        try write(Array(entries.prefix(Self.maxEntries)))
    }

    func reset() throws {
        guard let fileURL else { throw ExchangeIntentServiceError.storeUnavailable }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func readEntries() throws -> [ExchangeImportLedgerEntry] {
        guard let fileURL else { throw ExchangeIntentServiceError.storeUnavailable }
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let entries = try JSONDecoder().decode([ExchangeImportLedgerEntry].self, from: data)
        guard entries.count <= Self.maxEntries else { throw ExchangeIntentServiceError.invalidPacket }
        return entries
    }

    private func write(_ entries: [ExchangeImportLedgerEntry]) throws {
        guard let fileURL else { throw ExchangeIntentServiceError.storeUnavailable }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: fileURL.path)
    }

    private static func defaultURL(fileManager: FileManager) -> URL? {
        let roots = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let root = roots.first else { return nil }
        return root.appendingPathComponent("Fernlet", isDirectory: true)
            .appendingPathComponent("ExchangeImportLedger.json", isDirectory: false)
    }
}

/// One recorded import: "this packet was already applied, and here is what it produced."
///
/// The replay key is the **pair** `(packetID, hash)`, never `packetID` alone — an edited packet
/// keeps its identifier but changes its content hash, so it is correctly treated as a new import
/// rather than replayed. `resultID` is what makes the retry idempotent: an automation that ran the
/// write but lost the result gets the original identifier back instead of a duplicate import.
///
/// Metadata only, by design — it holds identifiers and a digest, never recipe text, plan contents,
/// or the file itself, so the ledger stays cheap to keep and safe to reason about in a wipe.
nonisolated struct ExchangeImportLedgerEntry: Codable, Equatable, Sendable {
    var packetID: UUID
    var hash: String
    var resultID: String
    var kind: ExchangeImportLedgerKind
    var importedAt: Date
}

/// Which import funnel an ``ExchangeImportLedgerEntry`` came from, and therefore how its `resultID`
/// is interpreted (a recipe UUID string versus a workout-plan import result identifier).
///
/// Persisted: these raw values are written into `ExchangeImportLedger.json` and are frozen English
/// tokens per the localization wall. Renaming a case would silently orphan every prior entry —
/// decoding fails and the ledger is rejected — turning already-applied imports into replayable
/// duplicates.
nonisolated enum ExchangeImportLedgerKind: String, Codable, Sendable {
    case recipe
    case workoutPlan
}
