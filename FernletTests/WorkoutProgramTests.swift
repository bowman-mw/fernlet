import Foundation
import Testing
import ActivityKit
import FernletDomainModel
import AIProviders
@testable import Fernlet

@MainActor
struct WorkoutProgramTests {
    /// The built-in locations are computed properties, so every access builds a fresh value. With a
    /// `UUID()` default that meant a new identity each read — and `settings.activeWorkoutLocation` falls
    /// back to `.fullGym`, so two reads of the same property could disagree about which location is
    /// active and an `activeID` captured from one read matched nothing on the next.
    @Test func builtInLocationIDsAreStableAcrossAccesses() {
        #expect(WorkoutLocation.fullGym.id == WorkoutLocation.fullGym.id)
        #expect(WorkoutLocation.home.id == WorkoutLocation.home.id)
        #expect(WorkoutLocation.fullGym.id != WorkoutLocation.home.id)
    }

    /// Templates must NOT inherit a built-in's fixed id, or adding a "Full gym" template alongside the
    /// default would produce two locations sharing an id — an Identifiable collision in the ForEach and
    /// an ambiguous `first(where:)` when resolving the active location.
    @Test func templateLocationsGetFreshIDsDistinctFromTheBuiltIns() {
        let ids = LocationTemplate.all.map { $0.makeLocation().id }
        #expect(Set(ids).count == ids.count, "two templates minted the same id")
        #expect(!ids.contains(WorkoutLocation.fullGym.id))
        #expect(LocationTemplate.all.first!.makeLocation().id != LocationTemplate.all.first!.makeLocation().id)
    }

    /// The active location must survive a round-trip through the settings default. Guards the fallback
    /// at `activeWorkoutLocation`'s `?? .fullGym`.
    @Test func defaultActiveLocationResolvesToAStableID() {
        let settings = FernletSettings()
        #expect(settings.activeWorkoutLocation.id == settings.activeWorkoutLocation.id)
        #expect(settings.workoutLocations.contains { $0.id == settings.activeWorkoutLocation.id })
    }

    /// The delete-confirm copy must agree in number and never read "the 0/1 pieces".
    @Test func deleteConfirmCopyPluralizesAndHandlesZero() {
        #expect(WorkoutLocationSetupView.deleteMessage(equipmentCount: 0) == "This deletes the location and its equipment setup. Your logged workouts are not affected.")
        #expect(WorkoutLocationSetupView.deleteMessage(equipmentCount: 1).contains("the 1 piece of equipment"))
        #expect(!WorkoutLocationSetupView.deleteMessage(equipmentCount: 1).contains("1 pieces"))
        #expect(WorkoutLocationSetupView.deleteMessage(equipmentCount: 5).contains("the 5 pieces of equipment"))
    }

    @Test func catalogDecodesWithEquipmentVariety() {
        let catalog = WorkoutExerciseCatalog.baseExercises
        #expect(catalog.count >= 80)
        #expect(catalog.contains { $0.equipment == .band })
        #expect(catalog.filter { $0.equipment == .bodyweight }.count >= 15)
        for pattern in [MovementPattern.squat, .hinge, .lunge, .push, .pull] {
            let bodyweightOption = catalog.contains {
                $0.movementPattern == pattern && WorkoutLocation.alwaysAvailable.contains($0.equipment)
            }
            #expect(bodyweightOption, "no bodyweight option for \(pattern)")
        }
    }

