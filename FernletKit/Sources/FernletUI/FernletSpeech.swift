//
//  FernletSpeech.swift
//  FernletUI
//
//  The app's ONE seam for spoken cues (workout runner idea 11, 2026-10-20).
//
//  ``FernletFeedback`` gives a moment a buzz or a chime; this file gives it words, for someone who
//  turned spoken cues on and is setting up a bench with the phone face-down. It sits beside the
//  feedback seam, keyed by the same moments, and never inside it: a caller resolves the words from
//  its own catalog and hands them over as a ``FernletSpokenLine``.
//
//  FOUR RULES, all load-bearing:
//
//  1. ONE VOICE. While VoiceOver runs, the synthesizer is never started — two voices talking at once
//     is worse than either. The line goes through ``FernletAnnouncer`` instead, and only when the
//     caller says VoiceOver has not already heard it (``FernletSpokenLine/voiceOverText`` is nil when
//     the screen's own announcement says it), so nothing is said twice.
//
//  2. NEVER TAKE THE AUDIO. The session is configured just before each line and released just after
//     it with `.notifyOthersOnDeactivation`, so the person's music comes straight back. Through
//     headphones, Bluetooth, CarPlay or AirPlay the line plays the way Apple documents for an
//     exercise app: `.playback` in `.voicePrompt` mode with `.duckOthers` and
//     `.interruptSpokenAudioAndMixWithOthers` — music dips under the words and is never paused; a
//     podcast pauses and resumes. On the phone's own speaker the session is `.ambient`: it mixes,
//     never ducks, and the ring/silent switch silences it (the sounds-and-haptics investigation,
//     §3.5 and decision 3: "On the speaker, the silent switch always wins"). A session that cannot
//     be configured or activated means the line is NOT spoken — speaking on the default solo-ambient
//     category would stop the person's music, which is the one thing this seam exists to avoid.
//     Volume is the system's; there is no volume control here.
//
//  3. NO COPY. Nothing in this file is ever spoken or shown, so it holds no user-visible string; the
//     words come resolved from the caller, like ``FernletAnnouncer``'s.
//
//  4. NEVER THE PAYLOAD. A spoken line is heard by the room. Callers pass catalog text about the
//     session (an exercise's name, a weight, "Rest's over."), never sealed content or a friend's name.
//

import AVFAudio
import os
import UIKit

// MARK: - Audio policy

/// How a spoken line's audio session behaves, chosen for each line from where the audio is going.
///
/// A pure value: ``category``, ``mode`` and ``options`` are what the production player hands
/// `AVAudioSession.setCategory(_:mode:options:)`, and a test reads them to prove the person's music
/// is mixed (and, in headphones, ducked) rather than paused. The raw values are stable identifiers
/// for logs and tests, never display text.
public nonisolated enum FernletSpeechAudioPolicy: String, CaseIterable, Sendable {
    /// The phone's own speaker (or receiver): `.ambient` — mixes with other audio, never ducks it, and
    /// is silenced by the ring/silent switch, like the runner's chime.
    case phoneSpeaker
    /// Anything else — headphones, Bluetooth, CarPlay, AirPlay: `.playback` in `.voicePrompt` mode,
    /// ducking the music and pausing other spoken audio while a line plays, so a person who turned
    /// spoken cues on hears them in their ears whatever the ring/silent switch says.
    case headphones

    /// The session category for this route.
    public var category: AVAudioSession.Category {
        switch self {
        case .phoneSpeaker: .ambient
        case .headphones: .playback
        }
    }

    /// The session mode: `.voicePrompt` (short synthesized prompts, the navigation-app mode) in
    /// headphones; the default on the speaker, where `.ambient` takes no special mode.
    public var mode: AVAudioSession.Mode {
        switch self {
        case .phoneSpeaker: .default
        case .headphones: .voicePrompt
        }
    }

    /// The category options. `.ambient` mixes by definition and cannot duck; `.playback` gets the
    /// exercise-app pair, both of which also mix with other audio.
    public var options: AVAudioSession.CategoryOptions {
        switch self {
        case .phoneSpeaker: []
        case .headphones: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        }
    }

    /// The policy for a route whose outputs are `outputs`: the phone speaker only when every output is
    /// the phone's own speaker or receiver (or there is no output at all — the conservative answer,
    /// since it respects the silent switch); headphones for anything else.
    public static func forRoute(_ outputs: [AVAudioSession.Port]) -> FernletSpeechAudioPolicy {
        let phone: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        return outputs.allSatisfy { phone.contains($0) } ? .phoneSpeaker : .headphones
    }
}

