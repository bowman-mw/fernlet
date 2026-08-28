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
/// `Equatable` (synthesized — every stored property already is) exists for the Phase 2.4 format
/// migrator's read-back verification: a converted file counts as converted only after the
/// re-sealed bytes decode back to exactly the entries that were opened.
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

    /// Current whole-file format prefix. v1 began directly with a ChaChaPoly box and had no AAD;
    /// keep that path only to drain old entries safely, then all later writes become v2.
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
    private func loadEntries() throws -> [PendingNarrativePayload] {
        let url = bufferFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let encrypted = try Data(contentsOf: url)
        guard !encrypted.isEmpty else { return [] }

        return try decodeEntries(from: encrypted, using: bufferKey())
    }

    /// Opens and decodes one whole-file blob under `key` — ``loadEntries()``'s body from the
    /// `FNB2`-prefix check down, both branches included.
    ///
    /// Split out (Phase 2.4) so ``convertLegacyFileToCurrentFormat()`` can pin ONE `SymmetricKey`
    /// value through its entire convert instead of re-fetching between open and seal: every
    /// `bufferKey()` call is a separate keychain read that MINTS on `nil`, and `KeychainItem.load`
    /// collapses transient failures into `nil` — so a mid-convert re-fetch could delete-then-replace
    /// the only copy of the real key. The legacy branch below is the single legacy read Phase 3
    /// deletes.
    private func decodeEntries(from encrypted: Data, using key: SymmetricKey) throws -> [PendingNarrativePayload] {
        let isV2 = encrypted.starts(with: Self.sealedFormatV2)
        let combined = isV2 ? encrypted.dropFirst(Self.sealedFormatV2.count) : encrypted
        let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
        let plaintext: Data
        if isV2 {
            plaintext = try ChaChaPoly.open(
                sealedBox,
                using: key,
                authenticating: FernletCryptoPurpose.AEAD.pendingNarrativeBufferV2.data
            )
        } else {
            plaintext = try ChaChaPoly.open(sealedBox, using: key) // cryptographic-domain: legacy-read
        }
        return try JSONDecoder().decode([PendingNarrativePayload].self, from: plaintext)
    }

    /// JSON-encodes and ChaChaPoly-seals the entries under the scope's buffer key, fetching (and on
    /// first use minting) that key via ``bufferKey()``.
    private func saveEntries(_ entries: [PendingNarrativePayload]) throws {
        try saveEntries(entries, using: bufferKey())
    }

    /// JSON-encodes and ChaChaPoly-seals the entries under `key`, writes them atomically, then
    /// best-effort re-applies backup exclusion and complete file protection to the fresh file.
    /// Key-parameterized for the same reason as ``decodeEntries(from:using:)``: the Phase 2.4
    /// convert must seal under exactly the key it opened with.
    private func saveEntries(_ entries: [PendingNarrativePayload], using key: SymmetricKey) throws {
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

    // MARK: - Format migration (crypto-standardization Phase 2.4)

    /// The terminal state of one ``convertLegacyFileToCurrentFormat()`` attempt — module-internal
    /// plumbing between the buffer and ``PendingNarrativeBufferFormatMigrator``'s pass tally.
    internal enum LegacyConversionOutcome {
        /// Re-sealed v2, read back, and verified equal to the opened entries.
        case converted
        /// The bytes already carry `FNB2` (or the file emptied out mid-pass) — nothing to convert.
        case alreadyCurrent
        /// The raw read threw (file protection mid-pass) — indeterminate, never "corrupt".
        case unreadable
        /// The buffer key could not be loaded through the non-minting read — indeterminate,
        /// never "corrupt": `loadBufferKey()`'s `nil` cannot distinguish a locked keychain from a
        /// genuinely absent row.
        case keyUnavailable
        /// Bytes read, key in hand, and the shipping reader's own paths reject them — the
        /// unconvertible bucket.
        case openedUnderNeither
        /// `saveEntries(_:using:)` threw; the original file is intact (`.atomic`).
        case writeFailed
        /// Wrote v2, but the verify read/open/compare failed. Blocks this pass only: the written
        /// bytes were sealed under the pinned key this pass held, so the next launch classifies
        /// the file `.v2Marked` by marker and latches census-only.
        case readBackFailed
    }

    /// Re-seals a legacy-format buffer file into the current `FNB2`+AAD format, via the shipping
    /// decode/seal halves — no second spelling of either crypto path exists — with ONE key value
    /// pinned through the entire convert.
    ///
    /// The pinning is load-bearing, not style: after the single non-minting `loadBufferKey()`
    /// guard, every open and seal takes that `SymmetricKey` as a parameter, so no line of the
    /// convert can reach `bufferKey()` or `createAndStoreBufferKey()` — a transient keychain
    /// misread mid-pass therefore cannot mint (a delete-then-add WRITE) over the only copy of the
    /// real key. Ordering safety is the house model: the only overwrite is the atomic replace of
    /// a file whose plaintext was fully recovered and is held in memory through read-back
    /// verification; nothing here deletes, truncates, or purges — not even corrupt bytes, which
    /// may really be "sealed under a key this device lost".
    internal func convertLegacyFileToCurrentFormat() -> LegacyConversionOutcome {
        // One raw read, classified honestly: a throw here cannot distinguish "read denied" from
        // "opens under neither", so it must be caught BEFORE the open — the fail-closed
        // unreadable-vs-unopenable split.
        let raw: Data
        do {
            raw = try Data(contentsOf: bufferFileURL)
        } catch {
            return .unreadable
        }
        // Free defensive re-check; the census take and this call run synchronously on one actor
        // with no suspension point between them, so divergence is not actually reachable.
        guard !raw.isEmpty, !raw.starts(with: Self.sealedFormatV2) else { return .alreadyCurrent }

        // THE one key fetch of the entire convert. Never `bufferKey()` — that mints on absence.
        // `nil` is always indeterminate, never "corrupt": a locked pass retries next launch.
        guard let key = loadBufferKey() else { return .keyUnavailable }

        let entries: [PendingNarrativePayload]
        do {
            entries = try decodeEntries(from: raw, using: key)
        } catch {
            // Bytes read, key in hand, the reader's own paths reject them.
            return .openedUnderNeither
        }
        do {
            try saveEntries(entries, using: key)
        } catch {
            // `.atomic` guarantees the original file is intact.
            return .writeFailed
        }
        // Read-back verification before "converted": the marker, then the shipping v2 branch
        // (AAD-bound open under the same pinned key), then entry-for-entry equality.
        do {
            let readBackRaw = try Data(contentsOf: bufferFileURL)
            guard readBackRaw.starts(with: Self.sealedFormatV2),
                  try decodeEntries(from: readBackRaw, using: key) == entries else {
                return .readBackFailed
            }
        } catch {
            return .readBackFailed
        }
        return .converted
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
