// DuressRecoveryTests.swift
// FernletTests
//
// Phase 7 (duress PIN), steps 7–8: `DuressMode.recoveryLock` — the response that destroys every
// local way into the content key while KEEPING the sealed corpus and a recovery blob only the
// user's own second device can open — and the two in-person ceremonies that enroll that device and
// get the key back from it.
//
// Three properties are being pinned, and they are the three ways this feature could go wrong:
//
//   * The trigger must destroy the right things and ONLY the right things. Destroying too little
//     leaves the coercer a way in; destroying too much (the recovery blob, the device fallback keys)
//     turns the one recoverable mode into silent, permanent data loss.
//   * The ceremony must authenticate. A key handed back by anyone other than the enrolled custodian
//     — or a `destroy` instruction sealed by a stranger to a public key anyone can read — would be
//     obeyed by a naive implementation, because `IdentityService.seal` provides confidentiality, not
//     sender authentication.
//   * The recovery must be all-or-nothing. A wrong key installed over a live corpus is unrecoverable
//     and silent, so the lock refuses any key that is not the one its blob seals.
//
// Lock rows go to a UUID-scoped keychain service via `LockTestHarness` (shared with
// FernletLockServiceTests); every identity is minted at its own throwaway service. Nothing here
// touches the production lock or the device's real proximity identity.

import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
import ProximityKit
@testable import Fernlet
@testable import FernletLock

// MARK: - Fixtures

/// Counts hook invocations the lock service owns.
@MainActor
private final class RecoveryTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Raw keychain read for one lock row under a harness's isolated service.
@MainActor
private func recoveryRow(_ key: LockKeychainKey, _ harness: LockTestHarness) -> Data? {
    KeychainItem.load(for: key, service: harness.serviceID)
}

/// Existence probe for a row behind an access control (the biometric bypass), which
/// `KeychainItem.load` cannot answer without prompting.
@MainActor
private func accessControlledRecoveryRowExists(_ key: LockKeychainKey, _ harness: LockTestHarness) -> Bool {
    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: harness.serviceID,
        kSecAttrAccount as String: key.rawValue,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
        kSecUseDataProtectionKeychain as String: true
    ]
    return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
}

/// A provisioned proximity identity at a throwaway keychain service.
@MainActor
private func makeThrowawayIdentity() throws -> IdentityService {
    let identity = IdentityService(keychainService: "com.fernlet.identity.test.\(UUID().uuidString)")
    try identity.ensureProvisioned()
    return identity
}

/// A configured lock with a real (ceremony-shaped) recovery custodian enrolled against it.
@MainActor
private final class RecoveryFixture {
    let harness = LockTestHarness()
    let service: FernletLockService
    let primaryIdentity: IdentityService
    let custodianIdentity: IdentityService
    /// The content key the user's real data is sealed under, captured before anything destructive.
    let contentKey: Data
    /// A stand-in for one row of the sealed corpus: ciphertext under `contentKey` that must still
    /// open after a recovery-lock + custodian recovery round trip.
    let sealedCorpusRow: Data
    let purgeCount = RecoveryTestCounter()

    static let corpusPlaintext = Data("a journal entry that must survive a recovery-lock".utf8)

    init(realPIN: String = "123456", biometricsEnabled: Bool = true) async throws {
        primaryIdentity = try makeThrowawayIdentity()
        custodianIdentity = try makeThrowawayIdentity()
        var biometricKey = Data()
        service = harness.makeService { _, _ in biometricKey }
        try await service.configure(credential: .pin6(realPIN), grantingScope: .privateHub)
        let key = try #require(service.contentKey(for: .privateHub))
        contentKey = key.withUnsafeBytes { Data($0) }
        biometricKey = contentKey
        sealedCorpusRow = try ChaChaPoly.seal(Self.corpusPlaintext, using: key).combined
        if biometricsEnabled {
            try await service.setBiometricEnabled(true, passcode: realPIN)
        }
        let counter = purgeCount
        service.installDuressPurgeHook { counter.increment() }
    }

    /// Enrolls `custodianIdentity` the way the ceremony does: seal the content key to its
    /// key-agreement key with the primary's identity, and persist it through the lock.
    func enrollCustodian(passcode: String = "123456") async throws {
        let custodianKeyAgreement = custodianIdentity.localKeyAgreementPublicKey
        let primary = primaryIdentity
        try await service.enrollRecoveryCustodian(
            passcode: passcode,
            signingPublicKey: custodianIdentity.localSigningPublicKey,
            keyAgreementPublicKey: custodianKeyAgreement,
            ownKeyAgreementPublicKey: primary.localKeyAgreementPublicKey
        ) { contentKey in
            try primary.seal(contentKey, to: custodianKeyAgreement, format: .wire2)
        }
    }

    /// What the custodian device recovers from the stored blob.
    func custodianOpensTheBlob() throws -> Data {
        let blob = try #require(service.custodianRecoveryBlob)
        return try custodianIdentity.open(
            blob,
            from: primaryIdentity.localKeyAgreementPublicKey,
            format: .wire2
        )
    }

    func cleanup() {
        harness.cleanup()
        try? primaryIdentity.wipe()
        try? custodianIdentity.wipe()
    }
}

// MARK: - Step 7: enrollment (the lock's half)

/// The custody half of enrollment: the content key leaves only into a sealing closure, the three
/// rows land in the order that makes every intermediate state read as "no custodian", and a duress
/// PIN cannot drive any of it.
@MainActor
@Suite(.serialized)
struct DuressRecoveryEnrollmentTests {

