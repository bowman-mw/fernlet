import Combine
import FernletFoundation
import CoreData
import CryptoKit
import Foundation
import HealthKit
import LocalAuthentication
import Testing
import FernletDomainModel
import PrivateStoreCore
import PrivateHealthStore
import HealthKitGateway
import FernletLock
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
        let periodStore = makePeriodStore(healthService: health, narrativeRepository: makeRepository(), lockService: MockLockService(state: .notConfigured))

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
        let periodStore = makePeriodStore(healthService: health, narrativeRepository: makeRepository(), lockService: MockLockService(state: .notConfigured))

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
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: makeRepository(),
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
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
        let periodStore = makePeriodStore(healthService: MockPeriodHealthKitService(), narrativeRepository: makeRepository(), lockService: lock)

        let result = try await periodStore.logEvent(UserLoggedCycleEvent(note: "save later", symptoms: [.headache]), unlockedContentKey: nil)

        #expect(result == .savedWithBufferedNarrative)
        #expect(lock.pending.count == 1)
        #expect(lock.pending.first?.noteBytes.flatMap { String(data: $0, encoding: .utf8) } == "save later")
    }

    @Test func lockedLogEventBuffersCustomSymptomScales() async throws {
        let lock = MockLockService(state: .locked(cooldownDeadline: nil))
        let store = makePeriodStore(
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
        let lock = MockLockService(state: .unlocked(scope: .privateHub))
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let store = makePeriodStore(
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
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .locked(cooldownDeadline: nil))
        )

        await store.loadEntries(unlockedContentKey: nil)

        let today = store.entries.first { $0.dateKey == FernletDate.dayKey(for: Date()) }
        #expect(today?.samples.isEmpty == false)
        #expect(today?.narrative == nil)
    }

    // MARK: - Visibility gate (hide = inert, never delete)

    /// The load-bearing guarantee: while hidden, Fernlet performs NO cycle decrypt AND no cycle
    /// HealthKit read. The HealthKit half is the one a key-withholding gate would miss.
    @Test func hiddenLoadPerformsNoHealthKitReadAndNoDecrypt() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .heavy),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "must never surface while hidden",
            symptomFlags: [.cramps]
        ), contentKey: key)
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachVisibilityGate { false }

        // Unlocked, with a valid key and real data present — the gate is the only thing stopping this.
        await store.loadEntries(unlockedContentKey: key)

        #expect(health.loadPeriodEventsCallCount == 0)
        #expect(store.entries.isEmpty)
        #expect(store.currentPhase == .unknown)
        #expect(store.prediction == nil)
    }

    /// Hiding mid-session must DROP plaintext already resident, not merely refuse the next load —
    /// otherwise up to 240 days of decrypted narratives stay in memory until the process dies.
    @Test func hidingMidSessionScrubsResidentPlaintext() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 10, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .medium),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "loaded while visible"
        ), contentKey: key)
        var visible = true
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachVisibilityGate { visible }

        await store.loadEntries(unlockedContentKey: key)
        #expect(!store.entries.isEmpty)

        visible = false
        store.scrubCycleState()

        #expect(store.entries.isEmpty)
        #expect(store.currentPhase == .unknown)
        #expect(store.prediction == nil)
    }

    /// The gate is checked BEFORE the HealthKit await, and that await is arbitrarily long. Hiding
    /// while it is in flight must abandon the load rather than publish narratives decrypted for a
    /// surface the app is now presenting as off.
    @Test func hidingDuringTheHealthKitAwaitAbandonsTheLoad() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 21, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .medium),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "must not surface after hiding"
        ), contentKey: key)
        var visible = true
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachVisibilityGate { visible }
        health.duringLoad = { visible = false }

        await store.loadEntries(unlockedContentKey: key)

        #expect(store.entries.isEmpty)
        #expect(store.prediction == nil)
        #expect(store.currentPhase == .unknown)
    }

    /// The same race in the LOCK dimension: the caller's content key was live when the load started,
    /// and the hub can lock during the HealthKit await. The load must be abandoned rather than
    /// decrypt 240 days of narratives with a key the hub has already dropped.
    @Test func lockingDuringTheHealthKitAwaitAbandonsTheLoad() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 22, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .medium),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "must not surface after locking"
        ), contentKey: key)
        var liveKey: SymmetricKey? = key
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachLiveContentKeyProvider { liveKey }

        // Control: with the hub still holding the same key, the load publishes normally.
        await store.loadEntries(unlockedContentKey: key)
        #expect(!store.entries.isEmpty)

        // The hub locks mid-await → abandon, scrubbing what the previous load left resident.
        health.duringLoad = { liveKey = nil }
        await store.loadEntries(unlockedContentKey: key)
        #expect(store.entries.isEmpty)

        // A re-key mid-await is the same verdict: this load's authorization no longer exists.
        health.duringLoad = { liveKey = SymmetricKey(data: Data(repeating: 23, count: 32)) }
        await store.loadEntries(unlockedContentKey: key)
        #expect(store.entries.isEmpty)
    }

    /// Hidden must never mean deleted: the sealed rows survive and come back on un-hide.
    @Test func hidingKeepsDataAndUnhidingRestoresIt() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 11, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .light),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "survives hiding"
        ), contentKey: key)
        var visible = false
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachVisibilityGate { visible }

        await store.loadEntries(unlockedContentKey: key)
        #expect(store.entries.isEmpty)

        visible = true
        await store.loadEntries(unlockedContentKey: key)

        let today = store.entries.first { $0.dateKey == FernletDate.dayKey(for: Date()) }
        #expect(today?.narrative?.note == "survives hiding")
    }

    @Test func hiddenLogEventIsRefused() async throws {
        let health = MockPeriodHealthKitService()
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: makeRepository(),
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachVisibilityGate { false }

        await #expect(throws: PeriodTrackingHiddenError.self) {
            _ = try await store.logEvent(
                UserLoggedCycleEvent(flowLevel: .medium),
                unlockedContentKey: SymmetricKey(data: Data(repeating: 12, count: 32))
            )
        }
        #expect(health.savedSamples.isEmpty)
    }

    /// The pending buffer unseals under a DEVICE key, not the content key, so withholding the content
    /// key does nothing here — the gate must refuse explicitly. The buffer is left intact to drain
    /// later, because hiding is not deleting.
    @Test func hiddenDrainIsRefusedAndLeavesBufferIntact() async throws {
        let lock = MockLockService(state: .unlocked(scope: .privateHub))
        let key = SymmetricKey(data: Data(repeating: 13, count: 32))
        lock.pending = [PendingNarrativePayload(
            hkExternalUUID: UUID().uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            noteBytes: Data("buffered".utf8),
            symptomFlagsBytes: nil,
            customSymptomScalesBytes: nil
        )]
        let store = makePeriodStore(
            healthService: MockPeriodHealthKitService(),
            narrativeRepository: makeRepository(),
            lockService: lock
        )
        store.attachVisibilityGate { false }

        try await store.drainPendingBuffer(contentKey: key)

        #expect(lock.pending.count == 1)
    }

    /// Regression: `editEvent` is delete-then-recreate. When the gate lived only inside `logEvent`, an
    /// edit racing a hide deleted the HealthKit samples AND the sealed narrative, then threw without
    /// writing the replacement — the gate itself destroying data it was built to preserve.
    @Test func hiddenEditIsRefusedBeforeAnythingIsDeleted() async throws {
        let health = MockPeriodHealthKitService()
        let repo = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 14, count: 32))
        let externalUUID = UUID()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .medium),
            externalUUID: externalUUID
        )
        try repo.insert(MenstrualNarrative(
            hkExternalUUID: externalUUID.uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "must survive a refused edit"
        ), contentKey: key)
        var visible = true
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )
        store.attachVisibilityGate { visible }
        await store.loadEntries(unlockedContentKey: key)
        let entry = try #require(store.entries.first { $0.narrative != nil })

        visible = false
        await #expect(throws: PeriodTrackingHiddenError.self) {
            _ = try await store.editEvent(
                UserLoggedCycleEvent(flowLevel: .heavy),
                replacingEntry: entry,
                unlockedContentKey: key
            )
        }

        // The narrative must still be readable — the refused edit deleted nothing.
        let surviving = try repo.narrative(forHKUUID: externalUUID.uuidString, contentKey: key)
        #expect(surviving?.note == "must survive a refused edit")
    }

    /// Regression: `deleteEntry` used to recompute `prediction` with no key check, while the identical
    /// assignment in `loadEntries` was gated — so deleting an entry re-enabled phase resolution (and
    /// the scoring softening riding on it) with no content key, punching through both lock and gate.
    @Test func deleteEntryDoesNotResurrectPredictionWithoutContentKey() async throws {
        let health = MockPeriodHealthKitService()
        let calendar = PeriodTestSupport.gmtCalendar()
        health.loadedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(flowLevel: .medium),
            externalUUID: UUID()
        )
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: makeRepository(),
            lockService: MockLockService(state: .locked(cooldownDeadline: nil)),
            calendar: calendar
        )

        await store.loadEntries(unlockedContentKey: nil)
        #expect(store.prediction == nil)

        if let entry = store.entries.first(where: { !$0.samples.isEmpty }) {
            try await store.deleteEntry(entry)
        }

        #expect(store.prediction == nil)
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
        let store = makePeriodStore(
            healthService: health,
            narrativeRepository: repo,
            lockService: MockLockService(state: .unlocked(scope: .privateHub))
        )

        await store.loadEntries(unlockedContentKey: key)

        let today = store.entries.first { $0.dateKey == FernletDate.dayKey(for: Date()) }
        #expect(today?.narrative?.note == "joined")
        #expect(today?.narrative?.symptomFlags == [.cramps])
    }

    @Test func drainPendingBufferWritesNarrativeRows() async throws {
        let lock = MockLockService(state: .unlocked(scope: .privateHub))
        lock.pending = [PendingNarrativePayload(
            hkExternalUUID: "hk-drain",
            dateKey: "2026-05-20",
            noteBytes: Data("drained note".utf8),
            symptomFlagsBytes: try JSONEncoder().encode([PeriodSymptom.bloating.rawValue]),
            customSymptomScalesBytes: try JSONEncoder().encode(["bloating": 4])
        )]
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        let periodStore = makePeriodStore(healthService: MockPeriodHealthKitService(), narrativeRepository: repository, lockService: lock)

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
        let lock = MockLockService(state: .unlocked(scope: .privateHub))
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
        let periodStore = makePeriodStore(healthService: MockPeriodHealthKitService(), narrativeRepository: repository, lockService: lock)

        await #expect(throws: (any Error).self) {
            try await periodStore.drainPendingBuffer(contentKey: key)
        }

        // Buffer is NOT purged on failure, so the user's notes survive for the next attempt.
        #expect(!lock.pending.isEmpty)
    }

    @Test func currentPhaseUsesObservedFlowOnly() async throws {
        let health = MockPeriodHealthKitService()
        health.loadedSamples = try HealthKitService.periodSamples(for: UserLoggedCycleEvent(date: Date(), flowLevel: .light), externalUUID: UUID())
        let periodStore = makePeriodStore(healthService: health, narrativeRepository: makeRepository(), lockService: MockLockService(state: .unlocked(scope: .privateHub)))

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
        let periodStore = makePeriodStore(
            healthService: health,
            narrativeRepository: makeRepository(),
            lockService: MockLockService(state: .unlocked(scope: .privateHub)),
            calendar: calendar
        )

        await periodStore.loadEntries(unlockedContentKey: key)
        let prediction = try #require(periodStore.prediction)

        #expect(prediction.confidence > 0.5)
        #expect(prediction.predictedFlow.count >= 3)
    }

    @Test func menstrualFlowCountReferenceIsRestrictedToAllowedFiles() throws {
        let root = RepoRoot.url
            .appendingPathComponent("App/Fernlet")
        let allowed: Set<String> = [
            "ContentView.swift",
            "HealthKitService.swift",
            "WellbeingModels.swift",
            "PeriodTrackerStore.swift",
            "CycleTrackerView.swift",
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

    /// `PeriodTrackerStore.isVisible` now defaults to fail-CLOSED (`{ false }`), so a store must OPT IN
    /// to visibility. These tests exercise the visible load/log/drain paths, so this factory injects
    /// `isVisible = { true }` by default; the visibility-gate tests below override it to `{ false }` /
    /// `{ visible }` after construction to assert the inert path.
    private func makePeriodStore(
        healthService: any PeriodHealthKitServicing,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        lockService: (any PeriodLockContext)? = nil,
        calendar: Calendar = .current,
        isVisible: @escaping () -> Bool = { true }
    ) -> PeriodTrackerStore {
        let store = PeriodTrackerStore(
            healthService: healthService,
            narrativeRepository: narrativeRepository,
            lockService: lockService,
            calendar: calendar
        )
        store.attachVisibilityGate(isVisible)
        return store
    }
}

// `@MainActor` like the suite that owns it: its call logs are mutated from the async witnesses,
// and the HealthKitGateway value types it builds (`AuthorizationOutcome`, `HealthBodyProfile`)
// have main-actor-isolated initializers.
@MainActor
private final class MockPeriodHealthKitService: PeriodHealthKitServicing {
    var savedSamples: [HKSample] = []
    var loadedSamples: [HKSample] = []

    func isHealthDataAvailable() -> Bool { true }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome { AuthorizationOutcome(writeStatuses: [:]) }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot { AuthorizationSnapshot(isAvailable: true, writeStatuses: [:]) }
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws { }
    func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws { }
    func stopObservingWorkouts() { }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { [] }
    func save(_ samples: [HKObject]) async throws { savedSamples += samples.compactMap { $0 as? HKSample } }
    func delete(_ samples: [HKSample]) async throws { }
    func deleteWorkout(fernletWorkoutID: UUID) async throws -> Bool { false }
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

    /// Counts HealthKit cycle reads so the visibility gate can assert ZERO of them — the flow samples
    /// this returns are unencrypted Health data, so "we withheld the content key" is not evidence the
    /// gate held.
    var loadPeriodEventsCallCount = 0

    /// Runs INSIDE the HealthKit read, standing in for "the world changed while the await was in
    /// flight" — the user hides cycle tracking, or the hub locks. The store re-checks both after this
    /// returns, so a test can drive the race deterministically.
    var duringLoad: (@MainActor () -> Void)?

    func loadPeriodEvents(in dateRange: DateInterval) async throws -> [HKSample] {
        loadPeriodEventsCallCount += 1
        duringLoad?()
        return loadedSamples
    }
}

// The isolated conformance (`@MainActor FernletLockServicing`) mirrors the production
// `FernletLockService` declaration: the protocol refines `PeriodLockContext`, whose requirements
// this main-actor mock satisfies with main-actor members.
@MainActor
private final class MockLockService: @MainActor FernletLockServicing {
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
        if state.unlockedScope != nil { key = SymmetricKey(data: Data(repeating: 3, count: 32)) }
    }

    func configure(credential: FernletLockCredential, grantingScope: FernletLockScope) async throws {
        state = .unlocked(scope: grantingScope)
    }
    func changeCredential(current: String, new: FernletLockCredential) async throws { }
    func unlock(passcode: String, for scope: FernletLockScope) async throws -> UnlockResult {
        state = .unlocked(scope: scope); return UnlockResult(method: .passcode)
    }
    func unlockWithBiometrics(for scope: FernletLockScope) async throws -> UnlockResult {
        state = .unlocked(scope: scope); return UnlockResult(method: .biometric)
    }
    func lock(reason: FernletLockReason) { state = .locked(cooldownDeadline: nil) }
    func revokeUnlockOutside(_ scope: FernletLockScope) {
        guard let current = state.unlockedScope, current != scope else { return }
        lock(reason: .scopeChanged)
    }
    func reset() throws { state = .notConfigured; pending = [] }
    func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws { biometricEnabled = enabled }
    func contentKey(for scope: FernletLockScope) -> SymmetricKey? {
        guard scope == .privateHub, state.isUnlocked(for: scope) else { return nil }
        return key
    }
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws { pending.append(payload) }
    func drainPendingNarratives() throws -> [PendingNarrativePayload] { pending }
    func purgePendingNarratives() throws { pending = [] }
}
