// GuidedRunSpokenCueTests.swift
// FernletTests
//
// Pins the guided runner's opt-in spoken cues (comparison report idea 11, 2026-10-20): the words each
// moment says (`GuidedRunSpokenCue`), the device-local "Spoken cues" switch, the director's gates (the
// switch, the app in front, on time and once), the VoiceOver routing (one voice: the announcer instead
// of the synthesizer, and nothing the runner sheet already said), and FernletUI's `FernletSpeaker` —
// its audio policy per route and the exact audio-session call sequence around each line.
//
// The synthesizer, the audio session and VoiceOver never report back in a unit test, so each is an
// injected seam here, as `FernletFeedback` and `FernletAnnouncer` are in their suites. What no test
// here can check — that the voice is heard in AirPods over music, that the music dips and comes back,
// that the ring/silent switch silences the speaker, and how VoiceOver reads the joined line — is owed
// on a device.

import AVFAudio
import Foundation
import Testing
import FernletUI
@testable import Fernlet

/// A voice that records what it was asked to say and reports idle only when the test says so.
@MainActor
private final class FakeVoice: FernletSpeechVoice {
    /// Every line, in order.
    private(set) var said: [String] = []
    /// Each line's idle report, in order.
    private var idles: [@MainActor () -> Void] = []

    func say(_ text: String, whenIdle idle: @escaping @MainActor () -> Void) {
        said.append(text)
        idles.append(idle)
    }

    /// Reports idle the way line `index` (default: the latest) would.
    func finish(line index: Int? = nil) {
        let at = index ?? idles.count - 1
        guard idles.indices.contains(at) else { return }
        idles[at]()
    }
}

/// The refusal a ``SessionRecorder`` throws for the call it is told to refuse.
private struct SessionRefused: Error {}

/// Records every audio-session call, and refuses one on request.
@MainActor
private final class SessionRecorder {
    /// Every call attempted, in order — a refused one included.
    var calls: [FernletSpeechSessionCall] = []
    /// The call to refuse, if any.
    var refuse: FernletSpeechSessionCall?

    /// The session seam.
    var perform: @MainActor (FernletSpeechSessionCall) throws -> Void {
        { [self] call in
            calls.append(call)
            if call == refuse { throw SessionRefused() }
        }
    }
}

/// Records every VoiceOver announcement.
@MainActor
private final class AnnouncementRecorder {
    /// Every announcement, in order.
    var posted: [FernletAnnouncement] = []

    /// An announcer that records here instead of posting.
    var announcer: FernletAnnouncer {
        FernletAnnouncer { [self] in posted.append($0) }
    }
}

/// A speaker wired to recorders, with VoiceOver and the route fixed for the test.
@MainActor
private final class SpeechRig {
    let voice: FakeVoice
    let session: SessionRecorder
    let announcements: AnnouncementRecorder
    let speaker: FernletSpeaker

    init(voiceOver: Bool = false, route: FernletSpeechAudioPolicy = .phoneSpeaker) {
        let voice = FakeVoice()
        let session = SessionRecorder()
        let announcements = AnnouncementRecorder()
        self.voice = voice
        self.session = session
        self.announcements = announcements
        speaker = FernletSpeaker(
            voice: voice, policy: { route }, session: session.perform,
            isVoiceOverRunning: { voiceOver }, announcer: announcements.announcer, settle: .zero
        )
    }

    /// Nothing reached the voice, the session or the announcer.
    var isSilent: Bool { voice.said.isEmpty && session.calls.isEmpty && announcements.posted.isEmpty }
}

@MainActor
@Suite struct GuidedRunSpokenCueTests {

    // MARK: Fixtures

    private nonisolated static let start = Date(timeIntervalSince1970: 2_000_000)