    @Test func enrollmentSealsTheExactContentKeyToTheCustodian() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }

        try await fixture.enrollCustodian()

        #expect(fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.enrolledCustodianSigningPublicKey == fixture.custodianIdentity.localSigningPublicKey)
        #expect(fixture.service.enrolledCustodianKeyAgreementPublicKey == fixture.custodianIdentity.localKeyAgreementPublicKey)
        // The custodian — and only the custodian — turns the blob back into the key.
        #expect(try fixture.custodianOpensTheBlob() == fixture.contentKey)
    }

    /// The stored row is `digest ‖ sealed`: the digest never leaves the device (it is this device's
    /// check value for what comes back), and the sealed half is what the ceremony transmits.
    @Test func theStoredBlobKeepsALocalCheckValueTheCustodianNeverSees() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }

        try await fixture.enrollCustodian()

        let row = try #require(recoveryRow(.recoveryBlob, fixture.harness))
        let sealed = try #require(fixture.service.custodianRecoveryBlob)
        #expect(row.count == SHA256.byteCount + sealed.count)
        #expect(Data(row.suffix(sealed.count)) == sealed)
        // The prefix is a digest of the content key, not the key or the sealing.
        let prefix = Data(row.prefix(SHA256.byteCount))
        #expect(prefix != fixture.contentKey)
        #expect(!sealed.contains(prefix))
    }

    /// A nobody-can-open blob is not a custodian. Two public keys with no sealing would let
    /// `recoveryLock` be armed over a device with no way back.
    @Test func twoPublicKeysWithoutABlobIsNotAnEnrolledCustodian() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        let harness = fixture.harness

        #expect(KeychainItem.store(Data(repeating: 0x11, count: 32), for: .custodianSigningPublicKey,
                                  service: harness.serviceID) == errSecSuccess)
        #expect(KeychainItem.store(Data(repeating: 0x22, count: 32), for: .custodianKeyAgreementPublicKey,
                                  service: harness.serviceID) == errSecSuccess)

        #expect(!fixture.service.hasRecoveryCustodian)
        await #expect(throws: FernletLockError.self) {
            try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        }
        #expect(!fixture.service.hasDuressConfigured)

        try await fixture.enrollCustodian()
        #expect(fixture.service.hasRecoveryCustodian)
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        #expect(fixture.service.hasDuressConfigured)
    }

    /// The single most dangerous omission in the whole phase: enrollment is the one credential entry
    /// point where honoring a duress PIN would EXPORT the real content key — sealed to a device the
    /// coercer chose — rather than merely showing a decoy.
    @Test func enrollmentUnderTheDuressPINSealsNothingAndPresentsTheDecoy() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.service.configureDuress(pin: "654321", mode: .decoy)
        fixture.service.lock(reason: .manual)

        try await fixture.enrollCustodian(passcode: "654321")

        #expect(!fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.custodianRecoveryBlob == nil)
        #expect(recoveryRow(.custodianSigningPublicKey, fixture.harness) == nil)
        // …and it looks exactly like an unlock, because that is the decoy.
        #expect(fixture.service.isDuressSessionActive)
        #expect(!fixture.service.hasResidentContentKey)
    }

    @Test func enrollmentRefusesAWrongPasscodeAndMalformedKeys() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.enrollCustodian(passcode: "000000")
            Issue.record("a wrong passcode enrolled a recovery custodian")
        } catch FernletLockError.invalidPasscode {
            // Expected.
        }
        #expect(!fixture.service.hasRecoveryCustodian)

        // A public key that is not a raw Curve25519 key would make an unopenable blob, so it is
        // refused before the content key is ever recovered.
        do {
            try await fixture.service.enrollRecoveryCustodian(
                passcode: "123456",
                signingPublicKey: Data(repeating: 0x11, count: 31),
                keyAgreementPublicKey: Data(repeating: 0x22, count: 32),
                ownKeyAgreementPublicKey: Data(repeating: 0x33, count: 32)
            ) { $0 }
            Issue.record("a malformed custodian signing key was accepted")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.recoveryCustodianInvalidKeyMessage)
        }
        #expect(!fixture.service.hasRecoveryCustodian)
    }

    /// Un-enrolling while `recoveryLock` is armed would leave a response that destroys every local
    /// key with nothing left to give them back.
    @Test func removingTheCustodianIsRefusedWhileRecoveryLockIsArmed() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)

        do {
            try fixture.service.removeRecoveryCustodian()
            Issue.record("the custodian was removed while recoveryLock was still armed")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.recoveryCustodianInUseMessage)
        }
        #expect(fixture.service.hasRecoveryCustodian)

        // Change the response first, and the removal goes through.
        try fixture.service.removeDuress()
        try fixture.service.removeRecoveryCustodian()
        #expect(!fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.custodianRecoveryBlob == nil)
    }

    /// The public-key length the lock enforces has to be the length the ceremony actually produces;
    /// the two constants live in different modules on purpose (no ProximityKit edge from the lock),
    /// so nothing but a test can keep them honest.
    @Test func theLocksCustodianKeyLengthMatchesTheCeremonys() {
        #expect(FernletLockService.recoveryCustodianPublicKeyByteCount == ProximityVerifySignature.publicKeyByteCount)
        #expect(DuressRecoveryTranscript.publicKeyByteCount == FernletLockService.recoveryCustodianPublicKeyByteCount)
    }
}

// MARK: - Step 7: the trigger

/// What entering a `recoveryLock` duress PIN destroys, what it keeps, and what it must not do.
@MainActor
@Suite(.serialized)
struct DuressRecoveryLockTriggerTests {

