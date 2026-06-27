import Combine
import CoreData
import CryptoKit
import Foundation
import HealthKit
import LocalAuthentication
import Testing
@testable import Fernlet

@MainActor
struct PeriodTrackerTests {
    @Test func narrativeRepositoryRoundTripsWithFixedKey() throws {
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let narrative = MenstrualNarrative(
            hkExternalUUID: "hk-1",
            dateKey: "2026-05-20",
            note: "cramps after lunch",
            symptomFlags: [.cramps, .fatigue],
            customSymptomScales: ["cramps": 6]
        )

        try repository.insert(narrative, contentKey: key)
        let read = try #require(try repository.narrative(forHKUUID: "hk-1", contentKey: key))

        #expect(read.note == "cramps after lunch")
        #expect(read.symptomFlags.sorted() == [.cramps, .fatigue])
        #expect(read.customSymptomScales["cramps"] == 6)
    }

    @Test func narrativeRepositoryRoundTripsCustomSymptomScales() throws {
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let narrative = MenstrualNarrative(
            hkExternalUUID: "hk-scales",
            dateKey: "2026-05-20",
            symptomFlags: [.cramps, .fatigue],
            customSymptomScales: ["cramps": 8, "fatigue": 4]
        )

        try repo.insert(narrative, contentKey: key)
        let read = try #require(try repo.narrative(forHKUUID: "hk-scales", contentKey: key))

        #expect(read.customSymptomScales["cramps"] == 8)
        #expect(read.customSymptomScales["fatigue"] == 4)
    }

