// CycleRecordMergeTests.swift
// FernletTests
//
// Invariant I26 of the period-data design (2026-09-30, §5.1a): `CycleRecord.merged` is
// content-commutative and idempotent, takes each block WHOLE by its clock, never brings back a flag
// the user cleared from an older copy, keeps a temperature with its unit, and batches are reduced by
// id before anything is written. Also the record's own value rules (§5.1): what "storable" means, and
// the sheet's caps applied by every initializer.

import Foundation
import Testing
import PrivateHealthStore

struct CycleRecordMergeTests {
    private static let id = UUID(uuidString: "0A0A0A0A-1B1B-4C4C-8D8D-2E2E2E2E2E2E") ?? UUID()
    private static let early = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let late = Date(timeIntervalSinceReferenceDate: 800_086_400)

    private func clinical(_ flow: PeriodFlowLevel?, start: Bool = false, bbt: Double? = nil,
                          unit: PeriodTemperatureUnit = .fahrenheit, at date: Date) -> CycleClinicalFields {
        CycleClinicalFields(flowLevel: flow, isCycleStart: start, basalBodyTemperature: bbt, temperatureUnit: unit, updatedAt: date)
    }

    private func narrative(_ note: String?, flags: [PeriodSymptom] = [], at date: Date) -> CycleNarrativeFields {
        CycleNarrativeFields(note: note, symptomFlags: flags, customSymptomScales: [:], updatedAt: date)
    }

    private func record(clinical: CycleClinicalFields?, narrative: CycleNarrativeFields?,
                        origin: CycleRecordOrigin = .logged, created: Date = Self.early,
                        loggedAt: Date = Self.early, dayKey: String = "2026-09-01") -> CycleRecord {
        CycleRecord(id: Self.id, dayKey: dayKey, loggedAt: loggedAt, clinical: clinical, narrative: narrative,
                    origin: origin, createdAt: created, updatedAt: created)
    }

    /// Content equality: everything but `origin`, which is `a`'s by rule.
    private func sameContent(_ lhs: CycleRecord, _ rhs: CycleRecord) -> Bool {
        var rhs = rhs
        rhs.origin = lhs.origin
        return lhs == rhs
    }

    /// A small fixed corpus of copies of one record — known/unknown/empty blocks, early/late clocks,
    /// equal clocks with different content — so the algebra is checked over every ordered pair.
    private var corpus: [CycleRecord] {
        [
            record(clinical: clinical(.heavy, start: true, at: Self.early), narrative: nil),
            record(clinical: clinical(.light, at: Self.late), narrative: narrative("later", at: Self.late),
                   origin: .restored, created: Self.late, loggedAt: Self.late, dayKey: "2026-09-02"),
            record(clinical: nil, narrative: narrative("old note", flags: [.cramps], at: Self.early), origin: .importedLegacy),
            record(clinical: clinical(nil, at: Self.late), narrative: narrative(nil, at: Self.late), created: Self.late),
            record(clinical: clinical(.medium, at: Self.late), narrative: narrative("same clock", at: Self.early),
                   created: Self.late, loggedAt: Self.late.addingTimeInterval(60)),
            record(clinical: clinical(.medium, bbt: 36.6, unit: .celsius, at: Self.late), narrative: nil, origin: .adoptedFromHealth),
            // The same clinical block as the first copy, logged at another time: the equal-block rule.
            record(clinical: clinical(.heavy, start: true, at: Self.early), narrative: narrative("twin", at: Self.late),
                   created: Self.late, loggedAt: Self.early.addingTimeInterval(-3_600), dayKey: "2026-08-31")
        ]
    }

    @Test func mergeIsCommutativeOnContentOverEveryPair() {
        for a in corpus {
            for b in corpus {
                let ab = CycleRecord.merged(a, b)
                let ba = CycleRecord.merged(b, a)
                #expect(sameContent(ab, ba), "merged(a, b) and merged(b, a) disagree on content:\n\(ab)\n\(ba)")
                #expect(ab.origin == a.origin, "origin is the first argument's")
            }
        }
    }

    @Test func mergeIsIdempotentAndAssociativeOverTheCorpus() {
        for x in corpus {
            #expect(CycleRecord.merged(x, x) == x)
        }
        for a in corpus {
            for b in corpus {
                for c in corpus {
                    let left = CycleRecord.merged(CycleRecord.merged(a, b), c)
                    let right = CycleRecord.merged(a, CycleRecord.merged(b, c))
                    #expect(sameContent(left, right), "batch order changed the reduced record")
                }
            }
        }
    }

    /// The later clinical block wins WHOLE: the user cleared "first day" and the flow on the newer
    /// copy, and neither comes back from the older one.
    @Test func aBlockIsTakenWholeSoAClearedFlagNeverReturns() {
        let older = record(clinical: clinical(.heavy, start: true, at: Self.early), narrative: nil)
        let newer = record(clinical: clinical(nil, start: false, at: Self.late), narrative: nil)
        for merged in [CycleRecord.merged(older, newer), CycleRecord.merged(newer, older)] {
            #expect(merged.clinical?.isCycleStart == false)
            #expect(merged.clinical?.flowLevel == nil)
            #expect(merged.clinical?.updatedAt == Self.late)
        }
    }

