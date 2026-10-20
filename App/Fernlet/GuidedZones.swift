//
//  GuidedZones.swift
//  Fernlet
//
//  Heart-rate zones for guided cardio (comparison report idea 9, roadmap step 4b, 2026-10-20). The owner's
//  ask: "on the live activity it should encourage the user to stay in a heart rate zone".
//
//  - Each timed cardio segment aims for a zone (`HeartRateZones`, FernletDomainModel): zone 2 for easy and
//    steady parts, zone 4 for an interval's hard part, from the person's age (Tanaka) and Apple Health's
//    resting heart rate when there is one (Karvonen).
//  - With "Heart rate during cardio" on and Fernlet's workout sharing with Apple Health on, a cardio part
//    starts an iPhone workout session that reads live heart rate (`LiveHeartRateSession.swift`). The runner
//    card, the Lock Screen and the Dynamic Island then show "118 bpm · aim 110–125" and a calm word — "in
//    range", "a little high", "a little low" — never colour alone and never animated.
//  - Without a reading — no switch, no sensor, or nothing for 20 seconds — the cue is the talk test, and no
//    number is shown. Nothing says the heart rate went missing.
//  - "Zone nudges" (off until turned on) adds one light tap when the heart rate has sat outside the target
//    for 30 seconds, once per drift and at most once a minute, after the part has had 30 seconds to settle
//    (a heart takes about that long to follow a change of pace, so a one-minute interval never nudges).
//
//  Privacy: the heart rate lives in memory only — never in the run state, the log, the synced blob or a
//  file — and the Live Activity carries the latest number while the run lasts. No network. The finished
//  run logs exactly as before; Fernlet writes no heart-rate value anywhere.
//

import Foundation
import Observation
import SwiftUI
import UIKit
import FernletDomainModel
import FernletUI
import HealthKitGateway

/// The guided runner's heart-rate switches: "Heart rate during cardio" and "Zone nudges", both off until
/// the person turns them on.
///
/// **Device-local `UserDefaults`, never synced**, beside ``WorkoutCuePreferences`` and for the same
/// reason: which sensors are paired, and whether this phone may buzz, belong to the device in hand. Kept
/// by "Delete everything", like the cue switches (`Docs/PrivacyWipeCoverage.md`): preferences, not
/// records. The keys are FROZEN persisted tokens, spelled once here and read and written only through
/// this type, so the wipe wall resolves every access to its literal.
struct WorkoutZonePreferences: Equatable {
    /// `Bool`, default `false`: read live heart rate during guided cardio.
    static let liveHeartRateKey = "fernlet.workoutCues.liveHeartRate"
    /// `Bool`, default `false`: a light tap when the heart rate drifts out of the target zone.
    static let zoneNudgesKey = "fernlet.workoutCues.zoneNudges"

    /// Read live heart rate during guided cardio.
    var liveHeartRate: Bool
    /// Tap when the heart rate has drifted out of the target zone (only with ``liveHeartRate``).
    var zoneNudges: Bool

    /// Both off: the switches until the person changes them.
    static let defaultSwitches = WorkoutZonePreferences(liveHeartRate: false, zoneNudges: false)

    /// The person's current switches, falling back to ``defaultSwitches`` for a switch never set.
    static func current(in defaults: UserDefaults = .standard) -> WorkoutZonePreferences {
        WorkoutZonePreferences(
            liveHeartRate: defaults.object(forKey: liveHeartRateKey) as? Bool ?? defaultSwitches.liveHeartRate,
            zoneNudges: defaults.object(forKey: zoneNudgesKey) as? Bool ?? defaultSwitches.zoneNudges
        )
    }

    /// Stores both switches — the Workout setup sheet's Save.
    static func save(_ preferences: WorkoutZonePreferences, in defaults: UserDefaults = .standard) {
        defaults.set(preferences.liveHeartRate, forKey: liveHeartRateKey)
        defaults.set(preferences.zoneNudges, forKey: zoneNudgesKey)
    }
}

/// One live heart-rate reading as the runner holds it: whole beats per minute and when it arrived.
/// In memory only.
struct GuidedZoneReading: Equatable {
    /// Beats per minute.
    let bpm: Int
    /// When the reading reached Fernlet.
    let at: Date

