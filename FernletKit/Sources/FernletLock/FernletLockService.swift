// FernletLockService.swift
// Fernlet
//
// Scrypt KDF via krzyzanowskim/CryptoSwift (https://github.com/krzyzanowskim/CryptoSwift).
// Memory-hard KDF, no PBKDF2 fallback.

import Foundation
import FernletFoundation
import CryptoKit
import Security
import LocalAuthentication
import Combine
import OSLog
import CryptoSwift
import Observation
import FernletDomainModel
import PrivateStoreCore
import PrivateHealthStore

// MARK: - Public types

@MainActor
public protocol FernletLockServicing: PeriodLockContext {
    var state: FernletLockState { get }
    var statePublisher: AnyPublisher<FernletLockState, Never> { get }
    var requiresReset: Bool { get }
    var biometricEnabled: Bool { get }
    var biometricType: LABiometryType { get }
    var credentialKind: FernletLockCredentialKind? { get }
    var currentAttemptCount: Int { get }

    func configure(credential: FernletLockCredential) async throws
    func changeCredential(current: String, new: FernletLockCredential) async throws
    func unlock(passcode: String) async throws -> UnlockResult
    func unlockWithBiometrics() async throws -> UnlockResult
    func lock(reason: FernletLockReason)
    func reset() throws
    func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws
    func contentKey() -> SymmetricKey?
}

extension FernletLockServicing {
    // Satisfies the narrow `PeriodLockContext.isLockConfigured` seam without each conformer
    // reimplementing it: a lock is "configured" once it leaves the `.notConfigured` state.
    public var isLockConfigured: Bool { state != .notConfigured }
}

public enum FernletLockState: Equatable {
    case notConfigured
    case locked(cooldownDeadline: Date?)
    case unlocked
}

public enum FernletLockCredentialKind: String, Codable {
    case pin4, pin6, alphanumeric
}

public enum FernletLockCredential {
    case pin4(String)
    case pin6(String)
    case alphanumeric(String)

    public var kind: FernletLockCredentialKind {
        switch self {
        case .pin4: .pin4
        case .pin6: .pin6
        case .alphanumeric: .alphanumeric
        }
    }

    public var rawValue: String {
        switch self {
        case .pin4(let value), .pin6(let value), .alphanumeric(let value): value
        }
    }

    public func validate() throws {
        switch self {
        case .pin4(let value):
            guard value.count == 4, value.allSatisfy(\.isNumber) else {
                throw FernletLockError.invalidCredential("PIN must be exactly 4 digits")
            }
        case .pin6(let value):
            guard value.count == 6, value.allSatisfy(\.isNumber) else {
                throw FernletLockError.invalidCredential("PIN must be exactly 6 digits")
            }
        case .alphanumeric(let value):
            guard value.count >= 8, value.count <= 64 else {
                throw FernletLockError.invalidCredential("Password must be 8-64 characters")
            }
        }
    }
}

public enum FernletLockReason {
    case viewDisappeared, background, protectedDataUnavailable, manual, failedAttempts

    var auditLabel: String {
        switch self {
        case .viewDisappeared: "viewDisappeared"
        case .background: "background"
        case .protectedDataUnavailable: "protectedDataUnavailable"
        case .manual: "manual"
        case .failedAttempts: "failedAttempts"
        }
    }
}

public enum UnlockMethod {
    case passcode, biometric
}

public struct UnlockResult {
    public let method: UnlockMethod

    public init(method: UnlockMethod) {
        self.method = method
    }
}

// MARK: - Cryptographic primitives

/// Narrowed from `public` to module-internal (WI-7, Docs/Security-Hardening-Plan-2026-06-27.md): these
/// key-wrapping/derivation primitives have no callers outside the FernletLock module (only its own
/// provider/service and the crypto unit tests, which `@testable import FernletLock`). Least privilege
/// keeps the lock's raw crypto off the package's public API surface.
enum FernletLockCrypto {
    nonisolated static let scryptN: Int = 65536
    nonisolated static let scryptR: Int = 8
    nonisolated static let scryptP: Int = 1
    nonisolated static let keyLength: Int = 32
    nonisolated static let saltLength: Int = 16
    nonisolated static let aeadNonceLength: Int = 12
    nonisolated static let aeadTagLength: Int = 16

