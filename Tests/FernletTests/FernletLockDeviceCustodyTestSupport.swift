// FernletLockDeviceCustodyTestSupport.swift
// FernletTests
//
// Shared fixtures for the no-passcode key custody (period-data design 2026-09-30, unit 1): a fake
// Secure Enclave behind the `DeviceContentKeyWrapping` seam, a fault-injecting keychain that can
// refuse one write/delete or "die" after N of them, a scripted device-owner check, and a builder
// that wires all of it into a `FernletLockService` on a `LockTestHarness`'s isolated services.

import CoreData
import CryptoKit
import Foundation
import Security
import Testing
import FernletCrypto
import FernletFoundation
import PrivateStoreCore
@testable import FernletLock

/// A stand-in Secure Enclave for the device-custody row: wraps by remembering, unwraps by lookup,
/// and can be told to be absent, to refuse to wrap, or to answer every unwrap with a fixed outcome.
/// One instance must be shared by every service in a "relaunch" test, exactly as one device has
/// one enclave.
@MainActor
final class FakeDeviceEnclave: DeviceContentKeyWrapping {
    /// Whether the fake reports an enclave at all (false exercises the `FDR1` branch).
    var isAvailable: Bool
    /// When true, `wrapVerified` returns nil — the failure that must never fall back to `FDR1`.
    var refusesToWrap = false
    /// When set, every unwrap answers this instead of looking the blob up.
    var forcedUnwrapOutcome: SecureEnclaveContentKeyWrap.UnwrapOutcome?
    /// Blob → key, the fake's whole "enclave".
    private var sealed: [Data: Data] = [:]

    /// Creates a fake enclave that is (or is not) available.
    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    /// Remembers `contentKey` under a fresh opaque blob.
    func wrapVerified(_ contentKey: Data, service: String) -> Data? {
        guard isAvailable, !refusesToWrap else { return nil }
        let blob = Data("fake-enclave:\(UUID().uuidString)".utf8)
        sealed[blob] = contentKey
        return blob
    }

    /// Looks the blob up, unless an outcome is forced.
    func unwrapResult(_ blob: Data, service: String) -> SecureEnclaveContentKeyWrap.UnwrapOutcome {
        if let forcedUnwrapOutcome { return forcedUnwrapOutcome }
        guard isAvailable else { return .unavailable(errSecNotAvailable) }
        guard let key = sealed[blob] else { return .blobRejected }
        return .recovered(key)
    }
}

/// A keychain seam that performs every write and delete for real until told otherwise, counting
/// them. `failingOperation` refuses exactly that one operation (0-based); `dyingAfter` refuses every
/// operation from that index on — which, with reads left alone, freezes the keychain exactly where a
/// killed process would leave it.
@MainActor
final class FaultInjectingKeychain {
    /// The index of the one operation to refuse, or nil.
    var failingOperation: Int?
    /// Refuse every operation at or after this index, or nil.
    var dyingAfter: Int?
    /// "Die" right after this row's first successful write: every later operation is refused.
    var dyingAfterStoring: LockKeychainKey?
    /// How many writes and deletes have been asked for.
    private(set) var operationCount = 0
    /// Set once `dyingAfterStoring` has fired.
    private var isDead = false

    /// Whether the next operation is refused (and counts it).
    private func refuseNext() -> Bool {
        defer { operationCount += 1 }
        if isDead { return true }
        if let failingOperation, operationCount == failingOperation { return true }
        if let dyingAfter, operationCount >= dyingAfter { return true }
        return false
    }

    /// The store seam.
    func store(_ data: Data, _ key: LockKeychainKey, _ service: String) -> OSStatus {
        guard !refuseNext() else { return errSecNotAvailable }
        let status = KeychainItem.store(data, for: key, service: service)
        if key == dyingAfterStoring, status == errSecSuccess { isDead = true }
        return status
    }

    /// The delete seam.
    func delete(_ key: LockKeychainKey, _ service: String) -> OSStatus {
        guard !refuseNext() else { return errSecNotAvailable }
        return KeychainItem.deleteReportingStatus(account: key.rawValue, service: service)
    }
}

/// A device-owner check that answers from a script and counts how often it was asked.
@MainActor
final class ScriptedDeviceOwnerVerifier: DeviceOwnerVerifying {
    /// The answer every call gets.
    var answer: DeviceOwnerVerification
    /// How many checks ran.
    private(set) var callCount = 0

    /// Creates a verifier that always answers `answer`.
    init(answer: DeviceOwnerVerification) {
        self.answer = answer
    }

