import Foundation
import FernletFoundation
import HealthKit
import FernletDomainModel

@MainActor
public protocol WorkoutSyncContext: AnyObject {
    var todayKey: String { get }
    func workoutExists(id: UUID) -> Bool
    func workoutExists(healthKitUUID: UUID) -> Bool
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String)
    func upsertWorkout(_ workout: Workout, date: String)
    /// True while a locally-removed workout's app-authored Health sample might still resurface (the save
    /// can land seconds after logging, after the row was removed). Consulted by `reconcileWorkouts` so a
    /// resurrected orphan is deleted-and-skipped, not re-imported as a new untagged Health row.
    func isWorkoutTombstoned(fernletWorkoutID: UUID) -> Bool
    /// Clears a tombstone once its Health sample has been confirmed deleted.
    func clearWorkoutTombstone(fernletWorkoutID: UUID)
    /// Removes the local row mirroring a Health sample that was deleted in the Health app. Must NOT
    /// restore a planned row or touch guided/progression bookkeeping — an external deletion is not an undo.
    func removeWorkoutByHealthKitUUID(_ hkUUID: UUID)
}

public protocol HealthWorkoutSample {
    var uuid: UUID { get }
    var workoutActivityType: HKWorkoutActivityType { get }
    var duration: TimeInterval { get }
    var endDate: Date { get }
    var metadata: [String: Any]? { get }
    func sumQuantity(for type: HKQuantityType) -> HKQuantity?
}

extension HKWorkout: HealthWorkoutSample {
    public func sumQuantity(for type: HKQuantityType) -> HKQuantity? {
        statistics(for: type)?.sumQuantity()
    }
}

public struct WorkoutHealthKitMetadata {
    public let muscleGroups: Set<MuscleGroup>
    public let exercises: String
    public let notes: String
    public let effort: Int?
    public let plannedWorkoutID: UUID?

    public init(muscleGroups: Set<MuscleGroup>, exercises: String, notes: String, effort: Int?, plannedWorkoutID: UUID?) {
        self.muscleGroups = muscleGroups
        self.exercises = exercises
        self.notes = notes
        self.effort = effort
        self.plannedWorkoutID = plannedWorkoutID
    }
}

@MainActor
public final class WorkoutHealthKitSync {
    private weak var context: WorkoutSyncContext?
    private let service: any HealthKitServicing

    public init(context: WorkoutSyncContext, service: any HealthKitServicing) {
        self.context = context
        self.service = service
    }

    public func saveIfAuthorized(_ workout: Workout, date: String) async {
        let snapshot = service.currentAuthorizationSnapshot()
        guard Self.isWorkoutLoggingAuthorized(snapshot) else { return }
        do {
            let hkUUID = try await service.saveWorkout(workout)
            context?.setWorkoutHealthKitUUID(workoutID: workout.id, hkUUID: hkUUID, date: date)
        } catch {
            FernletAuditLog.log("healthkit.workout.save.failed", context: ["error": error.localizedDescription])
        }
    }

    public func refreshFromHealth() async {
        do {
            try await service.startObservingWorkouts { [weak self] workouts, deletedHealthKitUUIDs in
                self?.reconcileWorkouts(workouts)
                self?.reconcileDeletedWorkouts(deletedHealthKitUUIDs)
            }
        } catch {
            FernletAuditLog.log("healthkit.workouts.refresh.failed", context: ["error": error.localizedDescription])
        }
    }

    /// Deletes the app-authored Health sample for a locally-removed workout. Fired by the store's
    /// `removeWorkout` for every removable (authored OR not-yet-stamped) row: an authored row's sample is
    /// deleted now; a row still mid-save has no sample yet, so the delete no-ops and the tombstone catches
    /// the sample once it lands (`reconcileWorkouts` deletes + skips it). Clears the tombstone as soon as
    /// the delete confirms. No-op when workout logging isn't authorized — there is no sample we could own.
    public func removeAuthoredWorkoutFromHealth(fernletWorkoutID id: UUID) async {
        guard Self.isWorkoutLoggingAuthorized(service.currentAuthorizationSnapshot()) else { return }
        do {
            let deleted = try await service.deleteWorkout(fernletWorkoutID: id)
            if deleted { context?.clearWorkoutTombstone(fernletWorkoutID: id) }
        } catch {
            FernletAuditLog.log("healthkit.workout.delete.failed", context: ["error": error.localizedDescription])
        }
    }

