//
//  GuidedRunCues.swift
//  Fernlet
//
//  Rest-end and hold-end cues for the guided workout runner (comparison report idea 2, 2026-10-20).
//
//  Before this file the runner was silent: with the phone face-down on a bench nothing said a rest
//  had run out, and a plank hold ended and moved on without a sound. Two halves:
//
//  - In the app, ``GuidedRunCueDirector`` turns the run's own clock (a rest's end, a hold's lead-in and
//    end) and the person's taps into named `FernletFeedbackEvent`s and plays them through FernletUI's
//    `FernletFeedback`, gated by the person's "Workout haptics" / "Workout sounds" switches
//    (``WorkoutCuePreferences``).
//  - In the background, where the app is suspended and can play nothing, the same director keeps one
//    local notification pending for the moment the current rest or hold ends
//    (`NotificationService.replaceWorkoutCues`). It never asks for permission: when notifications are
//    not already allowed, the background half simply does nothing. A Live Activity alert cannot do this
//    job — an `AlertConfiguration` rides an update, and nothing runs the app at the rest's end to send one.
//
//  In-session only, never a nudge: every cue belongs to a run the person started and is cancelled the
//  moment it finishes, is abandoned or is cleared. VoiceOver keeps its own channel: the runner's spoken
//  lines stay in `GuidedRunAnnouncement` (which gained one, "Hold now.", at the moment a lead-in ends,
//  so a VoiceOver user with haptics off still hears when to start holding), and a cue notification
//  that lands while the app is open is kept quiet by `FernletNotificationDelegate`, so nothing is said
//  twice. While a run is live the runner sheet keeps the screen awake (Cooking's `keepsScreenAwake`),
//  so a propped-up phone does not lock mid-rest and silence the in-app cues.
//
//  Spoken cues (idea 11) ride the same director: the same moments, the same foreground rule and the
//  same lateness guard, with the words in `GuidedRunSpokenCue` and the voice in FernletUI's
//  `FernletSpeaker`, behind their own "Spoken cues" switch (off by default). Never in the background
//  and never in a notification: a locked phone gets the chime-or-buzz notification above, not speech.
//

import Foundation
import UIKit
import AppServices
import FernletUI

/// The runner's cue rules as pure functions of the run state: which cue an in-app move plays, which
/// cues the run's own clock is due to play, and which the background must carry.
///
/// No clock, no store, no UIKit — each rule is checked in `GuidedRunCueTests` against real
/// ``GuidedWorkoutRunState`` transitions.
enum GuidedRunCuePlan {
    /// What moved the run in the app.
    enum Cause: Equatable {
        /// "Done set", "Next" or "Finish workout".
        case setDone
        /// "Skip rest", "Skip to next exercise", "Skip warm-up" or "Skip cool-down".
        case skip
        /// The runner moved a timed step on because its hold ran out.
        case holdRanOut
    }

    /// A cue due at a moment on the run's own clock.
    struct TimedCue: Equatable {
        /// What happens then.
        let event: FernletFeedbackEvent
        /// When.
        let fireAt: Date
    }

    /// How late a timed cue may still play. Past this, the moment has gone — the app was suspended
    /// through it, and the background notification (if any) already said so — and the cue is dropped
    /// rather than buzzing about a rest that ended minutes ago.
    static let lateTolerance: TimeInterval = 2

    /// The bundled file of silence a background cue carries when haptics are on and sounds are off.
    /// A notification with no sound at all is silent AND still; with a silent sound, the system plays
    /// its own notification haptic (under the person's Sounds & Haptics settings) and no tone. FROZEN:
    /// the file's name in the app bundle.
    static let silentNotificationSound = "fernlet-cue-silent.wav"

    /// The one cue for an in-app move from `before` to `after`, or nil.
    ///
    /// Only a live run cues (`before` working or resting), and only a real move does. Precedence,
    /// highest first, so one move never buzzes twice: a natural finish, then a new block, then what the
    /// move itself was — a logged set, or a hold that ran out. Skips cue only when they change the
    /// block (or finish); an abandon is silent.
    static func transitionCue(
        from before: GuidedWorkoutRunState?,
        to after: GuidedWorkoutRunState?,
        cause: Cause
    ) -> FernletFeedbackEvent? {
        guard let before, before.isWorking || before.isResting, let after, after != before else { return nil }
        if after.isFinishedNaturally { return .workoutFinished }
        guard !after.isDone else { return nil }
        if after.currentBlock != before.currentBlock { return .blockChanged }
        switch cause {
        case .setDone: return .setLogged
        case .holdRanOut: return .holdEnded
        case .skip: return nil
        }
    }

