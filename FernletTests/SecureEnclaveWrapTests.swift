import CryptoKit
import Foundation
import Security
import Testing
import FernletFoundation
@testable import FernletLock

/// Proves the Secure-Enclave wrap of the lock content key behaves correctly in BOTH custody
/// states: additive while the scrypt-wrapped item is retained (it round-trips, self-heals when
/// its blob is corrupted, and changes NOTHING when no enclave is available), and authoritative
/// once the hard binding has deleted that item (Docs/Verifiability.md §4, §6.1).
///
/// Every test handles both hardware cases explicitly, because `SecureEnclave.isAvailable` is
/// true on Apple-silicon-hosted simulators and false elsewhere — the fallback branch is not a
/// skip, it is the migration-safety property under test: SE-less hardware must stay legacy
/// forever, byte for byte.
@Suite(.serialized)
struct SecureEnclaveWrapTests {
    // MARK: - Shared helpers for the hard-binding tests

    /// A lock service on an isolated keychain service, optionally with enclave-wrap PERSISTENCE
    /// disabled — the only way to hold SE hardware in the pre-migration LEGACY state, since a
    /// real enclave otherwise hard-binds at `configure()`. The refusing store reports success and
    /// drops the write, so `storeVerified`'s read-back fails exactly as a hosed keychain would
    /// and `maintainSecureEnclaveWrap` swallows it — leaving no persisted wrap to verify against.
    @MainActor
    private func makeService(keychainService: String, persistEnclaveWrap: Bool = true) -> FernletLockService {
        let refusingStore: ((Data, LockKeychainKey, String) -> OSStatus)? = persistEnclaveWrap ? nil : { data, key, service in
            guard key != .seWrappedContentKey else { return errSecSuccess }
            return KeychainItem.store(data, for: key, service: service)
        }
        return FernletLockService(
            keychainService: keychainService,
            // reset() sweeps the sealed-content device keys too; keep that off the real service.
            sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
            keychainStore: refusingStore
        )
    }

    /// Whether the scrypt-wrapped legacy item still exists — the discriminator of the custody
    /// state machine, read exactly the way the service reads it.
    private func scryptItemExists(service: String) -> Bool {
        KeychainItem.load(for: .wrappedContentKey, service: service) != nil
    }

    /// The unlocked content key's raw bytes, through the one scope entitled to hold it.
    @MainActor
    private func contentKeyBytes(_ service: FernletLockService) throws -> Data {
        try #require(service.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }
    }

    // MARK: Proves wrapVerified→unwrap round-trips the exact key bytes, and that deleting the
    // enclave key makes existing blobs unopenable (the erase-device behavior the owner-decision
    // hard-binding would inherit).
    @Test func wrapRoundTripsAndDiesWithItsEnclaveKey() {
        guard SecureEnclaveContentKeyWrap.isAvailable else {
            #expect(SecureEnclaveContentKeyWrap.wrapVerified(Data(repeating: 7, count: 32), service: "com.fernlet.lock.test.se.unavailable") == nil,
                    "without an enclave, wrapVerified must fail soft to nil")
            return
        }
        let service = "com.fernlet.lock.test.se.\(UUID().uuidString)"
        defer { SecureEnclaveContentKeyWrap.deleteKey(service: service) }

        let contentKey = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        let blob = SecureEnclaveContentKeyWrap.wrapVerified(contentKey, service: service)
        #expect(blob != nil, "enclave available but wrapVerified failed")
        guard let blob else { return }
        #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKey)

