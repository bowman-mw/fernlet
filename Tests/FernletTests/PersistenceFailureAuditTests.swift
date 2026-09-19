import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import LocalPersistence
@testable import Fernlet

/// P9 item 1 (plan §14.3 finding 3): every environmental persistence failure is AUDITED, never
/// trapped.
///
/// The repositories used to answer a failed Core Data fetch/save/delete or a failed file
/// write/remove with `assertionFailure` inside the `catch`. Those failures are not programmer
/// errors — the stores load with `FileProtectionType.complete` and nothing defers a day write
/// while the device is locked — so a DEBUG build died on an ordinary locked-device write
/// ("Fatal error: day record delete failed"), which is exactly what P8's lock and background
/// device rows do.
///
/// Every cell drives the REAL code path with a store that genuinely throws, and asserts two
/// things: the call returns (the process ran to completion — a trap would have killed the test
/// runner, not failed the cell) AND the failure reached ``PersistenceFailureAudit``.
///
/// Three throwing rigs, each modelling a real condition:
/// - `makeReadOnlyController(at:seed:)` — the seeded store is re-attached READ-ONLY, so fetches
///   return rows and every save throws. This is the rig for every `catch` that sits after a
///   successful fetch, which is the shape of almost every delete/upsert path.
/// - `makeUnreadableController(at:seed:)` — the database file is overwritten underneath the open
///   connection, so the next fetch itself fails. The rig for the fetch-failure branches.
/// - a read-only directory / a non-finite `Double` — the file and encode failures.
///
/// A store that merely never loaded is NOT a rig: a context whose coordinator holds no stores
/// fetches empty and saves nothing, so nothing throws and nothing is proven.
///
/// Audit assertions use `contains`, never a count: the audit registry is process-global and other
/// suites run in parallel (the D-6a.10 flake shape).
@MainActor
@Suite(.serialized)
struct PersistenceFailureAuditTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - DayRecordRepository (the finding's named site)

    @Test func dayRecordDeleteAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = DayRecordRepository(
            controller: try makeReadOnlyController(at: directory, seed: seedDay))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.delete(dateKeys: ["2026-05-01"]) }
        #expect(survived == false, "a failed delete must still report not-durable")
        #expect(events.contains("dayRecord.delete.failed"))
    }

    @Test func dayRecordDeleteAllAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = DayRecordRepository(
            controller: try makeReadOnlyController(at: directory, seed: seedDay))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.deleteAll() }
        #expect(survived == false)
        #expect(events.contains("dayRecord.deleteAll.failed"))
    }

    @Test func dayRecordUpsertAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = DayRecordRepository(controller: try makeReadOnlyController(at: directory))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01"), updatedAt: stamp)])
        }
        #expect(survived == false)
        #expect(events.contains("dayRecord.upsert.failed"))
    }

    @Test func dayRecordFetchAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = DayRecordRepository(
            controller: try makeUnreadableController(at: directory, seed: seedDay))
        var events: [AuditEvent] = []
        let days = captureAudit(into: &events) { repo.loadAll() }
        #expect(days.isEmpty, "an unreadable store yields the documented empty result")
        #expect(events.contains("dayRecord.fetch.failed"))
    }

    @Test func dayRecordEncodeFailureAuditsInsteadOfTrapping() {
        // A non-finite number reaching JSON is a runtime data condition, not a programmer error.
        let repo = DayRecordRepository(controller: PersistenceController(inMemory: true, preferences: localOnly))
        let day = FernletDay(date: "2026-05-01", meals: [nonEncodableMeal()])
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.upsert([DayRecordUpsert(day: day, updatedAt: stamp)])
        }
        #expect(survived == true, "the un-encodable row is skipped; the batch still completes")
        #expect(events.contains("dayRecord.encode.failed"))
    }

    // MARK: - AppendOnlyRowStore (coin / milestone / custom-item engine)

    @Test func rowStoreFetchAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = CoinLedgerRepository(
            controller: try makeUnreadableController(at: directory, seed: seedCoin))
        var events: [AuditEvent] = []
        let rows = captureAudit(into: &events) { repo.load() }
        #expect(rows.isEmpty)
        #expect(events.contains("rowStore.fetch.failed"))
        #expect(events.contains("rowStore.fetch.failed", where: "store", equals: "coinLedger"))
    }

    @Test func rowStoreSaveAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = CoinLedgerRepository(controller: try makeReadOnlyController(at: directory))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.append([coinEntry()]) }
        #expect(survived == false)
        #expect(events.contains("rowStore.save.failed"))
    }

    @Test func rowStoreEncodeAuditsInsteadOfTrapping() {
        // The engine is generic over its Codable row, so the honest lever is a row that refuses to
        // encode — the same failure a non-finite number produces in the shipping row types.
        let store = AppendOnlyRowStore<UnencodableRow>(
            controller: PersistenceController(inMemory: true, preferences: localOnly),
            entityName: "CoinLedgerRecord",
            loadTimingLabel: "PersistenceFailureAuditTests.load",
            loadAsyncTimingLabel: "PersistenceFailureAuditTests.loadAsync",
            auditStore: "coinLedger",
            idString: { $0.id },
            createdAt: { _ in Date(timeIntervalSince1970: 0) }
        )
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { store.append([UnencodableRow(id: "row-1")]) }
        #expect(survived == true, "the un-encodable row is skipped, not trapped on")
        #expect(events.contains("rowStore.encode.failed"))
    }

    @Test func coinLedgerDeleteAllAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = CoinLedgerRepository(
            controller: try makeReadOnlyController(at: directory, seed: seedCoin))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.deleteAll() }
        #expect(survived == false)
        #expect(events.contains("coinLedger.deleteAll.failed"))
    }

    @Test func milestoneLedgerDeleteAllAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = MilestoneLedgerRepository(
            controller: try makeReadOnlyController(at: directory, seed: seedMilestone))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.deleteAll() }
        #expect(survived == false)
        #expect(events.contains("milestoneLedger.deleteAll.failed"))
    }

    @Test func customItemDeleteAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let itemID = UUID()
        let repo = CustomItemRepository(controller: try makeReadOnlyController(at: directory) { controller in
            _ = CustomItemRepository(controller: controller).upsert([customItem(id: itemID)])
        })
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.delete(ids: [itemID]) }
        #expect(survived == false)
        #expect(events.contains("customItem.delete.failed"))
    }

    @Test func customItemDeleteAllAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = CustomItemRepository(
            controller: try makeReadOnlyController(at: directory, seed: seedCustomItem))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.deleteAll() }
        #expect(survived == false)
        #expect(events.contains("customItem.deleteAll.failed"))
    }

    // MARK: - SavedRecipeRepository + its legacy JSON file

    @Test func savedRecipeFetchAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let recipeID = UUID()
        let controller = try makeUnreadableController(at: directory) { controller in
            _ = makeSavedRecipeRepository(controller: controller, in: directory)
                .upsert([recipe(id: recipeID, quantity: 1)])
        }
        let repo = makeSavedRecipeRepository(controller: controller, in: directory)
        var events: [AuditEvent] = []
        let rows = captureAudit(into: &events) { repo.load() }
        #expect(rows.isEmpty)
        #expect(events.contains("savedRecipe.fetch.failed"))
    }

    @Test func savedRecipeUpsertAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = makeSavedRecipeRepository(
            controller: try makeReadOnlyController(at: directory), in: directory)
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.upsert([recipe(id: UUID(), quantity: 1)]) }
        #expect(survived == false)
        #expect(events.contains("savedRecipe.upsert.failed"))
    }

    @Test func savedRecipeDeleteAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let recipeID = UUID()
        let controller = try makeReadOnlyController(at: directory) { controller in
            _ = makeSavedRecipeRepository(controller: controller, in: directory)
                .upsert([recipe(id: recipeID, quantity: 1)])
        }
        let repo = makeSavedRecipeRepository(controller: controller, in: directory)
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.delete(ids: [recipeID]) }
        #expect(survived == false)
        #expect(events.contains("savedRecipe.delete.failed"))
    }

    @Test func savedRecipeDeleteAllAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let controller = try makeReadOnlyController(at: directory) { controller in
            _ = makeSavedRecipeRepository(controller: controller, in: directory)
                .upsert([recipe(id: UUID(), quantity: 1)])
        }
        let repo = makeSavedRecipeRepository(controller: controller, in: directory)
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.deleteAll() }
        #expect(survived == false)
        #expect(events.contains("savedRecipe.deleteAll.failed"))
    }

    /// The UPDATE path is the load-bearing one: a failed blob encode must DROP `payloadData`, not
    /// leave the previous save's blob behind. `recipe(from:)` prefers a decodable blob whenever the
    /// legacy columns still match what that blob projected, and an edit confined to the structured
    /// `ingredients` is invisible to `legacyProjection` — so a stale blob would out-vote the fresh
    /// legacy columns and the user's edit would silently vanish on the next load.
    @Test func savedRecipePayloadEncodeAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let controller = PersistenceController(inMemory: true, preferences: localOnly)
        let repo = makeSavedRecipeRepository(controller: controller, in: directory)
        let recipeID = UUID()
        // A first, ENCODABLE save, so the row genuinely carries a prior blob to go stale.
        #expect(repo.upsert([recipe(id: recipeID, quantity: 1)]))
        let blobBefore = try savedRecipeRecord(in: controller)?.value(forKey: "payloadData") as? Data
        #expect(blobBefore != nil, "the rig is only honest if a prior blob exists")
        #expect(repo.load().first?.ingredients.first?.quantity == 1, "the blob is the read truth")

        // The edit changes ONLY the structured quantity — no legacy-visible column moves.
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.upsert([recipe(id: recipeID, quantity: .nan)]) }
        // The structured blob is ADDITIVE — the legacy columns are already written and the save
        // succeeds, so the row IS durable and the upsert still reports `true`.
        #expect(survived == true)
        #expect(events.contains("savedRecipe.payloadEncode.failed"))
        let blobAfter = try savedRecipeRecord(in: controller)?.value(forKey: "payloadData") as? Data
        #expect(blobAfter == nil,
                "the stale blob must be dropped, not left to out-vote the fresh legacy columns")
        let nameAfter = try savedRecipeRecord(in: controller)?.value(forKey: "name") as? String
        #expect(nameAfter == "test recipe", "the legacy columns carry the write, so the row stays readable")
        let reread = repo.load()
        #expect(reread.count == 1)
        #expect(reread.first?.ingredients.isEmpty == true,
                "the pre-edit structured ingredients must not come back from the stale blob")
    }

    @Test func savedRecipeLegacyWriteAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        // A regular FILE where the parent directory should be: `createDirectory` throws.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let legacy = LegacySavedRecipeJSONRepository(
            fileURL: blocker.appendingPathComponent("SavedRecipes.json"))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { legacy.save([recipe(id: UUID(), quantity: 1)]) }
        #expect(survived == false)
        #expect(events.contains("savedRecipe.legacyWrite.failed"))
    }

    @Test func savedRecipeLegacyDeleteAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let fileURL = directory.appendingPathComponent("SavedRecipes.json")
        try Data("[]".utf8).write(to: fileURL)
        let legacy = LegacySavedRecipeJSONRepository(fileURL: fileURL)
        try setWritable(directory, false)   // a read-only parent refuses the unlink
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { legacy.deleteFile() }
        #expect(survived == false, "the wipe must name the copy it could not remove")
        #expect(events.contains("savedRecipe.legacyDelete.failed"))
    }

    // MARK: - CoreDataFernletRepository (the aggregate blob)

    @Test func coreDataPurgeAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let controller = try makeReadOnlyController(at: directory) { controller in
            _ = makeBlobRepository(controller: controller, in: directory)
                .saveSnapshot(snapshot(withUnencodableMeal: false).forTestingSanitized)
        }
        let repo = makeBlobRepository(controller: controller, in: directory)
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.purgeAllPersistedData() }
        #expect(survived == false, "a wipe that could not clear the record must say so")
        #expect(events.contains("coredata.purge.failed"))
    }

    @Test func coreDataEncodeAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let controller = PersistenceController(inMemory: true, preferences: localOnly)
        let repo = makeBlobRepository(controller: controller, in: directory)
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.saveSnapshot(snapshot(withUnencodableMeal: true).forTestingSanitized)
        }
        #expect(survived == false, "an un-encodable blob is not durable")
        #expect(events.contains("coredata.encode.failed"))
    }

    @Test func coreDataSaveAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        // Read-only store: the blob fetch still succeeds, so the save's OWN catch is reached.
        // The day-row write is stubbed out — otherwise it fails first and short-circuits the save.
        let repo = CoreDataFernletRepository(
            controller: try makeReadOnlyController(at: directory),
            legacyRepository: makeLocalRepository(at: directory.appendingPathComponent("legacy.json")),
            dayRecordRepository: AcceptingDayRecordRepository()
        )
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.saveSnapshot(snapshot(withUnencodableMeal: false).forTestingSanitized)
        }
        #expect(survived == false)
        #expect(events.contains("coredata.save.failed"))
    }

    // MARK: - LocalFernletRepository (the local-only JSON blob)

    @Test func localStoreDirectoryCreateAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let repo = makeLocalRepository(at: blocker.appendingPathComponent("db.json"))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.saveSnapshot(snapshot(withUnencodableMeal: false).forTestingSanitized)
        }
        #expect(survived == false)
        #expect(events.contains("localStore.directoryCreate.failed"))
    }

    @Test func localStoreWriteAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = makeLocalRepository(at: directory.appendingPathComponent("db.json"))
        try setWritable(directory, false)   // the directory exists but refuses a new file
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.saveSnapshot(snapshot(withUnencodableMeal: false).forTestingSanitized)
        }
        #expect(survived == false)
        #expect(events.contains("localStore.write.failed"))
    }

    @Test func localStoreEncodeAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let repo = makeLocalRepository(at: directory.appendingPathComponent("db.json"))
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) {
            repo.saveSnapshot(snapshot(withUnencodableMeal: true).forTestingSanitized)
        }
        #expect(survived == false)
        #expect(events.contains("localStore.encode.failed"))
    }

    @Test func localStorePurgeAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let fileURL = directory.appendingPathComponent("db.json")
        try Data("{}".utf8).write(to: fileURL)
        let repo = makeLocalRepository(at: fileURL)
        try setWritable(directory, false)
        var events: [AuditEvent] = []
        let survived = captureAudit(into: &events) { repo.purgeAllPersistedData() }
        #expect(survived == false)
        #expect(events.contains("localStore.purge.failed"))
    }

    // MARK: - DiaryStore's past-day write

    @Test func diaryPastDaySaveAuditsInsteadOfTrapping() throws {
        let directory = try makeTempDirectory()
        defer { removeTempDirectory(directory) }
        let store = FernletStore(
            repository: makeLocalRepository(at: directory.appendingPathComponent("db.json")),
            sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(),
            photoDocumentsDirectory: uniquePhotoDirectory()
        )
        try setWritable(directory, false)   // every past-day round trip now fails to persist
        var events: [AuditEvent] = []
        captureAudit(into: &events) {
            store.addWorkout(
                Workout(name: "row", type: .upper, exercises: "", rpe: 5, notes: "",
                        duration: 10, intensity: .moderate),
                date: "2026-05-01")
        }
        #expect(events.contains("diary.pastDaySave.failed"))
    }
}