    /// The cues the run's own clock is due to play in the app, in time order.
    ///
    /// A rest cues its end (a zero-length rest has none). A timed step cues the end of its lead-in and
    /// the end of its hold — except the hold's end while the runner sheet is driving it
    /// (`sheetDrivesHoldEnd`): the sheet moves the step on at that instant and plays the one cue that
    /// move deserves, which may outrank "hold ended" (a new block, a finish). A step with no lead-in
    /// (a cardio segment that follows straight on) has no lead-in end to cue: its start IS the move
    /// that just cued, so a segment change buzzes once, not twice. Nothing else cues.
    static func timedCues(for state: GuidedWorkoutRunState?, sheetDrivesHoldEnd: Bool) -> [TimedCue] {
        guard let state else { return [] }
        if state.isResting {
            return restEnd(of: state).map { [TimedCue(event: .restEnded, fireAt: $0)] } ?? []
        }
        guard let window = state.holdWindow else { return [] }
        var cues: [TimedCue] = []
        if (state.currentExercise?.holdLeadIn ?? GuidedWorkoutRunState.holdLeadInSeconds) > 0 {
            cues.append(TimedCue(event: .holdStarted, fireAt: window.lowerBound))
        }
        if !sheetDrivesHoldEnd { cues.append(TimedCue(event: .holdEnded, fireAt: window.upperBound)) }
        return cues
    }

    /// The cue a phone in the background should get: the current rest's end or the current hold's end
    /// — a cardio segment's as a segment's, whose words say a timed part ran out rather than a hold.
    /// The lead-in's end stays an in-app cue only — five seconds after a step starts is too soon, and
    /// too often, for a notification.
    static func backgroundCues(for state: GuidedWorkoutRunState?) -> [NotificationService.WorkoutCue] {
        guard let state else { return [] }
        if state.isResting {
            return restEnd(of: state).map { [NotificationService.WorkoutCue(kind: .restEnded, fireAt: $0)] } ?? []
        }
        guard let window = state.holdWindow else { return [] }
        let kind: NotificationService.WorkoutCueKind = state.currentExercise?.segment == nil ? .holdEnded : .segmentEnded
        return [NotificationService.WorkoutCue(kind: kind, fireAt: window.upperBound)]
    }

    /// Whether a cue due at `fireAt` may still play at `now` (see ``lateTolerance``).
    static func isOnTime(_ fireAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fireAt) <= lateTolerance
    }

    /// The sound a background cue carries: the in-app chime when sounds are on, the silent file when
    /// only haptics are (so the system's notification haptic still plays), nothing when both are off.
    static func notificationSound(for preferences: FernletFeedbackPreferences) -> String? {
        if preferences.soundsEnabled { return FernletSound.chime.fileName }
        return preferences.hapticsEnabled ? silentNotificationSound : nil
    }

    /// The end of a resting run's rest window, or nil when there is no window or it is empty.
    private static func restEnd(of state: GuidedWorkoutRunState) -> Date? {
        guard state.isResting, let start = state.restStartedAt, let end = state.restEndsAt, end > start else {
            return nil
        }
        return end
    }
}

/// Plays the guided runner's cues: the run's clock in the app, the person's taps, and the background
/// notification for a phone that is put away.
///
/// Owned by `FernletStore` (`guidedRunCues`) and told about EVERY change of the run — in-app, Lock
/// Screen, reconcile, finish, abandon — through ``runChanged(to:)``, so its timers and its pending
/// notification always describe the run as it is now. The runner sheet adds the taps through
/// ``transition(from:to:cause:)``.
///
/// **Invariants**
///
/// - *Only a live run cues.* No run, a finished or an abandoned run arms nothing and cancels the
///   background cue; a transition cue needs a working or resting run before the move.
/// - *The person's switches, then the system's.* Every play reads ``WorkoutCuePreferences`` at that
///   moment; FernletFeedback drops a cue whose channels are off, and UIKit honours the system haptics
///   setting under that. Both switches off schedules no notification either.
/// - *Only while the app is in front.* Nothing plays unless the app is active; in the background the
///   notification is the cue, and a timer that wakes late (the app was suspended) is dropped by
///   ``GuidedRunCuePlan/isOnTime(_:now:)`` instead of buzzing about a moment that has passed.
/// - *One cue per moment.* While the runner sheet drives a hold's end (``sheetDrivesHoldEnd``) this
///   director does not cue it as well; the sheet's own move carries the cue.
/// - *Spoken cues are opt-in and in front only.* A moment is spoken (``GuidedRunSpokenCue``) only
///   with the "Spoken cues" switch on and the app active, at the same instant as its haptic — a
///   timed one only while on time, and once. With VoiceOver on it goes through the announcer, and
///   only while the runner sheet is not on screen (``runnerOnScreen``): on screen, the sheet's own
///   VoiceOver lines already say every moment, and a move's line carries the weight
///   (``voiceOverAddition(from:to:)``), so VoiceOver never hears a moment twice.
///
/// **Concurrency:** main-actor. The timer is one `Task` re-armed on change; background scheduling is a
/// chain of `Task`s so two quick moves cannot land out of order on the notification center.
@MainActor
final class GuidedRunCueDirector {
    /// Replaces the pending background cue: the cues to schedule and the sound file they carry.
    typealias BackgroundScheduler = @MainActor ([NotificationService.WorkoutCue], String?) async -> Void

