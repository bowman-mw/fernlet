import Foundation
import CoreData
import Testing
import CloudKitSync
import LocalPersistence
import FernletDomainModel
import FernletPersistence
@testable import Fernlet

/// Parity coverage for the two entry points into `CoreDataFernletRepository`'s aggregate-blob load.
///
/// `loadSnapshot(todayKey:)` (sync) and `loadSnapshotAsync(todayKey:)` used to re-implement the same
/// pipeline — cache check, fetch three-way, first-launch legacy migration, payload-nil guard, decode,
/// migration retry, read-only-recovery latching — in two places, and the sync path had far more test
/// coverage than the async one. They now share one staged pipeline with only the decode differing
/// (off the main actor in the async case), so these tests drive the SAME situations through the async
/// entry point that `FernletTests` already drives through the sync one.
///
/// Serialized: each test stands up its own in-memory Core Data stack, but `PersistenceController`'s
/// remote-change publisher is process-level and its debounced sink can invalidate a cache mid-test.
@MainActor
@Suite(.serialized)
struct CoreDataStagedBlobLoadTests {

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedBlobLoad-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    private func snapshot(bottleCount: Int, todayKey: String = "2026-05-16") -> FernletSnapshot {
        FernletSnapshot(
            todayKey: todayKey,
            day: FernletDay(date: todayKey, bottleCount: bottleCount),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }

    /// The happy path through the shared stages: what the sync load returns, the async load returns.
    @Test func asyncLoadReturnsTheSameRealDataAsTheSyncLoad() async {
        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("parity-legacy"))
        )
        #expect(repository.saveSnapshot(snapshot(bottleCount: 4)))

        repository.invalidateCache()
        let asyncLoaded = await repository.loadSnapshotAsync(todayKey: "2026-05-16")
        let syncLoaded = repository.loadSnapshot(todayKey: "2026-05-16")

        #expect(asyncLoaded.day.bottleCount == 4)
        #expect(syncLoaded.day.bottleCount == asyncLoaded.day.bottleCount)
        #expect(repository.isInReadOnlyRecovery == false)
    }

    /// The `.missing` stage from the async side: no Core Data record yet, so the legacy JSON store is
    /// migrated in and persisted. Previously this branch existed twice; only the sync copy was covered.
    @Test func asyncLoadMigratesTheLegacyStoreOnFirstLaunch() async {
        let legacyRepository = LocalFernletRepository(fileURL: temporaryDatabaseURL("first-launch-legacy"))
        #expect(legacyRepository.saveSnapshot(snapshot(bottleCount: 7)))

        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: legacyRepository
        )

        let migrated = await repository.loadSnapshotAsync(todayKey: "2026-05-16")
        #expect(migrated.day.bottleCount == 7)
        #expect(repository.isInReadOnlyRecovery == false)

        // The migration persisted, so a subsequent load reads the Core Data record rather than
        // re-migrating (and returns the same content either way).
        #expect(repository.loadSnapshot(todayKey: "2026-05-16").day.bottleCount == 7)
    }

    /// The `.failed` stage from the async side: a transient fetch failure must return the EMPTY
    /// fallback and latch read-only recovery, never fall through to the legacy store. A caller that
    /// applied this snapshot without checking the latch would blank every screen.
    @Test func asyncLoadLatchesReadOnlyRecoveryOnFetchFailure() async {
        let repository = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("async-fetch-failure-legacy"))
        )
        #expect(repository.isInReadOnlyRecovery == false)

        repository.forceNextFetchFailureForTesting(CocoaError(.fileReadUnknown))
        let fallback = await repository.loadSnapshotAsync(todayKey: "2026-05-16")

        #expect(fallback.day.meals.isEmpty)
        #expect(fallback.day.bottleCount == 0)
        #expect(repository.isInReadOnlyRecovery, "a failed fetch must latch read-only recovery")

        // A readable load clears the latch — the same contract the sync path has.
        repository.invalidateCache()
        _ = await repository.loadSnapshotAsync(todayKey: "2026-05-16")
        #expect(repository.isInReadOnlyRecovery == false, "a readable load must clear recovery")
    }

    /// The corruption policy from the async side: an undecodable payload latches read-only recovery,
    /// serves the empty fallback, refuses the next save, and leaves the corrupt record untouched — it
    /// is never overwritten with legacy data.
    @Test func asyncLoadRefusesToOverwriteACorruptRecord() async throws {
        let controller = PersistenceController(inMemory: true)
        let seeding = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("async-corrupt-seed-legacy"))
        )
        #expect(seeding.saveSnapshot(snapshot(bottleCount: 2)))

        let corruptData = Data("not-json".utf8)
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        request.predicate = NSPredicate(format: "recordID == %@", "primary")
        let record = try #require(try context.fetch(request).first)
        record.setValue(corruptData, forKey: "payloadData")
        try context.save()

        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("async-corrupt-legacy"))
        )
        let fallback = await repository.loadSnapshotAsync(todayKey: "2026-05-16")

        #expect(fallback.day.bottleCount == 0, "a corrupt payload must yield the empty fallback")
        #expect(repository.isInReadOnlyRecovery, "a corrupt payload must latch read-only recovery")
        #expect(repository.saveSnapshot(snapshot(bottleCount: 9)) == false, "saves stay refused while latched")

        let persisted = try #require(try context.fetch(request).first)
        #expect(persisted.value(forKey: "payloadData") as? Data == corruptData)
    }
}