    @Test func narrativeRepositoryRejectsWrongKey() throws {
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        let wrongKey = SymmetricKey(data: Data(repeating: 2, count: 32))
        try repository.insert(MenstrualNarrative(hkExternalUUID: "hk-2", dateKey: "2026-05-20", note: "private"), contentKey: key)

        #expect(throws: Error.self) {
            _ = try repository.narrative(forHKUUID: "hk-2", contentKey: wrongKey)
        }
    }

    @Test func logEventWritesHealthKitMetadata() async throws {
        let health = MockPeriodHealthKitService()
        let periodStore = PeriodTrackerStore(healthService: health, narrativeRepository: makeRepository(), lockService: MockLockService(state: .notConfigured))

        _ = try await periodStore.logEvent(UserLoggedCycleEvent(flowLevel: .medium, isCycleStart: true), unlockedContentKey: nil)
        let sample = try #require(health.savedSamples.first as? HKCategorySample)

        #expect(sample.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue)
        #expect(sample.metadata?[HKMetadataKeyExternalUUID] as? String != nil)
        #expect(sample.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool == true)
    }

    @Test func cycleEventWithoutFlowDoesNotEmitMenstrualFlowSample() throws {
        let samples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(date: Date(), basalBodyTemperature: 98.6),
            externalUUID: UUID()
        )

        #expect(samples.contains { sample in
            sample.sampleType.identifier == HKQuantityTypeIdentifier.basalBodyTemperature.rawValue
        })
        #expect(samples.compactMap { $0 as? HKCategorySample }.allSatisfy { sample in
            sample.categoryType.identifier != HKCategoryTypeIdentifier.menstrualFlow.rawValue
        })
    }

    @Test func logEventWithDefaultFlowSavesNoHealthKitSamples() async throws {
        let health = MockPeriodHealthKitService()
        let periodStore = PeriodTrackerStore(healthService: health, narrativeRepository: makeRepository(), lockService: MockLockService(state: .notConfigured))

        let result = try await periodStore.logEvent(UserLoggedCycleEvent(), unlockedContentKey: nil)

        #expect(result == .saved)
        #expect(health.savedSamples.isEmpty)
    }

    @Test func explicitUnspecifiedFlowEmitsHealthKitUnspecifiedSample() throws {
        let samples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(date: Date(), flowLevel: .unspecified),
            externalUUID: UUID()
        )
        let sample = try #require(samples.first as? HKCategorySample)

        #expect(sample.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue)
        #expect(sample.value == HKCategoryValueVaginalBleeding.unspecified.rawValue)
    }

    @Test func logEventPersistsProvidedDate() async throws {
        let health = MockPeriodHealthKitService()
        let key = SymmetricKey(data: Data(repeating: 6, count: 32))
        let store = PeriodTrackerStore(
            healthService: health,
            narrativeRepository: makeRepository(),
            lockService: MockLockService(state: .unlocked)
        )
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date())!

        _ = try await store.logEvent(
            UserLoggedCycleEvent(date: fiveDaysAgo, flowLevel: .light, note: "back-dated", symptoms: [.bloating]),
            unlockedContentKey: key
        )
        let sample = try #require(health.savedSamples.first as? HKCategorySample)

        #expect(Calendar.current.isDate(sample.startDate, inSameDayAs: fiveDaysAgo))
    }

    @Test func lockedLogEventBuffersNarrative() async throws {
        let lock = MockLockService(state: .locked(cooldownDeadline: nil))
        let periodStore = PeriodTrackerStore(healthService: MockPeriodHealthKitService(), narrativeRepository: makeRepository(), lockService: lock)

        let result = try await periodStore.logEvent(UserLoggedCycleEvent(note: "save later", symptoms: [.headache]), unlockedContentKey: nil)

        #expect(result == .savedWithBufferedNarrative)
        #expect(lock.pending.count == 1)
        #expect(lock.pending.first?.noteBytes.flatMap { String(data: $0, encoding: .utf8) } == "save later")
    }

    @Test func lockedLogEventBuffersCustomSymptomScales() async throws {
        let lock = MockLockService(state: .locked(cooldownDeadline: nil))
        let store = PeriodTrackerStore(
            healthService: MockPeriodHealthKitService(),
            narrativeRepository: makeRepository(),
            lockService: lock
        )

        _ = try await store.logEvent(
            UserLoggedCycleEvent(symptoms: [.cramps], customSymptomScales: ["cramps": 9]),
            unlockedContentKey: nil
        )
        let payload = try #require(lock.pending.first)
        let scales = try JSONDecoder().decode([String: Int].self, from: #require(payload.customSymptomScalesBytes))

        #expect(scales["cramps"] == 9)
    }

    @Test func loggingWithoutNarrativeDoesNotTouchRepositoryOrBuffer() async throws {
        let lock = MockLockService(state: .unlocked)
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let store = PeriodTrackerStore(
            healthService: MockPeriodHealthKitService(),
            narrativeRepository: repo,
            lockService: lock
        )

        let result = try await store.logEvent(UserLoggedCycleEvent(flowLevel: .light), unlockedContentKey: key)

        #expect(result == .saved)
        #expect(lock.pending.isEmpty)
        let range = DateInterval(start: Date().addingTimeInterval(-86_400), end: Date())
        #expect(try repo.narratives(in: range, contentKey: key).isEmpty)
    }

    @Test func loadEntriesWithNilKeyReturnsSamplesWithoutNarrative() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .medium),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "should not surface"
        ), contentKey: key)
        let store = PeriodTrackerStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .locked(cooldownDeadline: nil))
        )

        await store.loadEntries(unlockedContentKey: nil)

        let today = store.entries.first { $0.dateKey == FernletDate.dayKey(for: Date()) }
        #expect(today?.samples.isEmpty == false)
        #expect(today?.narrative == nil)
    }

    @Test func loadEntriesJoinsNarrativeToSampleByExternalUUID() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 5, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .heavy),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "joined",
            symptomFlags: [.cramps]
        ), contentKey: key)
        let store = PeriodTrackerStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked)
        )

        await store.loadEntries(unlockedContentKey: key)

        let today = store.entries.first { $0.dateKey == FernletDate.dayKey(for: Date()) }
        #expect(today?.narrative?.note == "joined")
        #expect(today?.narrative?.symptomFlags == [.cramps])
    }

    @Test func drainPendingBufferWritesNarrativeRows() async throws {
        let lock = MockLockService(state: .unlocked)
        lock.pending = [PendingNarrativePayload(
            hkExternalUUID: "hk-drain",
            dateKey: "2026-05-20",
            noteBytes: Data("drained note".utf8),
            symptomFlagsBytes: try JSONEncoder().encode([PeriodSymptom.bloating.rawValue]),
            customSymptomScalesBytes: try JSONEncoder().encode(["bloating": 4])
        )]
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        let periodStore = PeriodTrackerStore(healthService: MockPeriodHealthKitService(), narrativeRepository: repository, lockService: lock)

        try await periodStore.drainPendingBuffer(contentKey: key)
        let read = try #require(try repository.narrative(forHKUUID: "hk-drain", contentKey: key))

        #expect(lock.pending.isEmpty)
        #expect(read.note == "drained note")
        #expect(read.symptomFlags == [.bloating])
    }

    /// Regression for prior finding #37: a partial failure while draining the pending
    /// buffer must leave the buffer intact so the notes are retried on the next unlock,
    /// never silently dropped. The first payload decodes and inserts fine; the second
    /// has undecodable symptom bytes, so the drain throws partway through.
    @Test func drainPendingBufferPreservesBufferOnPartialFailure() async throws {
        let lock = MockLockService(state: .unlocked)
        lock.pending = [
            PendingNarrativePayload(
                hkExternalUUID: "hk-good",
                dateKey: "2026-05-20",
                noteBytes: Data("good note".utf8),
                symptomFlagsBytes: try JSONEncoder().encode([PeriodSymptom.cramps.rawValue]),
                customSymptomScalesBytes: nil
            ),
            PendingNarrativePayload(
                hkExternalUUID: "hk-bad",
                dateKey: "2026-05-21",
                noteBytes: Data("bad note".utf8),
                symptomFlagsBytes: Data("not-json".utf8),   // fails JSONDecoder.decode([String])
                customSymptomScalesBytes: nil
            )
        ]
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let periodStore = PeriodTrackerStore(healthService: MockPeriodHealthKitService(), narrativeRepository: repository, lockService: lock)

        await #expect(throws: (any Error).self) {
            try await periodStore.drainPendingBuffer(contentKey: key)
        }

        // Buffer is NOT purged on failure, so the user's notes survive for the next attempt.
        #expect(!lock.pending.isEmpty)
    }

    @Test func currentPhaseUsesObservedFlowOnly() async throws {
        let health = MockPeriodHealthKitService()
        health.loadedSamples = try HealthKitService.periodSamples(for: UserLoggedCycleEvent(date: Date(), flowLevel: .light), externalUUID: UUID())
        let periodStore = PeriodTrackerStore(healthService: health, narrativeRepository: makeRepository(), lockService: MockLockService(state: .unlocked))

        await periodStore.loadEntries(unlockedContentKey: SymmetricKey(data: Data(repeating: 1, count: 32)))
        #expect(periodStore.currentPhaseFromObservations() == .menstrual)

        health.loadedSamples = []
        await periodStore.loadEntries(unlockedContentKey: nil)
        #expect(periodStore.currentPhaseFromObservations() == .unknown)
        #expect(periodStore.prediction == nil)
    }

    @Test func loadEntriesBuildsPredictionWhenUnlocked() async throws {
        let health = MockPeriodHealthKitService()
        let calendar = Calendar.current
        let key = SymmetricKey(data: Data(repeating: 8, count: 32))
        let firstStart = calendar.date(byAdding: .day, value: -140, to: Date())!
        health.loadedSamples = try (0..<6).flatMap { cycleIndex in
            let start = calendar.date(byAdding: .day, value: cycleIndex * 28, to: firstStart)!
            return try HealthKitService.periodSamples(
                for: UserLoggedCycleEvent(date: start, flowLevel: .medium),
                externalUUID: UUID()
            )
        }
        let periodStore = PeriodTrackerStore(
            healthService: health,
            narrativeRepository: makeRepository(),
            lockService: MockLockService(state: .unlocked),
            calendar: calendar
        )

        await periodStore.loadEntries(unlockedContentKey: key)
        let prediction = try #require(periodStore.prediction)

        #expect(prediction.confidence > 0.5)
        #expect(prediction.predictedFlow.count >= 3)
    }

    @Test func menstrualFlowCountReferenceIsRestrictedToAllowedFiles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fernlet")
        let allowed: Set<String> = [
            "ContentView.swift",
            "HealthKitService.swift",
            "WellbeingModels.swift",
            "PeriodTrackerStore.swift",
            "PeriodTrackerView.swift",
            "LogPeriodSheet.swift"
        ]
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !allowed.contains($0.lastPathComponent) }
        let leakingFiles = try files.filter { url in
            try String(contentsOf: url, encoding: .utf8).contains("menstrualFlowEventCount")
        }
        #expect(leakingFiles.isEmpty)
    }

    private func makeRepository() -> MenstrualNarrativeRepository {
        MenstrualNarrativeRepository(context: PrivatePersistenceController(inMemory: true).container.viewContext)
    }
}

