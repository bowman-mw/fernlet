//
//  TierTwoDeviceLocalTests.swift
//  FernletTests
//
//  Owner decision 2026-09-23: "Tier 2 sensitive notes shouldn't be backed up to iCloud at all."
//
//  Tier-2 behavioral memories (`TierTwoMemoryEngine`'s judgemental inferences — goal_behavior_gap,
//  journal_avoidance_pattern, workout_mood_correlation, consistency_profile) used to ride the
//  aggregate blob `FernletDatabaseRecord.payloadData`, which `NSPersistentCloudKitContainer` mirrors
//  to the user's private CloudKit database whenever sync is on — in PLAINTEXT. These cells pin the
//  fix at the only place it can be proven: the bytes that were actually written.
//

import CoreData
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import LocalPersistence
@testable import Fernlet

/// Pins the 2026-09-23 owner decision for Tier-2 behavioral memories: never in the mirrored blob,
/// never in the local day-blob file, persisted only in the device-local, backup-excluded
/// `TierTwoMemoryStore` sidecar — with the engine's change-driven history intact — and wiped by
/// "delete everything".
@MainActor
@Suite(.serialized)
struct TierTwoDeviceLocalTests {

    // MARK: - Fixtures

    /// A never-shared legacy/local JSON location. Its directory is the shared temp dir, so the
    /// FILE name carries the uniqueness.
    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TierTwoDeviceLocal-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    /// A day with enough logged content to count as an active day for every engine category.
    private func activeDay(_ key: String) -> FernletDay {
        FernletDay(
            date: key,
            meals: [Meal(name: "Oats", mealType: .breakfast, macros: Macros(protein: 12, carbs: 40, fat: 6),
                         quality: .good, confidence: "Manual", note: "", source: "Manual")],
            workouts: [],
            journals: [],
            sleep: nil,
            bottleCount: 2
        )
    }

    /// An active day that also carries a workout, for flipping the goal-behavior verdict.
    private func trainingDay(_ key: String) -> FernletDay {
        var day = activeDay(key)
        day.workouts = [Workout(name: "Upper", type: .upper, exercises: "DB row 3x10", rpe: 7,
                                notes: "steady", duration: 35, intensity: .moderate)]
        return day
    }

