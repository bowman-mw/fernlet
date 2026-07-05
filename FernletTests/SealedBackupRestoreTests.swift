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
import PrivateMemoryStore
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

    // MARK: - Fresh-install gate treats a bare HealthKit sync stamp as "device already in use"

    /// Finding 7 (deferred design-judgment): the auto-restore fresh-install gate was narrowed onto the
    /// shared `FernletDay.hasLoggedContent`, which intentionally ignores a *bare, metric-less*
    /// `healthContext` (a HealthKit sync stamp — `syncedAt` set, every metric nil) so the coin economy
    /// doesn't award an "active day" for merely opening the app. But the RESTORE gate must be
    /// conservative: a device that already holds any day row — including a bare sync stamp — is in use,
    /// and auto-restore must NOT run over it. `isFreshInstallForRestore` therefore applies the stricter
    /// "any `healthContext` present ⇒ not fresh" check locally. Here the only content on the device is a
    /// past-day row carrying a bare `HealthDailyContext()`, so restore must be SKIPPED as non-empty.
    @MainActor
    @Test func restoreSkippedWhenOnlyContentIsBareHealthKitSyncStamp() async {
        // Sanity: a bare sync stamp is NOT "logged content" (shared-model semantics the gate overrides).
        #expect(FernletDay(date: "2026-06-10", healthContext: HealthDailyContext()).hasLoggedContent == false)

        // Seed a PAST-day ROW whose only content is a bare, metric-less HealthKit sync stamp — the shape a
        // migrated legacy day takes (migration fans blob days into rows without item G's empty-content guard).
        // Seed the row directly via the day-record store, bypassing saveSnapshot/updateDay (which item G would
        // skip for a content-less day, so it would never persist and the gate would never see it).
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let dayRepo = DayRecordRepository(controller: controller)
        dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-06-10", healthContext: HealthDailyContext()), updatedAt: Date())])
        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL),
            dayRecordRepository: dayRepo
        )
        let narratives = JournalNarrativeRepository(controller: PrivatePersistenceController(inMemory: true))
        let store = makeStoreSharingStores(
            date: FernletDate.date(fromDayKey: "2026-06-20")!,
            repository: repository,
            narratives: narratives
        )

        // The device is now "in use" for the restore gate → auto-restore must refuse (never clobbers).
        let outcome = await store.restoreSealedBackupOutcome(payloadType: .sensitiveNotes)
        #expect(outcome == .skippedStoreNotEmpty)
    }

    /// Positive control: the stricter gate must NOT wrongly block a legitimately blank device. With zero
    /// day rows and empty caches, `isFreshInstallForRestore` still returns true, so restore is NOT
    /// short-circuited as "store not empty" — it proceeds past the gate (and, with no CloudKit/escrow
    /// wired in a unit test, lands on a deferred/nothing outcome rather than `.skippedStoreNotEmpty`).
    @MainActor
    @Test func restoreNotSkippedOnGenuinelyBlankDevice() async {
        let store = makeTestStore()
        let outcome = await store.restoreSealedBackupOutcome(payloadType: .sensitiveNotes)
        #expect(outcome != .skippedStoreNotEmpty)
    }
}
