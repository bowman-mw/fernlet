import Combine
import LocalPersistence
import FernletFoundation
import CoreData
import Foundation
import FernletDomainModel
import FernletPersistence

@MainActor
final class CoreDataFernletRepository: FernletRepository, RemoteChangePublishingRepository {
    private static let primaryRecordID = "primary"

    private let controller: PersistenceController
    private let legacyRepository: LocalFernletRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cachedDatabase: LocalFernletDatabase?
    private var cachedRecordUpdatedAt: Date?
    private var persistenceBlockedByDecodeFailure = false
    private var persistenceBlockedByFetchFailure = false
    private var forcedFetchFailureForTesting: Error?
    private var cancellable: AnyCancellable?
    // Guards against re-entry when a merge triggers its own local save notification.
    private var isMergingSave = false

    /// Fires after the local cache is invalidated due to a remote change.
    let remoteChangeSubject = PassthroughSubject<Void, Never>()

    var remoteChangePublisher: AnyPublisher<Void, Never> {
        remoteChangeSubject.eraseToAnyPublisher()
    }

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

            let record: NSManagedObject
            switch fetchRecordResult() {
            case .found(let fetchedRecord):
                record = fetchedRecord
            case .missing:
                clearReadOnlyRecoveryFlags()
                let migrated = migrateDatabase(todayKey: todayKey)
                _ = saveDatabase(migrated)
                return snapshot(from: migrated, todayKey: todayKey)
            case .failed(let error):
                markPersistenceBlockedByFetchFailure(error)
                return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
            }
            guard let payload = record.value(forKey: "payloadData") as? Data else {
                print("[Fernlet] Core Data record exists but payloadData is nil; entering read-only recovery mode.")
                markPersistenceBlockedByDecodeFailure()
                return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
            }

