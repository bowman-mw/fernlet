// HeartRateZoneTests.swift
// FernletTests
//
// Pins comparison report idea 9 (roadmap step 4b, 2026-10-20): a heart-rate-zone cue for guided cardio on
// the runner and the Live Activity. Covered here: the zone math (Tanaka's maximum, Karvonen's reserve with a
// trusted resting rate, percent of maximum without one), each pace's target zone and the run state's mirror
// of it, where a reading sits and the words for it, the silent talk-test fallback with no fresh reading,
// the nudge's throttling, the Live Activity content and its tolerant decoding, the zone director over a
// fake live heart-rate source (start, stop, stale, failure, the nudge, the Live Activity refresh), the
// store driving it through a run, and the device-local switches.
//
// What no test here can check is owed on a device: live heart rate from an Apple Watch, AirPods Pro 3 and a
// BLE strap reaching an iPhone-only session; iOS's one-time workout-session notice; no second workout in
// Health after a run; the readout on a locked phone's Live Activity; and the nudge's feel.

import Foundation
import HealthKit
import SwiftUI
import Testing
import FernletDomainModel
import FernletUI
import HealthKitGateway
@testable import Fernlet

/// A live heart-rate source that records what the director asked of it and lets a test deliver readings.
@MainActor
private final class FakeHeartRateSource: LiveHeartRateSource {
    var isAvailable = true
    /// Whether the next start succeeds.
    var startSucceeds = true
    private(set) var startedActivities: [WorkoutActivityType] = []
    private(set) var stopCount = 0
    private(set) var readRequests = 0
    private var onReading: (@MainActor (Int) -> Void)?
    private var onEnded: (@MainActor () -> Void)?

    func requestReadAccess() async -> Bool {
        readRequests += 1
        return true
    }

    func start(
        activity: WorkoutActivityType,
        onReading: @escaping @MainActor (Int) -> Void,
        onEnded: @escaping @MainActor () -> Void
    ) async -> Bool {
        startedActivities.append(activity)
        guard startSucceeds else { return false }
        self.onReading = onReading
        self.onEnded = onEnded
        return true
    }

    func stop() {
        stopCount += 1
        onReading = nil
        onEnded = nil
    }

    func retireRecoveredSession() async {}

    /// A reading from the sensor.
    func deliver(_ bpm: Int) {
        onReading?(bpm)
    }

    /// The session stops by itself.
    func fail() {
        let ended = onEnded
        onReading = nil
        onEnded = nil
        ended?()
    }
}

/// A clock a test moves by hand.
@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Whether the app is in front, flipped by hand.
@MainActor
private final class TestForeground {
    var isActive = true
}

/// Records the director's taps, its VoiceOver lines and its Live Activity refreshes.
@MainActor
private final class ZoneCueRecorder {
    var played: [FernletFeedbackCue] = []
    var spoken: [String] = []
    var published = 0

    var feedback: FernletFeedback { FernletFeedback { [self] in played.append($0) } }
    var announcer: FernletAnnouncer { FernletAnnouncer { [self] in spoken.append($0.message) } }
}

/// Serialized: one test stands up a real `FernletStore` and adopts a run, which reaches process-global
/// state (the `Activity<…>` registry behind the Live Activity bridge), as `GuidedWorkoutRunStoreTests`.
@MainActor
@Suite(.serialized) struct HeartRateZoneTests {

    // MARK: Fixtures

    private typealias Zone = WorkoutActivityAttributes.ContentState.Zone

    private nonisolated static let t0 = Date(timeIntervalSince1970: 5_000_000)
    private nonisolated static let intervalsLine = "Intervals - 8 × 1 min hard / 1 min easy"
    private nonisolated static let english = Locale(identifier: "en_US")

