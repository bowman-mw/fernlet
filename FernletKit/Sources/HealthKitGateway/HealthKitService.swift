import Observation
import FernletFoundation
import PrivateHealthStore
import CoreData
import Foundation
import HealthKit
import Security
import SwiftUI
#if canImport(UIKit)
import UIKit
import FernletDomainModel
#endif

/// The full HealthKit surface Fernlet's stores and coordinators consume — authorization,
/// observation, reads, writes, and integration enable/disable.
///
/// ``HealthKitService`` is the production conformer; tests and previews inject fakes. Consumers
/// (the app's `FernletStore`, `HealthSyncCoordinator`, `StressService`, the Privacy settings
/// screens, and ``WorkoutHealthKitSync`` in this module) depend on this protocol rather than the
/// concrete service so HealthKit never has to be live under test. `@MainActor`: conformers manage
/// main-actor query/observation state, and handlers are invoked on the main actor.
@MainActor
public protocol HealthKitServicing {
    /// Whether this device has a Health store at all (`HKHealthStore.isHealthDataAvailable()`).
    func isHealthDataAvailable() -> Bool
    /// Presents the system authorization sheet for one ``HealthCapability`` and reports the
    /// resulting per-type write statuses.
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome
    /// Current availability + per-type write statuses across every capability, without prompting.
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot
    /// Starts a persistent anchored query for one sample type, delivering adds/deletes since the
    /// keychain-persisted anchor to the handler (on the main actor).
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws
    /// Observes workout additions AND deletions. The handler receives the added/updated samples and the
    /// UUIDs of samples deleted since the last anchor (so a Health-app-side deletion can remove its local
    /// mirror row).
    func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws
    /// Tears down the long-lived workout observation query, if any.
    func stopObservingWorkouts()
    /// One-shot fetch of workouts ending at or after `anchorDate`, newest first.
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout]
    /// One-shot fetch of the trailing backfill window of workouts (30 days before `referenceDate`).
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout]
    /// Saves arbitrary samples to Health (integration-gated).
    func save(_ samples: [HKObject]) async throws
    /// Deletes specific fetched samples from Health (integration-gated).
    func delete(_ samples: [HKSample]) async throws
    /// Deletes the Fernlet-authored workout sample(s) matching `fernletWorkoutID` (our `fernlet.workoutID`
    /// / sync-identifier metadata). Returns whether anything was found and deleted. Only ever finds our own
    /// authored samples — imports carry no such metadata.
    func deleteWorkout(fernletWorkoutID: UUID) async throws -> Bool
    /// Interval-bucketed statistics for one quantity type from `anchor` to now.
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics]
    /// Prompts for body-profile read/write authorization, then loads the profile.
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile
    /// Loads age/sex/height/weight from Health without prompting.
    func loadBodyProfile() async throws -> HealthBodyProfile
    /// Writes the profile's height and weight to Health as fresh samples.
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws
    /// Writes a completed workout to Health via `HKWorkoutBuilder`, returning the new sample's UUID.
    func saveWorkout(_ workout: Workout) async throws -> UUID
    /// Merged asleep hours for the sleep night containing `referenceDate` (18:00–11:00 window).
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double?
    /// Assembles the day's activity/body/cycle/mindfulness/intimate context for the requested
    /// capabilities (all of them when `capabilities` is nil).
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext
    /// Turns the integration off: stops queries, purges cached values and anchors, flips the master
    /// toggle. Fail-closed — throws rather than leaving cached clinical data behind.
    func disableIntegration() async throws
    /// Flips the master toggle on and restarts any registered observations.
    func enableIntegration() async throws
    /// Deep-links to the Health privacy settings for Fernlet (best effort).
    func openHealthPrivacySettings() async
}

/// One calendar day of stress-relevant metrics from ``HealthKitService/stressMetricDays(daysBack:referenceDate:)``.
///
/// Raw HealthKit aggregates only — the app-side `StressService` joins these with diary
/// confounders (workouts, sick days) into `StressDaySample`s for the pure engine. This type
/// must never be persisted into any synced store (the stress sidecar is device-local).
public struct StressMetricDay: Equatable, Sendable {
    /// `yyyy-MM-dd` day key.
    public var dateKey: String
    /// Daily mean HRV (SDNN, milliseconds).
    public var hrvSDNN: Double?
    /// Daily mean resting heart rate (bpm).
    public var restingHR: Double?
    /// Daily mean respiratory rate (breaths/min).
    public var respiratoryRate: Double?
    /// Daily mean sleeping wrist temperature (°C, absolute — the caller derives deltas).
    public var wristTempC: Double?

    public init(dateKey: String, hrvSDNN: Double? = nil, restingHR: Double? = nil, respiratoryRate: Double? = nil, wristTempC: Double? = nil) {
        self.dateKey = dateKey
        self.hrvSDNN = hrvSDNN
        self.restingHR = restingHR
        self.respiratoryRate = respiratoryRate
        self.wristTempC = wristTempC
    }
}

/// The seven per-feature Health permission bundles Fernlet requests and gates on individually.
///
/// Each case maps to a concrete share/read type set (see `HealthKitService.types(for:)`) and to a
/// per-capability opt-in flag in `StoragePreferences.healthKitCapabilityEnabled`. The Settings
/// privacy screens iterate `allCases` to render one toggle-plus-summary row per capability, and the
/// raw value doubles as the stable preference key — do not rename cases.
public enum HealthCapability: String, CaseIterable, Identifiable {
    /// Age, biological sex, height, and weight (read; height/weight write-back).
    case bodyProfile
    /// Menstrual-cycle observations: flow, BBT, cervical mucus, spotting, ovulation tests (read + write).
    case cycleTracking
    /// Recovery signals: sleep, resting HR, HRV, respiratory rate, wrist temperature (read-only).
    case bodyContext
    /// Workouts plus their energy/distance samples (read + write).
    case workoutLogging
    /// Daily activity: steps, active energy, exercise minutes (read-only).
    case activityContext
    /// Mindful sessions completed in Fernlet (write; read for the day context).
    case mindfulness
    /// Sexual activity samples, only when the intimacy feature is explicitly enabled (read + write).
    case intimateLogging

    public var id: String { rawValue }

    /// Short display name for settings rows and status messages.
    public var title: String {
        switch self {
        case .bodyProfile: "Body profile"
        case .cycleTracking: "Cycle tracking"
        case .bodyContext: "Body context"
        case .workoutLogging: "Workout logging"
        case .activityContext: "Activity context"
        case .mindfulness: "Mindfulness"
        case .intimateLogging: "Intimate logging"
        }
    }

    /// User-facing sentence describing exactly what the capability reads and writes, shown beside
    /// its settings toggle.
    public var summary: String {
        switch self {
        case .bodyProfile:
            "Read age, biological sex, height, and weight from Apple Health. Fernlet can write height and weight changes back when Health access allows it."
        case .cycleTracking:
            "Read and write cycle observations like menstrual flow, basal body temperature, cervical mucus, intermenstrual bleeding, and ovulation test results."
        case .bodyContext:
            "Read sleep, resting heart rate, heart rate variability, respiratory rate, and sleeping wrist temperature for recovery-aware companion context."
        case .workoutLogging:
            "Read and write workouts in Apple Health so Fernlet and Apple Fitness stay in sync."
        case .activityContext:
            "Read steps, active energy, and exercise minutes for daily activity context."
        case .mindfulness:
            "Write mindful sessions completed in Fernlet to Apple Health."
        case .intimateLogging:
            "Read and write sexual activity only when explicitly enabled."
        }
    }
}

/// The per-type write statuses reported after a ``HealthKitServicing/requestAuthorization(for:)``
/// prompt.
///
/// Read statuses are deliberately absent: HealthKit never reveals read authorization, so write
/// status is the only signal Fernlet can surface. Keys are HealthKit type identifier strings.
public struct AuthorizationOutcome {
    /// Write (share) status per HealthKit type identifier for the capability just requested.
    public let writeStatuses: [String: HKAuthorizationStatus]

    public init(writeStatuses: [String: HKAuthorizationStatus]) {
        self.writeStatuses = writeStatuses
    }
}

/// The body-profile fields Fernlet can import from Apple Health (age, sex, height, weight), each
/// optional because Health may hold any subset.
///
/// Returned by ``HealthKitServicing/loadBodyProfile()`` and applied onto the user's
/// `UserNutritionProfile` via ``applying(to:)``; the field-count helpers drive the settings
/// messaging about what was imported versus what stays manual.
public struct HealthBodyProfile {
    public var age: Int?
    public var sex: BiologicalSex?
    public var heightInches: Double?
    public var weightPounds: Double?

    public init(age: Int? = nil, sex: BiologicalSex? = nil, heightInches: Double? = nil, weightPounds: Double? = nil) {
        self.age = age
        self.sex = sex
        self.heightInches = heightInches
        self.weightPounds = weightPounds
    }

    /// How many of the four fields Health actually supplied.
    public var appliedFieldCount: Int {
        [age != nil, sex != nil, heightInches != nil, weightPounds != nil].filter { $0 }.count
    }

    /// Names of the fields Health did not supply, for the "manual settings remain for …" message.
    public var missingFieldNames: [String] {
        var names: [String] = []
        if age == nil { names.append("age") }
        if sex == nil { names.append("sex") }
        if heightInches == nil { names.append("height") }
        if weightPounds == nil { names.append("weight") }
        return names
    }

    /// Overlays the Health-supplied fields onto an existing nutrition profile, leaving absent
    /// fields untouched.
    ///
    /// - Important: Values are clamped to Fernlet's supported ranges (age 13–100, height 48–84 in,
    ///   weight 70–500 lb) so an outlier Health sample cannot push the profile out of bounds.
    public func applying(to profile: UserNutritionProfile) -> UserNutritionProfile {
        var updated = profile
        if let age { updated.age = min(max(age, 13), 100) }
        if let sex { updated.sex = sex }
        if let heightInches { updated.heightInches = min(max(heightInches, 48), 84) }
        if let weightPounds { updated.weightPounds = min(max(weightPounds, 70), 500) }
        return updated
    }
}

