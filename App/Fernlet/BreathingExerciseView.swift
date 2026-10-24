//
//  BreathingExerciseView.swift
//  Fernlet
//
//  A calm animated breathing circle: box breathing (4-4-4-4) or relax (4-7-8), 1–3 minutes,
//  optional soft haptics that follow the breath. Completing a session (never abandoning one)
//  reports the interval to the caller, which quietly offers it to Apple Health.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
import FernletUI
#endif

/// One phase of a breath cycle (e.g. "Breathe in" for 4 seconds toward the expanded circle).
///
/// The building block of a ``BreathingPreset``; ``BreathingExerciseView``'s session loop shows
/// `label`, animates the circle toward `targetScale` over `seconds`, then sleeps out the phase.
struct BreathPhase: Equatable {
    /// Which part of the breath a phase is.
    enum Kind: Equatable {
        /// Breathing in: the circle swells.
        case inhale
        /// A held breath: the circle rests where it is.
        case hold
        /// Breathing out: the circle settles.
        case exhale
    }

    /// Which part of the breath this is. It decides the phase's words and how the pacer's taps feel
    /// (``BreathingPacerHaptics``), so the two can never disagree.
    let kind: Kind
    let seconds: Double
    /// Target circle scale at the END of the phase (holds keep the previous target).
    let targetScale: CGFloat

    /// The phase's words — the running screen's only text, and the value VoiceOver speaks each time
    /// the pacer turns.
    ///
    /// A `LocalizedStringResource` rather than a `String`: `Text(_:)` renders it and
    /// `.accessibilityValue(Text(_:))` speaks it, and both of those resolve the catalog. A plain
    /// `String` would reach `Text`'s NON-localizing initializer instead, which is why this line used
    /// to be English forever with a clean build. It is display copy, never a token: nothing persists
    /// it (``BreathingPreset/id`` is the stored key) and nothing matches on it, so translating it is
    /// safe.
    var label: LocalizedStringResource {
        switch kind {
        case .inhale: BreathingCopy.breatheIn
        case .hold: BreathingCopy.hold
        case .exhale: BreathingCopy.breatheOut
        }
    }
}

/// A named breathing pattern: an ordered list of ``BreathPhase``s plus display copy for the
/// pattern picker.
///
/// Two curated presets exist — ``box`` (4-4-4-4) and ``relax`` (4-7-8) — surfaced on
/// ``BreathingExerciseView``'s setup screen via ``all``; the session loop repeats the preset's
/// phases until the chosen length elapses.
struct BreathingPreset: Identifiable, Equatable {
    /// The FROZEN persisted token (`@AppStorage("fernlet.breathing.presetID")`); never display text.
    let id: String
    /// The pattern tile's name. A `LocalizedStringResource`, like ``BreathPhase/label``: as a `String`
    /// it reached `Text`'s verbatim initializer and was never harvested.
    let name: LocalizedStringResource
    /// The pattern tile's rhythm line ("In 4 · hold 4 · out 4 · hold 4").
    let caption: LocalizedStringResource
    let phases: [BreathPhase]

    /// Box breathing: in 4 — hold 4 — out 4 — hold 4.
    static let box = BreathingPreset(
        id: "box",
        name: LocalizedStringResource("breathing.preset.box.name", defaultValue: "Box",
                                      comment: "Breathing screen: the name of box breathing (in, hold, out, hold, four seconds each) on its pattern tile."),
        caption: LocalizedStringResource("breathing.preset.box.caption", defaultValue: "In 4 · hold 4 · out 4 · hold 4",
                                         comment: "Breathing screen: box breathing's rhythm under its name — breathe in 4 seconds, hold 4, out 4, hold 4."),
        phases: [
            BreathPhase(kind: .inhale, seconds: 4, targetScale: 1.0),
            BreathPhase(kind: .hold, seconds: 4, targetScale: 1.0),
            BreathPhase(kind: .exhale, seconds: 4, targetScale: 0.55),
            BreathPhase(kind: .hold, seconds: 4, targetScale: 0.55)
        ]
    )

