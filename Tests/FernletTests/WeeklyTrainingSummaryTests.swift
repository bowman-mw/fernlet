import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// The Move tab's Weekly totals (comparison report, idea 18): hard sets per muscle group counted
/// from guided results and hand-logged lines (the load engine's two sources), full credit for a
/// primary muscle and half for a secondary one, warm-up stretches, holds, jumps, conditioning and
/// calibration ramps left out, the week starting on the calendar's own first weekday, aerobic minutes
/// from manual and Apple Health rows against the 150-minute guideline, the empty week, and the words
/// VoiceOver reads.
///
/// Set counting runs against a small fixture catalog, so curating the bundled catalog never moves
/// these numbers; one test confirms the bundled catalog is what the screen uses by default.
@MainActor
struct WeeklyTrainingSummaryTests {

    // MARK: - Fixtures

    static let bench = ExerciseTarget(name: "Bench press", primaryMuscles: [.chest], secondaryMuscles: [.triceps, .frontDelts],
                                      equipment: .barbell, movementPattern: .push)
    static let squat = ExerciseTarget(name: "Back squat", primaryMuscles: [.quads, .glutes], secondaryMuscles: [.hamstrings, .abs],
                                      equipment: .barbell, movementPattern: .squat)
    /// Lists the upper back as both primary and secondary, to pin that it counts once.
    static let row = ExerciseTarget(name: "Dumbbell row", primaryMuscles: [.lats, .upperBack], secondaryMuscles: [.biceps, .upperBack],
                                    equipment: .dumbbell, movementPattern: .pull)
    static let plank = ExerciseTarget(name: "Plank", primaryMuscles: [.abs], secondaryMuscles: [.obliques],
                                      equipment: .bodyweight, measure: .seconds)
    static let quadStretch = ExerciseTarget(name: "Standing quad stretch", primaryMuscles: [.quads],
                                            inputKind: .none, modality: .mobility, measure: .seconds)
    static let squatJump = ExerciseTarget(name: "Squat jump", primaryMuscles: [.quads, .glutes], movementPattern: .squat,
                                          inputKind: .none, modality: .power)
    static let burpee = ExerciseTarget(name: "Burpee", primaryMuscles: [.fullBody], movementPattern: .locomotion, modality: .cardio)
    static let catalog = [bench, squat, row, plank, quadStretch, squatJump, burpee]

    /// A Gregorian calendar in the zone day keys are written in, starting its weeks on
    /// `firstWeekday` (1 = Sunday, 2 = Monday).
    func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    func date(_ key: String) throws -> Date {
        try #require(FernletDate.date(fromDayKey: key))
    }

    func days(_ entries: [(String, [Workout])]) -> [String: FernletDay] {
        var days: [String: FernletDay] = [:]
        for (key, workouts) in entries { days[key] = FernletDay(date: key, workouts: workouts) }
        return days
    }

    /// The summary for the week holding `today` (default Tuesday 2026-10-20: its Monday-start week
    /// is Oct 19–25, its Sunday-start week Oct 18–24).
    func summary(
        _ entries: [(String, [Workout])], today: String = "2026-10-20", weeksBack: Int = 0,
        firstWeekday: Int = 2, bundledCatalog: Bool = false
    ) throws -> WeeklyTrainingSummary {
        let todayDate = try date(today)
        let built = WeeklyTrainingSummaryBuilder.summary(
            days: days(entries), today: todayDate, weeksBack: weeksBack,
            calendar: calendar(firstWeekday: firstWeekday), exercises: bundledCatalog ? nil : Self.catalog
        )
        return try #require(built)
    }

    func sets(_ summary: WeeklyTrainingSummary, _ muscle: MuscleGroup) -> Double {
        summary.muscleSets.first { $0.muscle == muscle }?.sets ?? 0
    }

    func handLogged(_ text: String, type: WorkoutType = .upper, minutes: Int? = 40) -> Workout {
        Workout(name: "Session", type: type, exercises: text, rpe: nil, notes: "", duration: minutes, intensity: .moderate)
    }

