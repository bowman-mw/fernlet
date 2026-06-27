import Foundation
import FernletFoundation
import HealthKit

@MainActor
protocol WorkoutSyncContext: AnyObject {
    var todayKey: String { get }
    func workoutExists(id: UUID) -> Bool
    func workoutExists(healthKitUUID: UUID) -> Bool
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String)
    func upsertWorkout(_ workout: Workout, date: String)
}

protocol HealthWorkoutSample {
    var uuid: UUID { get }
    var workoutActivityType: HKWorkoutActivityType { get }
    var duration: TimeInterval { get }
    var endDate: Date { get }
    var metadata: [String: Any]? { get }
    func sumQuantity(for type: HKQuantityType) -> HKQuantity?
}

extension HKWorkout: HealthWorkoutSample {
    func sumQuantity(for type: HKQuantityType) -> HKQuantity? {
        statistics(for: type)?.sumQuantity()
    }
}

struct WorkoutHealthKitMetadata {
    let muscleGroups: Set<MuscleGroup>
    let exercises: String
    let notes: String
    let effort: Int?
    let plannedWorkoutID: UUID?
}

@MainActor
final class WorkoutHealthKitSync {
    private weak var context: WorkoutSyncContext?
    private let service: any HealthKitServicing

    init(context: WorkoutSyncContext, service: any HealthKitServicing) {
        self.context = context
        self.service = service
    }

    func saveIfAuthorized(_ workout: Workout, date: String) async {
        let snapshot = service.currentAuthorizationSnapshot()
        guard Self.isWorkoutLoggingAuthorized(snapshot) else { return }
        do {
            let hkUUID = try await service.saveWorkout(workout)
            context?.setWorkoutHealthKitUUID(workoutID: workout.id, hkUUID: hkUUID, date: date)
        } catch {
            FernletAuditLog.log("healthkit.workout.save.failed", context: ["error": error.localizedDescription])
        }
    }

    func refreshFromHealth() async {
        do {
            try await service.startObservingWorkouts { [weak self] workouts in
                self?.reconcileWorkouts(workouts)
            }
        } catch {
            FernletAuditLog.log("healthkit.workouts.refresh.failed", context: ["error": error.localizedDescription])
        }
    }

    func backfillIfNeeded(defaults: UserDefaults = .standard) async {
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

    static func parseFernletMetadata(_ metadata: [String: Any]?) -> WorkoutHealthKitMetadata {
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

    static func isWorkoutLoggingAuthorized(_ snapshot: AuthorizationSnapshot) -> Bool {
        snapshot.status(for: HKObjectType.workoutType().identifier) == .sharingAuthorized ||
        snapshot.status(for: HealthCapability.workoutLogging.rawValue) == .sharingAuthorized
    }

    func stopObservation() {
        service.stopObservingWorkouts()
    }

    func reconcileWorkouts(_ samples: [some HealthWorkoutSample]) {
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
            if let knownID, let uuid = UUID(uuidString: knownID), context.workoutExists(id: uuid) {
                context.setWorkoutHealthKitUUID(
                    workoutID: uuid,
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
}
