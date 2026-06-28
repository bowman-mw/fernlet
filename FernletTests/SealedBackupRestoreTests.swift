//
//  SealedBackupRestoreTests.swift
//  FernletTests
//
//  Covers Item 4 (Remaining-work doc): the sealed-backup *restore-into-stores* path. The CloudKit
//  fetch + identity crypto are exercised by SealedBackupTests; these tests cover everything around
//  it that is unit-testable without iCloud — the empty-store guard, the Tier-2 writeback, its
//  survival across a normal snapshot save, and the period-narrative Core Data writeback (incl. the
//  locked-key path). Full end-to-end with live CloudKit remains device-runtime verification.
//

import CoreData
import LocalPersistence
import FernletFoundation
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import PrivateStoreCore
import PrivateHealthStore
import CloudKitSync
@testable import Fernlet

struct SealedBackupRestoreTests {

    // MARK: - Empty-store guard

    @MainActor
    @Test func restoreSkippedWhenStoreHasLoggedData() async {
        let store = makePopulatedTestStore()
        let before = store.tierTwoMemories
        // Guard short-circuits before any CloudKit/identity work, so this never hits the network.
        let restored = await store.restoreSealedBackup(payloadType: .sensitiveNotes)
        #expect(restored == false)
        #expect(store.tierTwoMemories == before)
    }