    /// Returns the scripted answer.
    func verifyDeviceOwner() async -> DeviceOwnerVerification {
        callCount += 1
        return answer
    }
}

/// Everything a device-custody test needs, on one harness's isolated services.
@MainActor
struct DeviceCustodyFixture {
    /// The isolated keychain / buffer / media services and the fake crypto.
    let harness = LockTestHarness()
    /// The device's one (fake) enclave.
    let enclave: FakeDeviceEnclave
    /// The device's sealed store (in memory, so its row count is this test's alone).
    let persistence = PrivatePersistenceController(inMemory: true)

    /// A fixture whose fake enclave is (or is not) available.
    init(enclaveAvailable: Bool = true) {
        enclave = FakeDeviceEnclave(isAvailable: enclaveAvailable)
    }

    /// A service on this fixture — "one launch". Every argument defaults to the plain device.
    func makeService(
        keychain: FaultInjectingKeychain? = nil,
        owner: ScriptedDeviceOwnerVerifier? = nil,
        unreadableRows: [LockKeychainKey: OSStatus] = [:]
    ) -> FernletLockService {
        let distinguishing: ((LockKeychainKey, String) -> KeychainItem.ReadResult)? = unreadableRows.isEmpty ? nil : { key, service in
            if let status = unreadableRows[key] { return .unreadable(status) }
            return KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: service)
        }
        return FernletLockService(
            keychainService: harness.serviceID,
            sealedContentKeyServices: [harness.sealedContentKeyServiceID],
            mediaKeychainServices: [harness.mediaKeychainServiceID],
            narrativeBufferScope: harness.narrativeBufferScope,
            dateProvider: harness.clock,
            uptimeProvider: harness.uptime,
            cryptoProvider: harness.crypto,
            keychainStore: keychain.map { faulty in { data, key, service in faulty.store(data, key, service) } },
            keychainLoadDistinguishing: distinguishing,
            keychainDelete: keychain.map { faulty in { key, service in faulty.delete(key, service) } },
            deviceOwnerVerifier: owner ?? ScriptedDeviceOwnerVerifier(answer: .failed),
            privatePersistenceController: persistence,
            deviceKeyWrapper: enclave
        )
    }

    /// Raw read of one lock row.
    func row(_ key: LockKeychainKey) -> Data? {
        KeychainItem.load(for: key, service: harness.serviceID)
    }

    /// Plants one sealed row in the fixture's store, so `sealedRowCount()` is non-zero.
    func plantSealedRow(sealedUnder contentKey: SymmetricKey) throws {
        let context = persistence.container.viewContext
        let object = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
        object.setValue(UUID(), forKey: "id")
        object.setValue("2026-09-30", forKey: "dayKey")
        object.setValue(Date(), forKey: "eventDate")
        object.setValue(try Self.seal("an entry", under: contentKey), forKey: "noteCiphertext")
        object.setValue(Date(), forKey: "createdAt")
        object.setValue(Date(), forKey: "updatedAt")
        try context.save()
    }

    /// Seals `text` the way a sealed column does, under `contentKey`.
    static func seal(_ text: String, under contentKey: SymmetricKey) throws -> Data {
        try ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1)
            .sealString(text, contentKey: contentKey)
    }

    /// Opens a column sealed by ``seal(_:under:)``; nil when `contentKey` is not the sealing key.
    static func open(_ sealed: Data, under contentKey: SymmetricKey) -> String? {
        do {
            return try ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1)
                .openString(sealed, contentKey: contentKey)
        } catch {
            return nil
        }
    }

    /// Tears down every keychain row, the buffer, and this service's enclave key.
    func cleanup() {
        harness.cleanup()
        _ = SecureEnclaveContentKeyWrap.deleteKey(service: harness.serviceID)
    }
}

/// The resident hub key's raw bytes, or nil.
@MainActor
func hubKeyBytes(_ service: FernletLockService) -> Data? {
    service.contentKey(for: .privateHub).map { $0.withUnsafeBytes { Data($0) } }
}

/// Opens the hub by whatever route the DERIVED state offers — the tap when no passcode is
/// configured, the passcode when one is — and returns the key it released. The "next launch"
/// half of every interrupted-transition assertion (design invariant I6).
@MainActor
func openHubByItsOwnPath(_ service: FernletLockService, passcode: String) async throws -> Data? {
    switch service.state {
    case .notConfigured:
        try service.openWithoutPasscode(for: .privateHub, allowingMint: false)
    case .locked:
        _ = try await service.unlock(passcode: passcode, for: .privateHub)
    case .unlocked, .openedWithoutPasscode:
        break
    }
    return hubKeyBytes(service)
}