    /// Relaxing breath: in 4 — hold 7 — out 8.
    static let relax = BreathingPreset(
        id: "relax",
        name: LocalizedStringResource("breathing.preset.relax.name", defaultValue: "Relax",
                                      comment: "Breathing screen: the name of the 4-7-8 relaxing breath on its pattern tile."),
        caption: LocalizedStringResource("breathing.preset.relax.caption", defaultValue: "In 4 · hold 7 · out 8",
                                         comment: "Breathing screen: the relaxing breath's rhythm under its name — breathe in 4 seconds, hold 7, out 8."),
        phases: [
            BreathPhase(kind: .inhale, seconds: 4, targetScale: 1.0),
            BreathPhase(kind: .hold, seconds: 7, targetScale: 1.0),
            BreathPhase(kind: .exhale, seconds: 8, targetScale: 0.55)
        ]
    )

    static let all: [BreathingPreset] = [.box, .relax]
}

/// The pacer's spoken and rendered words.
///
/// Four one- or two-word lines, gathered here because each is used at two or three call sites (the
/// presets, the idle state, the finish) and each has to be one catalog key rather than several
/// copies that could drift apart in translation. They carry translator comments the bare literals
/// could not: "Hold" is an instruction to hold a breath, not a verb for keeping something.
///
/// Every key is semantic (`breathing.phase.*`, `breathing.pacer.*`), never the English word: the
/// guided workout runner draws its own "Hold" (a held position) and "Ready when you are", and a
/// shared key would force one translation on both ("Retén el aire" here, "Mantén" there).
enum BreathingCopy {
    /// The inhale phase.
    static let breatheIn = LocalizedStringResource(
        "breathing.phase.inhale", defaultValue: "Breathe in",
        comment: "Shown and spoken while the breathing pacer's circle expands. An instruction to inhale, given to someone with their eyes closed — keep it short and calm.")

    /// A held breath, between the inhale and the exhale (and, in box breathing, after the exhale).
    static let hold = LocalizedStringResource(
        "breathing.phase.hold", defaultValue: "Hold",
        comment: "Shown and spoken while the breathing pacer rests between breaths. It means 'hold your breath', not 'keep' or 'wait' (the workout runner's hold is a different key).")

    /// The exhale phase.
    static let breatheOut = LocalizedStringResource(
        "breathing.phase.exhale", defaultValue: "Breathe out",
        comment: "Shown and spoken while the breathing pacer's circle contracts. An instruction to exhale.")

    /// The resting state, before a session starts and after one is ended early.
    static let ready = LocalizedStringResource(
        "breathing.pacer.ready", defaultValue: "Ready when you are",
        comment: "Shown and spoken by the breathing pacer while no session is running. Unhurried and permission-giving — the tool waits, it does not prompt.")

    /// The last thing the pacer says, as a completed session fades into the finish screen, and the
    /// finish screen's heading.
    static let allDone = LocalizedStringResource(
        "breathing.pacer.allDone", defaultValue: "All done",
        comment: "Shown and spoken by the breathing pacer the moment a session reaches its full length, and the heading of the finish screen after it.")

    /// The pacer's stable accessibility NAME. Stable is the point: VoiceOver re-speaks a focused
    /// element's changed value, and a changed label would instead be read as a new element.
    static let pacerLabel = LocalizedStringResource(
        "breathing.pacer.label", defaultValue: "Breathing pacer",
        comment: "VoiceOver name for the animated breathing circle. Its spoken value is the current phase — 'Breathe in', 'Hold', 'Breathe out'.")

    /// The finish screen's line for a session of `minutes` (1, 2 or 3).
    ///
    /// One plural-ruled key, whose English `one` form is the "a whole minute" sentence: the length
    /// is never more than three, so a plural category never stands for anything but the count it
    /// names here, and the two English literals that used to be picked by `minutes == 1` become one
    /// key a translator can vary.
    static func finished(minutes: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "breathing.finished.minutes",
            defaultValue: "That was \(minutes) whole minutes of care. Nicely done.",
            comment: "Breathing finish screen: how long the session was, in minutes (1, 2 or 3). Needs a plural variation per language; English says 'That was a whole minute of care. Nicely done.' for one.")
    }
}

/// The slow-breathing exercise: a softly swelling circle guided through a chosen
/// ``BreathingPreset`` for 1–3 minutes, with optional soft haptics that follow the breath
/// (``BreathingPacerHaptics``).
///
/// Pushed from ``FirstAidView``. Runs a setup → running → finished state machine driven by one
/// wall-clock session task; the cycle in progress when the timer crosses the line finishes gently
/// rather than cutting off mid-breath. Only a session that runs to its full chosen length calls
/// `onSessionComplete` (the caller's Health/milestone hook) — ending early or backgrounding the
/// app abandons quietly, so an inflated `.mindfulSession` interval is never written for an
/// exercise that didn't actually happen.
struct BreathingExerciseView: View {
    /// Called once when a session runs to its full chosen length (not when abandoned early).
    var onSessionComplete: (_ start: Date, _ end: Date) -> Void