    /// Re-syncs an edited authored workout's Health copy. `HKWorkout` samples are immutable, so the only
    /// way to reflect an edit is delete-the-old-sample + save-a-new-one. The new sample re-stamps the row
    /// with a fresh `healthKitUUID` + authored flag (via `saveIfAuthorized` → `setWorkoutHealthKitUUID`);
    /// the workout id (== `fernlet.workoutID` metadata) is unchanged, so reconcile keeps matching. The
    /// store clears the local row's `healthKitUUID` BEFORE calling this, so the delete's own deleted-object
    /// echo can't match — and therefore can't remove — the just-edited row.
    public func resyncAuthoredWorkoutInHealth(_ workout: Workout, date: String) async {
        guard Self.isWorkoutLoggingAuthorized(service.currentAuthorizationSnapshot()) else { return }
        do {
            _ = try await service.deleteWorkout(fernletWorkoutID: workout.id)
        } catch {
            FernletAuditLog.log("healthkit.workout.resyncDelete.failed", context: ["error": error.localizedDescription])
        }
        await saveIfAuthorized(workout, date: date)
    }

    public func backfillIfNeeded(defaults: UserDefaults = .standard) async {
        guard HealthKitService.shouldRunWorkoutBackfill(defaults: defaults) else { return }

        do {
            let workouts = try await service.backfillWorkoutsFromHealth(referenceDate: .now)
            reconcileWorkouts(workouts)
            HealthKitService.markWorkoutBackfillCompleted(defaults: defaults)
        } catch {
            FernletAuditLog.log("healthkit.workouts.backfill.failed", context: ["error": error.localizedDescription])
        }
    }

    static func makeWorkout(from sample: some HealthWorkoutSample) -> Workout {
        let activityType: WorkoutActivityType = {
            if let rawValue = sample.metadata?["fernlet.activityType"] as? String,
               let type = WorkoutActivityType(rawValue: rawValue) {
                return type
            }
            let base = ActivityTypeCatalog.fernletType(for: sample.workoutActivityType)
            if base == .cycling,
               let indoor = sample.metadata?[HKMetadataKeyIndoorWorkout] as? Bool, indoor {
                return .indoorCycling
            }
            return base
        }()
        let durationMin = Int(sample.duration / 60)
        let kcal = sample.sumQuantity(for: HKQuantityType(.activeEnergyBurned))?.doubleValue(for: .kilocalorie())
        let distanceMiles: Double? = {
            let types: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
            for typeID in types {
                if let quantity = sample.sumQuantity(for: HKQuantityType(typeID))?.doubleValue(for: .mile()), quantity > 0 {
                    return quantity
                }
            }
            return nil
        }()
        let name = (sample.metadata?["fernlet.activityName"] as? String) ?? activityType.displayName
        let mode: WorkoutMode = {
            if sample.workoutActivityType == .traditionalStrengthTraining || sample.workoutActivityType == .functionalStrengthTraining {
                return .strengthTraining
            }
            return .activity
        }()
        let metadata = parseFernletMetadata(sample.metadata)
        return Workout(
            name: name,
            type: activityType.fernletCategory,
            mode: mode,
            activityType: mode == .activity ? activityType : nil,
            exercises: metadata.exercises,
            rpe: nil,
            notes: metadata.notes,
            duration: durationMin,
            distanceMiles: distanceMiles,
            activeEnergyKcal: kcal,
            effort: metadata.effort,
            muscleGroups: metadata.muscleGroups,
            healthKitUUID: sample.uuid,
            plannedWorkoutID: metadata.plannedWorkoutID,
            intensity: .moderate,
            completedAt: sample.endDate
        )
    }

