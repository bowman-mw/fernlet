//
//  BreathingExerciseView.swift
//  Fernlet
//
//  A calm animated breathing circle: box breathing (4-4-4-4) or relax (4-7-8), 1–3 minutes,
//  optional soft haptics on phase changes. Completing a session (never abandoning one)
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
    /// The phase's words — the running screen's only text, and the value VoiceOver speaks each time
    /// the pacer turns.
    ///
    /// A `LocalizedStringResource` rather than a `String`: `Text(_:)` renders it and
    /// `.accessibilityValue(Text(_:))` speaks it, and both of those resolve the catalog. A plain
    /// `String` would reach `Text`'s NON-localizing initializer instead, which is why this line used
    /// to be English forever with a clean build. It is display copy, never a token: nothing persists
    /// it (``BreathingPreset/id`` is the stored key) and nothing matches on it, so translating it is
    /// safe.
    let label: LocalizedStringResource
    let seconds: Double
    /// Target circle scale at the END of the phase (holds keep the previous target).
    let targetScale: CGFloat
}

/// A named breathing pattern: an ordered list of ``BreathPhase``s plus display copy for the
/// pattern picker.
///
/// Two curated presets exist — ``box`` (4-4-4-4) and ``relax`` (4-7-8) — surfaced on
/// ``BreathingExerciseView``'s setup screen via ``all``; the session loop repeats the preset's
/// phases until the chosen length elapses.
struct BreathingPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let caption: String
    let phases: [BreathPhase]

    /// Box breathing: in 4 — hold 4 — out 4 — hold 4.
    static let box = BreathingPreset(
        id: "box",
        name: "Box",
        caption: "In 4 · hold 4 · out 4 · hold 4",
        phases: [
            BreathPhase(label: BreathingCopy.breatheIn, seconds: 4, targetScale: 1.0),
            BreathPhase(label: BreathingCopy.hold, seconds: 4, targetScale: 1.0),
            BreathPhase(label: BreathingCopy.breatheOut, seconds: 4, targetScale: 0.55),
            BreathPhase(label: BreathingCopy.hold, seconds: 4, targetScale: 0.55)
        ]
    )

    /// Relaxing breath: in 4 — hold 7 — out 8.
    static let relax = BreathingPreset(
        id: "relax",
        name: "Relax",
        caption: "In 4 · hold 7 · out 8",
        phases: [
            BreathPhase(label: BreathingCopy.breatheIn, seconds: 4, targetScale: 1.0),
            BreathPhase(label: BreathingCopy.hold, seconds: 7, targetScale: 1.0),
            BreathPhase(label: BreathingCopy.breatheOut, seconds: 8, targetScale: 0.55)
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
enum BreathingCopy {
    /// The inhale phase.
    static let breatheIn = LocalizedStringResource(
        "Breathe in",
        comment: "Shown and spoken while the breathing pacer's circle expands. An instruction to inhale, given to someone with their eyes closed — keep it short and calm.")

    /// A held breath, between the inhale and the exhale (and, in box breathing, after the exhale).
    static let hold = LocalizedStringResource(
        "Hold",
        comment: "Shown and spoken while the breathing pacer rests between breaths. It means 'hold your breath', not 'keep' or 'wait'.")

    /// The exhale phase.
    static let breatheOut = LocalizedStringResource(
        "Breathe out",
        comment: "Shown and spoken while the breathing pacer's circle contracts. An instruction to exhale.")

    /// The resting state, before a session starts and after one is ended early.
    static let ready = LocalizedStringResource(
        "Ready when you are",
        comment: "Shown and spoken by the breathing pacer while no session is running. Unhurried and permission-giving — the tool waits, it does not prompt.")

    /// The last thing the pacer says, as a completed session fades into the finish screen.
    static let allDone = LocalizedStringResource(
        "All done",
        comment: "Shown and spoken by the breathing pacer the moment a session reaches its full length.")

    /// The pacer's stable accessibility NAME. Stable is the point: VoiceOver re-speaks a focused
    /// element's changed value, and a changed label would instead be read as a new element.
    static let pacerLabel = LocalizedStringResource(
        "Breathing pacer",
        comment: "VoiceOver name for the animated breathing circle. Its spoken value is the current phase — 'Breathe in', 'Hold', 'Breathe out'.")
}

/// The slow-breathing exercise: a softly swelling circle guided through a chosen
/// ``BreathingPreset`` for 1–3 minutes, with optional soft haptics on phase changes.
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
    @AppStorage("fernlet.breathing.haptics") private var hapticsEnabled = true

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

    /// Top highlight stop of the core sphere gradient (mockup #AECC9F / #9DC08F) — a surface-local
    /// hue, so it's a plain constant rather than a shared token, per the GroundingView pattern.
    private static let mintHighlight = Color(light: Color(red: 0.682, green: 0.800, blue: 0.624),
                                             dark:  Color(red: 0.616, green: 0.753, blue: 0.561))

    var body: some View {
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
        .background(Color.parchment)
        .navigationTitle("Slow breathing")
        .navigationBarTitleDisplayMode(.inline)
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
                    Text("Ready when you are.")
                        .font(.custom(FernletFontName.instrumentSerifItalic, size: 19, relativeTo: .body))
                        .foregroundStyle(Color.slate)
                }

                Spacer(minLength: 8)

                setupControls

                Button {
                    startSession()
                } label: {
                    Text("Begin")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.parchmentInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("firstAid.breathing.begin")
            }
            .padding(20)
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
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
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
    /// one `.soft` haptic is identical for inhale, hold and exhale — and switchable off) now paces
    /// out loud, in step with the animation, for as long as the pacer holds focus.
    ///
    /// Deliberately NOT the whole running screen, which is what the 2026-08-22 audit's prose
    /// proposed: `accessibilityElement(children: .ignore)` around the full `VStack` would swallow
    /// "End early" — the session's only exit — and leave a blind user inside a three-minute exercise
    /// with no way out. The grouping stops above the button.
    private var pacer: some View {
        VStack(spacing: 0) {
            Text(phaseLabel)
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.moss)
                .animation(.easeInOut(duration: 0.3), value: phaseLabel)
                .padding(.top, 90)

            breathingCircle
                .frame(maxHeight: .infinity)
        }
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
                .padding(.bottom, 30)

            Text("All done")
                .font(.fernlet(.display))
                .foregroundStyle(Color.bark)
                .padding(.bottom, 12)

            Text(minutes == 1
                 ? "That was a whole minute of care. Nicely done."
                 : "That was \(minutes) whole minutes of care. Nicely done.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: 260)
                .padding(.bottom, 34)

            Button {
                startSession()
            } label: {
                Text("Once more")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.parchmentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300)
            .padding(.bottom, 10)

            // "Done" leaves the tool, exactly as Grounding's does — the two sibling exercises used
            // to give their identically-placed secondary action two different meanings ("Done for
            // now" quietly rewound to this tool's own setup screen). "Once more" above is the
            // repeat.
            Button("Done") {
                finishToSetup()
                dismiss()
            }
            .font(.fernlet(.label))
            .foregroundStyle(Color.slate)

            Spacer()
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 40)
        .transition(.opacity.combined(with: .offset(y: 14)))
    }

    /// Nested translucent moss circles with a soft highlight — the "breath" made visible.
    /// In setup it eases idly (a calm resting scale); in running it swells with `circleScale`.
    private var breathingCircle: some View {
        ZStack {
            // Feathered outer rings — fern fading to clear, so the halo has no hard edge.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.fern.opacity(0.14), Color.fern.opacity(0)],
                        center: .center,
                        startRadius: 59,
                        endRadius: 101
                    )
                )
                .frame(width: 280, height: 280)
                .scaleEffect(circleScale)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.fern.opacity(0.22), Color.fern.opacity(0)],
                        center: .center,
                        startRadius: 49,
                        endRadius: 84
                    )
                )
                .frame(width: 216, height: 216)
                .scaleEffect(circleScale)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Self.mintHighlight, Color.fern, Color.moss],
                        center: UnitPoint(x: 0.42, y: 0.36),
                        startRadius: 4,
                        endRadius: 100
                    )
                )
                .frame(width: 150, height: 150)
                .scaleEffect(circleScale)
                .shadow(color: Color.moss.opacity(0.28), radius: 22, x: 0, y: 12)
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.5), Color.white.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: 28
                            )
                        )
                        .frame(width: 56, height: 56)
                        .offset(x: -22, y: -22)
                        .scaleEffect(circleScale)
                )
        }
        .accessibilityHidden(true)
    }

    /// A soft moss medallion with a gentle amber halo, cradling a check — the finish reward.
    private var checkMedallion: some View {
        ZStack {
            // Feathered amber halo — goldenrod fading to clear, no hard disc edge.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.goldenrod.opacity(0.14), Color.goldenrod.opacity(0)],
                        center: .center,
                        startRadius: 32,
                        endRadius: 56
                    )
                )
                .frame(width: 150, height: 150)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Self.mintHighlight, Color.fern, Color.moss],
                        center: UnitPoint(x: 0.42, y: 0.36),
                        startRadius: 4,
                        endRadius: 70
                    )
                )
                .frame(width: 104, height: 104)
                .shadow(color: Color.moss.opacity(0.28), radius: 18, x: 0, y: 10)
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.parchment)
        }
        .accessibilityHidden(true)
    }

    private var setupControls: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haptics")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text("a soft tap on each turn")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                }
                Spacer()
                // The switch draws with its label hidden — the "Haptics" heading to its left is the
                // visible one — but it still needs a NAME. As `Toggle("", isOn:)` VoiceOver read it
                // as an anonymous "switch button, on" and Voice Control had nothing to say to press
                // it. `labelsHidden()` keeps the layout identical and gives it the word back.
                Toggle("Haptics", isOn: $hapticsEnabled)
                    .labelsHidden()
                    .tint(Color.moss)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .fernletSmallShadow()
    }

    private func patternTile(_ candidate: BreathingPreset) -> some View {
        let selected = preset == candidate
        return Button {
            presetID = candidate.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.custom(FernletFontName.dmSerifDisplay, size: 17, relativeTo: .body))
                    .foregroundStyle(Color.bark)
                Text(candidate.caption)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.parchment, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .background(Color.moss.opacity(selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.moss.opacity(selected ? 1 : 0), lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.moss)
                        .padding(9)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func lengthPill(_ candidate: Int) -> some View {
        let selected = minutes == candidate
        return Button {
            minutes = candidate
        } label: {
            Text("\(candidate) min")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.parchment, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(Color.moss.opacity(selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.moss.opacity(selected ? 1 : 0), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
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
                    tickHaptic()
                    withAnimation(.easeInOut(duration: phase.seconds)) {
                        circleScale = phase.targetScale
                    }
                    do {
                        try await Task.sleep(for: .seconds(phase.seconds))
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

    private func completeSession(start: Date) {
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

    private func tickHaptic() {
        #if canImport(UIKit)
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        #endif
    }
}
