import CryptoKit
import FernletCrypto
import Foundation
import PrivateHealthStore

// PeriodBackupFormat.swift — the period Sealed backup's v2 chunk format, its writer tag and the
// device-local bookkeeping the v2 export and restore keep (period-data design 2026-09-30, §5.3, §9.10).
// The record crypto and chunking are `SealedBackupService`'s and unchanged; only the plaintext inside
// each sealed chunk changed: whole `CycleRecord`s instead of `[MenstrualNarrative]`.

/// Who wrote a period backup set and which generation it is — the compare-and-swap pair of §9.10 E2.
///
/// `writer` is a ``PeriodBackupWriterTag`` (32 lowercase hex characters) for a v2 set, or
/// ``v1Writer`` for a set an earlier build wrote (a bare `[MenstrualNarrative]` array carries no
/// writer). The ``token`` spelling `"<writer>:<generation>"` is the FROZEN at-rest value of
/// `fernlet.sealedBackup.periodAcceptedHead` (`LocalizationBoundaryTests`).
struct PeriodBackupHead: Equatable, Hashable, Sendable {
    /// The writer of every set an earlier build wrote. FROZEN.
    static let v1Writer = "v1"

    /// The install that wrote the set (or ``v1Writer``).
    var writer: String
    /// The set's generation, authenticated by the record AEAD.
    var generation: Int64

    /// The persisted spelling, `"<writer>:<generation>"`.
    var token: String { "\(writer):\(generation)" }

    /// Creates a head.
    init(writer: String, generation: Int64) {
        self.writer = writer
        self.generation = generation
    }

    /// Parses a persisted ``token``; nil for anything malformed (an absent or unreadable record is
    /// "this install has accepted no head", which only ever refuses an export).
    init?(token: String) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let generation = Int64(parts[1]) else { return nil }
        self.init(writer: String(parts[0]), generation: generation)
    }
}

/// One v2 chunk plaintext: `{"v":2,"writer":"<32 hex>","total":N,"records":[CycleRecord…]}` for the
/// head (chunk 0), `{"v":2,"records":[…]}` for the rest (§9.10). The keys and `v` are FROZEN tokens
/// (`LocalizationBoundaryTests`); each record is ``CycleRecord``'s own frozen Codable — the same bytes
/// the sealed column and the pending buffer carry.
struct PeriodBackupChunk: Codable, Equatable {
    /// The envelope format this build writes.
    static let formatVersion = 2

    /// The head's writer tag; nil on every other chunk.
    var writer: String?
    /// The head's snapshot size — how many ids the set was built from (a record deleted mid-export is
    /// simply absent from its chunk, so the records may be fewer). Informational; nil on other chunks.
    var total: Int?
    /// The chunk's records.
    var records: [CycleRecord]

    /// FROZEN keys.
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case writer, total, records
    }

    /// Creates a chunk.
    init(writer: String? = nil, total: Int? = nil, records: [CycleRecord]) {
        self.writer = writer
        self.total = total
        self.records = records
    }

    /// Decodes a chunk; a `v` newer than ``formatVersion`` throws
    /// ``PeriodBackupFormatError/unsupportedVersion(_:)`` (retryable: a newer build wrote it).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else { throw PeriodBackupFormatError.unsupportedVersion(version) }
        writer = try container.decodeIfPresent(String.self, forKey: .writer)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        records = try container.decode([CycleRecord].self, forKey: .records)
    }

    /// Encodes the frozen shape.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encodeIfPresent(writer, forKey: .writer)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encode(records, forKey: .records)
    }
}

/// A period backup chunk this build cannot read.
enum PeriodBackupFormatError: Error, Equatable {
    /// A v2 envelope from a newer build (`v` above ``PeriodBackupChunk/formatVersion``). Retryable:
    /// nothing is wrong with the backup, this build is old.
    case unsupportedVersion(Int)
    /// A head chunk whose envelope carries no writer tag.
    case headWithoutWriter
}

