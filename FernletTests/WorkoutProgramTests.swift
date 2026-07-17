import Foundation
import Testing
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
}
