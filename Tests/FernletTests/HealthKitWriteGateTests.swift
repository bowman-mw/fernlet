import Foundation
import HealthKit
import Testing
import FernletFoundation
import FernletDomainModel
import HealthKitGateway
import PrivateHealthStore
@testable import Fernlet

/// Pins the owner's rule of 2026-09-23 ("That shouldn't happen", DPA-118): with Fernlet's master
/// Health switch off, or the switch for THIS kind of data off, Fernlet writes nothing to Apple Health.
///
/// The defect it closes: `HealthKitService.saveWorkout` was gated on device availability alone and
/// its callers checked only HealthKit's share grant — which outlives Fernlet's own switches — so a
/// user who turned Fernlet's Health off kept having every logged workout written to Apple Health.
/// Four more writes checked the master switch but never their own capability's switch, and the
/// height/weight write bypassed both the gate and the test seam by calling the Health store directly.
///
/// Every write kind is driven through the REAL `HealthKitService` over a recording store seam, so the
/// assertion is on what reached the store — not on what a fake service chose to report. The source
/// scan at the bottom is the other half: it proves no write can reach HealthKit except through the two
/// gated doors this suite exercises.
@MainActor
struct HealthKitWriteGateTests {

    // MARK: - Every write kind, every closed switch

    /// One kind of write Fernlet makes into Apple Health, with the capability whose switch owns it.
    enum WriteKind: CaseIterable, CustomTestStringConvertible {
        case workout
        case heightAndWeight
        case mindfulSession
        case intimacy
        case cycle
        case genericSave

        var testDescription: String { "\(self)" }

        /// The capability switch this write must be refused behind.
        var capability: HealthCapability {
            switch self {
            case .workout: .workoutLogging
            case .heightAndWeight: .bodyProfile
            case .mindfulSession, .genericSave: .mindfulness
            case .intimacy: .intimateLogging
            case .cycle: .cycleTracking
            }
        }

        /// Performs the write through the service's public API — the same call the app makes.
        @MainActor
        func perform(on service: HealthKitService) async throws {
            let end = Date()
            let start = end.addingTimeInterval(-600)
            switch self {
            case .workout:
                _ = try await service.saveWorkout(WriteGateHarness.sampleWorkout)
            case .heightAndWeight:
                try await service.saveBodyProfileMeasurements(UserNutritionProfile())
            case .mindfulSession:
                try await service.saveMindfulSession(start: start, end: end)
            case .intimacy:
                try await service.saveIntimacyEvent(date: end, protectionUsed: nil, externalUUID: UUID())
            case .cycle:
                _ = try await service.savePeriodEvent(UserLoggedCycleEvent(flowLevel: .medium), externalUUID: UUID())
            case .genericSave:
                try await service.save([try WriteGateHarness.mindfulSample(start: start, end: end)])
            }
        }
    }

    /// Which of the two switches is off.
    enum ClosedSwitch: CaseIterable, CustomTestStringConvertible {
        /// The master "Share with Health" switch (this kind's own switch left ON).
        case master
        /// This kind's own switch (the master left ON).
        case capability

        var testDescription: String { "\(self)" }
    }

    @Test(arguments: WriteKind.allCases, ClosedSwitch.allCases)
    func aClosedSwitchWritesNothing(kind: WriteKind, closed: ClosedSwitch) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(
            masterEnabled: closed != .master,
            enabledCapabilities: closed == .capability ? [] : [kind.capability]
        )
        defer { harness.cleanup() }

