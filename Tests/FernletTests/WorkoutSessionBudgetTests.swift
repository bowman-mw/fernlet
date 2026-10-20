import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the session-time budget and the stretch switches (2026-10-20, idea 5): every budget across
/// the goals and splits fits or says how long it runs, the trim order (short warm-up, cool-down
/// stretches, accessory work, accessory sets, the warm-up ramp cut to one set, main-lift sets), main
/// lifts never dropped, the injury
/// limits and the 48-hour guard holding after trimming, the short warm-up chosen by the day's muscles,
/// the Off switches, the cardio cap, the estimate the plan card and the runner share, and the
/// settings' tolerant decoding.
@MainActor
struct WorkoutSessionBudgetTests {

    // MARK: - Fixtures

    func probe(_ template: WorkoutSessionTemplate, goal: GoalType) -> TrainingSplit {
        TrainingSplit(id: "probe", name: "Probe", summary: "", specificity: .balanced, goalFit: [goal],
                      days: [WorkoutSplitDay(title: "Day", sessions: [template])])
    }

    func plan(
        _ split: TrainingSplit, day: Int = 0, goal: GoalType = .strength,
        profile: WorkoutProfile = WorkoutProfile(experience: .intermediate),
        options: WorkoutSessionOptions = WorkoutSessionOptions(),
        recent: WorkoutRecoveryGuard.RecentTraining? = nil
    ) -> WorkoutProgram.DayPlan {
        WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: profile, location: .fullGym, context: "",
            split: split, rotationIndex: day, recent: recent, options: options
        )
    }

    func session(
        _ template: WorkoutSessionTemplate, goal: GoalType = .strength,
        profile: WorkoutProfile = WorkoutProfile(experience: .intermediate),
        options: WorkoutSessionOptions = WorkoutSessionOptions(),
        recent: WorkoutRecoveryGuard.RecentTraining? = nil
    ) throws -> WorkoutProgram.SessionSuggestion {
        try #require(plan(probe(template, goal: goal), goal: goal, profile: profile, options: options, recent: recent)
            .sessions.first)
    }

    func steps(_ session: WorkoutProgram.SessionSuggestion, in block: SessionBlock) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == block }
    }

    func timed(_ name: String, hold: Int, side: ExerciseSide? = nil, block: SessionBlock) -> PrescribedExercise {
        PrescribedExercise(name: name, sets: 1, reps: "\(hold) s", role: .accessory, fromCatalog: true,
                           restSecondsOverride: 0, block: block, holdSeconds: hold, side: side)
    }

    func lift(_ name: String, sets: Int, rest: Int, role: SlotRole, block: SessionBlock = .lifting) -> PrescribedExercise {
        PrescribedExercise(name: name, sets: sets, reps: "8", role: role, fromCatalog: true,
                           restSecondsOverride: rest, block: block)
    }

    /// A session whose every cost is fixed by overrides, so the trims can be traced by hand:
    /// warm-up 10 × (30 + 5) = 350 s (short: 4 steps, 140 s); activation 110 + 50 + 135 = 295 s;
    /// lifting 720 + 315 + 255 = 1,290 s; cool-down 4 × 50 = 200 s — 2,135 s in all.
    func tracedBlocks() -> (blocks: WorkoutSessionBudget.Blocks, short: [PrescribedExercise]) {
        let warmUp = (1...10).map { timed("Stretch \($0)", hold: 30, block: .warmUp) }
        let activation = [
            lift("Dead bug", sets: 2, rest: 20, role: .core, block: .activation),
            timed("Single-leg stance", hold: 20, side: .left, block: .activation),
            timed("Single-leg stance", hold: 20, side: .right, block: .activation),
            lift("Squat jump", sets: 2, rest: 45, role: .accessory, block: .activation),
        ]
        let lifting = [
            lift("Back squat", sets: 4, rest: 180, role: .main),
            lift("Lunge", sets: 3, rest: 90, role: .accessory),
            lift("Calf raise", sets: 3, rest: 60, role: .accessory),
        ]
        let coolDown = ["A", "B", "C", "D"].map { timed("Cool \($0)", hold: 45, block: .coolDown) }
        let blocks = WorkoutSessionBudget.Blocks(warmUp: warmUp, activation: activation, lifting: lifting, coolDown: coolDown)
        return (blocks, Array(warmUp.prefix(4)))
    }

    func isInFlowOrder(_ steps: [PrescribedExercise]) -> Bool {
        var flow = WorkoutSessionBlocks.warmUpFlow[...]
        for step in steps {
            guard let index = flow.firstIndex(where: { $0.name == step.name && $0.side == step.side }) else { return false }
            flow = flow[flow.index(after: index)...]
        }
        return true
    }

    // MARK: - Tokens and the default

    /// The raw values persist in the synced settings; renaming one resets someone's choice.
    @Test func frozenSessionTokens() {
        #expect(WorkoutSessionLength.allCases.map(\.rawValue) == ["noLimit", "min20", "min30", "min45", "min60"])
        #expect(WorkoutSessionLength.allCases.map(\.minutes) == [nil, 20, 30, 45, 60])
        #expect(WorkoutWarmUpMode.allCases.map(\.rawValue) == ["full", "short", "off"])
        #expect(WorkoutCoolDownMode.allCases.map(\.rawValue) == ["full", "off"])
    }

    /// No limit, the full flow and the cool-down — the default — plan exactly as before: the owner's
    /// 23 steps as written, the cool-down, and no time note.
    @Test func theDefaultIsTheOwnersFlowAsWritten() throws {
        let built = try session(WorkoutSessions.upper)
        let warmUp = steps(built, in: .warmUp)
        let flow = WorkoutSessionBlocks.warmUpFlow
        #expect(warmUp.map(\.name) == flow.map(\.name))
        #expect(warmUp.map(\.side) == flow.map(\.side))
        #expect(warmUp.map(\.holdSeconds) == flow.map { Optional($0.seconds) })
        #expect(!steps(built, in: .coolDown).isEmpty)
        #expect(!built.suggestion.notes.contains("Fitted to") && !built.suggestion.notes.contains("Runs about"))
    }

    // MARK: - Every budget, every goal and split

    /// Each budget across every goal and split day stays at or under the budget by the plan card's
    /// estimate, or its note says how long it runs — in the card's own minutes.
    @Test func everyBudgetFitsOrSaysHowLongItRuns() {
        for goal in GoalType.allCases {
            for split in WorkoutSplitCatalog.all {
                for day in split.days.indices {
                    for length in WorkoutSessionLength.allCases {
                        guard let budget = length.minutes else { continue }
                        let built = plan(split, day: day, goal: goal, options: WorkoutSessionOptions(length: length))
                        for session in built.sessions {
                            let seconds = WorkoutSessionTime.seconds(of: session.exercises, goal: goal)
                            let minutes = WorkoutSessionTime.minutes(of: session.exercises, goal: goal)
                            #expect(seconds <= budget * 60 || session.suggestion.notes.contains("Runs about \(minutes) min"),
                                    "\(split.id) day \(day), \(goal.rawValue), \(budget) min: \(session.title) runs \(minutes) min")
                        }
                    }
                }
            }
        }
    }

    /// Main lifts are never dropped, and nothing is ever given more sets than the open plan; main
    /// lifts keep at least two (or what they had).
    @Test func mainLiftsAreNeverDroppedAndNothingGrows() {
        for goal in [GoalType.strength, .wellness, .weightManagement] {
            for split in WorkoutSplitCatalog.all {
                for day in split.days.indices {
                    let open = plan(split, day: day, goal: goal)
                    let fitted = plan(split, day: day, goal: goal, options: WorkoutSessionOptions(length: .min20))
                    for (before, after) in zip(open.sessions, fitted.sessions) {
                        let mains = Set(before.exercises.filter { $0.block == .lifting && $0.role == .main }.map(\.name))
                        let kept = after.exercises.filter { $0.block == .lifting }
                        #expect(mains.isSubset(of: Set(kept.map(\.name))), "\(split.id) day \(day): a main lift was dropped")
                        for step in kept {
                            let original = before.exercises.first { $0.block == .lifting && $0.name == step.name }
                            #expect(step.sets <= (original?.sets ?? step.sets), "\(step.name) grew")
                            if step.role == .main, let original {
                                #expect(step.sets >= min(original.sets, WorkoutSessionBudget.minimumSets))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - The trim order

    /// A 10-minute budget the session can't meet walks every step in order, to each floor: the
    /// short warm-up, two cool-down stretches, the jumps, the accessory lifts from the last, the
    /// balance drill, then main-lift sets down to two — and says how long it runs.
    @Test func theTrimsFollowTheOwnersOrderToEachFloor() {
        let traced = tracedBlocks()
        let outcome = WorkoutSessionBudget.fit(traced.blocks, budgetMinutes: 10, goal: .strength, shortWarmUp: traced.short)
        #expect(outcome.trims == [
            .shortWarmUp, .coolDownStretch("Cool D"), .coolDownStretch("Cool C"),
            .accessory("Squat jump"), .accessory("Calf raise"), .accessory("Lunge"), .accessory("Single-leg stance"),
            .mainSet("Back squat"), .mainSet("Back squat"),
        ])
        #expect(outcome.estimatedSeconds == 620 && !outcome.fits)
        #expect(outcome.blocks.activation.map(\.name) == ["Dead bug"], "the activation keeps one move")
        #expect(outcome.blocks.lifting.map(\.name) == ["Back squat"])
        #expect(outcome.blocks.lifting.first?.sets == 2)
        #expect(outcome.blocks.coolDown.map(\.name) == ["Cool A", "Cool B"])
        #expect(outcome.note?.hasPrefix("Runs about 11 min") == true)
    }

    /// Trimming stops as soon as the session fits: 30 minutes needs only the first three steps, 20
    /// minutes the accessory lifts too, and 36 minutes nothing at all.
    @Test func trimmingStopsAsSoonAsItFits() {
        let traced = tracedBlocks()
        let thirty = WorkoutSessionBudget.fit(traced.blocks, budgetMinutes: 30, goal: .strength, shortWarmUp: traced.short)
        #expect(thirty.trims == [.shortWarmUp, .coolDownStretch("Cool D"), .coolDownStretch("Cool C"), .accessory("Squat jump")])
        #expect(thirty.fits && thirty.estimatedSeconds == 1_690)
        #expect(thirty.note == "Fitted to 30 min: shorter warm-up; fewer cool-down stretches; left out Squat jump.")
        let twenty = WorkoutSessionBudget.fit(traced.blocks, budgetMinutes: 20, goal: .strength, shortWarmUp: traced.short)
        #expect(twenty.trims.map(\.stage) == [1, 2, 2, 3, 3, 3])
        #expect(twenty.blocks.lifting.map(\.name) == ["Back squat"])
        #expect(twenty.blocks.activation.contains { $0.name == "Single-leg stance" }, "balance outlasts the accessory lifts")
        let roomy = WorkoutSessionBudget.fit(traced.blocks, budgetMinutes: 36, goal: .strength, shortWarmUp: traced.short)
        #expect(roomy.trims.isEmpty && roomy.note == nil && roomy.blocks == traced.blocks)
    }

    /// With no main lift to fall back on, the last lift stays and its sets come down instead
    /// (step 4), never below two.
    @Test func accessorySetsComeDownWhenALiftMustStay() {
        let blocks = WorkoutSessionBudget.Blocks(
            activation: [lift("Dead bug", sets: 2, rest: 20, role: .core, block: .activation)],
            lifting: [lift("Curl", sets: 4, rest: 60, role: .accessory), lift("Pushdown", sets: 4, rest: 60, role: .accessory)]
        )
        let outcome = WorkoutSessionBudget.fit(blocks, budgetMinutes: 5, goal: .strength)
        #expect(outcome.trims == [.accessory("Pushdown"), .accessorySet("Curl"), .accessorySet("Curl")])
        #expect(outcome.fits && outcome.blocks.lifting.first?.sets == 2)
        #expect(outcome.note == "Fitted to 5 min: left out Pushdown; fewer sets of Curl.")
    }

    /// A back squat at 135 lb behind its warm-up ramp (45, 80 and 110 lb; 45 s each), then a lunge:
    /// 135 + 720 + 315 = 1,170 s.
    func rampedBlocks() -> WorkoutSessionBudget.Blocks {
        let prescription = WeightPrescription(low: 125, high: 145, suggested: 135, step: 5, unit: .lb, confidence: .medium)
        var squat = lift("Back squat", sets: 4, rest: 180, role: .main)
        squat.guidance = LoadGuidance(targetReps: 8, prescription: prescription, equipment: .barbell, unit: .lb)
        let ramp = WorkoutWarmUpSets.steps(for: squat, pattern: .squat)
        return WorkoutSessionBudget.Blocks(lifting: ramp + [squat, lift("Lunge", sets: 3, rest: 90, role: .accessory)])
    }

    func weights(_ steps: [PrescribedExercise]) -> [Double?] {
        steps.map { $0.guidance?.prescription?.suggested }
    }

    /// The warm-up ramp is step 5 (owner's pick R1): after the accessory work and sets, before any
    /// main-lift set, it comes down to its one set nearest 60 % of the working weight.
    @Test func aRampIsCutToItsSixtyPercentSetAfterAccessoriesAndBeforeMainSets() {
        let blocks = rampedBlocks()
        #expect(blocks.lifting.count == 5)
        #expect(WorkoutSessionBudget.Trim.warmUpRamp("Back squat").stage == 5)
        #expect(WorkoutSessionBudget.Trim.mainSet("Back squat").stage == 6)
        let thirteen = WorkoutSessionBudget.fit(blocks, budgetMinutes: 13, goal: .strength)
        #expect(thirteen.trims == [.accessory("Lunge"), .warmUpRamp("Back squat")])
        #expect(thirteen.fits)
        #expect(thirteen.estimatedSeconds == 765)
        let kept = weights(thirteen.blocks.lifting)
        let expectedKept: [Double?] = [80, 135]
        #expect(kept == expectedKept, "the 60 % set and the working sets")
        let workingSets = thirteen.blocks.lifting.last.map(\.sets)
        #expect(workingSets == 4, "no main-lift set came off")
        #expect(thirteen.note == "Fitted to 13 min: left out Lunge; one warm-up set for Back squat.")
        let ten = WorkoutSessionBudget.fit(blocks, budgetMinutes: 10, goal: .strength)
        let stages = ten.trims.map(\.stage)
        #expect(stages == [3, 5, 6])
        #expect(ten.note == "Fitted to 10 min: left out Lunge; fewer sets of Back squat; one warm-up set for Back squat.")
    }

    /// However tight the budget, the ramp keeps one set: it is cut once, never dropped.
    @Test func aRampNeverDropsToNone() {
        let outcome = WorkoutSessionBudget.fit(rampedBlocks(), budgetMinutes: 1, goal: .strength)
        let ramps = outcome.trims.filter { $0 == .warmUpRamp("Back squat") }.count
        #expect(ramps == 1)
        #expect(!outcome.fits)
        let warmUps = outcome.blocks.lifting.filter { WorkoutWarmUpSets.isWarmUpSet($0) }
        let warmUpWeights = weights(warmUps)
        let expected: [Double?] = [80]
        #expect(warmUpWeights == expected)
        let floorSets = outcome.blocks.lifting.last.map(\.sets)
        #expect(floorSets == WorkoutSessionBudget.minimumSets)
        let roomy = WorkoutSessionBudget.fit(rampedBlocks(), budgetMinutes: 60, goal: .strength)
        #expect(roomy.trims.isEmpty, "a session that fits keeps its whole ramp")
    }

    /// A main lift prescribed as accessory work for a mild injury is still a main lift: kept, and
    /// trimmed only as a main lift.
    @Test func anEasedMainLiftIsNeverDropped() {
        let blocks = WorkoutSessionBudget.Blocks(
            lifting: [lift("Leg press", sets: 3, rest: 60, role: .accessory), lift("Calf raise", sets: 3, rest: 60, role: .accessory)],
            mainLift: [true, false]
        )
        let outcome = WorkoutSessionBudget.fit(blocks, budgetMinutes: 1, goal: .strength)
        #expect(outcome.trims == [.accessory("Calf raise"), .mainSet("Leg press")])
        #expect(outcome.blocks.lifting.map(\.name) == ["Leg press"])
        #expect(outcome.note?.hasPrefix("Runs about 3 min") == true)
    }

    /// In the planner, a mild knee's eased squat-slot lift survives a 20-minute budget, and a severe
    /// knee's lunges, lunge stretches and jumps stay out of the trimmed session too.
    @Test func injuryLimitsHoldAfterTrimming() throws {
        let mild = WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild])
        let open = steps(try session(WorkoutSessions.lower, profile: mild), in: .lifting)
        let fitted = try session(WorkoutSessions.lower, profile: mild, options: WorkoutSessionOptions(length: .min20))
        let mainSlotPicks = open.prefix(2).map(\.name)
        #expect(Set(mainSlotPicks).isSubset(of: Set(steps(fitted, in: .lifting).map(\.name))))

        let severe = WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .severe])
        let trimmed = try session(WorkoutSessions.lower, profile: severe,
                                  options: WorkoutSessionOptions(length: .min20, warmUp: .short))
        let names = Set(trimmed.exercises.map(\.name))
        #expect(!names.contains("Low lunge stretch") && !names.contains("Side lunge stretch"))
        #expect(!names.contains("Squat jump"))
        let lunges = trimmed.exercises.filter {
            $0.block == .lifting && WorkoutExerciseCatalog.exercise(named: $0.name)?.movementPattern == .lunge
        }
        #expect(lunges.isEmpty)
    }

    /// The 48-hour guard's lighter sets still hold after trimming: its note stays, and no lift gets
    /// back the set the guard took.
    @Test func theRecoveryGuardHoldsAfterTrimming() throws {
        let recent = WorkoutRecoveryGuard.RecentTraining(hardMuscles: [.quads, .glutes, .hamstrings],
                                                         latestSessionNames: ["Something else"])
        let guarded = try session(WorkoutSessions.lower, recent: recent)
        let fitted = try session(WorkoutSessions.lower, options: WorkoutSessionOptions(length: .min30), recent: recent)
        #expect(guarded.suggestion.notes.contains("One set fewer on"))
        #expect(fitted.suggestion.notes.contains("One set fewer on"))
        for step in steps(fitted, in: .lifting) {
            let before = steps(guarded, in: .lifting).first { $0.name == step.name }
            #expect(step.sets <= (before?.sets ?? step.sets))
        }
    }

    // MARK: - The warm-up and cool-down switches

    /// The short warm-up is a subset of the owner's flow in its order, about four minutes, opening
    /// with the forward fold and keeping both sides of a one-sided stretch; it follows the day —
    /// lower-body stretches on a leg day, the shoulder and arm stretches on upper and push days.
    @Test func theShortWarmUpFollowsTheDaysMuscles() throws {
        let templates = [WorkoutSessions.legs, WorkoutSessions.lower, WorkoutSessions.upper,
                         WorkoutSessions.push, WorkoutSessions.pull, WorkoutSessions.fullBodyA]
        for template in templates {
            let short = steps(try session(template, options: WorkoutSessionOptions(warmUp: .short)), in: .warmUp)
            let holds = short.reduce(0) { $0 + ($1.holdSeconds ?? 0) }
            #expect(holds <= WorkoutSessionBlocks.shortWarmUpSeconds && holds >= 180, "\(template.title): \(holds) s")
            #expect(short.first?.name == "Standing forward fold")
            #expect(isInFlowOrder(short), "\(template.title) reorders the owner's flow")
            for name in Set(short.filter { $0.side != nil }.map(\.name)) {
                #expect(short.filter { $0.name == name && $0.side == .left }.count
                        == short.filter { $0.name == name && $0.side == .right }.count, "\(name) is one-sided")
            }
        }
        let legs = Set(steps(try session(WorkoutSessions.legs, options: WorkoutSessionOptions(warmUp: .short)), in: .warmUp).map(\.name))
        #expect(legs.contains("Low lunge stretch") && legs.contains("Lying hamstring stretch"))
        #expect(!legs.contains("Cross-body shoulder stretch") && !legs.contains("Overhead triceps stretch"))
        for template in [WorkoutSessions.upper, WorkoutSessions.push] {
            let names = Set(steps(try session(template, options: WorkoutSessionOptions(warmUp: .short)), in: .warmUp).map(\.name))
            #expect(names.contains("Cross-body shoulder stretch") && names.contains("Overhead triceps stretch"),
                    "\(template.title) warms up the shoulders and arms")
        }
    }

    /// A budget's first trim swaps the full flow for the same short one the setting picks.
    @Test func aBudgetsFirstTrimIsTheShortWarmUp() throws {
        let short = steps(try session(WorkoutSessions.upper, options: WorkoutSessionOptions(warmUp: .short)), in: .warmUp)
        let fitted = try session(WorkoutSessions.upper, options: WorkoutSessionOptions(length: .min45))
        #expect(steps(fitted, in: .warmUp).map(\.name) == short.map(\.name))
        #expect(fitted.suggestion.notes.contains("shorter warm-up"))
    }

    /// Off leaves the block out — under a budget too — and the plan text loses its summary line.
    @Test func offLeavesTheStretchBlocksOut() throws {
        let built = try session(WorkoutSessions.lower, options: WorkoutSessionOptions(warmUp: .off, coolDown: .off))
        #expect(steps(built, in: .warmUp).isEmpty && steps(built, in: .coolDown).isEmpty)
        #expect(!steps(built, in: .activation).isEmpty && !steps(built, in: .lifting).isEmpty)
        let lines = built.suggestion.exercises.split(separator: "\n").map(String.init)
        #expect(!lines.contains { $0.hasPrefix("Warm-up stretch flow") || $0.hasPrefix("Cool-down stretches") })
        let fitted = try session(WorkoutSessions.lower, options: WorkoutSessionOptions(length: .min20, warmUp: .off))
        #expect(steps(fitted, in: .warmUp).isEmpty)
        #expect(!steps(fitted, in: .coolDown).isEmpty, "the cool-down keeps its own switch")
    }

    // MARK: - Cardio, and the shared estimate

    /// A cardio session is its descriptor, so the budget caps the minutes it names.
    @Test func cardioSessionsCapTheMinutesTheyName() throws {
        let capped = try session(WorkoutSessions.longCardio, goal: .weightManagement,
                                 options: WorkoutSessionOptions(length: .min30))
        #expect(capped.exercises.first?.name == "Steady cardio - 30 min")
        #expect(capped.suggestion.exercises == "Steady cardio - 30 min")
        #expect(capped.suggestion.notes.contains("Shortened to fit 30 min."))
        #expect(WorkoutSessionTime.minutes(of: capped.exercises, goal: .weightManagement) == 30)
        let open = try session(WorkoutSessions.longCardio, goal: .weightManagement)
        #expect(open.exercises.first?.name == "Steady cardio - 40 min")
        let intervals = "Intervals - 8 × 1 min hard / 1 min easy"
        #expect(WorkoutSessionBudget.capped(intervals, length: .min20).text == intervals)
        #expect(WorkoutSessionBudget.capped("Easy cardio - 20 min", length: .min20).note == nil)
    }

    /// The runner reads a descriptor's minutes exactly as the planner does, with the same lead-in,
    /// so a started run counts down from the plan card's estimate.
    @Test func theRunnerTimesStepsLikeThePlanner() {
        let lines = [
            "Easy cardio - 20 min", "Intervals - 8 × 1 min hard / 1 min easy", "Steady cardio - 40 min",
            "Mobility flow - 15 min", "Conditioning intervals - 12 min", "Basketball drills / conditioning - 15 min",
            "Easy walk - 15 min", "Gentle mobility + walk - 12 min", "Optional cardio - 10 min",
            "Full-body bodyweight circuit - 3 rounds", "Cooldown walk", "Gentle stretching or an easy walk - 10 min",
            "Steady cardio – 25 min", "Steady cardio — 25 minutes",
        ]
        for line in lines {
            #expect(GuidedWorkoutRunState.descriptorSeconds(named: line, fallback: WorkoutSessionTime.descriptorFallbackSeconds)
                    == WorkoutSessionTime.descriptorSeconds(line), "\(line)")
        }
        #expect(GuidedWorkoutRunState.holdLeadInSeconds == WorkoutSessionTime.holdLeadInSeconds)
        #expect(WorkoutSessionTime.descriptorSeconds("Conditioning intervals - 12 min") == 720)
    }

    // MARK: - Settings

    func settings(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    func resaved(_ settings: FernletSettings) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(settings))
    }

    func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    /// A blob from before these settings opens with today's behaviour and nothing parked.
    @Test func olderBlobsOpenWithTheDefault() throws {
        let decoded = try settings(#"{"bottleOz": 24}"#)
        #expect(decoded.workoutSessionOptions == WorkoutSessionOptions())
        #expect(decoded.unknownWorkoutSessionLengthToken == nil)
        #expect(decoded.unknownWorkoutWarmUpToken == nil && decoded.unknownWorkoutCoolDownToken == nil)
    }

    /// The three choices ride the settings blob's top level and round-trip.
    @Test func sessionChoicesRoundTripAtTheTopLevel() throws {
        var original = FernletSettings()
        original.workoutSessionLength = .min45
        original.workoutWarmUp = .short
        original.workoutCoolDown = .off
        let json = try object(original)
        #expect(json["workoutSessionLength"] as? String == "min45")
        #expect(json["workoutWarmUp"] as? String == "short")
        #expect(json["workoutCoolDown"] as? String == "off")
        let again = try resaved(original)
        #expect(again.workoutSessionOptions == WorkoutSessionOptions(length: .min45, warmUp: .short, coolDown: .off))
        #expect(again.parkedUnknownKeys.isEmpty, "the new keys are known keys, never parked")
    }

    /// A newer build's values park instead of failing the decode, plan as the default here, and
    /// survive this build's re-save; the main keys carry tokens an older build knows.
    @Test func newerTokensParkAndSurviveAReSave() throws {
        let decoded = try settings(#"{"workoutSessionLength":"min90","workoutWarmUp":"dynamic","workoutCoolDown":"short"}"#)
        #expect(decoded.workoutSessionOptions == WorkoutSessionOptions())
        #expect(decoded.unknownWorkoutSessionLengthToken == "min90")
        #expect(decoded.unknownWorkoutWarmUpToken == "dynamic")
        #expect(decoded.unknownWorkoutCoolDownToken == "short")
        let again = try resaved(decoded)
        #expect(again.unknownWorkoutSessionLengthToken == "min90")
        #expect(again.unknownWorkoutWarmUpToken == "dynamic")
        #expect(again.unknownWorkoutCoolDownToken == "short")
        let json = try object(decoded)
        #expect(json["workoutSessionLength"] as? String == "noLimit")
        #expect(json["unknownWorkoutSessionLengthToken"] as? String == "min90")
    }

    /// A build that knows a parked token takes it back; a local choice clears it.
    @Test func aKnownParkedTokenIsReadoptedAndALocalChoiceWins() throws {
        let decoded = try settings(#"{"workoutSessionLength":"noLimit","unknownWorkoutSessionLengthToken":"min30"}"#)
        #expect(decoded.workoutSessionLength == .min30)
        #expect(decoded.unknownWorkoutSessionLengthToken == nil)
        var edited = try settings(#"{"workoutWarmUp":"dynamic"}"#)
        edited.workoutWarmUp = .off
        #expect(edited.unknownWorkoutWarmUpToken == nil)
    }

    /// Saving Workout setup writes only what changed, so an untouched field keeps a newer build's
    /// parked value.
    @Test func savingSetupKeepsAnUntouchedFieldsParkedToken() {
        let store = makeTestStore()
        var seeded = store.settings
        seeded.unknownWorkoutWarmUpToken = "dynamic"
        store.settings = seeded
        store.setWorkoutSessionOptions(WorkoutSessionOptions(length: .min30))
        #expect(store.settings.workoutSessionLength == .min30)
        #expect(store.settings.unknownWorkoutWarmUpToken == "dynamic")
        store.setWorkoutSessionOptions(WorkoutSessionOptions(length: .min30, warmUp: .short))
        #expect(store.settings.workoutWarmUp == .short)
        #expect(store.settings.unknownWorkoutWarmUpToken == nil)
    }

    /// The plan sheet's length shapes only the plan it builds; Workout setup's stays as it was.
    @Test func thePlanSheetsLengthShapesOnlyThatPlan() {
        let store = makeTestStore()
        let open = store.workoutDayPlan(intensity: .moderate, context: "")
        let fitted = store.workoutDayPlan(intensity: .moderate, context: "", sessionLength: .min20)
        #expect(store.settings.workoutSessionLength == .noLimit)
        #expect(fitted.sessions.count == open.sessions.count)
        for session in fitted.sessions {
            let minutes = WorkoutSessionTime.minutes(of: session.exercises, goal: store.settings.selectedGoal)
            #expect(minutes <= 20 || session.suggestion.notes.contains("Runs about \(minutes) min"))
        }
    }
}