    func guided(_ results: [ExerciseResult]?, text: String = "", type: WorkoutType = .fullBody, minutes: Int? = 50) -> Workout {
        Workout(name: "Guided", type: type, mode: type == .cardio ? .activity : .strengthTraining, exercises: text,
                rpe: nil, notes: "", duration: minutes, loggedFromGuidedSession: true, intensity: .moderate,
                exerciseResults: results)
    }

    func activity(_ kind: WorkoutActivityType, minutes: Int?, importedFromHealth: Bool = false) -> Workout {
        Workout(name: kind.defaultName, type: kind.fernletCategory, mode: .activity, activityType: kind, exercises: "",
                rpe: nil, notes: "", duration: minutes, healthKitUUID: importedFromHealth ? UUID() : nil, intensity: .moderate)
    }

    func result(_ name: String, sets: Int, reps: Int = 8, actual: [Int]? = nil, calibration: CalibrationStep? = nil) -> ExerciseResult {
        ExerciseResult(name: name, prescribedSets: sets, targetReps: reps, actualReps: actual, calibration: calibration)
    }

    // MARK: - Set counting, by source

    @Test func guidedResultsCountEverySetDoneAndTheRowTextIsNotReadAgain() throws {
        let workout = guided([result("Bench press", sets: 3)], text: "Bench press - 3 x 8 @ 135 lb")
        let week = try summary([("2026-10-20", [workout])])
        #expect(sets(week, .chest) == 3)
        #expect(sets(week, .triceps) == 1.5)
        #expect(sets(week, .frontDelts) == 1.5)
    }

    @Test func editedResultsCountOnlyTheSetsWithReps() throws {
        let week = try summary([("2026-10-20", [guided([result("Bench press", sets: 3, actual: [8, 6, 0])])])])
        #expect(sets(week, .chest) == 2)
    }

    @Test func handLoggedLinesCountTheSetsWrittenRepRangesIncluded() throws {
        let workout = handLogged("Bench press - 3 x 8 @ 135 lb\nback  SQUAT 5x5 @225lb\nBench press - 2 x 8-10")
        let week = try summary([("2026-10-21", [workout])])
        #expect(sets(week, .chest) == 5)
        #expect(sets(week, .quads) == 5)
        #expect(sets(week, .hamstrings) == 2.5)
    }

    @Test func aGuidedRowWithoutResultsIsAPlanNotARecord() throws {
        let markedDone = guided(nil, text: "Bench press - 4 x 5\nBack squat - 3 x 8")
        let week = try summary([("2026-10-20", [markedDone])])
        #expect(week.muscleSets.isEmpty)
    }

    @Test func setsAddUpAcrossTheWeeksDaysAndBothSources() throws {
        let week = try summary([
            ("2026-10-19", [guided([result("Bench press", sets: 4)])]),
            ("2026-10-22", [handLogged("Bench press - 3 x 10")]),
        ])
        #expect(sets(week, .chest) == 7)
        #expect(sets(week, .triceps) == 3.5)
    }

    @Test func theBundledCatalogIsTheDefault() throws {
        let week = try summary([("2026-10-20", [handLogged("Bench press - 3 x 8")])], bundledCatalog: true)
        #expect(sets(week, .chest) == 3)
    }

    // MARK: - Primary and secondary credit

    @Test func primaryMusclesCountInFullAndSecondaryAsHalf() throws {
        let week = try summary([("2026-10-20", [handLogged("Back squat - 4 x 6")])])
        #expect(sets(week, .quads) == 4)
        #expect(sets(week, .glutes) == 4)
        #expect(sets(week, .hamstrings) == 2)
        #expect(sets(week, .abs) == 2)
        #expect(WeeklyTrainingSummaryBuilder.primaryCredit == 1)
        #expect(WeeklyTrainingSummaryBuilder.secondaryCredit == 0.5)
    }