        let error = await #expect(throws: HealthKitServiceError.self) {
            try await kind.perform(on: harness.service)
        }

        #expect(error.map(Self.isSharingTurnedOff) == true, "the refusal must say sharing is off, not that Health is missing")
        #expect(harness.controller.writeCount == 0, "nothing may reach the Health store with a switch off")
    }

    /// The positive control: with both switches on (and the share grant in place) every kind DOES
    /// write — otherwise the refusals above could be the write path simply being broken.
    ///
    /// The one test here that REQUIRES a Health store rather than skipping without one: every other
    /// test returns early on a host without Health, so without this they would all pass vacuously.
    @Test(arguments: WriteKind.allCases)
    func bothSwitchesOnWrites(kind: WriteKind) async throws {
        try #require(HKHealthStore.isHealthDataAvailable(), "this host has no Health store, so the whole suite proves nothing")
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [kind.capability])
        defer { harness.cleanup() }

        try await kind.perform(on: harness.service)

        #expect(harness.controller.writeCount == 1)
    }

    /// Turning on a DIFFERENT kind never opens this one — the switch is per kind, not "any".
    @Test(arguments: WriteKind.allCases)
    func anotherKindsSwitchDoesNotOpenThisOne(kind: WriteKind) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let others = Set(HealthCapability.allCases).subtracting([kind.capability])
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: others)
        defer { harness.cleanup() }

        await #expect(throws: HealthKitServiceError.self) {
            try await kind.perform(on: harness.service)
        }
        #expect(harness.controller.writeCount == 0)
    }

    // MARK: - The generic door

    /// A batch mixing a kind that is shared with one that is not is refused WHOLE — never a partial
    /// write of the allowed half.
    @Test func aMixedBatchIsRefusedWhole() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.mindfulness])
        defer { harness.cleanup() }
        let now = Date()
        let height = HKQuantitySample(
            type: try HealthKitService.quantityType(.height),
            quantity: HKQuantity(unit: .inch(), doubleValue: 68),
            start: now,
            end: now
        )

        await #expect(throws: HealthKitServiceError.self) {
            try await harness.service.save([try WriteGateHarness.mindfulSample(start: now.addingTimeInterval(-60), end: now), height])
        }
        #expect(harness.controller.writeCount == 0)
    }

    /// A type Fernlet never asks to share (steps are only ever READ) has no switch that could have
    /// allowed it, so the generic door refuses it even with every switch on.
    @Test func aTypeFernletNeverSharesIsRefused() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: Set(HealthCapability.allCases))
        defer { harness.cleanup() }
        let now = Date()
        let steps = HKQuantitySample(
            type: try HealthKitService.quantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 100),
            start: now.addingTimeInterval(-60),
            end: now
        )

        await #expect(throws: HealthKitServiceError.self) {
            try await harness.service.save([steps])
        }
        #expect(harness.controller.writeCount == 0)
    }

    /// The gate's type→capability map, derived from the share sets: every share type maps back to
    /// exactly the capability that asks to share it, and the two read-only capabilities own none.
    @Test func everyShareTypeHasExactlyOneOwningCapability() throws {
        for capability in HealthCapability.allCases {
            let identifiers = HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability)
            for identifier in identifiers {
                let type = try #require(Self.sampleType(identifier))
                #expect(HealthKitService.writeCapability(for: type) == capability, "\(identifier)")
            }
        }
        #expect(HealthKitService.writeCapability(for: HKObjectType.workoutType()) == .workoutLogging)
        #expect(HealthKitService.writesSamplesToHealth(.bodyContext) == false)
        #expect(HealthKitService.writesSamplesToHealth(.activityContext) == false)
        let readOnly = try HealthKitService.quantityType(.stepCount)
        #expect(HealthKitService.writeCapability(for: readOnly) == nil)
    }

    // MARK: - Removal is deliberately not switch-gated (decision 2026-09-23)

    /// Removing samples Fernlet wrote — a cycle day the user deleted — works with sharing OFF: a delete
    /// puts nothing into Health, HealthKit only lets Fernlet delete its own samples, and "sharing off"
    /// must not strand them. If this ever flips, `PeriodTrackerStore.deleteEntry` stops working for a
    /// user who turned sharing off, and the decision needs revisiting on purpose.
    @Test func removingFernletsOwnSamplesIsNotSwitchGated() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [])
        defer { harness.cleanup() }
        let now = Date()

        try await harness.service.delete([try WriteGateHarness.mindfulSample(start: now.addingTimeInterval(-60), end: now)])

        #expect(harness.controller.deleteCallCount == 1)
        #expect(harness.controller.writeCount == 0)
    }

    /// A period EDIT is delete-then-write, so its pre-check must refuse exactly when the write would
    /// be — and pass for an entry with no clinical field, which writes nothing to Health.
    @Test func thePeriodEditPreCheckMatchesTheWriteGate() throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [])
        defer { harness.cleanup() }

        #expect(throws: HealthKitServiceError.self) {
            try harness.service.checkPeriodEventWriteAllowed(UserLoggedCycleEvent(flowLevel: .light))
        }
        try harness.service.checkPeriodEventWriteAllowed(UserLoggedCycleEvent(note: "a note only"))
        harness.enable(.cycleTracking)
        try harness.service.checkPeriodEventWriteAllowed(UserLoggedCycleEvent(flowLevel: .light))
    }

    // MARK: - The callers' quiet checks

    /// DPA-118 end to end: HealthKit's workout share grant is still in place (it outlives Fernlet's
    /// switches), Fernlet's Health is off, the user logs a workout — nothing reaches Health.
    @Test func loggingAWorkoutWithFernletsHealthOffWritesNothing() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [.workoutLogging])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let store = makeTestStore(healthKitService: harness.service)

        store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle()

        #expect(harness.controller.savedWorkoutCount == 0)
        #expect(store.day.workouts.count == 1, "the workout is still logged — only Health is left alone")
        #expect(store.day.workouts.first?.healthKitUUID == nil)
    }

    /// The same log with Fernlet's Health on reaches Health and stamps the row — the control that
    /// makes the refusal above meaningful.
    @Test func loggingAWorkoutWithFernletsHealthOnWritesOnce() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.workoutLogging])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let store = makeTestStore(healthKitService: harness.service)

        store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle { store.day.workouts.first?.healthKitUUID != nil }

        #expect(harness.controller.savedWorkoutCount == 1)
        #expect(store.day.workouts.first?.healthKitUUID == harness.controller.lastSavedWorkoutUUID)
    }

    /// An edit is delete-then-save. With workout sharing off the re-sync does NEITHER half: the save
    /// would be refused, and the delete alone would turn an edit into removing the workout from Health.
    @Test func editResyncWithSharingOffTouchesNothing() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [.workoutLogging])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let context = SilentWorkoutSyncContext()
        let sync = WorkoutHealthKitSync(context: context, service: harness.service, ownBundleID: "fernlet.tests")

        // In a task, bounded: the recording seam never answers a query, so a regressed re-sync that
        // starts the delete's lookup would otherwise hang this test instead of failing it.
        // Cancelling unwinds that lookup (the one-shot query bridge honours cancellation).
        let resync = Task { await sync.resyncAuthoredWorkoutInHealth(WriteGateHarness.sampleWorkout, date: "2026-09-23") }
        await Self.settle()
        let lookupsStarted = harness.controller.executedQueries.count
        resync.cancel()
        await resync.value

        #expect(lookupsStarted == 0, "the delete's lookup must not even run")
        #expect(harness.controller.deleteCallCount == 0)
        #expect(harness.controller.savedWorkoutCount == 0)
    }

    /// Settings' height/weight Stepper writes back to Health on every edit; with body-measurement
    /// sharing off it must stay silent — no write, and no error sentence on every tick.
    @Test func bodyMeasurementWriteBackWithSharingOffIsSilent() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let viewModel = HealthKitAuthorizationViewModel(
            service: harness.service,
            ledgerKeychainService: harness.serviceID,
            ledgerDefaults: harness.ledgerDefaults
        )

        await viewModel.syncBodyProfileMeasurements(UserNutritionProfile())

        #expect(harness.controller.writeCount == 0)
        #expect(viewModel.statusMessage.isEmpty)
    }

    // MARK: - Asking in context opens the switch the gate now reads

    /// The period sheet's own prompt used to leave cycle sharing's Fernlet switch off — harmless
    /// while writes ignored that switch, fatal to every period log once they do. Allowing the
    /// prompt now opens the switch (and records the ask), so the next log goes through.
    @Test func allowingTheContextualCyclePromptOpensItsSwitch() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [])
        defer { harness.cleanup() }
        harness.controller.promptAnswer = .sharingAuthorized
        let viewModel = harness.authorizationViewModel()

        await HealthAccessGrant.requestInContext(.cycleTracking, source: "test", authorization: viewModel, preferences: harness.preferences)

        #expect(harness.preferences.preferences.healthKitCapabilityEnabled[HealthCapability.cycleTracking.rawValue] == true)
        #expect(viewModel.hasRequested(.cycleTracking))
        _ = try await harness.service.savePeriodEvent(UserLoggedCycleEvent(flowLevel: .light), externalUUID: UUID())
        #expect(harness.controller.writeCount == 1)
    }

    /// Declining puts the switch back, so Settings never shows "Shared" for a kind the user just
    /// said no to — and the log that follows is refused by Fernlet, never sent to be refused by iOS.
    @Test func decliningTheContextualPromptLeavesTheSwitchOff() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [])
        defer { harness.cleanup() }
        harness.controller.promptAnswer = .sharingDenied
        let viewModel = harness.authorizationViewModel()

        await HealthAccessGrant.requestInContext(.cycleTracking, source: "test", authorization: viewModel, preferences: harness.preferences)

        #expect(harness.preferences.preferences.healthKitCapabilityEnabled[HealthCapability.cycleTracking.rawValue] == false)
        #expect(harness.service.isWriteSharingEnabled(for: .cycleTracking) == false)
    }

    /// With Fernlet's Health switched off the contextual ask does nothing at all — no prompt, no
    /// switch. Only the user (or the first-workout offer) turns the master on.
    @Test func theContextualAskNeverRunsWithHealthOff() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [])
        defer { harness.cleanup() }
        harness.controller.promptAnswer = .sharingAuthorized
        let viewModel = harness.authorizationViewModel()

        await HealthAccessGrant.requestInContext(.cycleTracking, source: "test", authorization: viewModel, preferences: harness.preferences)

        #expect(harness.controller.authorizationRequests.isEmpty)
        #expect(harness.preferences.preferences.healthKitCapabilityEnabled[HealthCapability.cycleTracking.rawValue] == false)
    }

    // MARK: - The only doors (source scan)

    /// The structural half: HealthKit is written through exactly two doors, both gated. No shipping
    /// file outside the gateway touches `HKHealthStore` or builds a workout; inside it, the raw Health
    /// store is only ever asked for the two characteristic READS, the builder lives only in the store
    /// seam, and each seam write is called from exactly one place — which calls the gate first.
    @Test func healthKitIsWrittenOnlyThroughTheGatedDoors() throws {
        let serviceSource = try Self.source("FernletKit/Sources/HealthKitGateway/HealthKitService.swift")
        let service = try #require(Self.body(of: "public final class HealthKitService", in: serviceSource))

        #expect(Self.occurrences(of: "HKWorkoutBuilder(", in: service) == 0)
        let rawStoreUses = Self.lines(containing: "healthStore.", in: service)
        #expect(rawStoreUses.allSatisfy { $0.contains("dateOfBirthComponents") || $0.contains("biologicalSex") },
                "the Health store may only be READ directly: \(rawStoreUses)")

        #expect(Self.occurrences(of: "storeController.save(", in: serviceSource) == 1)
        let saveBody = try #require(Self.body(of: "public func save(_ samples: [HKObject])", in: serviceSource))
        #expect(saveBody.contains("storeController.save("))
        #expect(saveBody.contains("requireWriteSharing("))

        #expect(Self.occurrences(of: "storeController.saveWorkout(", in: serviceSource) == 1)
        let workoutBody = try #require(Self.body(of: "public func saveWorkout(_ workout: Workout)", in: serviceSource))
        #expect(workoutBody.contains("storeController.saveWorkout("))
        #expect(workoutBody.contains("requireWriteSharing(.workoutLogging)"))

        let elsewhere = try Self.shippingSwiftFiles().filter { $0 != "FernletKit/Sources/HealthKitGateway/HealthKitService.swift" }
        for path in elsewhere {
            let code = Self.strippingLineComments(try Self.source(path))
            #expect(!code.contains("HKHealthStore"), "\(path) reaches HealthKit past the gateway")
            #expect(!code.contains("HKWorkoutBuilder"), "\(path) builds a workout past the gateway")
        }
    }

    // MARK: - Helpers

    private static func isSharingTurnedOff(_ error: HealthKitServiceError) -> Bool {
        if case .sharingTurnedOff = error { return true }
        return false
    }

    private static func sampleType(_ identifier: String) -> HKSampleType? {
        if let quantity = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)) {
            return quantity
        }
        return HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
    }

    /// Lets the store's detached Health tasks run; stops early once `until` holds.
    private static func settle(until: @MainActor () -> Bool = { false }) async {
        for _ in 0..<40 {
            if until() { return }
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return
            }
        }
    }

    /// The repository root, derived from this file's path (`Tests/FernletTests/<this>`).
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every shipping Swift file under `App/` and `FernletKit/Sources/`, repo-relative.
    private static func shippingSwiftFiles() throws -> [String] {
        var paths: [String] = []
        for root in ["App", "FernletKit/Sources"] {
            let rootURL = repositoryRoot.appendingPathComponent(root)
            let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                paths.append(String(url.path.dropFirst(repositoryRoot.path.count + 1)))
            }
        }
        #expect(paths.count > 100, "the scan found almost nothing — the layout moved")
        return paths
    }

    /// The brace-balanced body that follows the first `signature` in `source`, or nil.
    private static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature),
              let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func lines(containing needle: String, in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.contains(needle) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private static func strippingLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[..<range.lowerBound]
            }
            .joined(separator: "\n")
    }
}