    /// One background schedule, compared so an unchanged run does not touch the notification center.
    private struct BackgroundPlan: Equatable {
        /// The cues pending.
        let cues: [NotificationService.WorkoutCue]
        /// The sound they carry.
        let sound: String?
    }

    private let feedback: FernletFeedback
    private let preferences: @MainActor () -> FernletFeedbackPreferences
    private let isAppActive: @MainActor () -> Bool
    private let scheduleBackground: BackgroundScheduler
    private let speaker: FernletSpeaker
    private let spokenCuesOn: @MainActor () -> Bool

    /// The run as of the last ``runChanged(to:)``.
    private var run: GuidedWorkoutRunState?
    /// The timed cues the current timer is waiting on, in order. Read by tests.
    private(set) var armedCues: [GuidedRunCuePlan.TimedCue] = []
    private var timer: Task<Void, Never>?
    /// The last timed cue played, so a re-arm moments after it (the sheet closing just as a hold
    /// starts) never plays the same moment twice.
    private var lastTimedCue: GuidedRunCuePlan.TimedCue?
    /// What the notification center was last asked to hold; nil until the first sync, so the first
    /// one always runs and clears anything a previous process left pending.
    private var scheduledPlan: BackgroundPlan?
    private var backgroundTask: Task<Void, Never>?

    /// True while the runner sheet's working view is on screen: it moves a timed step on when its hold
    /// ends and plays that move's cue, so this director leaves the hold's end to it.
    var sheetDrivesHoldEnd = false {
        didSet {
            guard sheetDrivesHoldEnd != oldValue else { return }
            rearm()
        }
    }

    /// True while the runner sheet is on screen showing the live run. Its own VoiceOver lines then say
    /// every timed moment ("Rest's over…", "Hold now.") and every move, so under VoiceOver a spoken
    /// cue adds nothing at those moments; with the sheet closed, the announcer says the spoken line.
    var runnerOnScreen = false

    /// Creates a director. Every dependency is injectable; the defaults are production.
    ///
    /// - Parameters:
    ///   - feedback: The haptic and sound player; nil means the production player.
    ///   - preferences: The person's switches, read at every play.
    ///   - isAppActive: Whether the app is in front, read at every play.
    ///   - scheduleBackground: Replaces the pending background cue.
    ///   - speaker: The spoken-cue player; nil means `FernletSpeaker.system`.
    ///   - spokenCuesOn: Whether "Spoken cues" is on, read at every spoken moment; nil reads
    ///     ``WorkoutCuePreferences/spokenEnabled(in:)``.
    init(
        feedback: FernletFeedback? = nil,
        preferences: @escaping @MainActor () -> FernletFeedbackPreferences = { WorkoutCuePreferences.current() },
        isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        scheduleBackground: @escaping BackgroundScheduler = { cues, sound in
            await NotificationService.replaceWorkoutCues(cues, soundFileName: sound)
        },
        speaker: FernletSpeaker? = nil,
        spokenCuesOn: (@MainActor () -> Bool)? = nil
    ) {
        self.feedback = feedback ?? .system
        self.preferences = preferences
        self.isAppActive = isAppActive
        self.scheduleBackground = scheduleBackground
        self.speaker = speaker ?? .system
        self.spokenCuesOn = spokenCuesOn ?? { WorkoutCuePreferences.spokenEnabled() }
    }

    /// The in-app timer and the pending background scheduling end with the director (the memory wall's ML1).
    isolated deinit {
        timer?.cancel()
        backgroundTask?.cancel()
    }

    /// The run changed (or went away): re-arm the in-app timer and replace the background cue.
    func runChanged(to state: GuidedWorkoutRunState?) {
        run = state
        rearm()
        syncBackground()
    }