/// A point-in-time view of the integration's availability and every capability's per-type write
/// status, taken without prompting.
///
/// Produced by ``HealthKitServicing/currentAuthorizationSnapshot()``; consumed by the settings
/// screens (status labels via `HKAuthorizationStatus.fernletLabel`) and by
/// ``WorkoutHealthKitSync``'s authorization gate. `isAvailable` folds in the master toggle, not
/// just device capability — a snapshot from a disabled integration reports unavailable.
public struct AuthorizationSnapshot {
    /// True only when the device has a Health store AND the master integration toggle is on.
    public let isAvailable: Bool
    /// Write (share) status per HealthKit type identifier, across all capabilities' share types.
    public let writeStatuses: [String: HKAuthorizationStatus]

    public init(isAvailable: Bool, writeStatuses: [String: HKAuthorizationStatus]) {
        self.isAvailable = isAvailable
        self.writeStatuses = writeStatuses
    }

    /// Write status for one HealthKit type identifier, or nil when the type is not a share type.
    public func status(for identifier: String) -> HKAuthorizationStatus? {
        writeStatuses[identifier]
    }
}

/// Static lookup of which write-type identifiers each capability's settings row should display
/// status for.
///
/// Purely presentational: the Settings sheet uses it to resolve which ``AuthorizationSnapshot``
/// entries belong to a capability's row. Read-only capabilities (body/activity context) return an
/// empty list since HealthKit exposes no read status to show.
public struct HealthAuthorizationPresentation {
    /// The HealthKit type identifiers whose write status represents this capability in the UI.
    /// Note the workout-logging list shows the energy/distance sample types, not the workout type
    /// itself.
    public static func writeTypeIdentifiers(for capability: HealthCapability) -> [String] {
        switch capability {
        case .bodyProfile:
            [
                HKQuantityTypeIdentifier.height.rawValue,
                HKQuantityTypeIdentifier.bodyMass.rawValue
            ]
        case .cycleTracking:
            [
                HKCategoryTypeIdentifier.menstrualFlow.rawValue,
                HKQuantityTypeIdentifier.basalBodyTemperature.rawValue,
                HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue,
                HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue,
                HKCategoryTypeIdentifier.ovulationTestResult.rawValue
            ]
        case .bodyContext, .activityContext:
            []
        case .workoutLogging:
            [
                HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
                HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                HKQuantityTypeIdentifier.distanceCycling.rawValue,
                HKQuantityTypeIdentifier.distanceSwimming.rawValue
            ]
        case .mindfulness:
            [HKCategoryTypeIdentifier.mindfulSession.rawValue]
        case .intimateLogging:
            [HKCategoryTypeIdentifier.sexualActivity.rawValue]
        }
    }
}

/// Errors thrown by ``HealthKitService`` and its conformance seams.
///
/// All three cases carry user-presentable `errorDescription`s; `healthDataUnavailable` doubles as
/// the deliberate "gate closed" error for the master-toggle and per-capability opt-in guards, not
/// only for devices without a Health store.
public enum HealthKitServiceError: LocalizedError {
    /// The device has no Health store, or an integration/capability gate is closed.
    case healthDataUnavailable
    /// HealthKit returned no type object for this identifier (should not happen on supported OS
    /// versions; carries the identifier for diagnostics).
    case missingHealthType(String)
    /// `disableIntegration()` was invoked on a `HealthKitService` with no concrete cache clearer
    /// installed. Disable fails closed rather than silently leaving opted-out clinical data behind.
    case cacheClearerUnavailable

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "Health data is not available on this device."
        case .missingHealthType(let identifier):
            "Fernlet could not create the HealthKit type for \(identifier)."
        case .cacheClearerUnavailable:
            "Fernlet could not clear cached HealthKit values, so it did not disable HealthKit. Please try again."
        }
    }
}

/// The thin `HKHealthStore` seam ``HealthKitService`` routes its store operations through.
///
/// Exists so tests can substitute a fake store: `SystemHealthKitStoreController` is the
/// production conformer (a pure pass-through to `HKHealthStore`), and the disable/delete-all test
/// suites inject recorders. Note the service still calls `healthStore` directly for some one-shot
/// sample/statistics queries — only authorization, observation lifecycle, saves, and deletes are
/// guaranteed to pass through this seam.
public protocol HealthKitStoreControlling: AnyObject {
    /// Presents the system authorization sheet for the given share/read type sets.
    func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws
    /// Write (share) status for a type; non-sample types report `.notDetermined`.
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    /// Starts a query on the underlying store.
    func execute(_ query: HKQuery)
    /// Stops a long-running query.
    func stop(_ query: HKQuery)
    /// Saves samples to the underlying store.
    func save(_ samples: [HKObject]) async throws
    /// Deletes specific fetched samples from the underlying store.
    func delete(_ samples: [HKSample]) async throws
    /// Bulk-deletes objects of one type matching a predicate. Needed for "delete everything": deleting
    /// by fetched sample requires read authorization, but a user may have granted write-only — so
    /// Fernlet could have written samples it cannot read back and therefore cannot delete one-by-one.
    /// `HKHealthStore.deleteObjects(of:predicate:)` deletes only the caller's OWN samples regardless.
    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws
    /// Turns off background delivery registered for a type (part of integration teardown).
    func disableBackgroundDelivery(for type: HKObjectType) async throws
}

/// Production ``HealthKitStoreControlling`` conformer: a direct pass-through to `HKHealthStore`.
///
/// Internal by design — callers construct a ``HealthKitService`` and this wrapper is created for
/// them; only tests ever supply a different controller. Non-sample types silently degrade
/// (`.notDetermined` status, no-op bulk delete) to match the seam's contract.
final class SystemHealthKitStoreController: HealthKitStoreControlling {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws {
        try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        guard let sampleType = type as? HKSampleType else { return .notDetermined }
        return healthStore.authorizationStatus(for: sampleType)
    }

    func execute(_ query: HKQuery) {
        healthStore.execute(query)
    }

    func stop(_ query: HKQuery) {
        healthStore.stop(query)
    }

    func save(_ samples: [HKObject]) async throws {
        try await healthStore.save(samples)
    }

    func delete(_ samples: [HKSample]) async throws {
        try await healthStore.delete(samples)
    }

    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        guard let sampleType = type as? HKSampleType else { return }
        _ = try await healthStore.deleteObjects(of: sampleType, predicate: predicate)
    }

    func disableBackgroundDelivery(for type: HKObjectType) async throws {
        try await healthStore.disableBackgroundDelivery(for: type)
    }
}

/// Purges every HealthKit-derived value Fernlet has cached in its own stores.
///
/// The dependency-inversion seam that keeps this gateway off the CloudKitSync/LocalPersistence
/// edge: the real conformer, the app-side `CoreDataHealthKitCacheCleaner`, needs both of those
/// modules and is installed into ``HealthKitService/defaultCacheClearer`` at app launch.
/// ``HealthKitService/disableIntegration()`` fails closed without a conformer — see
/// `NoopHealthKitCacheClearer` for the explicit opt-out.
public protocol HealthKitCacheClearing {
    /// Removes cached HealthKit-derived clinical values from local/synced storage; throwing aborts
    /// the disable so the opt-out never half-applies.
    func clearHealthKitCachedValues() throws
}

/// Explicit "clearing is genuinely not needed" cleaner, for the rare injection where a caller
/// wants `disableIntegration()` to succeed without purging a cache (e.g. a test exercising the
/// non-cache teardown).
///
/// It is **no longer** the implicit default: a ``HealthKitService`` with no
/// clearer installed now fails closed (``HealthKitServiceError/cacheClearerUnavailable``) so an
/// opt-out can never silently leave cached clinical data behind. The real
/// `CoreDataHealthKitCacheCleaner` lives app-side (it needs CloudKitSync's PersistenceController +
/// LocalPersistence's LocalFernletDatabase) and is installed via
/// ``HealthKitService/defaultCacheClearer`` at app launch.
struct NoopHealthKitCacheClearer: HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws {}
}

/// Keychain persistence for the `HKQueryAnchor`s that make Fernlet's anchored queries incremental
/// across launches.
///
/// One keychain item per observed sample type (account `healthKitAnchors.<identifier>`) plus a
/// dedicated item for the workout observation, all under the `com.fernlet.healthkit-anchors`
/// service with after-first-unlock, this-device-only accessibility (anchors are device-local state
/// and must never roam). Anchors are `NSKeyedArchiver`-encoded with secure coding; every operation
/// is best-effort — a corrupt or missing anchor simply restarts the query from scratch.
/// ``HealthKitService/disableIntegration()`` deletes all anchors so a re-enable replays history
/// rather than resuming from a stale position.
public struct HealthKitAnchorKeychain {
    /// Keychain service string shared by every anchor item.
    public static let service = "com.fernlet.healthkit-anchors"
    /// Account-name prefix for per-sample-type anchors.
    public static let accountPrefix = "healthKitAnchors."
    /// Dedicated account name for the workout observation anchor.
    public static let workoutAnchorKey = "fernlet.healthkit.workoutAnchor"

    /// Keychain account name for one sample type's anchor.
    public static func account(for identifier: String) -> String {
        accountPrefix + identifier
    }

    /// Deletes the stored anchors for every listed sample-type identifier.
    public static func deleteAll(for identifiers: [String]) {
        for identifier in identifiers {
            delete(identifier: identifier)
        }
    }

    public static func delete(identifier: String) {
        KeychainItem.delete(account: account(for: identifier), service: service)
    }

    public static func deleteWorkoutAnchor() {
        KeychainItem.delete(account: workoutAnchorKey, service: service)
    }

    public static func loadWorkoutAnchor() -> HKQueryAnchor? {
        KeychainItem.load(account: workoutAnchorKey, service: service).flatMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
    }

