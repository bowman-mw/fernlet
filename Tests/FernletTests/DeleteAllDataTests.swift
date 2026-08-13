import CoreData
import CryptoKit
import Foundation
import Testing
// @testable for the internal `save`, which seeds the share-extension inbox the way the extension does.
@testable import AppServices
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletLock
import FernletPersistence
import HealthKitGateway
import LocalPersistence
import PrivateHealthStore
import PrivateMemoryStore
import PrivateStoreCore
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

    /// A live store over its own repository file, its own own-photo root, and its own heart-drop
    /// scope. All of it has to be per-store: these tests wipe, and every one of those is shared
    /// on-disk (or, for the heart-drop seal key, keychain) state — a store left on the process-wide
    /// roots deletes the photos, the queued hearts and the heart ledger of every concurrently
    /// running suite, and takes the key sealing their sidecars with it.
    private func makeStore(_ name: String) -> FernletStore {
        FernletStore(
            repository: LocalFernletRepository(fileURL: temporaryDatabaseURL(name)),
            sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(),
            appGroupDirectory: uniqueAppGroupDirectory(),
            sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
            photoDocumentsDirectory: uniquePhotoDirectory(),
            proximitySupportDirectory: uniqueProximityDirectory(),
            heartDropKeychainService: uniqueHeartDropKeychainService(),
            aiQuotaDefaults: uniqueAIQuotaDefaults()
        )
    }

    /// The survival twin of `guidedRunInFlightDoesNotSurviveTheWipe`: the wipe must reach THIS
    /// store's app-group state and no one else's.
    ///
    /// All four co-tenants of `<group.MBO.Fernlet>/FernletWidgets/` were on one process-wide path
    /// while `resetAll` cleared the two run files and `deleteAllData` also cleared the widget queue —
    /// and unlike the earlier rounds this one was demonstrably LIVE: `GuidedWorkoutRunStoreTests`
    /// reads the guided file through a real store, so a wipe here landed in the middle of it.
    ///
    /// Every assertion goes through the FILE, never the in-memory mirror. `mine.guidedRunState`
    /// survives B's wipe even with the bug present — only a reconcile re-reads the container, which
    /// is the thing that was actually shared.
    @Test func aDeleteAllInAnotherStoreLeavesThisOnesAppGroupStateIntact() async throws {
        let mineDirectory = uniqueAppGroupDirectory()
        let mine = makeTestStore(appGroupDirectory: mineDirectory)
        let theirs = makeTestStore()   // its own helper-defaulted app-group root

        let session = WorkoutProgram.SessionSuggestion(
            title: "Push", timeLabel: "", kind: .strength,
            exercises: [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)],
            suggestion: WorkoutSuggestion(name: "Push", exercises: "Bench 3x8", notes: "")
        )
        mine.startGuidedRun(session)
        mine.pendingWidgetActionQueue.append(PendingWidgetAction(
            id: UUID(), dateKey: mine.todayKey,
            action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        ))
        #expect(mine.guidedRunState != nil, "precondition: the guided run did not start")

        // The other suite's "delete everything" — reaches resetAll's run-file clears AND the queue.
        theirs.startGuidedRun(session)
        await theirs.deleteAllData(includingHealthKitSamples: false)

        // Its own state really is gone, so the assertions below cannot pass against a wipe that
        // quietly stopped wiping.
        theirs.reconcileGuidedRunFromAppGroup()
        #expect(theirs.guidedRunState == nil, "precondition: the other store's wipe did not clear its own run")

        // Ours survived — asserted through the container, and again through a THIRD store built on
        // our root after the wipe, so the test cannot pass by writing having silently stopped.
        mine.reconcileGuidedRunFromAppGroup()
        #expect(mine.guidedRunState?.sessionID == session.id,
                "another store's delete-all cleared this store's guided-run file")
        let relaunched = makeTestStore(appGroupDirectory: mineDirectory)
        relaunched.reconcileGuidedRunFromAppGroup()
        #expect(relaunched.guidedRunState?.sessionID == session.id,
                "the guided run did not survive on disk — the other store's wipe reached our container")
        #expect(!relaunched.pendingWidgetActionQueue.claimAll().isEmpty,
                "another store's delete-all drained this store's widget-action queue")
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
        let store = makeStore("delete-all-hooks")
        var called: Set<String> = []
        var worryCallCount = 0
        store.periodDataDeleteHook = { called.insert("period"); return true }
        store.intimacyDataDeleteHook = { called.insert("intimacy"); return true }
        store.journalDataDeleteHook = { called.insert("journal"); return true }
        store.worryBoxResetHook = { called.insert("worry"); worryCallCount += 1; return true }
        store.pendingNarrativeBufferPurgeHook = { called.insert("pendingBuffer"); return true }
        store.sealedStoreRebuildHook = { called.insert("sealedRebuild"); return true }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(called == ["period", "intimacy", "journal", "worry", "pendingBuffer", "sealedRebuild"])
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
        let store = makeStore("delete-all-buffer")
        var purged = false
        store.pendingNarrativeBufferPurgeHook = { purged = true; return true }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(purged, "the locked-note buffer survived the wipe and will re-insert on the next unlock")
    }

    /// A sealed store that fails to clear must reach the user. This is the most sensitive data in the
    /// app and the dialog promises it is gone — silently swallowing the failure is the exact defect the
    /// funnel exists to end.
    @Test func outcomeReportsASealedStoreThatFailedToDelete() async {
        let store = makeStore("delete-all-sealed-fail")
        store.journalDataDeleteHook = { false }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your journal entries"))
    }

    /// HealthKit deletion is the user's explicit choice at delete time, so it must NOT fire unless asked.
    @Test func healthKitSamplesAreOnlyDeletedWhenRequested() async {
        let store = makeStore("delete-all-hk-off")
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
        let store = makeStore("delete-all-survivors")
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

        let store = FernletStore(repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), appGroupDirectory: uniqueAppGroupDirectory(),
                                 sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
                                 photoDocumentsDirectory: uniquePhotoDirectory(),
                                 proximitySupportDirectory: uniqueProximityDirectory(),
                                 heartDropKeychainService: uniqueHeartDropKeychainService(),
                                 aiQuotaDefaults: uniqueAIQuotaDefaults())
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
        let store = FernletStore(repository: repository, sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), appGroupDirectory: uniqueAppGroupDirectory(),
                                 sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
                                 photoDocumentsDirectory: uniquePhotoDirectory(),
                                 proximitySupportDirectory: uniqueProximityDirectory(),
                                 heartDropKeychainService: uniqueHeartDropKeychainService(),
                                 aiQuotaDefaults: uniqueAIQuotaDefaults())
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

        let store = makeStore("delete-all-recipe-store")
        store.sharedRecipeImportQueue = queue
        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(queue.records().isEmpty)
    }

    /// The survival twin of the test above: the wipe must reach THIS store's inbox and no one else's.
    ///
    /// The share-extension queue is the app-group container's OTHER tenant — `SharedRecipeImports/`
    /// rather than the `FernletWidgets/` root `appGroupDirectory` covers — so it needed its own seam,
    /// and `deleteAllData` clears it for every concurrently-live store on the production path. Latent
    /// rather than live only because the two suites that drive the drain hand-inject a queue over
    /// their store's; the obvious way to write this test, reaching for `store.sharedRecipeImportQueue`
    /// directly, is exactly the one that joins the race.
    ///
    /// The queue is stateless (a file URL plus coders), so every assertion here is already a FILE
    /// read — and the third store, built on our file after the wipe, keeps it from passing if writing
    /// had silently stopped.
    @Test func aDeleteAllInAnotherStoreLeavesThisOnesRecipeInboxIntact() async {
        let mineQueueURL = uniqueSharedRecipeImportQueueURL()
        let mine = makeTestStore(sharedRecipeImportQueueFileURL: mineQueueURL)
        let theirs = makeTestStore()   // its own helper-defaulted inbox file

        let queued = SharedRecipeImportRecord(url: URL(string: "https://example.com/stew")!)
        mine.sharedRecipeImportQueue.save([queued])
        theirs.sharedRecipeImportQueue.save([
            SharedRecipeImportRecord(url: URL(string: "https://example.com/theirs")!)
        ])
        #expect(!mine.sharedRecipeImportQueue.records().isEmpty, "precondition: the seeded row did not land")

        await theirs.deleteAllData(includingHealthKitSamples: false)

        // Their own inbox really is empty, so nothing below can pass against a wipe that quietly
        // stopped wiping.
        #expect(theirs.sharedRecipeImportQueue.records().isEmpty,
                "precondition: the other store's wipe did not clear its own inbox")

        #expect(mine.sharedRecipeImportQueue.records().map(\.id) == [queued.id],
                "another store's delete-all emptied this store's recipe inbox")
        let relaunched = makeTestStore(sharedRecipeImportQueueFileURL: mineQueueURL)
        #expect(relaunched.sharedRecipeImportQueue.records().map(\.id) == [queued.id],
                "the queued import did not survive on disk — the other store's wipe reached our file")
    }

    /// A wipe reports what it could not finish. Every layer is best-effort, and the dialog promises
    /// permanence — so a store that fails to clear has to reach the user instead of being swallowed.
    @Test func outcomeReportsAStoreThatFailedToDelete() async {
        let store = FernletStore(repository: FailingPurgeRepository(), sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(), appGroupDirectory: uniqueAppGroupDirectory(),
                                 sharedRecipeImportQueueFileURL: uniqueSharedRecipeImportQueueURL(),
                                 photoDocumentsDirectory: uniquePhotoDirectory(),
                                 proximitySupportDirectory: uniqueProximityDirectory(),
                                 heartDropKeychainService: uniqueHeartDropKeychainService(),
                                 aiQuotaDefaults: uniqueAIQuotaDefaults())
        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your day history"))
    }

    /// The plaintext "export my data" dump must not survive the wipe. `writeDataExportFile()` writes the
    /// user's whole decrypted dataset UNENCRYPTED to tmp/ for the share sheet, and iOS only reclaims tmp/
    /// under storage pressure — so a user who exported and then deleted everything could otherwise be left
    /// with a full plaintext copy on disk after a dialog that told them it was gone.
    @Test func exportedDataFileIsSweptByTheWipe() async throws {
        let store = makeStore("delete-all-export")
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

        let store = makeStore("delete-all-legacy-export")
        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path), "the legacy plaintext export survived the wipe")
    }

    /// The trainer/nutritionist summary is the same kind of plaintext liability as the data export —
    /// injury notes, sickness days, wellbeing scores in the clear — and it writes into the same exports
    /// directory precisely so the wipe covers it by construction rather than by anyone remembering it.
    @Test func trainerExportFileIsSweptByTheWipe() async throws {
        let store = makeStore("delete-all-trainer-export")
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

        let store = makeStore("delete-all-legacy-trainer-export")
        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path), "the legacy plaintext trainer export survived the wipe")
    }

    /// A clean wipe reports success, so the caller can dismiss rather than cry wolf.
    @Test func outcomeIsCompleteWhenEveryStoreClears() async {
        let store = makeStore("delete-all-clean")
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
        let store = makeStore("delete-all-nil-hook")
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
        let store = makeStore("delete-all-hk-fail")
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
        let store = makeStore("delete-all-hk-revoked")
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
        let store = makeStore("delete-all-worry-fail")
        wireSucceedingSealedHooks(store)
        store.worryBoxResetHook = { false }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your Worry Box notes"))
    }

    /// A NIL (unwired) Worry Box hook is a failure, not a silent skip — same rule as the other sealed
    /// hooks: an unwired funnel can't claim it cleared a store it never called.
    @Test func outcomeReportsAnUnwiredWorryBoxHookAsIncomplete() async {
        let store = makeStore("delete-all-worry-nil")
        wireSucceedingSealedHooks(store)
        store.worryBoxResetHook = nil

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your Worry Box notes"))
    }

    /// The storage-preferences reset was the last nil-silent hook in the funnel: an unwired run left
    /// Health grants and backup flags as they were while the wipe reported complete.
    @Test func outcomeReportsAnUnwiredStoragePreferencesHookAsIncomplete() async {
        let store = makeStore("delete-all-prefs-nil")
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
        let store = makeStore("delete-all-dedupe")
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
    /// The app-group file is per-store now, so the opening `clearGuidedRun()` is redundant — kept
    /// because removing setup is not what this commit is for. The suite stays serialized for the
    /// process-global ActivityKit registries, which no seam covers.
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
        let store = makeStore("delete-all-settle")
        let inFlight = Task { while !Task.isCancelled { await Task.yield() } }
        store.periodBackupSettleTask = inFlight

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(inFlight.isCancelled, "the wipe left the period-backup settle running")
    }

    /// The intimacy un-hide settle is the same class of live writer as the period one, added with the
    /// intimacy backup payload: suspended in its CloudKit fetch it would resume after the wipe and
    /// re-insert intimate logs into the just-emptied store.
    @Test func deleteAllCancelsTheInFlightIntimacyBackupSettle() async {
        let store = makeStore("delete-all-intimacy-settle")
        let inFlight = Task { while !Task.isCancelled { await Task.yield() } }
        store.intimacyBackupSettleTask = inFlight

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(inFlight.isCancelled, "the wipe left the intimacy-backup settle running")
    }

    /// EVERY payload's re-upload deferral points at a backup the wipe just deleted (and at local data
    /// that is going with it), so none may survive as an obligation the app will keep surfacing — and
    /// keep retrying — against records that no longer exist.
    @Test func deleteAllClearsEveryPayloadsReuploadDeferral() async {
        let store = makeStore("delete-all-deferrals")
        wireSucceedingSealedHooks(store)
        var persisted: [SealedBackupPayloadType: Bool] = [:]
        store.sealedBackupDeferralPersistHook = { deferred, payload in persisted[payload] = deferred }
        for payload in SealedBackupPayloadType.allCases {
            store.recordSealedBackupReuploadDeferred(true, payloadType: payload)
        }

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(store.sealedBackupPeriodReuploadDeferred == false)
        #expect(store.sealedBackupJournalReuploadDeferred == false)
        #expect(store.sealedBackupIntimacyReuploadDeferred == false)
        // …and the persisted copies too, or the obligation comes back at the next launch.
        #expect(persisted[.periodData] == false)
        #expect(persisted[.journalNarratives] == false)
        #expect(persisted[.intimacyLogs] == false)
    }

    /// Wires every sealed/reset hook to succeed, for tests that need an otherwise-complete wipe.
    /// HealthKit is left out because it only fires when the caller opts into deleting samples.
    private func wireSucceedingSealedHooks(_ store: FernletStore) {
        store.periodDataDeleteHook = { true }
        store.intimacyDataDeleteHook = { true }
        store.journalDataDeleteHook = { true }
        store.pendingNarrativeBufferPurgeHook = { true }
        store.worryBoxResetHook = { true }
        store.sealedStoreRebuildHook = { true }
        store.storagePreferencesResetHook = { _, _ in true }
    }

    // MARK: - Crypto-erasure normalization (P1a): the sealed store FILE, not just its rows

    /// A failed store rebuild has to reach the user like any other leg. Reported as "your sealed
    /// store" — the rows are gone, but the file they lived in could not be re-created, so the
    /// residue promise is the one the wipe could not keep.
    @Test func outcomeReportsASealedStoreRebuildThatFailed() async {
        let store = makeStore("delete-all-rebuild-fail")
        wireSucceedingSealedHooks(store)
        store.sealedStoreRebuildHook = { false }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.isComplete)
        #expect(outcome.incompleteStores.contains("your sealed store"))
    }

    /// The rebuild lives in `resetAll()` so BOTH wipe legs get it — and so "delete everything",
    /// which delegates to `resetAll()`, does not run it twice (the same one-invocation contract the
    /// Worry Box purge has).
    @Test func theSealedStoreIsRebuiltExactlyOncePerWipe() async {
        let store = makeStore("delete-all-rebuild-once")
        var rebuildCount = 0
        wireSucceedingSealedHooks(store)
        store.sealedStoreRebuildHook = { rebuildCount += 1; return true }

        await store.deleteAllData(includingHealthKitSamples: false)
        #expect(rebuildCount == 1)

        // The standalone "Reset everything" entry point keeps it too.
        store.resetAll()
        #expect(rebuildCount == 2)
    }

    /// THE residue regression (Opus track §6): deleting the rows is not erasing them.
    ///
    /// A row-delete + history prune frees the SQLite pages and clears the shadow tables, but never
    /// checkpoints the WAL or vacuums the freelist — so the deleted record's bytes stay in the
    /// `-wal` frames and freed pages until something reuses them. `rebuildStore()` destroys the
    /// file those pages are in and re-creates it empty, which is what actually removes them.
    ///
    /// The marker is a journal `dayKey`, one of the deliberately PLAINTEXT columns (accepted risk
    /// NEW-4). That is the point: a scan for the sealed text column would prove nothing (it is
    /// ciphertext either way), whereas a plaintext column is a byte-exact witness for "these pages
    /// are still on disk".
    @Test func rebuildingTheSealedStoreRemovesTheResidueARowDeleteLeavesBehind() throws {
        let directory = try Self.makeScratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let controller = PrivatePersistenceController(storeURL: storeURL)
        let repository = JournalNarrativeRepository(controller: controller)
        let marker = "P1A-RESIDUE-\(UUID().uuidString)"

        try repository.insert(
            JournalNarrative(
                id: UUID(),
                dayKey: marker,
                tag: .quiet,
                entryDate: Date(),
                text: "a sealed thought",
                emotions: ["tired"],
                createdAt: Date(),
                updatedAt: Date()
            ),
            contentKey: SymmetricKey(size: .bits256)
        )
        #expect(Self.storeFiles(in: directory).contains(marker), "precondition: the seeded row never reached the store files")
        let identityBefore = Self.fileIdentity(of: storeURL)
        #expect(identityBefore != nil, "precondition: no sqlite file on disk to rebuild")

        try controller.purgeEncryptedEntities()
        // The defect this phase exists to fix: the rows are gone from the store, the bytes are not
        // gone from the disk. If this ever stops holding, the rebuild below is belt-and-braces
        // rather than load-bearing — which is still fine, but the honesty language in
        // Docs/PrivacyWipeCoverage.md is written on the assumption that it does hold.
        #expect(Self.storeFiles(in: directory).contains(marker), "row-delete unexpectedly erased the pages — re-check the honesty language in Docs/PrivacyWipeCoverage.md")

        try controller.rebuildStore()

        #expect(!Self.storeFiles(in: directory).contains(marker), "the deleted row's bytes survived the store rebuild")
        #expect(Self.fileIdentity(of: storeURL) != identityBefore, "the sqlite file was reused, not destroyed and re-created")

        // And the store is still usable — the user keeps using the app after a wipe, and the
        // long-lived repository captured the view context BEFORE the store was swapped underneath.
        let key = SymmetricKey(size: .bits256)
        #expect(try repository.narratives(forDayKey: marker, contentKey: key).isEmpty)
        try repository.insert(
            JournalNarrative(id: UUID(), dayKey: "2026-08-10", tag: .good, entryDate: Date(), text: "after", emotions: [], createdAt: Date(), updatedAt: Date()),
            contentKey: key
        )
        #expect(try repository.narratives(forDayKey: "2026-08-10", contentKey: key).count == 1)
    }

    /// The reversibility trap, asserted end to end: every deletion path must stay reachable while
    /// the app is LOCKED, so nothing in it — row-delete or rebuild — may need the content key.
    ///
    /// Seals one row in each of the four sealed entities under a real `FernletLockService` content
    /// key, engages the lock (scrubbing that key), then drives the real funnel with the real
    /// repositories wired to the hooks. The rows must be gone, the store file rebuilt, and the lock
    /// must still hold no key on the way out — a wipe that had to decrypt to delete would have had
    /// to unlock first.
    @Test func aLockedWipeDropsEverySealedRowAndRebuildsWithoutAContentKey() async throws {
        let directory = try Self.makeScratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let controller = PrivatePersistenceController(storeURL: storeURL)
        let suiteName = "fernlet-tests-p1a-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let lock = FernletLockService(
            keychainService: "com.fernlet.lock.test.p1a.\(UUID().uuidString)",
            // reset() sweeps the sealed-content device keys too; keep that off the real service.
            sealedContentKeyServices: ["com.fernlet.journal.test.p1a.\(UUID().uuidString)"],
            // The purge hook below drives the REAL buffer purge; keep it off the process-wide scope.
            narrativeBufferScope: uniqueNarrativeBufferScope(),
            privatePersistenceController: controller
        )
        defer { try? lock.reset() }
        try await lock.configure(credential: .pin6("135790"), grantingScope: .privateHub)
        let key = try #require(lock.contentKey(for: .privateHub), "precondition: configure produced no content key")

        try MenstrualNarrativeRepository(controller: controller, defaults: defaults)
            .insert(MenstrualNarrative(hkExternalUUID: "hk-p1a", dateKey: "2026-08-10", note: "cycle note"), contentKey: key)
        try IntimacyLogRepository(controller: controller)
            .insert(IntimacyLog(eventDate: Date(), note: "intimate note"), contentKey: key)
        try JournalNarrativeRepository(controller: controller)
            .insert(
                JournalNarrative(id: UUID(), dayKey: "2026-08-10", tag: .quiet, entryDate: Date(), text: "journal", emotions: [], createdAt: Date(), updatedAt: Date()),
                contentKey: key
            )
        try WorryNarrativeRepository(controller: controller).insert(WorryNarrative(text: "a worry"), contentKey: key)
        #expect(Self.sealedRowCount(in: controller) == 4, "precondition: the four sealed rows were not seeded")

        lock.lock(reason: .manual)
        #expect(lock.contentKey(for: .privateHub) == nil, "precondition: the wipe must run with the lock engaged")

        let store = makeStore("delete-all-locked")
        store.periodDataDeleteHook = { (try? MenstrualNarrativeRepository(controller: controller, defaults: defaults).deleteAll()) != nil }
        store.intimacyDataDeleteHook = { (try? IntimacyLogRepository(controller: controller).deleteAll()) != nil }
        store.journalDataDeleteHook = { (try? JournalNarrativeRepository(controller: controller).deleteAll()) != nil }
        store.worryBoxResetHook = { (try? WorryNarrativeRepository(controller: controller).deleteAll()) != nil }
        store.pendingNarrativeBufferPurgeHook = { (try? lock.purgePendingNarratives()) != nil }
        store.sealedStoreRebuildHook = { (try? controller.rebuildStore()) != nil }
        store.storagePreferencesResetHook = { _, _ in true }

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(Self.sealedRowCount(in: controller) == 0, "sealed rows survived a locked wipe")
        #expect(lock.contentKey(for: .privateHub) == nil, "the wipe produced a content key — deletion must never require the ability to read")
        for named in ["your cycle notes", "your intimate logs", "your journal entries", "your Worry Box notes", "your sealed store"] {
            #expect(!outcome.incompleteStores.contains(named), "\(named) reported incomplete after a locked wipe")
        }
    }

    /// The `_SUPPORT` half of the rebuild, which `destroyPersistentStore` does not cover: sealed
    /// columns over ~100 KB are spilled by Core Data into `.FernletPrivate_SUPPORT` as standalone
    /// ciphertext files that would otherwise outlive the store that named them.
    ///
    /// The `fileExists` assertion before the rebuild is the load-bearing one: it is what pins the
    /// SPELLING of that directory. The rebuild and `BackupExclusion` used to compute the path with
    /// two separate copies of the same expression (with a doc comment claiming there was one), so
    /// either could have drifted onto a directory the other never touched — and the removal was
    /// `try?`, which makes a wrong path indistinguishable from "nothing to remove".
    @Test func theRebuildRemovesTheExternalBlobDirectoryTheDestroyLeavesBehind() throws {
        let directory = try Self.makeScratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let controller = PrivatePersistenceController(storeURL: storeURL)
        let repository = JournalNarrativeRepository(controller: controller)
        let marker = "P1A-BLOB-\(UUID().uuidString)"

        // Big enough that `allowsExternalBinaryDataStorage` externalizes the sealed text column.
        try repository.insert(
            JournalNarrative(
                id: UUID(),
                dayKey: marker,
                tag: .quiet,
                entryDate: Date(),
                text: String(repeating: "a very long sealed thought. ", count: 8_000),
                emotions: ["tired"],
                createdAt: Date(),
                updatedAt: Date()
            ),
            contentKey: SymmetricKey(size: .bits256)
        )
        let supportDirectory = BackupExclusion.supportDirectory(for: storeURL)
        #expect(
            FileManager.default.fileExists(atPath: supportDirectory.path),
            "precondition: no external-blob directory at the ONE shared spelling — either the payload stopped externalizing or the rebuild and BackupExclusion have drifted onto different paths"
        )

        try controller.purgeEncryptedEntities()
        try controller.rebuildStore()

        #expect(
            !FileManager.default.fileExists(atPath: supportDirectory.path),
            "the external-blob directory outlived the store rebuild — its standalone ciphertext files are still on disk"
        )
        #expect(!Self.storeFiles(in: directory).contains(marker), "the deleted row's bytes survived the store rebuild")
    }

    /// A rebuild whose re-add fails must never leave the process holding a coordinator with ZERO
    /// stores, because that state is worse than the residue the rebuild exists to remove: every
    /// sealed write fails for the rest of the session, and `JournalSealingCoordinator` deliberately
    /// keeps a failed seal's PLAINTEXT in the days blob — which mirrors to iCloud when sync is on.
    ///
    /// Forced deterministically by making the store's directory unwritable, so both the destroy and
    /// the re-add fail. Three things are asserted: the failure is reported (not silent), a sealed
    /// save in that window throws a Swift error instead of tripping Core Data's uncatchable
    /// "no persistent stores" exception (the test COMPLETING is that assertion), and the next
    /// foreground's `reloadStoreIfNeeded()` heals it so sealing resumes.
    @Test func aFailedRebuildIsReportedHealsAndNeverTrapsASealedSave() throws {
        let directory = try Self.makeScratchStoreDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let controller = PrivatePersistenceController(storeURL: storeURL)
        let repository = JournalNarrativeRepository(controller: controller)
        let key = SymmetricKey(size: .bits256)
        try repository.insert(
            JournalNarrative(id: UUID(), dayKey: "2026-08-10", tag: .quiet, entryDate: Date(), text: "before", emotions: [], createdAt: Date(), updatedAt: Date()),
            contentKey: key
        )
        #expect(controller.isStoreLoaded, "precondition: the store never loaded")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        #expect(throws: (any Error).self) { try controller.rebuildStore() }
        #expect(controller.didFailToLoad, "a storeless controller must SAY so — nothing else can detect the state")
        #expect(!controller.isStoreLoaded, "precondition: the re-add unexpectedly succeeded, so this test proves nothing")

        // The uncatchable-crash guard. A bare `save()` here raises NSInternalInconsistencyException,
        // which is not a Swift error and would abort the whole test runner rather than fail a test.
        #expect(throws: PrivatePersistenceController.RebuildError.self) {
            try controller.container.viewContext.saveSealed()
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try controller.reloadStoreIfNeeded()
        #expect(controller.isStoreLoaded, "the foreground self-heal did not re-add the sealed store")
        #expect(!controller.didFailToLoad)
        // And sealing works again — the custody consequence, not just the flag.
        try repository.insert(
            JournalNarrative(id: UUID(), dayKey: "2026-08-11", tag: .good, entryDate: Date(), text: "after", emotions: [], createdAt: Date(), updatedAt: Date()),
            contentKey: key
        )
        #expect(try repository.narratives(forDayKey: "2026-08-11", contentKey: key).count == 1)
        // Idempotent: the app calls it on EVERY foreground, so the common case must be a no-op.
        try controller.reloadStoreIfNeeded()
        #expect(controller.isStoreLoaded)
    }

    /// A scratch directory for an ON-DISK sealed store. In-memory (`/dev/null`) controllers cannot
    /// express the rebuild's contract, which is entirely about real files.
    private static func makeScratchStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-sealed-rebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Every byte currently on disk under the sealed store's directory — sqlite, `-wal`, `-shm`,
    /// and the `_SUPPORT` external-blob tree — as one Latin-1 string. Latin-1 because it is the one
    /// encoding that round-trips arbitrary bytes: a UTF-8 decode of binary pages substitutes
    /// replacement characters, which is exactly how a residue scan quietly stops finding residue.
    private static func storeFiles(in directory: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return "" }
        var combined = ""
        for case let url as URL in enumerator {
            guard let data = try? Data(contentsOf: url) else { continue }
            combined += String(data: data, encoding: .isoLatin1) ?? ""
        }
        return combined
    }

    /// The file's inode number AND creation timestamp, so "destroyed and re-created" can be told
    /// apart from "truncated in place" — a truncation leaves the freed pages allocated to the same
    /// file. Both parts, because APFS can hand a freshly created file the inode it just freed.
    /// `nil` when the file does not exist, which also counts as "not the same file".
    private static func fileIdentity(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode)@\(created)"
    }

    /// Rows across all four sealed entities.
    private static func sealedRowCount(in controller: PrivatePersistenceController) -> Int {
        let context = controller.container.viewContext
        return context.performAndWait {
            ["MenstrualNarrative", "JournalNarrative", "IntimacyLog", "WorryNarrative"].reduce(0) { total, entityName in
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                return total + ((try? context.fetch(request).count) ?? 0)
            }
        }
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