    /// Arms the response and fires it, returning the fixture mid-decoy. A Phase 2.5 re-wrap
    /// staging orphan is planted before the trigger so
    /// ``theTriggerDestroysEveryLocalUnlockKey()`` can pin that the recovery-lock's explicit
    /// destruction list takes it — it is a scrypt-openable copy of the content key, and the
    /// mode's whole claim is that NO local route survives.
    private func triggeredFixture() async throws -> RecoveryFixture {
        let fixture = try await RecoveryFixture()
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        fixture.service.lock(reason: .manual)
        #expect(KeychainItem.store(Data([0xA5, 0x5A]), for: .wrappedContentKeyRewrapStaging,
                                   service: fixture.harness.serviceID) == errSecSuccess)
        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)
        return fixture
    }

    /// Every LOCAL route to the content key is gone — including the biometric bypass, the PIN-free
    /// door a coercer can use with no passcode at all.
    @Test func theTriggerDestroysEveryLocalUnlockKey() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }
        let harness = fixture.harness

        #expect(recoveryRow(.salt, harness) == nil)
        #expect(recoveryRow(.verifier, harness) == nil)
        #expect(recoveryRow(.wrappedContentKey, harness) == nil)
        // The Phase 2.5 re-wrap staging orphan `triggeredFixture()` planted went with the same
        // explicit list (the PrivacyWipeCoverage recovery-lock row, pinned executable) — a duress
        // entry returns before the unlock-tail sweep, so only the list can have taken it.
        #expect(recoveryRow(.wrappedContentKeyRewrapStaging, harness) == nil,
                "the recovery-lock destruction must take the re-wrap staging orphan")
        #expect(recoveryRow(.seWrappedContentKey, harness) == nil)
        #expect(accessControlledRecoveryRowExists(.biometricBypass, harness) == false)
        #expect(recoveryRow(.biometricEnabledFlag, harness) == nil)
        #expect(!fixture.service.biometricEnabled)
        // The duress PIN is spent with the rest.
        #expect(!fixture.service.hasDuressConfigured)
        #expect(recoveryRow(.duressMode, harness) == nil)
        // Unlike the WIPE, nothing is re-minted: no local unlock survives at all.
        #expect(recoveryRow(.kind, harness) == nil || recoveryRow(.salt, harness) == nil)
        #expect(fixture.harness.makeService().state == .notConfigured)
    }

    /// …and the material the mode exists for is untouched.
    @Test func theTriggerKeepsEverythingTheCeremonyNeeds() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }

        #expect(fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.enrolledCustodianSigningPublicKey == fixture.custodianIdentity.localSigningPublicKey)
        #expect(fixture.service.enrolledCustodianKeyAgreementPublicKey == fixture.custodianIdentity.localKeyAgreementPublicKey)
        // The blob still opens to the exact key the corpus is sealed under.
        #expect(try fixture.custodianOpensTheBlob() == fixture.contentKey)
        // The ProximityKit identity keys the return ceremony authenticates with live at a different
        // keychain service the lock never sweeps — the ceremony would be impossible without them.
        #expect(!fixture.primaryIdentity.localSigningPublicKey.isEmpty)
        #expect(!fixture.primaryIdentity.localKeyAgreementPublicKey.isEmpty)
        #expect(fixture.service.isAwaitingCustodianRecovery)
    }

    /// The journal / Worry Box device fallback keys survive here, and that is deliberate: the WIPE
    /// destroys them because "crypto-erased" would otherwise be false, but no recovery blob can give
    /// them back, so destroying them on the RECOVERABLE mode would be loss no ceremony can undo.
    @Test func theTriggerKeepsTheDeviceFallbackKeysTheWipeDestroys() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        let deviceKeyService = fixture.harness.sealedContentKeyServiceID
        _ = KeychainItem.store(Data(repeating: 0x5A, count: 32), for: .salt, service: deviceKeyService)
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        fixture.service.lock(reason: .manual)

        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)

        #expect(KeychainItem.load(for: .salt, service: deviceKeyService) != nil,
                "the recovery-lock destroyed device fallback keys no recovery blob can restore")
    }

    /// The corpus is being KEPT for the custodian, so firing the delete funnel would destroy exactly
    /// what the ceremony is going to open.
    @Test func theTriggerNeverFiresThePurgeHook() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }

        #expect(fixture.purgeCount.value == 0)
    }

    /// The coerced user can now say truthfully that they cannot open it — neither factor works.
    @Test func afterTheTriggerNeitherThePasscodeNorBiometricsOpenAnything() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)

        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
        }
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlockWithBiometrics(for: .privateHub)
        }
        #expect(service.contentKey(for: .privateHub) == nil)
    }

    /// Presentation is the same keyless decoy every other mode opens: a recovery-lock must not be
    /// distinguishable from a decoy, nor from a wipe.
    @Test func theTriggerPresentsTheSameKeylessDecoy() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(service.isDuressSessionActive)
        #expect(!service.hasResidentContentKey)
        #expect(service.contentKey(for: .privateHub) == nil)
        #expect(service.currentAttemptCount == 0)
        #expect(!service.requiresReset)
        #expect(!service.isBiometricUnlockAvailable)
    }

    /// Fails CLOSED. `configureDuress` refuses the mode without a custodian, but the rows can still
    /// be gone by the time the PIN is entered — and destroying the local keys then would be an
    /// unannounced permanent wipe the user never chose.
    @Test func theTriggerFallsBackToThePlainDecoyWhenTheRecoveryMaterialIsGone() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        // The blob vanishes after the response was armed (a swept or corrupted keychain).
        KeychainItem.delete(for: .recoveryBlob, service: fixture.harness.serviceID)
        fixture.service.lock(reason: .manual)

        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)

        #expect(fixture.service.isDuressSessionActive)
        #expect(!fixture.service.hasResidentContentKey)
        // Nothing was destroyed: the real passcode still opens the real key.
        _ = try await fixture.service.unlock(passcode: "123456", for: .privateHub)
        let recovered = try #require(fixture.service.contentKey(for: .privateHub))
        #expect(recovered.withUnsafeBytes { Data($0) } == fixture.contentKey)
    }

    /// A recovery-locked device is `.notConfigured`, so it offers "set up app lock". Tapping that
    /// must not destroy the only route back to the corpus.
    @Test func settingUpANewLockWhileAwaitingRecoveryKeepsTheRouteBack() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }
        let relaunched = fixture.harness.makeService()
        #expect(relaunched.isAwaitingCustodianRecovery)

        try await relaunched.configure(credential: .pin6("999999"), grantingScope: .privateHub)

        #expect(relaunched.hasRecoveryCustodian)
        #expect(relaunched.custodianRecoveryBlob != nil)
        // …and the blob still opens to the ORIGINAL key, not the one the new lock just minted.
        #expect(try fixture.custodianOpensTheBlob() == fixture.contentKey)
        // Which is exactly why the enrollment is now marked SUPERSEDED: the route back to the
        // pre-lock corpus survives, but the blob cannot open a byte written under this new lock.
        #expect(relaunched.hasSupersededRecoveryBlob)
    }

    /// The other half of the state above. `hasRecoveryCustodian` proves three rows exist, so on its
    /// own it would let the user arm `.recoveryLock` again over a blob that hands back the
    /// SUPERSEDED key — the response would destroy the live key and the ceremony would report
    /// success while orphaning everything written under the interim lock.
    @Test func aSupersededRecoveryBlobMayNotBeArmedAgain() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }
        let relaunched = fixture.harness.makeService()
        try await relaunched.configure(credential: .pin6("999999"), grantingScope: .privateHub)
        #expect(relaunched.hasSupersededRecoveryBlob)

        do {
            try await relaunched.configureDuress(pin: "654321", mode: .recoveryLock)
            Issue.record("a superseded recovery blob was armed again")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.recoveryCustodianSupersededMessage)
        }
        #expect(!relaunched.hasDuressConfigured)
        // The non-destructive responses are unaffected — the refusal is about this one pairing.
        try await relaunched.configureDuress(pin: "654321", mode: .decoy)
        #expect(relaunched.configuredDuressMode == .decoy)
        // …and the setup screen withholds the option for the same reason, with a reason to show.
        let availability = DuressSetupAvailability(lockService: relaunched)
        #expect(availability.hasRecoveryCustodian)
        #expect(availability.hasSupersededRecoveryBlob)
        #expect(!availability.isSelectable(.recoveryLock))
        #expect(availability.unavailableReason(for: .recoveryLock)?.contains("before this app lock") == true)
    }

    /// The way out: enrolling the custodian again re-seals to the LIVE content key, so the mark
    /// clears and the response becomes armable.
    @Test func reEnrollingClearsTheSupersededMark() async throws {
        let fixture = try await triggeredFixture()
        defer { fixture.cleanup() }
        let relaunched = fixture.harness.makeService()
        try await relaunched.configure(credential: .pin6("999999"), grantingScope: .privateHub)
        #expect(relaunched.hasSupersededRecoveryBlob)

        let custodianKeyAgreement = fixture.custodianIdentity.localKeyAgreementPublicKey
        let primary = fixture.primaryIdentity
        try await relaunched.enrollRecoveryCustodian(
            passcode: "999999",
            signingPublicKey: fixture.custodianIdentity.localSigningPublicKey,
            keyAgreementPublicKey: custodianKeyAgreement,
            ownKeyAgreementPublicKey: primary.localKeyAgreementPublicKey
        ) { contentKey in
            try primary.seal(contentKey, to: custodianKeyAgreement, format: .wire2)
        }

        #expect(!relaunched.hasSupersededRecoveryBlob)
        try await relaunched.configureDuress(pin: "654321", mode: .recoveryLock)
        #expect(relaunched.configuredDuressMode == .recoveryLock)
    }

    /// `configure` is FIRST-TIME setup, and its mint destroys the only copies of the live content
    /// key — so over a lock that still exists it is refused outright rather than allowed to sweep.
    /// The custodian material survives the refusal, because a refusal must change nothing.
    @Test func configuringOverALiveLockIsRefusedAndKeepsTheRecoveryMaterial() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.enrollCustodian()
        #expect(fixture.service.hasRecoveryCustodian)

        await #expect(throws: FernletLockError.self) {
            try await fixture.service.configure(credential: .pin6("999999"), grantingScope: .privateHub)
        }

        #expect(fixture.service.hasRecoveryCustodian)
        #expect(recoveryRow(.custodianSigningPublicKey, fixture.harness) != nil)
        #expect(fixture.service.custodianRecoveryBlob != nil)
        // …and the lock the refusal protected is still the ORIGINAL one.
        fixture.service.lock(reason: .manual)
        _ = try await fixture.service.unlock(passcode: "123456", for: .privateHub)
        let key = try #require(fixture.service.contentKey(for: .privateHub))
        #expect(key.withUnsafeBytes { Data($0) } == fixture.contentKey)
    }

    /// The legitimate re-setup route, end to end: `reset()` sweeps every row under the lock's
    /// keychain service — the recovery material with them — so the fresh `configure` that follows
    /// is a first-time setup again, and it lands with no custodian enrolled against it.
    @Test func aResetThenAFreshConfigureLeavesNoRecoveryMaterial() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.enrollCustodian()

        try fixture.service.reset()

        // The sweep is `reset()`'s own `KeychainItem.deleteAll`, before any re-mint runs.
        #expect(!fixture.service.hasRecoveryCustodian)
        #expect(recoveryRow(.custodianSigningPublicKey, fixture.harness) == nil)
        #expect(recoveryRow(.recoveryBlob, fixture.harness) == nil)

        try await fixture.service.configure(credential: .pin6("999999"), grantingScope: .privateHub)

        #expect(!fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.custodianRecoveryBlob == nil)
        #expect(!fixture.service.hasSupersededRecoveryBlob)
    }
}

