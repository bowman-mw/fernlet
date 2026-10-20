import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// Pins idea 6 — editing reps and weights after a run, and the Log sheet's set-by-set entry: a
/// correction round-trips through the record, its line and the stored JSON; a corrected set changes
/// the next prescription; a lift entered set by set is recorded exactly as a guided run records it;
/// and records written before (or after) this build still decode and keep what they carry.
@MainActor
struct WorkoutSetEditingTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    func dayKey(_ offset: Int) -> String { FernletDate.dayKey(for: day(offset)) }

    /// A guided bench press: 3 × 8 at 100 lb, prescribed 95–110 lb, completed as prescribed.
    func guidedBench(selected: Double = 100) -> ExerciseResult {
        ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8, rangeLow: 95, rangeHigh: 110,
                       suggestedWeight: 100, selectedWeight: selected, unit: .lb, equipment: .barbell,
                       confidence: .low)
    }

    /// A guided row the way the runner logs it: the warm-up and cool-down summaries around the lift's line.
    func guidedWorkout(_ result: ExerciseResult) -> Workout {
        let text = "Warm-up stretch flow - 8 min\n\(result.loggedLine)\nCool-down stretches - 3 min"
        return Workout(name: "Push", type: .upper, exercises: text, rpe: nil, notes: "", duration: nil,
                       loggedFromGuidedSession: true, intensity: .moderate, exerciseResults: [result])
    }

    func handWorkout(_ text: String) -> Workout {
        Workout(name: "Legs", type: .lower, exercises: text, rpe: nil, notes: "", duration: nil, intensity: .moderate)
    }

    /// Edits the first draft of `workout` with `change` and writes it back, as the Edit sheet's save does.
    func edited(_ workout: Workout, _ change: (inout ExerciseSetsDraft) -> Void) throws -> Workout {
        let original = WorkoutSetEditing.drafts(for: workout, defaultUnit: .lb)
        var drafts = original
        try #require(!drafts.isEmpty)
        change(&drafts[0])
        return WorkoutSetEditing.applying(drafts, original: original, to: workout)
    }

    /// The load engine's next bench session from `workouts` logged on day 20, planned on day 22.
    func nextBench(after workouts: [Workout]) -> LiftPlan {
        let todayKey = dayKey(22)
        let days = [dayKey(20): FernletDay(date: dayKey(20), workouts: workouts)]
        let context = WorkoutLoadContextBuilder.build(
            days: days, today: FernletDay(date: todayKey), todayKey: todayKey, settings: FernletSettings(),
            locale: Locale(identifier: "en_US")
        )
        return WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 8, high: 12), baseSets: 3, exposures: context.history(for: "Bench press"),
            equipment: .barbell, isLowerBody: false, defaultUnit: .lb, today: day(22)
        ))
    }

    func rows(_ sets: [(Int, String)]) -> [SetRowDraft] {
        sets.map { SetRowDraft(reps: $0.0, weight: $0.1) }
    }

    // MARK: - Editing round-trips

    @Test func aCorrectedSetRewritesTheRecordAndItsLineTogether() throws {
        let workout = guidedWorkout(guidedBench())
        let fixed = try edited(workout) { $0.rows[2].reps = 6; $0.rows[2].weight = "95" }
        let result = try #require(fixed.exerciseResults?.first)
        #expect(result.actualReps == [8, 8, 6])
        #expect(result.setWeights == [100, 100, 95])
        #expect(result.selectedWeight == 100)
        #expect((result.rangeLow, result.rangeHigh, result.suggestedWeight) == (95, 110, 100))
        #expect(fixed.exerciseLines == [
            "Warm-up stretch flow - 8 min",
            "Bench press - 3 x 8 @ 100 lb (did 8 @ 100, 8 @ 100, 6 @ 95)",
            "Cool-down stretches - 3 min",
        ])
        let parsed = try #require(ExerciseLineParser.parse(fixed.exerciseLines[1]))
        #expect((parsed.sets, parsed.repsCount, parsed.weight, parsed.weightUnit) == (3, 8, 100, "lb"))

        let stored = try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(fixed))
        #expect(stored.exerciseResults == fixed.exerciseResults)
        #expect(stored.exercises == fixed.exercises)
        let reopened = WorkoutSetEditing.drafts(for: stored, defaultUnit: .kg)
        #expect(reopened.first?.loggedSets == [
            LoggedSet(reps: 8, weight: 100), LoggedSet(reps: 8, weight: 100), LoggedSet(reps: 6, weight: 95),
        ])
        #expect(reopened.first?.unit == .lb)
    }

    @Test func puttingTheSetsBackReadsAsCompletedAsPrescribedAgain() throws {
        let workout = guidedWorkout(guidedBench())
        let fixed = try edited(workout) { $0.rows[2].reps = 6; $0.rows[2].weight = "95" }
        let undone = try edited(fixed) { $0.rows[2].reps = 8; $0.rows[2].weight = "100" }
        #expect(undone.exerciseResults == workout.exerciseResults)
        #expect(undone.exercises == workout.exercises)
    }

    @Test func effortAndReasonAreEditableAndAnUnknownTokenSurvivesOtherEdits() throws {
        let rated = try edited(guidedWorkout(guidedBench())) { $0.effort = .tough; $0.overrideReason = .pain }
        #expect(rated.exerciseResults?.first?.effort == .tough)
        #expect(rated.exerciseResults?.first?.overrideReason == .pain)

        var future = guidedBench()
        future.effortToken = "exhausted"
        let kept = try edited(guidedWorkout(future)) { $0.rows[0].reps = 7 }
        #expect(kept.exerciseResults?.first?.effortToken == "exhausted")
        #expect(kept.exerciseResults?.first?.actualReps == [7, 8, 8])
    }

    @Test func aCorrectedUnitRelabelsTheLiftWithoutConvertingIt() throws {
        let fixed = try edited(guidedWorkout(guidedBench(selected: 45))) { $0.unit = .kg }
        let result = try #require(fixed.exerciseResults?.first)
        #expect(result.unit == .kg)
        #expect(result.selectedWeight == 45)
        #expect(fixed.exerciseLines.contains("Bench press - 3 x 8 @ 45 kg"))
    }

    @Test func untouchedDraftsChangeNothing() throws {
        let workout = guidedWorkout(guidedBench())
        let drafts = WorkoutSetEditing.drafts(for: workout, defaultUnit: .lb)
        #expect(WorkoutSetEditing.applying(drafts, original: drafts, to: workout) == workout)
        let hand = handWorkout("Squat 5x5 @225lb\nPlank 3 x 30 s")
        let handDrafts = WorkoutSetEditing.drafts(for: hand, defaultUnit: .lb)
        #expect(WorkoutSetEditing.applying(handDrafts, original: handDrafts, to: hand) == hand)
    }

    @Test func onlyRecordsAndHandWrittenSetLinesAreEditableAndHealthImportsNever() {
        #expect(WorkoutSetEditing.drafts(for: guidedWorkout(guidedBench()), defaultUnit: .lb).map(\.name) == ["Bench press"])
        let planOnly = Workout(name: "Push", type: .upper, exercises: "Bench press - 3 x 8", rpe: nil, notes: "",
                               duration: nil, loggedFromGuidedSession: true, intensity: .moderate)
        #expect(WorkoutSetEditing.drafts(for: planOnly, defaultUnit: .lb).isEmpty)
        let hand = handWorkout("Squat 5x5 @225lb\nPlank 3 x 30 s\nCurl 3x8-12\n20 min row")
        let drafts = WorkoutSetEditing.drafts(for: hand, defaultUnit: .kg)
        #expect(drafts.map(\.name) == ["Squat"])
        #expect(drafts.first?.loggedSets == Array(repeating: LoggedSet(reps: 5, weight: 225), count: 5))
        #expect(drafts.first?.unit == .lb)
        var imported = guidedWorkout(guidedBench())
        imported.healthKitUUID = UUID()
        #expect(imported.isHealthImported)
        #expect(WorkoutSetEditing.drafts(for: imported, defaultUnit: .lb).isEmpty)
    }

    @Test func aCorrectedHandWrittenLineBecomesARecordInPlace() throws {
        let hand = handWorkout("Squat 5x5 @225lb\nPlank 3 x 30 s")
        let fixed = try edited(hand) { $0.rows[4].reps = 3 }
        let result = try #require(fixed.exerciseResults?.first)
        #expect(fixed.exerciseResults?.count == 1)
        #expect((result.name, result.prescribedSets, result.targetReps) == ("Squat", 5, 5))
        #expect(result.actualReps == [5, 5, 5, 5, 3])
        #expect(result.selectedWeight == 225)
        #expect(result.unit == .lb)
        #expect(fixed.exerciseLines == ["Squat - 5 x 5 @ 225 lb (did 5, 5, 5, 5, 3)", "Plank 3 x 30 s"])
    }

    @Test func replacingALineLeavesTheRestAndAppendsWhenItIsGone() {
        var workout = handWorkout("A 3x5\n  B 3x5  \nC 3x5")
        workout.replaceExerciseLine("B 3x5", with: "B - 3 x 5 @ 100 lb")
        #expect(workout.exercises == "A 3x5\nB - 3 x 5 @ 100 lb\nC 3x5")
        workout.replaceExerciseLine("D 3x5", with: "D - 3 x 5")
        #expect(workout.exerciseLines.last == "D - 3 x 5")
        var empty = handWorkout("")
        empty.replaceExerciseLine("", with: "E - 1 x 1")
        #expect(empty.exercises == "E - 1 x 1")
    }

    // MARK: - The draft's rows

    @Test func rowsAddRepeatAndRemoveWithinTheirBounds() {
        var draft = ExerciseSetsDraft.blank(name: "Bench press", unit: .lb, equipment: .barbell)
        draft.rows[0].weight = "100"
        draft.addSet()
        #expect(draft.rows.map(\.reps) == [8, 8])
        #expect(draft.rows[1].weight.isEmpty)
        #expect(draft.inheritedWeight(before: 1) == 100)
        draft.rows[1].weight = "95"
        draft.repeatLastSet()
        #expect(draft.rows.last?.weight == "95")
        #expect(draft.loggedSets.map(\.weight) == [100, 95, 95])
        for _ in 0..<(ExerciseResult.maxSets + 5) { draft.repeatLastSet() }
        #expect(draft.rows.count == ExerciseResult.maxSets)
        for row in draft.rows { draft.removeSet(id: row.id) }
        #expect(draft.rows.count == 1)
    }

    @Test func typedWeightsReadLocaleTolerantlyAndBlanksRepeatTheSetAbove() {
        #expect(SetRowDraft.weight(from: "62,5") == 62.5)
        #expect(SetRowDraft.weight(from: " 62.5 ") == 62.5)
        #expect(SetRowDraft.weight(from: "100 lb") == 100)
        #expect(SetRowDraft.weight(from: "") == nil)
        #expect(SetRowDraft.weight(from: "heavy") == nil)
        #expect(SetRowDraft.weight(from: "-5") == nil)
        let sets = [LoggedSet(reps: 8, weight: nil), LoggedSet(reps: 8, weight: 100), LoggedSet(reps: 8, weight: nil),
                    LoggedSet(reps: 6, weight: 95), LoggedSet(reps: 6, weight: nil)]
        #expect(LoggedSet.filledWeights(sets) == [100, 100, 100, 95, 95])
        #expect(LoggedSet.filledWeights([LoggedSet(reps: 10, weight: nil)]) == nil)
    }

    // MARK: - A corrected set feeds the engine

    @Test func aCorrectedMissChangesTheNextPrescription() throws {
        let workout = guidedWorkout(guidedBench())
        let before = nextBench(after: [workout])
        #expect(before.change == .moreReps)
        #expect((before.reps, before.prescription?.suggested) == (9, 100))

        let missed = try edited(workout) { $0.rows[2].reps = 5 }
        let after = nextBench(after: [missed])
        #expect(after.change == .lighter)
        #expect((after.reps, after.prescription?.suggested) == (8, 95))
    }

    @Test func aCorrectedWeightIsWhatTheNextSessionBuildsOn() throws {
        let workout = guidedWorkout(guidedBench())
        let heavier = try edited(workout) { draft in
            for index in draft.rows.indices { draft.rows[index].weight = "110" }
        }
        #expect(heavier.exerciseResults?.first?.setWeights == nil)
        let plan = nextBench(after: [heavier])
        #expect(plan.change == .moreReps)
        #expect(plan.prescription?.suggested == 110)
    }

    @Test func aLighterLastSetRepeatsTheLoadInsteadOfProgressing() throws {
        let dropped = try edited(guidedWorkout(guidedBench())) { $0.rows[2].weight = "95" }
        let droppedResult = try #require(dropped.exerciseResults?.first)
        let exposure = LiftExposure(date: day(20), result: droppedResult)
        #expect(exposure.weight == 100)
        #expect(exposure.workingSetReps == [8, 8])
        #expect((exposure.lighterSets, exposure.shortfall, exposure.completed) == (1, 0, false))
        let plan = nextBench(after: [dropped])
        #expect(plan.change == .same)
        #expect((plan.reps, plan.prescription?.suggested) == (8, 100))
    }

    // MARK: - Set-by-set entry records what a guided run records

    @Test func aLiftEnteredSetBySetIsRecordedAsTheRunnerRecordsIt() throws {
        let weight = WeightPrescription(low: 95, high: 110, suggested: 100, step: 5, unit: .lb, confidence: .low)
        let step = PrescribedExercise(
            name: "Bench press", sets: 3, reps: "8", role: .main, fromCatalog: true,
            guidance: LoadGuidance(targetReps: 8, prescription: weight, equipment: .barbell, unit: .lb)
        )
        let exercise = GuidedWorkoutRunState.Exercise(
            id: step.id, name: step.name, sets: step.sets, reps: step.reps, roleRaw: "main", fromCatalog: true,
            restSeconds: 90, holdSeconds: nil, blockRaw: step.block.rawValue, tracking: GuidedRunLoadLog.tracking(for: step)
        )
        var run = GuidedWorkoutRunState(sessionID: UUID(), committedDayKey: dayKey(20), intensityRaw: "moderate",
                                        title: "Push", suggestionExercisesText: "", suggestionNotes: "",
                                        sessionKindRaw: "strength", exercises: [exercise])
        run.setActualReps([8, 8, 6], forExercise: step.id)
        let guided = try #require(GuidedRunLoadLog.log(for: run)?.results.first)

        var draft = ExerciseSetsDraft.blank(name: "Bench press", unit: .lb, equipment: .barbell)
        draft.rows = rows([(8, "100"), (8, ""), (6, "")])
        let manual = try #require(draft.handLoggedResult())

        #expect(manual.loggedLine == guided.loggedLine)
        #expect(manual.loggedLine == "Bench press - 3 x 8 @ 100 lb (did 8, 8, 6)")
        #expect(manual.loggedSets == guided.loggedSets)
        #expect((manual.prescribedSets, manual.targetReps, manual.actualReps) == (3, 8, [8, 8, 6]))
        #expect(manual.unit == .lb)
        #expect(manual.equipment == .barbell)
        #expect(manual.workingWeight == 100)
        let fromGuided = LiftExposure(date: day(20), result: guided)
        let fromManual = LiftExposure(date: day(20), result: manual)
        #expect((fromManual.weight, fromManual.unit, fromManual.targetReps) == (fromGuided.weight, fromGuided.unit, fromGuided.targetReps))
        #expect((fromManual.repsPerSet, fromManual.setWeights) == (fromGuided.repsPerSet, fromGuided.setWeights))
        #expect((fromManual.completed, fromManual.shortfall, fromManual.structured) == (false, 2, true))
        #expect(WorkoutLoadEngine.estimatedMax(of: fromManual, in: .lb) == WorkoutLoadEngine.estimatedMax(of: fromGuided, in: .lb))
    }

    @Test func differentWeightsPerSetAreKeptAsStructureAndAsText() throws {
        var draft = ExerciseSetsDraft.blank(name: "Romanian deadlift", unit: .kg, equipment: .barbell)
        draft.rows = rows([(8, "62,5"), (8, ""), (6, "60")])
        let result = try #require(draft.handLoggedResult())
        #expect(result.setWeights == [62.5, 62.5, 60])
        #expect((result.selectedWeight, result.targetReps) == (62.5, 8))
        #expect(result.loggedLine == "Romanian deadlift - 3 x 8 @ 62.5 kg (did 8 @ 62.5, 8 @ 62.5, 6 @ 60)")
        let parsed = try #require(ExerciseLineParser.parse(result.loggedLine))
        #expect((parsed.sets, parsed.repsCount, parsed.weight, parsed.weightUnit) == (3, 8, 62.5, "kg"))

        let entry = WorkoutExerciseEntry(exercise: ExerciseTarget(name: "Romanian deadlift", primaryMuscles: []),
                                         sets: "", reps: "", weight: "", speed: "", incline: "", details: "",
                                         result: result)
        #expect(entry.summary == result.loggedLine)
        #expect(entry.detailSummary == "3 x 8 @ 62.5 kg (did 8 @ 62.5, 8 @ 62.5, 6 @ 60)")
    }

    @Test func aBodyweightLiftEnteredSetBySetCarriesNoWeight() throws {
        var draft = ExerciseSetsDraft.blank(name: "Pull-up", unit: .lb, equipment: .bodyweight)
        draft.rows = rows([(10, ""), (8, ""), (6, "")])
        let result = try #require(draft.handLoggedResult())
        #expect(result.selectedWeight == nil && result.unit == nil && result.setWeights == nil)
        #expect(result.loggedLine == "Pull-up - 3 x 10 (did 10, 8, 6)")
        #expect(ExerciseSetsDraft.blank(name: "  ", unit: .lb, equipment: nil).handLoggedResult() == nil)
    }

    @Test func theEngineReadsARowsRecordAndItsOtherHandWrittenLines() throws {
        var squat = ExerciseSetsDraft.blank(name: "Back squat", unit: .lb, equipment: .barbell)
        squat.rows = rows([(5, "200"), (5, ""), (5, "")])
        let record = try #require(squat.handLoggedResult())
        let text = "\(record.loggedLine)\nBack squat 1x3 @250 lb\nBench press 3x8 @135 lb"
        let row = Workout(name: "Mixed", type: .fullBody, exercises: text, rpe: nil, notes: "", duration: nil,
                          intensity: .moderate, exerciseResults: [record])
        let todayKey = dayKey(22)
        let context = WorkoutLoadContextBuilder.build(
            days: [dayKey(20): FernletDay(date: dayKey(20), workouts: [row])], today: FernletDay(date: todayKey),
            todayKey: todayKey, settings: FernletSettings(), locale: Locale(identifier: "en_US")
        )
        #expect(context.history(for: "Back squat").map(\.weight) == [200])
        #expect(context.history(for: "Back squat").map(\.structured) == [true])
        #expect(context.history(for: "Bench press").map(\.weight) == [135])
        #expect(context.history(for: "Bench press").map(\.structured) == [false])
    }

    // MARK: - Old and newer records decode

    @Test func aResultFromBeforePerSetWeightsDecodesAndKeepsItsShape() throws {
        let json = #"{"compoundsBefore":0,"name":"Bench press","prescribedSets":3,"selectedWeight":105,"targetReps":8,"unitToken":"lb"}"#
        let result = try JSONDecoder().decode(ExerciseResult.self, from: Data(json.utf8))
        #expect(result.setWeights == nil && result.parkedUnknownKeys.isEmpty)
        #expect(result.loggedLine == "Bench press - 3 x 8 @ 105 lb")
        // Re-encoded, it carries exactly the keys it came with: no per-set or parking artifact.
        let reencoded = try JSONEncoder().encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(Set(object.keys) == ["compoundsBefore", "name", "prescribedSets", "selectedWeight", "targetReps", "unitToken"])
        #expect(try JSONDecoder().decode(ExerciseResult.self, from: reencoded) == result)
    }

    @Test func aNewerBuildsKeysAreParkedAndWrittenBack() throws {
        let json = #"{"name":"Bench press","prescribedSets":2,"targetReps":8,"selectedWeight":100,"unitToken":"lb","setWeights":[100,95],"futureTempo":{"down":3,"cues":["slow"]}}"#
        let result = try JSONDecoder().decode(ExerciseResult.self, from: Data(json.utf8))
        #expect(result.setWeights == [100, 95])
        #expect(result.parkedUnknownKeys["futureTempo"] == .object(["down": .integer(3), "cues": .array([.string("slow")])]))
        let again = try JSONDecoder().decode(ExerciseResult.self, from: JSONEncoder().encode(result))
        #expect(again == result)
        var corrected = result
        corrected.record([LoggedSet(reps: 8, weight: 100), LoggedSet(reps: 7, weight: 100)], unit: .lb)
        #expect(corrected.parkedUnknownKeys == result.parkedUnknownKeys)
    }

    @Test func implausibleOrMisalignedWeightsReadAsAbsent() throws {
        let negative = #"{"name":"Bench press","prescribedSets":2,"targetReps":8,"selectedWeight":100,"unitToken":"lb","setWeights":[100,-5]}"#
        let decoded = try JSONDecoder().decode(ExerciseResult.self, from: Data(negative.utf8))
        #expect(decoded.setWeights == nil)
        let misaligned = ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8, selectedWeight: 100,
                                        unit: .lb, setWeights: [100, 95])
        #expect(misaligned.alignedSetWeights == nil)
        #expect(misaligned.workingWeight == 100)
        #expect(misaligned.loggedLine == "Bench press - 3 x 8 @ 100 lb")
        let exposure = LiftExposure(date: day(0), weight: 100, unit: .lb, targetReps: 8, repsPerSet: [8, 8, 8],
                                    setWeights: [100, 95])
        #expect(exposure.setWeights == nil && exposure.completed)
    }

    @Test func aWorkoutWithPerSetWeightsRoundTripsAndOneWithoutStaysByteIdentical() throws {
        var draft = ExerciseSetsDraft.blank(name: "Bench press", unit: .lb, equipment: .barbell)
        draft.rows = rows([(8, "100"), (8, ""), (6, "95")])
        let result = try #require(draft.handLoggedResult())
        let workout = Workout(name: "Push", type: .upper, exercises: result.loggedLine, rpe: nil, notes: "",
                              duration: nil, intensity: .moderate, exerciseResults: [result])
        let decoded = try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(workout))
        #expect(decoded.exerciseResults == [result])
        let plain = handWorkout("Squat 5x5 @225lb")
        let encoded = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!encoded.contains("exerciseResults") && !encoded.contains("setWeights"))
    }
}