    private static func run(_ exercises: [GuidedWorkoutRunState.Exercise], at origin: Date? = nil) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate", title: "Spoken",
            suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: exercises, setStartedAt: origin ?? start
        )
    }

    /// A tracked barbell lift: 105 lb suggested and preselected, last time 3 × 8 @ 100 lb.
    private static func trackedLift(_ name: String, sets: Int = 3) -> GuidedWorkoutRunState.Exercise {
        let tracking = GuidedWorkoutRunState.Tracking(
            targetReps: 8, rangeLow: 95, rangeHigh: 110, suggested: 105, step: 5, unitRaw: "lb",
            equipmentRaw: "barbell", confidenceRaw: nil, askReasonOnOverride: false, calibrationRaw: nil,
            easierSession: false, compoundsBefore: 0, selected: 105
        )
        return GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: 90,
            blockRaw: "lifting", tracking: tracking,
            lastTime: GuidedWorkoutRunState.LastTime(sets: 3, reps: "8", weight: 100, unitRaw: "lb")
        )
    }

    /// A lift with no load plan and no history.
    private static func plainLift(_ name: String, sets: Int = 1) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: 60, blockRaw: "lifting"
        )
    }

    /// A timed step held for `seconds`, on one side when `side` is given.
    private static func hold(
        _ name: String, seconds: Int = 20, sets: Int = 1, side: String? = nil, block: String = "warmUp"
    ) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: "\(seconds) s", roleRaw: "core", fromCatalog: true,
            restSeconds: 0, holdSeconds: seconds, blockRaw: block, sideRaw: side
        )
    }

    /// One part of "Intervals - 8 × 1 min hard / 1 min easy".
    private static func part(_ pace: String, round: Int?, rounds: Int?, seconds: Int = 60) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: "Intervals", sets: 1, reps: "", roleRaw: "cardio", fromCatalog: false, restSeconds: 0,
            holdSeconds: seconds, blockRaw: "cardio", leadInSeconds: 0,
            segment: GuidedWorkoutRunState.Segment(paceRaw: pace, round: round, rounds: rounds,
                                                   descriptor: "Intervals - 8 × 1 min hard / 1 min easy")
        )
    }

    /// A run resting before set 2 of a lift, its rest running from `restStart` to `restEnd`.
    private static func resting(from restStart: Date, to restEnd: Date) -> GuidedWorkoutRunState {
        var state = run([plainLift("Squat", sets: 2)], at: restStart)
        state.currentSet = 2
        state.phase = .resting
        state.restStartedAt = restStart
        state.restEndsAt = restEnd
        return state
    }

    /// The last set of a plain lift, moved on to a tracked Row: the move that names a new lift.
    private static func ontoTheRow() -> (before: GuidedWorkoutRunState, after: GuidedWorkoutRunState) {
        let before = run([plainLift("Squat"), trackedLift("Row")])
        var after = before
        after.markSetDone(now: start)
        return (before, after)
    }

    private func director(_ rig: SpeechRig, spoken: Bool = true, active: Bool = true) -> GuidedRunCueDirector {
        GuidedRunCueDirector(
            feedback: FernletFeedback { _ in },
            preferences: { FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false) },
            isAppActive: { active },
            scheduleBackground: { _, _ in },
            speaker: rig.speaker,
            spokenCuesOn: { spoken }
        )
    }

    // MARK: The words — the run's clock

    /// A rest's end, a hold's start and end, and a cardio part's start and end each have their words;
    /// the moments the clock never cues have none.
    @Test func timedMomentsSayTheirWords() {
        let plank = Self.run([Self.hold("Plank", seconds: 30, block: "activation")])
        let hard = Self.run([Self.part("hard", round: 3, rounds: 8)])
        #expect(GuidedRunSpokenCue.timed(.restEnded, in: Self.resting(from: Self.start, to: Self.start)) == "Rest's over.")
        #expect(GuidedRunSpokenCue.timed(.holdStarted, in: plank) == String(localized: GuidedRunAnnouncement.holdStartedLine))
        #expect(GuidedRunSpokenCue.timed(.holdStarted, in: plank) == "Hold now.")
        #expect(GuidedRunSpokenCue.timed(.holdStarted, in: hard) == "Go — hard.")
        #expect(GuidedRunSpokenCue.timed(.holdEnded, in: plank) == "Hold's done.")
        #expect(GuidedRunSpokenCue.timed(.holdEnded, in: hard) == "Time's up on this part.")
        for event in [FernletFeedbackEvent.setLogged, .blockChanged, .workoutFinished] {
            #expect(GuidedRunSpokenCue.timed(event, in: plank) == nil)
        }
    }

    // MARK: The words — moves

    /// Moving onto a lift says its name, then its suggested weight and last time — one clause, in the
    /// Live Activity's spoken words, without the range.
    @Test func aNewLiftSaysItsNameAndWeight() throws {
        let move = Self.ontoTheRow()
        let line = try #require(GuidedRunSpokenCue.move(from: move.before, to: move.after, cause: .setDone))
        let load = try #require(move.after.currentLoad)
        let weight = try #require(WorkoutActivityLoadText.spokenWeight(load))
        let last = try #require(WorkoutActivityLoadText.spokenLastTime(load))
        #expect(line.hasPrefix("Next: Row."))
        #expect(line.contains(weight) && line.contains(last))
        #expect(line.contains("Suggested weight") && line.contains("105") && line.contains("last time 3 by 8"))
        let range = try #require(WorkoutActivityLoadText.spokenRange(load))
        #expect(!line.contains(range), "the range is left out: one number sets up a bar")
    }

    /// A one-sided step says its side; a plain lift with nothing logged says only its name.
    @Test func aNewStepSaysItsSide() {
        let flow = Self.run([Self.hold("Forward fold"), Self.hold("Cat-cow", side: "left"), Self.plainLift("Squat")])
        var onCatCow = flow
        onCatCow.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: flow, to: onCatCow, cause: .holdRanOut) == "Next: Cat-cow, left side.")
        var onSquat = onCatCow
        onSquat.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: onCatCow, to: onSquat, cause: .setDone) == "Next: Squat.")
    }

    /// An interval part says its pace and round; a steady part says VoiceOver's own pace-and-length line.
    @Test func cardioPartsSayTheirPaceAndRound() {
        let intervals = Self.run([Self.part("hard", round: 3, rounds: 8), Self.part("easy", round: 3, rounds: 8),
                                  Self.part("hard", round: 4, rounds: 8)])
        var easy = intervals
        easy.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: intervals, to: easy, cause: .holdRanOut) == "Easy, round 3 of 8.")
        var hard = easy
        hard.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: easy, to: hard, cause: .holdRanOut) == "Hard, round 4 of 8.")

        let steady = Self.part("steady", round: nil, rounds: nil, seconds: 1_200)
        let warmUp = Self.run([Self.hold("Forward fold"), steady])
        var onSteady = warmUp
        onSteady.markSetDone(now: Self.start)
        let segment = GuidedWorkoutRunState.Segment(paceRaw: "steady", round: nil, rounds: nil,
                                                    descriptor: "Intervals - 8 × 1 min hard / 1 min easy")
        #expect(GuidedRunSpokenCue.move(from: warmUp, to: onSteady, cause: .holdRanOut)
                == String(localized: GuidedSegmentWords.changeLine(segment, seconds: 1_200)))
    }

    /// The finish says "Workout done."; an abandon, a rest beginning and a skipped rest say nothing;
    /// a hold that ran out into a rest says so.
    @Test func finishesRestsAndHoldEnds() {
        let last = Self.run([Self.plainLift("Squat")])
        var finished = last
        finished.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: last, to: finished, cause: .setDone) == "Workout done.")
        var abandoned = last
        abandoned.end()
        #expect(GuidedRunSpokenCue.move(from: last, to: abandoned, cause: .skip) == nil)

        let squats = Self.run([Self.plainLift("Squat", sets: 2)])
        var intoRest = squats
        intoRest.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: squats, to: intoRest, cause: .setDone) == nil)
        var skipped = intoRest
        skipped.skipRest(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: intoRest, to: skipped, cause: .skip) == nil)

        let planks = Self.run([Self.hold("Plank", seconds: 30, sets: 2, block: "activation")])
        var planksRest = planks
        planksRest.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.move(from: planks, to: planksRest, cause: .holdRanOut) == "Hold's done.")
    }

    /// A skip that lands on a new lift names it; nothing before, no move, or no run after says nothing.
    @Test func skipsNameTheNewStepAndNonMovesAreSilent() {
        let squats = Self.run([Self.plainLift("Squat", sets: 3), Self.trackedLift("Row")])
        var skipped = squats
        skipped.exerciseIndex = 1
        #expect(GuidedRunSpokenCue.move(from: squats, to: skipped, cause: .skip)?.hasPrefix("Next: Row.") == true)
        #expect(GuidedRunSpokenCue.move(from: nil, to: squats, cause: .setDone) == nil)
        #expect(GuidedRunSpokenCue.move(from: squats, to: squats, cause: .setDone) == nil)
        #expect(GuidedRunSpokenCue.move(from: squats, to: nil, cause: .setDone) == nil)
    }

    /// The weight clause is for a move onto a lift only: never within one, for a timed step, or for a
    /// lift with nothing to say. A weight the lifter picked is said as theirs, not as the suggestion.
    @Test func theWeightClauseIsForANewLiftOnly() throws {
        let move = Self.ontoTheRow()
        #expect(GuidedRunSpokenCue.loadClause(from: move.before, to: move.after) != nil)
        var nextSet = move.after
        nextSet.markSetDone(now: Self.start)
        #expect(GuidedRunSpokenCue.loadClause(from: move.after, to: nextSet) == nil, "same lift, into a rest")
        #expect(GuidedRunSpokenCue.loadClause(for: Self.run([Self.hold("Plank", seconds: 30)])) == nil)
        #expect(GuidedRunSpokenCue.loadClause(for: Self.run([Self.plainLift("Squat")])) == nil)

        var picked = move.after
        let id = try #require(picked.currentExercise?.id)
        picked.selectWeight(110, forExercise: id)
        let clause = try #require(GuidedRunSpokenCue.loadClause(for: picked))
        #expect(clause.hasPrefix("Weight") && clause.contains("110"))
    }

    // MARK: The words — Start (round 2, R4)

    /// One of a back squat's warm-up sets at 45 lb.
    private static func warmUpSet() -> GuidedWorkoutRunState.Exercise {
        let tracking = GuidedWorkoutRunState.Tracking(
            targetReps: 8, rangeLow: 45, rangeHigh: 45, suggested: 45, step: 5, unitRaw: "lb",
            equipmentRaw: "barbell", confidenceRaw: nil, askReasonOnOverride: false,
            calibrationRaw: GuidedWorkoutRunState.CalibrationToken.ramp, easierSession: false, compoundsBefore: 0,
            selected: 45
        )
        return GuidedWorkoutRunState.Exercise(
            name: "Back squat", sets: 1, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: 90,
            blockRaw: "lifting", tracking: tracking
        )
    }

    /// At Start the first step is named as the first — "First: Goblet squat." — with its suggested
    /// weight and last time, as a move onto it would say them.
    @Test func startNamesTheFirstStepAndItsWeight() throws {
        let state = Self.run([Self.trackedLift("Goblet squat"), Self.plainLift("Row")])
        let line = try #require(GuidedRunSpokenCue.start(state))
        let clause = try #require(GuidedRunSpokenCue.loadClause(for: state))
        #expect(line == GuidedRunSpokenCue.sentences("First: Goblet squat.", clause))
        #expect(line.contains("Suggested weight") && line.contains("105"))
        let plain = GuidedRunSpokenCue.start(Self.run([Self.plainLift("Squat")]))
        #expect(plain == "First: Squat.")
    }

    /// A first step that is a warm-up set says the warm-up line; a one-sided stretch says its side; an
    /// interval says its pace and round; a run not working on a step says nothing.
    @Test func startSaysEachKindOfFirstStep() throws {
        let ramped = Self.run([Self.warmUpSet(), Self.warmUpSet(), Self.trackedLift("Back squat")])
        let warmUp = try #require(GuidedRunSpokenCue.start(ramped))
        #expect(warmUp.hasPrefix("Warm-up set 1 of 2: Back squat."))
        let sided = GuidedRunSpokenCue.start(Self.run([Self.hold("Cat-cow", side: "left")]))
        #expect(sided == "First: Cat-cow, left side.")
        let intervals = GuidedRunSpokenCue.start(Self.run([Self.part("hard", round: 1, rounds: 8)]))
        #expect(intervals == "Hard, round 1 of 8.")
        var done = Self.run([Self.plainLift("Squat")])
        done.phase = .done
        let silent = GuidedRunSpokenCue.start(done) == nil
        #expect(silent)
    }

    /// The director says the start line aloud once, at Start — only with spoken cues on and the app in
    /// front, and never to VoiceOver, which hears the runner screen itself.
    @Test func theFirstStepIsSpokenAtStart() throws {
        let state = Self.run([Self.trackedLift("Goblet squat")])
        let expected = try #require(GuidedRunSpokenCue.start(state))
        let rig = SpeechRig()
        director(rig).started(state)
        #expect(rig.voice.said == [expected])
        #expect(rig.announcements.posted.isEmpty)
        let off = SpeechRig()
        director(off, spoken: false).started(state)
        #expect(off.isSilent)
        let away = SpeechRig()
        director(away, active: false).started(state)
        #expect(away.isSilent)
        let voiceOver = SpeechRig(voiceOver: true)
        director(voiceOver).started(state)
        #expect(voiceOver.isSilent)
    }

    /// Two sentences join with the locale's separator; a missing or empty second leaves the first alone.
    @Test func sentencesJoin() {
        #expect(GuidedRunSpokenCue.sentences("Next: Row.", "Suggested weight 105 pounds") == "Next: Row. Suggested weight 105 pounds")
        #expect(GuidedRunSpokenCue.sentences("Next: Row.", nil) == "Next: Row.")
        #expect(GuidedRunSpokenCue.sentences("Next: Row.", "") == "Next: Row.")
    }

    // MARK: The switch

    /// Off until the person turns it on; Save round-trips; the key is frozen; the other switches are
    /// untouched by it.
    @Test func spokenSwitchIsOffUntilTurnedOn() throws {
        let suite = "fernlet.tests.spokenCues.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!WorkoutCuePreferences.spokenEnabled(in: defaults))
        #expect(!WorkoutCuePreferences.defaultSpoken)
        WorkoutCuePreferences.saveSpoken(true, in: defaults)
        #expect(WorkoutCuePreferences.spokenEnabled(in: defaults))
        #expect(WorkoutCuePreferences.current(in: defaults) == WorkoutCuePreferences.defaultSwitches)
        WorkoutCuePreferences.saveSpoken(false, in: defaults)
        #expect(!WorkoutCuePreferences.spokenEnabled(in: defaults))
        #expect(WorkoutCuePreferences.spokenKey == "fernlet.workoutCues.spoken")
    }

    // MARK: The director — gates

    /// With the switch off, no move and no timed moment reaches the voice, the session or VoiceOver.
    @Test func spokenCuesAreOptIn() async {
        let rig = SpeechRig()
        let cues = director(rig, spoken: false)
        let move = Self.ontoTheRow()
        cues.transition(from: move.before, to: move.after, cause: .setDone)
        let now = Date()
        cues.runChanged(to: Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5)))
        await cues.timedCuesSettled()
        #expect(rig.isSilent)
        #expect(cues.voiceOverAddition(from: move.before, to: move.after) == nil)
    }

    /// With the app in the background nothing is spoken — no move, no timed moment.
    @Test func nothingIsSpokenWhileTheAppIsAway() async {
        let rig = SpeechRig()
        let cues = director(rig, active: false)
        let move = Self.ontoTheRow()
        cues.transition(from: move.before, to: move.after, cause: .setDone)
        let now = Date()
        cues.runChanged(to: Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5)))
        await cues.timedCuesSettled()
        #expect(rig.isSilent)
    }

    /// A move is spoken aloud with VoiceOver off, inside one configured-then-released audio session.
    @Test func aMoveIsSpokenAloud() async throws {
        let rig = SpeechRig()
        let cues = director(rig)
        let move = Self.ontoTheRow()
        cues.transition(from: move.before, to: move.after, cause: .setDone)
        let expected = try #require(GuidedRunSpokenCue.move(from: move.before, to: move.after, cause: .setDone))
        #expect(rig.voice.said == [expected])
        #expect(rig.session.calls == [.configure(.phoneSpeaker), .activate])
        rig.voice.finish()
        await rig.speaker.settled()
        #expect(rig.session.calls == [.configure(.phoneSpeaker), .activate, .deactivate])
        #expect(rig.announcements.posted.isEmpty)
    }

    /// A timed moment just due is spoken once, alongside its haptic; re-armed on the same moment it is
    /// not spoken again; one long past is not spoken at all.
    @Test func aTimedMomentIsSpokenOnceAndOnTime() async {
        let now = Date()
        let rig = SpeechRig()
        let cues = director(rig)
        let rest = Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5))
        cues.runChanged(to: rest)
        await cues.timedCuesSettled()
        #expect(rig.voice.said == ["Rest's over."])
        cues.runChanged(to: nil)
        cues.runChanged(to: rest)
        await cues.timedCuesSettled()
        #expect(rig.voice.said == ["Rest's over."])

        let lateRig = SpeechRig()
        let late = director(lateRig)
        late.runChanged(to: Self.resting(from: now.addingTimeInterval(-120), to: now.addingTimeInterval(-30)))
        await late.timedCuesSettled()
        #expect(lateRig.isSilent)
    }

    // MARK: The director — VoiceOver

    /// VoiceOver on, runner sheet on screen: the sheet's own lines say every moment, so the speaker
    /// adds nothing — no synthesizer, no session, no second announcement.
    @Test func voiceOverHearsTheRunnerSheetAlone() async {
        let rig = SpeechRig(voiceOver: true)
        let cues = director(rig)
        cues.runnerOnScreen = true
        let move = Self.ontoTheRow()
        cues.transition(from: move.before, to: move.after, cause: .setDone)
        let now = Date()
        cues.runChanged(to: Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5)))
        await cues.timedCuesSettled()
        #expect(rig.isSilent)
    }

    /// VoiceOver on, runner sheet closed: a timed moment goes through the announcer — never the
    /// synthesizer, never the audio session.
    @Test func voiceOverHearsATimedMomentThroughTheAnnouncer() async {
        let rig = SpeechRig(voiceOver: true)
        let cues = director(rig)
        let now = Date()
        cues.runChanged(to: Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5)))
        await cues.timedCuesSettled()
        #expect(rig.announcements.posted == [FernletAnnouncement(kind: .status, message: "Rest's over.")])
        #expect(rig.voice.said.isEmpty)
        #expect(rig.session.calls.isEmpty)
    }

    /// The runner sheet's VoiceOver line for a move gains the new lift's weight while spoken cues are
    /// on — and nothing for a move that lands on no weight.
    @Test func theVoiceOverLineGainsOnlyTheWeight() {
        let cues = director(SpeechRig(voiceOver: true))
        let move = Self.ontoTheRow()
        #expect(cues.voiceOverAddition(from: move.before, to: move.after)
                == GuidedRunSpokenCue.loadClause(from: move.before, to: move.after))
        #expect(cues.voiceOverAddition(from: move.before, to: move.after) != nil)
        var intoRest = move.after
        intoRest.markSetDone(now: Self.start)
        #expect(cues.voiceOverAddition(from: move.after, to: intoRest) == nil)
    }

    // MARK: The speaker

    /// VoiceOver on: a line with VoiceOver words is announced, one without is dropped, and neither
    /// touches the synthesizer or the session.
    @Test func speakerRoutesThroughVoiceOverWhenItRuns() {
        let rig = SpeechRig(voiceOver: true)
        rig.speaker.say(FernletSpokenLine(text: "Rest's over.", voiceOverText: "Rest's over."))
        rig.speaker.say(FernletSpokenLine(text: "Next: Row.", voiceOverText: nil))
        #expect(rig.announcements.posted == [FernletAnnouncement(kind: .status, message: "Rest's over.")])
        #expect(rig.voice.said.isEmpty && rig.session.calls.isEmpty)
    }

    /// In headphones the session is configured for ducked playback; on the speaker, for ambient mixing.
    @Test func speakerConfiguresTheRoutesPolicy() async {
        let rig = SpeechRig(route: .headphones)
        rig.speaker.say(FernletSpokenLine(text: "Hold now.", voiceOverText: nil))
        #expect(rig.session.calls == [.configure(.headphones), .activate])
        rig.voice.finish()
        await rig.speaker.settled()
        #expect(rig.session.calls.last == .deactivate)
    }

    /// Back-to-back lines configure and activate for each, release once after the last — and an
    /// earlier line's late idle report releases nothing while a newer line is speaking.
    @Test func backToBackLinesReleaseTheSessionOnce() async {
        let rig = SpeechRig()
        rig.speaker.say(FernletSpokenLine(text: "Hold's done.", voiceOverText: nil))
        rig.speaker.say(FernletSpokenLine(text: "Next: Cat-cow.", voiceOverText: nil))
        rig.voice.finish(line: 0)
        await rig.speaker.settled()
        #expect(rig.session.calls == [.configure(.phoneSpeaker), .activate, .configure(.phoneSpeaker), .activate])
        rig.voice.finish(line: 1)
        await rig.speaker.settled()
        let deactivations = rig.session.calls.filter { $0 == .deactivate }.count
        #expect(deactivations == 1)
        #expect(rig.session.calls.last == .deactivate)
        #expect(rig.voice.said == ["Hold's done.", "Next: Cat-cow."])
    }

    /// A session that refuses to be configured or activated means the line is not spoken at all —
    /// never on a category that would stop the person's music.
    @Test func aRefusedSessionNeverSpeaks() {
        let unconfigured = SpeechRig()
        unconfigured.session.refuse = .configure(.phoneSpeaker)
        unconfigured.speaker.say(FernletSpokenLine(text: "Rest's over.", voiceOverText: nil))
        #expect(unconfigured.session.calls == [.configure(.phoneSpeaker)])
        #expect(unconfigured.voice.said.isEmpty)

        let inactive = SpeechRig()
        inactive.session.refuse = .activate
        inactive.speaker.say(FernletSpokenLine(text: "Rest's over.", voiceOverText: nil))
        #expect(inactive.session.calls == [.configure(.phoneSpeaker), .activate])
        #expect(inactive.voice.said.isEmpty)

        let empty = SpeechRig()
        empty.speaker.say(FernletSpokenLine(text: "", voiceOverText: nil))
        #expect(empty.isSilent)
    }

    // MARK: The audio policy

    /// The phone speaker only when every output is the phone's own (or there is none); anything else —
    /// headphones, Bluetooth, CarPlay, AirPlay — is the headphones policy.
    @Test func policyFollowsTheRoute() {
        #expect(FernletSpeechAudioPolicy.forRoute([.builtInSpeaker]) == .phoneSpeaker)
        #expect(FernletSpeechAudioPolicy.forRoute([.builtInReceiver]) == .phoneSpeaker)
        #expect(FernletSpeechAudioPolicy.forRoute([]) == .phoneSpeaker)
        #expect(FernletSpeechAudioPolicy.forRoute([.headphones]) == .headphones)
        #expect(FernletSpeechAudioPolicy.forRoute([.bluetoothA2DP]) == .headphones)
        #expect(FernletSpeechAudioPolicy.forRoute([.carAudio]) == .headphones)
        #expect(FernletSpeechAudioPolicy.forRoute([.builtInSpeaker, .airPlay]) == .headphones)
    }

    /// Neither policy can pause the person's music: the speaker mixes (and obeys the silent switch);
    /// headphones duck the music and pause only spoken audio, Apple's exercise-app pattern.
    @Test func neitherPolicyPausesMusic() {
        let speaker = FernletSpeechAudioPolicy.phoneSpeaker
        #expect(speaker.category == .ambient)
        #expect(speaker.options.isEmpty)
        let headphones = FernletSpeechAudioPolicy.headphones
        #expect(headphones.category == .playback)
        #expect(headphones.mode == .voicePrompt)
        #expect(headphones.options.contains(.duckOthers))
        #expect(headphones.options.contains(.interruptSpokenAudioAndMixWithOthers))
        for policy in FernletSpeechAudioPolicy.allCases {
            #expect(policy.category != .soloAmbient, "solo ambient would stop the person's music")
        }
    }

    /// The voice speaks the app's language, in the person's own region when their device speaks it.
    @Test func theVoiceSpeaksTheAppsLanguage() {
        #expect(FernletSpeaker.voiceLanguage(appLanguage: "en", locale: Locale(identifier: "en_GB")) == "en-GB")
        #expect(FernletSpeaker.voiceLanguage(appLanguage: "en", locale: Locale(identifier: "es_ES")) == "en")
        #expect(FernletSpeaker.voiceLanguage(appLanguage: "es", locale: Locale(identifier: "es_MX")) == "es-MX")
    }
}
