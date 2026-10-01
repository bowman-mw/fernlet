//
//  SealedBackupRestoreTests.swift
//  FernletTests
//
//  Covers Item 4 (Remaining-work doc): the sealed-backup *restore-into-stores* path. The CloudKit
//  fetch + identity crypto are exercised by SealedBackupTests; these tests cover everything around
//  it that is unit-testable without iCloud — the empty-store guard, the refusal to write back the
//  RETIRED Tier-2 (sensitive notes) payload (owner decision 2026-09-23; the rest of its retirement is
//  in SensitiveNotesRetirementTests), and the period-narrative Core Data writeback (incl. the
//  locked-key path). Full end-to-end with live CloudKit remains device-runtime verification.
//

import CoreData
import ProximityKit
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

@Suite(.serialized)
struct SealedBackupRestoreTests {

    // MARK: - Empty-store guard

    /// The whole-device freshness gate refuses a device that already holds logged data. Journal is the
    /// probe (the retired sensitive-notes payload used to be): the gate answers before the payload's own
    /// store is ever read, so this never hits the network or the shared sealed store.
    @MainActor
    @Test func restoreSkippedWhenStoreHasLoggedData() async {
        let store = makePopulatedTestStore()
        let restored = await store.restoreSealedBackup(payloadType: .journalNarratives)
        #expect(restored == false)
        #expect(await store.restoreSealedBackupOutcome(payloadType: .journalNarratives) == .skippedStoreNotEmpty)
    }

    // MARK: - The retired Tier-2 (sensitive notes) payload is never written back