    public static func storeWorkoutAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        KeychainItem.store(data, account: workoutAnchorKey, service: service, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    public static func store(_ data: Data, identifier: String) {
        KeychainItem.store(data, account: account(for: identifier), service: service, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    public static func loadAnchor(for identifier: String) -> HKQueryAnchor? {
        KeychainItem.load(account: account(for: identifier), service: service).flatMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
    }

    public static func storeAnchor(_ anchor: HKQueryAnchor, for identifier: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        KeychainItem.store(data, account: account(for: identifier), service: service, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
}

/// Outcome of ``HealthKitService/deleteAllAuthoredSamples()``.
///
/// An enum rather than `Bool` because the
/// two failure modes need DIFFERENT messages from the "delete everything" funnel: `.failed` invites a
/// retry, while `.accessRevoked` cannot be fixed by retrying — once the user revokes Fernlet's share
/// access, only the Health app can remove the samples Fernlet wrote earlier.
public enum AuthoredSampleDeleteOutcome: Sendable {
    /// Every writable type cleared, or was an expected no-op skip (nothing of Fernlet's to delete).
    case complete
    /// At least one type hit an unexpected error — Fernlet-authored samples were left behind.
    case failed
    /// No unexpected errors, but at least one type refused with `.errorAuthorizationDenied`: the user
    /// revoked Fernlet's share access, so samples it wrote may remain in Health and Fernlet cannot
    /// remove them.
    case accessRevoked
}

/// Fernlet's production HealthKit gateway: the single class that talks to `HKHealthStore` for
/// authorization, observation, daily-context reads, workout/cycle/intimacy/mindfulness writes, and
/// the fail-closed integration disable.
///
/// The concrete ``HealthKitServicing`` conformer, and (via the `PeriodHealthKitServicing`
/// extension below) the cycle-event seam `PeriodTrackerStore` in the sealed `PrivateHealthStore`
/// module consumes — the one dependency edge that puts this module on the protected side of the S3
/// wall's DAG. Several instances coexist at runtime (the app store's, the Privacy settings
/// screen's, previews'), so cross-instance state deliberately lives outside the instance:
///
/// - **Gating:** almost every read/write first checks `isIntegrationEnabled`, which re-reads the
///   `healthKitMasterEnabled` flag live from the keychain-backed `StoragePreferencesStore` (never a
///   cached copy) so a toggle flipped by a *different* instance takes effect immediately. The
///   stress and mindfulness paths additionally enforce their per-capability opt-in themselves.
/// - **Persistence:** query anchors go through ``HealthKitAnchorKeychain``; preferences through
///   `StoragePreferencesStore`; the one-time workout backfill marker through `UserDefaults`.
///   Clinical samples live only in HealthKit — this class caches nothing itself.
/// - **Provenance:** app-authored workout samples are stamped with `fernlet.workoutID` (plus the
///   sync identifier) via ``makeMetadata(for:)``, which is what lets ``WorkoutHealthKitSync`` and
///   ``deleteWorkout(fernletWorkoutID:)`` find only Fernlet's own samples later.
/// - **Fail-closed disable:** ``disableIntegration()`` refuses to run without a
///   ``HealthKitCacheClearing`` conformer (instance-injected or the app-installed
///   ``defaultCacheClearer``) so opting out can never leave cached clinical values behind; every
///   enable/disable step is logged to `FernletAuditLog`.
///
/// Concurrency: `@MainActor` (query bookkeeping and preferences are main-actor state); HealthKit's
/// `@Sendable` completion handlers hop back via `Task { @MainActor in … }`, and the pure
/// type-lookup/metadata statics are `nonisolated`. The target compiles in Swift 5 language mode
/// specifically to keep those handler captures legal (see `Package.swift`). Failure mode for
/// closed gates and missing types is ``HealthKitServiceError``; observation callbacks silently
/// drop query errors (best-effort delivery).
@MainActor
public final class HealthKitService: HealthKitServicing {
    /// App-installed default cache cleaner. The concrete `CoreDataHealthKitCacheCleaner`
    /// lives in the app target (it needs CloudKitSync + LocalPersistence), so the app
    /// sets this provider at launch before any HealthKitService is constructed, keeping this
    /// gateway off the CloudKitSync/LocalPersistence edge. It is `nil` until then: a service
    /// constructed before the app wires it (a `#Preview`, a test, the share extension, a future
    /// early-launch path) has **no** clearer, and `disableIntegration()` fails closed rather than
    /// silently skipping the purge of cached HealthKit-derived clinical values.
    public static var defaultCacheClearer: HealthKitCacheClearing?

    /// The underlying Health store. Public because the `PeriodHealthKitServicing` conformance and
    /// some one-shot queries use it directly (bypassing ``HealthKitStoreControlling``).
    public let healthStore: HKHealthStore
    /// The seam all authorization/observation/save/delete traffic routes through (testable).
    private let storeController: HealthKitStoreControlling
    /// Optional: `nil` means "no clearer installed" → `disableIntegration()` throws rather than
    /// flipping the master switch off while leaving cached clinical data behind (fail-closed).
    private let cacheCleaner: HealthKitCacheClearing?
    /// Keychain-backed preferences access; the master toggle and per-capability opt-ins are always
    /// re-read live from here, never cached (see `isIntegrationEnabled`).
    private let preferencesStore: StoragePreferencesStore
    /// The single long-lived workout anchored query, if observation is running.
    private var workoutObservationQuery: HKAnchoredObjectQuery?
    /// Every currently executing long-lived query, so disable can stop them all.
    private var activeQueries: [HKQuery] = []
    /// Registered per-type observation handlers, kept so ``enableIntegration()`` can restart the
    /// anchored queries after a disable/enable cycle.
    private var observationRegistrations: [String: (type: HKSampleType, handler: (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void)] = [:]

    /// Creates a service over the given (or a fresh) Health store.
    ///
    /// - Parameters:
    ///   - healthStore: The Health store to read and write through; defaults to a fresh
    ///     `HKHealthStore`.
    ///   - storeController: Test seam; defaults to the pass-through `SystemHealthKitStoreController`.
    ///   - cacheCleaner: Falls back to ``defaultCacheClearer`` *as of construction*; ``disableIntegration()``
    ///     re-checks the static at call time to close the construction-order window.
    ///   - preferencesStore: Keychain preferences access; defaults to a fresh store on the standard service.
    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        storeController: HealthKitStoreControlling? = nil,
        cacheCleaner: HealthKitCacheClearing? = nil,
        preferencesStore: StoragePreferencesStore? = nil
    ) {
        self.healthStore = healthStore
        self.storeController = storeController ?? SystemHealthKitStoreController(healthStore: healthStore)
        self.cacheCleaner = cacheCleaner ?? Self.defaultCacheClearer
        self.preferencesStore = preferencesStore ?? StoragePreferencesStore()
    }

    public func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Presents the system prompt for one capability's share/read types; integration-gated, and
    /// reports only write statuses (HealthKit hides read authorization).
    public func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let types = try Self.types(for: capability)
        try await storeController.requestAuthorization(toShare: types.share, read: types.read)
        return AuthorizationOutcome(writeStatuses: writeStatuses(for: types.share))
    }

    /// Deletes every HealthKit sample Fernlet itself wrote, across every type it can write.
    ///
    /// Scoped by `HKSource.default()` — the current app — so it can only ever remove Fernlet's own
    /// samples. HealthKit does not permit deleting another app's data, and entries the user logged in
    /// Health or another app are untouched. That limit is the reason the delete dialog says the rest of
    /// Apple Health is theirs to clear.
    ///
    /// Best-effort per type: a type Fernlet was never authorized to share throws, and one unauthorized
    /// type must not abort the whole wipe.
    ///
    /// Returns HOW the wipe ended, not just whether — the two failure modes need different messages.
    /// The old `try?` swallowed every failure and returned Void, so the "delete everything" funnel —
    /// which promises these samples are gone — could report success while an unexpected error left
    /// Fernlet-authored samples behind. A never-granted / no-data / no-Health-store error is not a
    /// failure to report: nothing of Fernlet's was left behind. `.errorAuthorizationDenied` is neither
    /// a skip nor a plain failure: samples written BEFORE the user revoked share access remain in
    /// Health, and no retry from Fernlet can remove them — only the Health app can, so the caller must
    /// say that rather than report a false success (the old skip) or invite a doomed retry.
    ///
    /// Precedence when both occur: `.failed` wins — an unexpected error is retryable, and its generic
    /// label still tells the user Health entries remain.
    public func deleteAllAuthoredSamples() async -> AuthoredSampleDeleteOutcome {
        let shareTypes = Set(HealthCapability.allCases.flatMap { capability in
            (try? Self.types(for: capability).share) ?? []
        })
        let ownSamples = HKQuery.predicateForObjects(from: HKSource.default())
        var sawUnexpectedFailure = false
        var sawRevokedAccess = false
        for type in shareTypes {
            do {
                try await storeController.deleteObjects(of: type, predicate: ownSamples)
            } catch let error as HKError where Self.isExpectedDeleteSkip(error) {
                // Never-granted type, nothing matching the predicate, or Health unavailable on this
                // device: nothing Fernlet wrote was left behind, not a failure. Keep clearing the rest.
                continue
            } catch let error as HKError where error.code == .errorAuthorizationDenied {
                // Revoked share access: samples Fernlet wrote before the revocation may remain, and
                // Fernlet can no longer reach them. Tracked separately so the funnel can point the
                // user at the Health app instead of reporting the wipe complete.
                sawRevokedAccess = true
            } catch {
                // An unexpected error genuinely left authored samples behind — the one leg that used to
                // hide this. Record it but keep going so one bad type can't abort the rest of the wipe.
                sawUnexpectedFailure = true
            }
        }
        if sawUnexpectedFailure { return .failed }
        if sawRevokedAccess { return .accessRevoked }
        return .complete
    }

    /// A per-type delete error that provably left nothing of Fernlet's behind is an EXPECTED skip, not
    /// a failure: `.errorNoData` means the authored-samples predicate matched nothing (the NORMAL case
    /// for a type Fernlet was authorized for but never wrote to — a no-match delete left nothing behind
    /// by definition), `.errorAuthorizationNotDetermined` means the type was never granted at all, and
    /// `.errorHealthDataUnavailable` means this device has no Health store. Reporting any of these would
    /// cry wolf on the delete dialog just as surely as swallowing a real failure would lie on it.
    ///
    /// `.errorAuthorizationDenied` is deliberately NOT here: a user who let Fernlet write samples and
    /// then revoked its share access still has those samples in Health, so treating denial as a skip
    /// reports a wipe complete while the data remains — the exact silent-failure mode this funnel
    /// exists to prevent. Denial surfaces as `.accessRevoked` instead.
    private static func isExpectedDeleteSkip(_ error: HKError) -> Bool {
        switch error.code {
        case .errorNoData, .errorAuthorizationNotDetermined, .errorHealthDataUnavailable:
            return true
        default:
            return false
        }
    }

    /// Snapshot of the master gate (`isAvailable` folds the keychain toggle in, not just device
    /// capability) plus every capability's per-type write status, without prompting.
    public func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        let shareTypes = HealthCapability.allCases.flatMap { capability in
            (try? Self.types(for: capability).share) ?? []
        }
        return AuthorizationSnapshot(
            isAvailable: isIntegrationEnabled,
            writeStatuses: writeStatuses(for: Set(shareTypes))
        )
    }

    public func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        observationRegistrations[type.identifier] = (type, handler)
        startAnchoredQuery(for: type, handler: handler)
    }

    /// Starts (replacing any prior) the anchored workout observation limited to the trailing
    /// 30-day backfill window, resuming from the keychain-persisted anchor. Adds/deletes are
    /// delivered to the handler on the main actor and the new anchor is persisted after each batch.
    public func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        stopObservingWorkouts()

        let workoutType = HKObjectType.workoutType()
        let anchor = HealthKitAnchorKeychain.loadWorkoutAnchor()
        let startDate = Self.workoutBackfillStartDate(referenceDate: .now)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [])
        let query = HKAnchoredObjectQuery(
            type: workoutType,
            predicate: predicate,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { _, samples, deletedObjects, newAnchor, error in
            guard error == nil else { return }
            Self.deliver(workoutSamples: samples, deletedObjects: deletedObjects, anchor: newAnchor, handler: handler)
        }
        query.updateHandler = { _, samples, deletedObjects, newAnchor, error in
            guard error == nil else { return }
            Self.deliver(workoutSamples: samples, deletedObjects: deletedObjects, anchor: newAnchor, handler: handler)
        }
        workoutObservationQuery = query
        activeQueries.append(query)
        storeController.execute(query)
    }

    public func stopObservingWorkouts() {
        guard let query = workoutObservationQuery else { return }
        storeController.stop(query)
        activeQueries.removeAll { $0 === query }
        workoutObservationQuery = nil
    }

    public func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: anchorDate, end: nil, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples?.compactMap { $0 as? HKWorkout } ?? [])
            }
            healthStore.execute(query)
        }
    }

    public func backfillWorkoutsFromHealth(referenceDate: Date = .now) async throws -> [HKWorkout] {
        try await recentWorkouts(since: Self.workoutBackfillStartDate(referenceDate: referenceDate))
    }

    public func save(_ samples: [HKObject]) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        try await storeController.save(samples)
    }

    public func delete(_ samples: [HKSample]) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        try await storeController.delete(samples)
    }

    /// Deletes the Fernlet-authored workout sample(s) carrying this workout id in their metadata.
    ///
    /// - Returns: Whether any matching sample was found and deleted. Only ever matches our own
    ///   authored samples — imports carry no `fernlet.workoutID` / sync-identifier metadata.
    public func deleteWorkout(fernletWorkoutID id: UUID) async throws -> Bool {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        // We stamp both `fernlet.workoutID` and the sync identifier with the workout id on save; match
        // either so a sample is found regardless of which key survived.
        let idString = id.uuidString
        let byWorkoutID = HKQuery.predicateForObjects(withMetadataKey: "fernlet.workoutID", allowedValues: [idString])
        let bySyncID = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [idString])
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [byWorkoutID, bySyncID])
        let samples = try await fetchWorkouts(matching: predicate)
        guard !samples.isEmpty else { return false }
        try await storeController.delete(samples)
        return true
    }

    /// One-shot unsorted workout fetch for a predicate (used by the authored-sample delete).
    private func fetchWorkouts(matching predicate: NSPredicate) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples?.compactMap { $0 as? HKWorkout } ?? [])
            }
            healthStore.execute(query)
        }
    }

    public func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: nil,
                options: options,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }
                var statisticsResults: [HKStatistics] = []
                collection.enumerateStatistics(from: anchor, to: Date()) { statistics, _ in
                    statisticsResults.append(statistics)
                }
                continuation.resume(returning: statisticsResults)
            }
            healthStore.execute(query)
        }
    }

    /// Day-bucketed history of the stress-relevant metrics (HRV SDNN, resting HR, respiratory
    /// rate, sleeping wrist temperature) over the trailing window, one entry per calendar day
    /// (fields nil on days without samples), oldest first.
    ///
    /// Deliberate scope (Batch A): FOREGROUND PULL ONLY — no `HKObserverQuery`, no
    /// `enableBackgroundDelivery`, no new entitlement. The caller refreshes on launch and on
    /// scene-active; a day-grain baseline does not need background wakes.
    ///
    /// Gating: on top of the master toggle this ALSO enforces the per-capability
    /// `healthKitCapabilityEnabled["bodyContext"]` opt-in (read live from the keychain).
    /// `loadDailyHealthContext` historically leaves capability filtering to its callers; a
    /// stress baseline reads a 60-day clinical series, so this path fails closed itself.
    /// Individual metric queries are best-effort (a type the user never authorized simply
    /// contributes empty days) but the gates throw so the caller can scrub cached derivatives.
    public func stressMetricDays(daysBack: Int = 60, referenceDate: Date = .now) async throws -> [StressMetricDay] {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let preferences = StoragePreferencesStore.currentPreferences(service: preferencesStore.keychainService)
        guard preferences.healthKitCapabilityEnabled[HealthCapability.bodyContext.rawValue] == true else {
            throw HealthKitServiceError.healthDataUnavailable
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: referenceDate)
        let anchor = calendar.date(byAdding: .day, value: -(max(daysBack, 1) - 1), to: todayStart) ?? todayStart

        async let hrv = dailyAverages(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), anchor: anchor)
        async let restingHR = dailyAverages(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), anchor: anchor)
        async let respiratory = dailyAverages(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), anchor: anchor)
        async let wristTemp = dailyAverages(.appleSleepingWristTemperature, unit: .degreeCelsius(), anchor: anchor)
        let (hrvByDay, restingHRByDay, respiratoryByDay, wristTempByDay) = await (hrv, restingHR, respiratory, wristTemp)

        var days: [StressMetricDay] = []
        for offset in 0..<max(daysBack, 1) {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: anchor) else { continue }
            let key = FernletDate.dayKey(for: dayStart)
            days.append(StressMetricDay(
                dateKey: key,
                hrvSDNN: hrvByDay[key],
                restingHR: restingHRByDay[key],
                respiratoryRate: respiratoryByDay[key],
                wristTempC: wristTempByDay[key]
            ))
        }
        return days
    }

    /// Per-day `.discreteAverage` statistics for one quantity type, keyed by day key.
    /// Best-effort: an unauthorized/unavailable type returns an empty map rather than
    /// failing the whole stress fetch.
    private func dailyAverages(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, anchor: Date) async -> [String: Double] {
        guard let type = try? Self.quantityType(identifier) else { return [:] }
        let stats = (try? await statistics(for: type, options: .discreteAverage, interval: DateComponents(day: 1), anchor: anchor)) ?? []
        var byDay: [String: Double] = [:]
        for entry in stats {
            guard let value = entry.averageQuantity()?.doubleValue(for: unit) else { continue }
            byDay[FernletDate.dayKey(for: entry.startDate)] = Self.roundedTenth(value)
        }
        return byDay
    }

    public func requestBodyProfileAuthorization() async throws -> HealthBodyProfile {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        try await storeController.requestAuthorization(toShare: try Self.bodyProfileWriteTypes(), read: try Self.bodyProfileReadTypes())
        return try await loadBodyProfile()
    }

    public func loadBodyProfile() async throws -> HealthBodyProfile {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        async let heightInches = latestQuantityValue(for: try Self.quantityType(.height), unit: .inch())
        async let weightPounds = latestQuantityValue(for: try Self.quantityType(.bodyMass), unit: .pound())
        return HealthBodyProfile(
            age: Self.age(from: try? healthStore.dateOfBirthComponents()),
            sex: Self.biologicalSex(from: try? healthStore.biologicalSex().biologicalSex),
            heightInches: try await heightInches,
            weightPounds: try await weightPounds
        )
    }

    public func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let now = Date()
        let samples = try [
            HKQuantitySample(
                type: Self.quantityType(.height),
                quantity: HKQuantity(unit: .inch(), doubleValue: profile.heightInches),
                start: now,
                end: now
            ),
            HKQuantitySample(
                type: Self.quantityType(.bodyMass),
                quantity: HKQuantity(unit: .pound(), doubleValue: profile.weightPounds),
                start: now,
                end: now
            )
        ]
        try await healthStore.save(samples)
    }

    /// Writes a completed workout to Health via `HKWorkoutBuilder`, attaching energy/distance
    /// samples when present and the full `fernlet.*` provenance metadata.
    ///
    /// - Returns: The saved `HKWorkout`'s UUID, which the caller stamps onto the local row.
    /// - Important: Gated only on device availability (`isHealthDataAvailable()`), not the master
    ///   integration toggle — callers gate on workout-share authorization instead (see
    ///   ``WorkoutHealthKitSync/isWorkoutLoggingAuthorized(_:)``).
    public func saveWorkout(_ workout: Workout) async throws -> UUID {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }

        let config = Self.makeConfiguration(for: workout)
        let durationSeconds = TimeInterval((workout.duration ?? Self.defaultDuration(for: workout)) * 60)
        let endDate = workout.completedAt
        let startDate = endDate.addingTimeInterval(-durationSeconds)

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config, device: .local())
        try await Self.beginCollection(for: builder, at: startDate)

        var samples: [HKSample] = []
        if let kcal = workout.activeEnergyKcal, kcal > 0 {
            let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
            let sample = HKQuantitySample(
                type: HKQuantityType(.activeEnergyBurned),
                quantity: quantity,
                start: startDate,
                end: endDate
            )
            samples.append(sample)
        }
        if let miles = workout.distanceMiles, miles > 0 {
            let quantity = HKQuantity(unit: .mile(), doubleValue: miles)
            let sample = HKQuantitySample(
                type: HKQuantityType(Self.distanceTypeIdentifier(for: workout.activityType)),
                quantity: quantity,
                start: startDate,
                end: endDate
            )
            samples.append(sample)
        }
        if !samples.isEmpty {
            try await Self.add(samples, to: builder)
        }

        try await builder.addMetadata(Self.makeMetadata(for: workout))
        try await Self.endCollection(for: builder, at: endDate)
        let saved = try await builder.finishWorkout()
        guard let saved else { throw HealthKitServiceError.healthDataUnavailable }
        return saved.uuid
    }

    public func loadLastNightSleepHours(referenceDate: Date = Date()) async throws -> Double? {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        return try await sleepHours(referenceDate: referenceDate)
    }

    /// Assembles one day's `HealthDailyContext` (activity, body/sleep, cycle-event counts,
    /// mindfulness minutes, intimate-event counts) for the requested capabilities — all of them
    /// when `capabilities` is nil. Per-capability opt-in filtering is the CALLER's job here; only
    /// the master toggle is enforced.
    public func loadDailyHealthContext(referenceDate: Date = Date(), capabilities: Set<HealthCapability>? = nil) async throws -> HealthDailyContext {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let requested = capabilities ?? Set(HealthCapability.allCases)
        let dayInterval = Self.dayInterval(containing: referenceDate)
        var context = HealthDailyContext(syncedAt: Date())

        if requested.contains(.activityContext) {
            context.activity = HealthActivitySummary(
                steps: try await sumQuantity(.stepCount, unit: .count(), in: dayInterval).map { Int($0.rounded()) },
                activeEnergyKilocalories: try await sumQuantity(.activeEnergyBurned, unit: .kilocalorie(), in: dayInterval).map(Self.roundedTenth),
                exerciseMinutes: try await sumQuantity(.appleExerciseTime, unit: .minute(), in: dayInterval).map(Self.roundedTenth)
            )
        }

        if requested.contains(.bodyContext) {
            context.body = HealthBodyContext(
                sleepHours: try await sleepHours(referenceDate: referenceDate),
                restingHeartRateBPM: try await latestQuantityValue(for: try Self.quantityType(.restingHeartRate), unit: HKUnit.count().unitDivided(by: .minute())).map(Self.roundedTenth),
                heartRateVariabilityMS: try await latestQuantityValue(for: try Self.quantityType(.heartRateVariabilitySDNN), unit: HKUnit.secondUnit(with: .milli)).map(Self.roundedTenth),
                sleepStages: try await sleepStages(referenceDate: referenceDate)
            )
        }

        if requested.contains(.cycleTracking) {
            let samples = try await categorySamples(for: try Self.categoryType(.menstrualFlow), predicate: HKQuery.predicateForSamples(withStart: dayInterval.start, end: dayInterval.end, options: .strictStartDate))
            context.cycle = HealthCycleContext(
                menstrualFlowEventCount: samples.isEmpty ? nil : samples.count,
                latestCycleEventAt: samples.map(\.endDate).max()
            )
        }

        if requested.contains(.mindfulness) {
            let samples = try await categorySamples(for: try Self.categoryType(.mindfulSession), predicate: HKQuery.predicateForSamples(withStart: dayInterval.start, end: dayInterval.end, options: .strictStartDate))
            let minutes = samples.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 60 }
            context.mindfulness = HealthMindfulnessContext(mindfulSessionMinutes: minutes > 0 ? Self.roundedTenth(minutes) : nil)
        }

        if requested.contains(.intimateLogging) {
            let samples = try await categorySamples(for: try Self.categoryType(.sexualActivity), predicate: HKQuery.predicateForSamples(withStart: dayInterval.start, end: dayInterval.end, options: .strictStartDate))
            context.intimate = HealthIntimateContext(eventCount: samples.isEmpty ? nil : samples.count)
        }

        return context
    }

    /// Counts sexual-activity samples per day key across the month containing `month`, for the
    /// intimacy calendar overlay. Integration-gated; returns an empty map for an undecodable month.
    public func loadIntimacyEventsByDay(for month: Date) async throws -> [String: Int] {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [:] }
        let sexualActivity = try Self.categoryType(.sexualActivity)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let samples = try await categorySamples(for: sexualActivity, predicate: predicate)
        var result: [String: Int] = [:]
        for sample in samples {
            let key = FernletDate.dayKey(for: sample.startDate)
            result[key, default: 0] += 1
        }
        return result
    }

    /// Writes one sexual-activity sample (1-minute span) stamped with the sealed store's external
    /// UUID so the Health sample and the encrypted local note stay correlated. The clinical sample
    /// lives in HealthKit; any narrative stays in the sealed store — never here. Audited on success.
    public func saveIntimacyEvent(date: Date, protectionUsed: Bool?, externalUUID: UUID) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: externalUUID.uuidString
        ]
        if let protectionUsed {
            metadata[HKMetadataKeySexualActivityProtectionUsed] = protectionUsed
        }
        let sample = HKCategorySample(
            type: try Self.categoryType(.sexualActivity),
            value: HKCategoryValue.notApplicable.rawValue,
            start: date,
            end: date.addingTimeInterval(60),
            metadata: metadata
        )
        try await save([sample])
        FernletAuditLog.log("hk.write.saved", context: ["type": "intimacy", "externalUUID": externalUUID.uuidString])
    }

    /// Writes a completed in-app breathing session to Apple Health as an `HKCategorySample`
    /// `.mindfulSession` (the write authorization has been declared since the HealthKit integration
    /// shipped; this is its first writer).
    ///
    /// Gating mirrors `stressMetricDays`: the master toggle AND the per-capability
    /// `healthKitCapabilityEnabled["mindfulness"]` opt-in are enforced here (fail closed), and the
    /// write additionally requires granted mindful-session share authorization — it never triggers
    /// an authorization prompt of its own. Throws on any closed gate so tests can observe it; the
    /// First Aid caller deliberately swallows errors (a missed Health write must stay silent and
    /// non-blocking after a breathing exercise).
    public func saveMindfulSession(start: Date, end: Date) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let preferences = StoragePreferencesStore.currentPreferences(service: preferencesStore.keychainService)
        guard preferences.healthKitCapabilityEnabled[HealthCapability.mindfulness.rawValue] == true else {
            throw HealthKitServiceError.healthDataUnavailable
        }
        let type = try Self.categoryType(.mindfulSession)
        guard storeController.authorizationStatus(for: type) == .sharingAuthorized else {
            throw HealthKitServiceError.healthDataUnavailable
        }
        guard end > start else { return }
        let sample = HKCategorySample(
            type: type,
            value: HKCategoryValue.notApplicable.rawValue,
            start: start,
            end: end
        )
        try await save([sample])
        FernletAuditLog.log("hk.write.saved", context: ["type": "mindfulSession"])
    }

    /// Merged asleep hours inside the sleep-night window (18:00–11:00) containing `referenceDate`,
    /// clipping samples to the window and de-duplicating overlaps across sources; nil when nothing
    /// was asleep.
    private func sleepHours(referenceDate: Date) async throws -> Double? {
        let sleepType = try Self.categoryType(.sleepAnalysis)
        let interval = Self.sleepNightInterval(containing: referenceDate)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let samples = try await categorySamples(for: sleepType, predicate: predicate)
        let asleepIntervals = samples.compactMap { sample -> DateInterval? in
            guard let sleepValue = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  HKCategoryValueSleepAnalysis.allAsleepValues.contains(sleepValue) else { return nil }
            let start = max(sample.startDate, interval.start)
            let end = min(sample.endDate, interval.end)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
        let totalSeconds = Self.mergedDuration(for: asleepIntervals)
        guard totalSeconds > 0 else { return nil }
        return Self.roundedTenth(totalSeconds / 3600)
    }

    /// Buckets last night's sleep-analysis samples into deep/core/REM/awake durations. Returns nil
    /// when there are no asleep samples; the per-stage fields stay nil when a device only reports an
    /// undifferentiated asleep total (e.g. third-party trackers without staging). Minutes are merged
    /// per stage so overlapping samples from multiple sources don't double-count.
    private func sleepStages(referenceDate: Date) async throws -> SleepStagesData? {
        let sleepType = try Self.categoryType(.sleepAnalysis)
        let interval = Self.sleepNightInterval(containing: referenceDate)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let samples = try await categorySamples(for: sleepType, predicate: predicate)

        var deep: [DateInterval] = []
        var core: [DateInterval] = []
        var rem: [DateInterval] = []
        var awake: [DateInterval] = []
        var asleep: [DateInterval] = []
        for sample in samples {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            let start = max(sample.startDate, interval.start)
            let end = min(sample.endDate, interval.end)
            guard end > start else { continue }
            let span = DateInterval(start: start, end: end)
            switch value {
            case .asleepDeep: deep.append(span); asleep.append(span)
            case .asleepCore: core.append(span); asleep.append(span)
            case .asleepREM: rem.append(span); asleep.append(span)
            case .awake: awake.append(span)
            default:
                if HKCategoryValueSleepAnalysis.allAsleepValues.contains(value) { asleep.append(span) }
            }
        }

        let totalAsleepSeconds = Self.mergedDuration(for: asleep)
        guard totalAsleepSeconds > 0 else { return nil }

        func minutes(_ intervals: [DateInterval]) -> Double? {
            let seconds = Self.mergedDuration(for: intervals)
            return seconds > 0 ? Self.roundedTenth(seconds / 60) : nil
        }
        return SleepStagesData(
            deepMinutes: minutes(deep),
            coreMinutes: minutes(core),
            remMinutes: minutes(rem),
            awakeMinutes: minutes(awake),
            totalAsleepMinutes: Self.roundedTenth(totalAsleepSeconds / 60)
        )
    }

    /// Cumulative sum of one quantity type over an interval, in the given unit; nil when Health
    /// has no samples.
    private func sumQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> Double? {
        let type = try Self.quantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    /// One-shot fetch of category samples matching a predicate (sleep, cycle, mindfulness,
    /// intimacy paths).
    private func categorySamples(for type: HKCategoryType, predicate: NSPredicate?) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples?.compactMap { $0 as? HKCategorySample } ?? [])
            }
            healthStore.execute(query)
        }
    }

    /// Most recent sample's value for one quantity type (any date), in the given unit; nil when
    /// Health has none.
    private func latestQuantityValue(for type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    /// Turns the HealthKit integration off, fail-closed: stops every query, disables background
    /// delivery, purges the cached HealthKit-derived values via the cache clearer, deletes all
    /// stored anchors, and only then flips the master toggle off and resets the per-capability
    /// opt-ins. Throws (before any teardown) when no cache clearer is available, and rethrows any
    /// step's failure so the opt-out never half-applies; every attempt/outcome is audited.
    public func disableIntegration() async throws {
        FernletAuditLog.log("healthkit.disable.attempt")
        // Fail-closed: disabling HealthKit MUST purge the cached HealthKit-derived clinical values.
        // Resolve the clearer at CALL time — the instance value captured at init, else the current
        // static. This closes the construction-order window: a HealthKitService built before FernletApp
        // wired `defaultCacheClearer` (a #Preview, a test, a future early-launch path) still disables
        // correctly as long as the static is set by the time the user opts out. If NO clearer is
        // available even now, do NOT proceed — silently "succeeding" would flip the master switch off
        // while leaving opted-out clinical data in the local/synced store. Throw before any teardown so
        // the opt-out does not half-apply and the failure is audited and retryable.
        guard let cacheCleaner = cacheCleaner ?? Self.defaultCacheClearer else {
            FernletAuditLog.log("healthkit.disable.failed", context: ["error": "cache clearer not installed"])
            throw HealthKitServiceError.cacheClearerUnavailable
        }
        do {
            for query in activeQueries {
                storeController.stop(query)
            }
            activeQueries.removeAll()

            for type in observedObjectTypes() {
                try await storeController.disableBackgroundDelivery(for: type)
            }

            try cacheCleaner.clearHealthKitCachedValues()
            HealthKitAnchorKeychain.deleteAll(for: observedObjectTypes().map(\.identifier))
            HealthKitAnchorKeychain.deleteWorkoutAnchor()
            preferencesStore.update { preferences in
                preferences.healthKitMasterEnabled = false
                preferences.healthKitCapabilityEnabled = StoragePreferences.defaultHealthKitCapabilityEnabled
            }
            FernletAuditLog.log("healthkit.disable.completed")
        } catch {
            FernletAuditLog.log("healthkit.disable.failed", context: ["error": error.localizedDescription])
            throw error
        }
    }

    /// Flips the master toggle on and restarts every registered per-type observation (anchors were
    /// wiped on disable, so queries replay from scratch). Throws only when the device has no Health
    /// store; audited.
    public func enableIntegration() async throws {
        FernletAuditLog.log("healthkit.enable.attempt")
        guard isHealthDataAvailable() else {
            FernletAuditLog.log("healthkit.enable.failed", context: ["error": "healthDataUnavailable"])
            throw HealthKitServiceError.healthDataUnavailable
        }
        preferencesStore.update { preferences in
            preferences.healthKitMasterEnabled = true
        }
        for registration in observationRegistrations.values {
            startAnchoredQuery(for: registration.type, handler: registration.handler)
        }
        FernletAuditLog.log("healthkit.enable.completed")
    }

    /// Best-effort deep link to Fernlet's row in Health privacy settings (private `App-Prefs:`
    /// scheme first, then the app's own Settings page). No-op on platforms without UIKit.
    public func openHealthPrivacySettings() async {
        #if canImport(UIKit)
        let candidateURLs = [
            URL(string: "App-Prefs:HEALTH&path=SOURCES_ITEM_Fernlet"),
            URL(string: UIApplication.openSettingsURLString)
        ].compactMap { $0 }
        for url in candidateURLs {
            if await UIApplication.shared.open(url) {
                return
            }
        }
        #endif
    }

    /// The master gate consulted by nearly every read/write: device has a Health store AND the
    /// keychain `healthKitMasterEnabled` flag is on.
    private var isIntegrationEnabled: Bool {
        // Read the live keychain value rather than this instance's cached `preferences`.
        // Multiple HealthKitService instances exist (FernletStore, Privacy settings, etc.),
        // each with its own StoragePreferencesStore; the master toggle is flipped on a
        // different instance, so a cached read would keep reporting the old state until
        // relaunch — gating reads/writes/observation incorrectly.
        isHealthDataAvailable()
            && StoragePreferencesStore.currentPreferences(service: preferencesStore.keychainService).healthKitMasterEnabled
    }

    /// Shared delivery path for both workout-query result handlers: extracts workouts + deleted
    /// UUIDs off the query's callback queue, then hops to the main actor to invoke the handler and
    /// persist the new anchor.
    nonisolated private static func deliver(workoutSamples samples: [HKSample]?, deletedObjects: [HKDeletedObject]?, anchor: HKQueryAnchor?, handler: @escaping ([HKWorkout], [UUID]) -> Void) {
        let workouts = samples?.compactMap { $0 as? HKWorkout } ?? []
        let deletedUUIDs = (deletedObjects ?? []).map(\.uuid)
        Task { @MainActor in
            // A pure-deletion update carries no added samples — still deliver so the local mirror row can
            // be removed. Only skip the handler when there is genuinely nothing to report.
            if !workouts.isEmpty || !deletedUUIDs.isEmpty {
                handler(workouts, deletedUUIDs)
            }
            if let anchor { HealthKitAnchorKeychain.storeWorkoutAnchor(anchor) }
        }
    }

    private static func beginCollection(for builder: HKWorkoutBuilder, at startDate: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: startDate) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitServiceError.healthDataUnavailable)
                }
            }
        }
    }

    private static func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitServiceError.healthDataUnavailable)
                }
            }
        }
    }

    private static func endCollection(for builder: HKWorkoutBuilder, at endDate: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: endDate) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitServiceError.healthDataUnavailable)
                }
            }
        }
    }

    /// Launches one persistent anchored query for a sample type, resuming from (and persisting) its
    /// keychain anchor; both the initial and update handlers hop to the main actor before touching
    /// the caller's handler.
    private func startAnchoredQuery(for type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) {
        let savedAnchor = HealthKitAnchorKeychain.loadAnchor(for: type.identifier)
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: nil,
            anchor: savedAnchor,
            limit: HKObjectQueryNoLimit
        ) { query, samples, deletedObjects, newAnchor, error in
            guard error == nil else { return }
            let samplesCopy = samples ?? []
            let deletedCopy = deletedObjects ?? []
            Task { @MainActor in
                if let newAnchor { HealthKitAnchorKeychain.storeAnchor(newAnchor, for: type.identifier) }
                handler(query, samplesCopy, deletedCopy)
            }
        }
        query.updateHandler = { query, samples, deletedObjects, newAnchor, error in
            guard error == nil else { return }
            let samplesCopy = samples ?? []
            let deletedCopy = deletedObjects ?? []
            Task { @MainActor in
                if let newAnchor { HealthKitAnchorKeychain.storeAnchor(newAnchor, for: type.identifier) }
                handler(query, samplesCopy, deletedCopy)
            }
        }
        activeQueries.append(query)
        storeController.execute(query)
    }

    /// Deduplicated union of every registered observation type and every capability's share+read
    /// types — the full set whose background delivery and anchors the disable path must clear.
    private func observedObjectTypes() -> [HKObjectType] {
        var types: [HKObjectType] = observationRegistrations.values.map(\.type)
        for capability in HealthCapability.allCases {
            if let capabilityTypes = try? Self.types(for: capability) {
                types.append(contentsOf: capabilityTypes.share)
                types.append(contentsOf: capabilityTypes.read)
            }
        }
        var seen = Set<String>()
        return types.filter { type in
            seen.insert(type.identifier).inserted
        }
    }

    private func writeStatuses(for types: Set<HKSampleType>) -> [String: HKAuthorizationStatus] {
        Dictionary(uniqueKeysWithValues: types.map { type in
            (type.identifier, storeController.authorizationStatus(for: type))
        })
    }

    /// The authoritative share/read type sets for each capability — the single mapping every
    /// authorization request, status snapshot, and delete-all sweep is built from.
    nonisolated private static func types(for capability: HealthCapability) throws -> (share: Set<HKSampleType>, read: Set<HKObjectType>) {
        switch capability {
        case .bodyProfile:
            return (try bodyProfileWriteTypes(), try bodyProfileReadTypes())
        case .cycleTracking:
            let menstrualFlow = try categoryType(.menstrualFlow)
            let basalBodyTemperature = try quantityType(.basalBodyTemperature)
            let cervicalMucusQuality = try categoryType(.cervicalMucusQuality)
            let intermenstrualBleeding = try categoryType(.intermenstrualBleeding)
            let ovulationTestResult = try categoryType(.ovulationTestResult)
            let types: Set<HKSampleType> = [menstrualFlow, basalBodyTemperature, cervicalMucusQuality, intermenstrualBleeding, ovulationTestResult]
            return (types, Set(types))
        case .bodyContext:
            // Respiratory rate + sleeping wrist temperature feed the opt-in "body signals"
            // stress baseline (illness confounders) — read-only, foreground-pull only.
            let types: Set<HKObjectType> = [
                try quantityType(.heartRateVariabilitySDNN),
                try quantityType(.restingHeartRate),
                try quantityType(.respiratoryRate),
                try quantityType(.appleSleepingWristTemperature),
                try categoryType(.sleepAnalysis)
            ]
            return ([], types)
        case .activityContext:
            let types: Set<HKObjectType> = [
                try quantityType(.stepCount),
                try quantityType(.activeEnergyBurned),
                try quantityType(.appleExerciseTime)
            ]
            return ([], types)
        case .workoutLogging:
            let types = workoutWriteTypes()
            return (types, Set(types))
        case .mindfulness:
            let mindfulSession = try categoryType(.mindfulSession)
            return ([mindfulSession], [mindfulSession])
        case .intimateLogging:
            let sexualActivity = try categoryType(.sexualActivity)
            return ([sexualActivity], [sexualActivity])
        }
    }

    /// Builds the `HKWorkoutConfiguration` for a workout save: activity type via
    /// ``ActivityTypeCatalog``, plus indoor/outdoor and swimming-location hints for the variants
    /// HealthKit's activity type alone cannot express.
    public static func makeConfiguration(for workout: Workout) -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        switch workout.mode {
        case .strengthTraining:
            config.activityType = .traditionalStrengthTraining
        case .activity:
            config.activityType = workout.activityType.map(ActivityTypeCatalog.hkActivityType(for:)) ?? .other
            switch workout.activityType {
            case .indoorCycling:
                config.locationType = .indoor
            case .swimmingPool:
                config.locationType = .indoor
                config.swimmingLocationType = .pool
            case .swimmingOpenWater:
                config.locationType = .outdoor
                config.swimmingLocationType = .openWater
            default:
                config.locationType = .unknown
            }
        }
        return config
    }

    /// Builds the provenance metadata written onto every app-authored workout sample: the
    /// `fernlet.*` keys (id, name, mode, intensity, muscle groups, exercises, notes, effort,
    /// planned-workout link, activity type) plus the HealthKit sync identifier/version. This is the
    /// contract ``WorkoutHealthKitSync/parseFernletMetadata(_:)`` and the authored-sample delete
    /// predicates read back.
    public static func makeMetadata(for workout: Workout) -> [String: Any] {
        var metadata: [String: Any] = [
            "fernlet.workoutID": workout.id.uuidString,
            "fernlet.activityName": workout.name,
            "fernlet.mode": workout.mode.rawValue,
            "fernlet.intensity": workout.intensity.rawValue,
            HKMetadataKeySyncIdentifier: workout.id.uuidString,
            HKMetadataKeySyncVersion: NSNumber(value: 1)
        ]
        if !workout.muscleGroups.isEmpty {
            metadata["fernlet.muscleGroups"] = workout.muscleGroups.map(\.rawValue).sorted().joined(separator: ",")
        }
        if !workout.exercises.isEmpty {
            metadata["fernlet.exercises"] = workout.exercises
        }
        if !workout.notes.isEmpty {
            metadata["fernlet.notes"] = workout.notes
        }
        if let effort = workout.effort {
            metadata["fernlet.effort"] = NSNumber(value: effort)
        }
        if let plannedID = workout.plannedWorkoutID {
            metadata["fernlet.plannedWorkoutID"] = plannedID.uuidString
        }
        if let activityType = workout.activityType {
            metadata["fernlet.activityType"] = activityType.rawValue
            if activityType == .indoorCycling {
                metadata[HKMetadataKeyIndoorWorkout] = NSNumber(value: true)
            }
        }
        return metadata
    }

    /// Fallback duration in minutes when a workout was logged without one (30 for strength, the
    /// activity type's default otherwise).
    public static func defaultDuration(for workout: Workout) -> Int {
        switch workout.mode {
        case .strengthTraining:
            30
        case .activity:
            workout.activityType?.defaultDurationMinutes ?? 45
        }
    }

    /// Start of the workout import window: 30 days before the reference date. Shared by the
    /// one-time backfill and the observation predicate so both cover the same history.
    public static func workoutBackfillStartDate(referenceDate: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate
    }

    /// Whether the one-time workout backfill has not yet completed on this install.
    public static func shouldRunWorkoutBackfill(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: workoutBackfillCompletedKey)
    }

    /// Records the one-time workout backfill as done so it never reruns on this install.
    public static func markWorkoutBackfillCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: workoutBackfillCompletedKey)
    }

    private static let workoutBackfillCompletedKey = "fernlet.healthkit.workoutBackfillCompleted"

    private static func distanceTypeIdentifier(for activityType: WorkoutActivityType?) -> HKQuantityTypeIdentifier {
        switch activityType {
        case .cycling, .indoorCycling:
            .distanceCycling
        case .swimmingPool, .swimmingOpenWater:
            .distanceSwimming
        default:
            .distanceWalkingRunning
        }
    }

    private static func dayInterval(containing date: Date) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
        return DateInterval(start: start, end: end)
    }

    private static func roundedTenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// The 18:00–11:00 "sleep night" window a reference date belongs to: before 18:00 the date
    /// reads as "this morning's wake-up", so last night's window is used; from 18:00 the window
    /// rolls forward to tonight.
    private static func sleepNightInterval(containing date: Date) -> DateInterval {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        // Use the previous day's window unless the current time is at or after evening (18:00),
        // which indicates we want tonight's window rather than last night's.
        let eveningBoundary = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: dayStart) ?? dayStart.addingTimeInterval(18 * 3600)
        let sleepDayStart = date < eveningBoundary
            ? calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
            : dayStart
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: sleepDayStart) ?? sleepDayStart.addingTimeInterval(18 * 3600)
        let endDay = calendar.date(byAdding: .day, value: 1, to: sleepDayStart) ?? sleepDayStart.addingTimeInterval(24 * 3600)
        let end = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: endDay) ?? endDay.addingTimeInterval(11 * 3600)
        return DateInterval(start: start, end: end)
    }

    /// Total seconds covered by the union of the intervals — overlaps merge, so simultaneous
    /// samples from multiple sources (watch + phone) never double-count.
    private static func mergedDuration(for intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged.reduce(0) { $0 + $1.duration }
    }

    nonisolated private static func workoutWriteTypes() -> Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming)
        ]
    }

    nonisolated private static func bodyProfileReadTypes() throws -> Set<HKObjectType> {
        [
            try characteristicType(.dateOfBirth),
            try characteristicType(.biologicalSex),
            try quantityType(.height),
            try quantityType(.bodyMass)
        ]
    }

    nonisolated private static func bodyProfileWriteTypes() throws -> Set<HKSampleType> {
        [
            try quantityType(.height),
            try quantityType(.bodyMass)
        ]
    }

    private static func age(from components: DateComponents?) -> Int? {
        guard let components,
              let birthDate = Calendar.current.date(from: components) else { return nil }
        let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
        return age.map { min(max($0, 0), 130) }
    }

    private static func biologicalSex(from healthSex: HKBiologicalSex?) -> BiologicalSex? {
        switch healthSex {
        case .female: .female
        case .male: .male
        default: nil
        }
    }

    nonisolated private static func characteristicType(_ identifier: HKCharacteristicTypeIdentifier) throws -> HKCharacteristicType {
        guard let type = HKCharacteristicType.characteristicType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }

    /// Resolves a quantity-type identifier, throwing ``HealthKitServiceError/missingHealthType(_:)``
    /// instead of returning an optional.
    nonisolated public static func quantityType(_ identifier: HKQuantityTypeIdentifier) throws -> HKQuantityType {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }

    /// Resolves a category-type identifier, throwing ``HealthKitServiceError/missingHealthType(_:)``
    /// instead of returning an optional.
    nonisolated public static func categoryType(_ identifier: HKCategoryTypeIdentifier) throws -> HKCategoryType {
        guard let type = HKCategoryType.categoryType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }
}

