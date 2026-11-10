// WorkoutPlanFinisherTests.swift
// FernletTests
//
// Pins the one finishing pass every plan goes through (the owner's fix s1, 2026-11-10, review finding
// E5): the planner's own sessions come back from it untouched over many profiles; an AI adjustment and a
// hand edit are eased for a mild area, keep the 48-hour guard's lighter sets, are fitted to the time
// budget, get a real countdown on every hold, repeat no move today already has, are refused when the
// reply leaves too few lifts, lose equipment the request rules out, and carry a note rebuilt from what
// the pass did. The model itself never runs here: every reply is made up.

import Foundation
import Testing
@testable import FernletDomainModel
@testable import AIProviders
@testable import Fernlet

@MainActor
struct WorkoutPlanFinisherTests {

    // MARK: - Fixtures

    nonisolated static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    func key(_ name: String) -> String { WorkoutExerciseCatalog.normalizedName(name) }

    func lifted(_ offset: Int, _ weight: Double, reps: Int = 8) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: .lb, targetReps: reps, repsPerSet: [reps, reps, reps],
                     effort: nil, rangeLow: weight - 10, rangeHigh: weight + 10, calibration: nil, structured: true)
    }

    /// Three weeks of the lifts the planner reaches for first, so sessions carry weights and ramps.
    func history() -> [String: [LiftExposure]] {
        let lifts: [(String, Double)] = [
            ("Back squat", 185), ("Bench press", 135), ("Barbell row", 115), ("Overhead press", 85),
            ("Romanian deadlift", 155), ("Deadlift", 205), ("Dumbbell bench press", 50), ("Goblet squat", 45),
            ("Leg press", 230), ("Lat pulldown", 110), ("Dumbbell row", 45), ("Dumbbell shoulder press", 35),
        ]
        var map: [String: [LiftExposure]] = [:]
        for (name, weight) in lifts { map[key(name)] = [lifted(9, weight), lifted(16, weight), lifted(23, weight)] }
        return map
    }

    func load(warmUpSets: Bool = true, experience: ExperienceLevel? = nil, hasCoach: Bool = true) -> WorkoutLoadContext {
        WorkoutLoadContext(exposures: history(), today: day(30), defaultUnit: .lb,
                           calibration: CalibrationSettings(hasCoach: hasCoach), warmUpSets: warmUpSets,
                           experience: experience)
    }

    /// Everything one plan is built from.
    struct Setup {
        var goal: GoalType = .strength
        var intensity: WorkoutIntensity = .moderate
        var profile = WorkoutProfile(experience: .intermediate)
        var location: WorkoutLocation = .fullGym
        var split: TrainingSplit = WorkoutSplitCatalog.fullBody3
        var rotation = 0
        var note = ""
        var load: WorkoutLoadContext?
        var recent: WorkoutRecoveryGuard.RecentTraining?
        var options = WorkoutSessionOptions()
    }

    func plan(_ setup: Setup) -> WorkoutProgram.DayPlan {
        WorkoutProgram.dayPlan(
            goal: setup.goal, intensity: setup.intensity, profile: setup.profile, location: setup.location,
            context: setup.note, split: setup.split, rotationIndex: setup.rotation, load: setup.load,
            recent: setup.recent, options: setup.options
        )
    }

    func context(_ setup: Setup) -> WorkoutPlanFinisher.Context {
        WorkoutPlanFinisher.context(
            goal: setup.goal, intensity: setup.intensity, profile: setup.profile, location: setup.location,
            note: setup.note, split: setup.split, rotationIndex: setup.rotation, load: setup.load,
            recent: setup.recent, options: setup.options, noteMayShorten: true
        )
    }

    func lifting(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == .lifting }
    }

    func working(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        WorkoutWarmUpSets.removingWarmUpSets(from: lifting(session))
    }

    func target(_ name: String) throws -> ExerciseTarget {
        try #require(WorkoutExerciseCatalog.exercise(named: name))
    }

    /// What the adjuster hands back for a step it keeps: a name, sets, reps and the binding's role.
    func pick(_ step: PrescribedExercise) -> PrescribedExercise {
        let isolation = WorkoutExerciseCatalog.exercise(named: step.name)?.movementPattern == .isolation
        return PrescribedExercise(name: step.name, sets: step.sets, reps: step.holdSeconds == nil ? step.reps : "30 sec",
                                  role: isolation ? .accessory : .main, fromCatalog: true)
    }

    func pick(_ name: String, sets: Int = 3, reps: String = "8", role: SlotRole = .main) -> PrescribedExercise {
        PrescribedExercise(name: name, sets: sets, reps: reps, role: role, fromCatalog: true)
    }

    /// The first lifting session of `setup`'s plan.
    func session(_ setup: Setup) throws -> WorkoutProgram.SessionSuggestion {
        try #require(plan(setup).sessions.first(where: WorkoutPlanFinisher.isLifting))
    }

    func changed(_ adjustment: WorkoutPlanFinisher.Adjustment) throws -> WorkoutProgram.SessionSuggestion {
        guard case .changed(let session) = adjustment else {
            Issue.record("expected a changed session, got \(adjustment)")
            throw CancellationError()
        }
        return session
    }

    /// A setup whose first lifting session has at least five working lifts, for the refusal tests.
    func fiveLiftSetup() throws -> Setup {
        for split in WorkoutSplitCatalog.all {
            for rotation in split.days.indices {
                let setup = Setup(profile: WorkoutProfile(experience: .advanced), split: split, rotation: rotation,
                                  load: load(hasCoach: false))
                guard let first = plan(setup).sessions.first(where: WorkoutPlanFinisher.isLifting) else { continue }
                let plain = working(first).filter { $0.guidance?.calibration == nil }
                if plain.count >= 5, plain.count == working(first).count { return setup }
            }
        }
        Issue.record("no split day has a five-lift session")
        throw CancellationError()
    }

    /// The candidates the model would choose from for `session`, as the app builds them.
    func pool(_ session: WorkoutProgram.SessionSuggestion, request: String, setup: Setup, limits: InjuryLimits) -> [ExerciseTarget] {
        WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: session.catalogExerciseNames, request: request, location: setup.location,
            profile: setup.profile, limit: 400, limits: limits
        ).map(\.exercise)
    }

    // MARK: - Finishing a generated plan is a no-op

    /// A dozen profiles that between them turn on every part of the pass: limits (mild, severe, from
    /// today's note), the 48-hour window, a time budget, the load pass with ramps and a strength check,
    /// a light day, a home space.
    func profiles() -> [Setup] {
        let tired = WorkoutRecoveryGuard.RecentTraining(hardMuscles: [.chest, .quads, .lats, .glutes], latestSessionNames: [])
        var list: [Setup] = [Setup()]
        list.append(Setup(load: load()))
        list.append(Setup(load: load(hasCoach: false), recent: tired))
        list.append(Setup(load: load(), recent: tired, options: WorkoutSessionOptions(length: .min30)))
        list.append(Setup(intensity: .light, load: load(), options: WorkoutSessionOptions(length: .min20)))
        list.append(Setup(intensity: .hard, profile: WorkoutProfile(experience: .advanced), load: load(experience: .advanced)))
        list.append(Setup(profile: WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild]), load: load(),
                          options: WorkoutSessionOptions(length: .min30)))
        list.append(Setup(profile: WorkoutProfile(experience: .beginner, injuryAreas: [.shoulder: .mild, .lowerBack: .severe]),
                          load: load(), recent: tired))
        list.append(Setup(goal: .weightManagement, profile: WorkoutProfile(experience: .beginner), location: .home,
                          load: load(warmUpSets: false), options: WorkoutSessionOptions(length: .min45)))
        list.append(Setup(goal: .sportsPrep, profile: WorkoutProfile(sport: "basketball", experience: .intermediate),
                          note: "sore left knee, short on time", load: load(), recent: tired))
        list.append(Setup(goal: .wellness, profile: WorkoutProfile(experience: .beginner, injuryAreas: [.wristHand: .severe]),
                          location: .home, recent: tired, options: WorkoutSessionOptions(length: .min20)))
        list.append(Setup(goal: .bodybuilding, profile: WorkoutProfile(experience: .advanced, injuryAreas: [.elbow: .mild]),
                          load: load(experience: .advanced), recent: tired, options: WorkoutSessionOptions(length: .min60)))
        return list
    }

    /// The planner's own sessions are already finished: passed through the pass as an adjustment that
    /// asks for nothing, or as a hand edit that changes nothing, every step, the plan text and the note
    /// come back exactly as they were — over every split day, for every profile above. And each
    /// session's note is exactly its parts.
    @Test func finishingAFreshlyGeneratedPlanChangesNothing() {
        var sessions = 0
        var ramped = 0
        var lightened = 0
        var fitted = 0
        var eased = 0
        for base in profiles() {
            for split in WorkoutSplitCatalog.all {
                for rotation in split.days.indices {
                    var setup = base
                    setup.split = split
                    setup.rotation = rotation
                    let plan = plan(setup)
                    let context = context(setup)
                    for session in plan.sessions where WorkoutPlanFinisher.isLifting(session) {
                        sessions += 1
                        let parts = session.noteParts ?? []
                        #expect(WorkoutNotePart.text(of: parts) == session.suggestion.notes, "\(split.id) day \(rotation)")
                        if lifting(session).contains(where: WorkoutWarmUpSets.isWarmUpSet) { ramped += 1 }
                        if parts.contains(where: { $0.kind == .recovery && !$0.text.isEmpty }) { lightened += 1 }
                        if parts.contains(where: { $0.kind == .budget && !$0.text.isEmpty }) { fitted += 1 }
                        if working(session).contains(where: { step in
                            WorkoutExerciseCatalog.exercise(named: step.name).map(context.limits.eases) ?? false
                        }) { eased += 1 }
                        let others = plan.sessions.filter { $0.id != session.id }
                        for origin in [WorkoutPlanFinisher.Origin.adjustment, .handEdit] {
                            let finished = WorkoutPlanFinisher.finish(session, previous: session, others: others,
                                                                      origin: origin, context: context)
                            let same = finished.exercises == session.exercises
                            #expect(same, "\(split.id) day \(rotation) \(origin): \(finished.suggestion.exercises) ≠ \(session.suggestion.exercises)")
                            #expect(finished.suggestion.notes == session.suggestion.notes)
                            #expect(finished.suggestion.exercises == session.suggestion.exercises)
                        }
                    }
                }
            }
        }
        #expect(sessions > 150, "the sweep found only \(sessions) lifting sessions")
        #expect(ramped > 10 && lightened > 10 && fitted > 10 && eased > 5,
                "the sweep must reach every part of the pass: ramped \(ramped), lightened \(lightened), fitted \(fitted), eased \(eased)")
    }

    /// A reply that names the session's own lifts with their own sets and reps asks for nothing: the
    /// session is unchanged, whatever its trims — over every split day with the trims in play.
    @Test func aReplyThatRepeatsTheSessionChangesNothing() {
        let tired = WorkoutRecoveryGuard.RecentTraining(hardMuscles: [.chest, .quads, .lats], latestSessionNames: [])
        var checked = 0
        for split in WorkoutSplitCatalog.all {
            for rotation in split.days.indices {
                let setup = Setup(split: split, rotation: rotation, load: load(hasCoach: false), recent: tired,
                                  options: WorkoutSessionOptions(length: .min45))
                let plan = plan(setup)
                for session in plan.sessions where WorkoutPlanFinisher.isLifting(session) {
                    // A strength check is several steps of one lift: a reply names the lift once.
                    guard !lifting(session).contains(where: { $0.guidance?.calibration != nil && !WorkoutWarmUpSets.isWarmUpSet($0) }) else { continue }
                    checked += 1
                    let outcome = WorkoutPlanFinisher.adjusted(
                        session, picks: working(session).map(pick), request: WorkoutAdjustmentRequest(),
                        pool: [], others: plan.sessions.filter { $0.id != session.id }, context: context(setup)
                    )
                    guard case .unchanged = outcome else {
                        Issue.record("\(split.id) day \(rotation): expected unchanged, got \(outcome)")
                        continue
                    }
                }
            }
        }
        #expect(checked > 15)
    }

    // MARK: - Easing

    /// A mild knee: a knee lift the reply brings in as a heavy main lift (6 × 5) comes out as eased
    /// accessory work — the accessory reps, no more sets than accessory work gets, no warm-up ramp and
    /// no strength check — and no lift that loads the knee is a main lift.
    @Test func anAdjustedMildKneePlanEasesTheKneeLifts() throws {
        let setup = Setup(profile: WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild]),
                          split: WorkoutSplitCatalog.upperLower4, rotation: 1, load: load())
        let context = context(setup)
        let session = try session(setup)
        let candidates = pool(session, request: "more leg work", setup: setup, limits: context.limits)
        let newcomer = try #require(candidates.first { candidate in
            context.limits.eases(candidate) && candidate.movementPattern != .isolation && candidate.measure == .reps
                && !session.catalogExerciseNames.contains(candidate.name)
        })
        let kept = working(session).map(pick)
        let picks = [pick(newcomer.name, sets: 6, reps: "5")] + kept.dropLast()
        let adjusted = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: Array(picks), request: WorkoutAdjustmentRequest(), pool: candidates, context: context
        ))
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        let lift = try #require(working(adjusted).first { $0.name == newcomer.name })
        #expect(lift.role == .accessory)
        #expect(lift.reps == style.reps(for: .accessory), "eased to the accessory reps, not the reply's 5")
        #expect(lift.sets <= style.adjustedSets(for: .accessory, energy: .moderate), "not the reply's 6 sets")
        for step in lifting(adjusted) {
            let loadsKnee = WorkoutExerciseCatalog.exercise(named: step.name).map(context.limits.eases) ?? false
            guard loadsKnee else { continue }
            #expect(step.role != .main, "\(step.name) loads the knee and is still a main lift")
            #expect(!WorkoutWarmUpSets.isWarmUpSet(step), "\(step.name) loads the knee and was given a ramp")
            let isCheck = step.guidance?.calibration != nil
            #expect(!isCheck, "\(step.name) loads the knee and was given a strength check")
        }
    }

    /// The same rule read directly: a main lift that loads a mild area is accessory work with the
    /// accessory numbers; a lift that does not load it is left alone; and a lift already in the session
    /// with its own numbers keeps them (`numbers` false) while still never being a main lift.
    @Test func aLiftThatLoadsAMildAreaIsAccessoryWork() throws {
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        let context = WorkoutPlanFinisher.Context(goal: .strength, intensity: .moderate,
                                                  limits: InjuryLimits(mildAreas: [.knee]), location: .fullGym)
        let press = try target("Leg press")
        let heavy = pick("Leg press", sets: 6, reps: "5")
        let eased = WorkoutPlanFinisher.eased(heavy, target: press, style: style, context: context, numbers: true)
        #expect(eased.role == .accessory)
        #expect(eased.reps == style.reps(for: .accessory))
        #expect(eased.sets == style.adjustedSets(for: .accessory, energy: .moderate))
        let typed = WorkoutPlanFinisher.eased(heavy, target: press, style: style, context: context, numbers: false)
        #expect(typed.role == .accessory)
        #expect(typed.reps == "5" && typed.sets == 6, "numbers the person kept are theirs")
        let bench = try target("Bench press")
        let untouched = WorkoutPlanFinisher.eased(pick("Bench press", sets: 5, reps: "5"), target: bench, style: style,
                                                  context: context, numbers: true)
        #expect(untouched.role == .main && untouched.reps == "5" && untouched.sets == 5)
    }

    /// The editor's swap goes through the pass too: a knee lift swapped into a main lift's row with a
    /// mild knee is saved as eased accessory work, with a weight from its own history and no ramp.
    @Test func aSwappedInLiftIsEasedLikeAPlannersPick() throws {
        let setup = Setup(profile: WorkoutProfile(experience: .intermediate, injuryAreas: [.knee: .mild]), load: load())
        let context = context(setup)
        let session = try session(setup)
        var rows = working(session)
        let index = try #require(rows.firstIndex { $0.role == .main })
        let press = try target("Leg press")
        try #require(context.limits.eases(press) && context.limits.allows(press))
        rows[index] = GuidedWorkoutEditorSheet.swapped(rows[index], to: press, goal: .strength)
        var edited = session
        edited.exercises = session.exercises.filter { $0.block != .lifting } + rows
        let finished = WorkoutPlanFinisher.finish(edited, previous: session, origin: .handEdit, context: context)
        let lift = try #require(working(finished).first { $0.name == "Leg press" })
        #expect(lift.role == .accessory)
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        let floor = try #require(RepScheme(style.reps(for: .accessory)))
        let reps = try #require(RepScheme(lift.reps))
        #expect(reps.low >= floor.low, "no fewer reps than accessory work starts at, has \(lift.reps)")
        #expect(lift.sets <= max(rows[index].sets, style.adjustedSets(for: .accessory, energy: .moderate)))
        let hasWeight = lift.guidance?.prescription != nil
        #expect(hasWeight, "prescribed from its own history")
        #expect(working(finished).count == rows.count, "a hand edit never loses a row")
    }

    // MARK: - The 48-hour trim and the time budget

    /// After an adjustment that asks for six sets of everything: a tired lift the session already had
    /// stands at the sets the guard left it, a tired lift the reply brings in gives up a set, the
    /// session still fits its 30 minutes, and the note is exactly what the pass did.
    @Test func theTrimAndTheBudgetHoldAfterAnAdjustment() throws {
        let tired = WorkoutRecoveryGuard.RecentTraining(hardMuscles: [.chest, .quads, .lats, .glutes], latestSessionNames: [])
        let setup = Setup(load: load(hasCoach: false), recent: tired, options: WorkoutSessionOptions(length: .min30))
        let context = context(setup)
        let session = try session(setup)
        let before = Dictionary(working(session).map { ($0.name, $0.sets) }, uniquingKeysWith: { first, _ in first })
        let picks = working(session).map { step -> PrescribedExercise in
            var greedy = pick(step)
            greedy.sets = 6
            return greedy
        }
        let adjusted = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: picks, request: WorkoutAdjustmentRequest(), pool: [], context: context
        ))
        var heldTired = 0
        for step in working(adjusted) {
            let muscles = try target(step.name).primaryMuscles
            guard !muscles.isDisjoint(with: context.recentHard), step.holdSeconds == nil, let was = before[step.name] else { continue }
            heldTired += 1
            #expect(step.sets <= was, "\(step.name): \(was) sets after the guard, \(step.sets) after the adjustment")
        }
        #expect(heldTired > 0, "the fixture must have a tired lift")
        let seconds = WorkoutSessionTime.seconds(of: adjusted.exercises, goal: .strength)
        let budgetLine = adjusted.noteParts?.first { $0.kind == .budget }?.text ?? ""
        #expect(seconds <= 30 * 60 || !budgetLine.isEmpty, "over 30 minutes (\(seconds / 60) min) and the note is silent")
        #expect(adjusted.suggestion.notes == WorkoutNotePart.text(of: adjusted.noteParts ?? []))
        #expect(adjusted.suggestion.notes.contains(WorkoutPlannerCopy.adjustedToNote))
        #expect(adjusted.suggestion.exercises == WorkoutSessionBlocks.planText(for: adjusted.exercises))
    }

    /// A tired lift the reply brings in gives up exactly one set, once: a second adjustment that keeps
    /// it does not take another.
    @Test func aNewTiredLiftIsTrimmedOnce() throws {
        let tired = WorkoutRecoveryGuard.RecentTraining(hardMuscles: [.chest], latestSessionNames: [])
        let setup = Setup(split: WorkoutSplitCatalog.upperLower4, rotation: 0, load: load(hasCoach: false), recent: tired)
        let context = context(setup)
        let session = try session(setup)
        let candidates = pool(session, request: "more chest", setup: setup, limits: context.limits)
        let newcomer = try #require(candidates.first { candidate in
            candidate.primaryMuscles.contains(.chest) && candidate.measure == .reps
                && !session.catalogExerciseNames.contains(candidate.name)
        })
        let picks = working(session).map(pick).dropLast() + [pick(newcomer.name, sets: 4, reps: "10", role: .accessory)]
        let first = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: Array(picks), request: WorkoutAdjustmentRequest(), pool: candidates, context: context
        ))
        let lift = try #require(working(first).first { $0.name == newcomer.name })
        #expect(lift.sets == 3, "one set fewer than the reply's four")
        let recovery = try #require(first.noteParts?.first { $0.kind == .recovery })
        #expect(recovery.lifts.contains(newcomer.name) && !recovery.text.isEmpty, "the note names the lift it lightened")
        let again = WorkoutPlanFinisher.adjusted(first, picks: working(first).map(pick), request: WorkoutAdjustmentRequest(),
                                                 pool: candidates, context: context)
        guard case .unchanged = again else {
            Issue.record("a reply that repeats the adjusted session changed it again: \(again)")
            return
        }
    }

    /// The old note cannot outlive what it described: a session the budget trimmed says so; once an
    /// adjustment brings a left-out lift back, either the pass leaves it out again and says so, or the
    /// budget line no longer names it.
    @Test func theBudgetLineIsRewrittenNotKept() throws {
        let setup = Setup(load: load(hasCoach: false), options: WorkoutSessionOptions(length: .min20))
        let context = context(setup)
        let open = try session(Setup(load: load(hasCoach: false)))
        let session = try session(setup)
        let leftOut = try #require(working(open).map(\.name).first { name in !working(session).contains { $0.name == name } },
                                   "the 20-minute session must have left a lift out")
        let oldLine = try #require(session.noteParts?.first { $0.kind == .budget }?.text)
        #expect(!oldLine.isEmpty)
        let picks = working(session).map(pick) + [pick(leftOut, sets: 3, reps: "10", role: .accessory)]
        let outcome = WorkoutPlanFinisher.adjusted(session, picks: picks, request: WorkoutAdjustmentRequest(), pool: [],
                                                   context: context)
        // Left out again with nothing else changed: the session, and its still-true line, stand.
        guard case .changed(let adjusted) = outcome else {
            guard case .unchanged = outcome else {
                Issue.record("expected the lift back or the session unchanged, got \(outcome)")
                return
            }
            return
        }
        let line = adjusted.noteParts?.first { $0.kind == .budget }?.text ?? ""
        let isBack = working(adjusted).contains { $0.name == leftOut }
        let seconds = WorkoutSessionTime.seconds(of: adjusted.exercises, goal: .strength)
        if isBack {
            #expect(seconds <= 20 * 60 || !line.isEmpty, "the lift is back, the session is over, and the note is silent")
        } else {
            #expect(line.contains(ExerciseHowToCatalog.displayName(for: leftOut)), "left out again: the note says so")
        }
        #expect(adjusted.suggestion.notes == WorkoutNotePart.text(of: adjusted.noteParts ?? []))
    }

    /// A hand edit never drops a row or changes a number the person kept: adding a lift to a session
    /// fitted to 20 minutes saves every row, and the note says how long the session now runs.
    @Test func aHandEditKeepsEveryRowAndSaysHowLongItRuns() throws {
        let setup = Setup(load: load(hasCoach: false), options: WorkoutSessionOptions(length: .min20))
        let context = context(setup)
        let session = try session(setup)
        let rows = working(session)
        let added = PrescribedExercise(name: "Cable curl", sets: 3, reps: "12", role: .accessory, fromCatalog: true)
        try #require(!rows.contains { $0.name == added.name })
        var edited = session
        edited.exercises = session.exercises.filter { $0.block != .lifting } + rows + [added]
        let finished = WorkoutPlanFinisher.finish(edited, previous: session, origin: .handEdit, context: context)
        let after = working(finished)
        #expect(after.map(\.name) == rows.map(\.name) + [added.name])
        for (old, new) in zip(rows, after) {
            #expect(old.sets == new.sets && old.reps == new.reps, "\(old.name) was changed by the pass")
        }
        let seconds = WorkoutSessionTime.seconds(of: finished.exercises, goal: .strength)
        let line = finished.noteParts?.first { $0.kind == .budget }?.text ?? ""
        #expect(seconds <= 20 * 60 || !line.isEmpty, "over 20 minutes and the note is silent")
        #expect(!finished.suggestion.notes.contains(WorkoutPlannerCopy.adjustedToNote))
    }

    // MARK: - Holds

    /// A timed movement always has a real countdown: "30 sec" from the model becomes a 30-second hold,
    /// a text that names no time takes the goal's hold, and the plan line reads back as a hold.
    @Test func aHoldArrivesWithACountdown() throws {
        let setup = Setup(load: load(hasCoach: false))
        let context = context(setup)
        let session = try session(setup)
        let taken = Set(session.exercises.map(\.name))
        let holds = WorkoutExerciseCatalog.baseExercises.filter { exercise in
            exercise.measure == .seconds && exercise.modality == .strength && !taken.contains(exercise.name)
                && WorkoutSafetyFilter.feasible(exercise, location: .fullGym, limits: .empty)
        }
        try #require(holds.count >= 2, "the catalog needs two timed strength moves outside the session")
        let picks = working(session).map(pick).dropLast(2)
            + [pick(holds[0].name, sets: 3, reps: "30 sec", role: .accessory), pick(holds[1].name, sets: 2, reps: "8-12", role: .accessory)]
        let adjusted = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: Array(picks), request: WorkoutAdjustmentRequest(), pool: holds, context: context
        ))
        let first = try #require(working(adjusted).first { $0.name == holds[0].name })
        #expect(first.holdSeconds == 30)
        #expect(first.reps == "30 s")
        #expect(adjusted.suggestion.exercises.contains("\(holds[0].name) - 3 x 30 s"))
        let second = try #require(working(adjusted).first { $0.name == holds[1].name })
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        #expect(second.holdSeconds == style.holdSeconds, "no time in the text: the goal's hold")
        #expect(WorkoutPlanFinisher.holdSeconds(in: "45 s") == 45)
        #expect(WorkoutPlanFinisher.holdSeconds(in: "30-45 seconds") == 30)
        #expect(WorkoutPlanFinisher.holdSeconds(in: "1 min") == 60)
        #expect(WorkoutPlanFinisher.holdSeconds(in: "8-12") == nil)
        #expect(WorkoutPlanFinisher.holdSeconds(in: "AMRAP") == nil)
    }

    /// Reps the model wrote as a time on a rep-counted lift are put right, so the lift is loadable.
    @Test func aTimeOnARepCountedLiftBecomesItsRolesReps() throws {
        let style = WorkoutGoalStyle.style(for: .strength, energy: .moderate, sport: "")
        let bench = try target("Bench press")
        let fixed = WorkoutPlanFinisher.typedHold(pick("Bench press", reps: "30 sec"), target: bench, style: style, fixingReps: true)
        #expect(fixed.reps == style.reps(for: .main))
        #expect(fixed.holdSeconds == nil)
        let typed = WorkoutPlanFinisher.typedHold(pick("Bench press", reps: "AMRAP"), target: bench, style: style, fixingReps: false)
        #expect(typed.reps == "AMRAP", "what the person typed by hand stays")
    }

    // MARK: - Duplicates

    /// A reply cannot repeat the session's activation move or a lift of another of today's sessions.
    @Test func aRepeatOfTheActivationMoveOrAnotherSessionsLiftIsDropped() throws {
        let setup = Setup(load: load(hasCoach: false))
        let context = context(setup)
        let session = try session(setup)
        let activation = try #require(session.exercises.first { $0.block == .activation && $0.fromCatalog && $0.role == .core })
        let elsewhere = pick("Hammer curl", sets: 3, reps: "12", role: .accessory)
        try #require(!session.catalogExerciseNames.contains(elsewhere.name))
        let other = WorkoutProgram.SessionSuggestion(
            title: "Evening", timeLabel: "Evening", kind: .strength, exercises: [elsewhere],
            suggestion: WorkoutSuggestion(name: "Evening · Arms", exercises: elsewhere.line, notes: "")
        )
        let picks = working(session).map(pick).dropLast()
            + [pick(activation.name, sets: 3, reps: "30 sec", role: .main), elsewhere]
        let adjusted = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: Array(picks), request: WorkoutAdjustmentRequest(), pool: [], others: [other], context: context
        ))
        let names = lifting(adjusted).map(\.name)
        #expect(!names.contains(activation.name), "the activation move came back as a lift")
        #expect(!names.contains(elsewhere.name), "another session's lift was repeated")
        #expect(adjusted.exercises.filter { $0.block == .activation } == session.exercises.filter { $0.block == .activation })
    }

    // MARK: - The refusal

    /// A reply that leaves fewer than three lifts in a session that had four or more is refused; three
    /// are enough; and a session that had three to begin with may go to two.
    @Test func aReplyThatLeavesTooFewLiftsIsRefused() throws {
        let setup = try fiveLiftSetup()
        let context = context(setup)
        let session = try session(setup)
        let lifts = working(session)
        try #require(lifts.count >= 5, "the fixture needs a five-lift session, has \(lifts.count)")
        let one = WorkoutPlanFinisher.adjusted(session, picks: [pick(lifts[0])], request: WorkoutAdjustmentRequest(),
                                               pool: [], context: context)
        guard case .tooFewLifts = one else {
            Issue.record("one pick against a five-lift session was not refused: \(one)")
            return
        }
        let two = WorkoutPlanFinisher.adjusted(session, picks: lifts.prefix(2).map(pick), request: WorkoutAdjustmentRequest(),
                                               pool: [], context: context)
        guard case .tooFewLifts = two else {
            Issue.record("two picks against a five-lift session were not refused: \(two)")
            return
        }
        let three = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: lifts.prefix(3).map(pick), request: WorkoutAdjustmentRequest(), pool: [], context: context
        ))
        #expect(working(three).count == 3)
        var small = session
        small.exercises = session.exercises.filter { $0.block != .lifting } + lifts.prefix(3)
        let shorter = try changed(WorkoutPlanFinisher.adjusted(
            small, picks: lifts.prefix(2).map(pick), request: WorkoutAdjustmentRequest(), pool: [], context: context
        ))
        #expect(working(shorter).count == 2, "a three-lift session may be asked down to two")
    }

    /// Lifts that are dropped as repeats count as gone: a reply of five picks, three of them repeats of
    /// another session's lifts, leaves two and is refused.
    @Test func repeatsDoNotCountTowardTheThreeLifts() throws {
        let setup = try fiveLiftSetup()
        let context = context(setup)
        let session = try session(setup)
        let lifts = working(session)
        try #require(lifts.count >= 5)
        let taken = Set(session.exercises.map(\.name))
        let elsewhere = WorkoutExerciseCatalog.baseExercises.filter { exercise in
            exercise.movementPattern == .isolation && exercise.measure == .reps && exercise.modality == .strength
                && !taken.contains(exercise.name)
        }.prefix(3)
        try #require(elsewhere.count == 3)
        let repeats = elsewhere.map { pick($0.name, sets: 3, reps: "12", role: .accessory) }
        let other = WorkoutProgram.SessionSuggestion(
            title: "Evening", timeLabel: "Evening", kind: .strength, exercises: repeats,
            suggestion: WorkoutSuggestion(name: "Evening · Arms", exercises: "", notes: "")
        )
        let outcome = WorkoutPlanFinisher.adjusted(session, picks: lifts.prefix(2).map(pick) + repeats,
                                                   request: WorkoutAdjustmentRequest(), pool: [], others: [other], context: context)
        guard case .tooFewLifts = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
    }

    // MARK: - "No barbell"

    /// The request is read in code: what it rules out, and which of its words may still favour a name.
    @Test func theRequestIsReadBeforeTheModelSeesIt() {
        let none = WorkoutAdjustmentRequest.read("swap the squat for something easier")
        #expect(none.excludedEquipment.isEmpty)
        #expect(none.bonusWords.contains("squat"))
        let barbell = WorkoutAdjustmentRequest.read("No barbell today")
        #expect(barbell.excludedEquipment == [.barbell])
        #expect(!barbell.bonusWords.contains("barbell"), "a ruled-out word must not favour 'Barbell row'")
        #expect(WorkoutAdjustmentRequest.read("I don't have a barbell").excludedEquipment == [.barbell])
        #expect(WorkoutAdjustmentRequest.read("without dumbbells or cables").excludedEquipment == [.dumbbell, .cable])
        #expect(WorkoutAdjustmentRequest.read("no barbell, more dumbbell work").excludedEquipment == [.barbell])
        #expect(WorkoutAdjustmentRequest.read("no barbell, more dumbbell work").bonusWords.contains("dumbbell"))
        #expect(WorkoutAdjustmentRequest.read("dumbbells only").excludedEquipment == [.barbell, .kettlebell, .machine, .cable, .band])
        #expect(WorkoutAdjustmentRequest.read("bodyweight only").excludedEquipment.contains(.barbell))
        #expect(WorkoutAdjustmentRequest.read("no weights").excludedEquipment == [.barbell, .dumbbell, .kettlebell])
        #expect(WorkoutAdjustmentRequest.read("sin barra hoy").excludedEquipment.isEmpty, "matching words are English, like the injury note's")
    }

    /// "No barbell": no barbell exercise is offered to the model — not even the session's own — and
    /// "Barbell row" no longer rides to the top of the list on the word.
    @Test func noBarbellNeverReachesTheCandidates() throws {
        let setup = Setup(load: load(hasCoach: false))
        let session = try session(setup)
        try #require(session.catalogExerciseNames.contains { (try? target($0))?.equipment == .barbell },
                     "the fixture's session must have a barbell lift")
        let open = pool(session, request: "swap the row", setup: setup, limits: .empty)
        #expect(open.contains { $0.equipment == .barbell })
        let filtered = pool(session, request: "no barbell today", setup: setup, limits: .empty)
        #expect(!filtered.isEmpty)
        #expect(!filtered.contains { $0.equipment == .barbell })
        #expect(!filtered.contains { $0.name.lowercased().contains("barbell") })
        let ranked = WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: [], request: "no barbell today", location: .fullGym, profile: setup.profile, limit: 5
        ).map(\.exercise.name)
        #expect(!ranked.contains("Barbell row") && !ranked.contains("Barbell curl"))
    }

    /// Even when a reply names barbell lifts, none comes back: each is replaced by a lift that does
    /// the same work on equipment the request allows, or left out.
    @Test func noBarbellYieldsNoBarbellLiftWhateverTheReplyNames() throws {
        let setup = Setup(load: load(hasCoach: false))
        let context = context(setup)
        let session = try session(setup)
        let request = WorkoutAdjustmentRequest.read("no barbell today")
        let candidates = pool(session, request: "no barbell today", setup: setup, limits: context.limits)
        let barbellLifts = try working(session).filter { try target($0.name).equipment == .barbell }
        try #require(!barbellLifts.isEmpty)
        // The reply keeps everything, barbell lifts included, and adds another one.
        let picks = working(session).map(pick) + [pick("Barbell curl", sets: 3, reps: "10", role: .accessory)]
        let adjusted = try changed(WorkoutPlanFinisher.adjusted(
            session, picks: picks, request: request, pool: candidates, context: context
        ))
        for step in lifting(adjusted) {
            let exercise = try target(step.name)
            #expect(exercise.equipment != .barbell, "\(step.name) is a barbell lift")
            #expect(request.allows(exercise))
        }
        #expect(working(adjusted).count >= WorkoutProgram.minimumLifts)
        let squat = try target("Back squat")
        let swap = try #require(WorkoutAdjustmentRequest.replacement(for: squat, in: candidates, excluding: []))
        #expect(swap.movementPattern == .squat && swap.equipment != .barbell)
    }

    /// Today's "Anything else?" reaches the candidates too: a knee eased for today only removes the
    /// lifts that load it hard.
    @Test func todaysNoteLimitsTheCandidates() throws {
        let setup = Setup(note: "sore left knee", load: load(hasCoach: false))
        let context = context(setup)
        #expect(context.limits.mildAreas.contains(.knee))
        let session = try session(setup)
        let saved = pool(session, request: "more legs", setup: setup, limits: setup.profile.injuryLimits)
        let today = pool(session, request: "more legs", setup: setup, limits: context.limits)
        #expect(saved.contains { $0.name == "Back squat" })
        #expect(!today.contains { $0.name == "Back squat" })
        #expect(today.allSatisfy(context.limits.allows))
    }

    // MARK: - Training age and owned weights (w6)

    /// A lift re-prescribed by the pass is planned at the person's training age, on the weights the
    /// space owns: an intermediate's lift the planner would hold is held here too, where the old
    /// re-run stepped it as a beginner's.
    @Test func anAdjustedLiftUsesTheStoredTierAndInventory() throws {
        let squat = try target("Back squat")
        let sessions = [lifted(16, 180), lifted(23, 185)]
        func engine(_ tier: TrainingTier) -> LiftPlan {
            WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
                scheme: RepScheme(low: 8, high: 8), baseSets: 3, exposures: sessions, equipment: squat.equipment,
                isLowerBody: true, defaultUnit: .lb, today: day(30), inventory: WorkoutLocation.fullGym.weights, tier: tier
            ))
        }
        try #require(engine(.beginner).prescription != engine(.intermediate).prescription,
                     "the fixture must tell a beginner's step from an intermediate's hold")
        let context = WorkoutLoadContext(exposures: [key("Back squat"): sessions], today: day(30), defaultUnit: .lb,
                                         experience: .intermediate)
        let guidance = try #require(WorkoutPlanRun.engineGuidance(
            for: squat, reps: "8", sets: 3, location: .fullGym, load: context, inventory: WorkoutLocation.fullGym.weights
        ))
        #expect(guidance.prescription == engine(.intermediate).prescription)
        let beginner = WorkoutLoadContext(exposures: [key("Back squat"): sessions], today: day(30), defaultUnit: .lb,
                                          experience: .beginner)
        let stepped = try #require(WorkoutPlanRun.engineGuidance(
            for: squat, reps: "8", sets: 3, location: .fullGym, load: beginner, inventory: WorkoutLocation.fullGym.weights
        ))
        #expect(stepped.prescription == engine(.beginner).prescription)
    }

    /// A planned workout's line with no weight is planned on the space's own weights: at a space that
    /// owns three dumbbell pairs, the suggestion is one of them.
    @Test func aPlannedRunUsesTheSpacesWeightsAndTheStoredTier() throws {
        var home = WorkoutLocation.home
        home.weights.setDumbbells([10, 25, 40])
        let name = "Dumbbell bench press"
        let sessions = [lifted(16, 30), lifted(23, 30)]
        let context = WorkoutLoadContext(exposures: [key(name): sessions], today: day(30), defaultUnit: .lb,
                                         experience: .intermediate)
        let line = "\(name) - 3 x 8"
        let step = WorkoutPlanRun.step(for: line, parsed: PlannedWorkoutRun.parsedLine(line), location: home, load: context,
                                       catalog: WorkoutExerciseCatalog.baseExercises)
        let suggested = try #require(step.exercise.guidance?.prescription?.suggested)
        #expect([10, 25, 40].contains(suggested), "\(suggested) lb is not a dumbbell this space owns")
        let bench = try target(name)
        let expected = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 8, high: 8), baseSets: 3, exposures: sessions, equipment: .dumbbell,
            isLowerBody: false, defaultUnit: .lb, today: day(30), inventory: home.weights, tier: .intermediate
        ))
        #expect(bench.equipment == .dumbbell)
        #expect(step.exercise.guidance?.prescription == expected.prescription)
    }

    // MARK: - The rest day's line

    /// The rest day offers no walk when walking is ruled out: a severe ankle, knee or hip gets the
    /// seated line, still the optional gentle stretch, built from seated stretches.
    @Test func theRestDayOffersSeatedStretchingWhenAWalkIsRuledOut() throws {
        let plain = WorkoutPlanningService.restDayPlan(locationName: "Home")
        #expect(plain.sessions.first?.suggestion.exercises == WorkoutPlanningService.restDayMovementLine)
        let limits = InjuryLimits(severeAreas: [.knee])
        try #require(limits.barsWalking)
        let seated = WorkoutPlanningService.restDayPlan(locationName: "Home", limits: limits)
        let line = try #require(seated.sessions.first?.exercises.first)
        #expect(line.name == WorkoutPlanningService.restDaySeatedLine)
        #expect(!line.name.lowercased().contains("walk"))
        #expect(WorkoutTimedSessions.isOptionalStretch(line), "still the optional stretch, never today's workout")
        #expect(WorkoutProgram.descriptorMinutes(in: line.name) == 10)
        #expect(WorkoutPlanLine.displayed(line.name) == line.name)
        let feasible = WorkoutExerciseCatalog.baseExercises.filter(limits.allows)
        let steps = WorkoutTimedSessions.expand([line], feasible: feasible)
        #expect(steps.count > 1, "the seated line expands into stretches")
        #expect(steps.allSatisfy { WorkoutTimedSessions.seatedMoves.contains($0.name) })
        let mild = WorkoutPlanningService.restDayPlan(locationName: "Home", limits: InjuryLimits(mildAreas: [.knee]))
        #expect(mild.sessions.first?.suggestion.exercises == WorkoutPlanningService.restDayMovementLine)
    }
}