// MARK: - Step 7: re-establishing the unlock

/// The tail of the ceremony, in the lock: turning recovered bytes back into a working lock, and
/// refusing anything that is not those bytes.
@MainActor
@Suite(.serialized)
struct DuressRecoveryReestablishTests {

    private func recoveryLockedFixture() async throws -> RecoveryFixture {
        let fixture = try await RecoveryFixture()
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        fixture.service.lock(reason: .manual)
        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)
        return fixture
    }

    /// The whole point, end to end: the corpus opens again.
    @Test func reestablishingUnderANewPasscodeReopensTheSealedCorpus() async throws {
        let fixture = try await recoveryLockedFixture()
        defer { fixture.cleanup() }
        let recovered = try fixture.custodianOpensTheBlob()

        try await fixture.service.reestablishLocalUnlock(
            contentKey: recovered,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )

        let key = try #require(fixture.service.contentKey(for: .privateHub))
        #expect(key.withUnsafeBytes { Data($0) } == fixture.contentKey)
        let box = try ChaChaPoly.SealedBox(combined: fixture.sealedCorpusRow)
        #expect(try ChaChaPoly.open(box, using: key) == RecoveryFixture.corpusPlaintext)
        // The decoy session ends: this is a proven real-credential act.
        #expect(!fixture.service.isDuressSessionActive)
    }

    /// The NEW passcode is the passcode now — and the old one, and the spent duress PIN, are not.
    @Test func theRebuiltLockAnswersOnlyToTheNewCredential() async throws {
        let fixture = try await recoveryLockedFixture()
        defer { fixture.cleanup() }
        let recovered = try fixture.custodianOpensTheBlob()
        try await fixture.service.reestablishLocalUnlock(
            contentKey: recovered,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )
        fixture.service.lock(reason: .manual)

        _ = try await fixture.service.unlock(passcode: "222222", for: .privateHub)
        let key = try #require(fixture.service.contentKey(for: .privateHub))
        #expect(key.withUnsafeBytes { Data($0) } == fixture.contentKey)

        fixture.service.lock(reason: .manual)
        await #expect(throws: FernletLockError.self) {
            _ = try await fixture.service.unlock(passcode: "123456", for: .privateHub)
        }
        // The spent duress PIN is not a decoy trigger any more either — the rows went with the
        // trigger, so it is simply a wrong passcode.
        await #expect(throws: FernletLockError.self) {
            _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)
        }
        #expect(!fixture.service.isDuressSessionActive)
    }

    /// A custodian that returns the wrong bytes — a bug, a stale blob, another corpus — must not
    /// silently re-lock the device around a key that opens nothing.
    @Test func reestablishingRefusesAKeyThatIsNotTheOneTheBlobSeals() async throws {
        let fixture = try await recoveryLockedFixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reestablishLocalUnlock(
                contentKey: Data(repeating: 0x7E, count: 32),
                credential: .pin6("222222"),
                grantingScope: .privateHub
            )
            Issue.record("a key the recovery blob does not seal was installed")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.recoveryKeyMismatchMessage)
        }
        // Nothing was written: the device is still awaiting its real recovery.
        #expect(recoveryRow(.salt, fixture.harness) == nil)
        #expect(fixture.service.isAwaitingCustodianRecovery)
    }

    @Test func reestablishingRefusesWhenThereIsNoRecoveryMaterialAtAll() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reestablishLocalUnlock(
                contentKey: fixture.contentKey,
                credential: .pin6("222222"),
                grantingScope: .privateHub
            )
            Issue.record("a recovery ran on a device that never enrolled a custodian")
        } catch FernletLockError.invalidCredential(let message) {
            #expect(message == FernletLockService.recoveryNotAvailableMessage)
        }
    }

    /// The custodian stays enrolled: the blob seals the very key just installed, so re-running the
    /// QR ceremony would buy nothing and leaving the user unprotected would cost something.
    @Test func reestablishingKeepsTheEnrolledCustodian() async throws {
        let fixture = try await recoveryLockedFixture()
        defer { fixture.cleanup() }
        let recovered = try fixture.custodianOpensTheBlob()

        try await fixture.service.reestablishLocalUnlock(
            contentKey: recovered,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )

        #expect(fixture.service.hasRecoveryCustodian)
        #expect(try fixture.custodianOpensTheBlob() == fixture.contentKey)
        #expect(!fixture.service.isAwaitingCustodianRecovery)
    }

    /// A sysdiagnose pulled afterwards must not read as "a recovery happened here", which would
    /// disclose that a duress PIN existed. The recovery emits exactly what a first-time setup emits.
    @Test func reestablishingEmitsTheSameAuditLineAsAFreshSetup() async throws {
        let fixture = try await recoveryLockedFixture()
        defer { fixture.cleanup() }
        let recovered = try fixture.custodianOpensTheBlob()
        let capture = RecoveryAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        try await fixture.service.reestablishLocalUnlock(
            contentKey: recovered,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )

        #expect(capture.contains(event: "lock.configured", context: ["kind": "pin6", "scope": "privateHub"]))
        for needle in ["duress", "recovery", "custodian", "decoy", "reestablish"] {
            #expect(!capture.anyEventNameContains(needle),
                    "an event name mentioning '\(needle)' would disclose the duress feature")
        }
    }
}

