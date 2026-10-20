import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// Pins where load-aware progression meets the app: the day plan's load pass (weight ranges, the
/// "add weight now" reset, the plateau ladder — a fair retest up front, then a heavier block — the
/// dip's deload, and the monthly calibration), the runner's tracking from plan to log, and the context
/// the planner reads from the day history, with each session's sleep and readiness flag.
@MainActor
struct WorkoutLoadPlanningTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    static let pushSplit = TrainingSplit(
        id: "probe", name: "Probe", summary: "", specificity: .balanced, goalFit: [.wellness],
        days: [WorkoutSplitDay(title: "Push", sessions: [WorkoutSessions.push])]
    )

    func pushSession(
        history: [String: [LiftExposure]] = [:], today: Int = 30,
        calibration: CalibrationSettings = CalibrationSettings(hasCoach: true),
        progression: [String: Int] = [:], useLoad: Bool = true, experience: ExperienceLevel? = nil,
        liftWeeks: [String: Double] = [:], goal: GoalType = .wellness, traits: LifterTraits = .unknown,
        focus: WorkoutStrengthFocus = .both
    ) throws -> WorkoutProgram.SessionSuggestion {
        let load = WorkoutLoadContext(exposures: history, today: day(today), defaultUnit: .lb, calibration: calibration,
                                      traits: traits, experience: experience, liftWeeks: liftWeeks, focus: focus)
        let plan = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: Self.pushSplit, rotationIndex: 0,
            progression: progression, load: useLoad ? load : nil
        )
        return try #require(plan.sessions.first)
    }

    func lifting(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == .lifting }
    }

    func key(_ name: String) -> String { WorkoutExerciseCatalog.normalizedName(name) }

    func session(_ offset: Int, _ weight: Double, reps: Int, target: Int, effort: ExerciseEffort? = nil) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: .lb, targetReps: target,
                     repsPerSet: [reps, reps, reps], effort: effort, rangeLow: weight - 10, rangeHigh: weight + 10,
                     structured: true)
    }

    /// Three sessions a week (days 0, 2 and 4) of fives: six weeks climbing 5 lb a week from 100 lb,
    /// then `flatWeeks` weeks flat at 130 lb. With an inferred training age the trend calls the stall
    /// after nine flat weeks, and reads it as slowing for the first few (``WorkoutTrend``;
    /// `Tools/plateau-sim/swift_mirror.py` replays it).
    func climbThenFlat(flatWeeks: Int) -> [LiftExposure] {
        (0..<(6 + flatWeeks)).flatMap { week in
            [0, 2, 4].map { session(week * 7 + $0, 100 + 5 * Double(min(week, 6)), reps: 5, target: 5) }
        }
    }

    /// Six weeks climbing, then two sessions well under the line (125 lb × 3 against 5 asked) — a dip,
    /// or with `flag` two low sessions after short nights.
    func dipped(flag: WorkoutSessionFlag? = nil) -> [LiftExposure] {
        let climbing = (0..<6).flatMap { week in
            [0, 2, 4].map { session(week * 7 + $0, 100 + 5 * Double(week), reps: 5, target: 5) }
        }
        let low = [42, 44].map { offset -> LiftExposure in
            var missed = session(offset, 125, reps: 3, target: 5)
            missed.flag = flag
            return missed
        }
        return climbing + low
    }

    // MARK: - The load pass

    @Test func liftsWithoutHistoryAskForAFirstWeight() throws {
        let session = try pushSession()
        let main = try #require(lifting(session).first)
        let guidance = try #require(main.guidance)
        #expect(guidance.isLoadable)
        #expect(guidance.prescription == nil)
        #expect(session.suggestion.notes.contains("New lifts: pick a weight you could lift about 2 more times than asked"))
    }

    @Test func aLiftAtTheTopOfItsRangeSaysAddWeightNow() throws {
        let main = try #require(lifting(try pushSession()).first).name
        let session = try pushSession(history: [key(main): [session(28, 135, reps: 12, target: 12)]])
        let lift = try #require(lifting(session).first)
        #expect(lift.name == main)
        #expect(lift.reps == "8")
        #expect(lift.guidance?.prescription?.suggested == 140)
        #expect(session.suggestion.notes.contains("\(main): back to 8 reps — add weight now (140 lb)."))
    }

    @Test func theCountBasedLadderNoLongerClaimsAWeek() throws {
        let main = try #require(lifting(try pushSession(useLoad: false)).first).name
        let notes = try pushSession(progression: [main: 2], useLoad: false).suggestion.notes
        #expect(!notes.contains("Week"))
        #expect(notes.contains("Rep ladder: 10 of 8–12 today. One more rep each time; at 12, add weight."))
        let reset = try pushSession(progression: [main: 5], useLoad: false).suggestion.notes
        #expect(reset.contains("Back to 8 reps — add weight now, about 2.5–5%."))
    }

    @Test func aStallStartsWithAFairRetestUpFrontWithLongerRest() throws {
        let second = lifting(try pushSession(goal: .strength))[1]
        let session = try pushSession(history: [key(second.name): climbThenFlat(flatWeeks: 9)], today: 104, goal: .strength)
        let first = try #require(lifting(session).first)
        #expect(first.name == second.name)
        let rest = try #require(first.restSecondsOverride)
        #expect(rest >= WorkoutPlateau.retestRestSeconds)
        #expect(first.guidance?.easierSession == false)
        let notes = session.suggestion.notes
        #expect(notes.contains("\(second.name) has held steady for"))
        #expect(notes.contains("Today \(second.name) goes first, with at least 3 minutes' rest between sets — a fair retest."))
        #expect(!notes.contains("helper muscles") && !notes.contains("Sleep has averaged"))
    }

    @Test func theLoadingChangeIsAShortHeavierBlock() throws {
        let main = try #require(lifting(try pushSession(goal: .strength)).first).name
        let session = try pushSession(history: [key(main): climbThenFlat(flatWeeks: 10)], today: 111, goal: .strength)
        let lift = try #require(lifting(session).first { $0.name == main })
        // The plan's next step is 5 reps at 135 lb; the block takes two reps off and loads the estimate
        // for 3 (130 × (1 + 7/30) ÷ (1 + 5/30) ≈ 137, on the 5 lb step), never under today's 135.
        #expect(lift.reps == "3")
        #expect(lift.guidance?.targetReps == 3)
        #expect(lift.guidance?.prescription?.suggested == 135)
        #expect(session.suggestion.notes.contains("For the next few sessions, \(main) goes a little heavier for fewer reps — 3 reps at about 135 lb."))
    }

    @Test func aDipGetsADeloadHalfTheSetsAtTheKeptLoad() throws {
        let main = try #require(lifting(try pushSession(goal: .strength)).first)
        let session = try pushSession(history: [key(main.name): dipped()], today: 46, goal: .strength)
        let lift = try #require(lifting(session).first { $0.name == main.name })
        #expect(lift.sets == (main.sets + 1) / 2)
        #expect(lift.guidance?.easierSession == true)
        #expect(lift.guidance?.prescription?.suggested == 125)
        let notes = session.suggestion.notes
        #expect(notes.contains("\(main.name) came in a little lower the last two times."))
        #expect(notes.contains("Today is a lighter \(main.name) session: 2 sets at the usual weight, about 125 lb."))
    }

    @Test func lowSessionsAfterShortNightsHoldTheLoadWithNoDeload() throws {
        let main = try #require(lifting(try pushSession(goal: .strength)).first)
        let session = try pushSession(history: [key(main.name): dipped(flag: WorkoutSessionFlag(sleep: .shortNight))],
                                      today: 46, goal: .strength)
        let lift = try #require(lifting(session).first { $0.name == main.name })
        #expect(lift.sets == main.sets)
        #expect(lift.guidance?.easierSession == false)
        #expect(lift.guidance?.prescription?.suggested == 125)
        #expect(!session.suggestion.notes.contains("came in a little lower"))
    }

    @Test func theTrainingAgeAnswerIsAFloorThatEachLiftsLogRaises() {
        func age(_ experience: ExperienceLevel?, weeks: Double) -> TrainingAge? {
            WorkoutLoadContext(exposures: [:], today: day(0), defaultUnit: .lb, experience: experience,
                               liftWeeks: [key("Bench press"): weeks]).trainingAge(for: "Bench press")
        }
        #expect(age(.intermediate, weeks: 4) == TrainingAge(weeks: 26))
        #expect(age(.intermediate, weeks: 60) == TrainingAge(weeks: 60))
        let advanced = age(.advanced, weeks: 4)
        #expect(advanced == TrainingAge(weeks: 104))
        // "Under 6 months" — also the default nobody changed — stays inferred, from the lift's own log.
        let beginner = age(.beginner, weeks: 30)
        #expect(beginner == TrainingAge(weeks: 30, isInferred: true))
        let tier = beginner.map(\.tier)
        #expect(tier == .intermediate)
        #expect(age(nil, weeks: 30) == nil)
    }

    @Test func pastSixMonthsTheMainLiftRepeatsUntilTwoGoodSessionsInARow() throws {
        let main = try #require(lifting(try pushSession()).first).name
        let history = [key(main): [session(28, 135, reps: 9, target: 9)]]
        let session = try pushSession(history: history, experience: .intermediate)
        let lift = try #require(lifting(session).first { $0.name == main })
        #expect(lift.reps == "9")
        #expect(session.suggestion.notes.contains("\(main): the same again today — one more session like the last, and it moves on."))
        let novice = try pushSession(history: history, experience: .beginner)
        let noviceLifts = lifting(novice)
        let noviceLift = try #require(noviceLifts.first { $0.name == main })
        #expect(noviceLift.reps == "10")
    }

    @Test func eachLiftsTrainingAgeIsReadFromItsFirstLoggedSession() throws {
        func row(_ offset: Int) -> FernletDay {
            FernletDay(date: FernletDate.dayKey(for: day(offset)), workouts: [
                Workout(name: "Push", type: .upper, exercises: "Bench press 3x8 @100 lb", rpe: nil, notes: "",
                        duration: nil, intensity: .moderate),
            ])
        }
        let todayKey = FernletDate.dayKey(for: day(400))
        let days = [row(100), row(390)]
        let context = WorkoutLoadContextBuilder.build(
            days: Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) }), today: FernletDay(date: todayKey),
            todayKey: todayKey, settings: FernletSettings(), locale: Locale(identifier: "en_US")
        )
        let weeks = try #require(context.liftWeeks[key("Bench press")])
        #expect(abs(weeks - 300.0 / 7) < 0.2)
        #expect(context.experience == FernletSettings().workoutProfile.experience)
    }

    @Test func aDueCalibrationTurnsTheMainLiftIntoARampAndATest() throws {
        let baseline = try pushSession(goal: .strength)
        let main = try #require(lifting(baseline).first).name
        let history = [key(main): [session(21, 135, reps: 10, target: 10), session(28, 135, reps: 10, target: 10)]]
        // Strength and sports prep keep the monthly strength check (G7).
        let session = try pushSession(history: history, calibration: CalibrationSettings(), goal: .strength)
        let steps = lifting(session).filter { $0.name == main }
        #expect(steps.map(\.guidance?.calibration) == [.ramp, .ramp, .ramp, .test])
        #expect(steps.first?.line.hasSuffix("(ramp-up)") == true)
        let accessorySets = { (s: WorkoutProgram.SessionSuggestion) in lifting(s).filter { $0.role == .accessory }.map(\.sets) }
        let uncalibrated = try pushSession(history: history, goal: .strength)
        #expect(accessorySets(session) == accessorySets(uncalibrated).map { max(1, $0 - 1) })
        #expect(session.suggestion.notes.contains("Strength check today: \(main) builds up over a few lighter sets"))
    }

    // MARK: - The runner, plan to log

    func bench(selected: Double? = nil, calibration: CalibrationStep? = nil) -> PrescribedExercise {
        let weight = WeightPrescription(low: 95, high: 110, suggested: 100, step: 5, unit: .lb, confidence: .low)
        return PrescribedExercise(
            name: "Bench press", sets: 3, reps: "8", role: .main, fromCatalog: true,
            guidance: LoadGuidance(targetReps: 8, prescription: weight, equipment: .barbell, unit: .lb, calibration: calibration)
        )
    }

    func runState(_ steps: [PrescribedExercise]) -> GuidedWorkoutRunState {
        let exercises = steps.map {
            GuidedWorkoutRunState.Exercise(
                id: $0.id, name: $0.name, sets: $0.sets, reps: $0.reps, roleRaw: "main", fromCatalog: $0.fromCatalog,
                restSeconds: 90, holdSeconds: $0.holdSeconds, blockRaw: $0.block.rawValue,
                tracking: GuidedRunLoadLog.tracking(for: $0)
            )
        }
        return GuidedWorkoutRunState(sessionID: UUID(), committedDayKey: "2026-10-19", intensityRaw: "moderate",
                                     title: "Push", suggestionExercisesText: "", suggestionNotes: "",
                                     sessionKindRaw: "strength", exercises: exercises)
    }

    @Test func guidanceBecomesRunTrackingWithTheSuggestionPicked() throws {
        let tracking = try #require(GuidedRunLoadLog.tracking(for: bench()))
        #expect(tracking.selected == 100)
        #expect((tracking.rangeLow, tracking.rangeHigh, tracking.step) == (95, 110, 5))
        #expect((tracking.unitRaw, tracking.confidenceRaw) == ("lb", "low"))
        #expect(tracking.isLoadable)
        let test = try #require(GuidedRunLoadLog.tracking(for: bench(calibration: .test)))
        #expect(test.rangeLow == nil && test.calibrationRaw == "test")
    }

    @Test func runTrackingSnapsWeightsAndClearsOnTargetEdits() throws {
        var state = runState([bench()])
        let id = try #require(state.exercises.first).id
        state.selectWeight(102, forExercise: id)
        #expect(state.exercises[0].tracking?.selected == 100)
        state.selectWeight(120, forExercise: id)
        #expect(state.exercises[0].tracking?.isOutsideRange == true)
        state.setActualReps([8, 8, 6], forExercise: id)
        #expect(state.exercises[0].tracking?.actualReps == [8, 8, 6])
        state.setActualReps([8, 8, 8], forExercise: id)
        #expect(state.exercises[0].tracking?.actualReps == nil)
    }

    @Test func aMissedMaxAttemptSkipsTheRest() {
        let attempts = (0..<3).map { _ in bench(calibration: .attempt) }
        var state = runState(attempts + [PrescribedExercise(name: "Triceps pushdown", sets: 3, reps: "10", role: .accessory, fromCatalog: true)])
        state.setActualReps([0], forExercise: state.exercises[0].id)
        #expect(state.exercises.map(\.name) == ["Bench press", "Triceps pushdown"])
    }

    @Test func aFinishedRunLogsWhatWasLiftedAndNotWhatWasSkipped() throws {
        let stretch = PrescribedExercise(name: "Standing forward fold", sets: 1, reps: "20 s", role: .accessory,
                                         fromCatalog: true, block: .warmUp, holdSeconds: 20)
        var press = bench()
        press.name = "Overhead press"
        var state = runState([stretch, bench(), press])
        state.selectWeight(105, forExercise: state.exercises[1].id)
        state.exerciseIndex = 2
        state.markCurrentSkipped()
        let log = try #require(GuidedRunLoadLog.log(for: state))
        #expect(log.text.contains("Warm-up stretch flow"))
        #expect(log.text.contains("Bench press - 3 x 8 @ 105 lb"))
        #expect(log.text.contains("Overhead press - skipped"))
        #expect(log.results.map(\.name) == ["Bench press"])
        #expect(log.results.first?.selectedWeight == 105)
        #expect(log.results.first?.wasEdited == false)
    }

    // MARK: - The planner's context

    @Test func theContextReadsResultsAndHandLogsButNeverGuidedPlanText() throws {
        func workout(_ text: String, guided: Bool, results: [ExerciseResult]? = nil) -> Workout {
            Workout(name: "Push", type: .upper, exercises: text, rpe: nil, notes: "", duration: nil,
                    loggedFromGuidedSession: guided ? true : nil, intensity: .moderate, exerciseResults: results)
        }
        let structured = ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8, selectedWeight: 100, unit: .lb)
        let test = ExerciseResult(name: "Bench press", prescribedSets: 1, targetReps: 5, selectedWeight: 125, unit: .lb, calibration: .test)
        let sleep = SleepLog(hours: 6, quality: .ok, note: "")
        let days = [
            FernletDay(date: FernletDate.dayKey(for: day(20)), workouts: [workout("", guided: true, results: [structured])], sleep: sleep),
            FernletDay(date: FernletDate.dayKey(for: day(21)), workouts: [workout("Bench press - 3 x 8", guided: true)], sleep: sleep),
            FernletDay(date: FernletDate.dayKey(for: day(22)), workouts: [workout("Bench press 3x8 @135 lb\nBench press 1x5 @145 lb", guided: false)], sleep: sleep),
            FernletDay(date: FernletDate.dayKey(for: day(25)), workouts: [workout("", guided: true, results: [test])]),
        ]
        let todayKey = FernletDate.dayKey(for: day(30))
        let context = WorkoutLoadContextBuilder.build(
            days: Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) }), today: FernletDay(date: todayKey),
            todayKey: todayKey, settings: FernletSettings(), locale: Locale(identifier: "en_US")
        )
        let bench = context.history(for: "Bench press")
        #expect(bench.map(\.weight) == [100, 145, 125])
        #expect(bench.map(\.structured) == [true, false, true])
        #expect(context.calibration.lastCalibration == FernletDate.date(fromDayKey: FernletDate.dayKey(for: day(25))))
        #expect(context.defaultUnit == .lb)
        // Six hours the night before is a short night; two in a row (days 21 and 22) the firmer flag.
        let sleeps = bench.map { $0.flag?.sleep }
        let expected: [SleepFlag?] = [.shortNight, .shortNights, nil]
        #expect(sleeps == expected)
        #expect(WorkoutLoadContextBuilder.defaultUnit(for: Locale(identifier: "de_DE")) == .kg)
    }

    @Test func theSleepFlagReadsSixHoursAndTheMedianAndALightDayFlagsToo() throws {
        let session = day(30)
        var nights: [String: Double] = [:]
        for back in 1...14 { nights[FernletDate.dayKey(for: day(30 - back))] = 8.5 }
        // Median 8.5 h: 7 h is 90 minutes under it, 7.2 h is not; 6 h is short whatever the median.
        nights[FernletDate.dayKey(for: session)] = 7.0
        #expect(WorkoutLoadContextBuilder.sleepFlag(on: session, nights: nights) == .shortNight)
        nights[FernletDate.dayKey(for: session)] = 7.2
        #expect(WorkoutLoadContextBuilder.sleepFlag(on: session, nights: nights) == nil)
        nights[FernletDate.dayKey(for: session)] = 6.0
        nights[FernletDate.dayKey(for: day(29))] = 6.0
        #expect(WorkoutLoadContextBuilder.sleepFlag(on: session, nights: nights) == .shortNights)
        // A night with nothing logged is never short.
        #expect(WorkoutLoadContextBuilder.sleepFlag(on: day(60), nights: nights) == nil)

        let light = Workout(name: "Push", type: .upper, exercises: "Bench press 3x8 @100 lb", rpe: nil, notes: "",
                            duration: nil, intensity: .light)
        let row = FernletDay(date: FernletDate.dayKey(for: day(20)), workouts: [light])
        let context = WorkoutLoadContextBuilder.exposures([(row, day(20))])
        let flag = try #require(context.byLift[key("Bench press")]?.first?.flag)
        #expect(flag.lightDay && flag.sleep == nil)
    }

    // MARK: - Food (G11, G12, G13)

    /// G11: the builder reads the last two weeks' protein in grams per kilogram of the body weight in
    /// effect, and counts the days with meals in each week; today, and anything older, is left out.
    @Test func theProteinContextIsGramsPerKilogramWithEachWeeksLoggedDays() throws {
        func meals(_ offset: Int, protein: Int) -> FernletDay {
            let macros = Macros(protein: protein, carbs: 0, fat: 0)
            let meal = Meal(name: "Lunch", mealType: .lunch, macros: macros, quality: .good, confidence: "high",
                            note: "", source: "manual")
            return FernletDay(date: FernletDate.dayKey(for: day(offset)), meals: [meal])
        }
        // Six days in the last week, five in the week before, and one older day that isn't read.
        let days = [99, 98, 97, 96, 95, 94, 92, 91, 90, 89, 87, 80].map { meals($0, protein: 64) }
        let context = WorkoutLoadContextBuilder.build(
            days: Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) }), today: meals(100, protein: 300),
            todayKey: FernletDate.dayKey(for: day(100)), settings: FernletSettings(),
            body: UserNutritionProfile(weightPounds: 80 * 2.20462), locale: Locale(identifier: "en_US")
        )
        let byWeek = context.recovery.loggedDaysByWeek
        let expected = [6, 5]
        #expect(byWeek == expected)
        let perKilogram = try #require(context.recovery.proteinGramsPerKg)
        #expect(abs(perKilogram - 0.8) < 0.001)
        #expect(context.recovery.proteinUnderFloor)
        // The food-logs switch reads as on until switched off, and nothing reads a weigh-in yet.
        #expect(context.foodAware)
        #expect(context.bodyWeights.isEmpty)
        var off = FernletSettings()
        off.workoutFoodAware = false
        let quiet = WorkoutLoadContextBuilder.build(days: [:], today: FernletDay(date: "2026-10-20"),
                                                    todayKey: "2026-10-20", settings: off)
        #expect(!quiet.foodAware)
    }

    /// G13: the switch syncs at the top level only once chosen, so every blob saved before keeps its
    /// shape; a fresh start (resetDiary's new settings) forgets it with the rest.
    @Test func theFoodLogsSwitchIsWrittenOnlyOnceChosen() throws {
        func object(_ settings: FernletSettings) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        }
        let fresh = FernletSettings()
        #expect(fresh.workoutFoodAware == nil)
        #expect(fresh.workoutUsesFoodLogs)
        let freshHasKey = try object(fresh)["workoutFoodAware"] != nil
        #expect(!freshHasKey)
        var chosen = FernletSettings()
        chosen.workoutFoodAware = false
        let written = try object(chosen)["workoutFoodAware"] as? Bool
        #expect(written == false)
        let back = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(chosen))
        #expect(back.workoutFoodAware == false)
        #expect(!back.workoutUsesFoodLogs)
    }

    /// G12: the one optional food question comes only before a session of more than 45 minutes with 15
    /// or more working sets, only for the goals that follow their main lifts, and never with the
    /// food-logs switch off.
    @Test func theFoodQuestionComesOnlyBeforeLongHighVolumeSessions() {
        func lifts(_ count: Int, sets: Int) -> [PrescribedExercise] {
            (0..<count).map { index in
                PrescribedExercise(name: "Lift \(index)", sets: sets, reps: "8", role: .main, fromCatalog: true,
                                   restSecondsOverride: 150,
                                   guidance: LoadGuidance(targetReps: 8, equipment: .barbell, unit: .lb))
            }
        }
        let long = lifts(5, sets: 4)
        #expect(WorkoutFuelCheck.workingSets(long) == 20)
        #expect(WorkoutSessionTime.minutes(of: long, goal: .strength) > WorkoutFuelCheck.longSessionMinutes)
        #expect(WorkoutFuelCheck.asks(long, goal: .strength, foodAware: true))
        #expect(WorkoutFuelCheck.asks(long, goal: .sportsPrep, foodAware: true))
        #expect(!WorkoutFuelCheck.asks(long, goal: .strength, foodAware: false))
        for goal in [GoalType.weightManagement, .wellness, .mentalHealth, .recovery, .exploring] {
            #expect(!WorkoutFuelCheck.asks(long, goal: goal, foodAware: true), "\(goal) was asked")
        }
        #expect(!WorkoutFuelCheck.asks(lifts(3, sets: 3), goal: .strength, foodAware: true))
        // Plenty of sets in a short session isn't asked either.
        let quick = long.map { lift -> PrescribedExercise in
            var short = lift
            short.restSecondsOverride = 30
            return short
        }
        #expect(!WorkoutFuelCheck.asks(quick, goal: .strength, foodAware: true))
    }

    /// G12: the Ready screen's "no" rides on every tracked lift's result, and a run saved before the
    /// question existed decodes with no answer.
    @Test func theRunsFoodAnswerRidesOnEachTrackedResult() throws {
        let weight = WeightPrescription(low: 95, high: 110, suggested: 100, step: 5, unit: .lb, confidence: .low)
        let bench = PrescribedExercise(name: "Bench press", sets: 3, reps: "8", role: .main, fromCatalog: true,
                                       guidance: LoadGuidance(targetReps: 8, prescription: weight, equipment: .barbell, unit: .lb))
        let step = GuidedWorkoutRunState.Exercise(
            id: bench.id, name: bench.name, sets: bench.sets, reps: bench.reps, roleRaw: "main", fromCatalog: true,
            restSeconds: 90, blockRaw: bench.block.rawValue, tracking: GuidedRunLoadLog.tracking(for: bench)
        )
        var state = GuidedWorkoutRunState(sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate",
                                          title: "Push", suggestionExercisesText: "", suggestionNotes: "",
                                          sessionKindRaw: "strength", exercises: [step])
        let unanswered = try #require(GuidedRunLoadLog.log(for: state)?.results.first)
        #expect(unanswered.unfueled == nil)
        state.unfueled = true
        let said = try #require(GuidedRunLoadLog.log(for: state)?.results.first)
        #expect(said.unfueled == true)
        let encodedResult = String(decoding: try JSONEncoder().encode(unanswered), as: UTF8.self)
        #expect(!encodedResult.contains("unfueled"))
        let carried = try JSONDecoder().decode(ExerciseResult.self, from: JSONEncoder().encode(said))
        #expect(carried.unfueled == true)
        let exposure = LiftExposure(date: day(0), result: carried)
        #expect(exposure.unfueled)

        state.unfueled = nil
        let encoded = try JSONEncoder().encode(state)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let hasKey = object["unfueled"] != nil
        #expect(!hasKey)
        let decoded = try JSONDecoder().decode(GuidedWorkoutRunState.self, from: encoded)
        #expect(decoded.unfueled == nil)
    }
}
