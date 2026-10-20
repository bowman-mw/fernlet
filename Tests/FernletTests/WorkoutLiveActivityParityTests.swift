// WorkoutLiveActivityParityTests.swift
// FernletTests
//
// Pins comparison report idea 7 (2026-10-20), Live Activity parity with Hevy's free Live Activity:
// the set's suggested weight, range and last time's numbers on the Lock Screen and in the expanded
// Dynamic Island (display only), and "−15 s" / "+15 s" beside "Skip rest" there and in the runner.
//
// Covered here: the run state's rest adjustment and its limits (never under five seconds left, never
// past ten minutes), the time-left estimate following it, the content state's load mapping and its
// tolerant decoding of older payloads and runs, the two intents' effect on the stored run, the store's
// in-app adjustment and the Lock Screen one both re-arming the rest-end cue and its notification, the
// last-time numbers baked in at start, and the drawn and spoken words. What no test here can check —
// how the card looks at each text size, and that a Lock Screen tap re-arms a notification on a phone —
// is owed on a device.

import Foundation
import Testing
import AppServices
import FernletDomainModel
import FernletUI
@testable import Fernlet

/// Records what a ``GuidedRunCueDirector`` asked the notification center to hold, in order.
@MainActor
private final class RestCueRecorder {
    /// Every request's cues, in order.
    var schedules: [[NotificationService.WorkoutCue]] = []

    /// A scheduler that records here instead of touching the notification center.
    var scheduler: GuidedRunCueDirector.BackgroundScheduler {
        { [self] cues, _ in schedules.append(cues) }
    }
}

/// Serialized for the same reason as `GuidedWorkoutRunStoreTests`: three tests stand up a real
/// `FernletStore`, which reaches process-global state (the `Activity<…>` registry behind the Live
/// Activity bridge and `NotificationCenter.default`, which the intents post on).
@MainActor
@Suite(.serialized) struct WorkoutLiveActivityParityTests {

    // MARK: Fixtures

    /// When the fixture rests begin — a whole second, so app-group ISO-8601 dates read back exactly.
    private nonisolated static let t0 = Date(timeIntervalSince1970: 3_000_000)
    private nonisolated static let english = Locale(identifier: "en_US")

    private typealias Load = WorkoutActivityAttributes.ContentState.Load

    /// A tracked barbell lift's plan: 105 lb suggested and preselected, 95–110 lb.
    private static func tracking(selected: Double? = 105, suggested: Double? = 105) -> GuidedWorkoutRunState.Tracking {
        GuidedWorkoutRunState.Tracking(
            targetReps: 8, rangeLow: 95, rangeHigh: 110, suggested: suggested, step: 5, unitRaw: "lb",
            equipmentRaw: "barbell", confidenceRaw: nil, askReasonOnOverride: false, calibrationRaw: nil,
            easierSession: false, compoundsBefore: 0, selected: selected
        )
    }

    private static func lift(
        _ name: String, sets: Int = 3, rest: Int = 90,
        tracking: GuidedWorkoutRunState.Tracking? = nil, lastTime: GuidedWorkoutRunState.LastTime? = nil
    ) -> GuidedWorkoutRunState.Exercise {
        GuidedWorkoutRunState.Exercise(
            name: name, sets: sets, reps: "8", roleRaw: "main", fromCatalog: true, restSeconds: rest,
            blockRaw: "lifting", tracking: tracking, lastTime: lastTime
        )
    }