/// Observable view model behind the Health authorization UI (Settings sheet, period-tracker and
/// log-period sheets): drives per-capability permission requests, body-profile import/sync, and
/// per-capability context refreshes, publishing progress and user-facing status text.
///
/// A thin, stateless-by-intent layer over ``HealthKitServicing`` — it holds no health data, only
/// the latest ``AuthorizationSnapshot``, an `isRequesting` flag, and a `statusMessage` the views
/// render verbatim. Which capabilities the user has EVER requested is remembered in `UserDefaults`
/// (HealthKit itself never reveals whether a prompt was shown), so the UI can distinguish
/// "never asked" from "asked and denied". Errors are absorbed into `statusMessage` rather than
/// thrown — every flow degrades to "manual entries remain available" messaging. `@MainActor`
/// `@Observable`; the injected service is `@ObservationIgnored`.
@MainActor
@Observable
public final class HealthKitAuthorizationViewModel {
    /// Latest availability + write-status snapshot; refreshed after every request/flow.
    public private(set) var snapshot: AuthorizationSnapshot
    /// User-facing outcome text for the last action, rendered verbatim by the settings UI.
    public private(set) var statusMessage: String = ""
    /// True while an authorization or Health fetch is in flight (drives progress UI).
    public private(set) var isRequesting = false
    /// Capabilities the user has ever been prompted for, persisted in `UserDefaults`.
    private(set) var requestedCapabilities: Set<HealthCapability>