            do {
                let decodedAt = record.value(forKey: "updatedAt") as? Date
                let database = try await Self.decodeDatabaseAsync(from: payload)
                // A concurrent saveDatabase() may have installed a fresher cache while we decoded.
                if let fresh = cachedDatabase {
                    return snapshot(from: fresh, todayKey: todayKey)
                }
                clearReadOnlyRecoveryFlags()
                cachedDatabase = database
                cachedRecordUpdatedAt = decodedAt
                return snapshot(from: database, todayKey: todayKey)
            } catch {
                print("[Fernlet] Core Data record decode failed; entering read-only recovery mode: \(error.localizedDescription)")
                markPersistenceBlockedByDecodeFailure()
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

    func forceNextFetchFailureForTesting(_ error: Error = CocoaError(.fileReadUnknown)) {
        forcedFetchFailureForTesting = error
    }

    private func invalidateCacheIfRecordChanged() {
        guard !isMergingSave else { return }
        let latestUpdatedAt = fetchRecordUpdatedAt()
        guard latestUpdatedAt != cachedRecordUpdatedAt else { return }

        // When a remote change arrives and we have a locally-cached database, merge the
        // incoming remote days into it so edits to different days on different devices
        // are both preserved rather than the remote overwriting the local entirely.
        if let localDatabase = cachedDatabase {
            switch fetchRecordResult() {
            case .found(let record):
                if let remotePayload = record.value(forKey: "payloadData") as? Data,
                   let remoteDatabase = try? decoder.decode(LocalFernletDatabase.self, from: remotePayload) {
                    let (merged, addedAny) = mergingRemoteDays(into: localDatabase, from: remoteDatabase)
                    if addedAny {
                        isMergingSave = true
                        let saved = saveDatabase(merged)
                        isMergingSave = false
                        if saved {
                            // cachedDatabase and cachedRecordUpdatedAt are now set by saveDatabase.
                            remoteChangeSubject.send()
                            return
                        }
                    }
                    // No new remote days to merge (or the merge save was refused): fall through
                    // to drop the cache and adopt the remote payload on the next load. This
                    // converges on the remote copy for overlapping-day edits *without writing*,
                    // so it never bumps updatedAt or bounces a change back to the other device
                    // (breaking the feedback loop) while still letting genuine remote edits to
                    // existing days reach this device instead of being silently dropped.
                }
            case .missing, .failed:
                break
            }
        }

        cachedDatabase = nil
        cachedRecordUpdatedAt = latestUpdatedAt
        remoteChangeSubject.send()
    }

    /// Produces a merged database that contains all days from `local` plus any days
    /// from `remote` that are absent in `local`. Non-day fields come from `local`
    /// because the user's explicit changes on this device take precedence.
    private func mergingRemoteDays(into local: LocalFernletDatabase, from remote: LocalFernletDatabase) -> (database: LocalFernletDatabase, addedAny: Bool) {
        var merged = local
        var addedAny = false
        for (key, remoteDay) in remote.days where local.days[key] == nil {
            merged.days[key] = remoteDay
            addedAny = true
        }
        guard addedAny else { return (merged, false) }
        if merged.days.count > FernletLimits.maxStoredDays {
            let oldest = merged.days.keys.sorted().prefix(merged.days.count - FernletLimits.maxStoredDays)
            oldest.forEach { merged.days.removeValue(forKey: $0) }
        }
        merged.rebuildDerivedTables(todayKey: FernletDate.dayKey(for: .now))
        return (merged, true)
    }

    func loadAllDays() -> [String: FernletDay] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).days
    }

    func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    @discardableResult func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool {
        var database = loadDatabase(todayKey: FernletDate.dayKey(for: .now))
        database.tierTwoMemories = records
        database.updatedAt = Date()
        return saveDatabase(database)
    }

    private func loadDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")

        if let cached = cachedDatabase {
            return cached
        }

        // Stage 1: Check if a record exists at all.
        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            // No record — first launch or fresh install. Migrate from legacy.
            clearReadOnlyRecoveryFlags()
            let migrated = migrateDatabase(todayKey: todayKey)
            _ = saveDatabase(migrated)
            return migrated
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return LocalFernletDatabase()
        }

        // Stage 2: Record exists — attempt decode.
        guard let data = record.value(forKey: "payloadData") as? Data else {
            print("[Fernlet] Core Data record exists but payloadData is nil; entering read-only recovery mode.")
            markPersistenceBlockedByDecodeFailure()
            return LocalFernletDatabase()
        }

        do {
            let database = try StartupTiming.timed("CoreDataFernletRepository.loadDatabase.decode") {
                try decoder.decode(LocalFernletDatabase.self, from: data)
            }
            clearReadOnlyRecoveryFlags()
            cachedDatabase = database
            cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            return database
        } catch {
            // Record exists but is corrupt. Do NOT overwrite with legacy data.
            print("[Fernlet] Core Data record decode failed; entering read-only recovery mode: \(error.localizedDescription)")
            markPersistenceBlockedByDecodeFailure()
            return LocalFernletDatabase()
        }
    }

    private func markPersistenceBlockedByDecodeFailure() {
        persistenceBlockedByDecodeFailure = true
        cachedDatabase = nil
        cachedRecordUpdatedAt = nil
    }

    private func markPersistenceBlockedByFetchFailure(_ error: Error) {
        persistenceBlockedByFetchFailure = true
        cachedDatabase = nil
        print("[Fernlet] Core Data record fetch failed; entering read-only recovery mode: \(error.localizedDescription)")
    }

    /// Clears the read-only recovery latches once the store is readable again. A transient
    /// fetch/decode failure must not permanently block saves for the rest of the session:
    /// the latches only need to hold while the in-memory state may be a failure fallback.
    private func clearReadOnlyRecoveryFlags() {
        persistenceBlockedByDecodeFailure = false
        persistenceBlockedByFetchFailure = false
    }

    @discardableResult private func saveDatabase(_ database: LocalFernletDatabase) -> Bool {
        assert(database.schemaVersion >= 1, "schema version invalid")
        guard !persistenceBlockedByDecodeFailure else {
            print("[Fernlet] Refusing to save after Core Data database decode failed.")
            return false
        }
        guard !persistenceBlockedByFetchFailure else {
            print("[Fernlet] Refusing to save after Core Data record fetch failed.")
            return false
        }
        guard let data = try? encoder.encode(database) else {
            assertionFailure("Core Data database encode failed")
            return false
        }

        let context = controller.container.viewContext
        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            record = NSEntityDescription.insertNewObject(
                forEntityName: "FernletDatabaseRecord",
                into: context
            )
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return false
        }
        record.setValue(Self.primaryRecordID, forKey: "recordID")
        record.setValue(data, forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")

        do {
            if context.hasChanges {
                try context.save()
            }
            cachedDatabase = database  // Update cache with known-good state
            cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            return true
        } catch {
            assertionFailure("Core Data database save failed")
            context.rollback()
            cachedDatabase = nil  // Invalidate on failure
            return false
        }
    }

    private func fetchRecordUpdatedAt() -> Date? {
        switch fetchRecordResult() {
        case .found(let record):
            return record.value(forKey: "updatedAt") as? Date
        case .missing:
            return nil
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return cachedRecordUpdatedAt
        }
    }

    private enum FetchRecordResult {
        case found(NSManagedObject)
        case missing
        case failed(Error)
    }

    private func fetchRecordResult() -> FetchRecordResult {
        if let forcedFetchFailureForTesting {
            self.forcedFetchFailureForTesting = nil
            return .failed(forcedFetchFailureForTesting)
        }

        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        request.predicate = NSPredicate(format: "recordID == %@", Self.primaryRecordID)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let records = try context.fetch(request)
            guard let primary = records.first else { return .missing }
            // Remove duplicate records that can form when two devices first launch before
            // their initial CloudKit import settles. The oldest duplicates are deleted
            // in-context; they will be removed from the store on the next context.save().
            if records.count > 1 {
                records.dropFirst().forEach { context.delete($0) }
            }
            return .found(primary)
        } catch {
            return .failed(error)
        }
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

    nonisolated private static func decodeDatabaseAsync(from data: Data) async throws -> LocalFernletDatabase {
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