/// One call the speech player makes on the shared audio session, in the order it makes them.
///
/// Production performs each on `AVAudioSession.sharedInstance()`; a test injects a recorder and
/// asserts the exact sequence — configure and activate before a line, deactivate once after the last.
public nonisolated enum FernletSpeechSessionCall: Equatable, Sendable {
    /// `setCategory(_:mode:options:)` with the policy's three values.
    case configure(FernletSpeechAudioPolicy)
    /// `setActive(true)` — in headphones this is the moment the music dips.
    case activate
    /// `setActive(false, options: .notifyOthersOnDeactivation)` — the music comes back up, and a
    /// paused podcast is told it may resume.
    case deactivate
}

/// One spoken cue as it leaves a caller: what the synthesizer says, and what VoiceOver should hear
/// in its place.
public nonisolated struct FernletSpokenLine: Equatable, Sendable {
    /// The sentence the synthesizer speaks when VoiceOver is off. Caller-resolved catalog text.
    public let text: String
    /// What the announcer posts instead while VoiceOver runs, or nil when the screen's own VoiceOver
    /// announcement already says this moment — then nothing more is posted, so nothing is said twice.
    public let voiceOverText: String?

    /// Creates a line.
    ///
    /// - Parameters:
    ///   - text: The sentence to speak aloud. Never sealed content.
    ///   - voiceOverText: The announcement to post under VoiceOver instead, or nil when VoiceOver
    ///     already hears this moment from the screen.
    public init(text: String, voiceOverText: String?) {
        self.text = text
        self.voiceOverText = voiceOverText
    }
}

/// The voice behind ``FernletSpeaker``: says a line, cutting off anything still being said, and
/// reports when nothing is left to say.
///
/// Production is an `AVSpeechSynthesizer`; a test conforms a recorder and finishes lines itself,
/// because the synthesizer never reports back what it said in a unit test. Main-actor, written out
/// so a conformer's isolation never depends on how the module's default isolation treats protocols.
@MainActor
public protocol FernletSpeechVoice: AnyObject {
    /// Says `text` now, cutting off a line still in progress (the newest moment wins), and calls
    /// `idle` once every line has finished or been cut off.
    func say(_ text: String, whenIdle idle: @escaping @MainActor () -> Void)
}

// MARK: - Speaker

/// The shared spoken-cue player: routes a ``FernletSpokenLine`` to VoiceOver or to the synthesizer,
/// and holds the audio session only while a line is being spoken.
///
/// Production callers use ``system``. A test constructs its own with a recording voice, session,
/// VoiceOver read and announcer, exactly as ``FernletFeedback`` and ``FernletAnnouncer`` are tested.
///
/// **Invariants**
///
/// - *One voice.* While VoiceOver runs, ``say(_:)`` never touches the voice or the audio session; it
///   posts ``FernletSpokenLine/voiceOverText`` through the announcer, or nothing.
/// - *Configured or silent.* Each line configures the session for the current route
///   (``FernletSpeechAudioPolicy``) and activates it first; if either fails, the line is dropped
///   and logged, never spoken on a category that would stop the person's music.
/// - *Released after the last line.* When the voice goes idle, the session is deactivated with
///   `.notifyOthersOnDeactivation` after a short settle (``defaultSettle``) — once, and not at all if
///   another line started in the meantime, so back-to-back lines duck the music once.
/// - *No copy* (see the file header).
///
/// **Concurrency:** main-actor, like the announcer and the views that drive it. The deactivation is
/// one main-actor `Task`, replaced whenever a new line starts.
@MainActor
public final class FernletSpeaker {
    /// The production speaker: an `AVSpeechSynthesizer` made on first use, the shared audio session,
    /// and the system's VoiceOver state.
    public static let system = FernletSpeaker()

    /// How long the session stays active after the voice goes idle before it is released: long
    /// enough for the synthesizer's audio to wind down (deactivating with I/O still running fails),
    /// short enough that the music comes back as the line ends.
    public nonisolated static let defaultSettle: Duration = .milliseconds(300)

