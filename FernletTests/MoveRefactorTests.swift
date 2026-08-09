import Foundation
import Testing
import FernletDomainModel
import HealthKitGateway
@testable import Fernlet

@MainActor
struct MoveRefactorTests {
    @Test func parseFernletMetadataHandlesMissingKeys() {
        let parsed = WorkoutHealthKitSync.parseFernletMetadata(nil)

        #expect(parsed.muscleGroups.isEmpty)
        #expect(parsed.exercises.isEmpty)
        #expect(parsed.notes.isEmpty)
        #expect(parsed.effort == nil)
        #expect(parsed.plannedWorkoutID == nil)
    }

    @Test func parseFernletMetadataParsesAllKeysWhenPresent() {
        let plannedID = UUID()
        let metadata: [String: Any] = [
            "fernlet.muscleGroups": "chest,triceps",
            "fernlet.exercises": "Bench press 3x8",
            "fernlet.notes": "steady",
            "fernlet.effort": NSNumber(value: 7),
            "fernlet.plannedWorkoutID": plannedID.uuidString
        ]

        let parsed = WorkoutHealthKitSync.parseFernletMetadata(metadata)

        #expect(parsed.muscleGroups == [.chest, .triceps])
        #expect(parsed.exercises == "Bench press 3x8")
        #expect(parsed.notes == "steady")
        #expect(parsed.effort == 7)
        #expect(parsed.plannedWorkoutID == plannedID)
    }

    @Test func parseFernletMetadataSkipsUnknownMuscleGroups() {
        let parsed = WorkoutHealthKitSync.parseFernletMetadata(["fernlet.muscleGroups": "chest,unknownGroup,triceps"])

        #expect(parsed.muscleGroups == [.chest, .triceps])
    }

    @Test func healthCapabilityIncludesWorkoutLogging() {
        #expect(HealthCapability.allCases.contains(.workoutLogging))
    }

