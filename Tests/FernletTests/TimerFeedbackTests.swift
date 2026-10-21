// TimerFeedbackTests.swift
// FernletTests
//
// The sounds-and-haptics Tier B and C pass on Fernlet's two timers (2026-10-20,
// `Docs/Handoff/Sounds-Haptics-Investigation.md` §4 B7, C1, C4): "time's up" as one Core Haptics
// pattern with a two-impact fallback, the cooking timer's own sound switch, the runner's weight,
// effort and rest-chip ticks, and the cooking walker's Next / Back / Finish. Everything goes through
// the player's injected `perform` seam, because neither UIKit nor Core Haptics reports back what it
// played (and a simulator plays no haptics at all).
//
// Every switch read here goes to a private `UserDefaults` suite: the real keys are process-global
// disk state shared by every suite running in parallel.

import Foundation
import Testing
import FernletUI
@testable import Fernlet

/// Records what a ``FernletFeedback`` was asked to play.
@MainActor
private final class TimerPlayedLog {
    /// Every cue that reached the player, in order.
    var played: [FernletFeedbackCue] = []
    /// ONE player for the log's life.
    lazy var feedback = FernletFeedback(perform: { [unowned self] in played.append($0) })
}

@MainActor
@Suite struct TimerFeedbackTests {

    /// A fresh, private defaults suite holding `level` (or nothing).
    private func defaults(level: String? = nil) throws -> UserDefaults {
        let suite = try #require(UserDefaults(suiteName: "TimerFeedbackTests.\(UUID().uuidString)"))
        if let level { suite.set(level, forKey: FernletHapticsLevel.storageKey) }
        return suite
    }

    // MARK: C4 — "time's up" through Core Haptics