    private static func run(_ exercises: [GuidedWorkoutRunState.Exercise]) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate", title: "Push",
            suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: exercises, setStartedAt: t0
        )
    }

    /// A run resting before set 2 of one lift, its rest running `rest` seconds from `start`.
    private static func resting(rest: Int, from start: Date) -> GuidedWorkoutRunState {
        var state = run([lift("Bench press", rest: rest)])
        state.markSetDone(now: start)
        return state
    }

    private static func session(_ name: String, _ exercises: [PrescribedExercise]) -> WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: .strength, exercises: exercises,
            suggestion: WorkoutSuggestion(name: name, exercises: exercises.map(\.line).joined(separator: "\n"), notes: "")
        )
    }

    /// A director that records the background cue and plays nothing.
    private static func director(_ background: RestCueRecorder) -> GuidedRunCueDirector {
        GuidedRunCueDirector(
            feedback: FernletFeedback(perform: { _ in }),
            preferences: { FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false) },
            isAppActive: { false },
            scheduleBackground: background.scheduler
        )
    }

    /// "Now" on a whole second, so a run written to the app group reads back with the same dates.
    private static func wholeSecondNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    /// Writes a run resting from `start` to `end` to `directory`, as the Lock Screen would find it.
    private static func writeResting(from start: Date, to end: Date, in directory: URL) -> Bool {
        var state = run([lift("Bench press")])
        state.markSetDone(now: start)
        state.restEndsAt = end
        return GuidedWorkoutRunStateStore(directory: directory).write(state)
    }

    /// Formatted text with the no-break spaces a locale may put between number and unit made plain.
    private static func plain(_ text: String?) -> String? {
        text.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    private static func fullLoad() -> Load {
        Load(weight: 105, suggested: 105, rangeLow: 95, rangeHigh: 110, unitRaw: "lb",
             lastSets: 3, lastReps: "8", lastWeight: 100, lastUnitRaw: "lb")
    }

    // MARK: Rest adjustment — the run state

    /// "+15 s" moves only the rest's end: the start, the set and the phase stay.
    @Test func plusFifteenMovesOnlyTheRestsEnd() {
        var state = Self.resting(rest: 90, from: Self.t0)
        let moved = state.adjustRest(by: 15, now: Self.t0.addingTimeInterval(10))
        #expect(moved)
        #expect(state.restStartedAt == Self.t0)
        #expect(state.restEndsAt == Self.t0.addingTimeInterval(105))
        #expect(state.restDuration == 105)
        #expect(state.isResting && state.currentSet == 2, "an adjustment never moves the set")
    }

    /// "−15 s" shortens the rest by fifteen seconds.
    @Test func minusFifteenShortensTheRest() {
        var state = Self.resting(rest: 90, from: Self.t0)
        let moved = state.adjustRest(by: -15, now: Self.t0.addingTimeInterval(10))
        #expect(moved)
        #expect(state.restEndsAt == Self.t0.addingTimeInterval(75))
        #expect(state.restDuration == 75)
    }

    /// "−15 s" always leaves five seconds; at five, or over, it does nothing ("Skip rest" ends a rest).
    @Test func minusFifteenAlwaysLeavesFiveSeconds() {
        var state = Self.resting(rest: 90, from: Self.t0)
        let tenLeft = Self.t0.addingTimeInterval(80)
        let moved = state.adjustRest(by: -15, now: tenLeft)
        #expect(moved)
        #expect(state.restEndsAt == tenLeft.addingTimeInterval(5))
        let movedAgain = state.adjustRest(by: -15, now: tenLeft)
        #expect(movedAgain == false, "five seconds left is the floor")
        #expect(state.restEndsAt == tenLeft.addingTimeInterval(5))

        var over = Self.resting(rest: 90, from: Self.t0)
        let overMoved = over.adjustRest(by: -15, now: Self.t0.addingTimeInterval(100))
        #expect(overMoved == false)
        #expect(over.restEndsAt == Self.t0.addingTimeInterval(90))
    }

    /// "+15 s" stops at ten minutes from the rest's start: short of the cap it lands on the cap.
    @Test func plusFifteenStopsAtTenMinutes() {
        var state = Self.resting(rest: 590, from: Self.t0)
        let now = Self.t0.addingTimeInterval(10)
        let moved = state.adjustRest(by: 15, now: now)
        #expect(moved)
        #expect(state.restEndsAt == Self.t0.addingTimeInterval(TimeInterval(GuidedWorkoutRunState.maximumRestSeconds)))
        let movedAgain = state.adjustRest(by: 15, now: now)
        #expect(movedAgain == false)
        #expect(state.restDuration == GuidedWorkoutRunState.maximumRestSeconds)
    }

    /// Over a timer that already ran out, "+15 s" means fifteen more seconds from now — unless the rest
    /// is already ten minutes old.
    @Test func plusFifteenAfterTheTimerRanOutCountsFromNow() {
        var state = Self.resting(rest: 90, from: Self.t0)
        let now = Self.t0.addingTimeInterval(120)
        let moved = state.adjustRest(by: 15, now: now)
        #expect(moved)
        #expect(state.restEndsAt == now.addingTimeInterval(15))

        var old = Self.resting(rest: 90, from: Self.t0)
        let oldMoved = old.adjustRest(by: 15, now: Self.t0.addingTimeInterval(700))
        #expect(oldMoved == false)
        #expect(old.restEndsAt == Self.t0.addingTimeInterval(90))
    }

    /// Outside a rest, or by zero, nothing moves.
    @Test func adjustingOutsideARestDoesNothing() {
        var working = Self.run([Self.lift("Bench press")])
        let workingMoved = working.adjustRest(by: 15, now: Self.t0)
        #expect(workingMoved == false)
        #expect(working.restEndsAt == nil)
        var resting = Self.resting(rest: 90, from: Self.t0)
        let zeroMoved = resting.adjustRest(by: 0, now: Self.t0)
        #expect(zeroMoved == false)
        #expect(resting.restEndsAt == Self.t0.addingTimeInterval(90))
    }

    /// Whatever the taps and the clock, the window the countdowns draw stays ordered and within ten
    /// minutes, and never ends sooner than five seconds after a "−15 s".
    @Test func theRestWindowStaysOrderedThroughAnyTaps() throws {
        var state = Self.resting(rest: 30, from: Self.t0)
        for step in 0..<60 {
            let now = Self.t0.addingTimeInterval(TimeInterval(step * 7))
            let seconds = step.isMultiple(of: 3) ? -15 : 15
            let moved = state.adjustRest(by: seconds, now: now)
            let start = try #require(state.restStartedAt)
            let end = try #require(state.restEndsAt)
            #expect(start <= end)
            #expect(end.timeIntervalSince(start) <= TimeInterval(GuidedWorkoutRunState.maximumRestSeconds))
            if moved && seconds < 0 {
                #expect(end >= now.addingTimeInterval(TimeInterval(GuidedWorkoutRunState.minimumRestLeftSeconds)))
            }
        }
    }

    /// The buttons and every spoken line say fifteen, five and ten minutes; these pin the numbers.
    @Test func theRestLimitsAreTheOnesTheWordsSay() {
        #expect(GuidedWorkoutRunState.restAdjustStepSeconds == 15)
        #expect(GuidedWorkoutRunState.minimumRestLeftSeconds == 5)
        #expect(GuidedWorkoutRunState.maximumRestSeconds == 10 * 60)
    }

    // MARK: The time-left estimate

    /// The header's "min left" follows an adjusted rest: the in-flight rest counts at its own length.
    @Test func theTimeLeftEstimateFollowsAnAdjustedRest() {
        var state = Self.run([Self.lift("Squat", sets: 2), Self.lift("Bench press", sets: 2)])
        state.markSetDone(now: Self.t0)
        // Squat's last set and its 90 s rest, Bench press's 2 × 45 + 90, and the 60 s changeover between.
        #expect(state.estimatedSecondsRemaining() == 375)
        let lengthened = state.adjustRest(by: 15, now: Self.t0)
        #expect(lengthened)
        #expect(state.estimatedSecondsRemaining() == 390)
        let shortened = state.adjustRest(by: -15, now: Self.t0)
        #expect(shortened)
        let shortenedAgain = state.adjustRest(by: -15, now: Self.t0)
        #expect(shortenedAgain)
        #expect(state.estimatedSecondsRemaining() == 360)
    }

    // MARK: The content state's load

    /// The set's weight, range and last time reach the Live Activity as numbers and unit tokens.
    @Test func theContentStateCarriesTheSetsLoadAsNumbers() throws {
        let last = GuidedWorkoutRunState.LastTime(sets: 3, reps: "8", weight: 100, unitRaw: "lb")
        let state = Self.run([Self.lift("Bench press", tracking: Self.tracking(), lastTime: last)])
        let load = try #require(state.contentState.load)
        #expect(load == Self.fullLoad())
    }

    /// A weight picked in the runner is the weight the Lock Screen shows; resting keeps it (the next
    /// set is the same lift's).
    @Test func aWeightPickedInTheAppReachesTheLoad() throws {
        var state = Self.run([Self.lift("Bench press", tracking: Self.tracking())])
        let id = try #require(state.currentExercise?.id)
        state.selectWeight(110, forExercise: id)
        #expect(state.contentState.load?.weight == 110)
        #expect(state.contentState.load?.suggested == 105)
        state.markSetDone(now: Self.t0)
        #expect(state.contentState.load?.weight == 110)
    }

    /// A timed step and a lift with nothing to show carry no load; a bodyweight lift still shows last time.
    @Test func stepsWithNothingToShowCarryNoLoad() throws {
        let plank = GuidedWorkoutRunState.Exercise(
            name: "Plank", sets: 1, reps: "30 s", roleRaw: "core", fromCatalog: true, restSeconds: 0,
            holdSeconds: 30, blockRaw: "activation", lastTime: GuidedWorkoutRunState.LastTime(sets: 2, reps: "30 s")
        )
        #expect(Self.run([plank]).contentState.load == nil, "a timed step shows its countdown, not a load")
        #expect(Self.run([Self.lift("Bench press")]).contentState.load == nil)

        var bodyweight = Self.tracking(selected: nil, suggested: nil)
        bodyweight.step = nil
        bodyweight.unitRaw = nil
        let pullUps = Self.lift("Pull-up", tracking: bodyweight, lastTime: GuidedWorkoutRunState.LastTime(sets: 3, reps: "6"))
        let load = try #require(Self.run([pullUps]).contentState.load)
        #expect(load.weight == nil && load.rangeLow == nil && load.unitRaw == nil)
        #expect(load.lastSets == 3 && load.lastReps == "6")
    }

    /// The content state round-trips with its load, and stays far under ActivityKit's 4 KB payload cap.
    @Test func theContentStateRoundTripsWithItsLoad() throws {
        let last = GuidedWorkoutRunState.LastTime(sets: 3, reps: "8-10", weight: 100, unitRaw: "lb")
        var state = Self.run([Self.lift("Single-arm dumbbell row on a bench", tracking: Self.tracking(), lastTime: last)])
        state.markSetDone(now: Self.t0)
        let content = state.contentState
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: data) == content)
        #expect(data.count < 1_024, "the content state grew to \(data.count) bytes")
    }

    /// A payload from before the load line (no `load`, no hold, block or side keys) still decodes, and
    /// so does a load carrying only some of its fields.
    @Test func olderAndPartialPayloadsStillDecode() throws {
        let old = """
            {"exerciseName":"Bench press","setNumber":2,"totalSets":3,"reps":"8","phase":"resting",\
            "restStartedAt":0,"restEndsAt":90,"exerciseIndex":0,"totalExercises":4}
            """
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: Data(old.utf8))
        #expect(decoded.load == nil)
        #expect(decoded.holdStartsAt == nil && decoded.blockRaw == nil && decoded.sideRaw == nil)
        #expect(decoded.restEndsAt == Date(timeIntervalSinceReferenceDate: 90))

        let partial = """
            {"exerciseName":"Bench press","setNumber":1,"totalSets":3,"reps":"8","phase":"working",\
            "exerciseIndex":0,"totalExercises":4,"load":{"weight":105}}
            """
        let withPartialLoad = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: Data(partial.utf8))
        #expect(withPartialLoad.load == Load(weight: 105))
    }

    /// A run saved before last time's numbers existed still decodes, keeping its weight plan.
    @Test func aRunSavedBeforeLastTimeStillDecodes() throws {
        let last = GuidedWorkoutRunState.LastTime(sets: 3, reps: "8", weight: 100, unitRaw: "lb")
        let state = Self.run([Self.lift("Bench press", tracking: Self.tracking(), lastTime: last)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        var exercises = try #require(json["exercises"] as? [[String: Any]])
        #expect(exercises[0]["lastTime"] != nil)
        exercises[0].removeValue(forKey: "lastTime")
        json["exercises"] = exercises

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let older = try decoder.decode(GuidedWorkoutRunState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.exercises[0].lastTime == nil)
        #expect(older.exercises[0].tracking == state.exercises[0].tracking)
        #expect(older.contentState.load?.weight == 105)
        #expect(older.contentState.load?.lastSets == nil)
    }

    // MARK: Last time, baked in at start

    /// One rollup in, last time's numbers out per lift: the most recent entry of a name wins, the unit
    /// crosses as its token, and an entry with no numbers is left out.
    @Test func lastTimesComeFromTheHistoryRollup() {
        typealias Entry = TrainerExportBundle.ExerciseHistoryEntry
        let entries = [
            Entry(name: "Bench press", sessions: 2, totalSets: 6, firstLogged: "2026-10-01", lastLogged: "2026-10-15",
                  lastSets: 3, lastReps: "8", lastWeight: 100, weightUnit: "lb"),
            Entry(name: "bench  PRESS", sessions: 1, totalSets: 5, firstLogged: "2026-09-01", lastLogged: "2026-09-01",
                  lastSets: 5, lastReps: "5", lastWeight: 90, weightUnit: "lb"),
            Entry(name: "Goblet squat", sessions: 1, totalSets: 3, firstLogged: "2026-10-10", lastLogged: "2026-10-10",
                  lastSets: 3, lastReps: "10", lastWeight: 24, weightUnit: "kg"),
            Entry(name: "Pull-up", sessions: 1, totalSets: 3, firstLogged: "2026-10-12", lastLogged: "2026-10-12",
                  lastSets: 3, lastReps: "6"),
            Entry(name: "Mystery", sessions: 1, totalSets: 0, firstLogged: "2026-10-12", lastLogged: "2026-10-12"),
        ]
        let byName = GuidedRunLoadLog.lastTimes(from: entries)
        let key = WorkoutExerciseCatalog.normalizedName
        #expect(byName[key("Bench press")] == GuidedWorkoutRunState.LastTime(sets: 3, reps: "8", weight: 100, unitRaw: "lb"))
        #expect(byName[key("Goblet squat")]?.unitRaw == "kg")
        #expect(byName[key("Pull-up")] == GuidedWorkoutRunState.LastTime(sets: 3, reps: "6"))
        #expect(byName[key("Mystery")] == nil)
    }

    /// Starting a run bakes last time into each counted lift — never into a hold — from the same
    /// history the runner's "Last time" pill reads, so a cold-launched intent can still show it.
    @Test func startingARunBakesLastTimeFromTheLoggedHistory() throws {
        let store = makeTestStore(appGroupDirectory: uniqueAppGroupDirectory())
        store.addWorkout(Workout(name: "Earlier", type: .upper, exercises: "Bench Press - 3 x 8 @ 100 lb\nPlank - 2 x 30 s",
                                 rpe: nil, notes: "", duration: 40, intensity: .moderate))
        let session = Self.session("Push", [
            PrescribedExercise(name: "Bench Press", sets: 3, reps: "8", role: .main, fromCatalog: true),
            PrescribedExercise(name: "Plank", sets: 2, reps: "30 s", role: .core, fromCatalog: true,
                               block: .activation, holdSeconds: 30),
            PrescribedExercise(name: "Seated row", sets: 3, reps: "10", role: .main, fromCatalog: true),
        ])
        #expect(store.startGuidedRun(session))
        let run = try #require(store.guidedRunState)
        #expect(run.exercises[0].lastTime == GuidedWorkoutRunState.LastTime(sets: 3, reps: "8", weight: 100, unitRaw: "lb"))
        #expect(run.exercises[1].lastTime == nil, "a hold shows its countdown, not last time")
        #expect(run.exercises[2].lastTime == nil, "never logged")
        #expect(run.contentState.load?.lastWeight == 100)
        store.clearGuidedRun()
    }

    // MARK: The intents — the stored run

    /// "+15 s" and "−15 s" from the Lock Screen move the stored rest's end and nothing else.
    @Test func theRestIntentsMoveTheStoredRest() async throws {
        let directory = uniqueAppGroupDirectory()
        let now = Self.wholeSecondNow()
        let start = now.addingTimeInterval(-10)
        #expect(Self.writeResting(from: start, to: now.addingTimeInterval(80), in: directory))

        let added = await GuidedWorkoutIntentRunner.adjustRest(bySeconds: 15, directory: directory)
        #expect(added == .adjusted)
        let longer = try #require(GuidedWorkoutRunStateStore(directory: directory).read())
        #expect(longer.restEndsAt == now.addingTimeInterval(95))
        #expect(longer.restStartedAt == start)
        #expect(longer.isResting && longer.currentSet == 2)

        let taken = await GuidedWorkoutIntentRunner.adjustRest(bySeconds: -15, directory: directory)
        #expect(taken == .adjusted)
        let shorter = try #require(GuidedWorkoutRunStateStore(directory: directory).read())
        #expect(shorter.restEndsAt == now.addingTimeInterval(80))
    }

    /// With no run, during a set, or at the ten-minute cap, the intents say so and leave the file alone.
    @Test func theRestIntentsSayWhyNothingMoved() async throws {
        let directory = uniqueAppGroupDirectory()
        let noRun = await GuidedWorkoutIntentRunner.adjustRest(bySeconds: 15, directory: directory)
        #expect(noRun == .noRunInProgress)

        #expect(GuidedWorkoutRunStateStore(directory: directory).write(Self.run([Self.lift("Bench press")])))
        let working = await GuidedWorkoutIntentRunner.adjustRest(bySeconds: -15, directory: directory)
        #expect(working == .wrongPhase)

        let start = Self.wholeSecondNow().addingTimeInterval(-30)
        let capEnd = start.addingTimeInterval(TimeInterval(GuidedWorkoutRunState.maximumRestSeconds))
        #expect(Self.writeResting(from: start, to: capEnd, in: directory))
        let capped = await GuidedWorkoutIntentRunner.adjustRest(bySeconds: 15, directory: directory)
        #expect(capped == .atLimit)
        let file = try #require(GuidedWorkoutRunStateStore(directory: directory).read())
        #expect(file.restEndsAt == capEnd, "a refused adjustment leaves the file as it was")
    }

    // MARK: The cues follow the new end

    /// The runner's own "+15 s": mirrored for the Lock Screen, the estimate moves, and the rest-end cue
    /// and its background notification are re-armed for the new end.
    @Test func theRunnersAdjustmentReArmsTheRestEndCue() async throws {
        let directory = uniqueAppGroupDirectory()
        let store = makeTestStore(appGroupDirectory: directory)
        let background = RestCueRecorder()
        let cues = Self.director(background)
        store.guidedRunCues = cues
        let session = Self.session("Push", [PrescribedExercise(name: "Bench Press", sets: 3, reps: "8", role: .main, fromCatalog: true)])
        #expect(store.startGuidedRun(session))
        #expect(store.guidedAdjustRest(by: 15) == false, "no rest to adjust mid-set")
        store.guidedMarkSetDone()
        let before = try #require(store.guidedRunState?.restEndsAt)
        let estimate = try #require(store.guidedRunState?.estimatedSecondsRemaining())

        #expect(store.guidedAdjustRest(by: 15))
        let after = try #require(store.guidedRunState?.restEndsAt)
        #expect(after == before.addingTimeInterval(15))
        #expect(store.guidedRunState?.estimatedSecondsRemaining() == estimate + 15)
        #expect(cues.armedCues == [GuidedRunCuePlan.TimedCue(event: .restEnded, fireAt: after)])
        await cues.backgroundSettled()
        #expect(background.schedules.last == [NotificationService.WorkoutCue(kind: .restEnded, fireAt: after)])
        let file = try #require(GuidedWorkoutRunStateStore(directory: directory).read()?.restEndsAt)
        #expect(abs(file.timeIntervalSince(after)) < 1, "mirrored for the Lock Screen's buttons")
        store.clearGuidedRun()
    }

    /// The Lock Screen's "+15 s" reaches the open in-app run at once (the intent's notification), and
    /// that reconcile re-arms the rest-end cue and its background notification for the new end.
    @Test func aLockScreenAdjustmentReArmsTheRestEndCue() async throws {
        let directory = uniqueAppGroupDirectory()
        let store = makeTestStore(appGroupDirectory: directory)
        let background = RestCueRecorder()
        let cues = Self.director(background)
        store.guidedRunCues = cues
        let session = Self.session("Push", [PrescribedExercise(name: "Bench Press", sets: 3, reps: "8", role: .main, fromCatalog: true)])
        #expect(store.startGuidedRun(session))
        store.activateWidgetBridge()
        store.guidedMarkSetDone()
        let before = try #require(store.guidedRunState?.restEndsAt)

        let outcome = await GuidedWorkoutIntentRunner.adjustRest(bySeconds: 15, directory: directory)
        #expect(outcome == .adjusted)
        let after = try #require(GuidedWorkoutRunStateStore(directory: directory).read()?.restEndsAt)
        #expect(after > before)
        // The observer is on the main queue; give it its turn (bounded, no wall clock).
        for _ in 0..<50 where store.guidedRunState?.restEndsAt != after {
            await Task.yield()
        }
        #expect(store.guidedRunState?.restEndsAt == after, "the in-app run never saw the Lock Screen's +15 s")
        #expect(cues.armedCues == [GuidedRunCuePlan.TimedCue(event: .restEnded, fireAt: after)])
        await cues.backgroundSettled()
        #expect(background.schedules.last == [NotificationService.WorkoutCue(kind: .restEnded, fireAt: after)])
        store.clearGuidedRun()
    }

    // MARK: Words — drawn

    /// The drawn load reads like the runner: "105 lb", "95–110 lb", "Last time: 3 × 8 @ 100 lb".
    @Test func theDrawnLoadReadsLikeTheRunner() {
        let load = Self.fullLoad()
        #expect(Self.plain(WorkoutActivityLoadText.weightText(load, locale: Self.english)) == "105 lb")
        #expect(Self.plain(WorkoutActivityLoadText.rangeText(load, locale: Self.english)) == "95–110 lb")
        #expect(Self.plain(WorkoutActivityLoadText.lastTimeLine(load, locale: Self.english)) == "Last time: 3 × 8 @ 100 lb")
        #expect(WorkoutActivityLoadText.drawsWeight(load))
        // The runner's weight panel draws through the same formatter, so the two never disagree.
        #expect(GuidedLoadFormat.weight(105, unit: .pounds)
                == WorkoutActivityLoadText.weight(105, unit: .pounds, width: .abbreviated, locale: .current))
    }

    /// Partial loads draw what they have: no range for a one-weight range, last time without a weight
    /// or without sets.
    @Test func partialLoadsDrawWhatTheyHave() {
        var oneWeight = Self.fullLoad()
        oneWeight.rangeLow = 100
        oneWeight.rangeHigh = 100
        #expect(WorkoutActivityLoadText.rangeText(oneWeight, locale: Self.english) == nil)
        let bodyweight = Load(lastSets: 3, lastReps: "12")
        #expect(Self.plain(WorkoutActivityLoadText.lastTimeLine(bodyweight, locale: Self.english)) == "Last time: 3 × 12")
        #expect(WorkoutActivityLoadText.drawsWeight(bodyweight) == false)
        let weightOnly = Load(lastWeight: 100, lastUnitRaw: "lb")
        #expect(Self.plain(WorkoutActivityLoadText.lastTimeLine(weightOnly, locale: Self.english)) == "Last time: 100 lb")
        #expect(WorkoutActivityLoadText.weightText(Load(), locale: Self.english) == nil)
    }

    /// Numbers and units follow the locale: a German Lock Screen draws "62,5 kg", and a weight with no
    /// unit is a bare number rather than a guessed unit.
    @Test func weightsFollowTheLocale() {
        let german = Locale(identifier: "de_DE")
        let kilos = Self.plain(WorkoutActivityLoadText.weight(62.5, unit: .kilograms, width: .abbreviated, locale: german))
        #expect(kilos?.contains("62,5") == true && kilos?.contains("kg") == true, "\(kilos ?? "nil")")
        #expect(WorkoutActivityLoadText.weight(62.5, unit: nil, width: .abbreviated, locale: german) == "62,5")
        #expect(WorkoutActivityLoadText.unit("kg") == UnitMass.kilograms)
        #expect(WorkoutActivityLoadText.unit("lb") == UnitMass.pounds)
        #expect(WorkoutActivityLoadText.unit("stone") == nil)
    }

    // MARK: Words — spoken

    /// VoiceOver hears the load in words, as one sentence: "Suggested weight 105 pounds, range 95 to
    /// 110 pounds, last time 3 by 8 at 100 pounds".
    @Test func theSpokenLoadIsOneSentenceInWords() throws {
        let load = Self.fullLoad()
        let weight = try #require(Self.plain(WorkoutActivityLoadText.spokenWeight(load, locale: Self.english)))
        let range = try #require(Self.plain(WorkoutActivityLoadText.spokenRange(load, locale: Self.english)))
        let last = try #require(Self.plain(WorkoutActivityLoadText.spokenLastTime(load, locale: Self.english)))
        #expect(weight == "Suggested weight 105 pounds")
        #expect(range == "range 95 to 110 pounds")
        #expect(last == "last time 3 by 8 at 100 pounds")
        let summary = try #require(Self.plain(WorkoutActivityLoadText.spokenSummary(load, locale: Self.english)))
        #expect(summary == Self.plain([weight, range, last].formatted(.list(type: .and, width: .narrow).locale(Self.english))))
        #expect(summary.hasPrefix(weight) && summary.hasSuffix(last))

        var noRange = load
        noRange.rangeLow = nil
        noRange.rangeHigh = nil
        let short = try #require(Self.plain(WorkoutActivityLoadText.spokenSummary(noRange, locale: Self.english)))
        #expect(short.hasPrefix("Suggested weight 105 pounds") && short.hasSuffix("last time 3 by 8 at 100 pounds"))
        #expect(!short.contains("range"))
    }

    /// A weight the lifter picked is not called a suggestion; a bodyweight lift speaks last time alone;
    /// an empty load says nothing.
    @Test func theSpokenLoadNamesWhatItIs() {
        var picked = Self.fullLoad()
        picked.weight = 110
        #expect(Self.plain(WorkoutActivityLoadText.spokenWeight(picked, locale: Self.english)) == "Weight 110 pounds")
        let bodyweight = Load(lastSets: 3, lastReps: "12")
        #expect(Self.plain(WorkoutActivityLoadText.spokenSummary(bodyweight, locale: Self.english)) == "last time 3 by 12")
        let weightOnly = Load(lastWeight: 100, lastUnitRaw: "lb")
        #expect(Self.plain(WorkoutActivityLoadText.spokenLastTime(weightOnly, locale: Self.english)) == "last time 100 pounds")
        #expect(WorkoutActivityLoadText.spokenSummary(Load(), locale: Self.english) == nil)
    }

    /// The rest buttons' spoken names and the runner's lines after a tap — including the two limits,
    /// where nothing on screen moves.
    @Test func theRestButtonsSayWhatTheyDid() {
        #expect(String(localized: GuidedWorkoutAddRestIntent.title) == "Add 15 seconds of rest")
        #expect(String(localized: GuidedWorkoutShortenRestIntent.title) == "Take 15 seconds off the rest")
        let lines = [(true, true), (false, true), (true, false), (false, false)].map {
            String(localized: GuidedRunAnnouncement.restAdjusted(adding: $0.0, moved: $0.1))
        }
        #expect(lines[0] == "Added 15 seconds of rest.")
        #expect(lines[1] == "Took 15 seconds off the rest.")
        #expect(lines[2] == "Your rest is already at its 10-minute limit.")
        #expect(lines[3] == "Your rest is nearly over, so there's nothing to take off.")
    }

    // MARK: Display only

    /// The Live Activity shows a weight and never edits one; compact and minimal stay as they were.
    @Test func theLiveActivityShowsWeightsAndNeverEditsThem() throws {
        let widget = try RepoRoot.source("App/FernletWidgets/WorkoutLiveActivity.swift")
        let intents = try RepoRoot.source("App/FernletWidgets/GuidedWorkoutLiveActivityIntents.swift")
        for source in [widget, intents] {
            for edit in ["selectWeight", "setActualReps", "setEffort", "setOverrideReason", "editGuidedRun"] {
                #expect(!source.contains(edit), "the Live Activity reached a load edit: \(edit)")
            }
        }
        #expect(widget.contains("LOAD RULE"))
        let runState = try RepoRoot.source("App/FernletWidgets/GuidedWorkoutRunState.swift")
        #expect(runState.contains("the Live Activity never edits these"))

        let compact = try #require(Self.section(of: widget, from: "private struct WorkoutIslandCompactTrailing",
                                                to: "private struct WorkoutIslandMinimal"))
        let minimal = try #require(Self.section(of: widget, from: "private struct WorkoutIslandMinimal",
                                                to: "// MARK: - Shared helpers"))
        #expect(!compact.contains("load") && !minimal.contains("load"), "the compact and minimal Island stay uncluttered")
    }

    /// The text of `source` between two markers, or nil when either is gone.
    private static func section(of source: String, from start: String, to end: String) -> String? {
        guard let lower = source.range(of: start)?.upperBound,
              let upper = source.range(of: end, range: lower..<source.endIndex)?.lowerBound else { return nil }
        return String(source[lower..<upper])
    }
}
