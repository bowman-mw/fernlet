import CryptoKit
import FernletFoundation
import Foundation
import HealthKit

// CycleDayEntry.swift — one calendar day of cycle data after the cutover (period-data design
// 2026-09-30, §6.4): Fernlet's own sealed records for the day, plus whatever Apple Health holds for
// it, read-only. And the decoders that turn Apple Health cycle samples into the cycle vocabulary,
// moved here from the old sample-backed entry so the legacy import, fill-on-read and "Keep in
// Fernlet" all build a clinical block by ONE rule.

// MARK: - Apple Health sample decoding

/// The Apple Health side of a record's mirror (period-data design 2026-09-30, §7.1).
public nonisolated enum FernletCycleRecordMirror {
    /// The metadata key every post-cutover mirror sample carries, holding the record's id
    /// (`uuidString`) beside `HKMetadataKeyExternalUUID` (the same id). It is what tells a mirror,
    /// written from a record, from a pre-cutover sample (§8): the legacy import never imports a
    /// sample that carries it. A FROZEN at-rest token in Apple Health — never rename or localize it
    /// (`LocalizationBoundaryTests` pins the spelling).
    public static let recordIDKey = "FernletCycleRecordID"
}

/// Decoders from Apple Health cycle samples to the sealed cycle vocabulary — the one rule the day
/// entry's Health fallback, the legacy import (§8.3), fill-on-read (§6.3 step 6) and "Keep in
/// Fernlet" (§7.3) share.
///
/// Every decoder reads the FIRST matching sample of its kind (a day's samples are ordered as the
/// caller gave them). A value HealthKit gained after this build decodes as `nil` (or, for flow, as
/// ``PeriodFlowLevel/unspecified``, the honest "a flow sample exists" answer). Pure and `nonisolated`.
public nonisolated enum CycleHealthSamples {
    /// The record id a Fernlet-authored sample belongs to: its
    /// ``FernletCycleRecordMirror/recordIDKey``, else its
    /// `HKMetadataKeyExternalUUID` (every pre-cutover builder stamped one, and the legacy import
    /// uses it as the record id), else an id derived from its start time (§8.3 step 3 — defensive:
    /// no shipped builder wrote a sample without an external UUID).
    public static func recordID(of sample: HKSample) -> UUID {
        if let marked = (sample.metadata?[FernletCycleRecordMirror.recordIDKey] as? String).flatMap(UUID.init(uuidString:)) {
            return marked
        }
        if let external = sample.metadata?[HKMetadataKeyExternalUUID] as? String {
            return CycleLegacyIdentity.recordID(forLegacyExternalID: external)
        }
        return CycleLegacyIdentity.recordID(forUnmarkedSampleStart: sample.startDate)
    }

    /// Whether the sample is a post-cutover mirror (it carries ``FernletCycleRecordMirror/recordIDKey``).
    public static func isMarkedMirror(_ sample: HKSample) -> Bool {
        sample.metadata?[FernletCycleRecordMirror.recordIDKey] != nil
    }

    /// The samples of one category type, in order.
    static func categorySamples(_ identifier: HKCategoryTypeIdentifier, in samples: [HKSample]) -> [HKCategorySample] {
        samples.compactMap { $0 as? HKCategorySample }.filter { $0.categoryType.identifier == identifier.rawValue }
    }

    /// The flow level one menstrual-flow sample records (`unspecified` for a value this build does
    /// not name).
    public static func flowLevel(of sample: HKCategorySample) -> PeriodFlowLevel {
        switch HKCategoryValueVaginalBleeding(rawValue: sample.value) {
        case .some(HKCategoryValueVaginalBleeding.none): return PeriodFlowLevel.none
        case .some(.light): return .light
        case .some(.medium): return .medium
        case .some(.heavy): return .heavy
        default: return .unspecified
        }
    }

    /// The flow level the first menstrual-flow sample records, or `nil` with none.
    public static func flowLevel(in samples: [HKSample]) -> PeriodFlowLevel? {
        categorySamples(.menstrualFlow, in: samples).first.map(flowLevel(of:))
    }

    /// Whether any menstrual-flow sample records actual bleeding (a level above none).
    public static func hasActualBleedingFlow(in samples: [HKSample]) -> Bool {
        categorySamples(.menstrualFlow, in: samples).contains { flowLevel(of: $0) != PeriodFlowLevel.none }
    }

    /// Whether the first menstrual-flow sample carries `HKMetadataKeyMenstrualCycleStart`.
    public static func isCycleStart(in samples: [HKSample]) -> Bool {
        categorySamples(.menstrualFlow, in: samples).first?.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool ?? false
    }

    /// Whether any sample records intermenstrual bleeding.
    public static func hasIntermenstrualBleeding(in samples: [HKSample]) -> Bool {
        !categorySamples(.intermenstrualBleeding, in: samples).isEmpty
    }

    /// The mucus quality of the first cervical-mucus sample, if any.
    public static func cervicalMucusQuality(in samples: [HKSample]) -> CervicalMucusQuality? {
        guard let sample = categorySamples(.cervicalMucusQuality, in: samples).first else { return nil }
        return CervicalMucusQuality.allCases.first { $0.hkValue == sample.value }
    }

    /// The result of the first ovulation-test sample, if any.
    public static func ovulationTestResult(in samples: [HKSample]) -> OvulationTestResult? {
        guard let sample = categorySamples(.ovulationTestResult, in: samples).first else { return nil }
        return OvulationTestResult.allCases.first { $0.hkValue == sample.value }
    }

    /// The first basal-body-temperature sample in Fahrenheit, if any.
    public static func basalBodyTemperatureFahrenheit(in samples: [HKSample]) -> Double? {
        let sample = samples.compactMap { $0 as? HKQuantitySample }
            .first { $0.quantityType.identifier == HKQuantityTypeIdentifier.basalBodyTemperature.rawValue }
        return sample?.quantity.doubleValue(for: .degreeFahrenheit())
    }

    /// The clinical block a group of Fernlet-authored samples records, stamped with the group's
    /// latest end date (the block's clock, §6.3 step 6), or `nil` for an empty group. A temperature
    /// is carried in Fahrenheit with its unit — Apple Health keeps the quantity, not the unit it was
    /// typed in.
    public static func clinicalFields(from samples: [HKSample]) -> CycleClinicalFields? {
        guard let latestEnd = samples.map(\.endDate).max() else { return nil }
        return CycleClinicalFields(
            flowLevel: flowLevel(in: samples),
            isCycleStart: isCycleStart(in: samples),
            hasIntermenstrualBleeding: hasIntermenstrualBleeding(in: samples),
            basalBodyTemperature: basalBodyTemperatureFahrenheit(in: samples),
            temperatureUnit: .fahrenheit,
            cervicalMucusQuality: cervicalMucusQuality(in: samples),
            ovulationTestResult: ovulationTestResult(in: samples),
            updatedAt: latestEnd
        )
    }

    /// A clinical-only record for one group of Fernlet-authored samples sharing `id` — the legacy
    /// import's (§8.3 step 4), fill-on-read's (§6.3 step 6) and "Keep in Fernlet"'s (§7.3) shape: the
    /// clinical block KNOWN from the samples, the narrative UNKNOWN, the day and time from the
    /// earliest sample's start. Every clock is the samples' own latest end date, never "now", so the
    /// same samples always build the same record and re-running an import changes nothing (I13).
    ///
    /// - Returns: `nil` for an empty group.
    public static func clinicalRecord(id: UUID, samples: [HKSample], origin: CycleRecordOrigin) -> CycleRecord? {
        guard let clinical = clinicalFields(from: samples),
              let start = samples.map(\.startDate).min() else { return nil }
        return CycleRecord(
            id: id,
            dayKey: FernletDate.dayKey(for: start),
            loggedAt: start,
            clinical: clinical,
            narrative: nil,
            origin: origin,
            createdAt: clinical.updatedAt,
            updatedAt: clinical.updatedAt
        )
    }

    /// Groups Fernlet-authored samples by the record id each belongs to (``recordID(of:)``), keeping
    /// first-seen order. Bounded by the input.
    public static func groupedByRecordID(_ samples: [HKSample]) -> [(id: UUID, samples: [HKSample])] {
        var order: [UUID] = []
        var groups: [UUID: [HKSample]] = [:]
        for sample in samples {
            let id = recordID(of: sample)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(sample)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// The deterministic record ids of the pre-record world (period-data design 2026-09-30, §8.2, §8.3):
/// every legacy source — a sealed `MenstrualNarrative`, a v1 pending-buffer entry, Fernlet's own
/// unmarked Apple Health samples — maps to the SAME id on every run and every device, so an import,
/// a drain and a restore of one entry merge into one record instead of duplicating it.
///
/// A legacy external id that is a UUID (every shipped builder minted one) IS the record id. Anything
/// else, and a sample with no external id at all, gets a SHA-256-derived id (an identifier, not a
/// secret: no key and no domain-separated purpose is involved). FROZEN derivations.
public nonisolated enum CycleLegacyIdentity {
    /// The record id for a legacy external id (a narrative's `hkExternalUUID`, a v1 buffer entry's).
    public static func recordID(forLegacyExternalID external: String) -> UUID {
        UUID(uuidString: external) ?? derivedID(from: "legacy-external|\(external)")
    }

    /// The record id for a Fernlet-authored sample that carries no external id (§8.3 step 3).
    public static func recordID(forUnmarkedSampleStart start: Date) -> UUID {
        derivedID(from: "legacy|\(Int64(start.timeIntervalSince1970.rounded()))")
    }

    /// The first 16 bytes of SHA-256(`input`), shaped as an RFC 4122 version-8 UUID.
    private static func derivedID(from input: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - The day

/// One calendar day of cycle data: Fernlet's own sealed ``CycleRecord``s for the day, and what Apple
/// Health holds for it — read-only (period-data design 2026-09-30, §6.4).
///
/// The read-side unit ``PeriodTrackerStore`` publishes: one entry per day of the 240-day load
/// window, present whether or not anything was observed. Fernlet's records are the source of truth;
/// Apple Health samples ride beside them in two read-only groups:
/// - ``fernletHealthSamples`` — Fernlet-authored samples with NO matching record whose clinical block
///   is known: the other iPhone's mirrors, an earlier install's copies, a copy whose Health delete
///   failed. A day holding only these is a "Health-only Fernlet day" with its own two actions (§7.3);
/// - ``otherHealthSamples`` — every other app's samples, shown labelled and never imported.
///
/// The derived accessors take the first record whose clinical block sets the field, then fall back to
/// the Health samples. ``phase`` is `.menstrual` exactly when the day records ACTUAL bleeding — a
/// logged "none" no longer reads as menstrual. Identified by its day key.
public nonisolated struct CycleDayEntry: Identifiable, Equatable {
    public var id: String { dateKey }
    /// Midnight of the day.
    public var date: Date
    /// Canonical `yyyy-MM-dd` day key; doubles as the identity.
    public var dateKey: String
    /// Fernlet's records for this day, newest `updatedAt` first.
    public var records: [CycleRecord]
    /// Fernlet-authored Apple Health samples with no matching record whose clinical block is known.
    public var fernletHealthSamples: [HKSample]
    /// Other apps' Apple Health samples for this day.
    public var otherHealthSamples: [HKSample]

    /// Creates a day.
    public init(
        date: Date,
        dateKey: String,
        records: [CycleRecord] = [],
        fernletHealthSamples: [HKSample] = [],
        otherHealthSamples: [HKSample] = []
    ) {
        self.date = date
        self.dateKey = dateKey
        self.records = records
        self.fernletHealthSamples = fernletHealthSamples
        self.otherHealthSamples = otherHealthSamples
    }

    /// Every Apple Health sample shown for the day, Fernlet's first.
    public var healthSamples: [HKSample] { fernletHealthSamples + otherHealthSamples }
    /// The record an edit opens: the newest.
    public var primaryRecord: CycleRecord? { records.first }
    /// Whether anything at all is on this day: a record or an Apple Health sample.
    public var hasObservedEvent: Bool { !records.isEmpty || !fernletHealthSamples.isEmpty || !otherHealthSamples.isEmpty }
    /// Whether any record carries a narrative (a note, a symptom or a scale).
    public var hasNarrative: Bool { records.contains(where: \.hasNarrative) }
    /// Whether the day holds Fernlet's Apple Health copies and no record (§7.3).
    public var isHealthOnlyFernletDay: Bool { records.isEmpty && !fernletHealthSamples.isEmpty }
    /// `.menstrual` exactly when the day records actual bleeding; `.unknown` otherwise (richer phases
    /// come from `PeriodContextBridge`'s calendar math).
    public var phase: CyclePhase { hasActualBleedingFlow ? .menstrual : .unknown }

    /// The first record's value for a clinical field, if any record sets it.
    private func recordValue<Value>(_ pick: (CycleClinicalFields) -> Value?) -> Value? {
        for record in records {  // R2: bounded by the day's records.
            if let clinical = record.clinical, let value = pick(clinical) { return value }
        }
        return nil
    }

    /// Observed flow: a record's, else the first Apple Health flow sample's.
    public var flowLevel: PeriodFlowLevel? {
        recordValue(\.flowLevel) ?? CycleHealthSamples.flowLevel(in: healthSamples)
    }
    /// Whether the day records ACTUAL bleeding. When a record sets a flow level the records decide
    /// (the user's own entry is authoritative); otherwise any Apple Health flow sample above none.
    public var hasActualBleedingFlow: Bool {
        guard recordValue(\.flowLevel) == nil else { return records.contains(where: \.hasActualBleedingFlow) }
        return CycleHealthSamples.hasActualBleedingFlow(in: healthSamples)
    }
    /// Whether a record, or else the first Apple Health flow sample, marks the first day of a cycle.
    public var isCycleStart: Bool {
        records.contains { $0.clinical?.isCycleStart == true } || CycleHealthSamples.isCycleStart(in: healthSamples)
    }
    /// Whether a record, or else Apple Health, records intermenstrual bleeding.
    public var hasIntermenstrualBleeding: Bool {
        records.contains { $0.clinical?.hasIntermenstrualBleeding == true }
            || CycleHealthSamples.hasIntermenstrualBleeding(in: healthSamples)
    }
    /// Cervical-mucus quality: a record's, else Apple Health's.
    public var cervicalMucusQuality: CervicalMucusQuality? {
        recordValue(\.cervicalMucusQuality) ?? CycleHealthSamples.cervicalMucusQuality(in: healthSamples)
    }
    /// Ovulation-test result: a record's, else Apple Health's.
    public var ovulationTestResult: OvulationTestResult? {
        recordValue(\.ovulationTestResult) ?? CycleHealthSamples.ovulationTestResult(in: healthSamples)
    }
    /// Basal body temperature in Fahrenheit: a record's (converted from the unit it was entered in),
    /// else Apple Health's.
    public var basalBodyTemperatureFahrenheit: Double? {
        recordValue(\.basalBodyTemperatureFahrenheit) ?? CycleHealthSamples.basalBodyTemperatureFahrenheit(in: healthSamples)
    }
    /// Every record's note, in record order.
    public var notes: [String] { records.compactMap { $0.narrative?.note } }
    /// The union of every record's symptoms, in declaration order.
    public var symptomFlags: [PeriodSymptom] {
        Array(Set(records.flatMap { $0.narrative?.symptomFlags ?? [] })).sorted()
    }
    /// Every record's custom symptom scales, the larger value kept per key.
    public var customSymptomScales: [String: Int] {
        records.reduce(into: [String: Int]()) { result, record in
            result.merge(record.narrative?.customSymptomScales ?? [:]) { max($0, $1) }
        }
    }
    /// The names of the other apps whose samples are on this day, distinct and sorted.
    public var healthSourceNames: [String] {
        Array(Set(otherHealthSamples.map { $0.sourceRevision.source.name })).sorted()
    }
}

nonisolated extension CycleClinicalFields {
    /// The block's basal body temperature in Fahrenheit, whatever unit it was entered in.
    public var basalBodyTemperatureFahrenheit: Double? {
        guard let value = basalBodyTemperature else { return nil }
        return temperatureUnit == .celsius ? value * 9 / 5 + 32 : value
    }
}