    /// Whether the reading is still live at `now`: no older than ``GuidedZonePlan/freshSeconds``.
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= -1 && age <= GuidedZonePlan.freshSeconds
    }
}

/// The zone cue's rules as pure functions: when the runner wants a live session, and what cue a run shows
/// with or without a reading.
enum GuidedZonePlan {
    /// How long a reading stays live. Past it the cue falls back to the talk test, silently.
    static let freshSeconds: TimeInterval = 20
    /// The least time between two Live Activity updates for a changed reading (a band change is sooner).
    static let publishGapSeconds: TimeInterval = 5

    /// Whether `run` wants a live heart-rate session: a live run on a timed cardio segment, the person's
    /// switch on, and Fernlet allowed to share workouts with Apple Health. `sharingAllowed` is asked last,
    /// and only when everything else holds — it reads the keychain-backed switches.
    static func wantsSession(
        run: GuidedWorkoutRunState?,
        switchOn: Bool,
        sourceAvailable: Bool,
        sharingAllowed: @MainActor () -> Bool
    ) -> Bool {
        guard switchOn, sourceAvailable, let run, run.isWorking || run.isResting,
              run.currentExercise?.segment != nil else { return false }
        return sharingAllowed()
    }

    /// The cue `run` shows: nil off a cardio segment; the talk test (the target alone) without a fresh
    /// reading or zones; the reading against the target's range otherwise.
    static func zone(
        for run: GuidedWorkoutRunState?,
        zones: HeartRateZones?,
        reading: GuidedZoneReading?,
        now: Date
    ) -> WorkoutActivityAttributes.ContentState.Zone? {
        guard let run, run.isWorking || run.isResting, var zone = run.currentZone else { return nil }
        guard let target = zone.target, let zones, let reading, reading.isFresh(at: now),
              let range = zones.range(zone: target) else { return zone }
        zone.bpm = reading.bpm
        zone.low = range.lowerBound
        zone.high = range.upperBound
        return zone
    }
}

/// When a zone nudge is due: the heart rate has sat outside the target for ``driftSeconds``, the part has
/// had ``settleSeconds`` to take effect, this drift has not been nudged already, and the last nudge was
/// at least ``minimumGapSeconds`` ago. A pure value; the director feeds it readings and asks.
struct GuidedZoneNudgeTracker: Equatable {
    /// How long a reading must stay outside the target before a nudge.
    static let driftSeconds: TimeInterval = 30
    /// The least time between two nudges.
    static let minimumGapSeconds: TimeInterval = 60
    /// How long after a new target (a new part, a new pace) drift starts to count: a heart takes about
    /// this long to follow a change of pace.
    static let settleSeconds: TimeInterval = 30

    /// When the current target began; nil before any.
    private(set) var targetSince: Date?
    /// When the current drift began counting; nil while in range.
    private(set) var driftSince: Date?
    /// Whether this drift has been nudged already.
    private(set) var driftNudged = false
    /// When the last nudge was due.
    private(set) var lastNudgeAt: Date?

    /// A new target began at `now`: the drift clock starts over after the settle time.
    mutating func retarget(at now: Date) {
        targetSince = now
        driftSince = nil
        driftNudged = false
    }

    /// The reading went away (stale, or the session ended): any drift stops counting.
    mutating func readingLost() {
        driftSince = nil
        driftNudged = false
    }

    /// Takes one reading's verdict at `now`; returns true when a nudge is due now.
    mutating func observe(inRange: Bool, at now: Date) -> Bool {
        guard !inRange else {
            driftSince = nil
            driftNudged = false
            return false
        }
        if let targetSince, now.timeIntervalSince(targetSince) < Self.settleSeconds { return false }
        guard let since = driftSince else {
            driftSince = now
            return false
        }
        guard !driftNudged, now.timeIntervalSince(since) >= Self.driftSeconds else { return false }
        if let lastNudgeAt, now.timeIntervalSince(lastNudgeAt) < Self.minimumGapSeconds { return false }
        driftNudged = true
        lastNudgeAt = now
        return true
    }
}

