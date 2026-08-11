// DuressDecoyAndWipeTests.swift
// FernletTests
//
// Phase 7 (duress PIN), steps 5–6: the DECOY's app half — the sensitive-surface gates the store
// forces shut while a duress session is in force — and the SILENT WIPE's crypto-erase.
//
// Two properties are being pinned here, and they pull in opposite directions, which is why they
// share a file:
//
//   * The DECOY must change NOTHING on disk. It is an in-memory flag riding the existing hide
//     machinery, so entering the real passcode puts every surface back exactly as it was. A decoy
//     that persisted its forced-hidden visibility would be silent data hiding — and would reach the
//     sealed-backup toggles that DELETE the user's iCloud backup.
//   * The WIPE must change EVERYTHING on disk, irreversibly, in the milliseconds before the coercer
//     notices — and must then look like nothing happened, which is why a throwaway empty lock is
//     re-minted under the same PIN.
//
// The lock-level tests use a UUID-scoped keychain service via `LockTestHarness` (shared with
// FernletLockServiceTests) and clean up after themselves; nothing here touches the production
// service. The store-level tests write to a temporary JSON repository.

import CryptoKit
import Foundation
import Security
import Testing
import FernletDomainModel
import FernletFoundation
import HealthKitGateway
import LocalPersistence
import PrivateHealthStore
@testable import Fernlet
@testable import FernletLock

// MARK: - Step 5: the decoy's app half

/// The store-side half of the DECOY: `duressSessionActive` forces the sensitive-surface gates shut
/// without touching a single stored preference.
@MainActor
@Suite(.serialized)
struct DuressDecoyVisibilityTests {

