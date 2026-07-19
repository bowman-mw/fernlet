import HealthKit
import FernletFoundation
import Testing
import FernletDomainModel
import HealthKitGateway
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

    /// Finding B: a locally-removed workout whose app-authored sample resurfaces (its in-flight save
    /// landed after the row was gone) must NOT be re-imported. reconcile skips the upsert and deletes the
    /// orphan from Health by its `fernlet.workoutID`, clearing the tombstone once the delete confirms.
    @Test func reconcileSkipsAndDeletesTombstonedSample() async {
        let removedID = UUID()
        let context = FakeWorkoutSyncContext(tombstonedIDs: [removedID])
        let sample = FakeHealthWorkoutSample(metadata: ["fernlet.workoutID": removedID.uuidString])
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])
        // The Health delete is fired on a detached Task; let it run.
        for _ in 0..<20 where service.deletedFernletWorkoutIDs.isEmpty { await Task.yield() }

        #expect(context.upsertedWorkouts.isEmpty)
        #expect(context.setUUIDCalls.isEmpty)
        #expect(service.deletedFernletWorkoutIDs == [removedID])
        #expect(context.clearedTombstones == [removedID])   // delete confirmed → tombstone pruned
    }

    /// Finding A.3: a Health-app-side deletion (delivered as deleted UUIDs) removes the matching local
    /// mirror row by `healthKitUUID` — making "manage it in the Health app" real.
    @Test func reconcileDeletedRemovesLocalRowByHealthKitUUID() {
        let context = FakeWorkoutSyncContext()
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)
        let deletedUUID = UUID()

        sync.reconcileDeletedWorkouts([deletedUUID])

        #expect(context.removedByHealthKitUUID == [deletedUUID])
    }

    /// A sample with no `fernlet.workoutID` is a genuine Apple Health import: fresh id, NOT authored, so
    /// the store keeps refusing edit/remove on it. Guards the authored-rebuild below from over-reaching.
    @Test func reconcileImportsForeignSampleWithoutAuthoredProvenance() throws {
        let context = FakeWorkoutSyncContext()
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([FakeHealthWorkoutSample()])

        let imported = try #require(context.upsertedWorkouts.first?.workout)
        #expect(imported.healthKitAuthored == nil)
        #expect(imported.isHealthImported)
    }

    /// A foreign sample carrying only `HKMetadataKeySyncIdentifier` — a key ANY app may set — must not be
    /// mistaken for one of ours: the authored rebuild keys off our private `fernlet.workoutID` alone.
    @Test func reconcileDoesNotClaimAuthorshipFromSyncIdentifierAlone() throws {
        let context = FakeWorkoutSyncContext()
        let foreignID = UUID()
        let sample = FakeHealthWorkoutSample(metadata: [HKMetadataKeySyncIdentifier: foreignID.uuidString])
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])

        let imported = try #require(context.upsertedWorkouts.first?.workout)
        #expect(imported.healthKitAuthored == nil)
        #expect(imported.id != foreignID)
    }

    /// Pre-merge review finding #4: two devices, Health iCloud on. Device A edits a Fernlet-authored
    /// workout W, so its resync deletes sample S_old and saves S_new. Device B still holds the pre-edit row
    /// (`healthKitUUID == S_old`), and A's edit is not yet merged in over CloudKit. If B's observer delivers
    /// S_old's DELETION first, B drops its row — then S_new arrives with no matching row left.
    ///
    /// S_new must rebuild W as ITSELF: same workout id (so it merges with A's edited row instead of
    /// duplicating it) and `healthKitAuthored` (so it stays editable/removable). Rebuilding it as a fresh
    /// random-id import would strand the user with a workout Fernlet refuses to edit or remove.
    @Test func deleteBeforeDayRecordRebuildsAuthoredWorkoutInsteadOfDemotingIt() throws {
        let workoutID = UUID()
        let oldSampleUUID = UUID()
        // Device B's pre-edit state: row W, stamped with the sample A is about to supersede.
        let context = FakeWorkoutSyncContext(
            existingIDs: [workoutID],
            existingHealthKitUUIDs: [oldSampleUUID]
        )
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        // Batch 1 — the resync's delete lands alone, ahead of both S_new and A's day record.
        sync.reconcileDeletedWorkouts([oldSampleUUID])
        #expect(context.removedByHealthKitUUID == [oldSampleUUID])
        context.existingIDs.remove(workoutID)   // the row is gone on B

        // Batch 2 — the replacement sample arrives, still tagged with the unchanged workout id.
        let newSample = FakeHealthWorkoutSample(metadata: ["fernlet.workoutID": workoutID.uuidString])
        sync.reconcileWorkouts([newSample])

        #expect(context.upsertedWorkouts.count == 1)
        let rebuilt = try #require(context.upsertedWorkouts.first?.workout)
        #expect(rebuilt.id == workoutID)                   // same identity → merges, never duplicates
        #expect(rebuilt.healthKitUUID == newSample.uuid)
        #expect(rebuilt.isHealthAuthored)                  // still Fernlet's own
        #expect(!rebuilt.isHealthImported)                 // NOT demoted to an un-editable import
    }

    /// The rebuild must not resurrect a workout the user removed here: a tombstoned id still wins, and its
    /// resurfaced sample is deleted from Health rather than rebuilt as authored.
    @Test func tombstoneStillBeatsAuthoredRebuild() async {
        let removedID = UUID()
        let context = FakeWorkoutSyncContext(tombstonedIDs: [removedID])
        let sample = FakeHealthWorkoutSample(metadata: ["fernlet.workoutID": removedID.uuidString])
        let service = FakeWorkoutHealthKitService(
            authorizationStatuses: [HKObjectType.workoutType().identifier: .sharingAuthorized]
        )
        let sync = WorkoutHealthKitSync(context: context, service: service)

        sync.reconcileWorkouts([sample])
        for _ in 0..<20 where service.deletedFernletWorkoutIDs.isEmpty { await Task.yield() }

        #expect(context.upsertedWorkouts.isEmpty)
        #expect(service.deletedFernletWorkoutIDs == [removedID])
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
    var tombstonedIDs: Set<UUID>
    private(set) var setUUIDCalls: [(workoutID: UUID, hkUUID: UUID, date: String)] = []
    private(set) var upsertedWorkouts: [(workout: Workout, date: String)] = []
    private(set) var clearedTombstones: [UUID] = []
    private(set) var removedByHealthKitUUID: [UUID] = []

    init(existingIDs: Set<UUID> = [], existingHealthKitUUIDs: Set<UUID> = [], tombstonedIDs: Set<UUID> = []) {
        self.existingIDs = existingIDs
        self.existingHealthKitUUIDs = existingHealthKitUUIDs
        self.tombstonedIDs = tombstonedIDs
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

    func isWorkoutTombstoned(fernletWorkoutID id: UUID) -> Bool {
        tombstonedIDs.contains(id)
    }

    func clearWorkoutTombstone(fernletWorkoutID id: UUID) {
        clearedTombstones.append(id)
        tombstonedIDs.remove(id)
    }

    func removeWorkoutByHealthKitUUID(_ hkUUID: UUID) {
        removedByHealthKitUUID.append(hkUUID)
        existingHealthKitUUIDs.remove(hkUUID)
    }
}

@MainActor
private final class FakeWorkoutHealthKitService: HealthKitServicing {
    var authorizationStatuses: [String: HKAuthorizationStatus]
    var observedWorkouts: [HKWorkout]
    var integrationAvailable = true
    var saveWorkoutUUID = UUID()
    var deleteWorkoutReturns = true
    private(set) var saveWorkoutCallCount = 0
    private(set) var stopObservingWorkoutsCallCount = 0
    private(set) var deletedFernletWorkoutIDs: [UUID] = []

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
    func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws {
        handler(observedWorkouts, [])
    }
    func stopObservingWorkouts() { stopObservingWorkoutsCallCount += 1 }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { observedWorkouts }
    func save(_ samples: [HKObject]) async throws { }
    func delete(_ samples: [HKSample]) async throws { }
    func deleteWorkout(fernletWorkoutID: UUID) async throws -> Bool {
        deletedFernletWorkoutIDs.append(fernletWorkoutID)
        return deleteWorkoutReturns
    }
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
