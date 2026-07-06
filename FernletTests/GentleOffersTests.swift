//
//  GentleOffersTests.swift
//  FernletTests
//
//  Batch B gentle interventions: the pure GentleOfferEngine gating + deterministic rotation,
//  the persisted once-per-day cap (via the settings dismissal map), WeatherKit comfort
//  classification + nil paths, and the mindful-session HealthKit write gating (fake store).
//

import Foundation
import HealthKit
import Testing
import AppServices
import DiaryStore
import FernletDomainModel
import FernletFoundation
import FernletScoring
import HealthKitGateway
#if canImport(WeatherKit)
import WeatherKit
#endif
@testable import Fernlet

// MARK: - Offer gating + rotation (pure engine)

struct GentleOfferEngineTests {

    private func offer(
        dateKey: String = "2026-07-05",
        stressEnabled: Bool = false,
        stressState: StressState? = nil,
        moodTrend: String? = nil,
        walk: Bool = false
    ) -> GentleOfferKind? {
        GentleOfferEngine.offer(
            dateKey: dateKey,
            stressAwarenessEnabled: stressEnabled,
            stressState: stressState,
            moodTrendValue: moodTrend,
            walkIsInviting: walk
        )
    }

    @Test func noGateNoOffer() {
        #expect(offer() == nil)
        #expect(offer(stressEnabled: true, stressState: .calm) == nil)
        #expect(offer(stressEnabled: true, stressState: .okay) == nil)
        #expect(offer(moodTrend: "steady") == nil)
        #expect(offer(moodTrend: "improving") == nil)
    }

    @Test func tenseAndNeedsCareOpenTheBodyGate() {
        #expect(offer(stressEnabled: true, stressState: .tense) != nil)
        #expect(offer(stressEnabled: true, stressState: .needsCare) != nil)
    }

    @Test func bodyGateRequiresTheOptIn() {
        // A tense reading with the setting off must never surface an offer.
        #expect(offer(stressEnabled: false, stressState: .tense) == nil)
        #expect(offer(stressEnabled: false, stressState: .needsCare) == nil)
    }

    @Test func moodNeedsGentlenessAloneOpensTheGate() {
        // The exact literal DerivedSignalFactory.moodTrend emits — and only that one.
        #expect(offer(moodTrend: "needs gentleness") != nil)
        #expect(offer(moodTrend: "declining") == nil)
    }

    @Test func rotationIsDeterministicPerDay() {
        for dateKey in ["2026-07-01", "2026-07-02", "2026-07-03"] {
            let first = offer(dateKey: dateKey, stressEnabled: true, stressState: .tense, walk: true)
            let second = offer(dateKey: dateKey, stressEnabled: true, stressState: .tense, walk: true)
            #expect(first == second, "same day must always offer the same thing")
        }
    }

    @Test func walkOnlyEntersRotationWhenInviting() {
        let days = (1...31).map { String(format: "2026-07-%02d", $0) }
        let withoutWalk = days.compactMap { offer(dateKey: $0, stressEnabled: true, stressState: .tense, walk: false) }
        #expect(!withoutWalk.contains(.shortWalk), "no walk offer without pleasant daytime weather")

        let withWalk = days.compactMap { offer(dateKey: $0, stressEnabled: true, stressState: .tense, walk: true) }
        #expect(withWalk.contains(.shortWalk), "pleasant daytime weather should rotate the walk in")
    }

    @Test func nonWalkOfferIsStableWhenWeatherFlips() {
        // Regression (finding #22): the day's offer must not change identity when the async, cached
        // weather comfort flips walk eligibility — except on days whose pick IS the walk (inherently
        // weather-gated). Previously the modulo base flipped 2↔3 and swapped breathing↔worryBox too.
        for dateKey in (1...31).map({ String(format: "2026-07-%02d", $0) }) {
            let dry = offer(dateKey: dateKey, stressEnabled: true, stressState: .tense, walk: false)
            let pleasant = offer(dateKey: dateKey, stressEnabled: true, stressState: .tense, walk: true)
            if pleasant == .shortWalk {
                #expect(dry == .breathing || dry == .worryBox)
            } else {
                #expect(dry == pleasant, "\(dateKey): non-walk offer must not shuffle when weather flips")
            }
        }
    }

    @Test func rotationVariesAcrossDays() {
        let days = (1...31).map { String(format: "2026-07-%02d", $0) }
        let kinds = Set(days.compactMap { offer(dateKey: $0, stressEnabled: true, stressState: .tense, walk: false) })
        #expect(kinds == [.breathing, .worryBox], "both indoor offers should appear across a month")
    }