// MARK: - Step 8: the ceremonies

/// The app-side coordinator, driven as two devices: one `DuressRecoveryCoordinator` per identity,
/// passing the payloads each step returns by hand — which is exactly what the mesh will do.
@MainActor
@Suite(.serialized)
struct DuressRecoveryCeremonyTests {

    /// Two coordinators over two identities, plus the primary's lock.
    @MainActor
    private final class Pair {
        let fixture: RecoveryFixture
        let primary: DuressRecoveryCoordinator
        let custodian: DuressRecoveryCoordinator
        /// The custodian's own lock — never touched by the ceremony, but the coordinator needs one.
        let custodianHarness = LockTestHarness()

        init(fixture: RecoveryFixture, clock: @escaping () -> Date) {
            self.fixture = fixture
            primary = DuressRecoveryCoordinator(
                identity: fixture.primaryIdentity,
                lockService: fixture.service,
                now: clock
            )
            custodian = DuressRecoveryCoordinator(
                identity: fixture.custodianIdentity,
                lockService: custodianHarness.makeService(),
                now: clock
            )
        }

        func cleanup() {
            fixture.cleanup()
            custodianHarness.cleanup()
        }
    }

    private func makePair(clock: @escaping () -> Date = Date.init) async throws -> Pair {
        Pair(fixture: try await RecoveryFixture(), clock: clock)
    }