    /// The renderer changed underneath; the callers didn't. Each timer ending is still ONE cue whose
    /// haptic is `.attention` — the pattern's three taps (or the fallback's two impacts) live below
    /// the seam — and the app-wide Off plays nothing at all.
    @Test func timesUpStillPlaysOnceAndOffPlaysNothing() throws {
        let log = TimerPlayedLog()
        let on = FernletFeedbackPreferences.resolved(in: try defaults(level: "all"))
        for event in [FernletFeedbackEvent.restEnded, .holdEnded, .timerEnded] {
            log.feedback.play(event, preferences: on)
        }
        #expect(log.played.map(\.event) == [.restEnded, .holdEnded, .timerEnded])
        #expect(log.played.map(\.haptic) == [.attention, .attention, .attention])

        let off = TimerPlayedLog()
        let offPreferences = FernletFeedbackPreferences.resolved(in: try defaults(level: "off"))
        for event in [FernletFeedbackEvent.restEnded, .holdEnded, .timerEnded] {
            off.feedback.play(event, preferences: offPreferences)
        }
        #expect(off.played.isEmpty, "Apple documents nothing about Core Haptics and the system switch; Fernlet's Off must hold")

        let fewer = FernletFeedbackPreferences.resolved(in: try defaults(level: "fewer"))
        #expect(FernletFeedbackCue(event: .timerEnded, preferences: fewer)?.haptic == .attention,
                "a timer the person set is a session moment: it stays at Fewer")
    }

    /// Short, transient and rising: a knock, never a buzz (the HIG's "prefer short haptics that
    /// complement discrete events"), under the report's ~400 ms.
    @Test func theAttentionPatternIsAShortRisingKnock() {
        let taps = FernletFeedback.attentionPattern
        #expect((2...3).contains(taps.count))
        #expect(taps.first?.time == 0)
        #expect((taps.last?.time ?? 1) < 0.4)
        for (earlier, later) in zip(taps, taps.dropFirst()) {
            #expect(later.time > earlier.time, "taps out of order")
            #expect(later.intensity > earlier.intensity, "soft to firm: each tap stronger than the last")
            #expect(later.sharpness >= earlier.sharpness, "soft to firm: never rounder than the last")
        }
        #expect(taps.allSatisfy { (0...1).contains($0.intensity) && (0...1).contains($0.sharpness) })
        // The fallback is the pair the pattern replaced, unchanged.
        #expect(FernletFeedback.attentionIntensity == 0.8)
        #expect(FernletFeedback.attentionGap == .milliseconds(150))
    }

    /// Core Haptics only where it plays: never without haptic hardware (every simulator), never in an
    /// app extension. Anywhere else, the two impacts.
    @Test func attentionFallsBackWhereCoreHapticsCannotPlay() {
        #expect(FernletAttentionRenderer.choose(supportsHaptics: true, inAppExtension: false) == .coreHaptics)
        #expect(FernletAttentionRenderer.choose(supportsHaptics: false, inAppExtension: false) == .impacts)
        #expect(FernletAttentionRenderer.choose(supportsHaptics: true, inAppExtension: true) == .impacts)
        #expect(FernletAttentionRenderer.choose(supportsHaptics: false, inAppExtension: true) == .impacts)
    }

    // MARK: C1 — the cooking timer's sound switch

    /// Off until the person turns it on; on, the timer's ending carries the runner's chime. The key is
    /// a frozen persisted token.
    @Test func theCookingTimerSoundIsOffUntilTurnedOn() throws {
        #expect(CookingCuePreferences.soundsKey == "fernlet.cookingCues.sounds", "a FROZEN persisted key")
        let suite = try defaults(level: "all")
        #expect(!CookingCuePreferences.soundsEnabled(in: suite))
        let quiet = try #require(FernletFeedbackCue(event: .timerEnded, preferences: CookingCuePreferences.current(in: suite)))
        #expect(quiet.haptic == .attention && quiet.sound == nil)

        suite.set(true, forKey: CookingCuePreferences.soundsKey)
        let chiming = try #require(FernletFeedbackCue(event: .timerEnded, preferences: CookingCuePreferences.current(in: suite)))
        #expect(chiming.haptic == .attention && chiming.sound == .chime)
    }

    /// The switch goes through the one resolver, ANDed with the app-wide level: Off silences the
    /// timer's tap, and the chime keeps its own switch (the level governs haptics, as it does for the
    /// workout's sounds).
    @Test func theCookingTimerResolvesUnderTheAppWideLevel() throws {
        let suite = try defaults(level: "off")
        #expect(CookingCuePreferences.current(in: suite).isSilent)
        suite.set(true, forKey: CookingCuePreferences.soundsKey)
        let cue = try #require(FernletFeedbackCue(event: .timerEnded, preferences: CookingCuePreferences.current(in: suite)))
        #expect(cue.haptic == nil && cue.sound == .chime)
    }

    // MARK: B7 — the runner's touch cues

    /// A −/+ tap ticks only when the weight really changed, and bumps at the one-step floor, where
    /// the store's snap holds "Lighter" at one step.
    @Test func aWeightStepTicksOnlyWhenTheWeightChanged() {
        #expect(GuidedTouchCue.weightStep(before: 100, after: 105) == .tick)
        #expect(GuidedTouchCue.weightStep(before: nil, after: 45) == .tick, "the first pick from Not set")
        #expect(GuidedTouchCue.weightStep(before: 105, after: 105) == .limit)
        #expect(GuidedTouchCue.weightStep(before: nil, after: nil) == .limit)

        let atFloor = GuidedWorkoutRunState.Tracking(
            targetReps: 8, rangeLow: nil, rangeHigh: nil, suggested: 5, step: 5, unitRaw: "lb",
            equipmentRaw: "dumbbell", confidenceRaw: nil, askReasonOnOverride: false, calibrationRaw: nil,
            easierSession: false, compoundsBefore: 0, selected: 5
        )
        let lighter = atFloor.steppedWeight(direction: -1, start: 10).flatMap { atFloor.snapped($0) }
        #expect(GuidedTouchCue.weightStep(before: atFloor.selected, after: lighter) == .limit,
                "Lighter at the floor changes nothing, and must not feel like it did")
        let heavier = atFloor.steppedWeight(direction: 1, start: 10).flatMap { atFloor.snapped($0) }
        #expect(GuidedTouchCue.weightStep(before: atFloor.selected, after: heavier) == .tick)
    }

    /// A rest chip ticks when the rest moved and bumps at its bounds; every runner touch answers to
    /// Workout haptics and drops at Fewer.
    @Test func restChipsTickAndTheRunnersTouchesAnswerToItsSwitches() throws {
        #expect(GuidedTouchCue.restAdjust(moved: true) == .tick)
        #expect(GuidedTouchCue.restAdjust(moved: false) == .limit)

        let all = try defaults(level: "all")
        #expect(FernletFeedbackCue(event: .tick, preferences: WorkoutCuePreferences.current(in: all))?.haptic == .selection)
        #expect(FernletFeedbackCue(event: .limit, preferences: WorkoutCuePreferences.current(in: all))?.haptic == .rigidLimit)
        let fewer = try defaults(level: "fewer")
        #expect(FernletFeedbackCue(event: .tick, preferences: WorkoutCuePreferences.current(in: fewer)) == nil)
        all.set(false, forKey: WorkoutCuePreferences.hapticsKey)
        #expect(FernletFeedbackCue(event: .tick, preferences: WorkoutCuePreferences.current(in: all)) == nil,
                "Workout haptics off silences the runner's ticks too")
        all.set(true, forKey: WorkoutCuePreferences.soundsKey)
        #expect(FernletFeedbackCue(event: .tick, preferences: WorkoutCuePreferences.current(in: all)) == nil,
                "a tick never sounds, whatever Workout sounds says")
    }

    // MARK: The cooking walker

    private func run(stepIndex: Int = 0, finished: Bool = false) -> CookingRunState {
        CookingRunState(
            recipeID: UUID(uuidString: "00000000-0000-0000-0000-0000000C0F01")!,
            recipeName: "Weeknight ragù",
            startedDayKey: "2026-10-20",
            steps: [CookingRunState.Step(text: "Chop"), CookingRunState.Step(text: "Simmer", durationSeconds: 600),
                    CookingRunState.Step(text: "Serve")],
            stepIndex: stepIndex,
            finished: finished
        )
    }

    /// Next and Back tick; Finish plays one `done` as "All done." appears; a tap that changed nothing
    /// (a second Finish while the screen crossfades) plays nothing.
    @Test func theWalkerTicksAndFinishPlaysDoneOnce() {
        var next = run(stepIndex: 0)
        next.advance()
        #expect(CookingModeView.walkerCue(before: run(stepIndex: 0), after: next) == .tick)

        var back = run(stepIndex: 2)
        back.goBack()
        #expect(CookingModeView.walkerCue(before: run(stepIndex: 2), after: back) == .tick)
        #expect(CookingModeView.walkerCue(before: run(stepIndex: 0), after: nil) == .tick,
                "Back from the first step leaves the walk for mise en place")

        var finish = run(stepIndex: 2)
        finish.advance()
        #expect(finish.isFinished)
        #expect(CookingModeView.walkerCue(before: run(stepIndex: 2), after: finish) == .done)
        #expect(CookingModeView.walkerCue(before: finish, after: finish) == nil, "done plays once per cook")
        #expect(CookingModeView.walkerCue(before: nil, after: next) == nil)
        #expect(FernletFeedbackEvent.tick.scope == .touch && FernletFeedbackEvent.done.scope == .outcome,
                "Fewer drops the page-turn ticks and keeps the finish")
    }
}