// MARK: - Harness

/// A real `HealthKitService` over a recording store seam, with its own preferences keychain slot,
/// capability-ledger slot and defaults suite, so no test can see — or clear — another's switches.
@MainActor
final class WriteGateHarness {
    let controller = WriteRecordingStoreController()
    let preferences: StoragePreferencesStore
    let service: HealthKitService
    let serviceID: String
    let ledgerDefaults: UserDefaults
    private let ledgerSuiteName: String

    init(masterEnabled: Bool, enabledCapabilities: Set<HealthCapability>) {
        serviceID = "com.fernlet.healthkit-write-gate.tests.\(UUID().uuidString)"
        ledgerSuiteName = "com.fernlet.healthkit-write-gate.defaults.\(UUID().uuidString)"
        ledgerDefaults = UserDefaults(suiteName: ledgerSuiteName) ?? .standard
        preferences = StoragePreferencesStore(keychainService: serviceID)
        preferences.update { prefs in
            prefs.healthKitMasterEnabled = masterEnabled
            for capability in enabledCapabilities {
                prefs.healthKitCapabilityEnabled[capability.rawValue] = true
            }
        }
        // The mindful write also needs HealthKit's own grant; every other kind is gated by the switches.
        controller.statuses[HKCategoryTypeIdentifier.mindfulSession.rawValue] = .sharingAuthorized
        service = HealthKitService(
            storeController: controller,
            preferencesStore: preferences,
            capabilityLedgerKeychainService: serviceID,
            capabilityLedgerDefaults: ledgerDefaults
        )
    }

