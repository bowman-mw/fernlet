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
import FernletDomainModel
import FernletFoundation

// MARK: - Payload

/// One period-log narrative captured while the app lock was engaged, awaiting sealing under the real content key.
///
/// `PeriodTrackerStore` (in `PrivateHealthStore`) builds a payload when the user logs a cycle
/// event that carries narrative content but no unlocked content key is available, and hands it to
/// `FernletLockService.bufferPendingNarrative(_:)`. The lock service appends it to a
/// ``PendingNarrativeBuffer``; after the next successful unlock the drained payloads are
/// re-inserted as sealed `MenstrualNarrative` rows under the real ChaChaPoly column key.
///
/// The `…Bytes` fields hold plaintext encodings (UTF-8 note text, JSON-encoded symptom values):
/// at-rest protection comes from the buffer's whole-file ChaChaPoly seal, not from the fields
/// themselves.
public struct PendingNarrativePayload: Codable {
    /// The HealthKit external-UUID string tying this narrative to its saved cycle sample.
    public let hkExternalUUID: String
    /// The entry's calendar day key.
    public let dateKey: String             // yyyy-MM-dd
    /// UTF-8 bytes of the free-form note, or `nil` when the event had none.
    public let noteBytes: Data?
    /// JSON-encoded array of symptom raw values, or `nil`.
    public let symptomFlagsBytes: Data?
    /// JSON-encoded custom symptom-scale values, or `nil`.
    public let customSymptomScalesBytes: Data?

    /// Creates a payload from already-encoded narrative fields.
    public init(
        hkExternalUUID: String,
        dateKey: String,
        noteBytes: Data?,
        symptomFlagsBytes: Data?,
        customSymptomScalesBytes: Data?
    ) {
        self.hkExternalUUID = hkExternalUUID
        self.dateKey = dateKey
        self.noteBytes = noteBytes
        self.symptomFlagsBytes = symptomFlagsBytes
        self.customSymptomScalesBytes = customSymptomScalesBytes
    }
}

// MARK: - Buffer

/// An encrypted on-disk holding pen for period-log narratives written while the Fernlet app lock is engaged.
///
/// `FernletLockService` (in `FernletLock`) owns the app's single instance and exposes it to
/// `PeriodTrackerStore` through the `PeriodLockContext` seam: narratives logged without an
/// unlocked content key are appended here, then drained after the next successful unlock and
/// re-sealed as `MenstrualNarrative` rows under the real column key.
///
/// Storage and crypto:
/// - The buffer's whole identity — the directory holding `pending-narratives.bin` AND the
///   keychain service holding its key — is the ``PendingNarrativeStorageScope`` given at init,
///   `.production` resolving to the shipped `Application Support/Fernlet` +
///   `com.fernlet.narrative-buffer`. Two instances share state exactly when their scopes match.
/// - All entries are JSON-encoded as a single array and sealed with ChaChaPoly into
///   `pending-narratives.bin` under the scope's directory; each save excludes the file from
///   backup and (best-effort) applies complete file protection.
/// - The 256-bit buffer key is its own data-protection keychain item
///   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), deliberately separate from the lock's
///   content key so logging can reach the buffer without the user's Fernlet passcode. A legacy
///   service-less keychain item is migrated into the scoped slot on first read — by the
///   production scope only, since that row is production's migration source and the migration
///   deletes it.
/// - The buffer caps at 50 entries; ``append(_:)`` evicts the oldest beyond the cap and records
///   the eviction via `FernletAuditLog`.
///
/// - Important: ``drainAll()`` never deletes. Callers must durably persist the drained payloads
///   first and only then call ``purge()``, so a partial re-seal failure cannot silently drop
///   notes the user wrote while locked.
///
/// Concurrency: a plain nonisolated, non-`Sendable` class with no internal locking; correctness
/// relies on the single lock-service-owned instance being driven from the main actor.
public final class PendingNarrativeBuffer {

    /// The buffer's storage identity — file directory and keychain service as one value. Two
    /// instances share on-disk and keychain state exactly when their scopes are equal.
    private let scope: PendingNarrativeStorageScope

