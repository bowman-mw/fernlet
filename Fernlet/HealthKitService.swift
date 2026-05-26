import Combine
import CoreData
import Foundation
import HealthKit
import Security
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
protocol HealthKitServicing {
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

enum HealthCapability: String, CaseIterable, Identifiable {
    case bodyProfile
    case cycleTracking
    case bodyContext
    case workoutLogging
    case activityContext
    case mindfulness
    case intimateLogging

    var id: String { rawValue }

    var title: String {
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

    var summary: String {
        switch self {
        case .bodyProfile:
            "Read age, biological sex, height, and weight from Apple Health. Fernlet can write height and weight changes back when Health access allows it."
        case .cycleTracking:
            "Read and write cycle observations like menstrual flow, basal body temperature, cervical mucus, intermenstrual bleeding, and ovulation test results."
        case .bodyContext:
            "Read sleep, resting heart rate, and heart rate variability for recovery-aware companion context."
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

struct AuthorizationOutcome {
    let writeStatuses: [String: HKAuthorizationStatus]
}

struct HealthBodyProfile {
    var age: Int?
    var sex: BiologicalSex?
    var heightInches: Double?
    var weightPounds: Double?

    var appliedFieldCount: Int {
        [age != nil, sex != nil, heightInches != nil, weightPounds != nil].filter { $0 }.count
    }

    var missingFieldNames: [String] {
        var names: [String] = []
        if age == nil { names.append("age") }
        if sex == nil { names.append("sex") }
        if heightInches == nil { names.append("height") }
        if weightPounds == nil { names.append("weight") }
        return names
    }

    func applying(to profile: UserNutritionProfile) -> UserNutritionProfile {
        var updated = profile
        if let age { updated.age = min(max(age, 13), 100) }
        if let sex { updated.sex = sex }
        if let heightInches { updated.heightInches = min(max(heightInches, 48), 84) }
        if let weightPounds { updated.weightPounds = min(max(weightPounds, 70), 500) }
        return updated
    }
}

struct AuthorizationSnapshot {
    let isAvailable: Bool
    let writeStatuses: [String: HKAuthorizationStatus]

    func status(for identifier: String) -> HKAuthorizationStatus? {
        writeStatuses[identifier]
    }
}

struct HealthAuthorizationPresentation {
    static func writeTypeIdentifiers(for capability: HealthCapability) -> [String] {
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

enum HealthKitServiceError: LocalizedError {
    case healthDataUnavailable
    case missingHealthType(String)

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "Health data is not available on this device."
        case .missingHealthType(let identifier):
            "Fernlet could not create the HealthKit type for \(identifier)."
        }
    }
}

protocol HealthKitStoreControlling: AnyObject {
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

protocol HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws
}

struct CoreDataHealthKitCacheCleaner: HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws {
        let controller = PersistenceController.shared
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        let records = try context.fetch(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        for record in records {
            guard let payload = record.value(forKey: "payloadData") as? Data else { continue }
            var database = try decoder.decode(LocalFernletDatabase.self, from: payload)
            var changed = false
            for key in database.days.keys {
                guard var day = database.days[key], let context = day.healthContext else { continue }
                if let healthSleepHours = context.body?.sleepHours,
                   let sleep = day.sleep,
                   sleep.note.isEmpty,
                   sleep.hours == healthSleepHours {
                    day.sleep = nil
                }
                day.healthContext = nil
                database.days[key] = day
                changed = true
            }
            if changed {
                let todayKey = database.days.keys.sorted().last ?? FernletDate.dayKey(for: .now)
                database.rebuildDerivedTables(todayKey: todayKey)
                record.setValue(try encoder.encode(database), forKey: "payloadData")
                record.setValue(Date(), forKey: "updatedAt")
            }
        }
        if context.hasChanges {
            try context.save()
        }
    }
}

struct HealthKitAnchorKeychain {
    static let service = "com.fernlet.healthkit-anchors"
    static let accountPrefix = "healthKitAnchors."
    static let workoutAnchorKey = "fernlet.healthkit.workoutAnchor"

    static func account(for identifier: String) -> String {
        accountPrefix + identifier
    }

    static func deleteAll(for identifiers: [String]) {
        for identifier in identifiers {
            delete(identifier: identifier)
        }
    }

    static func delete(identifier: String) {
        delete(account: account(for: identifier))
    }

    static func deleteWorkoutAnchor() {
        delete(account: workoutAnchorKey)
    }

    static func loadWorkoutAnchor() -> HKQueryAnchor? {
        load(account: workoutAnchorKey).flatMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
    }

    static func storeWorkoutAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        store(data, account: workoutAnchorKey)
    }

    static func store(_ data: Data, identifier: String) {
        store(data, account: account(for: identifier))
    }

    private static func load(account: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func store(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        delete(account: account)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class HealthKitService: HealthKitServicing {
    let healthStore: HKHealthStore
    private let storeController: HealthKitStoreControlling
    private let cacheCleaner: HealthKitCacheClearing
    private let preferencesStore: StoragePreferencesStore
    private var workoutObservationQuery: HKAnchoredObjectQuery?
    private var activeQueries: [HKQuery] = []
    private var observationRegistrations: [String: (type: HKSampleType, handler: (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void)] = [:]

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        storeController: HealthKitStoreControlling? = nil,
        cacheCleaner: HealthKitCacheClearing? = nil,
        preferencesStore: StoragePreferencesStore? = nil
    ) {
        self.healthStore = healthStore
        self.storeController = storeController ?? SystemHealthKitStoreController(healthStore: healthStore)
        self.cacheCleaner = cacheCleaner ?? CoreDataHealthKitCacheCleaner()
        self.preferencesStore = preferencesStore ?? StoragePreferencesStore()
    }

    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        let types = try Self.types(for: capability)
        try await storeController.requestAuthorization(toShare: types.share, read: types.read)
        return AuthorizationOutcome(writeStatuses: writeStatuses(for: types.share))
    }

    func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        let shareTypes = HealthCapability.allCases.flatMap { capability in
            (try? Self.types(for: capability).share) ?? []
        }
        return AuthorizationSnapshot(
            isAvailable: isIntegrationEnabled,
            writeStatuses: writeStatuses(for: Set(shareTypes))
        )
    }

    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        observationRegistrations[type.identifier] = (type, handler)
        startAnchoredQuery(for: type, handler: handler)
    }

    func startObservingWorkouts(handler: @escaping ([HKWorkout]) -> Void) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        stopObservingWorkouts()

        let workoutType = HKObjectType.workoutType()
        let anchor = HealthKitAnchorKeychain.loadWorkoutAnchor()
        let query = HKAnchoredObjectQuery(
            type: workoutType,
            predicate: nil,
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

    func stopObservingWorkouts() {
        guard let query = workoutObservationQuery else { return }
        storeController.stop(query)
        activeQueries.removeAll { $0 === query }
        workoutObservationQuery = nil
    }

    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] {
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

    func backfillWorkoutsFromHealth(referenceDate: Date = .now) async throws -> [HKWorkout] {
        try await recentWorkouts(since: Self.workoutBackfillStartDate(referenceDate: referenceDate))
    }

    func save(_ samples: [HKObject]) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        try await storeController.save(samples)
    }

    func delete(_ samples: [HKSample]) async throws {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        try await storeController.delete(samples)
    }

    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] {
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

    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        try await storeController.requestAuthorization(toShare: try Self.bodyProfileWriteTypes(), read: try Self.bodyProfileReadTypes())
        return try await loadBodyProfile()
    }

    func loadBodyProfile() async throws -> HealthBodyProfile {
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

    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws {
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

    func saveWorkout(_ workout: Workout) async throws -> UUID {
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

    func loadLastNightSleepHours(referenceDate: Date = Date()) async throws -> Double? {
        guard isIntegrationEnabled else { throw HealthKitServiceError.healthDataUnavailable }
        return try await sleepHours(referenceDate: referenceDate)
    }

    func loadDailyHealthContext(referenceDate: Date = Date(), capabilities: Set<HealthCapability>? = nil) async throws -> HealthDailyContext {
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
                heartRateVariabilityMS: try await latestQuantityValue(for: try Self.quantityType(.heartRateVariabilitySDNN), unit: HKUnit.secondUnit(with: .milli)).map(Self.roundedTenth)
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

    func disableIntegration() async throws {
        FernletAuditLog.log("healthkit.disable.attempt")
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

    func enableIntegration() async throws {
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

    func openHealthPrivacySettings() async {
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
        isHealthDataAvailable() && preferencesStore.preferences.healthKitMasterEnabled
    }

    nonisolated private static func deliver(workoutSamples samples: [HKSample]?, anchor: HKQueryAnchor?, handler: @escaping ([HKWorkout]) -> Void) {
        let workouts = samples?.compactMap { $0 as? HKWorkout } ?? []
        Task { @MainActor in
            if let anchor {
                HealthKitAnchorKeychain.storeWorkoutAnchor(anchor)
            }
            guard !workouts.isEmpty else { return }
            handler(workouts)
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
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: nil,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { query, samples, deletedObjects, _, error in
            guard error == nil else { return }
            handler(query, samples ?? [], deletedObjects ?? [])
        }
        query.updateHandler = { query, samples, deletedObjects, _, error in
            guard error == nil else { return }
            handler(query, samples ?? [], deletedObjects ?? [])
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
            let types: Set<HKObjectType> = [
                try quantityType(.heartRateVariabilitySDNN),
                try quantityType(.restingHeartRate),
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

    internal static func makeConfiguration(for workout: Workout) -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        switch workout.mode {
        case .strengthTraining:
            config.activityType = .traditionalStrengthTraining
        case .activity:
            config.activityType = workout.activityType.map(ActivityTypeCatalog.hkActivityType(for:)) ?? .other
        }
        config.locationType = .unknown
        return config
    }

    internal static func makeMetadata(for workout: Workout) -> [String: Any] {
        var metadata: [String: Any] = [
            "fernlet.workoutID": workout.id.uuidString,
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
        return metadata
    }

    internal static func defaultDuration(for workout: Workout) -> Int {
        switch workout.mode {
        case .strengthTraining:
            30
        case .activity:
            workout.activityType?.defaultDurationMinutes ?? 45
        }
    }

    static func workoutBackfillStartDate(referenceDate: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate
    }

    static func shouldRunWorkoutBackfill(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: workoutBackfillCompletedKey)
    }

    static func markWorkoutBackfillCompleted(defaults: UserDefaults = .standard) {
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
        let morningBoundary = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: dayStart) ?? dayStart.addingTimeInterval(11 * 3600)
        let sleepDayStart = date < morningBoundary
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

    nonisolated static func quantityType(_ identifier: HKQuantityTypeIdentifier) throws -> HKQuantityType {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }

    nonisolated static func categoryType(_ identifier: HKCategoryTypeIdentifier) throws -> HKCategoryType {
        guard let type = HKCategoryType.categoryType(forIdentifier: identifier) else {
            throw HealthKitServiceError.missingHealthType(identifier.rawValue)
        }
        return type
    }
}

@MainActor
final class HealthKitAuthorizationViewModel: ObservableObject {
    @Published private(set) var snapshot: AuthorizationSnapshot
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isRequesting = false
    @Published private(set) var requestedCapabilities: Set<HealthCapability>

    private let service: HealthKitServicing

    init(service: HealthKitServicing? = nil) {
        let resolvedService = service ?? HealthKitService()
        self.service = resolvedService
        self.snapshot = resolvedService.currentAuthorizationSnapshot()
        self.requestedCapabilities = Self.loadRequestedCapabilities()
        if !snapshot.isAvailable {
            statusMessage = "Health data is not available on this device."
        }
    }

    func refresh() {
        snapshot = service.currentAuthorizationSnapshot()
    }

    func hasRequested(_ capability: HealthCapability) -> Bool {
        requestedCapabilities.contains(capability)
    }

    func request(_ capability: HealthCapability) async {
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

    func showRevocationInstructions(for capability: HealthCapability) {
        statusMessage = "To revoke \(capability.title.lowercased()) access, open Settings > Privacy & Security > Health > Fernlet. iOS does not allow apps to revoke Health permissions directly."
    }

    func showIntimateLoggingAgeWallMessage() {
        statusMessage = "Intimate logging is available only when the manual body profile age is 18 or older."
    }

    func importBodyProfile(current profile: UserNutritionProfile) async -> UserNutritionProfile? {
        await loadBodyProfile(current: profile, requestsAuthorization: true)
    }

    func updateBodyProfile(current profile: UserNutritionProfile) async -> UserNutritionProfile? {
        await loadBodyProfile(current: profile, requestsAuthorization: false)
    }

    func syncBodyProfileMeasurements(_ profile: UserNutritionProfile) async {
        guard snapshot.status(for: HKQuantityTypeIdentifier.height.rawValue) == .sharingAuthorized,
              snapshot.status(for: HKQuantityTypeIdentifier.bodyMass.rawValue) == .sharingAuthorized else { return }
        do {
            try await service.saveBodyProfileMeasurements(profile)
            snapshot = service.currentAuthorizationSnapshot()
        } catch {
            statusMessage = "Could not update height or weight in Health. \(error.localizedDescription)"
        }
    }

    func updateHealthContext(for capability: HealthCapability) async -> HealthDailyContext? {
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
    var fernletLabel: String {
        switch self {
        case .notDetermined: "Not requested"
        case .sharingDenied: "Write denied"
        case .sharingAuthorized: "Write allowed"
        @unknown default: "Unknown"
        }
    }
}
