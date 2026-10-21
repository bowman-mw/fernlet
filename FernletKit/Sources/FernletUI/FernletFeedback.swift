//
//  FernletFeedback.swift
//  FernletUI
//
//  The app's ONE seam for haptic and sound cues (workout runner round, 2026-10-20; app-wide pass the
//  same day).
//
//  The guided workout runner was silent: a rest ended or a plank hold ran out with the phone face-down
//  on a bench and nothing said so. This file gives every such moment a NAME (``FernletFeedbackEvent``)
//  and one place that decides what each name feels and sounds like, so the next surface that wants a
//  cue adds a case and a row to the switches below instead of inventing its own generator call. The
//  app-wide pass (`Docs/Handoff/Sounds-Haptics-Investigation.md` §3) did exactly that: the runner's
//  cases were joined by the app's touches, outcomes and session moments, each with a ``scope`` that
//  the app-wide Haptics level (``FernletHapticsLevel``, All / Fewer / Off) reads.
//
//  FOUR RULES, all load-bearing:
//
//  1. EVENTS, NOT GENERATORS. Callers name what happened, never which haptic to play. The mapping lives
//     in ``FernletFeedbackEvent/haptic`` and ``FernletFeedbackEvent/sound`` and nowhere else, and every
//     intensity lives in ``FernletFeedback``'s renderer, so tuning a feel on a device is a one-file edit.
//     `FeedbackBoundaryTests` (FernletTests) fails the build's test run on a feedback generator, an
//     audio player or a `.sensoryFeedback` anywhere else in the shipping tree.
//
//  2. THE PERSON'S SWITCHES WIN. Every play takes a ``FernletFeedbackPreferences``; an event whose
//     channels are all switched off is dropped before anything reaches UIKit. Those preferences come
//     from ONE resolver, ``FernletFeedbackPreferences/resolved(haptics:sounds:in:)``, which ANDs the
//     calling surface's own switch (Workout haptics, breathing's Haptics) with the app-wide level. The
//     system's own Settings › Sounds & Haptics switch is honoured underneath that by
//     `UIFeedbackGenerator` itself. The one Core Haptics pattern ("time's up", report C4) has no such
//     promise from Apple, so its renderer reads the app-wide level again at the moment it plays: Off
//     silences it whatever the cue says.
//
//  3. NEVER TAKE THE AUDIO. Sounds play through AudioServices system sounds: they follow the ring/silent
//     switch (silent means no sound), play at the ringer volume, and mix with whatever is playing — no
//     `AVAudioSession` category is set, so the person's music is never paused, ducked or interrupted.
//     The files are short and authored quiet (see ``FernletSound``). The Core Haptics engine plays
//     haptics only (`playsHapticsOnly`), so it never touches the audio session either.
//
//  4. NO COPY. Nothing here is ever spoken or shown, so this file holds no user-visible string. Spoken
//     equivalents stay with ``FernletAnnouncer``; the opt-in spoken cues (``FernletSpeaker``,
//     `FernletSpeech.swift`) sit beside this seam, said at the same moments, rather than inside it.
//

import AudioToolbox
import CoreHaptics
import os
import SwiftUI
import UIKit

// MARK: - Vocabulary