    @Test func aMuscleListedAsBothCountsOnceAsPrimary() throws {
        let week = try summary([("2026-10-20", [handLogged("Dumbbell row - 3 x 10")])])
        #expect(sets(week, .upperBack) == 3)
        #expect(sets(week, .lats) == 3)
        #expect(sets(week, .biceps) == 1.5)
    }

    @Test func rowsFollowTheBodyOrderNotTheCount() throws {
        let week = try summary([("2026-10-20", [handLogged("Zercher squat - 3 x 5\nBench press - 3 x 5")])])
        let expected: [MuscleGroup] = [.chest, .frontDelts, .triceps]
        #expect(week.muscleSets.map(\.muscle) == expected)
    }

    // MARK: - Exclusions

    @Test func stretchesHoldsJumpsAndConditioningAreNotHardSets() throws {
        let text = """
            Warm-up stretch flow - 9 min
            Standing quad stretch - 2 x 30 s
            Plank - 3 x 40 s
            Plank - 3 x 10
            Squat jump - 2 x 4
            Burpee - 3 x 10
            Cool-down stretches - 4 min
            """
        let week = try summary([("2026-10-20", [handLogged(text)])])
        #expect(week.muscleSets.isEmpty)
    }

    @Test func calibrationRampsAreSkippedButTheTestSetCounts() throws {
        let results = [
            result("Back squat", sets: 1, reps: 5, calibration: .ramp),
            result("Back squat", sets: 1, reps: 3, calibration: .ramp),
            result("Back squat", sets: 1, reps: 5, calibration: .test),
        ]
        let copied = handLogged("Back squat - 1 x 5 @ 95 lb (ramp-up)\nBack squat - 1 x 5 @ 185 lb (test set)")
        let week = try summary([("2026-10-20", [guided(results)]), ("2026-10-21", [copied])])
        #expect(sets(week, .quads) == 2)
    }

    @Test func theRampTagIsTheOneTheLogWrites() {
        let line = ExerciseResult(name: "Back squat", prescribedSets: 1, targetReps: 5, calibration: .ramp).loggedLine
        #expect(line.hasSuffix(WeeklyTrainingSummaryBuilder.rampTag))
    }

    // MARK: - Week boundaries

    /// A set count per day, so each day's membership shows in the total: Sun 18 = 1, Mon 19 = 2,
    /// Sun 25 = 4, Mon 26 = 8.
    func boundaryDays() -> [(String, [Workout])] {
        [
            ("2026-10-18", [handLogged("Bench press - 1 x 8")]),
            ("2026-10-19", [handLogged("Bench press - 2 x 8")]),
            ("2026-10-25", [handLogged("Bench press - 4 x 8")]),
            ("2026-10-26", [handLogged("Bench press - 8 x 8")]),
        ]
    }

    @Test func aMondayStartWeekRunsMondayToSunday() throws {
        let week = try summary(boundaryDays(), firstWeekday: 2)
        #expect(FernletDate.dayKey(for: week.weekStart) == "2026-10-19")
        #expect(FernletDate.dayKey(for: week.weekEnd) == "2026-10-25")
        #expect(sets(week, .chest) == 6)
    }

    @Test func aSundayStartWeekRunsSundayToSaturday() throws {
        let week = try summary(boundaryDays(), firstWeekday: 1)
        #expect(FernletDate.dayKey(for: week.weekStart) == "2026-10-18")
        #expect(FernletDate.dayKey(for: week.weekEnd) == "2026-10-24")
        #expect(sets(week, .chest) == 3)
    }

    @Test func aSundayClosesTheMondayWeekButOpensTheSundayWeek() throws {
        let mondayStart = try summary(boundaryDays(), today: "2026-10-18", firstWeekday: 2)
        #expect(FernletDate.dayKey(for: mondayStart.weekStart) == "2026-10-12")
        #expect(sets(mondayStart, .chest) == 1)
        let sundayStart = try summary(boundaryDays(), today: "2026-10-18", firstWeekday: 1)
        #expect(FernletDate.dayKey(for: sundayStart.weekStart) == "2026-10-18")
        #expect(sets(sundayStart, .chest) == 3)
    }

