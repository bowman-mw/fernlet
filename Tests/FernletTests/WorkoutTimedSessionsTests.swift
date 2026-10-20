// WorkoutTimedSessionsTests.swift
// FernletTests
//
// Pins comparison report idea 4 (roadmap step 4a, 2026-10-20): guided timed cardio and mobility, with no
// heart rate yet. A plan's cardio lines ("Intervals - 8 × 1 min hard / 1 min easy", "Easy cardio -
// 20 min") become countdown segments the runner walks like holds; a Mobility day's "Mobility flow -
// 15 min" becomes a timed stretch session in the owner's warm-up order; the rest day's gentle stretching
// becomes a short, optional floor stretch that is never today's workout.
//
// Covered here: reading the descriptor lines (and leaving the ones it cannot time as text), the segments
// and their lead-ins, the expansion when a run starts and the log folding it back, the stretch-session
// builders, the rest day staying optional, walking and auto-advancing the segments on the run's own
// clock, the Live Activity's content and its tolerant decoding, the cues and VoiceOver lines at a
// segment change, the block skip, and what a finished run logs (type and time held). What no test here
// can check — how the cues feel and sound at a segment change, the Live Activity on a locked phone, and
// the runner's layout at AX5 — is owed on a device.

import Foundation
import Testing
import UserNotifications
import FernletDomainModel
import FernletUI
@testable import AppServices
@testable import Fernlet

/// Serialized: several tests stand up a real `FernletStore` and start a run, which reaches process-global
/// state (the `Activity<…>` registry behind the Live Activity bridge), as `GuidedWorkoutRunStoreTests`.
@MainActor
@Suite(.serialized) struct WorkoutTimedSessionsTests {

    // MARK: Fixtures

    /// When the fixture runs' first step begins — a whole second, so encoded dates read back exactly.
    private nonisolated static let t0 = Date(timeIntervalSince1970: 4_000_000)
    private nonisolated static let intervalsLine = "Intervals - 8 × 1 min hard / 1 min easy"

    /// Every stretch, as a full gym with no limits allows them.
    private static var everyStretch: [ExerciseTarget] {
        WorkoutSafetyFilter.feasibleExercises(in: WorkoutExerciseCatalog.allExercises, location: .fullGym, profile: WorkoutProfile())
    }

    private static func line(_ text: String, block: SessionBlock = .lifting) -> PrescribedExercise {
        PrescribedExercise(name: text, sets: 0, reps: "", role: .accessory, fromCatalog: false, block: block)
    }