/// A moment that can carry a haptic or sound cue.
///
/// The cases are *events*, not feelings: a call site says what happened ("the rest ran out", "the
/// water landed") and the mapping below decides how that feels. Add a case — and its row in
/// ``haptic``, ``sound``, ``scope`` and ``minimumInterval`` — for any new surface rather than calling a
/// feedback generator directly. The raw values are stable identifiers for logs and tests, never
/// display text.
///
/// **What gets no event at all** (the report's "never" list, §3.8): passive arrivals (AI suggestions,
/// imports, a companion mood change, milestone coins, a timed release, a peer appearing), scrolling,
/// navigation and presentation, anything about absence, any goal, streak or personal best, a second
/// haptic on a system control that has its own (Toggle, Picker, DatePicker, swipe actions, the system
/// camera), unlock success (it can never become a duress tell), and the companion while it is settled.
public nonisolated enum FernletFeedbackEvent: String, CaseIterable, Sendable {
    // MARK: The guided workout runner

    /// A rest's countdown reached zero. The rest itself waits for the person; this only says time's up.
    case restEnded
    /// A timed step's five-second "Get into position" lead-in turned into "Hold".
    case holdStarted
    /// A timed hold (a stretch, a plank, a carry) ran out.
    case holdEnded
    /// The person tapped "Done set" and the set was logged — a light acknowledgement under the thumb.
    case setLogged
    /// The run moved into a new block (warm-up → activation → lifting → cardio → cool-down).
    case blockChanged
    /// The run finished naturally and was logged.
    case workoutFinished
    /// During guided cardio, the live heart rate has sat outside the part's target zone for a while —
    /// the opt-in "Zone nudges" cue. A light tap, never a sound: a suggestion, not an alarm.
    case zoneDrift

    // MARK: Touches (dropped at the "Fewer" level)

    /// A choice or a value changed on a custom control (a picker, a chip, a weight step).
    case tick
    /// A one-tap log or check-off landed in place (water +1, the quick mood chip, a heart sent).
    case logged
    /// The tap can't go further (water at its cap, a weight at its floor).
    case limit
    /// Something was reordered, added or removed in a list.
    case moved
    /// A custom long press was recognized.
    case held

    // MARK: Outcomes

    /// A scanner got the code (a barcode, a QR code). What the code MEANS is a separate event.
    case captured
    /// A result the person waited for, or one nothing else confirms, landed (a meal logged, a
    /// passcode set, photos saved).
    case done
    /// It landed, with something the person needs to read.
    case caveat
    /// It didn't happen. Every announced error carries this beside its words.
    case failed
    /// A friend was linked or verified in person.
    case friendHere

    // MARK: Session moments

    /// A guided step or phase changed (a breathing phase).
    case pace
    /// The cooking timer ran out — the same "time's up" as a rest or a hold.
    case timerEnded
    /// A session chat message arrived while the chat was closed. Rate-limited (``minimumInterval``):
    /// peers set the pace, so a burst plays once.
    case messageIn
    /// The disposable camera's wheel clicked past one detent.
    case windDetent
    /// The disposable camera's wheel reached the end: the camera is armed.
    case wound
    /// The disposable camera's shutter.
    case shutter

    /// The haptic this event plays when haptics are on. Every event has one.
    ///
    /// The three timer endings share ``FernletHaptic/attention`` on purpose: "a timer you were waiting
    /// on ran out" should feel the same whether it was a rest, a hold or the cooking timer. A logged set
    /// keeps the runner's light impact; whether it and ``logged`` should share one feel is a device
    /// check (`Docs/Handoff/Sounds-Haptics-Investigation.md` §8).
    public var haptic: FernletHaptic {
        switch self {
        case .restEnded, .holdEnded, .timerEnded: .attention
        case .holdStarted, .held: .firm
        case .setLogged, .zoneDrift: .light
        case .blockChanged, .friendHere: .heavy
        case .workoutFinished, .done: .success
        case .tick: .selection
        case .logged: .soft
        case .limit: .rigidLimit
        case .moved: .lightTap
        case .captured: .firmCatch
        case .caveat: .warning
        case .failed: .error
        case .pace: .softPulse
        case .messageIn: .softKnock
        case .windDetent: .detent
        case .wound, .shutter: .rigid
        }
    }

    /// The quiet sound this event plays when sounds are on, or nil for an event that stays silent.
    ///
    /// Only session moments may carry a sound, and only the timers and the runner's steps do: a sound
    /// can be heard by the room and a haptic can't, so touches, outcomes (which include every private
    /// surface's errors), the in-person session and the camera stay silent whatever a caller passes.
    /// A logged set is silent: the person just tapped, so a sound would only echo the tap. A zone
    /// nudge is silent too: a heart rate drifting a little is never worth a sound over someone's music.
    /// The cooking timer's chime plays only when the cook turned its "Timer sound" switch on (report
    /// C1, the app's `CookingCuePreferences`).
    public var sound: FernletSound? {
        switch self {
        case .restEnded, .holdEnded, .blockChanged, .workoutFinished, .timerEnded: .chime
        case .holdStarted: .tick
        case .setLogged, .zoneDrift, .tick, .logged, .limit, .moved, .held, .captured, .done, .caveat,
             .failed, .friendHere, .pace, .messageIn, .windDetent, .wound, .shutter: nil
        }
    }

    /// Which part of the app-wide Haptics level this event answers to (``FernletHapticsLevel``).
    ///
    /// "Fewer" drops ``FernletFeedbackScope/touch`` — the small taps under the thumb, which some people
    /// find fussy — and keeps results and timers.
    public var scope: FernletFeedbackScope {
        switch self {
        case .setLogged, .tick, .logged, .limit, .moved, .held: .touch
        case .captured, .done, .caveat, .failed, .friendHere: .outcome
        case .restEnded, .holdStarted, .holdEnded, .blockChanged, .workoutFinished, .zoneDrift, .pace,
             .timerEnded, .messageIn, .windDetent, .wound, .shutter: .session
        }
    }

    /// The shortest time between two plays of this event, or nil when every play counts.
    ///
    /// A chat message's pace is set by the peers, not the person, so a burst plays once per ten
    /// seconds; back-to-back water taps get one tap each but never a buzz-roll.
    public var minimumInterval: Duration? {
        switch self {
        case .messageIn: .seconds(10)
        case .logged: .milliseconds(150)
        case .restEnded, .holdStarted, .holdEnded, .setLogged, .blockChanged, .workoutFinished, .zoneDrift,
             .tick, .limit, .moved, .held, .captured, .done, .caveat, .failed, .friendHere, .pace,
             .timerEnded, .windDetent, .wound, .shutter: nil
        }
    }
}