/// Runs guided cardio's heart-rate cue: starts and ends the live session as the run moves on and off cardio
/// segments, keeps the latest reading (in memory only) and lets it go stale, plays the opt-in zone nudge,
/// and asks the store to refresh the Live Activity when what it shows changes.
///
/// Owned by `FernletStore` (`guidedZones`) and told about every change of the run through
/// ``runChanged(to:)``, beside the cue director. The runner card observes ``reading``.
///
/// **Invariants**
/// - *Only by the person's leave.* No session without the "Heart rate during cardio" switch and Fernlet's
///   workout sharing; the switch itself is what asked Apple Health (``requestReadAccess()``).
/// - *One session, only on cardio.* Started on a cardio segment of a live run, ended the moment the run
///   leaves cardio, finishes, is abandoned or cleared; a session that fails is not retried in that run.
/// - *Never a second workout.* The source discards its builder's workout; the run's log is the writer.
/// - *Silent fallback.* A reading older than ``GuidedZonePlan/freshSeconds`` is dropped and the cue becomes
///   the talk test, with no message.
@MainActor
@Observable
final class GuidedZoneDirector {
    /// The latest live reading, or nil — what the runner card draws. In memory only.
    private(set) var reading: GuidedZoneReading?

    @ObservationIgnored private let source: any LiveHeartRateSource
    @ObservationIgnored private let switches: @MainActor () -> WorkoutZonePreferences
    @ObservationIgnored private let sharingAllowed: @MainActor () -> Bool
    @ObservationIgnored private let zonesProvider: @MainActor () -> HeartRateZones?
    @ObservationIgnored private let feedback: FernletFeedback
    @ObservationIgnored private let announcer: FernletAnnouncer
    @ObservationIgnored private let cuePreferences: @MainActor () -> FernletFeedbackPreferences
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private let clock: @MainActor () -> Date
    /// Asks the store to re-publish the Live Activity with ``zone(for:)``.
    @ObservationIgnored private let publish: @MainActor () -> Void

    /// The run as of the last ``runChanged(to:)``.
    @ObservationIgnored private var run: GuidedWorkoutRunState?
    /// The person's zones, read when the session starts.
    @ObservationIgnored private var zones: HeartRateZones?
    /// Whether a live session is running.
    @ObservationIgnored private(set) var isSessionRunning = false
    /// A start in flight; no second start begins while it runs.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Bumped by every stop, so a start that lands after it knows it is no longer wanted.
    @ObservationIgnored private var generation = 0
    /// The run whose session failed: not retried until another run.
    @ObservationIgnored private var failedRunID: UUID?
    /// The target zone the nudge tracker is on, and the segment it belongs to.
    @ObservationIgnored private var trackedTarget: TrackedTarget?
    @ObservationIgnored private var tracker = GuidedZoneNudgeTracker()
    @ObservationIgnored private var staleTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublished: PublishedCue?
    @ObservationIgnored private var recoveryChecked = false

    /// The segment and target the nudge tracker last saw, so a new part (even at the same pace) settles.
    private struct TrackedTarget: Equatable {
        /// The segment step.
        let stepID: UUID
        /// Its set, for a step timed more than once.
        let set: Int
        /// The zone it aims for.
        let target: Int
    }

    /// What the Live Activity was last asked to show, and when.
    private struct PublishedCue: Equatable {
        /// The cue.
        let zone: WorkoutActivityAttributes.ContentState.Zone?
        /// When.
        let at: Date
    }