    /// The unified-log sink for a session that could not be configured, activated or released.
    private static let logger = Logger(subsystem: "com.fernlet", category: "speech")

    private let voice: any FernletSpeechVoice
    private let policy: @MainActor () -> FernletSpeechAudioPolicy
    private let session: @MainActor (FernletSpeechSessionCall) throws -> Void
    private let isVoiceOverRunning: @MainActor () -> Bool
    private let announcer: FernletAnnouncer
    private let settle: Duration
    /// The latest line handed to the voice; a stale idle report (an earlier line's) is ignored.
    private var line = 0
    /// The pending release of the session, cancelled when a new line starts.
    private var deactivation: Task<Void, Never>?

    /// Creates a speaker. Every dependency is injectable; nil means production.
    ///
    /// - Parameters:
    ///   - voice: The voice; nil means an `AVSpeechSynthesizer` in the app's language.
    ///   - policy: The audio policy for the current route; nil reads the shared session's route.
    ///   - session: Performs one session call; nil performs it on the shared `AVAudioSession`.
    ///   - isVoiceOverRunning: Whether VoiceOver is on, read at every line; nil reads `UIAccessibility`.
    ///   - announcer: Where a line goes under VoiceOver; nil means ``FernletAnnouncer/system``.
    ///   - settle: The wait between the voice going idle and the release; nil means ``defaultSettle``.
    public init(
        voice: (any FernletSpeechVoice)? = nil,
        policy: (@MainActor () -> FernletSpeechAudioPolicy)? = nil,
        session: (@MainActor (FernletSpeechSessionCall) throws -> Void)? = nil,
        isVoiceOverRunning: (@MainActor () -> Bool)? = nil,
        announcer: FernletAnnouncer? = nil,
        settle: Duration? = nil
    ) {
        self.voice = voice ?? FernletSynthesizerVoice(language: FernletSpeaker.voiceLanguage())
        self.policy = policy ?? { FernletSpeaker.currentRoutePolicy() }
        self.session = session ?? { try FernletSpeaker.perform($0) }
        self.isVoiceOverRunning = isVoiceOverRunning ?? { UIAccessibility.isVoiceOverRunning }
        self.announcer = announcer ?? .system
        self.settle = settle ?? Self.defaultSettle
    }

    /// The pending session release ends with the speaker (the memory wall's ML1).
    isolated deinit {
        deactivation?.cancel()
    }

    /// Says one spoken cue the way the person hears the app: through VoiceOver's announcer while it
    /// runs (only the part VoiceOver has not already heard), otherwise aloud through the voice.
    ///
    /// - Parameter line: The caller-resolved words. Never sealed content.
    public func say(_ line: FernletSpokenLine) {
        if isVoiceOverRunning() {
            if let words = line.voiceOverText {
                announcer.announce(.status, resolved: words)
            }
            return
        }
        speakAloud(line.text)
    }

    /// Waits for a pending session release. A test seam: with a zero settle it returns once the
    /// session has been released (or the release was superseded).
    public func settled() async {
        await deactivation?.value
    }

    /// The voice language for text in the app's language: the person's own regional voice when their
    /// device speaks the app's language ("en-GB" for a British English device), else the app's
    /// language itself — the words are the app's catalog text, so a Spanish voice must never read
    /// English words. Nil when the app's language is unknown (the system default voice then).
    ///
    /// - Parameters:
    ///   - appLanguage: The app's running localization; nil reads `Bundle.main.preferredLocalizations`.
    ///   - locale: The device locale; nil means `Locale.current`.
    public nonisolated static func voiceLanguage(appLanguage: String? = nil, locale: Locale? = nil) -> String? {
        guard let app = appLanguage ?? Bundle.main.preferredLocalizations.first else { return nil }
        let device = locale ?? Locale.current
        let appCode = Locale(identifier: app).language.languageCode?.identifier
        guard let code = device.language.languageCode?.identifier, code == appCode,
              let region = device.region?.identifier else {
            return app
        }
        return "\(code)-\(region)"
    }