    nonisolated static func deriveVerifier(passcode: String, salt: Data, n: Int = scryptN) async throws -> Data {
        let password = Array(passcode.utf8)
        let saltBytes = Array(salt)
        let dkLen = keyLength
        let N = n
        let r = scryptR
        let p = scryptP
        return try await Task.detached(priority: .userInitiated) {
            let bytes = try Scrypt(
                password: password,
                salt: saltBytes,
                dkLen: dkLen,
                N: N,
                r: r,
                p: p
            ).calculate()
            return Data(bytes)
        }.value
    }

    nonisolated static func generateSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes) == errSecSuccess else {
            throw FernletLockError.internalError("salt generation failed")
        }
        return Data(bytes)
    }

    nonisolated static func generateContentKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    nonisolated static func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrappingKey = SymmetricKey(data: wrappingKeyData)
        return try ChaChaPoly.seal(contentKey, using: wrappingKey).combined
    }

    nonisolated static func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrappingKey = SymmetricKey(data: wrappingKeyData)
        let sealedBox = try ChaChaPoly.SealedBox(combined: wrappedContentKey)
        return try ChaChaPoly.open(sealedBox, using: wrappingKey)
    }

    nonisolated static func deriveColumnKey(contentKey: Data, info: String, outputByteCount: Int) -> Data {
        let inputKey = SymmetricKey(data: contentKey)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            info: Data(info.utf8),
            outputByteCount: outputByteCount
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
}

@MainActor
public protocol FernletLockCryptoProviding: AnyObject {
    func generateSalt() throws -> Data
    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data
    func generateContentKey() -> Data
    func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data
    func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data
}

final class SystemFernletLockCryptoProvider: FernletLockCryptoProviding {
    func generateSalt() throws -> Data {
        try FernletLockCrypto.generateSalt()
    }

    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data {
        try await FernletLockCrypto.deriveVerifier(passcode: passcode, salt: salt, n: n)
    }

    func generateContentKey() -> Data {
        FernletLockCrypto.generateContentKey()
    }

    func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data {
        try FernletLockCrypto.wrapContentKey(contentKey, using: wrappingKeyData)
    }

    func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data {
        try FernletLockCrypto.unwrapContentKey(wrappedContentKey, using: wrappingKeyData)
    }
}

private func cooldownDuration(for level: Int) -> TimeInterval {
    switch level {
    case 1: 60
    case 2: 900
    case 3: 3600
    case 4: 14400
    default: 60
    }
}

public enum LockKeychainKey: String {
    case salt = "com.fernlet.lock.salt"
    case verifier = "com.fernlet.lock.verifier"
    case kind = "com.fernlet.lock.kind"
    case wrappedContentKey = "com.fernlet.lock.wrappedContentKey"
    case biometricBypass = "com.fernlet.lock.biometricBypass"
    case biometricEnabledFlag = "com.fernlet.lock.biometricEnabled"
    case cooldownDeadline = "com.fernlet.lock.cooldownDeadline"
    case cooldownMonotonicAnchor = "com.fernlet.lock.cooldownMonotonicAnchor"
    case cooldownDurationSeconds = "com.fernlet.lock.cooldownDurationSeconds"
    case attemptCount = "com.fernlet.lock.attemptCount"
    case cooldownLevel = "com.fernlet.lock.cooldownLevel"
    case requiresReset = "com.fernlet.lock.requiresReset"
    case scryptN = "com.fernlet.lock.scryptN"
}

@MainActor
public protocol FernletDateProviding: AnyObject {
    var now: Date { get }
}

final class SystemFernletDateProvider: FernletDateProviding {
    var now: Date { Date() }
}

@MainActor
public protocol FernletUptimeProviding: AnyObject {
    var systemUptime: TimeInterval { get }
}

final class SystemFernletUptimeProvider: FernletUptimeProviding {
    var systemUptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

extension KeychainItem {
    @discardableResult
    static func store(_ data: Data, for key: LockKeychainKey, service: String) -> OSStatus {
        store(
            data,
            account: key.rawValue,
            service: service,
            // WhenUnlockedThisDeviceOnly: items survive device passcode removal instead of being
            // silently deleted, preventing unexpected notConfigured state and content key loss.
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    public static func load(for key: LockKeychainKey, service: String) -> Data? {
        load(account: key.rawValue, service: service)
    }

    public static func delete(for key: LockKeychainKey, service: String) {
        delete(account: key.rawValue, service: service)
    }

    static func accessControl(for flag: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            flag,
            &cfError
        ) else {
            throw cfError?.takeRetainedValue() as Error? ?? FernletLockError.internalError("access control creation failed")
        }
        return access
    }

    static func storeBiometricBypass(_ data: Data, service: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.biometricBypass.rawValue,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let access = try accessControl(for: .biometryCurrentSet)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.biometricBypass.rawValue,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FernletLockError.keychainFailure(operation: "store biometric bypass", status: status)
        }
    }

