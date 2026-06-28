import Foundation
import FernletFoundation
import CryptoKit
import Security
import Testing
import FernletDomainModel
import PrivateStoreCore
@testable import FernletLock
@testable import Fernlet

// Cooldown tests use constructor-injected FernletDateProviding so restart behavior and exact deadlines
// can be verified without sleeping. Every test uses a UUID-scoped Keychain service and deletes that
// service in cleanup; these tests must never run against the production Keychain service.
@MainActor
@Suite(.serialized)
struct FernletLockServiceTests {
    @Test func keychainItemAccessAttributes() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"))
        try await service.setBiometricEnabled(true, passcode: "123456")
        service.lock(reason: .manual)
        do {
            _ = try await service.unlock(passcode: "000000")
            Issue.record("Wrong passcode unexpectedly unlocked the service")
        } catch FernletLockError.invalidPasscode {
        }

        for key in [
            LockKeychainKey.salt,
            .verifier,
            .kind,
            .wrappedContentKey,
            .attemptCount
        ] {
            guard let attributes = keychainAttributes(account: key.rawValue, service: harness.serviceID) else {
                Issue.record("Missing Keychain item for \(key.rawValue)")
                continue
            }
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            #expect((attributes[kSecAttrSynchronizable as String] as? Bool) != true)
        }

        try await failPasscode(service, times: 3)
        for key in [
            LockKeychainKey.cooldownDeadline,
            .cooldownMonotonicAnchor,
            .cooldownDurationSeconds,
            .cooldownLevel
        ] {
            guard let attributes = keychainAttributes(account: key.rawValue, service: harness.serviceID) else {
                Issue.record("Missing Keychain item for \(key.rawValue)")
                continue
            }
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            #expect((attributes[kSecAttrSynchronizable as String] as? Bool) != true)
        }

