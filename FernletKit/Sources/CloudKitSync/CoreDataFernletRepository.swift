import Combine
import LocalPersistence
import FernletFoundation
import CoreData
import Foundation
import FernletDomainModel
import FernletPersistence

@MainActor
public final class CoreDataFernletRepository: FernletRepository, @MainActor RemoteChangePublishingRepository {
    private static let primaryRecordID = "primary"

    private let controller: PersistenceController
    private let legacyRepository: LocalFernletRepository
    private let dayRecordRepository: any DayRecordRepositoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cachedDatabase: LocalFernletDatabase?
    private var cachedRecordUpdatedAt: Date?
    /// Decoded day-row history, memoized so the two full-history reads on every launch/foreground/remote
    /// change (`rebuildDerivedSignals` + `reconcileCoinLedger`) — and the month/day views that read past days
    /// — share ONE decode instead of re-scanning the whole (now uncapped) `DayRecord` table each call.
    /// Invalidated conservatively: nil'd on every `saveDatabase` (which follows every day-row write), on the
    /// remote-change/manual cache invalidation, and on entering read-only recovery — so it can never serve a
    /// day that was edited or synced in. Today is always overlaid live by `DiaryStore.loadDays`, so a stale
    /// today-row here is irrelevant.
    private var cachedAllDays: [String: FernletDay]?
    private var persistenceBlockedByDecodeFailure = false
    private var persistenceBlockedByFetchFailure = false
    private var forcedFetchFailureForTesting: Error?
    private var cancellable: AnyCancellable?

    /// Fires after the local cache is invalidated due to a remote change.
    public let remoteChangeSubject = PassthroughSubject<Void, Never>()

    public var remoteChangePublisher: AnyPublisher<Void, Never> {
        remoteChangeSubject.eraseToAnyPublisher()
    }

