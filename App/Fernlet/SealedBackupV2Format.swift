import CryptoKit
import FernletCrypto
import Foundation

// SealedBackupV2Format.swift — the Sealed backup v2 plaintext every v2 payload shares (journal and
// intimacy Sealed backup v2 design 2026-09-30, §5.1, building on the period design's §9.10): the
// chunk envelope, the writer tag, the set tag and the head stamp the compare-and-swap names. The
// record crypto, AAD, salt derivation and chunk size are `SealedBackupService`'s and unchanged; only
// the plaintext inside each sealed chunk is defined here.

/// Who wrote a set in iCloud and which generation it is — the stamp the E2 compare-and-swap names
/// and the user's explicit "Restore it here" / "Replace" are bound to (§4.6, §5.5).
///
/// `writer` is a ``SealedBackupWriterTag`` (32 lowercase hex) for a v2 set and ``v1Writer`` for a set
/// an earlier build wrote (a bare JSON array carries no writer). `generation` is the set's generation
/// as the record AEAD authenticated it.
struct SealedBackupHeadStamp: Equatable, Hashable, Sendable {
    /// The writer of every set an earlier build wrote. FROZEN.
    static let v1Writer = "v1"

    /// The install that wrote the set (or ``v1Writer``).
    var writer: String
    /// The set's authenticated generation.
    var generation: Int64

    /// Creates a stamp.
    init(writer: String, generation: Int64) {
        self.writer = writer
        self.generation = generation
    }
}

/// One v2 chunk plaintext (§5.1, FROZEN keys): `{"v":2,"writer":"<32 hex>","set":"<32 hex>","total":N,
/// "records":[R…]}` for the head (chunk 0) and the same without `total` for every other chunk. Every
/// chunk names its writer and set, so a restore can prove each chunk belongs to the head's set (§5.3)
/// and a chunk spliced in from another set at the same generation fails closed. `R` is the payload's
/// own `Codable` record, whose coding keys are frozen tokens too.
struct SealedBackupV2Envelope<Record: Codable>: Codable {
    /// The envelope format this build writes.
    static var formatVersion: Int { 2 }

    /// The install that wrote the set (``SealedBackupWriterTag``).
    var writer: String
    /// The set's tag (``SealedBackupSetTag``).
    var set: String
    /// The head's snapshot size — how many ids the set was built from. Nil on every other chunk.
    var total: Int?
    /// The chunk's records.
    var records: [Record]

    /// FROZEN keys.
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case writer, set, total, records
    }

    /// Creates an envelope.
    init(writer: String, set: String, total: Int?, records: [Record]) {
        self.writer = writer
        self.set = set
        self.total = total
        self.records = records
    }

    /// Decodes an envelope. A `v` other than ``formatVersion`` throws
    /// ``SealedBackupV2FormatError/unsupportedVersion(_:)``; a missing or malformed writer or set tag
    /// throws ``SealedBackupV2FormatError/malformedEnvelope``.
    init(from decoder: any Decoder) throws {
        let header = try SealedBackupV2EnvelopeHeader(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        writer = header.writer
        set = header.set
        total = header.total
        records = try container.decode([Record].self, forKey: .records)
    }

    /// Encodes the frozen shape.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(writer, forKey: .writer)
        try container.encode(set, forKey: .set)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encode(records, forKey: .records)
    }
}

/// The envelope fields without its records — what E2 reads from a head to classify it (§5.5) and the
/// set verification reads from every chunk (§5.3), without decoding a single record.
struct SealedBackupV2EnvelopeHeader: Decodable, Equatable {
    /// The writer tag.
    var writer: String
    /// The set tag.
    var set: String
    /// The head's snapshot size; nil on a suffix chunk.
    var total: Int?

    /// The envelope's frozen keys (records excepted).
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case writer, set, total
    }

    /// Decodes and validates the header.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == SealedBackupV2Envelope<Int>.formatVersion else {
            throw SealedBackupV2FormatError.unsupportedVersion(version)
        }
        let writer = try container.decode(String.self, forKey: .writer)
        let set = try container.decode(String.self, forKey: .set)
        guard SealedBackupSetTag.isValid(writer), SealedBackupSetTag.isValid(set) else {
            throw SealedBackupV2FormatError.malformedEnvelope
        }
        let total = try container.decodeIfPresent(Int.self, forKey: .total)
        if let total { guard total >= 0 else { throw SealedBackupV2FormatError.malformedEnvelope } }
        self.writer = writer
        self.set = set
        self.total = total
    }
}

/// A v2 chunk plaintext this build cannot read.
enum SealedBackupV2FormatError: Error, Equatable {
    /// An envelope from a newer build (`v` other than 2). Never overwritten automatically: the
    /// export names it `.needsNewerFernlet` (§5.5).
    case unsupportedVersion(Int)
    /// An object that is not a v2 envelope this build understands (no writer or set tag, or a
    /// malformed one).
    case malformedEnvelope
    /// The set's chunks do not belong together: a writer, set or salt that differs from the head's,
    /// a set tag that differs from the record name it was fetched under, or a record total that
    /// differs from the head's (§5.3). Fails closed as a retryable restore.
    case setMismatch
}

/// Reading the shape of a decrypted chunk plaintext.
enum SealedBackupV2Format {
    /// Whether a plaintext is a v1 set: its first non-whitespace byte opens a JSON array.
    static func isV1(_ plaintext: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return plaintext.first { !whitespace.contains($0) } == UInt8(ascii: "[")
    }

    /// The header of a v2 chunk plaintext (throws for v1 or anything this build cannot read).
    static func header(of plaintext: Data) throws -> SealedBackupV2EnvelopeHeader {
        try JSONDecoder().decode(SealedBackupV2EnvelopeHeader.self, from: plaintext)
    }

