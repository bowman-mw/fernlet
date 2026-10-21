// GuidedRunCueTests.swift
// FernletTests
//
// Pins the guided runner's rest-end and hold-end cues (comparison report idea 2, 2026-10-20): the
// shared FernletFeedback seam's event mapping and switches, the runner's device-local cue switches,
// which run transitions and clock moments cue what, the background notification's shape, and the
// rule that nothing cues outside a live run, with the switches off, or with the app in the background.
//
// Same reason as `FernletAnnouncerTests`: UIKit never reports back what it played, so "did this buzz,
// and did that one NOT?" is only answerable through the player's injected closure. The rules
// themselves are pure — (before, after, cause) or (state) in, cue out — and are checked against real
// `GuidedWorkoutRunState` transitions without a view, a clock or a simulator haptic engine. What no
// test here can check — that the haptic is felt, the chime is quiet, the silent-switch is honoured,
// and the background notification buzzes a locked phone — is owed on a device.

import Foundation
import Testing
import UserNotifications
import FernletUI
@testable import AppServices
@testable import Fernlet

/// Records what a ``FernletFeedback`` was asked to play, in order.
@MainActor
private final class CueRecorder {
    /// Every cue that reached the player, in order.
    var played: [FernletFeedbackCue] = []

    /// A player that records here instead of playing.
    var feedback: FernletFeedback {
        FernletFeedback { [self] in played.append($0) }
    }

    /// The events only.
    var events: [FernletFeedbackEvent] { played.map(\.event) }
}

/// Records what a ``GuidedRunCueDirector`` asked the background (the notification center) to hold.
@MainActor
private final class BackgroundRecorder {
    /// One request: the cues and the sound file they carry.
    struct Schedule: Equatable {
        let cues: [NotificationService.WorkoutCue]
        let sound: String?
    }

    /// Every request, in order.
    var schedules: [Schedule] = []

    /// A scheduler that records here instead of touching the notification center.
    var scheduler: GuidedRunCueDirector.BackgroundScheduler {
        { [self] cues, sound in schedules.append(Schedule(cues: cues, sound: sound)) }
    }
}

@MainActor
@Suite struct GuidedRunCueTests {

    // MARK: Fixtures

