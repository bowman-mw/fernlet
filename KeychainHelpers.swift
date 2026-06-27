// KeychainHelpers.swift
// Fernlet
//
// Generic Keychain accessors shared by FernletLockService and IdentityService.
// Lock-specific typed wrappers (LockKeychainKey) live in FernletLockService.swift.

import Foundation
import Security

enum KeychainItem {
    enum Account: String {
        case storagePreferences = "com.fernlet.storage-preferences.preferences"
        case deviceJournalKey = "com.fernlet.journal.deviceKey"
    }

    nonisolated static let productionService = "com.fernlet.lock"
    nonisolated static let storagePreferencesService = "com.fernlet.storage-preferences"
    nonisolated static let journalService = "com.fernlet.journal"

    // MARK: - Generic String-keyed operations

    @discardableResult
    static func store(
        _ data: Data,
        account: String,
        service: String,
        accessibility: CFString,
        synchronizable: Bool = false
    ) -> OSStatus {
        delete(account: account, service: service)
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

    static func load(account: String, service: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll(service: String) {
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
    static func store(_ data: Data, for account: Account, service: String) -> OSStatus {
        store(data, account: account.rawValue, service: service,
              accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func load(for account: Account, service: String) -> Data? {
        load(account: account.rawValue, service: service)
    }

    static func delete(for account: Account, service: String) {
        delete(account: account.rawValue, service: service)
    }
}
