import Foundation
import HealthKit
import FernletDomainModel
import HealthKitGateway

/// The state the health sync flow needs from the app store. Refines `WorkoutSyncContext`
/// so the same host can back the owned `WorkoutHealthKitSync`. Mirrors the
/// `WorkoutHealthKitSync`/`WorkoutSyncContext` pattern so `HealthSyncCoordinator`
/// depends on this seam rather than the concrete `FernletStore` (plan §5d).
@MainActor
protocol HealthSyncContext: WorkoutSyncContext {
    var day: FernletDay { get set }
    func scheduleSnapshotSave()
}

/// HealthKit ingestion: daily-context merge + HealthKit-derived sleep + workout
/// import / backfill / observe, extracted from `FernletStore` (plan §5d). Owns the
/// `HealthKitServicing` dependency and the `WorkoutHealthKitSync` pipeline, keeping
/// HealthKit off the store/core path.
@MainActor
final class HealthSyncCoordinator {
    private unowned let host: any HealthSyncContext
    private let providedHealthKitService: (any HealthKitServicing)?
    private lazy var workoutHealthKitSync = WorkoutHealthKitSync(
        context: host,
        service: providedHealthKitService ?? HealthKitService()
    )

    init(host: any HealthSyncContext, healthKitService: (any HealthKitServicing)?) {
        self.host = host
        self.providedHealthKitService = healthKitService
    }

    func updateHealthContext(_ context: HealthDailyContext) {
        if var existing = host.day.healthContext {
            existing.merge(context)
            host.day.healthContext = existing
        } else {
            host.day.healthContext = context
        }
        if let sleepHours = context.body?.sleepHours {
            setHealthSleepHours(sleepHours)
        }
        host.scheduleSnapshotSave()
    }

    func setHealthSleepHours(_ hours: Double) {
        guard hours > 0 else { return }
        let roundedHours = (hours * 10).rounded() / 10
        let current = host.day.sleep
        host.day.sleep = SleepLog(
            hours: roundedHours,
            quality: current?.quality ?? .ok,
            note: current?.note ?? ""
        )
        host.scheduleSnapshotSave()
    }

    func saveWorkoutToHealthIfAuthorized(_ workout: Workout, date: String) async {
        await workoutHealthKitSync.saveIfAuthorized(workout, date: date)
    }

    func refreshWorkoutsFromHealth() async {
        await workoutHealthKitSync.refreshFromHealth()
    }

    func backfillWorkoutsFromHealthIfNeeded(defaults: UserDefaults = .standard) async {
        await workoutHealthKitSync.backfillIfNeeded(defaults: defaults)
    }

    func stopWorkoutObservation() {
        workoutHealthKitSync.stopObservation()
    }
}