private final class MockPeriodHealthKitService: PeriodHealthKitServicing {
    var savedSamples: [HKSample] = []
    var loadedSamples: [HKSample] = []

    func isHealthDataAvailable() -> Bool { true }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome { AuthorizationOutcome(writeStatuses: [:]) }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot { AuthorizationSnapshot(isAvailable: true, writeStatuses: [:]) }
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws { }
    func startObservingWorkouts(handler: @escaping ([HKWorkout]) -> Void) async throws { }
    func stopObservingWorkouts() { }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { [] }
    func save(_ samples: [HKObject]) async throws { savedSamples += samples.compactMap { $0 as? HKSample } }
    func delete(_ samples: [HKSample]) async throws { }
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] { [] }
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func loadBodyProfile() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws { }
    func saveWorkout(_ workout: Workout) async throws -> UUID { UUID() }
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double? { nil }
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext { HealthDailyContext() }
    func disableIntegration() async throws { }
    func enableIntegration() async throws { }
    func openHealthPrivacySettings() async { }

    func savePeriodEvent(_ event: UserLoggedCycleEvent, externalUUID: UUID) async throws -> [HKSample] {
        let samples = try HealthKitService.periodSamples(for: event, externalUUID: externalUUID)
        savedSamples += samples
        return samples
    }

    func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample] {
        loadedSamples
    }
}

