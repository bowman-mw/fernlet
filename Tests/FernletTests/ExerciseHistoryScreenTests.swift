import XCTest
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// The Exercise history screen's row building (`ExerciseHistoryRowModel` +
/// `TrainerExportBundle.ExerciseHistoryEntry.bestRecallValues`): ordering straight from the rollup
/// (most recently trained first), the per-row value strings against seeded days, and the empty
/// state.
///
/// The parse-and-rollup half is pinned by `CoachPlanExchangeTests`, and the "last time" values line
/// by `ExerciseLastTimeTests` — these tests cover the screen's seam on top: one rollup pass in,
/// display-ready rows out, exactly as `ExerciseHistoryView` builds them.
@MainActor
final class ExerciseHistoryScreenTests: XCTestCase {

    // MARK: - Fixtures (same shape as ExerciseLastTimeTests')

    private func day(_ date: String, exercises: String) -> FernletDay {
        var day = FernletDay(date: date)
        day.workouts = [Workout(name: "Session", type: .upper, exercises: exercises,
                                rpe: nil, notes: "", duration: 40, intensity: .moderate)]
        return day
    }

    /// Rows built the way the screen builds them: ONE rollup pass over the seeded days, then the
    /// straight entry → row mapping.
    private func rows(for days: [FernletDay]) -> [ExerciseHistoryRowModel] {
        ExerciseHistoryRowModel.rows(from: FernletStore.rollUpExerciseHistory(days: days).entries)
    }

    // MARK: - Ordering

    func testRowsOrderedByRecencyNotSeedOrder() {
        let days = [
            day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb"),
            day("2026-08-01", exercises: "Squat - 5 x 5 @ 185 lb"),
            day("2026-08-05", exercises: "Seated row - 3 x 10 @ 90 lb"),
        ]
        // Newest seeded first, so a naive "iteration order" listing would lead with the seed order.
        XCTAssertEqual(rows(for: days).map(\.name), ["Bench press", "Seated row", "Squat"])
    }

    func testSameDayTieBreaksTowardTheMoreOftenLoggedExercise() {
        let days = [
            day("2026-08-01", exercises: "Squat - 5 x 5 @ 185 lb"),
            day("2026-08-08", exercises: "Squat - 5 x 5 @ 190 lb\nBench press - 3 x 8 @ 135 lb"),
        ]
        // Both last logged 2026-08-08; Squat has two sessions to Bench's one.
        XCTAssertEqual(rows(for: days).map(\.name), ["Squat", "Bench press"])
    }

    // MARK: - Per-row fields

    func testRowCarriesLastBestAndFrequencyValues() {
        let days = [
            day("2026-08-01", exercises: "Bench press - 5 x 5 @ 125 lb"),
            day("2026-08-05", exercises: "Bench press - 3 x 3 @ 150 lb"),
            day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb"),
        ]
        guard let row = rows(for: days).first else { return XCTFail("expected one row") }
        XCTAssertEqual(row.name, "Bench press")
        XCTAssertEqual(row.lastLoggedDayKey, "2026-08-08")
        XCTAssertEqual(row.firstLoggedDayKey, "2026-08-01")
        XCTAssertEqual(row.lastValues, "3x8 @ 135 lb", "last means the most recent day, not the heaviest")
        XCTAssertEqual(row.bestValues, "150 lb × 3", "best is the heaviest load, with its reps")
        XCTAssertEqual(row.sessions, 3)
    }

    func testBestFoldsAcrossLinesOfOneDayWhichStaysOneSession() {
        let twoLines = day("2026-08-08",
                           exercises: "Bench press - 3 x 8 @ 135 lb\nBench press - 2 x 5 @ 155 lb")
        guard let row = rows(for: [twoLines]).first else { return XCTFail("expected one row") }
        XCTAssertEqual(row.sessions, 1, "sessions count days, not lines")
        XCTAssertEqual(row.bestValues, "155 lb × 5")
    }

    func testBestOmitsRepsWhenTheyNeverParsedToAPlainNumber() {
        let ranged = day("2026-08-08", exercises: "Lat pulldown - 3 x 8-10 @ 100 lb")
        XCTAssertEqual(rows(for: [ranged]).first?.bestValues, "100 lb",
                       "a rep range has no single count, so the best line states only the load")
    }

    func testWeightlessExerciseHasNoBestLine() {
        let bodyweight = day("2026-08-08", exercises: "Push-up - 3 x 12")
        guard let row = rows(for: [bodyweight]).first else { return XCTFail("expected one row") }
        XCTAssertNil(row.bestValues, "no stated weight must yield no best, not an invented one")
        XCTAssertEqual(row.lastValues, "3x12")
    }

    func testBestUnitFollowsTheStoredUnit() {
        let kg = day("2026-08-08", exercises: "Romanian deadlift - 4 x 8 @ 60kg")
        XCTAssertEqual(rows(for: [kg]).first?.bestValues, "60 kg × 8")
    }

    // MARK: - Empty state

    func testNoDaysYieldsNoRows() {
        XCTAssertTrue(rows(for: []).isEmpty)
    }

    func testDaysWithOnlyUnparseableLinesYieldNoRows() {
        // No sets × reps pattern, so the parser honestly refuses rather than inventing a row.
        let conditioning = day("2026-08-08", exercises: "20 min row")
        XCTAssertTrue(rows(for: [conditioning]).isEmpty)
    }

    // MARK: - Date display

    func testDisplayDateFallsBackToTheRawKeyWhenUnparseable() {
        XCTAssertEqual(ExerciseHistoryRowModel.displayDate(fromDayKey: "not-a-day-key"), "not-a-day-key")
    }

    func testDisplayDateCarriesTheYear() {
        let text = ExerciseHistoryRowModel.displayDate(fromDayKey: "2026-08-08")
        XCTAssertNotEqual(text, "2026-08-08", "a valid key formats, it doesn't echo the token")
        XCTAssertTrue(text.contains("2026"), "a history can span years, so the year must be stated")
    }
}
