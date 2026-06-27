import Testing
import FernletFoundation
import Foundation
import FernletDomainModel
import FernletScoring
@testable import Fernlet

@MainActor
struct PeriodContextBridgeTests {
    private let calendar = PeriodTestSupport.gmtCalendar()

    private func makeSource(entries: [CycleDayEntry], prediction: CyclePrediction?) -> FakePeriodSource {
        FakePeriodSource(entries: entries, prediction: prediction)
    }

    private func todayEntry(flow: PeriodFlowLevel?) -> CycleDayEntry {
        PeriodTestSupport.entry(on: Date(), flow: flow)
    }

    // MARK: 3-cycle gate

    @Test func phaseIsUnknownWithoutPredictionUnlessObservedFlowToday() {
        let withFlow = makeSource(entries: [todayEntry(flow: .medium)], prediction: nil)
        #expect(PeriodContextBridge(source: withFlow, calendar: calendar).currentPhaseSignal() == .menstrual)

        let withoutFlow = makeSource(entries: [todayEntry(flow: PeriodFlowLevel.none)], prediction: nil)
        #expect(PeriodContextBridge(source: withoutFlow, calendar: calendar).currentPhaseSignal() == .unknown)
    }

    // MARK: Lock degradation

    @Test func nutritionAndExerciseAreNoDataUntilUnlocked() {
        let source = makeSource(entries: [todayEntry(flow: .medium)], prediction: PeriodTestSupport.prediction())
        let bridge = PeriodContextBridge(source: source, calendar: calendar)

        // Default (locked / not refreshed) → symptom-dependent hints withheld.
        #expect(bridge.nutritionSignal() == .noData)
        #expect(bridge.exerciseSignal() == .noData)

        bridge.refresh(unlocked: true, wellbeingByDay: [:])
        #expect(bridge.nutritionSignal() == .iron(.suggested))     // menstrual today
        #expect(bridge.exerciseSignal() == .gentleness(.suggested))
    }

    // MARK: Deletion → deliberate forgetfulness

    @Test func deletingPeriodDataReturnsUnknownAndNoData() {
        let source = makeSource(entries: [todayEntry(flow: .medium)], prediction: PeriodTestSupport.prediction())
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        bridge.refresh(unlocked: true, wellbeingByDay: [:])
        #expect(bridge.currentPhaseSignal() == .menstrual)

        // Simulate a wipe: entries cleared, prediction gone.
        source.entries = []
        source.prediction = nil
        bridge.refresh(unlocked: true, wellbeingByDay: [:])
        #expect(bridge.currentPhaseSignal() == .unknown)
        #expect(bridge.currentPhaseBand() == .unknown)
        #expect(bridge.nutritionSignal() == .noData)
        #expect(bridge.exerciseSignal() == .noData)
    }

    // MARK: Scoring egress gating

    @Test func scoringAdjustmentIsNoneWithoutPrediction() {
        let source = makeSource(entries: [todayEntry(flow: .medium)], prediction: nil)
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        #expect(bridge.scoringAdjustment(forDayKey: FernletDate.dayKey(for: Date())) == .none)
    }

    @Test func phaseAwareBehaviourGatedUntilThreeCompletedCycles() {
        // 3 starts = 2 completed cycles, one short of the gate → no phase-aware adjustment yet, even though
        // a prediction exists and the day would otherwise resolve to luteal.
        let entries = [PeriodTestSupport.entry(on: PeriodTestSupport.date(2026, 3, 1, calendar: calendar), flow: .medium)]
        let source = makeSource(entries: entries, prediction: PeriodTestSupport.prediction(cycleLength: 28, cyclesObserved: 3))
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        let lutealKey = FernletDate.dayKey(for: PeriodTestSupport.date(2026, 3, 21, calendar: calendar))
        #expect(bridge.scoringAdjustment(forDayKey: lutealKey) == .none)
    }

    @Test func scoringAdjustmentCarriesPhaseButDoesNotSoftenWithoutHardTrend() {
        let entries = [PeriodTestSupport.entry(on: PeriodTestSupport.date(2026, 3, 1, calendar: calendar), flow: .medium)]
        let source = makeSource(entries: entries, prediction: PeriodTestSupport.prediction(cycleLength: 28))
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        bridge.refresh(unlocked: true, wellbeingByDay: [:]) // no observations → no trends

        // Mar 21 → cycleDay 20 → luteal.
        let adjustment = bridge.scoringAdjustment(forDayKey: FernletDate.dayKey(for: PeriodTestSupport.date(2026, 3, 21, calendar: calendar)))
        #expect(adjustment.phase == .luteal)
        #expect(adjustment.hydrationRelief == .none)
        #expect(adjustment.leniency == .none)
        #expect(adjustment.softensScoring == false)
    }