    /// Encodes one v2 chunk.
    static func encode<Record: Codable>(_ envelope: SealedBackupV2Envelope<Record>) throws -> Data {
        try JSONEncoder().encode(envelope)
    }
}

/// Names the install that wrote a v2 set (§5.1; period design §9.10): the first 16 bytes of
/// `SHA256(Hash.sealedBackupWriterTagV1 ‖ DeviceBindingID)`, as 32 lowercase hex characters.
///
/// Per INSTALL — the binding is minted per install, kept by "Delete everything" and never migrates —
/// which is exactly what the compare-and-swap asks: "is the set in iCloud this install's". It travels
/// only inside the escrow-sealed plaintext, so it adds no plaintext CloudKit field. An identifier, not
/// a secret. One registered purpose for every payload: no new `CryptographicPurpose` (§1 goal 7).
enum SealedBackupWriterTag {
    /// The tag for this install, or nil when the install binding is unavailable — the export then
    /// fails transiently, never writes an untagged set.
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

/// A v2 set's tag (§5.1): 16 CSPRNG bytes per export pass, in lowercase hex. Not a hash, so it needs
/// no registered purpose. It is inside every chunk's sealed plaintext and in the suffix chunks' record
/// names (`…chunk.<i>.<set>`), a random value with no content.
enum SealedBackupSetTag {
    /// How many random bytes a set tag carries.
    static let byteCount = 16

    /// Mints a fresh set tag from the platform CSPRNG (no unsafe buffer access, Power-of-10 R9).
    static func mint() -> String {
        (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Whether `tag` has the shape of a writer or set tag: 32 lowercase hex characters.
    static func isValid(_ tag: String) -> Bool {
        tag.utf8.count == byteCount * 2
            && tag.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// What the period backup's last pass has to tell Privacy & Data (period design §10.6), derived from
/// the engine's status and, after a relaunch, from the persisted observation of a foreign head
/// (design 2026-09-30 §10.1). A view model only; nothing persists it.
enum PeriodBackupExportState: Equatable {
    /// Nothing to report.
    case clear
    /// The cycle backup in iCloud was written by a set this install does not own or accept (another
    /// iPhone, or — a ``SealedBackupHeadStamp/v1Writer`` stamp — an earlier version of Fernlet on
    /// another iPhone). Nothing is written over it until the user chooses "Restore it here" or
    /// "Replace it with this iPhone's history".
    case heldByAnotherDevice(SealedBackupHeadStamp)
    /// The cycle backup in iCloud is sealed to a backup key this iPhone does not hold, is damaged, or
    /// will not authenticate (a restore that ended `.notRecognized`). Nothing is written over it until
    /// the user chooses "Start a new backup" (§4.6), behind its own confirmation.
    case sealedWithAnotherKey
    /// This install's restore waits for the backup key iCloud Keychain syncs: a set exists in iCloud
    /// that no key here opens yet (`.deferredKeyNotSynced` — on a new iPhone a missing key and one
    /// that does not match read the same, §5.6). Every export waits on it (E1). Named as waiting,
    /// never as a set this iPhone can't restore or another iPhone's: it may be the only copy of the
    /// history, and its key is usually on its way. "Start a new backup" stays available behind its
    /// own confirmation, which says so (design §10.1, review B1 fix round 2 N-1).
    case waitingForKey
    /// This many cycle records can never open on this iPhone, so the backup is paused (nothing
    /// written).
    case unopenableEntries(Int)
    /// The cycle backup in iCloud is numbered below one this iPhone has already seen, so the restore
    /// refused it and every export waits (E1). "Restore it here" merges exactly that set anyway;
    /// "Replace it with this iPhone's history" writes over it (design §4.6, review B1-D-B1-R1).
    case olderThanSeen(SealedBackupHeadStamp)

    /// The state for the engine's period `status` — the one mapping `FernletStore` and the tests
    /// share. A restore waiting for its synced key (`.deferredKeyNotSynced`) is named as waiting
    /// (``waitingForKey``), never as a set sealed with another key: on a new iPhone that is the normal
    /// wait for iCloud Keychain, and the set may be the only copy of the history (review B1 fix round 2
    /// N-1). One whose set will not authenticate (`.notRecognized`) offers what a head sealed with
    /// another key offers. Both keep "Start a new backup" behind its confirmation, so an install whose
    /// restore can never land is never left with no way out (review B1-D-B1-R1); one refused as older
    /// names that set with both choices. With no status this process (after a relaunch) the persisted
    /// observation of another iPhone's set is read.
    ///
    /// - Parameters:
    ///   - status: The engine's period status, nil when none this process.
    ///   - rolledBackStamp: The set the last restore refused as older than this iPhone's floor.
    ///   - observed: The persisted observation of a foreign head (read only with no status).
    static func derive(
        status: SealedBackupV2Status?,
        rolledBackStamp: SealedBackupHeadStamp?,
        observed: () -> SealedBackupHeadStamp?
    ) -> PeriodBackupExportState {
        switch status {
        case .heldByAnotherDevice(let stamp)?: return .heldByAnotherDevice(stamp)
        case .headSealedWithOtherKey?, .headDamaged?: return .sealedWithAnotherKey
        case .waitingForRestore(.deferredKeyNotSynced)?: return .waitingForKey
        case .waitingForRestore(.notRecognized)?: return .sealedWithAnotherKey
        case .waitingForRestore(.rolledBack)?: return rolledBackStamp.map(PeriodBackupExportState.olderThanSeen) ?? .clear
        case .paused(let ids)?: return .unopenableEntries(ids.count)
        case .some: return .clear
        case nil: return observed().map(PeriodBackupExportState.heldByAnotherDevice) ?? .clear
        }
    }
}
