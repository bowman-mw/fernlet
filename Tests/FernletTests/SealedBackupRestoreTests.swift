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

/// A throwaway `UserDefaults` suite per call, so the device-local `hasEverStoredNarrative` latch cannot
/// leak between tests. In production the latch lives in `.standard`, which is process-global under the
/// test runner — one test inserting a narrative would otherwise mark every later test's device as
/// "already diverged" and silently invert the targeted-restore assertions.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "fernlet.tests.narrativeLatch.\(UUID().uuidString)") ?? .standard
}

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
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
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
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
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
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
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
        #expect(dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-06-10", healthContext: HealthDailyContext()), updatedAt: Date())]) == true)
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

    // MARK: - Un-hide restore path (pre-merge review 2026-07-19, finding #2)

    /// The bug: the G5 gate correctly skips the launch-time period restore while cycle tracking is
    /// hidden, but there was NO compensating restore afterwards. `restoreSealedBackupsIfNeeded` only ever
    /// restores into a fresh install, so once the day blob syncs down the device is permanently "not
    /// fresh" and every remaining period seam (un-hide, escrow-adopt, launch follow-through) RE-UPLOADS
    /// rather than restores — a user who hid period tracking on device A and reinstalled on device B could
    /// never get their sealed cycle history back.
    ///
    /// Here the device is in use (populated days/meals/journal) but holds no cycle history. The launch
    /// restore must still refuse it as non-fresh; the targeted un-hide restore must NOT be short-circuited
    /// (with no CloudKit/escrow wired in a unit test it lands on a deferred outcome, exactly as
    /// `restoreNotSkippedOnGenuinelyBlankDevice` does).
    @MainActor
    @Test func unhideRestoreRunsOnDeviceThatIsNoLongerAFreshInstall() async {
        let store = makePopulatedTestStore()
        store.settings.periodTrackingVisible = true
        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )

        // Baseline: the launch/auto path is permanently blocked on this device — the bug's mechanism.
        let launchOutcome = await store.restoreSealedBackupOutcome(payloadType: .periodData)
        #expect(launchOutcome == .skippedStoreNotEmpty)

        // The compensating path gets past the freshness gate.
        let unhideOutcome = await store.restorePeriodBackupTargeted(narrativeRepository: narrativeRepository)
        #expect(unhideOutcome != .skippedStoreNotEmpty)
    }

    /// The un-hide restore relaxes ONLY the whole-device freshness gate. Cycle history the user already
    /// has on this device is still never clobbered or duplicated. (Mechanically the refusal now comes
    /// from the `hasEverStoredNarrative` latch — the insert latches before the count is ever consulted —
    /// and the count check remains behind it as defense in depth; the populated-but-UNLATCHED
    /// configuration is exercised by `latchBackfillsFromExistingRowsWrittenBeforeTheLatchShipped`.)
    @MainActor
    @Test func unhideRestoreStillRefusesPopulatedNarrativeStore() async throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        try narrativeRepository.insert(
            MenstrualNarrative(hkExternalUUID: "local-1", dateKey: "2026-05-20", note: "Logged locally.", symptomFlags: []),
            contentKey: key
        )

        let outcome = await store.restorePeriodBackupTargeted(narrativeRepository: narrativeRepository)
        #expect(outcome == .skippedStoreNotEmpty)
        #expect(try narrativeRepository.narrativeCount() == 1)   // unchanged
    }

    /// The fail-closed-at-the-decrypt-seam property is preserved: this path decrypts cycle narratives and
    /// writes them into the sealed store, so it must refuse while period tracking is hidden. Reported as
    /// RETRYABLE, which is also what stops the caller from re-uploading this device's still-gated
    /// narrative store over the cloud backup.
    @MainActor
    @Test func unhideRestoreRefusesWhilePeriodTrackingHidden() async {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = false
        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )

        let outcome = await store.restorePeriodBackupTargeted(narrativeRepository: narrativeRepository)
        #expect(outcome.didRestore == false)
        #expect(outcome.isRetryable)
    }

    /// The regression the first cut of this fix shipped, caught by adversarial review: an empty narrative
    /// store is NOT self-evidently safe to restore into. `PeriodTrackerStore.deleteEntry` hard-deletes the
    /// row and never reconciles the sealed backup, so after the user deletes their cycle entries the store
    /// is empty while the CLOUD copy is stale-but-populated. `.payloadStoreOnly` dropped the whole-device
    /// freshness gate that had been standing in for "has this device diverged from the cloud snapshot?",
    /// so un-hiding — a mere visibility toggle — silently resurrected deliberately-deleted cycle notes
    /// (`.restored` has needsAttention == false, so not even a banner). The device-local
    /// `hasEverStoredNarrative` latch carries that missing bit.
    ///
    /// Here the store is empty because a narrative was written and then deleted. The targeted restore must
    /// refuse, even though the row count is 0 and period tracking is visible.
    @MainActor
    @Test func unhideRestoreRefusesAfterTheUserDeletedTheirCycleHistory() async throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        let narrative = MenstrualNarrative(
            hkExternalUUID: "local-1", dateKey: "2026-05-20", note: "Logged, then deleted.", symptomFlags: []
        )
        try narrativeRepository.insert(narrative, contentKey: key)
        #expect(narrativeRepository.hasEverStoredNarrative)   // latched by the write

        // The user deletes it — the store is now empty, but the cloud backup still holds it.
        try narrativeRepository.delete(id: narrative.id)
        #expect(try narrativeRepository.narrativeCount() == 0)
        #expect(narrativeRepository.hasEverStoredNarrative)   // latch is one-way, survives the delete

        // Un-hiding must NOT resurrect the deleted note, despite the empty store.
        let outcome = await store.restorePeriodBackupTargeted(narrativeRepository: narrativeRepository)
        #expect(outcome == .skippedStoreNotEmpty)
        #expect(outcome.didRestore == false)
        #expect(outcome.needsAttention == false)   // a deliberate, benign refusal — no banner
        #expect(try narrativeRepository.narrativeCount() == 0)
    }

    /// The upgrade configuration: rows written by a build that PREDATES the latch (simulated by reading
    /// the same populated context through fresh defaults, where the insert never latched). The getter
    /// must backfill from the row count — without it, an upgrading install reads as "never populated"
    /// and the whole latch scheme silently no-ops for exactly the users with history to protect.
    @MainActor
    @Test func latchBackfillsFromExistingRowsWrittenBeforeTheLatchShipped() async throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        // The "old build" writes a narrative; its defaults suite is then discarded, like an app update
        // shipping the latch after the data already exists.
        let preLatchRepository = MenstrualNarrativeRepository(context: context, defaults: isolatedDefaults())
        try preLatchRepository.insert(
            MenstrualNarrative(hkExternalUUID: "pre-1", dateKey: "2026-04-01", note: "Pre-upgrade.", symptomFlags: []),
            contentKey: key
        )
        // The "new build" sees the same rows through defaults that never latched.
        let upgraded = MenstrualNarrativeRepository(context: context, defaults: isolatedDefaults())
        #expect(upgraded.hasEverStoredNarrative, "the latch did not backfill from existing rows")

        let outcome = await store.restorePeriodBackupTargeted(narrativeRepository: upgraded)
        #expect(outcome == .skippedStoreNotEmpty)
    }

    /// The resurrection the backfill alone cannot stop: the upgrading user DELETES their pre-latch
    /// history first (nothing ever read the latch while rows existed), leaving an empty store behind
    /// unlatched defaults — indistinguishable from a fresh install by count. The DELETE itself must
    /// latch: removing a row is proof this device diverged from the cloud snapshot, so a later un-hide
    /// must refuse to re-pull the deliberately-deleted notes.
    @MainActor
    @Test func targetedRestoreRefusesAfterPreLatchHistoryIsDeleted() async throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let preLatchRepository = MenstrualNarrativeRepository(context: context, defaults: isolatedDefaults())
        let narrative = MenstrualNarrative(
            hkExternalUUID: "pre-1", dateKey: "2026-04-01", note: "Pre-upgrade, then deleted.", symptomFlags: []
        )
        try preLatchRepository.insert(narrative, contentKey: key)

        // The upgraded build's first touch of the store is the DELETE — no read ever backfilled.
        let upgraded = MenstrualNarrativeRepository(context: context, defaults: isolatedDefaults())
        try upgraded.delete(id: narrative.id)
        #expect(try upgraded.narrativeCount() == 0)
        #expect(upgraded.hasEverStoredNarrative, "the delete did not latch the diverged marker")

        let outcome = await store.restorePeriodBackupTargeted(narrativeRepository: upgraded)
        #expect(outcome == .skippedStoreNotEmpty)
        #expect(try upgraded.narrativeCount() == 0)
    }

    /// The diverged latch is enforced in `isEmptyStoreForRestore` itself — the gate EVERY restore path
    /// funnels through — so the AMBIENT `.freshInstall` pass honors it too. The scenario: delete-all
    /// empties the day blob (the device classifies as fresh again) but the sealed-backup chunk delete
    /// failed, so a stale cloud backup survives; the next launch must NOT quietly restore the wiped
    /// cycle history. The write point throws rather than inserting.
    @MainActor
    @Test func freshInstallScopedApplyRefusesADivergedEmptyStore() throws {
        let store = makeTestStore()   // blank → classifies as a fresh install
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let repository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        // Populate then wipe THROUGH the repository, the way the delete-all funnel's period hook does:
        // the deleteAll latches, leaving an empty-but-diverged store.
        try repository.insert(
            MenstrualNarrative(hkExternalUUID: "wiped-1", dateKey: "2026-04-01", note: "Wiped.", symptomFlags: []),
            contentKey: key
        )
        try repository.deleteAll()
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative)

        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "stale-1", dateKey: "2026-03-01", note: "Stale cloud copy.", symptomFlags: [])
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(
                data, payloadType: .periodData, narrativeRepository: repository, scope: .freshInstall
            )
        }
        #expect(try repository.narrativeCount() == 0)
    }

    /// Delete-all cancels the in-flight un-hide settle Task, and the restore write point honors that
    /// cancellation: a settle suspended in its CloudKit fetch when the wipe runs must not resume and
    /// re-insert cycle narratives into the just-emptied store.
    @MainActor
    @Test func applyRefusesToWriteInsideACancelledTask() async throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let repository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "backup-1", dateKey: "2026-06-01", note: "From backup.", symptomFlags: [])
        ])

        let restore = Task { () -> Result<Int, Error> in
            // Deterministically wait out the cancel below — models the settle suspended in its fetch
            // when "delete everything" cancels it.
            while !Task.isCancelled { await Task.yield() }
            return Result { try store.applyRestoredPayload(
                data, payloadType: .periodData, narrativeRepository: repository, scope: .payloadStoreOnly
            ) }
        }
        restore.cancel()

        guard case .failure(let error) = await restore.value else {
            Issue.record("a cancelled restore still wrote \((try? repository.narrativeCount()) ?? -1) records")
            return
        }
        #expect(error is CancellationError)
        #expect(try repository.narrativeCount() == 0)
    }

    /// The latch must be set by the RESTORE path too, not just ordinary logging — otherwise a user who
    /// restores a backup, then deletes it all, could re-pull it by toggling visibility.
    @MainActor
    @Test func restoringNarrativesLatchesTheEverStoredMarker() throws {
        let store = makePopulatedTestStore()
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        #expect(narrativeRepository.hasEverStoredNarrative == false)
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "backup-1", dateKey: "2026-06-01", note: "From backup.", symptomFlags: [])
        ])
        _ = try store.applyRestoredPayload(
            data, payloadType: .periodData, narrativeRepository: narrativeRepository, scope: .payloadStoreOnly
        )
        #expect(narrativeRepository.hasEverStoredNarrative)
    }

    /// The write point honors the relaxed scope too (defense in depth cuts both ways): with
    /// `.payloadStoreOnly` an in-use device with an EMPTY narrative store accepts the restored history,
    /// where the default `.freshInstall` scope would refuse it.
    @MainActor
    @Test func applyRestoredPeriodWritesUnderPayloadStoreOnlyScopeOnInUseDevice() throws {
        let store = makePopulatedTestStore()
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let narrativeRepository = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "backup-1", dateKey: "2026-06-01", note: "From backup.", symptomFlags: []),
            MenstrualNarrative(hkExternalUUID: "backup-2", dateKey: "2026-06-02", note: "Also from backup.", symptomFlags: [])
        ])

        // Default scope: refused, because the device is in use.
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(data, payloadType: .periodData, narrativeRepository: narrativeRepository)
        }
        #expect(try narrativeRepository.narrativeCount() == 0)

        // Targeted scope: accepted, because the narrative store itself is empty.
        let count = try store.applyRestoredPayload(
            data,
            payloadType: .periodData,
            narrativeRepository: narrativeRepository,
            scope: .payloadStoreOnly
        )
        #expect(count == 2)
        #expect(try narrativeRepository.narrativeCount() == 2)
    }

    // MARK: - Journal self-sufficiency (P3): restored entries must actually be VISIBLE

    /// The hazard the `reinstateJournalEntries` hook exists for. `JournalNarrative` carries the whole
    /// entry, but the journal UI renders `FernletDay.journals` SKELETONS and hydrates the text by id —
    /// and on a sync-OFF device reset the days blob is gone too. Restoring narrative rows alone would
    /// leave entries that exist, decrypt, and are rendered by nothing: a silent recovery failure for
    /// exactly the users the sealed backup exists to protect.
    ///
    /// Here the device has NO day rows at all. After the restore, the day must carry the entry (right
    /// id, tag, date) and reading it back must hydrate the sealed text.
    @MainActor
    @Test func journalRestoreReconstructsDaySkeletonsSoEntriesAreVisibleAndHydrate() throws {
        let (store, _, narratives) = makeTestStoreWithRepositories(
            date: try #require(FernletDate.date(fromDayKey: "2026-06-10"))
        )
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        // No days blob whatsoever — the post-reset state.
        #expect(store.loadDay(for: "2026-06-01").journals.isEmpty)

        let entryDate = try #require(FernletDate.date(fromDayKey: "2026-06-01"))
        let restored = JournalNarrative(
            id: UUID(), dayKey: "2026-06-01", tag: .hard, entryDate: entryDate,
            text: "The words that only live in the sealed store.", emotions: ["tired"],
            createdAt: entryDate, updatedAt: entryDate
        )
        let count = try store.applyRestoredPayload(
            try JSONEncoder().encode([restored]),
            payloadType: .journalNarratives,
            journalRepository: narratives,
            scope: .payloadStoreOnly
        )
        #expect(count == 1)

        // The skeleton landed in the day blob…
        let skeletons = store.loadDay(for: "2026-06-01").journals
        #expect(skeletons.count == 1)
        #expect(skeletons.first?.id == restored.id)
        #expect(skeletons.first?.tag == .hard)
        // …carrying NO sealed content (text and emotions are sealed columns; putting them back in the
        // iCloud-mirrored blob would undo the sealing).
        #expect(skeletons.first?.text.isEmpty == true)
        #expect(skeletons.first?.emotions.isEmpty == true)

        // …and the read path hydrates the text and emotions by id from the sealed store.
        let hydrated = store.loadDayWithDecryptedJournals(for: "2026-06-01").journals
        #expect(hydrated.first?.text == "The words that only live in the sealed store.")
        #expect(hydrated.first?.emotions == ["tired"])
    }

    /// The same reconstruction for TODAY, which the in-memory `day` owns rather than the repository —
    /// the sealed-journal refresh has to fill it in without a reload.
    @MainActor
    @Test func journalRestoreReconstructsTodaysEntriesAndHydratesThemInMemory() throws {
        let today = try #require(FernletDate.date(fromDayKey: "2026-06-10"))
        let (store, _, narratives) = makeTestStoreWithRepositories(date: today)
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        let restored = JournalNarrative(
            id: UUID(), dayKey: "2026-06-10", tag: .good, entryDate: today,
            text: "Today, recovered.", emotions: [], createdAt: today, updatedAt: today
        )
        _ = try store.applyRestoredPayload(
            try JSONEncoder().encode([restored]),
            payloadType: .journalNarratives,
            journalRepository: narratives,
            scope: .payloadStoreOnly
        )

        #expect(store.day.journals.map(\.id) == [restored.id])
        #expect(store.day.journals.first?.text == "Today, recovered.",
                "the sealed-journal refresh did not hydrate the reconstructed skeleton")
    }

    /// Reconstruction must be idempotent and additive: an entry the day already holds is never
    /// duplicated, and an unrelated entry already on the day survives.
    @MainActor
    @Test func journalRestoreDoesNotDuplicateEntriesTheDayAlreadyHolds() throws {
        let today = try #require(FernletDate.date(fromDayKey: "2026-06-10"))
        let (store, _, narratives) = makeTestStoreWithRepositories(date: today)
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)

        // An entry this device already has (skeleton + sealed row), as a mid-restore race would leave it.
        let existing = JournalNarrative(
            id: UUID(), dayKey: "2026-06-10", tag: .good, entryDate: today,
            text: "Already here.", emotions: [], createdAt: today, updatedAt: today
        )
        store.day.journals = [
            JournalEntry(id: existing.id, text: "", tag: .good, date: today, emotions: [])
        ]

        let alsoRestored = JournalNarrative(
            id: UUID(), dayKey: "2026-06-10", tag: .hard, entryDate: today.addingTimeInterval(60),
            text: "New from the backup.", emotions: [], createdAt: today, updatedAt: today
        )
        _ = try store.applyRestoredPayload(
            try JSONEncoder().encode([existing, alsoRestored]),
            payloadType: .journalNarratives,
            journalRepository: narratives,
            scope: .payloadStoreOnly
        )

        #expect(store.day.journals.count == 2, "reconstruction duplicated an entry the day already had")
        #expect(Set(store.day.journals.map(\.id)) == [existing.id, alsoRestored.id])
    }
}
