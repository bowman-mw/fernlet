import Foundation
import FernletFoundation
import HealthKit
import FernletDomainModel
import FernletScoring
import PrivateHealthStore
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

    /// A cycle entry carrying real menstrual-flow HealthKit samples (built via the production sample
    /// factory, no HealthKit access) and an optional encrypted-narrative stand-in for symptoms.
    static func entry(
        on date: Date,
        flow: PeriodFlowLevel?,
        symptoms: [PeriodSymptom] = []
    ) -> CycleDayEntry {
        let samples: [HKSample]
        if let flow {
            samples = (try? HealthKitService.periodSamples(
                for: UserLoggedCycleEvent(date: date, flowLevel: flow),
                externalUUID: UUID()
            )) ?? []
        } else {
            samples = []
        }
        let narrative: MenstrualNarrative? = symptoms.isEmpty ? nil : MenstrualNarrative(
            hkExternalUUID: UUID().uuidString,
            dateKey: FernletDate.dayKey(for: date),
            note: nil,
            symptomFlags: symptoms,
            customSymptomScales: [:]
        )
        return CycleDayEntry(
            date: date,
            dateKey: FernletDate.dayKey(for: date),
            samples: samples,
            narrative: narrative,
            phase: flow != nil ? .menstrual : .unknown
        )
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
