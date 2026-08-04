import Foundation
import FernletFoundation
import CryptoKit
import Security
import FernletDomainModel

/// Supplies the symmetric key the module's media stores use to encrypt bytes at rest.
///
/// One provider (and thus one key) is shared by every sealed media store — ``PrivateMediaStore``,
/// ``MealPhotoStore``, and ``ProgressPhotoStore`` all take one at init. Kept as a protocol so
/// tests can inject an in-memory key instead of touching the real keychain; the production
/// conformer is ``KeychainPrivateMediaKeyProvider``. Every store treats a nil key as "do not
/// write plaintext" (fail-closed), so a provider that can't produce a key disables persistence
/// rather than weakening it.
public protocol PrivateMediaKeyProviding {
    /// The media-encryption key, generating and persisting one on first use.
    /// Returns nil only when the key cannot be created or read (e.g. keychain unavailable).
    func mediaKey() -> SymmetricKey?

    /// Delete-all seam (Docs/PrivacyWipeCoverage.md): drop any in-memory copy of the key so a
    /// post-wipe capture can't encrypt under a keychain row that no longer exists (such bytes
    /// would surface as `.unreadable` after relaunch mints a fresh key). No-op by default —
    /// in-memory test providers have nothing stale to drop.
    func invalidateCachedKey()
}

extension PrivateMediaKeyProviding {
    public func invalidateCachedKey() {}
}

/// Keychain-backed provider for the module's shared at-rest media key.
///
/// The default ``PrivateMediaKeyProviding`` used by every media store. The key is a random
/// 256-bit key, generated once and reused: all provider instances read the SAME keychain row
/// (fixed service/account), so the stores share one key even when each store default-constructs
/// its own provider. It is stored **backup-restorable** (`kSecAttrAccessibleAfterFirstUnlock`,
/// *not* `…ThisDeviceOnly`) so the encrypted media cache — which is included in the standard
/// iCloud device backup through the app container (spec §16/§19) — can still be decrypted after
/// that backup is restored onto a new device. The key rides along in the same encrypted backup
/// as the bytes it protects, so neither the bytes nor the key are exposed unless that backup is
/// restored.
///
/// Concurrency: NOT `Sendable` — `cachedKey` is unsynchronized mutable state, safe only because
/// each instance stays inside one isolation domain (in practice, the main actor of the store
/// owner). Failure mode: if the keychain can't store or return the key, ``mediaKey()`` returns
/// nil and every dependent store fails closed (nothing written in plaintext).
public final class KeychainPrivateMediaKeyProvider: PrivateMediaKeyProviding {
    static let service = "com.fernlet.private-media"
    static let account = "com.fernlet.private-media.contentKey"

    /// In-memory copy of the key, cached to avoid a keychain hit per byte read. Unsynchronized:
    /// confined by convention to the owning store's isolation domain (in practice the main actor
    /// of `MeshNetworkManager` or the app's `FernletStore`).
    private var cachedKey: SymmetricKey?

    public init() {}

    /// Returns the shared media key: cached copy first, then the keychain row, else a freshly
    /// minted 256-bit key persisted to the keychain.
    /// - Returns: The key, or nil when a new key could not be stored (nothing is cached then,
    ///   so dependent stores fail closed rather than sealing under an unpersisted key).
    public func mediaKey() -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        if let existing = KeychainItem.load(account: Self.account, service: Self.service) {
            let key = SymmetricKey(data: existing)
            cachedKey = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let status = KeychainItem.store(
            keyData,
            account: Self.account,
            service: Self.service,
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        )
        guard status == errSecSuccess else { return nil }
        cachedKey = key
        return key
    }

    /// Drops the in-memory key copy so the next ``mediaKey()`` call re-reads (or re-mints from)
    /// the keychain — the delete-all seam described on the protocol requirement.
    public func invalidateCachedKey() {
        cachedKey = nil
    }

    /// Removes the shared at-rest media key row. **Deliberately has no callers** — do not add one.
    ///
    /// The row is a single keychain item shared by EVERY `PrivateMediaStore`, including the friend
    /// photo wall's cache, which survives "Delete everything" by design (product decision: friends'
    /// shared photos are the friends' gift, removed one at a time). Delete-all used to call this on
    /// the premise that every media store had been emptied first; that premise is false for exactly
    /// the one store deliberately left full, so the call silently destroyed the wall — the photos
    /// kept rendering from the in-memory key until relaunch, then `mediaKey()` minted a fresh key
    /// and every retained photo decrypted to garbage. See Docs/PrivacyWipeCoverage.md.
    ///
    /// Kept as API only for a future caller that first empties the wall too. A key whose stores are
    /// all empty protects nothing, so leaving the row in place leaks nothing.
    public static func deleteKeychainRowForWipe() {
        KeychainItem.delete(account: account, service: service)
    }
}