/// Which kind of moment an event is, for the app-wide Haptics level.
public nonisolated enum FernletFeedbackScope: String, CaseIterable, Sendable {
    /// A small acknowledgement of the person's own tap, in place.
    case touch
    /// A result: it worked, it worked with a caveat, it didn't, a code was caught, a friend is here.
    case outcome
    /// A moment in a session the person started: a timer running out, a step changing, the camera.
    case session
}

/// The app-wide Haptics level: Settings › Your day › Sounds & haptics (owner's decision 2,
/// 2026-10-20, "Like the three way").
///
/// It sits ABOVE each surface's own switch (Workout haptics, breathing's Haptics); a haptic plays only
/// when both allow it (``FernletFeedbackPreferences/resolved(haptics:sounds:in:)``). It governs
/// haptics only: a surface's sounds keep their own switch, and the ring/silent switch still wins.
///
/// **Device-local `UserDefaults`, never synced** — how a phone should feel belongs to the phone in
/// hand, as iOS keeps its own Sounds & Haptics per device. The key and the raw values are FROZEN
/// persisted tokens. "Delete everything" keeps the key (`Docs/PrivacyWipeCoverage.md`): a preference,
/// not a record.
///
/// This is the one preference this module reads, and ``current(in:)`` is the one place it is read:
/// every module that plays a cue — the app, `FernletLockUI` — must see the same level, and this is
/// the lowest module they share. The player itself still reads nothing.
public nonisolated enum FernletHapticsLevel: String, CaseIterable, Sendable {
    /// Every haptic Fernlet has.
    case all
    /// Results and timers only: the small touch taps are dropped.
    case fewer
    /// No haptics anywhere in Fernlet.
    case off

    /// The `UserDefaults` key. FROZEN.
    public static let storageKey = "fernlet.feedback.haptics"

    /// The level until the person changes it.
    public static let defaultLevel: FernletHapticsLevel = .all

    /// Whether an event of `scope` may play a haptic at this level.
    public func allows(_ scope: FernletFeedbackScope) -> Bool {
        switch self {
        case .all: true
        case .fewer: scope != .touch
        case .off: false
        }
    }

    /// The person's level now, falling back to ``defaultLevel`` for a level never set or a stored
    /// value this build doesn't know.
    public static func current(in defaults: UserDefaults = .standard) -> FernletHapticsLevel {
        guard let raw = defaults.string(forKey: storageKey) else { return defaultLevel }
        return FernletHapticsLevel(rawValue: raw) ?? defaultLevel
    }
}

/// The haptic vocabulary, one case per distinct feel.
///
/// Each case is played by a `UIFeedbackGenerator` (``FernletFeedback`` renders them, and its renderer
/// holds every intensity), which plays nothing when the system haptics setting is off or the app is
/// not in the foreground — all but ``attention``, which is Fernlet's one Core Haptics pattern and
/// falls back to generator impacts. Only patterns that play on iPhone exist here: SwiftUI's `.increase`,
/// `.decrease`, `.start`, `.stop` and `.levelChange` play only on other platforms, so none of them is
/// ever a feel.
public nonisolated enum FernletHaptic: String, CaseIterable, Sendable {
    /// A light impact: an acknowledgement under the thumb.
    case light
    /// A medium impact: "start now", or a long press caught.
    case firm
    /// A heavy impact: the session moved on to something new, or a friend is here.
    case heavy
    /// "Time's up" for a timer that ran out: three transient taps rising from soft to firm in about a
    /// quarter of a second (``FernletFeedback/attentionPattern``), played through Core Haptics (report
    /// C4) — never a continuous buzz.
    ///
    /// Where Core Haptics can't play it — hardware without haptics, an app extension, or an engine
    /// that fails to start or play — the same moment falls back to the pair it replaced: two heavy
    /// impacts at 0.8 intensity, 150 ms apart (``FernletFeedback/attentionIntensity``,
    /// ``FernletFeedback/attentionGap``). Either way it is ONE cue: callers name the case and never
    /// learn which renderer played it.
    ///
    /// Deliberately NOT `UINotificationFeedbackGenerator`'s `.warning` pattern: app-wide, `.warning`
    /// is reserved for "it worked, with a caveat", and a rest running out is not a caveat.
    case attention
    /// The success notification pattern: a result that landed.
    case success
    /// The system selection tick: a value changed.
    case selection
    /// A soft impact at half strength: a log that landed in place.
    case soft
    /// A soft impact at 0.6: a breathing phase (the pacer's tap since it was built).
    case softPulse
    /// A soft impact at 0.7: a chat message arrived.
    case softKnock
    /// A rigid impact at 0.35: a small "can't".
    case rigidLimit
    /// A light impact at 0.6: something moved.
    case lightTap
    /// A medium impact at 0.7: a code caught.
    case firmCatch
    /// The warning notification pattern: it worked, with a caveat.
    case warning
    /// The error notification pattern: it didn't happen.
    case error
    /// A light impact at 0.55: one detent of the camera's wheel.
    case detent
    /// A full-strength rigid impact: the camera armed, the shutter.
    case rigid
}

