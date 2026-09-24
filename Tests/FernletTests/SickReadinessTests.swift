import Foundation
import Testing
import FernletDomainModel
import LocalPersistence
import StoreCore
@testable import Fernlet

/// Marking today unwell forces readiness to `needs rest` (spec §6a: "Sickness always forces
/// `needs rest`"; owner, 2026-09-23: "That should be updated").
///
/// Before this, the readiness signal never saw the sickness flag. A user who tapped "I'm unwell
/// today" on Home after a good night and two meals was told "The signals suggest room to push today
/// if you want to.", and the Move tab recommended — and would commit — a hard session.
@MainActor
struct SickReadinessTests {

    // MARK: - Fixture

    /// A day whose signals read "ready for hard": a great, full night and two meals, nothing hard
    /// lately. The only day in a fresh store, so every trend other than readiness is still
    /// "insufficient data" and readiness is the signal Home's ambient line is chosen by.
    private func readyForHardStore() -> FernletStore {
        let store = makeTestStore()
        store.setSleep(hours: 8, quality: .great, note: "")
        store.addMeal(from: "oatmeal with berries")
        store.addMeal(from: "chicken and rice bowl")
        store.flushPendingSnapshotSave()
        return store
    }

    private func readiness(_ store: FernletStore) -> String? {
        store.derivedSignals.first { $0.signalName == "intensityReadiness" }?.value
    }

    // MARK: - The signal

    @Test func theFixtureReadsReadyForHard() {
        #expect(readiness(readyForHardStore()) == "ready for hard", "fixture drifted — the tests below prove nothing")
    }

    @Test func markingTodayUnwellForcesNeedsRestAtOnce() {
        let store = readyForHardStore()
        store.setSick(true, on: store.todayKey)
        // No save flush: the Home row's tap must change what Home says in the same frame, not one
        // debounced second later.
        #expect(readiness(store) == "needs rest")
    }

    @Test func needsRestSurvivesTheNextSaveRebuild() {
        let store = readyForHardStore()
        store.setSick(true, on: store.todayKey)
        store.flushPendingSnapshotSave()
        #expect(readiness(store) == "needs rest", "the post-save rebuild dropped the sickness flag")
    }

    @Test func unmarkingRestoresTheBehaviouralReadiness() {
        let store = readyForHardStore()
        store.setSick(true, on: store.todayKey)
        store.setSick(false, on: store.todayKey)
        #expect(readiness(store) == "ready for hard")
    }

    // MARK: - What Move and Home do with it

    @Test func anUnwellDayRecommendsTheGentlestIntensity() {
        let store = readyForHardStore()
        #expect(store.recommendedWorkoutIntensity() == .hard, "fixture drifted")
        store.setSick(true, on: store.todayKey)
        // Never nil: the Move root commits `recommendedWorkoutIntensity() ?? .moderate`, so nil on a
        // rest day would build a moderate session.
        #expect(store.recommendedWorkoutIntensity() == .light)
    }

    @Test func homeNeverSaysPushOnAnUnwellDay() {
        let store = readyForHardStore()
        store.setSick(true, on: store.todayKey)
        let line = HomeView.signalThought(for: store.derivedSignals) ?? ""
        #expect(!line.localizedCaseInsensitiveContains("push"), "Home told an unwell user: \(line)")
        #expect(line.localizedCaseInsensitiveContains("rest"), "Home's line on an unwell day: \(line)")
    }

    @Test func moveBuildsNoStrengthWorkOnAnUnwellDay() {
        let store = readyForHardStore()
        store.setSick(true, on: store.todayKey)
        let plan = store.previewTodaysGuidedWorkoutPlan(intensity: store.recommendedWorkoutIntensity() ?? .moderate)
        #expect(GuidedWorkoutAvailability.firstGuidable(in: plan, excluding: []) == nil, "an unwell day got a guided session")
        #expect(plan.sessions.allSatisfy { $0.catalogExerciseNames.isEmpty }, "an unwell day got catalog strength work")
    }

    @Test func needsRestTodayFollowsTheUnwellFlag() {
        let store = readyForHardStore()
        #expect(!store.needsRestToday)
        store.setSick(true, on: store.todayKey)
        #expect(store.needsRestToday)
        store.setSick(false, on: store.todayKey)
        #expect(!store.needsRestToday)
    }

    // MARK: - The factory

    private static let dayKey = "2026-09-23"

    /// The readiness record for one empty day. (No default-argument day: a default argument is
    /// evaluated nonisolated, and `dayKey` is main-actor isolated — swift5-mainactor-default-args.)
    private func readinessRecord(isSickToday: Bool) -> DerivedSignalRecord? {
        DerivedSignalFactory.makeSignals(from: [(Self.dayKey, FernletDay(date: Self.dayKey))], todayKey: Self.dayKey, isSickToday: isSickToday)
            .first { $0.signalName == "intensityReadiness" }
    }

    @Test func sicknessForcesNeedsRestEvenWithNothingLogged() {
        let record = readinessRecord(isSickToday: true)
        #expect(record?.value == "needs rest", "an unwell day with no logs read \(record?.value ?? "nil")")
        // Provenance: the flag alone decided it, so the Trends row must not credit workouts or sleep.
        #expect(record?.sourceFields == ["sickness"])
    }

