// KeychainHelpers.swift
// Fernlet
//
// Generic Keychain accessors shared by FernletLockService and IdentityService.
// Lock-specific typed wrappers (LockKeychainKey) live in FernletLockService.swift.

import Foundation
import Security

public nonisolated enum KeychainItem {
    public enum Account: String {
        case storagePreferences = "com.fernlet.storage-preferences.preferences"
        case deviceJournalKey = "com.fernlet.journal.deviceKey"
    }

    /// Which synchronizable variant of an item a query should match. The default `.any` preserves the
    /// historical behavior (`kSecAttrSynchronizableAny`). `.synced` / `.local` let a caller distinguish
    /// an iCloud-Keychain-replicated item from a `ThisDeviceOnly` one when BOTH can exist under the same
    /// service+account — the keychain treats `kSecAttrSynchronizable` as part of an item's primary key,
    /// so a synced item and a device-only item with the same account coexist as two distinct rows. The
    /// backup-escrow reconciliation relies on telling them apart (see IdentityService).
    public enum SynchronizableScope {
        case any
        case synced
        case local

        fileprivate var queryValue: Any {
            switch self {
            case .any:    return kSecAttrSynchronizableAny
            case .synced: return true
            case .local:  return false
            }
        }
    }

    nonisolated public static let productionService = "com.fernlet.lock"
    nonisolated public static let storagePreferencesService = "com.fernlet.storage-preferences"
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

    @discardableResult
    public static func store(_ data: Data, for account: Account, service: String) -> OSStatus {
        store(data, account: account.rawValue, service: service,
              accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    public static func load(for account: Account, service: String) -> Data? {
        load(account: account.rawValue, service: service)
    }

    public static func delete(for account: Account, service: String) {
        delete(account: account.rawValue, service: service)
    }
}