// MARK: - Rigs

/// One captured audit record: the event token and its context.
private struct AuditEvent {
    let event: String
    let context: [String: String]
}

private extension Array where Element == AuditEvent {
    /// Whether `token` was emitted at all. Never a count — the audit registry is process-global and
    /// other suites emit into it in parallel.
    func contains(_ token: String) -> Bool { contains { $0.event == token } }

    /// Whether ANY record of `token` carries `key == value`. Deliberately not `first`: the audit
    /// registry is process-global and other suites emit into it while the handler is installed, so
    /// another suite's record of the same token can arrive ahead of this cell's and a first-match
    /// assertion would read the wrong context (the D-6a.10 flake shape).
    func contains(_ token: String, where key: String, equals value: String) -> Bool {
        contains { $0.event == token && $0.context[key] == value }
    }
}

extension PersistenceFailureAuditTests {
    /// Local-only preferences: no CloudKit mirroring for any controller a test stands up.
    fileprivate var localOnly: StoragePreferences { StoragePreferences(iCloudSyncEnabled: false) }

    /// Runs `body` with an audit capture handler installed, collecting every event it emits.
    @discardableResult
    fileprivate func captureAudit<T>(into events: inout [AuditEvent], _ body: () -> T) -> T {
        let sink = AuditSink()
        let token = FernletAuditLog.addCaptureHandler { event, context in
            sink.append(AuditEvent(event: event, context: context))
        }
        let result = body()
        FernletAuditLog.removeCaptureHandler(token)
        events = sink.drain()
        return result
    }