    @Test func sicknessTouchesReadinessOnly() {
        let healthy = DerivedSignalFactory.makeSignals(from: [(Self.dayKey, FernletDay(date: Self.dayKey))], todayKey: Self.dayKey)
        let unwell = DerivedSignalFactory.makeSignals(from: [(Self.dayKey, FernletDay(date: Self.dayKey))], todayKey: Self.dayKey, isSickToday: true)
        #expect(healthy.map(\.signalName) == unwell.map(\.signalName))
        for (before, after) in zip(healthy, unwell) where before.signalName != "intensityReadiness" {
            #expect(before.value == after.value, "\(before.signalName) changed with the unwell flag")
        }
    }

    @Test func theDefaultIsTheBehaviouralReadiness() {
        #expect(readinessRecord(isSickToday: false)?.value == "insufficient data")
        #expect(DerivedSignalsRebuilder.rebuild(allDays: [Self.dayKey: FernletDay(date: Self.dayKey)], todayKey: Self.dayKey)
            .first { $0.signalName == "intensityReadiness" }?.value == "insufficient data")
    }

    @Test func theRebuilderForwardsTheFlag() {
        let signals = DerivedSignalsRebuilder.rebuild(
            allDays: [Self.dayKey: FernletDay(date: Self.dayKey)], todayKey: Self.dayKey, isSickToday: true
        )
        #expect(signals.first { $0.signalName == "intensityReadiness" }?.value == "needs rest")
    }

    // MARK: - Home's copy

    private func signal(_ name: String, _ value: String) -> DerivedSignalRecord {
        DerivedSignalRecord(signalName: name, value: value, windowStart: Self.dayKey, windowEnd: Self.dayKey, sourceFields: [])
    }

    @Test func restOutranksEveryOtherHomeLine() {
        let signals = [
            signal("moodTrend", "improving"),
            signal("energyTrend", "rising"),
            signal("intensityReadiness", "needs rest")
        ]
        #expect(HomeView.signalThought(for: signals) == SignalPresentation.restDayThought)
        #expect(LaunchPreparationService.deterministicThought(for: signals) == SignalPresentation.restDayThought)
    }

    @Test func theRestLineNeverPushes() {
        let line = SignalPresentation.restDayThought
        #expect(line.localizedCaseInsensitiveContains("rest"))
        for word in ["push", "hard", "workout", "train"] {
            #expect(!line.localizedCaseInsensitiveContains(word), "the rest line says \"\(word)\": \(line)")
        }
    }

    @Test func theCompanionPromptSeesRestFirst() {
        let signals = [
            signal("moodTrend", "improving"),
            signal("energyTrend", "rising"),
            signal("eatingPattern", "consistent"),
            signal("progressionTrend", "insufficient data"),
            signal("intensityReadiness", "needs rest")
        ]
        let prompt = LaunchPreparationService.thoughtPromptSignals(signals)
        #expect(prompt.count == 3)
        #expect(prompt.first?.value == "needs rest", "the model would not have been told the user is unwell")
        #expect(!prompt.contains { $0.value == "insufficient data" })
    }

    @Test func theCompanionPromptIsUnchangedOnAnOrdinaryDay() {
        let signals = [
            signal("moodTrend", "insufficient data"),
            signal("energyTrend", "rising"),
            signal("eatingPattern", "consistent"),
            signal("progressionTrend", "steady"),
            signal("intensityReadiness", "ready for hard")
        ]
        #expect(LaunchPreparationService.thoughtPromptSignals(signals).map(\.signalName)
            == ["energyTrend", "eatingPattern", "progressionTrend"])
    }

    // MARK: - Trends

    @Test func theTokenHasItsOwnDisplayLabel() {
        let label = SignalPresentation.valueLabel(for: "needs rest")
        #expect(!label.isEmpty)
        #expect(label != "needs rest", "the display label must be its own string, not the frozen token")
        #expect(SignalPresentation.valueLabel(for: "ready for hard") == "Ready For Hard", "other tokens keep their rendering")
        #expect(SignalPresentation.strength(for: "needs rest") == 1)
        #expect(SignalPresentation.sourceLabel(for: "sickness") != "sickness")
        let explanation = SignalPresentation.explanation(for: signal("intensityReadiness", "needs rest"))
        #expect(explanation.localizedCaseInsensitiveContains("unwell"))
    }

    // MARK: - Move's copy and plan

    @Test func aRestDayOffersTheGentlestChipOnly() {
        #expect(WorkoutSuggestionSheet.offeredIntensities(needsRest: true) == [.light])
        #expect(WorkoutSuggestionSheet.offeredIntensities(needsRest: false) == Array(WorkoutIntensity.allCases))
    }

    @Test func moveRestDayCopyNeverPushes() {
        for resource in MoveRestDayCopy.all {
            let line = String(localized: resource)
            #expect(!line.isEmpty)
            for word in ["push", "hard", "intense", "workout"] {
                #expect(!line.localizedCaseInsensitiveContains(word), "Move's rest-day copy says \"\(word)\": \(line)")
            }
        }
    }

    @Test func theRestDayPlanIsOneGentleUnguidedLine() {
        let plan = WorkoutPlanningService.restDayPlan(locationName: "Home")
        #expect(plan.sessions.count == 1)
        let session = plan.sessions[0]
        #expect(session.kind == .mobility)
        #expect(!GuidedWorkoutAvailability.isGuidable(session))
        #expect(session.catalogExerciseNames.isEmpty)
        // "Already did this — log it" records a light, 10-minute movement row.
        let logged = session.workout(intensity: .light)
        #expect(logged.intensity == .light)
        #expect(logged.duration == 10)
        // Approved, it settles the root card on the gentle "easy movement" state — never "Start".
        guard case .noneToGuide = GuidedWorkoutCardState.resolve(plan: plan, completed: []) else {
            Issue.record("a rest-day plan resolved to a startable card")
            return
        }
    }
}