    @Test func invitationsCarryNoPressureWords() {
        for kind in GentleOfferKind.allCases {
            let lowered = kind.invitation.lowercased()
            #expect(!lowered.contains("you should"))
            #expect(!lowered.contains("you must"))
            #expect(!lowered.contains("you need to"))
        }
    }
}

// MARK: - Once-per-day cap (persisted dismissal)

@MainActor
struct GentleOfferDailyCapTests {

    @Test func dismissConsumesTodayAndFreesTomorrow() {
        let store = makeTestStore()
        #expect(store.isGentleOfferAvailableToday)

        store.dismissGentleOffer()

        #expect(!store.isGentleOfferAvailableToday, "dismissing (or accepting) consumes the day's one offer")
        let until = store.settings.nutrientBubbleDismissedUntil[DiaryStore.gentleOfferDismissalKey]
        #expect(until == DiaryStore.gentleOfferSuppressionEnd(), "suppression must end at the start of the next local day")
    }

    @Test func suppressionEndIsStartOfNextLocalDay() {
        let calendar = Calendar.current
        let now = Date()
        let end = DiaryStore.gentleOfferSuppressionEnd(now: now)
        #expect(calendar.isDate(end, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now))
        #expect(end == calendar.startOfDay(for: end))
    }

    @Test func dismissalKeyRoundTripsThroughSettingsCodec() throws {
        // The cap persists through the existing nutrientBubbleDismissedUntil [String: Date]
        // map — prove a new key in that map survives the settings encode/decode cycle.
        var settings = FernletSettings()
        let until = DiaryStore.gentleOfferSuppressionEnd()
        settings.nutrientBubbleDismissedUntil[DiaryStore.gentleOfferDismissalKey] = until

        let decoded = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.nutrientBubbleDismissedUntil[DiaryStore.gentleOfferDismissalKey] == until)
    }
}

// MARK: - Weather comfort (walk gate)

@MainActor
struct WeatherComfortTests {

    #if canImport(WeatherKit)
    @Test func clearMildDaytimeIsPleasant() {
        let comfort = WeatherKitService.comfort(condition: .clear, temperatureCelsius: 21, isDaylight: true)
        #expect(comfort.isPleasant)
        #expect(comfort.isDaytime)
    }

    @Test func gloomyOrExtremeConditionsAreNotPleasant() {
        #expect(!WeatherKitService.comfort(condition: .rain, temperatureCelsius: 21, isDaylight: true).isPleasant)
        #expect(!WeatherKitService.comfort(condition: .clear, temperatureCelsius: 40, isDaylight: true).isPleasant)
        #expect(!WeatherKitService.comfort(condition: .clear, temperatureCelsius: -3, isDaylight: true).isPleasant)
        #expect(!WeatherKitService.comfort(condition: .blowingDust, temperatureCelsius: 21, isDaylight: true).isPleasant)
    }

    @Test func nightIsReportedEvenWhenPleasant() {
        let comfort = WeatherKitService.comfort(condition: .mostlyClear, temperatureCelsius: 18, isDaylight: false)
        #expect(comfort.isPleasant)
        #expect(!comfort.isDaytime, "the walk offer needs daylight — the gate reads this flag")
    }
    #endif

    @Test func currentComfortIsNilWithoutLocationAuthorization() async {
        // The test host never has location authorization, so the API must degrade to nil
        // (same nil-on-any-failure contract as moodRecoveryPrompt) — never throw, never block.
        let comfort = await WeatherKitService.shared.currentComfort()
        #expect(comfort == nil)
    }

    @Test func concurrentWeatherSurfacesCoalesceWithoutCrashing() async {
        // Regression guard for the shared-continuation bug: a cold-launch burst of the three
        // weather surfaces firing at once (Home ambient + comfort + mood prompt) used to overwrite
        // the single locationContinuation and leak the first waiter (SWIFT TASK CONTINUATION MISUSE).
        // The test host has no location authorization, so each concurrent caller on the same cache
        // miss must coalesce and return nil — never hang, never double-resume, never crash.
        async let comfort = WeatherKitService.shared.currentComfort()
        async let ambient = WeatherKitService.shared.currentAmbient()
        async let prompt = WeatherKitService.shared.moodRecoveryPrompt()
        let results = await (comfort, ambient, prompt)
        #expect(results.0 == nil)
        #expect(results.1 == nil)
        #expect(results.2 == nil)
    }
}

