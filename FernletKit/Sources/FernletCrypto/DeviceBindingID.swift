import Foundation
import Security
import Synchronization

/// The per-install random identifier that device-binds new sealed-column ciphertext.
///
/// A 16-byte cryptographically random value, minted once per install into a
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never-synchronized keychain row and
/// passed by ``ColumnCrypto`` as part of the ChaChaPoly *additional authenticated data* — the
/// column purpose ‖ this ID — on every sealed write, all of which are format v3. Because the row
/// is `ThisDeviceOnly`, the ID — like every key that can open the sealed corpus — restores only
/// onto the same physical device, so a V3 ciphertext refuses to authenticate anywhere else even
/// if the content key were somehow exfiltrated with it. Losing the row implies the (equally
/// `ThisDeviceOnly`) content keys are gone too, so no new data-loss mode is introduced
/// (Docs/Verifiability.md §4).
///
/// **Fail-closed on the write side (owner decision D4, Phase 3).** The binding is a GATE now,
/// not defense-in-depth. ``current()`` still answers `nil` when the keychain cannot produce a
/// durable ID, but the one seal entry — `ColumnCrypto.sealPlaintextV3Strict` — turns that `nil`
/// into `SealedColumnStrictSealError.bindingUnavailable`, and the caller sees a FAILED save.
/// Until Phase 3 it fell back to the un-domained legacy blob instead, on the argument that
/// binding should never block a save; that fallback is exactly why every format-census zero was
/// a moment rather than a latch, because the row is `AfterFirstUnlockThisDeviceOnly` and a
/// single write in the pre-first-unlock window could re-mint a legacy blob on any shipping
/// build, at any time, after the count had read zero. A failed save is the accepted cost of a
/// legacy population that can only shrink. What has NOT changed is the durability gate: an ID is
/// returned **only after** a read-back confirms the row is durably stored, because sealing under
/// an AAD that would not be reproducible at open time is the one outcome worse than refusing.
///
/// The open side still distinguishes harder, and that distinction outlived the fallback it was
/// built beside: ``currentForOpen()`` separates an authoritatively absent row — `nil`, which
/// `ColumnCrypto.openBlob` refuses as `SealedColumnOpenError.installBindingMissing`, terminal
/// because the AAD can no longer be reconstructed — from a failed keychain read, which throws
/// the retryable ``ReadError`` and is deliberately never flattened into an open failure. So a
/// transient keychain outage degrades to "try again" instead of making V3 ciphertext look
/// corrupted. There is no legacy open left to fall through to: `openBlob` refuses every
/// non-`0x03` marker as `SealedColumnOpenError.retiredFormat`.
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
    /// `.unavailable` simulates an authoritatively absent row (the refusal path on both sides);
    /// `.readError` simulates a transient keychain read failure (row state unknown).
    /// Task-local so parallel test suites cannot leak an override into each other or into
    /// repository tests that seal against the real row.
    enum TestOverride {
        /// Behave as if the install ID is exactly these bytes.
        case identifier(Data)
        /// Behave as if no durable install ID exists or can be produced: the seal refuses with
        /// `SealedColumnStrictSealError.bindingUnavailable` and the open refuses with
        /// `SealedColumnOpenError.installBindingMissing`. Neither writes or reads anything.
        case unavailable
        /// Behave as if the keychain read itself errored: ``current()`` returns `nil` — the seal
        /// treats "row state unknown" like "no binding" and refuses — while ``currentForOpen()``
        /// throws ``ReadError``, which propagates to the caller as retryable rather than as a
        /// format or authentication claim.
        case readError
        /// Behave as whatever `binding` currently answers — the MUTABLE override for tests that
        /// must change the install binding *mid-operation*. The pins it was added for (the Phase
        /// 2.6 environment-break and binding-read-error cases, which flipped the answer between
        /// the format migrator's seal and its read-back) went with that migrator in Phase 3, so
        /// it currently has no caller; it survives because "the answer changes mid-flight" is a
        /// scenario the three static cases below cannot express at all. Those stay the default
        /// idiom; reach for this only when a fixed answer cannot express the scenario.
        case scripted(ScriptedBinding)
    }

    /// The reference-typed mutable answer behind ``TestOverride/scripted(_:)``: a `Mutex`-owned
    /// slot the test flips while the code under test is mid-flight. Test seam only — production
    /// reads never see it because ``testOverride`` is always `nil` there.
    final class ScriptedBinding: Sendable {
        /// One scripted keychain answer, mirroring the three static override cases.
        enum Answer: Sendable {
            /// The install ID is exactly these bytes.
            case identifier(Data)
            /// No durable install ID exists (authoritative absence).
            case unavailable
            /// The keychain read itself errors (row state unknown, retryable).
            case readError
        }

        /// The current scripted answer; owned by the lock, like ``DeviceBindingID/cache``.
        private let slot: Mutex<Answer>

        /// Creates a scripted binding answering `initial` until ``set(_:)`` changes it.
        init(_ initial: Answer) {
            slot = Mutex(initial)
        }

        /// Replaces the scripted answer; the next binding read observes it.
        func set(_ answer: Answer) {
            slot.withLock { $0 = answer }
        }

        /// The answer reads observe right now.
        var current: Answer {
            slot.withLock { $0 }
        }
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
    /// - Returns: The 16-byte install ID, or `nil` when the keychain cannot durably store one —
    ///   at which point the seal REFUSES (`SealedColumnStrictSealError.bindingUnavailable`);
    ///   there is no unbound format left to fall back to. Failures are not cached, so a
    ///   transient keychain error is retried on the next call; successes are.
    public static func current() -> Data? {
        if let override = testOverride {
            switch override {
            case .identifier(let data): return data
            case .unavailable, .readError: return nil
            case .scripted(let scripted):
                // Mirrors the static cases: a scripted read error still answers `nil` here, so the
                // seal side treats "row state unknown" exactly like "no binding" — and, since D4,
                // that means it blocks the save rather than writing an unbound blob.
                if case .identifier(let data) = scripted.current { return data }
                return nil
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

    /// Returns the binding ID for *opening* an existing V3 blob, distinguishing an absent row
    /// from a failed keychain read.
    ///
    /// Unlike ``current()`` this never mints: a V3 blob can only exist because an ID was durably
    /// stored on this install, so a freshly minted ID could never open it. Absence is therefore
    /// an authoritative `nil`, which `ColumnCrypto.openBlob` turns into
    /// `SealedColumnOpenError.installBindingMissing` — terminal, and pointedly not an
    /// authentication claim, because nothing is wrong with the ciphertext. A read *error*
    /// instead throws ``ReadError`` so ``ColumnCrypto`` can surface a retryable failure rather
    /// than a spurious authentication failure. Keeping those two apart is this method's whole
    /// reason to exist, and it outlived the legacy open it was originally written to feed.
    /// Successes populate the same cache as ``current()``; failures are never cached, so the
    /// next call re-reads the keychain.
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
            case .scripted(let scripted):
                switch scripted.current {
                case .identifier(let data): return data
                case .unavailable: return nil
                case .readError: throw ReadError(status: errSecIO)
                }
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
        /// retry can fix — treated as absent so it refuses like a missing row instead of being
        /// retried forever as ``ReadError``).
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
