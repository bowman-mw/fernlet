// FernletFeedbackTests.swift
// FernletTests
//
// The app-wide sounds-and-haptics pass (2026-10-20, `Docs/Handoff/Sounds-Haptics-Investigation.md`
// §3.9): FernletUI's vocabulary, the app-wide Haptics level and its one resolver, pacing, and the
// app's call sites that decide WHICH event plays — all through the player's injected `perform` seam,
// because UIKit never reports back what it played. The runner's own cue rules stay in
// `GuidedRunCueTests` (a rest that wakes 30 s late plays nothing: `dueCuePlaysOnceAndAStaleOneIsDropped`;
// "Skip to next exercise" cues at most once: `skipToNextExerciseCuesAtMostOnce`), and the grep-wall
// that keeps every cue behind the seam is `FeedbackBoundaryTests`.
//
// Every level read here goes to a private `UserDefaults` suite: the real key is process-global disk
// state shared by every suite running in parallel.

import Foundation
import Testing
import UserNotifications
import FernletUI
@testable import AppServices
@testable import Fernlet

/// Records what a ``FernletFeedback`` was asked to play, on a clock the test steps by hand.
@MainActor
private final class PlayedLog {
    /// Every cue that reached the player, in order.
    var played: [FernletFeedbackCue] = []
    /// The player's clock.
    var now = ContinuousClock.now
    /// ONE player for the log's life, so its pacer remembers across plays.
    lazy var feedback = FernletFeedback(perform: { [unowned self] in played.append($0) }, now: { [unowned self] in now })

    var events: [FernletFeedbackEvent] { played.map(\.event) }
    var haptics: [FernletHaptic?] { played.map(\.haptic) }
}

@MainActor
@Suite struct FernletFeedbackTests {

    /// A fresh, private defaults suite holding `level` (or nothing).
    private func defaults(level: String? = nil) throws -> UserDefaults {
        let suite = try #require(UserDefaults(suiteName: "FernletFeedbackTests.\(UUID().uuidString)"))
        if let level { suite.set(level, forKey: FernletHapticsLevel.storageKey) }
        return suite
    }

    // MARK: The vocabulary

    /// The scopes are the table the "Fewer" level reads: touches are the small taps under the thumb.
    @Test func everyEventHasAScopeAndTheTouchesAreTheSmallTaps() {
        let touches = Set(FernletFeedbackEvent.allCases.filter { $0.scope == .touch })
        #expect(touches == [.setLogged, .tick, .logged, .limit, .moved, .held])
        let outcomes = Set(FernletFeedbackEvent.allCases.filter { $0.scope == .outcome })
        #expect(outcomes == [.captured, .done, .caveat, .failed, .friendHere])
        // The report's feels for the app-wide events (§3.3), and "time's up" is one feel everywhere.
        #expect(FernletFeedbackEvent.tick.haptic == .selection)
        #expect(FernletFeedbackEvent.limit.haptic == .rigidLimit)
        #expect(FernletFeedbackEvent.done.haptic == .success)
        #expect(FernletFeedbackEvent.caveat.haptic == .warning)
        #expect(FernletFeedbackEvent.failed.haptic == .error)
        #expect(FernletFeedbackEvent.timerEnded.haptic == FernletFeedbackEvent.restEnded.haptic)
        #expect(FernletFeedbackEvent.captured.haptic != .success, "a code caught is not yet a result")
        #expect(FernletFeedbackEvent.messageIn.haptic != .success, "a message arriving is not a task that succeeded")
        #expect(FernletHaptic.attention != .warning, "app-wide, .warning means only a caveat")
    }