    /// Stands up a file-backed stack, lets `seed` populate it, then re-attaches the SAME store
    /// READ-ONLY: fetches return the seeded rows, every save throws. The rig for every `catch`
    /// that sits after a successful fetch — almost every delete/upsert path.
    fileprivate func makeReadOnlyController(
        at directory: URL,
        seed: @MainActor (PersistenceController) -> Void = { _ in }
    ) throws -> PersistenceController {
        let url = directory.appendingPathComponent("Fernlet.sqlite")
        let controller = makeWritableController(at: url)
        seed(controller)
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        _ = try coordinator.addPersistentStore(
            type: .sqlite, at: url, options: [NSReadOnlyPersistentStoreOption: true as NSNumber])
        controller.container.viewContext.reset()
        return controller
    }

    /// Stands up a file-backed stack, lets `seed` populate it, then overwrites the database file
    /// (and any WAL sidecar) with garbage UNDERNEATH the open connection. SQLite re-reads page 1's
    /// header at the start of every read transaction, so the next fetch fails — the rig for the
    /// fetch-failure branches.
    fileprivate func makeUnreadableController(
        at directory: URL,
        seed: @MainActor (PersistenceController) -> Void
    ) throws -> PersistenceController {
        let url = directory.appendingPathComponent("Fernlet.sqlite")
        let controller = makeWritableController(at: url)
        seed(controller)
        let garbage = Data(repeating: 0xFF, count: 64 * 1024)
        try garbage.write(to: url)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try garbage.write(to: sidecar)
            }
        }
        controller.container.viewContext.reset()
        return controller
    }

    private func makeWritableController(at url: URL) -> PersistenceController {
        PersistenceController(
            inMemory: false, preferences: localOnly, storeURL: url, iCloudAvailable: false)
    }

    /// Seeds one day row, so a delete has something to delete.
    fileprivate func seedDay(_ controller: PersistenceController) {
        _ = DayRecordRepository(controller: controller).upsert([
            DayRecordUpsert(day: FernletDay(date: "2026-05-01"), updatedAt: stamp)
        ])
    }

    fileprivate func seedCoin(_ controller: PersistenceController) {
        _ = CoinLedgerRepository(controller: controller).append([coinEntry()])
    }

    fileprivate func seedMilestone(_ controller: PersistenceController) {
        _ = MilestoneLedgerRepository(controller: controller).append([
            MilestoneLedgerEntry(id: "event:journal:seed", kind: .journal,
                                 dayKey: "2026-05-01", createdAt: stamp)
        ])
    }

    fileprivate func seedCustomItem(_ controller: PersistenceController) {
        _ = CustomItemRepository(controller: controller).upsert([customItem(id: UUID())])
    }

    fileprivate func customItem(id: UUID) -> CustomizationItem {
        CustomizationItem(
            id: id, name: "seed", slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: UUID()), createdAt: stamp)
    }

    /// A private scratch directory for one cell (suites share process-global disk).
    fileprivate func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.persistfail.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Restores write permission (a cell may have removed it) and removes the directory.
    fileprivate func removeTempDirectory(_ directory: URL) {
        try? setWritable(directory, true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Flips the directory's POSIX write bits — how a cell makes a file write or unlink fail.
    fileprivate func setWritable(_ directory: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: directory.path)
    }

    fileprivate func makeSavedRecipeRepository(
        controller: PersistenceController, in directory: URL
    ) -> SavedRecipeRepository {
        SavedRecipeRepository(
            controller: controller,
            legacyRepository: LegacySavedRecipeJSONRepository(
                fileURL: directory.appendingPathComponent("SavedRecipes.json")),
            defaults: isolatedDefaults()
        )
    }

    fileprivate func makeBlobRepository(
        controller: PersistenceController, in directory: URL
    ) -> CoreDataFernletRepository {
        CoreDataFernletRepository(
            controller: controller,
            legacyRepository: makeLocalRepository(at: directory.appendingPathComponent("legacy.json"))
        )
    }

    /// Every ``LocalFernletRepository`` a cell builds, with BOTH of its process-global seams pinned.
    ///
    /// `legacyDefaults` is the load-bearing one: `purgeAllPersistedData()` calls
    /// `clearLegacyUserDefaultsIfPresent()` BEFORE the file-existence guard, so a repository built
    /// without the seam deletes every `LegacyKeys` fixed key and every `dayPrefix` key out of
    /// `.standard` — the shared test host's domain — while other suites are running. That is exactly
    /// the hazard the seam's doc comment exists to prevent. `backupExclusionPreference` keeps `init`
    /// off the real preferences keychain.
    fileprivate func makeLocalRepository(at url: URL) -> LocalFernletRepository {
        LocalFernletRepository(
            fileURL: url,
            backupExclusionPreference: { false },
            legacyDefaults: isolatedDefaults()
        )
    }

    /// The single saved-recipe row, for the cell that asserts on the raw `payloadData` column the
    /// read path prefers over the legacy typed columns.
    fileprivate func savedRecipeRecord(in controller: PersistenceController) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        return try controller.container.viewContext.fetch(request).first
    }

    fileprivate func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.persistfail.\(UUID().uuidString)") ?? .standard
    }

    fileprivate func coinEntry() -> CoinLedgerEntry {
        CoinLedgerEntry(id: "earn:2026-05-01", kind: .earn, amount: 1, dayKey: "2026-05-01",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A meal whose component quantity is non-finite — JSON encoding of it throws, which is the
    /// runtime data condition the encode sites used to trap on.
    fileprivate func nonEncodableMeal() -> Meal {
        Meal(name: "unencodable", mealType: .breakfast, macros: Macros(protein: 1, carbs: 1, fat: 1),
             componentSnapshots: [MealComponentSnapshot(
                name: "component", quantity: .nan, unit: "g",
                macros: Macros(protein: 1, carbs: 1, fat: 1), micronutrients: Micronutrients())],
             quality: .ok, confidence: "test", note: "", source: "test")
    }

    fileprivate func recipe(id: UUID, quantity: Double) -> RecipeDefinition {
        RecipeDefinition(
            id: id, name: "test recipe", servings: 1,
            ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: quantity, unit: "g")],
            source: "test", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A snapshot whose blob-level `recentMeals` optionally carries the un-encodable meal, so the
    /// aggregate encode fails even once the day rows have been written.
    fileprivate func snapshot(withUnencodableMeal: Bool) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: "2026-05-02",
            day: FernletDay(date: "2026-05-02"),
            settings: FernletSettings(),
            recentMeals: withUnencodableMeal ? [nonEncodableMeal()] : [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }
}

/// Thread-safe collector behind the audit capture handler (handlers are invoked outside the log's
/// own lock and may arrive from any executor).
private final class AuditSink {
    private let lock = NSLock()
    private var events: [AuditEvent] = []

    func append(_ event: AuditEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func drain() -> [AuditEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// A row that always refuses to encode — the generic stand-in for a shipping row carrying a
/// non-finite number, used to drive ``AppendOnlyRowStore``'s encode-failure path.
private struct UnencodableRow: Codable {
    let id: String

    func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(id, EncodingError.Context(
            codingPath: [], debugDescription: "test row never encodes"))
    }
}

/// A day-row store that accepts every write, so a cell can reach the aggregate blob's own save
/// failure without the row write short-circuiting the snapshot save first.
@MainActor
private struct AcceptingDayRecordRepository: DayRecordRepositoring {
    func loadAll() -> [String: FernletDay] { [:] }
    func load(dateKeys: [String]) -> [String: FernletDay] { [:] }
    func loadRecent(limit: Int) -> [FernletDay] { [] }
    func upsert(_ days: [DayRecordUpsert]) -> Bool { true }
    func delete(dateKeys: [String]) -> Bool { true }
    func deleteAll() -> Bool { true }
}
