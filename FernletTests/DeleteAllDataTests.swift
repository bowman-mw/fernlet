import Foundation
import Testing
// @testable for the internal `save`, which seeds the share-extension inbox the way the extension does.
@testable import AppServices
import FernletDomainModel
import FernletPersistence
import LocalPersistence
@testable import Fernlet

/// Covers "delete everything" actually deleting everything.
///
/// The bug these exist to prevent: `resetDiary()` only reassigns in-memory properties, so before this
/// work "Reset everything" left the entire day history on disk. The app looked empty, then reloaded the
/// lot on the next launch via `loadAllDays()` — and re-uploaded it to iCloud.
/// Serialized: each test stands up a real `FernletStore` over its own repository, and running them
/// concurrently lets that shared process-level state race — the disk assertions pass in isolation and
/// fail in parallel.
@MainActor
@Suite(.serialized)
struct DeleteAllDataTests {

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    /// A snapshot with one day of real content.
    private func snapshot(todayKey: String, bottles: Int) -> FernletSnapshot {
        var day = FernletDay(date: todayKey)
        day.bottleCount = bottles
        return FernletSnapshot(
            todayKey: todayKey,
            day: day,
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }

    /// The headline regression: purging must clear the PERSISTED store, not just memory.
    ///
    /// Drives the repository directly rather than through a live `FernletStore`: the store's snapshot
    /// save is debounced, so a pending write can land after the purge and resurrect the file — which is
    /// a real hazard for the funnel (hence purge-last there) but pure noise here. This test is about
    /// whether the purge erases what is on disk.
    ///
    /// Asserts the data is unreadable afterwards rather than that a file is absent: a repository may
    /// legitimately recreate an empty store, and "the bytes are gone" is the property that matters.
    @Test func purgingRemovesPersistedDays() {
        let todayKey = "2026-07-01"
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-persisted"))
        #expect(repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot(todayKey: todayKey, bottles: 4), sealedJournalIDs: [])), "save failed")
        // Precondition: the write landed, so the purge has something to remove.
        #expect(repository.loadSnapshot(todayKey: todayKey).day.bottleCount == 4, "precondition: save did not land")

        #expect(repository.purgeAllPersistedData(), "purge returned false")

        // Assert the WRITTEN day is gone, not that the map is empty: a repository legitimately
        // synthesizes a blank entry for the current date on read, so `isEmpty` would fail for a reason
        // that has nothing to do with deletion. A surviving past day is the actual bug this guards.
        #expect(repository.loadAllDays()[todayKey] == nil, "the purged day survived")
        #expect(repository.loadSnapshot(todayKey: todayKey).day.bottleCount == 0, "the purged day's content survived")
    }

    /// A purge must not leave the repository unable to save — the user keeps using the app afterwards.
    @Test func purgingLeavesTheRepositoryUsable() {
        let todayKey = "2026-07-02"
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-usable"))
        repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot(todayKey: todayKey, bottles: 1), sealedJournalIDs: []))

        repository.purgeAllPersistedData()