/// One transient tap in a Core Haptics pattern: when it lands, how strong it is and how crisp.
///
/// Transient only, by construction — there is no duration to give — so no pattern built from these
/// can ever become the continuous buzz the HIG warns against.
public nonisolated struct FernletHapticTap: Equatable, Sendable {
    /// Seconds from the pattern's start.
    public let time: TimeInterval
    /// Strength, 0 (nothing) to 1 (full).
    public let intensity: Float
    /// Crispness, 0 (round and soft) to 1 (sharp and firm).
    public let sharpness: Float

    /// Creates a tap.
    public init(time: TimeInterval, intensity: Float, sharpness: Float) {
        self.time = time
        self.intensity = intensity
        self.sharpness = sharpness
    }
}

/// Which renderer plays ``FernletHaptic/attention``.
public nonisolated enum FernletAttentionRenderer: String, Sendable {
    /// The Core Haptics pattern, ``FernletFeedback/attentionPattern``.
    case coreHaptics
    /// The two heavy impacts it replaced: the fallback wherever Core Haptics can't play.
    case impacts

    /// The renderer for a process: Core Haptics only on hardware that supports it, and never in an
    /// app extension — a widget or the Messages extension never plays a cue, so it must never pay for
    /// an engine either. A failure at play time falls back as well; that is decided where it happens.
    ///
    /// - Parameters:
    ///   - supportsHaptics: `CHHapticEngine.capabilitiesForHardware().supportsHaptics`.
    ///   - inAppExtension: Whether this process is an app extension (its bundle is an `.appex`).
    public static func choose(supportsHaptics: Bool, inAppExtension: Bool) -> FernletAttentionRenderer {
        supportsHaptics && !inAppExtension ? .coreHaptics : .impacts
    }
}

/// The cue sounds, each a short, quiet file bundled with the app.
///
/// The raw value is the file's base name and is FROZEN: the same files are named by the app's
/// background cue notifications (`UNNotificationSound(named:)`), and like fonts (``FernletFontName``)
/// they ship in the APP bundle and are resolved by name from here. The files are plain sine tones
/// written for Fernlet (22.05 kHz mono 16-bit PCM WAV): the chime is C6 with a soft G6 for half a
/// second at about −14 dBFS, the tick one 90 ms A6 blip a little quieter.
public nonisolated enum FernletSound: String, CaseIterable, Sendable {
    /// The soft two-note chime for a timer that ran out or a session step that moved on.
    case chime = "fernlet-cue-chime"
    /// The short tick for "hold now".
    case tick = "fernlet-cue-tick"

    /// The extension every cue sound file carries.
    public static let fileExtension = "wav"

    /// The bundled file's name with its extension — what `UNNotificationSound(named:)` takes.
    public var fileName: String { "\(rawValue).\(Self.fileExtension)" }
}

