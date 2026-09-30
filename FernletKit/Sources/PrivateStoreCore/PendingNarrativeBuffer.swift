// PendingNarrativeBuffer.swift
// Fernlet
//
// Encrypted buffer for period-log narrative entries written while FernletLock is not unlocked.
// Drained on the next successful unlock so entries are sealed under the real column key.
// Uses a separate buffer key (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) so background
// logging can reach the buffer without requiring the user's passcode.

import Foundation
import CryptoKit
import FernletCrypto
import Security
import FernletDomainModel
import FernletFoundation

// MARK: - Errors

/// A failure the pending-narrative buffer can name for itself, rather than surfacing as a bare
/// `CryptoKit` throw the drain's audit line cannot explain.
///
/// One case today, and it exists because the crypto standardization round's Phase 3 deleted this
/// surface's legacy reader: bytes with no `FNB2` marker used to be opened as a bare, unbound
/// `ChaChaPoly` box, and now they are classified and refused instead.
///
/// Concurrency: a plain value type; no state.
public enum PendingNarrativeBufferError: Error, Equatable {
    /// The buffer file is non-empty and carries no `FNB2` marker — the pre-`91c3956` shape, a bare
    /// `ChaChaPoly` combined box sealed with no associated data. Phase 3 deleted the reader for it,
    /// so the bytes are refused by name rather than opened under no domain at all.
    ///
    /// What it does NOT prove: the retired format had no marker of its own, so "no `FNB2`" covers
    /// corrupt, truncated and foreign bytes exactly as it covers a genuine pre-`91c3956` buffer —
    /// the same upper bound ``PendingNarrativeBufferFormatCensus/Format/legacyUnprefixed`` reports,
    /// and for the identical reason. Nothing is deleted on this path: the buffer file is left
    /// byte-identical, because bytes that will not open may really be "sealed under a key this
    /// device lost", and the drain's contract is to keep what it cannot decode.
    case legacyUnprefixedFormat
    /// The buffer key's keychain row could not be READ (`errSecInteractionNotAllowed` before first
    /// unlock, `errSecNotAvailable`, …), carrying the status. Nothing is minted and nothing is
    /// written: the key may be perfectly intact, and a fresh key over it would make every buffered
    /// entry unopenable. An append fails with nothing lost; a drain retries at the next open.
    case keyUnreadable(status: OSStatus)
    /// The buffer key's row is definitively ABSENT while the buffer file still holds entries — the
    /// entries were sealed under a key that no longer exists (a wipe that destroyed the key but not
    /// the file, a restore that brought the file without the key). They can never be opened, so the
    /// key is NOT re-minted over them: removing the file is a separate, explicit act.
    case bufferUnopenable
}

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
///
/// `Equatable` (synthesized — every stored property already is) so a caller can compare what it
/// wrote with what it read back.
public struct PendingNarrativePayload: Codable, Equatable {
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
///   deletes it. The key is read with a DISTINGUISHING read and minted only on a definitive
///   absence over an absent or empty file: an unreadable key throws
///   ``PendingNarrativeBufferError/keyUnreadable(status:)`` and a missing key over buffered
///   entries throws ``PendingNarrativeBufferError/bufferUnopenable`` — never a fresh key over
///   either (`KeyCustodyBoundaryTests.bufferKeyIsNeverMintedOverAnUnreadableRow`).
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

    /// The whole-file format prefix, REQUIRED on both write and read. v1 began directly with a
    /// ChaChaPoly box and bound no associated data; the crypto standardization round's Phase 3
    /// deleted that read, so the marker's absence now only classifies bytes as
    /// ``PendingNarrativeBufferError/legacyUnprefixedFormat``.
    ///
    /// Module-visible rather than `private` so ``PendingNarrativeBufferFormatCensus`` classifies
    /// files against THIS constant instead of a second copy of the same four bytes. A census with
    /// its own copy would keep reporting "v2" after a change here, which is precisely the proof the
    /// crypto-standardization plan's Phase 0 must not be able to fake. Still internal: nothing
    /// outside this module needs the raw constant (the census re-exports it as
    /// ``PendingNarrativeBufferFormatCensus/versionTwoMarker``).
    static let sealedFormatV2 = Data("FNB2".utf8)

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

    /// The sealed buffer file under the scope's directory. Pure — reading a path performs no I/O, so
    /// `purge()`/`loadEntries()` no longer create a directory they only wanted a name from.
    private var bufferFileURL: URL {
        Self.fileURL(in: scope.directory)
    }

