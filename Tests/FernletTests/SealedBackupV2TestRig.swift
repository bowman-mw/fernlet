//
//  SealedBackupV2TestRig.swift
//  FernletTests
//
//  The Sealed backup v2 test rig (journal and intimacy Sealed backup v2 design 2026-09-30, §4–§5):
//  one iPhone per `PeriodBackupDevice` — its own sealed cycle records, host bookkeeping, rollback
//  generation store, writer tag and device-only signing key — over a cloud database and an escrow key
//  it shares with the other iPhones of a test (the key iCloud Keychain would sync), plus the transport
//  doubles the engine tests interpose.
//

import ProximityKit
import CloudKit
import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import PrivateHealthStore
import PrivateStoreCore
import Testing
@testable import Fernlet

/// One iPhone for the period backup v2 tests.
@MainActor
final class PeriodBackupDevice {
    let host: FakeSealedBackupHost
    /// This iPhone's sealed store.
    let controller: PrivatePersistenceController
    let records: CycleRecordStore
    let generationDefaults: UserDefaults
    let coordinator: SealedBackupCoordinator
    /// This install's writer tag (32 hex, derived from the name a test gives the iPhone).
    let writer: String
    /// This iPhone's keychain: the shared escrow key and its own signing key.
    let keychainService: String
    /// The background-task assertions the commits took.
    let backgroundTasks = RecordingBackgroundTasks()
    private let cloud: FakeSealedBackupCloud
    private let preferencesBox: PeriodBackupPreferencesBox

    /// The storage preferences the coordinator reads — settable mid-test (iCloud sync turned back on).
    var preferences: StoragePreferences {
        get { preferencesBox.value }
        set { preferencesBox.value = newValue }
    }

    /// The Private tab's key on this iPhone.
    var key: SymmetricKey { host.sealedBackupContentKey ?? SymmetricKey(size: .bits256) }

    /// The v2 engine every period pass runs on.
    var engine: SealedBackupV2Engine { coordinator.engine }

    /// The set this install has accepted (install-bound), if any.
    var acceptedStamp: SealedBackupHeadStamp? {
        host.sealedBackupBookkeeping.acceptedHead(.periodData, installTag: writer)?.stamp
    }

    /// Creates an iPhone with the period backup on, iCloud sync on and the upload owed.
    ///
    /// - Parameters:
    ///   - cloud: The shared cloud.
    ///   - name: This install's name; its writer tag is ``tag(_:)`` of it.
    ///   - resolved: Whether this install's period restore has already resolved.
    ///   - database: A transport to interpose; the cloud's own by default.
    ///   - keychainService: The identity's keychain as-is (no shared escrow key copied in) — another
    ///     account, an iPhone without iCloud Keychain, or the same install before and after a reset.
    ///     Nil: a fresh keychain for this iPhone holding a copy of the cloud's escrow key.
    ///   - preferences: The storage preferences the coordinator reads.
    ///   - clock: The engine's clock (spacing tests).
    init(
        cloud: FakeSealedBackupCloud,
        writer name: String,
        resolved: Bool = false,
        database: (any CloudKitRecordDatabase)? = nil,
        keychainService: String? = nil,
        preferences: StoragePreferences = PeriodBackupDevice.backupOn,
        clock: (() -> Date)? = nil
    ) {
        self.cloud = cloud
        let host = FakeSealedBackupHost()
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        self.host = host
        let controller = PrivatePersistenceController(inMemory: true)
        self.controller = controller
        let records = CycleRecordStore(controller: controller)
        self.records = records
        let generationDefaults = UserDefaults(suiteName: "fernlet.tests.periodGeneration.\(UUID().uuidString)") ?? .standard
        self.generationDefaults = generationDefaults
        let service = keychainService ?? Self.phoneKeychain(sharing: cloud)
        self.keychainService = service
        let writer = Self.tag(name)
        self.writer = writer
        let transport = database ?? cloud.database
        let preferencesBox = PeriodBackupPreferencesBox(preferences)
        self.preferencesBox = preferencesBox
        let tasks = backgroundTasks
        coordinator = SealedBackupCoordinator(
            host: host,
            identityFactory: { IdentityService(keychainService: service) },
            serviceFactory: { identity in
                SealedBackupService(
                    cloudDataService: Self.cloudDataService(transport),
                    identityService: identity,
                    generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
                )
            },
            preferencesProvider: { preferencesBox.value },
            periodRecordStore: records,
            writerTagProvider: { writer },
            clock: clock,
            backgroundTasks: tasks
        )
        if resolved { host.sealedBackupBookkeeping.markRestoreResolved(.periodData) }
    }

    /// Seals `records` straight into this iPhone's store (under `key`, this iPhone's by default),
    /// through a temporarily open gate — the store's own gate (the host's visibility, installed by the
    /// coordinator) is put back afterwards.
    func seed(_ seeded: [CycleRecord], key: SymmetricKey? = nil) throws {
        let previous = records.isVisible
        records.attachVisibilityGate { true }
        defer { records.attachVisibilityGate(previous) }
        _ = try records.upsertMerged(seeded, retiringNarrativeIDs: [], contentKey: key ?? self.key)
    }

