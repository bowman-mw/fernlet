import Combine
import CryptoKit
import FernletFoundation
import FernletLock
import HealthKitGateway
import Foundation
import HealthKit
import LocalAuthentication
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

/// The cutover's test double for the Apple Health mirror seam (period-data design 2026-09-30, §7.1):
/// every knob the store reads, and a log of every call in order, so a test can pin WHAT reached
/// Health and WHEN (seal before mirror, Fernlet's rows before Health's).
///
/// `@MainActor` like the store that drives it.
@MainActor
final class MockCycleHealthService: PeriodHealthKitServicing {
    /// The metadata key that marks a fabricated sample as ANOTHER app's (tests cannot mint one).
    static let otherAppKey = "test.otherApp"

    var mirrorEnabled = false
    var readEnabled = true
    var readDetermined = true
    var loadedSamples: [HKSample] = []
    var legacySamples: [HKSample] = []
    var legacyError: Error?
    var writeMirrorError: Error?
    var deleteMirrorResult = 0
    var deleteMirrorError: Error?
    var deleteAuthoredError: Error?

    /// Every seam call, in order ("writeMirror", "deleteMirror", "deleteAuthored", "load", "legacy",
    /// "determined").
    private(set) var calls: [String] = []
    private(set) var writtenMirrors: [CycleRecord] = []
    private(set) var deletedMirrorIDs: [UUID] = []
    private(set) var deletedAuthoredCount = 0

    /// Runs inside the Health read — "the world changed while the await was in flight".
    var duringLoad: (@MainActor () -> Void)?
    /// Runs inside the legacy read.
    var duringLegacyLoad: (@MainActor () -> Void)?
    /// Runs at the start of every write or delete call, before it answers — lets a test look at the
    /// sealed store at the moment Health is first touched.
    var onHealthWrite: (@MainActor (String) -> Void)?

    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    func isCycleMirrorEnabled() -> Bool { mirrorEnabled }
    func isCycleHealthReadEnabled() -> Bool { readEnabled }

    func cycleReadAuthorizationDetermined() async -> Bool {
        calls.append("determined")
        return readDetermined
    }

    func writeMirror(of record: CycleRecord) async throws {
        calls.append("writeMirror")
        onHealthWrite?("writeMirror")
        if let writeMirrorError { throw writeMirrorError }
        writtenMirrors.append(record)
    }

    func deleteMirror(recordID: UUID) async throws -> Int {
        calls.append("deleteMirror")
        onHealthWrite?("deleteMirror")
        if let deleteMirrorError { throw deleteMirrorError }
        deletedMirrorIDs.append(recordID)
        return deleteMirrorResult
    }

    func deleteFernletAuthored(_ samples: [HKSample]) async throws -> Int {
        calls.append("deleteAuthored")
        onHealthWrite?("deleteAuthored")
        if let deleteAuthoredError { throw deleteAuthoredError }
        deletedAuthoredCount += samples.count
        return samples.count
    }

    func loadHealthCycleSamples(in range: DateInterval) async throws -> [HKSample] {
        calls.append("load")
        duringLoad?()
        return loadedSamples
    }

    func loadLegacyFernletCycleSamples(limit: Int) async throws -> [HKSample] {
        calls.append("legacy")
        duringLegacyLoad?()
        if let legacyError { throw legacyError }
        return Array(legacySamples.prefix(limit))
    }
}

/// A Health-copy error that says only "sharing is off" — the classifying protocol's `nil` arm.
struct SharingOffForTest: PeriodHealthCopyErrorClassifying {
    var periodHealthCopyFailure: PeriodLogOutcome.HealthCopyFailure? { nil }
}

/// A lock seam double: records what is buffered and can refuse.
@MainActor
final class MockCycleLockService: @MainActor FernletLockServicing {
    var state: FernletLockState
    var statePublisher: AnyPublisher<FernletLockState, Never> { Just(state).eraseToAnyPublisher() }
    var requiresReset = false
    var biometricEnabled = false
    var biometricType: LABiometryType = .none
    var credentialKind: FernletLockCredentialKind?
    var currentAttemptCount = 0
    var pending: [PendingNarrativePayload] = []
    /// When set, buffering throws it.
    var bufferError: Error?
    /// When set, the purge throws it once and clears.
    var purgeErrorOnce: Error?

