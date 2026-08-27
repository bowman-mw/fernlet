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

    /// Merges a fresh `HealthDailyContext` into today's record and persists only when health values
    /// changed. `syncedAt` alone is volatile refresh metadata: it never dirties the snapshot.
    func updateHealthContext(_ context: HealthDailyContext) {
        let contextChanged = applyHealthContext(context)
        let sleepChanged = context.body?.sleepHours.map(applyHealthSleepHours) ?? false
        guard contextChanged || sleepChanged else { return }
        host.scheduleSnapshotSave()
    }

    private func applyHealthContext(_ context: HealthDailyContext) -> Bool {
        if var existing = host.day.healthContext {
            existing.merge(context)
            guard !Self.hasSameHealthValues(host.day.healthContext, existing) else { return false }
            host.day.healthContext = existing
            return true
        }
        guard context.hasContent else { return false }
        host.day.healthContext = context
        return true
    }

    private static func hasSameHealthValues(
        _ lhs: HealthDailyContext?,
        _ rhs: HealthDailyContext
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.activity == rhs.activity
            && lhs.body == rhs.body
            && lhs.cycle == rhs.cycle
            && lhs.mindfulness == rhs.mindfulness
            && lhs.intimate == rhs.intimate
    }

    /// The largest sleep total one calendar day can carry. HealthKit sums overlapping samples from
    /// several sources, so an ingested value above a full day is a defect in the sample set, not a
    /// night's sleep — it is dropped rather than scored (R5: validate at the ingestion boundary).
    private static let maxSleepHours: Double = 24

    /// Writes HealthKit-derived sleep hours (rounded to 0.1 h) into today's sleep log, preserving
    /// any user-authored quality/note. Non-finite, non-positive, or above-a-day hours are ignored.
    func setHealthSleepHours(_ hours: Double) {
        guard applyHealthSleepHours(hours) else { return }
        host.scheduleSnapshotSave()
    }

    @discardableResult
    private func applyHealthSleepHours(_ hours: Double) -> Bool {
        guard hours.isFinite, hours > 0, hours <= Self.maxSleepHours else { return false }
        let roundedHours = (hours * 10).rounded() / 10
        let current = host.day.sleep
        let updated = SleepLog(
            hours: roundedHours,
            quality: current?.quality ?? .ok,
            note: current?.note ?? ""
        )
        guard updated != current else { return false }
        host.day.sleep = updated
        return true
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

    /// Launch-only workout setup: one-time historical backfill followed by one persistent observer.
    /// The sync's request/opt-in gate makes both operations no-ops before permission is requested.
    func backfillWorkoutsFromHealthIfNeeded(defaults: UserDefaults = .standard) async {
        await workoutHealthKitSync.backfillIfNeeded(defaults: defaults)
        await workoutHealthKitSync.refreshFromHealth()
    }

    /// Stops the live Health workout observer (HealthKit master toggle off, or mid-wipe so the
    /// observer can't re-import samples into a just-emptied store).
    func stopWorkoutObservation() {
        workoutHealthKitSync.stopObservation()
    }
}