    /// Plays the cue for an in-app move, if it earns one (``GuidedRunCuePlan/transitionCue(from:to:cause:)``),
    /// and says the move aloud when spoken cues are on (``GuidedRunSpokenCue/move(from:to:cause:)``).
    ///
    /// Every move comes from the runner sheet, which announces it to VoiceOver itself, so the spoken
    /// line carries nothing for VoiceOver here (the sheet's line gains ``voiceOverAddition(from:to:)``).
    /// A skip that earns no haptic can still be spoken: it lands on a new step worth naming.
    func transition(from before: GuidedWorkoutRunState?, to after: GuidedWorkoutRunState?, cause: GuidedRunCuePlan.Cause) {
        if let event = GuidedRunCuePlan.transitionCue(from: before, to: after, cause: cause) {
            play(event)
        }
        speak(GuidedRunSpokenCue.move(from: before, to: after, cause: cause), toVoiceOver: false)
    }

    /// Says the run's first step aloud as it starts (``GuidedRunSpokenCue/start(_:)``), when spoken cues
    /// are on and the app is in front — "First: Goblet squat. Suggested weight 35 pounds." The store
    /// calls it once, from its Start (`FernletStore.startGuidedRun`), never on a resume. VoiceOver hears
    /// the runner screen itself, so nothing is posted to it.
    func started(_ state: GuidedWorkoutRunState) {
        speak(GuidedRunSpokenCue.start(state), toVoiceOver: false)
    }

    /// What the runner sheet's own VoiceOver line for a move gains while spoken cues are on: the new
    /// lift's suggested weight and last time, the one thing that line does not already say. Nil when
    /// spoken cues are off or the move lands on no weight.
    func voiceOverAddition(from before: GuidedWorkoutRunState?, to after: GuidedWorkoutRunState?) -> String? {
        guard spokenCuesOn() else { return nil }
        return GuidedRunSpokenCue.loadClause(from: before, to: after)
    }

    /// Waits for the current timer to finish (or be cancelled). A test seam: with every cue already
    /// due, the timer never sleeps, so this returns once it has played them.
    func timedCuesSettled() async {
        await timer?.value
    }

    /// Waits for every background schedule started so far. A test seam.
    func backgroundSettled() async {
        await backgroundTask?.value
    }

    /// Plays one event through the player, if the app is in front and the switches allow it.
    private func play(_ event: FernletFeedbackEvent) {
        guard isAppActive() else { return }
        feedback.play(event, preferences: preferences())
    }

    /// Says `words` through the speaker, if there are any, the app is in front and spoken cues are on.
    /// `toVoiceOver` is whether VoiceOver should hear them too — false when the runner sheet already
    /// says this moment to VoiceOver itself.
    private func speak(_ words: String?, toVoiceOver: Bool) {
        guard let words, isAppActive(), spokenCuesOn() else { return }
        speaker.say(FernletSpokenLine(text: words, voiceOverText: toVoiceOver ? words : nil))
    }

    /// Re-arms the timer when the cues due have changed; an unchanged run keeps the timer it has, so
    /// an edit that does not move the clock (a weight pick) never replays or drops a cue.
    private func rearm() {
        let cues = GuidedRunCuePlan.timedCues(for: run, sheetDrivesHoldEnd: sheetDrivesHoldEnd)
        guard cues != armedCues else { return }
        armedCues = cues
        timer?.cancel()
        guard !cues.isEmpty else {
            timer = nil
            return
        }
        timer = Task { [weak self] in
            guard let self else { return }
            await self.fire(cues)
        }
    }

    /// Sleeps to each cue in turn and plays it if it is still on time. Bounded: at most two cues (a
    /// hold's lead-in end and its end).
    private func fire(_ cues: [GuidedRunCuePlan.TimedCue]) async {
        for cue in cues {
            let wait = cue.fireAt.timeIntervalSinceNow
            if wait > 0 {
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, cue != lastTimedCue,
                  GuidedRunCuePlan.isOnTime(cue.fireAt, now: Date()) else { continue }
            lastTimedCue = cue
            play(cue.event)
            speak(GuidedRunSpokenCue.timed(cue.event, in: run), toVoiceOver: !runnerOnScreen)
        }
    }

    /// Replaces the background cue when what it should hold has changed, chained behind the previous
    /// replacement so the notification center sees the moves in order.
    private func syncBackground() {
        let switches = preferences()
        let cues = switches.isSilent ? [] : GuidedRunCuePlan.backgroundCues(for: run)
        let sound = GuidedRunCuePlan.notificationSound(for: switches)
        let plan = BackgroundPlan(cues: cues, sound: sound)
        guard plan != scheduledPlan else { return }
        scheduledPlan = plan
        let previous = backgroundTask
        let schedule = scheduleBackground
        backgroundTask = Task {
            await previous?.value
            await schedule(cues, sound)
        }
    }
}
