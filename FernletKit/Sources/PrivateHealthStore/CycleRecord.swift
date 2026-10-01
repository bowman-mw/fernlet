import FernletFoundation
import Foundation

// CycleRecord.swift — the sealed, self-contained cycle entry (period-data design 2026-09-30, §5.1).
//
// One record is ONE ciphertext blob in the `CycleRecord` entity: every field below, dates and day key
// included, lives inside it. The same frozen Codable is the sealed column's plaintext, the pending
// buffer's v2 payload and (from the backup v2 round) the Sealed backup's chunk element, so every
// `CodingKeys` string and every raw value it writes is an AT-REST TOKEN: never localize, rename or
// re-spell one (`LocalizationBoundaryTests.frozenCycleRecordTokens` is the canary).
//
// Nothing here seals, reads or writes anything — `CycleRecordRepository` does. This file is values
// and one pure merge.

/// Where a cycle record came from — and, once its clinical block is known, where THAT block came
/// from: a block supplied later to an unknown slot brings its own origin (``CycleRecord/merged(_:_:)``,
/// review round 2, N-1), because the origin is what tells whether Fernlet's Apple Health copy of the
/// block existed by construction.
///
/// FROZEN tokens: the raw values ride the sealed column and the backup chunks. Display, if any ever
/// appears, goes through a separate property. A token this build does not know decodes as
/// ``importedLegacy`` (the least specific claim), so a record written by a newer build still opens.
public nonisolated enum CycleRecordOrigin: String, CaseIterable, Codable, Sendable {
    /// Logged in the sheet on this install — including a legacy note-only record whose unknown
    /// clinical block the user filled in the sheet.
    case logged
    /// Built from a source that predates records: a sealed `MenstrualNarrative`, a v1 pending-buffer
    /// entry, or Fernlet's own unmarked Apple Health samples — including a record whose unknown
    /// clinical block fill-on-read completed from Fernlet's samples.
    case importedLegacy
    /// Brought back from the Sealed backup.
    case restored
    /// Adopted from a Fernlet-authored Apple Health copy with "Keep in Fernlet".
    case adoptedFromHealth
}

/// Why a stored record's plaintext could not become a ``CycleRecord`` on this build.
///
/// `nonisolated` and `Sendable`: thrown from inside the repository's `performAndWait` closures.
public nonisolated enum CycleRecordDecodingError: Error, Equatable, Sendable {
    /// The record says it is schema `found`, newer than this build reads (a downgrade meeting a newer
    /// build's record). Never classified as dead: the record is fine, this build is old. A repository
    /// treats it as retryable and never overwrites it.
    case unsupportedSchemaVersion(found: Int)
}