    private func snapshot(_ day: FernletDay, goals: [FitnessGoal] = []) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: day.date, day: day, settings: FernletSettings(), recentMeals: [],
            previousJournals: [], memories: [], goals: goals, workshop: WorkshopData()
        )
    }

    /// The sidecar's records exactly as they sit on disk.
    private func sidecarRecords(_ store: TierTwoMemoryStore) throws -> [TierTwoMemoryRecord] {
        try RowPayloadCoders.makeDecoder().decode(
            [TierTwoMemoryRecord].self, from: Data(contentsOf: store.fileURL)
        )
    }

    /// Writes `records` straight into a sidecar file, below the store — how a test plants state the
    /// store must then carry forward.
    private func plant(_ records: [TierTwoMemoryRecord], in store: TierTwoMemoryStore) throws {
        try RowPayloadCoders.makeEncoder().encode(records).write(to: store.fileURL, options: .atomic)
    }

    /// Writes four past active days and saves today, so the engine's 3-day minimum is met and it
    /// emits at least the consistency profile. Returns today's key.
    private func seedEnoughHistory(into repository: some FernletRepository) -> String {
        let pastKeys = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"]
        let today = "2026-09-05"
        for key in pastKeys {
            #expect(repository.updateDay(activeDay(key), for: key, todayKey: today))
        }
        #expect(repository.saveSnapshot(snapshot(activeDay(today))))
        return today
    }

    /// The raw JSON object the Core Data path last wrote into the mirrored aggregate record —
    /// exactly what `NSPersistentCloudKitContainer` would export.
    private func mirroredBlobObject(_ controller: PersistenceController) throws -> [String: Any] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        let record = try #require(try controller.container.viewContext.fetch(request).first)
        let payload = try #require(record.value(forKey: "payloadData") as? Data)
        return try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    /// Seeds a PRE-UPGRADE aggregate record — one carrying a `tierTwoMemories` array, which is what
    /// every existing install's mirrored record holds — straight into the store, below the repository.
    private func seedPreUpgradeBlob(in controller: PersistenceController) throws {
        let record = TierTwoMemoryRecord(
            category: "journal_avoidance_pattern",
            text: "Journal entries frequently contain excuse and avoidance language.",
            state: "high_avoidance",
            evidence: "3/4 journal entries contain avoidance language",
            confidence: "high"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(LocalFernletDatabase())) as? [String: Any]
        )
        object["tierTwoMemories"] = try JSONSerialization.jsonObject(with: encoder.encode([record]))
        object["daysMigratedToRows"] = true
        let payload = try JSONSerialization.data(withJSONObject: object)

        let context = controller.container.viewContext
        let row = NSEntityDescription.insertNewObject(forEntityName: "FernletDatabaseRecord", into: context)
        row.setValue("primary", forKey: "recordID")
        row.setValue(payload, forKey: "payloadData")
        row.setValue(Date(), forKey: "updatedAt")
        try context.save()
    }

    // MARK: - The mirrored blob

    /// The headline cell. After a save that DOES produce Tier-2 inferences, the aggregate record the
    /// CloudKit mirror exports carries no `tierTwoMemories` key at all — while the inferences still
    /// exist, device-locally, for the one on-device reader that needs them.
    @Test func coreDataSaveWritesAMirroredBlobWithNoTierTwoKey() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("coredata"))
        )
        _ = seedEnoughHistory(into: repository)

        #expect(!repository.loadTierTwoMemories().isEmpty,
                "precondition: the engine emitted nothing, so this cell would pass vacuously")
        let blob = try mirroredBlobObject(controller)
        #expect(blob["settings"] != nil, "precondition: this is not the aggregate record")
        #expect(blob["tierTwoMemories"] == nil,
                "Tier-2 inferences reached the CloudKit-mirrored aggregate record")
    }

    /// Every EXISTING install's mirrored record already carries Tier-2 in plaintext. The fix is only
    /// real if the next ordinary save overwrites that record without it — so the stale cloud copy is
    /// replaced by the mirror, not left behind.
    @Test func aPreUpgradeBlobLosesItsTierTwoOnTheNextSave() throws {
        let controller = PersistenceController(inMemory: true)
        try seedPreUpgradeBlob(in: controller)
        #expect(try mirroredBlobObject(controller)["tierTwoMemories"] != nil, "precondition: seed failed")

        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("preupgrade"))
        )
        #expect(repository.saveSnapshot(snapshot(activeDay("2026-09-05"))))

        #expect(try mirroredBlobObject(controller)["tierTwoMemories"] == nil,
                "the next save re-wrote the old blob's Tier-2 back into the mirrored record")
    }

    /// The local JSON path is never mirrored, but it is an ordinary Application Support file — and so
    /// rides the user's device backup (iCloud Backup included) whenever the backup-exclusion
    /// preference is off. "Not backed up to iCloud at all" therefore covers it too.
    @Test func localJSONFileNeverCarriesTierTwo() throws {
        let url = temporaryDatabaseURL("localjson")
        let repository = LocalFernletRepository(fileURL: url)
        _ = seedEnoughHistory(into: repository)

        #expect(!repository.loadTierTwoMemories().isEmpty,
                "precondition: the engine emitted nothing, so this cell would pass vacuously")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["settings"] != nil, "precondition: this is not the database file")
        #expect(object["tierTwoMemories"] == nil,
                "Tier-2 inferences were written into the day-blob file")
    }

    // MARK: - Where Tier-2 lives now

    /// The records exist on disk only in the sidecar beside the database — and that file is excluded
    /// from device backups (iCloud Backup included), which the day-blob file is only by preference.
    @Test func tierTwoLivesInABackupExcludedSidecarBesideTheDatabase() throws {
        let url = temporaryDatabaseURL("sidecar")
        let repository = LocalFernletRepository(fileURL: url)
        _ = seedEnoughHistory(into: repository)

        let store = repository.tierTwoMemoryStore
        #expect(store.fileURL == TierTwoMemoryStore.sidecarURL(besideDatabaseAt: url))
        #expect(store.fileURL.deletingLastPathComponent() == url.deletingLastPathComponent())
        let onDisk = try sidecarRecords(store)
        #expect(!onDisk.isEmpty)
        #expect(onDisk == repository.loadTierTwoMemories())
        let values = try URL(fileURLWithPath: store.fileURL.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true, "the Tier-2 sidecar would ride the device backup")
    }

    /// Both backends agree on ONE device-local file: the Core Data repository reuses its legacy
    /// repository's sidecar, so switching storage modes never strands or duplicates the inferences.
    @Test func coreDataRepositorySharesItsLegacyRepositorysSidecar() throws {
        let legacyURL = temporaryDatabaseURL("shared")
        let legacy = LocalFernletRepository(fileURL: legacyURL)
        let repository = CoreDataFernletRepository(controller: PersistenceController(inMemory: true), legacyRepository: legacy)
        _ = seedEnoughHistory(into: repository)

        #expect(repository.tierTwoMemoryStore.fileURL == legacy.tierTwoMemoryStore.fileURL)
        #expect(try sidecarRecords(repository.tierTwoMemoryStore) == repository.loadTierTwoMemories())
        #expect(legacy.loadTierTwoMemories() == repository.loadTierTwoMemories())
    }

    /// No inferences, no file: a history too short for the engine leaves nothing on disk rather than
    /// an empty list the backup-exclusion flag then has to cover.
    @Test func tooLittleHistoryWritesNoSidecar() {
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("short"))
        #expect(repository.saveSnapshot(snapshot(activeDay("2026-09-05"))))
        #expect(repository.loadTierTwoMemories().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repository.tierTwoMemoryStore.fileURL.path))
    }

    // MARK: - Why it is persisted rather than recomputed

    /// The engine is change-driven, and the sidecar is what carries that state across a relaunch: an
    /// UNCHANGED verdict keeps its record (same id, same first-seen date — the date `MemoryAgent`'s
    /// recency filter reads), and a CHANGED one supersedes its predecessor, which stays behind as
    /// inactive history. A from-scratch recompute would mint a fresh record for both.
    @Test func aRelaunchKeepsFirstSeenDatesAndSupersededVerdictsStayAsHistory() throws {
        let url = temporaryDatabaseURL("history")
        // Weight management, not strength: the strength arm's "misaligned" text says "low-motivation
        // period", which the diagnostic post-classifier rejects on "period" — it is never stored.
        let goal = FitnessGoal(type: .weightManagement, goal: "Eat steadily", timeframe: "8 weeks", metric: "meals")
        let first = LocalFernletRepository(fileURL: url)
        for key in ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"] {
            #expect(first.updateDay(activeDay(key), for: key, todayKey: "2026-09-05"))
        }
        #expect(first.saveSnapshot(snapshot(activeDay("2026-09-05"), goals: [goal])))
        let before = first.loadTierTwoMemories()
        let gap = try #require(before.first { $0.category == "goal_behavior_gap" && $0.active })
        let consistency = try #require(before.first { $0.category == "consistency_profile" && $0.active })
        #expect(gap.state == "dietary_only", "precondition: meal-only days under a weight-management goal")

        // A simulated relaunch: a brand-new repository over the same files, then five training days.
        let relaunched = LocalFernletRepository(fileURL: url)
        #expect(relaunched.loadTierTwoMemories() == before)
        for key in ["2026-09-06", "2026-09-07", "2026-09-08", "2026-09-09"] {
            #expect(relaunched.updateDay(trainingDay(key), for: key, todayKey: "2026-09-10"))
        }
        #expect(relaunched.saveSnapshot(snapshot(trainingDay("2026-09-10"), goals: [goal])))

        let after = relaunched.loadTierTwoMemories()
        let gaps = after.filter { $0.category == "goal_behavior_gap" }
        #expect(gaps.first { $0.id == gap.id }?.active == false, "the superseded verdict was not kept as history")
        #expect(gaps.filter(\.active).map(\.state) == ["aligned"])
        let stillConsistent = try #require(after.first { $0.category == "consistency_profile" && $0.active })
        #expect(stillConsistent.id == consistency.id, "an unchanged verdict was re-minted")
        #expect(stillConsistent.extractedDate == consistency.extractedDate, "the first-seen date moved")
    }

    /// Records already in the sidecar survive an ordinary save that is too short on history for the
    /// engine to judge anything — the engine prunes, it never discards what it cannot re-derive.
    @Test func persistedRecordsSurviveASaveWithTooLittleHistory() throws {
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("survive"))
        let planted = [TierTwoMemoryRecord(category: "consistency_profile", text: "Logs consistently.", state: "consistent")]
        try plant(planted, in: repository.tierTwoMemoryStore)
        let expected = repository.loadTierTwoMemories()
        #expect(expected.count == 1)

        #expect(repository.saveSnapshot(snapshot(activeDay("2026-09-05"))))

        #expect(repository.loadTierTwoMemories() == expected)
    }

    // MARK: - Delete everything

    /// Both repositories' purge removes the sidecar — including the Core Data one, whose legacy JSON
    /// file typically does not exist at all in the shipping configuration.
    @Test func purgeRemovesTheSidecarOnBothBackends() {
        let local = LocalFernletRepository(fileURL: temporaryDatabaseURL("purge-local"))
        _ = seedEnoughHistory(into: local)
        #expect(FileManager.default.fileExists(atPath: local.tierTwoMemoryStore.fileURL.path))
        #expect(local.purgeAllPersistedData())
        #expect(!FileManager.default.fileExists(atPath: local.tierTwoMemoryStore.fileURL.path))
        #expect(local.loadTierTwoMemories().isEmpty)

        let coreData = CoreDataFernletRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LocalFernletRepository(fileURL: temporaryDatabaseURL("purge-coredata"))
        )
        _ = seedEnoughHistory(into: coreData)
        #expect(FileManager.default.fileExists(atPath: coreData.tierTwoMemoryStore.fileURL.path))
        #expect(coreData.purgeAllPersistedData())
        #expect(!FileManager.default.fileExists(atPath: coreData.tierTwoMemoryStore.fileURL.path))
        #expect(coreData.loadTierTwoMemories().isEmpty)
    }

    /// "Delete everything" through the real funnel reaches Tier-2 wherever it now lives.
    @Test func deleteEverythingClearsTierTwo() async {
        let (store, repository, _) = makeTestStoreWithRepositories()
        _ = seedEnoughHistory(into: repository)
        #expect(!store.tierTwoMemories.isEmpty, "precondition: nothing to delete")

        _ = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(store.tierTwoMemories.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repository.tierTwoMemoryStore.fileURL.path),
                "the Tier-2 sidecar survived delete everything")
    }
}