    static func loadBiometricBypassSync(prompt: String, service: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = prompt

        let access = try accessControl(for: .biometryCurrentSet)
        let authGroup = DispatchSemaphore(value: 0)
        let authLock = NSLock()
        var authSucceeded = false
        var authError: Error?
        context.evaluateAccessControl(access, operation: .useItem, localizedReason: prompt) { success, error in
            authLock.lock()
            authSucceeded = success
            authError = error
            authLock.unlock()
            authGroup.signal()
        }
        authGroup.wait()

        authLock.lock()
        let didAuthenticate = authSucceeded
        let authenticationError = authError
        authLock.unlock()
        guard didAuthenticate else {
            throw authenticationError ?? FernletLockError.biometricFailed
        }

        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.biometricBypass.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw FernletLockError.biometricFailed
        }
        return data
    }
}

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var result: UInt8 = 0
    for (x, y) in zip(a, b) {
        result |= x ^ y
    }
    return result == 0
}

@MainActor
@Observable
public final class FernletLockService: @MainActor FernletLockServicing {
    @ObservationIgnored
    private let stateSubject = PassthroughSubject<FernletLockState, Never>()

    public private(set) var state: FernletLockState = .notConfigured {
        didSet { stateSubject.send(state) }
    }
    private(set) var hasAutoPromptedBiometricForCurrentLockSession = false
    public private(set) var isPerformingBiometricUnlock = false

    public var statePublisher: AnyPublisher<FernletLockState, Never> { stateSubject.eraseToAnyPublisher() }

    public let keychainService: String
    @ObservationIgnored private let dateProvider: FernletDateProviding
    @ObservationIgnored private let uptimeProvider: FernletUptimeProviding
    @ObservationIgnored private let cryptoProvider: FernletLockCryptoProviding
    @ObservationIgnored private let biometricBypassLoader: ((String, String) throws -> Data)?
    @ObservationIgnored private let keychainStore: (Data, LockKeychainKey, String) -> OSStatus
    @ObservationIgnored private let keychainLoad: (LockKeychainKey, String) -> Data?
    @ObservationIgnored private let privatePersistenceController: PrivatePersistenceController
    @ObservationIgnored private var _contentKey: SymmetricKey?
    @ObservationIgnored private let buffer = PendingNarrativeBuffer()

    public init(
        keychainService: String = KeychainItem.productionService,
        dateProvider: FernletDateProviding? = nil,
        uptimeProvider: FernletUptimeProviding? = nil,
        cryptoProvider: FernletLockCryptoProviding? = nil,
        biometricBypassLoader: ((String, String) throws -> Data)? = nil,
        keychainStore: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        keychainLoad: ((LockKeychainKey, String) -> Data?)? = nil,
        privatePersistenceController: PrivatePersistenceController? = nil
    ) {
        self.keychainService = keychainService
        self.dateProvider = dateProvider ?? SystemFernletDateProvider()
        self.uptimeProvider = uptimeProvider ?? SystemFernletUptimeProvider()
        self.cryptoProvider = cryptoProvider ?? SystemFernletLockCryptoProvider()
        self.biometricBypassLoader = biometricBypassLoader
        self.keychainStore = keychainStore ?? { data, key, service in
            KeychainItem.store(data, for: key, service: service)
        }
        self.keychainLoad = keychainLoad ?? { key, service in
            KeychainItem.load(for: key, service: service)
        }
        self.privatePersistenceController = privatePersistenceController ?? .shared

        if self.keychainLoad(.salt, keychainService) == nil {
            state = .notConfigured
        } else {
            state = .locked(cooldownDeadline: activeCooldownDeadline())
        }
    }

    public var requiresReset: Bool {
        keychainLoad(.requiresReset, keychainService) != nil
    }

    public var biometricEnabled: Bool {
        keychainLoad(.biometricEnabledFlag, keychainService) != nil
    }

