import HealthKit
import FernletFoundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct WorkoutHealthKitSyncTests {
    @Test func refreshReconcilesNewHKWorkoutByUpserting() async throws {
        let context = FakeWorkoutSyncContext()
        let sample = FakeHealthWorkoutSample()
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])

        #expect(context.upsertedWorkouts.count == 1)
        #expect(context.upsertedWorkouts.first?.workout.healthKitUUID == sample.uuid)
        #expect(context.upsertedWorkouts.first?.date == FernletDate.dayKey(for: sample.endDate))
    }

    @Test func refreshMatchingFernletWorkoutIDSetsHealthKitUUID() async throws {
        let workoutID = UUID()
        let context = FakeWorkoutSyncContext(existingIDs: [workoutID])
        let sample = FakeHealthWorkoutSample(metadata: ["fernlet.workoutID": workoutID.uuidString])
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])

        #expect(context.setUUIDCalls.count == 1)
        #expect(context.setUUIDCalls.first?.workoutID == workoutID)
        #expect(context.setUUIDCalls.first?.hkUUID == sample.uuid)
        #expect(context.upsertedWorkouts.isEmpty)
    }

    @Test func refreshKnownHealthKitUUIDNoOps() async throws {
        let sample = FakeHealthWorkoutSample()
        let context = FakeWorkoutSyncContext(existingHealthKitUUIDs: [sample.uuid])
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])

        #expect(context.setUUIDCalls.isEmpty)
        #expect(context.upsertedWorkouts.isEmpty)
    }

    /// Regression for prior finding #21: if the integration is disabled while a long-lived
    /// workout observation query is still alive (disable ran on a different service
    /// instance), reconcile must import nothing AND tear down the orphaned query so Apple
    /// Health workouts stop flowing in.
    @Test func reconcileStopsObservationWhenIntegrationDisabled() {
        let context = FakeWorkoutSyncContext()
        let sample = FakeHealthWorkoutSample()
        let service = FakeWorkoutHealthKitService(authorizationStatuses: [:])
        service.integrationAvailable = false
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])

        #expect(context.upsertedWorkouts.isEmpty)
        #expect(service.stopObservingWorkoutsCallCount == 1)
    }

    @Test func saveIfAuthorizedNoOpsWhenWorkoutAuthorizationMissing() async {
        let context = FakeWorkoutSyncContext()
        let service = FakeWorkoutHealthKitService(authorizationStatuses: [:])
        let sync = WorkoutHealthKitSync(context: context, service: service)

        await sync.saveIfAuthorized(makeWorkout(), date: context.todayKey)

        #expect(service.saveWorkoutCallCount == 0)
        #expect(context.setUUIDCalls.isEmpty)
    }

    @Test func isWorkoutLoggingAuthorizedChecksWorkoutTypeIdentifier() {
        let snapshot = AuthorizationSnapshot(
            isAvailable: true,
            writeStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )

        #expect(WorkoutHealthKitSync.isWorkoutLoggingAuthorized(snapshot))
    }

    @Test func isWorkoutLoggingAuthorizedChecksCapabilityRawValue() {
        let snapshot = AuthorizationSnapshot(
            isAvailable: true,
            writeStatuses: [HealthCapability.workoutLogging.rawValue: .sharingAuthorized]
        )

        #expect(WorkoutHealthKitSync.isWorkoutLoggingAuthorized(snapshot))
    }

    private func makeWorkout(id: UUID = UUID()) -> Workout {
        Workout(
            id: id,
            name: "Workout",
            type: .fullBody,
            mode: .strengthTraining,
            exercises: "Bench press",
            rpe: nil,
            notes: "",
            duration: 30,
            intensity: .moderate,
            completedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
    }
}

private struct FakeHealthWorkoutSample: HealthWorkoutSample {
    let uuid: UUID
    let workoutActivityType: HKWorkoutActivityType
    let duration: TimeInterval
    let endDate: Date
    let metadata: [String: Any]?

    init(
        uuid: UUID = UUID(),
        workoutActivityType: HKWorkoutActivityType = .running,
        duration: TimeInterval = 45 * 60,
        endDate: Date = Date(timeIntervalSince1970: 1_779_667_500),
        metadata: [String: Any]? = nil
    ) {
        self.uuid = uuid
        self.workoutActivityType = workoutActivityType
        self.duration = duration
        self.endDate = endDate
        self.metadata = metadata
    }

    func sumQuantity(for type: HKQuantityType) -> HKQuantity? {
        nil
    }
}

@MainActor
private final class FakeWorkoutSyncContext: WorkoutSyncContext {
    let todayKey = "2026-05-26"
    var existingIDs: Set<UUID>
    var existingHealthKitUUIDs: Set<UUID>
    private(set) var setUUIDCalls: [(workoutID: UUID, hkUUID: UUID, date: String)] = []
    private(set) var upsertedWorkouts: [(workout: Workout, date: String)] = []

    init(existingIDs: Set<UUID> = [], existingHealthKitUUIDs: Set<UUID> = []) {
        self.existingIDs = existingIDs
        self.existingHealthKitUUIDs = existingHealthKitUUIDs
    }

    func workoutExists(id: UUID) -> Bool {
        existingIDs.contains(id)
    }

    func workoutExists(healthKitUUID: UUID) -> Bool {
        existingHealthKitUUIDs.contains(healthKitUUID)
    }

    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
        setUUIDCalls.append((workoutID, hkUUID, date))
        existingHealthKitUUIDs.insert(hkUUID)
    }

    func upsertWorkout(_ workout: Workout, date: String) {
        upsertedWorkouts.append((workout, date))
        if let healthKitUUID = workout.healthKitUUID {
            existingHealthKitUUIDs.insert(healthKitUUID)
        }
    }
}

@MainActor
private final class FakeWorkoutHealthKitService: HealthKitServicing {
    var authorizationStatuses: [String: HKAuthorizationStatus]
    var observedWorkouts: [HKWorkout]
    var integrationAvailable = true
    var saveWorkoutUUID = UUID()
    private(set) var saveWorkoutCallCount = 0
    private(set) var stopObservingWorkoutsCallCount = 0

    init(authorizationStatuses: [String: HKAuthorizationStatus], observedWorkouts: [HKWorkout] = []) {
        self.authorizationStatuses = authorizationStatuses
        self.observedWorkouts = observedWorkouts
    }

    func isHealthDataAvailable() -> Bool { true }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome { AuthorizationOutcome(writeStatuses: [:]) }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        AuthorizationSnapshot(isAvailable: integrationAvailable, writeStatuses: authorizationStatuses)
    }
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws { }
    func startObservingWorkouts(handler: @escaping ([HKWorkout]) -> Void) async throws {
        handler(observedWorkouts)
    }
    func stopObservingWorkouts() { stopObservingWorkoutsCallCount += 1 }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { observedWorkouts }
    func save(_ samples: [HKObject]) async throws { }
    func delete(_ samples: [HKSample]) async throws { }
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] { [] }
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func loadBodyProfile() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws { }
    func saveWorkout(_ workout: Workout) async throws -> UUID {
        saveWorkoutCallCount += 1
        return saveWorkoutUUID
    }
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double? { nil }
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext { HealthDailyContext() }
    func disableIntegration() async throws { }
    func enableIntegration() async throws { }
    func openHealthPrivacySettings() async { }
}