    /// Turns one capability's switch on.
    func enable(_ capability: HealthCapability) {
        preferences.update { $0.healthKitCapabilityEnabled[capability.rawValue] = true }
    }

    /// A Settings-style view model over this harness's service and ledger slot.
    func authorizationViewModel() -> HealthKitAuthorizationViewModel {
        HealthKitAuthorizationViewModel(service: service, ledgerKeychainService: serviceID, ledgerDefaults: ledgerDefaults)
    }

    func cleanup() {
        KeychainItem.delete(for: .storagePreferences, service: serviceID)
        _ = HealthCapabilityRequestLedger.clear(keychainService: serviceID, legacyDefaults: ledgerDefaults)
        ledgerDefaults.removePersistentDomain(forName: ledgerSuiteName)
    }

    /// A plain Fernlet-logged activity workout with energy and distance, so the workout write carries
    /// samples as well as the workout itself.
    static var sampleWorkout: Workout {
        Workout(
            name: "Morning run",
            type: .cardio,
            mode: .activity,
            activityType: .running,
            exercises: "",
            rpe: nil,
            notes: "",
            duration: 30,
            distanceMiles: 3,
            activeEnergyKcal: 280,
            intensity: .moderate
        )
    }

    static func mindfulSample(start: Date, end: Date) throws -> HKCategorySample {
        HKCategorySample(
            type: try HealthKitService.categoryType(.mindfulSession),
            value: HKCategoryValue.notApplicable.rawValue,
            start: start,
            end: end
        )
    }
}