    /// Runs the QR + challenge/response round from the custodian's display to the primary's proof.
    private func runVerificationRound(
        _ pair: Pair,
        beginning: (URL) throws -> VerifyChallengePayload
    ) throws -> VerifyResponsePayload {
        let url = try #require(pair.custodian.makeDisplayURL())
        let challenge = try beginning(url)
        let response = try #require(pair.custodian.handleChallenge(
            challenge,
            senderKeyAgreementPublicKey: pair.fixture.primaryIdentity.localKeyAgreementPublicKey
        ))
        return response
    }

    // MARK: Enrollment

    @Test func theEnrollmentCeremonySealsTheContentKeyToTheScannedDevice() async throws {
        let pair = try await makePair()
        defer { pair.cleanup() }

        let response = try runVerificationRound(pair) { try pair.primary.beginCustodianEnrollment(scannedURL: $0) }
        try await pair.primary.completeCustodianEnrollment(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey,
            passcode: "123456"
        )

        #expect(pair.fixture.service.hasRecoveryCustodian)
        #expect(try pair.fixture.custodianOpensTheBlob() == pair.fixture.contentKey)
    }

    /// A device cannot be its own custodian: the blob would be sealed to a key that SURVIVES the
    /// destruction, i.e. a second copy of the content key left on the coerced phone.
    @Test func enrollmentRefusesThisDevicesOwnCode() async throws {
        let pair = try await makePair()
        defer { pair.cleanup() }
        // The primary displays its own QR and then scans it.
        let ownURL = try #require(pair.primary.makeDisplayURL())

        #expect(throws: DuressRecoveryError.selfEnrollmentRefused) {
            _ = try pair.primary.beginCustodianEnrollment(scannedURL: ownURL)
        }
        #expect(!pair.fixture.service.hasRecoveryCustodian)
    }

    @Test func enrollmentRefusesAStaleOrForgedCode() async throws {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let pair = try await makePair(clock: { now })
        defer { pair.cleanup() }
        let url = try #require(pair.custodian.makeDisplayURL())

        // Past the QR's freshness window — a photographed code is not a present device.
        now = now.addingTimeInterval(ProximityVerifyQR.freshnessWindow + 60)
        #expect(throws: DuressRecoveryError.invalidQRCode) {
            _ = try pair.primary.beginCustodianEnrollment(scannedURL: url)
        }
        #expect(throws: DuressRecoveryError.invalidQRCode) {
            _ = try pair.primary.beginCustodianEnrollment(scannedURL: URL(string: "fernlet://verify?d=nonsense")!)
        }
    }

    /// The challenge response is what proves the live peer HOLDS the key the QR displayed; a
    /// response from anyone else must not complete an enrollment.
    @Test func enrollmentRefusesAResponseFromADifferentDevice() async throws {
        let pair = try await makePair()
        defer { pair.cleanup() }
        let interloper = try makeThrowawayIdentity()
        defer { try? interloper.wipe() }

        let url = try #require(pair.custodian.makeDisplayURL())
        let challenge = try pair.primary.beginCustodianEnrollment(scannedURL: url)
        let forged = VerifyResponsePayload(
            challengeNonce: challenge.challengeNonce,
            signature: Data(repeating: 0, count: 64)
        )

        await #expect(throws: DuressRecoveryError.challengeResponseRejected) {
            try await pair.primary.completeCustodianEnrollment(
                response: forged,
                senderSigningPublicKey: interloper.localSigningPublicKey,
                passcode: "123456"
            )
        }
        #expect(!pair.fixture.service.hasRecoveryCustodian)
    }

    // MARK: Recovery

    /// Enrolls, fires the recovery-lock, and returns the pair mid-decoy.
    private func recoveryLockedPair() async throws -> Pair {
        let pair = try await makePair()
        let response = try runVerificationRound(pair) { try pair.primary.beginCustodianEnrollment(scannedURL: $0) }
        try await pair.primary.completeCustodianEnrollment(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey,
            passcode: "123456"
        )
        try await pair.fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        pair.fixture.service.lock(reason: .manual)
        _ = try await pair.fixture.service.unlock(passcode: "654321", for: .privateHub)
        return pair
    }

    @Test func theRecoveryCeremonyReturnsTheExactKeyAndRebuildsTheUnlock() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let primaryKA = pair.fixture.primaryIdentity.localKeyAgreementPublicKey

        let response = try runVerificationRound(pair) { try pair.primary.beginRecovery(scannedURL: $0) }
        let sealedRequest = try pair.primary.makeRecoveryRequest(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey
        )
        let summary = try pair.custodian.openRecoveryRequest(sealedRequest, from: primaryKA)
        #expect(summary.requesterFingerprint == IdentityService.fingerprint(of: pair.fixture.primaryIdentity.localSigningPublicKey))
        let sealedReply = try pair.custodian.answerPendingRecoveryRequest(.returnKey)
        let outcome = try await pair.primary.completeRecovery(
            sealedReply: sealedReply,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )

        #expect(outcome == .unlockReestablished)
        let key = try #require(pair.fixture.service.contentKey(for: .privateHub))
        #expect(key.withUnsafeBytes { Data($0) } == pair.fixture.contentKey)
        let box = try ChaChaPoly.SealedBox(combined: pair.fixture.sealedCorpusRow)
        #expect(try ChaChaPoly.open(box, using: key) == RecoveryFixture.corpusPlaintext)
    }

    /// "Some device proved it holds the key it displayed" is not recovery — recovery is with the
    /// ENROLLED custodian, and the difference is what stops a stranger's phone from handing back
    /// bytes that would be installed as the content key.
    @Test func recoveryRefusesAQRFromADeviceThatIsNotTheEnrolledCustodian() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let interloperIdentity = try makeThrowawayIdentity()
        defer { try? interloperIdentity.wipe() }
        let interloperHarness = LockTestHarness()
        defer { interloperHarness.cleanup() }
        let interloper = DuressRecoveryCoordinator(
            identity: interloperIdentity,
            lockService: interloperHarness.makeService()
        )
        let strangerURL = try #require(interloper.makeDisplayURL())

        #expect(throws: DuressRecoveryError.notTheEnrolledCustodian) {
            _ = try pair.primary.beginRecovery(scannedURL: strangerURL)
        }
    }

    /// `IdentityService.seal` gives confidentiality, NOT sender authentication — anyone can seal to
    /// a public key. Without the reply signature, a stranger could seal a `.destroy` instruction to
    /// the primary and have it obeyed. This is the test that says they cannot.
    @Test func aForgedReplyFromAStrangerIsRejected() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let interloper = try makeThrowawayIdentity()
        defer { try? interloper.wipe() }

        let response = try runVerificationRound(pair) { try pair.primary.beginRecovery(scannedURL: $0) }
        _ = try pair.primary.makeRecoveryRequest(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey
        )
        // A stranger seals a well-formed `.destroy` reply straight to the primary's public key.
        let forged = DuressRecoveryReply(
            version: 1,
            challengeNonce: response.challengeNonce,
            decision: .destroy,
            contentKey: Data(),
            signature: Data(repeating: 0, count: 64)
        )
        let sealed = try interloper.seal(
            try JSONEncoder().encode(forged),
            to: pair.fixture.primaryIdentity.localKeyAgreementPublicKey,
            format: .wire2
        )

        await #expect(throws: DuressRecoveryError.self) {
            _ = try await pair.primary.completeRecovery(
                sealedReply: sealed,
                credential: .pin6("222222"),
                grantingScope: .privateHub
            )
        }
        #expect(pair.fixture.service.isAwaitingCustodianRecovery)
    }

    /// The new passcode is format-checked BEFORE the ceremony round is spent.
    ///
    /// `reestablishLocalUnlock` validates it too, but it used to do so after `completeRecovery` had
    /// already cleared `pendingRound` (and after the custodian had consumed its pending request), so
    /// a five-digit "6-digit PIN" or an empty field threw into a dead end: the re-shown step could
    /// only raise `.noRoundInProgress`, and both phones had to redo every QR hop. Refusing first
    /// keeps the retry the error invites actually usable.
    @Test func aMalformedNewPasscodeIsRefusedBeforeTheCeremonyRoundIsSpent() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let primaryKA = pair.fixture.primaryIdentity.localKeyAgreementPublicKey

        let response = try runVerificationRound(pair) { try pair.primary.beginRecovery(scannedURL: $0) }
        let sealedRequest = try pair.primary.makeRecoveryRequest(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey
        )
        _ = try pair.custodian.openRecoveryRequest(sealedRequest, from: primaryKA)
        let sealedReply = try pair.custodian.answerPendingRecoveryRequest(.returnKey)

        // A PIN that is not six digits — the one input the human types, with no client-side length
        // gate on the field.
        do {
            _ = try await pair.primary.completeRecovery(
                sealedReply: sealedReply,
                credential: .pin6("22222"),
                grantingScope: .privateHub
            )
            Issue.record("a malformed new passcode completed a recovery")
        } catch FernletLockError.invalidCredential {
            // Expected — and, crucially, raised before the round was spent.
        }
        #expect(pair.fixture.service.isAwaitingCustodianRecovery)

        // The round survived, so the SAME sealed reply completes the recovery on the retry the error
        // invites — no second trip through the QR hops on either phone.
        let outcome = try await pair.primary.completeRecovery(
            sealedReply: sealedReply,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )
        #expect(outcome == .unlockReestablished)
        let key = try #require(pair.fixture.service.contentKey(for: .privateHub))
        #expect(key.withUnsafeBytes { Data($0) } == pair.fixture.contentKey)
    }

    /// A `destroy` answer is REPORTED, never acted on here: destroying the corpus is an explicit,
    /// user-visible act of the app's own funnel, not something a message from another phone performs.
    @Test func aDestroyAnswerIsReportedWithoutOpeningTheBlobOrTouchingTheLock() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let primaryKA = pair.fixture.primaryIdentity.localKeyAgreementPublicKey

        let response = try runVerificationRound(pair) { try pair.primary.beginRecovery(scannedURL: $0) }
        let sealedRequest = try pair.primary.makeRecoveryRequest(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey
        )
        _ = try pair.custodian.openRecoveryRequest(sealedRequest, from: primaryKA)
        let sealedReply = try pair.custodian.answerPendingRecoveryRequest(.destroy)
        let outcome = try await pair.primary.completeRecovery(
            sealedReply: sealedReply,
            credential: .pin6("222222"),
            grantingScope: .privateHub
        )

        #expect(outcome == .destructionRequested)
        // Nothing was rebuilt, and nothing was destroyed by the coordinator either.
        #expect(pair.fixture.service.isAwaitingCustodianRecovery)
        #expect(pair.fixture.service.contentKey(for: .privateHub) == nil)
        #expect(pair.fixture.service.hasRecoveryCustodian)
    }

    /// The custodian must not be a decrypt-on-demand service for a blob somebody else is holding: a
    /// request is honored only inside the live ceremony round this device just answered.
    @Test func theCustodianRefusesARequestForwardedIntoADifferentRound() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let primaryKA = pair.fixture.primaryIdentity.localKeyAgreementPublicKey

        // The genuine primary composes a request in its own round…
        let response = try runVerificationRound(pair) { try pair.primary.beginRecovery(scannedURL: $0) }
        let sealedRequest = try pair.primary.makeRecoveryRequest(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey
        )
        // …and someone who captured those bytes replays them after a LATER round with the custodian.
        let laterURL = try #require(pair.custodian.makeDisplayURL())
        let laterPayload = try #require(ProximityVerifyQR.parse(laterURL))
        let laterChallenge = VerifyChallengePayload(
            qrNonce: laterPayload.nonce,
            challengeNonce: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        )
        _ = pair.custodian.handleChallenge(laterChallenge, senderKeyAgreementPublicKey: primaryKA)

        #expect(throws: DuressRecoveryError.malformedPayload) {
            _ = try pair.custodian.openRecoveryRequest(sealedRequest, from: primaryKA)
        }
    }

    /// The custodian answers into the round it proved, so a cold request — no ceremony at all — is
    /// refused before the sealed body is even opened.
    @Test func theCustodianRefusesARequestWithNoCeremonyAtAll() async throws {
        let pair = try await recoveryLockedPair()
        defer { pair.cleanup() }
        let primaryKA = pair.fixture.primaryIdentity.localKeyAgreementPublicKey
        let response = try runVerificationRound(pair) { try pair.primary.beginRecovery(scannedURL: $0) }
        let sealedRequest = try pair.primary.makeRecoveryRequest(
            response: response,
            senderSigningPublicKey: pair.fixture.custodianIdentity.localSigningPublicKey
        )
        // The sheet closed; nothing is being displayed and no round is proven.
        pair.custodian.clearDisplay()

        #expect(throws: DuressRecoveryError.noRoundInProgress) {
            _ = try pair.custodian.openRecoveryRequest(sealedRequest, from: primaryKA)
        }
    }

    /// Recovery on a device that never enrolled anyone has nothing to scan FOR.
    @Test func recoveryRefusesOnADeviceWithNoCustodian() async throws {
        let pair = try await makePair()
        defer { pair.cleanup() }
        let url = try #require(pair.custodian.makeDisplayURL())

        #expect(throws: DuressRecoveryError.noRecoveryMaterial) {
            _ = try pair.primary.beginRecovery(scannedURL: url)
        }
    }
}

