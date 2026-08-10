import Foundation
import Security

/// The per-install random identifier that device-binds new sealed-column ciphertext.
///
/// A 16-byte cryptographically random value, minted once per install into a
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never-synchronized keychain row and
/// passed by ``ColumnCrypto`` as ChaChaPoly *additional authenticated data* on every new sealed
/// write (format v2). Because the row is `ThisDeviceOnly`, the ID — like every key that can open
/// the sealed corpus — restores only onto the same physical device, so a v2 ciphertext refuses
/// to authenticate anywhere else even if the content key were somehow exfiltrated with it.
/// Losing the row implies the (equally `ThisDeviceOnly`) content keys are gone too, so no new
/// data-loss mode is introduced (Docs/Verifiability.md §4).
///
/// **Fail-open by design:** binding is defense-in-depth, never a gate. If the keychain cannot
/// produce a durable ID, ``current()`` returns `nil` and sealing falls back to the legacy
/// unbound format — exactly today's behavior — rather than blocking a save or, worse, sealing
/// under an AAD that would not be reproducible at open time. An ID is returned **only after** a
/// read-back confirms the row is durably stored.
///
/// Deliberately self-contained (direct Security-framework calls, no `FernletFoundation`
/// dependency) so `FernletCrypto` keeps its zero-in-package-dependency layering.
///
/// Concurrency: `nonisolated` (this module defaults to MainActor isolation, but the sealed-store
/// repositories call ``ColumnCrypto`` from nonisolated `performAndWait` closures). The cache is
/// guarded by a lock; the keychain itself is thread-safe. ``testOverride`` is a `@TaskLocal`, so
/// concurrent test suites can each pin their own binding without touching the real keychain.
public nonisolated enum DeviceBindingID {
    /// Keychain service namespace for the install-binding row.
    static let service = "com.fernlet.device-binding"
    /// Keychain account of the install-binding row.
    static let account = "com.fernlet.device-binding.installID"
    /// Size of the minted identifier in bytes.
    static let idByteCount = 16

    /// Test seam: what ``current()`` should pretend the install binding is.
    ///
    /// `.identifier` pins a specific ID (e.g. to simulate two different installs);
    /// `.unavailable` simulates a keychain that cannot produce one (the legacy-format path).
    /// Task-local so parallel test suites cannot leak an override into each other or into
    /// repository tests that seal against the real row.
    enum TestOverride {
        /// Behave as if the install ID is exactly these bytes.
        case identifier(Data)
        /// Behave as if no durable install ID can be produced (seal falls back to legacy).
        case unavailable
    }

    /// The task-local test override consulted before the keychain; always `nil` in production.
    @TaskLocal static var testOverride: TestOverride?

    /// Lock guarding ``cached`` (the keychain result is immutable once minted, so a plain
    /// read-through cache is sufficient).
    private static let cacheLock = NSLock()
    /// The durably-stored install ID, cached after the first successful read or mint.
    /// `nonisolated(unsafe)`: all access is through ``cacheLock``.
    nonisolated(unsafe) private static var cached: Data?

    /// Returns this install's binding ID, minting and durably persisting one on first use.
    ///
    /// - Returns: The 16-byte install ID, or `nil` when the keychain cannot durably store one
    ///   (callers must then seal in the legacy unbound format). Failures are not cached, so a
    ///   transient keychain error is retried on the next call; successes are.
    public static func current() -> Data? {
        if let override = testOverride {
            switch override {
            case .identifier(let data): return data
            case .unavailable: return nil
            }
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        if let existing = load() {
            cached = existing
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: idByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, idByteCount, &bytes) == errSecSuccess else { return nil }
        let minted = Data(bytes)
        let addStatus = add(minted)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem { return nil }
        // Durability gate: only trust (and cache) an ID the keychain reads back. Sealing under an
        // unpersisted AAD would make the ciphertext unopenable after relaunch. The read-back also
        // resolves an add/add race (errSecDuplicateItem): whichever row won is the ID.
        guard let stored = load() else { return nil }
        cached = stored
        return stored
    }

    /// Drops the in-memory cache so the next ``current()`` re-reads the keychain (test hygiene
    /// after a test deletes the row; production never needs it — the row is immutable).
    static func invalidateCacheForTesting() {
        cacheLock.lock()
        cached = nil
        cacheLock.unlock()
    }

    /// Reads the install-ID row, returning `nil` when absent, unreadable, or the wrong size.
    private static func load() -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == idByteCount else { return nil }
        return data
    }

    /// Adds the install-ID row (`AfterFirstUnlockThisDeviceOnly`, non-synchronizable — the same
    /// lifecycle class as the no-lock sealing keys that gate the same data).
    private static func add(_ data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }
}
