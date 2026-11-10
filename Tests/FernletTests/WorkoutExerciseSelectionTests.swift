import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins which exercises the planner picks, and the rules that make those picks.
///
/// The old picker filled a slot with any exercise whose score was above zero and broke the many
/// ties alphabetically. A full gym's bench slot got "Band chest press", a biceps slot at a
/// bodyweight-only location got "Ab wheel", a vertical pull got "Cable row", and every core slot
/// everywhere got "Medicine ball slam" (tagged as needing no equipment). These cells hold the
/// fixed behavior: eligibility by pattern, plane and primary muscle; a tool preference by role and
/// experience; gear that really gates; and rotation by the last logged split day.
@MainActor
struct WorkoutExerciseSelectionTests {

    // MARK: - Fixtures

    private static let hotelGym = WorkoutLocation(
        name: "Hotel gym", ownedEquipment: [.treadmill, .exerciseBike, .dumbbells, .weightBench, .cableMachine])
    private static let park = WorkoutLocation(name: "Park", ownedEquipment: [])

    private func names(
        _ session: WorkoutSessionTemplate,
        at location: WorkoutLocation,
        experience: ExperienceLevel,
        goal: GoalType = .strength
    ) -> (picked: [String], activation: [String], dropped: [String]) {
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced,
                                  goalFit: [goal], days: [WorkoutSplitDay(title: "Day", sessions: [session])])
        let plan = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: experience),
            location: location, context: "", split: split, rotationIndex: 0
        )
        let exercises = plan.sessions.flatMap(\.exercises).filter(\.fromCatalog)
        let picked = exercises.filter { $0.block == .lifting }.map(\.name)
        let activation = exercises.filter { $0.block == .activation }.map(\.name)
        return (picked, activation, plan.droppedSlots)
    }

    private func catalogExercise(_ name: String) -> ExerciseTarget? {
        WorkoutExerciseCatalog.exercise(named: name)
    }

    // MARK: - Picks a lifter would recognize

    /// A trained lifter at a full gym gets the barbell staples, not the band versions that used to
    /// win on alphabetical order.
    @Test func fullGymIntermediateGetsTheBarbellStaples() {
        let fullBodyA = names(WorkoutSessions.fullBodyA, at: .fullGym, experience: .intermediate).picked
        #expect(fullBodyA.contains("Back squat"))
        #expect(fullBodyA.contains("Bench press"))
        #expect(fullBodyA.contains("Barbell row"))
        let upper = names(WorkoutSessions.upper, at: .fullGym, experience: .intermediate).picked
        #expect(upper.contains("Overhead press"))
        #expect(upper.contains("Pull-up"))
        for lift in fullBodyA + upper {
            #expect(!lift.hasPrefix("Band "), "\(lift) won a full-gym slot")
        }
    }

    /// Beginners start on dumbbells, machines and cables (NASM/ACSM novice guidance), and an
    /// advanced movement never lands in their plan while a simpler one fits.
    @Test func beginnersStartOnDumbbellsAndMachines() {
        let fullBodyA = names(WorkoutSessions.fullBodyA, at: .fullGym, experience: .beginner).picked
        #expect(fullBodyA.contains("Goblet squat"))
        #expect(fullBodyA.contains("Dumbbell bench press"))
        #expect(fullBodyA.contains("Dumbbell row"))
        let fullBodyB = names(WorkoutSessions.fullBodyB, at: .fullGym, experience: .beginner).picked
        #expect(fullBodyB.contains("Lat pulldown"), "a beginner's vertical pull should not be a pull-up")
        for lift in fullBodyA + fullBodyB {
            #expect(catalogExercise(lift)?.difficulty != .advanced, "\(lift) is advanced")
        }
    }

    /// A hotel gym without a pull-up bar gets a pulldown for its vertical pull, never a row, and a
    /// dumbbell-only squat slot still gets a goblet squat (dumbbell OR kettlebell).
    @Test func hotelGymPicksFitTheRoom() {
        let upper = names(WorkoutSessions.upper, at: Self.hotelGym, experience: .intermediate).picked
        #expect(upper.contains("Lat pulldown"))
        #expect(!upper.contains("Chin-up") && !upper.contains("Pull-up"), "no bar at this hotel")
        #expect(!upper.contains("Dip"))
        let lower = names(WorkoutSessions.lower, at: Self.hotelGym, experience: .beginner).picked
        #expect(lower.contains("Goblet squat"))
    }

    /// With nothing but bodyweight, the arm slots drop honestly instead of taking an ab wheel and
    /// a bird dog, and the vertical pull drops instead of offering a pull-up with no bar.
    @Test func bodyweightOnlyDropsSlotsItCannotFill() {
        let upper = names(WorkoutSessions.upper, at: Self.park, experience: .intermediate)
        #expect(upper.dropped.contains("Biceps"))
        #expect(upper.dropped.contains("Triceps"))
        #expect(upper.dropped.contains("Vertical pull"))
        #expect(!upper.picked.contains("Ab wheel") && !upper.picked.contains("Bird dog"))
        #expect(upper.picked.contains("Push-up"))
        #expect(upper.picked.contains("Inverted row"))
    }

    /// Core slots no longer all go to "Medicine ball slam": it is a power move that needs a
    /// medicine ball. A full gym gets an anti-rotation press; bare floor gets a dead bug. The core
    /// pick now runs in the activation block, ahead of the lifting.
    @Test func coreSlotsGetARealCoreExercise() {
        let gym = names(WorkoutSessions.fullBodyA, at: .fullGym, experience: .intermediate).activation
        #expect(gym.contains("Pallof press"))
        let floor = names(WorkoutSessions.fullBodyA, at: Self.park, experience: .beginner).activation
        #expect(floor.contains("Dead bug"))
        #expect(!(gym + floor).contains("Medicine ball slam"))
    }

    // MARK: - The rules, over every template, location and level

    private static let allSessions: [WorkoutSessionTemplate] = [
        WorkoutSessions.fullBodyA, WorkoutSessions.fullBodyB, WorkoutSessions.fullBodyC,
        WorkoutSessions.upper, WorkoutSessions.lower, WorkoutSessions.push, WorkoutSessions.pull,
        WorkoutSessions.legs, WorkoutSessions.chest, WorkoutSessions.back, WorkoutSessions.shoulders,
        WorkoutSessions.arms, WorkoutSessions.arnoldChestBack, WorkoutSessions.arnoldShouldersArms,
        WorkoutSessions.sportConditioning,
    ]

    private static var allLocations: [WorkoutLocation] {
        [.fullGym, .home, hotelGym, park] + LocationTemplate.all.map { $0.makeLocation() }
    }

    /// Every pick, in every slot of every template, at every location and level, satisfies the
    /// slot's pattern, plane and primary-muscle requirements and is rep-measured strength work.
    /// Picks are matched back to slots in order, skipping the slots the plan reports as dropped —
    /// except where a short session was filled from other body areas (the owner's fix s3,
    /// 2026-11-10): there the fill picks stand in the first dropped slots, are strength work the
    /// location can run, and are deliberately NOT the dropped slot's own kind of work.
    @Test func everyPickIsEligibleForItsSlot() {
        for session in Self.allSessions {
            for location in Self.allLocations {
                for experience in ExperienceLevel.allCases {
                    let result = names(session, at: location, experience: experience)
                    var remaining = result.picked[...]
                    let liftSlots = session.slots.prefix(experience.maxSlotsPerDay).filter { $0.role != .core }
                    let ownPicks = liftSlots.filter { !result.dropped.contains($0.label) }.count
                    var fills = max(0, result.picked.count - ownPicks)
                    // Core slots run in the activation block; the lifting picks follow the rest in order.
                    for slot in liftSlots where remaining.first != nil || !result.dropped.contains(slot.label) {
                        let isFill = result.dropped.contains(slot.label)
                        if isFill && fills == 0 { continue }
                        guard let name = remaining.popFirst(), let exercise = catalogExercise(name) else {
                            Issue.record("\(session.title) @ \(location.name): no pick for \(slot.label)")
                            break
                        }
                        if isFill {
                            fills -= 1
                            #expect(exercise.modality == .strength && !WorkoutProgram.isEligible(exercise, for: slot),
                                    "\(session.title) @ \(location.name) [\(experience)]: \(name) fills \(slot.label)")
                        } else {
                            #expect(WorkoutProgram.isEligible(exercise, for: slot),
                                    "\(session.title) @ \(location.name) [\(experience)]: \(name) in \(slot.label)")
                        }
                        #expect(WorkoutSafetyFilter.hasEquipment(for: exercise, at: location))
                    }
                }
            }
        }
    }

    /// The rule itself, on the exact mismatches the old picker allowed.
    @Test func eligibilityRejectsTheOldMismatches() throws {
        let biceps = WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps])
        let verticalPull = WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull,
                                           plane: .vertical, muscles: [.lats, .upperBack])
        let squat = WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes])
        let core = WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core)
        let abWheel = try #require(catalogExercise("Ab wheel"))
        let cableRow = try #require(catalogExercise("Cable row"))
        let boxJump = try #require(catalogExercise("Box jump"))
        let plank = try #require(catalogExercise("Plank"))
        let stretch = try #require(catalogExercise("Low lunge stretch"))
        let lunge = WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes])
        #expect(!WorkoutProgram.isEligible(abWheel, for: biceps))
        #expect(!WorkoutProgram.isEligible(cableRow, for: verticalPull))
        #expect(!WorkoutProgram.isEligible(boxJump, for: squat), "plyometrics are not squat-slot strength work")
        #expect(!WorkoutProgram.isEligible(stretch, for: lunge), "a stretch is not lunge-slot strength work")
        #expect(WorkoutProgram.isEligible(plank, for: core), "a hold is prescribed as a hold, so it may fill a core slot")
        #expect(WorkoutProgram.isEligible(try #require(catalogExercise("Lat pulldown")), for: verticalPull))
    }

    // MARK: - Equipment that really gates

    @Test func specificGearGatesTheExercisesThatNeedIt() throws {
        let noBar = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells])
        let withBar = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells, .pullUpBar, .weightBench, .medicineBall])
        for name in ["Pull-up", "Chin-up", "Hanging leg raise", "Dumbbell bench press", "Medicine ball slam"] {
            let exercise = try #require(catalogExercise(name))
            #expect(!WorkoutSafetyFilter.hasEquipment(for: exercise, at: noBar), "\(name) without its gear")
            #expect(WorkoutSafetyFilter.hasEquipment(for: exercise, at: withBar), "\(name) with its gear")
        }
        let bench = try #require(catalogExercise("Dumbbell bench press"))
        #expect(WorkoutSafetyFilter.missingEquipment(for: bench, at: noBar) == [GymEquipment.weightBench.displayName])
    }

    /// Any one listed tool is enough: a goblet squat is a dumbbell OR kettlebell movement.
    @Test func alternativeEquipmentCountsAsAvailable() throws {
        let goblet = try #require(catalogExercise("Goblet squat"))
        let dumbbellsOnly = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells])
        #expect(WorkoutSafetyFilter.hasEquipment(for: goblet, at: dumbbellsOnly))
        #expect(!WorkoutSafetyFilter.hasEquipment(for: goblet, at: Self.park))
    }

    // MARK: - Catalog curation

    /// Every bundled push and pull names its plane, so a plane slot can never be fooled by an
    /// untagged row; holds and carries are timed; jumps and throws are power work.
    @Test func bundledCatalogIsCurated() {
        let catalog = WorkoutExerciseCatalog.baseExercises
        for exercise in catalog where exercise.modality == .strength
            && (exercise.movementPattern == .push || exercise.movementPattern == .pull) {
            #expect(exercise.plane != nil, "\(exercise.name) has no plane")
        }
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0) })
        for timed in ["Plank", "Side plank", "Hollow hold", "Farmer's carry", "Suitcase carry"] {
            #expect(byName[timed]?.measure == .seconds, "\(timed) should be timed")
        }
        for power in ["Box jump", "Broad jump", "Lateral bound", "Medicine ball slam", "Clean", "Snatch"] {
            #expect(byName[power]?.modality == .power, "\(power) should be power work")
        }
    }

    /// A custom row keeps its persisted shape: the curation keys are written only when they differ
    /// from their defaults, so a synced custom exercise is byte-for-byte what older builds expect.
    @Test func customRowsEncodeWithoutTheCurationKeys() throws {
        let custom = ExerciseTarget(name: "Sled push", primaryMuscles: [.quads], equipment: .none, movementPattern: .push)
        let data = try JSONEncoder().encode(custom)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["name", "primaryMuscles", "secondaryMuscles", "equipment", "movementPattern", "inputKind"])
        #expect(try JSONDecoder().decode(ExerciseTarget.self, from: data) == custom)
    }

    /// An unknown token from a newer catalog falls back to the default instead of throwing — a
    /// custom row lives in the synced settings blob, where one throw would fail the whole decode.
    @Test func unknownCurationTokensFallBackToDefaults() throws {
        let json = """
        {"name": "Future move", "primaryMuscles": ["chest"], "modality": "aquatic", "difficulty": 9,
         "measure": "meters", "plane": "diagonal", "alternativeEquipment": ["hoverboard", "dumbbell"],
         "requiredGear": ["sled", "weightBench"]}
        """
        let decoded = try JSONDecoder().decode(ExerciseTarget.self, from: Data(json.utf8))
        #expect(decoded.modality == .strength)
        #expect(decoded.difficulty == .standard)
        #expect(decoded.measure == .reps)
        #expect(decoded.plane == nil)
        #expect(decoded.alternativeEquipment == [.dumbbell])
        #expect(decoded.requiredGear == [.weightBench])
    }

    // MARK: - Rotation by the last logged split day

    /// The weekday rotation gave someone training Monday and Wednesday on Full Body ×2 session A
    /// every time. Rotation now follows what was logged: A, then B, then A.
    @Test func rotationAdvancesFromTheLastLoggedDay() {
        let split = WorkoutSplitCatalog.fullBody2
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: []) == 0)
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: [["Full Body A"]]) == 1)
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: [["Full Body B"], ["Full Body A"]]) == 0)
    }

    /// Workouts outside the split (a walk, a class) are skipped over to the last split day.
    @Test func rotationSkipsWorkoutsOutsideTheSplit() {
        let split = WorkoutSplitCatalog.fullBody3
        let history = [["Evening walk"], ["Yoga"], ["Full Body B"]]
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: history) == 2)
    }

    /// A repeated day (Upper twice in Upper/Lower) still alternates.
    @Test func rotationAlternatesARepeatedDay() {
        let split = WorkoutSplitCatalog.upperLower4
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: [["Upper"]]) == 1)
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: [["Lower"]]) == 2)
    }

    /// A two-session day is recognized by its time-labelled names, and the day that shares the
    /// most names wins: morning easy cardio + evening push is Day 3, not Day 1.
    @Test func rotationMatchesMultiSessionDaysByMostSharedNames() {
        let split = WorkoutSplitCatalog.cardioStrength4
        let dayThree = [["Morning · Easy cardio", "Evening · Push"]]
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: dayThree) == 3)
    }

    /// The scan is bounded: a split day logged further back than the lookback does not count.
    @Test func rotationLookbackIsBounded() {
        let split = WorkoutSplitCatalog.fullBody3
        let filler = Array(repeating: ["Walk"], count: WorkoutProgram.rotationLookbackDays)
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: filler + [["Full Body A"]]) == 0)
    }


    // MARK: - The smaller planner fixes (e8, 2026-11-10)

    /// Logging only the morning cardio of a two-session day used to match the earliest day with
    /// that session and send the rotation back. It now carries on from the day logged before it.
    @Test func aPartlyLoggedTwoSessionDayDoesNotRewindTheRotation() {
        let split = WorkoutSplitCatalog.cardioStrength4
        let dayThreeMorningOnly = [["Morning · Easy cardio"], ["Morning · Intervals", "Evening · Lower"]]
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: dayThreeMorningOnly) == 3)
        // After day 4 the rotation wraps, so the same morning session is day 1's.
        let dayOneMorningOnly = [["Morning · Easy cardio"], ["Morning · Steady cardio", "Evening · Pull"]]
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: dayOneMorningOnly) == 1)
        // With nothing logged before it, the earliest day it fits, as before.
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: [["Morning · Easy cardio"]]) == 1)
        // A whole day logged is never ambiguous.
        #expect(WorkoutProgram.nextDayIndex(in: split, recentSessionNames: [["Morning · Easy cardio", "Evening · Push"]]) == 3)
    }

    /// Cardio machines alternate from one cardio day to the next: the seed is the count of cardio
    /// sessions logged, not the cardio day's fixed place in the split.
    @Test func cardioMachinesAlternateFromOneCardioDayToTheNext() throws {
        let split = WorkoutSplitCatalog.dailyMove
        #expect(WorkoutProgram.cardioSessionsLogged(in: split, recentSessionNames: []) == 0)
        let history = [["Full Body A"], ["Easy cardio"], ["Evening walk"], ["Full Body B"], ["Easy cardio", "Stretch"]]
        #expect(WorkoutProgram.cardioSessionsLogged(in: split, recentSessionNames: history) == 2)
        #expect(WorkoutProgram.cardioSessionsLogged(in: WorkoutSplitCatalog.ppl3, recentSessionNames: history) == 0)
        let gym = WorkoutLocation(name: "Garage", ownedEquipment: [.exerciseBike, .rowingMachine])
        func machine(seed: Int) throws -> String {
            let plan = WorkoutProgram.dayPlan(goal: .wellness, intensity: .moderate, profile: WorkoutProfile(), location: gym,
                                              context: "", split: split, rotationIndex: 1, cardioSeed: seed)
            return try #require(WorkoutCardioMachines.machine(in: plan.sessions.first?.suggestion.exercises ?? ""))
        }
        #expect(try machine(seed: 0) != machine(seed: 1), "the same cardio day names the other machine next time")
        #expect(try machine(seed: 0) == machine(seed: 2))
    }

    /// An exercise a coach defines gets the traits the filters read: a pull-up's plane, bar and
    /// difficulty, a stretch's modality, a bench lift's bench.
    @Test func coachDefinedExercisesGetDefaultTraits() {
        func traits(_ name: String, _ muscles: Set<MuscleGroup>, _ equipment: Equipment, _ pattern: MovementPattern) -> ExerciseTarget {
            CoachExerciseTraits.applied(to: ExerciseTarget(name: name, primaryMuscles: muscles, equipment: equipment, movementPattern: pattern))
        }
        let pullUp = traits("Weighted pull-up", [.lats], .bodyweight, .pull)
        #expect(pullUp.plane == .vertical && pullUp.difficulty == .advanced && pullUp.requiredGear == [.pullUpBar])
        #expect(!WorkoutSafetyFilter.hasEquipment(for: pullUp, at: WorkoutLocation(name: "Room", ownedEquipment: [])))
        #expect(!WorkoutProgram.isEligible(pullUp, for: WorkoutSessions.upper.slots[1]), "a pull-up is no horizontal pull")
        #expect(!InjuryLimits(mildAreas: [.upperBack]).allows(traits("Weighted pull-up", [.upperBack], .bodyweight, .pull)))

        let row = traits("Chest-supported dumbbell row", [.upperBack], .dumbbell, .pull)
        #expect(row.plane == .horizontal && row.difficulty == .foundational)
        let press = traits("Incline dumbbell bench press", [.chest], .dumbbell, .push)
        #expect(press.plane == .horizontal && press.requiredGear == [.weightBench])
        #expect(traits("Arnold press", [.frontDelts], .dumbbell, .push).plane == .vertical)
        #expect(traits("Incline push-up", [.chest], .bodyweight, .push).requiredGear.isEmpty)

        let stretch = traits("Couch stretch", [.quads], .bodyweight, .isolation)
        #expect(stretch.modality == .mobility)
        #expect(!WorkoutProgram.isEligible(stretch, for: WorkoutSessions.legs.slots[0]), "a stretch fills no lifting slot")
        #expect(traits("Tuck jump", [.quads], .bodyweight, .squat).modality == .power)
        #expect(traits("Assisted pull-up", [.lats], .machine, .pull).difficulty == .foundational)

        let plain = traits("Hammer curl", [.biceps], .dumbbell, .isolation)
        #expect(plain.plane == nil && plain.modality == .strength && plain.difficulty == .standard && plain.requiredGear.isEmpty)
    }
}
