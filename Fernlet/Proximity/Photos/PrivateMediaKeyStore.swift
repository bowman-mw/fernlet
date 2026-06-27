import Foundation
import FernletFoundation
import CryptoKit
import Security

/// Supplies the symmetric key `PrivateMediaStore` uses to encrypt cached media bytes at rest.
///
/// Kept as a protocol so tests can inject an in-memory key instead of touching the real keychain.
protocol PrivateMediaKeyProviding {
    /// The media-encryption key, generating and persisting one on first use.
    /// Returns nil only when the key cannot be created or read (e.g. keychain unavailable).
    func mediaKey() -> SymmetricKey?
}

/// Keychain-backed provider for `PrivateMediaStore`'s at-rest key.
///
/// The key is a random 256-bit key, generated once and reused. It is stored
/// **backup-restorable** (`kSecAttrAccessibleAfterFirstUnlock`, *not* `…ThisDeviceOnly`) so the
/// encrypted media cache — which is included in the standard iCloud device backup through the app
/// container (spec §16/§19) — can still be decrypted after that backup is restored onto a new
/// device. The key rides along in the same encrypted backup as the bytes it protects, so neither
/// the bytes nor the key are exposed unless that backup is restored.
final class KeychainPrivateMediaKeyProvider: PrivateMediaKeyProviding {
    static let service = "com.fernlet.private-media"
    static let account = "com.fernlet.private-media.contentKey"

    /// Confined to `MeshNetworkManager`'s main actor; cached to avoid a keychain hit per byte read.
    private var cachedKey: SymmetricKey?

    func mediaKey() -> SymmetricKey? {
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
}