    @ObservationIgnored
    private let service: HealthKitServicing

    public init(service: HealthKitServicing? = nil) {
        let resolvedService = service ?? HealthKitService()
        self.service = resolvedService
        self.snapshot = resolvedService.currentAuthorizationSnapshot()
        self.requestedCapabilities = Self.loadRequestedCapabilities()
        if !snapshot.isAvailable {
            statusMessage = "Health data is not available on this device."
        }
    }

    /// Re-reads the authorization snapshot without prompting (e.g. on scene re-activation).
    public func refresh() {
        snapshot = service.currentAuthorizationSnapshot()
    }

    /// Whether this capability's system prompt has ever been triggered from Fernlet.
    public func hasRequested(_ capability: HealthCapability) -> Bool {
        requestedCapabilities.contains(capability)
    }

    /// Runs the system authorization prompt for one capability, then refreshes the snapshot and
    /// reports the outcome in `statusMessage`.
    public func request(_ capability: HealthCapability) async {
        isRequesting = true
        statusMessage = ""
        defer { isRequesting = false }

        do {
            _ = try await service.requestAuthorization(for: capability)
            markRequested(capability)
            snapshot = service.currentAuthorizationSnapshot()
            statusMessage = "Updated Health access for \(capability.title.lowercased())."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Sets `statusMessage` to the manual-revocation walkthrough — iOS gives apps no API to revoke
    /// Health permissions themselves.
    public func showRevocationInstructions(for capability: HealthCapability) {
        statusMessage = "To revoke \(capability.title.lowercased()) access, open Settings > Privacy & Security > Health > Fernlet. iOS does not allow apps to revoke Health permissions directly."
    }

    /// Sets `statusMessage` to the 16+ age-gate explanation shown instead of the intimate-logging
    /// authorization flow when the user is below the gate.
    public func showIntimateLoggingAgeWallMessage() {
        statusMessage = "Intimate logging is available at 16 and older. Fernlet checks your age range with Apple — see Settings › Intimacy."
    }

    /// First-time body-profile import: prompts for authorization, then overlays Health's fields
    /// onto the profile. Returns nil when Health supplied nothing (message explains the fallback).
    public func importBodyProfile(current profile: UserNutritionProfile) async -> UserNutritionProfile? {
        await loadBodyProfile(current: profile, requestsAuthorization: true)
    }

    /// Re-pulls the body profile without prompting (for already-authorized refreshes).
    public func updateBodyProfile(current profile: UserNutritionProfile) async -> UserNutritionProfile? {
        await loadBodyProfile(current: profile, requestsAuthorization: false)
    }

    /// Writes the profile's height/weight back to Health, but only when both types show write
    /// authorization — otherwise silently no-ops rather than prompting.
    public func syncBodyProfileMeasurements(_ profile: UserNutritionProfile) async {
        guard snapshot.status(for: HKQuantityTypeIdentifier.height.rawValue) == .sharingAuthorized,
              snapshot.status(for: HKQuantityTypeIdentifier.bodyMass.rawValue) == .sharingAuthorized else { return }
        do {
            try await service.saveBodyProfileMeasurements(profile)
            snapshot = service.currentAuthorizationSnapshot()
        } catch {
            statusMessage = "Could not update height or weight in Health. \(error.localizedDescription)"
        }
    }

    /// Fetches today's `HealthDailyContext` restricted to one capability, for the settings "update
    /// now" affordance. Returns nil (with a fallback message) on any failure.
    public func updateHealthContext(for capability: HealthCapability) async -> HealthDailyContext? {
        isRequesting = true
        statusMessage = ""
        defer { isRequesting = false }

        do {
            let context = try await service.loadDailyHealthContext(referenceDate: .now, capabilities: [capability])
            markRequested(capability)
            statusMessage = "Updated \(capability.title.lowercased()) data from Health."
            return context
        } catch {
            statusMessage = "\(capability.title) update was unavailable. Manual app entries remain available. \(error.localizedDescription)"
            return nil
        }
    }

    private func loadBodyProfile(current profile: UserNutritionProfile, requestsAuthorization: Bool) async -> UserNutritionProfile? {
        isRequesting = true
        statusMessage = ""
        defer { isRequesting = false }

        do {
            let healthProfile = requestsAuthorization
                ? try await service.requestBodyProfileAuthorization()
                : try await service.loadBodyProfile()
            markRequested(.bodyProfile)
            snapshot = service.currentAuthorizationSnapshot()
            guard healthProfile.appliedFieldCount > 0 else {
                statusMessage = "No body profile data was available from Health. Manual settings will be used."
                return nil
            }
            if healthProfile.missingFieldNames.isEmpty {
                statusMessage = requestsAuthorization ? "Imported body profile from Health." : "Updated body profile from Health."
            } else {
                statusMessage = "Updated \(healthProfile.appliedFieldCount) fields from Health. Manual settings remain for \(healthProfile.missingFieldNames.joined(separator: ", "))."
            }
            return healthProfile.applying(to: profile)
        } catch {
            statusMessage = "Health profile update was unavailable. Manual settings will be used. \(error.localizedDescription)"
            return nil
        }
    }

    private func markRequested(_ capability: HealthCapability) {
        requestedCapabilities.insert(capability)
        Self.saveRequestedCapabilities(requestedCapabilities)
    }

    private static func loadRequestedCapabilities() -> Set<HealthCapability> {
        let rawValues = UserDefaults.standard.stringArray(forKey: requestedCapabilitiesKey) ?? []
        return Set(rawValues.compactMap(HealthCapability.init(rawValue:)))
    }

    private static func saveRequestedCapabilities(_ capabilities: Set<HealthCapability>) {
        UserDefaults.standard.set(capabilities.map(\.rawValue).sorted(), forKey: requestedCapabilitiesKey)
    }

    private static let requestedCapabilitiesKey = "fernlet.healthkit.requested-capabilities"
}

extension HKAuthorizationStatus {
    /// Short user-facing label for a write status ("Not requested" / "Write denied" /
    /// "Write allowed"), shown on the settings capability rows.
    public var fernletLabel: String {
        switch self {
        case .notDetermined: "Not requested"
        case .sharingDenied: "Write denied"
        case .sharingAuthorized: "Write allowed"
        @unknown default: "Unknown"
        }
    }
}

/// Cycle-event read/write conformance for the narrow `PeriodHealthKitServicing` seam owned by
/// `PeriodTrackerStore` (in the PrivateHealthStore module). The conformance lives here — beside
/// ``HealthKitService`` — because it reaches into the service's internals (`save`, `healthStore`,
/// `categoryType`/`quantityType`); it is the reason this gateway target depends on
/// PrivateHealthStore, a wall-legal edge (only AIProviders/CloudKitSync are barred from the
/// sealed stores).
extension HealthKitService: PeriodHealthKitServicing {
    /// Writes one logged cycle event as its constituent Health samples (flow, BBT, mucus,
    /// ovulation test, spotting — whichever fields are present), each stamped with the sealed
    /// store's external UUID so the encrypted narrative and the clinical samples stay correlated.
    /// Gated on device availability only; audited on success.
    public func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample] {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        let samples = try Self.periodSamples(for: event, externalUUID: externalUUID)
        if !samples.isEmpty {
            try await save(samples)
        }
        FernletAuditLog.log("hk.write.saved", context: ["type": "cycle", "externalUUID": externalUUID.uuidString])
        return samples
    }

    /// Fetches every cycle-related sample (all five period sample types, whatever their source
    /// app) in the range, sorted by start date — the raw feed `PeriodTrackerStore` folds into its
    /// sealed cycle entries.
    public func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample] {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        let predicate = HKQuery.predicateForSamples(withStart: dateRange.start, end: dateRange.end, options: .strictStartDate)
        var allSamples: [HKSample] = []
        for sampleType in try Self.periodSampleTypes() {
            allSamples += try await samples(for: sampleType, predicate: predicate)
        }
        return allSamples.sorted { $0.startDate < $1.startDate }
    }