    private func makeStore(_ name: String) -> FernletStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
        return FernletStore(repository: LocalFernletRepository(fileURL: url))
    }

    /// Puts the device-local age record above the 16+ intimacy gate, so the intimacy assertions are
    /// about the duress flag rather than about age.
    private func seedAgeMeetingIntimacyGate(_ store: FernletStore) {
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.intimacy.minimumAge,
            upperBound: nil,
            provenance: .selfDeclared
        )
    }

    /// Puts a store in the state the decoy has to defeat: both surfaces explicitly VISIBLE, the hub
    /// unlocked, and a day record holding live cycle + intimate context.
    private func makeFullyVisibleStore(_ name: String) -> FernletStore {
        let store = makeStore(name)
        seedAgeMeetingIntimacyGate(store)
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true
        // The decoy unlock IS an unlock — `state == .unlocked(scope: .privateHub)` — so the lock
        // gate in `allowedHealthCapabilities` is deliberately open here. Anything that closes below
        // is the VISIBILITY gate doing it, which is the half this phase adds.
        store.lockState = .unlocked(scope: .privateHub)
        return store
    }

    /// The core of the decoy: an explicit "yes, show me these" preference is overridden while the
    /// flag is up, and honored again the moment it drops.
    @Test func duressSessionForcesBothSensitiveGatesShutRegardlessOfSettings() {
        let store = makeFullyVisibleStore("duress-gates")
        #expect(store.isPeriodTrackingVisible)
        #expect(store.isIntimacyTrackingVisible)

        store.duressSessionActive = true

        #expect(!store.isPeriodTrackingVisible)
        #expect(!store.isIntimacyTrackingVisible)
        #expect(!store.sensitiveSurfaceVisibility.period)
        #expect(!store.sensitiveSurfaceVisibility.intimacy)
        // The preferences themselves are untouched — the gate is a read-time AND, not a write.
        #expect(store.settings.periodTrackingVisible == true)
        #expect(store.settings.intimacyTrackingVisible)
    }

    /// `sex == .female` with no explicit choice is the OTHER way period tracking becomes visible.
    /// The flag has to beat the derived value too, or a user who never opened Settings gets no decoy.
    @Test func duressSessionBeatsTheDerivedPeriodVisibilityToo() {
        let store = makeStore("duress-gates-derived")
        store.settings.periodTrackingVisible = nil
        store.settings.userProfile.sex = .female
        #expect(store.isPeriodTrackingVisible)

        store.duressSessionActive = true
        #expect(!store.isPeriodTrackingVisible)
        // Still no explicit choice written: the derived path is untouched.
        #expect(store.settings.periodTrackingVisible == nil)
    }

    /// G4, the ambient-read gate. Home requests EVERY capability on each appearance, so this is what
    /// stops HealthKit cycle/intimate samples being read out on a path no view drives — including
    /// `HomeView`'s second `HealthKitService` and the ungated cycle-outlook card.
    @Test func duressSessionDropsCycleAndIntimateFromTheAllowedHealthCapabilities() {
        let store = makeFullyVisibleStore("duress-capabilities")
        let requested = Set(HealthCapability.allCases)
        #expect(store.allowedHealthCapabilities(from: requested).contains(.cycleTracking))
        #expect(store.allowedHealthCapabilities(from: requested).contains(.intimateLogging))

        store.duressSessionActive = true

        let allowed = store.allowedHealthCapabilities(from: requested)
        #expect(!allowed.contains(.cycleTracking))
        #expect(!allowed.contains(.intimateLogging))
        // Everything else is untouched — a decoy that dropped step counts would be conspicuous.
        #expect(allowed.contains(.activityContext))
        #expect(allowed.contains(.workoutLogging))
        // …and Settings > Health stops offering the rows whose "Update data" action would re-read
        // HealthKit and undo the scrub below.
        #expect(!store.visibleHealthCapabilities.contains(.cycleTracking))
        #expect(!store.visibleHealthCapabilities.contains(.intimateLogging))
    }

    /// The scrub has to fire off the VALUE, not off a setter — the decoy never calls
    /// `setPeriodTrackingVisible`, so a scrub keyed to the toggle would leave the day's resident
    /// cycle/intimate context live behind a hidden UI.
    @Test func duressSessionScrubsResidentHealthContextThroughTheValueFlip() {
        let store = makeFullyVisibleStore("duress-scrub")
        store.day.healthContext = HealthDailyContext(
            cycle: HealthCycleContext(),
            intimate: HealthIntimateContext()
        )
        let scrubbedPeriodState = DuressTestFlag()
        store.periodScrubHook = { scrubbedPeriodState.raise() }

        let before = store.sensitiveSurfaceVisibility
        store.duressSessionActive = true
        let after = store.sensitiveSurfaceVisibility
        // The value genuinely changed, which is what drives ContentView's `.onChange`.
        #expect(before != after)
        // Stands in for `.onChange(of: store.sensitiveSurfaceVisibility)`.
        if !after.period { store.periodScrubHook?() }
        store.scrubHiddenHealthContext()

        #expect(scrubbedPeriodState.isRaised, "the cycle-state scrub (entries + bridge trends) must run")
        #expect(store.day.healthContext?.cycle == nil)
        #expect(store.day.healthContext?.intimate == nil)
    }

    /// Reversibility is the decoy's defining property: the real passcode clears the flag and every
    /// surface comes straight back, because nothing was ever written.
    @Test func clearingTheDuressFlagRestoresEverySurface() {
        let store = makeFullyVisibleStore("duress-reversible")

        store.duressSessionActive = true
        #expect(!store.isPeriodTrackingVisible)
        #expect(!store.isIntimacyTrackingVisible)

        store.duressSessionActive = false

        #expect(store.isPeriodTrackingVisible)
        #expect(store.isIntimacyTrackingVisible)
        let allowed = store.allowedHealthCapabilities(from: Set(HealthCapability.allCases))
        #expect(allowed.contains(.cycleTracking))
        #expect(allowed.contains(.intimateLogging))
    }

    /// **The hazard test.** A decoy that persisted its forced-hidden visibility would stop being a
    /// decoy and become silent data hiding — and `setPeriodTrackingVisible(false)` is wired to the
    /// sealed-backup machinery, so it could reach a path that DELETES the user's iCloud backup. The
    /// settings blob must come out of a decoy session byte-identical to how it went in.
    @Test func aDecoySessionPersistsNothingIntoTheSettingsBlob() throws {
        let store = makeFullyVisibleStore("duress-persists-nothing")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(store.settings)

        store.duressSessionActive = true
        // Exercise every read path a decoy session actually takes, so a lazily-persisting getter
        // would be caught rather than merely unexercised.
        _ = store.isPeriodTrackingVisible
        _ = store.isIntimacyTrackingVisible
        _ = store.sensitiveSurfaceVisibility
        _ = store.visibleHealthCapabilities
        _ = store.allowedHealthCapabilities(from: Set(HealthCapability.allCases))
        store.duressSessionActive = false

        let after = try encoder.encode(store.settings)
        #expect(after == before, "the decoy wrote a preference — it must gate on the in-memory flag ONLY")
    }

    /// End-to-end over the real seam: a duress unlock on a real `FernletLockService`, mirrored into
    /// the store exactly as `ContentView` mirrors it. This is what proves the two halves are wired
    /// to the same flag rather than merely agreeing in the abstract.
    @Test func aRealDuressUnlockClosesTheStoreGatesAndARealUnlockReopensThem() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        let store = makeFullyVisibleStore("duress-endtoend")

        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .decoy)
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        // Stands in for ContentView's `.onChange(of: lockService.isDuressSessionActive)`.
        store.duressSessionActive = service.isDuressSessionActive
        store.lockState = service.state

        #expect(store.lockState == .unlocked(scope: .privateHub), "the decoy must look like an unlock")
        #expect(!store.isPeriodTrackingVisible)
        #expect(!store.isIntimacyTrackingVisible)
        // Keyless: the sealed surfaces have no key to render with either.
        #expect(service.contentKey(for: .privateHub) == nil)

        service.lock(reason: .manual)
        // The flag deliberately SURVIVES the re-lock, so the gates stay shut.
        store.duressSessionActive = service.isDuressSessionActive
        #expect(store.duressSessionActive)
        #expect(!store.isPeriodTrackingVisible)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        store.duressSessionActive = service.isDuressSessionActive
        store.lockState = service.state

        #expect(!store.duressSessionActive)
        #expect(store.isPeriodTrackingVisible)
        #expect(store.isIntimacyTrackingVisible)
        #expect(service.contentKey(for: .privateHub) != nil)
    }
}

