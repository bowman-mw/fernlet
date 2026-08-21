import XCTest
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// The guided workout editor's per-card "last time" recall
/// (`GuidedWorkoutEditorSheet.lastTimeRecall(names:days:)`): which row names get a recall value,
/// which are absent (so their card renders no line), and the map being keyed the way the cards
/// look their own names up.
///
/// The lookup and line-formatting halves are pinned by `ExerciseLastTimeTests` — these tests only
/// cover the editor's map on top of them: keying by the row's own spelling, absence for
/// never-logged rows, duplicates folding to one entry, and the values matching the shared row
/// editor's line exactly.
@MainActor
final class GuidedEditorLastTimeTests: XCTestCase {

    // MARK: - Fixtures (same shape as ExerciseLastTimeTests')

    private func day(_ date: String, exercises: String) -> FernletDay {
        var day = FernletDay(date: date)
        day.workouts = [Workout(name: "Session", type: .upper, exercises: exercises,
                                rpe: nil, notes: "", duration: 40, intensity: .moderate)]
        return day
    }

    // MARK: - Presence

    func testLoggedRowGetsTheSharedRecallValues() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        let map = GuidedWorkoutEditorSheet.lastTimeRecall(names: ["Bench press"], days: [logged])
        XCTAssertEqual(map["Bench press"], "3x8 @ 135 lb",
                       "the guided card must show the exact line the shared row editor shows")
    }

    func testWeightlessHistoryRecallsJustThePrescription() {
        let bodyweight = day("2026-08-08", exercises: "Push-up - 3 x 12")
        let map = GuidedWorkoutEditorSheet.lastTimeRecall(names: ["Push-up"], days: [bodyweight])
        XCTAssertEqual(map["Push-up"], "3x12")
    }

    func testMostRecentSessionWinsThroughTheEditorSeam() {
        let older = day("2026-08-01", exercises: "Bench press - 5 x 5 @ 125 lb")
        let newer = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        // Newest passed first, so a naive "last element wins" fold would show the OLDER session.
        let map = GuidedWorkoutEditorSheet.lastTimeRecall(names: ["Bench press"],
                                                          days: [newer, older])
        XCTAssertEqual(map["Bench press"], "3x8 @ 135 lb")
    }

    // MARK: - Absence

    func testNeverLoggedRowIsAbsentSoNoLineRenders() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        let map = GuidedWorkoutEditorSheet.lastTimeRecall(names: ["Bench press", "Squat"],
                                                          days: [logged])
        XCTAssertEqual(map["Bench press"], "3x8 @ 135 lb")
        XCTAssertNil(map["Squat"], "a never-logged exercise must render no recall line")
    }

    func testNoRowsYieldAnEmptyMap() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        XCTAssertEqual(GuidedWorkoutEditorSheet.lastTimeRecall(names: [], days: [logged]), [:])
    }

    func testNoHistoryAtAllYieldsAnEmptyMap() {
        XCTAssertEqual(GuidedWorkoutEditorSheet.lastTimeRecall(names: ["Bench press"], days: []),
                       [:])
    }

    // MARK: - Keying

    func testMapIsKeyedByTheRowsOwnSpelling() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        let map = GuidedWorkoutEditorSheet.lastTimeRecall(names: ["bench PRESS"], days: [logged])
        XCTAssertEqual(map["bench PRESS"], "3x8 @ 135 lb",
                       "the card looks values up by the row's spelling, so that must be the key")
        XCTAssertNil(map["Bench press"], "no phantom entry under the logged spelling")
    }

    func testDuplicateAndBlankNamesStayHarmless() {
        let logged = day("2026-08-08", exercises: "Bench press - 3 x 8 @ 135 lb")
        let map = GuidedWorkoutEditorSheet.lastTimeRecall(
            names: ["Bench press", "Bench press", "   ", ""], days: [logged])
        XCTAssertEqual(map, ["Bench press": "3x8 @ 135 lb"],
                       "duplicates fold to one entry; blank names never match anything")
    }
}
