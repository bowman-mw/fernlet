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

    private static let bufferKeyAccount = "com.fernlet.buffer.key"
    private static let maxEntries = 50
    private var evictedCount = 0

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
            evictedCount += excess
            FernletAuditLog.log("buffer.evicted", context: ["count": "\(excess)"])
        }

        try saveEntries(entries)
    }

    func drainAll() throws -> [PendingNarrativePayload] {
        let entries = try loadEntries()
        try purge()
        return entries
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
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.bufferKeyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private func createAndStoreBufferKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.bufferKeyAccount,
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
