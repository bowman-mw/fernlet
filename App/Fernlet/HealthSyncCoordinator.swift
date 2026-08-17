import Foundation
import HealthKit
import FernletDomainModel
import HealthKitGateway

/// The state the health sync flow needs from the app store.
///
/// Refines `WorkoutSyncContext` so the same host can back the owned `WorkoutHealthKitSync`.
/// Mirrors the `WorkoutHealthKitSync`/`WorkoutSyncContext` pattern so ``HealthSyncCoordinator``
/// depends on this seam rather than the concrete ``FernletStore`` (plan §5d), which is its only
/// production conformer.
@MainActor
protocol HealthSyncContext: WorkoutSyncContext {
    var day: FernletDay { get set }
    func scheduleSnapshotSave()
}

/// HealthKit ingestion: daily-context merge + HealthKit-derived sleep + workout
/// import / backfill / observe, extracted from ``FernletStore`` (plan §5d).
///
/// Owns the `HealthKitServicing` dependency and the lazily-built `WorkoutHealthKitSync` pipeline,
/// keeping HealthKit off the store/core path. The host is held `unowned` through the
/// ``HealthSyncContext`` seam — the store owns this coordinator, so the coordinator can never
/// outlive it. @MainActor: it mutates `host.day` and schedules snapshot saves on the store's
/// main-actor state; the workout sync legs are async and best-effort (an unauthorized or failed
/// HealthKit call degrades to a no-op rather than surfacing an error).
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

    /// Merges a fresh `HealthDailyContext` into today's record (coalescing with what's already
    /// there), mirrors HealthKit-derived sleep hours into the sleep log, and schedules a save.
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

    /// The largest sleep total one calendar day can carry. HealthKit sums overlapping samples from
    /// several sources, so an ingested value above a full day is a defect in the sample set, not a
    /// night's sleep — it is dropped rather than scored (R5: validate at the ingestion boundary).
    private static let maxSleepHours: Double = 24

    /// Writes HealthKit-derived sleep hours (rounded to 0.1 h) into today's sleep log, preserving
    /// any user-authored quality/note. Non-finite, non-positive, or above-a-day hours are ignored.
    func setHealthSleepHours(_ hours: Double) {
        guard hours.isFinite, hours > 0, hours <= Self.maxSleepHours else { return }
        let roundedHours = (hours * 10).rounded() / 10
        let current = host.day.sleep
        host.day.sleep = SleepLog(
            hours: roundedHours,
            quality: current?.quality ?? .ok,
            note: current?.note ?? ""
        )
        host.scheduleSnapshotSave()
    }

    /// Writes an app-authored workout to Health when sharing is authorized (no-op otherwise).
    func saveWorkoutToHealthIfAuthorized(_ workout: Workout, date: String) async {
        await workoutHealthKitSync.saveIfAuthorized(workout, date: date)
    }

    /// Deletes the app-authored Health sample for a locally-removed workout (tombstone-guarded).
    func removeWorkoutFromHealth(fernletWorkoutID id: UUID) async {
        await workoutHealthKitSync.removeAuthoredWorkoutFromHealth(fernletWorkoutID: id)
    }

    /// Re-syncs an edited authored workout's immutable Health sample (delete-old + save-new).
    func resyncWorkoutInHealth(_ workout: Workout, date: String) async {
        await workoutHealthKitSync.resyncAuthoredWorkoutInHealth(workout, date: date)
    }

    /// Pulls current Health workouts into the diary (import + dedupe via the sync pipeline).
    func refreshWorkoutsFromHealth() async {
        await workoutHealthKitSync.refreshFromHealth()
    }

    /// One-time historical workout backfill (run-once flag lives in `defaults`), then starts the
    /// live observation the pipeline maintains.
    func backfillWorkoutsFromHealthIfNeeded(defaults: UserDefaults = .standard) async {
        await workoutHealthKitSync.backfillIfNeeded(defaults: defaults)
    }

    /// Stops the live Health workout observer (HealthKit master toggle off, or mid-wipe so the
    /// observer can't re-import samples into a just-emptied store).
    func stopWorkoutObservation() {
        workoutHealthKitSync.stopObservation()
    }
}
