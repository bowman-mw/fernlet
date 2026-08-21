import XCTest
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// The row editor's "last time" recall: the per-exercise lookup
/// (`FernletStore.exerciseHistoryEntry(named:days:)`) and the values line it renders
/// (`TrainerExportBundle.ExerciseHistoryEntry.lastTimeRecallValues`).
///
/// The parse-and-rollup half is pinned by `CoachPlanExchangeTests` — these tests only cover the new
/// seam on top of it: name matching across case/whitespace variants, "most recent session" being
/// what the line shows, absence when there is no history, and the unit following the stored unit.
@MainActor
final class ExerciseLastTimeTests: XCTestCase {

    // MARK: - Fixtures (same shape as CoachPlanExchangeTests' rollup fixtures)

    private func day(_ date: String, exercises: String) -> FernletDay {
        var day = FernletDay(date: date)
        day.workouts = [Workout(name: "Session", type: .upper, exercises: exercises,
                                rpe: nil, notes: "", duration: 40, intensity: .moderate)]
        return day
    }

    // MARK: - Lookup

    func testRecallsMostRecentSessionNotIterationOrder() {
        let older = day("2026-08-01", exercises: "Bench press - 5 x 5 @ 125 lb")
        let newer = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")

        // Newest passed first, so a naive "last element wins" fold would show the OLDER session.
        let entry = FernletStore.exerciseHistoryEntry(named: "Bench press", days: [newer, older])
        XCTAssertEqual(entry?.lastSets, 3)
        XCTAssertEqual(entry?.lastReps, "8")
        XCTAssertEqual(entry?.lastWeight, 135)
        XCTAssertEqual(entry?.lastTimeRecallValues, "3x8 @ 135 lb")
    }

    func testMatchesCaseAndWhitespaceVariantsOfTheName() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        for name in ["bench PRESS", "  Bench press  ", "bench  press"] {
            let entry = FernletStore.exerciseHistoryEntry(named: name, days: [logged])
            XCTAssertEqual(entry?.lastWeight, 135, "'\(name)' should match the logged exercise")
        }
    }

    func testNoHistoryYieldsNoEntry() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        XCTAssertNil(FernletStore.exerciseHistoryEntry(named: "Squat", days: [logged]))
        XCTAssertNil(FernletStore.exerciseHistoryEntry(named: "Bench press", days: []))
        XCTAssertNil(FernletStore.exerciseHistoryEntry(named: "   ", days: [logged]),
                     "a blank name must never match anything")
    }

    // MARK: - Recall line

    func testUnitFollowsTheStoredUnit() {
        let kg = day("2026-08-08", exercises: "Romanian deadlift - 4 x 8 @ 60kg")
        let entry = FernletStore.exerciseHistoryEntry(named: "Romanian deadlift", days: [kg])
        XCTAssertEqual(entry?.weightUnit, "kg")
        XCTAssertEqual(entry?.lastTimeRecallValues, "4x8 @ 60 kg")
    }

    func testWeightlessSessionRecallsJustThePrescription() {
        let bodyweight = day("2026-08-08", exercises: "Push-up - 3 x 12")
        let entry = FernletStore.exerciseHistoryEntry(named: "Push-up", days: [bodyweight])
        XCTAssertNil(entry?.lastWeight)
        XCTAssertEqual(entry?.lastTimeRecallValues, "3x12")
    }

    func testRepRangeSurvivesTheRoundTrip() {
        let ranged = day("2026-08-08", exercises: "Lat pulldown - 3 x 8-10 @ 100 lb")
        let entry = FernletStore.exerciseHistoryEntry(named: "Lat pulldown", days: [ranged])
        XCTAssertEqual(entry?.lastTimeRecallValues, "3x8-10 @ 100 lb",
                       "the rep text is recalled as written, not collapsed to a number")
    }
}
