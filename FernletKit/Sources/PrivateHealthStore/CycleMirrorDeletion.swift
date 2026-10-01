import Foundation

// CycleMirrorDeletion.swift — what deleting a cycle record's Apple Health copy did, kind by kind
// (period-data design 2026-09-30, §7.1). Apple Health grants and refuses Fernlet's share access per
// sample kind, and a refusal cannot say whether access was never granted or was taken away after a
// copy was written. So a mirror delete reports the kinds it was refused instead of throwing, and the
// store decides, from the record itself, whether a copy can really be left behind (review round 1,
// R2: a refused kind the entry never held left nothing, and must neither stop the rewrite nor be
// reported as "still in Apple Health").

/// One of the five Apple Health sample kinds a cycle record's mirror can hold — the unit Apple Health
/// grants, and refuses, Fernlet's share access in. The first-day-of-cycle flag is not a kind of its
/// own: it rides on the menstrual-flow sample.
///
/// In-memory vocabulary between the mirror seam and ``PeriodTrackerStore`` only: never persisted,
/// never shown, never on the wire, so it has no raw value to freeze.
public nonisolated enum CycleMirrorSampleKind: CaseIterable, Hashable, Sendable {
    /// `HKCategoryTypeIdentifier.menstrualFlow` (also carries the first-day-of-cycle flag).
    case menstrualFlow
    /// `HKQuantityTypeIdentifier.basalBodyTemperature`.
    case basalBodyTemperature
    /// `HKCategoryTypeIdentifier.cervicalMucusQuality`.
    case cervicalMucusQuality
    /// `HKCategoryTypeIdentifier.ovulationTestResult`.
    case ovulationTestResult
    /// `HKCategoryTypeIdentifier.intermenstrualBleeding`.
    case intermenstrualBleeding

    /// The kinds a mirror of `clinical` writes — one per set field, exactly as the gateway's sample
    /// builder writes them (`HealthKitWriteGateTests` pins the two against each other). A
    /// first-day-of-cycle flag with no flow level writes nothing of its own.
    public static func kinds(writtenFor clinical: CycleClinicalFields) -> Set<CycleMirrorSampleKind> {
        var kinds: Set<CycleMirrorSampleKind> = []
        if clinical.flowLevel != nil { kinds.insert(.menstrualFlow) }
        if clinical.basalBodyTemperature != nil { kinds.insert(.basalBodyTemperature) }
        if clinical.cervicalMucusQuality != nil { kinds.insert(.cervicalMucusQuality) }
        if clinical.ovulationTestResult != nil { kinds.insert(.ovulationTestResult) }
        if clinical.hasIntermenstrualBleeding { kinds.insert(.intermenstrualBleeding) }
        return kinds
    }

    /// The kinds a Fernlet copy of `record` in Apple Health could hold: its clinical block's own kinds
    /// — or, for an UNKNOWN block, every kind, because such a record's pre-cutover samples (which
    /// carry its id) were never read and could be of any kind.
    public static func possibleCopyKinds(of record: CycleRecord) -> Set<CycleMirrorSampleKind> {
        guard let clinical = record.clinical else { return Set(allCases) }
        return kinds(writtenFor: clinical)
    }
}

/// What deleting one record's Apple Health copy did (``PeriodHealthKitServicing/deleteMirror(recordID:)``):
/// how many of Fernlet's samples Apple Health deleted, and which kinds it would not let Fernlet touch.
///
/// A refused kind is share access the user DENIED for it. HealthKit reports access never granted and
/// access taken away after a copy was written the same way, so a refusal alone does not mean anything
/// was left behind; ``PeriodTrackerStore`` weighs it against the record (only a kind the record's
/// copy could hold counts). Every other failure is thrown by the seam, not reported here.
public nonisolated struct CycleMirrorDeletion: Equatable, Sendable {
    /// How many samples Apple Health deleted (HealthKit's own count).
    public var deletedCount: Int
    /// The kinds whose delete Apple Health refused (share access denied).
    public var refusedKinds: Set<CycleMirrorSampleKind>

    /// Creates a result; the default is "nothing deleted, nothing refused" (a device without Health).
    public init(deletedCount: Int = 0, refusedKinds: Set<CycleMirrorSampleKind> = []) {
        self.deletedCount = deletedCount
        self.refusedKinds = refusedKinds
    }
}