    /// Pattern, length, and haptics persist between visits: a daily user who prefers "Relax · 3 min"
    /// had to re-pick both every single time before Begin.
    @AppStorage("fernlet.breathing.presetID") private var presetID = BreathingPreset.box.id
    @AppStorage("fernlet.breathing.minutes") private var minutes = 1
    @AppStorage(BreathingPreferences.hapticsKey) private var hapticsEnabled = BreathingPreferences.defaultHaptics
    /// The app-wide Haptics level (Settings › Sounds & haptics), read here only for the note under the
    /// Haptics switch; the pacer's tap reads it through FernletUI's resolver at every phase.
    @AppStorage(FernletHapticsLevel.storageKey) private var appHapticsLevel = FernletHapticsLevel.defaultLevel

    /// The stored pattern, resolved against the curated presets (falling back to Box if the stored
    /// id ever names a preset that no longer exists).
    private var preset: BreathingPreset {
        BreathingPreset.all.first { $0.id == presetID } ?? .box
    }

    @State private var isRunning = false
    @State private var isFinished = false
    @State private var phaseLabel = BreathingCopy.ready
    /// Puts VoiceOver on the pacer when a session begins.
    ///
    /// Load-bearing, not a nicety: VoiceOver re-speaks a changed `accessibilityValue` only on the
    /// element that currently holds focus. Without this the cursor stays on Begin, every phase change
    /// is silent, and the exercise conveys nothing at all for up to three minutes.
    @AccessibilityFocusState private var isPacerFocused: Bool
    @State private var circleScale: CGFloat = 0.6
    @State private var idleBreathing = false
    @State private var sessionTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The circle's small resting scale — it sways gently around this so the first
    /// "Breathe in" visibly swells out of it (mockup rests ~168px against a 280px full).
    private let restingScale: CGFloat = 0.6

    /// Hard iteration cap for the session loop. The real bound is wall clock (<= 3 minutes) and the
    /// shortest preset cycle is 16 s, so 12 cycles is the most a legitimate session can run; 16 is
    /// headroom that still keeps the loop's maximum visible at the loop.
    private static let maxCycles = 16

