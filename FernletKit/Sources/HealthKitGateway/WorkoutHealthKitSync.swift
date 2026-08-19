import Foundation
import FernletFoundation
import HealthKit
import FernletDomainModel

/// The slice of app-store state ``WorkoutHealthKitSync`` needs to reconcile Health workouts with
/// local rows.
///
/// The host-protocol seam that keeps this gateway module off any store dependency: the app's
/// `FernletStore` is the production conformer (its `HealthSyncContext` refinement in
/// `HealthSyncCoordinator` adds app-only members), and tests supply fakes. The pattern is mirrored
/// by several other app coordinators (`ProximityHost`, `MealResolutionService`, etc.). Held `weak`
/// by the sync object, so every call is best-effort against a possibly-deallocated store.
/// `@MainActor` because the conformer is the observable app store.
@MainActor
public protocol WorkoutSyncContext: AnyObject {
    /// Day key (`yyyy-MM-dd`) for "today" as the store defines it.
    var todayKey: String { get }
    /// Whether a local row exists for this Fernlet workout id (on any day).
    func workoutExists(id: UUID) -> Bool
    /// Whether a local row already mirrors this Health sample UUID (prevents duplicate imports).
    func workoutExists(healthKitUUID: UUID) -> Bool
    /// Stamps an existing row with the Health sample UUID it now mirrors (and authored provenance).
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String)
    /// Inserts or replaces the local row for a workout imported/rebuilt from a Health sample.
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

/// The read-only surface of a Health workout sample that reconciliation needs.
///
/// A testability seam: `HKWorkout` is the production conformer (retroactively, below), and the unit
/// tests conform lightweight fakes so ``WorkoutHealthKitSync/reconcileWorkouts(_:)`` and
/// `WorkoutHealthKitSync.makeWorkout(from:authoredFernletID:)` can run without a real Health store.
public protocol HealthWorkoutSample {
    var uuid: UUID { get }
    var workoutActivityType: HKWorkoutActivityType { get }
    var duration: TimeInterval { get }
    var endDate: Date { get }
    /// Sample metadata; Fernlet-authored samples carry the `fernlet.*` keys written by
    /// `HealthKitService.makeMetadata`.
    var metadata: [String: Any]? { get }
    /// Bundle identifier of the app that WROTE this sample (`sourceRevision.source.bundleIdentifier`).
    /// The only non-forgeable provenance HealthKit offers — every `metadata` key, INCLUDING the standard
    /// `HKMetadataKeySyncIdentifier`, is writable by any co-installed app with workout share access.
    /// `nil` means "unknown", which callers MUST treat as not-ours (fail closed).
    ///
    /// Deliberately has NO protocol-extension default: a default of `nil` would silently re-open the
    /// hole for any future conformer, so the missing-witness compile error is the forcing function.
    var sourceBundleID: String? { get }
    /// Cumulative statistic for one quantity type over the workout (energy, distance).
    func sumQuantity(for type: HKQuantityType) -> HKQuantity?
}

/// Production conformance: a real Health workout answers ``HealthWorkoutSample/sumQuantity(for:)``
/// from its per-type statistics, and reports the writing app from its source revision.
extension HKWorkout: HealthWorkoutSample {
    /// The writing app's bundle identifier, straight off the sample's `sourceRevision` — the one
    /// field HealthKit stamps itself and no other app can forge.
    public var sourceBundleID: String? { sourceRevision.source.bundleIdentifier }

    public func sumQuantity(for type: HKQuantityType) -> HKQuantity? {
        statistics(for: type)?.sumQuantity()
    }
}

/// The Fernlet-specific fields decoded from a Health sample's `fernlet.*` metadata keys.
///
/// Produced by ``WorkoutHealthKitSync/parseFernletMetadata(_:)`` when rebuilding a local row from a
/// Health sample; foreign (non-Fernlet) samples yield empty/nil fields. The inverse of what
/// `HealthKitService.makeMetadata` writes on save.
public struct WorkoutHealthKitMetadata {
    public let muscleGroups: Set<MuscleGroup>
    public let exercises: String
    public let notes: String
    public let effort: Int?
    /// Links a completed workout back to the planned row it fulfilled, so a rebuild keeps the plan
    /// association.
    public let plannedWorkoutID: UUID?

