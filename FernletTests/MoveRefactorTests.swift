import Foundation
import Testing
import FernletDomainModel
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
}
