import CryptoKit
import FernletSocial
import Foundation
import PrivateMediaStore
import PrivateStoreCore
import ProximityKit
import Security
import Testing
import FernletFoundation
@testable import Fernlet
@testable import FernletCrypto
@testable import FernletLock

/// The key-custody tripwire (Docs/Verifiability.md §2, §4): CI fails loudly if any keychain row
/// that guards sealed data loosens its device binding.
///
/// Two halves, in the house style of `NoTrackingBoundaryTests`/`S3BoundaryTests`:
/// - **Attribute checks** drive each production key store against an isolated (or well-known)
///   keychain service and read the row's ACTUAL `kSecAttrAccessible` + `kSecAttrSynchronizable`
///   back via `SecItemCopyMatching` — asserting the exact expected class, not the source text.
/// - **Grep-walls** pin where the two sanctioned exceptions may live in shipping code:
///   `synchronizable: true` (the escrow promotion) only in `SealedBackupEscrowKey.swift`, and a bare
///   non-`ThisDeviceOnly` accessibility class only in `PrivateMediaKeyStore.swift` +
///   `SealedBackupEscrowKey.swift`; and where a device identity may be built: only in the app's
///   factory in `SealedBackupEscrowKey.swift`, which carries the escrow key. ProximityKit builds none:
///   its host door, `ProximityHost.makeProximityIdentity()`, has no default, so the app's store must
///   answer it, and a behavioural cell holds what it answers, the store's three managers each holding
///   an identity that carries the escrow key. Between them no shipping path provisions an identity
///   that could mint over a previous build's key-agreement row without first promoting it into the
///   escrow. Exact-set in both directions, with planted-violation fixtures and a scan floor, so the
///   wall can neither miss a new file nor rot into a stale allowance.
///
/// A future "make sealed data shareable" change would have to flip one of these rows to a
/// synchronizable or non-device class — and fail here, in the same commit.
struct KeyCustodyBoundaryTests {
    // MARK: - Attribute checks (real keychain, real store code)

