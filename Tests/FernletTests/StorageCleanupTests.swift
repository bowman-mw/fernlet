import Testing
import CoreData
import Foundation
import CloudKitSync
import LocalPersistence
import FernletDomainModel
import FernletPersistence
@testable import Fernlet

/// Perf review 2026-10-31: files nothing reads any more leave the device. The legacy JSON database goes once
/// the Core Data record it migrated into loads (never before: a missing record still migrates from it), its
/// live Tier-2 sidecar stays, and the June catalog move's decoded-JSON caches are swept by name only.
@MainActor
@Suite(.serialized)
struct StorageCleanupTests {
    private static func temporaryJSON() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    private static func snapshot(_ today: String) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: today, day: FernletDay(date: today), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData()
        )
    }

    @Test func theLegacyDatabaseGoesOnlyOnceItsRecordLoads() throws {
        let today = "2026-10-31"
        let legacyURL = Self.temporaryJSON()
        let legacy = LocalFernletRepository(fileURL: legacyURL)
        #expect(legacy.saveSnapshot(Self.snapshot(today)))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        let sidecar = TierTwoMemoryStore.sidecarURL(besideDatabaseAt: legacyURL)
        try Data("[]".utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let controller = PersistenceController(inMemory: true)
        // First launch: no record, so the migration reads the legacy file, and the file must survive it.
        _ = CoreDataFernletRepository(controller: controller, legacyRepository: legacy).loadSnapshot(todayKey: today)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path), "a migration never deletes its own source")

        // Next launch: the record decodes, so the migration is done and the file goes.
        _ = CoreDataFernletRepository(controller: controller, legacyRepository: LocalFernletRepository(fileURL: legacyURL))
            .loadSnapshot(todayKey: today)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path), "the live Tier-2 sidecar stays")
        #expect(LocalFernletRepository(fileURL: legacyURL).retireMigratedDatabaseFile(), "nothing left is success")
    }

    @Test func theSweepRemovesOnlyTheRetiredCatalogCaches() throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: caches) }
        for name in OrphanedCacheSweep.retiredNames + ["food_catalog_v3.bplist", "keep.bin"] {
            try Data([1]).write(to: caches.appendingPathComponent(name))
        }
        #expect(Set(OrphanedCacheSweep.run(in: caches)) == Set(OrphanedCacheSweep.retiredNames))
        let left = try FileManager.default.contentsOfDirectory(atPath: caches.path)
        #expect(Set(left) == ["food_catalog_v3.bplist", "keep.bin"])
        #expect(OrphanedCacheSweep.run(in: caches).isEmpty, "a second launch finds nothing to do")
    }
}
