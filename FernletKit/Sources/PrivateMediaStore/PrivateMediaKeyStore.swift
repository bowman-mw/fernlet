import Foundation
import FernletFoundation
import CryptoKit
import Security
import FernletDomainModel

/// Supplies the symmetric key `PrivateMediaStore` uses to encrypt cached media bytes at rest.
///
/// Kept as a protocol so tests can inject an in-memory key instead of touching the real keychain.
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

/// Keychain-backed provider for `PrivateMediaStore`'s at-rest key.
///
/// The key is a random 256-bit key, generated once and reused. It is stored
/// **backup-restorable** (`kSecAttrAccessibleAfterFirstUnlock`, *not* `…ThisDeviceOnly`) so the
/// encrypted media cache — which is included in the standard iCloud device backup through the app
/// container (spec §16/§19) — can still be decrypted after that backup is restored onto a new
/// device. The key rides along in the same encrypted backup as the bytes it protects, so neither
/// the bytes nor the key are exposed unless that backup is restored.
public final class KeychainPrivateMediaKeyProvider: PrivateMediaKeyProviding {
    static let service = "com.fernlet.private-media"
    static let account = "com.fernlet.private-media.contentKey"

    /// Confined to `MeshNetworkManager`'s main actor; cached to avoid a keychain hit per byte read.
    private var cachedKey: SymmetricKey?

    public init() {}

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