/// Reading and writing the period backup's chunk plaintexts — both shapes (§9.10 "Payload").
enum PeriodBackupFormat {
    /// The records one chunk carries. A JSON array is a v1 set: `[MenstrualNarrative]`, each becoming
    /// a narrative-only record under its deterministic legacy id with origin
    /// ``CycleRecordOrigin/restored`` (so it merges with the same entry's import or drain). An object
    /// is a v2 envelope, decoded directly.
    static func records(fromChunk plaintext: Data) throws -> [CycleRecord] {
        if isV1(plaintext) {
            return try JSONDecoder().decode([MenstrualNarrative].self, from: plaintext)
                .map { CycleRecord(legacyNarrative: $0, origin: .restored) }
        }
        return try JSONDecoder().decode(PeriodBackupChunk.self, from: plaintext).records
    }

    /// The head of a set from its chunk 0 plaintext and the set's authenticated generation: a v1 set
    /// is written by ``PeriodBackupHead/v1Writer``; a v2 head names its writer.
    static func head(ofChunk plaintext: Data, generation: Int64) throws -> PeriodBackupHead {
        if isV1(plaintext) { return PeriodBackupHead(writer: PeriodBackupHead.v1Writer, generation: generation) }
        guard let writer = try JSONDecoder().decode(PeriodBackupChunk.self, from: plaintext).writer else {
            throw PeriodBackupFormatError.headWithoutWriter
        }
        return PeriodBackupHead(writer: writer, generation: generation)
    }

    /// Encodes one v2 chunk; the head (index 0) carries the writer tag and the snapshot size.
    static func encodeChunk(index: Int, records: [CycleRecord], writer: String, total: Int) throws -> Data {
        let chunk = index == 0
            ? PeriodBackupChunk(writer: writer, total: total, records: records)
            : PeriodBackupChunk(records: records)
        return try JSONEncoder().encode(chunk)
    }

    /// Whether a plaintext is a v1 set: its first non-whitespace byte opens a JSON array.
    private static func isV1(_ plaintext: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return plaintext.first { !whitespace.contains($0) } == UInt8(ascii: "[")
    }
}

/// Names the install that wrote a period backup set (§9.10): the first 16 bytes of
/// `SHA256(Hash.sealedBackupWriterTagV1 ‖ DeviceBindingID)`, as 32 lowercase hex characters.
///
/// It travels only inside the escrow-sealed head plaintext, so it adds no plaintext field to CloudKit.
/// It is per INSTALL (the binding is minted per install and never migrates), not per Apple Account,
/// which is exactly what the compare-and-swap needs: "is the set in iCloud the one this install last
/// wrote or merged". An identifier, not a secret.
enum PeriodBackupWriterTag {
    /// The tag for this install, or nil when the install binding is unavailable — the export then
    /// defers (transient), never writes an untagged head.
    static func current() -> String? {
        guard let binding = DeviceBindingID.current() else { return nil }
        return tag(forBinding: binding)
    }

