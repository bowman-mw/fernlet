// DuressLockTests.swift
// FernletTests
//
// Phase 7 (duress PIN), steps 1–4: the duress verifier's own salt, the unconditional derivation
// that closes the timing oracle, the duress-FIRST ordering in every credential entry point, and the
// KEYLESS decoy session.
//
// These tests are about a property that is easy to state and easy to lose: entering the duress PIN
// must be indistinguishable from a benign unlock to anyone watching the device — same state, same
// audit line, no attempt/cooldown residue — while never handing over the real content key. Every
// assertion below pins one half of that.
//
// All Keychain writes go to a UUID-scoped service via `LockTestHarness` (shared with
// FernletLockServiceTests) and are deleted in cleanup; nothing here touches the production service.

import Foundation
import FernletFoundation
import CryptoKit
import LocalAuthentication
import Security
import Testing
@testable import FernletLock

@MainActor
@Suite(.serialized)
struct DuressLockTests {

    // MARK: - Timing shape: the derivation is unconditional

    /// The whole timing-oracle defense rests on `.duressSalt` existing whether or not a duress PIN
    /// does, so that unlock always pays exactly two scrypt derivations. If a future refactor made
    /// the duress derivation conditional, this row would stop appearing on an install that never
    /// configured a duress PIN — and unlock latency would start answering "is there a duress PIN?"
    @Test func unlockDerivesAgainstADuressSaltEvenWhenNoDuressPINIsConfigured() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        // configure() sweeps stale duress rows, so the salt is genuinely absent going in.
        #expect(duressRow(.duressSalt, harness) == nil, "precondition: configure() must not leave a duress salt")
        #expect(!service.hasDuressConfigured)

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)

        let dummySalt = try #require(duressRow(.duressSalt, harness),
                                     "unlock must derive against a duress salt even with no duress PIN")
        #expect(dummySalt.count == FernletLockCrypto.saltLength)
        // A dummy salt is not a configured duress PIN: no verifier, no mode.
        #expect(duressRow(.duressVerifier, harness) == nil)
        #expect(duressRow(.duressMode, harness) == nil)
        #expect(!service.hasDuressConfigured)

        // …and it is the PRIMARY salt's independent sibling, never the same row read twice.
        let primarySalt = try #require(duressRow(.salt, harness))
        #expect(dummySalt != primarySalt)
    }

    // MARK: - Configuration

    @Test func configureDuressStoresItsOwnSaltVerifierAndMode() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)

        #expect(service.hasDuressConfigured)
        let duressSalt = try #require(duressRow(.duressSalt, harness))
        let primarySalt = try #require(duressRow(.salt, harness))
        #expect(duressSalt != primarySalt)
        let duressVerifier = try #require(duressRow(.duressVerifier, harness))
        #expect(duressRow(.duressMode, harness) == Data([DuressMode.decoy.rawValue]))
        // Only the digest is persisted, never a derived key that could unwrap anything.
        #expect(duressVerifier.count == SHA256.byteCount)
    }

    @Test func configureDuressRejectsAPINEqualToTheRealPasscode() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        do {
            try await service.configureDuress(pin: "123456", mode: .decoy)
            Issue.record("A duress PIN equal to the real passcode was accepted — the real content key is now unreachable")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.duressPINMatchesPasscodeMessage)
        }
        #expect(!service.hasDuressConfigured)

        // The real passcode still opens the real key: nothing was half-written.
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
        #expect(!service.isDuressSessionActive)
    }

    /// The duress PIN has to be typeable on the SAME pad the real credential renders — a 4-digit pad
    /// auto-submits at four taps, so a 6-digit duress PIN there could never be entered at all.
    @Test func configureDuressRejectsAPINThatDoesNotFitTheConfiguredCredentialKind() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin4("1234"), grantingScope: .privateHub)
        await #expect(throws: FernletLockError.self) {
            try await service.configureDuress(pin: "654321", mode: .decoy)
        }
        #expect(!service.hasDuressConfigured)

        try await service.configureDuress(pin: "4321", mode: .decoy)
        #expect(service.hasDuressConfigured)
    }

    @Test func configureDuressRefusesRecoveryLockUntilACustodianIsEnrolled() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        #expect(!service.hasRecoveryCustodian)
        do {
            try await service.configureDuress(pin: "654321", mode: .recoveryLock)
            Issue.record("recoveryLock was accepted with no custodian — the keys would be destroyed with no way back")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.duressRecoveryCustodianRequiredMessage)
        }
        #expect(!service.hasDuressConfigured)

        // Stand in for the in-person QR enrollment by writing the three rows it writes. All three
        // are the gate: two public keys with no sealed blob is a half-written enrollment, and
        // arming this response over one would destroy the local keys with nothing able to give
        // them back. (The real ceremony is exercised in `DuressRecoveryEnrollmentTests`.)
        KeychainItem.store(Data(repeating: 0x11, count: 32), for: .custodianSigningPublicKey, service: harness.serviceID)
        KeychainItem.store(Data(repeating: 0x22, count: 32), for: .custodianKeyAgreementPublicKey, service: harness.serviceID)
        #expect(!service.hasRecoveryCustodian, "the blob is the third row of the gate")
        KeychainItem.store(Data(repeating: 0x33, count: 96), for: .recoveryBlob, service: harness.serviceID)
        #expect(service.hasRecoveryCustodian)

        try await service.configureDuress(pin: "654321", mode: .recoveryLock)
        #expect(service.hasDuressConfigured)
        #expect(duressRow(.duressMode, harness) == Data([DuressMode.recoveryLock.rawValue]))
    }

    /// Replacing an existing duress PIN must swap BOTH the secret and the response atomically
    /// enough that the old PIN never survives and a half-written state never reads as "configured".
    @Test func reconfiguringDuressReplacesThePINAndTheMode() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        let firstSalt = try #require(duressRow(.duressSalt, harness))

        try await service.configureDuress(pin: "222222", mode: .silentWipe)

        let secondSalt = try #require(duressRow(.duressSalt, harness))
        #expect(secondSalt != firstSalt, "a replacement must mint a fresh duress salt")
        #expect(duressRow(.duressMode, harness) == Data([DuressMode.silentWipe.rawValue]))

        service.lock(reason: .manual)
        // The superseded duress PIN is now just a wrong passcode.
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "654321", for: .privateHub)
        }
        #expect(!service.isDuressSessionActive)
        // The new one triggers.
        _ = try await service.unlock(passcode: "222222", for: .privateHub)
        #expect(service.isDuressSessionActive)
    }

    @Test func removeDuressStopsTheDuressPINAndLeavesTheRealOneWorking() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        try service.removeDuress()

        #expect(!service.hasDuressConfigured)
        #expect(duressRow(.duressVerifier, harness) == nil)
        #expect(duressRow(.duressMode, harness) == nil)

        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "654321", for: .privateHub)
        }
        #expect(!service.isDuressSessionActive, "a removed duress PIN must read as a plain wrong passcode")

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil)
    }

    // MARK: - The DECOY session

    /// The decoy's defining property: the unlock SUCCEEDS and installs no key. Everything sealed
    /// under the content key therefore reads empty, and nothing was destroyed to achieve it — the
    /// real passcode brings the real key straight back.
    @Test func duressUnlockOpensAKeylessDecoyAndIsFullyReversible() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let setup = harness.makeService()
        try await setup.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let realKey = try #require(setup.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await setup.configureDuress(pin: "654321", mode: .decoy)

        // A fresh instance = a relaunch, so the process passcode flags start false and the
        // "a duress unlock sets neither" assertion is meaningful.
        let service = harness.makeService()
        #expect(!service.passcodeUnlockedThisProcess)
        #expect(!service.passcodeVerifiedThisProcess)

        let result = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(result.method == .passcode, "the result must look exactly like a benign passcode unlock")
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(service.isDuressSessionActive)
        #expect(!service.hasResidentContentKey, "the decoy must be KEYLESS — no content key may be resident")
        #expect(service.contentKey(for: .privateHub) == nil)
        #expect(!service.passcodeUnlockedThisProcess, "a duress entry must not satisfy PIN-before-biometrics")
        #expect(!service.passcodeVerifiedThisProcess)

        // Nothing persisted, nothing deleted: the lock's own records are untouched by the decoy.
        #expect(duressRow(.duressVerifier, harness) != nil)
        #expect(duressRow(.duressMode, harness) == Data([DuressMode.decoy.rawValue]))

        // The flag deliberately OUTLIVES a re-lock — that is what keeps biometrics suppressed for
        // the whole duress session rather than only until the screen turns off.
        service.lock(reason: .manual)
        #expect(service.isDuressSessionActive, "lock() must NOT end a duress session")

        // …and only the real passcode ends it, restoring the real key.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(!service.isDuressSessionActive)
        #expect(service.passcodeUnlockedThisProcess)
        let recovered = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(recovered == realKey, "the decoy must be reversible — the real key survives it untouched")
    }

    /// The duress verifier lives under its OWN salt precisely so a passcode change cannot strand it:
    /// `changeCredential` rewrites the primary salt and verifier, and the app never holds the duress
    /// plaintext at that moment to recompute against. (Mirrors
    /// `biometricBypassSurvivesPasscodeChangeAndYieldsSameContentKey`.)
    @Test func duressOwnSaltSurvivesAPasscodeChange() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let realKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await service.configureDuress(pin: "654321", mode: .decoy)
        let duressSaltBefore = try #require(duressRow(.duressSalt, harness))
        let duressVerifierBefore = try #require(duressRow(.duressVerifier, harness))

        try await service.changeCredential(current: "123456", new: .pin6("111111"))

        #expect(duressRow(.duressSalt, harness) == duressSaltBefore, "the re-key rewrote the duress salt")
        #expect(duressRow(.duressVerifier, harness) == duressVerifierBefore)
        let primarySaltAfter = try #require(duressRow(.salt, harness))
        #expect(primarySaltAfter != duressSaltBefore,
                "precondition: the re-key really did mint a new PRIMARY salt")

        // The duress PIN still triggers…
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.isDuressSessionActive)
        #expect(service.contentKey(for: .privateHub) == nil)

        // …and the NEW real passcode still opens the same content key.
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "111111", for: .privateHub)
        #expect(!service.isDuressSessionActive)
        let recovered = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(recovered == realKey)
    }

    // MARK: - Ordering: duress runs ahead of the lockout guards and the attempt counter

    /// Lockout is exactly when coercion is likeliest, so a duress PIN that goes inert after four
    /// wrong attempts fails at the only moment it was built for. The compare therefore runs before
    /// both the cooldown guard and the `requiresReset` guard — while a wrong non-duress PIN still
    /// hits them untouched.
    @Test func duressFiresDuringAnActiveCooldownAndAfterResetIsRequired() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        service.lock(reason: .manual)

        // --- Active cooldown ---
        try await failUnlock(service, times: 4)
        let deadline = try #require(cooldownDeadline(from: service.state), "precondition: no cooldown started")
        #expect(deadline > harness.clock.now)
        // Even the REAL passcode is refused while the cooldown runs…
        do {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
            Issue.record("precondition failed: the cooldown did not refuse the real passcode")
        } catch FernletLockError.cooldownActive {
        }
        // …but the duress PIN gets through.
        let duringCooldown = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(duringCooldown.method == .passcode)
        #expect(service.isDuressSessionActive)
        #expect(service.state == .unlocked(scope: .privateHub))

        // --- requiresReset ---
        let second = harness.makeService()
        second.lock(reason: .manual)
        try await driveToRequiresReset(second, harness: harness)
        #expect(second.requiresReset, "precondition: the ladder was not exhausted")
        do {
            _ = try await second.unlock(passcode: "123456", for: .privateHub)
            Issue.record("precondition failed: requiresReset did not refuse the real passcode")
        } catch FernletLockError.resetRequired {
        }
        // A wrong, non-duress PIN is still refused with the same terminal error…
        do {
            _ = try await second.unlock(passcode: "000000", for: .privateHub)
            Issue.record("a wrong passcode was accepted while requiresReset was set")
        } catch FernletLockError.resetRequired {
        }
        // …and the duress PIN still works.
        _ = try await second.unlock(passcode: "654321", for: .privateHub)
        #expect(second.isDuressSessionActive)
        #expect(!second.hasResidentContentKey)
        #expect(!second.requiresReset, "duress clears attempt state exactly as a benign unlock does")
    }

    /// A duress entry must leave NO residue that tells it apart from a benign unlock afterwards:
    /// no incremented counter, no cooldown record, and the same `lock.released` audit line.
    @Test func duressNeverCountsAsAFailedAttemptAndEmitsTheBenignAuditLine() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        service.lock(reason: .manual)

        try await failUnlock(service, times: 2)
        #expect(service.currentAttemptCount == 2, "precondition: the attempt counter is not moving")

        let capture = DuressAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        // Durable state: identical to what a successful unlock leaves behind.
        #expect(service.currentAttemptCount == 0)
        #expect(duressRow(.attemptCount, harness) == nil)
        #expect(duressRow(.cooldownDeadline, harness) == nil)
        #expect(duressRow(.cooldownLevel, harness) == nil)
        #expect(duressRow(.requiresReset, harness) == nil)

        // Audit: the benign release line, and nothing that names duress. (Asserted as "contains"
        // rather than "equals" because FernletAuditLog's capture registry is process-global and
        // other suites may be emitting concurrently.)
        #expect(capture.contains(event: "lock.released",
                                 context: ["method": "passcode", "scope": FernletLockScope.privateHub.rawValue]),
                "a duress unlock must emit the SAME audit line as a benign one")
        #expect(!capture.anyEventNameContains("duress"),
                "a duress-specific audit label is a forensic tell")

        // The benign unlock's line is byte-for-byte the one we just asserted.
        capture.removeAll()
        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(capture.contains(event: "lock.released",
                                 context: ["method": "passcode", "scope": FernletLockScope.privateHub.rawValue]))
    }

    // MARK: - The other two credential entry points

    /// "Change your passcode" is a plausible demand under coercion. Honoring it with the duress PIN
    /// would re-key the REAL lock to a passcode the coercer chose, so the duress compare runs before
    /// a single credential row is touched.
    @Test func changeCredentialConsultsDuressFirstAndRewritesNothing() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let realKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await service.configureDuress(pin: "654321", mode: .decoy)
        let saltBefore = try #require(duressRow(.salt, harness))
        let verifierBefore = try #require(duressRow(.verifier, harness))
        let kindBefore = try #require(duressRow(.kind, harness))
        // Whichever row this hardware's custody state keeps (scrypt wrap when legacy, the enclave
        // wrap once configure() hard-bound the install).
        let contentKeyRow: LockKeychainKey =
            duressRow(.wrappedContentKey, harness) != nil ? .wrappedContentKey : .seWrappedContentKey
        let contentKeyRowBefore = try #require(duressRow(contentKeyRow, harness))

        try await service.changeCredential(current: "654321", new: .pin6("999999"))

        #expect(service.isDuressSessionActive, "a coerced re-key must present the decoy")
        #expect(!service.hasResidentContentKey)
        #expect(duressRow(.salt, harness) == saltBefore, "the duress PIN re-keyed the REAL lock")
        #expect(duressRow(.verifier, harness) == verifierBefore)
        #expect(duressRow(.kind, harness) == kindBefore)
        #expect(duressRow(contentKeyRow, harness) == contentKeyRowBefore)

        // The coercer's chosen passcode opens nothing; the real one still opens everything.
        service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "999999", for: .privateHub)
        }
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        let recovered = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(recovered == realKey)
    }

    /// The mirror-image trap: re-keying the REAL passcode to the duress PIN would make every
    /// subsequent unlock take the duress branch first, stranding the real content key forever.
    @Test func changeCredentialRefusesANewPasscodeEqualToTheDuressPIN() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let realKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await service.configureDuress(pin: "654321", mode: .decoy)

        do {
            try await service.changeCredential(current: "123456", new: .pin6("654321"))
            Issue.record("the real passcode was re-keyed to the duress PIN — the content key is now unreachable")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.duressPINMatchesPasscodeMessage)
        }
        #expect(!service.isDuressSessionActive, "the refusal is a validation error, not a duress trigger")

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        let recovered = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(recovered == realKey)
    }

    /// Enabling biometrics writes the RAW content key into the `.biometryCurrentSet` bypass row —
    /// a permanent, PIN-free door around the decoy. A coerced "turn on Face ID" must enable nothing.
    @Test func setBiometricEnabledConsultsDuressFirstAndEnablesNothing() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)

        try await service.setBiometricEnabled(true, passcode: "654321")

        #expect(service.isDuressSessionActive)
        #expect(!service.biometricEnabled, "a duress PIN enabled biometrics on the REAL content key")
        #expect(duressRow(.biometricEnabledFlag, harness) == nil)
        #expect(keychainAttributesForDuressTests(account: LockKeychainKey.biometricBypass.rawValue,
                                                 service: harness.serviceID) == nil,
                "the bypass row must not exist — it would hold the real content key")
    }

    /// The biometric side door, closed at the service (the guarantee) as well as in the UI policy.
    /// Note the flags: a normal unlock earlier in the same process leaves
    /// `passcodeUnlockedThisProcess` true, so PIN-before-biometrics alone would NOT stop this.
    @Test func aDuressSessionSuppressesBiometricUnlockUntilTheRealPINIsEntered() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        var biometricKey = Data()
        var loaderConsulted = false
        let service = harness.makeService(
            biometricBypassLoader: { _, _ in
                loaderConsulted = true
                return biometricKey
            },
            biometricTypeOverride: { .faceID }
        )

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        biometricKey = try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        try await service.setBiometricEnabled(true, passcode: "123456")
        try await service.configureDuress(pin: "654321", mode: .decoy)
        #expect(service.passcodeUnlockedThisProcess, "precondition: PIN-before-biometrics is already satisfied")
        #expect(service.isBiometricUnlockAvailable)

        service.lock(reason: .manual)
        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(service.isDuressSessionActive)

        #expect(!service.isBiometricUnlockAvailable, "the biometric offer must be withdrawn during a duress session")
        do {
            _ = try await service.unlockWithBiometrics(for: .privateHub)
            Issue.record("biometrics walked around the decoy and recovered the REAL content key")
        } catch FernletLockError.biometricNotAvailable {
        }
        #expect(!loaderConsulted, "the guard must refuse before any keychain/LocalAuthentication work")
        #expect(!service.hasResidentContentKey)

        // Only the real PIN reopens the door.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(!service.isDuressSessionActive)
        #expect(service.isBiometricUnlockAvailable)
        service.lock(reason: .manual)
        let result = try await service.unlockWithBiometrics(for: .privateHub)
        #expect(result.method == .biometric)
        #expect(loaderConsulted)
    }

    // MARK: - Mode dispatch

    /// The destructive halves of `.silentWipe` and `.recoveryLock` are covered by their own suites
    /// (`DuressSilentWipeTests`, `DuressRecoveryLockTriggerTests`). What belongs HERE is the
    /// dispatch's fail-closed edge: a `.recoveryLock` whose recovery material has gone missing since
    /// it was armed must present the plain, non-destructive decoy rather than destroy the local keys
    /// with nothing left able to give them back.
    @Test func recoveryLockWithoutItsMaterialFallsBackToThePlainDecoy() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        KeychainItem.store(Data(repeating: 0x11, count: 32), for: .custodianSigningPublicKey, service: harness.serviceID)
        KeychainItem.store(Data(repeating: 0x22, count: 32), for: .custodianKeyAgreementPublicKey, service: harness.serviceID)
        KeychainItem.store(Data(repeating: 0x33, count: 96), for: .recoveryBlob, service: harness.serviceID)
        try await service.configureDuress(pin: "654321", mode: .recoveryLock)
        // The blob vanishes after the response was armed.
        KeychainItem.delete(for: .recoveryBlob, service: harness.serviceID)
        service.lock(reason: .manual)

        let result = try await service.unlock(passcode: "654321", for: .privateHub)
        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(service.isDuressSessionActive)
        #expect(!service.hasResidentContentKey)
        // Nothing destroyed: the real passcode still opens the real key.
        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        #expect(service.contentKey(for: .privateHub) != nil,
                "a recoveryLock with no recovery material destroyed keys nothing can restore")
    }
}