    @Test func steppingBackShowsEarlierWeeksAndStopsAtFour() throws {
        let entries: [(String, [Workout])] = [
            ("2026-10-13", [handLogged("Bench press - 3 x 8")]),
            ("2026-09-21", [handLogged("Bench press - 5 x 5")]),
        ]
        let lastWeek = try summary(entries, weeksBack: 1)
        #expect(FernletDate.dayKey(for: lastWeek.weekStart) == "2026-10-12")
        #expect(sets(lastWeek, .chest) == 3)
        let fourBack = try summary(entries, weeksBack: 4)
        #expect(FernletDate.dayKey(for: fourBack.weekStart) == "2026-09-21")
        #expect(sets(fourBack, .chest) == 5)
        let today = try date("2026-10-20")
        let monday = calendar(firstWeekday: 2)
        #expect(WeeklyTrainingSummaryBuilder.summary(days: [:], today: today, weeksBack: 5, calendar: monday) == nil)
        #expect(WeeklyTrainingSummaryBuilder.summary(days: [:], today: today, weeksBack: -1, calendar: monday) == nil)
    }

    // MARK: - Aerobic minutes

    @Test func aerobicMinutesCountManualAndImportedCardio() throws {
        let imported = activity(.cycling, minutes: 45, importedFromHealth: true)
        #expect(imported.isHealthImported)
        let week = try summary([
            ("2026-10-19", [activity(.running, minutes: 30)]),
            ("2026-10-20", [imported, guided(nil, type: .cardio, minutes: 20)]),
        ])
        #expect(week.aerobicMinutes == 95)
    }

    /// Apple Health imports are device-local (they live in the residue cache, not the synced day), so
    /// this goes through a real store: `loadDays()` — what the screen reads — must hand them back.
    @Test func importedHealthWorkoutsReachTheWeekThroughTheStoresHistory() throws {
        let today = try date("2026-10-20")
        let store = makeTestStore(date: today)
        store.upsertWorkout(activity(.walking, minutes: 42, importedFromHealth: true), date: "2026-10-19")
        store.upsertWorkout(activity(.hiit, minutes: 20, importedFromHealth: true), date: "2026-10-20")
        store.upsertWorkout(activity(.running, minutes: 30), date: "2026-10-20")
        store.flushPendingSnapshotSave()
        let built = WeeklyTrainingSummaryBuilder.summary(
            days: store.loadDays(), today: today, weeksBack: 0, calendar: calendar(firstWeekday: 2), exercises: Self.catalog
        )
        let week = try #require(built)
        #expect(week.aerobicMinutes == 92)
    }

    @Test func strengthYogaAndPilatesMinutesAreNotAerobic() throws {
        let importedStrength = Workout(name: "Traditional Strength Training", type: .fullBody, exercises: "", rpe: nil,
                                       notes: "", duration: 50, healthKitUUID: UUID(), intensity: .moderate)
        let week = try summary([
            ("2026-10-20", [activity(.yoga, minutes: 60), activity(.pilates, minutes: 45), importedStrength,
                            guided([result("Bench press", sets: 3)], minutes: 55),
                            handLogged("Bench press - 3 x 8", minutes: 40)]),
        ])
        #expect(week.aerobicMinutes == 0)
    }

    @Test func danceAndStrikingArtsCountAsAerobic() throws {
        let week = try summary([("2026-10-21", [activity(.socialDance, minutes: 40), activity(.martialArts, minutes: 30)])])
        #expect(week.aerobicMinutes == 70)
    }

    @Test func legacyRunsAndRowsFiledUnderCardioCount() throws {
        let legacyRun = handLogged("Couch to 10K week 3", type: .run, minutes: 25)
        let cardioRow = handLogged("Treadmill", type: .cardio, minutes: 15)
        let week = try summary([("2026-10-21", [legacyRun, cardioRow])])
        #expect(week.aerobicMinutes == 40)
    }

