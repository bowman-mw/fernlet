import Foundation
import FernletFoundation
import CryptoKit
import Security
import FernletDomainModel

/// Supplies the symmetric key a media store uses to encrypt bytes at rest.
///
/// Kept as a protocol so tests can inject an in-memory key instead of touching the real keychain;
/// the production conformer is ``KeychainPrivateMediaKeyProvider``. Every store treats a nil key
/// as "do not write plaintext" (fail-closed), so a provider that can't produce a key disables
/// persistence rather than weakening it.
///
/// - Important: there is no longer ONE key behind every store. Security-hardening Phase 5 split
///   the media key in two — the friend photo wall keeps the original backup-restorable row, the
///   user's OWN photos (meal / recipe / progress) seal under a separate row that is on its way to
///   being device-bound. Which key a provider vends is a property of the provider instance
///   (``KeychainPrivateMediaKeyProvider/Role``), not of this protocol, so stores stay
///   key-agnostic.
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

/// Keychain-backed provider for the module's at-rest media keys.
///
/// The default ``PrivateMediaKeyProviding`` used by every media store. Each key is a random
/// 256-bit key, generated once and reused: all provider instances for a given ``Role`` read the
/// SAME keychain row (fixed service/account), so stores sharing a role share a key even when each
/// store constructs its own provider instance.
///
/// ## Two keys, two custody classes (security-hardening Phase 5, Docs/Verifiability.md §6.3)
///
/// - ``Role/friendWall`` — account `com.fernlet.private-media.contentKey`, the ORIGINAL row,
///   unchanged: `kSecAttrAccessibleAfterFirstUnlock`, *not* `…ThisDeviceOnly`, non-sync, i.e.
///   deliberately **backup-restorable**. The friend photowall cache is included in the standard
///   iCloud device backup through the app container (spec §16/§19) and must still decrypt after
///   that backup lands on a new phone; the key rides along inside the same encrypted backup as the
///   bytes it protects, so neither is exposed unless that backup is restored. Repurposing the
///   existing row for the wall means **zero re-encryption** of the wall and preserves its
///   survives-delete-all / never-deleted-by-wipe properties verbatim.
/// - ``Role/ownPhotos`` — account `com.fernlet.private-media.ownContentKey`, a NEW row for the
///   user's own meal / recipe / progress (body) photos. Minted `AfterFirstUnlock` **for now** so
///   nothing strands while `OwnPhotoKeyMigrator` re-seals the existing corpora; the flip to
///   `AfterFirstUnlockThisDeviceOnly` is step 5c and is a ONE-LINE policy change in
///   ``defaultDeviceBinding(for:)`` (the "flip, not flag-day" precedent set by
///   `SecureEnclaveContentKeyWrap`). It is gated on ``OwnPhotoMigrationLatch`` — binding before
///   every own file is re-sealed would silently turn stragglers into unreadable bytes.
///
/// ## Delete-all
///
/// NEITHER row is deleted by "delete everything" (owner decision, Phase 5). The friend row must
/// survive because the wall it protects deliberately survives; the own row is kept for the same
/// stale-cache reason that made ``deleteKeychainRowForWipe()`` callerless — the own STORES are
/// emptied instead (`MealPhotoStore.deleteAll` / `ProgressPhotoStore.deleteAll`), and a key whose
/// stores are empty protects nothing.
///
/// Concurrency: NOT `Sendable` — `cachedKey` is unsynchronized mutable state, safe only because
/// each instance stays inside one isolation domain (in practice, the main actor of the store
/// owner, or the one-off background task that runs the migration pass). Failure mode: if the
/// keychain can't store or return the key, ``mediaKey()`` returns nil and every dependent store
/// fails closed (nothing written in plaintext).
public final class KeychainPrivateMediaKeyProvider: PrivateMediaKeyProviding {
    /// Which of the module's two at-rest media keys a provider instance vends.
    ///
    /// The role fixes the keychain account and the mint-time binding policy; everything else about
    /// the provider is identical. Deliberately NOT `Codable`/persisted anywhere — it is a
    /// compile-time wiring decision made where each store is constructed.
    public enum Role: Sendable, CaseIterable {
        /// The friend photowall cache (`MeshNetworkManager.photoCacheStore`): the original,
        /// backup-restorable row. Never re-encrypted, never wiped.
        case friendWall
        /// The user's own photos — meal, recipe, and gym-progress (body) pictures plus the sealed
        /// progress index. Separate row so it can be device-bound without touching the wall.
        case ownPhotos

        /// The `kSecAttrAccount` this role's key lives under (both share one service).
        var account: String {
            switch self {
            case .friendWall: return KeychainPrivateMediaKeyProvider.account
            case .ownPhotos:  return KeychainPrivateMediaKeyProvider.ownAccount
            }
        }
    }

    static let service = "com.fernlet.private-media"
    /// Friend-wall (original, backup-restorable) key row.
    static let account = "com.fernlet.private-media.contentKey"
    /// Own-photos key row (Phase 5 split).
    static let ownAccount = "com.fernlet.private-media.ownContentKey"