    public init(muscleGroups: Set<MuscleGroup>, exercises: String, notes: String, effort: Int?, plannedWorkoutID: UUID?) {
        self.muscleGroups = muscleGroups
        self.exercises = exercises
        self.notes = notes
        self.effort = effort
        self.plannedWorkoutID = plannedWorkoutID
    }
}

/// Two-way reconciler between Fernlet's local workout rows and Apple Health workout samples.
///
/// Owned by the app's `HealthSyncCoordinator` (one long-lived instance per launch). Outbound, it
/// writes app-logged workouts to Health (``saveIfAuthorized(_:date:)``), deletes the app-authored
/// sample when a row is removed (``removeAuthoredWorkoutFromHealth(fernletWorkoutID:)``), and
/// re-syncs edits via delete-then-save (``resyncAuthoredWorkoutInHealth(_:date:)``) because
/// `HKWorkout` samples are immutable. Inbound, it observes Health via
/// ``HealthKitServicing/startObservingWorkouts(handler:)`` and folds additions and deletions into
/// the store (``reconcileWorkouts(_:)`` / ``reconcileDeletedWorkouts(_:)``), plus a one-time 30-day
/// backfill (``backfillIfNeeded(defaults:)``).
///
/// Key invariants:
/// - Provenance takes BOTH halves: the sample's `sourceRevision` bundle identifier must be this app's
///   AND it must carry our private `fernlet.workoutID` key. Metadata is forgeable by any co-installed
///   app with workout share access (the standard `HKMetadataKeySyncIdentifier` included), so the source
///   is the half that decides. Only a proven-own sample rebuilds a row under its original id and stays
///   editable; everything else imports under a fresh id as a read-only row.
/// - Tombstones (via ``WorkoutSyncContext``) close the race where an in-flight save lands after the
///   local row was removed — the resurfacing sample is deleted and skipped, never re-imported.
/// - Health-app-side deletions are honored immediately (no grace window); a cross-device edit's
///   delete therefore transiently removes the row on other devices until the replacement sample
///   heals it (see ``reconcileDeletedWorkouts(_:)``).
///
/// `@MainActor`; holds its ``WorkoutSyncContext`` weakly and treats every Health call as
/// best-effort — failures are logged to `FernletAuditLog`, never thrown to callers.
@MainActor
public final class WorkoutHealthKitSync {
    /// The store seam, weak so a torn-down store silently no-ops reconciliation.
    private weak var context: WorkoutSyncContext?
    /// The HealthKit gateway used for all sample reads/writes/observation.
    private let service: any HealthKitServicing
    /// Workout ids whose tombstone delete is already running.
    ///
    /// R3: bounds task fan-out to one in-flight delete per id, so a batch that redelivers the same
    /// resurrected samples (HealthKit replays until the anchor advances) cannot re-issue deletes.
    private var inFlightTombstoneDeletes: Set<UUID> = []
    /// This app's bundle identifier — the value an inbound sample's ``HealthWorkoutSample/sourceBundleID``
    /// must equal before its `fernlet.*` metadata is believed. Injectable so the FOREIGN case is testable
    /// without depending on what `Bundle.main` resolves to under the test host.
    private let ownBundleID: String

    /// - Parameter ownBundleID: defaults to `Bundle.main.bundleIdentifier`, falling back to `""` — the
    ///   fail-closed value, since an empty string never equals a real sample's bundle id, so an
    ///   unresolvable `Bundle.main` degrades to "never claim authorship", never to "trust everything".
    public init(
        context: WorkoutSyncContext,
        service: any HealthKitServicing,
        ownBundleID: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.context = context
        self.service = service
        self.ownBundleID = ownBundleID
    }

    /// Writes a workout to Apple Health if workout sharing is authorized, then stamps the local row
    /// with the returned sample UUID. Silently no-ops when unauthorized; save failures are audited,
    /// not thrown.
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

