// WorkoutAdjustmentOutcomeTests.swift
// FernletTests
//
// Pins "Adjust with AI" from the reply inward (the owner's fixes s1 and s2, 2026-11-10, review findings
// E5 and E6): the binding of a reply's numbers to real exercises, the reason given for every way an
// adjustment can change nothing — with the request kept in the field — and the plan an adjustment
// commits, built through the store with today's "Anything else?" honoured. The on-device model never
// runs in a test: the service is handed a double that answers with a made-up reply.

import Foundation
import Testing
import AIContext
@testable import FernletDomainModel
@testable import AIProviders
@testable import Fernlet

/// Serialized for the same reason as `GuidedPlanLifetimeTests`: each test stands up a real
/// `FernletStore`, which reaches process-global registries the directory seams do not cover.
@MainActor
@Suite(.serialized)
struct WorkoutAdjustmentOutcomeTests {

    // MARK: - Fixtures

    /// A thrown model error.
    struct ModelFailure: Error {}

    /// What the double saw, so a test can read the candidates the model would have been shown.
    final class Seen {
        var candidates: [[WorkoutAdjustmentCandidate]] = []
        var calls = 0
    }

    /// A split whose first day is one lifting session of five or more lifts for an advanced lifter at
    /// the full gym — what the refusal rule needs.
    private func fiveLiftSplitID() -> String {
        for split in WorkoutSplitCatalog.all {
            let plan = WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: WorkoutProfile(experience: .advanced),
                                              location: .fullGym, context: "", split: split, rotationIndex: 0)
            guard plan.sessions.count == 1, let session = plan.sessions.first, WorkoutPlanFinisher.isLifting(session) else { continue }
            if session.catalogExerciseNames.count >= 5 { return split.id }
        }
        return "full-body-3"
    }

    /// A store on a one-session-a-day split at the full gym, for an advanced lifter (so the day has
    /// five or more lifts), with AI switched on.
    private func makeStore() -> FernletStore {
        let store = makeTestStore()
        store.setSelectedSplit(fiveLiftSplitID())
        var profile = store.settings.workoutProfile
        profile.experience = .advanced
        store.setWorkoutProfile(profile)
        store.setWorkoutLocations([.fullGym, .home], activeID: WorkoutLocation.fullGym.id)
        store.settings.aiStatus = .ready
        return store
    }

    /// A planning service over `store` whose model is `reply`.
    private func service(
        _ store: FernletStore, seen: Seen = Seen(),
        reply: @escaping @MainActor ([WorkoutAdjustmentCandidate], [String]) throws -> WorkoutAdjustmentReply
    ) -> WorkoutPlanningService {
        let service = WorkoutPlanningService(host: store)
        service.adjuster = { _, candidates, lines, _ in
            seen.calls += 1
            seen.candidates.append(candidates)
            return try reply(candidates, lines)
        }
        return service
    }

    private func lifts(_ plan: WorkoutProgram.DayPlan) -> [PrescribedExercise] {
        plan.sessions.flatMap(\.exercises).filter { $0.block == .lifting && !WorkoutWarmUpSets.isWarmUpSet($0) }
    }

    /// The session's own lifts as a reply would name them.
    private func same(_ plan: WorkoutProgram.DayPlan) -> [PrescribedExercise] {
        lifts(plan).map { step in
            let isolation = WorkoutExerciseCatalog.exercise(named: step.name)?.movementPattern == .isolation
            return PrescribedExercise(name: step.name, sets: step.sets, reps: step.reps,
                                      role: isolation ? .accessory : .main, fromCatalog: true)
        }
    }

    private func reason(_ outcome: WorkoutAdjustmentOutcome) -> WorkoutAdjustmentOutcome.Reason? {
        if case .unchanged(let reason) = outcome { return reason }
        return nil
    }

    // MARK: - Binding a reply (the pure half of the model stage)

    /// The binding pass is reachable without FoundationModels: numbers bind to their candidates,
    /// unknown numbers and repeats are dropped, sets are clamped, blank reps defaulted, and an
    /// isolation move is accessory work.
    @Test func aReplyIsBoundToItsCandidates() throws {
        let squat = try #require(WorkoutExerciseCatalog.exercise(named: "Back squat"))
        let curl = try #require(WorkoutExerciseCatalog.exercise(named: "Cable curl"))
        let candidates = [WorkoutAdjustmentCandidate(id: 1, exercise: squat), WorkoutAdjustmentCandidate(id: 2, exercise: curl)]
        let picks = [
            WorkoutAdjustmentPick(candidateNumber: 2, sets: 9, reps: "  "),
            WorkoutAdjustmentPick(candidateNumber: 7, sets: 3, reps: "8"),
            WorkoutAdjustmentPick(candidateNumber: 1, sets: 0, reps: "5"),
            WorkoutAdjustmentPick(candidateNumber: 1, sets: 3, reps: "8"),
        ]
        let resolved = try #require(WorkoutAdjustmentCandidateBuilder.resolved(picks, candidates: candidates))
        #expect(resolved.map(\.name) == ["Cable curl", "Back squat"])
        #expect(resolved.map(\.sets) == [6, 1])
        #expect(resolved.map(\.reps) == ["8-12", "5"])
        #expect(resolved[0].role == .accessory && resolved[1].role == .main)
        #expect(resolved.allSatisfy { $0.fromCatalog && $0.holdSeconds == nil })
        #expect(WorkoutAdjustmentCandidateBuilder.resolved([], candidates: candidates) == nil)
        #expect(WorkoutAdjustmentCandidateBuilder.resolved([picks[1]], candidates: candidates) == nil, "nothing usable")
        let many = (0..<20).map { _ in WorkoutAdjustmentPick(candidateNumber: 1, sets: 3, reps: "8") }
        #expect(WorkoutAdjustmentCandidateBuilder.resolved(many, candidates: candidates)?.count == 1)
    }

    /// A call the gate did not dispatch says why: off and a device with no model read as off, a used-up
    /// budget as not now.
    @Test func aCallThatWasNotDispatchedSaysWhy() {
        #expect(FoundationWorkoutAdjustmentModel.reply(forFallback: .aiOff) == .aiOff)
        #expect(FoundationWorkoutAdjustmentModel.reply(forFallback: .deviceIncapable) == .aiOff)
        #expect(FoundationWorkoutAdjustmentModel.reply(forFallback: .resting) == .notNow)
        #expect(FoundationWorkoutAdjustmentModel.reply(forFallback: .sleepy) == .notNow)
        #expect(FoundationWorkoutAdjustmentModel.reply(forFallback: .allRungsExhausted) == .notNow)
    }

    // MARK: - Every reason, for its cause (s2)

    @Test func aiSwitchedOffSaysSoAndNeverCallsTheModel() async {
        let store = makeStore()
        store.settings.aiStatus = .off
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let seen = Seen()
        let outcome = await service(store, seen: seen) { _, _ in .notNow }.adjustWorkoutDayPlan(plan, request: "no barbell")
        #expect(reason(outcome) == .aiOff)
        #expect(seen.calls == 0)
    }

    @Test func noModelOnThisDeviceReadsAsOff() async {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let outcome = await service(store) { _, _ in .aiOff }.adjustWorkoutDayPlan(plan, request: "swap the squat")
        #expect(reason(outcome) == .aiOff)
    }

    @Test func aModelThatCannotAnswerSaysTryAgain() async {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let notNow = await service(store) { _, _ in .notNow }.adjustWorkoutDayPlan(plan, request: "swap the squat")
        #expect(reason(notNow) == .couldNot)
        let thrown = await service(store) { _, _ in throw ModelFailure() }.adjustWorkoutDayPlan(plan, request: "swap the squat")
        #expect(reason(thrown) == .couldNot)
    }

    @Test func aReplyThatAsksForTheSamePlanSaysNothingNeededChanging() async {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let answer = same(plan)
        let outcome = await service(store) { _, _ in .picks(answer) }.adjustWorkoutDayPlan(plan, request: "looks good")
        #expect(reason(outcome) == .nothingNeeded)
        let blank = await service(store) { _, _ in .picks(answer) }.adjustWorkoutDayPlan(plan, request: "   ")
        #expect(reason(blank) == .nothingNeeded)
    }

    /// One valid pick against a session of five lifts is refused: the outcome says so and the
    /// committed plan is exactly what it was.
    @Test func onePickAgainstAFiveLiftSessionIsRefusedAndThePlanIsUnchanged() async throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        try #require(lifts(plan).count >= 5, "the fixture needs a five-lift session, has \(lifts(plan).count)")
        let one = Array(same(plan).prefix(1))
        let outcome = await service(store) { _, _ in .picks(one) }.adjustWorkoutDayPlan(plan, request: "just one lift")
        #expect(reason(outcome) == .tooFewLifts)
        let committed = try #require(store.currentGuidedWorkoutPlan)
        #expect(committed.sessions.map(\.exercises) == plan.sessions.map(\.exercises))
        #expect(committed.sessions.map(\.suggestion.notes) == plan.sessions.map(\.suggestion.notes))
    }

    /// The one reason shown when sessions gave several, and a line for each.
    @Test func everyReasonHasItsOwnLine() {
        typealias Reason = WorkoutAdjustmentOutcome.Reason
        #expect(Reason.strongest(of: []) == .nothingNeeded)
        #expect(Reason.strongest(of: [.nothingNeeded, .couldNot]) == .couldNot)
        #expect(Reason.strongest(of: [.couldNot, .tooFewLifts, .aiOff]) == .tooFewLifts)
        #expect(Reason.strongest(of: [.aiOff, .nothingNeeded]) == .aiOff)
        #expect(Reason.aiOff.message == "On-device AI is off.")
        #expect(Reason.couldNot.message == "Couldn't adjust just now. Try again.")
        #expect(Reason.nothingNeeded.message == "Nothing needed changing.")
        #expect(Set(Reason.allCases.map(\.message)).count == Reason.allCases.count)
        #expect(Reason.allCases.allSatisfy { !$0.message.isEmpty })
    }

    /// The request stays in the field unless the plan changed.
    @Test func theRequestIsKeptUnlessThePlanChanged() async {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        for reason in WorkoutAdjustmentOutcome.Reason.allCases {
            let field = WorkoutAdjustField.after(.unchanged(reason), request: "no barbell today")
            #expect(field.request == "no barbell today")
            #expect(field.notice == reason)
        }
        let cleared = WorkoutAdjustField.after(.changed(plan), request: "no barbell today")
        #expect(cleared.request.isEmpty)
        #expect(cleared.notice == nil)
    }

    // MARK: - An adjustment that lands

    /// A reply that drops the last lift changes the plan: every session keeps its id (so completions
    /// stay valid), the note says it was adjusted, and the plan text is the steps'.
    @Test func aChangedPlanKeepsItsSessionIDsAndSaysItWasAdjusted() async throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let answer = Array(same(plan).dropLast())
        try #require(answer.count >= 3)
        let outcome = await service(store) { _, _ in .picks(answer) }.adjustWorkoutDayPlan(plan, request: "one fewer lift")
        guard case .changed(let adjusted) = outcome else {
            Issue.record("expected a changed plan, got \(outcome)")
            return
        }
        #expect(adjusted.sessions.map(\.id) == plan.sessions.map(\.id))
        #expect(Set(lifts(adjusted).map(\.name)) == Set(answer.map(\.name)))
        let session = try #require(adjusted.sessions.first)
        #expect(session.suggestion.notes.contains("Adjusted to your note."))
        #expect(session.suggestion.exercises == WorkoutSessionBlocks.planText(for: session.exercises))
        store.replaceGuidedWorkoutPlan(adjusted, replacing: Set(plan.sessions.map(\.id)))
        #expect(store.currentGuidedWorkoutPlan?.sessions.first?.suggestion.exercises == session.suggestion.exercises)
    }

    /// "No barbell" through the store: the model is never shown a barbell lift, and a reply that names
    /// barbell lifts anyway commits none.
    @Test func noBarbellThroughTheStoreCommitsNoBarbellLift() async throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let answer = same(plan)
        try #require(answer.contains { WorkoutExerciseCatalog.exercise(named: $0.name)?.equipment == .barbell })
        let seen = Seen()
        let outcome = await service(store, seen: seen) { _, _ in .picks(answer) }
            .adjustWorkoutDayPlan(plan, request: "no barbell today")
        let shown = seen.candidates.flatMap { $0 }.map(\.exercise)
        #expect(!shown.isEmpty)
        #expect(!shown.contains { $0.equipment == .barbell })
        guard case .changed(let adjusted) = outcome else {
            Issue.record("expected a changed plan, got \(outcome)")
            return
        }
        for step in lifts(adjusted) {
            let exercise = try #require(WorkoutExerciseCatalog.exercise(named: step.name))
            #expect(exercise.equipment != .barbell, "\(step.name) is a barbell lift")
        }
    }

    /// Today's "Anything else?" is honoured by an adjustment: with "sore left knee" on the committed
    /// plan the model is not shown the lifts a knee eased for today leaves out, and a knee lift the
    /// reply brings in as a heavy main lift is committed as eased accessory work.
    @Test func anAdjustmentHonoursTodaysAnythingElse() async throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate, context: "sore left knee")
        let today = WorkoutDayNote.Applied(context: "sore left knee", saved: store.settings.workoutProfile.injuryLimits,
                                           options: store.settings.workoutSessionOptions, mayShorten: true).limits
        try #require(today.mildAreas.contains(.knee))
        let seen = Seen()
        var answer = Array(same(plan).dropLast())
        let outcome = await service(store, seen: seen) { candidates, _ in
            if let knee = candidates.map(\.exercise).first(where: { exercise in
                today.eases(exercise) && exercise.movementPattern != .isolation && exercise.measure == .reps
                    && !answer.contains { $0.name == exercise.name }
            }) {
                answer.insert(PrescribedExercise(name: knee.name, sets: 6, reps: "5", role: .main, fromCatalog: true), at: 0)
            }
            return .picks(answer)
        }.adjustWorkoutDayPlan(plan, request: "more leg work")
        let shown = seen.candidates.flatMap { $0 }.map(\.exercise)
        #expect(!shown.contains { $0.name == "Back squat" }, "a knee eased for today leaves the barbell squat out")
        #expect(shown.allSatisfy(today.allows))
        guard case .changed(let adjusted) = outcome else {
            Issue.record("expected a changed plan, got \(outcome)")
            return
        }
        let style = WorkoutGoalStyle.style(for: store.settings.selectedGoal, energy: .moderate, sport: "")
        var kneeLifts = 0
        for step in adjusted.sessions.flatMap(\.exercises) where step.block == .lifting {
            guard let exercise = WorkoutExerciseCatalog.exercise(named: step.name), today.eases(exercise) else { continue }
            kneeLifts += 1
            #expect(step.role != .main, "\(step.name) loads the knee and is a main lift")
            #expect(!WorkoutWarmUpSets.isWarmUpSet(step))
        }
        #expect(kneeLifts > 0)
        let brought = try #require(lifts(adjusted).first { $0.name == answer[0].name })
        #expect(brought.reps == style.reps(for: .accessory), "not the reply's 5 reps")
        #expect(brought.sets < 6)
    }

    /// The plan editor's save goes through the same pass: a timed move added by hand with only its text
    /// is saved with a real countdown, and the store's plan carries it.
    @Test func aHandEditGoesThroughThePassOnItsWayToTheStore() throws {
        let store = makeStore()
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let session = try #require(plan.sessions.first)
        let taken = Set(session.exercises.map(\.name))
        let hold = try #require(WorkoutExerciseCatalog.baseExercises.first { exercise in
            exercise.measure == .seconds && exercise.modality == .strength && !taken.contains(exercise.name)
                && WorkoutSafetyFilter.feasible(exercise, location: .fullGym, limits: .empty)
        })
        var edited = session
        edited.exercises.insert(
            PrescribedExercise(name: hold.name, sets: 2, reps: "40 sec", role: .accessory, fromCatalog: true),
            at: edited.exercises.lastIndex { $0.block == .lifting }.map { $0 + 1 } ?? 0
        )
        let finished = store.finishedGuidedSession(edited, previous: session)
        let step = try #require(finished.exercises.first { $0.name == hold.name })
        #expect(step.holdSeconds == 40)
        #expect(step.reps == "40 s")
        #expect(finished.id == session.id)
        #expect(store.updateGuidedSession(finished))
        #expect(store.currentGuidedWorkoutPlan?.sessions.first?.suggestion.exercises.contains("\(hold.name) - 2 x 40 s") == true)
    }
}