    /// Reads back the accessibility + synchronizable attributes of one generic-password row.
    private func rowAttributes(account: String, service: String) -> (accessible: String, synchronizable: Bool)? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any],
              let accessible = attrs[kSecAttrAccessible as String] as? String else { return nil }
        let synchronizable = (attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
        return (accessible, synchronizable)
    }

    // MARK: Proves every lock credential/content-key row is written WhenUnlockedThisDeviceOnly,
    // never synchronizable — through the REAL LockKeychainKey store path.
    @Test func lockKeychainRowsAreWhenUnlockedThisDeviceOnly() {
        let service = "com.fernlet.lock.test.custody.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        // Representative rows across the lock's footprint (all share one store path; the
        // biometric bypass is separately pinned by source in `biometricBypassACLIsPinnedInSource`
        // because storing a WhenPasscodeSet item requires a device passcode the simulator lacks).
        // `.wrappedContentKeyRewrapStaging` is the Phase 2.5 re-wrap staging row: it holds a
        // scrypt-openable copy of the content key for its whole (bounded) lifetime, so a staging
        // copy under a weaker class than the live row would out-expose it — the inheritance is
        // asserted through the REAL store path here, not assumed (T-26).
        // `.deviceContentKey` is the no-passcode home of the content key (period-data design §4.2):
        // it rides the same store path, so it must land in the same class.
        for key in [LockKeychainKey.salt, .verifier, .wrappedContentKey,
                    .wrappedContentKeyRewrapStaging, .seWrappedContentKey, .deviceContentKey] {
            #expect(KeychainItem.store(Data([0xAB]), for: key, service: service) == errSecSuccess)
            let attrs = rowAttributes(account: key.rawValue, service: service)
            #expect(attrs?.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                    "\(key.rawValue) must be WhenUnlockedThisDeviceOnly")
            #expect(attrs?.synchronizable == false, "\(key.rawValue) must never sync")
        }
    }

    // MARK: Proves the P4 hard-bound custody state through the REAL configure() path: on enclave
    // hardware the scrypt-wrapped item is GONE, so the only content-key-bearing row left is the
    // Secure-Enclave wrap (plus the optional biometric bypass, which is off here) — and it is
    // still WhenUnlockedThisDeviceOnly and non-synchronizable. On SE-less hardware the
    // complementary property holds: the install stays legacy and keeps the scrypt row.
    @MainActor
    @Test func hardBoundStateLeavesOnlyTheEnclaveWrapBearingTheContentKey() async throws {
        let service = "com.fernlet.lock.test.custody.hardbound.\(UUID().uuidString)"
        defer {
            KeychainItem.deleteAll(service: service)
            _ = SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }
        let lockService = FernletLockService(
            keychainService: service,
            // reset() sweeps the sealed-content device keys too; keep that off the real service.
            sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
            // reset() also purges the pending-narrative buffer; keep that off the process-wide scope.
            narrativeBufferScope: uniqueNarrativeBufferScope()
        )
        try await lockService.configure(credential: .pin6("123456"), grantingScope: .privateHub)

        // The four accounts that can ever carry the content key itself. The Phase 2.5 re-wrap
        // staging row (`.wrappedContentKeyRewrapStaging`) is the fourth: expected ABSENT after
        // `configure()` in BOTH branches — configure never stages — so the exact-set assertions
        // below now SEE the row instead of silently under-covering it.
        let contentKeyBearing: [LockKeychainKey] = [
            .wrappedContentKey, .wrappedContentKeyRewrapStaging, .seWrappedContentKey, .biometricBypass
        ]
        let present = contentKeyBearing.filter { KeychainItem.load(for: $0, service: service) != nil }

        if SecureEnclaveContentKeyWrap.isAvailable {
            #expect(present == [.seWrappedContentKey],
                    "hard-bound: the enclave wrap must be the ONLY content-key-bearing row; found \(present.map(\.rawValue))")
        } else {
            #expect(present == [.wrappedContentKey],
                    "SE-less hardware must stay legacy; found \(present.map(\.rawValue))")
        }
        // T-27: the steady state stays staging-free — a hard-bound install (and the SE-less
        // legacy complement) must never carry a scrypt-openable staging copy at rest. The dynamic
        // version of the same claim (a planted orphan is swept by the next passcode unlock under
        // any custody) lives at the service level in RewrapStagingSweepTests, which took the
        // coverage over when LockWrapFormatMigrationTests was deleted with its migrator in Phase 3.
        #expect(KeychainItem.load(for: .wrappedContentKeyRewrapStaging, service: service) == nil,
                "the re-wrap staging row must be absent in the steady state")
        for key in present {
            let attrs = rowAttributes(account: key.rawValue, service: service)
            #expect(attrs?.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                    "\(key.rawValue) must be WhenUnlockedThisDeviceOnly")
            #expect(attrs?.synchronizable == false, "\(key.rawValue) must never sync")
        }
    }

    // MARK: The device-custody row through the REAL tap (period-data design §4.2, invariant I7):
    // the production enclave wrapper, the production store path, the production keychain. On
    // enclave hardware (Apple-silicon simulators included) the row is `FDS1` and nothing else; either
    // way it is WhenUnlockedThisDeviceOnly and never synchronizable, and the key it holds opens the
    // same Private tab after a relaunch.
    @MainActor
    @Test func theDeviceCustodyRowIsWhenUnlockedThisDeviceOnlyThroughTheRealTap() throws {
        let service = "com.fernlet.lock.test.custody.device.\(UUID().uuidString)"
        defer {
            KeychainItem.deleteAll(service: service)
            _ = SecureEnclaveContentKeyWrap.deleteKey(service: service)
        }
        let makeService = {
            FernletLockService(
                keychainService: service,
                sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
                narrativeBufferScope: uniqueNarrativeBufferScope(),
                privatePersistenceController: PrivatePersistenceController(inMemory: true)
            )
        }
        let lockService = makeService()
        try lockService.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let key = try #require(lockService.contentKey(for: .privateHub)).withUnsafeBytes { Data($0) }

        let row = try #require(KeychainItem.load(for: .deviceContentKey, service: service))
        let expectedMarker = SecureEnclaveContentKeyWrap.isAvailable ? "FDS1" : "FDR1"
        #expect(row.starts(with: Data(expectedMarker.utf8)), "the device row must be \(expectedMarker) on this host")
        if SecureEnclaveContentKeyWrap.isAvailable {
            #expect(row.range(of: key) == nil, "an enclave device must never hold the raw key in the row")
        }
        let attrs = rowAttributes(account: LockKeychainKey.deviceContentKey.rawValue, service: service)
        #expect(attrs?.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attrs?.synchronizable == false, "the device-custody row must never sync")

        let relaunched = makeService()
        try relaunched.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(relaunched.contentKey(for: .privateHub).map { $0.withUnsafeBytes { Data($0) } } == key)
    }

    // MARK: One REAL enclave key, two custodies (review C-U1-R3): on enclave hardware the hard-bound
    // passcode custody and the `FDS1` device row are wrapped under the SAME enclave key, so a
    // removal must delete the passcode's wrap BLOB and keep the KEY the device row needs. Every
    // other adoption/removal test injects a fake enclave for the device row; this one runs tap →
    // setup (hard-bound) → relaunch + unlock → removal → relaunch + tap through the production
    // wrapper, and fails if any step deletes or rotates the enclave key.
    @MainActor
    @Test func theRealEnclaveCarriesOneKeyThroughAddingAndRemovingAPasscode() async throws {
        let service = "com.fernlet.lock.test.custody.roundTrip.\(UUID().uuidString)"
        let bufferScope = uniqueNarrativeBufferScope()
        defer {
            KeychainItem.deleteAll(service: service)
            _ = SecureEnclaveContentKeyWrap.deleteKey(service: service)
            KeychainItem.deleteAll(service: bufferScope.keychainService)
        }
        let crypto = FakeLockCryptoProvider()
        let persistence = PrivatePersistenceController(inMemory: true)
        let makeService = {
            FernletLockService(
                keychainService: service,
                sealedContentKeyServices: ["com.fernlet.journal.test.\(UUID().uuidString)"],
                narrativeBufferScope: bufferScope,
                cryptoProvider: crypto,
                privatePersistenceController: persistence
            )
        }
        let hubKey: (FernletLockService) -> Data? = { $0.contentKey(for: .privateHub).map { $0.withUnsafeBytes { Data($0) } } }
        let enclave = SecureEnclaveContentKeyWrap.isAvailable
        let first = makeService()
        try first.openWithoutPasscode(for: .privateHub, allowingMint: true)
        let key = try #require(hubKey(first))
        first.lock(reason: .manual)

        try await first.configure(credential: .pin6("123456"), grantingScope: .privateHub, acknowledgedPriorData: false)
        #expect(hubKey(first) == key, "setup must adopt the device key")
        #expect(KeychainItem.load(for: .deviceContentKey, service: service) == nil, "the proven custody retires the row")
        #expect((KeychainItem.load(for: .seWrappedContentKey, service: service) != nil) == enclave)
        #expect((KeychainItem.load(for: .wrappedContentKey, service: service) == nil) == enclave, "born hard-bound where an enclave exists")

        let locked = makeService()
        _ = try await locked.unlock(passcode: "123456", for: .privateHub)
        #expect(hubKey(locked) == key)
        try await locked.removeCredential(current: "123456")
        #expect(KeychainItem.load(for: .seWrappedContentKey, service: service) == nil, "the passcode's wrap blob goes")
        let row = try #require(KeychainItem.load(for: .deviceContentKey, service: service))
        #expect(row.starts(with: Data((enclave ? "FDS1" : "FDR1").utf8)))
        if enclave {
            var enclaveKeySurvived = false
            if case .loaded = SecureEnclaveContentKeyWrap.loadKeyResult(service: service) { enclaveKeySurvived = true }
            #expect(enclaveKeySurvived, "the removal deleted the enclave key the FDS1 row is wrapped under")
        }

        let relaunched = makeService()
        #expect(relaunched.state == .notConfigured)
        try relaunched.openWithoutPasscode(for: .privateHub, allowingMint: false)
        #expect(hubKey(relaunched) == key, "the device row must open to the same key after the round trip")
    }

    // MARK: The pending buffer's key (period-data design §6.5, review R1-F5, invariant I21's key
    // half): an unreadable read must never mint a replacement. `KeychainItem.store` is
    // delete-then-add, so the old collapsing read + mint destroyed the real key — and every entry
    // buffered under it — on a single transient failure. Driven through the R5 empty-service guard
    // (`.unreadable(errSecParam)`), the same way `deviceSealingKeyIsNeverMintedOverAnUnreadableRow`
    // is; the named error is the proof no mint was attempted (the mint path throws a different one).
    @Test func bufferKeyIsNeverMintedOverAnUnreadableRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.bufferKeyUnreadable.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = PendingNarrativeBuffer(scope: PendingNarrativeStorageScope(directory: directory, keychainService: ""))
        let payload = PendingNarrativePayload(
            hkExternalUUID: UUID().uuidString, dateKey: "2026-09-30",
            noteBytes: Data("held".utf8), symptomFlagsBytes: nil, customSymptomScalesBytes: nil
        )
        #expect(throws: PendingNarrativeBufferError.keyUnreadable(status: errSecParam)) {
            try buffer.append(payload)
        }
        #expect(!FileManager.default.fileExists(atPath: PendingNarrativeBuffer.fileURL(in: directory).path),
                "an append whose key could not be read must write nothing")
    }

    // MARK: Proves the no-lock sealing keys (journal + worry device keys) mint as
    // AfterFirstUnlockThisDeviceOnly, never synchronizable — via loadOrCreateSymmetricKey.
    @Test func deviceSealingKeysAreAfterFirstUnlockThisDeviceOnly() {
        let service = "com.fernlet.journal.test.custody.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        for account in [KeychainItem.Account.deviceJournalKey, .deviceWorryKey] {
            _ = KeychainItem.loadOrCreateSymmetricKey(for: account, service: service)
            let attrs = rowAttributes(account: account.rawValue, service: service)
            #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                    "\(account.rawValue) must be AfterFirstUnlockThisDeviceOnly")
            #expect(attrs?.synchronizable == false, "\(account.rawValue) must never sync")
        }
    }

    // MARK: Proves the device sealing keys fail CLOSED on an unreadable row rather than minting over
    // it. `KeychainItem.store` is delete-then-add, so a mint on an unreadable read would destroy the
    // real key and turn every sealed journal entry and worry into permanent garbage. A real
    // `errSecInteractionNotAllowed` can't be forced from a test, so the same `.unreadable` branch is
    // driven through the R5 empty-service guard (`loadDistinguishingAbsence` → `.unreadable(errSecParam)`).
    @Test func deviceSealingKeyIsNeverMintedOverAnUnreadableRow() {
        #expect(KeychainItem.loadOrCreateSymmetricKey(for: .deviceJournalKey, service: "") == nil,
                "an unreadable row must never mint a replacement key")
        #expect(KeychainItem.loadOrCreateSymmetricKey(for: .deviceWorryKey, service: "") == nil,
                "an unreadable row must never mint a replacement key")

        // Non-regression: a readable row is returned, never re-minted.
        let service = "com.fernlet.journal.test.unreadable.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        let first = KeychainItem.loadOrCreateSymmetricKey(for: .deviceJournalKey, service: service)
        let second = KeychainItem.loadOrCreateSymmetricKey(for: .deviceJournalKey, service: service)
        #expect(first?.rawBytes != nil, "the absent-row mint path must still persist and return a key")
        #expect(first?.rawBytes == second?.rawBytes, "a readable row must be returned, never re-minted")
    }

    // MARK: Proves the sealed-column install-binding ID (ColumnCrypto v2 AAD) lives in a
    // ThisDeviceOnly, never-synchronizable row — the property the ciphertext binding rests on.
    @Test func installBindingIDIsAfterFirstUnlockThisDeviceOnly() {
        guard DeviceBindingID.current() != nil else {
            Issue.record("DeviceBindingID.current() returned nil — could not mint the install row")
            return
        }
        let attrs = rowAttributes(account: DeviceBindingID.account, service: DeviceBindingID.service)
        #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attrs?.synchronizable == false)
    }

    // MARK: Pins sanctioned exception 1 of 2: the media key is DELIBERATELY backup-restorable
    // (AfterFirstUnlock, NOT ThisDeviceOnly — the documented product decision in
    // PrivateMediaKeyStore.swift) but still never iCloud-Keychain-synchronizable. If this test
    // fails in the ThisDeviceOnly direction, someone reversed that product decision — see
    // Docs/Verifiability.md §6.3 before assuming it is a bug.
    @MainActor
    @Test func mediaKeyIsTheSanctionedBackupRestorableException() {
        let provider = KeychainPrivateMediaKeyProvider()
        #expect(provider.mediaKey() != nil, "media key could not be minted/read")
        let attrs = rowAttributes(account: "com.fernlet.private-media.contentKey",
                                  service: "com.fernlet.private-media")
        #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlock as String,
                "media key must stay AfterFirstUnlock (backup-restorable by product decision)")
        #expect(attrs?.synchronizable == false, "media key must never reach iCloud Keychain")
    }

    // MARK: Phase-5 media-key split. The user's OWN photos moved to a SECOND row
    // (`…ownContentKey`), distinct from the friend wall's above. Pinned here: the two rows really
    // are two independent keys (a split that vended the same bytes twice would be theatre), and the
    // own row is non-synchronizable like everything else. Its accessibility class is the subject of
    // the next test.
    @MainActor
    @Test func ownPhotoKeyIsASecondRowDistinctFromTheFriendWallKey() {
        let friend = KeychainPrivateMediaKeyProvider(role: .friendWall)
        let own = KeychainPrivateMediaKeyProvider(role: .ownPhotos)
        let friendBytes = friend.mediaKey().map { $0.withUnsafeBytes { Data($0) } }
        let ownBytes = own.mediaKey().map { $0.withUnsafeBytes { Data($0) } }
        #expect(friendBytes != nil, "friend media key could not be minted/read")
        #expect(ownBytes != nil, "own-photo media key could not be minted/read")
        #expect(friendBytes != ownBytes, "the media-key split vends ONE key under two names")

        let attrs = rowAttributes(account: "com.fernlet.private-media.ownContentKey",
                                  service: "com.fernlet.private-media")
        #expect(attrs != nil, "the own-photo row does not exist")
        #expect(attrs?.synchronizable == false, "own-photo media key must never reach iCloud Keychain")
    }

    // MARK: The step-5c custody flip, asserted on the REAL row through the REAL gate: once the
    // migration latch is set and a cross-device route exists, `…ownContentKey` is
    // AfterFirstUnlockThisDeviceOnly and still non-synchronizable. That is the whole point of the
    // media-key split — the user's own meal, recipe and body photos stop being readable from a
    // restored device backup, while the friend wall above deliberately stays backup-restorable.
    //
    // The gate inputs come from an ISOLATED defaults suite (never the device's real latch/consent),
    // and the binder is idempotent, so this drives the shipping mechanism rather than re-deriving
    // it. If someone weakens the binding — a delete-then-add re-store, a wrong class, an accidental
    // synchronizable — it fails here, in the same commit, on a CODEOWNERS-protected tripwire.
    @MainActor
    @Test func ownPhotoKeyBindsToThisDeviceOnceItsGateIsSatisfied() throws {
        let suiteName = "KeyCustodyBoundaryTests-ownPhotoBinding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        MediaAtRestFormatMigrationLatch(defaults: defaults).markComplete()

        let before = KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey()
            .map { $0.withUnsafeBytes { Data($0) } }
        let outcome = OwnPhotoKeyBinder(escrowRouteCommitted: true, defaults: defaults).bindIfEligible()
        #expect(outcome == .bound, "the own-photo key refused to bind with its gate satisfied: \(outcome)")

        let attrs = rowAttributes(account: "com.fernlet.private-media.ownContentKey",
                                  service: "com.fernlet.private-media")
        #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                "the own-photo media key must be device-bound (Docs/Verifiability.md §6.3 item 3)")
        #expect(attrs?.synchronizable == false, "own-photo media key must never reach iCloud Keychain")

        // The flip changes custody, never key material: a re-mint here would silently orphan every
        // meal, recipe and progress photo already sealed under this key.
        let after = KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey()
            .map { $0.withUnsafeBytes { Data($0) } }
        #expect(after == before, "binding rotated the own-photo key instead of re-binding the row")
    }

    // MARK: The pending session-photo key (2026-09-30): the row behind photos nobody has chosen
    // yet is BORN device-bound — `AfterFirstUnlockThisDeviceOnly`, non-synchronizable — with no gate,
    // because nothing pending is ever escrowed or meant to survive onto another phone. A third,
    // independent key: a pending box must never open under the wall's or the own-photo key.
    //
    // The row is process-global in the simulator (like the wall's), so this never deletes it: on a
    // fresh simulator it is minted here; on a reused one it was minted by this same code.
    @MainActor
    @Test func pendingSessionPhotoKeyIsDeviceBoundAtMint() {
        #expect(KeychainPrivateMediaKeyProvider.defaultDeviceBinding(for: .pendingSessionPhotos),
                "the pending session-photo key must be minted device-bound")
        let pending = KeychainPrivateMediaKeyProvider(role: .pendingSessionPhotos)
        #expect(pending.deviceBound)
        let pendingBytes = pending.mediaKey().map { $0.withUnsafeBytes { Data($0) } }
        #expect(pendingBytes != nil, "pending session-photo key could not be minted/read")
        let wallBytes = KeychainPrivateMediaKeyProvider(role: .friendWall).mediaKey().map { $0.withUnsafeBytes { Data($0) } }
        let ownBytes = KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey().map { $0.withUnsafeBytes { Data($0) } }
        #expect(pendingBytes != wallBytes, "the pending key is the friend-wall key under another name")
        #expect(pendingBytes != ownBytes, "the pending key is the own-photo key under another name")

        let attrs = rowAttributes(account: "com.fernlet.private-media.pendingContentKey",
                                  service: "com.fernlet.private-media")
        #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                "the pending session-photo key must be AfterFirstUnlockThisDeviceOnly (never backup-restorable)")
        #expect(attrs?.synchronizable == false, "the pending session-photo key must never reach iCloud Keychain")
    }

    // MARK: The duress silent wipe crypto-erases pending photos by sweeping the WHOLE media service.
    // Pinned against the lock's own constant (FernletLock cannot import PrivateMediaStore, so the
    // service is restated there by value): the row the provider really writes must be found under
    // exactly the service the wipe sweeps. A role moved to another service would survive the wipe.
    @MainActor
    @Test func pendingSessionPhotoKeyLivesUnderTheServiceTheDuressWipeSweeps() {
        #expect(KeychainPrivateMediaKeyProvider(role: .pendingSessionPhotos).mediaKey() != nil)
        let attrs = rowAttributes(account: "com.fernlet.private-media.pendingContentKey",
                                  service: FernletLockService.privateMediaKeychainService)
        #expect(attrs != nil,
                "the pending session-photo row is not under \(FernletLockService.privateMediaKeychainService), the service the duress wipe sweeps")
    }

    // MARK: Proves the proximity identity private keys provision as ThisDeviceOnly and that a
    // freshly minted escrow key is WITHHELD from sync (WS-2: ThisDeviceOnly until a later launch
    // promotes it) — sanctioned exception 2 of 2 is the *promotion*, pinned by the grep-wall.
    @MainActor
    @Test func identityKeysProvisionDeviceOnly() throws {
        let service = "com.fernlet.identity.test.custody.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()

        for account in ["signingPrivateKey", "keyAgreementPrivateKey"] {
            let attrs = rowAttributes(account: account, service: service)
            #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                    "\(account) must be AfterFirstUnlockThisDeviceOnly")
            #expect(attrs?.synchronizable == false, "\(account) must never sync")
        }

        _ = identity.provisionBackupEscrowKeyForSealing()
        let escrowRows = KeychainItem.loadAll(service: service)
            .filter { $0.account.hasPrefix("backupEscrowPrivateKey.k.") }
        #expect(!escrowRows.isEmpty, "escrow minting produced no content-addressed row")
        for row in escrowRows {
            let attrs = rowAttributes(account: row.account, service: service)
            #expect(attrs?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                    "a freshly minted escrow key must be withheld from sync (WS-2)")
            #expect(attrs?.synchronizable == false)
        }
    }

    // MARK: - Grep-walls (shipping source, exact-set in both directions)

    /// Shipping-code roots — app, all package modules, and all three extensions. Test targets are
    /// deliberately excluded (this file plants violation fixtures). The Messages extension joined on
    /// 2026-09-23; `PowerOfTenBoundaryTests.everyShippingCodeWallScansEveryShippingRoot()` now
    /// fails when a shipping root is missing here.
    static let shippingRoots = [
        "App/Fernlet", "FernletKit/Sources", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension"
    ]

    /// Minimum shipping files the scan must see; catches a broken enumerator, not churn.
    private static let scanFloor = 250

    /// Enumerates every shipping Swift file under ``shippingRoots``.
    private func shippingSwiftFiles() -> [URL] {
        let repoRoot = RepoRoot.url
        var files: [URL] = []
        for root in Self.shippingRoots {
            let rootURL = repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("scan root missing: \(root)")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }

    /// Matcher: does this source opt a keychain write into iCloud Keychain sync?
    static func containsSynchronizableTrue(_ source: String) -> Bool {
        source.contains("synchronizable: true")
    }

    /// Matcher: every bare (non-`ThisDeviceOnly`) accessibility-class token in `source`.
    /// A constant name immediately followed by `ThisDeviceOnly` is device-bound and ignored.
    static func bareAccessibilityTokens(in source: String) -> [String] {
        let bareClasses = ["kSecAttrAccessibleAfterFirstUnlock", "kSecAttrAccessibleWhenUnlocked", "kSecAttrAccessibleAlways"]
        var hits: [String] = []
        for token in bareClasses {
            var searchRange = source.startIndex..<source.endIndex
            while let range = source.range(of: token, range: searchRange) {
                let suffixStart = range.upperBound
                if !source[suffixStart...].hasPrefix("ThisDeviceOnly") {
                    hits.append(token)
                }
                searchRange = range.upperBound..<source.endIndex
            }
        }
        return hits
    }

    // MARK: Wall: `synchronizable: true` may appear ONLY in SealedBackupEscrowKey.swift (the escrow
    // key's promotion to iCloud Keychain — the one key whose entire purpose is to sync).
    // Exact-set both ways: a new syncing write fails, and a stale allowance fails.
    @Test func synchronizableTrueIsConfinedToTheEscrowService() throws {
        let files = shippingSwiftFiles()
        #expect(files.count >= Self.scanFloor, "scan saw \(files.count) files — enumerator broken?")
        var hitFiles: Set<String> = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if Self.containsSynchronizableTrue(source) { hitFiles.insert(url.lastPathComponent) }
        }
        #expect(hitFiles == ["SealedBackupEscrowKey.swift"],
                "iCloud-Keychain-synchronizable keychain writes must exist only in the escrow promotion; found \(hitFiles.sorted())")
    }

    // MARK: Wall: a bare non-ThisDeviceOnly accessibility class may appear ONLY in the two
    // sanctioned files (media key = backup-restorable by product decision; SealedBackupEscrowKey =
    // the synced escrow slots). Everything else must be ThisDeviceOnly.
    @Test func bareAccessibilityClassesAreConfinedToTheSanctionedFiles() throws {
        let files = shippingSwiftFiles()
        #expect(files.count >= Self.scanFloor)
        var hitFiles: Set<String> = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if !Self.bareAccessibilityTokens(in: source).isEmpty { hitFiles.insert(url.lastPathComponent) }
        }
        #expect(hitFiles == ["PrivateMediaKeyStore.swift", "SealedBackupEscrowKey.swift"],
                "non-device-bound accessibility classes must stay confined to the two sanctioned files; found \(hitFiles.sorted())")
    }

    // MARK: Wall: every shipping identity is built by its host's door. An identity that carries no
    // escrow participant mints over the key-agreement row a pre-migration build left without first
    // promoting that key into its escrow slot, destroying the user's backup key on the first
    // provisioning, so an identity may be constructed ONLY in the app's factory
    // (`IdentityService.fernletApp(keychainService:)`, which carries `SealedBackupEscrowKey`, and which
    // `FernletStore.makeProximityIdentity()` answers). ProximityKit constructs none: its host door has
    // no default, so a host answers it, and a new convenience initializer or static factory of the
    // identity anywhere else is a construction too.

    /// The shipping files that may construct an `IdentityService`, by repo-relative path: the app's
    /// factory, alone.
    static let identityConstructionHomes: Set<String> = ["App/Fernlet/SealedBackupEscrowKey.swift"]

    /// ProximityKit's file that declares the identity, the one place its initializers may delegate to
    /// one another: a delegating initializer there is the identity's own API, and every call of it is
    /// still read where it is made.
    static let identityDeclarationFile = "FernletKit/Sources/ProximityKit/Identity/IdentityService.swift"

    /// An argument list whose first label is one of the identity's initializer's three
    /// (`namespace:`, `keychainService:`, `provisioningParticipant:`).
    private static let identityFirstLabel = #"\(\s*(?:namespace|keychainService|provisioningParticipant)\s*:"#

    /// Matcher: the 1-based lines of lexed `code` (comments removed, literals emptied) that construct
    /// an identity: a call of the type (`IdentityService(…)`, `IdentityService.init(…)`), or an implicit
    /// initializer (`.init(…)`, `Self(…)`, `Self.init(…)`) under one of the identity's three labels
    /// first, which no other shipping type is built with implicitly today, so a construction cannot
    /// hide behind type inference.
    static func identityConstructionLines(in code: String) -> [Int] {
        let pattern = #"(?<![A-Za-z0-9_])IdentityService\s*(?:\.\s*init\s*)?\("#
            + #"|(?<![A-Za-z0-9_.])(?:Self\s*(?:\.\s*init\s*)?|\.\s*init\s*)"# + identityFirstLabel
        return lines(matching: pattern, in: code)
    }

    /// Matcher: the 1-based lines of lexed `code` on which an initializer delegates under one of the
    /// identity's three labels first (`self.init(namespace:`, …), read only where the code names
    /// `IdentityService`, as the extension that holds a convenience initializer of the identity does:
    /// another type's delegation to its own `init(namespace:)` or `init(keychainService:)`, in a file
    /// whose code never names the identity, is not one.
    static func identityDelegationLines(in code: String) -> [Int] {
        guard !lines(matching: #"(?<![A-Za-z0-9_])IdentityService(?![A-Za-z0-9_])"#, in: code).isEmpty else {
            return []
        }
        return lines(matching: #"(?<![A-Za-z0-9_.])self\s*\.\s*init\s*"# + identityFirstLabel, in: code)
    }

    /// The 1-based lines of `code` on which `pattern` matches, or `[-1]`, which no sample expects and
    /// no file passes, when the pattern does not compile.
    private static func lines(matching pattern: String, in code: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [-1] }
        let text = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: text.length)).map {
            text.substring(to: $0.range.location).count(where: { $0 == "\n" }) + 1
        }
    }

    /// Every shipping Swift file constructs an identity only in ``identityConstructionHomes``, exact
    /// both ways, read as lexed code (`SwiftSourceLexer`, from `ProximityNamespaceBoundaryTests`), so
    /// a doc comment or a string that spells a construction is not one: a construction in any file, and
    /// a delegating initializer in any file but ``identityDeclarationFile``. Both matchers are held to
    /// their samples and their neighbours first.
    @Test func everyShippingIdentityIsBuiltByItsHostsDoor() throws {
        Self.expectTheIdentityMatchersSeeTheirSamplesAndNoNeighbour()
        var homes: Set<String> = []
        var scanned = 0
        // R2: bounded by the five shipping roots and each root's finite file list.
        for root in Self.shippingRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("scan root missing: \(root)")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                scanned += 1
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // A path that does not resolve under its root is kept whole, so it fails the set loudly.
                let suffix = url.path.range(of: "/" + root + "/", options: .backwards).map { url.path[$0.upperBound...] }
                let path = suffix.map { root + "/" + $0 } ?? url.path
                let code = SwiftSourceLexer.lex(source).code
                let delegations = path == Self.identityDeclarationFile ? [] : Self.identityDelegationLines(in: code)
                guard !(Self.identityConstructionLines(in: code) + delegations).isEmpty else { continue }
                homes.insert(path)
            }
        }
        #expect(scanned >= Self.scanFloor, "scan saw \(scanned) files — enumerator broken?")
        #expect(homes == Self.identityConstructionHomes, """
            shipping code constructs an IdentityService in \(homes.sorted()); only \
            \(Self.identityConstructionHomes.sorted()) may. Build Fernlet's identity with \
            `IdentityService.fernletApp(keychainService:)` (it carries the sealed-backup escrow key), a \
            manager's with its host's `makeProximityIdentity()`, add no initializer or factory of the \
            identity outside ProximityKit's `Identity/IdentityService.swift`, and spell any other type's \
            `init(namespace:)` with its type name.
            """)
    }

    /// The construction matcher reads every way a construction is spelled and none of the nearest code
    /// that builds no identity (another type's initializer under the same label, the lock service's own
    /// delegation, the factory's call, a static read); the delegation matcher reads a convenience
    /// initializer of the identity delegating under its first label or under another initializer's,
    /// and not another type's delegation in code that never names the identity, even when a comment
    /// does, nor code that names it and delegates nothing. Each sample is lexed first, as the files are.
    private static func expectTheIdentityMatchersSeeTheirSamplesAndNoNeighbour() {
        let constructions = [
            "let id = IdentityService(namespace: .fernlet)", "let id = IdentityService.init(namespace: n)",
            "let id: IdentityService = .init(namespace: n)", "return Self(namespace: n, keychainService: s)",
            "return Self.init(namespace: n)", "let id: IdentityService = .init(keychainService: s)",
            "let id: IdentityService = .init(provisioningParticipant: nil)"
        ]
        let notConstructions = [
            "let tag = IdentityService.fingerprint(of: key)", "let identity: IdentityService",
            "/// IdentityService(namespace:)", #"let s = "IdentityService(namespace: .fernlet)""#,
            "let id = IdentityService.fernletApp()", "self.init(namespace: .fernlet, keychainService: service)",
            "let radio = NetworkMeshSession(namespace: namespace)",
            "let lock = FernletLockService(keychainService: service)",
            "self.init(\n    keychainService: keychainService,\n    sealedContentKeyServices: services\n)"
        ]
        let delegations = [
            "extension IdentityService {\n    convenience init(service: String) {\n        self.init(namespace: .fernlet, keychainService: service)\n    }\n}",
            "extension IdentityService {\n    convenience init(service: String) {\n        self.init(keychainService: service)\n    }\n}"
        ]
        let notDelegations = [
            "final class Radio {\n    convenience init() {\n        self.init(namespace: .fernlet)\n    }\n}",
            "/// IdentityService\nconvenience init(service: String) {\n    self.init(keychainService: service)\n}",
            "extension IdentityService {\n    static let shared = fernletApp()\n}"
        ]
        // R2: bounded by the four fixture lists.
        for sample in constructions {
            #expect(identityConstructionLines(in: SwiftSourceLexer.lex(sample).code) == [1], "missed: \(sample)")
        }
        for neighbour in notConstructions {
            #expect(identityConstructionLines(in: SwiftSourceLexer.lex(neighbour).code).isEmpty,
                    "read a construction in: \(neighbour)")
        }
        for sample in delegations {
            #expect(identityDelegationLines(in: SwiftSourceLexer.lex(sample).code) == [3], "missed: \(sample)")
        }
        for neighbour in notDelegations {
            #expect(identityDelegationLines(in: SwiftSourceLexer.lex(neighbour).code).isEmpty,
                    "read a delegation in: \(neighbour)")
        }
    }

    // MARK: Behaviour: the app's store hands its three managers Fernlet's custody. The construction
    // wall above holds every shipping construction to the app's factory, and ProximityKit's host door
    // has no default, so the store must answer it; this cell holds what the managers hold at run time.

    /// The app's own store (`makeTestStore()`, the real `FernletStore`) hands its mesh, recipe-share and
    /// presence managers, each built with no identity, an identity whose provisioning participant is a
    /// `SealedBackupEscrowKey`, one of its own per identity, and its host door, asked through the
    /// protocol as the managers ask it, answers the same. A participant-less identity on a device a
    /// pre-migration build left in provisioning Case 3 would mint over the synced key-agreement row
    /// without promoting it into the escrow, destroying the user's backup key. Each manager keeps its
    /// identity private, so it is read by reflection: a manager that stops keeping one under that name
    /// fails here by name.
    @MainActor
    @Test func theStoresManagersHoldIdentitiesCarryingTheEscrowKey() throws {
        let store = makeTestStore()
        let host: any ProximityHost = store
        #expect(host.makeProximityIdentity().provisioningParticipant is SealedBackupEscrowKey,
                "the store's host door answers an identity without the sealed-backup escrow key")
        let managers: [(name: String, manager: AnyObject)] = [
            ("mesh", store.meshNetworkManager), ("recipe-share", store.recipeShareManager),
            ("presence", store.presenceManager)
        ]
        var participants: Set<ObjectIdentifier> = []
        // R2: bounded by the three managers.
        for (name, manager) in managers {
            let identity = try #require(Self.heldIdentity(of: manager), "the \(name) manager keeps no `identity`")
            let participant = try #require(identity.provisioningParticipant as? SealedBackupEscrowKey,
                                           "the \(name) manager's identity does not carry the sealed-backup escrow key")
            participants.insert(ObjectIdentifier(participant))
        }
        #expect(participants.count == managers.count, "two managers' identities share one escrow key")
    }

    /// The `IdentityService` a manager keeps in its stored `identity` property, read by reflection, or
    /// nil when it keeps none under that name.
    private static func heldIdentity(of manager: AnyObject) -> IdentityService? {
        Mirror(reflecting: manager).children.first { $0.label == "identity" }?.value as? IdentityService
    }

    // MARK: Fixtures: prove both matchers actually fire on planted violations (and stay quiet on
    // the device-bound spellings), so the walls above cannot rot into always-passing.
    @Test func custodyMatchersFlagPlantedViolations() {
        #expect(Self.containsSynchronizableTrue(
            "KeychainItem.store(d, account: a, service: s, accessibility: x, synchronizable: true)"))
        #expect(!Self.containsSynchronizableTrue(
            "KeychainItem.store(d, account: a, service: s, accessibility: x, synchronizable: false)"))

        #expect(Self.bareAccessibilityTokens(in: "let a = kSecAttrAccessibleAfterFirstUnlock") == ["kSecAttrAccessibleAfterFirstUnlock"])
        #expect(Self.bareAccessibilityTokens(in: "let a = kSecAttrAccessibleWhenUnlocked,") == ["kSecAttrAccessibleWhenUnlocked"])
        #expect(Self.bareAccessibilityTokens(in: "let a = kSecAttrAccessibleAlways").count == 1)
        #expect(Self.bareAccessibilityTokens(in: "let a = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly").isEmpty)
        #expect(Self.bareAccessibilityTokens(in: "let a = kSecAttrAccessibleWhenUnlockedThisDeviceOnly").isEmpty)
    }

    // MARK: Source pin: the biometric bypass copy of the content key keeps the strongest class
    // in the app — WhenPasscodeSetThisDeviceOnly behind a .biometryCurrentSet gate. (Runtime
    // verification is impossible on a passcode-less simulator, so this one is a source pin.)
    @Test func biometricBypassACLIsPinnedInSource() throws {
        let url = RepoRoot.url
            .appendingPathComponent("FernletKit/Sources/FernletLock/FernletLockService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly"))
        #expect(source.contains(".biometryCurrentSet"))
    }
}