/// Which feedback channels the person has switched on for a surface, under the app-wide level.
///
/// The surface's own switches are read by the caller from wherever that surface keeps them (the
/// workout runner's are device-local `UserDefaults`, `WorkoutCuePreferences` in the app; breathing's
/// is the `fernlet.breathing.haptics` switch on its screen). Production callers build the value through
/// ``resolved(haptics:sounds:in:)``, the one resolver, so the app-wide level is never forgotten; the
/// memberwise init stays for tests and for surfaces' stored drafts.
public nonisolated struct FernletFeedbackPreferences: Equatable, Sendable {
    /// The surface's own haptics switch.
    public var hapticsEnabled: Bool
    /// The surface's own sounds switch.
    public var soundsEnabled: Bool
    /// The app-wide Haptics level the surface's switch sits under.
    public var hapticsLevel: FernletHapticsLevel

    /// Creates a preference set. Both channels are explicit: each surface owns its own defaults. The
    /// level defaults to ``FernletHapticsLevel/all`` — a stored draft of a surface's switches.
    public init(hapticsEnabled: Bool, soundsEnabled: Bool, hapticsLevel: FernletHapticsLevel = .all) {
        self.hapticsEnabled = hapticsEnabled
        self.soundsEnabled = soundsEnabled
        self.hapticsLevel = hapticsLevel
    }

    /// The ONE resolver: a surface's own switches ANDed with the app-wide Haptics level, read now.
    ///
    /// Read at play time, never cached, so a change in Settings reaches a session already running.
    /// When the level is ``FernletHapticsLevel/off`` the result's ``hapticsEnabled`` is false too, so
    /// a check that only knows the surface switch (the runner's background cue) stays honest.
    ///
    /// - Parameters:
    ///   - haptics: The surface's own haptics switch. A surface with none passes the default, on.
    ///   - sounds: The surface's own sounds switch. Off unless the surface has one and it is on.
    ///   - defaults: Where the level is read from; tests pass a private suite.
    public static func resolved(
        haptics: Bool = true,
        sounds: Bool = false,
        in defaults: UserDefaults = .standard
    ) -> FernletFeedbackPreferences {
        let level = FernletHapticsLevel.current(in: defaults)
        return FernletFeedbackPreferences(
            hapticsEnabled: haptics && level != .off,
            soundsEnabled: sounds,
            hapticsLevel: level
        )
    }

    /// Whether `event`'s haptic may play: the surface switch is on AND the level allows its scope.
    public func allowsHaptic(for event: FernletFeedbackEvent) -> Bool {
        hapticsEnabled && hapticsLevel.allows(event.scope)
    }

    /// Both channels are off: nothing should be played or scheduled at all.
    public var isSilent: Bool { !soundsEnabled && (!hapticsEnabled || hapticsLevel == .off) }
}

/// One cue exactly as it leaves the seam: the event plus what will actually play, after the
/// person's switches were applied.
///
/// Tests record these instead of watching UIKit, which never reports back what it played.
public nonisolated struct FernletFeedbackCue: Equatable, Sendable {
    /// What happened.
    public let event: FernletFeedbackEvent
    /// The haptic that plays, or nil when haptics are off.
    public let haptic: FernletHaptic?
    /// The sound that plays, or nil when sounds are off or the event has none.
    public let sound: FernletSound?

    /// The cue `event` produces under `preferences`, or nil when nothing would play.
    public init?(event: FernletFeedbackEvent, preferences: FernletFeedbackPreferences) {
        let haptic = preferences.allowsHaptic(for: event) ? event.haptic : nil
        let sound = preferences.soundsEnabled ? event.sound : nil
        guard haptic != nil || sound != nil else { return nil }
        self.event = event
        self.haptic = haptic
        self.sound = sound
    }
}

// MARK: - Player

/// The shared haptic-and-sound player: one place that turns a ``FernletFeedbackEvent`` into a
/// generator call or a system sound, and the injection point that makes "did this cue play?" a
/// question a unit test can answer.
///
/// Production callers use ``system``. A test constructs its own with a recording closure, exactly as
/// ``FernletAnnouncer`` is tested.
///
/// **Invariants**
///
/// - *Switches first.* ``play(_:preferences:)`` drops an event whose channels are all off before the
///   injected closure sees it, so a recording test proves silence as well as sound.
/// - *Paced.* An event with a ``FernletFeedbackEvent/minimumInterval`` plays at most once per interval
///   per player; a play the switches already dropped doesn't use up the window.
/// - *Never the audio session.* Sounds go through `AudioServicesPlaySystemSoundWithCompletion`, which
///   honours the ring/silent switch and mixes with other audio; each play creates its system sound and
///   disposes of it on completion, so nothing accumulates however long a workout runs.
/// - *One cue, one renderer.* ``FernletHaptic/attention`` is a Core Haptics pattern where the hardware
///   plays one (``FernletAttentionEngine``) and two generator impacts everywhere else; either way the
///   closure sees one ``FernletFeedbackCue``, so a test counts "time's up" the same on a simulator
///   (which has no haptics) as a device would play it.
/// - *No copy* (see the file header).
///
/// **Concurrency:** main-actor, like the UIKit generators it drives; `FernletUI` builds with
/// `defaultIsolation(MainActor.self)`. The one hop off the main actor is the system sound's
/// completion, which is `@Sendable` and touches only the sound's id.
public struct FernletFeedback {
    /// The production player: UIKit generators and AudioServices system sounds.
    public static let system = FernletFeedback()

    /// The unified-log sink for a sound that cannot be found or created. A missing cue is never fatal,
    /// but it is never silent in the log either.
    private static let logger = Logger(subsystem: "com.fernlet", category: "feedback")