    public static func parseFernletMetadata(_ metadata: [String: Any]?) -> WorkoutHealthKitMetadata {
        let muscleGroupsRaw = (metadata?["fernlet.muscleGroups"] as? String) ?? ""
        let muscleGroups = Set(muscleGroupsRaw.split(separator: ",").compactMap { rawValue in
            MuscleGroup(rawValue: String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let exercises = (metadata?["fernlet.exercises"] as? String) ?? ""
        let notes = (metadata?["fernlet.notes"] as? String) ?? ""
        let effort = (metadata?["fernlet.effort"] as? NSNumber)?.intValue
        let plannedWorkoutID = (metadata?["fernlet.plannedWorkoutID"] as? String).flatMap(UUID.init(uuidString:))
        return WorkoutHealthKitMetadata(
            muscleGroups: muscleGroups,
            exercises: exercises,
            notes: notes,
            effort: effort,
            plannedWorkoutID: plannedWorkoutID
        )
    }

    public static func isWorkoutLoggingAuthorized(_ snapshot: AuthorizationSnapshot) -> Bool {
        snapshot.status(for: HKObjectType.workoutType().identifier) == .sharingAuthorized ||
        snapshot.status(for: HealthCapability.workoutLogging.rawValue) == .sharingAuthorized
    }

    public func stopObservation() {
        service.stopObservingWorkouts()
    }

    public func reconcileWorkouts(_ samples: [some HealthWorkoutSample]) {
        guard let context else { return }
        // The integration can be disabled by a *different* HealthKitService instance
        // (the Privacy screen builds its own), which cannot reach this long-lived
        // observation query. If we observe that it is now disabled, tear the query down
        // here so Apple Health workouts stop importing instead of flowing in until relaunch.
        guard service.currentAuthorizationSnapshot().isAvailable else {
            stopObservation()
            return
        }
        for sample in samples {
            let externalID = sample.metadata?["fernlet.workoutID"] as? String
            let syncID = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
            let knownID = externalID ?? syncID
            let knownUUID = knownID.flatMap(UUID.init(uuidString:))
            // A tombstoned id is a locally-removed workout whose app-authored Health sample just
            // resurfaced (its in-flight save landed after the row was gone). Delete it from Health and
            // skip the import so it can't come back as a new, untagged, unremovable Health row.
            if let knownUUID, context.isWorkoutTombstoned(fernletWorkoutID: knownUUID) {
                Task { [weak self] in
                    await self?.removeAuthoredWorkoutFromHealth(fernletWorkoutID: knownUUID)
                }
                continue
            }
            if let knownUUID, context.workoutExists(id: knownUUID) {
                context.setWorkoutHealthKitUUID(
                    workoutID: knownUUID,
                    hkUUID: sample.uuid,
                    date: FernletDate.dayKey(for: sample.endDate)
                )
                continue
            }
            if context.workoutExists(healthKitUUID: sample.uuid) {
                continue
            }

            let workout = Self.makeWorkout(from: sample)
            let dayKey = FernletDate.dayKey(for: sample.endDate)
            context.upsertWorkout(workout, date: dayKey)
        }
    }

    /// Consumes the Health-app-side deletions the workout observer delivers: for each deleted sample the
    /// local mirror row (matched by `healthKitUUID`, imports AND authored alike) is removed, making the
    /// row's "manage it in the Health app" advice real. A row removed this way must NOT restore a planned
    /// row or touch guided/progression bookkeeping — an external deletion is not an undo — which the
    /// context method enforces. Self-initiated deletes (our own remove/edit-resync) echo back here too, but
    /// find no matching row (remove already dropped it; edit cleared the row's `healthKitUUID`), so they
    /// no-op.
    public func reconcileDeletedWorkouts(_ deletedHealthKitUUIDs: [UUID]) {
        guard let context else { return }
        for uuid in deletedHealthKitUUIDs {
            context.removeWorkoutByHealthKitUUID(uuid)
        }
    }
}