        SecureEnclaveContentKeyWrap.deleteKey(service: service)
        #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == nil,
                "a wrapped blob must be unopenable once its enclave key is gone")
    }

    // MARK: Proves the lock service maintains the SE wrap across configure and unlock, that the
    // blob opens to the real content key, and — while the install is still LEGACY, which is the
    // only state where the question is meaningful — that a CORRUPTED blob never blocks an unlock
    // and is silently repaired by it. (Once hard-bound, a wrap that will not open is fatal by
    // design and is covered by `enclaveKeyDeathAfterHardBindingSurfacesTheExplicitError`.)
    @MainActor
    @Test func lockServiceMaintainsAndRepairsTheWrapWithoutEverBlockingUnlock() async throws {
        let service = "com.fernlet.lock.test.se.svc.\(UUID().uuidString)"
        // Set up with wrap persistence refused, so the install starts LEGACY even on enclave
        // hardware — the pre-migration state a corrupt-blob repair has to survive.
        let legacySetup = makeService(keychainService: service, persistEnclaveWrap: false)
        defer {
            try? legacySetup.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await legacySetup.configure(credential: .pin6("135791"), grantingScope: .privateHub)
        let contentKeyData = try contentKeyBytes(legacySetup)
        #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil)
        #expect(scryptItemExists(service: service), "setup must have left the legacy scrypt item")

        // A corrupt blob in the legacy state: the unlock must still succeed via scrypt…
        KeychainItem.store(Data(repeating: 0xFF, count: 64), for: .seWrappedContentKey, service: service)
        let lockService = makeService(keychainService: service)
        _ = try await lockService.unlock(passcode: "135791", for: .privateHub)
        #expect(try contentKeyBytes(lockService) == contentKeyData)

        if SecureEnclaveContentKeyWrap.isAvailable {
            // …and repair the blob back to a working wrap of the same content key…
            let repaired = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service))
            #expect(SecureEnclaveContentKeyWrap.unwrap(repaired, service: service) == contentKeyData,
                    "unlock must self-heal a corrupt SE wrap")
            // …after which that proven wrap is what lets the same unlock hard-bind.
            #expect(!scryptItemExists(service: service),
                    "a repaired, re-read, verified wrap must complete the hard binding")
        } else {
            #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == Data(repeating: 0xFF, count: 64),
                    "without an enclave nothing may touch the blob — behavior must be byte-for-byte legacy")
            #expect(scryptItemExists(service: service), "SE-less hardware must keep the scrypt item")
        }
    }

    // MARK: Proves reset() removes the enclave key itself (a kSecClassKey item the lock's
    // generic-password sweep cannot reach), so a destroyed lock leaves no orphan key material.
    @MainActor
    @Test func resetRemovesTheEnclaveKey() async throws {
        guard SecureEnclaveContentKeyWrap.isAvailable else { return }
        let service = "com.fernlet.lock.test.se.reset.\(UUID().uuidString)"
        let lockService = FernletLockService(
            keychainService: service,
            // reset() sweeps the sealed-content device keys too; keep that off the real service.
            sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"]
        )
        try await lockService.configure(credential: .pin6("246802"), grantingScope: .privateHub)
        #expect(SecureEnclaveContentKeyWrap.loadKey(service: service) != nil)
        try lockService.reset()
        #expect(SecureEnclaveContentKeyWrap.loadKey(service: service) == nil)
    }

    // MARK: - The SE-wrap / unlock-scope seam (P0a rebase regressions)
    //
    // The Secure-Enclave wrap and the per-screen unlock scope were built on separate branches and
    // both rewrote `configure()`/`unlock()`. Merging them could silently drop either half —
    // a missing `maintainSecureEnclaveWrap` would go unnoticed until the wrap is made
    // authoritative, and a re-widened `retainContentKey` would hand the sealed-content key back
    // to every surface. These two tests pin the union: the wrap is maintained on EVERY successful
    // configure/unlock regardless of scope, while `_contentKey` stays resident only for
    // `.privateHub`. `hasResidentContentKey` is the seam that can tell "scrubbed" from "merely
    // withheld" — `contentKey(for:)` returns nil for a foreign scope either way.

    // MARK: Proves the merged `configure(credential:grantingScope:)` does BOTH jobs: it
    // establishes a round-trip-verifying SE wrap of the freshly minted key, and it grants exactly
    // the requested scope (leaving the Private Hub — the only holder of the content key — shut).
    @MainActor
    @Test func configureEstablishesTheWrapAndGrantsOnlyTheRequestedScope() async throws {
        let service = "com.fernlet.lock.test.se.configscope.\(UUID().uuidString)"
        let lockService = FernletLockService(
            keychainService: service,
            // reset() sweeps the sealed-content device keys too; keep that off the real service.
            sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"]
        )
        defer {
            try? lockService.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await lockService.configure(credential: .pin6("864209"), grantingScope: .appLockSettings)

        // Scope half: setting the lock up from Settings → App lock opens THAT screen only.
        #expect(lockService.state == .unlocked(scope: .appLockSettings))
        #expect(lockService.isUnlocked(for: .appLockSettings))
        #expect(!lockService.isUnlocked(for: .privateHub))
        #expect(lockService.contentKey(for: .privateHub) == nil)
        #expect(lockService.contentKey(for: .appLockSettings) == nil)
        #expect(!lockService.hasResidentContentKey,
                "a non-hub grant must DROP the content key, not merely withhold it")

        // Capture the blob configure() wrote before any unlock could repair it, so this asserts
        // configure's own maintain call rather than a later self-heal.
        let blobFromConfigure = KeychainItem.load(for: .seWrappedContentKey, service: service)

        // Recover the real content-key bytes through the one scope entitled to them.
        lockService.lock(reason: .manual)
        _ = try await lockService.unlock(passcode: "864209", for: .privateHub)
        let contentKeyData = try #require(lockService.contentKey(for: .privateHub))
            .withUnsafeBytes { Data($0) }

        if SecureEnclaveContentKeyWrap.isAvailable {
            let blob = try #require(blobFromConfigure,
                                    "configure on SE hardware must establish the second wrap")
            #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKeyData,
                    "the wrap configure() wrote must round-trip to the minted content key")
        } else {
            #expect(blobFromConfigure == nil,
                    "without an enclave no blob may exist — behavior must be byte-for-byte legacy")
        }
    }

    // MARK: Proves a merged `unlock(passcode:for:)` maintains the SE wrap for EVERY scope while
    // retaining the in-memory content key for `.privateHub` alone. The wrap protects the key at
    // rest, not the session, so scoping must not have narrowed it.
    //
    // Starts from a LEGACY install with NO wrap, then unlocks for `.progressPhotos` FIRST: the
    // blob can only exist afterward because a non-hub unlock established it (the scope-
    // independence claim), and — on enclave hardware — that same non-hub unlock is what performs
    // the hard binding. Deleting the blob between iterations, as this test used to, would now be
    // destroying the only copy of the key rather than staging a repair.
    @MainActor
    @Test func unlockMaintainsTheWrapForEveryScopeButRetainsTheKeyOnlyForTheHub() async throws {
        let service = "com.fernlet.lock.test.se.unlockscope.\(UUID().uuidString)"
        let legacySetup = makeService(keychainService: service, persistEnclaveWrap: false)
        defer {
            try? legacySetup.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await legacySetup.configure(credential: .pin6("975310"), grantingScope: .privateHub)
        let contentKeyData = try contentKeyBytes(legacySetup)
        #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil,
                "the wrap must be absent before the first unlock under test")

        let lockService = makeService(keychainService: service)
        for scope in [FernletLockScope.progressPhotos, .appLockSettings] {
            lockService.lock(reason: .manual)

            _ = try await lockService.unlock(passcode: "975310", for: scope)

            #expect(lockService.state == .unlocked(scope: scope))
            #expect(lockService.contentKey(for: .privateHub) == nil)
            #expect(lockService.contentKey(for: scope) == nil)
            #expect(!lockService.hasResidentContentKey,
                    "\(scope.rawValue) must not leave the sealed-content key resident")

            if SecureEnclaveContentKeyWrap.isAvailable {
                let blob = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service),
                                        "unlock for \(scope.rawValue) must still maintain the SE wrap")
                #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKeyData)
                #expect(!scryptItemExists(service: service),
                        "a \(scope.rawValue) unlock must hard-bind too — the wrap is at-rest, not per-session")
            } else {
                #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil)
                #expect(scryptItemExists(service: service))
            }
        }

        // …and the hub unlock both maintains the wrap AND keeps the key.
        lockService.lock(reason: .manual)
        _ = try await lockService.unlock(passcode: "975310", for: .privateHub)

        #expect(lockService.hasResidentContentKey)
        #expect(try contentKeyBytes(lockService) == contentKeyData)
        if SecureEnclaveContentKeyWrap.isAvailable {
            let blob = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service))
            #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKeyData)
        } else {
            #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil)
        }
    }

    // MARK: - HARD binding (P4): the scrypt item is deleted once the enclave wrap is proven
    //
    // The five tests below pin the state machine end to end. On SE hardware they exercise the
    // real hard-bound path; on SE-less hardware each asserts the complementary property — the
    // install stays LEGACY and behaves byte for byte as it did before P4 — which is the whole
    // safety claim for devices that can never hard-bind.

    // MARK: Proves configure() is born HARD-BOUND on enclave hardware (the scrypt item it wrote
    // moments earlier is deleted) and that a later unlock recovers the SAME key with no scrypt
    // item in existence — i.e. through the enclave alone. On SE-less hardware, the exact
    // opposite: the scrypt item is RETAINED and unlock is legacy.
    @MainActor
    @Test func configureIsBornHardBoundAndUnlockRecoversViaTheEnclaveAlone() async throws {
        let service = "com.fernlet.lock.test.se.hardbind.\(UUID().uuidString)"
        let lockService = makeService(keychainService: service)
        defer {
            try? lockService.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await lockService.configure(credential: .pin6("112233"), grantingScope: .privateHub)
        let contentKeyData = try contentKeyBytes(lockService)

        guard SecureEnclaveContentKeyWrap.isAvailable else {
            #expect(scryptItemExists(service: service),
                    "SE-less hardware must NEVER delete the scrypt item")
            #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil)
            lockService.lock(reason: .manual)
            _ = try await lockService.unlock(passcode: "112233", for: .privateHub)
            #expect(try contentKeyBytes(lockService) == contentKeyData, "legacy unlock must be unchanged")
            return
        }

        #expect(!scryptItemExists(service: service),
                "configure() on enclave hardware must delete the scrypt item after the wrap verifies")
        let blob = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service))
        #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKeyData)

        // Second unlock, through a FRESH service instance (nothing cached in memory): the only
        // surviving copy of the key is the enclave wrap, so a success proves the SE-only path.
        lockService.lock(reason: .manual)
        let relaunched = makeService(keychainService: service)
        _ = try await relaunched.unlock(passcode: "112233", for: .privateHub)
        #expect(try contentKeyBytes(relaunched) == contentKeyData,
                "hard-bound unlock must recover the same key via the enclave")
        #expect(!scryptItemExists(service: service), "a hard-bound unlock must never resurrect the scrypt item")
    }

    // MARK: Proves the MIGRATION half: an install that is still legacy (its enclave wrap could not
    // be persisted at setup) hard-binds on its first unlock under this build — the scrypt item is
    // deleted only after the freshly written wrap is re-read and proven.
    @MainActor
    @Test func firstUnlockUnderThisBuildMigratesALegacyInstall() async throws {
        let service = "com.fernlet.lock.test.se.migrate.\(UUID().uuidString)"
        // Setup with wrap persistence refused → a genuine pre-migration LEGACY install.
        let legacySetup = makeService(keychainService: service, persistEnclaveWrap: false)
        defer {
            try? legacySetup.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }
        try await legacySetup.configure(credential: .pin6("445566"), grantingScope: .privateHub)
        let contentKeyData = try contentKeyBytes(legacySetup)
        #expect(scryptItemExists(service: service), "setup must have left the legacy scrypt item")
        #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil)

        // Now the P4 build (normal keychain writes) unlocks that install.
        let migrating = makeService(keychainService: service)
        _ = try await migrating.unlock(passcode: "445566", for: .privateHub)
        #expect(try contentKeyBytes(migrating) == contentKeyData, "the migrating unlock must still work")

        if SecureEnclaveContentKeyWrap.isAvailable {
            #expect(!scryptItemExists(service: service),
                    "first unlock under P4 must hard-bind: scrypt item deleted")
            let blob = try #require(KeychainItem.load(for: .seWrappedContentKey, service: service))
            #expect(SecureEnclaveContentKeyWrap.unwrap(blob, service: service) == contentKeyData)
            // And the install stays usable afterward, via the enclave only.
            migrating.lock(reason: .manual)
            _ = try await migrating.unlock(passcode: "445566", for: .privateHub)
            #expect(try contentKeyBytes(migrating) == contentKeyData)
        } else {
            #expect(scryptItemExists(service: service), "SE-less hardware must stay legacy")
        }
    }

    // MARK: Proves keep-old-until-verified is load-bearing: while no enclave wrap can be
    // PERSISTED (corrupt blob that cannot be replaced, or none at all), the scrypt item survives
    // every unlock and the unlock keeps working. This is the property that makes the flip
    // non-destructive — a wrap that cannot be proven never costs the user their only other copy.
    @MainActor
    @Test func keepOldUntilVerifiedRetainsTheScryptItemWhenNoWrapCanBeProven() async throws {
        let service = "com.fernlet.lock.test.se.keepold.\(UUID().uuidString)"
        let lockService = makeService(keychainService: service, persistEnclaveWrap: false)
        defer {
            try? lockService.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await lockService.configure(credential: .pin6("778899"), grantingScope: .privateHub)
        let contentKeyData = try contentKeyBytes(lockService)
        // ABSENT wrap: nothing to verify against, so nothing may be deleted.
        #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil)
        #expect(scryptItemExists(service: service), "an absent wrap must never trigger the flip")

        // CORRUPT wrap: unwrappable, and (writes refused) unrepairable — still no deletion.
        KeychainItem.store(Data(repeating: 0xFF, count: 64), for: .seWrappedContentKey, service: service)
        lockService.lock(reason: .manual)
        _ = try await lockService.unlock(passcode: "778899", for: .privateHub)
        #expect(try contentKeyBytes(lockService) == contentKeyData,
                "a corrupt wrap must never block the scrypt unlock")
        #expect(scryptItemExists(service: service), "a corrupt wrap must never trigger the flip")
    }

    // MARK: Proves the honest failure of the hard-binding trade: once bound, destroying the
    // enclave key (an Erase All Content and Settings, an SE reset) makes a CORRECT passcode fail
    // with the explicit `contentKeyUnrecoverable` — never a silent wrong key — while the verifier
    // still gates the attempt counter exactly as before.
    @MainActor
    @Test func enclaveKeyDeathAfterHardBindingSurfacesTheExplicitError() async throws {
        let service = "com.fernlet.lock.test.se.keydeath.\(UUID().uuidString)"
        let lockService = makeService(keychainService: service)
        defer {
            try? lockService.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await lockService.configure(credential: .pin6("101112"), grantingScope: .privateHub)
        guard SecureEnclaveContentKeyWrap.isAvailable, !scryptItemExists(service: service) else {
            // SE-less: no hard-bound state exists to lose, and unlock stays legacy.
            lockService.lock(reason: .manual)
            _ = try await lockService.unlock(passcode: "101112", for: .privateHub)
            #expect(lockService.hasResidentContentKey)
            return
        }
        lockService.lock(reason: .manual)

        // The enclave key dies out from under the app; the keychain rows all survive.
        SecureEnclaveContentKeyWrap.deleteKey(service: service)

        // A WRONG passcode still fails as a wrong passcode, and still counts (the verifier is
        // untouched by the custody change — it is what gates the brute-force ladder).
        do {
            _ = try await lockService.unlock(passcode: "999999", for: .privateHub)
            Issue.record("a wrong passcode unlocked a hard-bound lock with a dead enclave key")
        } catch FernletLockError.invalidPasscode { }
        #expect(lockService.currentAttemptCount == 1, "the verifier must still drive the attempt counter")

        // The RIGHT passcode now fails with the explicit unrecoverable error…
        do {
            _ = try await lockService.unlock(passcode: "101112", for: .privateHub)
            Issue.record("unlock succeeded although the enclave key that holds the content key is gone")
        } catch FernletLockError.contentKeyUnrecoverable { }
        // …installs no key, stays locked, and neither penalizes nor forgives the attempt count.
        #expect(!lockService.hasResidentContentKey, "no key may be installed when recovery failed")
        #expect(lockService.contentKey(for: .privateHub) == nil)
        #expect(lockService.state == .locked(cooldownDeadline: nil))
        #expect(lockService.currentAttemptCount == 1, "a correct passcode is not a failed attempt")
    }

    // MARK: Proves a hard-bound re-key survives: `changeCredential` recovers the content key from
    // the enclave (the wrap is indifferent to the passcode), rewrites only the passcode gate, and
    // never resurrects the scrypt item — which would silently undo the hard binding.
    @MainActor
    @Test func changeCredentialHardBoundKeepsTheKeyAndNeverRewritesTheScryptItem() async throws {
        let service = "com.fernlet.lock.test.se.rekey.\(UUID().uuidString)"
        let lockService = makeService(keychainService: service)
        defer {
            try? lockService.reset()
            SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }

        try await lockService.configure(credential: .pin6("131415"), grantingScope: .privateHub)
        let contentKeyData = try contentKeyBytes(lockService)
        let hardBound = SecureEnclaveContentKeyWrap.isAvailable && !scryptItemExists(service: service)

        try await lockService.changeCredential(current: "131415", new: .pin6("161718"))
        if hardBound {
            #expect(!scryptItemExists(service: service),
                    "a hard-bound re-key must not write a scrypt-wrapped copy back")
        }

        // The new passcode opens the SAME content key…
        lockService.lock(reason: .manual)
        _ = try await lockService.unlock(passcode: "161718", for: .privateHub)
        #expect(try contentKeyBytes(lockService) == contentKeyData,
                "re-keying must preserve the content key (no sealed-data loss)")

        // …and the old one no longer does.
        lockService.lock(reason: .manual)
        do {
            _ = try await lockService.unlock(passcode: "131415", for: .privateHub)
            Issue.record("the superseded passcode still unlocked the service")
        } catch FernletLockError.invalidPasscode { }
    }
}
