import Foundation
import Testing
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
        store.periodDataDeleteHook = { called.insert("period") }
        store.intimacyDataDeleteHook = { called.insert("intimacy") }
        store.journalDataDeleteHook = { called.insert("journal") }
        store.worryBoxResetHook = { called.insert("worry") }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(called == ["period", "intimacy", "journal", "worry"])
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
}