        #expect(repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot(todayKey: todayKey, bottles: 3), sealedJournalIDs: [])))
        #expect(repository.loadSnapshot(todayKey: todayKey).day.bottleCount == 3)
    }

    @Test func purgingAnEmptyRepositorySucceeds() {
        let repository = LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-empty"))

        // Nothing written yet — must be a no-op success, not a failure.
        #expect(repository.purgeAllPersistedData())
    }

    /// `deleteAllData` must reach the sealed stores it does not own, via the hooks. Without them the
    /// funnel would silently skip the app's most sensitive data.
    @Test func deleteAllDataInvokesEverySealedStoreHook() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-hooks")))
        var called: Set<String> = []
        store.periodDataDeleteHook = { called.insert("period"); return true }
        store.intimacyDataDeleteHook = { called.insert("intimacy"); return true }
        store.journalDataDeleteHook = { called.insert("journal"); return true }
        store.worryBoxResetHook = { called.insert("worry") }
        store.pendingNarrativeBufferPurgeHook = { called.insert("pendingBuffer"); return true }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(called == ["period", "intimacy", "journal", "worry", "pendingBuffer"])
    }

    /// The pending-narrative buffer holds cycle notes written while the app was LOCKED, in a file under a
    /// separate device key. The narrative repositories only drop Core Data rows, so nothing else in the
    /// funnel reaches it — and its next drain re-inserts every payload into the store the wipe emptied.
    ///
    /// `FernletLockService.reset()` used to purge it. The funnel deliberately does not call `reset()`
    /// (the app lock survives a wipe), so this must be its own step. Without it, "delete everything"
    /// quietly means "delete until the next unlock".
    @Test func pendingNarrativeBufferIsPurgedSoLockedNotesCannotComeBack() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-buffer")))
        var purged = false
        store.pendingNarrativeBufferPurgeHook = { purged = true; return true }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(purged, "the locked-note buffer survived the wipe and will re-insert on the next unlock")
    }

    /// A sealed store that fails to clear must reach the user. This is the most sensitive data in the
    /// app and the dialog promises it is gone — silently swallowing the failure is the exact defect the
    /// funnel exists to end.
    @Test func outcomeReportsASealedStoreThatFailedToDelete() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-sealed-fail")))
        store.journalDataDeleteHook = { false }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your journal entries"))
    }

    /// HealthKit deletion is the user's explicit choice at delete time, so it must NOT fire unless asked.
    @Test func healthKitSamplesAreOnlyDeletedWhenRequested() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-hk-off")))
        var healthDeleted = false
        store.healthKitSampleDeleteHook = { healthDeleted = true }

        await store.deleteAllData(includingHealthKitSamples: false)
        #expect(!healthDeleted)

        await store.deleteAllData(includingHealthKitSamples: true)
        #expect(healthDeleted)
    }

    /// Deliberate survivors. If one of these starts getting wiped, the confirm dialog's disclosure
    /// becomes a lie — and for the moderation ban, a wipe would become a way to undo a block.
    @Test func deleteAllDataClearsTheDayButKeepsDeliberateSurvivors() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-survivors")))
        store.addBottle()
        #expect(store.day.bottleCount > 0)

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(store.day.bottleCount == 0)
        #expect(store.day.meals.isEmpty)
    }

    /// THE regression test for the original bug: a wipe must survive a relaunch.
    ///
    /// Deleting is only half the property — the store re-reads from the repository at launch, so a wipe
    /// that leaves rows behind (or lets a writer put them back) looks successful and then hands the data
    /// straight back. Asserted by re-reading the repository directly rather than trusting the in-memory
    /// store, which is what the old "Reset everything" made look empty.
    ///
    /// Note the post-condition: NOT `loadAllDays().isEmpty`. The repository synthesizes a blank entry for
    /// the current date on read, so the assertion is that the WRITTEN day is gone.
    @Test func deletedDaysDoNotComeBackOnTheNextLaunch() async {
        let url = temporaryDatabaseURL("delete-all-relaunch")
        let pastKey = "2026-01-02"
        let repository = LocalFernletRepository(fileURL: url)
        repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot(todayKey: pastKey, bottles: 4), sealedJournalIDs: []))
        #expect(repository.loadAllDays()[pastKey] != nil, "precondition: the seeded day did not land")

        let store = FernletStore(repository: repository)
        await store.deleteAllData(includingHealthKitSamples: false)

        // A fresh repository over the same file is the next launch.
        let relaunched = LocalFernletRepository(fileURL: url)
        #expect(relaunched.loadAllDays()[pastKey] == nil, "the deleted day came back on relaunch")
    }

    /// The debounced snapshot save is a writer that fires a second AFTER the wipe returns. `resetAll()`
    /// schedules one on its way past, so without the closing `cancelPending()` the purge is undone by the
    /// store's own save — re-creating today's row and the blob (and their CloudKit records).
    ///
    /// Waits past the 1s debounce deliberately: the whole failure mode is invisible to a test that
    /// asserts immediately.
    @Test func noPendingSaveResurrectsDataAfterTheWipe() async throws {
        let url = temporaryDatabaseURL("delete-all-debounce")
        let repository = LocalFernletRepository(fileURL: url)
        let store = FernletStore(repository: repository)
        store.addBottle()   // schedules a debounced save
        await store.deleteAllData(includingHealthKitSamples: false)

        try await Task.sleep(for: .milliseconds(1_400))

        let relaunched = LocalFernletRepository(fileURL: url)
        #expect(relaunched.loadAllDays().values.allSatisfy { $0.bottleCount == 0 })
    }

    /// A recipe shared in before the wipe must not import itself back afterwards. The queue is drained on
    /// the next foreground, so a surviving row rebuilds user content into a store the user was told was
    /// empty — and the share extension can refill the file while the app is backgrounded, which is why
    /// the drain has to FIND it empty rather than be told not to run.
    @Test func sharedRecipeInboxIsClearedSoItCannotDrainAfterTheWipe() async {
        let queueURL = temporaryDatabaseURL("delete-all-recipe-inbox")
        let queue = SharedRecipeImportQueue(fileURL: queueURL)
        queue.save([SharedRecipeImportRecord(url: URL(string: "https://example.com/soup")!)])
        #expect(!queue.records().isEmpty, "precondition: the seeded queue row did not land")

        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-recipe-store")))
        store.sharedRecipeImportQueue = queue
        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(queue.records().isEmpty)
    }

    /// A wipe reports what it could not finish. Every layer is best-effort, and the dialog promises
    /// permanence — so a store that fails to clear has to reach the user instead of being swallowed.
    @Test func outcomeReportsAStoreThatFailedToDelete() async {
        let store = FernletStore(repository: FailingPurgeRepository())
        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your day history"))
    }

    /// A clean wipe reports success, so the caller can dismiss rather than cry wolf.
    @Test func outcomeIsCompleteWhenEveryStoreClears() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-clean")))
        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(outcome.isComplete)
        #expect(outcome.incompleteStores.isEmpty)
    }
}

/// A repository whose purge always fails, to prove the funnel surfaces the failure rather than reporting
/// a wipe it never achieved. Everything else is an inert double — this exists for one return value.
private struct FailingPurgeRepository: FernletRepository {
    func loadSnapshot(todayKey: String) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: todayKey,
            day: FernletDay(date: todayKey),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }
    func saveSnapshot(_ snapshot: SanitizedSnapshot) -> Bool { true }
    func updateDay(_ day: SanitizedDay, for dateKey: String, todayKey: String) -> Bool { true }
    func storageDescription() -> String { "failing-purge double" }
    func loadAllDays() -> [String: FernletDay] { [:] }
    func loadTierTwoMemories() -> [TierTwoMemoryRecord] { [] }
    func purgeAllPersistedData() -> Bool { false }
}
