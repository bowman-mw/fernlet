// KeychainHelpers.swift
// Fernlet
//
// Generic Keychain accessors shared by FernletLockService and IdentityService.
// Lock-specific typed wrappers (LockKeychainKey) live in FernletLockService.swift.

import Foundation
import Security

/// Generic data-protection Keychain accessors shared by Fernlet's key and preference stores.
///
/// The common substrate for every keychain-backed secret in the app: `FernletLockService`'s lock
/// credentials, `IdentityService`'s mesh identity and backup-escrow keys, the device-bound
/// journal and Worry Box content keys, and the persisted ``StoragePreferences`` blob. All
/// operations target generic-password items in the data-protection keychain
/// (`kSecUseDataProtectionKeychain`), keyed by service + account.
///
/// Two subtleties are load-bearing:
/// - The keychain treats `kSecAttrSynchronizable` as part of an item's primary key, so an
///   iCloud-synced item and a `ThisDeviceOnly` item can coexist under the same service + account
///   as two distinct rows. ``SynchronizableScope`` lets callers target one variant; the
///   backup-escrow reconciliation depends on telling them apart.
/// - ``store(_:account:service:accessibility:synchronizable:replacing:)`` is delete-then-add, and
///   its `replacing` scope controls which variant the delete removes — pass a narrow scope when
///   promoting an escrow item so a genuine key that just synced in is not clobbered.
///
/// Lock-specific typed wrappers (`LockKeychainKey`) live in `FernletLockService`; this type stays
/// mechanism-only. `nonisolated`: pure Security-framework calls with no shared state, callable
/// from any executor.
public nonisolated enum KeychainItem {
    /// Well-known account names for Fernlet's own keychain items.
    ///
    /// Each case is the literal `kSecAttrAccount` string under which one of the app's
    /// device-bound secrets is stored. The typed convenience overloads
    /// (``store(_:for:service:)``, ``load(for:service:)``, ``delete(for:service:)``) take an
    /// `Account` and pin `AfterFirstUnlockThisDeviceOnly` accessibility.
    public enum Account: String {
        /// The JSON-encoded ``StoragePreferences`` blob persisted by ``StoragePreferencesStore``.
        case storagePreferences = "com.fernlet.storage-preferences.preferences"
        /// Device-bound fallback key sealing journal narratives when no user lock is configured
        /// or the lock is closed.
        case deviceJournalKey = "com.fernlet.journal.deviceKey"
        /// Device-bound fallback key for Worry Box notes (sealed, local-only) when no user lock is
        /// configured or the lock is closed. Lives under `journalService` beside the journal device key
        /// so lock reset (`KeychainItem.deleteAll`-adjacent flows) treats the sealed-content keys alike.
        case deviceWorryKey = "com.fernlet.worry.deviceKey"
    }

    /// Which synchronizable variant of an item a query should match.
    ///
    /// The default `.any` preserves the
    /// historical behavior (`kSecAttrSynchronizableAny`). `.synced` / `.local` let a caller distinguish
    /// an iCloud-Keychain-replicated item from a `ThisDeviceOnly` one when BOTH can exist under the same
    /// service+account — the keychain treats `kSecAttrSynchronizable` as part of an item's primary key,
    /// so a synced item and a device-only item with the same account coexist as two distinct rows. The
    /// backup-escrow reconciliation relies on telling them apart (see IdentityService).
    public enum SynchronizableScope {
        /// Match either variant (`kSecAttrSynchronizableAny`) — the historical default behavior.
        case any
        /// Match only the iCloud-Keychain-replicated variant.
        case synced
        /// Match only the `ThisDeviceOnly` (non-synchronizable) variant.
        case local

        fileprivate var queryValue: Any {
            switch self {
            case .any:    return kSecAttrSynchronizableAny
            case .synced: return true
            case .local:  return false
            }
        }
    }

    /// Service string for the app-lock credentials (`FernletLockService`'s production slot).
    nonisolated public static let productionService = "com.fernlet.lock"
    /// Service string under which the ``StoragePreferences`` blob is stored.
    nonisolated public static let storagePreferencesService = "com.fernlet.storage-preferences"
    /// Service string for the sealed-content device keys (journal and Worry Box).
    nonisolated public static let journalService = "com.fernlet.journal"

    // MARK: - Generic String-keyed operations

    /// Stores `data`, first removing any colliding item. `replacing` controls WHICH synchronizable
    /// variant is removed before the add: the default `.any` matches the historical "overwrite whatever
    /// is there" behavior. Pass `.local` (or `.synced`) to remove only that variant — used when
    /// promoting a `ThisDeviceOnly` escrow item to `synchronizable` without risking the removal of a
    /// genuine key that just synced in under the same account.
    @discardableResult
    public static func store(
        _ data: Data,
        account: String,
        service: String,
        accessibility: CFString,
        synchronizable: Bool = false,
        replacing: SynchronizableScope = .any
    ) -> OSStatus {
        delete(account: account, service: service, synchronizable: replacing)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessibility,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Loads the data of the single item matching `service` + `account` within `synchronizable`
    /// scope, or `nil` when no item matches (or the keychain call fails).
    public static func load(account: String, service: String, synchronizable: SynchronizableScope = .any) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Enumerates EVERY generic-password item under `service` (optionally restricted to a synchronizable
    /// scope), returning each item's account + data. Used by the content-addressed backup-escrow store:
    /// because each escrow key lives at an account derived from its own public key, divergent keys land on
    /// DIFFERENT accounts and coexist rather than overwrite one another — so the reconcile path must
    /// enumerate to discover the full set (a fresh device does not know the account name a priori). Query
    /// `.synced` and `.local` separately to learn each row's sync status. Returns `[]` on no match/error.
    public static func loadAll(service: String, synchronizable: SynchronizableScope = .any) -> [(account: String, data: Data)] {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
    }

    /// Deletes the item matching `service` + `account` within `synchronizable` scope. A no-match
    /// result is silently ignored, so the call is safe to make unconditionally.
    public static func delete(account: String, service: String, synchronizable: SynchronizableScope = .any) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable.queryValue,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes EVERY item under `service`, both synced and device-only variants. Used by the
    /// lock-reset and delete-everything flows to clear a whole service slot at once.
    public static func deleteAll(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Account typed convenience (AfterFirstUnlockThisDeviceOnly)

    /// Stores `data` for a well-known ``Account``, pinned to
    /// `AfterFirstUnlockThisDeviceOnly` accessibility (device-bound, never iCloud-synced).
    @discardableResult
    public static func store(_ data: Data, for account: Account, service: String) -> OSStatus {
        store(data, account: account.rawValue, service: service,
              accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Loads the data stored for a well-known ``Account``, or `nil` when absent.
    public static func load(for account: Account, service: String) -> Data? {
        load(account: account.rawValue, service: service)
    }

    /// Deletes the item stored for a well-known ``Account``; a no-match is silently ignored.
    public static func delete(for account: Account, service: String) {
        delete(account: account.rawValue, service: service)
    }
}