    /// Creates a director. Every dependency is injectable; nil means production.
    ///
    /// - Parameters:
    ///   - source: The live heart-rate source; nil means the HealthKit one.
    ///   - switches: The person's zone switches, read at every decision.
    ///   - sharingAllowed: Whether Fernlet may share workouts with Apple Health right now.
    ///   - zones: The person's zones (age and resting heart rate), read when a session starts.
    ///   - feedback: The haptic player; nil means production.
    ///   - announcer: The VoiceOver announcer; nil means production.
    ///   - cuePreferences: The runner's haptics and sounds switches, which a nudge also obeys.
    ///   - isAppActive: Whether the app is in front; a session starts and a nudge plays only then.
    ///   - clock: Now.
    ///   - publish: Re-publishes the Live Activity.
    init(
        source: (any LiveHeartRateSource)? = nil,
        switches: @escaping @MainActor () -> WorkoutZonePreferences = { WorkoutZonePreferences.current() },
        sharingAllowed: @escaping @MainActor () -> Bool,
        zones: @escaping @MainActor () -> HeartRateZones?,
        feedback: FernletFeedback? = nil,
        announcer: FernletAnnouncer? = nil,
        cuePreferences: @escaping @MainActor () -> FernletFeedbackPreferences = { WorkoutCuePreferences.current() },
        isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        clock: @escaping @MainActor () -> Date = { Date() },
        publish: @escaping @MainActor () -> Void
    ) {
        self.source = source ?? HealthKitLiveHeartRateSource()
        self.switches = switches
        self.sharingAllowed = sharingAllowed
        self.zonesProvider = zones
        self.feedback = feedback ?? .system
        self.announcer = announcer ?? .system
        self.cuePreferences = cuePreferences
        self.isAppActive = isAppActive
        self.clock = clock
        self.publish = publish
    }

    /// The session start and the freshness timer end with the director (the memory wall's ML1).
    isolated deinit {
        startTask?.cancel()
        staleTask?.cancel()
    }

    /// The cue `state` shows right now: the talk test, or the live reading against its target.
    func zone(for state: GuidedWorkoutRunState?) -> WorkoutActivityAttributes.ContentState.Zone? {
        GuidedZonePlan.zone(for: state, zones: zones, reading: reading, now: clock())
    }

    /// The run changed (or went away): start or end the session, and re-aim the nudge.
    ///
    /// A session STARTS only with the app in front: a Lock Screen tap can wake Fernlet in the background,
    /// and a session refused there would count as failed for the rest of the run. The next change seen in
    /// front (the foreground reconcile adopts the run again) starts it. A running session carries on in
    /// the background until the run leaves cardio.
    func runChanged(to state: GuidedWorkoutRunState?) {
        run = state
        retarget(for: state)
        let switchOn = switches().liveHeartRate && failedRunID != state?.sessionID
        let wanted = GuidedZonePlan.wantsSession(
            run: state, switchOn: switchOn, sourceAvailable: source.isAvailable, sharingAllowed: sharingAllowed
        )
        if !wanted {
            stopSession()
        } else if isAppActive() {
            startIfNeeded(for: state)
        }
    }

    /// Asks Apple Health to let Fernlet read heart rate — only ever from the person turning the switch on.
    func requestReadAccess() async {
        guard source.isAvailable, sharingAllowed() else { return }
        _ = await source.requestReadAccess()
    }

    /// Ends a session HealthKit kept alive across a crash — once per launch, and only for someone who uses
    /// the switch. The store calls this whenever it reconciles the run (launch and foreground).
    func retireRecoveredSessionIfNeeded() {
        guard !recoveryChecked, switches().liveHeartRate, !isSessionRunning, startTask == nil else { return }
        recoveryChecked = true
        let source = source
        Task { await source.retireRecoveredSession() }
    }

    /// Waits for a start in flight to land. A test seam, like the cue director's `timedCuesSettled()`.
    func sessionStartSettled() async {
        await startTask?.value
    }

    /// A reading arrived from the session.
    func receive(bpm: Int) {
        guard isSessionRunning || startTask != nil, HeartRateZones.plausibleBPM.contains(bpm) else { return }
        let now = clock()
        reading = GuidedZoneReading(bpm: bpm, at: now)
        armStaleCheck()
        nudgeIfDue(at: now)
        publishIfChanged(at: now)
    }

    /// Drops the reading once it is older than ``GuidedZonePlan/freshSeconds`` — the silent fallback to
    /// the talk test. The stale timer calls this; so can a test.
    func expireStaleReading() {
        guard let reading, !reading.isFresh(at: clock()) else { return }
        self.reading = nil
        tracker.readingLost()
        publishIfChanged(at: clock())
    }

    /// The session stopped by itself: no retry in this run, back to the talk test.
    func sessionEnded() {
        guard isSessionRunning else { return }
        isSessionRunning = false
        failedRunID = run?.sessionID
        clearReading()
        publish()
    }