    public var biometricType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
    }

    public var credentialKind: FernletLockCredentialKind? {
        guard let data = keychainLoad(.kind, keychainService),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return FernletLockCredentialKind(rawValue: string)
    }

    public var currentAttemptCount: Int {
        guard let data = keychainLoad(.attemptCount, keychainService),
              let byte = data.first else { return 0 }
        return Int(byte)
    }

    public func consumeAutoBiometricPromptOpportunity() -> Bool {
        guard !hasAutoPromptedBiometricForCurrentLockSession else { return false }
        hasAutoPromptedBiometricForCurrentLockSession = true
        return true
    }

    public func configure(credential: FernletLockCredential) async throws {
        try credential.validate()

        let saltData = try cryptoProvider.generateSalt()
        let derivedKey = try await cryptoProvider.deriveVerifier(passcode: credential.rawValue, salt: saltData, n: FernletLockCrypto.scryptN)
        let contentKeyData = cryptoProvider.generateContentKey()
        let wrappedContentKey = try cryptoProvider.wrapContentKey(contentKeyData, using: derivedKey)

        try storeVerified(saltData, for: .salt)
        try storeVerified(derivedKey, for: .verifier)
        try storeVerified(Data(credential.kind.rawValue.utf8), for: .kind)
        try storeVerified(wrappedContentKey, for: .wrappedContentKey)
        var configuredN = Int32(FernletLockCrypto.scryptN)
        try storeVerified(Data(bytes: &configuredN, count: MemoryLayout<Int32>.size), for: .scryptN)
        KeychainItem.delete(for: .biometricBypass, service: keychainService)
        KeychainItem.delete(for: .biometricEnabledFlag, service: keychainService)
        KeychainItem.delete(for: .cooldownDeadline, service: keychainService)
        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: keychainService)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: keychainService)
        KeychainItem.delete(for: .attemptCount, service: keychainService)
        KeychainItem.delete(for: .cooldownLevel, service: keychainService)
        KeychainItem.delete(for: .requiresReset, service: keychainService)

        _contentKey = SymmetricKey(data: contentKeyData)
        state = .unlocked
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.configured", context: ["kind": credential.kind.rawValue])
    }

    public func changeCredential(current: String, new: FernletLockCredential) async throws {
        try new.validate()
        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService),
              let wrappedData = KeychainItem.load(for: .wrappedContentKey, service: keychainService) else {
            throw FernletLockError.notConfigured
        }

        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: current, salt: saltData, n: storedScryptN())
        guard constantTimeEqual(computedVerifier, storedVerifier) else {
            throw FernletLockError.invalidPasscode
        }

        let contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
        let newSalt = try cryptoProvider.generateSalt()
        let newDerivedKey = try await cryptoProvider.deriveVerifier(passcode: new.rawValue, salt: newSalt, n: FernletLockCrypto.scryptN)
        let newWrappedContentKey = try cryptoProvider.wrapContentKey(contentKeyData, using: newDerivedKey)

        try storeVerified(newSalt, for: .salt)
        try storeVerified(newDerivedKey, for: .verifier)
        try storeVerified(Data(new.kind.rawValue.utf8), for: .kind)
        try storeVerified(newWrappedContentKey, for: .wrappedContentKey)
        var newN = Int32(FernletLockCrypto.scryptN)
        try storeVerified(Data(bytes: &newN, count: MemoryLayout<Int32>.size), for: .scryptN)

        if KeychainItem.load(for: .biometricEnabledFlag, service: keychainService) != nil {
            try KeychainItem.storeBiometricBypass(contentKeyData, service: keychainService)
        }
        if case .unlocked = state {
            _contentKey = SymmetricKey(data: contentKeyData)
        }

        FernletAuditLog.log("lock.kindChanged", context: ["newKind": new.kind.rawValue])
    }

    public func unlock(passcode: String) async throws -> UnlockResult {
        guard !requiresReset else { throw FernletLockError.resetRequired }
        if let deadline = activeCooldownDeadline() {
            state = .locked(cooldownDeadline: deadline)
            throw FernletLockError.cooldownActive(deadline: deadline)
        }

        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService),
              let wrappedData = KeychainItem.load(for: .wrappedContentKey, service: keychainService) else {
            throw FernletLockError.notConfigured
        }

        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
        guard constantTimeEqual(computedVerifier, storedVerifier) else {
            try recordFailedAttempt()
            FernletAuditLog.log("lock.failedAttempt", context: ["cooldownLevel": "\(loadCooldownLevel())"])
            throw FernletLockError.invalidPasscode
        }

        let contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
        clearAttemptState()
        _contentKey = SymmetricKey(data: contentKeyData)
        state = .unlocked
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.released", context: ["method": "passcode"])
        return UnlockResult(method: .passcode)
    }

    public func unlockWithBiometrics() async throws -> UnlockResult {
        guard !requiresReset else { throw FernletLockError.resetRequired }
        isPerformingBiometricUnlock = true
        defer { isPerformingBiometricUnlock = false }

        let contentKeyData: Data
        if let biometricBypassLoader {
            contentKeyData = try biometricBypassLoader("Unlock Fernlet", keychainService)
        } else {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw FernletLockError.biometricNotAvailable
            }

            let service = keychainService
            contentKeyData = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try KeychainItem.loadBiometricBypassSync(prompt: "Unlock Fernlet", service: service)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        _contentKey = SymmetricKey(data: contentKeyData)
        state = .unlocked
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.released", context: ["method": "biometric"])
        return UnlockResult(method: .biometric)
    }

    public func lock(reason: FernletLockReason) {
        guard case .unlocked = state else { return }
        scrubContentKey()
        state = .locked(cooldownDeadline: activeCooldownDeadline())
        FernletAuditLog.log("lock.engaged", context: ["reason": reason.auditLabel])
    }

    public func reset() throws {
        KeychainItem.deleteAll(service: keychainService)
        try buffer.purge()
        try privatePersistenceController.purgeEncryptedEntities()
        scrubContentKey()
        state = .notConfigured
        hasAutoPromptedBiometricForCurrentLockSession = false
        isPerformingBiometricUnlock = false
        FernletAuditLog.log("lock.reset")
    }

    public func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws {
        if enabled {
            guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
                  let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService),
                  let wrappedData = KeychainItem.load(for: .wrappedContentKey, service: keychainService) else {
                throw FernletLockError.notConfigured
            }

            let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
            guard constantTimeEqual(computedVerifier, storedVerifier) else {
                throw FernletLockError.invalidPasscode
            }

            let contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
            try KeychainItem.storeBiometricBypass(contentKeyData, service: keychainService)
            try storeVerified(Data([1]), for: .biometricEnabledFlag)
        } else {
            KeychainItem.delete(for: .biometricBypass, service: keychainService)
            KeychainItem.delete(for: .biometricEnabledFlag, service: keychainService)
        }
    }

    public func contentKey() -> SymmetricKey? {
        _contentKey
    }

    public func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws {
        try buffer.append(payload)
    }

    public func drainPendingNarratives() throws -> [PendingNarrativePayload] {
        try buffer.drainAll()
    }

    public func purgePendingNarratives() throws {
        try buffer.purge()
    }

    private func scrubContentKey() {
        _contentKey = nil
    }

    private func storeVerified(_ data: Data, for key: LockKeychainKey) throws {
        try verifyStatus(keychainStore(data, key, keychainService), operation: "store \(key.rawValue)")
        guard keychainLoad(key, keychainService) == data else {
            throw FernletLockError.keychainFailure(operation: "read back \(key.rawValue)", status: errSecItemNotFound)
        }
    }

    private func verifyStatus(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            throw FernletLockError.keychainFailure(operation: operation, status: status)
        }
    }

    private func activeCooldownDeadline() -> Date? {
        guard let data = keychainLoad(.cooldownDeadline, keychainService),
              let timeInterval = data.toDouble else { return nil }
        let wallClockDeadline = Date(timeIntervalSinceReferenceDate: timeInterval)
        let wallClockRemaining = wallClockDeadline.timeIntervalSince(dateProvider.now)

        let effectiveRemaining: TimeInterval
        switch monotonicRemainingCooldownSeconds() {
        case .available(let monotonicRemaining):
            effectiveRemaining = max(wallClockRemaining, monotonicRemaining)
            if wallClockRemaining <= 0, monotonicRemaining > 0 {
                FernletAuditLog.log(
                    "lock.cooldownClockRegression",
                    context: ["monotonicRemainingSeconds": "\(Int(monotonicRemaining))"]
                )
            }
        case .rebootDetected:
            effectiveRemaining = wallClockRemaining
            FernletAuditLog.log("lock.cooldownMonotonicResetByReboot")
        case .notRecorded:
            effectiveRemaining = wallClockRemaining
        }

        guard effectiveRemaining > 0 else { return nil }
        return dateProvider.now.addingTimeInterval(effectiveRemaining)
    }

    private enum MonotonicCheckOutcome {
        case available(remainingSeconds: TimeInterval)
        case rebootDetected
        case notRecorded
    }

    private func monotonicRemainingCooldownSeconds() -> MonotonicCheckOutcome {
        guard let anchorData = keychainLoad(.cooldownMonotonicAnchor, keychainService),
              let anchor = anchorData.toDouble,
              let durationData = keychainLoad(.cooldownDurationSeconds, keychainService),
              let duration = durationData.toDouble else {
            return .notRecorded
        }

        let nowUptime = uptimeProvider.systemUptime
        if nowUptime + 1.0 < anchor {
            return .rebootDetected
        }

        let elapsed = nowUptime - anchor
        return .available(remainingSeconds: max(duration - elapsed, 0))
    }

    private func loadCooldownLevel() -> Int {
        guard let data = keychainLoad(.cooldownLevel, keychainService),
              let byte = data.first else { return 0 }
        return Int(byte)
    }

    private func recordFailedAttempt() throws {
        let newAttemptCount = currentAttemptCount + 1
        let currentLevel = loadCooldownLevel()

        if newAttemptCount >= 4 {
            if currentLevel >= 4 {
                try storeVerified(Data([1]), for: .requiresReset)
                try storeAttemptCount(0)
                state = .locked(cooldownDeadline: nil)
                FernletAuditLog.log("lock.cooldownStarted", context: ["level": "reset-required"])
            } else {
                let newLevel = currentLevel + 1
                let duration = cooldownDuration(for: newLevel)
                let deadline = dateProvider.now.addingTimeInterval(duration)
                try storeVerified(Data([UInt8(newLevel)]), for: .cooldownLevel)

                var deadlineInterval = deadline.timeIntervalSinceReferenceDate
                try storeVerified(Data(bytes: &deadlineInterval, count: MemoryLayout<Double>.size), for: .cooldownDeadline)

                var anchor = uptimeProvider.systemUptime
                try storeVerified(Data(bytes: &anchor, count: MemoryLayout<Double>.size), for: .cooldownMonotonicAnchor)

                var durationSeconds = duration
                try storeVerified(Data(bytes: &durationSeconds, count: MemoryLayout<Double>.size), for: .cooldownDurationSeconds)

                try storeAttemptCount(0)
                state = .locked(cooldownDeadline: deadline)
                FernletAuditLog.log("lock.cooldownStarted", context: [
                    "level": "\(newLevel)",
                    "durationSeconds": "\(Int(duration))"
                ])
            }
        } else {
            try storeAttemptCount(newAttemptCount)
            state = .locked(cooldownDeadline: activeCooldownDeadline())
        }
    }

    private func storeAttemptCount(_ count: Int) throws {
        try storeVerified(Data([UInt8(min(count, 255))]), for: .attemptCount)
    }

    private func storedScryptN() -> Int {
        guard let data = keychainLoad(.scryptN, keychainService),
              data.count == MemoryLayout<Int32>.size else {
            return 32768  // pre-NEW-3 installs stored no N; 32768 was the only value used
        }
        return Int(data.withUnsafeBytes { $0.load(as: Int32.self) })
    }

    private func clearAttemptState() {
        KeychainItem.delete(for: .attemptCount, service: keychainService)
        KeychainItem.delete(for: .cooldownDeadline, service: keychainService)
        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: keychainService)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: keychainService)
        KeychainItem.delete(for: .cooldownLevel, service: keychainService)
        KeychainItem.delete(for: .requiresReset, service: keychainService)
    }
}

extension LockKeychainKey: CaseIterable {
    public static var allCases: [LockKeychainKey] {
        [
            .salt,
            .verifier,
            .kind,
            .wrappedContentKey,
            .biometricBypass,
            .biometricEnabledFlag,
            .cooldownDeadline,
            .cooldownMonotonicAnchor,
            .cooldownDurationSeconds,
            .attemptCount,
            .cooldownLevel,
            .requiresReset,
            .scryptN
        ]
    }
}

private extension Data {
    var toDouble: Double? {
        guard count == MemoryLayout<Double>.size else { return nil }
        return withUnsafeBytes { $0.load(as: Double.self) }
    }
}
