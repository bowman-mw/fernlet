import Foundation
import Testing
// @testable for the internal `save`, which seeds the share-extension inbox the way the extension does.
@testable import AppServices
import FernletDomainModel
import FernletPersistence
import HealthKitGateway
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
        var worryCallCount = 0
        store.periodDataDeleteHook = { called.insert("period"); return true }
        store.intimacyDataDeleteHook = { called.insert("intimacy"); return true }
        store.journalDataDeleteHook = { called.insert("journal"); return true }
        store.worryBoxResetHook = { called.insert("worry"); worryCallCount += 1; return true }
        store.pendingNarrativeBufferPurgeHook = { called.insert("pendingBuffer"); return true }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(called == ["period", "intimacy", "journal", "worry", "pendingBuffer"])
        // Exactly once: the funnel used to invoke the worry hook itself AND again via `resetAll()`.
        // One purge per wipe — the `resetAll` one, so a standalone reset keeps it.
        #expect(worryCallCount == 1)
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
        store.healthKitSampleDeleteHook = { healthDeleted = true; return .complete }

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

    /// The plaintext "export my data" dump must not survive the wipe. `writeDataExportFile()` writes the
    /// user's whole decrypted dataset UNENCRYPTED to tmp/ for the share sheet, and iOS only reclaims tmp/
    /// under storage pressure — so a user who exported and then deleted everything could otherwise be left
    /// with a full plaintext copy on disk after a dialog that told them it was gone.
    @Test func exportedDataFileIsSweptByTheWipe() async throws {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-export")))
        // Wire the sealed hooks so the wipe is otherwise complete (an unwired hook now reports failure);
        // this test asserts the export sweep specifically keeps a clean wipe complete.
        wireSucceedingSealedHooks(store)
        let exportURL = try store.writeDataExportFile()
        #expect(FileManager.default.fileExists(atPath: exportURL.path), "precondition: the export file was not written")

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!FileManager.default.fileExists(atPath: exportURL.path), "the plaintext export survived the wipe")
        // The sweep is one of the stores the funnel reports on, so a clean wipe stays complete.
        #expect(outcome.isComplete)
    }

    /// A legacy export written flat into tmp/ (the location before the dedicated exports directory) is
    /// still swept, so an app updated across that change can't strand an old plaintext dump.
    @Test func legacyFlatExportFileIsSweptByTheWipe() async throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fernlet-data-2026-01-01.json")
        try Data("{}".utf8).write(to: legacyURL, options: [.atomic, .completeFileProtection])
        #expect(FileManager.default.fileExists(atPath: legacyURL.path), "precondition: the legacy file was not written")

        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-legacy-export")))
        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path), "the legacy plaintext export survived the wipe")
    }

    /// The trainer/nutritionist summary is the same kind of plaintext liability as the data export —
    /// injury notes, sickness days, wellbeing scores in the clear — and it writes into the same exports
    /// directory precisely so the wipe covers it by construction rather than by anyone remembering it.
    @Test func trainerExportFileIsSweptByTheWipe() async throws {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-trainer-export")))
        // Wire the sealed hooks so the wipe is otherwise complete (an unwired hook now reports failure);
        // this test asserts the export sweep specifically keeps a clean wipe complete.
        wireSucceedingSealedHooks(store)
        let exportURL = try #require(store.writeTrainerExportFile(options: .coreOnly))
        #expect(FileManager.default.fileExists(atPath: exportURL.path), "precondition: the trainer export file was not written")

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!FileManager.default.fileExists(atPath: exportURL.path), "the plaintext trainer export survived the wipe")
        // The sweep is one of the stores the funnel reports on, so a clean wipe stays complete.
        #expect(outcome.isComplete)
    }

    /// A legacy trainer summary written flat into tmp/ (the location before the trainer writer moved
    /// into the exports directory) is still swept, so an app updated across that change can't strand an
    /// old plaintext summary.
    @Test func legacyFlatTrainerExportFileIsSweptByTheWipe() async throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fernlet-training-2026-01-01.json")
        try Data("{}".utf8).write(to: legacyURL, options: [.atomic, .completeFileProtection])
        #expect(FileManager.default.fileExists(atPath: legacyURL.path), "precondition: the legacy file was not written")

        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-legacy-trainer-export")))
        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path), "the legacy plaintext trainer export survived the wipe")
    }

    /// A clean wipe reports success, so the caller can dismiss rather than cry wolf.
    @Test func outcomeIsCompleteWhenEveryStoreClears() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-clean")))
        // A nil sealed hook now counts as a failure (an unwired funnel can't claim it cleared a store it
        // never called), so a "clean wipe" must supply them all.
        wireSucceedingSealedHooks(store)

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(outcome.isComplete)
        #expect(outcome.incompleteStores.isEmpty)
    }

    /// A NIL (unwired) sealed hook is a failure, not a silent skip. The old `== false` treated nil as
    /// success, so an unwired funnel would quietly miss the app's most sensitive rows and still report a
    /// complete wipe. Here the journal hook is left nil while the rest succeed.
    @Test func outcomeReportsAnUnwiredSealedHookAsIncomplete() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-nil-hook")))
        store.periodDataDeleteHook = { true }
        store.intimacyDataDeleteHook = { true }
        store.pendingNarrativeBufferPurgeHook = { true }
        // journalDataDeleteHook deliberately left nil — the unwired case.

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your journal entries"))
    }

    /// The HealthKit delete leg used to be the one hook typed Void, so a failure there was swallowed and
    /// a wipe the dialog called complete could leave Fernlet's Apple Health samples behind. Now it returns
    /// an outcome, and `.failed` must surface.
    @Test func outcomeReportsWhenHealthKitDeleteFails() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-hk-fail")))
        wireSucceedingSealedHooks(store)
        store.healthKitSampleDeleteHook = { .failed }

        let outcome = await store.deleteAllData(includingHealthKitSamples: true)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your Apple Health entries"))
    }

    /// Revoked Health share access is NOT a plain failure: the samples Fernlet wrote remain in Health
    /// and no retry from Fernlet can remove them — only the Health app can. The old skip-list treated
    /// denial as an expected skip, so the wipe reported COMPLETE while the samples remained (the silent
    /// failure this funnel exists to end). The outcome must be incomplete with the actionable label,
    /// not the generic one that would invite a doomed retry.
    @Test func outcomeReportsRevokedHealthAccessWithTheActionableLabel() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-hk-revoked")))
        wireSucceedingSealedHooks(store)
        store.healthKitSampleDeleteHook = { .accessRevoked }

        let outcome = await store.deleteAllData(includingHealthKitSamples: true)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains(
            "your Apple Health entries (Fernlet's Health access is turned off — remove them in the Health app)"
        ))
        #expect(!outcome.incompleteStores.contains("your Apple Health entries"),
                "revoked access must not ALSO show the generic label — the retry it invites can only fail")
    }

    /// The Worry Box hook used to be the one enumerated sealed store typed Void, so a failed (or
    /// unwired) purge was swallowed while the dialog promised "Worry Box notes" by name. A false must
    /// surface like every other sealed hook.
    @Test func outcomeReportsAWorryBoxPurgeThatFailed() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-worry-fail")))
        wireSucceedingSealedHooks(store)
        store.worryBoxResetHook = { false }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your Worry Box notes"))
    }

    /// A NIL (unwired) Worry Box hook is a failure, not a silent skip — same rule as the other sealed
    /// hooks: an unwired funnel can't claim it cleared a store it never called.
    @Test func outcomeReportsAnUnwiredWorryBoxHookAsIncomplete() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-worry-nil")))
        wireSucceedingSealedHooks(store)
        store.worryBoxResetHook = nil

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your Worry Box notes"))
    }

    /// The storage-preferences reset was the last nil-silent hook in the funnel: an unwired run left
    /// Health grants and backup flags as they were while the wipe reported complete.
    @Test func outcomeReportsAnUnwiredStoragePreferencesHookAsIncomplete() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-prefs-nil")))
        wireSucceedingSealedHooks(store)
        store.storagePreferencesResetHook = nil

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your storage settings"))
    }

    /// A single store can be named by two independent legs — the sealed cycle-notes rows and the
    /// locked-note buffer both purge "your cycle notes". Both failing must still list it ONCE, or the
    /// failure alert reads "…and your cycle notes and your cycle notes".
    @Test func incompleteStoresAreDeduplicated() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-dedupe")))
        store.periodDataDeleteHook = { false }            // names "your cycle notes"
        store.intimacyDataDeleteHook = { true }
        store.journalDataDeleteHook = { true }
        store.pendingNarrativeBufferPurgeHook = { false } // also names "your cycle notes"

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(outcome.incompleteStores.filter { $0 == "your cycle notes" }.count == 1)
    }

    /// The guided-workout runner (new on this branch: it backs the interactive Live Activity) mirrors an
    /// in-flight run to a process-wide app-group file that a foreground/launch reconcile re-reads — and a
    /// naturally-finished run re-LOGS a workout into the store. Without clearing it, a run
    /// in flight at wipe time survives "delete everything": the next reconcile re-adopts it (the run
    /// reappears in the sheet/card) or re-logs it into the just-emptied store — which, with sync on,
    /// re-uploads the resurrected day to iCloud. It is a live writer like the widget queue and the recipe
    /// inbox, so the funnel must stop it.
    ///
    /// Process-wide app-group file (like the guided-run suite): clear it first, keep the suite serialized.
    @Test func guidedRunInFlightDoesNotSurviveTheWipe() async {
        let store = makeTestStore()
        store.clearGuidedRun()
        let s = WorkoutProgram.SessionSuggestion(
            title: "Push", timeLabel: "", kind: .strength,
            exercises: [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)],
            suggestion: WorkoutSuggestion(name: "Push", exercises: "Bench 3x8", notes: "")
        )
        store.startGuidedRun(s)
        #expect(store.guidedRunState != nil, "precondition: the guided run did not start")

        await store.deleteAllData(includingHealthKitSamples: false)

        // Cleared in memory…
        #expect(store.guidedRunState == nil, "the in-flight guided run survived the wipe in memory")
        // …and in the app-group file: a reconcile (the same path a relaunch/foreground takes) must find
        // nothing to re-adopt or re-log. If the file survived, reconcile would set `guidedRunState` back.
        store.reconcileGuidedRunFromAppGroup()
        #expect(store.guidedRunState == nil, "the guided run survived the wipe in the app-group file")
        #expect(store.day.workouts.isEmpty, "a guided run re-logged a workout after the wipe")
    }

    /// The un-hide period-backup settle is a live writer like the guided run and the widget queue: a
    /// settle suspended in its CloudKit fetch when the wipe runs would resume afterwards and re-insert
    /// cycle narratives (and possibly re-upload a backup) into the just-emptied store. The funnel must
    /// cancel it; `applyRestoredChunks`' cancellation check then stops the write
    /// (`applyRefusesToWriteInsideACancelledTask` in SealedBackupRestoreTests covers that half).
    @Test func deleteAllCancelsTheInFlightPeriodBackupSettle() async {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL("delete-all-settle")))
        let inFlight = Task { while !Task.isCancelled { await Task.yield() } }
        store.periodBackupSettleTask = inFlight

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(inFlight.isCancelled, "the wipe left the period-backup settle running")
    }

    /// Wires every sealed/reset hook to succeed, for tests that need an otherwise-complete wipe.
    /// HealthKit is left out because it only fires when the caller opts into deleting samples.
    private func wireSucceedingSealedHooks(_ store: FernletStore) {
        store.periodDataDeleteHook = { true }
        store.intimacyDataDeleteHook = { true }
        store.journalDataDeleteHook = { true }
        store.pendingNarrativeBufferPurgeHook = { true }
        store.worryBoxResetHook = { true }
        store.storagePreferencesResetHook = { _, _ in true }
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