    /// Starts the session for `state` unless one runs or is starting. Reads the zones now, so a resting
    /// heart rate that arrives mid-run never moves a target under the person.
    private func startIfNeeded(for state: GuidedWorkoutRunState?) {
        guard let state, !isSessionRunning, startTask == nil else { return }
        zones = zonesProvider()
        let ticket = generation
        let activity = GuidedRunTimedLog.activityType(for: state) ?? .mixedCardio
        startTask = Task { [weak self] in
            guard let self else { return }
            let began = await self.source.start(
                activity: activity,
                onReading: { [weak self] bpm in self?.receive(bpm: bpm) },
                onEnded: { [weak self] in self?.sessionEnded() }
            )
            self.startFinished(began: began, ticket: ticket)
        }
    }

    /// A start landed: keep it if it is still wanted, end it if a stop came first, then catch up with the run.
    private func startFinished(began: Bool, ticket: Int) {
        startTask = nil
        guard began else {
            failedRunID = run?.sessionID
            clearReading()
            return
        }
        guard ticket == generation else {
            source.stop()
            runChanged(to: run)
            return
        }
        isSessionRunning = true
    }

    /// Ends the session (and any start in flight) and drops the reading.
    private func stopSession() {
        guard isSessionRunning || startTask != nil || reading != nil else { return }
        generation += 1
        if isSessionRunning {
            source.stop()
            isSessionRunning = false
        }
        clearReading()
    }

    /// Drops the reading and the stale timer, and forgets any drift.
    private func clearReading() {
        staleTask?.cancel()
        staleTask = nil
        reading = nil
        tracker.readingLost()
        lastPublished = nil
    }

    /// Re-aims the nudge when the run moved onto a different part.
    private func retarget(for state: GuidedWorkoutRunState?) {
        guard let state, let exercise = state.currentExercise, let target = state.currentZone?.target else {
            trackedTarget = nil
            return
        }
        let next = TrackedTarget(stepID: exercise.id, set: state.currentSet, target: target)
        guard next != trackedTarget else { return }
        trackedTarget = next
        tracker.retarget(at: clock())
    }

    /// Plays the nudge when one is due and the person asked for nudges: a light tap, and the same said to
    /// VoiceOver. Only while the app is in front — a background app cannot play a haptic.
    private func nudgeIfDue(at now: Date) {
        guard let zone = zone(for: run), let band = zone.band else { return }
        guard tracker.observe(inRange: band == .inRange, at: now) else { return }
        guard switches().zoneNudges, isAppActive() else { return }
        feedback.play(.zoneDrift, preferences: cuePreferences())
        if band == .high {
            announcer.announce(.status, "Heart rate a little high.")
        } else {
            announcer.announce(.status, "Heart rate a little low.")
        }
    }

    /// Re-arms the timer that drops the reading once it goes stale.
    private func armStaleCheck() {
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(GuidedZonePlan.freshSeconds + 0.5))
            } catch {
                return
            }
            self?.expireStaleReading()
        }
    }

    /// Asks the store to refresh the Live Activity when the cue changed: at once for a new band (or a
    /// reading appearing or going), otherwise no more than every ``GuidedZonePlan/publishGapSeconds``.
    private func publishIfChanged(at now: Date) {
        let current = zone(for: run)
        if let lastPublished {
            guard current != lastPublished.zone else { return }
            let bandChanged = current?.band != lastPublished.zone?.band
            guard bandChanged || now.timeIntervalSince(lastPublished.at) >= GuidedZonePlan.publishGapSeconds else {
                return
            }
        }
        lastPublished = PublishedCue(zone: current, at: now)
        publish()
    }
}

/// The runner's own words for the zone cue: the talk test as a whole sentence under the card.
///
/// The Lock Screen's shorter talk test and the live reading's words are shared with the widget
/// (``WorkoutActivityZoneText``).
enum GuidedZoneWords {
    /// The talk test for a part aiming at `target`: zone 2's "You should be able to talk in short
    /// sentences.", zone 4's "You should only manage a few words at a time."
    static func talkTest(target: Int) -> Text {
        guard target > WorkoutActivityZoneText.conversationalZoneLimit else {
            return Text("You should be able to talk in short sentences.")
        }
        return Text("You should only manage a few words at a time.")
    }
}
