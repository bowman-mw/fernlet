import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// Pins where load-aware progression meets the app: the day plan's load pass (weight ranges, the
/// "add weight now" reset, the plateau response in order — easier session up front, support work,
/// a variation — and the monthly calibration), the runner's tracking from plan to log, and the
/// context the planner reads from the day history.
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
        progression: [String: Int] = [:], useLoad: Bool = true
    ) throws -> WorkoutProgram.SessionSuggestion {
        let load = WorkoutLoadContext(exposures: history, today: day(today), defaultUnit: .lb, calibration: calibration)
        let plan = WorkoutProgram.dayPlan(
            goal: .wellness, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
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

    /// A best of 135 × 10, then tough 135 × 9s every week from day 7 through `lastDay`.
    func stalled(through lastDay: Int) -> [LiftExposure] {
        [session(0, 135, reps: 10, target: 10)]
            + stride(from: 7, through: lastDay, by: 7).map { session($0, 135, reps: 9, target: 9, effort: .tough) }
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

    @Test func aPlateauStartsWithAnEasierSessionUpFrontAndMoreRest() throws {
        let second = lifting(try pushSession())[1]
        let session = try pushSession(history: [key(second.name): stalled(through: 28)])
        let first = try #require(lifting(session).first)
        #expect(first.name == second.name)
        #expect(first.sets == 2)
        #expect(first.guidance?.easierSession == true)
        #expect(first.guidance?.prescription?.suggested == 120)
        let rest = WorkoutRestGuidance.restSeconds(
            demand: WorkoutRestGuidance.demand(role: .main, movementPattern: .push), goal: .wellness
        )
        #expect(first.restSecondsOverride == WorkoutRestGuidance.clamp(rest + WorkoutPlateau.extraRestMainSeconds))
        #expect(session.suggestion.notes.contains("\(second.name) has held steady for 4 weeks. That's normal"))
        #expect(session.suggestion.notes.contains("Today is an easier \(second.name) session: 2 sets at about 120 lb."))
    }

    @Test func theSupportBlockSwapsAnAccessoryForHelperWork() throws {
        let baseline = lifting(try pushSession())
        let main = try #require(baseline.first).name
        let session = try pushSession(history: [key(main): stalled(through: 42)], today: 44)
        let names = lifting(session).map(\.name)
        let added = try #require(names.first { !baseline.map(\.name).contains($0) })
        let support = try #require(WorkoutExerciseCatalog.exercise(named: added))
        #expect(!support.primaryMuscles.isDisjoint(with: [.upperBack, .rearDelts]))
        #expect(names.contains { WorkoutExerciseCatalog.exercise(named: $0)?.primaryMuscles.contains(.triceps) == true })
        #expect(session.suggestion.notes.contains("takes an accessory spot to build up the muscles that help your \(main)"))
    }

    @Test func aVariationStandsInAfterTheSupportBlock() throws {
        let main = try #require(lifting(try pushSession()).first).name
        let session = try pushSession(history: [key(main): stalled(through: 70)], today: 72)
        #expect(!lifting(session).map(\.name).contains(main))
        #expect(session.suggestion.notes.contains("stands in for \(main) for a few weeks"))
    }

    @Test func aDueCalibrationTurnsTheMainLiftIntoARampAndATest() throws {
        let baseline = try pushSession()
        let main = try #require(lifting(baseline).first).name
        let history = [key(main): [session(21, 135, reps: 10, target: 10), session(28, 135, reps: 10, target: 10)]]
        let session = try pushSession(history: history, calibration: CalibrationSettings())
        let steps = lifting(session).filter { $0.name == main }
        #expect(steps.map(\.guidance?.calibration) == [.ramp, .ramp, .ramp, .test])
        #expect(steps.first?.line.hasSuffix("(ramp-up)") == true)
        let accessorySets = { (s: WorkoutProgram.SessionSuggestion) in lifting(s).filter { $0.role == .accessory }.map(\.sets) }
        let uncalibrated = try pushSession(history: history)
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
        #expect(context.recovery.sleepNights == 3 && context.recovery.sleepIsLow)
        #expect(WorkoutLoadContextBuilder.defaultUnit(for: Locale(identifier: "de_DE")) == .kg)
    }
}
