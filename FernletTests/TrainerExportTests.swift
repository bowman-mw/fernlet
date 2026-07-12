import XCTest
import FernletDomainModel
import ProximityKit
@testable import Fernlet

/// Trainer / Nutritionist export (Phase 7). Proves the curated bundle carries workouts + nutrition and is
/// FAIL-CLOSED against every hard-excluded category, that opt-in sections stay out until chosen, and that
/// the wire payload round-trips + is bounded. (The "sealed on the wire" contract is asserted in
/// `FernletIdentityEnvelopeTests.trainerExportEnvelopeRejectsUnsealedPayload`.)
@MainActor
final class TrainerExportTests: XCTestCase {

    /// Encodes the data-bearing sections only (the `about` readme deliberately NAMES the excluded
    /// categories, so it is blanked before the forbidden-token scan — mirrors `DataExportTests`).
    private func bundleJSON(_ bundle: TrainerExportBundle) throws -> String {
        var scan = bundle
        scan.about = .init(exportedOn: "", preparedFor: "", note: "", includes: [], neverIncludes: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(scan), encoding: .utf8)!.lowercased()
    }

    /// A day carrying workouts + nutrition + cycle/intimate health context. The widest possible bundle
    /// (every optional toggled on) must include the training data and provably exclude every hard-walled
    /// category.
    func testTrainerBundleIncludesTrainingDataAndExcludesSensitive() throws {
        let (seedStore, repository, narratives) = makeTestStoreWithRepositories()
        let dayKey = seedStore.todayKey
        let meal = seedStore.addMeal(from: "chicken breast 6oz", type: .lunch)
        let workout = Workout(
            name: "Leg day", type: WorkoutType.allCases.first!,
            exercises: "Squat 3x5 @185\nLunge 3x10", rpe: 8, notes: "solid session",
            duration: 45, intensity: WorkoutIntensity.allCases.first!)

        var day = FernletDay(date: dayKey)
        day.meals = [meal]
        day.workouts = [workout]
        day.healthContext = HealthDailyContext(
            activity: HealthActivitySummary(steps: 6000),
            cycle: HealthCycleContext(menstrualFlowEventCount: 3),
            intimate: HealthIntimateContext(eventCount: 1))
        repository.updateDay(day, for: dayKey, todayKey: dayKey)

        let store = makeStoreSharingStores(repository: repository, narratives: narratives)
        var options = TrainerExportOptions()
        options.includeGoal = true; options.includeHydration = true; options.includeSleep = true
        options.includeSickness = true; options.includeWellbeing = true
        let bundle = store.buildTrainerExport(options: options)

        let exportedDay = bundle.days.first { $0.day == dayKey }
        XCTAssertEqual(exportedDay?.workouts?.first?.name, "Leg day", "workouts must be included")
        XCTAssertNotNil(exportedDay?.nutrition, "the nutrition summary must be included")
        XCTAssertGreaterThan(exportedDay?.nutrition?.totalCalories ?? 0, 0, "nutrition should carry logged calories")

        let json = try bundleJSON(bundle)
        for token in ["cycle", "intimate", "menstrual", "ovulation", "libido", "period", "flow", "eventcount",
                      "journal", "sensitive", "worry", "photo", "privatekey", "friend"] {
            XCTAssertFalse(json.contains(token), "trainer bundle leaked forbidden token: \(token)")
        }
    }

    /// Opt-in categories stay out of the bundle until the user toggles them on.
    func testOptionalCategoriesOmittedUntilSelected() throws {
        let (seedStore, repository, narratives) = makeTestStoreWithRepositories()
        let dayKey = seedStore.todayKey
        let meal = seedStore.addMeal(from: "oatmeal", type: .breakfast)
        var day = FernletDay(date: dayKey)
        day.meals = [meal]
        day.bottleCount = 3
        day.sleep = SleepLog(hours: 7.5, quality: .good, note: "rested")
        repository.updateDay(day, for: dayKey, todayKey: dayKey)
        let store = makeStoreSharingStores(repository: repository, narratives: narratives)

        let core = try bundleJSON(store.buildTrainerExport(options: .coreOnly))
        for token in ["hydration", "\"sleep\"", "wellbeing", "wassick"] {
            XCTAssertFalse(core.contains(token), "core-only bundle should omit \(token)")
        }

        var opted = TrainerExportOptions()
        opted.includeHydration = true; opted.includeSleep = true
        let optedJSON = try bundleJSON(store.buildTrainerExport(options: opted))
        XCTAssertTrue(optedJSON.contains("hydration"), "opted-in hydration should appear")
        XCTAssertTrue(optedJSON.contains("\"sleep\""), "opted-in sleep should appear")
    }

    /// The wire payload round-trips and rejects an empty / oversized bundle.
    func testTrainerExportPayloadRoundTripAndBounds() throws {
        let bundle = Data("{\"days\":[]}".utf8)
        let payload = TrainerExportPayload(bundle: bundle)
        XCTAssertTrue(payload.isWellFormed)
        let decoded = try JSONDecoder().decode(TrainerExportPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.bundle, bundle)

        XCTAssertFalse(TrainerExportPayload(bundle: Data()).isWellFormed, "empty bundle is rejected")
        XCTAssertFalse(TrainerExportPayload(bundle: Data(count: TrainerExportPayload.maxBundleBytes + 1)).isWellFormed,
                       "oversized bundle is rejected")
    }
}