/// The clinical half of a cycle record — the fields Apple Health also understands.
///
/// `nil` on a ``CycleRecord`` means UNKNOWN (a narrative-only legacy source never recorded them);
/// a present block whose fields are all unset (``isEmpty``) means the user said "none". The block is
/// always merged WHOLE (§5.1a): a flag the user cleared cannot come back from an older copy, and the
/// basal body temperature always travels with its unit.
public nonisolated struct CycleClinicalFields: Codable, Equatable, Sendable {
    /// Observed flow, or `nil` when none was logged.
    public var flowLevel: PeriodFlowLevel?
    /// Whether the user marked this day as the first day of a cycle.
    public var isCycleStart: Bool
    /// Whether the user logged spotting between periods.
    public var hasIntermenstrualBleeding: Bool
    /// Basal body temperature AS ENTERED, in ``temperatureUnit``; always finite when set.
    public var basalBodyTemperature: Double?
    /// The unit ``basalBodyTemperature`` was entered in.
    public var temperatureUnit: PeriodTemperatureUnit
    /// Observed cervical-mucus quality, or `nil`.
    public var cervicalMucusQuality: CervicalMucusQuality?
    /// Ovulation-test outcome, or `nil`.
    public var ovulationTestResult: OvulationTestResult?
    /// When this block last changed — the merge's clock for the whole block.
    public var updatedAt: Date

    /// Creates a clinical block. A non-finite temperature is dropped (JSON cannot carry one, and a
    /// temperature of NaN is not a reading).
    public init(
        flowLevel: PeriodFlowLevel? = nil,
        isCycleStart: Bool = false,
        hasIntermenstrualBleeding: Bool = false,
        basalBodyTemperature: Double? = nil,
        temperatureUnit: PeriodTemperatureUnit = .fahrenheit,
        cervicalMucusQuality: CervicalMucusQuality? = nil,
        ovulationTestResult: OvulationTestResult? = nil,
        updatedAt: Date
    ) {
        self.flowLevel = flowLevel
        self.isCycleStart = isCycleStart
        self.hasIntermenstrualBleeding = hasIntermenstrualBleeding
        self.basalBodyTemperature = basalBodyTemperature.flatMap { $0.isFinite ? $0 : nil }
        self.temperatureUnit = temperatureUnit
        self.cervicalMucusQuality = cervicalMucusQuality
        self.ovulationTestResult = ovulationTestResult
        self.updatedAt = updatedAt
    }

    /// The clinical fields of a logged event, stamped `updatedAt`.
    public init(event: UserLoggedCycleEvent, updatedAt: Date) {
        self.init(
            flowLevel: event.flowLevel,
            isCycleStart: event.isCycleStart,
            hasIntermenstrualBleeding: event.hasIntermenstrualBleeding,
            basalBodyTemperature: event.basalBodyTemperature,
            temperatureUnit: event.temperatureUnit,
            cervicalMucusQuality: event.cervicalMucusQuality,
            ovulationTestResult: event.ovulationTestResult,
            updatedAt: updatedAt
        )
    }

    /// Whether no clinical field is set (the unit alone is not a field).
    public var isEmpty: Bool {
        flowLevel == nil && !isCycleStart && !hasIntermenstrualBleeding && basalBodyTemperature == nil
            && cervicalMucusQuality == nil && ovulationTestResult == nil
    }

    /// FROZEN at-rest keys.
    enum CodingKeys: String, CodingKey {
        case flowLevel, isCycleStart, hasIntermenstrualBleeding, basalBodyTemperature, temperatureUnit
        case cervicalMucusQuality, ovulationTestResult, updatedAt
    }

    /// Tolerant per token: an enum value this build does not know decodes as `nil`; a temperature
    /// whose unit is missing or unknown is dropped with it (a number without its unit is not a
    /// reading). `updatedAt` is required — a block without its clock cannot be merged.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let unit = try container.decodeIfPresent(String.self, forKey: .temperatureUnit).flatMap(PeriodTemperatureUnit.init(rawValue:))
        let temperature = try container.decodeIfPresent(Double.self, forKey: .basalBodyTemperature)
        self.init(
            flowLevel: try container.decodeIfPresent(String.self, forKey: .flowLevel).flatMap(PeriodFlowLevel.init(rawValue:)),
            isCycleStart: try container.decodeIfPresent(Bool.self, forKey: .isCycleStart) ?? false,
            hasIntermenstrualBleeding: try container.decodeIfPresent(Bool.self, forKey: .hasIntermenstrualBleeding) ?? false,
            basalBodyTemperature: unit == nil ? nil : temperature,
            temperatureUnit: unit ?? .fahrenheit,
            cervicalMucusQuality: try container.decodeIfPresent(String.self, forKey: .cervicalMucusQuality).flatMap(CervicalMucusQuality.init(rawValue:)),
            ovulationTestResult: try container.decodeIfPresent(String.self, forKey: .ovulationTestResult).flatMap(OvulationTestResult.init(rawValue:)),
            updatedAt: Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .updatedAt))
        )
    }

    /// Writes the frozen shape. Enums as their raw values; the date as seconds since
    /// 2001-01-01 UTC, independent of any encoder's date strategy.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(flowLevel?.rawValue, forKey: .flowLevel)
        try container.encode(isCycleStart, forKey: .isCycleStart)
        try container.encode(hasIntermenstrualBleeding, forKey: .hasIntermenstrualBleeding)
        try container.encodeIfPresent(basalBodyTemperature, forKey: .basalBodyTemperature)
        try container.encode(temperatureUnit.rawValue, forKey: .temperatureUnit)
        try container.encodeIfPresent(cervicalMucusQuality?.rawValue, forKey: .cervicalMucusQuality)
        try container.encodeIfPresent(ovulationTestResult?.rawValue, forKey: .ovulationTestResult)
        try container.encode(updatedAt.timeIntervalSinceReferenceDate, forKey: .updatedAt)
    }

    /// Every field but the clock, unambiguously spelled — the merge's tiebreak between two blocks
    /// with the same `updatedAt` and different content, so the merge stays commutative.
    var contentTiebreak: String {
        [
            flowLevel?.rawValue ?? "-", isCycleStart ? "1" : "0", hasIntermenstrualBleeding ? "1" : "0",
            basalBodyTemperature.map { "\($0)" } ?? "-", temperatureUnit.rawValue,
            cervicalMucusQuality?.rawValue ?? "-", ovulationTestResult?.rawValue ?? "-"
        ].joined(separator: "|")
    }
}