    /// The tag for a given install binding.
    static func tag(forBinding binding: Data) -> String {
        let digest = SHA256.hash(data: FernletCryptoPurpose.Hash.sealedBackupWriterTagV1.data + binding)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the period backup's last export attempt has to tell Privacy & Data (§10.6). In memory only:
/// the next export at the next Cycle visit re-derives it.
enum PeriodBackupExportState: Equatable {
    /// Nothing to report.
    case clear
    /// The cycle backup in iCloud was written by a set this install has not accepted (another iPhone,
    /// or this one before an app-lock reset or "Delete everything"). Nothing is written over it until
    /// the user chooses "Restore it here" or "Replace it with this iPhone's history" (§9.10 E2, Q9).
    case heldByAnotherDevice(PeriodBackupHead)
    /// The export's pre-pass found this many records that can never open on this iPhone (after the
    /// "entries this iPhone can't open" check, only tampering or corruption), so nothing was written
    /// (§9.10 E3).
    case unopenableEntries(Int)
}

/// The period Sealed backup's device-local bookkeeping (period-data design 2026-09-30, §5.3, §9.10):
/// the restore marker and the compare-and-swap record. Standard defaults, injected so tests get an
/// isolated suite. Like the divergence latches, both travel inside an iCloud or Finder device backup —
/// which is why the "entries this iPhone can't open" check and the app-lock reset funnel clear them.
///
/// - **`fernlet.cycleRecord.periodRestoreResolved`** — "this install has finished pulling the period
///   backup". While false the AMBIENT period restore runs (an id-keyed merge); once true it never runs
///   ambiently again, which is what stops a stale cloud copy from resurrecting entries the user
///   deleted. Absent means "never decided": the first read seeds it, ONCE, from the legacy
///   `fernlet.menstrualNarrative.everStored` latch (an install that already held cycle data had its
///   ambient restore closed by that latch and keeps that), and writes the answer, so the latch is
///   never read for period again. Cleared (written `false`, never removed, so the seed cannot run
///   again) by the "can't open" check and the reset funnel; KEPT by "Delete everything".
/// - **`fernlet.sealedBackup.periodAcceptedHead`** — the `(writer, generation)` of the last set this
///   install wrote or merged (``PeriodBackupHead/token``). The export replaces only that set. Lives
///   in the generation store's namespace, so "Delete everything" clears it with the rollback marks.
@MainActor
struct PeriodBackupLedger {
    /// The restore marker's FROZEN key.
    static let restoreResolvedKey = "fernlet.cycleRecord.periodRestoreResolved"
    /// The compare-and-swap record's FROZEN key.
    static let acceptedHeadKey = SealedBackupGenerationStore.periodAcceptedHeadKey

    /// Where both live.
    let defaults: UserDefaults
    /// The legacy cycle divergence latch (`MenstrualNarrativeRepository.hasEverStoredNarrative` in
    /// production), read only while the marker is absent — the one-time seed.
    let legacyLatch: @MainActor () -> Bool

    /// Creates the ledger.
    ///
    /// - Parameters:
    ///   - defaults: Where the marker and the record live.
    ///   - legacyLatch: The one-time seed's source.
    init(defaults: UserDefaults, legacyLatch: @escaping @MainActor () -> Bool) {
        self.defaults = defaults
        self.legacyLatch = legacyLatch
    }

    /// Whether the period restore is resolved, seeding an absent marker once from ``legacyLatch``.
    var isRestoreResolved: Bool {
        if let decided = defaults.object(forKey: Self.restoreResolvedKey) as? Bool { return decided }
        let seeded = legacyLatch()
        defaults.set(seeded, forKey: Self.restoreResolvedKey)
        return seeded
    }

    /// Whether the marker reads `true` right now — bookkeeping for the "can't open" check. Never seeds.
    var restoreResolvedIsSet: Bool { defaults.object(forKey: Self.restoreResolvedKey) as? Bool == true }

    /// Marks the period restore resolved.
    func markRestoreResolved() {
        defaults.set(true, forKey: Self.restoreResolvedKey)
    }

    /// Re-opens the ambient period restore (writes `false`, so the one-time seed never runs again).
    func reopenRestore() {
        defaults.set(false, forKey: Self.restoreResolvedKey)
    }

    /// The head this install last wrote or merged, if any (read through the generation store, whose
    /// namespace the record lives in).
    var acceptedHead: PeriodBackupHead? {
        SealedBackupGenerationStore(defaults: defaults).periodAcceptedHeadToken.flatMap(PeriodBackupHead.init(token:))
    }

    /// Records the head this install just wrote or merged — or, on the user's explicit "Replace", the
    /// other set they chose to replace.
    func recordAcceptedHead(_ head: PeriodBackupHead) {
        SealedBackupGenerationStore(defaults: defaults).recordPeriodAcceptedHeadToken(head.token)
    }

    /// Forgets the accepted head (it spoke for a key or an install state that no longer exists).
    func clearAcceptedHead() {
        SealedBackupGenerationStore(defaults: defaults).clearPeriodAcceptedHead()
    }
}