        let bypass = try #require(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID))
        #expect(bypass[kSecAttrAccessControl as String] != nil)
        #expect((bypass[kSecAttrSynchronizable as String] as? Bool) != true)
    }

    @Test func lockKeychainWritesUseDataProtectionKeychain() throws {
        let source = try String(contentsOf: lockServiceSourceURL(), encoding: .utf8)
        #expect(source.contains("kSecUseDataProtectionKeychain as String: true"))
        #expect(source.contains("kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly"))
        #expect(source.contains("kSecAttrSynchronizable as String: false"))
    }

    @Test func autoBiometricPromptOpportunityIsConsumedOncePerLockSession() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)

        #expect(service.consumeAutoBiometricPromptOpportunity())
        #expect(!service.consumeAutoBiometricPromptOpportunity())
        service.lock(reason: .manual)
        #expect(!service.consumeAutoBiometricPromptOpportunity())

        _ = try await service.unlock(passcode: "123456")
        service.lock(reason: .manual)
        #expect(service.consumeAutoBiometricPromptOpportunity())
    }

    @Test func biometricBypassAbsentWhenBiometricOff() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))

        #expect(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID) == nil)
    }

    @Test func biometricBypassPresentWhenBiometricOn() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        try await service.setBiometricEnabled(true, passcode: "123456")

        let attributes = try #require(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID))
        #expect(attributes[kSecAttrAccessControl as String] != nil)
    }

    @Test func biometricBypassRemovedWhenBiometricOffAgain() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        try await service.setBiometricEnabled(true, passcode: "123456")
        try await service.setBiometricEnabled(false, passcode: "123456")

        #expect(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID) == nil)
    }

    @Test func biometricBypassSurvivesPasscodeChangeAndYieldsSameContentKey() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        var biometricKey = Data()
        let service = harness.makeService { _, _ in biometricKey }
        try await service.configure(credential: .pin6("123456"))
        biometricKey = try #require(service.contentKey()).withUnsafeBytes { Data($0) }
        try await service.setBiometricEnabled(true, passcode: "123456")
        try await service.changeCredential(current: "123456", new: .alphanumeric("newpass123"))

        #expect(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID) != nil)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "newpass123")
        let passcodeKey = try #require(service.contentKey()).withUnsafeBytes { Data($0) }
        service.lock(reason: .manual)
        _ = try await service.unlockWithBiometrics()
        let bypassKey = try #require(service.contentKey()).withUnsafeBytes { Data($0) }
        #expect(passcodeKey == biometricKey)
        #expect(bypassKey == passcodeKey)
    }

    @Test func configuredStatePersistsAcrossInstances() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"))
        serviceA.lock(reason: .manual)

        let serviceB = harness.makeService()
        #expect(serviceB.state == .locked(cooldownDeadline: nil))
        _ = try await serviceB.unlock(passcode: "123456")
        #expect(serviceB.state == .unlocked)
    }

    @Test func attemptCounterPersistsAcrossInstances() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"))
        serviceA.lock(reason: .manual)
        try await failPasscode(serviceA, times: 3)

        let serviceB = harness.makeService()
        try await failPasscode(serviceB, times: 1)
        #expect(serviceB.currentAttemptCount == 0)
        #expect(cooldownDeadline(from: serviceB.state) != nil)
    }

    @Test func cooldownDeadlinePersistsAcrossInstances() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"))
        serviceA.lock(reason: .manual)
        try await failPasscode(serviceA, times: 4)

        let serviceB = harness.makeService()
        await #expect(throws: FernletLockError.self) {
            _ = try await serviceB.unlock(passcode: "123456")
        }
        #expect(cooldownDeadline(from: serviceB.state) != nil)
    }

    @Test func cooldownLevelPersistsAcrossMultipleCooldowns() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"))
        serviceA.lock(reason: .manual)
        try await failPasscode(serviceA, times: 4)
        harness.clock.advance(by: 61)
        harness.uptime.advance(by: 61)

        let serviceB = harness.makeService()
        try await failPasscode(serviceB, times: 4)
        #expect(cooldownRemaining(serviceB, clock: harness.clock) == 900)
    }

    @Test func cooldownDurationsAreExact() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)

        for expected in [60.0, 900.0, 3600.0, 14400.0] {
            try await failPasscode(service, times: 4)
            #expect(cooldownRemaining(service, clock: harness.clock) == expected)
            harness.clock.advance(by: expected + 1)
            harness.uptime.advance(by: expected + 1)
        }
    }

    @Test func resetRequiredAfterFourthCooldownCycleExpiresAndFourMoreFailures() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)

        for duration in [60.0, 900.0, 3600.0, 14400.0] {
            try await failPasscode(service, times: 4)
            harness.clock.advance(by: duration + 1)
            harness.uptime.advance(by: duration + 1)
        }
        try await failPasscode(service, times: 4)
        #expect(service.requiresReset)
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "123456")
        }
    }

    @Test func successfulUnlockResetsCountersAndCooldown() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        try await failPasscode(service, times: 3)

        _ = try await service.unlock(passcode: "123456")
        #expect(service.currentAttemptCount == 0)
        #expect(loadByte(.cooldownLevel, service: harness.serviceID) == nil)
        #expect(keychainData(account: LockKeychainKey.cooldownDeadline.rawValue, service: harness.serviceID) == nil)
        #expect(keychainData(account: LockKeychainKey.cooldownMonotonicAnchor.rawValue, service: harness.serviceID) == nil)
        #expect(keychainData(account: LockKeychainKey.cooldownDurationSeconds.rawValue, service: harness.serviceID) == nil)
    }

    @Test func cooldownHeldWhenWallClockAdvancedPastDeadlineButMonotonicDisagrees() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }

        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)
        #expect(cooldownDeadline(from: service.state) != nil)

        audit.removeAll()
        harness.clock.advance(by: 90)

        do {
            _ = try await service.unlock(passcode: "123456")
            Issue.record("Correct passcode should remain blocked while monotonic cooldown is active")
        } catch FernletLockError.cooldownActive {
        } catch {
            Issue.record("Expected cooldownActive, got \(error)")
        }

        #expect(audit.contains("lock.cooldownClockRegression"))
    }

    @Test func cooldownExpiresWhenBothClocksAdvancePastDeadline() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        harness.clock.advance(by: 90)
        harness.uptime.advance(by: 90)

        _ = try await service.unlock(passcode: "123456")
        #expect(service.state == .unlocked)
        #expect(service.currentAttemptCount == 0)
        #expect(loadByte(.cooldownLevel, service: harness.serviceID) == nil)
        #expect(keychainData(account: LockKeychainKey.cooldownDeadline.rawValue, service: harness.serviceID) == nil)
        #expect(keychainData(account: LockKeychainKey.cooldownMonotonicAnchor.rawValue, service: harness.serviceID) == nil)
        #expect(keychainData(account: LockKeychainKey.cooldownDurationSeconds.rawValue, service: harness.serviceID) == nil)
    }

    @Test func cooldownFallsBackToWallClockAfterSimulatedReboot() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }

        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        audit.removeAll()
        harness.uptime.simulateReboot(uptimeAfterReboot: 5)
        harness.clock.advance(by: 90)

        _ = try await service.unlock(passcode: "123456")
        #expect(service.state == .unlocked)
        #expect(audit.contains("lock.cooldownMonotonicResetByReboot"))
    }

    @Test func cooldownStartedAfterHardeningWritesMonotonicAnchor() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        for key in [LockKeychainKey.cooldownMonotonicAnchor, .cooldownDurationSeconds] {
            let attributes = try #require(keychainAttributes(account: key.rawValue, service: harness.serviceID))
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            #expect((attributes[kSecAttrSynchronizable as String] as? Bool) != true)
        }

        #expect(keychainData(account: LockKeychainKey.cooldownMonotonicAnchor.rawValue, service: harness.serviceID) != nil)
        #expect(keychainData(account: LockKeychainKey.cooldownDurationSeconds.rawValue, service: harness.serviceID) != nil)
    }

    @Test func legacyCooldownWithoutMonotonicAnchorFallsBackToWallClock() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }

        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: harness.serviceID)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: harness.serviceID)
        audit.removeAll()
        harness.clock.advance(by: 90)

        _ = try await service.unlock(passcode: "123456")
        #expect(service.state == .unlocked)
        #expect(!audit.contains("lock.cooldownClockRegression"))
    }

    @Test func biometricFailuresDoNotCountAgainstPasscodeBudget() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService { _, _ in throw FernletLockError.biometricFailed }
        try await service.configure(credential: .pin6("123456"))
        try await service.setBiometricEnabled(true, passcode: "123456")
        service.lock(reason: .manual)

        for _ in 0..<10 {
            await #expect(throws: FernletLockError.self) {
                _ = try await service.unlockWithBiometrics()
            }
        }
        #expect(service.currentAttemptCount == 0)
    }

    @Test func resetDeletesEveryItemAndPendingBuffer() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        try await service.setBiometricEnabled(true, passcode: "123456")
        try service.bufferPendingNarrative(samplePayload())
        try await failPasscode(service, times: 4)

        try service.reset()
        #expect(service.state == .notConfigured)
        #expect(allKeychainAttributes(service: harness.serviceID).isEmpty)
        #expect(try service.drainPendingNarratives().isEmpty)
    }

    @Test func resetIsIdempotent() throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try service.reset()
        try service.reset()
        #expect(service.state == .notConfigured)
    }

    @Test func resetThenReconfigureProducesFreshSaltAndVerifier() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        let firstSalt = try #require(keychainData(account: LockKeychainKey.salt.rawValue, service: harness.serviceID))
        let firstVerifier = try #require(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID))

        try service.reset()
        try await service.configure(credential: .pin6("123456"))
        let secondSalt = try #require(keychainData(account: LockKeychainKey.salt.rawValue, service: harness.serviceID))
        let secondVerifier = try #require(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID))
        #expect(firstSalt != secondSalt)
        #expect(firstVerifier != secondVerifier)
    }

    @Test func pin4Setup() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin4("1234"))
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "1234")
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "12345") }
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "0000") }
    }

    @Test func pin4RejectsNonNumericAndWrongLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin4("abcd")) }
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin4("123")) }
    }

    @Test func pin6Setup() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"))
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456")
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "12345") }
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "000000") }
    }

    @Test func pin6RejectsNonNumericAndWrongLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin6("abcdef")) }
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin6("12345")) }
    }

    @Test func alphanumericSetupIsExactAndCaseSensitive() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .alphanumeric("hunter2hunter2"))
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "hunter2hunter2")
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "hunter2hunter2 ") }
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "Hunter2hunter2") }
    }

    @Test func alphanumericMinimumLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .alphanumeric("short")) }
    }

    @Test func alphanumericMaximumLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) {
            try await service.configure(credential: .alphanumeric(String(repeating: "x", count: 65)))
        }
    }

    @Test func changeCredentialKind() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin4("1234"))
        try await service.changeCredential(current: "1234", new: .alphanumeric("newpass123"))
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "1234") }
        _ = try await service.unlock(passcode: "newpass123")
        #expect(service.currentAttemptCount == 0)
    }
}