    /// Creates a buffer handle on the given scope. Deliberately no argument-less variant: an
    /// implicit process-wide default is exactly how an instance silently rejoins the cross-suite
    /// wipe race this scope exists to end. Production callers pass `.production`.
    public init(scope: PendingNarrativeStorageScope) {
        self.scope = scope
    }

    private static let bufferKeyAccount = "com.fernlet.buffer.key"           // legacy (no service)
    private static let bufferKeyAccountV2 = "com.fernlet.buffer.key.v2"      // current (with service)
    private static let maxEntries = 50

    /// The sealed buffer file inside `directory` — the ONE spelling of the file's name, so the
    /// production default and a scoped root can never name different files.
    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("pending-narratives.bin")
    }

    /// The sealed buffer file under the scope's directory, creating the directory as a side effect.
    private var bufferFileURL: URL {
        try? FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true)
        return Self.fileURL(in: scope.directory)
    }

    // MARK: - Public API

    /// Appends a payload to the sealed buffer, evicting (and audit-logging) the oldest entries
    /// beyond the 50-entry cap.
    ///
    /// - Important: Each append decrypts, re-encodes, and re-seals the entire buffer file.
    public func append(_ payload: PendingNarrativePayload) throws {
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
    ///
    /// - Returns: Every buffered payload, oldest first.
    public func drainAll() throws -> [PendingNarrativePayload] {
        try loadEntries()
    }

    /// Deletes the buffer file outright.
    ///
    /// Call only after the drained payloads have been durably persisted, or when intentionally
    /// discarding them (e.g. on lock reset or when period tracking is hidden).
    public func purge() throws {
        let url = bufferFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Serialise / deserialise with ChaChaPoly

    /// Decrypts and decodes the buffer file; returns `[]` when it does not exist or is empty.
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

    /// JSON-encodes and ChaChaPoly-seals the entries, writes them atomically, then best-effort
    /// re-applies backup exclusion and complete file protection to the fresh file.
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

    /// Returns the buffer key, creating and storing a fresh one on first use.
    private func bufferKey() throws -> SymmetricKey {
        if let existing = loadBufferKey() { return existing }
        return try createAndStoreBufferKey()
    }

    /// Loads the buffer key from the keychain, migrating a legacy service-less item into the
    /// scoped v2 slot when that is all that exists.
    private func loadBufferKey() -> SymmetricKey? {
        // Try current key (with service) first
        if let data = KeychainItem.load(account: Self.bufferKeyAccountV2, service: scope.keychainService) {
            return SymmetricKey(data: data)
        }
        // Only the production scope may consume the legacy row: it is production's one migration
        // source, and the migration below DELETES it — a scoped (test) buffer that fell through
        // here would steal the key into its throwaway service and strand the real buffer file.
        guard scope.keychainService == PendingNarrativeStorageScope.productionKeychainService else {
            return nil
        }
        // Migrate legacy key (no service) into the scoped service slot
        if let key = loadLegacyServicelessKey() {
            let keyData = key.withUnsafeBytes { Data($0) }
            // Status deliberately ignored: the legacy key is still returned below, so a failed
            // migration write only means the migration re-runs on the next load.
            KeychainItem.store(
                keyData,
                account: Self.bufferKeyAccountV2,
                service: scope.keychainService,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            // Raw SecItemDelete: KeychainItem cannot express a service-less query (service is a
            // required parameter), and the v1 row was stored without one. Dies with the v1
            // migration when it is retired.
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

    /// Reads the legacy v1 buffer key, which was stored WITHOUT a `kSecAttrService` attribute.
    ///
    /// Kept as a raw `SecItemCopyMatching` call because `KeychainItem` cannot express a
    /// service-less query (service is a required parameter of its contract). This whole helper
    /// dies when the v1-to-v2 migration in ``loadBufferKey()`` is retired.
    private func loadLegacyServicelessKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.bufferKeyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    /// Generates a 256-bit key and stores it background-accessible (after first unlock, this
    /// device only); throws `FernletLockError.internalError` when the keychain write fails.
    private func createAndStoreBufferKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Background-accessible: works after first device unlock, no passcode required
        let status = KeychainItem.store(
            keyData,
            account: Self.bufferKeyAccountV2,
            service: scope.keychainService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        guard status == errSecSuccess else {
            throw FernletLockError.internalError("buffer key creation failed: \(status)")
        }
        return key
    }
}