/// Records every write, delete and query that reaches the store seam; reports the share statuses a
/// test sets.
@MainActor
final class WriteRecordingStoreController: HealthKitStoreControlling {
    var statuses: [String: HKAuthorizationStatus] = [:]
    private(set) var savedBatches: [[HKObject]] = []
    private(set) var savedWorkoutCount = 0
    private(set) var lastSavedWorkoutUUID: UUID?
    private(set) var deleteCallCount = 0
    private(set) var executedQueries: [HKQuery] = []
    private(set) var authorizationRequests: [Set<String>] = []

    /// Every write that reached the store: sample batches plus workouts.
    var writeCount: Int { savedBatches.count + savedWorkoutCount }

    /// Marks every type Fernlet can share as granted — HealthKit's side of the permission, which
    /// persists regardless of Fernlet's own switches.
    func grantAllShareTypes() {
        for capability in HealthCapability.allCases {
            for identifier in HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability) {
                statuses[identifier] = .sharingAuthorized
            }
        }
        statuses[HKObjectType.workoutType().identifier] = .sharingAuthorized
    }

    /// What the "user" answers when a system prompt is presented: every requested share type takes
    /// this status. Nil leaves the statuses untouched (a prompt HealthKit had nothing to show for).
    var promptAnswer: HKAuthorizationStatus?

    func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws {
        authorizationRequests.append(Set(shareTypes.map(\.identifier)))
        guard let promptAnswer else { return }
        for type in shareTypes {
            statuses[type.identifier] = promptAnswer
        }
    }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        statuses[type.identifier] ?? .notDetermined
    }

    /// Whether HealthKit "would show" a sheet: what `authorizationRequestStatus` reports.
    var requestStatus: HKAuthorizationRequestStatus = .unknown
    /// How many times the would-a-sheet-show question was asked.
    private(set) var requestStatusQueries = 0

    func authorizationRequestStatus(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async -> HKAuthorizationRequestStatus {
        requestStatusQueries += 1
        return requestStatus
    }

    func execute(_ query: HKQuery) { executedQueries.append(query) }
    func stop(_ query: HKQuery) { }

    func save(_ samples: [HKObject]) async throws {
        savedBatches.append(samples)
    }

    func saveWorkout(
        configuration: HKWorkoutConfiguration,
        start: Date,
        end: Date,
        samples: [HKSample],
        metadata: [String: Any]
    ) async throws -> UUID {
        savedWorkoutCount += 1
        let uuid = UUID()
        lastSavedWorkoutUUID = uuid
        return uuid
    }

    func delete(_ samples: [HKSample]) async throws { deleteCallCount += 1 }
    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws { }
    func disableBackgroundDelivery(for type: HKObjectType) async throws { }
}

/// A `WorkoutSyncContext` that holds nothing and records nothing — for driving the sync's outbound
/// legs where only what reached the store matters.
@MainActor
final class SilentWorkoutSyncContext: WorkoutSyncContext {
    var todayKey: String { "2026-09-23" }
    func workoutExists(id: UUID) -> Bool { false }
    func workoutExists(healthKitUUID: UUID) -> Bool { false }
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) { }
    func upsertWorkout(_ workout: Workout, date: String) { }
    func isWorkoutTombstoned(fernletWorkoutID: UUID) -> Bool { false }
    func clearWorkoutTombstone(fernletWorkoutID: UUID) { }
    func removeWorkoutByHealthKitUUID(_ hkUUID: UUID) { }
}
