//
//  FernletFeedback.swift
//  FernletUI
//
//  The app's ONE seam for haptic and sound cues (workout runner round, 2026-10-20).
//
//  The guided workout runner was silent: a rest ended or a plank hold ran out with the phone face-down
//  on a bench and nothing said so. This file gives every such moment a NAME (``FernletFeedbackEvent``)
//  and one place that decides what each name feels and sounds like, so the next surface that wants a
//  cue — and the app-wide sounds-and-haptics pass that is expected to extend this — adds a case and a
//  row to two switches instead of inventing its own generator call.
//
//  FOUR RULES, all load-bearing:
//
//  1. EVENTS, NOT GENERATORS. Callers name what happened, never which haptic to play. The mapping lives
//     in ``FernletFeedbackEvent/haptic`` and ``FernletFeedbackEvent/sound`` and nowhere else.
//
//  2. THE PERSON'S SWITCHES WIN. Every play takes a ``FernletFeedbackPreferences``; an event whose
//     channels are all switched off is dropped before anything reaches UIKit. The system's own
//     Settings › Sounds & Haptics switch is honoured underneath that by `UIFeedbackGenerator` itself.
//
//  3. NEVER TAKE THE AUDIO. Sounds play through AudioServices system sounds: they follow the ring/silent
//     switch (silent means no sound), play at the ringer volume, and mix with whatever is playing — no
//     `AVAudioSession` category is set, so the person's music is never paused, ducked or interrupted.
//     The files are short and authored quiet (see ``FernletSound``).
//
//  4. NO COPY. Nothing here is ever spoken or shown, so this file holds no user-visible string. Spoken
//     equivalents stay with ``FernletAnnouncer``; the opt-in spoken cues (``FernletSpeaker``,
//     `FernletSpeech.swift`) sit beside this seam, said at the same moments, rather than inside it.
//

import AudioToolbox
import os
import UIKit

// MARK: - Vocabulary

/// A moment that can carry a haptic or sound cue.
///
/// The cases are *events*, not feelings: a call site says what happened ("the rest ran out") and the
/// mapping below decides how that feels. Today every case belongs to the guided workout runner; add a
/// case — and its row in ``haptic`` and ``sound`` — for any new surface rather than calling a feedback
/// generator directly. The raw values are stable identifiers for logs and tests, never display text.
public nonisolated enum FernletFeedbackEvent: String, CaseIterable, Sendable {
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

    /// The haptic this event plays when haptics are on. Every event has one.
    ///
    /// The two timer endings share ``FernletHaptic/attention`` on purpose: "a timer you were waiting on
    /// ran out" should feel the same whether it was a rest or a hold.
    public var haptic: FernletHaptic {
        switch self {
        case .restEnded, .holdEnded: .attention
        case .holdStarted: .firm
        case .setLogged, .zoneDrift: .light
        case .blockChanged: .heavy
        case .workoutFinished: .success
        }
    }

    /// The quiet sound this event plays when sounds are on, or nil for an event that stays silent.
    ///
    /// A logged set is silent: the person just tapped, so a sound would only echo the tap. A zone
    /// nudge is silent too: a heart rate drifting a little is never worth a sound over someone's music.
    public var sound: FernletSound? {
        switch self {
        case .restEnded, .holdEnded, .blockChanged, .workoutFinished: .chime
        case .holdStarted: .tick
        case .setLogged, .zoneDrift: nil
        }
    }
}

/// The haptic vocabulary, one case per distinct feel.
///
/// Each case is played by a `UIFeedbackGenerator` (``FernletFeedback`` renders them), which plays
/// nothing when the system haptics setting is off or the app is not in the foreground.
public nonisolated enum FernletHaptic: String, CaseIterable, Sendable {
    /// A light impact: an acknowledgement under the thumb.
    case light
    /// A medium impact: "start now".
    case firm
    /// A heavy impact: the session moved on to something new.
    case heavy
    /// "Time's up" for a timer that ran out: two heavy impacts at 0.8 intensity, 150 ms apart
    /// (``FernletFeedback/attentionIntensity``, ``FernletFeedback/attentionGap``).
    ///
    /// Deliberately NOT `UINotificationFeedbackGenerator`'s `.warning` pattern: app-wide, `.warning`
    /// is reserved for "it worked, with a caveat", and a rest running out is not a caveat. A Core
    /// Haptics pattern may replace this pair later; callers name the case, so nothing else changes.
    case attention
    /// The success notification pattern, for a finished workout.
    case success
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

/// Which feedback channels the person has switched on for a surface.
///
/// A plain value the caller reads from wherever that surface keeps its switches (the workout runner's
/// are device-local `UserDefaults`, `WorkoutCuePreferences` in the app); this module never reads or
/// writes a preference itself.
public nonisolated struct FernletFeedbackPreferences: Equatable, Sendable {
    /// Play haptics.
    public var hapticsEnabled: Bool
    /// Play sounds.
    public var soundsEnabled: Bool

    /// Creates a preference pair. Both channels are explicit: each surface owns its own defaults.
    public init(hapticsEnabled: Bool, soundsEnabled: Bool) {
        self.hapticsEnabled = hapticsEnabled
        self.soundsEnabled = soundsEnabled
    }

    /// Both channels are off: nothing should be played or scheduled at all.
    public var isSilent: Bool { !hapticsEnabled && !soundsEnabled }
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
        let haptic = preferences.hapticsEnabled ? event.haptic : nil
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
/// - *Never the audio session.* Sounds go through `AudioServicesPlaySystemSoundWithCompletion`, which
///   honours the ring/silent switch and mixes with other audio; each play creates its system sound and
///   disposes of it on completion, so nothing accumulates however long a workout runs.
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

    /// Creates a player.
    ///
    /// - Parameter perform: Test seam. `nil` (production) resolves in the init body to the real
    ///   haptic and sound rendering, mirroring ``FernletAnnouncer``'s seam.
    public init(perform: (@MainActor (FernletFeedbackCue) -> Void)? = nil) {
        self.perform = perform ?? { FernletFeedback.render($0) }
    }

    /// Plays `event` on the channels `preferences` leaves on; does nothing when both are off.
    ///
    /// - Parameters:
    ///   - event: What happened.
    ///   - preferences: The person's switches for the calling surface.
    public func play(_ event: FernletFeedbackEvent, preferences: FernletFeedbackPreferences) {
        guard let cue = FernletFeedbackCue(event: event, preferences: preferences) else { return }
        perform(cue)
    }

    /// The production rendering: the haptic first (it is felt at once), then the sound.
    private static func render(_ cue: FernletFeedbackCue) {
        if let haptic = cue.haptic { playHaptic(haptic) }
        if let sound = cue.sound { playSound(sound) }
    }

    /// The strength of each of ``FernletHaptic/attention``'s two heavy impacts.
    public static let attentionIntensity: CGFloat = 0.8
    /// The pause between ``FernletHaptic/attention``'s two impacts.
    public static let attentionGap: Duration = .milliseconds(150)

    /// Plays one haptic through UIKit. The generators respect the system haptics setting themselves.
    private static func playHaptic(_ haptic: FernletHaptic) {
        switch haptic {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .firm: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .attention: playAttention()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// "Time's up": a heavy impact, a short pause, and a second one (see ``FernletHaptic/attention``).
    /// The second tap is a main-actor task of its own, so the caller never waits on the pause; a
    /// cancelled pause simply skips it.
    private static func playAttention() {
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