    private static func session(_ steps: [PrescribedExercise], kind: SessionKind, title: String) -> WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            title: title, timeLabel: "", kind: kind, exercises: steps,
            suggestion: WorkoutSuggestion(name: title, exercises: steps.map(\.line).joined(separator: "\n"), notes: "")
        )
    }

    /// Commits today's slot, then swaps in `session` as the whole plan.
    private static func commit(_ session: WorkoutProgram.SessionSuggestion, to store: FernletStore) {
        let base = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let plan = WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: [session], droppedSlots: [], locationName: "Test")
        store.replaceGuidedWorkoutPlan(plan, replacing: Set(base.sessions.map(\.id)))
    }

    /// The run a real store builds for `session`, its first step started at ``t0``.
    private static func startedRun(_ session: WorkoutProgram.SessionSuggestion) throws -> GuidedWorkoutRunState {
        let store = makeTestStore()
        commit(session, to: store)
        #expect(store.startGuidedRun(session))
        var run = try #require(store.guidedRunState)
        run.setStartedAt = t0
        return run
    }

    /// Every one-sided move has as many left steps as right ones.
    private static func sidesPaired(_ steps: [PrescribedExercise]) -> Bool {
        let names = Set(steps.filter { $0.side != nil }.map(\.name))
        return names.allSatisfy { name in
            steps.filter { $0.name == name && $0.side == .left }.count == steps.filter { $0.name == name && $0.side == .right }.count
        }
    }

    /// A JSON object with `keys` removed at the top level and in every element of `arrayKey`.
    private static func strip(_ data: Data, keys: [String], inArray arrayKey: String? = nil) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in keys { object[key] = nil }
        if let arrayKey, let rows = object[arrayKey] as? [[String: Any]] {
            object[arrayKey] = rows.map { row in row.filter { !keys.contains($0.key) } }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Reading a descriptor

    @Test func steadyLinesAreOneSegment() {
        #expect(WorkoutTimedSessions.classify("Easy cardio - 20 min") == .steady(minutes: 20, pace: .easy))
        #expect(WorkoutTimedSessions.classify("Steady cardio - 40 min") == .steady(minutes: 40, pace: .steady))
        #expect(WorkoutTimedSessions.classify("Optional cardio - 10 min") == .steady(minutes: 10, pace: .steady))
        #expect(WorkoutTimedSessions.classify("Easy walk - 15 min") == .steady(minutes: 15, pace: .easy))
        #expect(WorkoutTimedSessions.classify("Row - 10 min") == .steady(minutes: 10, pace: .steady))
        #expect(WorkoutTimedSessions.classify("Steady cardio – 25 min") == .steady(minutes: 25, pace: .steady),
                "an en dash separates as the planner's minutes parser allows")
    }

    @Test func intervalLinesReadTheirShape() {
        #expect(WorkoutTimedSessions.classify(Self.intervalsLine) == .intervals(rounds: 8, workSeconds: 60, easySeconds: 60))
        #expect(WorkoutTimedSessions.classify("Sprints - 6 x 30 s hard / 90 s easy") == .intervals(rounds: 6, workSeconds: 30, easySeconds: 90))
        #expect(WorkoutTimedSessions.classify("Bike - 10 × 20s / 40s") == .intervals(rounds: 10, workSeconds: 20, easySeconds: 40),
                "unmarked parts read hard, then easy")
        // A length with no shape takes the plan's own interval shape.
        #expect(WorkoutTimedSessions.classify("Conditioning intervals - 12 min") == .intervals(rounds: 6, workSeconds: 60, easySeconds: 60))
    }

    @Test func stretchLinesReadAsStretchSessions() {
        #expect(WorkoutTimedSessions.classify("Mobility flow - 15 min") == .mobilityFlow(minutes: 15))
        #expect(WorkoutTimedSessions.classify(WorkoutPlanningService.restDayMovementLine) == .gentleStretch)
        #expect(TimedDescriptor.gentleStretch.isPrimary == false, "the rest day's stretch is never the day's session")
        #expect(TimedDescriptor.mobilityFlow(minutes: 15).isPrimary)
    }

    /// Anything it cannot read with certainty stays the untimed text it always was.
    @Test func malformedLinesStayUntimedText() {
        let untimed = [
            "Full-body bodyweight circuit - 3 rounds", "Soccer drills / conditioning - 15 min",
            "Gentle mobility + walk - 12 min", "Intervals - 8 × 1 min easy / 1 min hard",
            "Intervals - 40 × 1 min hard / 1 min easy", "Intervals - 8 × 1 hr hard / 1 min easy",
            "Intervals - 8 × 1 min hard", "Easy cardio", "Easy cardio - ", "Easy cardio - 0 min",
            "Easy cardio - 900 min", "Yoga - 20 min", " - 20 min", "Foam roll - 5 min",
        ]
        for text in untimed {
            #expect(WorkoutTimedSessions.classify(text) == nil, "\(text) should stay untimed")
            #expect(!WorkoutTimedSessions.isGuidable(Self.line(text)))
        }
    }

    /// Every cardio and mobility session the planner writes today can be guided.
    @Test func everyCardioAndMobilityTemplateIsTimed() throws {
        for template in [WorkoutSessions.easyCardio, WorkoutSessions.intervals, WorkoutSessions.longCardio, WorkoutSessions.mobility] {
            let text = try #require(template.conditioning)
            #expect(WorkoutTimedSessions.classify(text) != nil, "\(text) is not timed")
        }
    }

    // MARK: Segments

    @Test func intervalSegmentsAlternateAndFollowOn() {
        let segments = WorkoutTimedSessions.segments(
            for: .intervals(rounds: 8, workSeconds: 60, easySeconds: 60), descriptor: Self.intervalsLine
        )
        #expect(segments.count == 16)
        let paces = Array(repeating: [CardioPace.hard, CardioPace.easy], count: 8).flatMap { $0 }
        #expect(segments.map(\.pace) == paces)
        let rounds: [Int?] = (1...8).flatMap { round -> [Int?] in [round, round] }
        #expect(segments.map(\.round) == rounds)
        let everyPartMatches = segments.allSatisfy { $0.rounds == 8 && $0.seconds == 60 && $0.descriptor == Self.intervalsLine }
        #expect(everyPartMatches)
        let firstFollowsOn = segments.first?.followsOn
        #expect(firstFollowsOn == false, "the first part gets its 'get ready'")
        let laterPartsFollowOn = segments.dropFirst().allSatisfy(\.followsOn)
        #expect(laterPartsFollowOn, "every later part starts straight off the one before")
    }

    @Test func aSteadyLineIsOneCountdown() {
        let segments = WorkoutTimedSessions.segments(for: .steady(minutes: 20, pace: .easy), descriptor: "Easy cardio - 20 min")
        #expect(segments.count == 1)
        #expect(segments.first?.seconds == 1_200)
        #expect(segments.first?.pace == .easy)
        #expect(segments.first?.round == nil && segments.first?.followsOn == false)
    }

    // MARK: Expanding a plan, folding a log

    @Test func aCardioLineExpandsIntoTimedSteps() {
        let steps = WorkoutTimedSessions.expand([Self.line(Self.intervalsLine)], feasible: [])
        #expect(steps.count == 16)
        #expect(steps.allSatisfy { $0.block == .cardio && $0.holdSeconds == 60 && $0.sets == 1 && !$0.fromCatalog })
        #expect(steps.allSatisfy { $0.restSecondsOverride == 0 && $0.name == "Intervals" })
        #expect(WorkoutSessionBlocks.planText(for: steps) == Self.intervalsLine, "the log folds the segments back into the line")
        // A resumed run's steps are no longer descriptors, so a second expansion changes nothing.
        #expect(WorkoutTimedSessions.expand(steps, feasible: []).count == 16)
    }

    @Test func aLiftingSessionsCardioBlockExpandsAndTheRestStays() {
        let bench = PrescribedExercise(name: "Bench press", sets: 3, reps: "8", role: .main, fromCatalog: true)
        let finisher = Self.line("Steady cardio - 20 min", block: .cardio)
        let drills = Self.line("Soccer drills / conditioning - 15 min", block: .cardio)
        #expect(WorkoutTimedSessions.isGuidable(finisher) && !WorkoutTimedSessions.isGuidable(drills))
        let steps = WorkoutTimedSessions.expand([bench, finisher, drills], feasible: [])
        #expect(steps.map(\.name) == ["Bench press", "Steady cardio", "Soccer drills / conditioning - 15 min"])
        #expect(steps[1].holdSeconds == 1_200 && steps[1].segment?.pace == .steady)
        #expect(steps[2].holdSeconds == nil, "a line it cannot time stays one untimed step")
        #expect(WorkoutSessionBlocks.planText(for: steps)
                == "Bench press - 3 x 8\nSteady cardio - 20 min\nSoccer drills / conditioning - 15 min")
    }

    // MARK: Stretch sessions

    @Test func aMobilityFlowFollowsTheOwnersOrderForAboutFifteenMinutes() {
        let steps = WorkoutTimedSessions.mobilityFlow(minutes: 15, feasible: Self.everyStretch)
        #expect(steps.map(\.name) == WorkoutSessionBlocks.warmUpFlow.map(\.name))
        #expect(steps.map(\.side) == WorkoutSessionBlocks.warmUpFlow.map(\.side))
        let hold = steps.first?.holdSeconds ?? 0
        #expect(WorkoutTimedSessions.mobilityHoldRange.contains(hold))
        #expect(steps.allSatisfy { $0.holdSeconds == hold && $0.block == .mobility && $0.sets == 1 && $0.fromCatalog })
        let seconds = steps.count * (hold + WorkoutTimedSessions.stretchLeadInSeconds)
        #expect(abs(seconds - 15 * 60) <= 60, "about fifteen minutes, lead-ins included: \(seconds) s")
    }

    @Test func aMobilityFlowKeepsToTheInjuryFilter() {
        let knees = WorkoutProfile.fromOnboarding(level: "intermediate", interests: "", constraints: "bad knee")
        let feasible = WorkoutSafetyFilter.feasibleExercises(in: WorkoutExerciseCatalog.allExercises, location: .fullGym, profile: knees)
        let allowed = Set(feasible.map(\.name))
        let steps = WorkoutTimedSessions.mobilityFlow(minutes: 15, feasible: feasible)
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { allowed.contains($0.name) })
        #expect(!steps.contains { $0.name == "Low lunge stretch" || $0.name == "Side lunge stretch" })
        #expect(steps.allSatisfy { WorkoutTimedSessions.mobilityHoldRange.contains($0.holdSeconds ?? 0) })
        #expect(Self.sidesPaired(steps))
    }

    /// Too short for the flow even at 30 s: each move once, whole moves off the end, never a lone side.
    @Test func aShortMobilityFlowDropsWholeMoves() {
        let steps = WorkoutTimedSessions.mobilityFlow(minutes: 5, feasible: Self.everyStretch)
        #expect(!steps.isEmpty)
        #expect(Self.sidesPaired(steps))
        #expect(steps.filter { $0.name == "Standing forward fold" }.count == 1, "each move once")
        let hold = steps.first?.holdSeconds ?? 0
        #expect(steps.count * (hold + WorkoutTimedSessions.stretchLeadInSeconds) <= 6 * 60)
    }

    @Test func theGentleStretchIsShortAndOnTheFloor() {
        let steps = WorkoutTimedSessions.gentleStretch(feasible: Self.everyStretch)
        let seconds = steps.count * (WorkoutTimedSessions.gentleHoldSeconds + WorkoutTimedSessions.stretchLeadInSeconds)
        #expect((7 * 60...9 * 60).contains(seconds), "about eight minutes: \(seconds) s")
        #expect(steps.allSatisfy { $0.block == .mobility && $0.holdSeconds == WorkoutTimedSessions.gentleHoldSeconds })
        let names = Set(steps.map(\.name))
        for standing in ["Standing quad stretch", "Low lunge stretch", "Side lunge stretch", "Standing forward fold", "Downward dog"] {
            #expect(!names.contains(standing), "\(standing) is not gentle enough for an unwell day")
        }
        #expect(Self.sidesPaired(steps))
    }

    // MARK: The rest day stays optional

    @Test func theRestDayStretchStaysOptional() throws {
        let plan = WorkoutPlanningService.restDayPlan(locationName: "Home")
        let rest = try #require(plan.sessions.first)
        #expect(!GuidedWorkoutAvailability.isGuidable(rest), "never today's workout on a rest day")
        #expect(GuidedWorkoutAvailability.firstGuidable(in: plan, excluding: []) == nil)
        #expect(GuidedWorkoutAvailability.optionalStretch(in: plan, excluding: [])?.id == rest.id)
        #expect(GuidedWorkoutAvailability.optionalStretch(in: plan, excluding: [rest.id]) == nil, "gone once it is logged")
        #expect(GuidedWorkoutAvailability.optionalStretch(in: plan, excluding: [], loggedGuidedWorkoutNames: [rest.suggestion.name]) == nil)
        guard case .noneToGuide = GuidedWorkoutCardState.resolve(plan: plan, completed: []) else {
            Issue.record("a rest-day plan resolved to a startable card")
            return
        }
        // A training day never offers it, and its cardio is the session itself.
        let cardio = Self.session([Self.line("Easy cardio - 20 min")], kind: .cardio, title: "Easy cardio")
        let training = WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: [cardio], droppedSlots: [], locationName: "Gym")
        #expect(GuidedWorkoutAvailability.optionalStretch(in: training, excluding: []) == nil)
        #expect(GuidedWorkoutAvailability.firstGuidable(in: training, excluding: [])?.id == cardio.id)
    }

    @Test func theRestDayStretchRunsAsAGentleStretchSession() throws {
        let rest = try #require(WorkoutPlanningService.restDayPlan(locationName: "Home").sessions.first)
        let run = try Self.startedRun(rest)
        #expect(run.exercises.count == WorkoutTimedSessions.gentleStretch(feasible: Self.everyStretch).count)
        #expect(run.exercises.allSatisfy { $0.block == GuidedWorkoutRunState.BlockToken.mobility && $0.holdSeconds == 40 })
        #expect(GuidedRunTimedLog.activityType(for: run) == .flexibility)
        // "Already did this — log it" still records a plain movement row: it may as well have been a walk.
        #expect(rest.workout(intensity: .light).activityType == nil)
    }

    // MARK: Walking the segments

    @Test func aCardioRunWalksItsSegments() throws {
        let cardio = Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals")
        let run = try Self.startedRun(cardio)
        #expect(run.exercises.count == 16)
        #expect(run.exercises.allSatisfy { $0.block == GuidedWorkoutRunState.BlockToken.cardio && $0.restSeconds == 0 })
        #expect(run.exercises.first?.leadInSeconds == nil)
        #expect(run.exercises.dropFirst().allSatisfy { $0.leadInSeconds == 0 })
        #expect(run.exercises.first?.segment
                == GuidedWorkoutRunState.Segment(paceRaw: "hard", round: 1, rounds: 8, descriptor: Self.intervalsLine))
        #expect(GuidedBlockSkip(run: run).identifier == "workout.guided.finishEarly")
    }

    @Test func segmentsAutoAdvanceWithoutALeadInAfterTheFirst() throws {
        var run = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        let first = try #require(run.holdWindow)
        #expect(first.lowerBound == Self.t0.addingTimeInterval(5) && first.upperBound == Self.t0.addingTimeInterval(65))
        // The runner moves a part on at its window's end.
        run.markSetDone(now: first.upperBound)
        #expect(run.exerciseIndex == 1 && run.isWorking)
        let second = try #require(run.holdWindow)
        #expect(second.lowerBound == first.upperBound, "an easy part starts the moment the hard part ends")
        #expect(second.upperBound == first.upperBound.addingTimeInterval(60))
        #expect(run.currentExercise?.segment?.paceRaw == GuidedWorkoutRunState.PaceToken.easy)
        #expect(run.exercises[0].heldSeconds == 60)
        var now = second.upperBound
        for _ in 0..<15 {
            run.markSetDone(now: now)
            if let window = run.holdWindow { now = window.upperBound }
        }
        #expect(run.isFinishedNaturally, "the last part finishes the run by itself")
        #expect(run.exercises.reduce(0) { $0 + ($1.heldSeconds ?? 0) } == 16 * 60)
        #expect(GuidedRunTimedLog.heldMinutes(for: run) == 16)
    }

    @Test func theTimeLeftCountsEachPartOnce() throws {
        let run = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        // Sixteen minutes of parts, each counted once. The one five-second "get ready" before the first part is
        // not counted, as the plan card's estimate does not count it (so a budget's minutes stay whole).
        #expect(run.estimatedSecondsRemaining() == 16 * 60)
    }

    // MARK: Skipping a block

    @Test func finishEarlyLogsTheTimeHeld() throws {
        var run = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        #expect(run.canSkipBlock && !run.hasStepAfterCurrentBlock)
        run.skipBlock(now: Self.t0.addingTimeInterval(35))
        #expect(run.isFinishedNaturally)
        #expect(run.exercises.first?.heldSeconds == 30)
        #expect(GuidedRunTimedLog.heldMinutes(for: run) == 1)
    }

    @Test func skipCardioHandsOverToTheCoolDown() throws {
        let bench = PrescribedExercise(name: "Bench press", sets: 1, reps: "8", role: .main, fromCatalog: true)
        let finisher = Self.line("Intervals - 4 × 1 min hard / 1 min easy", block: .cardio)
        let calf = PrescribedExercise(name: "Calf stretch", sets: 1, reps: "45 s", role: .accessory, fromCatalog: true,
                                      restSecondsOverride: 0, block: .coolDown, holdSeconds: 45)
        var run = try Self.startedRun(Self.session([bench, finisher, calf], kind: .strength, title: "Push"))
        #expect(run.exercises.count == 10)
        #expect(!run.canSkipBlock, "the lifting block is not skipped wholesale")
        run.markSetDone(now: Self.t0.addingTimeInterval(30))
        #expect(run.canSkipBlock && run.hasStepAfterCurrentBlock)
        #expect(GuidedBlockSkip(run: run).identifier == "workout.guided.skipCardio")
        run.skipBlock(now: Self.t0.addingTimeInterval(40))
        #expect(run.isWorking && run.currentBlock == GuidedWorkoutRunState.BlockToken.coolDown)
        // The cool-down's own skip still finishes and logs.
        #expect(GuidedBlockSkip(run: run).identifier == "workout.guided.skipCoolDown")
    }

    // MARK: The Live Activity

    @Test func theLiveActivityShowsTheSegment() throws {
        var run = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        run.markSetDone(now: Self.t0.addingTimeInterval(65))
        let content = run.contentState
        #expect(content.paceRaw == "easy" && content.round == 1 && content.rounds == 8)
        #expect(content.holdStartsAt == Self.t0.addingTimeInterval(65))
        #expect(content.holdEndsAt == Self.t0.addingTimeInterval(125))
        #expect(content.exerciseName == "Intervals" && content.totalSets == 1)
        #expect(content.load == nil, "a segment has no weight to show")
        #expect(content.blockRaw == GuidedWorkoutRunState.BlockToken.cardio)
    }

    /// A payload, or a stored run, from before guided cardio still decodes — with no segment.
    @Test func olderPayloadsAndRunsDecode() throws {
        let run = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        let content = try JSONEncoder().encode(run.contentState)
        let oldContent = try Self.strip(content, keys: ["paceRaw", "round", "rounds"])
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: oldContent)
        #expect(decoded.paceRaw == nil && decoded.round == nil && decoded.holdEndsAt == run.contentState.holdEndsAt)

        let stored = try JSONEncoder().encode(run)
        let oldRun = try Self.strip(stored, keys: ["leadInSeconds", "segment", "heldSeconds"], inArray: "exercises")
        let decodedRun = try JSONDecoder().decode(GuidedWorkoutRunState.self, from: oldRun)
        #expect(decodedRun.exercises.count == 16)
        #expect(decodedRun.exercises.allSatisfy { $0.segment == nil && $0.holdLeadIn == GuidedWorkoutRunState.holdLeadInSeconds })
    }

    // MARK: Cues and VoiceOver at a segment change

    @Test func aSegmentChangeCuesOnceAndSaysItsPace() throws {
        let before = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        var after = before
        after.markSetDone(now: Self.t0.addingTimeInterval(65))
        // One haptic or sound cue for the move…
        #expect(GuidedRunCuePlan.transitionCue(from: before, to: after, cause: .holdRanOut) == .holdEnded)
        // …and none at the next part's start: it has no lead-in, so its start IS that move.
        #expect(GuidedRunCuePlan.timedCues(for: after, sheetDrivesHoldEnd: true).isEmpty)
        #expect(GuidedRunCuePlan.timedCues(for: before, sheetDrivesHoldEnd: true).map(\.event) == [.holdStarted])
        // The background cue says a timed part ran out, not a hold.
        #expect(GuidedRunCuePlan.backgroundCues(for: after).map(\.kind) == [.segmentEnded])
        // VoiceOver hears the pace, length and round once — not "Next: Intervals."
        let spoken = try #require(GuidedRunAnnouncement.spoken(from: before, to: after))
        let sentence = String(localized: spoken.sentence)
        #expect(sentence.hasPrefix("Easy for ") && sentence.hasSuffix(". Round 1 of 8."), "\(sentence)")
        #expect(String(localized: GuidedSegmentWords.goLine(GuidedWorkoutRunState.PaceToken.hard)) == "Go — hard.")
    }

    @Test func paceWordsAreWords() throws {
        #expect(GuidedSegmentWords.paceWord(GuidedWorkoutRunState.PaceToken.hard) == "Hard")
        #expect(GuidedSegmentWords.paceWord(GuidedWorkoutRunState.PaceToken.easy) == "Easy")
        #expect(GuidedSegmentWords.paceWord(GuidedWorkoutRunState.PaceToken.steady) == "Steady")
        #expect(GuidedSegmentWords.paceWord("sprint") == "Steady", "an unknown token reads as steady")
        let run = try Self.startedRun(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals"))
        let easy = try #require(run.exercises.dropFirst().first)
        let upNext = GuidedSegmentWords.upNextName(easy)
        #expect(upNext.hasPrefix("Easy ") && upNext.hasSuffix(":00"), "\(upNext)")
    }

    @Test func theSegmentCueNotificationSaysAPartEnded() {
        let segment = NotificationService.workoutCueContent(for: .segmentEnded, soundFileName: nil)
        let hold = NotificationService.workoutCueContent(for: .holdEnded, soundFileName: nil)
        #expect(!segment.title.isEmpty && !segment.body.isEmpty)
        #expect(segment.title != hold.title)
        #expect(NotificationService.workoutCueID(for: .segmentEnded) == "fernlet.workoutCue.segmentEnded")
        #expect(NotificationService.isWorkoutCue(NotificationService.workoutCueID(for: .segmentEnded)))
    }

    // MARK: Logging

    @Test func aFinishedCardioRunLogsAsCardioWithItsTime() throws {
        let directory = uniqueAppGroupDirectory()
        let store = makeTestStore(appGroupDirectory: directory)
        let cardio = Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals")
        Self.commit(cardio, to: store)
        #expect(store.startGuidedRun(cardio))
        var run = try #require(store.guidedRunState)
        run.setStartedAt = Self.t0
        var now = Self.t0.addingTimeInterval(65)
        for _ in 0..<16 {
            run.markSetDone(now: now)
            if let window = run.holdWindow { now = window.upperBound }
        }
        #expect(run.isFinishedNaturally)
        // Finished as the Lock Screen would leave it; the app logs it on its next look.
        #expect(GuidedWorkoutRunStateStore(directory: directory).write(run))
        store.reconcileGuidedRunFromAppGroup()
        let logged = try #require(store.day.workouts.first { $0.name == "Intervals" && $0.loggedFromGuidedSession == true })
        #expect(logged.mode == .activity && logged.type == .cardio)
        #expect(logged.activityType == .hiit)
        #expect(logged.duration == 16)
        #expect(logged.exercises == Self.intervalsLine, "the log names the line, not sixteen parts")
    }

    @Test func timedRunsLogTheRightActivity() throws {
        let steady = try Self.startedRun(Self.session([Self.line("Steady cardio - 20 min")], kind: .cardio, title: "Steady cardio"))
        #expect(GuidedRunTimedLog.activityType(for: steady) == .mixedCardio)
        let walk = try Self.startedRun(Self.session([Self.line("Easy walk - 15 min")], kind: .cardio, title: "Walk"))
        #expect(GuidedRunTimedLog.activityType(for: walk) == .walking)
        let mobility = try Self.startedRun(Self.session([Self.line("Mobility flow - 15 min")], kind: .mobility, title: "Mobility"))
        #expect(GuidedRunTimedLog.activityType(for: mobility) == .flexibility)
        #expect(mobility.exercises.count == WorkoutSessionBlocks.warmUpFlow.count)
        #expect(GuidedBlockSkip(run: mobility).identifier == "workout.guided.finishEarly")
        let lift = try Self.startedRun(Self.session(
            [PrescribedExercise(name: "Bench press", sets: 2, reps: "8", role: .main, fromCatalog: true)], kind: .strength, title: "Push"
        ))
        #expect(GuidedRunTimedLog.activityType(for: lift) == nil && GuidedRunTimedLog.heldMinutes(for: lift) == nil,
                "a lifting run's type and length are not this idea's")
        // The "Already did this" path names the same activities.
        #expect(Self.session([Self.line(Self.intervalsLine)], kind: .cardio, title: "Intervals").workout(intensity: .moderate).activityType == .hiit)
        #expect(Self.session([Self.line("Mobility flow - 15 min")], kind: .mobility, title: "Mobility").workout(intensity: .light).activityType == .flexibility)
    }

    // MARK: Frozen tokens

    @Test func tokensMatchTheDomain() {
        #expect(GuidedWorkoutRunState.BlockToken.mobility == SessionBlock.mobility.rawValue)
        #expect(GuidedWorkoutRunState.PaceToken.steady == CardioPace.steady.rawValue)
        #expect(GuidedWorkoutRunState.PaceToken.hard == CardioPace.hard.rawValue)
        #expect(GuidedWorkoutRunState.PaceToken.easy == CardioPace.easy.rawValue)
        #expect(WorkoutTimedSessions.stretchLeadInSeconds == GuidedWorkoutRunState.holdLeadInSeconds)
    }
}