    @Test func anAerobicRowWithNoDurationAddsNothing() throws {
        let week = try summary([("2026-10-21", [activity(.running, minutes: nil), activity(.walking, minutes: -5)])])
        #expect(week.aerobicMinutes == 0)
    }

    /// The sports added in round 2 (R5) count as well: a team or snow sport by its cardio category, and
    /// boxing, wrestling, golf and surfing as moderate on the Compendium.
    @Test func theAddedSportsCountAsAerobic() throws {
        let week = try summary([("2026-10-21", [
            activity(.volleyball, minutes: 30), activity(.downhillSkiing, minutes: 45), activity(.boxing, minutes: 20),
            activity(.wrestling, minutes: 10), activity(.golf, minutes: 60), activity(.surfing, minutes: 25),
        ])])
        #expect(week.aerobicMinutes == 190)
    }

    // MARK: - No data

    @Test func aWeekWithNothingLoggedHasNoRowsAndNoMinutes() throws {
        let earlier = try summary([("2026-10-12", [handLogged("Bench press - 3 x 8"), activity(.running, minutes: 30)])])
        #expect(earlier.muscleSets.isEmpty)
        #expect(earlier.aerobicMinutes == 0)
        let nothing = try summary([])
        #expect(nothing.muscleSets.isEmpty)
        #expect(nothing.aerobicMinutes == 0)
    }

    // MARK: - What VoiceOver reads, and what the screen draws

    @Test func setCountsReadAsANumberWithItsNoun() {
        #expect(WeeklyTotalsCopy.setsNumber(12) == "12")
        #expect(WeeklyTotalsCopy.setsNumber(9.5) == "9.5")
        #expect(WeeklyTotalsCopy.setsValue(12) == "12 hard sets")
        #expect(WeeklyTotalsCopy.setsValue(9.5) == "9.5 hard sets")
        #expect(WeeklyTotalsCopy.setsValue(0.5) == "0.5 hard sets")
        #expect(WeeklyTotalsCopy.setsValue(1) == "1 hard set")
    }

    @Test func eachRowSpeaksItsMuscleThenItsCount() throws {
        let week = try summary([("2026-10-20", [handLogged("Bench press - 3 x 8")])])
        let spoken = week.muscleSets.map { "\($0.muscle.displayName), \(WeeklyTotalsCopy.setsValue($0.sets))" }
        let expected = ["Chest, 3 hard sets", "Front Delts, 1.5 hard sets", "Triceps, 1.5 hard sets"]
        #expect(spoken == expected)
    }

    @Test func aerobicMinutesReadAgainstTheGuideline() {
        #expect(WeeklyTotalsCopy.aerobicLine(minutes: 95) == "95 of 150 minutes")
        #expect(WeeklyTotalsCopy.aerobicSpoken(minutes: 95) == "95 of 150 aerobic minutes")
        #expect(WeeklyTotalsCopy.aerobicFraction(minutes: 75) == 0.5)
        #expect(WeeklyTotalsCopy.aerobicFraction(minutes: 300) == 1)
        #expect(WeeklyTotalsCopy.aerobicFraction(minutes: 0) == 0)
    }

    @Test func theReferenceLinesStateTheRangesPlainly() {
        #expect(WeeklyTotalsCopy.setsReference == "10–20 hard sets a week per muscle is a common range for muscle growth.")
        #expect(WeeklyTotalsCopy.aerobicReference
            == "The WHO guideline for adults is at least 150 minutes of moderate activity a week, or 75 minutes of vigorous activity.")
    }

    @Test func theWeekRangeNamesItsFirstAndLastDays() throws {
        let week = try summary([])
        let range = WeeklyTotalsCopy.weekRange(start: week.weekStart, end: week.weekEnd)
        #expect(range.contains("19"))
        #expect(range.contains("25"))
    }
}
