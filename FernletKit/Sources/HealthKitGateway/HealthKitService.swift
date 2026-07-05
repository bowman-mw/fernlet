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

@MainActor
public protocol HealthKitServicing {
    func isHealthDataAvailable() -> Bool
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws
    func startObservingWorkouts(handler: @escaping ([HKWorkout]) -> Void) async throws
    func stopObservingWorkouts()
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout]
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout]
    func save(_ samples: [HKObject]) async throws
    func delete(_ samples: [HKSample]) async throws
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics]
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile
    func loadBodyProfile() async throws -> HealthBodyProfile
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws
    func saveWorkout(_ workout: Workout) async throws -> UUID
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double?
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext
    func disableIntegration() async throws
    func enableIntegration() async throws
    func openHealthPrivacySettings() async
}

/// One calendar day of stress-relevant metrics from `stressMetricDays(daysBack:referenceDate:)`.
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

public enum HealthCapability: String, CaseIterable, Identifiable {
    case bodyProfile
    case cycleTracking
    case bodyContext
    case workoutLogging
    case activityContext
    case mindfulness
    case intimateLogging

    public var id: String { rawValue }

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

public struct AuthorizationOutcome {
    public let writeStatuses: [String: HKAuthorizationStatus]

    public init(writeStatuses: [String: HKAuthorizationStatus]) {
        self.writeStatuses = writeStatuses
    }
}

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

    public var appliedFieldCount: Int {
        [age != nil, sex != nil, heightInches != nil, weightPounds != nil].filter { $0 }.count
    }

    public var missingFieldNames: [String] {
        var names: [String] = []
        if age == nil { names.append("age") }
        if sex == nil { names.append("sex") }
        if heightInches == nil { names.append("height") }
        if weightPounds == nil { names.append("weight") }
        return names
    }

    public func applying(to profile: UserNutritionProfile) -> UserNutritionProfile {
        var updated = profile
        if let age { updated.age = min(max(age, 13), 100) }
        if let sex { updated.sex = sex }
        if let heightInches { updated.heightInches = min(max(heightInches, 48), 84) }
        if let weightPounds { updated.weightPounds = min(max(weightPounds, 70), 500) }
        return updated
    }
}

public struct AuthorizationSnapshot {
    public let isAvailable: Bool
    public let writeStatuses: [String: HKAuthorizationStatus]

    public init(isAvailable: Bool, writeStatuses: [String: HKAuthorizationStatus]) {
        self.isAvailable = isAvailable
        self.writeStatuses = writeStatuses
    }

    public func status(for identifier: String) -> HKAuthorizationStatus? {
        writeStatuses[identifier]
    }
}

public struct HealthAuthorizationPresentation {
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

public enum HealthKitServiceError: LocalizedError {
    case healthDataUnavailable
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

public protocol HealthKitStoreControlling: AnyObject {
    func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    func execute(_ query: HKQuery)
    func stop(_ query: HKQuery)
    func save(_ samples: [HKObject]) async throws
    func delete(_ samples: [HKSample]) async throws
    func disableBackgroundDelivery(for type: HKObjectType) async throws
}

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

    func disableBackgroundDelivery(for type: HKObjectType) async throws {
        try await healthStore.disableBackgroundDelivery(for: type)
    }
}

public protocol HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws
}

/// Explicit "clearing is genuinely not needed" cleaner, for the rare injection where a caller
/// wants `disableIntegration()` to succeed without purging a cache (e.g. a test exercising the
/// non-cache teardown). It is **no longer** the implicit default: a `HealthKitService` with no
/// clearer installed now fails closed (`HealthKitServiceError.cacheClearerUnavailable`) so an
/// opt-out can never silently leave cached clinical data behind. The real
/// `CoreDataHealthKitCacheCleaner` lives app-side (it needs CloudKitSync's PersistenceController +
/// LocalPersistence's LocalFernletDatabase) and is installed via
/// `HealthKitService.defaultCacheClearer` at app launch.
struct NoopHealthKitCacheClearer: HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws {}
}

public struct HealthKitAnchorKeychain {
    public static let service = "com.fernlet.healthkit-anchors"
    public static let accountPrefix = "healthKitAnchors."
    public static let workoutAnchorKey = "fernlet.healthkit.workoutAnchor"

    public static func account(for identifier: String) -> String {
        accountPrefix + identifier
    }

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

    public let healthStore: HKHealthStore
    private let storeController: HealthKitStoreControlling
    /// Optional: `nil` means "no clearer installed" → `disableIntegration()` throws rather than
    /// flipping the master switch off while leaving cached clinical data behind (fail-closed).
    private let cacheCleaner: HealthKitCacheClearing?
    private let preferencesStore: StoragePreferencesStore
    private var workoutObservationQuery: HKAnchoredObjectQuery?
    private var activeQueries: [HKQuery] = []
    private var observationRegistrations: [String: (type: HKSampleType, handler: (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void)] = [:]

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

    public func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let types = try Self.types(for: capability)
        try await storeController.requestAuthorization(toShare: types.share, read: types.read)
        return AuthorizationOutcome(writeStatuses: writeStatuses(for: types.share))
    }

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