    /// Creates the scope's directory if it is missing. Called only by ``saveEntries(_:)`` — the one
    /// path that needs the directory to exist — so the failure reaches the caller as a throw instead
    /// of surfacing later as a misleading write error.
    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: scope.directory, withIntermediateDirectories: true)
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
    ///
    /// - Throws: ``PendingNarrativeBufferError/legacyUnprefixedFormat`` when the file is non-empty
    ///   and carries no `FNB2` marker. Phase 3 deleted the reader for that shape, so its absence is
    ///   a NAMED refusal rather than an unbound open — and the file is left untouched, exactly as
    ///   the drain leaves bytes it cannot decode.
    private func loadEntries() throws -> [PendingNarrativePayload] {
        let url = bufferFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let encrypted = try Data(contentsOf: url)
        guard !encrypted.isEmpty else { return [] }
        guard encrypted.starts(with: Self.sealedFormatV2) else {
            FernletAuditLog.log("buffer.legacyFormatRefused")
            throw PendingNarrativeBufferError.legacyUnprefixedFormat
        }

        let sealedBox = try ChaChaPoly.SealedBox(
            combined: encrypted.dropFirst(Self.sealedFormatV2.count)
        )
        let plaintext = try ChaChaPoly.open(
            sealedBox,
            using: bufferKey(),
            authenticating: FernletCryptoPurpose.AEAD.pendingNarrativeBufferV2.data
        )
        return try JSONDecoder().decode([PendingNarrativePayload].self, from: plaintext)
    }

    /// JSON-encodes and ChaChaPoly-seals the entries under the scope's buffer key (fetching, and on
    /// first use minting, that key via ``bufferKey()``), writes them atomically, then best-effort
    /// re-applies backup exclusion and complete file protection to the fresh file.
    private func saveEntries(_ entries: [PendingNarrativePayload]) throws {
        let key = try bufferKey()
        let plaintext = try JSONEncoder().encode(entries)
        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: FernletCryptoPurpose.AEAD.pendingNarrativeBufferV2.data
        )
        let encrypted = Self.sealedFormatV2 + sealedBox.combined

        try ensureDirectoryExists()
        let url = bufferFileURL
        try encrypted.write(to: url, options: .atomic)

        // Mark file with complete protection and exclude from backup. Both stay best-effort — the
        // ChaChaPoly seal is the primary at-rest protection — but a failure is now named, not lost.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            FernletAuditLog.log("buffer.backupExclusionFailed", context: ["error": "\(error)"])
        }

        do {
            try (url as NSURL).setResourceValue(
                URLFileProtection.complete,
                forKey: .fileProtectionKey
            )
        } catch {
            FernletAuditLog.log("buffer.fileProtectionFailed", context: ["error": "\(error)"])
        }
    }

    // MARK: - Buffer key management

    /// Returns the buffer key, minting one only when that provably loses nothing.
    ///
    /// **Never mints over a key it could not read, nor over entries it cannot open** (period-data
    /// design 2026-09-30, §6.5, review R1-F5). The read distinguishes absence from failure:
    /// - found → the key;
    /// - unreadable → ``PendingNarrativeBufferError/keyUnreadable(status:)``. The old collapsing read
    ///   minted a fresh key on ANY nil, and `KeychainItem.store` is delete-then-add, so one transient
    ///   read failure destroyed the real key and every buffered entry with it;
    /// - absent → the legacy service-less key is migrated if the production scope has one; otherwise
    ///   a key is minted only when the buffer file is absent or empty. A non-empty file with no key
    ///   is ``PendingNarrativeBufferError/bufferUnopenable``: those entries were sealed under a key
    ///   that is gone, and a new key would not open them either.
    private func bufferKey() throws -> SymmetricKey {
        switch KeychainItem.loadDistinguishingAbsence(account: Self.bufferKeyAccountV2, service: scope.keychainService) {
        case .found(let data):
            return SymmetricKey(data: data)
        case .unreadable(let status):
            FernletAuditLog.log("buffer.keyUnreadable", context: ["status": "\(status)"])
            throw PendingNarrativeBufferError.keyUnreadable(status: status)
        case .absent:
            if let migrated = migrateLegacyServicelessKeyIfPresent() { return migrated }
            guard bufferFileIsAbsentOrEmpty() else {
                FernletAuditLog.log("buffer.keyMissingOverEntries")
                throw PendingNarrativeBufferError.bufferUnopenable
            }
            return try createAndStoreBufferKey()
        }
    }

    /// Whether the buffer file holds no entries at all — absent, or zero bytes. A size that cannot be
    /// read answers false (fail closed: "maybe entries" must never license a mint).
    private func bufferFileIsAbsentOrEmpty() -> Bool {
        let path = bufferFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue == 0
    }

    /// Migrates a legacy service-less buffer key into the scoped v2 slot, for a v2 slot that read
    /// definitively ABSENT — the only state that may consult the legacy row.
    private func migrateLegacyServicelessKeyIfPresent() -> SymmetricKey? {
        // Only the production scope may consume the legacy row: it is production's one migration
        // source, and the migration below DELETES it — a scoped (test) buffer that fell through
        // here would steal the key into its throwaway service and strand the real buffer file.
        guard scope.keychainService == PendingNarrativeStorageScope.productionKeychainService else {
            return nil
        }
        // Migrate legacy key (no service) into the scoped service slot
        if let key = loadLegacyServicelessKey() {
            let storeStatus = KeychainItem.store(
                key.rawBytes,
                account: Self.bufferKeyAccountV2,
                service: scope.keychainService,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            // The legacy row is the ONLY other copy of this key: deleting it after a failed v2 write
            // would lose the key outright and turn every buffered narrative into unopenable
            // ciphertext. Keep the source row so the migration genuinely retries on the next load.
            guard storeStatus == errSecSuccess else {
                FernletAuditLog.log("buffer.keyMigrationWriteFailed", context: ["status": "\(storeStatus)"])
                return key
            }
            // Raw SecItemDelete: KeychainItem cannot express a service-less query (service is a
            // required parameter), and the v1 row was stored without one. Dies with the v1
            // migration when it is retired.
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: Self.bufferKeyAccount,
                kSecUseDataProtectionKeychain as String: true
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                // Recovery: none needed — the v2 row is committed, so the surviving legacy row is
                // inert residue that the next successful migration attempt removes.
                FernletAuditLog.log("buffer.legacyKeyDeleteFailed", context: ["status": "\(deleteStatus)"])
            }
            return key
        }
        return nil
    }

    /// Reads the legacy v1 buffer key, which was stored WITHOUT a `kSecAttrService` attribute.
    ///
    /// Kept as a raw `SecItemCopyMatching` call because `KeychainItem` cannot express a
    /// service-less query (service is a required parameter of its contract). This whole helper
    /// dies when the v1-to-v2 migration in ``migrateLegacyServicelessKeyIfPresent()`` is retired.
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

        // Background-accessible: works after first device unlock, no passcode required
        let status = KeychainItem.store(
            key.rawBytes,
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
