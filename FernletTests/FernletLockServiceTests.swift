import Foundation
import FernletFoundation
import CryptoKit
import LocalAuthentication
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

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.setBiometricEnabled(true, passcode: "123456")
        service.lock(reason: .manual)
        do {
            _ = try await service.unlock(passcode: "000000", for: .privateHub)
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

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        #expect(service.consumeAutoBiometricPromptOpportunity())
        #expect(!service.consumeAutoBiometricPromptOpportunity())
        service.lock(reason: .manual)
        #expect(!service.consumeAutoBiometricPromptOpportunity())

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        service.lock(reason: .manual)
        #expect(service.consumeAutoBiometricPromptOpportunity())
    }

    @Test func biometricBypassAbsentWhenBiometricOff() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)

        #expect(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID) == nil)
    }

    @Test func biometricBypassPresentWhenBiometricOn() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.setBiometricEnabled(true, passcode: "123456")

        let attributes = try #require(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID))
        #expect(attributes[kSecAttrAccessControl as String] != nil)
    }

    @Test func biometricBypassRemovedWhenBiometricOffAgain() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.setBiometricEnabled(true, passcode: "123456")
        try await service.setBiometricEnabled(false, passcode: "123456")

        #expect(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID) == nil)
    }

    @Test func biometricBypassSurvivesPasscodeChangeAndYieldsSameContentKey() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        var biometricKey = Data()
        let service = harness.makeService { _, _ in biometricKey }
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        biometricKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await service.setBiometricEnabled(true, passcode: "123456")
        try await service.changeCredential(current: "123456", new: .alphanumeric("newpass123"))

        #expect(keychainAttributes(account: LockKeychainKey.biometricBypass.rawValue, service: harness.serviceID) != nil)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "newpass123", for: .privateHub)
        let passcodeKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        service.lock(reason: .manual)
        _ = try await service.unlockWithBiometrics(for: .privateHub)
        let bypassKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(passcodeKey == biometricKey)
        #expect(bypassKey == passcodeKey)
    }

    @Test func configuredStatePersistsAcrossInstances() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        serviceA.lock(reason: .manual)

        let serviceB = harness.makeService()
        #expect(serviceB.state == .locked(cooldownDeadline: nil))
        _ = try await serviceB.unlock(passcode: "123456", for: .privateHub)
        #expect(serviceB.state == .unlocked(scope: .privateHub))
    }

    @Test func attemptCounterPersistsAcrossInstances() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
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
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        serviceA.lock(reason: .manual)
        try await failPasscode(serviceA, times: 4)

        let serviceB = harness.makeService()
        await #expect(throws: FernletLockError.self) {
            _ = try await serviceB.unlock(passcode: "123456", for: .privateHub)
        }
        #expect(cooldownDeadline(from: serviceB.state) != nil)
    }

    @Test func cooldownLevelPersistsAcrossMultipleCooldowns() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        for duration in [60.0, 900.0, 3600.0, 14400.0] {
            try await failPasscode(service, times: 4)
            harness.clock.advance(by: duration + 1)
            harness.uptime.advance(by: duration + 1)
        }
        try await failPasscode(service, times: 4)
        #expect(service.requiresReset)
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
        }
    }

    @Test func successfulUnlockResetsCountersAndCooldown() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        try await failPasscode(service, times: 3)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)
        #expect(cooldownDeadline(from: service.state) != nil)

        audit.removeAll()
        harness.clock.advance(by: 90)

        do {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        harness.clock.advance(by: 90)
        harness.uptime.advance(by: 90)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        audit.removeAll()
        harness.uptime.simulateReboot(uptimeAfterReboot: 5)
        harness.clock.advance(by: 90)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(audit.contains("lock.cooldownMonotonicResetByReboot"))
    }

    @Test func cooldownStartedAfterHardeningWritesMonotonicAnchor() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        try await failPasscode(service, times: 4)

        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: harness.serviceID)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: harness.serviceID)
        audit.removeAll()
        harness.clock.advance(by: 90)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(!audit.contains("lock.cooldownClockRegression"))
    }

    @Test func biometricFailuresDoNotCountAgainstPasscodeBudget() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService { _, _ in throw FernletLockError.biometricFailed }
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.setBiometricEnabled(true, passcode: "123456")
        service.lock(reason: .manual)

        for _ in 0..<10 {
            await #expect(throws: FernletLockError.self) {
                _ = try await service.unlockWithBiometrics(for: .privateHub)
            }
        }
        #expect(service.currentAttemptCount == 0)
    }

    @Test func resetDeletesEveryItemAndPendingBuffer() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
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
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let firstSalt = try #require(keychainData(account: LockKeychainKey.salt.rawValue, service: harness.serviceID))
        let firstVerifier = try #require(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID))

        try service.reset()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let secondSalt = try #require(keychainData(account: LockKeychainKey.salt.rawValue, service: harness.serviceID))
        let secondVerifier = try #require(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID))
        #expect(firstSalt != secondSalt)
        #expect(firstVerifier != secondVerifier)
    }

    @Test func pin4Setup() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin4("1234"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "1234", for: .privateHub)
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "12345", for: .privateHub) }
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "0000", for: .privateHub) }
    }

    @Test func pin4RejectsNonNumericAndWrongLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin4("abcd"), grantingScope: .privateHub) }
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin4("123"), grantingScope: .privateHub) }
    }

    @Test func pin6Setup() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "12345", for: .privateHub) }
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "000000", for: .privateHub) }
    }

    @Test func pin6RejectsNonNumericAndWrongLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin6("abcdef"), grantingScope: .privateHub) }
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .pin6("12345"), grantingScope: .privateHub) }
    }

    @Test func alphanumericSetupIsExactAndCaseSensitive() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .alphanumeric("hunter2hunter2"), grantingScope: .privateHub)
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "hunter2hunter2", for: .privateHub)
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "hunter2hunter2 ", for: .privateHub) }
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "Hunter2hunter2", for: .privateHub) }
    }

    @Test func alphanumericMinimumLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) { try await service.configure(credential: .alphanumeric("short"), grantingScope: .privateHub) }
    }

    @Test func alphanumericMaximumLength() async throws {
        let service = LockTestHarness().makeService()
        await #expect(throws: FernletLockError.self) {
            try await service.configure(credential: .alphanumeric(String(repeating: "x", count: 65)), grantingScope: .privateHub)
        }
    }

    @Test func changeCredentialKind() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin4("1234"), grantingScope: .privateHub)
        try await service.changeCredential(current: "1234", new: .alphanumeric("newpass123"))
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) { _ = try await service.unlock(passcode: "1234", for: .privateHub) }
        _ = try await service.unlock(passcode: "newpass123", for: .privateHub)
        #expect(service.currentAttemptCount == 0)
    }

    // MARK: - Verifier / wrapping-key split + legacy migration

    @Test func legacyRawKeyVerifierUnlocksAndMigratesToDigest() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let expectedContentKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        service.lock(reason: .manual)

        // Simulate a pre-split install: overwrite the digest verifier with the RAW derived key (the old
        // format, where the verifier and the content-key wrapping key were the same bytes).
        let salt = try #require(keychainData(account: LockKeychainKey.salt.rawValue, service: harness.serviceID))
        let rawDerived = try await harness.crypto.deriveVerifier(passcode: "123456", salt: salt, n: FernletLockCrypto.scryptN)
        KeychainItem.store(rawDerived, for: .verifier, service: harness.serviceID)
        #expect(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID) == rawDerived)

        // Unlock still succeeds via the legacy compare, and yields the same content key.
        let result = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) } == expectedContentKey)

        // The verifier is migrated in place to the digest form (no longer the raw wrapping key).
        let migrated = try #require(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID))
        #expect(migrated == FernletLockCrypto.verifierDigest(of: rawDerived))
        #expect(migrated != rawDerived)

        // A subsequent unlock now matches via the current (digest) path.
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
    }

    @Test func wrongPasscodeRejectedAgainstLegacyVerifier() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        service.lock(reason: .manual)

        let salt = try #require(keychainData(account: LockKeychainKey.salt.rawValue, service: harness.serviceID))
        let rawDerived = try await harness.crypto.deriveVerifier(passcode: "123456", salt: salt, n: FernletLockCrypto.scryptN)
        KeychainItem.store(rawDerived, for: .verifier, service: harness.serviceID)

        do {
            _ = try await service.unlock(passcode: "000000", for: .privateHub)
            Issue.record("Wrong passcode unexpectedly unlocked against a legacy verifier")
        } catch FernletLockError.invalidPasscode {
        }
        // The legacy verifier is untouched by a failed attempt.
        #expect(keychainData(account: LockKeychainKey.verifier.rawValue, service: harness.serviceID) == rawDerived)
        #expect(service.contentKey(for: .privateHub) == nil)
    }

    // MARK: - PIN-before-biometrics (first passcode success per process)

    @Test func configureSetsPasscodeUnlockedThisProcess() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        #expect(!service.passcodeUnlockedThisProcess)
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.passcodeUnlockedThisProcess)
    }

    @Test func passcodeUnlockedThisProcessIsFalseAfterRelaunch() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        serviceA.lock(reason: .manual)
        #expect(serviceA.passcodeUnlockedThisProcess)

        // Relaunch simulation: a fresh instance restored from the same keychain service.
        // The flag is in-memory only, so a new process starts passcode-first again.
        let serviceB = harness.makeService()
        #expect(serviceB.state == .locked(cooldownDeadline: nil))
        #expect(!serviceB.passcodeUnlockedThisProcess)
    }

    @Test func resetClearsPasscodeUnlockedThisProcess() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(service.passcodeUnlockedThisProcess)

        try service.reset()
        #expect(!service.passcodeUnlockedThisProcess)
    }

    @Test func biometricUnlockRefusedUntilFirstPasscodeSuccessInProcess() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        var biometricKey = Data()
        let serviceA = harness.makeService { _, _ in biometricKey }
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        biometricKey = try #require(serviceA.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await serviceA.setBiometricEnabled(true, passcode: "123456")
        serviceA.lock(reason: .manual)

        // Relaunch simulation: no passcode success has happened in serviceB's "process" yet,
        // so the fail-closed service guard refuses before the bypass loader is ever consulted.
        let serviceB = harness.makeService { _, _ in biometricKey }
        do {
            _ = try await serviceB.unlockWithBiometrics(for: .privateHub)
            Issue.record("Biometric unlock succeeded before the process's first passcode success")
        } catch FernletLockError.biometricNotAvailable {
        }
        #expect(serviceB.state == .locked(cooldownDeadline: nil))

        // One passcode success satisfies the requirement for the rest of the process...
        _ = try await serviceB.unlock(passcode: "123456", for: .privateHub)
        #expect(serviceB.passcodeUnlockedThisProcess)
        serviceB.lock(reason: .manual)

        // ...after which the biometric path works again.
        let result = try await serviceB.unlockWithBiometrics(for: .privateHub)
        #expect(result.method == .biometric)
        #expect(serviceB.state == .unlocked(scope: .privateHub))
    }

    @Test func isBiometricUnlockAvailableGatesOnFirstPasscodeSuccess() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let serviceA = harness.makeService()
        try await serviceA.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await serviceA.setBiometricEnabled(true, passcode: "123456")
        serviceA.lock(reason: .manual)

        // Relaunch simulation: biometrics are enabled in the keychain, but no passcode success
        // has happened in this "process", so the policy is false no matter what the device's
        // biometry reports (the passcodeUnlockedThisProcess conjunct alone forces it).
        let serviceB = harness.makeService()
        #expect(serviceB.biometricEnabled)
        #expect(!serviceB.passcodeUnlockedThisProcess)
        #expect(!serviceB.isBiometricUnlockAvailable)

        _ = try await serviceB.unlock(passcode: "123456", for: .privateHub)
        serviceB.lock(reason: .manual)
        // After the first passcode success the flag no longer suppresses the offer: only the
        // device-capability conjuncts remain (biometricType is real LAContext state, so on
        // hardware without enrolled biometry the policy legitimately stays false).
        #expect(serviceB.passcodeUnlockedThisProcess)
        #expect(serviceB.isBiometricUnlockAvailable == (serviceB.biometricEnabled && serviceB.biometricType != .none))
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
            _ = try await service.unlock(passcode: "000000", for: .privateHub)
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
