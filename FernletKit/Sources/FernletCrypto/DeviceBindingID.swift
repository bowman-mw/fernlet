import Foundation
import Security
import Synchronization

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
/// read-back confirms the row is durably stored. The open side distinguishes harder:
/// ``currentForOpen()`` separates an authoritatively absent row (fall through to the legacy
/// open) from a failed keychain read (throws the retryable ``ReadError``), so a transient
/// keychain outage degrades to "try again" instead of making v2 ciphertext look corrupted.
///
/// Deliberately self-contained (direct Security-framework calls, no `FernletFoundation`
/// dependency) so `FernletCrypto` keeps its zero-in-package-dependency layering.
///
/// Concurrency: `nonisolated` (this module defaults to MainActor isolation, but the sealed-store
/// repositories call ``ColumnCrypto`` from nonisolated `performAndWait` closures). The cache is a
/// `Mutex` that owns its slot; the keychain itself is thread-safe. ``testOverride`` is a `@TaskLocal`, so
/// concurrent test suites can each pin their own binding without touching the real keychain.
public nonisolated enum DeviceBindingID {
    /// Keychain service namespace for the install-binding row.
    static let service = "com.fernlet.device-binding"
    /// Keychain account of the install-binding row.
    static let account = "com.fernlet.device-binding.installID"
    /// Size of the minted identifier in bytes.
    static let idByteCount = 16

    /// Test seam: what ``current()`` / ``currentForOpen()`` should pretend the install binding is.
    ///
    /// `.identifier` pins a specific ID (e.g. to simulate two different installs);
    /// `.unavailable` simulates an authoritatively absent row (the legacy-format path);
    /// `.readError` simulates a transient keychain read failure (row state unknown).
    /// Task-local so parallel test suites cannot leak an override into each other or into
    /// repository tests that seal against the real row.
    enum TestOverride {
        /// Behave as if the install ID is exactly these bytes.
        case identifier(Data)
        /// Behave as if no durable install ID exists or can be produced (seal falls back to
        /// legacy; open falls through to the legacy path).
        case unavailable
        /// Behave as if the keychain read itself errored: ``current()`` returns `nil`
        /// (seal falls back to legacy) while ``currentForOpen()`` throws ``ReadError``.
        case readError
    }

    /// The install-binding keychain read failed with an error other than "row not found".
    ///
    /// Thrown only by ``currentForOpen()``, and only when the row's state is *unknown* — the
    /// keychain answered with an error status rather than an authoritative absence. Retryable by
    /// contract: failures are never cached, so the next open re-reads the keychain, and a
    /// transient outage (e.g. `errSecInteractionNotAllowed` before first unlock, or a spurious
    /// `errSecInternal`) degrades to "try again" instead of a spurious authentication failure
    /// that reads like corrupted data.
    public struct ReadError: Error {
        /// The `SecItemCopyMatching` status the read failed with.
        public let status: OSStatus
    }

    /// The task-local test override consulted before the keychain; always `nil` in production.
    @TaskLocal static var testOverride: TestOverride?

    /// The durably-stored install ID, cached after the first successful read or mint.
    ///
    /// A `Mutex` that OWNS the value rather than a mutable static guarded by a separate lock: the
    /// keychain row is immutable once minted, so a read-through cache is sufficient, and holding
    /// the slot inside the lock makes the access discipline a property the compiler checks instead
    /// of a convention repeated at three call sites (Power of 10 R6 — no stored `static var` — and
    /// R9 — no `nonisolated(unsafe)`).
    private static let cache = Mutex<Data?>(nil)

    /// Returns this install's binding ID, minting and durably persisting one on first use.
    ///
    /// - Returns: The 16-byte install ID, or `nil` when the keychain cannot durably store one
    ///   (callers must then seal in the legacy unbound format). Failures are not cached, so a
    ///   transient keychain error is retried on the next call; successes are.
    public static func current() -> Data? {
        if let override = testOverride {
            switch override {
            case .identifier(let data): return data
            case .unavailable, .readError: return nil
            }
        }
        return cache.withLock { slot -> Data? in
            if let slot { return slot }
            if case .found(let existing) = load() {
                slot = existing
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
            guard case .found(let stored) = load() else { return nil }
            slot = stored
            return stored
        }
    }

    /// Returns the binding ID for *opening* an existing v2 blob, distinguishing an absent row
    /// from a failed keychain read.
    ///
    /// Unlike ``current()`` this never mints: a v2 blob can only exist because an ID was durably
    /// stored on this install, so a freshly minted ID could never open it. Absence is therefore
    /// an authoritative `nil` — the caller falls through to the legacy open, which correctly
    /// refuses a true v2 blob whose binding row is genuinely gone — while a read *error* throws
    /// ``ReadError`` so ``ColumnCrypto`` can surface a retryable failure instead of a spurious
    /// authentication failure. Successes populate the same cache as ``current()``; failures are
    /// never cached, so the next call re-reads the keychain.
    ///
    /// - Returns: The 16-byte install ID, or `nil` when the keychain authoritatively reports no
    ///   row exists.
    /// - Throws: ``ReadError`` when the keychain read failed (row state unknown, retry later).
    public static func currentForOpen() throws -> Data? {
        if let override = testOverride {
            switch override {
            case .identifier(let data): return data
            case .unavailable: return nil
            case .readError: throw ReadError(status: errSecIO)
            }
        }
        return try cache.withLock { slot -> Data? in
            if let slot { return slot }
            switch load() {
            case .found(let existing):
                slot = existing
                return existing
            case .absent:
                return nil
            case .failure(let status):
                throw ReadError(status: status)
            }
        }
    }

    /// Drops the in-memory cache so the next ``current()`` re-reads the keychain (test hygiene
    /// after a test deletes the row; production never needs it — the row is immutable).
    static func invalidateCacheForTesting() {
        cache.withLock { $0 = nil }
    }

    /// Outcome of one keychain read of the install-ID row, distinguishing "no row" from "the
    /// read itself failed" — the seam ``currentForOpen()`` needs so a transient keychain error
    /// degrades to retry instead of masquerading as a missing binding.
    private enum LoadResult {
        /// The row exists and carries a well-formed 16-byte ID.
        case found(Data)
        /// The keychain answered authoritatively: no such row (or a malformed one, which no
        /// retry can fix — treated as absent so behavior stays fail-open).
        case absent
        /// The read errored (any status other than success/not-found); the row's state is
        /// unknown and a later retry may succeed.
        case failure(OSStatus)
    }

    /// Reads the install-ID row, classifying the result per ``LoadResult``.
    private static func load() -> LoadResult {
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == idByteCount else { return .absent }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        default:
            return .failure(status)
        }
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
