import HealthKit
import Testing
import FernletDomainModel
import HealthKitGateway
@testable import Fernlet

@MainActor
struct HealthKitWorkoutTests {
    @Test func saveWorkoutBuildsTraditionalStrengthConfigForStrengthMode() {
        let workout = makeWorkout(mode: .strengthTraining)

        let config = HealthKitService.makeConfiguration(for: workout)

        #expect(config.activityType == .traditionalStrengthTraining)
        #expect(config.locationType == .unknown)
    }

    @Test func saveWorkoutBuildsCorrectActivityTypeForActivityMode() {
        for activityType in WorkoutActivityType.allCases {
            let workout = makeWorkout(mode: .activity, activityType: activityType)

            let config = HealthKitService.makeConfiguration(for: workout)

            #expect(config.activityType == ActivityTypeCatalog.hkActivityType(for: activityType))
        }
    }

    @Test func saveWorkoutDefaultsDurationWhenMissing() {
        let strength = makeWorkout(mode: .strengthTraining, duration: nil)
        let activity = makeWorkout(mode: .activity, activityType: nil, duration: nil)

        #expect(HealthKitService.defaultDuration(for: strength) == 30)
        #expect(HealthKitService.defaultDuration(for: activity) == 45)
    }

    @Test func backfillWindowIs30Days() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let referenceDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 23, hour: 12)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 23, hour: 12)))

        #expect(HealthKitService.workoutBackfillStartDate(referenceDate: referenceDate, calendar: calendar) == expected)
    }

    @Test func backfillFlagIsPersistedAfterFirstRun() throws {
        let suiteName = "com.fernlet.tests.workout-backfill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HealthKitService.shouldRunWorkoutBackfill(defaults: defaults))
        HealthKitService.markWorkoutBackfillCompleted(defaults: defaults)
        #expect(!HealthKitService.shouldRunWorkoutBackfill(defaults: defaults))
    }

    @Test func saveWorkoutMetadataIncludesFernletID() {
        let workoutID = UUID()
        let workout = makeWorkout(id: workoutID)

        let metadata = HealthKitService.makeMetadata(for: workout)

        #expect(metadata["fernlet.workoutID"] as? String == workoutID.uuidString)
    }

    @Test func saveWorkoutMetadataIncludesMuscleGroupsWhenPresent() {
        let workout = makeWorkout(muscleGroups: [.glutes, .quads, .abs])

        let metadata = HealthKitService.makeMetadata(for: workout)

        #expect(metadata["fernlet.muscleGroups"] as? String == "abs,glutes,quads")
    }

    @Test func saveWorkoutMetadataOmitsMuscleGroupsWhenEmpty() {
        let workout = makeWorkout(muscleGroups: [])

        let metadata = HealthKitService.makeMetadata(for: workout)

        #expect(metadata["fernlet.muscleGroups"] == nil)
    }

    @Test func saveWorkoutMetadataIncludesPlannedIDWhenPresent() {
        let plannedID = UUID()
        let workout = makeWorkout(plannedWorkoutID: plannedID)

        let metadata = HealthKitService.makeMetadata(for: workout)

        #expect(metadata["fernlet.plannedWorkoutID"] as? String == plannedID.uuidString)
    }

    @Test(.disabled("Requires HealthKit entitlement")) func makeWorkoutFromHKWorkoutPreservesActivityType() async throws {
    }

    @Test(.disabled("Requires HealthKit entitlement")) func makeWorkoutSetsStrengthModeForStrengthHKActivity() async throws {
    }

    @Test func makeWorkoutParsesMuscleGroupsMetadata() {
        let metadata: [String: Any] = ["fernlet.muscleGroups": "chest,triceps"]

        let parsed = WorkoutHealthKitSync.parseFernletMetadata(metadata)

        #expect(parsed.muscleGroups == [.chest, .triceps])
    }

    @Test(.disabled("Requires HealthKit entitlement")) func makeWorkoutDefaultsModeToActivityForCardio() async throws {
    }

    private func makeWorkout(
        id: UUID = UUID(),
        mode: WorkoutMode = .strengthTraining,
        activityType: WorkoutActivityType? = nil,
        duration: Int? = 30,
        muscleGroups: Set<MuscleGroup> = [],
        plannedWorkoutID: UUID? = nil
    ) -> Workout {
        Workout(
            id: id,
            name: "Workout",
            type: activityType?.fernletCategory ?? .fullBody,
            mode: mode,
            activityType: activityType,
            exercises: "Bench press",
            rpe: nil,
            notes: "",
            duration: duration,
            muscleGroups: muscleGroups,
            plannedWorkoutID: plannedWorkoutID,
            intensity: .moderate,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