// MARK: - Step 6: the silent wipe

/// `DuressMode.silentWipe`: the synchronous crypto-erase, the throwaway lock that keeps the decoy
/// convincing across a re-lock, and the fire-and-forget purge hook.
@MainActor
@Suite(.serialized)
struct DuressSilentWipeTests {

    /// Configures a real lock with biometrics enrolled and a silent-wipe duress PIN, and hands back
    /// everything a post-wipe assertion needs to compare against.
    private struct WipeFixture {
        let harness: LockTestHarness
        let service: FernletLockService
        /// The content key the user's real data is sealed under, before the wipe.
        let originalContentKey: Data
        let originalSalt: Data
        let originalVerifier: Data
        /// The Secure-Enclave wrap blob, when this host has an enclave at all.
        let originalSecureEnclaveBlob: Data?
        /// Incremented by the injected `duressPurgeHook`.
        let purgeCount: DuressTestCounter
    }

    private func makeWipeFixture() async throws -> WipeFixture {
        let harness = LockTestHarness()
        var biometricKey = Data()
        let service = harness.makeService { _, _ in biometricKey }
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        let originalContentKey = try #require(service.contentKey(for: .privateHub))
            .withUnsafeBytes { Data($0) }
        biometricKey = originalContentKey
        // Biometrics ON: the `.biometricBypass` row holds the RAW content key, which is the copy a
        // wipe most easily forgets and the one a coercer can use with no PIN at all.
        try await service.setBiometricEnabled(true, passcode: "123456")
        try await service.configureDuress(pin: "654321", mode: .silentWipe)

        let counter = DuressTestCounter()
        service.duressPurgeHook = { counter.increment() }

        return WipeFixture(
            harness: harness,
            service: service,
            originalContentKey: originalContentKey,
            originalSalt: try #require(lockRow(.salt, harness)),
            originalVerifier: try #require(lockRow(.verifier, harness)),
            originalSecureEnclaveBlob: lockRow(.seWrappedContentKey, harness),
            purgeCount: counter
        )
    }