    /// Where a cue actually goes. Injectable so a test can record what was (and was not) played.
    private let perform: @MainActor (FernletFeedbackCue) -> Void
    /// When each paced event last played, for this player.
    private let pacer: FernletFeedbackPacer
    /// The clock the pacer reads. Injectable so a test can step time instead of sleeping.
    private let now: @MainActor () -> ContinuousClock.Instant

    /// Creates a player.
    ///
    /// - Parameters:
    ///   - perform: Test seam. `nil` (production) resolves in the init body to the real haptic and
    ///     sound rendering, mirroring ``FernletAnnouncer``'s seam.
    ///   - now: Test seam for ``FernletFeedbackEvent/minimumInterval``. `nil` reads the continuous
    ///     clock.
    public init(
        perform: (@MainActor (FernletFeedbackCue) -> Void)? = nil,
        now: (@MainActor () -> ContinuousClock.Instant)? = nil
    ) {
        self.perform = perform ?? { FernletFeedback.render($0) }
        self.pacer = FernletFeedbackPacer()
        self.now = now ?? { ContinuousClock.now }
    }

    /// Plays `event` on the channels `preferences` leaves on; does nothing when both are off, or when
    /// a paced event played too recently.
    ///
    /// - Parameters:
    ///   - event: What happened.
    ///   - preferences: The person's switches for the calling surface, from
    ///     ``FernletFeedbackPreferences/resolved(haptics:sounds:in:)``.
    public func play(_ event: FernletFeedbackEvent, preferences: FernletFeedbackPreferences) {
        guard let cue = FernletFeedbackCue(event: event, preferences: preferences) else { return }
        guard pacer.admits(event, at: now()) else { return }
        perform(cue)
    }

    /// Plays `event` under the app-wide level alone: the call for a surface with no switch of its own
    /// (an error, a meal logged, a code caught). Haptics only — such surfaces never carry a sound.
    public func play(_ event: FernletFeedbackEvent) {
        play(event, preferences: .resolved())
    }

    /// The production rendering: the haptic first (it is felt at once), then the sound.
    private static func render(_ cue: FernletFeedbackCue) {
        if let haptic = cue.haptic { playHaptic(haptic) }
        if let sound = cue.sound { playSound(sound) }
    }

    /// ``FernletHaptic/attention`` through Core Haptics: three transient taps, soft to firm, the last
    /// at 260 ms — under the report's 400 ms, so "time's up" is a knock, never a buzz. Rising, so it
    /// reads as "now" from across a bench and can't be mistaken for the two even knocks of a fallback
    /// or a firm `holdStarted`. Tuned on a device here and nowhere else (report §8).
    public static let attentionPattern: [FernletHapticTap] = [
        FernletHapticTap(time: 0, intensity: 0.45, sharpness: 0.25),
        FernletHapticTap(time: 0.13, intensity: 0.7, sharpness: 0.45),
        FernletHapticTap(time: 0.26, intensity: 1, sharpness: 0.65),
    ]
    /// The fallback's strength: each of ``FernletHaptic/attention``'s two heavy impacts where Core
    /// Haptics can't play.
    public static let attentionIntensity: CGFloat = 0.8
    /// The pause between the fallback's two impacts.
    public static let attentionGap: Duration = .milliseconds(150)

    /// Plays one haptic through UIKit. The generators respect the system haptics setting themselves.
    private static func playHaptic(_ haptic: FernletHaptic) {
        switch haptic {
        case .attention: playAttention()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light, .firm, .heavy, .soft, .softPulse, .softKnock, .rigidLimit, .lightTap, .firmCatch,
             .detent, .rigid:
            playImpact(haptic)
        }
    }