@MainActor
private final class MockLockService: FernletLockServicing {
    var state: FernletLockState
    var statePublisher: AnyPublisher<FernletLockState, Never> { Just(state).eraseToAnyPublisher() }
    var requiresReset = false
    var biometricEnabled = false
    var biometricType: LABiometryType = .none
    var credentialKind: FernletLockCredentialKind?
    var currentAttemptCount = 0
    var pending: [PendingNarrativePayload] = []
    private var key: SymmetricKey?

    init(state: FernletLockState) {
        self.state = state
        if state == .unlocked { key = SymmetricKey(data: Data(repeating: 3, count: 32)) }
    }

    func configure(credential: FernletLockCredential) async throws { state = .unlocked }
    func changeCredential(current: String, new: FernletLockCredential) async throws { }
    func unlock(passcode: String) async throws -> UnlockResult { state = .unlocked; return UnlockResult(method: .passcode) }
    func unlockWithBiometrics() async throws -> UnlockResult { state = .unlocked; return UnlockResult(method: .biometric) }
    func lock(reason: FernletLockReason) { state = .locked(cooldownDeadline: nil) }
    func reset() throws { state = .notConfigured; pending = [] }
    func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws { biometricEnabled = enabled }
    func contentKey() -> SymmetricKey? { key }
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws { pending.append(payload) }
    func drainPendingNarratives() throws -> [PendingNarrativePayload] { pending }
    func purgePendingNarratives() throws { pending = [] }
}