    /// The erase itself. Every row that can lead to the old content key is gone or replaced, and the
    /// biometric bypass — the PIN-free door around the decoy — is simply absent.
    @Test func silentWipeDestroysEveryLocalKeyForTheOldContentKey() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        let harness = fixture.harness
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        // The credential records are the THROWAWAY lock's now, not the user's.
        #expect(lockRow(.salt, harness) != fixture.originalSalt)
        #expect(lockRow(.verifier, harness) != fixture.originalVerifier)
        // Biometrics: both rows destroyed, and never re-enrolled by the re-mint. Read via attributes
        // rather than data — the bypass sits behind an access control.
        #expect(accessControlledRowExists(.biometricBypass, harness) == false)
        #expect(lockRow(.biometricEnabledFlag, harness) == nil)
        #expect(!service.biometricEnabled)
        // The duress PIN itself is consumed: no duress verifier or mode survives the wipe.
        #expect(!service.hasDuressConfigured)
        #expect(lockRow(.duressMode, harness) == nil)
        // Recovery material goes too — a surviving recovery blob is a sealing of the very key this
        // claims to have erased, openable by the custodian device.
        #expect(lockRow(.recoveryBlob, harness) == nil)
        #expect(!service.hasRecoveryCustodian)
    }

    /// "Crypto-erased" means the enclave copy is unopenable, not merely that a blob was replaced.
    /// The SE KEY is a `kSecClassKey` item outside the generic-password rows, so forgetting it would
    /// leave the pre-wipe wrap openable by anyone who kept a copy of the blob.
    @Test func silentWipeDestroysTheSecureEnclaveKeySoTheOldWrapCanNeverBeOpened() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        guard SecureEnclaveContentKeyWrap.isAvailable,
              let originalBlob = fixture.originalSecureEnclaveBlob else {
            // Enclave-less host: there is no hard-bound copy to destroy, and the rest of the wipe is
            // covered by the sibling tests.
            return
        }
        #expect(SecureEnclaveContentKeyWrap.unwrap(originalBlob, service: fixture.harness.serviceID) != nil,
                "precondition: the pre-wipe blob must open before the wipe")
        fixture.service.lock(reason: .manual)

        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)

        #expect(SecureEnclaveContentKeyWrap.unwrap(originalBlob, service: fixture.harness.serviceID) == nil,
                "the pre-wipe enclave wrap still opens — the enclave key was not destroyed")
        // The throwaway lock got its OWN enclave key, so a wiped device looks like a normal install
        // rather than the only one in the world with no wrap.
        let replacement = lockRow(.seWrappedContentKey, fixture.harness)
        #expect(replacement != nil)
        #expect(replacement != originalBlob)
    }

    /// Two of the four sealed entities are NOT sealed under the content key: journal and Worry Box
    /// rows written while the lock was closed use device fallback keys instead. Destroying the
    /// content key alone would leave exactly those rows openable, so "crypto-erased" would be false
    /// for them — the same three-sweep argument `reset()` makes.
    @Test func silentWipeDestroysTheJournalAndWorryBoxDeviceFallbackKeys() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let deviceKeyService = fixture.harness.sealedContentKeyServiceID
        // Stands in for a device fallback key: any generic password under that service, since the
        // sweep is by service rather than by account.
        _ = KeychainItem.store(Data(repeating: 0x5A, count: 32), for: .salt, service: deviceKeyService)
        #expect(KeychainItem.load(for: .salt, service: deviceKeyService) != nil,
                "precondition: the stand-in device key must be present before the wipe")
        fixture.service.lock(reason: .manual)

        _ = try await fixture.service.unlock(passcode: "654321", for: .privateHub)

        #expect(KeychainItem.load(for: .salt, service: deviceKeyService) == nil,
                "rows sealed under the device fallback keys are still openable after a 'crypto-erase'")
    }

    /// The user's real passcode is dead, and no path hands back the old content key.
    @Test func afterTheWipeTheRealPasscodeNoLongerOpensAnything() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        service.lock(reason: .manual)

        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
        }
        #expect(service.contentKey(for: .privateHub) == nil)
        // The biometric door is gone with the bypass row, so it cannot resurrect the old key either.
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlockWithBiometrics(for: .privateHub)
        }
    }

    /// The wipe still has to LOOK like an unlock. The session it opens is the same keyless decoy
    /// every other duress mode opens — no content key, neither passcode flag, no attempt residue.
    @Test func silentWipePresentsTheSameKeylessDecoyAsEveryOtherMode() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)

        let result = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(result.method == .passcode)
        #expect(service.state == .unlocked(scope: .privateHub))
        #expect(service.isDuressSessionActive)
        #expect(!service.hasResidentContentKey)
        #expect(service.contentKey(for: .privateHub) == nil)
        #expect(service.currentAttemptCount == 0)
        #expect(!service.requiresReset)
        // The biometric side door stays shut for the whole duress session — the flag survives
        // `lock()`, so this holds even though `configure()` earlier in this process satisfied the
        // PIN-before-biometrics requirement.
        #expect(!service.isBiometricUnlockAvailable)
    }

    /// The PIN-before-biometrics flags, asserted where the assertion is meaningful: a service that
    /// has only ever seen the duress PIN.
    ///
    /// They cannot be asserted on the fixture's own instance — `configure()` set both, and only
    /// `reset()` clears them — so this drives the wipe from a second, "relaunched" service reading
    /// the same keychain. A duress entry must never satisfy the requirement that guards the RAW
    /// content key in the biometric bypass.
    @Test func aDuressEntryNeverCountsAsThisProcessesPasscodeSuccess() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        fixture.service.lock(reason: .manual)

        let relaunched = fixture.harness.makeService()
        #expect(!relaunched.passcodeUnlockedThisProcess)
        #expect(!relaunched.passcodeVerifiedThisProcess)

        _ = try await relaunched.unlock(passcode: "654321", for: .privateHub)

        #expect(relaunched.isDuressSessionActive)
        #expect(!relaunched.passcodeUnlockedThisProcess)
        #expect(!relaunched.passcodeVerifiedThisProcess)
        #expect(!relaunched.isBiometricUnlockAvailable)
    }

    /// The re-mint is what keeps the decoy convincing past the first re-lock. Without it the wiped
    /// device shows "set up app lock", which says both "there was a duress PIN" and "it fired".
    @Test func theThrowawayLockOpensToAnEmptyAppUnderTheDuressPINAfterARelock() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)
        service.lock(reason: .manual)

        // A second, fresh service instance reads only what is on disk — the right probe for "does
        // this device still look like an ordinary locked app?"
        let relaunched = fixture.harness.makeService()
        #expect(relaunched.state == .locked(cooldownDeadline: nil), "the wiped device must not read as unconfigured")
        #expect(relaunched.credentialKind == .pin6, "the pad must render exactly as it did before")

        let result = try await relaunched.unlock(passcode: "654321", for: .privateHub)

        #expect(result.method == .passcode)
        #expect(relaunched.state == .unlocked(scope: .privateHub))
        // This is now an ordinary unlock of an ordinary (empty) lock — not a duress session.
        #expect(!relaunched.isDuressSessionActive)
        let throwawayKey = try #require(relaunched.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
        #expect(throwawayKey != fixture.originalContentKey,
                "the throwaway lock resurrected the ERASED content key")
    }

    /// Fire-and-forget, but exactly once: the durable purge is a background errand, and a second
    /// invocation would mean the funnel ran twice on the same wipe.
    @Test func silentWipeFiresTheDurablePurgeHookExactlyOnce() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)
        #expect(fixture.purgeCount.value == 0)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(fixture.purgeCount.value == 1)
    }

    /// The purge hook is a DURESS-ONLY seam. Nothing on the ordinary unlock path may fire it — a
    /// stray invocation would be a silent "delete everything" triggered by a correct passcode.
    @Test func aBenignUnlockNeverFiresTheDurablePurgeHook() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "123456", for: .privateHub)
        service.lock(reason: .manual)
        _ = try? await service.unlock(passcode: "000000", for: .privateHub)

        #expect(fixture.purgeCount.value == 0)
        #expect(service.contentKey(for: .privateHub) == nil || !service.isDuressSessionActive)
    }

    /// Audit indistinguishability, on the most destructive mode there is: a wipe emits the SAME
    /// `lock.released` line a benign passcode unlock emits, and nothing that names the wipe.
    @Test func silentWipeEmitsTheSameAuditLineAsABenignUnlock() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        let capture = WipeAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(capture.contains(event: "lock.released", context: ["method": "passcode", "scope": "privateHub"]))
        // The re-mint must not announce itself as a fresh setup, and nothing may name the wipe.
        #expect(!capture.anyEventNameContains("configured"))
        #expect(!capture.anyEventNameContains("duress"))
        #expect(!capture.anyEventNameContains("wipe"))
        #expect(!capture.anyEventNameContains("reset"))
    }

    /// The wipe fires during a lockout too — the duress compare runs ahead of the cooldown and
    /// `requiresReset` guards, because a lockout is exactly when coercion is likeliest.
    @Test func silentWipeFiresEvenWhileTheLockIsInCooldown() async throws {
        let fixture = try await makeWipeFixture()
        defer { fixture.harness.cleanup() }
        let service = fixture.service
        service.lock(reason: .manual)
        // Enough wrong attempts to arm a cooldown.
        for _ in 0..<FernletLockService.attemptsPerCooldownBatch {
            _ = try? await service.unlock(passcode: "000000", for: .privateHub)
        }
        await #expect(throws: FernletLockError.self) {
            _ = try await service.unlock(passcode: "123456", for: .privateHub)
        }

        let result = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(result.method == .passcode)
        #expect(service.isDuressSessionActive)
        #expect(fixture.purgeCount.value == 1)
        // No cooldown residue survives to tell the two apart.
        #expect(service.currentAttemptCount == 0)
    }
}

// MARK: - Helpers

/// A reference box for observing that a hook the store owns actually fired. A reference type rather
/// than a captured `var` so the escaping closure and the assertion see the same storage.
@MainActor
private final class DuressTestFlag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}

/// A reference box counting how many times a hook the lock service owns fired.
@MainActor
private final class DuressTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Raw keychain read for one lock row under a harness's isolated service.
@MainActor
private func lockRow(_ key: LockKeychainKey, _ harness: LockTestHarness) -> Data? {
    KeychainItem.load(for: key, service: harness.serviceID)
}

/// Existence probe for a row stored behind an access control (the biometric bypass), which
/// `KeychainItem.load` is the wrong tool for — attributes come back without an authentication
/// prompt, data would not.
@MainActor
private func accessControlledRowExists(_ key: LockKeychainKey, _ harness: LockTestHarness) -> Bool {
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

/// A local `FernletAuditLog` sink for the indistinguishability assertions.
///
/// The audit registry is process-global and other suites emit into it concurrently, so every
/// assertion built on this is phrased as "contains" (or "contains nothing named…"), never as an
/// equality over the whole captured stream.
private final class WipeAuditCapture {
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