    private nonisolated static let start = Date(timeIntervalSince1970: 2_000_000)
    private nonisolated static let hapticsOnly = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false)
    private static let bothOff = FernletFeedbackPreferences(hapticsEnabled: false, soundsEnabled: false)

    private static func run(_ exercises: [GuidedWorkoutRunState.Exercise], at origin: Date = GuidedRunCueTests.start) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate", title: "Cues",
            suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: exercises, setStartedAt: origin
        )
    }

    /// A rep-counted lift.
    private static func lift(_ name: String, sets: Int = 2, rest: Int = 60, block: String = "lifting") -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: rest, blockRaw: block
        )
    }

    /// A timed step held for `seconds`.
    private static func hold(_ name: String, seconds: Int, sets: Int = 1, rest: Int = 0, block: String) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: "\(seconds) s", roleRaw: "core", fromCatalog: true,
            restSeconds: rest, holdSeconds: seconds, blockRaw: block
        )
    }

    /// A run resting between two sets of one lift, its rest running from `restStart` to `restEnd`.
    private static func resting(from restStart: Date, to restEnd: Date) -> GuidedWorkoutRunState {
        var state = run([lift("Squat")], at: restStart)
        state.currentSet = 2
        state.phase = .resting
        state.restStartedAt = restStart
        state.restEndsAt = restEnd
        return state
    }

    // MARK: FernletFeedback — the event mapping

    /// Every event has a haptic; the two timer endings feel the same; a logged set is silent.
    @Test func eventMapping() {
        #expect(FernletFeedbackEvent.restEnded.haptic == .attention)
        #expect(FernletFeedbackEvent.holdEnded.haptic == FernletFeedbackEvent.restEnded.haptic)
        #expect(FernletFeedbackEvent.holdStarted.haptic == .firm)
        #expect(FernletFeedbackEvent.setLogged.haptic == .light)
        #expect(FernletFeedbackEvent.blockChanged.haptic == .heavy)
        #expect(FernletFeedbackEvent.workoutFinished.haptic == .success)
        #expect(FernletFeedbackEvent.setLogged.sound == nil, "the tap is its own sound")
        #expect(FernletFeedbackEvent.holdStarted.sound == .tick)
        for event in [FernletFeedbackEvent.restEnded, .holdEnded, .blockChanged, .workoutFinished] {
            #expect(event.sound == .chime)
        }
        // "Time's up" is two heavy impacts, not the `.warning` pattern reserved for caveats.
        #expect(FernletFeedback.attentionIntensity == 0.8)
        #expect(FernletFeedback.attentionGap == .milliseconds(150))
    }

    /// The cue keeps only the channels the switches leave on, and nothing at all when none play.
    @Test func cueHonoursTheSwitches() throws {
        let haptic = try #require(FernletFeedbackCue(event: .restEnded, preferences: Self.hapticsOnly))
        #expect(haptic.haptic == .attention && haptic.sound == nil)
        let soundsOnly = FernletFeedbackPreferences(hapticsEnabled: false, soundsEnabled: true)
        let sound = try #require(FernletFeedbackCue(event: .restEnded, preferences: soundsOnly))
        #expect(sound.haptic == nil && sound.sound == .chime)
        #expect(FernletFeedbackCue(event: .setLogged, preferences: soundsOnly) == nil, "no haptic, no sound")
        #expect(FernletFeedbackCue(event: .restEnded, preferences: Self.bothOff) == nil)
    }

    /// The player hands a cue to its output, and drops one whose switches are all off.
    @Test func playerDropsSilence() {
        let recorder = CueRecorder()
        recorder.feedback.play(.holdStarted, preferences: Self.hapticsOnly)
        recorder.feedback.play(.holdEnded, preferences: Self.bothOff)
        #expect(recorder.events == [.holdStarted])
        #expect(recorder.played.first?.haptic == .firm && recorder.played.first?.sound == nil)
    }

    /// The cue sounds — and the silent file a haptics-only background cue carries — ship in the app
    /// bundle under the names the player and the notifications ask for.
    @Test func cueSoundFilesShip() throws {
        for sound in FernletSound.allCases {
            #expect(Bundle.main.url(forResource: sound.rawValue, withExtension: FernletSound.fileExtension) != nil,
                    "\(sound.fileName) is missing from the app bundle")
        }
        #expect(FernletSound.chime.fileName == "fernlet-cue-chime.wav")
        let silent = GuidedRunCuePlan.silentNotificationSound
        let base = try #require(silent.split(separator: ".").first.map { String($0) })
        #expect(Bundle.main.url(forResource: base, withExtension: FernletSound.fileExtension) != nil)
    }

    // MARK: The switches

    /// Haptics on and sounds off until the person changes them; Save round-trips; the keys are frozen.
    @Test func cueSwitchesDefaultAndRoundTrip() throws {
        let suite = "fernlet.tests.workoutCues.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(WorkoutCuePreferences.current(in: defaults) == Self.hapticsOnly)
        #expect(WorkoutCuePreferences.defaultSwitches == Self.hapticsOnly)
        let flipped = FernletFeedbackPreferences(hapticsEnabled: false, soundsEnabled: true)
        WorkoutCuePreferences.save(flipped, in: defaults)
        #expect(WorkoutCuePreferences.current(in: defaults) == flipped)
        #expect(WorkoutCuePreferences.hapticsKey == "fernlet.workoutCues.haptics")
        #expect(WorkoutCuePreferences.soundsKey == "fernlet.workoutCues.sounds")
    }

    // MARK: Transitions — which move cues what

    /// "Done set" logs a set: into a rest, or on to the next lift in the same block.
    @Test func doneSetIsALoggedSet() {
        let before = Self.run([Self.lift("Squat"), Self.lift("Row")])
        var intoRest = before
        intoRest.markSetDone(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: before, to: intoRest, cause: .setDone) == .setLogged)

        var lastSet = before
        lastSet.currentSet = 2
        var nextLift = lastSet
        nextLift.markSetDone(now: Self.start)
        #expect(nextLift.exerciseIndex == 1)
        #expect(GuidedRunCuePlan.transitionCue(from: lastSet, to: nextLift, cause: .setDone) == .setLogged)
    }

    /// The finish outranks everything; an abandon is silent.
    @Test func finishCuesAndAbandonIsSilent() {
        var before = Self.run([Self.lift("Squat", sets: 1)])
        var finished = before
        finished.markSetDone(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: before, to: finished, cause: .setDone) == .workoutFinished)
        before.end()
        var live = Self.run([Self.lift("Squat", sets: 1)])
        var abandoned = live
        abandoned.end()
        #expect(GuidedRunCuePlan.transitionCue(from: live, to: abandoned, cause: .skip) == nil)
        live.markSetDone(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: before, to: live, cause: .setDone) == nil,
                "a run that was already over cues nothing")
    }

    /// Skipping is quiet unless it changes the block or finishes the session.
    @Test func skipsCueOnlyANewBlockOrTheFinish() {
        var resting = Self.run([Self.lift("Squat")])
        resting.markSetDone(now: Self.start)
        var skippedRest = resting
        skippedRest.skipRest(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: resting, to: skippedRest, cause: .skip) == nil)

        let warmUp = Self.run([Self.hold("Forward fold", seconds: 20, block: "warmUp"), Self.lift("Squat")])
        var skippedWarmUp = warmUp
        skippedWarmUp.skipBlock(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: warmUp, to: skippedWarmUp, cause: .skip) == .blockChanged)

        let coolDown = Self.run([Self.hold("Calf stretch", seconds: 45, block: "coolDown")])
        var skippedCoolDown = coolDown
        skippedCoolDown.skipBlock(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: coolDown, to: skippedCoolDown, cause: .skip) == .workoutFinished)
    }

    /// "Skip to next exercise" walks the run through every set and rest left, but the person tapped
    /// once, so it cues at most once: nothing inside one block, the block change when it crosses one
    /// (sounds-and-haptics report §3.9).
    @Test func skipToNextExerciseCuesAtMostOnce() {
        func skipped(_ before: GuidedWorkoutRunState) -> GuidedWorkoutRunState {
            var after = before
            // What `FernletStore.guidedSkipToNextExercise` does, bounded the same way.
            for _ in 0..<12 where after.exerciseIndex == before.exerciseIndex && !after.isDone {
                if after.isResting { after.skipRest(now: Self.start) } else { after.markSetDone(now: Self.start) }
            }
            return after
        }
        var sameBlock = Self.run([Self.lift("Squat", sets: 3), Self.lift("Row")])
        sameBlock.markSetDone(now: Self.start)
        let inBlock = CueRecorder()
        director(inBlock, BackgroundRecorder()).transition(from: sameBlock, to: skipped(sameBlock), cause: .skip)
        #expect(inBlock.played.isEmpty, "a skip inside one block is silent")

        let crossing = Self.run([Self.lift("Row", sets: 3), Self.hold("Calf stretch", seconds: 45, block: "coolDown")])
        let across = CueRecorder()
        director(across, BackgroundRecorder()).transition(from: crossing, to: skipped(crossing), cause: .skip)
        #expect(across.events == [.blockChanged], "one cue for the whole skip, never one per set")
    }

    /// A hold that runs out cues its end — or the new block it moves into.
    @Test func holdRunningOutCuesItsEndOrTheNewBlock() {
        let flow = Self.run([Self.hold("Forward fold", seconds: 20, block: "warmUp"),
                             Self.hold("Cat-cow", seconds: 30, block: "warmUp"),
                             Self.lift("Squat")])
        var nextStretch = flow
        nextStretch.markSetDone(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: flow, to: nextStretch, cause: .holdRanOut) == .holdEnded)
        var intoLifting = nextStretch
        intoLifting.markSetDone(now: Self.start)
        #expect(GuidedRunCuePlan.transitionCue(from: nextStretch, to: intoLifting, cause: .holdRanOut) == .blockChanged)
    }

    /// No live run before the move, or no move at all: nothing cues.
    @Test func noCueOutsideALiveMove() {
        let live = Self.run([Self.lift("Squat")])
        #expect(GuidedRunCuePlan.transitionCue(from: nil, to: live, cause: .setDone) == nil)
        #expect(GuidedRunCuePlan.transitionCue(from: live, to: live, cause: .setDone) == nil)
        #expect(GuidedRunCuePlan.transitionCue(from: live, to: nil, cause: .setDone) == nil)
    }

    // MARK: The run's clock — what is due when

    /// A rest cues its end; an empty rest cues nothing.
    @Test func restCuesItsEnd() {
        let end = Self.start.addingTimeInterval(90)
        let cues = GuidedRunCuePlan.timedCues(for: Self.resting(from: Self.start, to: end), sheetDrivesHoldEnd: true)
        #expect(cues == [GuidedRunCuePlan.TimedCue(event: .restEnded, fireAt: end)])
        let empty = Self.resting(from: Self.start, to: Self.start)
        #expect(GuidedRunCuePlan.timedCues(for: empty, sheetDrivesHoldEnd: false).isEmpty)
    }

    /// A timed step cues the end of its lead-in and of its hold; the hold's end is the sheet's when the
    /// sheet is driving it. A rep-counted set, a finished run and no run cue nothing.
    @Test func holdCuesItsLeadInAndEnd() {
        let plank = Self.run([Self.hold("Plank", seconds: 30, block: "activation")])
        let leadIn = TimeInterval(GuidedWorkoutRunState.holdLeadInSeconds)
        let holdStart = Self.start.addingTimeInterval(leadIn)
        let holdEnd = holdStart.addingTimeInterval(30)
        #expect(GuidedRunCuePlan.timedCues(for: plank, sheetDrivesHoldEnd: false) == [
            GuidedRunCuePlan.TimedCue(event: .holdStarted, fireAt: holdStart),
            GuidedRunCuePlan.TimedCue(event: .holdEnded, fireAt: holdEnd),
        ])
        #expect(GuidedRunCuePlan.timedCues(for: plank, sheetDrivesHoldEnd: true) == [
            GuidedRunCuePlan.TimedCue(event: .holdStarted, fireAt: holdStart),
        ])
        #expect(GuidedRunCuePlan.timedCues(for: Self.run([Self.lift("Squat")]), sheetDrivesHoldEnd: false).isEmpty)
        var done = plank
        done.end()
        #expect(GuidedRunCuePlan.timedCues(for: done, sheetDrivesHoldEnd: false).isEmpty)
        #expect(GuidedRunCuePlan.timedCues(for: nil, sheetDrivesHoldEnd: false).isEmpty)
    }

    /// The background carries the rest's end or the hold's end — never the lead-in — and nothing once
    /// the run is over.
    @Test func backgroundCarriesTheTimerEnd() throws {
        let end = Self.start.addingTimeInterval(90)
        #expect(GuidedRunCuePlan.backgroundCues(for: Self.resting(from: Self.start, to: end))
                == [NotificationService.WorkoutCue(kind: .restEnded, fireAt: end)])
        let plank = Self.run([Self.hold("Plank", seconds: 30, block: "activation")])
        let window = try #require(plank.holdWindow)
        #expect(GuidedRunCuePlan.backgroundCues(for: plank)
                == [NotificationService.WorkoutCue(kind: .holdEnded, fireAt: window.upperBound)])
        #expect(GuidedRunCuePlan.backgroundCues(for: Self.run([Self.lift("Squat")])).isEmpty)
        var done = plank
        done.end()
        #expect(GuidedRunCuePlan.backgroundCues(for: done).isEmpty)
        #expect(GuidedRunCuePlan.backgroundCues(for: nil).isEmpty)
    }

    /// A cue may play a little late, never long after its moment.
    @Test func lateCuesAreDropped() {
        let due = Self.start
        #expect(GuidedRunCuePlan.isOnTime(due, now: due.addingTimeInterval(1)))
        #expect(!GuidedRunCuePlan.isOnTime(due, now: due.addingTimeInterval(GuidedRunCuePlan.lateTolerance + 1)))
    }

    /// The background cue's sound follows the switches: chime, silence that still buzzes, or none.
    @Test func backgroundSoundFollowsTheSwitches() {
        #expect(GuidedRunCuePlan.notificationSound(for: FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: true))
                == FernletSound.chime.fileName)
        #expect(GuidedRunCuePlan.notificationSound(for: Self.hapticsOnly) == GuidedRunCuePlan.silentNotificationSound)
        #expect(GuidedRunCuePlan.notificationSound(for: Self.bothOff) == nil)
    }

    // MARK: The director

    private func director(
        _ cues: CueRecorder, _ background: BackgroundRecorder,
        preferences: FernletFeedbackPreferences = GuidedRunCueTests.hapticsOnly, active: Bool = true
    ) -> GuidedRunCueDirector {
        GuidedRunCueDirector(
            feedback: cues.feedback, preferences: { preferences }, isAppActive: { active },
            scheduleBackground: background.scheduler
        )
    }

    /// A tap cues only while the app is in front.
    @Test func tapsCueOnlyInTheForeground() {
        let before = Self.run([Self.lift("Squat")])
        var after = before
        after.markSetDone(now: Self.start)

        let away = CueRecorder()
        director(away, BackgroundRecorder(), active: false).transition(from: before, to: after, cause: .setDone)
        #expect(away.played.isEmpty)

        let open = CueRecorder()
        director(open, BackgroundRecorder()).transition(from: before, to: after, cause: .setDone)
        #expect(open.events == [.setLogged])
    }

    /// Both switches off: nothing plays and nothing is scheduled.
    @Test func switchedOffIsSilentEverywhere() async {
        let cues = CueRecorder()
        let background = BackgroundRecorder()
        let silent = director(cues, background, preferences: Self.bothOff)
        let now = Date()
        silent.runChanged(to: Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5)))
        await silent.timedCuesSettled()
        await silent.backgroundSettled()
        #expect(cues.played.isEmpty)
        #expect(background.schedules == [BackgroundRecorder.Schedule(cues: [], sound: nil)])
    }

    /// A rest that has just ended cues once; one that ended long ago (the app slept through it, and the
    /// background notification already said so) cues nothing.
    @Test func dueCuePlaysOnceAndAStaleOneIsDropped() async {
        let now = Date()
        let fresh = CueRecorder()
        let onTime = director(fresh, BackgroundRecorder())
        let rest = Self.resting(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-0.5))
        onTime.runChanged(to: rest)
        await onTime.timedCuesSettled()
        #expect(fresh.events == [.restEnded])
        // Re-armed on the same moment straight after (the run went away and came back): not replayed.
        onTime.runChanged(to: nil)
        onTime.runChanged(to: rest)
        await onTime.timedCuesSettled()
        #expect(fresh.events == [.restEnded])

        let stale = CueRecorder()
        let late = director(stale, BackgroundRecorder())
        late.runChanged(to: Self.resting(from: now.addingTimeInterval(-120), to: now.addingTimeInterval(-30)))
        await late.timedCuesSettled()
        #expect(stale.played.isEmpty)
    }

    /// The armed cues follow the run and the sheet, and go away with the run.
    @Test func armedCuesFollowTheRunAndTheSheet() {
        let cues = director(CueRecorder(), BackgroundRecorder())
        cues.runChanged(to: Self.run([Self.hold("Plank", seconds: 30, block: "activation")], at: Date()))
        #expect(cues.armedCues.map(\.event) == [.holdStarted, .holdEnded])
        cues.sheetDrivesHoldEnd = true
        #expect(cues.armedCues.map(\.event) == [.holdStarted])
        cues.runChanged(to: nil)
        #expect(cues.armedCues.isEmpty)
    }

    /// The background holds the current timer's end, follows the run, is not re-sent for an unchanged
    /// run, and is cancelled when the run ends.
    @Test func backgroundFollowsTheRun() async throws {
        let background = BackgroundRecorder()
        let cues = director(CueRecorder(), background)
        let plank = Self.run([Self.hold("Plank", seconds: 30, block: "activation")], at: Date())
        let window = try #require(plank.holdWindow)
        cues.runChanged(to: plank)
        cues.runChanged(to: plank)
        await cues.backgroundSettled()
        #expect(background.schedules == [BackgroundRecorder.Schedule(
            cues: [NotificationService.WorkoutCue(kind: .holdEnded, fireAt: window.upperBound)],
            sound: GuidedRunCuePlan.silentNotificationSound)])

        cues.runChanged(to: nil)
        await cues.backgroundSettled()
        #expect(background.schedules.last == BackgroundRecorder.Schedule(cues: [], sound: GuidedRunCuePlan.silentNotificationSound))
    }

    /// The store tells its director about every change of the run — here a run adopted from the app
    /// group (as after a Lock Screen move) and then cleared.
    @Test func storeReportsEveryRunChange() async {
        let directory = uniqueAppGroupDirectory()
        let store = makeTestStore(appGroupDirectory: directory)
        let background = BackgroundRecorder()
        let cues = director(CueRecorder(), background, active: false)
        store.guidedRunCues = cues

        let plank = Self.run([Self.hold("Plank", seconds: 30, sets: 2, rest: 30, block: "activation")], at: Date())
        #expect(GuidedWorkoutRunStateStore(directory: directory).write(plank))
        store.reconcileGuidedRunFromAppGroup()
        #expect(cues.armedCues.map(\.event) == [.holdStarted, .holdEnded])
        await cues.backgroundSettled()
        #expect(background.schedules.last?.cues.map(\.kind) == [.holdEnded])

        store.clearGuidedRun()
        #expect(cues.armedCues.isEmpty)
        await cues.backgroundSettled()
        #expect(background.schedules.last?.cues == [])
    }

    // MARK: VoiceOver at the hold's start

    /// The lead-in's end is spoken once, at the moment — never for a hold already running when the
    /// runner reopens, nor after the app slept through it — and its words are its own, not the rest's.
    @Test func holdStartIsSpokenOnlyOnTime() throws {
        let leadInEnd = Self.start
        let line = try #require(GuidedRunAnnouncement.holdStarted(leadInEndedAt: leadInEnd, now: leadInEnd.addingTimeInterval(0.2)))
        #expect(String(localized: line) == String(localized: GuidedRunAnnouncement.holdStartedLine))
        #expect(String(localized: line) != String(localized: GuidedRunAnnouncement.restOver))
        let late = leadInEnd.addingTimeInterval(GuidedRunCuePlan.lateTolerance + 5)
        #expect(GuidedRunAnnouncement.holdStarted(leadInEndedAt: leadInEnd, now: late) == nil)
    }

    // MARK: The background notification

    /// A workout cue says only that a timer ended, at the default interruption level, carrying the
    /// sound it was given; its identifiers are frozen and recognisable, and nothing else matches them.
    @Test func cueNotificationShape() {
        let rest = NotificationService.workoutCueContent(for: .restEnded, soundFileName: FernletSound.chime.fileName, addressing: .masculine)
        let hold = NotificationService.workoutCueContent(for: .holdEnded, soundFileName: nil, addressing: .masculine)
        #expect(!rest.title.isEmpty && !rest.body.isEmpty && !hold.title.isEmpty && !hold.body.isEmpty)
        #expect(rest.title != hold.title)
        #expect(rest.sound != nil && hold.sound == nil)
        #expect(rest.interruptionLevel == .active)
        #expect(NotificationService.workoutCueID(for: .restEnded) == "fernlet.workoutCue.restEnded")
        #expect(NotificationService.workoutCueID(for: .holdEnded) == "fernlet.workoutCue.holdEnded")
        for kind in NotificationService.WorkoutCueKind.allCases {
            #expect(NotificationService.isWorkoutCue(NotificationService.workoutCueID(for: kind)))
        }
        #expect(!NotificationService.isWorkoutCue(NotificationService.dailyCheckInID))
        #expect(!NotificationService.isWorkoutCue(NotificationService.sessionMessageID))
    }
}