    /// One timed cardio part of `pace`.
    private static func segment(_ pace: String, seconds: Int = 60, round: Int? = 1, rounds: Int? = 8) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: "Intervals", sets: 1, reps: "", roleRaw: "accessory", fromCatalog: false, restSeconds: 0,
            holdSeconds: seconds, blockRaw: GuidedWorkoutRunState.BlockToken.cardio,
            segment: GuidedWorkoutRunState.Segment(paceRaw: pace, round: round, rounds: rounds, descriptor: intervalsLine)
        )
    }

    /// A rep-counted lift.
    private static func lift() -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(name: "Bench press", sets: 3, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: 90)
    }

    private static func run(_ exercises: [GuidedWorkoutRunState.Exercise], kind: String = "cardio", at origin: Date? = nil) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate", title: "Intervals",
            suggestionExercisesText: intervalsLine, suggestionNotes: "", sessionKindRaw: kind,
            exercises: exercises, setStartedAt: origin ?? t0
        )
    }

    /// A director over `source`, with both switches on, sharing allowed, the app in front and a 40-year-old's
    /// zones (maximum 180: zone 2 is 108–126, zone 4 is 144–162) unless told otherwise.
    private static func director(
        _ source: FakeHeartRateSource,
        clock: TestClock,
        recorder: ZoneCueRecorder,
        switches: WorkoutZonePreferences? = nil,
        sharing: Bool = true,
        foreground: TestForeground? = nil
    ) -> GuidedZoneDirector {
        let chosen = switches ?? WorkoutZonePreferences(liveHeartRate: true, zoneNudges: true)
        let front = foreground ?? TestForeground()
        return GuidedZoneDirector(
            source: source,
            switches: { chosen },
            sharingAllowed: { sharing },
            zones: { HeartRateZones(age: 40) },
            feedback: recorder.feedback,
            announcer: recorder.announcer,
            cuePreferences: { FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false) },
            isAppActive: { front.isActive },
            clock: { clock.now },
            publish: { recorder.published += 1 }
        )
    }

    private static func close(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 1e-9
    }

    // MARK: The zone math

    /// Tanaka: 208 − 0.7 × age, with the age clamped to 13…100.
    @Test func tanakaMaximumFromAge() {
        #expect(Self.close(HeartRateZones.tanakaMaximum(age: 40), 180))
        #expect(Self.close(HeartRateZones.tanakaMaximum(age: 20), 194))
        #expect(Self.close(HeartRateZones.tanakaMaximum(age: 5), HeartRateZones.tanakaMaximum(age: 13)))
        #expect(Self.close(HeartRateZones.tanakaMaximum(age: 120), HeartRateZones.tanakaMaximum(age: 100)))
        #expect(Self.close(HeartRateZones(age: 40).maximumHeartRate, 180))
    }

    /// No resting rate: five bands of 50–100 % of the maximum, in whole beats.
    @Test func zonesArePercentOfMaximumWithoutARestingRate() {
        let zones = HeartRateZones(age: 40)
        #expect(zones.method == .percentOfMaximum)
        #expect(zones.restingHeartRate == nil)
        let one = zones.range(zone: 1)
        let two = zones.range(zone: 2)
        let four = zones.range(zone: 4)
        let five = zones.range(zone: 5)
        #expect(one == 90...108)
        #expect(two == 108...126)
        #expect(four == 144...162)
        #expect(five == 162...180)
        #expect(zones.range(zone: 0) == nil)
        #expect(zones.range(zone: 6) == nil)
    }

    /// A trusted resting rate: Karvonen's heart-rate reserve, rest + p × (max − rest).
    @Test func zonesUseTheHeartRateReserveWithARestingRate() {
        let zones = HeartRateZones(age: 40, restingHeartRate: 60)
        #expect(zones.method == .heartRateReserve)
        #expect(zones.restingHeartRate == 60)
        let two = zones.range(zone: 2)
        let four = zones.range(zone: 4)
        #expect(two == 132...144)
        #expect(four == 156...168)
    }

    /// A resting rate no heart has at rest is not trusted: the zones fall back to percent of maximum.
    @Test func anUntrustedRestingRateFallsBackToPercentOfMaximum() {
        #expect(HeartRateZones(age: 40, restingHeartRate: 25).method == .percentOfMaximum)
        #expect(HeartRateZones(age: 40, restingHeartRate: 120).method == .percentOfMaximum)
        #expect(HeartRateZones(age: 40, restingHeartRate: .nan).method == .percentOfMaximum)
        #expect(HeartRateZones(age: 40, restingHeartRate: 25) == HeartRateZones(age: 40))
    }

    // MARK: Paces and targets

    /// Easy and steady aim for zone 2, hard for zone 4 — and the run state's token mirror agrees.
    @Test func eachPaceAimsForItsZone() {
        #expect(HeartRateZones.targetZone(for: .easy) == 2)
        #expect(HeartRateZones.targetZone(for: .steady) == 2)
        #expect(HeartRateZones.targetZone(for: .hard) == 4)
        for pace in CardioPace.allCases {
            let mirrored = GuidedWorkoutRunState.targetZone(paceRaw: pace.rawValue)
            #expect(mirrored == HeartRateZones.targetZone(for: pace), "the run state's mirror of \(pace)")
        }
        #expect(GuidedWorkoutRunState.targetZone(paceRaw: "sprint") == HeartRateZones.steadyZone, "an unknown pace aims as steady")
        let zones = HeartRateZones(age: 40)
        #expect(zones.target(for: .hard) == zones.range(zone: 4))
        #expect(zones.target(for: .easy) == zones.range(zone: 2))
    }

    // MARK: Words

    /// Where a reading sits, always in words: under, inside (edges included) or over the range.
    @Test func whereAReadingSitsIsSaidInWords() {
        #expect(Zone.band(bpm: 109, range: 110...125) == .low)
        #expect(Zone.band(bpm: 110, range: 110...125) == .inRange)
        #expect(Zone.band(bpm: 125, range: 110...125) == .inRange)
        #expect(Zone.band(bpm: 126, range: 110...125) == .high)
        #expect(WorkoutActivityZoneText.bandWord(.inRange, locale: Self.english) == "in range")
        #expect(WorkoutActivityZoneText.bandWord(.high, locale: Self.english) == "a little high")
        #expect(WorkoutActivityZoneText.bandWord(.low, locale: Self.english) == "a little low")

        let live = Zone(target: 2, bpm: 118, low: 110, high: 125)
        #expect(live.isLive)
        #expect(WorkoutActivityZoneText.readout(live, locale: Self.english) == "118 bpm · aim 110–125")
        #expect(WorkoutActivityZoneText.line(live, locale: Self.english) == "118 bpm · aim 110–125 · in range")
        #expect(WorkoutActivityZoneText.spoken(live, locale: Self.english) == "Heart rate 118, aiming for 110 to 125, in range")
        let high = Zone(target: 2, bpm: 131, low: 110, high: 125)
        #expect(WorkoutActivityZoneText.line(high, locale: Self.english) == "131 bpm · aim 110–125 · a little high")
        let low = Zone(target: 4, bpm: 100, low: 110, high: 125)
        #expect(WorkoutActivityZoneText.spoken(low, locale: Self.english) == "Heart rate 100, aiming for 110 to 125, a little low")
    }

    /// No live reading: no number anywhere, and the talk test for the part's zone.
    @Test func withoutAReadingTheCueIsTheTalkTest() {
        let easy = Zone(target: 2)
        #expect(!easy.isLive)
        #expect(WorkoutActivityZoneText.readout(easy, locale: Self.english) == nil)
        #expect(WorkoutActivityZoneText.spoken(easy, locale: Self.english) == nil)
        #expect(WorkoutActivityZoneText.line(easy, locale: Self.english) == "Aim: talk in short sentences")
        #expect(WorkoutActivityZoneText.line(Zone(target: 4), locale: Self.english) == "Aim: a few words at a time")
        #expect(WorkoutActivityZoneText.line(Zone(), locale: Self.english) == nil)
        #expect(!Zone(target: 2, bpm: 118).isLive, "a reading with no range is not drawn")
        #expect(!Zone(target: 2, bpm: 118, low: 130, high: 120).isLive, "nor one with an inverted range")
        #expect(GuidedZoneWords.talkTest(target: 2) == Text("You should be able to talk in short sentences."))
        #expect(GuidedZoneWords.talkTest(target: 4) == Text("You should only manage a few words at a time."))
    }

    // MARK: The plan

    /// The runner's cue: the reading against the part's target while fresh, the talk test otherwise, and
    /// nothing off a cardio part or once the run is over.
    @Test func theCueFallsBackSilentlyWithoutAFreshReading() {
        let run = Self.run([Self.segment("hard")])
        let zones = HeartRateZones(age: 40)
        let fresh = GuidedZoneReading(bpm: 150, at: Self.t0)
        let none = GuidedZonePlan.zone(for: run, zones: zones, reading: nil, now: Self.t0)
        #expect(none == Zone(target: 4))
        let live = GuidedZonePlan.zone(for: run, zones: zones, reading: fresh, now: Self.t0.addingTimeInterval(10))
        #expect(live == Zone(target: 4, bpm: 150, low: 144, high: 162))
        let staleAt = Self.t0.addingTimeInterval(GuidedZonePlan.freshSeconds + 1)
        let stale = GuidedZonePlan.zone(for: run, zones: zones, reading: fresh, now: staleAt)
        #expect(stale == Zone(target: 4))
        let noZones = GuidedZonePlan.zone(for: run, zones: nil, reading: fresh, now: Self.t0)
        #expect(noZones == Zone(target: 4), "no zones, no number")
        let lifting = GuidedZonePlan.zone(for: Self.run([Self.lift()], kind: "strength"), zones: zones, reading: fresh, now: Self.t0)
        #expect(lifting == nil)
        var ended = run
        ended.end()
        #expect(GuidedZonePlan.zone(for: ended, zones: zones, reading: fresh, now: Self.t0) == nil)
    }

    /// A session is wanted only on a live cardio part, with the switch, a source and workout sharing — and
    /// sharing (a keychain read) is asked last.
    @Test func aSessionIsWantedOnlyOnCardioWithLeave() {
        let cardio = Self.run([Self.segment("steady", seconds: 1200, round: nil, rounds: nil)])
        var asked = 0
        let wanted = GuidedZonePlan.wantsSession(run: cardio, switchOn: true, sourceAvailable: true, sharingAllowed: { asked += 1; return true })
        #expect(wanted)
        #expect(asked == 1)
        let switchedOff = GuidedZonePlan.wantsSession(run: cardio, switchOn: false, sourceAvailable: true, sharingAllowed: { asked += 1; return true })
        #expect(!switchedOff)
        #expect(asked == 1, "sharing is not asked when the switch is off")
        let noSource = GuidedZonePlan.wantsSession(run: cardio, switchOn: true, sourceAvailable: false, sharingAllowed: { true })
        #expect(!noSource)
        let noSharing = GuidedZonePlan.wantsSession(run: cardio, switchOn: true, sourceAvailable: true, sharingAllowed: { false })
        #expect(!noSharing)
        let lifting = GuidedZonePlan.wantsSession(run: Self.run([Self.lift()], kind: "strength"), switchOn: true, sourceAvailable: true, sharingAllowed: { true })
        #expect(!lifting)
        let noRun = GuidedZonePlan.wantsSession(run: nil, switchOn: true, sourceAvailable: true, sharingAllowed: { true })
        #expect(!noRun)
    }


    // MARK: The nudge

    /// A nudge after 30 s of drift — counted only once the part has had 30 s to settle — once per drift,
    /// and never within a minute of the last.
    @Test func theNudgeIsThrottled() {
        var tracker = GuidedZoneNudgeTracker()
        tracker.retarget(at: Self.t0)
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(10)), "still settling")
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(31)), "the drift starts")
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(60)), "29 s of drift")
        #expect(tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(61)), "30 s of drift: one nudge")
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(80)), "once per drift")
        #expect(!tracker.observe(inRange: true, at: Self.t0.addingTimeInterval(81)), "back in range")
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(82)), "a new drift starts")
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(112)), "30 s of drift, 51 s since the last nudge")
        #expect(tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(121)), "a minute since the last nudge")
    }

    /// A lost reading restarts the drift; a new part settles before drift counts again.
    @Test func aLostReadingOrANewPartStartsTheDriftOver() {
        var tracker = GuidedZoneNudgeTracker()
        tracker.retarget(at: Self.t0)
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(31)))
        tracker.readingLost()
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(62)), "the drift starts over")
        #expect(tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(92)))
        tracker.retarget(at: Self.t0.addingTimeInterval(200))
        #expect(!tracker.observe(inRange: false, at: Self.t0.addingTimeInterval(210)), "a new part settles first")
    }

    // MARK: The director over a fake source

    /// A cardio part starts the session; a reading becomes the cue and refreshes the Live Activity.
    @Test func aCardioPartStartsTheSessionAndShowsTheReading() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let clock = TestClock(Self.t0)
        let director = Self.director(source, clock: clock, recorder: recorder)
        let run = Self.run([Self.segment("hard")])
        director.runChanged(to: run)
        await director.sessionStartSettled()
        #expect(director.isSessionRunning)
        #expect(source.startedActivities == [.hiit])
        #expect(director.zone(for: run) == Zone(target: 4), "the talk test until a reading arrives")

        source.deliver(150)
        let bpm = director.reading?.bpm
        #expect(bpm == 150)
        #expect(director.zone(for: run) == Zone(target: 4, bpm: 150, low: 144, high: 162))
        #expect(recorder.published == 1)
        #expect(recorder.played.isEmpty, "no nudge in range")
    }

    /// No session without the switch, without workout sharing, without a source, or off cardio.
    @Test func noSessionWithoutLeaveOrOffCardio() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let clock = TestClock(Self.t0)
        let cardio = Self.run([Self.segment("easy")])
        let off = Self.director(source, clock: clock, recorder: recorder,
                                switches: WorkoutZonePreferences(liveHeartRate: false, zoneNudges: true))
        off.runChanged(to: cardio)
        await off.sessionStartSettled()
        let unshared = Self.director(source, clock: clock, recorder: recorder, sharing: false)
        unshared.runChanged(to: cardio)
        await unshared.sessionStartSettled()
        let lifting = Self.director(source, clock: clock, recorder: recorder)
        lifting.runChanged(to: Self.run([Self.lift()], kind: "strength"))
        await lifting.sessionStartSettled()
        source.isAvailable = false
        let noHealth = Self.director(source, clock: clock, recorder: recorder)
        noHealth.runChanged(to: cardio)
        await noHealth.sessionStartSettled()
        #expect(source.startedActivities.isEmpty)
        #expect(off.zone(for: cardio) == Zone(target: 2), "the talk test still shows")
    }

    /// Leaving cardio ends the session and drops the reading; a reading after that is ignored.
    @Test func leavingCardioEndsTheSession() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let director = Self.director(source, clock: TestClock(Self.t0), recorder: recorder)
        let run = Self.run([Self.segment("hard"), Self.lift()], kind: "strength")
        director.runChanged(to: run)
        await director.sessionStartSettled()
        source.deliver(150)
        var lifting = run
        lifting.markSetDone(now: Self.t0.addingTimeInterval(60))
        director.runChanged(to: lifting)
        #expect(source.stopCount == 1)
        #expect(!director.isSessionRunning)
        #expect(director.reading == nil)
        director.receive(bpm: 155)
        #expect(director.reading == nil, "no session, no reading")
    }

    /// A stop that lands while the start is in flight still ends the session.
    @Test func aStopDuringAStartEndsTheSession() async {
        let source = FakeHeartRateSource()
        let director = Self.director(source, clock: TestClock(Self.t0), recorder: ZoneCueRecorder())
        director.runChanged(to: Self.run([Self.segment("hard")]))
        director.runChanged(to: nil)
        await director.sessionStartSettled()
        #expect(source.stopCount == 1)
        #expect(!director.isSessionRunning)
    }

    /// Nothing for 20 seconds: the reading is dropped and the cue is the talk test again, silently.
    @Test func aStaleReadingFallsBackToTheTalkTest() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let clock = TestClock(Self.t0)
        let director = Self.director(source, clock: clock, recorder: recorder)
        let run = Self.run([Self.segment("hard")])
        director.runChanged(to: run)
        await director.sessionStartSettled()
        source.deliver(150)
        clock.now = Self.t0.addingTimeInterval(10)
        director.expireStaleReading()
        #expect(director.reading != nil, "still fresh at 10 s")
        clock.now = Self.t0.addingTimeInterval(GuidedZonePlan.freshSeconds + 1)
        director.expireStaleReading()
        #expect(director.reading == nil)
        #expect(director.zone(for: run) == Zone(target: 4))
        #expect(recorder.published == 2, "the Live Activity drops the number too")
        #expect(recorder.spoken.isEmpty, "the fallback says nothing")
    }

    /// The Live Activity is refreshed for a new band at once, otherwise at most every five seconds.
    @Test func theLiveActivityRefreshIsThrottled() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let clock = TestClock(Self.t0)
        let director = Self.director(source, clock: clock, recorder: recorder)
        director.runChanged(to: Self.run([Self.segment("hard")]))
        await director.sessionStartSettled()
        source.deliver(150)
        clock.now = Self.t0.addingTimeInterval(1)
        source.deliver(151)
        #expect(recorder.published == 1, "same band within five seconds")
        clock.now = Self.t0.addingTimeInterval(6)
        source.deliver(152)
        #expect(recorder.published == 2)
        clock.now = Self.t0.addingTimeInterval(7)
        source.deliver(170)
        #expect(recorder.published == 3, "a new band shows at once")
    }

    /// With nudges on and the app in front, 30 s of drift after the settle plays one light tap and says it.
    @Test func aDriftNudgesOnceWhenAskedFor() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let clock = TestClock(Self.t0)
        let director = Self.director(source, clock: clock, recorder: recorder)
        director.runChanged(to: Self.run([Self.segment("steady", seconds: 1200, round: nil, rounds: nil)]))
        await director.sessionStartSettled()
        for offset in [31.0, 50, 61, 70] {
            clock.now = Self.t0.addingTimeInterval(offset)
            source.deliver(140)
        }
        let events = recorder.played.map(\.event)
        #expect(events == [.zoneDrift])
        let haptics = recorder.played.compactMap(\.haptic)
        #expect(haptics == [FernletHaptic.light])
        #expect(recorder.spoken == ["Heart rate a little high."])
    }

    /// Nudges off, or the app gone to the background mid-part: no tap and no line.
    @Test func noNudgeWhenSwitchedOffOrInTheBackground() async {
        let quiet = ZoneCueRecorder()
        let clock = TestClock(Self.t0)
        let front = TestForeground()
        let off = Self.director(FakeHeartRateSource(), clock: clock, recorder: quiet,
                                switches: WorkoutZonePreferences(liveHeartRate: true, zoneNudges: false))
        let away = Self.director(FakeHeartRateSource(), clock: clock, recorder: quiet, foreground: front)
        for director in [off, away] {
            clock.now = Self.t0
            front.isActive = true
            director.runChanged(to: Self.run([Self.segment("steady", seconds: 1200, round: nil, rounds: nil)]))
            await director.sessionStartSettled()
            #expect(director.isSessionRunning)
            front.isActive = false
            for offset in [31.0, 61] {
                clock.now = Self.t0.addingTimeInterval(offset)
                director.receive(bpm: 90)
            }
        }
        #expect(quiet.played.isEmpty)
        #expect(quiet.spoken.isEmpty)
    }

    /// A run seen with the app in the background (a Lock Screen tap woke it) starts no session — and is
    /// not counted as failed: the next change seen in front starts it.
    @Test func aSessionStartsOnlyWithTheAppInFront() async {
        let source = FakeHeartRateSource()
        let front = TestForeground()
        front.isActive = false
        let director = Self.director(source, clock: TestClock(Self.t0), recorder: ZoneCueRecorder(), foreground: front)
        let run = Self.run([Self.segment("hard")])
        director.runChanged(to: run)
        await director.sessionStartSettled()
        #expect(source.startedActivities.isEmpty)
        front.isActive = true
        director.runChanged(to: run)
        await director.sessionStartSettled()
        #expect(source.startedActivities.count == 1)
        #expect(director.isSessionRunning)
    }

    /// A session that stops by itself, or never starts, is not retried in that run.
    @Test func aFailedSessionIsNotRetriedInThatRun() async {
        let source = FakeHeartRateSource()
        let recorder = ZoneCueRecorder()
        let director = Self.director(source, clock: TestClock(Self.t0), recorder: recorder)
        let run = Self.run([Self.segment("hard"), Self.segment("easy")])
        director.runChanged(to: run)
        await director.sessionStartSettled()
        source.fail()
        #expect(!director.isSessionRunning)
        var next = run
        next.markSetDone(now: Self.t0.addingTimeInterval(65))
        director.runChanged(to: next)
        await director.sessionStartSettled()
        #expect(source.startedActivities.count == 1)

        let refused = FakeHeartRateSource()
        refused.startSucceeds = false
        let second = Self.director(refused, clock: TestClock(Self.t0), recorder: recorder)
        second.runChanged(to: run)
        await second.sessionStartSettled()
        second.runChanged(to: next)
        await second.sessionStartSettled()
        #expect(refused.startedActivities.count == 1)
        #expect(!second.isSessionRunning)
    }

    /// Health is asked for heart-rate access only while workout sharing is on.
    @Test func readAccessIsAskedOnlyWithSharing() async {
        let shared = FakeHeartRateSource()
        await Self.director(shared, clock: TestClock(Self.t0), recorder: ZoneCueRecorder()).requestReadAccess()
        #expect(shared.readRequests == 1)
        let unshared = FakeHeartRateSource()
        await Self.director(unshared, clock: TestClock(Self.t0), recorder: ZoneCueRecorder(), sharing: false).requestReadAccess()
        #expect(unshared.readRequests == 0)
    }

    /// The store tells the director about the run — adopted from the app group, then cleared — and a test
    /// store, with no Health, never shares workouts.
    @Test func theStoreDrivesTheDirectorThroughTheRun() async {
        let directory = uniqueAppGroupDirectory()
        let store = makeTestStore(appGroupDirectory: directory)
        #expect(!store.isWorkoutHealthSharingEnabled)
        let source = FakeHeartRateSource()
        store.guidedZones = Self.director(source, clock: TestClock(Date()), recorder: ZoneCueRecorder())
        let cardio = Self.run([Self.segment("hard")], at: Date())
        #expect(GuidedWorkoutRunStateStore(directory: directory).write(cardio))
        store.reconcileGuidedRunFromAppGroup()
        await store.guidedZones.sessionStartSettled()
        #expect(source.startedActivities == [.hiit])
        #expect(store.guidedZones.isSessionRunning)
        store.clearGuidedRun()
        #expect(source.stopCount == 1)
        #expect(!store.guidedZones.isSessionRunning)
    }

    // MARK: The Live Activity

    /// A cardio part's content carries its target; a lift's carries none; the live reading round-trips; and
    /// a payload from before zones, or with a zone missing a field, still decodes.
    @Test func theZoneRidesTheContentStateAndOlderPayloadsDecode() throws {
        let content = Self.run([Self.segment("hard")]).contentState
        #expect(content.zone == Zone(target: 4))
        #expect(Self.run([Self.lift()], kind: "strength").contentState.zone == nil)

        var live = content
        live.zone = Zone(target: 4, bpm: 150, low: 144, high: 162)
        let data = try JSONEncoder().encode(live)
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: data)
        #expect(decoded == live)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var zoneObject = try #require(object["zone"] as? [String: Any])
        zoneObject["bpm"] = nil
        object["zone"] = zoneObject
        let thinned = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                                               from: try JSONSerialization.data(withJSONObject: object))
        let thinnedZone = try #require(thinned.zone)
        #expect(thinnedZone.target == 4)
        #expect(!thinnedZone.isLive)

        object["zone"] = nil
        let older = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self,
                                             from: try JSONSerialization.data(withJSONObject: object))
        #expect(older.zone == nil)
        #expect(older.paceRaw == "hard")
    }

    // MARK: Switches, cue and sensor reading

    /// Both switches are off until turned on, live on this device only, under frozen keys.
    @Test func theZoneSwitchesAreOffUntilTurnedOn() throws {
        let suite = "fernlet.tests.zones.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WorkoutZonePreferences.current(in: defaults) == WorkoutZonePreferences.defaultSwitches)
        #expect(!WorkoutZonePreferences.defaultSwitches.liveHeartRate)
        #expect(!WorkoutZonePreferences.defaultSwitches.zoneNudges)
        let on = WorkoutZonePreferences(liveHeartRate: true, zoneNudges: true)
        WorkoutZonePreferences.save(on, in: defaults)
        #expect(WorkoutZonePreferences.current(in: defaults) == on)
        #expect(WorkoutZonePreferences.liveHeartRateKey == "fernlet.workoutCues.liveHeartRate")
        #expect(WorkoutZonePreferences.zoneNudgesKey == "fernlet.workoutCues.zoneNudges")
    }

    /// The nudge is a light tap and never a sound.
    @Test func aZoneNudgeIsALightSilentTap() {
        #expect(FernletFeedbackEvent.zoneDrift.haptic == .light)
        #expect(FernletFeedbackEvent.zoneDrift.sound == nil)
    }

    /// The HealthKit source reads whole beats per minute and drops a value no heart makes.
    @Test func theSourceReadsWholeBeatsPerMinute() {
        let unit = HKUnit.count().unitDivided(by: .minute())
        #expect(HealthKitLiveHeartRateSource.beatsPerMinute(HKQuantity(unit: unit, doubleValue: 118.4)) == 118)
        #expect(HealthKitLiveHeartRateSource.beatsPerMinute(HKQuantity(unit: unit, doubleValue: 118.6)) == 119)
        #expect(HealthKitLiveHeartRateSource.beatsPerMinute(HKQuantity(unit: unit, doubleValue: 10)) == nil)
        #expect(HealthKitLiveHeartRateSource.beatsPerMinute(HKQuantity(unit: unit, doubleValue: 400)) == nil)
    }
}
