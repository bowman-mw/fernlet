import Testing
import Foundation
import FernletDomainModel
import PrivateHealthStore
@testable import Fernlet

struct CyclePhaseResolverTests {
    private let calendar = PeriodTestSupport.gmtCalendar()
    private func day(_ d: Int) -> Date { PeriodTestSupport.date(2026, 3, d, calendar: calendar) }

    /// One flow day at the start of a 28-day cycle, plus a prediction, so the resolver can place dates.
    private func anchoredEntries() -> [CycleDayEntry] {
        [PeriodTestSupport.entry(on: day(1), flow: .medium)]
    }

    @Test func observedFlowAlwaysResolvesToMenstrual() {
        let entries = anchoredEntries()
        let phase = CyclePhaseResolver.phase(on: day(1), entries: entries, prediction: PeriodTestSupport.prediction(), calendar: calendar)
        #expect(phase == .menstrual)
    }

    @Test func withoutPredictionNonBleedingDaysAreUnknown() {
        let entries = anchoredEntries()
        // Day 8 has no flow sample; with no prediction the non-bleeding phases can't be derived.
        let phase = CyclePhaseResolver.phase(on: day(8), entries: entries, prediction: nil, calendar: calendar)
        #expect(phase == .unknown)
    }

    @Test func derivesFollicularOvulatoryLutealFromCalendarMath() {
        let entries = anchoredEntries()
        let prediction = PeriodTestSupport.prediction(cycleLength: 28)
        // cycleDay 0..4 menstrual, ~5..12 follicular, ~13..15 ovulatory (ovulation = 14), ~16..29 luteal.
        #expect(CyclePhaseResolver.phase(on: day(3), entries: entries, prediction: prediction, calendar: calendar) == .menstrual)
        #expect(CyclePhaseResolver.phase(on: day(9), entries: entries, prediction: prediction, calendar: calendar) == .follicular)
        #expect(CyclePhaseResolver.phase(on: day(15), entries: entries, prediction: prediction, calendar: calendar) == .ovulatory)
        #expect(CyclePhaseResolver.phase(on: day(21), entries: entries, prediction: prediction, calendar: calendar) == .luteal)
    }

    @Test func staleDaysBeyondCycleResolveToUnknown() {
        let entries = anchoredEntries()
        let prediction = PeriodTestSupport.prediction(cycleLength: 28, variationDays: 2)
        // day 1 + 28 + 2 buffer = day 31; day 40 is well past with no newer start → unknown.
        let phase = CyclePhaseResolver.phase(on: day(40), entries: entries, prediction: prediction, calendar: calendar)
        #expect(phase == .unknown)
    }

    @Test func bandMappingMatchesPhase() {
        #expect(CyclePhaseResolver.band(for: .menstrual) == .menstruating)
        #expect(CyclePhaseResolver.band(for: .follicular) == .early)
        #expect(CyclePhaseResolver.band(for: .ovulatory) == .mid)
        #expect(CyclePhaseResolver.band(for: .luteal) == .late)
        #expect(CyclePhaseResolver.band(for: .unknown) == .unknown)
    }

    @Test func noFlowDaysAtAllResolvesToUnknown() {
        let phase = CyclePhaseResolver.phase(on: day(10), entries: [], prediction: PeriodTestSupport.prediction(), calendar: calendar)
        #expect(phase == .unknown)
    }
}
