import Testing
import Foundation
import FernletDomainModel
@testable import Fernlet

@MainActor
struct PeriodAwareScoringTests {
    private let weights = GoalWeights.forGoal(.wellness)

    private func breakdown(_ adjustment: PeriodScoringAdjustment) -> ScoreBreakdown {
        FernletScoring.computeBreakdown(
            journalTag: .good,
            mealCount: 2,
            workoutCount: 1,
            sleepQuality: .good,
            bottleCount: 2,
            hydrationTarget: 4,
            hygiene: [],
            weights: weights,
            periodAdjustment: adjustment
        )
    }

    // MARK: Backward compatibility

    @Test func computeBreakdownIsByteIdenticalWithoutPeriodAdjustment() {
        let withoutArg = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
            bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights
        )
        let explicitNone = breakdown(.none)
        #expect(withoutArg == explicitNone)
    }

    @Test func sicknessHydrationMultiplierUnchangedWithNonePeriod() {
        // The `.none` period path must not perturb the existing sickness ×1.2 hydration target.
        let sick = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
            bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights, isSick: true
        )
        let sickWithNone = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
            bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights, isSick: true,
            periodAdjustment: .none
        )
        #expect(sick == sickWithNone)
    }

    // MARK: Weight transform

    @Test func adjustedForPeriodIsIdentityForNone() {
        #expect(weights.adjustedForPeriod(.none) == weights)
    }

    @Test func adjustedForPeriodShiftsWorkoutAndPreservesTotal() {
        let lenient = weights.adjustedForPeriod(.suggested)
        #expect(lenient.workoutWeight < weights.workoutWeight)
        #expect(lenient.sleepWeight > weights.sleepWeight)
        #expect(lenient.hydrationWeight > weights.hydrationWeight)
        #expect(abs(lenient.total - 1.0) < 0.000_001)
    }

    // MARK: Softening behaviour

    @Test func hydrationReliefMakesHydrationMoreForgiving() {
        let base = breakdown(.none)
        let relieved = breakdown(PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .suggested, leniency: .none))
        // Same 2 bottles against a relaxed target (4 → 3) → a higher hydration component.
        #expect(relieved.components["hydration"]! > base.components["hydration"]!)
    }

    @Test func leniencyIsReflectedInAppliedWeights() {
        let lenient = breakdown(PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .none, leniency: .suggested))
        #expect(lenient.appliedWeights.workoutWeight < weights.workoutWeight)
        #expect(abs(lenient.appliedWeights.total - 1.0) < 0.000_001)
    }

    // MARK: Store opt-in gating

    @Test func storePeriodAdjustmentRespectsOptIn() {
        let store = makeTestStore()
        let adjustment = PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .suggested, leniency: .suggested)
        store.attachPeriodScoringContext(StubPeriodContext(adjustment))

        // Default: opted out → no adjustment even though a bridge is attached.
        #expect(store.periodAdjustment(for: "2026-06-20") == .none)

        store.setPeriodAwareScoringEnabled(true)
        #expect(store.periodAdjustment(for: "2026-06-20") == adjustment)
    }

    @Test func dailyHealthScoreRecordsPhaseLabelOnlyWhenOptedIn() {
        let optedOut = makeTestStore()
        optedOut.attachPeriodScoringContext(StubPeriodContext(PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .none, leniency: .none)))
        let outScore = optedOut.dailyHealthScore(for: "2026-06-21", day: FernletDay(date: "2026-06-21"))
        #expect(outScore.periodPhase == nil)

        let optedIn = makeTestStore()
        optedIn.attachPeriodScoringContext(StubPeriodContext(PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .none, leniency: .none)))
        optedIn.setPeriodAwareScoringEnabled(true)
        let inScore = optedIn.dailyHealthScore(for: "2026-06-22", day: FernletDay(date: "2026-06-22"))
        #expect(inScore.periodPhase == "luteal")
    }

    @Test func periodPhaseLabelIsStrippedFromTheSyncedSnapshot() {
        let store = makeTestStore()
        store.attachPeriodScoringContext(StubPeriodContext(PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .none, leniency: .none)))
        store.setPeriodAwareScoringEnabled(true)
        store.storeDaySummary("a calm day", for: "2026-06-23")
        // The in-memory record carries the coarse phase label for device-only audit…
        #expect(store.dailyScores.contains { $0.periodPhase == "luteal" })
        // …but the copy that gets persisted/synced to CloudKit never carries cycle-derived metadata.
        #expect(store.storedDailyScores.allSatisfy { $0.periodPhase == nil })
    }

    @Test func storeScoringIsUnchangedWhenOptedOut() {
        // A fully-populated day scored with a bridge attached but opt-out must equal the no-bridge score.
        let withBridge = makePopulatedTestStore()
        withBridge.attachPeriodScoringContext(StubPeriodContext(PeriodScoringAdjustment(phase: .luteal, hydrationRelief: .suggested, leniency: .suggested)))
        let plain = makePopulatedTestStore()
        #expect(withBridge.scoreBreakdown(for: withBridge.day) == plain.scoreBreakdown(for: plain.day))
    }
}