@MainActor
final class LockTestHarness {
    let serviceID = "com.fernlet.lock.test.\(UUID().uuidString)"
    let clock = FakeDateProvider(now: Date(timeIntervalSinceReferenceDate: 1_000_000))
    let uptime = MockUptimeProvider(systemUptime: 100_000)
    let crypto = FakeLockCryptoProvider()

    func makeService(biometricBypassLoader: ((String, String) throws -> Data)? = nil) -> FernletLockService {
        FernletLockService(
            keychainService: serviceID,
            dateProvider: clock,
            uptimeProvider: uptime,
            cryptoProvider: crypto,
            biometricBypassLoader: biometricBypassLoader
        )
    }

    func cleanup() {
        KeychainItem.deleteAll(service: serviceID)
        try? PendingNarrativeBuffer().purge()
    }
}

final class FakeDateProvider: FernletDateProviding {
    private(set) var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

final class MockUptimeProvider: FernletUptimeProviding {
    private(set) var systemUptime: TimeInterval

    init(systemUptime: TimeInterval = 100_000) {
        self.systemUptime = systemUptime
    }

    func advance(by seconds: TimeInterval) {
        systemUptime += seconds
    }

    func simulateReboot(uptimeAfterReboot: TimeInterval = 5) {
        systemUptime = uptimeAfterReboot
    }
}

final class FakeLockCryptoProvider: FernletLockCryptoProviding {
    private var saltCounter: UInt8 = 0
    private var contentKeyCounter: UInt8 = 0
    private var wrappedKeys: [Data: (wrappingKey: Data, contentKey: Data)] = [:]

