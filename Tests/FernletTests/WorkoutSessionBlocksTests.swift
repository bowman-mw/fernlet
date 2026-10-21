import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the session layout the owner chose on 2026-10-19 — stretch, activate (core, balance,
/// jumps), lift, any cardio, cool down — and the timed steps that carry it through the guided run.
///
/// Covers the plan the engine builds (block order, the owner's warm-up flow, light activation,
/// cool-down for the worked muscles, holds and carries back in their slots, the plan text a log
/// records), what an injury note removes, the run state's hold window and block skip, and the
/// small surfaces that read a timed step (the history parser, the spoken transition, the editor).
@MainActor
struct WorkoutSessionBlocksTests {

    // MARK: - Fixtures

    private static let park = WorkoutLocation(name: "Park", ownedEquipment: [])

    private func session(
        _ template: WorkoutSessionTemplate,
        at location: WorkoutLocation = .fullGym,
        profile: WorkoutProfile = WorkoutProfile(experience: .intermediate),
        goal: GoalType = .strength,
        intensity: WorkoutIntensity = .moderate
    ) -> WorkoutProgram.SessionSuggestion? {
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced,
                                  goalFit: [goal], days: [WorkoutSplitDay(title: "Day", sessions: [template])])
        return WorkoutProgram.dayPlan(
            goal: goal, intensity: intensity, profile: profile, location: location,
            context: "", split: split, rotationIndex: 0
        ).sessions.first
    }

    private func steps(_ session: WorkoutProgram.SessionSuggestion, in block: SessionBlock) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == block }
    }

    // MARK: - Layout

    /// Every lifting session runs in the owner's order, and every block is present on a full
    /// strength day at a full gym.
    @Test func sessionsRunInTheOwnersOrder() throws {
        let order = SessionBlock.allCases
        for template in [WorkoutSessions.fullBodyA, WorkoutSessions.upper, WorkoutSessions.lower, WorkoutSessions.sportConditioning] {
            let built = try #require(session(template, goal: .sportsPrep))
            let positions = built.exercises.compactMap { order.firstIndex(of: $0.block) }
            #expect(positions == positions.sorted(), "\(template.title) is out of block order")
        }
        let lower = try #require(session(WorkoutSessions.lower))
        for block in [SessionBlock.warmUp, .activation, .lifting, .coolDown] {
            #expect(!steps(lower, in: block).isEmpty, "Lower has no \(block) block")
        }
    }

    /// The warm-up is the owner's flow, step for step: forward fold, lunge, fold, side lunge, lunge,
    /// lying hamstring — left leg, then all of it for the right — then butterfly, yoga, a balancing
    /// quad stretch each side, the wide-leg fold and the arm stretches, with short holds.
    @Test func warmUpIsTheOwnersFlow() throws {
        let warmUp = steps(try #require(session(WorkoutSessions.fullBodyA)), in: .warmUp)
        #expect(warmUp.map(\.name) == WorkoutSessionBlocks.warmUpFlow.map(\.name))
        #expect(warmUp.count == 23)
        #expect(warmUp.prefix(6).map(\.name) == [
            "Standing forward fold", "Low lunge stretch", "Standing forward fold",
            "Side lunge stretch", "Low lunge stretch", "Lying hamstring stretch",
        ])
        #expect(warmUp[1].side == .left && warmUp[7].side == .right, "the left leg goes first, then the right")
        #expect(warmUp.allSatisfy { ($0.holdSeconds ?? 0) <= 30 }, "warm-up holds stay at 30 s or less")
        #expect(warmUp.allSatisfy { $0.sets == 1 && $0.fromCatalog })
    }

    /// A knee note drops the lunge stretches and the jumps, exactly as it drops lunges and squats.
    @Test func injuryNotesShapeTheWarmUpAndActivation() throws {
        let knees = WorkoutProfile.fromOnboarding(level: "intermediate", interests: "", constraints: "bad knee")
        let built = try #require(session(WorkoutSessions.lower, profile: knees))
        let names = Set(built.exercises.map(\.name))
        #expect(!names.contains("Low lunge stretch"))
        #expect(!names.contains("Side lunge stretch"))
        #expect(!names.contains("Squat jump"))
    }

    /// The core slot runs light, ahead of the lifting: two sets, a short rest. Balance comes with it.
    @Test func activationIsLightAndComesFirst() throws {
        let activation = steps(try #require(session(WorkoutSessions.fullBodyA)), in: .activation)
        let core = try #require(activation.first)
        #expect(core.name == "Pallof press")
        #expect(core.sets == 2 && core.restSecondsOverride == 20)
        #expect(activation.contains { $0.name == "Single-leg stance" && $0.side == .left })
        #expect(activation.contains { $0.name == "Single-leg stance" && $0.side == .right })
    }

    /// Jumps prime a trained lifter's leg day; never a beginner's, never a light day, never upper body.
    @Test func jumpsOnlyWhereTheyFit() throws {
        func hasJumps(_ built: WorkoutProgram.SessionSuggestion?) -> Bool {
            (built?.exercises ?? []).contains { $0.block == .activation && $0.name == "Squat jump" }
        }
        #expect(hasJumps(session(WorkoutSessions.lower)))
        #expect(!hasJumps(session(WorkoutSessions.lower, profile: WorkoutProfile(experience: .beginner))))
        #expect(!hasJumps(session(WorkoutSessions.lower, intensity: .light)))
        #expect(!hasJumps(session(WorkoutSessions.lower, goal: .recovery)))
        #expect(!hasJumps(session(WorkoutSessions.upper)))
    }

    /// The cool-down stretches what the lifting worked, both sides of a one-sided stretch, with
    /// long holds.
    @Test func coolDownStretchesTheWorkedMuscles() throws {
        let lower = steps(try #require(session(WorkoutSessions.lower)), in: .coolDown)
        let lowerMuscles: Set<MuscleGroup> = [.quads, .hamstrings, .glutes, .calves, .adductors, .abductors]
        #expect(!lower.isEmpty)
        for step in lower {
            let target = try #require(WorkoutExerciseCatalog.exercise(named: step.name))
            #expect(!target.primaryMuscles.isDisjoint(with: lowerMuscles), "\(step.name) after a lower day")
            #expect(step.holdSeconds == WorkoutSessionBlocks.coolDownHoldSeconds)
            if target.unilateral {
                #expect(lower.contains { $0.name == step.name && $0.side == .left })
                #expect(lower.contains { $0.name == step.name && $0.side == .right })
            }
        }
        let upper = steps(try #require(session(WorkoutSessions.upper)), in: .coolDown).map(\.name)
        #expect(upper.contains("Doorway chest stretch"))
    }

    /// Holds and carries are back in their slots, prescribed as holds: Full Body C's carry is a
    /// farmer's carry for 40 seconds on a strength goal.
    @Test func carriesAndHoldsArePrescribedAsHolds() throws {
        let lifting = steps(try #require(session(WorkoutSessions.fullBodyC)), in: .lifting)
        let carry = try #require(lifting.first { $0.name == "Farmer's carry" })
        #expect(carry.holdSeconds == 40)
        #expect(carry.reps == "40 s")
        #expect(carry.line == "Farmer's carry - \(carry.sets) x 40 s")
    }

    // MARK: - Plan text, progression, adjustment

    /// The log records one summary line per stretch block, not twenty-three stretch lines.
    @Test func planTextSummarizesTheStretchBlocks() throws {
        let built = try #require(session(WorkoutSessions.lower))
        let lines = built.suggestion.exercises.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("Warm-up stretch flow - ") == true)
        #expect(lines.last?.hasPrefix("Cool-down stretches - ") == true)
        #expect(!lines.contains { $0.contains("Low lunge stretch") })
        #expect(lines.contains { $0.hasPrefix("Back squat - ") })
    }

    /// Only the lifting block progresses: stretches and activation work are never counted.
    @Test func progressionNamesAreTheLiftingBlock() throws {
        let built = try #require(session(WorkoutSessions.lower))
        #expect(Set(built.catalogExerciseNames) == Set(steps(built, in: .lifting).map(\.name)))
        #expect(!built.catalogExerciseNames.contains("Standing forward fold"))
        #expect(!built.catalogExerciseNames.contains("Pallof press"))
    }

    /// An AI adjustment replaces the lifting block and keeps the warm-up, activation and cool-down.
    @Test func adjustmentKeepsTheBlocksAroundTheLifting() throws {
        let built = try #require(session(WorkoutSessions.lower))
        let swap = [PrescribedExercise(name: "Leg press", sets: 3, reps: "10", role: .main, fromCatalog: true)]
        let adjusted = WorkoutProgram.applyAdjustment(to: built, exercises: swap)
        #expect(steps(adjusted, in: .lifting).map(\.name) == ["Leg press"])
        #expect(steps(adjusted, in: .warmUp) == steps(built, in: .warmUp))
        #expect(steps(adjusted, in: .coolDown) == steps(built, in: .coolDown))
        #expect(steps(adjusted, in: .activation) == steps(built, in: .activation))
    }

    /// The editor edits the lifting rows only, so the twenty-odd stretches never hit its row cap.
    @Test func editorSeesTheLiftingRowsOnly() throws {
        let built = try #require(session(WorkoutSessions.lower))
        #expect(GuidedWorkoutEditorSheet.liftingRows(of: built) == steps(built, in: .lifting))
    }

    // MARK: - Guided run

    private func run(_ exercises: [GuidedWorkoutRunState.Exercise], at start: Date) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-19", intensityRaw: "moderate", title: "Lower",
            suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: exercises, setStartedAt: start
        )
    }

    private func step(_ name: String, block: String, hold: Int? = nil, sets: Int = 1) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: hold.map { "\($0) s" } ?? "8", roleRaw: "accessory", fromCatalog: true,
            restSeconds: 0, holdSeconds: hold, blockRaw: block
        )
    }

    /// The run's block tokens are the domain's raw values — a run in progress stores them.
    @Test func blockTokensMatchTheDomain() {
        #expect(GuidedWorkoutRunState.BlockToken.warmUp == SessionBlock.warmUp.rawValue)
        #expect(GuidedWorkoutRunState.BlockToken.activation == SessionBlock.activation.rawValue)
        #expect(GuidedWorkoutRunState.BlockToken.lifting == SessionBlock.lifting.rawValue)
        #expect(GuidedWorkoutRunState.BlockToken.cardio == SessionBlock.cardio.rawValue)
        #expect(GuidedWorkoutRunState.BlockToken.coolDown == SessionBlock.coolDown.rawValue)
    }

    /// A timed step's hold starts after the lead-in and lasts its hold; moving on re-stamps the start.
    @Test func holdWindowFollowsTheLeadIn() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var state = run([step("Standing forward fold", block: "warmUp", hold: 20),
                         step("Back squat", block: "lifting", sets: 3)], at: start)
        let window = try #require(state.holdWindow)
        let leadIn = TimeInterval(GuidedWorkoutRunState.holdLeadInSeconds)
        #expect(window.lowerBound == start.addingTimeInterval(leadIn))
        #expect(window.upperBound == start.addingTimeInterval(leadIn + 20))
        let later = start.addingTimeInterval(40)
        state.markSetDone(now: later)
        #expect(state.exerciseIndex == 1 && state.setStartedAt == later)
        #expect(state.holdWindow == nil, "a rep-counted set has no hold window")
        #expect(state.contentState.holdEndsAt == nil)
    }

    /// "Skip warm-up" jumps to the first step after it; "Skip cool-down" finishes and logs.
    @Test func skipBlockLeavesTheWarmUpAndFinishesTheCoolDown() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var state = run([step("Standing forward fold", block: "warmUp", hold: 20),
                         step("Cat-cow", block: "warmUp", hold: 30),
                         step("Back squat", block: "lifting", sets: 3),
                         step("Calf stretch", block: "coolDown", hold: 45)], at: start)
        #expect(state.canSkipBlock)
        state.skipBlock(now: start.addingTimeInterval(5))
        #expect(state.exerciseIndex == 2 && state.isWorking)
        #expect(!state.canSkipBlock, "the lifting block is not skipped wholesale")
        state.exerciseIndex = 3
        state.skipBlock(now: start.addingTimeInterval(600))
        #expect(state.isFinishedNaturally, "skipping the cool-down still logs the session")
    }

    /// The header counts within the block: the third stretch is "3 of 23", not "3 of 40".
    @Test func blockPositionCountsWithinTheBlock() {
        var state = run([step("A", block: "warmUp", hold: 20), step("B", block: "warmUp", hold: 20),
                         step("C", block: "lifting", sets: 3)], at: Date())
        state.exerciseIndex = 1
        #expect(state.blockPosition.index == 2 && state.blockPosition.count == 2)
        state.exerciseIndex = 2
        #expect(state.blockPosition.index == 1 && state.blockPosition.count == 1)
    }

    // MARK: - Surfaces that read a timed step

    /// A logged hold reads back as seconds with no rep count, so no tally calls it 30 reps.
    @Test func parserReadsAHoldAsSeconds() throws {
        let plank = try #require(ExerciseLineParser.parse("Plank - 2 x 30 s"))
        #expect(plank.sets == 2 && plank.reps == "30 s" && plank.repsCount == nil)
        let squat = try #require(ExerciseLineParser.parse("Back squat - 3 x 5"))
        #expect(squat.repsCount == 5)
        #expect(ExerciseLineParser.parse("Warm-up stretch flow - 9 min") == nil)
    }

    /// Moving onto a one-sided stretch says its side, never "Set 1 of 1".
    @Test func announcementSaysTheSide() throws {
        let start = Date()
        var lunge = step("Low lunge stretch", block: "warmUp", hold: 20)
        lunge.sideRaw = "left"
        let before = run([step("Standing forward fold", block: "warmUp", hold: 20), lunge], at: start)
        var after = before
        after.markSetDone(now: start)
        let spoken = try #require(GuidedRunAnnouncement.spoken(from: before, to: after))
        let sentence = String(localized: spoken.sentence)
        #expect(sentence.contains("Low lunge stretch") && sentence.contains("left side"))
        #expect(!sentence.contains("Set 1 of 1"))
    }
}