    /// Plays one impact feel. THE TUNING TABLE: every impact's style and strength lives here and
    /// nowhere else (report §3.3), so a device pass changes one switch.
    private static func playImpact(_ haptic: FernletHaptic) {
        guard let (style, intensity) = impactStyle(for: haptic) else {
            assertionFailure("feedback.impact.notAnImpact: \(haptic.rawValue)")
            return
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }

    /// The style and strength of an impact feel, or nil for a feel that is not an impact.
    private static func impactStyle(
        for haptic: FernletHaptic
    ) -> (UIImpactFeedbackGenerator.FeedbackStyle, CGFloat)? {
        switch haptic {
        case .light: (.light, 1)
        case .firm: (.medium, 1)
        case .heavy: (.heavy, 1)
        case .soft: (.soft, 0.5)
        case .softPulse: (.soft, 0.6)
        case .softKnock: (.soft, 0.7)
        case .rigidLimit: (.rigid, 0.35)
        case .lightTap: (.light, 0.6)
        case .firmCatch: (.medium, 0.7)
        case .detent: (.light, 0.55)
        case .rigid: (.rigid, 1)
        case .attention, .success, .selection, .warning, .error: nil
        }
    }

    /// "Time's up" (see ``FernletHaptic/attention``): the Core Haptics pattern, or the two impacts
    /// wherever it can't play.
    ///
    /// The app-wide level is read again here, at the moment of playing. A cue that reached the
    /// renderer already passed it, but Apple documents nothing about Core Haptics and the system's own
    /// haptics switch, so Fernlet's Off is this pattern's last word and is never left to a caller.
    private static func playAttention() {
        guard FernletHapticsLevel.current() != .off else { return }
        if FernletAttentionEngine.shared.play(attentionPattern) { return }
        playAttentionImpacts()
    }

    /// The fallback: a heavy impact, a short pause, and a second one. The second tap is a main-actor
    /// task of its own, so the caller never waits on the pause; a cancelled pause simply skips it.
    private static func playAttentionImpacts() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: attentionIntensity)
        Task { @MainActor in
            do {
                try await Task.sleep(for: FernletFeedback.attentionGap)
            } catch {
                return
            }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: FernletFeedback.attentionIntensity)
        }
    }

    /// Plays one cue sound as a system sound: silent-switch aware, mixed with other audio, disposed
    /// of when it finishes.
    ///
    /// The ONE place a ``FernletSound`` becomes audio, so the renderer can change underneath the
    /// names — to an `AVAudioPlayer` on an `.ambient` session, say, if system sounds turn out not to
    /// reach AirPods on a device — without any caller noticing.
    ///
    /// R7: a missing file or a failed create is named in the log and skipped — the haptic beside it
    /// has already played, and a cue is never worth an error surface.
    private static func playSound(_ sound: FernletSound) {
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: FernletSound.fileExtension) else {
            logger.error("feedback.sound.missing: \(sound.rawValue, privacy: .public)")
            return
        }
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            logger.error("feedback.sound.createFailed: \(sound.rawValue, privacy: .public) status=\(status, privacy: .public)")
            return
        }
        let created = soundID
        AudioServicesPlaySystemSoundWithCompletion(created) { @Sendable in
            AudioServicesDisposeSystemSoundID(created)
        }
    }
}

// MARK: - Core Haptics

/// The one `CHHapticEngine` in Fernlet, behind ``FernletHaptic/attention`` (report C4).
///
/// - *Lazy.* Nothing is made until the first "time's up" reaches the renderer, so someone who never
///   runs a timer never starts an engine — and never in an app extension
///   (``FernletAttentionRenderer/choose(supportsHaptics:inAppExtension:)``).
/// - *Restarts itself.* The system stops the engine when the app goes to the background, after an
///   idle spell (auto-shutdown is on, so an engine between rests costs no power), on an interruption
///   or a system error, and resets it when the haptic server restarts. Both handlers mark it stopped,
///   and the next play starts it again — not the handler itself: a stop arrives while backgrounding,
///   where a start would fail, or at an idle timeout, where it would undo the power auto-shutdown saved.
/// - *Never loses a cue.* A failed engine, start, pattern or player is logged and answered with
///   ``FernletFeedback``'s two-impact fallback.
/// - *Haptics only.* `playsHapticsOnly` keeps it off the audio session (the file header's rule 3).
///
/// **Concurrency:** main-actor like the rest of the player. The engine calls its handlers on a queue
/// of its own; each hops back to the main actor before touching anything here.
final class FernletAttentionEngine {
    /// The process's one engine holder.
    static let shared = FernletAttentionEngine()

    /// The unified-log sink for an engine that won't make, start or play: never fatal, never silent.
    private static let logger = Logger(subsystem: "com.fernlet", category: "feedback")

    /// The engine, once made.
    private var engine: CHHapticEngine?
    /// Whether the engine is known to be running: false until started, and again once it stops or resets.
    private var isRunning = false
    /// This process can never use Core Haptics (no haptic hardware, or an app extension). Both facts
    /// hold for the process's life, so they are asked once.
    private var isUnavailable = false