    @Test func scoringAdjustmentSoftensHistoricallyHardPhase() {
        let (entries, wellbeing) = multiCycleHistory()
        let source = makeSource(entries: entries, prediction: PeriodTestSupport.prediction(cycleLength: 28, cyclesObserved: 4))
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        bridge.refresh(unlocked: true, wellbeingByDay: wellbeing)

        // A medium/high-confidence "worse sleep in luteal" trend should now exist…
        #expect(bridge.currentTrends.contains { $0.phase == .luteal && $0.metric == .sleep && $0.direction == .worse && $0.confidence >= .medium })

        // …so a luteal day softens (Feb 16 → cycleDay 18 of the Jan 29 cycle).
        let lutealKey = FernletDate.dayKey(for: PeriodTestSupport.date(2026, 2, 16, calendar: calendar))
        let adjustment = bridge.scoringAdjustment(forDayKey: lutealKey)
        #expect(adjustment.phase == .luteal)
        #expect(adjustment.hydrationRelief == .suggested)
        #expect(adjustment.leniency == .suggested)
    }

    // MARK: Recompute-on-demand

    @Test func phaseResolutionReadsLiveSourceWithoutExplicitRefresh() {
        let source = makeSource(entries: [todayEntry(flow: PeriodFlowLevel.none)], prediction: nil)
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        #expect(bridge.currentPhaseSignal() == .unknown)

        // Mutating the source is reflected immediately (no cached signal).
        source.entries = [todayEntry(flow: .heavy)]
        #expect(bridge.currentPhaseSignal() == .menstrual)
    }

    /// The memoized `cachedPeriodStarts` (the per-render scoring optimization) must be rebuilt on every
    /// `refresh()`. A newer detected period start re-anchors the cycle math, so the same query day resolves
    /// to a different non-bleeding phase after refresh — which only happens if the starts memo invalidated.
    @Test func refreshRebuildsCachedPeriodStartsAfterEntriesChange() {
        let mar1 = PeriodTestSupport.date(2026, 3, 1, calendar: calendar)
        let source = makeSource(
            entries: [PeriodTestSupport.entry(on: mar1, flow: .medium)],
            prediction: PeriodTestSupport.prediction(cycleLength: 28, cyclesObserved: 4)
        )
        let bridge = PeriodContextBridge(source: source, calendar: calendar)
        bridge.refresh(unlocked: true, wellbeingByDay: [:])

        // Mar 21 is day 20 of the lone Mar 1 cycle → luteal.
        let queryKey = FernletDate.dayKey(for: PeriodTestSupport.date(2026, 3, 21, calendar: calendar))
        #expect(bridge.scoringAdjustment(forDayKey: queryKey).phase == .luteal)

        // A second period start on Mar 18 re-anchors the cycle; Mar 21 is now cycle-day 3 → menstrual.
        // A stale Mar 1 anchor (un-invalidated memo) would keep returning luteal.
        let mar18 = PeriodTestSupport.date(2026, 3, 18, calendar: calendar)
        source.entries = [
            PeriodTestSupport.entry(on: mar1, flow: .medium),
            PeriodTestSupport.entry(on: mar18, flow: .medium)
        ]
        bridge.refresh(unlocked: true, wellbeingByDay: [:])
        #expect(bridge.scoringAdjustment(forDayKey: queryKey).phase == .menstrual)
    }

    /// Four period starts (= 3 completed cycles, the gate), flow on the first 4 days of each, with low sleep
    /// on every luteal day and high sleep elsewhere, so the trend engine reliably flags luteal sleep as
    /// historically worse.
    private func multiCycleHistory() -> (entries: [CycleDayEntry], wellbeing: [String: PeriodWellbeingSample]) {
        let starts = [
            PeriodTestSupport.date(2026, 1, 1, calendar: calendar),
            PeriodTestSupport.date(2026, 1, 29, calendar: calendar),
            PeriodTestSupport.date(2026, 2, 26, calendar: calendar),
            PeriodTestSupport.date(2026, 3, 26, calendar: calendar)
        ]
        let firstDay = starts[0]
        var entries: [CycleDayEntry] = []
        for offset in 0..<114 {
            let date = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            let isFlow = starts.contains { start in
                let d = calendar.dateComponents([.day], from: start, to: date).day ?? -1
                return d >= 0 && d < 4
            }
            entries.append(PeriodTestSupport.entry(on: date, flow: isFlow ? .medium : nil))
        }

        let prediction = PeriodTestSupport.prediction(cycleLength: 28, cyclesObserved: 4)
        var wellbeing: [String: PeriodWellbeingSample] = [:]
        for entry in entries {
            let phase = CyclePhaseResolver.phase(on: entry.date, entries: entries, prediction: prediction, calendar: calendar)
            let sleep = phase == .luteal ? 0.3 : 0.9
            wellbeing[entry.dateKey] = PeriodWellbeingSample(sleep: sleep, mood: 0.7, exercise: 0.7, nutrition: 0.7)
        }
        return (entries, wellbeing)
    }
}