    init(state: FernletLockState) {
        self.state = state
    }

    func configure(credential: FernletLockCredential, grantingScope: FernletLockScope) async throws {
        state = .unlocked(scope: grantingScope)
    }
    func changeCredential(current: String, new: FernletLockCredential) async throws { }
    func unlock(passcode: String, for scope: FernletLockScope) async throws -> UnlockResult {
        state = .unlocked(scope: scope)
        return UnlockResult(method: .passcode)
    }
    func unlockWithBiometrics(for scope: FernletLockScope) async throws -> UnlockResult {
        state = .unlocked(scope: scope)
        return UnlockResult(method: .biometric)
    }
    func lock(reason: FernletLockReason) { state = .locked(cooldownDeadline: nil) }
    func revokeUnlockOutside(_ scope: FernletLockScope) {
        guard let current = state.unlockedScope, current != scope else { return }
        lock(reason: .scopeChanged)
    }
    func reset() throws { state = .notConfigured; pending = [] }
    func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws { biometricEnabled = enabled }
    func contentKey(for scope: FernletLockScope) -> SymmetricKey? { nil }
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws {
        if let bufferError { throw bufferError }
        pending.append(payload)
    }
    func drainPendingNarratives() throws -> [PendingNarrativePayload] { pending }
    func purgePendingNarratives() throws {
        if let purgeErrorOnce {
            self.purgeErrorOnce = nil
            throw purgeErrorOnce
        }
        pending = []
    }
}

/// One period store over ONE in-memory sealed stack (so the import's narrative retirement is atomic
/// with its record writes, as on device), an isolated import ledger, and the mock seams.
@MainActor
struct CycleStoreHarness {
    let controller = PrivatePersistenceController(inMemory: true)
    let health = MockCycleHealthService()
    let lock: MockCycleLockService
    let ledgerDefaults = UserDefaults(suiteName: "fernlet.tests.cycleImport.\(UUID().uuidString)") ?? .standard
    let store: PeriodTrackerStore
    let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))

    init(lockState: FernletLockState = .notConfigured, visible: Bool = true) {
        lock = MockCycleLockService(state: lockState)
        store = PeriodTrackerStore(
            healthService: health,
            narrativeRepository: MenstrualNarrativeRepository(controller: controller, defaults: ledgerDefaults),
            lockService: lock,
            calendar: .current,
            recordStore: CycleRecordStore(controller: controller),
            importLedger: CycleLegacyImportLedger(defaults: ledgerDefaults),
            ownSampleFilter: { $0.metadata?[MockCycleHealthService.otherAppKey] == nil }
        )
        store.attachVisibilityGate { visible }
    }

    /// The legacy narrative table on the same stack.
    var narratives: MenstrualNarrativeRepository { MenstrualNarrativeRepository(controller: controller, defaults: ledgerDefaults) }
    /// A second funnel on the same stack, visible, for reading back what was written.
    var records: CycleRecordStore {
        let funnel = CycleRecordStore(controller: controller)
        funnel.attachVisibilityGate { true }
        return funnel
    }
    /// The import markers.
    var ledger: CycleLegacyImportLedger { CycleLegacyImportLedger(defaults: ledgerDefaults) }

    /// Every stored record, read back under the harness key.
    func storedRecords() throws -> [CycleRecord] {
        try records.allRecords(contentKey: key).records
    }

    /// Samples shaped like another app's write of `record` (marked as other, no Fernlet metadata).
    static func otherAppSamples(flow: PeriodFlowLevel, on date: Date) throws -> [HKSample] {
        let record = CycleRecord(event: UserLoggedCycleEvent(date: date, flowLevel: flow))
        return try HealthKitService.periodSamples(for: record).compactMap { sample in
            guard let category = sample as? HKCategorySample else { return nil }
            // HealthKit requires the cycle-start key on every menstrual-flow sample.
            return HKCategorySample(type: category.categoryType, value: category.value, start: category.startDate,
                                    end: category.endDate, metadata: [
                                        MockCycleHealthService.otherAppKey: true,
                                        HKMetadataKeyMenstrualCycleStart: false
                                    ])
        }
    }
}
