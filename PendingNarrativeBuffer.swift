// PendingNarrativeBuffer.swift
// Fernlet
//
// Encrypted buffer for period-log narrative entries written while FernletLock is not unlocked.
// Drained on the next successful unlock so entries are sealed under the real column key.
// Uses a separate buffer key (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) so background
// logging can reach the buffer without requiring the user's passcode.

import Foundation
import CryptoKit
import Security

// MARK: - Payload

struct PendingNarrativePayload: Codable {
    let hkExternalUUID: String
    let dateKey: String             // yyyy-MM-dd
    let noteBytes: Data?
    let symptomFlagsBytes: Data?
    let customSymptomScalesBytes: Data?
}

// MARK: - Buffer

final class PendingNarrativeBuffer {

    private static let bufferKeyService = "com.fernlet.narrative-buffer"
    private static let bufferKeyAccount = "com.fernlet.buffer.key"           // legacy (no service)
    private static let bufferKeyAccountV2 = "com.fernlet.buffer.key.v2"      // current (with service)
    private static let maxEntries = 50
    private var bufferFileURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Fernlet", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("pending-narratives.bin")
    }

    // MARK: - Public API

    func append(_ payload: PendingNarrativePayload) throws {
        var entries = try loadEntries()
        entries.append(payload)

        // Evict oldest entries if cap exceeded
        if entries.count > Self.maxEntries {
            let excess = entries.count - Self.maxEntries
            entries.removeFirst(excess)
            FernletAuditLog.log("buffer.evicted", context: ["count": "\(excess)"])
        }

        try saveEntries(entries)
    }

    /// Reads and returns the buffered payloads **without** removing them.
    /// The buffer is only cleared once the caller has durably persisted the
    /// payloads, via an explicit `purge()` call. Purging here would lose any
    /// payloads the caller fails to persist (e.g. a partial insert failure),
    /// silently dropping notes the user wrote while the app was locked.
    func drainAll() throws -> [PendingNarrativePayload] {
        try loadEntries()
    }

    func purge() throws {
        let url = bufferFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Serialise / deserialise with ChaChaPoly

    private func loadEntries() throws -> [PendingNarrativePayload] {
        let url = bufferFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let encrypted = try Data(contentsOf: url)
        guard !encrypted.isEmpty else { return [] }

        let key = try bufferKey()
        let sealedBox = try ChaChaPoly.SealedBox(combined: encrypted)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)
        return try JSONDecoder().decode([PendingNarrativePayload].self, from: plaintext)
    }

    private func saveEntries(_ entries: [PendingNarrativePayload]) throws {
        let plaintext = try JSONEncoder().encode(entries)
        let key = try bufferKey()
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)
        let encrypted = sealedBox.combined

        let url = bufferFileURL
        try encrypted.write(to: url, options: .atomic)

        // Mark file with complete protection and exclude from backup
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)

        try? (url as NSURL).setResourceValue(
            URLFileProtection.complete,
            forKey: .fileProtectionKey
        )
    }

    // MARK: - Buffer key management

    private func bufferKey() throws -> SymmetricKey {
        if let existing = loadBufferKey() { return existing }
        return try createAndStoreBufferKey()
    }

    private func loadBufferKey() -> SymmetricKey? {
        // Try current key (with service) first
        if let key = loadRawBufferKey(account: Self.bufferKeyAccountV2, service: Self.bufferKeyService) {
            return key
        }
        // Migrate legacy key (no service) into the scoped service slot
        if let key = loadRawBufferKey(account: Self.bufferKeyAccount, service: nil) {
            let keyData = key.withUnsafeBytes { Data($0) }
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.bufferKeyService,
                kSecAttrAccount as String: Self.bufferKeyAccountV2,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecUseDataProtectionKeychain as String: true,
                kSecValueData as String: keyData
            ]
            SecItemDelete(addQuery as CFDictionary)
            SecItemAdd(addQuery as CFDictionary, nil)
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: Self.bufferKeyAccount,
                kSecUseDataProtectionKeychain as String: true
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return key
        }
        return nil
    }

    private func loadRawBufferKey(account: String, service: String?) -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let service { query[kSecAttrService as String] = service }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private func createAndStoreBufferKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.bufferKeyService,
            kSecAttrAccount as String: Self.bufferKeyAccountV2,
            // Background-accessible: works after first device unlock, no passcode required
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: keyData
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FernletLockError.internalError("buffer key creation failed: \(status)")
        }
        return key
    }
}