    /// Starts (or restarts) the anchored workout observation, wiring added samples into
    /// ``reconcileWorkouts(_:)`` and deletions into ``reconcileDeletedWorkouts(_:)``. Adds are
    /// reconciled before deletes in each batch, which is what makes a same-batch edit-resync safe.
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
            // R7: the Bool is "a prior sample was found and deleted". `false` is legitimate for a
            // row that was never stamped, but it is ALSO what a predicate mismatch on a real old
            // sample returns — after which the save below leaves two samples in Health. Recovery is
            // to proceed (the new sample is the truth), with an audit line so the duplicate is
            // diagnosable instead of unexplained.
            let deleted = try await service.deleteWorkout(fernletWorkoutID: workout.id)
            if !deleted {
                FernletAuditLog.log("healthkit.workout.resync.noPriorSample", context: [
                    "workoutID": workout.id.uuidString
                ])
            }
        } catch {
            FernletAuditLog.log("healthkit.workout.resyncDelete.failed", context: ["error": error.localizedDescription])
        }
        await saveIfAuthorized(workout, date: date)
    }

    /// One-time (per install, tracked in `UserDefaults`) import of the trailing 30 days of Health
    /// workouts, reconciled through the same path as live observation. Marks completion only after
    /// a successful fetch so a failed backfill retries on the next launch.
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

    /// Upper bound on an imported sample's duration. A workout longer than a week is a corrupt or hostile
    /// sample, not a workout; clamping keeps the `Int` conversion total (a NaN/infinite `duration` traps).
    static let maxImportedDurationSeconds: TimeInterval = 7 * 24 * 3600

    /// The app's effort scale, as the activity logger's slider defines it (`MoveView` →
    /// `ActivityPickerSection`, `Slider(value:in: 1...10)`). An imported `fernlet.effort` is clamped into
    /// it so a corrupt or hostile sample cannot plant an out-of-scale value in the synced blob.
    static let importedEffortRange: ClosedRange<Int> = 1...10

    /// Builds a local row from a Health sample. `authoredFernletID` is non-nil only when the sample was
    /// WRITTEN BY THIS APP *and* carries our own `fernlet.workoutID` metadata (see
    /// ``ownWorkoutID(from:ownBundleID:)``), which makes it a sample Fernlet wrote: the row is rebuilt
    /// under that same workout id and re-marked `healthKitAuthored`
    /// rather than landing as a fresh random-id Health *import*. That keeps identity stable across
    /// devices — a rebuilt row merges with the same-id row another device holds instead of duplicating
    /// it — and keeps the row editable/removable, which an import is not.
    static func makeWorkout(from sample: some HealthWorkoutSample, authoredFernletID: UUID? = nil) -> Workout {
        // `fernlet.*` is OUR private provenance namespace. On a proven-own sample its contents are the
        // user's own text (Fernlet caps none of it on write, so any length cap here would silently
        // truncate their own notes on a legitimate cross-device rebuild). On any other sample it is
        // 100% attacker-controlled and no legitimate third-party app ever writes it — so it is ignored
        // outright rather than sanitized, which keeps forged names/notes/exercises out of the synced
        // blob and out of the on-device AI prompt entirely.
        let ownMetadata = authoredFernletID != nil ? sample.metadata : nil
        let activityType: WorkoutActivityType = {
            if let rawValue = ownMetadata?["fernlet.activityType"] as? String,
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
        // P10 rule 7: `Int(_:)` on a non-finite or absurd `Double` traps. `duration` comes off an
        // untrusted sample, so clamp it into a total range before converting.
        let durationMin = sample.duration.isFinite
            ? Int(min(max(sample.duration, 0), Self.maxImportedDurationSeconds) / 60)
            : 0
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
        let name = (ownMetadata?["fernlet.activityName"] as? String) ?? activityType.displayName
        let mode: WorkoutMode = {
            if sample.workoutActivityType == .traditionalStrengthTraining || sample.workoutActivityType == .functionalStrengthTraining {
                return .strengthTraining
            }
            return .activity
        }()
        let metadata = parseFernletMetadata(ownMetadata)
        // `HealthKitService.makeMetadata` writes the workout's true intensity onto every app-authored
        // sample; read it back so a REBUILT authored row returns as itself rather than reset to
        // `.moderate` — a lossy rebuild can win the day-record last-writer-wins merge and silently
        // revert an edit made on another device. Foreign samples lack the key and keep the default.
        let intensity = (ownMetadata?["fernlet.intensity"] as? String)
            .flatMap(WorkoutIntensity.init(rawValue:)) ?? .moderate
        return Workout(
            id: authoredFernletID ?? UUID(),
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
            healthKitAuthored: authoredFernletID != nil ? true : nil,
            plannedWorkoutID: metadata.plannedWorkoutID,
            intensity: intensity,
            completedAt: sample.endDate
        )
    }

    /// Decodes the `fernlet.*` metadata keys from a Health sample into a typed
    /// ``WorkoutHealthKitMetadata``; missing keys — or the `nil` dictionary callers pass for any sample
    /// whose authorship is not proven — yield empty/nil fields.
    public static func parseFernletMetadata(_ metadata: [String: Any]?) -> WorkoutHealthKitMetadata {
        let muscleGroupsRaw = (metadata?["fernlet.muscleGroups"] as? String) ?? ""
        let muscleGroups = Set(muscleGroupsRaw.split(separator: ",").compactMap { rawValue in
            MuscleGroup(rawValue: String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let exercises = (metadata?["fernlet.exercises"] as? String) ?? ""
        let notes = (metadata?["fernlet.notes"] as? String) ?? ""
        // Clamped to the logger's own 1...10 scale: the value round-trips through sample metadata, so a
        // corrupt or hostile write must not land an out-of-scale effort in the day record.
        let rawEffort = (metadata?["fernlet.effort"] as? NSNumber)?.intValue
        let effort = rawEffort.map { min(max($0, importedEffortRange.lowerBound), importedEffortRange.upperBound) }
        let plannedWorkoutID = (metadata?["fernlet.plannedWorkoutID"] as? String).flatMap(UUID.init(uuidString:))
        return WorkoutHealthKitMetadata(
            muscleGroups: muscleGroups,
            exercises: exercises,
            notes: notes,
            effort: effort,
            plannedWorkoutID: plannedWorkoutID
        )
    }

    /// Whether the snapshot shows workout sharing granted — keyed by the workout type identifier
    /// (the key the real service reports) or, as a fallback, the capability raw value (a key only
    /// test doubles produce). Gates every outbound write in this class.
    public static func isWorkoutLoggingAuthorized(_ snapshot: AuthorizationSnapshot) -> Bool {
        snapshot.status(for: HKObjectType.workoutType().identifier) == .sharingAuthorized ||
        snapshot.status(for: HealthCapability.workoutLogging.rawValue) == .sharingAuthorized
    }

    /// The workout id a sample may claim as OURS: its `fernlet.workoutID` metadata value, and ONLY when the
    /// sample was written by this app. Metadata is forgeable by any co-installed app with workout write
    /// access — `HKMetadataKeySyncIdentifier` included — so the bundle identifier is the half that decides.
    /// Fails closed: unknown or foreign source ⇒ nil ⇒ the sample imports as a foreign row and can never
    /// repoint or rebuild an existing one.
    static func ownWorkoutID(from sample: some HealthWorkoutSample, ownBundleID: String) -> UUID? {
        guard !ownBundleID.isEmpty, sample.sourceBundleID == ownBundleID else { return nil }
        guard let raw = sample.metadata?["fernlet.workoutID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// Tears down the long-lived workout observation query (used on disable and by
    /// ``reconcileWorkouts(_:)`` when it notices the integration was switched off elsewhere).
    public func stopObservation() {
        service.stopObservingWorkouts()
    }

    /// Folds a batch of observed/backfilled Health workout samples into local rows: re-stamps rows
    /// that already exist under a known Fernlet id, skips already-mirrored samples, deletes-and-skips
    /// tombstoned resurrections, rebuilds missing app-authored rows under their original id, and
    /// imports everything else as a fresh read-only row. Also tears the observation down if it
    /// notices the integration was disabled by another service instance.
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
        // R3: the tombstoned ids are collected here and deleted by ONE task after the loop, instead
        // of one detached Task per sample (unbounded fan-out on a resurrected batch).
        var tombstoned: [UUID] = []
        for sample in samples {
            // Authorship = OUR source AND our private `fernlet.workoutID` key. Metadata alone decides
            // nothing: any co-installed app with workout share access can write both that key and the
            // standard sync identifier, and a forged id would otherwise repoint or rebuild the user's
            // genuine row. Nothing silent: a foreign sample that claims one of our ids is audited.
            let ownID = Self.ownWorkoutID(from: sample, ownBundleID: ownBundleID)
            if ownID == nil, sample.metadata?["fernlet.workoutID"] != nil {
                FernletAuditLog.log("healthkit.workout.foreignProvenanceClaim", context: [
                    "source": sample.sourceBundleID ?? "unknown"
                ])
            }
            // A tombstoned id is a locally-removed workout whose app-authored Health sample just
            // resurfaced (its in-flight save landed after the row was gone). Delete it from Health and
            // skip the import so it can't come back as a new, untagged, unremovable Health row.
            if let ownID, context.isWorkoutTombstoned(fernletWorkoutID: ownID) {
                if !inFlightTombstoneDeletes.contains(ownID) {
                    inFlightTombstoneDeletes.insert(ownID)
                    tombstoned.append(ownID)
                }
                continue
            }
            if let ownID, context.workoutExists(id: ownID) {
                context.setWorkoutHealthKitUUID(
                    workoutID: ownID,
                    hkUUID: sample.uuid,
                    date: FernletDate.dayKey(for: sample.endDate)
                )
                continue
            }
            if context.workoutExists(healthKitUUID: sample.uuid) {
                continue
            }

            // No local row for this sample. If THIS APP wrote it and it carries our own
            // `fernlet.workoutID` (never `syncID`, which any app may set, and never metadata from a
            // foreign source) then Fernlet authored it and the row is missing — most often because
            // another device edited the workout and this device consumed the resync's *delete* of the old
            // sample before the day record or the replacement sample arrived. Rebuild under the sample's
            // own workout id and authored provenance so the row returns as itself, editable, instead of
            // demoted to an un-editable import under a fresh random id. A foreign sample falls through
            // here and lands as a normal read-only import: it is still a workout the user really did.
            let workout = Self.makeWorkout(from: sample, authoredFernletID: ownID)
            let dayKey = FernletDate.dayKey(for: sample.endDate)
            context.upsertWorkout(workout, date: dayKey)
        }
        guard !tombstoned.isEmpty else { return }
        Task { [weak self] in
            for id in tombstoned {
                await self?.removeAuthoredWorkoutFromHealth(fernletWorkoutID: id)
                self?.inFlightTombstoneDeletes.remove(id)
            }
        }
    }

    /// Consumes the Health-app-side deletions the workout observer delivers: for each deleted sample the
    /// local mirror row (matched by `healthKitUUID`, imports AND authored alike) is removed, making the
    /// row's "manage it in the Health app" advice real. A row removed this way must NOT restore a planned
    /// row or touch guided/progression bookkeeping — an external deletion is not an undo — which the
    /// context method enforces. Self-initiated deletes (our own remove/edit-resync) echo back here too, but
    /// find no matching row (remove already dropped it; edit cleared the row's `healthKitUUID`), so they
    /// no-op.
    ///
    /// That clear-before-resync guard is per-device. A SECOND device still holding the pre-edit row (whose
    /// `healthKitUUID` is the now-deleted old sample) has no way to tell "the user deleted this in the
    /// Health app" from "another device edited it" — the two are the same deletion until the replacement
    /// arrives. We deliberately honour the deletion immediately rather than deferring it behind a grace
    /// window: a deferral that an app kill lands inside would silently swallow a real Health-app deletion,
    /// which is the worse failure. The replacement sample then heals the row — it carries the unchanged
    /// `fernlet.workoutID`, so `reconcileWorkouts` rebuilds it under its own id with authored provenance.
    /// Net effect on the second device is a transient disappearance, not a demotion to an un-editable
    /// import. Deletes delivered in the same batch as (or after) the replacement never remove anything:
    /// `refreshFromHealth` reconciles adds first, which re-stamps the row's `healthKitUUID`.
    public func reconcileDeletedWorkouts(_ deletedHealthKitUUIDs: [UUID]) {
        guard let context else { return }
        for uuid in deletedHealthKitUUIDs {
            context.removeWorkoutByHealthKitUUID(uuid)
        }
    }
}