    /// Pure sample-construction for one cycle event: emits a sample per populated field, all
    /// sharing the external UUID and the `HKMetadataKeyMenstrualCycleStart` flag (forced false on
    /// the intermenstrual-bleeding sample — spotting never starts a cycle).
    nonisolated public static func periodSamples(for event: UserLoggedCycleEvent, externalUUID: UUID) throws -> [HKSample] {
        let start = event.date
        let end = max(event.date.addingTimeInterval(60), event.date)
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: externalUUID.uuidString,
            HKMetadataKeyMenstrualCycleStart: event.isCycleStart
        ]
        var samples: [HKSample] = []

        if let flowLevel = event.flowLevel {
            samples.append(HKCategorySample(type: try categoryType(.menstrualFlow), value: flowLevel.hkValue, start: start, end: end, metadata: metadata))
        }

        if let temperature = event.basalBodyTemperature {
            let unit: HKUnit = event.temperatureUnit == .fahrenheit ? .degreeFahrenheit() : .degreeCelsius()
            samples.append(HKQuantitySample(type: try quantityType(.basalBodyTemperature), quantity: HKQuantity(unit: unit, doubleValue: temperature), start: start, end: end, metadata: metadata))
        }
        if let mucus = event.cervicalMucusQuality {
            samples.append(HKCategorySample(type: try categoryType(.cervicalMucusQuality), value: mucus.hkValue, start: start, end: end, metadata: metadata))
        }
        if let ovulation = event.ovulationTestResult {
            samples.append(HKCategorySample(type: try categoryType(.ovulationTestResult), value: ovulation.hkValue, start: start, end: end, metadata: metadata))
        }
        if event.hasIntermenstrualBleeding {
            metadata[HKMetadataKeyMenstrualCycleStart] = false
            samples.append(HKCategorySample(type: try categoryType(.intermenstrualBleeding), value: HKCategoryValue.notApplicable.rawValue, start: start, end: end, metadata: metadata))
        }
        return samples
    }

    /// The five cycle-tracking sample types the period seam reads and writes.
    nonisolated static func periodSampleTypes() throws -> [HKSampleType] {
        [
            try categoryType(.menstrualFlow),
            try quantityType(.basalBodyTemperature),
            try categoryType(.cervicalMucusQuality),
            try categoryType(.ovulationTestResult),
            try categoryType(.intermenstrualBleeding)
        ]
    }

    /// One-shot unsorted sample fetch for any sample type (period seam helper).
    private func samples(for type: HKSampleType, predicate: NSPredicate?) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }
}