    /// Plays `taps` now. Returns false when the caller must fall back: this process has no engine, or
    /// it failed to start or to play.
    func play(_ taps: [FernletHapticTap]) -> Bool {
        guard let engine = startedEngine() else { return false }
        do {
            let player = try engine.makePlayer(with: Self.pattern(taps))
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            Self.logger.error("feedback.attention.playFailed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            return false
        }
    }

    /// The engine, made on first use and started when it isn't running; nil when this process has
    /// none, or it would not start.
    private func startedEngine() -> CHHapticEngine? {
        guard let engine = engine ?? makeEngine() else { return nil }
        guard !isRunning else { return engine }
        do {
            try engine.start()
            isRunning = true
            return engine
        } catch {
            Self.logger.error("feedback.attention.startFailed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Makes the engine where Core Haptics plays, with both handlers set; nil anywhere else, or when
    /// the system refuses one (the next "time's up" asks again).
    private func makeEngine() -> CHHapticEngine? {
        guard !isUnavailable else { return nil }
        let renderer = FernletAttentionRenderer.choose(
            supportsHaptics: CHHapticEngine.capabilitiesForHardware().supportsHaptics,
            inAppExtension: Bundle.main.bundleURL.pathExtension == "appex"
        )
        guard renderer == .coreHaptics else {
            isUnavailable = true
            return nil
        }
        do {
            let made = try CHHapticEngine()
            made.playsHapticsOnly = true
            made.isAutoShutdownEnabled = true
            made.stoppedHandler = { @Sendable [weak self] reason in
                let code = reason.rawValue
                Task { @MainActor in self?.markStopped("stopped", reason: code) }
            }
            made.resetHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.markStopped("reset", reason: 0) }
            }
            engine = made
            return made
        } catch {
            Self.logger.error("feedback.attention.makeFailed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The engine stopped or was reset: the next play starts it again.
    private func markStopped(_ how: String, reason: Int) {
        isRunning = false
        Self.logger.info("feedback.attention.\(how, privacy: .public) reason=\(reason, privacy: .public)")
    }

    /// `taps` as a pattern of transient events — never a continuous one.
    private static func pattern(_ taps: [FernletHapticTap]) throws -> CHHapticPattern {
        let events = taps.map { tap in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.sharpness),
                ],
                relativeTime: tap.time
            )
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}

// MARK: - Pacing

/// Remembers when each paced event last played, so a burst of the same event plays once per
/// ``FernletFeedbackEvent/minimumInterval``.
///
/// One per player: ``FernletFeedback/system`` shares one across the app, and a test's player starts
/// fresh. R3: keyed by the closed event set, so it holds at most one instant per case.
final class FernletFeedbackPacer {
    /// The last admitted play of each paced event.
    private var lastPlayed: [FernletFeedbackEvent: ContinuousClock.Instant] = [:]

    /// Whether `event` may play at `now`; records the play when it may.
    func admits(_ event: FernletFeedbackEvent, at now: ContinuousClock.Instant) -> Bool {
        guard let interval = event.minimumInterval else { return true }
        if let last = lastPlayed[event], now < last.advanced(by: interval) { return false }
        lastPlayed[event] = now
        return true
    }
}

// MARK: - Declarative twin

public extension View {
    /// Plays `event` when `trigger` changes and `condition` holds — the twin of SwiftUI's
    /// `.sensoryFeedback(_:trigger:condition:)` for a view whose moment is a value changing.
    ///
    /// The app-wide level is resolved when the change happens, never when the view was drawn, so a
    /// Settings change reaches a screen already open. Touches and outcomes never carry a sound, so
    /// the twin takes only the surface's haptics switch.
    ///
    /// - Parameters:
    ///   - event: What happened.
    ///   - trigger: The value whose change is the moment.
    ///   - surfaceHaptics: The surface's own haptics switch, if it has one; on otherwise.
    ///   - feedback: The player; tests pass a recording one.
    ///   - condition: Whether this change is the moment (for example, "an error ARRIVED", not "it
    ///     cleared"). Every change counts when omitted.
    func fernletFeedback<Trigger: Equatable>(
        _ event: FernletFeedbackEvent,
        trigger: Trigger,
        haptics surfaceHaptics: Bool = true,
        feedback: FernletFeedback = .system,
        when condition: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> Bool = { _, _ in true }
    ) -> some View {
        fernletFeedback(trigger: trigger, haptics: surfaceHaptics, feedback: feedback) { oldValue, newValue in
            condition(oldValue, newValue) ? event : nil
        }
    }

    /// Plays the event `event(old, new)` names when `trigger` changes, or nothing when it names none —
    /// the twin of SwiftUI's `.sensoryFeedback(trigger:_:)`, for a moment whose outcome picks the
    /// event (a share that landed or failed).
    ///
    /// - Parameters:
    ///   - trigger: The value whose change is the moment.
    ///   - surfaceHaptics: The surface's own haptics switch, if it has one; on otherwise.
    ///   - feedback: The player; tests pass a recording one.
    ///   - event: The event this change plays, or nil for none.
    func fernletFeedback<Trigger: Equatable>(
        trigger: Trigger,
        haptics surfaceHaptics: Bool = true,
        feedback: FernletFeedback = .system,
        _ event: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> FernletFeedbackEvent?
    ) -> some View {
        onChange(of: trigger) { oldValue, newValue in
            guard let played = event(oldValue, newValue) else { return }
            feedback.play(played, preferences: .resolved(haptics: surfaceHaptics))
        }
    }
}