    /// Mint-time binding policy per role — **the 5c flip point**.
    ///
    /// `true` mints `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the key cannot leave this
    /// device, so a restored backup or a stolen container yields nothing); `false` mints the
    /// backup-restorable `kSecAttrAccessibleAfterFirstUnlock`.
    ///
    /// - `.friendWall` is `false` **permanently** — that is the documented product decision the
    ///   wall's cross-device readability rests on, pinned by `KeyCustodyBoundaryTests`.
    /// - `.ownPhotos` is `false` **today** and flips to `true` in step 5c, once
    ///   ``OwnPhotoMigrationLatch`` proves every own file is sealed under this key AND the escrow
    ///   photo route (or explicit user consent) covers the phone-swap case. Changing it here is
    ///   the whole flip: existing rows keep their minted class until re-minted, so the flip is
    ///   forward-looking and must be paired with 5c's re-mint, never shipped alone.
    public static func defaultDeviceBinding(for role: Role) -> Bool {
        switch role {
        case .friendWall: return false
        case .ownPhotos:  return false
        }
    }

    /// Which key this instance vends.
    public let role: Role
    /// Whether a row minted by this instance is bound to this device (see
    /// ``defaultDeviceBinding(for:)``).
    public let deviceBound: Bool
    /// Whether ``mediaKey()`` may CREATE the row when the keychain definitively reports it absent.
    ///
    /// False for read-only uses — the legacy-key fallback on the own-photo read path and the
    /// migration's "can I still open pre-split bytes?" probe. Minting there would be worse than
    /// useless: a brand-new random key opens nothing, and writing it would install a row that
    /// later looks authoritative.
    public let mintsIfAbsent: Bool

    /// In-memory copy of the key, cached to avoid a keychain hit per byte read. Unsynchronized:
    /// confined by convention to the owning store's isolation domain (in practice the main actor
    /// of `MeshNetworkManager` or the app's `FernletStore`).
    private var cachedKey: SymmetricKey?

    /// Creates a provider for one media-key ``Role``.
    ///
    /// - Parameters:
    ///   - role: Which key to vend. Defaults to ``Role/friendWall`` so the pre-split default
    ///     construction (`KeychainPrivateMediaKeyProvider()`) keeps reading the original row
    ///     byte-for-byte; own-photo stores pass ``Role/ownPhotos`` explicitly.
    ///   - deviceBound: Mint-time binding override, for tests that need to exercise a binding
    ///     class the shipping policy hasn't flipped to yet. Nil (the normal case) resolves to
    ///     ``defaultDeviceBinding(for:)`` — keep the policy in that one place.
    ///   - mintsIfAbsent: Pass false for a read-only probe/fallback provider that must never
    ///     create a row (see ``mintsIfAbsent``).
    public init(role: Role = .friendWall, deviceBound: Bool? = nil, mintsIfAbsent: Bool = true) {
        self.role = role
        self.deviceBound = deviceBound ?? Self.defaultDeviceBinding(for: role)
        self.mintsIfAbsent = mintsIfAbsent
    }

    /// The accessibility class a freshly minted row for this instance is stored under.
    private var accessibility: CFString {
        deviceBound ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlock
    }

    /// Returns this role's media key: cached copy first, then the keychain row, else — only when
    /// the keychain **definitively** reports the row absent and ``mintsIfAbsent`` is true — a
    /// freshly minted 256-bit key persisted to the keychain.
    ///
    /// - Returns: The key, or nil when the row could not be read, could not be stored, or is
    ///   absent on a non-minting provider. Nothing is cached in those cases, so dependent stores
    ///   fail closed rather than sealing under an unpersisted (or wrong) key.
    /// - Important: the absent-vs-unreadable distinction is load-bearing, not cosmetic. A plain
    ///   "read returned nil ⇒ mint" would, during the window when the row exists but is
    ///   unavailable (an `AfterFirstUnlock` item before the first post-boot unlock, or any
    ///   transient `SecItemCopyMatching` failure), mint a fresh key and — since
    ///   `KeychainItem.store` is delete-then-add — REPLACE the real one, turning every sealed
    ///   photo into permanent garbage with no failure signal. Fail closed instead: no key, no
    ///   reads, no writes, and the next attempt after unlock succeeds.
    public func mediaKey() -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        switch KeychainItem.loadDistinguishingAbsence(account: role.account, service: Self.service) {
        case .found(let existing):
            let key = SymmetricKey(data: existing)
            cachedKey = key
            return key
        case .unreadable:
            return nil
        case .absent:
            break
        }
        guard mintsIfAbsent else { return nil }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let status = KeychainItem.store(
            keyData,
            account: role.account,
            service: Self.service,
            accessibility: accessibility
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

    /// Removes the friend-wall at-rest media key row. **Deliberately has no callers** — do not add one.
    ///
    /// The row is a single keychain item behind the friend photo wall's `PrivateMediaStore`, which
    /// survives "Delete everything" by design (product decision: friends' shared photos are the
    /// friends' gift, removed one at a time). Delete-all used to call this on the premise that every
    /// media store had been emptied first; that premise is false for exactly the one store
    /// deliberately left full, so the call silently destroyed the wall — the photos kept rendering
    /// from the in-memory key until relaunch, then `mediaKey()` minted a fresh key and every retained
    /// photo decrypted to garbage. See Docs/PrivacyWipeCoverage.md.
    ///
    /// The Phase-5 own-photos row (``ownAccount``) is deliberately NOT deleted by the wipe either,
    /// and has no equivalent method: its stores ARE emptied by delete-all, so the key protects
    /// nothing afterwards, and deleting it would only re-introduce the same stale-cache hazard for
    /// anything captured between the wipe and relaunch.
    ///
    /// Kept as API only for a future caller that first empties the wall too. A key whose stores are
    /// all empty protects nothing, so leaving the row in place leaks nothing.
    public static func deleteKeychainRowForWipe() {
        KeychainItem.delete(account: account, service: service)
    }
}