// MARK: - Mindful-session HealthKit write gating

@MainActor
struct MindfulSessionSaveTests {

    private final class RecordingStoreController: HealthKitStoreControlling {
        var authorizationStatuses: [String: HKAuthorizationStatus] = [:]
        private(set) var savedObjects: [HKObject] = []

        func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws {}
        func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
            authorizationStatuses[type.identifier] ?? .notDetermined
        }
        func execute(_ query: HKQuery) {}
        func stop(_ query: HKQuery) {}
        func save(_ samples: [HKObject]) async throws { savedObjects.append(contentsOf: samples) }
        func delete(_ samples: [HKSample]) async throws {}
        func disableBackgroundDelivery(for type: HKObjectType) async throws {}
    }

    private struct Harness {
        let controller: RecordingStoreController
        let service: HealthKitService
        let preferenceServiceID: String

        func cleanup() {
            KeychainItem.delete(for: .storagePreferences, service: preferenceServiceID)
        }
    }

    private func makeHarness(
        masterEnabled: Bool,
        mindfulnessCapabilityEnabled: Bool,
        writeStatus: HKAuthorizationStatus
    ) -> Harness {
        let serviceID = "com.fernlet.mindful-save.tests.\(UUID().uuidString)"
        let preferences = StoragePreferencesStore(keychainService: serviceID)
        preferences.update { prefs in
            prefs.healthKitMasterEnabled = masterEnabled
            prefs.healthKitCapabilityEnabled[HealthCapability.mindfulness.rawValue] = mindfulnessCapabilityEnabled
        }
        let controller = RecordingStoreController()
        controller.authorizationStatuses[HKCategoryTypeIdentifier.mindfulSession.rawValue] = writeStatus
        let service = HealthKitService(storeController: controller, preferencesStore: preferences)
        return Harness(controller: controller, service: service, preferenceServiceID: serviceID)
    }

    @Test func savesWhenEveryGateIsOpen() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = makeHarness(masterEnabled: true, mindfulnessCapabilityEnabled: true, writeStatus: .sharingAuthorized)
        defer { harness.cleanup() }
        let start = Date(timeIntervalSinceNow: -120)
        let end = Date()

        try await harness.service.saveMindfulSession(start: start, end: end)

        #expect(harness.controller.savedObjects.count == 1)
        let sample = harness.controller.savedObjects.first as? HKCategorySample
        #expect(sample?.categoryType.identifier == HKCategoryTypeIdentifier.mindfulSession.rawValue)
        #expect(sample?.startDate == start)
        #expect(sample?.endDate == end)
    }

    @Test func masterToggleOffFailsClosed() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = makeHarness(masterEnabled: false, mindfulnessCapabilityEnabled: true, writeStatus: .sharingAuthorized)
        defer { harness.cleanup() }

        await #expect(throws: HealthKitServiceError.self) {
            try await harness.service.saveMindfulSession(start: Date(timeIntervalSinceNow: -60), end: Date())
        }
        #expect(harness.controller.savedObjects.isEmpty)
    }

    @Test func mindfulnessCapabilityOffFailsClosed() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = makeHarness(masterEnabled: true, mindfulnessCapabilityEnabled: false, writeStatus: .sharingAuthorized)
        defer { harness.cleanup() }

        await #expect(throws: HealthKitServiceError.self) {
            try await harness.service.saveMindfulSession(start: Date(timeIntervalSinceNow: -60), end: Date())
        }
        #expect(harness.controller.savedObjects.isEmpty)
    }

    @Test func missingWriteAuthorizationFailsClosedWithoutPrompting() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = makeHarness(masterEnabled: true, mindfulnessCapabilityEnabled: true, writeStatus: .notDetermined)
        defer { harness.cleanup() }

        await #expect(throws: HealthKitServiceError.self) {
            try await harness.service.saveMindfulSession(start: Date(timeIntervalSinceNow: -60), end: Date())
        }
        #expect(harness.controller.savedObjects.isEmpty)
    }

    @Test func degenerateIntervalIsSilentlySkipped() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = makeHarness(masterEnabled: true, mindfulnessCapabilityEnabled: true, writeStatus: .sharingAuthorized)
        defer { harness.cleanup() }
        let instant = Date()

        try await harness.service.saveMindfulSession(start: instant, end: instant)

        #expect(harness.controller.savedObjects.isEmpty, "a zero-length session must not produce a Health sample")
    }
}