    public func startObservingWorkouts(handler: @escaping ([HKWorkout]) -> Void) async throws {
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
        ) { _, samples, _, newAnchor, error in
            guard error == nil else { return }
            Self.deliver(workoutSamples: samples, anchor: newAnchor, handler: handler)
        }
        query.updateHandler = { _, samples, _, newAnchor, error in
            guard error == nil else { return }
            Self.deliver(workoutSamples: samples, anchor: newAnchor, handler: handler)
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

    private var isIntegrationEnabled: Bool {
        // Read the live keychain value rather than this instance's cached `preferences`.
        // Multiple HealthKitService instances exist (FernletStore, Privacy settings, etc.),
        // each with its own StoragePreferencesStore; the master toggle is flipped on a
        // different instance, so a cached read would keep reporting the old state until
        // relaunch — gating reads/writes/observation incorrectly.
        isHealthDataAvailable()
            && StoragePreferencesStore.currentPreferences(service: preferencesStore.keychainService).healthKitMasterEnabled
    }

    nonisolated private static func deliver(workoutSamples samples: [HKSample]?, anchor: HKQueryAnchor?, handler: @escaping ([HKWorkout]) -> Void) {
        let workouts = samples?.compactMap { $0 as? HKWorkout } ?? []
        Task { @MainActor in
            guard !workouts.isEmpty else {
                if let anchor { HealthKitAnchorKeychain.storeWorkoutAnchor(anchor) }
                return
            }
            handler(workouts)
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

    public static func defaultDuration(for workout: Workout) -> Int {
        switch workout.mode {
        case .strengthTraining:
            30
        case .activity:
            workout.activityType?.defaultDurationMinutes ?? 45
        }
    }

    public static func workoutBackfillStartDate(referenceDate: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate
    }

    public static func shouldRunWorkoutBackfill(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: workoutBackfillCompletedKey)
    }

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

    nonisolated public static func quantityType(_ identifier: HKQuantityTypeIdentifier) throws -> HKQuantityType {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }

    nonisolated public static func categoryType(_ identifier: HKCategoryTypeIdentifier) throws -> HKCategoryType {
        guard let type = HKCategoryType.categoryType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }
}

@MainActor
@Observable
public final class HealthKitAuthorizationViewModel {
    public private(set) var snapshot: AuthorizationSnapshot
    public private(set) var statusMessage: String = ""
    public private(set) var isRequesting = false
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

    public func refresh() {
        snapshot = service.currentAuthorizationSnapshot()
    }

    public func hasRequested(_ capability: HealthCapability) -> Bool {
        requestedCapabilities.contains(capability)
    }

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

    public func showRevocationInstructions(for capability: HealthCapability) {
        statusMessage = "To revoke \(capability.title.lowercased()) access, open Settings > Privacy & Security > Health > Fernlet. iOS does not allow apps to revoke Health permissions directly."
    }

    public func showIntimateLoggingAgeWallMessage() {
        statusMessage = "Intimate logging is available only when the manual body profile age is 18 or older."
    }

    public func importBodyProfile(current profile: UserNutritionProfile) async -> UserNutritionProfile? {
        await loadBodyProfile(current: profile, requestsAuthorization: true)
    }

    public func updateBodyProfile(current profile: UserNutritionProfile) async -> UserNutritionProfile? {
        await loadBodyProfile(current: profile, requestsAuthorization: false)
    }

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
    public var fernletLabel: String {
        switch self {
        case .notDetermined: "Not requested"
        case .sharingDenied: "Write denied"
        case .sharingAuthorized: "Write allowed"
        @unknown default: "Unknown"
        }
    }
}

// Cycle-event read/write conformance for the narrow `PeriodHealthKitServicing` seam used by
// `PeriodTrackerStore` (in the PrivateHealthStore module). This conformance lives app-side because
// it reaches into `HealthKitService` internals (`save`, `healthStore`, `categoryType`/`quantityType`).
extension HealthKitService: PeriodHealthKitServicing {
    public func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample] {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        let samples = try Self.periodSamples(for: event, externalUUID: externalUUID)
        if !samples.isEmpty {
            try await save(samples)
        }
        FernletAuditLog.log("hk.write.saved", context: ["type": "cycle", "externalUUID": externalUUID.uuidString])
        return samples
    }

    public func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample] {
        guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }
        let predicate = HKQuery.predicateForSamples(withStart: dateRange.start, end: dateRange.end, options: .strictStartDate)
        var allSamples: [HKSample] = []
        for sampleType in try Self.periodSampleTypes() {
            allSamples += try await samples(for: sampleType, predicate: predicate)
        }
        return allSamples.sorted { $0.startDate < $1.startDate }
    }

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

    nonisolated static func periodSampleTypes() throws -> [HKSampleType] {
        [
            try categoryType(.menstrualFlow),
            try quantityType(.basalBodyTemperature),
            try categoryType(.cervicalMucusQuality),
            try categoryType(.ovulationTestResult),
            try categoryType(.intermenstrualBleeding)
        ]
    }

    private func samples(for type: HKSampleType, predicate: NSPredicate?) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }
}
