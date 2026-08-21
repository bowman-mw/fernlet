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

    /// The two built-in ids are spelled as raw bytes through `UUID(uuid:)` (no force unwrap, R5).
    /// This pins their canonical string form: the ids are persisted in `settings`, so a typo in the
    /// byte tuple would orphan every saved location without this check.
    @Test func builtInLocationIDsMatchTheirPersistedStringForm() {
        #expect(WorkoutLocation.fullGym.id.uuidString == "F0E1D2C3-B4A5-4968-8778-6A5B4C3D2E1F")
        #expect(WorkoutLocation.home.id.uuidString == "0A1B2C3D-4E5F-4061-9273-8495A6B7C8D9")
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

    // MARK: - Guided-session state machine (GuidedWorkoutRunState)

    private func ex(_ name: String, sets: Int, role: SlotRole = .main, reps: String = "5", fromCatalog: Bool = true) -> PrescribedExercise {
        PrescribedExercise(name: name, sets: sets, reps: reps, role: role, fromCatalog: fromCatalog)
    }

    private func roleRaw(_ role: SlotRole) -> String {
        switch role { case .main: "main"; case .accessory: "accessory"; case .core: "core" }
    }
    private let fixedNow = Date(timeIntervalSince1970: 1_000)

    /// Build a WORKING run with a fixed per-exercise rest so transitions assert without wall-clock
    /// flakiness. The sheet-local runner is gone; the state machine now lives on the value type
    /// GuidedWorkoutRunState, shared with the Live Activity intents.
    private func makeRun(_ exercises: [PrescribedExercise], restSeconds: Int = 90) -> GuidedWorkoutRunState {
        let runExercises = exercises.map {
            GuidedWorkoutRunState.Exercise(
                id: $0.id, name: $0.name, sets: $0.sets, reps: $0.reps,
                roleRaw: roleRaw($0.role), fromCatalog: $0.fromCatalog, restSeconds: restSeconds
            )
        }
        var state = GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-07-19", intensityRaw: "Moderate",
            title: "Test", suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: runExercises
        )
        state.phase = runExercises.isEmpty ? .done : .working
        return state
    }

    @Test func runStartsWorkingOnFirstSet() {
        let run = makeRun([ex("Squat", sets: 3)])
        #expect(run.phase == .working)
        #expect(run.exerciseIndex == 0)
        #expect(run.currentSet == 1)
        #expect(run.completedNaturally == false)
    }

    @Test func markSetDoneAdvancesSetThenRests() {
        var run = makeRun([ex("Squat", sets: 3)], restSeconds: 90)
        run.markSetDone(now: fixedNow)
        #expect(run.phase == .resting)
        #expect(run.currentSet == 2)                       // counter points at the upcoming set
        #expect(run.restDuration == 90)
        #expect(run.restEndsAt == fixedNow.addingTimeInterval(90))
    }

    @Test func lastSetOfAnExerciseAdvancesToNextExerciseWorkingNoRest() {
        var run = makeRun([ex("Squat", sets: 2), ex("Bench", sets: 2)])
        run.markSetDone(now: fixedNow)   // ex0 set1 done → rest, currentSet 2
        run.skipRest()                    // → working ex0 set2
        #expect(run.exerciseIndex == 0)
        #expect(run.currentSet == 2)
        run.markSetDone(now: fixedNow)   // last set of ex0 → next exercise, straight to working
        #expect(run.phase == .working)
        #expect(run.exerciseIndex == 1)
        #expect(run.currentSet == 1)
        #expect(run.restEndsAt == nil)
    }

    @Test func lastSetOfLastExerciseFinishesAndMarksCompleted() {
        var run = makeRun([ex("Squat", sets: 1)])
        run.markSetDone(now: fixedNow)
        #expect(run.phase == .done)
        #expect(run.completedNaturally == true)
    }

    @Test func skipRestResumesWorkingAndClearsTimer() {
        var run = makeRun([ex("Squat", sets: 3)])
        run.markSetDone(now: fixedNow)    // → resting on set 2
        #expect(run.phase == .resting)
        run.skipRest()
        #expect(run.phase == .working)
        #expect(run.currentSet == 2)
        #expect(run.restEndsAt == nil)
    }

    @Test func endAbortsWithoutMarkingCompleted() {
        var run = makeRun([ex("Squat", sets: 3)])
        run.markSetDone(now: fixedNow)    // mid-session, resting
        run.end()
        #expect(run.phase == .done)
        #expect(run.completedNaturally == false)   // aborted → nothing to log
    }

    @Test func restWindowIsAFixedValidRangeSetOnlyWhileResting() throws {
        var run = makeRun([ex("Squat", sets: 2), ex("Bench", sets: 1)], restSeconds: 90)
        #expect(run.restStartedAt == nil)
        #expect(run.restEndsAt == nil)

        run.markSetDone(now: fixedNow)    // → resting before set 2
        let started = try #require(run.restStartedAt)
        let ends = try #require(run.restEndsAt)
        // The sheet/widget render `Text(timerInterval: started...ends)` — a fixed window. It must be a
        // valid (non-inverted) range or the range literal traps, however long the user over-rests.
        #expect(started <= ends)
        #expect(ends.timeIntervalSince(started) == 90)

        run.skipRest()                    // leaving .resting clears both halves together
        #expect(run.restStartedAt == nil)
        #expect(run.restEndsAt == nil)

        run.markSetDone(now: fixedNow)    // last set of Squat → straight to Bench, no rest window
        #expect(run.phase == .working)
        #expect(run.restStartedAt == nil)
        #expect(run.restEndsAt == nil)

        run.markSetDone(now: fixedNow)    // finish Bench → done, still no rest window
        #expect(run.phase == .done)
        #expect(run.restStartedAt == nil)
        #expect(run.restEndsAt == nil)
    }

    @Test func zeroLengthRestStillFormsAValidWindow() throws {
        var run = makeRun([ex("Squat", sets: 2)], restSeconds: 0)
        run.markSetDone(now: fixedNow)
        let started = try #require(run.restStartedAt)
        let ends = try #require(run.restEndsAt)
        #expect(started <= ends)      // degenerate but valid: started...started
    }

    @Test func descriptorLineWithZeroSetsIsWalkedAsOneStep() {
        // Cardio/conditioning lines carry sets == 0; the runner must treat them as a single
        // completable step, not loop or divide by zero.
        var run = makeRun([ex("Easy cardio - 20 min", sets: 0, role: .accessory, reps: "", fromCatalog: false)])
        #expect(run.totalSetsForCurrent == 1)
        run.markSetDone(now: fixedNow)
        #expect(run.phase == .done)
        #expect(run.completedNaturally == true)
    }

    // MARK: Runner display derivations (MOVE-26)

    @Test func setsCompletedForCurrentIsCounterMinusOneInBothPhases() {
        var run = makeRun([ex("Squat", sets: 3)])
        #expect(run.setsCompletedForCurrent == 0)   // working set 1: nothing done yet
        run.markSetDone(now: fixedNow)              // → resting, counter already on set 2
        #expect(run.setsCompletedForCurrent == 1)
        run.skipRest()                              // → working set 2, same answer
        #expect(run.setsCompletedForCurrent == 1)
    }

    @Test func canSkipToNextExerciseOnlyWhileSomethingIsNext() {
        var run = makeRun([ex("Squat", sets: 1), ex("Bench", sets: 1)])
        #expect(run.canSkipToNextExercise)          // Bench is next
        run.markSetDone(now: fixedNow)              // last set of Squat → working Bench
        #expect(run.canSkipToNextExercise == false) // nothing after the last exercise
        run.markSetDone(now: fixedNow)              // finish
        #expect(run.canSkipToNextExercise == false)
    }

    @Test func estimatedSecondsRemainingCountsSetsAndRestsAcrossPhases() {
        var run = makeRun([ex("Squat", sets: 2), ex("Bench", sets: 2)], restSeconds: 90)
        // Working ex0 set 1: (2×45 + 1×90) + (2×45 + 1×90) = 360.
        #expect(run.estimatedSecondsRemaining() == 360)
        run.markSetDone(now: fixedNow)
        // Resting before ex0 set 2: (1×45 + the in-flight 90) + 180 = 315.
        #expect(run.estimatedSecondsRemaining() == 315)
        run.skipRest()
        run.markSetDone(now: fixedNow)  // last Squat set → working Bench
        run.markSetDone(now: fixedNow)  // → resting before Bench set 2
        run.skipRest()
        run.markSetDone(now: fixedNow)  // done
        #expect(run.estimatedSecondsRemaining() == 0)
    }

    @Test func estimatedSecondsRemainingCountsDescriptorsAsFixedSteps() {
        let run = makeRun([
            ex("Squat", sets: 1),
            ex("Cooldown walk", sets: 0, role: .accessory, reps: "", fromCatalog: false),
        ], restSeconds: 60)
        // One set (45s, no rest — it's the exercise's only set) + one 300s descriptor step.
        #expect(run.estimatedSecondsRemaining() == 345)
    }

    // MARK: - Rest guidance (WorkoutRestGuidance)

    @Test func restSecondsVaryByDemandAndGoalAsIntended() {
        // Heavy compounds rest longer than isolation, which rests longer than core.
        #expect(WorkoutRestGuidance.restSeconds(demand: .heavyCompound, goal: .strength)
                > WorkoutRestGuidance.restSeconds(demand: .isolation, goal: .strength))
        #expect(WorkoutRestGuidance.restSeconds(demand: .isolation, goal: .strength)
                > WorkoutRestGuidance.restSeconds(demand: .core, goal: .strength))
        // Strength rests longer than the gentler recovery goal for the same demand.
        #expect(WorkoutRestGuidance.restSeconds(demand: .heavyCompound, goal: .strength)
                > WorkoutRestGuidance.restSeconds(demand: .heavyCompound, goal: .recovery))
        // Never below the floor; hypertrophy isolation never dips under 60s (evidence caveat).
        #expect(WorkoutRestGuidance.restSeconds(demand: .core, goal: .recovery) >= WorkoutRestGuidance.minimumSeconds)
        #expect(WorkoutRestGuidance.restSeconds(demand: .isolation, goal: .wellness) >= 60)
    }

    @Test func restDemandKeysOffMovementAndRole() {
        // A squat/hinge pattern is a heavy compound even as an accessory; isolation stays isolation.
        #expect(WorkoutRestGuidance.demand(role: .accessory, movementPattern: .squat) == .heavyCompound)
        #expect(WorkoutRestGuidance.demand(role: .accessory, movementPattern: .isolation) == .isolation)
        // A main lift with no known pattern falls back to a heavy compound; core role is always core.
        #expect(WorkoutRestGuidance.demand(role: .main, movementPattern: nil) == .heavyCompound)
        #expect(WorkoutRestGuidance.demand(role: .core, movementPattern: .push) == .core)
    }

    // MARK: - Live Activity content mapping (GuidedWorkoutRunState.contentState)

    @Test func contentStateFromWorkingRunCarriesSetAndReps() {
        let run = makeRun([ex("Squat", sets: 3, reps: "5"), ex("Bench", sets: 2, reps: "8")])
        let state = run.contentState
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
    @Test func contentStateFromRestingRunPassesTheFixedWindowThrough() throws {
        var run = makeRun([ex("Squat", sets: 3, reps: "5")], restSeconds: 90)
        run.markSetDone(now: fixedNow)             // → resting before set 2
        let state = run.contentState
        #expect(state.phase == .resting)
        #expect(state.setNumber == 2)              // the upcoming set
        let start = try #require(state.restStartedAt)
        let end = try #require(state.restEndsAt)
        #expect(start == run.restStartedAt)
        #expect(end == run.restEndsAt)
        // The load-bearing invariant the widget guards on: a non-inverted window.
        #expect(start <= end)
        #expect(end.timeIntervalSince(start) == 90)
    }

    /// `.done`: the mapping stays total (collapses to `.working`), but the activity ENDS on done — it
    /// is never `update`d to this state — so the rendered phase here is moot by design.
    @Test func contentStateFromDoneRunIsTotalAndClearsTheTimer() {
        var run = makeRun([ex("Squat", sets: 1, reps: "5")])
        run.markSetDone(now: fixedNow)             // natural finish
        #expect(run.phase == .done)
        let state = run.contentState
        #expect(state.phase == .working)           // collapsed; the activity ends rather than updating
        #expect(state.restStartedAt == nil && state.restEndsAt == nil)
    }

    /// A cardio/mobility line carries `sets == 0`; the mapping must surface the `max(1, …)` clamp so
    /// the widget shows one step, not "Set 1 of 0".
    @Test func contentStateClampsCardioZeroSetsToOne() {
        let run = makeRun([ex("Easy cardio", sets: 0, role: .accessory, reps: "", fromCatalog: false)])
        let state = run.contentState
        #expect(state.totalSets == 1)
        #expect(state.setNumber == 1)
        #expect(state.reps.isEmpty)
    }

    /// Whatever rest length the run produces, the mapped window is always a valid range — the
    /// degenerate zero-rest case still yields `start...start`, never an inverted range.
    @Test func contentStateRestWindowStaysValidEvenForZeroRest() throws {
        var run = makeRun([ex("Squat", sets: 2, reps: "5")], restSeconds: 0)
        run.markSetDone(now: fixedNow)
        let state = run.contentState
        let start = try #require(state.restStartedAt)
        let end = try #require(state.restEndsAt)
        #expect(start <= end)                      // degenerate but valid: start...start
    }

    // MARK: - Stale-date budget (orphaned-activity retirement)

    /// While resting, the activity stays fresh until a grace PAST the rest deadline — never stale the
    /// instant the timer hits 0:00, because over-resting is a designed state.
    @Test func staleDateWhileRestingIsTheDeadlinePlusAGrace() throws {
        var run = makeRun([ex("Squat", sets: 3, reps: "5")], restSeconds: 90)
        run.markSetDone(now: fixedNow)             // → resting
        let end = try #require(run.restEndsAt)
        // The resting branch keys off the rest deadline, not the posting time, so `postedAt` is moot.
        let stale = run.staleDate(postedAt: Date(timeIntervalSince1970: 9_999))
        #expect(stale == end.addingTimeInterval(GuidedWorkoutRunState.Staleness.restGrace))
        #expect(stale > end)                       // a live 0:00 is never treated as stale
    }

    /// While working, the activity stays fresh for the working cap measured from when it was posted —
    /// long enough never to clip a real set, short enough a dead process can't haunt the Lock Screen.
    @Test func staleDateWhileWorkingIsPostingTimePlusTheCap() {
        let run = makeRun([ex("Squat", sets: 3, reps: "5")])   // → working
        let posted = Date(timeIntervalSince1970: 5_000)
        #expect(run.staleDate(postedAt: posted)
                == posted.addingTimeInterval(GuidedWorkoutRunState.Staleness.workingCap))
    }

    /// Defensive: a resting snapshot that is somehow missing its window falls back to the working cap
    /// rather than trapping — the helper is total.
    @Test func staleDateFallsBackToTheCapWhenRestingHasNoWindow() {
        var run = makeRun([ex("Squat", sets: 3, reps: "5")])
        run.phase = .resting                       // resting but the window is somehow missing
        let posted = Date(timeIntervalSince1970: 5_000)
        #expect(run.staleDate(postedAt: posted)
                == posted.addingTimeInterval(GuidedWorkoutRunState.Staleness.workingCap))
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
        #expect(GuidedWorkoutCardState.resolve(plan: day, completed: [am.id, pm.id], loggedGuidedWorkoutNames: ["Warm-up"]) == .allComplete(remainingMovement: false))

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
        let state = GuidedWorkoutCardState.resolve(plan: plan([s]), completed: [], loggedGuidedWorkoutNames: ["Upper"])
        #expect(state == .allComplete(remainingMovement: false))
        // …and firstGuidable must not re-offer it, so Start opens nothing to re-log.
        #expect(GuidedWorkoutAvailability.firstGuidable(in: plan([s]), excluding: [], loggedGuidedWorkoutNames: ["Upper"]) == nil)
    }

    /// The reconciliation seam is robust to regeneration: two generations of the "same" plan mint
    /// different ids, so a completed-id set from one never lines up with the other — but the name does.
    @Test func nameReconciliationSurvivesFreshSessionIDs() {
        let first = session("Push", [ex("Bench", sets: 3)])
        let regenerated = session("Push", [ex("Bench", sets: 3)])   // identical content, fresh id
        #expect(first.id != regenerated.id)
        #expect(GuidedWorkoutAvailability.isAlreadyLogged(regenerated, completed: [first.id], loggedGuidedWorkoutNames: []) == false)
        #expect(GuidedWorkoutAvailability.isAlreadyLogged(regenerated, completed: [], loggedGuidedWorkoutNames: ["Push"]) == true)
    }

    /// Finding 1 through the real store: logging a TAGGED guided workout (exactly as the guided
    /// onComplete does) leaves the day record carrying its name, so a fresh plan instance with an EMPTY
    /// completed set still resolves to done via `store.loggedGuidedWorkoutNamesToday`.
    @Test func loggedGuidedWorkoutNamesTodayReconcilesTheCardAfterRelaunch() {
        let store = makeTestStore()
        let s = session("Upper", [ex("Bench", sets: 3)])
        store.addWorkout(s.workout(intensity: .moderate, loggedFromGuidedSession: true))
        #expect(store.loggedGuidedWorkoutNamesToday.contains("Upper"))
        let state = GuidedWorkoutCardState.resolve(
            plan: plan([s]),
            completed: store.guidedCompletedSessionIDs,   // empty on a fresh run
            loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
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

    /// Finding 2 invariant, relaunch flavor: a guided session logged only in the day record (no recorded
    /// id) still pins the plan, because rework's guard also reconciles against
    /// `loggedGuidedWorkoutNamesToday`.
    @Test func reworkRefusesWhenAPlanSessionIsLoggedByNameOnly() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)   // pins today's day key
        let s = session("Upper", [ex("Bench", sets: 3)])
        // Inject a committed plan with a known session (its ids match the plan being replaced).
        let baseIDs = Set(store.currentGuidedWorkoutPlan!.sessions.map(\.id))
        store.replaceGuidedWorkoutPlan(plan([s]), replacing: baseIDs)
        #expect(store.canReworkTodaysGuidedPlan == true)
        // Relaunch-style: only the day record knows, and only a TAGGED guided log reconciles.
        store.addWorkout(s.workout(intensity: .hard, loggedFromGuidedSession: true))
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
        // The day guard fires first (the plan no longer belongs to today), before the identity check.
        store.replaceGuidedWorkoutPlan(plan([session("Upper", [ex("Bench", sets: 3)])]), replacing: [])
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

    // MARK: - Guided tag, plan-day anchoring, and adjustment identity (guided-flow review fixes)

    /// New finding 1: a manual Log-sheet entry OR a planned-workout completion that shares a guided
    /// session's name ("Legs") is UNTAGGED, so it must not make the guided flow claim itself done and
    /// must not block a rework. Only a tagged guided log reconciles.
    @Test func manualOrPlannedLogSharingAGuidedNameDoesNotBrickTheGuidedFlow() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)
        let s = session("Legs", [ex("Squat", sets: 3)])
        store.replaceGuidedWorkoutPlan(plan([s]), replacing: Set(store.currentGuidedWorkoutPlan!.sessions.map(\.id)))

        // A manual Log-sheet "Legs" (untagged) — not the guided flow's own row.
        store.addWorkout(Workout(name: "Legs", type: .lower, exercises: "", rpe: nil, notes: "", duration: nil, intensity: .moderate))
        #expect(store.loggedGuidedWorkoutNamesToday.contains("Legs") == false)
        #expect(GuidedWorkoutAvailability.isAlreadyLogged(s, completed: [], loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday) == false)
        #expect(store.canReworkTodaysGuidedPlan == true, "a manual same-name log must not brick the guided flow")

        // A planned-workout completion named "Legs" (carries plannedWorkoutID, still untagged) — same.
        let planned = PlannedWorkout(name: "Legs", split: .legs, source: .user, notes: "", duration: nil)
        store.completePlannedWorkout(planned, date: store.todayKey)
        #expect(store.loggedGuidedWorkoutNamesToday.contains("Legs") == false)
        #expect(store.canReworkTodaysGuidedPlan == true, "a planned same-name completion must not brick the guided flow")
    }

    /// New finding 2: a guided completion belongs to the day its plan was committed. When a rest crosses
    /// local midnight between commit and completion, the workout must file under the committed day (not
    /// the rolled-over "today") and carry the committed intensity — so the day it belongs to is coherent
    /// and the weekday-aliased next day resolves fresh.
    @Test func guidedRunnerCompletionAnchorsToThePlansCommittedDayAndIntensityAfterRollover() {
        let store = makeTestStore()
        let base = store.todayKey
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)     // committed on `base`, at .hard
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        _ = store.refreshCurrentDayIfNeeded(now: tomorrow)            // midnight crossed while the sheet was open
        #expect(store.todayKey != base)
        #expect(store.currentGuidedWorkoutPlan == nil)               // reads through nil on the new day

        store.completeGuidedRunnerSession(session("Upper", [ex("Bench", sets: 3)]))

        // Filed under the committed day (`base`), tagged, at the committed intensity — NOT today.
        let onBase = store.loadDay(for: base).workouts.first { $0.name == "Upper" }
        #expect(onBase != nil, "guided completion must land on the plan's committed day")
        #expect(onBase?.intensity == .hard, "must log the committed intensity, not a re-derived .moderate")
        #expect(onBase?.loggedFromGuidedSession == true)
        #expect(store.day.workouts.contains { $0.name == "Upper" } == false, "must not file under the rolled-over day")
    }

    /// New finding 3: an AI adjustment kicked off against plan P1 must not clobber a plan P2 the user
    /// reworked-and-committed while the adjustment was in flight. `replaceGuidedWorkoutPlan` refuses when
    /// the committed plan's identity (its session-id set) no longer matches the one the adjustment began
    /// from; it still applies when the plan is unchanged.
    @Test func replaceGuidedPlanRefusesWhenCommittedPlanChangedSinceAdjustmentBegan() {
        let store = makeTestStore()
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .hard)     // P1
        let baseIDs = Set(store.currentGuidedWorkoutPlan!.sessions.map(\.id))

        // Positive path first: an adjustment that preserves the ids (unchanged committed plan) applies.
        var adjusted = store.currentGuidedWorkoutPlan!
        adjusted.dayTitle = "Adjusted!"
        store.replaceGuidedWorkoutPlan(adjusted, replacing: baseIDs)
        #expect(store.currentGuidedWorkoutPlan?.dayTitle == "Adjusted!")

        // Now the user reworks and commits a different plan (P2, fresh session ids)…
        #expect(store.reworkTodaysGuidedPlan() == true)
        _ = store.commitTodaysGuidedWorkoutPlan(intensity: .light)    // P2
        let p2IDs = store.currentGuidedWorkoutPlan?.sessions.map(\.id)

        // …and the stale P1 adjustment finally resolves — it must be refused, leaving P2 intact.
        store.replaceGuidedWorkoutPlan(plan([session("StaleP1", [ex("Bench", sets: 3)])]), replacing: baseIDs)
        #expect(store.currentGuidedWorkoutPlan?.sessions.map(\.id) == p2IDs, "a stale adjustment must not clobber the reworked plan")
        #expect(store.currentGuidedWorkoutPlan?.sessions.contains { $0.suggestion.name == "StaleP1" } == false)
    }
}