    /// Done in the header once a session finishes (`b3-breathe-done`): back to setup, then out of the
    /// tool; nil (no Done) before that, where Back is the way out.
    private var doneAction: (() -> Void)? {
        guard isFinished else { return nil }
        return { finishToSetup(); dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // World (b3-breathe-*): "‹ First aid", the title in the sheet, and Done once finished.
            FirstAidToolHeader(title: Text("Slow breathing"), onDone: doneAction)
            Group {
                if isFinished {
                    finishedScreen
                } else if isRunning {
                    runningScreen
                } else {
                    setupScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fernletSheetStyle()
        .navigationTitle("Slow breathing")
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // The persisted length is user defaults, i.e. arbitrary storage: `startSession` refuses
            // anything outside 1…3, so a stray value would make Begin a silent no-op.
            if !(1...3).contains(minutes) { minutes = 1 }
        }
        .onDisappear { sessionTask?.cancel() }
        // Driven from the STATE FLIP, not from `startSession()`: at the moment Begin's action runs,
        // `runningScreen` — and therefore the pacer element this targets — has not been built yet,
        // so a focus request there lands on nothing. T0-4 has no second channel (a changed
        // accessibilityValue is re-spoken only on the FOCUSED element, and there is no
        // announcement), so a focus request that misses makes the whole fix inert.
        .onChange(of: isRunning) { _, running in
            guard running else { return }
            isPacerFocused = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Breathing is a present-moment activity. If the app is actually backgrounded mid-session
            // (locked, home-swiped) the wall-clock timer would otherwise "complete" whenever the
            // process resumes — minutes or an hour later — and write an inflated `.mindfulSession` to
            // Health for an exercise that was abandoned. Treat backgrounding as a gentle abandon (no
            // completion write, no achievement). Transient `.inactive` (a banner, Control Center) is
            // left alone: the process isn't suspended, so the clock stays honest.
            if newPhase == .background, isRunning { stopSession() }
        }
    }

    // MARK: - Setup

    private var setupScreen: some View {
        // A ScrollView keeps Begin reachable at the largest Dynamic Type sizes, where a plain
        // VStack would push it off-screen; `.basedOnSize` leaves default sizes looking unchanged.
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                VStack(spacing: 20) {
                    breathingCircle
                        // A gentle idle sway around 1.0 — `circleScale` (set to `restingScale` in
                        // onAppear) already renders the circle at its 0.6 resting size, so this outer
                        // factor must stay near 1.0 or the two scales compound and Begin pops the
                        // circle back up to full resting size.
                        .scaleEffect(idleBreathing ? 1.04 : 0.98)
                        .onAppear {
                            circleScale = restingScale
                            // The forever-repeating idle sway is decoration, not the exercise —
                            // Reduce Motion holds the circle still. (The GUIDED breathing scale
                            // during a session stays: that motion IS the exercise.)
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                                idleBreathing = true
                            }
                        }
                        .onDisappear { idleBreathing = false }
                        // The rings rest at 0.6 of their full size: lay out what is drawn, not the
                        // full ring, so Begin stays on screen (`b3-breathe-setup`).
                        .frame(height: 170)
                    Text("Ready when you are.")
                        .font(FernletFramedFont.field)
                        .foregroundStyle(WorldPalette.dim)
                }

                Spacer(minLength: 8)

                setupControls

                // World (b3-breathe-setup): Begin is the full-width framed moss primary.
                Button {
                    startSession()
                } label: {
                    Text("Begin")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("firstAid.breathing.begin")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Running

    private var runningScreen: some View {
        // The phase word sits high (fixed top padding), the circle floats in the space below it,
        // and "End early" rests at the bottom — matching the mockup's running frame.
        VStack(spacing: 0) {
            pacer

            // Slate, not softTaupe: this is the session's only exit, and softTaupe measures
            // 2.03:1 on parchment — every other muted label in this file already uses slate
            // (PRIV-24 completion, caught by the 2026-08-22 accessibility audit).
            Button("End early") { stopSession() }
                .font(FernletFramedFont.button)
                .foregroundStyle(WorldPalette.mossInk)
                .fernletTapTarget()
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    /// The pacer itself — the phase word and the swelling circle — as ONE accessibility element
    /// whose spoken *value* is the current phase.
    ///
    /// Why a value and not a label: VoiceOver re-speaks the focused element's value when it changes,
    /// and does not re-read a `Text` that merely swapped its contents. So a session that was
    /// entirely visual (both circles are `accessibilityHidden`, the word never announced, and the
    /// haptic was then one tap identical for inhale, hold and exhale — and is switchable off) now paces
    /// out loud, in step with the animation, for as long as the pacer holds focus.
    ///
    /// Deliberately NOT the whole running screen, which is what the 2026-08-22 audit's prose
    /// proposed: `accessibilityElement(children: .ignore)` around the full `VStack` would swallow
    /// "End early" — the session's only exit — and leave a blind user inside a three-minute exercise
    /// with no way out. The grouping stops above the button.
    private var pacer: some View {
        // World (b3-breathe-session): the rings first, the phase word under them in big Fraunces.
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            breathingCircle
                .frame(height: 300)
            Text(phaseLabel)
                .font(.custom(FernletFontName.frauncesSemiBold, size: 40, relativeTo: .largeTitle))
                .foregroundStyle(WorldPalette.mossInk)
                .animation(.easeInOut(duration: 0.3), value: phaseLabel)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(BreathingCopy.pacerLabel))
        .accessibilityValue(Text(phaseLabel))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($isPacerFocused)
    }

    // MARK: - Finished

    private var finishedScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            checkMedallion
                .padding(.bottom, 24)

            Text(BreathingCopy.allDone)
                .font(.custom(FernletFontName.frauncesSemiBold, size: 40, relativeTo: .largeTitle))
                .foregroundStyle(WorldPalette.bark)
                .padding(.bottom, 10)

            Text(BreathingCopy.finished(minutes: minutes))
                .font(FernletFramedFont.field)
                .foregroundStyle(WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            Spacer()

            // World (b3-breathe-done): "Once more" is the full-width framed primary at the foot; Done
            // (which leaves the tool, exactly as Grounding's does) moved to the header's top right.
            Button {
                startSession()
            } label: {
                Text("Once more")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 20)
        .transition(.opacity.combined(with: .offset(y: 14)))
    }

    /// Nested translucent moss circles with a soft highlight — the "breath" made visible.
    /// In setup it eases idly (a calm resting scale); in running it swells with `circleScale`.
    private var breathingCircle: some View {
        // World (b3-breathe-setup, -session): three framed moss rings, pale to deep, that swell and
        // settle together with `circleScale`.
        ZStack {
            breathingRing(diameter: 250, fill: Self.ringPale)
            breathingRing(diameter: 196, fill: Self.ringMid)
            breathingRing(diameter: 140, fill: Self.ringDeep)
        }
        .accessibilityHidden(true)
    }

    /// One ring of the pacer: a moss disc in the 3-pt ink frame, scaled with the breath.
    private func breathingRing(diameter: CGFloat, fill: Color) -> some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 3 / max(circleScale, 0.3)))
            .frame(width: diameter, height: diameter)
            .scaleEffect(circleScale)
    }

    /// The rings' three moss tones (`b3-breathe-*`, the kit's `#DCE6D2`, `#B9D1A8`, `#8DB879`), with
    /// darker greens on dark paper.
    private static let ringPale = Color(light: Color(red: 0.863, green: 0.902, blue: 0.824),
                                        dark: Color(red: 0.231, green: 0.282, blue: 0.204))
    private static let ringMid = Color(light: Color(red: 0.725, green: 0.820, blue: 0.659),
                                       dark: Color(red: 0.322, green: 0.416, blue: 0.267))
    private static let ringDeep = Color(light: Color(red: 0.553, green: 0.722, blue: 0.475),
                                        dark: Color(red: 0.420, green: 0.565, blue: 0.341))

    /// The finish reward (`b3-breathe-done`): a moss medal in the ink frame with its shadow, cradling
    /// the white pixel tick.
    private var checkMedallion: some View {
        ZStack {
            Circle()
                .fill(WorldPalette.ink.opacity(0.22))
                .frame(width: 112, height: 112)
                .offset(y: 5)
            Circle()
                .fill(WorldPalette.accent)
                .frame(width: 112, height: 112)
                .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 3))
            WorldSpriteView(sprite: WorldSprites.check, scale: 6, tint: WorldPalette.onAccent)
        }
        .accessibilityHidden(true)
    }

    /// Pattern, length and haptics in one framed card (`b3-breathe-setup`).
    private var setupControls: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Pattern")
                    HStack(spacing: 10) {
                        ForEach(BreathingPreset.all) { candidate in
                            patternTile(candidate)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Length")
                    HStack(spacing: 8) {
                        ForEach(1...3, id: \.self) { candidate in
                            lengthPill(candidate)
                        }
                    }
                }
                hapticsRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Haptics: what the taps feel like, the app-wide-off note, and the switch.
    private var hapticsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Haptics")
                    .font(FernletFramedFont.rowTitle.weight(.bold))
                    .foregroundStyle(WorldPalette.bark)
                Text("soft taps in, one tap out",
                     comment: "Under the breathing screen's Haptics switch: what the haptics feel like. Several soft taps while breathing in, a single tap as the breath goes out, nothing while holding.")
                    .font(FernletFramedFont.rowValue)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                // Owner's decision 5: this switch stays, under the app-wide level. When that
                // level is Off, an "on" switch here plays nothing, so say why.
                if appHapticsLevel == .off {
                    Text("Haptics are off for all of Fernlet in Settings.")
                        .font(FernletFramedFont.rowValue)
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                        .accessibilityIdentifier("breathing.hapticsOffNote")
                }
            }
            Spacer()
            // The switch draws with its label hidden — the "Haptics" heading to its left is the
            // visible one — but it still needs a NAME. As `Toggle("", isOn:)` VoiceOver read it
            // as an anonymous "switch button, on" and Voice Control had nothing to say to press
            // it. `labelsHidden()` keeps the layout identical and gives it the word back. World: the
            // framed switch the app root sets.
            Toggle("Haptics", isOn: $hapticsEnabled)
                .labelsHidden()
                // Stated here: a sheet the root presents does not inherit the root's toggle style.
                .toggleStyle(FernletFramedToggleStyle())
        }
    }

    /// One pattern tile (`b3-breathe-setup`): a framed paper tile, the chosen one framed in moss with
    /// the pixel tick.
    private func patternTile(_ candidate: BreathingPreset) -> some View {
        let selected = preset == candidate
        let shape = RoundedRectangle(cornerRadius: 10)
        return Button {
            presetID = candidate.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(candidate.name)
                        .font(FernletFramedFont.rowTitle.weight(.bold))
                        .foregroundStyle(WorldPalette.bark)
                    Spacer(minLength: 4)
                    if selected {
                        WorldSpriteView(sprite: WorldSprites.check, scale: 2)
                            .accessibilityHidden(true)
                    }
                }
                Text(candidate.caption)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(WorldPalette.paperLight, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 2.5))
            .padding(selected ? 3 : 0)
            .overlay { if selected { RoundedRectangle(cornerRadius: 13).strokeBorder(WorldPalette.moss, lineWidth: 3) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // T1-5: a hand-rolled selection tile — the checkmark glyph is otherwise the only signal.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One length chip (`b3-breathe-setup`): the app's framed chip, filled when chosen.
    private func lengthPill(_ candidate: Int) -> some View {
        let selected = minutes == candidate
        return Button {
            minutes = candidate
        } label: {
            Text("\(candidate) min")
        }
        .buttonStyle(ChipButtonStyle(selected: selected))
        // T1-5: a selection chip — the fill is otherwise the only signal (the chip style also adds
        // the selected trait; saying it here keeps the contract visible).
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Return to the setup screen from the finished screen (no session running).
    private func finishToSetup() {
        isFinished = false
        isRunning = false
        phaseLabel = BreathingCopy.ready
        circleScale = restingScale
    }

    // MARK: - Session

    private func startSession() {
        // R5/R2: the loop below is bounded by wall clock, and that bound only holds because every
        // iteration sleeps a non-empty preset. State both preconditions at entry rather than trusting
        // the two curated presets and the 1–3 length pills to stay the only inputs.
        guard !isRunning, !preset.phases.isEmpty, (1...3).contains(minutes) else { return }
        isRunning = true
        isFinished = false
        // Start from the small resting scale so the first "Breathe in" visibly swells outward.
        circleScale = restingScale
        let start = Date()
        let duration = TimeInterval(minutes * 60)
        let phases = preset.phases

        sessionTask = Task { @MainActor in
            // Full cycles until the chosen length is reached; the cycle in progress when the
            // timer crosses the line finishes gently rather than cutting off mid-breath.
            // R2: the wall-clock bound (<= 180 s, and every cycle sleeps >= 16 s of preset) is
            // backed by a named iteration cap so the loop states its own maximum.
            var cycles = 0
            while cycles < Self.maxCycles, Date().timeIntervalSince(start) < duration {
                cycles += 1
                for phase in phases {
                    guard !Task.isCancelled else { return }
                    phaseLabel = phase.label
                    withAnimation(.easeInOut(duration: phase.seconds)) {
                        circleScale = phase.targetScale
                    }
                    do {
                        try await pace(phase)
                    } catch {
                        // A cancelled sleep IS the abandon signal (End early / background /
                        // onDisappear): leave at the sleep rather than one phase later.
                        return
                    }
                }
            }
            guard !Task.isCancelled else { return }
            completeSession(start: start)
        }
    }

    /// Sleeps out one phase, tapping at each of its offsets (``BreathingPacerHaptics``) in step with
    /// the circle. Throws when the session is cancelled, at whichever sleep it was in.
    ///
    /// R2: bounded by the phase's offsets, at most ``BreathingPacerHaptics/inhaleTaps``.
    private func pace(_ phase: BreathPhase) async throws {
        var elapsed = 0.0
        for offset in BreathingPacerHaptics.tapOffsets(for: phase) {
            // The phase's first tap is at its start: played at once, with the words and the circle.
            if offset > elapsed { try await Task.sleep(for: .seconds(offset - elapsed)) }
            elapsed = offset
            BreathingPacerHaptics.tap(hapticsEnabled: hapticsEnabled)
        }
        try await Task.sleep(for: .seconds(phase.seconds - elapsed))
    }

    private func completeSession(start: Date) {
        // B3: the session reached its full length — the same quiet success every time, behind the
        // same two switches as the pacer's taps. "All done" and the finish screen are its twin.
        BreathingPacerHaptics.finish(hapticsEnabled: hapticsEnabled)
        phaseLabel = BreathingCopy.allDone
        withAnimation(.easeInOut(duration: 1.2)) { circleScale = restingScale }
        // Cross-fade into the finished screen (matching the mockup's fade-and-rise) rather than snapping.
        withAnimation(.easeOut(duration: 0.6)) {
            isRunning = false
            isFinished = true
        }
        onSessionComplete(start, Date())
    }

    /// Ends the session early: no completion callback (no Health write, no achievement) —
    /// stopping early is always allowed and never judged.
    private func stopSession() {
        sessionTask?.cancel()
        sessionTask = nil
        isRunning = false
        phaseLabel = BreathingCopy.ready
        withAnimation(.easeInOut(duration: 0.8)) { circleScale = restingScale }
    }

}

/// The pacer's felt rhythm (report C3, answering accessibility finding T0-4's "one undifferentiated
/// haptic"): each part of the breath feels different, so someone with their eyes closed can tell
/// where they are without the words.
///
/// - **Breathe in:** ``inhaleTaps`` taps, evenly spaced across the inhale as the circle swells.
/// - **Hold:** nothing. The stillness is the hold.
/// - **Breathe out:** one tap as the exhale begins.
///
/// Every tap is FernletUI's one breathing feel, `pace`: a short soft tap, never a continuous buzz,
/// so the inhale is told apart by count and rhythm, not strength. Every cue here — the taps and the
/// finish — plays only when both this screen's Haptics switch and the app-wide level allow it
/// (owner's decision 5, "Keep it"), and none ever carries a sound.
///
/// Main-actor, like the player it drives.
@MainActor
enum BreathingPacerHaptics {
    /// How many taps carry an inhale.
    static let inhaleTaps = 3

    /// When each of `phase`'s taps falls, in seconds from the phase's start, earliest first.
    static func tapOffsets(for phase: BreathPhase) -> [Double] {
        switch phase.kind {
        case .inhale: (0..<inhaleTaps).map { phase.seconds * Double($0) / Double(inhaleTaps) }
        case .hold: []
        case .exhale: [0]
        }
    }

    /// One pacer tap.
    ///
    /// - Parameters:
    ///   - hapticsEnabled: The screen's own Haptics switch.
    ///   - feedback: Test seam: the player. `nil` (production) is ``FernletFeedback/system``.
    ///   - defaults: Where the app-wide level is read; tests pass a private suite.
    static func tap(hapticsEnabled: Bool, feedback: FernletFeedback? = nil, defaults: UserDefaults = .standard) {
        (feedback ?? .system).play(.pace, preferences: .resolved(haptics: hapticsEnabled, in: defaults))
    }

    /// A session that ran to its full length (report B3): `done`, never on an early end, which is
    /// "never judged" and so says nothing.
    ///
    /// - Parameters:
    ///   - hapticsEnabled: The screen's own Haptics switch.
    ///   - feedback: Test seam: the player. `nil` (production) is ``FernletFeedback/system``.
    ///   - defaults: Where the app-wide level is read; tests pass a private suite.
    static func finish(hapticsEnabled: Bool, feedback: FernletFeedback? = nil, defaults: UserDefaults = .standard) {
        (feedback ?? .system).play(.done, preferences: .resolved(haptics: hapticsEnabled, in: defaults))
    }
}

/// The breathing timer's device-local switch: whether its pacer taps with the breath (on until the person
/// turns it off). The key is a FROZEN persisted token, spelled once here; every access stays in this
/// file, where the wipe wall resolves it to its literal. "Delete everything" keeps it
/// (`Docs/PrivacyWipeCoverage.md`): a preference, not a record.
enum BreathingPreferences {
    /// `Bool`, default ``defaultHaptics``.
    static let hapticsKey = "fernlet.breathing.haptics"
    /// The switch until the person changes it: on.
    static let defaultHaptics = true
}

/// The breathing switch as Settings › Sounds & haptics shows it: the same key the breathing screen's
/// Haptics switch edits, never a copy.
struct BreathingHapticsSwitch: View {
    @AppStorage(BreathingPreferences.hapticsKey) private var haptics = BreathingPreferences.defaultHaptics

    var body: some View {
        SoundsHapticsSwitchRow(
            title: "Breathing haptics",
            footnote: "Soft taps as you breathe in and one as you breathe out, in First aid › Slow breathing.",
            isOn: $haptics,
            identifier: "settings.soundsHaptics.breathingHaptics"
        )
    }
}