/// The narrative half of a cycle record — what Fernlet adds and Apple Health never holds.
///
/// `nil` on a ``CycleRecord`` means UNKNOWN (a samples-only legacy source); a present block with no
/// note, flags or scales (``isEmpty``) means "none". Merged WHOLE like the clinical block. Every
/// initializer — decoding included — applies the caps the log sheet has always applied (R3), so no
/// path can store an unbounded note or scale dictionary.
public nonisolated struct CycleNarrativeFields: Codable, Equatable, Sendable {
    /// Longest note kept, in characters (the sheet's cap since before records).
    public static let maxNoteLength = 1_000
    /// Most custom symptom scales kept.
    public static let maxCustomSymptoms = 40
    /// Longest custom symptom name kept, in characters.
    public static let maxCustomSymptomNameLength = 40

    /// The trimmed note, or `nil` when there is none (never an empty string).
    public var note: String?
    /// Built-in symptoms, de-duplicated and in declaration order. Their raw values are FROZEN.
    public var symptomFlags: [PeriodSymptom]
    /// Custom symptom name → intensity; at most ``maxCustomSymptoms`` keys of at most
    /// ``maxCustomSymptomNameLength`` characters.
    public var customSymptomScales: [String: Int]
    /// When this block last changed — the merge's clock for the whole block.
    public var updatedAt: Date

    /// Creates a narrative block, trimming and capping everything as the sheet always has.
    public init(note: String?, symptomFlags: [PeriodSymptom], customSymptomScales: [String: Int], updatedAt: Date) {
        let trimmed = note.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNoteLength)) }
        self.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.symptomFlags = Array(Set(symptomFlags)).sorted()
        self.customSymptomScales = Self.bounded(customSymptomScales)
        self.updatedAt = updatedAt
    }

    /// Whether the block holds no note, no flag and no scale.
    public var isEmpty: Bool { note == nil && symptomFlags.isEmpty && customSymptomScales.isEmpty }

    /// Caps a custom-scale dictionary at ``maxCustomSymptoms`` entries (smallest names first, so the
    /// cut is deterministic) and each name at ``maxCustomSymptomNameLength`` characters. Names that
    /// collide once truncated keep the larger value, so the merge cannot trap.
    public static func bounded(_ scales: [String: Int]) -> [String: Int] {
        let kept = scales
            .sorted { $0.key < $1.key }
            .prefix(maxCustomSymptoms)
            .map { (String($0.key.prefix(maxCustomSymptomNameLength)), $0.value) }
        return Dictionary(kept, uniquingKeysWith: { lhs, rhs in max(lhs, rhs) })
    }

    /// FROZEN at-rest keys.
    enum CodingKeys: String, CodingKey {
        case note, symptomFlags, customSymptomScales, updatedAt
    }

    /// Tolerant per token: a symptom this build does not know is dropped (the lossy-but-sealed trade
    /// the narrative column has always made — the raw values are frozen so this never fires in
    /// practice). `updatedAt` is required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let flags = try container.decodeIfPresent([String].self, forKey: .symptomFlags) ?? []
        self.init(
            note: try container.decodeIfPresent(String.self, forKey: .note),
            symptomFlags: flags.compactMap(PeriodSymptom.init(rawValue:)),
            customSymptomScales: try container.decodeIfPresent([String: Int].self, forKey: .customSymptomScales) ?? [:],
            updatedAt: Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .updatedAt))
        )
    }

    /// Writes the frozen shape; symptoms as their raw values, the date as seconds since 2001.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(symptomFlags.map(\.rawValue), forKey: .symptomFlags)
        try container.encode(customSymptomScales, forKey: .customSymptomScales)
        try container.encode(updatedAt.timeIntervalSinceReferenceDate, forKey: .updatedAt)
    }

    /// Every field but the clock, length-prefixed where free text could contain a separator — the
    /// merge's tiebreak (see ``CycleClinicalFields``).
    var contentTiebreak: String {
        let text = note.map { "\($0.count):\($0)" } ?? "-"
        let flags = symptomFlags.map(\.rawValue).joined(separator: ",")
        let scales = customSymptomScales.sorted { $0.key < $1.key }.map { "\($0.key.count):\($0.key)=\($0.value)" }
        return ([text, flags] + scales).joined(separator: "|")
    }
}