    /// Writes a v1 period set (bare `[MenstrualNarrative]`) the way an earlier build did — under this
    /// iPhone's identity (its signing key) and generation store.
    func writeV1Set(_ narratives: [MenstrualNarrative]) async throws {
        let identity = IdentityService(keychainService: keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        let service = SealedBackupService(
            cloudDataService: Self.cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
        )
        let chunk = try JSONEncoder().encode(narratives)
        try await service.reconcileChunked(payloadType: .periodData, chunkCount: 1) { _ in chunk }
    }

    /// The writer tag an iPhone named `name` writes under (a real tag's shape: 32 lowercase hex).
    static func tag(_ name: String) -> String {
        SealedBackupWriterTag.tag(forBinding: Data(name.utf8))
    }

    /// The stamp of a set the iPhone named `name` wrote at `generation`.
    static func stamp(_ name: String, _ generation: Int64) -> SealedBackupHeadStamp {
        SealedBackupHeadStamp(writer: tag(name), generation: generation)
    }

    /// iCloud sync on, the period backup on, its upload owed.
    nonisolated static let backupOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupPeriodEnabled: true, sealedBackupPeriodReuploadDeferred: true
    )

    /// A fresh in-memory cycle-record funnel.
    static func makeRecordStore() -> CycleRecordStore {
        CycleRecordStore(controller: PrivatePersistenceController(inMemory: true))
    }

    /// A logged record on day `day` of a fixed calendar.
    static func record(day: Int, note: String = "n") -> CycleRecord {
        let base = Date(timeIntervalSinceReferenceDate: 790_000_000)
        return CycleRecord(
            event: UserLoggedCycleEvent(date: base.addingTimeInterval(Double(day) * 86_400), flowLevel: .light, note: note),
            now: base
        )
    }

    /// One v2 chunk plaintext of `records` (a test writer and set).
    static func v2Chunk(_ records: [CycleRecord], total: Int? = nil) throws -> Data {
        try SealedBackupV2Format.encode(SealedBackupV2Envelope(writer: tag("w"), set: tag("set"), total: total, records: records))
    }

    /// A cloud with the escrow key provisioned, as on an account whose iCloud Keychain synced it.
    static func makeCloud() throws -> FakeSealedBackupCloud {
        let cloud = FakeSealedBackupCloud(
            keychainService: "com.fernlet.period-v2.\(UUID().uuidString)",
            generationDefaults: UserDefaults(suiteName: "fernlet.tests.periodCloud.\(UUID().uuidString)") ?? .standard
        )
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return cloud
    }

    /// A fresh keychain for one iPhone holding a copy of the cloud's escrow key — so its identity
    /// adopts that key and mints its OWN device-only signing key, as a second iPhone does.
    static func phoneKeychain(sharing cloud: FakeSealedBackupCloud) -> String {
        let service = "\(cloud.keychainService).phone.\(UUID().uuidString)"
        cloud.phoneKeychainServices.append(service)
        for item in KeychainItem.loadAll(service: cloud.keychainService) where item.account.hasPrefix("backupEscrowPrivateKey") {
            let status = KeychainItem.store(item.data, account: item.account, service: service,
                                            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            #expect(status == errSecSuccess, "the escrow key could not be copied to the iPhone's keychain")
        }
        return service
    }

    /// The head of the period set in `cloud`, read the way E2 reads it.
    static func cloudHead(_ cloud: FakeSealedBackupCloud, keychainService: String? = nil) async throws -> SealedBackupHeadStamp? {
        let reader = try reader(cloud, keychainService: keychainService)
        guard let record = try await reader.fetchHeadRecord(payloadType: .periodData) else { return nil }
        let plaintext = try reader.open(record)
        guard !SealedBackupV2Format.isV1(plaintext) else {
            return SealedBackupHeadStamp(writer: SealedBackupHeadStamp.v1Writer, generation: record.generation)
        }
        return SealedBackupHeadStamp(writer: try SealedBackupV2Format.header(of: plaintext).writer, generation: record.generation)
    }

    /// Every record id in the period set the head in `cloud` names.
    static func cloudRecordIDs(_ cloud: FakeSealedBackupCloud, keychainService: String? = nil) async throws -> Set<UUID> {
        let reader = try reader(cloud, keychainService: keychainService)
        guard let head = try await reader.fetchHeadRecord(payloadType: .periodData) else { return [] }
        let plaintext = try reader.open(head)
        let adapter = CycleRecordBackupAdapter(store: makeRecordStore())
        if SealedBackupV2Format.isV1(plaintext) {
            let chunks = try await reader.restoreChunks(payloadType: .periodData) ?? []
            return Set(try chunks.flatMap { try adapter.decodeV1Chunk($0) }.map(\.id))
        }
        let set = try SealedBackupV2Format.header(of: plaintext).set
        let suffix = try await reader.fetchSuffixRecords(payloadType: .periodData, chunkCount: head.chunkCount, setTag: set)
        let plaintexts = [plaintext] + (try suffix.map { try reader.open($0) })
        let decoded = try plaintexts.flatMap { try JSONDecoder().decode(SealedBackupV2Envelope<CycleRecord>.self, from: $0).records }
        return Set(decoded.map(\.id))
    }

    /// A read-only service over `cloud` (its escrow key, or the keys in `keychainService`) with its own
    /// fresh rollback mark.
    static func reader(_ cloud: FakeSealedBackupCloud, keychainService: String? = nil) throws -> SealedBackupService {
        let identity = IdentityService(keychainService: keychainService ?? cloud.keychainService)
        try identity.ensureProvisioned()
        _ = identity.loadBackupEscrowKeyForOpen()
        return SealedBackupService(
            cloudDataService: cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(
                defaults: UserDefaults(suiteName: "fernlet.tests.periodReader.\(UUID().uuidString)") ?? .standard
            )
        )
    }

    static func cloudDataService(_ database: any CloudKitRecordDatabase) -> CloudKitDataService {
        CloudKitDataService(
            accountProvider: AlwaysAvailableAccountProvider(),
            database: database,
            zoneID: CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
            isCloudKitSyncEnabled: { false }
        )
    }
}

/// Background-task assertions, recorded rather than taken (no UIKit app state in a unit test).
@MainActor
final class RecordingBackgroundTasks: SealedBackupBackgroundTaskAsserting {
    /// Tokens begun and not yet ended.
    private(set) var open: Set<Int> = []
    /// How many assertions were ever begun.
    private(set) var begun = 0