    @Test func fullGymProducesCompleteWorkout() {
        let profile = WorkoutProfile(trainingDaysPerWeek: 3, experience: .intermediate)
        let plan = WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: profile,
            location: .fullGym, context: "", split: WorkoutSplitCatalog.fullBody3, rotationIndex: 0
        )
        #expect(plan.droppedSlots.isEmpty)
        #expect(plan.sessions.count == 1)
        #expect(plan.sessions[0].suggestion.exercises.split(separator: "\n").count >= 4)
    }

    @Test func bodyweightOnlyLocationStillProducesWorkout() {
        let park = WorkoutLocation(name: "Park", ownedEquipment: [])
        let profile = WorkoutProfile(trainingDaysPerWeek: 3, experience: .beginner)
        let plan = WorkoutProgram.dayPlan(
            goal: .wellness, intensity: .moderate, profile: profile,
            location: park, context: "", split: WorkoutSplitCatalog.fullBody3, rotationIndex: 0
        )
        #expect(plan.sessions.isEmpty == false)
        #expect(plan.sessions[0].suggestion.exercises.isEmpty == false)
        #expect(plan.sessions[0].suggestion.exercises.split(separator: "\n").count >= 3)
    }

    @Test func multiSessionDayProducesSeparateSessions() {
        // Cardio + Strength prescribes a morning cardio and an evening lift on every day.
        let plan = WorkoutProgram.dayPlan(
            goal: .weightManagement, intensity: .moderate, profile: WorkoutProfile(),
            location: .fullGym, context: "", split: WorkoutSplitCatalog.cardioStrength4, rotationIndex: 0
        )
        #expect(plan.sessions.count == 2)
        #expect(plan.sessions.contains { $0.kind == .cardio })
        #expect(plan.sessions.contains { $0.kind == .strength })
    }

    @Test func safetyFilterExcludesInjuredAreasAndMovements() {
        let profile = WorkoutProfile(
            avoidedMuscles: [.frontDelts, .sideDelts, .rearDelts],
            avoidedMovements: [.push]
        )
        let feasible = WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.baseExercises, location: .fullGym, profile: profile
        )
        #expect(feasible.allSatisfy { $0.movementPattern != .push })
        #expect(feasible.allSatisfy {
            $0.primaryMuscles.union($0.secondaryMuscles).isDisjoint(with: [.frontDelts, .sideDelts, .rearDelts])
        })
    }

    @Test func equipmentFilterHonorsLocation() {
        let park = WorkoutLocation(name: "Park", ownedEquipment: [])
        let feasible = WorkoutSafetyFilter.feasibleExercises(
            in: WorkoutExerciseCatalog.baseExercises, location: park, profile: WorkoutProfile()
        )
        #expect(feasible.isEmpty == false)
        #expect(feasible.allSatisfy { WorkoutLocation.alwaysAvailable.contains($0.equipment) })
    }

    @Test func onboardingTextBecomesStructuredProfile() {
        let profile = WorkoutProfile.fromOnboarding(
            level: "intermediate",
            interests: "running, kettlebells, mobility",
            constraints: "shoulder issues, only dumbbells"
        )
        #expect(profile.experience == .intermediate)
        #expect(profile.interests == ["running", "kettlebells", "mobility"])
        // "shoulder issues" → avoid the delts and pressing, and keep the raw note.
        #expect(profile.avoidedMuscles.contains(.frontDelts))
        #expect(profile.avoidedMovements.contains(.push))
        #expect(profile.injuryNotes == "shoulder issues, only dumbbells")
    }

    @Test func recommenderSpecificityScalesWithReadiness() {
        #expect(WorkoutSplitRecommender.desiredSpecificity(experience: .beginner, consistency: .low, activity: .sedentary) == .minimal)
        #expect(WorkoutSplitRecommender.desiredSpecificity(experience: .advanced, consistency: .high, activity: .veryActive) == .specialized)
    }

    /// Regression for prior finding #15: equal-scoring splits must order deterministically by id
    /// (Array.sorted(by:) is not guaranteed stable). `full-body-3` and `upper-lower-full-3` are
    /// both balanced / 3-day / 3-session and both fit wellness & weightManagement, so they always
    /// tie — the result must place `full-body-3` before `upper-lower-full-3` every run.
    @Test func recommenderBreaksScoreTiesDeterministicallyByID() {
        for goal in [GoalType.wellness, .weightManagement] {
            let ids = WorkoutSplitRecommender.ranked(
                goal: goal, experience: .intermediate, consistency: .medium,
                activity: .moderate, preferredDays: 3
            ).map(\.id)
            let fullBody = ids.firstIndex(of: "full-body-3")
            let upperLowerFull = ids.firstIndex(of: "upper-lower-full-3")
            #expect(fullBody != nil && upperLowerFull != nil)
            if let fullBody, let upperLowerFull {
                #expect(fullBody < upperLowerFull, "tie must resolve by ascending id for goal \(goal)")
            }
        }
    }

    @Test func granularEquipmentMapsToEngineCapabilities() {
        // 22 items across 5 categories.
        #expect(GymEquipment.allCases.count == 22)
        for category in EquipmentCategory.allCases {
            #expect(GymEquipment.allCases.contains { $0.category == category })
        }
        // A dumbbells-only location unlocks dumbbell work (and always-available bodyweight), not barbell.
        let dumbbellOnly = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells])
        #expect(dumbbellOnly.has(.dumbbell))
        #expect(dumbbellOnly.has(.bodyweight))
        #expect(dumbbellOnly.has(.barbell) == false)
        // Full gym covers every coarse capability the catalog can require.
        let fullCaps = WorkoutLocation.fullGym.capabilities
        for capability in Equipment.allCases {
            #expect(fullCaps.contains(capability), "full gym missing \(capability)")
        }
    }

    @Test func progressionClimbsRepsThenBumpsSets() {
        // Base shows the full range; each completion climbs reps, then resets a cycle later.
        #expect(WorkoutProgram.progressedPrescription(baseSets: 3, baseReps: "8-12", completions: 0).reps == "8-12")
        #expect(WorkoutProgram.progressedPrescription(baseSets: 3, baseReps: "8-12", completions: 1).reps == "9")
        #expect(WorkoutProgram.progressedPrescription(baseSets: 3, baseReps: "8-12", completions: 4).reps == "12")
        // After two full rep cycles the set count bumps by one and reps reset to the bottom.
        let deep = WorkoutProgram.progressedPrescription(baseSets: 3, baseReps: "8-12", completions: 10)
        #expect(deep.reps == "8")
        #expect(deep.sets == 4)
        // Fixed-rep lifts progress by adding a set every few completions.
        #expect(WorkoutProgram.progressedPrescription(baseSets: 4, baseReps: "5", completions: 3).sets == 5)
        #expect(WorkoutProgram.progressedPrescription(baseSets: 4, baseReps: "5", completions: 0) == (4, "5"))
    }

    @Test func adjustmentCandidatesAreConstrainedAndCapped() {
        let candidates = WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: ["Back squat"], request: "no barbell, easier on knees",
            location: .fullGym, profile: WorkoutProfile()
        )
        #expect(candidates.isEmpty == false)
        #expect(candidates.count <= 28)
        #expect(Set(candidates.map(\.id)).count == candidates.count) // unique ids
        #expect(candidates.map(\.id) == Array(1...candidates.count))  // numbered 1...n

        // At a bodyweight-only location every candidate must be bodyweight/none equipment.
        let park = WorkoutLocation(name: "Park", ownedEquipment: [])
        let parkCandidates = WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: [], request: "full body", location: park, profile: WorkoutProfile()
        )
        #expect(parkCandidates.isEmpty == false)
        #expect(parkCandidates.allSatisfy { WorkoutLocation.alwaysAvailable.contains($0.exercise.equipment) })
    }

    @Test func recommenderPrefersGoalFit() {
        let ranked = WorkoutSplitRecommender.ranked(
            goal: .strength, experience: .advanced, consistency: .high, activity: .veryActive, preferredDays: 6
        )
        #expect(ranked.isEmpty == false)
        #expect(ranked.first?.goalFit.contains(.strength) == true)
        // A very-ready strength user should be offered something more specific than full-body.
        #expect((ranked.first?.specificity.rawValue ?? 0) >= SplitSpecificity.focused.rawValue)
    }

    // MARK: - Guided-session runner (WorkoutSessionRunner)

    private func ex(_ name: String, sets: Int, role: SlotRole = .main, reps: String = "5", fromCatalog: Bool = true) -> PrescribedExercise {
        PrescribedExercise(name: name, sets: sets, reps: reps, role: role, fromCatalog: fromCatalog)
    }

    /// A fixed clock + fixed rest so rest transitions are asserted without wall-clock flakiness.
    private func makeRunner(_ exercises: [PrescribedExercise], goal: GoalType = .strength, restSeconds: Int = 90) -> WorkoutSessionRunner {
        WorkoutSessionRunner(
            exercises: exercises,
            goal: goal,
            now: { Date(timeIntervalSince1970: 1_000) },
            restProvider: { _, _ in restSeconds }
        )
    }

    @Test func runnerStartsIntoWorkingOnFirstSet() {
        let runner = makeRunner([ex("Squat", sets: 3)])
        #expect(runner.phase == .ready)
        runner.start()
        #expect(runner.phase == .working)
        #expect(runner.exerciseIndex == 0)
        #expect(runner.currentSet == 1)
        #expect(runner.completedNaturally == false)
    }

    @Test func runnerWithNoExercisesGoesStraightToDoneWithoutCompletion() {
        let runner = makeRunner([])
        runner.start()
        #expect(runner.phase == .done)
        // Nothing to log: an empty session must not count as a completed workout.
        #expect(runner.completedNaturally == false)
    }

    @Test func completeSetAdvancesSetThenRests() {
        let runner = makeRunner([ex("Squat", sets: 3)], restSeconds: 90)
        runner.start()
        runner.completeSet()
        #expect(runner.phase == .resting)
        #expect(runner.currentSet == 2)                // counter points at the upcoming set
        #expect(runner.restDuration == 90)
        #expect(runner.restEndsAt == Date(timeIntervalSince1970: 1_090))  // fixed now + rest
    }

    @Test func lastSetOfAnExerciseAdvancesToNextExerciseWorkingNoRest() {
        let runner = makeRunner([ex("Squat", sets: 2), ex("Bench", sets: 2)])
        runner.start()
        runner.completeSet()   // ex0 set1 done → rest, currentSet 2
        runner.skipRest()      // → working ex0 set2
        #expect(runner.exerciseIndex == 0)
        #expect(runner.currentSet == 2)
        runner.completeSet()   // last set of ex0 → next exercise, straight to working
        #expect(runner.phase == .working)
        #expect(runner.exerciseIndex == 1)
        #expect(runner.currentSet == 1)
        #expect(runner.restEndsAt == nil)
    }

    @Test func lastSetOfLastExerciseFinishesAndMarksCompleted() {
        let runner = makeRunner([ex("Squat", sets: 1)])
        runner.start()
        runner.completeSet()
        #expect(runner.phase == .done)
        #expect(runner.completedNaturally == true)
    }

    @Test func skipRestResumesWorkingAndClearsTimer() {
        let runner = makeRunner([ex("Squat", sets: 3)])
        runner.start()
        runner.completeSet()          // → resting on set 2
        #expect(runner.phase == .resting)
        runner.skipRest()
        #expect(runner.phase == .working)
        #expect(runner.currentSet == 2)
        #expect(runner.restEndsAt == nil)
    }

    @Test func endAbortsWithoutMarkingCompleted() {
        let runner = makeRunner([ex("Squat", sets: 3)])
        runner.start()
        runner.completeSet()          // mid-session, resting
        runner.end()
        #expect(runner.phase == .done)
        #expect(runner.completedNaturally == false)   // aborted → nothing to log
    }

    @Test func restWindowIsAFixedValidRangeSetOnlyWhileResting() throws {
        let runner = makeRunner([ex("Squat", sets: 2), ex("Bench", sets: 1)], restSeconds: 90)
        #expect(runner.restStartedAt == nil)
        #expect(runner.restEndsAt == nil)
        runner.start()
        #expect(runner.restStartedAt == nil)
        #expect(runner.restEndsAt == nil)

        runner.completeSet()          // → resting before set 2
        let started = try #require(runner.restStartedAt)
        let ends = try #require(runner.restEndsAt)
        // The sheet renders `Text(timerInterval: started...ends)` — a fixed window. It must be a
        // valid (non-inverted) range or the range literal traps, however long the user over-rests.
        #expect(started <= ends)
        #expect(ends.timeIntervalSince(started) == 90)

        runner.skipRest()             // leaving .resting clears both halves together
        #expect(runner.restStartedAt == nil)
        #expect(runner.restEndsAt == nil)

        runner.completeSet()          // last set of Squat → straight to Bench, no rest window
        #expect(runner.phase == .working)
        #expect(runner.restStartedAt == nil)
        #expect(runner.restEndsAt == nil)

        runner.completeSet()          // finish Bench → done, still no rest window
        #expect(runner.phase == .done)
        #expect(runner.restStartedAt == nil)
        #expect(runner.restEndsAt == nil)
    }

    @Test func zeroLengthRestStillFormsAValidWindow() throws {
        let runner = makeRunner([ex("Squat", sets: 2)], restSeconds: 0)
        runner.start()
        runner.completeSet()
        let started = try #require(runner.restStartedAt)
        let ends = try #require(runner.restEndsAt)
        #expect(started <= ends)      // degenerate but valid: started...started
    }

    @Test func consumeCompletionReportsExactlyOnce() {
        let runner = makeRunner([ex("Squat", sets: 1)])
        runner.start()
        #expect(runner.consumeCompletion() == false)   // mid-session: nothing to report yet
        runner.completeSet()                           // natural finish
        #expect(runner.consumeCompletion() == true)    // the one report → onComplete fires once
        #expect(runner.consumeCompletion() == false)   // double-tap of "Finish workout" → no-op
    }

    @Test func consumeCompletionNeverReportsAnAbandonedSession() {
        let runner = makeRunner([ex("Squat", sets: 3)])
        runner.start()
        runner.completeSet()
        runner.end()                                   // "End without logging"
        #expect(runner.consumeCompletion() == false)
    }

    @Test func descriptorLineWithZeroSetsIsWalkedAsOneStep() {
        // Cardio/conditioning lines carry sets == 0; the runner must treat them as a single
        // completable step, not loop or divide by zero.
        let runner = makeRunner([ex("Easy cardio - 20 min", sets: 0, role: .accessory, reps: "", fromCatalog: false)])
        runner.start()
        #expect(runner.totalSetsForCurrent == 1)
        runner.completeSet()
        #expect(runner.phase == .done)
        #expect(runner.completedNaturally == true)
    }

    @Test func restSecondsVaryByRoleAndGoalAsIntended() {
        // Compounds rest longer than accessories, which rest longer than core.
        #expect(WorkoutSessionRunner.restSeconds(for: .main, goal: .strength)
                > WorkoutSessionRunner.restSeconds(for: .accessory, goal: .strength))
        #expect(WorkoutSessionRunner.restSeconds(for: .accessory, goal: .strength)
                > WorkoutSessionRunner.restSeconds(for: .core, goal: .strength))
        // Strength-leaning goals rest a touch longer than the gentler goals for the same role.
        #expect(WorkoutSessionRunner.restSeconds(for: .main, goal: .strength)
                > WorkoutSessionRunner.restSeconds(for: .main, goal: .recovery))
        // Never below a sane floor.
        #expect(WorkoutSessionRunner.restSeconds(for: .core, goal: .recovery) >= 30)
    }

    // MARK: - Live Activity content mapping (WorkoutActivityAttributes.ContentState)

    /// `.ready`: the mapping is total, but nothing is rendered yet — the controller only starts on the
    /// first working set, so the collapsed phase reads `.working` and no rest window is set.
    @Test func contentStateFromReadyRunnerCollapsesToWorkingWithNoTimer() {
        let runner = makeRunner([ex("Squat", sets: 3, reps: "5")])
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        #expect(state.phase == .working)
        #expect(state.exerciseName == "Squat")
        #expect(state.setNumber == 1)
        #expect(state.totalSets == 3)
        #expect(state.reps == "5")
        #expect(state.restStartedAt == nil)
        #expect(state.restEndsAt == nil)
        #expect(state.exerciseIndex == 0)
        #expect(state.totalExercises == 1)
    }

    @Test func contentStateFromWorkingRunnerCarriesSetAndReps() {
        let runner = makeRunner([ex("Squat", sets: 3, reps: "5"), ex("Bench", sets: 2, reps: "8")])
        runner.start()
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        #expect(state.phase == .working)
        #expect(state.exerciseName == "Squat")
        #expect(state.setNumber == 1)
        #expect(state.totalSets == 3)
        #expect(state.reps == "5")
        #expect(state.totalExercises == 2)
        #expect(state.restStartedAt == nil && state.restEndsAt == nil)
    }

    /// `.resting`: phase flips and the FIXED rest window passes through verbatim, so the widget can
    /// render `Text(timerInterval: restStartedAt...restEndsAt)` without inverting after expiry.
    @Test func contentStateFromRestingRunnerPassesTheFixedWindowThrough() throws {
        let runner = makeRunner([ex("Squat", sets: 3, reps: "5")], restSeconds: 90)
        runner.start()
        runner.completeSet()                       // → resting before set 2
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        #expect(state.phase == .resting)
        #expect(state.setNumber == 2)              // the upcoming set
        let start = try #require(state.restStartedAt)
        let end = try #require(state.restEndsAt)
        #expect(start == runner.restStartedAt)
        #expect(end == runner.restEndsAt)
        // The load-bearing invariant the widget guards on: a non-inverted window.
        #expect(start <= end)
        #expect(end.timeIntervalSince(start) == 90)
    }

    /// `.done`: the mapping stays total (collapses to `.working`), but the controller ENDS on done —
    /// it never `update`s to this state — so the rendered phase here is moot by design.
    @Test func contentStateFromDoneRunnerIsTotalAndClearsTheTimer() {
        let runner = makeRunner([ex("Squat", sets: 1, reps: "5")])
        runner.start()
        runner.completeSet()                       // natural finish
        #expect(runner.phase == .done)
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        #expect(state.phase == .working)           // collapsed; controller ends rather than updating
        #expect(state.restStartedAt == nil && state.restEndsAt == nil)
    }

    /// A cardio/mobility line carries `sets == 0`; the mapping must surface the runner's `max(1, …)`
    /// clamp so the widget shows one step, not "Set 1 of 0".
    @Test func contentStateClampsCardioZeroSetsToOne() {
        let runner = makeRunner([ex("Easy cardio", sets: 0, role: .accessory, reps: "", fromCatalog: false)])
        runner.start()
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        #expect(state.totalSets == 1)
        #expect(state.setNumber == 1)
        #expect(state.reps.isEmpty)
    }

    /// Whatever rest length the runner produces, the mapped window is always a valid range — the
    /// degenerate zero-rest case still yields `start...start`, never an inverted range.
    @Test func contentStateRestWindowStaysValidEvenForZeroRest() throws {
        let runner = makeRunner([ex("Squat", sets: 2, reps: "5")], restSeconds: 0)
        runner.start()
        runner.completeSet()
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        let start = try #require(state.restStartedAt)
        let end = try #require(state.restEndsAt)
        #expect(start <= end)                      // degenerate but valid: start...start
    }

    // MARK: - Stale-date budget (orphaned-activity retirement)

    /// While resting, the activity stays fresh until a grace PAST the rest deadline — never stale the
    /// instant the timer hits 0:00, because over-resting is a designed state.
    @Test func staleDateWhileRestingIsTheDeadlinePlusAGrace() throws {
        let runner = makeRunner([ex("Squat", sets: 3, reps: "5")], restSeconds: 90)
        runner.start()
        runner.completeSet()                       // → resting
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        let end = try #require(state.restEndsAt)
        // The resting branch keys off the rest deadline, not the posting time, so `postedAt` is moot.
        let stale = state.staleDate(postedAt: Date(timeIntervalSince1970: 9_999))
        #expect(stale == end.addingTimeInterval(WorkoutActivityAttributes.ContentState.Staleness.restGrace))
        #expect(stale > end)                       // a live 0:00 is never treated as stale
    }

    /// While working, the activity stays fresh for the working cap measured from when it was posted —
    /// long enough never to clip a real set, short enough a dead process can't haunt the Lock Screen.
    @Test func staleDateWhileWorkingIsPostingTimePlusTheCap() {
        let runner = makeRunner([ex("Squat", sets: 3, reps: "5")])
        runner.start()                             // → working
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        let posted = Date(timeIntervalSince1970: 5_000)
        #expect(state.staleDate(postedAt: posted)
                == posted.addingTimeInterval(WorkoutActivityAttributes.ContentState.Staleness.workingCap))
    }

    /// Defensive: a resting snapshot that is somehow missing its window falls back to the working cap
    /// rather than trapping — the helper is total.
    @Test func staleDateFallsBackToTheCapWhenRestingHasNoWindow() {
        let state = WorkoutActivityAttributes.ContentState(
            exerciseName: "Squat", setNumber: 2, totalSets: 3, reps: "5",
            phase: .resting, restStartedAt: nil, restEndsAt: nil,
            exerciseIndex: 0, totalExercises: 1
        )
        let posted = Date(timeIntervalSince1970: 5_000)
        #expect(state.staleDate(postedAt: posted)
                == posted.addingTimeInterval(WorkoutActivityAttributes.ContentState.Staleness.workingCap))
    }

    // MARK: Move-root "Start today's workout" card availability

    private func session(_ name: String, _ exercises: [PrescribedExercise], kind: SessionKind = .strength) -> WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            title: name,
            timeLabel: "",
            kind: kind,
            exercises: exercises,
            suggestion: WorkoutSuggestion(name: name, exercises: exercises.map(\.line).joined(separator: "\n"), notes: "")
        )
    }

    private func plan(_ sessions: [WorkoutProgram.SessionSuggestion]) -> WorkoutProgram.DayPlan {
        WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: sessions, droppedSlots: [], locationName: "Gym")
    }

    @Test func cardIsReadyForAGuidableSession() {
        let s = session("Upper", [ex("Bench", sets: 3)])
        let state = GuidedWorkoutCardState.resolve(plan: plan([s]), completed: [])
        #expect(state == .ready(sessionID: s.id))
    }

    @Test func cardIsAllCompleteOnceTheGuidableSessionIsLogged() {
        // Requirement 6: a fully-logged day must show a done state, never a restart that double-logs.
        // A single-session day has no leftover movement, so the done copy is the plain "rest up" one.
        let s = session("Upper", [ex("Bench", sets: 3)])
        let state = GuidedWorkoutCardState.resolve(plan: plan([s]), completed: [s.id])
        #expect(state == .allComplete(remainingMovement: false))
    }

    @Test func cardIsNoneToGuideForACardioOnlyDay() {
        // A descriptor line carries sets == 0 → not guidable, but there's still movement to do.
        let cardio = session("Zone 2", [ex("Easy cardio - 25 min", sets: 0, role: .accessory, reps: "", fromCatalog: false)], kind: .cardio)
        let state = GuidedWorkoutCardState.resolve(plan: plan([cardio]), completed: [])
        if case .noneToGuide(let reason) = state {
            #expect(reason.contains("easy movement"))
        } else {
            Issue.record("expected .noneToGuide for a cardio-only day, got \(state)")
        }
    }

    @Test func cardIsNoneToGuideForARestDay() {
        // No sessions with any exercises at all → a rest day.
        let state = GuidedWorkoutCardState.resolve(plan: plan([session("Rest", [], kind: .mobility)]), completed: [])
        if case .noneToGuide(let reason) = state {
            #expect(reason.contains("Rest day"))
        } else {
            Issue.record("expected .noneToGuide for a rest day, got \(state)")
        }
    }

    @Test func cardPicksTheFirstUnloggedGuidableSessionOnAMultiSessionDay() {
        // Cardio warm-up first (not guidable), then two strength sessions. The card opens the first
        // *guidable, not-yet-logged* session — and reports allComplete only once both are logged.
        let cardio = session("Warm-up", [ex("Row - 10 min", sets: 0, role: .accessory, reps: "", fromCatalog: false)], kind: .cardio)
        let am = session("AM strength", [ex("Squat", sets: 3)])
        let pm = session("PM strength", [ex("Deadlift", sets: 2)])
        let day = plan([cardio, am, pm])

        #expect(GuidedWorkoutCardState.resolve(plan: day, completed: []) == .ready(sessionID: am.id))
        #expect(GuidedWorkoutCardState.resolve(plan: day, completed: [am.id]) == .ready(sessionID: pm.id))
        // Both strength sessions logged, but the cardio warm-up (a non-guided movement session) is still
        // unlogged — so the done state flags remaining movement rather than implying the whole day's done.
        #expect(GuidedWorkoutCardState.resolve(plan: day, completed: [am.id, pm.id]) == .allComplete(remainingMovement: true))
        // Once the cardio is logged too (by name), nothing's left and the plain done state stands.
        #expect(GuidedWorkoutCardState.resolve(plan: day, completed: [am.id, pm.id], loggedWorkoutNames: ["Warm-up"]) == .allComplete(remainingMovement: false))

        // The shared guidable filter agrees and skips the cardio session outright.
        #expect(GuidedWorkoutAvailability.firstGuidable(in: day, excluding: [])?.id == am.id)
        #expect(GuidedWorkoutAvailability.firstGuidable(in: day, excluding: [am.id, pm.id]) == nil)
    }

    // MARK: Reconciliation, rework, committed intensity, and day rollover (f502506 review fixes)

    /// Finding 1: after a routine relaunch the plan is regenerated with FRESH session ids and the
    /// in-memory completed set is empty — but the logged workout survives in the day record, keyed by
    /// `suggestion.name`. The card must reconcile against that name and show a done state (never a
    /// re-runnable `.ready`), so a tapped Start can't add the workout, save to HealthKit, or advance
    /// progression a second time.
    @Test func cardReconcilesANameMatchedLoggedWorkoutAfterRelaunch() {
        let s = session("Upper", [ex("Bench", sets: 3)])
        // Fresh plan instance, empty completed set — only the day record (by name) knows it's logged.
        let state = GuidedWorkoutCardState.resolve(plan: plan([s]), completed: [], loggedWorkoutNames: ["Upper"])
        #expect(state == .allComplete(remainingMovement: false))
        // …and firstGuidable must not re-offer it, so Start opens nothing to re-log.
        #expect(GuidedWorkoutAvailability.firstGuidable(in: plan([s]), excluding: [], loggedWorkoutNames: ["Upper"]) == nil)
    }

    /// The reconciliation seam is robust to regeneration: two generations of the "same" plan mint
    /// different ids, so a completed-id set from one never lines up with the other — but the name does.
    @Test func nameReconciliationSurvivesFreshSessionIDs() {
        let first = session("Push", [ex("Bench", sets: 3)])
        let regenerated = session("Push", [ex("Bench", sets: 3)])   // identical content, fresh id
        #expect(first.id != regenerated.id)
        #expect(GuidedWorkoutAvailability.isAlreadyLogged(regenerated, completed: [first.id], loggedWorkoutNames: []) == false)
        #expect(GuidedWorkoutAvailability.isAlreadyLogged(regenerated, completed: [], loggedWorkoutNames: ["Push"]) == true)
    }

    /// Finding 1 through the real store: logging a session's workout (exactly as the guided onComplete
    /// does) leaves the day record carrying its name, so a fresh plan instance with an EMPTY completed
    /// set still resolves to done via `store.loggedWorkoutNamesToday`.
    @Test func loggedWorkoutNamesTodayReconcilesTheCardAfterRelaunch() {
        let store = makeTestStore()
        let s = session("Upper", [ex("Bench", sets: 3)])
        store.addWorkout(s.workout(intensity: .moderate))
        #expect(store.loggedWorkoutNamesToday.contains("Upper"))
        let state = GuidedWorkoutCardState.resolve(
            plan: plan([s]),
            completed: store.guidedCompletedSessionIDs,   // empty on a fresh run
            loggedWorkoutNames: store.loggedWorkoutNamesToday
        )
        #expect(state == .allComplete(remainingMovement: false))
    }

    /// Finding 2: while nothing of the committed plan is logged, it stays regenerable — rework clears it
    /// so the configurator (and the Equipment & limits entry) is reachable again.
    @Test func reworkClearsTheCommittedPlanWhileNothingIsLogged() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        #expect(store.currentGuidedWorkoutPlan != nil)
        #expect(store.canReworkTodaysGuidedPlan == true)
        #expect(store.reworkTodaysGuidedPlan() == true)
        #expect(store.currentGuidedWorkoutPlan == nil)
        #expect(store.committedGuidedIntensity == nil)
    }

    /// Finding 2 invariant: any recorded session completion pins the plan — rework refuses, so it can
    /// never orphan an already-counted session.
    @Test func reworkRefusesOnceAnySessionCompletionIsRecorded() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        store.markGuidedSessionCompleted(UUID())
        #expect(store.canReworkTodaysGuidedPlan == false)
        #expect(store.reworkTodaysGuidedPlan() == false)
        #expect(store.currentGuidedWorkoutPlan != nil)
    }

    /// Finding 2 invariant, relaunch flavor: a session logged only in the day record (no recorded id)
    /// still pins the plan, because rework's guard also reconciles against `loggedWorkoutNamesToday`.
    @Test func reworkRefusesWhenAPlanSessionIsLoggedByNameOnly() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)   // pins today's day key
        let s = session("Upper", [ex("Bench", sets: 3)])
        store.replaceGuidedWorkoutPlan(plan([s]))                   // a committed plan with a known session
        #expect(store.canReworkTodaysGuidedPlan == true)
        store.addWorkout(s.workout(intensity: .hard))              // relaunch-style: only the day record knows
        #expect(store.guidedCompletedSessionIDs.isEmpty)
        #expect(store.canReworkTodaysGuidedPlan == false)
        #expect(store.reworkTodaysGuidedPlan() == false)
        #expect(store.currentGuidedWorkoutPlan != nil)
    }

    /// Finding 3: the committed intensity is recorded and stable — a same-day re-commit ignores its
    /// intensity argument, so a later readiness-derived value can't override how the plan was built.
    @Test func committedIntensityIsRecordedAndStableAcrossSameDayRecommits() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        #expect(store.committedGuidedIntensity == .hard)
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .light)
        #expect(store.committedGuidedIntensity == .hard)
    }

    /// Finding 3: every logging surface reads `store.committedGuidedIntensity` — pin that the logged
    /// workout carries the committed value (`.hard`), not a re-derived `.moderate`.
    @Test func loggingSurfacesUseTheCommittedIntensityNotAReDerivedOne() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        let s = session("Upper", [ex("Bench", sets: 3)])
        // The exact expression both surfaces evaluate at their logging sites:
        let logged = s.workout(intensity: store.committedGuidedIntensity ?? .moderate)
        #expect(logged.intensity == .hard)
        store.addWorkout(logged)
        #expect(store.day.workouts.last?.intensity == .hard)
    }

    /// Finding 4: a committed plan (and its intensity) reads through as nil once the store rolls over to
    /// a new day, so the card re-resolves against the new day instead of yesterday's cached plan.
    @Test func committedPlanReadsThroughAsNilAfterDayRollover() {
        let store = makeTestStore()
        let base = store.todayKey
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        #expect(store.currentGuidedWorkoutPlan != nil)
        #expect(store.committedGuidedIntensity == .hard)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        _ = store.refreshCurrentDayIfNeeded(now: tomorrow)
        #expect(store.todayKey != base)
        #expect(store.currentGuidedWorkoutPlan == nil)
        #expect(store.committedGuidedIntensity == nil)
    }

    /// Low note under finding 4: an AI adjust that resolves after a rollover must not resurrect
    /// yesterday's plan (with yesterday's completions) as today's — `replaceGuidedWorkoutPlan` refuses
    /// once the plan it targets is no longer today's.
    @Test func replaceGuidedPlanDoesNotResurrectYesterdaysPlanAfterRollover() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        _ = store.refreshCurrentDayIfNeeded(now: tomorrow)
        #expect(store.currentGuidedWorkoutPlan == nil)
        store.replaceGuidedWorkoutPlan(plan([session("Upper", [ex("Bench", sets: 3)])]))
        #expect(store.currentGuidedWorkoutPlan == nil)
    }

    /// Finding 4b: the recovery `startTodaysGuidedWorkout` relies on when a stale Start commits but the
    /// plan has nothing to guide — with no completion recorded, the just-committed plan can be released,
    /// so the day is never left silently pinned behind a dead button.
    @Test func aNoOpCommitStaysReleasableWhenNothingIsGuidable() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        #expect(store.currentGuidedWorkoutPlan != nil)
        #expect(store.reworkTodaysGuidedPlan() == true)   // releasable — nothing logged
        #expect(store.currentGuidedWorkoutPlan == nil)
    }
}