/// One cycle entry as Fernlet keeps it: the day, the clinical block and the narrative block, sealed
/// as ONE blob (period-data design 2026-09-30, §5.1).
///
/// A record logged from the sheet has BOTH blocks known (either may be empty). One built from a
/// narrative-only legacy source has `clinical == nil`; one built from legacy samples alone has
/// `narrative == nil`. A record that carries nothing (``isStorable`` false) is never stored — an
/// emptied edit deletes instead.
///
/// There is no HealthKit-id field: every Apple Health copy of a record carries
/// `HKMetadataKeyExternalUUID = id.uuidString`, and every legacy import uses the legacy external UUID
/// as `id`, so the id alone identifies Fernlet's copies.
///
/// Codable is the FROZEN at-rest format — explicit keys, a schema field `"v": 2`, enums as raw-value
/// strings, dates as seconds since 2001 — and is tolerant per token (see the blocks). `Sendable`: it
/// crosses the repository's `performAndWait` closures.
public nonisolated struct CycleRecord: Identifiable, Codable, Equatable, Sendable {
    /// The payload format this build writes — and the newest it reads. Mirrored into the entity's
    /// plaintext `schemaVersion` column so a newer build's row is recognized without a decrypt.
    public static let schemaVersion = 2

    /// Random for a new log; deterministic for an import (the legacy external UUID).
    public var id: UUID
    /// `yyyy-MM-dd` of ``loggedAt``, fixed when the record was written.
    public var dayKey: String
    /// The date and time the user picked.
    public var loggedAt: Date
    /// The clinical block, or `nil` when UNKNOWN.
    public var clinical: CycleClinicalFields?
    /// The narrative block, or `nil` when UNKNOWN.
    public var narrative: CycleNarrativeFields?
    /// Where the record — once its clinical block is known, that block — came from.
    public var origin: CycleRecordOrigin
    /// When the record was first written.
    public var createdAt: Date
    /// When anything in the record last changed.
    public var updatedAt: Date

    /// Creates a record from its parts, as stored.
    public init(
        id: UUID,
        dayKey: String,
        loggedAt: Date,
        clinical: CycleClinicalFields?,
        narrative: CycleNarrativeFields?,
        origin: CycleRecordOrigin,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.dayKey = dayKey
        self.loggedAt = loggedAt
        self.clinical = clinical
        self.narrative = narrative
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A record for what the user entered in the log sheet — both blocks KNOWN, the sheet's caps
    /// applied (note ≤ 1000 characters, ≤ 40 custom scales of ≤ 40-character names).
    ///
    /// - Parameters:
    ///   - event: What the sheet holds.
    ///   - id: The record's id; a new random one by default.
    ///   - origin: Where it came from; ``CycleRecordOrigin/logged`` by default.
    ///   - now: The write time, stamped on the record and both blocks.
    public init(event: UserLoggedCycleEvent, id: UUID = UUID(), origin: CycleRecordOrigin = .logged, now: Date = Date()) {
        self.init(
            id: id,
            dayKey: FernletDate.dayKey(for: event.date),
            loggedAt: event.date,
            clinical: CycleClinicalFields(event: event, updatedAt: now),
            narrative: CycleNarrativeFields(
                note: event.note,
                symptomFlags: Array(event.symptoms),
                customSymptomScales: event.customSymptomScales,
                updatedAt: now
            ),
            origin: origin,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Whether the clinical block is known and sets at least one field.
    public var hasClinicalFields: Bool { clinical?.isEmpty == false }
    /// Whether the narrative block is known and holds a note, a flag or a scale.
    public var hasNarrative: Bool { narrative?.isEmpty == false }
    /// Whether the record logs actual bleeding (a flow level other than none).
    public var hasActualBleedingFlow: Bool { clinical?.flowLevel.map { $0 != PeriodFlowLevel.none } ?? false }
    /// Whether the record carries anything at all; one that does not is never stored.
    public var isStorable: Bool { hasClinicalFields || hasNarrative }

    /// FROZEN at-rest keys. `v` is the schema field.
    enum CodingKeys: String, CodingKey {
        case schema = "v"
        case id, dayKey, loggedAt, clinical, narrative, origin, createdAt, updatedAt
    }

    /// Decodes the frozen shape. A schema newer than ``schemaVersion`` throws
    /// ``CycleRecordDecodingError/unsupportedSchemaVersion(found:)`` (retryable, never "dead"); an
    /// older or malformed one, a day key that is not `yyyy-MM-dd`, or a missing identity field throws
    /// a `DecodingError` (the record is unusable). An unknown origin token decodes as
    /// ``CycleRecordOrigin/importedLegacy``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.schemaVersion
        guard schema <= Self.schemaVersion else { throw CycleRecordDecodingError.unsupportedSchemaVersion(found: schema) }
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: container, debugDescription: "schema \(schema) was never written")
        }
        let dayKey = try container.decode(String.self, forKey: .dayKey)
        guard dayKey.count == 10 else {
            throw DecodingError.dataCorruptedError(forKey: .dayKey, in: container, debugDescription: "not a yyyy-MM-dd day key")
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            dayKey: dayKey,
            loggedAt: Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .loggedAt)),
            clinical: try container.decodeIfPresent(CycleClinicalFields.self, forKey: .clinical),
            narrative: try container.decodeIfPresent(CycleNarrativeFields.self, forKey: .narrative),
            origin: CycleRecordOrigin(rawValue: try container.decode(String.self, forKey: .origin)) ?? .importedLegacy,
            createdAt: Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .createdAt)),
            updatedAt: Date(timeIntervalSinceReferenceDate: try container.decode(Double.self, forKey: .updatedAt))
        )
    }

    /// Writes the frozen shape, schema field first in meaning if not in bytes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(loggedAt.timeIntervalSinceReferenceDate, forKey: .loggedAt)
        try container.encodeIfPresent(clinical, forKey: .clinical)
        try container.encodeIfPresent(narrative, forKey: .narrative)
        try container.encode(origin.rawValue, forKey: .origin)
        try container.encode(createdAt.timeIntervalSinceReferenceDate, forKey: .createdAt)
        try container.encode(updatedAt.timeIntervalSinceReferenceDate, forKey: .updatedAt)
    }

    /// The record's frozen JSON — what the pending buffer's v2 payload carries.
    public func frozenJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes a record from its frozen JSON (see ``init(from:)`` for what throws).
    public init(frozenJSON data: Data) throws {
        self = try JSONDecoder().decode(CycleRecord.self, from: data)
    }
}