    /// Configures and activates the session for the current route, then hands the line to the voice.
    /// R7: a session that refuses is logged and the line dropped — never spoken unconfigured.
    private func speakAloud(_ text: String) {
        guard !text.isEmpty else { return }
        let route = policy()
        do {
            try session(.configure(route))
            try session(.activate)
        } catch {
            Self.logger.error("speech.session.refused: \(route.rawValue, privacy: .public) code=\((error as NSError).code, privacy: .public)")
            return
        }
        deactivation?.cancel()
        deactivation = nil
        line &+= 1
        let spoken = line
        voice.say(text) { [weak self] in self?.voiceWentIdle(after: spoken) }
    }

    /// The voice has nothing left to say: release the session after the settle, unless a newer line
    /// has started by then.
    private func voiceWentIdle(after spoken: Int) {
        guard spoken == line else { return }
        deactivation?.cancel()
        let wait = settle
        deactivation = Task { [weak self] in
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
            guard let self, spoken == self.line else { return }
            self.release()
        }
    }

    /// Deactivates the session so the music comes back. R7: a refusal is logged; the next line's
    /// release tries again.
    private func release() {
        do {
            try session(.deactivate)
        } catch {
            Self.logger.error("speech.session.releaseFailed: code=\((error as NSError).code, privacy: .public)")
        }
    }

    /// The production policy: from the shared session's current output route.
    private static func currentRoutePolicy() -> FernletSpeechAudioPolicy {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return FernletSpeechAudioPolicy.forRoute(outputs.map { $0.portType })
    }

    /// The production session: one call on the shared `AVAudioSession`.
    private static func perform(_ call: FernletSpeechSessionCall) throws {
        let audio = AVAudioSession.sharedInstance()
        switch call {
        case .configure(let route):
            try audio.setCategory(route.category, mode: route.mode, options: route.options)
        case .activate:
            try audio.setActive(true)
        case .deactivate:
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Production voice

/// The production ``FernletSpeechVoice``: one `AVSpeechSynthesizer`, made on first use, speaking in
/// the app's language on the app's own audio session (which ``FernletSpeaker`` configures).
///
/// Each utterance prefers the person's assistive-technology speech settings
/// (`prefersAssistiveTechnologySettings`), and keeps the system's rate and volume otherwise. A new
/// line cuts off the one in progress at a word boundary, so a quick run of moves says the current
/// one rather than a queue of stale ones.
///
/// **Concurrency:** main-actor. The synthesizer's delegate callbacks are `nonisolated` and hop to
/// the main actor before touching the line count, as `WeatherKitService`'s location callbacks do.
@MainActor
final class FernletSynthesizerVoice: NSObject, FernletSpeechVoice, AVSpeechSynthesizerDelegate {
    /// The BCP-47 language of the voice, or nil for the system default.
    private let language: String?
    /// Made on first ``say(_:whenIdle:)``, so a person who never turns spoken cues on never gets one.
    private var synthesizer: AVSpeechSynthesizer?
    /// Lines handed to the synthesizer that have not yet finished or been cut off.
    private var linesInFlight = 0
    /// Called once ``linesInFlight`` reaches zero; the latest caller's.
    private var idle: (@MainActor () -> Void)?

    /// Creates the voice.
    ///
    /// - Parameter language: The voice's BCP-47 language (``FernletSpeaker/voiceLanguage(appLanguage:locale:)``).
    init(language: String?) {
        self.language = language
        super.init()
    }

    func say(_ text: String, whenIdle idle: @escaping @MainActor () -> Void) {
        // Lines are counted, not matched: a cut-off line reports `didCancel`, a finished one
        // `didFinish`, and idle is reported once none is left — so a late callback for a cut-off line
        // can never end the line that replaced it.
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        let speaker = synthesizer ?? makeSynthesizer()
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .word)
        }
        self.idle = idle
        linesInFlight += 1
        speaker.speak(utterance)
    }

    /// Makes the synthesizer on first use, on the app's own audio session.
    private func makeSynthesizer() -> AVSpeechSynthesizer {
        let made = AVSpeechSynthesizer()
        made.usesApplicationAudioSession = true
        made.delegate = self
        synthesizer = made
        return made
    }

    /// One line finished or was cut off; report idle when none is left.
    private func lineEnded() {
        linesInFlight = max(0, linesInFlight - 1)
        guard linesInFlight == 0, let idle else { return }
        self.idle = nil
        idle()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.lineEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.lineEnded() }
    }
}