    /// A temperature travels with its unit: the winning block brings both, never the other side's unit.
    @Test func aTemperatureAlwaysTravelsWithItsUnit() {
        let celsius = record(clinical: clinical(nil, bbt: 36.6, unit: .celsius, at: Self.late), narrative: nil)
        let fahrenheit = record(clinical: clinical(.light, bbt: 97.9, unit: .fahrenheit, at: Self.early), narrative: nil)
        let merged = CycleRecord.merged(fahrenheit, celsius)
        #expect(merged.clinical?.basalBodyTemperature == 36.6)
        #expect(merged.clinical?.temperatureUnit == .celsius)
        #expect(merged.clinical?.flowLevel == nil, "the older block's flow must not be mixed in")
    }

    /// An UNKNOWN block is filled from the side that knows it; nothing is invented when neither does.
    @Test func anUnknownBlockIsFilledNeverInvented() {
        let notes = record(clinical: nil, narrative: narrative("from the narrative", at: Self.early))
        let samples = record(clinical: clinical(.medium, at: Self.early), narrative: nil, loggedAt: Self.late, dayKey: "2026-09-03")
        let merged = CycleRecord.merged(notes, samples)
        #expect(merged.clinical?.flowLevel == .medium)
        #expect(merged.narrative?.note == "from the narrative")
        // The clinical side's time is exact (sample start dates); the narrative's was a day's midnight.
        #expect(merged.loggedAt == Self.late)
        #expect(merged.dayKey == "2026-09-03")
        let neither = CycleRecord.merged(record(clinical: nil, narrative: nil), record(clinical: nil, narrative: nil))
        #expect(neither.clinical == nil && neither.narrative == nil)
    }

    @Test func createdIsTheEarlierAndUpdatedTheLater() {
        var a = record(clinical: clinical(.light, at: Self.early), narrative: nil, created: Self.late)
        a.updatedAt = Self.late
        let b = record(clinical: clinical(.light, at: Self.early), narrative: nil, created: Self.early)
        let merged = CycleRecord.merged(a, b)
        #expect(merged.createdAt == Self.early)
        #expect(merged.updatedAt == Self.late)
    }

    /// Two records with different ids are never merged: the first comes back unchanged.
    @Test func differentIDsAreNotMerged() {
        let a = record(clinical: clinical(.light, at: Self.early), narrative: nil)
        var b = record(clinical: clinical(.heavy, at: Self.late), narrative: nil)
        b.id = UUID()
        #expect(CycleRecord.merged(a, b) == a)
    }

    /// Duplicate ids inside one batch collapse to one record before anything is written.
    @Test func aBatchIsReducedByIDKeepingFirstOccurrenceOrder() {
        let other = CycleRecord(id: UUID(), dayKey: "2026-09-05", loggedAt: Self.early, clinical: clinical(.light, at: Self.early),
                                narrative: nil, origin: .logged, createdAt: Self.early, updatedAt: Self.early)
        let first = record(clinical: clinical(.heavy, at: Self.early), narrative: nil)
        let second = record(clinical: nil, narrative: narrative("dup", at: Self.late))
        let reduced = CycleRecord.reducedByID([first, other, second])
        #expect(reduced.map(\.id) == [Self.id, other.id])
        #expect(reduced.first?.clinical?.flowLevel == .heavy)
        #expect(reduced.first?.narrative?.note == "dup")
    }

    // MARK: - Record values (§5.1)

    @Test func storableMeansSomethingIsActuallyThere() {
        #expect(!record(clinical: nil, narrative: nil).isStorable)
        #expect(!record(clinical: clinical(nil, at: Self.early), narrative: narrative(nil, at: Self.early)).isStorable)
        #expect(!record(clinical: nil, narrative: narrative("   ", at: Self.early)).isStorable, "a whitespace note is no note")
        #expect(record(clinical: clinical(PeriodFlowLevel.none, at: Self.early), narrative: nil).isStorable, "flow 'none' is an answer")
        #expect(record(clinical: nil, narrative: narrative(nil, flags: [.acne], at: Self.early)).isStorable)
        #expect(!record(clinical: clinical(PeriodFlowLevel.none, at: Self.early), narrative: nil).hasActualBleedingFlow)
        #expect(record(clinical: clinical(.light, at: Self.early), narrative: nil).hasActualBleedingFlow)
    }

    /// A logged event becomes a record with BOTH blocks known and the sheet's caps applied.
    @Test func aLoggedEventKeepsBothBlocksWithTheSheetsCaps() {
        let scales = Dictionary(uniqueKeysWithValues: (0..<60).map { (String(repeating: "k", count: 50) + "\($0)", $0) })
        let event = UserLoggedCycleEvent(
            date: Self.early, basalBodyTemperature: .nan, note: "  " + String(repeating: "n", count: 1_500),
            symptoms: [.fatigue, .cramps], customSymptomScales: scales
        )
        let made = CycleRecord(event: event, now: Self.late)
        #expect(made.clinical != nil && made.narrative != nil)
        #expect(made.clinical?.isEmpty == true, "only a NaN temperature was set, and it is not a reading")
        #expect(made.narrative?.note?.count == CycleNarrativeFields.maxNoteLength)
        #expect(made.narrative?.symptomFlags == [.cramps, .fatigue])
        #expect((made.narrative?.customSymptomScales.count ?? 0) <= CycleNarrativeFields.maxCustomSymptoms)
        #expect(made.narrative?.customSymptomScales.keys.allSatisfy { $0.count <= CycleNarrativeFields.maxCustomSymptomNameLength } == true)
        #expect(made.createdAt == Self.late && made.clinical?.updatedAt == Self.late)
        #expect(made.origin == .logged)
    }
}