// MARK: - Merge (§5.1a)

/// A record block — clinical or narrative — as the merge and an edit handle it: taken whole, by its
/// clock, with an unambiguous spelling of its content for the equal-clock tiebreak.
nonisolated protocol CycleRecordBlock: Equatable {
    /// When the block last changed (an edit restamps it).
    var updatedAt: Date { get set }
    /// Every field but the clock, for the equal-clock tiebreak.
    var contentTiebreak: String { get }
}

nonisolated extension CycleClinicalFields: CycleRecordBlock {}
nonisolated extension CycleNarrativeFields: CycleRecordBlock {}

nonisolated extension CycleRecord {
    /// Merges two copies of ONE record (same id) — the one rule drain, import, restore and
    /// fill-on-read all use (period-data design 2026-09-30, §5.1a).
    ///
    /// - **Per block:** both known → the block with the later `updatedAt` wins WHOLE; one known → that
    ///   one; neither → `nil`. A block is never mixed field by field. Equal clocks with different
    ///   content resolve by the blocks' content spelling, not by argument order, so the merge is
    ///   commutative on content (a deliberate refinement of the design's "ties: `a`", which would
    ///   have made two devices merging the same pair disagree).
    /// - **`loggedAt` / `dayKey`:** from the side whose clinical block is known (sample times are
    ///   exact) — the winning block's side when both are, the earlier `loggedAt` when both blocks are
    ///   identical; otherwise the earlier-created side's.
    /// - **`origin`:** `combinedOrigin(_:_:)` — `a`'s (the stored copy's, at every call site)
    ///   unless `b` speaks more strongly for the clinical block: a block built from Fernlet's own
    ///   Apple Health samples, or a block supplied to an UNKNOWN slot, brings its origin with it.
    ///   **`createdAt`:** the earlier. **`updatedAt`:** the later.
    ///
    /// Idempotent (`merged(x, x) == x`) and associative, so a batch reduces to the same record in
    /// any order. Two records with different ids are not merged: `a` comes back unchanged.
    public static func merged(_ a: CycleRecord, _ b: CycleRecord) -> CycleRecord {
        guard a.id == b.id else { return a }
        var result = a
        result.origin = combinedOrigin(a, b)
        result.clinical = mergedBlock(a.clinical, b.clinical)
        result.narrative = mergedBlock(a.narrative, b.narrative)
        let timeSource = timeSource(a, b)
        result.loggedAt = timeSource.loggedAt
        result.dayKey = timeSource.dayKey
        result.createdAt = min(a.createdAt, b.createdAt)
        result.updatedAt = max(a.updatedAt, b.updatedAt)
        return result
    }

    /// Reduces a batch by id with ``merged(_:_:)`` — duplicate ids inside one batch collapse to one
    /// record (§5.1a) — keeping first-occurrence order. Bounded by the batch.
    public static func reducedByID(_ records: [CycleRecord]) -> [CycleRecord] {
        var order: [UUID] = []
        var byID: [UUID: CycleRecord] = [:]
        for record in records {
            if let existing = byID[record.id] {
                byID[record.id] = merged(existing, record)
            } else {
                order.append(record.id)
                byID[record.id] = record
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Whether the clinical block is known AND the origin says it was built from Fernlet's own Apple
    /// Health samples (``CycleRecordOrigin/importedLegacy``, ``CycleRecordOrigin/adoptedFromHealth``:
    /// the legacy import, fill-on-read, "Keep in Fernlet") — so a Fernlet copy was in Apple Health
    /// when the block was built. A narrative-only legacy record is NOT: a narrative proves nothing
    /// about Apple Health (review round 2, N-1).
    var clinicalBlockIsFromFernletHealthSamples: Bool {
        guard clinical != nil else { return false }
        switch origin {
        case .importedLegacy, .adoptedFromHealth: return true
        case .logged, .restored: return false
        }
    }

    /// The origin of two copies of one record combined — by a merge (``merged(_:_:)``) or by an edit
    /// applied over its stored copy (`a` the stored copy, `b` the edit, which is always
    /// ``CycleRecordOrigin/logged``). Once a record's clinical block is known, its origin is what says
    /// whether Fernlet's Apple Health copy of that block existed by construction — the question a
    /// refused Health delete asks (review round 2, N-1) — so it follows the copy that speaks most
    /// strongly for the block:
    ///
    /// 1. A copy whose clinical block was built from Fernlet's own Health samples
    ///    (``clinicalBlockIsFromFernletHealthSamples``): those samples existed, and a merge never
    ///    loses that evidence.
    /// 2. Otherwise a copy whose clinical block is known: a block supplied to an UNKNOWN slot — the
    ///    user's edit of a legacy note-only day, a restored copy — brings its origin with it, so a
    ///    flow the user added to such a day is `logged`, not "imported from Apple Health".
    /// 3. Otherwise `a`'s.
    ///
    /// Ties go to `a`. "The first copy of the highest standing" is associative, as the merge is.
    static func combinedOrigin(_ a: CycleRecord, _ b: CycleRecord) -> CycleRecordOrigin {
        originStanding(of: b) > originStanding(of: a) ? b.origin : a.origin
    }

    /// How strongly a copy's origin speaks for its clinical block (see ``combinedOrigin(_:_:)``):
    /// 2 built from Fernlet's Health samples, 1 otherwise known, 0 unknown.
    private static func originStanding(of record: CycleRecord) -> Int {
        if record.clinicalBlockIsFromFernletHealthSamples { return 2 }
        return record.clinical == nil ? 0 : 1
    }

    /// The whole-block rule for one block kind.
    private static func mergedBlock<Block: CycleRecordBlock>(_ a: Block?, _ b: Block?) -> Block? {
        guard let a else { return b }
        guard let b else { return a }
        return winningBlock(a, b)
    }

    /// The later block; on equal clocks the one whose content spells later (either, when equal).
    private static func winningBlock<Block: CycleRecordBlock>(_ a: Block, _ b: Block) -> Block {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        return b.contentTiebreak > a.contentTiebreak ? b : a
    }

    /// Which side's `loggedAt` and `dayKey` the merge keeps (see ``merged(_:_:)``). Every branch is a
    /// minimum or maximum over a total order carried by the merged record itself, so the rule is
    /// associative as well as commutative: a batch reduces to the same record in any order.
    private static func timeSource(_ a: CycleRecord, _ b: CycleRecord) -> CycleRecord {
        switch (a.clinical, b.clinical) {
        case let (clinicalA?, clinicalB?):
            guard clinicalA != clinicalB else { return earlierLogged(a, b) }
            return winningBlock(clinicalA, clinicalB) == clinicalA ? a : b
        case (.some, .none):
            return a
        case (.none, .some):
            return b
        case (.none, .none):
            return earlierCreated(a, b)
        }
    }

    /// Two copies with the same clinical block: the earlier `loggedAt`, then the smaller day key.
    private static func earlierLogged(_ a: CycleRecord, _ b: CycleRecord) -> CycleRecord {
        if a.loggedAt != b.loggedAt { return a.loggedAt < b.loggedAt ? a : b }
        return b.dayKey < a.dayKey ? b : a
    }

    /// The earlier-created side (the merged `createdAt` is that side's, so the pair stays coherent);
    /// ties by ``earlierLogged(_:_:)``.
    private static func earlierCreated(_ a: CycleRecord, _ b: CycleRecord) -> CycleRecord {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt ? a : b }
        return earlierLogged(a, b)
    }
}
