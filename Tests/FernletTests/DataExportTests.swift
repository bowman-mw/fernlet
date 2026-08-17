import XCTest
import FernletDomainModel
@testable import Fernlet

@MainActor
final class DataExportTests: XCTestCase {

    /// Encodes the data-bearing sections only (the `about` readme deliberately *names* the excluded
    /// categories, so it is blanked before the forbidden-token scan).
    private func dataJSON(_ export: FernletDataExport) throws -> String {
        var scan = export
        scan.about = .init(exportedOn: "", note: "", includes: [], excludes: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(scan), encoding: .utf8)!.lowercased()
    }

    /// The export vocabulary can only carry allowlisted, non-sensitive fields: a fully-populated
    /// export round-trips and its data sections contain none of the sealed/sensitive tokens.
    func testExportShapeRoundTripsAndCarriesNoSensitiveVocabulary() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let export = FernletDataExport(
            about: .init(exportedOn: "2026-07-11", includes: ["logs"], excludes: ["sealed data"]),
            you: .init(goal: "wellness", dailyWaterTargetBottles: 4, bottleOunces: 24, showsCalories: false),
            days: [
                .init(day: "2026-07-11",
                      wellbeing: .init(score: 0.62, state: "Okay", summary: "A steady day."),
                      meals: [.init(name: "Oatmeal", type: "breakfast", calories: 150,
                                    proteinGrams: 5, carbsGrams: 27, fatGrams: 3, note: nil, loggedAt: now)],
                      workouts: nil, sleep: .init(hours: 7.5, quality: "good", note: nil),
                      water: .init(bottles: 3, targetBottles: 4), hygiene: ["teeth"],
                      journal: [.init(feeling: "good", text: "Felt calm today.", emotions: ["calm"], date: now)],
                      health: .init(steps: 6000, activeEnergyKcal: 320, exerciseMinutes: 25,
                                    sleepHours: 7.4, restingHeartRateBPM: 58, heartRateVariabilityMS: 45))
            ],
            coreMemories: [.init(category: "people", note: "Met a friend.", remembered: now)],
            goals: [.init(type: "wellness", goal: "Feel steady", timeframe: nil, metric: nil, milestones: nil, weeklyStructure: nil)],
            recipes: [.init(name: "Soup", servings: 2, ingredients: ["2 cup broth"], notes: nil, createdAt: now)],
            wardrobe: .init(coins: 40, customItems: [.init(name: "Hat", slot: "hat", madeByYou: true, createdAt: now)]),
            friends: [.init(displayName: "Sam", fingerprint: "ab12cd34", status: "friend", friendsSince: now, lastSeen: now)])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FernletDataExport.self, from: try encoder.encode(export))
        XCTAssertEqual(decoded.days.first?.meals?.first?.name, "Oatmeal")
        XCTAssertEqual(decoded.friends.first?.displayName, "Sam")

        let json = try dataJSON(export)
        for token in ["cycle", "intimate", "menstrual", "period", "libido", "ovulation",
                      "sensitive", "worry", "photo", "privatekey"] {
            XCTAssertFalse(json.contains(token), "export vocabulary leaked forbidden token: \(token)")
        }
    }

    /// A day whose Apple Health context carries cycle + intimate data (plus a non-sensitive step
    /// count) exports the steps but strips every cycle/intimate signal.
    func testExportStripsCycleAndIntimateHealthContext() throws {
        let (seedStore, repository, narratives) = makeTestStoreWithRepositories()
        let dayKey = seedStore.todayKey

        var day = FernletDay(date: dayKey)
        day.healthContext = HealthDailyContext(
            activity: HealthActivitySummary(steps: 6000),
            cycle: HealthCycleContext(menstrualFlowEventCount: 3),
            intimate: HealthIntimateContext(eventCount: 1))
        repository.updateDay(day, for: dayKey, todayKey: dayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        let export = store.buildDataExport()

        let exportedDay = export.days.first { $0.day == dayKey }
        XCTAssertEqual(exportedDay?.health?.steps, 6000, "non-sensitive activity should be exported")

        let json = try dataJSON(export)
        for token in ["cycle", "intimate", "menstrual", "ovulation", "eventcount", "flow"] {
            XCTAssertFalse(json.contains(token), "export leaked cycle/intimate token: \(token)")
        }
    }

    /// The share-sheet completion seam (Item A) leans on `purgeDataExports()` to remove the plaintext
    /// dump once the sheet is done with it. Directly: a written export — plus any older lingerer at the
    /// same seam — is swept, without needing a full "delete everything" wipe to run.
    func testPurgeDataExportsSweepsWrittenAndLingeringExports() throws {
        let (store, _, _) = makeTestStoreWithRepositories()

        // The file the user just shared.
        let freshURL = try store.writeDataExportFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path), "precondition: fresh export not written")

        // A lingerer from a previous day's export, in the same directory.
        let staleURL = FernletStore.dataExportsDirectory.appendingPathComponent("Fernlet-data-2026-01-01.json")
        try Data("{}".utf8).write(to: staleURL, options: [.atomic, .completeFileProtection])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleURL.path), "precondition: stale export not written")

        XCTAssertTrue(store.purgeDataExports(), "purge reported failure")

        XCTAssertFalse(FileManager.default.fileExists(atPath: freshURL.path), "the shared export survived the purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path), "a lingering older export survived the purge")
    }

    /// The trainer share sheet's completion handler deletes the ONE file it prepared, not the whole
    /// exports directory: a data export prepared in Privacy & Data may still be in flight. Asserts both
    /// halves — the shared summary is gone, the unrelated export it must not touch survives.
    func testDiscardExportedFileRemovesOnlyTheSharedFile() throws {
        let (store, _, _) = makeTestStoreWithRepositories()
        defer { XCTAssertTrue(store.purgeDataExports(), "cleanup purge reported failure") }

        // Data export first: its write path sweeps the directory, so preparing it second would take the
        // trainer summary with it. Trainer-then-share is the real order a user hits anyway.
        let dataURL = try store.writeDataExportFile()
        let trainerURL = try XCTUnwrap(store.writeTrainerExportFile(options: .coreOnly))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trainerURL.path), "precondition: no trainer summary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path), "precondition: no data export")

        XCTAssertTrue(store.discardExportedFile(at: trainerURL), "discard reported failure")

        XCTAssertFalse(FileManager.default.fileExists(atPath: trainerURL.path),
                       "the shared trainer summary outlived the share")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path),
                      "discarding one export took an unrelated in-flight export with it")

        // Idempotent: a second completion (or a purge that already ran) is success, not failure.
        XCTAssertTrue(store.discardExportedFile(at: trainerURL), "an already-deleted file should report success")
    }

    /// The single-file discard is reachable from a share-sheet completion handler, so it refuses any URL
    /// outside the exports directory rather than becoming an arbitrary-file delete.
    func testDiscardExportedFileRefusesPathsOutsideTheExportsDirectory() throws {
        let (store, _, _) = makeTestStoreWithRepositories()

        let outsider = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-export-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: outsider, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outsider) }

        XCTAssertFalse(store.discardExportedFile(at: outsider), "a file outside the exports directory was accepted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path),
                      "a file outside the exports directory was deleted")
    }

    /// Belt-and-braces: a kill/crash/jettison while the share sheet was up leaves a previous plaintext
    /// dump on disk, so the completion-handler purge never fired. The NEXT export's write path must sweep
    /// that survivor before writing — no two plaintext dumps ever coexist.
    func testWriteDataExportFileSweepsALingeringPriorExport() throws {
        let (store, _, _) = makeTestStoreWithRepositories()

        // A plaintext dump stranded by an interrupted share (a different day's filename, still in the dir).
        let strandedURL = FernletStore.dataExportsDirectory.appendingPathComponent("Fernlet-data-2025-12-31.json")
        try FileManager.default.createDirectory(at: FernletStore.dataExportsDirectory, withIntermediateDirectories: true)
        try Data("{\"stranded\":true}".utf8).write(to: strandedURL, options: [.atomic, .completeFileProtection])
        XCTAssertTrue(FileManager.default.fileExists(atPath: strandedURL.path), "precondition: stranded export not written")

        // Writing a fresh export sweeps the stranded one first, then lands the new file.
        let freshURL = try store.writeDataExportFile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: strandedURL.path),
                       "the stranded prior export survived the next write")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path),
                      "the fresh export should exist after writing")

        // Clean up so the shared tmp/ directory doesn't leak between tests.
        XCTAssertTrue(store.purgeDataExports(), "cleanup purge reported failure")
    }

    /// A user's authored cooking steps (F5) and their planner day-assignments (F3) are their own data, so
    /// "export my data" must carry both: the recipe's `steps` (a step's timer rendered inline) and the
    /// day's `plannedMeals` (recipe names). Guards against the export projection silently dropping either.
    func testExportCarriesRecipeStepsAndPlannedMeals() throws {
        let (store, _, _) = makeTestStoreWithRepositories()

        let recipe = store.addRecipe(
            name: "Ragù",
            servings: 2,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Onion", quantity: 1, unit: "each", protein: 1, carbs: 9, fat: 0)],
            steps: [
                RecipeStep(text: "Chop the onion"),
                RecipeStep(text: "Simmer gently", durationSeconds: 600)
            ])
        // Assign it to today via the planner so the day carries a `plannedRecipeIDs` row.
        store.planRecipe(recipe.id, date: store.todayKey)

        let export = store.buildDataExport()

        let exportedRecipe = try XCTUnwrap(export.recipes.first { $0.name == "Ragù" })
        XCTAssertEqual(exportedRecipe.steps, ["Chop the onion", "Simmer gently (10 min timer)"],
                       "authored cooking steps (with timers) must survive the export")

        let plannedDay = try XCTUnwrap(export.days.first { $0.day == store.todayKey })
        XCTAssertEqual(plannedDay.plannedMeals, ["Ragù"], "planner day-assignment must survive the export")
    }
}