    /// Owner decision 2026-09-23: the sensitive-notes payload — the Tier-2 memories — is retired. Even
    /// called directly at the write point, over a populated store, it writes nothing and does not throw.
    @MainActor
    @Test func applyRestoredSensitiveNotesNeverWritesTierTwo() throws {
        let store = makePopulatedTestStore()
        let before = store.tierTwoMemories
        let data = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "consistency_profile", text: "Should not be written.", state: "consistent")
        ])
        #expect(try store.applyRestoredPayload(data, payloadType: .sensitiveNotes) == 0)
        #expect(store.tierTwoMemories == before)
    }

    /// The period restore is a MERGE (period-data design 2026-09-30, §9.10): on a device that already
    /// holds cycle history — and that is "in use" by every other measure — it adds the backup's entries
    /// beside the local ones and overwrites none of them. (The v1 store-empty refusal is gone: a merge
    /// cannot clobber, and the resolved marker is what stops resurrection.)
    @MainActor
    @Test func applyRestoredPeriodMergesIntoAPopulatedStoreWithoutClobbering() throws {
        let store = makePopulatedTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let records = PeriodBackupDevice.makeRecordStore()
        records.attachVisibilityGate { true }
        let local = PeriodBackupDevice.record(day: 1, note: "Logged locally.")
        try records.insert(local, contentKey: key)
        let backedUp = PeriodBackupDevice.record(day: 2, note: "From backup.")
        let data = try PeriodBackupFormat.encodeChunk(index: 0, records: [backedUp], writer: "w", total: 1)

        #expect(try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records) == 1)

        let after = try records.allRecords(contentKey: key).records
        #expect(after.count == 2)
        #expect(after.first { $0.id == local.id } == local, "the local entry is untouched")
    }

    /// The blank-device half of the same refusal: the case the retired payload used to "restore" into —
    /// a fresh install with an empty Tier-2 store — now stays empty. (Survival of records that already
    /// live in the device-local store across a save is pinned in `TierTwoDeviceLocalTests`.)
    @MainActor
    @Test func applyRestoredSensitiveNotesWritesNothingOnABlankDevice() throws {
        let store = makeTestStore()
        let data = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "consistency_profile", text: "Logs steadily on weekdays.", state: "consistent"),
            TierTwoMemoryRecord(category: "workout_mood_correlation", text: "Gentle evenings.", state: "neutral")
        ])
        #expect(try store.applyRestoredPayload(data, payloadType: .sensitiveNotes) == 0)
        #expect(store.tierTwoMemories.isEmpty)
    }

    // MARK: - Period record writeback (v2 merge)

    /// A v1 set (bare `[MenstrualNarrative]`) restores as narrative-only records under their legacy
    /// ids, re-sealed under this iPhone's key.
    @MainActor
    @Test func applyRestoredPeriodWritesV1NarrativesAsRecords() throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let records = PeriodBackupDevice.makeRecordStore()
        let ids = [UUID(), UUID()]
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: ids[0].uuidString, dateKey: "2026-06-01", note: "Cramps, low energy.", symptomFlags: []),
            MenstrualNarrative(hkExternalUUID: ids[1].uuidString, dateKey: "2026-06-02", note: "Better.", symptomFlags: [])
        ])

        #expect(try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records) == 2)

        let readBack = try records.allRecords(contentKey: key).records
        #expect(Set(readBack.map(\.id)) == Set(ids))
        #expect(readBack.contains { $0.narrative?.note == "Cramps, low energy." && $0.origin == .restored })
    }

    @MainActor
    @Test func applyRestoredPeriodThrowsWhenContentKeyLocked() throws {
        let store = makeTestStore() // no hub key wired → no content key
        let records = PeriodBackupDevice.makeRecordStore()
        let data = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "uuid-1", dateKey: "2026-06-01", note: "x", symptomFlags: [])
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.self) {
            try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records)
        }
        #expect(try records.recordCount() == 0)
    }

    /// WI-5's duplicate hazard, closed the v2 way: the merge is keyed by record id, so restoring the
    /// same set twice changes nothing the second time and duplicates nothing.
    @MainActor
    @Test func applyRestoredPeriodDoesNotDuplicateOnSecondRestore() throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let records = PeriodBackupDevice.makeRecordStore()
        let data = try PeriodBackupFormat.encodeChunk(
            index: 0, records: [PeriodBackupDevice.record(day: 1), PeriodBackupDevice.record(day: 2)], writer: "w", total: 2
        )

        #expect(try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records) == 2)
        #expect(try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records) == 0,
                "the second merge finds nothing new")
        #expect(try records.recordCount() == 2)
    }

    /// The merge never regresses a block: a local copy of the same entry whose note was edited AFTER
    /// the backup keeps the edit, while the backup completes the block the local copy did not know.
    @MainActor
    @Test func applyRestoredPeriodNeverRegressesANewerLocalBlock() throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let records = PeriodBackupDevice.makeRecordStore()
        records.attachVisibilityGate { true }
        let backedUp = PeriodBackupDevice.record(day: 1, note: "Before the edit.")
        var local = backedUp
        local.clinical = nil
        local.narrative?.note = "After the edit."
        local.narrative?.updatedAt = backedUp.createdAt.addingTimeInterval(3_600)
        try records.insert(local, contentKey: key)
        let data = try PeriodBackupFormat.encodeChunk(index: 0, records: [backedUp], writer: "w", total: 1)

        #expect(try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records) == 1)

        let merged = try #require(try records.allRecords(contentKey: key).records.first)
        #expect(merged.narrative?.note == "After the edit.", "the newer local note survives the older backup")
        #expect(merged.clinical == backedUp.clinical, "the block the local copy did not know is filled in")
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
        // Journal is the probe: the freshness verdict answers before its own store is ever read.
        let outcome = await store.restoreSealedBackupOutcome(payloadType: .journalNarratives)
        #expect(outcome == .skippedStoreNotEmpty)
    }

    /// Positive control: the stricter gate must NOT wrongly block a legitimately blank device. With zero
    /// day rows and empty caches, `isFreshInstallForRestore` still returns true, so the restore is NOT
    /// refused as "store not empty" — it gets past the gate to the next precondition, which with no
    /// content key active is the locked-key refusal. Driven at the write point over an ISOLATED empty
    /// journal store (the retired sensitive-notes payload, then period, used to be this probe; period's
    /// v2 merge restore has no freshness gate at all, and every live payload's default store is the
    /// shared on-device one, which other suites can populate).
    @MainActor
    @Test func restoreNotSkippedOnGenuinelyBlankDevice() throws {
        let store = makeTestStore()
        let journalRepository = JournalNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        let entryDate = Date(timeIntervalSince1970: 1_780_000_000)
        let data = try JSONEncoder().encode([
            JournalNarrative(id: UUID(), dayKey: "2026-06-01", tag: .good, entryDate: entryDate,
                             text: "x", emotions: [], createdAt: entryDate, updatedAt: entryDate)
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.locked) {
            try store.applyRestoredPayload(data, payloadType: .journalNarratives, journalRepository: journalRepository)
        }
    }

    // MARK: - The ambient period restore (v2) through the store's wrappers

    /// Finding #2 of the 2026-07-19 review, the v2 way: a device that is no longer a fresh install
    /// (populated days, meals, journal) still runs the ambient period restore — there is no freshness
    /// gate on a merge. With no CloudKit wired in a unit test it lands on a deferred outcome, but it is
    /// not short-circuited.
    @MainActor
    @Test func theAmbientPeriodRestoreRunsOnADeviceThatIsNoLongerAFreshInstall() async {
        let store = makePopulatedTestStore()
        store.settings.periodTrackingVisible = true
        store.openHubForTesting(contentKey: SymmetricKey(size: .bits256))
        #expect(await store.restorePeriodBackup() != .skippedStoreNotEmpty)
    }

    /// The fail-closed-at-the-decrypt-seam property: the period restore decrypts cycle history and
    /// seals it in, so it refuses while period tracking is hidden — retryable, and recorded as no
    /// status (un-hiding IS the retry).
    @MainActor
    @Test func theAmbientPeriodRestoreRefusesWhilePeriodTrackingHidden() async {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = false
        store.openHubForTesting(contentKey: SymmetricKey(size: .bits256))

        let outcome = await store.restorePeriodBackup()
        #expect(outcome.didRestore == false)
        #expect(outcome.isRetryable)
        #expect(store.sealedBackupRestoreStatus[.periodData] == nil)
    }

    /// The resurrection the latch used to stop, stopped by the resolved marker (design §5.3): once this
    /// install's period restore has resolved, the ambient restore never runs again — so entries the
    /// user deleted can never come back from the stale cloud copy by an un-hide or a settle. Benign:
    /// no banner, no network.
    @MainActor
    @Test func aResolvedInstallNeverRestoresAmbientlyAgain() async {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        store.openHubForTesting(contentKey: SymmetricKey(size: .bits256))
        store.periodBackupLedger.markRestoreResolved()

        let outcome = await store.restorePeriodBackup()
        #expect(outcome == .skippedStoreNotEmpty)
        #expect(outcome.needsAttention == false)
        #expect(store.sealedBackupRestoreStatus[.periodData] == nil)
    }

    /// The marker's one-time migration (design §5.3): an install that already held cycle data — its
    /// legacy `fernlet.menstrualNarrative.everStored` latch is set — had its ambient restore closed by
    /// that latch, and keeps it closed; the seed is read once and written, never read again.
    @MainActor
    @Test func theRestoreMarkerSeedsOnceFromTheLegacyLatch() {
        let defaults = isolatedDefaults()
        let latchReads = ReadCounter()
        let inUse = PeriodBackupLedger(defaults: defaults, legacyLatch: { latchReads.value += 1; return true })
        #expect(inUse.isRestoreResolved, "an install that held cycle data stays resolved")
        #expect(inUse.isRestoreResolved)
        #expect(latchReads.value == 1, "the latch is read once, then never again for period")

        let fresh = PeriodBackupLedger(defaults: isolatedDefaults(), legacyLatch: { false })
        #expect(!fresh.isRestoreResolved)
        fresh.markRestoreResolved()
        #expect(fresh.isRestoreResolved)
        fresh.reopenRestore()
        #expect(!fresh.isRestoreResolved, "reopened is an explicit false: the seed never runs again")
        #expect(!fresh.restoreResolvedIsSet)
    }

    /// The write point honors a cancelled surrounding Task: a settle suspended in its CloudKit fetch
    /// when "delete everything" cancels it must not resume and merge cycle records into the
    /// just-emptied store.
    @MainActor
    @Test func applyRefusesToWriteInsideACancelledTask() async throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let records = PeriodBackupDevice.makeRecordStore()
        let data = try PeriodBackupFormat.encodeChunk(index: 0, records: [PeriodBackupDevice.record(day: 1)], writer: "w", total: 1)

        let restore = Task { () -> Result<Int, Error> in
            // Deterministically wait out the cancel below — models the settle suspended in its fetch
            // when "delete everything" cancels it.
            while !Task.isCancelled { await Task.yield() }
            return Result { try store.applyRestoredPayload(data, payloadType: .periodData, cycleRecordStore: records) }
        }
        restore.cancel()

        guard case .failure(let error) = await restore.value else {
            Issue.record("a cancelled restore still wrote \((try? records.recordCount()) ?? -1) records")
            return
        }
        #expect(error is CancellationError)
        #expect(try records.recordCount() == 0)
    }

    /// The journal keeps the v1 no-clobber gate, which every journal restore funnels through — the
    /// AMBIENT `.freshInstall` pass included: a completed delete-all makes the device classify as fresh
    /// again, and the journal's divergence latch (set by its `deleteAll`) is what stops a backup that
    /// survived a failed chunk delete from restoring the wiped journal at the next launch.
    @MainActor
    @Test func freshInstallScopedApplyRefusesADivergedEmptyJournalStore() throws {
        let store = makeTestStore()   // blank → classifies as a fresh install
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let repository = JournalNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        let entryDate = Date(timeIntervalSince1970: 1_780_000_000)
        let entry = JournalNarrative(id: UUID(), dayKey: "2026-04-01", tag: .good, entryDate: entryDate,
                                     text: "Wiped.", emotions: [], createdAt: entryDate, updatedAt: entryDate)
        try repository.insert(entry, contentKey: key)
        try repository.deleteAll()
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative)

        var stale = entry
        stale.id = UUID()
        stale.text = "Stale cloud copy."
        #expect(throws: FernletStore.SealedBackupWiringError.storeNotEmpty) {
            try store.applyRestoredPayload(
                try JSONEncoder().encode([stale]), payloadType: .journalNarratives,
                journalRepository: repository, scope: .freshInstall
            )
        }
        #expect(try repository.narrativeCount() == 0)
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
        store.openHubForTesting(contentKey: key)

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
        store.openHubForTesting(contentKey: key)

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
        store.openHubForTesting(contentKey: key)

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

    // MARK: - Period backup v2 restore through the coordinator (design §9.10; I15, I16)

    /// I15: the ambient period restore runs iff this install's restore is unresolved AND no app-lock
    /// reset holds it for the owner. Held: nothing written, nothing recorded. Unresolved: it merges,
    /// resolves the marker and accepts the set. Resolved: it never runs again.
    @MainActor
    @Test func theAmbientPeriodRestoreRunsOnlyWhileUnresolvedAndNotHeld() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud))

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        second.host.sealedBackupRestoreAwaitsOwner = true
        #expect(await second.coordinator.restorePeriodBackup() == .deferredTransient)
        #expect(try second.records.recordCount() == 0)
        #expect(second.host.recordedOutcomes[.periodData] == nil)
        #expect(!second.host.periodBackupLedger.isRestoreResolved)

        second.host.sealedBackupRestoreAwaitsOwner = false
        #expect(await second.coordinator.restorePeriodBackup() == .restored(1))
        #expect(second.host.periodBackupLedger.isRestoreResolved)
        #expect(second.host.periodBackupLedger.acceptedHead == head, "the merged set is the accepted one")

        try second.records.deleteAll()
        #expect(await second.coordinator.restorePeriodBackup() == .skippedStoreNotEmpty)
        #expect(try second.records.recordCount() == 0, "a deleted entry never comes back ambiently")
    }

    /// Fail closed at the decrypt seam, for every caller of the period restore — the bare outcome
    /// wrapper included: while period tracking is hidden, or with no Private tab key, the cycle set in
    /// iCloud is never even fetched and opened (the rollback mark it would have raised stays at 0).
    @MainActor
    @Test func thePeriodRestoreNeverOpensTheCloudSetWhileHiddenOrKeyless() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        second.host.isPeriodTrackingVisible = false
        #expect(await second.coordinator.restoreSealedBackupOutcome(payloadType: .periodData) == .deferredTransient)
        second.host.isPeriodTrackingVisible = true
        second.host.sealedBackupContentKey = nil
        #expect(await second.coordinator.restoreSealedBackupOutcome(payloadType: .periodData) == .deferredLocked)
        #expect(SealedBackupGenerationStore(defaults: second.generationDefaults).lastSeen(for: .periodData) == 0,
                "nothing was fetched and opened")
    }

    /// I15: the marker resolves only on a non-retryable outcome that pulled the set or proved there is
    /// none. No escrow key yet stays unresolved (retried at the next settle); a set this account's key
    /// cannot open stays unresolved with its needs-attention status; an empty cloud resolves.
    @MainActor
    @Test func theRestoreMarkerResolvesOnlyWhenTheRestoreLandsForGood() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let noEscrow = "com.fernlet.period-v2.noescrow.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: noEscrow) }
        let notSynced = PeriodBackupDevice(cloud: cloud, writer: "notSynced", keychainService: noEscrow)
        #expect(await notSynced.coordinator.restorePeriodBackup() == .deferredKeyNotSynced)
        #expect(!notSynced.host.periodBackupLedger.isRestoreResolved)

        let otherAccount = "com.fernlet.period-v2.otheraccount.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: otherAccount) }
        let identity = IdentityService(keychainService: otherAccount)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        let stranger = PeriodBackupDevice(cloud: cloud, writer: "stranger", keychainService: otherAccount)
        #expect(await stranger.coordinator.restorePeriodBackup() == .notRecognized)
        #expect(!stranger.host.periodBackupLedger.isRestoreResolved)
        #expect(stranger.host.recordedOutcomes[.periodData] == .notRecognized)

        let emptyCloud = try PeriodBackupDevice.makeCloud()
        defer { emptyCloud.tearDown() }
        let alone = PeriodBackupDevice(cloud: emptyCloud, writer: "alone")
        #expect(await alone.coordinator.restorePeriodBackup() == .nothingToRestore)
        #expect(alone.host.periodBackupLedger.isRestoreResolved)
    }

    /// I15: at a Cycle settle with nothing to restore from on this install — the period backup off, or
    /// iCloud sync off — the restore is marked resolved without any network work.
    @MainActor
    @Test func theSettleResolvesTheRestoreWhenThereIsNothingToRestoreFrom() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let backupOff = PeriodBackupDevice(cloud: cloud, writer: "a", preferences: StoragePreferences(iCloudSyncEnabled: true))
        await backupOff.coordinator.settlePeriodBackup()
        #expect(backupOff.host.periodBackupLedger.isRestoreResolved)

        let syncOff = PeriodBackupDevice(cloud: cloud, writer: "b", preferences: StoragePreferences(sealedBackupPeriodEnabled: true))
        syncOff.host.sealedBackupContentKey = nil
        await syncOff.coordinator.settlePeriodBackup()
        #expect(!syncOff.host.periodBackupLedger.isRestoreResolved, "only a hub settle (the key live) decides")
        syncOff.host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        await syncOff.coordinator.settlePeriodBackup()
        #expect(syncOff.host.periodBackupLedger.isRestoreResolved)
    }

    /// I16, restore half: a restore is a merge that never deletes or regresses an openable local record
    /// — a local-only entry stays, a local entry edited after the backup keeps its edit, and the
    /// backup's other entries arrive. A v1 narrative merges with the same entry's clinical-only record
    /// (imported from Apple Health) into one record carrying both blocks.
    @MainActor
    @Test func theRestoreMergesWithoutDeletingOrRegressingLocalRecords() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let shared = PeriodBackupDevice.record(day: 1, note: "In the backup.")
        let backedUpOnly = PeriodBackupDevice.record(day: 2)
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([shared, backedUpOnly])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        var edited = shared
        edited.narrative?.note = "Edited here later."
        edited.narrative?.updatedAt = shared.createdAt.addingTimeInterval(86_400)
        let localOnly = PeriodBackupDevice.record(day: 3)
        try second.seed([edited, localOnly])

        #expect(await second.coordinator.restorePeriodBackup() == .restored(1))
        let after = try second.records.allRecords(contentKey: second.key).records
        #expect(Set(after.map(\.id)) == [shared.id, backedUpOnly.id, localOnly.id])
        #expect(after.first { $0.id == shared.id }?.narrative?.note == "Edited here later.")
        #expect(after.first { $0.id == localOnly.id } == localOnly)
    }

    /// v1 sets keep restoring after the update: their narratives become narrative-only records under
    /// their legacy ids, so one merges with the clinical-only record the legacy import built from the
    /// same entry's Apple Health samples.
    @MainActor
    @Test func aV1SetRestoresAndMergesWithTheSameEntrysImportedRecord() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let legacyID = UUID()
        let writer = PeriodBackupDevice(cloud: cloud, writer: "old")
        try await writer.writeV1Set([MenstrualNarrative(hkExternalUUID: legacyID.uuidString, dateKey: "2026-05-01", note: "From the old backup.")])

        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone")
        var imported = PeriodBackupDevice.record(day: 1)
        imported.id = legacyID
        imported.narrative = nil
        imported.origin = .importedLegacy
        try phone.seed([imported])

        #expect(await phone.coordinator.restorePeriodBackup() == .restored(1))
        let merged = try #require(try phone.records.allRecords(contentKey: phone.key).records.first)
        #expect(merged.id == legacyID)
        #expect(merged.clinical == imported.clinical && merged.narrative?.note == "From the old backup.")
        #expect(phone.host.periodBackupLedger.acceptedHead == PeriodBackupHead(writer: PeriodBackupHead.v1Writer, generation: 1))
    }

    /// After an app-lock reset (design §5.3, Q14): nothing restores and nothing exports until the
    /// device owner's "Restore". Then the history comes back, the pre-reset copy is settled, and only
    /// then may this iPhone back up over it — with the merged history, never the post-reset store alone.
    @MainActor
    @Test func theOwnersRestoreBringsThePeriodHistoryBackBeforeAnythingIsBackedUpOverIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let before = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let history = PeriodBackupDevice.record(day: 1)
        try before.seed([history])
        #expect(await before.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let preReset = cloud.sealedRecordIdentities

        let after = PeriodBackupDevice(cloud: cloud, writer: "phone")
        after.host.restoreHold.hold(keepingCopiesFrom: PeriodBackupDevice.backupOn)
        try after.seed([PeriodBackupDevice.record(day: 9)])
        await after.coordinator.settlePeriodBackup()
        #expect(cloud.sealedRecordIdentities == preReset, "held: nothing restored, nothing written over it")
        #expect(try after.records.recordCount() == 1)

        await after.coordinator.releaseRestoreHoldForOwner()
        #expect(!after.host.sealedBackupRestoreAwaitsOwner)
        #expect(!after.host.sealedBackupKeepsPreResetCopy(of: .periodData), "the restore landed: the copy is settled")
        #expect(try after.records.recordCount() == 2, "the pre-reset history is back")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try after.records.allIDs()),
                "and the backup now holds the merged history")
    }

    /// Review U5-backup-v2-C-U5-1 / L-U5-R2: "nothing to restore from" is not "nothing up there"
    /// while an app-lock reset keeps the period backup's pre-reset copy. With iCloud sync off at the
    /// Cycle settle the restore used to be marked resolved — and then the owner's later "Restore"
    /// found it resolved and restored nothing, while the hold (waiting for that restore) kept the
    /// period backup from ever uploading again. The marker now stays open, and the history comes back
    /// once sync is on and the owner asks.
    @MainActor
    @Test func aResetWithICloudSyncOffStillRestoresThePreResetHistoryLater() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let before = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try before.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await before.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let after = PeriodBackupDevice(cloud: cloud, writer: "phone")
        after.host.restoreHold.hold(keepingCopiesFrom: PeriodBackupDevice.backupOn)
        try after.seed([PeriodBackupDevice.record(day: 9)])
        after.preferences = StoragePreferences(sealedBackupPeriodEnabled: true, sealedBackupPeriodReuploadDeferred: true)
        await after.coordinator.settlePeriodBackup()
        #expect(!after.host.periodBackupLedger.isRestoreResolved, "sync off: the pre-reset copy is out of reach, not gone")

        after.preferences = PeriodBackupDevice.backupOn
        await after.coordinator.releaseRestoreHoldForOwner()
        #expect(try after.records.recordCount() == 2, "the pre-reset history is back")
        #expect(!after.host.sealedBackupKeepsPreResetCopy(of: .periodData), "and the hold has nothing left to keep")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try after.records.allIDs()),
                "so the period backup uploads again, with the merged history")
    }

    /// Review U5-backup-v2-L-U5-R2, the release half: the owner's "Restore" reopens this install's
    /// period restore while the hold keeps the period copy, so no marker resolved in the meantime can
    /// stand between the owner and the pre-reset history. A period copy the hold does not keep leaves
    /// the marker alone.
    @MainActor
    @Test func theOwnersRestoreReopensAResolvedPeriodRestoreOnlyWhileItsCopyIsKept() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let before = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try before.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await before.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let after = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        after.host.restoreHold.hold(keepingCopiesFrom: PeriodBackupDevice.backupOn)
        await after.coordinator.releaseRestoreHoldForOwner()
        #expect(try after.records.recordCount() == 1, "the kept copy is restored although the marker read resolved")

        let other = PeriodBackupDevice(cloud: cloud, writer: "other", resolved: true)
        other.host.restoreHold.hold(keepingCopiesFrom: StoragePreferences())
        await other.coordinator.releaseRestoreHoldForOwner()
        #expect(other.host.periodBackupLedger.isRestoreResolved, "nothing kept: the resolved restore stays resolved")
        #expect(try other.records.recordCount() == 0)
    }

    /// The new-iPhone scenario end to end (design §9.10 consequence 2, §4.9): an iPhone set up from a
    /// device backup arrives with the sealed rows of the old iPhone (sealed under a key that never
    /// migrates, so dead here) and the old iPhone's bookkeeping (the marker resolved, its accepted
    /// head). The "can't open" check names the rows and clears that bookkeeping on Remove; the next
    /// Cycle settle then merges the backup in, re-sealed under this iPhone's key, and backs up again.
    @MainActor
    @Test func aNewIPhoneFromADeviceBackupRemovesTheDeadRowsAndRestoresTheBackup() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = PeriodBackupDevice(cloud: cloud, writer: "old", resolved: true)
        let history = [PeriodBackupDevice.record(day: 1), PeriodBackupDevice.record(day: 2)]
        try old.seed(history)
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let new = PeriodBackupDevice(cloud: cloud, writer: "new")
        try new.seed(history, key: old.key)
        new.host.periodBackupLedger.markRestoreResolved()
        new.host.periodBackupLedger.recordAcceptedHead(try #require(old.host.periodBackupLedger.acceptedHead))
        let entries = SealedPriorEntryStore(
            controller: new.controller,
            latchDefaults: new.host.periodBackupLedger.defaults,
            intimacyStore: IntimacyLogStore(repository: IntimacyLogRepository(controller: new.controller, defaults: new.host.periodBackupLedger.defaults)),
            restoresAfterRemoval: { _ in true }
        )
        #expect(try entries.cycleEntryCount() == 2)
        #expect(entries.hasBackupBookkeeping())

        // The card's Remove: exactly the dead rows go, then the bookkeeping that spoke for the old key.
        try entries.removeCycleEntries()
        entries.clearBackupBookkeeping()
        #expect(!new.host.periodBackupLedger.isRestoreResolved)
        #expect(new.host.periodBackupLedger.acceptedHead == nil)

        await new.coordinator.settlePeriodBackup()
        let restored = try new.records.allRecords(contentKey: new.key)
        #expect(restored.isFullyOpen && restored.records.count == 2, "the history is back, under this iPhone's key")
        #expect(new.host.periodBackupLedger.isRestoreResolved)
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.writer == "new", "and this iPhone backs it up again")
    }
}

/// A mutable count a `@MainActor` closure can bump.
@MainActor
final class ReadCounter {
    var value = 0
}
