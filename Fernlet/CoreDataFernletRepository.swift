import Combine
import CoreData
import Foundation

@MainActor
final class CoreDataFernletRepository: FernletRepository {
    private static let primaryRecordID = "primary"

    private let controller: PersistenceController
    private let legacyRepository: LocalFernletRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cachedDatabase: LocalFernletDatabase?
    private var cachedRecordUpdatedAt: Date?
    private var cacheGeneration: UInt64 = 0
    private var cancellable: AnyCancellable?

    /// Fires after the local cache is invalidated due to a remote change.
    let remoteChangeSubject = PassthroughSubject<Void, Never>()

    init(controller: PersistenceController? = nil, legacyRepository: LocalFernletRepository? = nil) {
        self.controller = controller ?? .shared
        self.legacyRepository = legacyRepository ?? LocalFernletRepository(fileURL: LocalFernletRepository.defaultFileURL())
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
        self.cancellable = self.controller.remoteChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateCacheIfRecordChanged()
            }
    }

    func loadSnapshot(todayKey: String) -> FernletSnapshot {
        StartupTiming.timed("CoreDataFernletRepository.loadSnapshot") {
            assert(!todayKey.isEmpty, "today key required")
            let database = loadDatabase(todayKey: todayKey)
            return snapshot(from: database, todayKey: todayKey)
        }
    }

    func loadSnapshotAsync(todayKey: String) async -> FernletSnapshot {
        await StartupTiming.timed("CoreDataFernletRepository.loadSnapshotAsync") {
            assert(!todayKey.isEmpty, "today key required")

            if let cached = cachedDatabase {
                return snapshot(from: cached, todayKey: todayKey)
            }

            guard let record = fetchRecord() else {
                let migrated = migrateDatabase(todayKey: todayKey)
                _ = saveDatabase(migrated)
                return snapshot(from: migrated, todayKey: todayKey)
            }
            guard let payload = record.value(forKey: "payloadData") as? Data else {
                assertionFailure("Core Data record exists but payloadData is nil")
                return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
            }

            do {
                let database = try await Self.decodeDatabaseAsync(from: payload)
                cachedDatabase = database
                cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
                return snapshot(from: database, todayKey: todayKey)
            } catch {
                assertionFailure("Core Data record decode failed: \(error.localizedDescription)")
                return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
            }
        }
    }

    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        assert(!dateKey.isEmpty, "date key required")
        let database = loadDatabase(todayKey: todayKey)
        return database.days[dateKey] ?? FernletDay(date: dateKey)
    }

    @discardableResult func saveSnapshot(_ snapshot: FernletSnapshot) -> Bool {
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        var database = loadDatabase(todayKey: snapshot.todayKey)
        database.apply(snapshot)
        database.rebuildDerivedTables(todayKey: snapshot.todayKey)
        return saveDatabase(database)
    }

    @discardableResult func updateDay(_ day: FernletDay, for dateKey: String, todayKey: String) -> Bool {
        assert(!dateKey.isEmpty, "date key required")
        assert(!todayKey.isEmpty, "today key required")
        assert(day.date == dateKey, "day date mismatch")
        var database = loadDatabase(todayKey: todayKey)
        database.days[dateKey] = day
        database.rebuildDerivedTables(todayKey: todayKey)
        return saveDatabase(database)
    }

    func storageDescription() -> String {
        "Core Data + iCloud"
    }

    func invalidateCache() {
        cachedDatabase = nil
        cachedRecordUpdatedAt = nil
        remoteChangeSubject.send()
    }

    private func invalidateCacheIfRecordChanged() {
        let latestUpdatedAt = fetchRecordUpdatedAt()
        guard latestUpdatedAt != cachedRecordUpdatedAt else { return }
        cachedDatabase = nil
        cachedRecordUpdatedAt = latestUpdatedAt
        remoteChangeSubject.send()
    }

    func loadAllDays() -> [String: FernletDay] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).days
    }

    func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    private func loadDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")

        if let cached = cachedDatabase {
            return cached
        }

        // Stage 1: Check if a record exists at all.
        guard let record = fetchRecord() else {
            // No record — first launch or fresh install. Migrate from legacy.
            let migrated = migrateDatabase(todayKey: todayKey)
            _ = saveDatabase(migrated)
            return migrated
        }

        // Stage 2: Record exists — attempt decode.
        guard let data = record.value(forKey: "payloadData") as? Data else {
            assertionFailure("Core Data record exists but payloadData is nil")
            return LocalFernletDatabase()
        }

        do {
            let database = try StartupTiming.timed("CoreDataFernletRepository.loadDatabase.decode") {
                try decoder.decode(LocalFernletDatabase.self, from: data)
            }
            cachedDatabase = database
            cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            return database
        } catch {
            // Record exists but is corrupt. Do NOT overwrite with legacy data.
            assertionFailure("Core Data record decode failed: \(error.localizedDescription)")
            // Return empty database so the app doesn't crash.
            // TODO: Add telemetry/logging here for production builds.
            return LocalFernletDatabase()
        }
    }

    @discardableResult private func saveDatabase(_ database: LocalFernletDatabase) -> Bool {
        assert(database.schemaVersion >= 1, "schema version invalid")
        guard let data = try? encoder.encode(database) else {
            assertionFailure("Core Data database encode failed")
            return false
        }

        let context = controller.container.viewContext
        let record = fetchRecord() ?? NSEntityDescription.insertNewObject(
            forEntityName: "FernletDatabaseRecord", into: context
        )
        record.setValue(Self.primaryRecordID, forKey: "recordID")
        record.setValue(data, forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")

        do {
            if context.hasChanges {
                try context.save()
            }
            cachedDatabase = database  // Update cache with known-good state
            cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            cacheGeneration += 1
            return true
        } catch {
            assertionFailure("Core Data database save failed")
            context.rollback()
            cachedDatabase = nil  // Invalidate on failure
            return false
        }
    }

    private func fetchRecordUpdatedAt() -> Date? {
        guard let record = fetchRecord() else { return nil }
        return record.value(forKey: "updatedAt") as? Date
    }

    private func fetchRecord() -> NSManagedObject? {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        request.predicate = NSPredicate(format: "recordID == %@", Self.primaryRecordID)
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try? context.fetch(request).first
    }

    private func migrateDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")
        return legacyRepository.loadDatabaseForMigration(todayKey: todayKey)
    }

    private func snapshot(from database: LocalFernletDatabase, todayKey: String) -> FernletSnapshot {
        let day = database.days[todayKey] ?? FernletDay(date: todayKey)
        return FernletSnapshot(
            todayKey: todayKey,
            day: day,
            settings: database.settings,
            recentMeals: database.recentMeals,
            previousJournals: database.previousJournals,
            memories: database.memories,
            goals: database.goals,
            workshop: database.workshop,
            foodItems: database.foodItems,
            recipes: database.recipes,
            dailyScores: database.dailyScores,
            retryQueue: database.retryQueue,
            connectionSessionLogs: database.connectionSessionLogs,
            trustedProximityPeers: database.trustedProximityPeers,
            trainerAuditEvents: database.trainerAuditEvents
        )
    }

    private static func decodeDatabaseAsync(from data: Data) async throws -> LocalFernletDatabase {
        let signpostID = StartupTiming.begin("CoreDataFernletRepository.loadDatabase.decode.async")
        defer { StartupTiming.end("CoreDataFernletRepository.loadDatabase.decode.async", signpostID: signpostID) }

        let decoder = makeDecoder()
        return try decoder.decode(LocalFernletDatabase.self, from: data)
    }

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