// MARK: - Helpers

/// Fails `times` unlock attempts with a passcode that is neither the real nor the duress one,
/// swallowing every refusal the ladder can produce.
@MainActor
private func failUnlock(_ service: FernletLockService, times: Int) async throws {
    for _ in 0..<times {
        do {
            _ = try await service.unlock(passcode: "000000", for: .privateHub)
            Issue.record("a deliberately wrong passcode unlocked the service")
        } catch FernletLockError.invalidPasscode {
        } catch FernletLockError.cooldownActive {
        } catch FernletLockError.resetRequired {
        }
    }
}

/// Drives the cooldown ladder to exhaustion (`requiresReset`), advancing BOTH the fake wall clock
/// and the fake uptime past each level's duration — the service takes the max of the two remainders,
/// so advancing only one would leave the cooldown in force.
@MainActor
private func driveToRequiresReset(_ service: FernletLockService, harness: LockTestHarness) async throws {
    // 60s → 15min → 1h → 4h, then the next exhausted batch flips requiresReset.
    for waitSeconds in [61.0, 901.0, 3601.0, 14401.0] {
        try await failUnlock(service, times: FernletLockService.attemptsPerCooldownBatch)
        harness.clock.advance(by: waitSeconds)
        harness.uptime.advance(by: waitSeconds)
    }
    try await failUnlock(service, times: FernletLockService.attemptsPerCooldownBatch)
}

private func cooldownDeadline(from state: FernletLockState) -> Date? {
    if case .locked(let deadline) = state { return deadline }
    return nil
}

/// Raw keychain read for one lock row under the harness's isolated service.
@MainActor
private func duressRow(_ key: LockKeychainKey, _ harness: LockTestHarness) -> Data? {
    KeychainItem.load(for: key, service: harness.serviceID)
}

/// Attribute read used to prove the biometric-bypass row is absent (it is stored through an access
/// control, so `KeychainItem.load` is not the right probe for it).
private func keychainAttributesForDuressTests(account: String, service: String) -> [String: Any]? {
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

/// A local `FernletAuditLog` sink for the indistinguishability assertions.
///
/// The audit registry is process-global and other suites emit into it concurrently, so every
/// assertion built on this is phrased as "contains" (or "contains nothing named…"), never as an
/// equality over the whole captured stream.
private final class DuressAuditCapture {
    private let lock = NSLock()
    private var events: [(event: String, context: [String: String])] = []
    private var token: UUID?

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.events.append((event, context))
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
        events.removeAll()
    }

    func contains(event: String, context: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.event == event && $0.context == context }
    }

    func anyEventNameContains(_ needle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.event.localizedCaseInsensitiveContains(needle) }
    }
}