// MARK: - Audit capture

/// A local `FernletAuditLog` sink. The registry is process-global and other suites emit into it
/// concurrently, so every assertion is phrased as "contains" or "contains nothing named…", never as
/// an equality over the whole captured stream.
private final class RecoveryAuditCapture {
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

    func contains(event: String, context: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.event == event && $0.context == context }
    }

    func anyEventNameContains(_ needle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.event.localizedCaseInsensitiveContains(needle) }
    }
}

// MARK: - The enrollment's OTHER dependency: this device's own proximity identity

/// The recovery blob is sealed with THIS device's long-term key-agreement key mixed into the
/// derivation and the AEAD's additional data, and the custodian opens it with the live,
/// ceremony-proven sender key. So the enrollment silently dies the moment this device's identity
/// rotates — and "Delete everything" rotates it while deliberately KEEPING the app lock, the content
/// key and the recovery rows.
///
/// Nothing in `FernletLock` can see that happen (it has no ProximityKit edge, by design), which is
/// why the enrollment records the owner key and the app-side coordinator does the comparing. Without
/// this reconcile the phone would keep `DuressMode.recoveryLock` armed over a blob no device on earth
/// can open: firing it destroys every local unlock key for a ceremony that can only end in
/// "this phone can't open that request" — the unannounced permanent lock-out the mode's fail-closed
/// guard exists to prevent.
@MainActor
@Suite(.serialized)
struct DuressRecoveryIdentityRotationTests {