    public init(
        controller: PersistenceController? = nil,
        legacyRepository: LocalFernletRepository? = nil,
        dayRecordRepository: (any DayRecordRepositoring)? = nil
    ) {
        let resolvedController = controller ?? .shared
        self.controller = resolvedController
        self.legacyRepository = legacyRepository ?? LocalFernletRepository(fileURL: LocalFernletRepository.defaultFileURL())
        self.dayRecordRepository = dayRecordRepository ?? DayRecordRepository(controller: resolvedController)
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
        self.cancellable = self.controller.remoteChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateCacheIfRecordChanged()
            }
    }

    public func loadSnapshot(todayKey: String) -> FernletSnapshot {
        StartupTiming.timed("CoreDataFernletRepository.loadSnapshot") {
            assert(!todayKey.isEmpty, "today key required")
            let database = loadDatabase(todayKey: todayKey)
            return snapshot(from: database, todayKey: todayKey)
        }
    }

    public func loadSnapshotAsync(todayKey: String) async -> FernletSnapshot {
        let signpostID = StartupTiming.begin("CoreDataFernletRepository.loadSnapshotAsync")
        defer { StartupTiming.end("CoreDataFernletRepository.loadSnapshotAsync", signpostID: signpostID) }

        assert(!todayKey.isEmpty, "today key required")

        if let cached = cachedDatabase {
            let database = cached.daysMigratedToRows ? cached : migrateDaysToRowsIfNeeded(cached)
            return snapshot(from: database, todayKey: todayKey)
        }

        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            clearReadOnlyRecoveryFlags()
            var migrated = migrateDatabase(todayKey: todayKey)
            migrated = migrateDaysToRowsIfNeeded(migrated)
            if cachedDatabase == nil { _ = saveDatabase(migrated) }
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
            let decoded = try await Self.decodeDatabaseAsync(from: payload)
            // A concurrent saveDatabase() may have installed a fresher cache while we decoded.
            if let fresh = cachedDatabase {
                return snapshot(from: fresh, todayKey: todayKey)
            }
            clearReadOnlyRecoveryFlags()
            let database = migrateDaysToRowsIfNeeded(decoded)
            if cachedDatabase == nil {
                cachedDatabase = database
                cachedRecordUpdatedAt = decodedAt
            }
            return snapshot(from: database, todayKey: todayKey)
        } catch {
            print("[Fernlet] Core Data record decode failed; entering read-only recovery mode: \(error.localizedDescription)")
            markPersistenceBlockedByDecodeFailure()
            return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
        }
    }

    public func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        assert(!dateKey.isEmpty, "date key required")
        if let cached = cachedAllDays?[dateKey] { return cached }   // served from the shared day cache (no query)
        _ = loadDatabase(todayKey: todayKey)  // ensure decoded + rows backfilled
        return dayRecordRepository.load(dateKeys: [dateKey])[dateKey] ?? FernletDay(date: dateKey)
    }

    @discardableResult public func saveSnapshot(_ sanitized: SanitizedSnapshot) -> Bool {
        let snapshot = sanitized.snapshot
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        var database = loadDatabase(todayKey: snapshot.todayKey)
        // Write today's day to its per-row store FIRST so the derived rebuild (sourced from rows) sees it —
        // but not while persistence is blocked (a failed reload returns the empty fallback, and writing the
        // row then would corrupt it just as saveDatabase refuses the blob). Skip → the whole save is a no-op.
        if !isPersistenceBlocked {
            dayRecordRepository.upsert([DayRecordUpsert(day: snapshot.day, updatedAt: Date())])
        }
        // While migration is still pending (e.g. a failed batch left the flag false), the blob may hold the
        // only copy of un-migrated days, so don't bound/prune it then. Once migrated, refreshRowDerivedState
        // clears the blob's days entirely, so the bound here is moot — apply still writes the aggregate.
        let blobDayBound = database.daysMigratedToRows ? FernletLimits.derivedLogWindowDays : nil
        database.apply(snapshot, maxStoredDays: blobDayBound)
        refreshRowDerivedState(&database, todayKey: snapshot.todayKey)
        return saveDatabase(database)
    }

    /// After day rows are written, refresh the blob's row-derived state from the bounded recent window:
    /// rebuild the derived log tables, recompute the day-content summary (so iCloud detection stays a
    /// single blob read), and — once migration is complete — clear the blob's `days` cache entirely (the
    /// per-row `DayRecord` store is the authoritative, uncapped source of truth).
    private func refreshRowDerivedState(_ database: inout LocalFernletDatabase, todayKey: String) {
        let recent = recentDayPairs()
        database.rebuildDerivedTables(todayKey: todayKey, recentDays: recent)
        database.dayContentSummary = DayContentSummary(days: recent.map(\.1))
        if database.daysMigratedToRows {
            database.days = [:]
        }
    }

    @discardableResult public func updateDay(_ sanitized: SanitizedDay, for dateKey: String, todayKey: String) -> Bool {
        let day = sanitized.day
        assert(!dateKey.isEmpty, "date key required")
        assert(!todayKey.isEmpty, "today key required")
        assert(day.date == dateKey, "day date mismatch")
        var database = loadDatabase(todayKey: todayKey)
        if !isPersistenceBlocked {
            dayRecordRepository.upsert([DayRecordUpsert(day: day, updatedAt: Date())])
        }
        // The edited day lives in its row; refresh the derived tables + detection summary from rows (and,
        // once migrated, keep the blob's days cleared). Never write the edited day into the blob.
        refreshRowDerivedState(&database, todayKey: todayKey)
        return saveDatabase(database)
    }

    public func storageDescription() -> String {
        "Core Data + iCloud"
    }

    public func invalidateCache() {
        cachedDatabase = nil
        cachedAllDays = nil
        cachedRecordUpdatedAt = nil
        remoteChangeSubject.send()
    }

    public func forceNextFetchFailureForTesting(_ error: Error = CocoaError(.fileReadUnknown)) {
        forcedFetchFailureForTesting = error
    }

    private func invalidateCacheIfRecordChanged() {
        let latestUpdatedAt = fetchRecordUpdatedAt()
        guard latestUpdatedAt != cachedRecordUpdatedAt else { return }

        // Days now live in per-record DayRecords, so NSPersistentCloudKitContainer merges day edits per
        // record: different-day edits on two devices both persist (the old whole-blob union that dropped
        // same-day remote edits is gone), and a same-day conflict resolves by the store's merge policy.
        // A remote change therefore just drops the cached aggregate; day rows are re-read fresh (and
        // duplicate-collapsed) on the next access, so no bespoke merge or feedback-loop guard is needed.
        cachedDatabase = nil
        cachedAllDays = nil
        cachedRecordUpdatedAt = latestUpdatedAt
        remoteChangeSubject.send()
    }

    /// Fans the blob's `days` into per-row `DayRecord`s once (idempotent, batched, crash-safe). Called
    /// only after a CLEAN aggregate decode (never under read-only recovery, which would fan out an empty
    /// fallback). On any batch failure it leaves `daysMigratedToRows` false so a later launch resumes —
    /// `upsert` skips rows already written, so the rows themselves are the progress cursor. This permanent
    /// lazy backfill is what makes retiring the blob's `days` safe.
    private func migrateDaysToRowsIfNeeded(_ database: LocalFernletDatabase) -> LocalFernletDatabase {
        guard !database.daysMigratedToRows else { return database }
        let pairs = database.days.sorted { $0.key < $1.key }
        if !pairs.isEmpty {
            // Backfill ONLY days that don't already have a row. A row can already exist because another
            // device wrote a fresher edit for that day (synced in), or a prior migration batch / updateDay
            // already wrote it. Overwriting such a row with the blob's stale copy — stamped with the blob's
            // single global `updatedAt` — would let the stale day win the max-updatedAt dedup and clobber the
            // newer edit both locally and back out over CloudKit. Skipping keeps migration a pure backfill,
            // fixes the re-fan-clobbers-a-row-edit case, and leaves the rows themselves as the resume cursor.
            let stamp = database.updatedAt
            let existingKeys = Set(dayRecordRepository.load(dateKeys: pairs.map(\.key)).keys)
            let backfill = pairs.filter { !existingKeys.contains($0.key) }
            let batchSize = 250
            var index = 0
            while index < backfill.count {
                let slice = backfill[index..<min(index + batchSize, backfill.count)]
                let ok = dayRecordRepository.upsert(slice.map { DayRecordUpsert(day: $0.value, updatedAt: stamp) })
                guard ok else { return database }  // leave the flag false → resume next launch
                index += batchSize
            }
        }
        var migrated = database
        migrated.daysMigratedToRows = true
        // Seed the detection summary from the blob's days, then retire the blob's day cache (the rows just
        // written are authoritative). The `days` field stays decodable so an older build can still lazily
        // backfill from a blob that predates this clearing.
        migrated.dayContentSummary = DayContentSummary(days: Array(database.days.values))
        migrated.days = [:]
        _ = saveDatabase(migrated)
        return migrated
    }

    /// The bounded recent-day window from the row store, oldest-first, for derived-table rebuilds — so a
    /// rebuild never scans the whole (now uncapped) history.
    private func recentDayPairs() -> [(String, FernletDay)] {
        dayRecordRepository.loadRecent(limit: FernletLimits.derivedLogWindowDays)
            .map { ($0.date, $0) }
            .sorted { $0.0 < $1.0 }
    }

    public func loadAllDays() -> [String: FernletDay] {
        if let cached = cachedAllDays { return cached }
        _ = loadDatabase(todayKey: FernletDate.dayKey(for: .now))  // ensure decoded + migration attempted
        let all = dayRecordRepository.loadAll()
        // Only memoize once migration has completed and the store is readable. Caching a partially-migrated
        // set (a failed batch leaves `daysMigratedToRows` false) would short-circuit the resume-on-next-load
        // and strand the un-backfilled days.
        if cachedDatabase?.daysMigratedToRows == true, !isPersistenceBlocked {
            cachedAllDays = all
        }
        return all
    }

    public func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    @discardableResult public func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool {
        var database = loadDatabase(todayKey: FernletDate.dayKey(for: .now))
        database.tierTwoMemories = records
        database.updatedAt = Date()
        return saveDatabase(database)
    }

    private func loadDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")

        if let cached = cachedDatabase {
            // Permanent lazy backfill: if a prior migration attempt didn't finish, retry on every load
            // until the rows are written (the flag flips true) — what makes retiring the blob safe.
            return cached.daysMigratedToRows ? cached : migrateDaysToRowsIfNeeded(cached)
        }

        // Stage 1: Check if a record exists at all.
        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            // No record — first launch or fresh install. Migrate from legacy, then fan its days to rows.
            clearReadOnlyRecoveryFlags()
            var migrated = migrateDatabase(todayKey: todayKey)
            migrated = migrateDaysToRowsIfNeeded(migrated)
            if cachedDatabase == nil { _ = saveDatabase(migrated) }
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
            let decoded = try StartupTiming.timed("CoreDataFernletRepository.loadDatabase.decode") {
                try decoder.decode(LocalFernletDatabase.self, from: data)
            }
            clearReadOnlyRecoveryFlags()
            let database = migrateDaysToRowsIfNeeded(decoded)
            if cachedDatabase == nil {
                cachedDatabase = database
                cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            }
            return database
        } catch {
            // Record exists but is corrupt. Do NOT overwrite with legacy data.
            print("[Fernlet] Core Data record decode failed; entering read-only recovery mode: \(error.localizedDescription)")
            markPersistenceBlockedByDecodeFailure()
            return LocalFernletDatabase()
        }
    }

    /// True while the aggregate store is in read-only recovery (a failed fetch/decode returned the empty
    /// fallback). Day-row writes are skipped in this state so a no-op save can't corrupt a day's row.
    private var isPersistenceBlocked: Bool {
        persistenceBlockedByDecodeFailure || persistenceBlockedByFetchFailure
    }

    private func markPersistenceBlockedByDecodeFailure() {
        persistenceBlockedByDecodeFailure = true
        cachedDatabase = nil
        cachedAllDays = nil
        cachedRecordUpdatedAt = nil
    }

    private func markPersistenceBlockedByFetchFailure(_ error: Error) {
        persistenceBlockedByFetchFailure = true
        cachedDatabase = nil
        cachedAllDays = nil
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
        // Every save follows a day-row write (saveSnapshot/updateDay/migrate), so drop the memoized day
        // history — the next read re-decodes the fresh rows.
        cachedAllDays = nil
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
        // Today's day comes from its row (the authoritative day store). While migration is incomplete (a
        // failed/lagging backfill leaves `daysMigratedToRows` false) the row may not be written yet, so fall
        // back to the blob's copy — which still holds the day until migration clears `days` — before
        // returning an empty day. Otherwise an empty today would surface and the next save would clobber the
        // real entries. Post-migration `database.days` is empty, so this fallback is a no-op there.
        let day = dayRecordRepository.load(dateKeys: [todayKey])[todayKey]
            ?? database.days[todayKey]
            ?? FernletDay(date: todayKey)
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
