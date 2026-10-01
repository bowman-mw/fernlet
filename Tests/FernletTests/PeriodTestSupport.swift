import Foundation
import FernletFoundation
import HealthKit
import FernletDomainModel
import FernletScoring
import PrivateHealthStore
import PeriodContextBridge
import HealthKitGateway
@testable import Fernlet

/// Deterministic fixtures + a scoring-context stub shared by the period-aware tests. Kept non-private so
/// multiple test files can reuse them (the period mocks in PeriodTrackerTests are file-private).
enum PeriodTestSupport {
    static func gmtCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = gmtCalendar()) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A cycle day as the store publishes it after the cutover: one sealed record carrying the flow
    /// level (a "None" flow is a logged none, not menstrual) and, optionally, symptoms in its narrative
    /// block — so the bridge's symptom load sees a narrative only when symptoms were given.
    static func entry(
        on date: Date,
        flow: PeriodFlowLevel?,
        symptoms: [PeriodSymptom] = []
    ) -> CycleDayEntry {
        let dayKey = FernletDate.dayKey(for: date)
        guard flow != nil || !symptoms.isEmpty else { return CycleDayEntry(date: date, dateKey: dayKey) }
        return CycleDayEntry(date: date, dateKey: dayKey, records: [record(on: date, flow: flow, symptoms: symptoms)])
    }

    /// A logged record for `date`: the clinical block known (with `flow`), the narrative block known
    /// only when `symptoms` are given.
    static func record(on date: Date, flow: PeriodFlowLevel?, symptoms: [PeriodSymptom] = []) -> CycleRecord {
        var record = CycleRecord(event: UserLoggedCycleEvent(date: date, flowLevel: flow, symptoms: Set(symptoms)), now: date)
        if symptoms.isEmpty { record.narrative = nil }
        return record
    }

    /// Apple Health samples shaped like a PRE-cutover Fernlet write of `record`: the external UUID,
    /// no `FernletCycleRecordID` marker (what the legacy import adopts).
    static func legacySamples(for record: CycleRecord) throws -> [HKSample] {
        try HealthKitService.periodSamples(for: record).map(stripMarker)
    }

    /// The same sample without the mirror marker.
    static func stripMarker(_ sample: HKSample) -> HKSample {
        var metadata = sample.metadata ?? [:]
        metadata.removeValue(forKey: FernletCycleRecordMirror.recordIDKey)
        if let category = sample as? HKCategorySample {
            return HKCategorySample(type: category.categoryType, value: category.value, start: category.startDate, end: category.endDate, metadata: metadata)
        }
        if let quantity = sample as? HKQuantitySample {
            return HKQuantitySample(type: quantity.quantityType, quantity: quantity.quantity, start: quantity.startDate, end: quantity.endDate, metadata: metadata)
        }
        return sample
    }

    static func prediction(
        cycleLength: Int = 28,
        variationDays: Int = 2,
        confidence: Double = 0.8,
        cyclesObserved: Int = 4,
        anchor: Date = date(2026, 1, 1)
    ) -> CyclePrediction {
        let next = gmtCalendar().date(byAdding: .day, value: cycleLength, to: anchor) ?? anchor
        let lower = gmtCalendar().date(byAdding: .day, value: -variationDays, to: next) ?? next
        let upper = gmtCalendar().date(byAdding: .day, value: variationDays, to: next) ?? next
        return CyclePrediction(
            nextStart: next,
            likelyStartRange: lower...upper,
            predictedCycleLength: cycleLength,
            averageCycleLength: cycleLength,
            variationDays: variationDays,
            confidence: confidence,
            cyclesObserved: cyclesObserved,
            predictedFlow: []
        )
    }
}

/// Minimal `PeriodScoringContextProviding` stub: returns a fixed adjustment regardless of day, so the
/// FernletStore opt-in gating + period-phase labelling can be tested without a live bridge.
@MainActor
final class StubPeriodContext: PeriodScoringContextProviding {
    var adjustment: PeriodScoringAdjustment
    init(_ adjustment: PeriodScoringAdjustment) { self.adjustment = adjustment }
    func scoringAdjustment(forDayKey dayKey: String) -> PeriodScoringAdjustment { adjustment }
}

/// Core-Data-free `PeriodContextSource` for bridge tests — just holds the live cycle data the bridge reads,
/// so bridge tests never spin up a Core Data stack (avoiding contention with the parallel persistence tests).
@MainActor
final class FakePeriodSource: PeriodContextSource {
    var entries: [CycleDayEntry]
    var prediction: CyclePrediction?
    init(entries: [CycleDayEntry] = [], prediction: CyclePrediction? = nil) {
        self.entries = entries
        self.prediction = prediction
    }
}