    func begin(_ name: String, onExpiry: @escaping @MainActor () -> Void) -> Int {
        begun += 1
        open.insert(begun)
        return begun
    }

    func end(_ token: Int) {
        open.remove(token)
    }
}

/// A clock a test moves by hand.
@MainActor
final class ManualClock {
    /// Now.
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Moves now forward.
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// The storage preferences one ``PeriodBackupDevice``'s coordinator reads, boxed so a test can change
/// them between calls.
final class PeriodBackupPreferencesBox {
    /// The preferences.
    var value: StoragePreferences

    /// Boxes `value`.
    init(_ value: StoragePreferences) { self.value = value }
}

/// A transport that holds its first save until the test releases it — an upload still in flight.
final class HoldingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    private var holdsNextSave = true
    private var heldSave: CheckedContinuation<Void, Never>?
    /// Saves that landed.
    private(set) var savedCount = 0
    /// Whether a save is waiting for ``releaseHeldSave()``.
    var isHoldingSave: Bool { heldSave != nil }

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
        try await base.saveRecords(records)
        savedCount += records.count
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }

    /// Lets the held save land.
    func releaseHeldSave() {
        heldSave?.resume()
        heldSave = nil
    }
}

/// A transport that runs `onFirstSave` (on the main actor) before its first save lands — a record
/// logged, a key dropped or a wipe begun while the export is uploading.
final class InterruptingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    /// Runs once, before the first save.
    var onFirstSave: (@MainActor () -> Void)?

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        if let hook = onFirstSave {
            onFirstSave = nil
            hook()
        }
        try await base.saveRecords(records)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }
}

/// A transport whose FIRST head save lands but answers with an error — CloudKit's "the request timed
/// out" after the server committed it — so the export's own bookkeeping never runs for a set that is
/// in iCloud.
final class LandedButFailedCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    private var failsNextHeadSave = true

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        try await base.saveRecords(records)
        if failsNextHeadSave, records.contains(where: { !$0.recordID.recordName.contains(".chunk.") }) {
            failsNextHeadSave = false
            throw CKError(.networkFailure)
        }
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }
}

/// A transport that holds its first head FETCH until released — a restore or export suspended in
/// CloudKit while the test changes the world around it (a wipe, a reset, a hide, a turn-off).
final class SuspendingFetchCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    private var holdsNextFetch = true
    private var heldFetch: CheckedContinuation<Void, Never>?
    /// Whether a fetch is waiting for ``releaseHeldFetch()``.
    var isHoldingFetch: Bool { heldFetch != nil }
    /// Saves that landed after the hold was set.
    private(set) var savedNames: [String] = []

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        if holdsNextFetch {
            holdsNextFetch = false
            await withCheckedContinuation { heldFetch = $0 }
        }
        return try await base.records(for: recordIDs)
    }
    func saveRecords(_ records: [CKRecord]) async throws {
        try await base.saveRecords(records)
        savedNames += records.map(\.recordID.recordName)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }

    /// Lets the held fetch return.
    func releaseHeldFetch() {
        heldFetch?.resume()
        heldFetch = nil
    }
}

/// Waits (bounded) until `condition` holds, yielding to let other tasks run.
@MainActor
func yieldUntil(_ condition: () -> Bool, maxYields: Int = 5_000) async -> Bool {
    for _ in 0..<maxYields where !condition() { await Task.yield() }
    return condition()
}