    @Test func workoutModeRoundTripsCodable() throws {
        for mode in WorkoutMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(WorkoutMode.self, from: data)

            #expect(decoded == mode)
        }
    }

    @Test func muscleGroupAllRegionsCovered() {
        for muscleGroup in MuscleGroup.allCases {
            #expect(BodyRegion.allCases.contains(muscleGroup.region))
        }
    }

    @Test func bodyRegionAllCasesUsed() {
        let usedRegions = Set(MuscleGroup.allCases.map(\.region))

        for region in BodyRegion.allCases {
            #expect(usedRegions.contains(region))
        }
    }

    @Test func muscleGroupRoundTripsCodable() throws {
        for muscleGroup in MuscleGroup.allCases {
            let data = try JSONEncoder().encode(muscleGroup)
            let decoded = try JSONDecoder().decode(MuscleGroup.self, from: data)

            #expect(decoded == muscleGroup)
        }
    }

    @Test func equipmentDisplayNamesNonEmpty() {
        for equipment in Equipment.allCases {
            #expect(!equipment.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func exerciseTargetDecodesNewSchema() throws {
        let json = """
        {
          "name": "Bench press",
          "primaryMuscles": ["chest"],
          "secondaryMuscles": ["triceps", "frontDelts"],
          "equipment": "barbell",
          "movementPattern": "push",
          "inputKind": "strength"
        }
        """

        let target = try JSONDecoder().decode(ExerciseTarget.self, from: Data(json.utf8))

        #expect(target.name == "Bench press")
        #expect(target.primaryMuscles == [.chest])
        #expect(target.secondaryMuscles == [.triceps, .frontDelts])
        #expect(target.equipment == .barbell)
        #expect(target.movementPattern == .push)
    }

    @Test func exerciseTargetDecodesLegacySchema() throws {
        let json = """
        {
          "name": "Legacy row",
          "category": "Upper",
          "muscles": ["Back", "Biceps", "Class"],
          "inputKind": "strength"
        }
        """

        let target = try JSONDecoder().decode(ExerciseTarget.self, from: Data(json.utf8))

        #expect(target.primaryMuscles == [.upperBack, .biceps])
        #expect(target.secondaryMuscles.isEmpty)
        #expect(target.equipment == .none)
        #expect(target.movementPattern == .isolation)
    }

    @Test func bundledExerciseCatalogLoads() {
        #expect(!WorkoutExerciseCatalog.baseExercises.isEmpty)

        for exercise in WorkoutExerciseCatalog.baseExercises {
            #expect(!exercise.primaryMuscles.isEmpty)
        }
    }

    @Test func bundledCatalogContainsNoClasses() {
        let blockedPattern = #"class|tennis|basketball|soccer|pickleball|outdoor (walk|run)|bike|row erg"#

        for exercise in WorkoutExerciseCatalog.baseExercises where exercise.inputKind == .none {
            #expect(exercise.name.range(of: blockedPattern, options: [.caseInsensitive, .regularExpression]) == nil)
        }
    }

    @Test func bundledCatalogHasReasonableSize() {
        #expect(WorkoutExerciseCatalog.baseExercises.count >= 35)
    }

    @Test func legacyJSONWithFocusTagsStillDecodes() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy push",
          "type": "Upper",
          "exercises": "Bench press 3x8",
          "rpe": 7,
          "notes": "steady",
          "duration": 40,
          "intensity": "moderate",
          "focusTag": "push",
          "focusColorName": "moss"
        }
        """

        let workout = try JSONDecoder().decode(Workout.self, from: Data(json.utf8))

        #expect(workout.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(workout.name == "Legacy push")
        #expect(workout.type == .upper)
        #expect(workout.exercises == "Bench press 3x8")
        #expect(workout.rpe == 7)
        #expect(workout.notes == "steady")
        #expect(workout.duration == 40)
        #expect(workout.intensity == .moderate)
        #expect(workout.mode == .strengthTraining)
        #expect(workout.activityType == nil)
        #expect(workout.muscleGroups.isEmpty)
    }

    @Test func legacySettingsJSONWithFocusTagsStillDecodes() throws {
        let json = """
        {
          "bottleOz": 32,
          "hydrationTarget": 5,
          "showDeveloperNotes": true,
          "selectedGoal": "wellness",
          "workoutFocusTags": [
            { "id": "push", "name": "Push", "color": "moss" }
          ]
        }
        """

        let settings = try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))

        #expect(settings.bottleOz == 32)
        #expect(settings.hydrationTarget == 5)
        #expect(settings.showDeveloperNotes)
        #expect(settings.selectedGoal == .wellness)
        #expect(!settings.quickLogItems.isEmpty)
        #expect(!settings.homeWidgets.isEmpty)
    }

    @Test func workoutRoundTripsWithNewFields() throws {
        let healthKitUUID = UUID()
        let plannedWorkoutID = UUID()
        let workout = Workout(
            name: "Ride",
            type: .cardio,
            mode: .activity,
            activityType: .cycling,
            exercises: "",
            rpe: nil,
            notes: "felt smooth",
            duration: 45,
            distanceMiles: 12.4,
            activeEnergyKcal: 320,
            effort: 6,
            muscleGroups: [.quads, .glutes],
            healthKitUUID: healthKitUUID,
            plannedWorkoutID: plannedWorkoutID,
            intensity: .moderate
        )

        let data = try JSONEncoder().encode(workout)
        let decoded = try JSONDecoder().decode(Workout.self, from: data)

        #expect(decoded.mode == .activity)
        #expect(decoded.activityType == .cycling)
        #expect(decoded.distanceMiles == 12.4)
        #expect(decoded.activeEnergyKcal == 320)
        #expect(decoded.effort == 6)
        #expect(decoded.muscleGroups == [.quads, .glutes])
        #expect(decoded.healthKitUUID == healthKitUUID)
        #expect(decoded.plannedWorkoutID == plannedWorkoutID)
    }

    @Test func workoutRoundTripsWithAndWithoutGuidedTag() throws {
        // Tagged guided log: the flag survives a round-trip.
        let tagged = Workout(name: "Legs", type: .lower, exercises: "", rpe: nil, notes: "",
                             duration: nil, loggedFromGuidedSession: true, intensity: .hard)
        let taggedData = try JSONEncoder().encode(tagged)
        #expect(try JSONDecoder().decode(Workout.self, from: taggedData).loggedFromGuidedSession == true)

        // Untagged (the default): decodes back to nil, and the key is OMITTED from the blob so existing
        // rows stay byte-identical.
        let untagged = Workout(name: "Legs", type: .lower, exercises: "", rpe: nil, notes: "",
                               duration: nil, intensity: .hard)
        let untaggedData = try JSONEncoder().encode(untagged)
        #expect(try JSONDecoder().decode(Workout.self, from: untaggedData).loggedFromGuidedSession == nil)
        let json = String(data: untaggedData, encoding: .utf8) ?? ""
        #expect(!json.contains("loggedFromGuidedSession"), "untagged rows must not encode the guided marker")
    }

    @Test func inferredCategoryFavorsActivityTypeWhenActivityMode() {
        let workout = Workout(
            name: "Ride",
            type: .fullBody,
            mode: .activity,
            activityType: .cycling,
            exercises: "Bench press",
            rpe: nil,
            notes: "",
            duration: 30,
            muscleGroups: [.chest, .triceps],
            intensity: .moderate
        )

        #expect(workout.inferredCategory == .cardio)
    }

    @Test func inferredCategoryAggregatesMuscleGroups() {
        let workout = Workout(
            name: "Push",
            type: .fullBody,
            exercises: "",
            rpe: nil,
            notes: "",
            duration: 30,
            muscleGroups: [.chest, .triceps, .frontDelts],
            intensity: .moderate
        )

        #expect(workout.inferredCategory == .upper)
    }

    @Test func inferredCategoryFallsBackToTextWhenEmpty() {
        let workout = Workout(
            name: "Bench press",
            type: .fullBody,
            exercises: "Bench press 3x8",
            rpe: nil,
            notes: "",
            duration: 30,
            intensity: .moderate
        )

        #expect(workout.muscleGroups.isEmpty)
        #expect(workout.inferredCategory == WorkoutExerciseCatalog.inferredCategory(for: workout))
        #expect(workout.inferredCategory == .upper)
    }

    @Test func saveDisabledStrengthRequiresNameAndExercises() {
        let row = WorkoutExerciseEntry(
            exercise: ExerciseTarget(
                name: "Bench press",
                primaryMuscles: [.chest],
                secondaryMuscles: [.triceps],
                equipment: .barbell,
                movementPattern: .push
            ),
            sets: "3",
            reps: "8",
            weight: "95 lb",
            speed: "",
            incline: "",
            details: ""
        )

        #expect(WorkoutSheetRules.saveDisabled(mode: .strengthTraining, workoutName: "", exerciseRows: [row], selectedActivityType: nil, duration: "", distance: ""))
        #expect(WorkoutSheetRules.saveDisabled(mode: .strengthTraining, workoutName: "Push", exerciseRows: [], selectedActivityType: nil, duration: "", distance: ""))
        #expect(!WorkoutSheetRules.saveDisabled(mode: .strengthTraining, workoutName: "Push", exerciseRows: [row], selectedActivityType: nil, duration: "", distance: ""))

        // A typed-but-not-yet-"Added" valid draft (an exercise chosen) satisfies the has-exercises
        // requirement, so Save enables on a name + lone draft — matching WorkoutPlanSheet and reaching
        // the Save-closure auto-commit. No rows AND no draft stays disabled; a name is still required.
        #expect(!WorkoutSheetRules.saveDisabled(mode: .strengthTraining, workoutName: "Push", exerciseRows: [], selectedActivityType: nil, duration: "", distance: "", hasPendingValidDraft: true))
        #expect(WorkoutSheetRules.saveDisabled(mode: .strengthTraining, workoutName: "Push", exerciseRows: [], selectedActivityType: nil, duration: "", distance: "", hasPendingValidDraft: false))
        #expect(WorkoutSheetRules.saveDisabled(mode: .strengthTraining, workoutName: "", exerciseRows: [], selectedActivityType: nil, duration: "", distance: "", hasPendingValidDraft: true))
    }

    @Test func saveDisabledActivityRequiresTypeAndDurationOrDistance() {
        #expect(WorkoutSheetRules.saveDisabled(mode: .activity, workoutName: "", exerciseRows: [], selectedActivityType: nil, duration: "45", distance: ""))
        #expect(WorkoutSheetRules.saveDisabled(mode: .activity, workoutName: "", exerciseRows: [], selectedActivityType: .running, duration: "", distance: ""))
        #expect(!WorkoutSheetRules.saveDisabled(mode: .activity, workoutName: "", exerciseRows: [], selectedActivityType: .running, duration: "30", distance: ""))
        #expect(!WorkoutSheetRules.saveDisabled(mode: .activity, workoutName: "", exerciseRows: [], selectedActivityType: .running, duration: "", distance: "3.2"))
    }

    @Test func aggregatedMuscleGroupsCombinesPrimaryAndSecondary() {
        let bench = WorkoutExerciseEntry(
            exercise: ExerciseTarget(
                name: "Bench press",
                primaryMuscles: [.chest],
                secondaryMuscles: [.triceps, .frontDelts],
                equipment: .barbell,
                movementPattern: .push
            ),
            sets: "3",
            reps: "8",
            weight: "",
            speed: "",
            incline: "",
            details: ""
        )
        let row = WorkoutExerciseEntry(
            exercise: ExerciseTarget(
                name: "Barbell row",
                primaryMuscles: [.upperBack, .lats],
                secondaryMuscles: [.biceps],
                equipment: .barbell,
                movementPattern: .pull
            ),
            sets: "3",
            reps: "10",
            weight: "",
            speed: "",
            incline: "",
            details: ""
        )

        #expect(WorkoutSheetRules.aggregatedMuscleGroups(from: [bench, row]) == [.chest, .triceps, .frontDelts, .upperBack, .lats, .biceps])
    }

    @Test func settingsSheetMoveTabNoLongerReferencesFocusTags() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let settingsURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fernlet/SettingsSheet.swift")
        let source = try String(contentsOf: settingsURL, encoding: .utf8)

        #expect(!source.contains("workoutFocusTags"))
        #expect(!source.contains("addWorkoutFocusTag"))
        #expect(!source.contains("removeWorkoutFocusTag"))
    }

    // MARK: - Coach plan-source tag gate (Increment 8, Plan-Prekeys-ProtectedLoad-CoachMesh)

    /// The tag gate keys off coach-sourced plans actually existing in the user's days — NOT the
    /// proximity audit, which every mode writes (a friend-mesh user is not a coach client).
    @Test func coachPlanSourceTagRequiresACoachSourcedPlan() {
        let coachPlan = PlannedWorkout(
            name: "Week 3 push", split: .upper, source: .coach, notes: "", duration: nil)
        let userPlan = PlannedWorkout(
            name: "Own plan", split: .workout, source: .user, notes: "", duration: nil)

        let emptyToday = FernletDay(date: "2026-07-26")
        #expect(!MoveView.hasCoachSourcedPlans(in: [:], today: emptyToday))

        // A friend-mesh user with only self-authored plans: no tag.
        let userOnly = FernletDay(date: "2026-07-25", plannedWorkouts: [userPlan])
        #expect(!MoveView.hasCoachSourcedPlans(in: ["2026-07-25": userOnly], today: emptyToday))

        // A coach plan in a loaded day, or in today's (possibly not-yet-reloaded) day: tag.
        let coachDay = FernletDay(date: "2026-07-24", plannedWorkouts: [coachPlan, userPlan])
        #expect(MoveView.hasCoachSourcedPlans(
            in: ["2026-07-25": userOnly, "2026-07-24": coachDay], today: emptyToday))
        let coachToday = FernletDay(date: "2026-07-26", plannedWorkouts: [coachPlan])
        #expect(MoveView.hasCoachSourcedPlans(in: [:], today: coachToday))
    }

    // MARK: - Shared exercise draft (WorkoutSheet / WorkoutPlanSheet state machine)

    private static func strengthTarget(_ name: String = "Bench press") -> ExerciseTarget {
        ExerciseTarget(
            name: name,
            primaryMuscles: [.chest],
            secondaryMuscles: [.triceps],
            equipment: .barbell,
            movementPattern: .push,
            inputKind: .strength
        )
    }

    private static func treadmillTarget() -> ExerciseTarget {
        ExerciseTarget(
            name: "Treadmill",
            primaryMuscles: [.quads],
            equipment: .machine,
            movementPattern: .isolation,
            inputKind: .treadmill
        )
    }

    /// An empty draft commits nothing and reports it. Both sheets' save-time auto-commit is guarded on
    /// this: WorkoutPlanSheet additionally re-folds its rows into the free-text plan and must not run
    /// that fold when nothing was appended.
    @Test func emptyDraftCommitsNothingAndReportsFalse() {
        var draft = WorkoutExerciseDraft()
        draft.sets = "3"     // typed inputs without a chosen exercise are still "nothing to add"
        var rows: [WorkoutExerciseEntry] = []

        #expect(draft.commit(into: &rows) == false)
        #expect(rows.isEmpty)
    }

    /// The plan sheet's behaviour: sets/reps are kept as typed.
    @Test func draftCommitKeepsSetsAndRepsByDefault() {
        var draft = WorkoutExerciseDraft()
        draft.exercise = Self.strengthTarget()
        draft.sets = "3"
        draft.reps = "8"
        draft.weight = "95 lb"
        draft.details = "paused"
        var rows: [WorkoutExerciseEntry] = []

        // Hoisted out of `#expect`: the macro rewrites its condition into a closure whose captured
        // base is immutable, so a bare `mutating` call cannot appear inside it.
        let committed = draft.commit(into: &rows)
        #expect(committed)
        #expect(rows.count == 1)
        #expect(rows[0].sets == "3")
        #expect(rows[0].reps == "8")
        #expect(rows[0].weight == "95 lb")
        #expect(rows[0].details == "paused")
    }

    /// The log sheet's belt-and-braces guard, preserved through the extraction: it passes
    /// `includingSetsAndReps: logMode == .strengthTraining`, so an activity-mode commit blanks
    /// sets/reps. Only strength mode auto-commits, but the guard stays explicit rather than assuming.
    @Test func draftCommitBlanksSetsAndRepsWhenExcluded() {
        var draft = WorkoutExerciseDraft()
        draft.exercise = Self.strengthTarget()
        draft.sets = "3"
        draft.reps = "8"
        draft.weight = "95 lb"
        var rows: [WorkoutExerciseEntry] = []

        let committed = draft.commit(into: &rows, includingSetsAndReps: false)
        #expect(committed)
        #expect(rows[0].sets.isEmpty)
        #expect(rows[0].reps.isEmpty)
        #expect(rows[0].weight == "95 lb", "weight is filtered by inputKind, not by the sets/reps flag")
    }

    /// Input-kind filtering: a strength exercise never carries treadmill fields and vice versa, so
    /// switching exercises mid-draft cannot smuggle a stale speed onto a barbell row.
    @Test func draftCommitFiltersInputsByExerciseKind() {
        var strength = WorkoutExerciseDraft()
        strength.exercise = Self.strengthTarget()
        strength.weight = "95 lb"
        strength.speed = "6.0"
        strength.incline = "2"
        var strengthRows: [WorkoutExerciseEntry] = []
        strength.commit(into: &strengthRows)

        #expect(strengthRows[0].weight == "95 lb")
        #expect(strengthRows[0].speed.isEmpty)
        #expect(strengthRows[0].incline.isEmpty)

        var treadmill = WorkoutExerciseDraft()
        treadmill.exercise = Self.treadmillTarget()
        treadmill.weight = "95 lb"
        treadmill.speed = "6.0"
        treadmill.incline = "2"
        var treadmillRows: [WorkoutExerciseEntry] = []
        treadmill.commit(into: &treadmillRows)

        #expect(treadmillRows[0].weight.isEmpty)
        #expect(treadmillRows[0].speed == "6.0")
        #expect(treadmillRows[0].incline == "2")
    }

    /// Committing clears the draft and bumps the reset token, so the builder drops its picker state and
    /// the next Add cannot re-append the previous exercise.
    @Test func draftClearsAndBumpsResetTokenOnCommit() {
        var draft = WorkoutExerciseDraft()
        draft.exercise = Self.strengthTarget()
        draft.sets = "3"
        draft.reps = "8"
        draft.speed = "6.0"
        draft.details = "paused"
        let tokenBefore = draft.resetToken
        var rows: [WorkoutExerciseEntry] = []

        draft.commit(into: &rows)

        #expect(!draft.hasExercise)
        #expect(draft.sets.isEmpty && draft.reps.isEmpty && draft.weight.isEmpty)
        #expect(draft.speed.isEmpty && draft.incline.isEmpty && draft.details.isEmpty)
        #expect(draft.resetToken == tokenBefore + 1)

        // A second commit on the now-empty draft adds nothing — the guard both sheets rely on.
        #expect(draft.commit(into: &rows) == false)
        #expect(rows.count == 1)
    }

    /// The mode-switch path (`onChange(of: logMode) { draft.clear() }`) in both sheets.
    @Test func draftClearBlanksEveryFieldAndAdvancesTheToken() {
        var draft = WorkoutExerciseDraft()
        draft.exercise = Self.treadmillTarget()
        draft.sets = "3"
        draft.reps = "8"
        draft.weight = "95 lb"
        draft.speed = "6.0"
        draft.incline = "2"
        draft.details = "easy"
        let tokenBefore = draft.resetToken

        draft.clear()

        #expect(draft.entry() == nil)
        #expect(!draft.hasExercise)
        #expect(draft.sets.isEmpty && draft.reps.isEmpty && draft.weight.isEmpty)
        #expect(draft.speed.isEmpty && draft.incline.isEmpty && draft.details.isEmpty)
        #expect(draft.resetToken == tokenBefore + 1)
    }
}