    func generateSalt() throws -> Data {
        saltCounter &+= 1
        return Data(repeating: saltCounter, count: FernletLockCrypto.saltLength)
    }

    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data {
        let material = Data("verifier:\(passcode):".utf8) + salt
        return SHA256.hash(data: material).withUnsafeBytes { Data($0) }
    }

    func generateContentKey() -> Data {
        contentKeyCounter &+= 1
        return Data(repeating: contentKeyCounter, count: FernletLockCrypto.keyLength)
    }

    func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrapped = UUID().uuidString.data(using: .utf8)!
        wrappedKeys[wrapped] = (wrappingKeyData, contentKey)
        return wrapped
    }

    func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data {
        guard let stored = wrappedKeys[wrappedContentKey],
              stored.wrappingKey == wrappingKeyData else {
            throw FernletLockError.invalidPasscode
        }
        return stored.contentKey
    }
}

private final class AuditCapture {
    private let lock = NSLock()
    private var storedEvents: [(event: String, context: [String: String])] = []
    private var token: UUID?

    var events: [(event: String, context: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append((event, context))
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storedEvents.removeAll()
    }

    func contains(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.contains { $0.event == event }
    }
}

@MainActor
private func failPasscode(_ service: FernletLockService, times: Int) async throws {
    for _ in 0..<times {
        do {
            _ = try await service.unlock(passcode: "000000")
        } catch FernletLockError.invalidPasscode {
        } catch FernletLockError.cooldownActive {
        } catch FernletLockError.resetRequired {
        }
    }
}

private func cooldownDeadline(from state: FernletLockState) -> Date? {
    if case .locked(let deadline) = state { return deadline }
    return nil
}

@MainActor
private func cooldownRemaining(_ service: FernletLockService, clock: FakeDateProvider) -> TimeInterval? {
    cooldownDeadline(from: service.state)?.timeIntervalSince(clock.now)
}

private func samplePayload() -> PendingNarrativePayload {
    PendingNarrativePayload(
        hkExternalUUID: UUID().uuidString,
        dateKey: "2026-05-20",
        noteBytes: Data("buffered".utf8),
        symptomFlagsBytes: Data([1]),
        customSymptomScalesBytes: nil
    )
}

private func keychainData(account: String, service: String) -> Data? {
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

private func keychainAttributes(account: String, service: String) -> [String: Any]? {
    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
        kSecUseDataProtectionKeychain as String: true
    ]
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? [String: Any]
}

private func allKeychainAttributes(service: String) -> [[String: Any]] {
    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
        kSecUseDataProtectionKeychain as String: true
    ]
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
    return result as? [[String: Any]] ?? []
}

private func loadByte(_ key: LockKeychainKey, service: String) -> UInt8? {
    keychainData(account: key.rawValue, service: service)?.first
}

private func lockServiceSourceURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("FernletKit/Sources/FernletLock/FernletLockService.swift")
}
