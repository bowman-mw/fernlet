// GymVisualExpansionTests.swift
// FernletTests
//
// The Gym Visual expansion's planner work (2026-10-21, the owner's calls on the shortlist): a new
// variation fills a gap but never displaces a staple; the planner's generic cardio lines name a machine
// the location has, the runner
// times them at the right pace, Apple Health files them as that machine's activity, screens draw them,
// and the Log sheet logs them in minutes; treadmill rows need a treadmill; a Smith machine row is the
// supported end for a mild area but still loads the spine; the cool-down never ends on a warm-up drill.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct GymVisualExpansionTests {

    private static let rowerOnly = WorkoutLocation(name: "Garage", ownedEquipment: [.rowingMachine])
    private static let bikeAndRower = WorkoutLocation(name: "Garage", ownedEquipment: [.exerciseBike, .rowingMachine])
    private static let park = WorkoutLocation(name: "Park", ownedEquipment: [])

    private static func feasible(at location: WorkoutLocation, limits: InjuryLimits = .empty) -> [ExerciseTarget] {
        WorkoutExerciseCatalog.allExercises.filter { WorkoutSafetyFilter.feasible($0, location: location, limits: limits) }
    }

    // MARK: Variations

    /// A variation fills only a slot no staple can: with dumbbells only, an Upper day's triceps slot —
    /// dropped before the expansion — takes a dumbbell triceps variation, while a full gym's plans keep
    /// every staple, so the plans people already follow (and their weight history) do not move.
    @Test func aVariationFillsAGapButNeverDisplacesAStaple() {
        let profile = WorkoutProfile(trainingDaysPerWeek: 4, experience: .intermediate)
        let variations = Set(WorkoutExerciseCatalog.baseExercises.filter(\.variation).map(\.name))
        #expect(variations.contains("Dumbbell overhead triceps extension") && !variations.contains("Chest press machine"))
        let garage = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells])
        let dumbbells = WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: profile, location: garage,
                                               context: "", split: WorkoutSplitCatalog.upperLower4, rotationIndex: 0)
        let gapPicks = dumbbells.sessions.flatMap(\.exercises).map(\.name)
        #expect(gapPicks.contains { ["Dumbbell overhead triceps extension", "Dumbbell kickback"].contains($0) }, "\(gapPicks)")
        for rotation in 0..<4 {
            let gym = WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: profile, location: .fullGym,
                                             context: "", split: WorkoutSplitCatalog.upperLower4, rotationIndex: rotation)
            let picks = Set(gym.sessions.flatMap(\.exercises).map(\.name))
            #expect(picks.isDisjoint(with: variations), "\(picks.intersection(variations))")
        }
    }

    // MARK: Naming the machine

    /// Each generic line names the machine its effort prefers among those the location has: an easy
    /// line keeps "easy" after its minutes, the steady and interval lines keep their own clause.
    @Test func genericCardioLinesNameTheLocationsMachine() {
        let rower = Self.feasible(at: Self.rowerOnly)
        #expect(WorkoutCardioMachines.named("Easy cardio - 20 min", feasible: rower, seed: 0) == "Rowing machine - 20 min easy")
        #expect(WorkoutCardioMachines.named("Steady cardio - 40 min", feasible: rower, seed: 3) == "Rowing machine - 40 min")
        #expect(WorkoutCardioMachines.named("Intervals - 8 × 1 min hard / 1 min easy", feasible: rower, seed: 0)
                == "Rowing machine - 8 × 1 min hard / 1 min easy")
        for line in ["Easy walk - 15 min", "Gentle mobility + walk - 12 min", "Basketball drills / conditioning - 15 min",
                     "Mobility flow - 15 min", "Bench press - 3 x 8"] {
            #expect(WorkoutCardioMachines.named(line, feasible: rower, seed: 0) == line, "\(line) is not a generic cardio line")
        }
    }

    /// With no machine the line stays generic; with two, the rotation index alternates them; the
    /// recumbent bike is never named, since an owned "Exercise bike" does not say which kind it is.
    @Test func noMachineKeepsTheLineAndTwoMachinesAlternate() {
        #expect(WorkoutCardioMachines.named("Easy cardio - 20 min", feasible: Self.feasible(at: Self.park), seed: 0)
                == "Easy cardio - 20 min")
        let both = Self.feasible(at: Self.bikeAndRower)
        let picks = (0..<4).map { WorkoutCardioMachines.named("Easy cardio - 20 min", feasible: both, seed: $0) }
        #expect(picks == ["Stationary bike - 20 min easy", "Rowing machine - 20 min easy",
                          "Stationary bike - 20 min easy", "Rowing machine - 20 min easy"])
        #expect(!picks.contains { $0.hasPrefix("Recumbent") })
    }

    /// A severe knee leaves every leg machine out of the pool, so the line stays generic rather than
    /// naming a machine the person was told to avoid.
    @Test func aMachineTheInjuriesRuleOutIsNeverNamed() {
        var profile = WorkoutProfile()
        profile.injuryAreas = [.knee: .severe]
        let pool = Self.feasible(at: Self.bikeAndRower, limits: profile.injuryLimits)
        #expect(WorkoutCardioMachines.named("Easy cardio - 20 min", feasible: pool, seed: 0) == "Easy cardio - 20 min")
    }

    /// The day plan does it: the recovery split's easy-cardio day names the rower in a garage that has
    /// one, and keeps the generic line in a park.
    @Test func theDayPlansCardioSessionNamesTheMachine() throws {
        let garage = WorkoutProgram.dayPlan(goal: .recovery, intensity: .light, profile: WorkoutProfile(),
                                            location: Self.rowerOnly, context: "", split: WorkoutSplitCatalog.recoveryFlow,
                                            rotationIndex: 1)
        let session = try #require(garage.sessions.first { $0.kind == .cardio })
        #expect(session.suggestion.exercises == "Rowing machine - 20 min easy")
        let line = try #require(session.exercises.first?.name)
        #expect(WorkoutProgram.descriptorMinutes(in: line) == 20)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: line) == .rowing)
        let outdoors = WorkoutProgram.dayPlan(goal: .recovery, intensity: .light, profile: WorkoutProfile(),
                                              location: Self.park, context: "", split: WorkoutSplitCatalog.recoveryFlow,
                                              rotationIndex: 1)
        #expect(outdoors.sessions.first { $0.kind == .cardio }?.suggestion.exercises == "Easy cardio - 20 min")
    }

    // MARK: Running, logging and drawing the line

    /// The runner times a machine line: steady minutes with the easy mark's pace, or the interval
    /// shape; the segments carry the machine's own name, so the how-to sheet comes with them.
    @Test func theRunnerTimesAMachineLine() throws {
        #expect(WorkoutTimedSessions.classify("Rowing machine - 20 min easy") == .steady(minutes: 20, pace: .easy))
        #expect(WorkoutTimedSessions.classify("Stair climber - 40 min") == .steady(minutes: 40, pace: .steady))
        #expect(WorkoutTimedSessions.classify("Elliptical - 8 × 1 min hard / 1 min easy")
                == .intervals(rounds: 8, workSeconds: 60, easySeconds: 60))
        #expect(WorkoutProgram.descriptorMinutes(in: "Stationary bike - 20 min easy") == 20)
        let line = PrescribedExercise(name: "Rowing machine - 20 min easy", sets: 0, reps: "", role: .accessory, fromCatalog: false)
        let steps = WorkoutTimedSessions.expand([line], feasible: [])
        #expect(!steps.isEmpty && steps.allSatisfy { $0.name == "Rowing machine" })
        #expect(ExerciseHowToCatalog.entry(for: "Rowing machine") != nil, "the step's how-to sheet")
    }

    /// Apple Health files each machine as what it is, intervals included; other lines are unchanged.
    @Test func eachMachineLogsAsItsOwnActivity() {
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Rowing machine - 20 min easy") == .rowing)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Rowing machine - 8 × 1 min hard / 1 min easy") == .rowing)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Stationary bike - 30 min") == .indoorCycling)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Elliptical - 20 min easy") == .elliptical)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Stair climber - 20 min") == .stairClimbing)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Treadmill walk - 20 min easy") == .walking)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Easy cardio - 20 min") == .mixedCardio)
        #expect(WorkoutTimedSessions.activityType(forDescriptor: "Intervals - 8 × 1 min hard / 1 min easy") == .hiit)
    }

    /// A screen draws a machine line through the machine's display name, the easy mark as words; a
    /// typed line with more after the minutes is drawn as written.
    @Test func aMachineLineDrawsThroughItsDisplayName() {
        #expect(WorkoutPlanLine.displayed("Rowing machine - 20 min") == "Rowing machine - 20 min")
        #expect(WorkoutPlanLine.displayed("Stationary bike - 20 min easy") == "Stationary bike - 20 min, easy")
        #expect(WorkoutPlanLine.displayed("Elliptical - 8 × 1 min hard / 1 min easy") == "Elliptical - 8 × 1 min hard / 1 min easy")
        #expect(WorkoutPlanLine.displayed("Rowing machine - 20 min 5 km") == "Rowing machine - 20 min 5 km")
    }

    /// The Log sheet logs a machine in minutes, in the planner's own shape, and reopens it with the
    /// minutes back in their field and the rest in details.
    @Test func theLogSheetLogsAMachineInMinutes() throws {
        let rower = try #require(WorkoutExerciseCatalog.exercise(named: "Rowing machine"))
        #expect(rower.inputKind == .timed)
        let written = WorkoutExerciseEntry(exercise: rower, sets: "", reps: "", weight: "", speed: "", incline: "",
                                           details: "5 km", minutes: "20").summary
        #expect(written == "Rowing machine - 20 min 5 km")
        let reopened = try #require(WorkoutSheetRules.exerciseEntries(from: written).first)
        #expect(reopened.exercise.name == "Rowing machine")
        #expect(reopened.minutes == "20")
        #expect(reopened.details == "5 km")
        #expect(reopened.summary == written)
    }

    // MARK: Gear, injuries and the cool-down

    /// Every cardio machine row needs its machine, the treadmill rows included, so a bike-only
    /// location no longer gets a treadmill walk.
    @Test func everyMachineRowNeedsItsMachine() {
        let bikeOnly = Self.feasible(at: WorkoutLocation(name: "Spare room", ownedEquipment: [.exerciseBike])).map(\.name)
        #expect(bikeOnly.contains("Stationary bike"))
        #expect(!bikeOnly.contains("Treadmill walk") && !bikeOnly.contains("Rowing machine") && !bikeOnly.contains("Elliptical"))
        for row in WorkoutExerciseCatalog.baseExercises where row.equipment == .cardio {
            #expect(!row.requiredGear.isEmpty, "\(row.name) is a machine with no machine required")
        }
    }

    /// The owner counts the Smith machine as supported: its squat is not the heavy end a mild knee
    /// leaves out. Its bar still sits on the spine, so a severe lower back leaves it out with the back squat.
    @Test func theSmithMachineIsSupportedButStillLoadsTheSpine() throws {
        let smith = try #require(WorkoutExerciseCatalog.exercise(named: "Smith machine squat"))
        #expect(!InjuryLimits.isHeavyLoading(smith))
        var knee = WorkoutProfile()
        knee.injuryAreas = [.knee: .mild]
        #expect(knee.injuryLimits.allows(smith))
        #expect(BodyArea.lowerBack.isLoaded(by: smith, primaryOnly: true))
        var back = WorkoutProfile()
        back.injuryAreas = [.lowerBack: .severe]
        #expect(!back.injuryLimits.allows(smith))
    }

    /// The moving warm-up drills never end a session; the stretches beside them still can.
    @Test func theCoolDownNeverEndsOnAWarmUpDrill() {
        let profile = WorkoutProfile(trainingDaysPerWeek: 4, experience: .intermediate)
        var coolDown: [String] = []
        for rotation in 0..<4 {
            let plan = WorkoutProgram.dayPlan(goal: .strength, intensity: .moderate, profile: profile, location: .fullGym,
                                              context: "", split: WorkoutSplitCatalog.upperLower4, rotationIndex: rotation)
            coolDown += plan.sessions.flatMap(\.exercises).filter { $0.block == .coolDown }.map(\.name)
        }
        #expect(!coolDown.isEmpty)
        #expect(Set(coolDown).isDisjoint(with: WorkoutSessionBlocks.warmUpDrills), "\(Set(coolDown))")
    }
}
