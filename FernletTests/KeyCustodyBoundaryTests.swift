import CryptoKit
import Foundation
import PrivateMediaStore
import ProximityKit
import Security
import Testing
import FernletFoundation
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
///   `synchronizable: true` (the escrow promotion) only in `IdentityService.swift`, and a bare
///   non-`ThisDeviceOnly` accessibility class only in `PrivateMediaKeyStore.swift` +
///   `IdentityService.swift`. Exact-set in both directions, with planted-violation fixtures and
///   a scan floor, so the wall can neither miss a new file nor rot into a stale allowance.
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
        for key in [LockKeychainKey.salt, .verifier, .wrappedContentKey, .seWrappedContentKey] {
            KeychainItem.store(Data([0xAB]), for: key, service: service)
            let attrs = rowAttributes(account: key.rawValue, service: service)
            #expect(attrs?.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                    "\(key.rawValue) must be WhenUnlockedThisDeviceOnly")
            #expect(attrs?.synchronizable == false, "\(key.rawValue) must never sync")
        }
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

    /// Shipping-code roots — app, all package modules, and both extensions. Test targets are
    /// deliberately excluded (this file plants violation fixtures).
    private static let shippingRoots = ["Fernlet", "FernletKit/Sources", "FernletWidgets", "FernletShareExtension"]

    /// Minimum shipping files the scan must see; catches a broken enumerator, not churn.
    private static let scanFloor = 250

    /// Enumerates every shipping Swift file under ``shippingRoots``.
    private func shippingSwiftFiles() -> [URL] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    // MARK: Wall: `synchronizable: true` may appear ONLY in IdentityService.swift (the escrow
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
        #expect(hitFiles == ["IdentityService.swift"],
                "iCloud-Keychain-synchronizable keychain writes must exist only in the escrow promotion; found \(hitFiles.sorted())")
    }

    // MARK: Wall: a bare non-ThisDeviceOnly accessibility class may appear ONLY in the two
    // sanctioned files (media key = backup-restorable by product decision; IdentityService =
    // the synced escrow slots). Everything else must be ThisDeviceOnly.
    @Test func bareAccessibilityClassesAreConfinedToTheSanctionedFiles() throws {
        let files = shippingSwiftFiles()
        #expect(files.count >= Self.scanFloor)
        var hitFiles: Set<String> = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if !Self.bareAccessibilityTokens(in: source).isEmpty { hitFiles.insert(url.lastPathComponent) }
        }
        #expect(hitFiles == ["PrivateMediaKeyStore.swift", "IdentityService.swift"],
                "non-device-bound accessibility classes must stay confined to the two sanctioned files; found \(hitFiles.sorted())")
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
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FernletKit/Sources/FernletLock/FernletLockService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly"))
        #expect(source.contains(".biometryCurrentSet"))
    }
}