    @Test func rotatingThisDevicesIdentityRetiresTheEnrollmentAndDisarmsTheResponse() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)
        #expect(fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.enrolledRecoveryOwnerKeyAgreementPublicKey
                == fixture.primaryIdentity.localKeyAgreementPublicKey)

        // What `FernletStore.deleteAllData` does to the identity, and only that: the lock keychain,
        // the content key and the recovery rows all survive it.
        try fixture.primaryIdentity.wipe()
        try fixture.primaryIdentity.ensureProvisioned()
        #expect(fixture.service.hasRecoveryCustodian, "precondition: the wipe leaves the lock rows alone")

        let coordinator = DuressRecoveryCoordinator(
            identity: fixture.primaryIdentity,
            lockService: fixture.service
        )
        #expect(coordinator.reconcileEnrollmentWithLocalIdentity())

        // The dead enrollment is gone…
        #expect(!fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.custodianRecoveryBlob == nil)
        #expect(recoveryRow(.recoveryOwnerKeyAgreementPublicKey, fixture.harness) == nil)
        // …and the armed response degraded to the NON-destructive decoy rather than staying a
        // promise the device can no longer keep.
        #expect(fixture.service.configuredDuressMode == .decoy)

        // Which is what the coerced user actually gets: a decoy, with the real key untouched.
        fixture.service.lock(reason: .manual)
        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)
        #expect(fixture.service.isDuressSessionActive)
        #expect(recoveryRow(.verifier, fixture.harness) != nil, "the local unlock keys must survive")
        _ = try await fixture.service.unlock(passcode: "123456", for: .privateHub)
        let recovered = try #require(fixture.service.contentKey(for: .privateHub))
        #expect(recovered.withUnsafeBytes { Data($0) } == fixture.contentKey)
    }

    @Test func anUnchangedIdentityLeavesTheEnrollmentAlone() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.enrollCustodian()
        try await fixture.service.configureDuress(pin: "654321", mode: .recoveryLock)

        let coordinator = DuressRecoveryCoordinator(
            identity: fixture.primaryIdentity,
            lockService: fixture.service
        )
        #expect(!coordinator.reconcileEnrollmentWithLocalIdentity())
        #expect(!coordinator.reconcileEnrollmentWithLocalIdentity(), "idempotent")

        #expect(fixture.service.hasRecoveryCustodian)
        #expect(fixture.service.configuredDuressMode == .recoveryLock)
        #expect(try fixture.custodianOpensTheBlob() == fixture.contentKey)
    }

    /// A device with no enrollment has nothing to reconcile, and a reconcile must never be the
    /// reason an enrollment disappears on a read that simply failed.
    @Test func reconcileIsANoOpWithoutAnEnrollment() async throws {
        let fixture = try await RecoveryFixture()
        defer { fixture.cleanup() }

        let coordinator = DuressRecoveryCoordinator(
            identity: fixture.primaryIdentity,
            lockService: fixture.service
        )
        #expect(!coordinator.reconcileEnrollmentWithLocalIdentity())
        #expect(!fixture.service.hasRecoveryCustodian)
    }
}