    @MainActor
    @Test func applyRestoredSensitiveNotesRefusesToClobberPopulatedStore() throws {
        // Defense in depth: even called directly (bypassing restoreSealedBackup's guard),
        // applyRestoredPayload must not overwrite an existing store.
        let store = makePopulatedTestStore()
        let before = store.tierTwoMemories
        let data = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "consistency", text: "Should not be written.", state: "steady")
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(data, payloadType: .sensitiveNotes)
        }
        #expect(store.tierTwoMemories == before)
    }

    @MainActor
    @Test func applyRestoredPeriodRefusesToClobberPopulatedStore() throws {
        // The no-clobber guard runs before the locked-key check, so a populated store throws
        // `storeNotEmpty` even when no content key is active.
        let store = makePopulatedTestStore()
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "uuid-1", dateKey: "2026-06-01", note: "x", symptomFlags: [])
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(data, payloadType: .periodData)
        }
    }

    // MARK: - Tier-2 (sensitive notes) writeback

    @MainActor
    @Test func applyRestoredSensitiveNotesWritesTierTwoMemories() throws {
        let store = makeTestStore()
        let records = [
            TierTwoMemoryRecord(category: "consistency", text: "Logs steadily on weekdays.", state: "steady"),
            TierTwoMemoryRecord(category: "recovery", text: "Prefers gentle evenings after hard days.", state: "present")
        ]
        let data = try JSONEncoder().encode(records)

        let count = try store.applyRestoredPayload(data, payloadType: .sensitiveNotes)
        #expect(count == 2)

        let loaded = store.tierTwoMemories
        #expect(loaded.count == 2)
        #expect(Set(loaded.map(\.category)) == ["consistency", "recovery"])
    }

    @Test func replacedTierTwoMemoriesSurviveSnapshotSave() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-restore-survive-\(UUID().uuidString).json")
        let repository = LocalFernletRepository(fileURL: url)
        let records = [TierTwoMemoryRecord(category: "consistency", text: "Steady weekday logger.", state: "steady")]
        #expect(repository.replaceTierTwoMemories(records))

        // A normal app save rebuilds derived tables; on a fresh install (no day history) the
        // inference engine must preserve the restored records rather than wipe them.
        let today = FernletDate.dayKey(for: .now)
        let snapshot = FernletSnapshot(
            todayKey: today,
            day: FernletDay(date: today),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        #expect(repository.saveSnapshot(snapshot))

        let loaded = repository.loadTierTwoMemories()
        #expect(loaded.count == 1)
        #expect(loaded.first?.category == "consistency")
    }

    @MainActor
    @Test func applyRestoredSensitiveNotesIgnoresEmptyPayload() throws {
        let store = makeTestStore()
        let data = try JSONEncoder().encode([TierTwoMemoryRecord]())
        let count = try store.applyRestoredPayload(data, payloadType: .sensitiveNotes)
        #expect(count == 0)
        #expect(store.tierTwoMemories.isEmpty)
    }

    // MARK: - Period narrative writeback

    @MainActor
    @Test func applyRestoredPeriodWritesNarratives() throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )
        let narratives = [
            MenstrualNarrative(hkExternalUUID: "uuid-1", dateKey: "2026-06-01", note: "Cramps, low energy.", symptomFlags: []),
            MenstrualNarrative(hkExternalUUID: "uuid-2", dateKey: "2026-06-02", note: "Better.", symptomFlags: [])
        ]
        let data = try JSONEncoder().encode(narratives)

        let count = try store.applyRestoredPayload(data, payloadType: .periodData, narrativeRepository: narrativeRepository)
        #expect(count == 2)

        let interval = DateInterval(
            start: try #require(FernletDate.date(fromDayKey: "2026-05-31")),
            end: try #require(FernletDate.date(fromDayKey: "2026-06-03"))
        )
        let readBack = try narrativeRepository.narratives(in: interval, contentKey: key)
        #expect(readBack.count == 2)
        #expect(readBack.contains { $0.note == "Cramps, low energy." })
    }

    @MainActor
    @Test func applyRestoredPeriodThrowsWhenContentKeyLocked() throws {
        let store = makeTestStore() // no lock activated → no content key
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "uuid-1", dateKey: "2026-06-01", note: "x", symptomFlags: [])
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.self) {
            try store.applyRestoredPayload(data, payloadType: .periodData)
        }
    }

    // MARK: - Period no-clobber guard consults the narrative store (WI-5)

    /// WI-5 (Docs/Security-Hardening-Plan-2026-06-27.md): the period-data no-clobber guard previously
    /// only checked the days/memory caches (`isFreshInstallForRestore`), never the separate sealed
    /// narrative store. Period narratives live in PrivateHealthStore and are written independently, so a
    /// device could hold N sealed narratives while still looking "fresh", and restore (insert-only, run
    /// every launch) duplicated that history. The guard now also gates on the narrative count.
    @MainActor
    @Test func applyRestoredPeriodDoesNotDuplicateOnSecondRestore() throws {
        let store = makeTestStore()                         // fresh by the day/memory checks
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)       // unlock so the period insert path has a key

        // One in-memory narrative store shared across both restores (mirrors production's shared store).
        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "uuid-1", dateKey: "2026-06-01", note: "Cramps.", symptomFlags: []),
            MenstrualNarrative(hkExternalUUID: "uuid-2", dateKey: "2026-06-02", note: "Better.", symptomFlags: [])
        ])

        // First restore into an empty narrative store succeeds.
        let first = try store.applyRestoredPayload(data, payloadType: .periodData, narrativeRepository: narrativeRepository)
        #expect(first == 2)
        #expect(try narrativeRepository.narrativeCount() == 2)

        // Second restore is refused — the narrative store already holds sealed history. No duplication.
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(data, payloadType: .periodData, narrativeRepository: narrativeRepository)
        }
        #expect(try narrativeRepository.narrativeCount() == 2)
    }

    /// The exact bug scenario: the device looks "fresh" (no logged days/memories) but the separate
    /// narrative store was already seeded locally (as PeriodTrackerStore.logEvent would). A restore must
    /// be refused rather than duplicating/clobbering that sealed history.
    @MainActor
    @Test func applyRestoredPeriodRefusedWhenNarrativeStorePreSeeded() throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )
        try narrativeRepository.insert(
            MenstrualNarrative(hkExternalUUID: "local-1", dateKey: "2026-05-20", note: "Logged locally.", symptomFlags: []),
            contentKey: key
        )
        #expect(try narrativeRepository.narrativeCount() == 1)

        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "backup-1", dateKey: "2026-06-01", note: "From backup.", symptomFlags: [])
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(data, payloadType: .periodData, narrativeRepository: narrativeRepository)
        }
        #expect(try narrativeRepository.narrativeCount() == 1)   // unchanged
    }
}