    /// Sound can be heard by the room; a haptic can't. No touch or outcome — which covers every error
    /// on a private surface — can ever carry one, whatever a caller passes.
    @Test func onlySessionMomentsCarryASound() throws {
        for event in FernletFeedbackEvent.allCases where event.sound != nil {
            #expect(event.scope == .session, "\(event) carries a sound outside a session")
        }
        let soundsOn = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: true)
        for event in [FernletFeedbackEvent.failed, .done, .caveat, .logged, .tick, .captured, .friendHere,
                      .pace, .messageIn, .windDetent, .wound, .shutter] {
            let cue = try #require(FernletFeedbackCue(event: event, preferences: soundsOn))
            #expect(cue.sound == nil, "\(event) would sound")
        }
    }

    // MARK: The app-wide level

    /// Haptics Off plays nothing — and an event with a sound still plays only its sound.
    @Test func hapticsOffPlaysNothing() throws {
        let log = PlayedLog()
        let off = FernletFeedbackPreferences.resolved(in: try defaults(level: "off"))
        for event in FernletFeedbackEvent.allCases { log.feedback.play(event, preferences: off) }
        #expect(log.played.isEmpty)

        let offWithSounds = FernletFeedbackPreferences.resolved(sounds: true, in: try defaults(level: "off"))
        let rest = try #require(FernletFeedbackCue(event: .restEnded, preferences: offWithSounds))
        #expect(rest.haptic == nil && rest.sound == .chime, "the level governs haptics, not a surface's sounds")
        #expect(!offWithSounds.isSilent)
        #expect(FernletFeedbackPreferences.resolved(in: try defaults(level: "off")).isSilent)
    }

    /// Fewer drops the small taps and keeps results and timers.
    @Test func fewerDropsTickAndKeepsFailed() throws {
        let log = PlayedLog()
        let fewer = FernletFeedbackPreferences.resolved(in: try defaults(level: "fewer"))
        for event in [FernletFeedbackEvent.tick, .logged, .limit, .setLogged, .failed, .done, .restEnded, .pace] {
            log.feedback.play(event, preferences: fewer)
        }
        #expect(log.events == [.failed, .done, .restEnded, .pace])
        #expect(log.haptics == [.error, .success, .attention, .softPulse])
    }

    /// The one resolver ANDs the surface's switch with the level; an unset or unknown level is All.
    @Test func resolverAndsTheSurfaceSwitchWithTheLevel() throws {
        #expect(FernletHapticsLevel.current(in: try defaults()) == .all)
        #expect(FernletHapticsLevel.current(in: try defaults(level: "fewer")) == .fewer)
        #expect(FernletHapticsLevel.current(in: try defaults(level: "sometimes")) == .all)
        #expect(FernletHapticsLevel.storageKey == "fernlet.feedback.haptics", "a FROZEN persisted key")
        #expect(FernletHapticsLevel.allCases.map(\.rawValue) == ["all", "fewer", "off"], "FROZEN persisted values")

        let off = FernletFeedbackPreferences.resolved(haptics: true, sounds: true, in: try defaults(level: "off"))
        #expect(!off.hapticsEnabled && off.soundsEnabled && off.hapticsLevel == .off)
        let surfaceOff = FernletFeedbackPreferences.resolved(haptics: false, in: try defaults(level: "all"))
        #expect(FernletFeedbackCue(event: .failed, preferences: surfaceOff) == nil)
    }

    /// Owner's decision 5: breathing keeps its switch, and a tap plays only when both allow it.
    @Test func aBreathingTapNeedsBothSwitches() throws {
        let log = PlayedLog()
        log.feedback.play(.pace, preferences: .resolved(haptics: false, in: try defaults(level: "all")))
        log.feedback.play(.pace, preferences: .resolved(haptics: true, in: try defaults(level: "off")))
        #expect(log.played.isEmpty)
        log.feedback.play(.pace, preferences: .resolved(haptics: true, in: try defaults(level: "fewer")))
        #expect(log.haptics == [.softPulse], "a breathing phase is a session moment: it stays at Fewer")
        #expect(BreathingPreferences.hapticsKey == "fernlet.breathing.haptics", "the existing key, unchanged")
    }

    // MARK: Pacing

    /// Peers set the pace of chat messages, so a burst plays once per ten seconds; a play the switches
    /// dropped doesn't use up the window.
    @Test func aBurstOfMessagesPlaysOncePerTenSeconds() throws {
        let log = PlayedLog()
        let on = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false)
        let off = FernletFeedbackPreferences(hapticsEnabled: false, soundsEnabled: false)
        log.feedback.play(.messageIn, preferences: off)
        log.feedback.play(.messageIn, preferences: on)
        log.now = log.now.advanced(by: .seconds(4))
        log.feedback.play(.messageIn, preferences: on)
        log.now = log.now.advanced(by: .seconds(6))
        log.feedback.play(.messageIn, preferences: on)
        #expect(log.events == [.messageIn, .messageIn], "dropped, played, held back, played again at 10 s")
        #expect(log.haptics == [.softKnock, .softKnock])

        let water = PlayedLog()
        water.feedback.play(.logged, preferences: on)
        water.now = water.now.advanced(by: .milliseconds(100))
        water.feedback.play(.logged, preferences: on)
        water.feedback.play(.failed, preferences: on)
        water.now = water.now.advanced(by: .milliseconds(100))
        water.feedback.play(.logged, preferences: on)
        #expect(water.events == [.logged, .failed, .logged], "one tap per 150 ms, never a buzz-roll; other events unpaced")
    }

    // MARK: Call sites

    /// A7: water +1 at the cap plays `limit`, not `logged`.
    @Test func waterAtTheCapPlaysLimitNotLogged() {
        #expect(HomeView.waterQuickAddEvent(before: 3, after: 4) == .logged)
        #expect(HomeView.waterQuickAddEvent(before: 30, after: 30) == .limit)
        let log = PlayedLog()
        log.feedback.play(HomeView.waterQuickAddEvent(before: 30, after: 30),
                          preferences: FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false))
        #expect(log.events == [.limit] && log.haptics == [.rigidLimit])
    }

    /// A15: the cooking timer uses the runner's lateness rule after its sleep, so a timer that wakes
    /// 30 s late — the app was suspended through it — plays nothing.
    @Test func aCookingTimerThatWakesLatePlaysNothing() {
        let end = Date(timeIntervalSince1970: 2_000_000)
        #expect(CookingModeView.signalsExpiry(endingAt: end, now: end.addingTimeInterval(0.4)))
        #expect(!CookingModeView.signalsExpiry(endingAt: end, now: end.addingTimeInterval(30)))
        #expect(FernletFeedbackEvent.timerEnded.scope == .session, "a timer the person set keeps playing at Fewer")
    }

    /// The runner plays under the app-wide level too, while Workout setup still edits the switches as
    /// the person set them.
    @Test func theRunnerPlaysUnderTheAppWideLevel() throws {
        let suite = try defaults(level: "off")
        #expect(WorkoutCuePreferences.stored(in: suite).hapticsEnabled, "the setup sheet's draft is the raw switch")
        let playing = WorkoutCuePreferences.current(in: suite)
        #expect(!playing.hapticsEnabled)
        #expect(GuidedRunCuePlan.notificationSound(for: playing) == nil, "no buzzing background cue at Off")

        let fewer = WorkoutCuePreferences.current(in: try defaults(level: "fewer"))
        #expect(FernletFeedbackCue(event: .restEnded, preferences: fewer)?.haptic == .attention)
        #expect(FernletFeedbackCue(event: .setLogged, preferences: fewer) == nil)
        #expect(GuidedRunCuePlan.notificationSound(for: fewer) == GuidedRunCuePlan.silentNotificationSound)
    }

    /// Owner's decision 6: the daily check-in arrives without sound, in the background and the
    /// foreground; the workout cue stays hidden in the foreground as before.
    @Test func dailyCheckInArrivesWithoutSound() {
        #expect(NotificationService.dailyCheckInContent().sound == nil)
        let checkIn = FernletNotificationDelegate.foregroundPresentation(for: NotificationService.dailyCheckInID)
        #expect(checkIn.contains(.banner) && !checkIn.contains(.sound))
        let cue = FernletNotificationDelegate.foregroundPresentation(
            for: NotificationService.workoutCueID(for: .restEnded))
        #expect(cue.isEmpty)
        #expect(FernletNotificationDelegate.foregroundPresentation(for: NotificationService.sessionMessageID)
                == [.banner, .sound])
    }

    // MARK: Lock, passcode and duress (source pins: these flows have no player seam of their own)

    /// The body of the top-level type that `declaration` opens, up to its closing brace at column 0.
    private func body(of declaration: String, in path: String) throws -> String {
        let source = try RepoRoot.source(path)
        let start = try #require(source.range(of: declaration), "\(declaration) moved out of \(path)")
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// A12: passcode setup, change-passcode and duress-code setup feel identical, one-to-one — the same
    /// `fail` helper for every error and exactly one `done` on success — because a duress code is set up
    /// exactly as a passcode is changed, and the two must be indistinguishable.
    @Test func lockSetupChangeAndDuressFeelIdentical() throws {
        let fail = """
            private func fail(_ message: String) {
                    errorMessage = message
                    FernletFeedback.system.play(.failed)
                }
            """
        let flows = [
            try body(of: "public struct FernletLockSetupView: View {", in: "FernletKit/Sources/FernletLockUI/FernletLockView.swift"),
            try body(of: "private struct FernletLockChangePasscodeView: View {", in: "App/Fernlet/SettingsSheet.swift"),
            try body(of: "private struct DuressPINEntrySheet: View {", in: "App/Fernlet/DuressPINSetupView.swift"),
        ]
        let rawError = try Regex(#"errorMessage = (?!nil\b|message\b)"#)
        for flow in flows {
            #expect(flow.contains(fail), "a lock flow lost the shared `fail` helper")
            #expect(flow.components(separatedBy: "FernletFeedback.system.play(.done)").count == 2,
                    "a lock flow plays `done` other than exactly once")
            #expect(flow.components(separatedBy: "FernletFeedback.system.play(").count == 3,
                    "a lock flow plays a cue the other two don't")
            #expect(flow.firstMatch(of: rawError) == nil, "a lock flow sets an error without its haptic")
        }
    }

    /// The unlock screen plays one thing — `failed` as an error ARRIVES — and nothing on success, so
    /// a duress unlock plays exactly what a real unlock plays: nothing is keyed on which code matched.
    @Test func aDuressUnlockPlaysExactlyWhatARealUnlockPlays() throws {
        let unlock = try body(of: "public struct FernletLockView: View {", in: "FernletKit/Sources/FernletLockUI/FernletLockView.swift")
        #expect(unlock.contains(".fernletFeedback(.failed, trigger: errorMessage) { _, message in message != nil }"))
        #expect(unlock.components(separatedBy: "ernletFeedback").count == 2, "the unlock screen gained a second cue")
        #expect(!unlock.contains("FernletFeedback.system.play("), "an imperative cue on the unlock screen")
    }

    /// The companion has no haptic yet (report B5, not built): a calm-idle pet plays nothing, and the
    /// petting governor's settled period is never rewarded.
    @Test func aCalmCompanionPlaysNothing() throws {
        let source = try RepoRoot.source("App/Fernlet/HomeView.swift")
        let start = try #require(source.range(of: "private func interactWithCompanion() {"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let pet = source[start.lowerBound..<end.upperBound]
        #expect(!pet.contains("FernletFeedback") && !pet.contains("fernletFeedback"))
    }
}
