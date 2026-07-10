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
#endif

/// One phase of a breath cycle (e.g. "Breathe in" for 4 seconds toward the expanded circle).
struct BreathPhase: Equatable {
    let label: String
    let seconds: Double
    /// Target circle scale at the END of the phase (holds keep the previous target).
    let targetScale: CGFloat
}

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
            BreathPhase(label: "Breathe in", seconds: 4, targetScale: 1.0),
            BreathPhase(label: "Hold", seconds: 4, targetScale: 1.0),
            BreathPhase(label: "Breathe out", seconds: 4, targetScale: 0.55),
            BreathPhase(label: "Hold", seconds: 4, targetScale: 0.55)
        ]
    )

    /// Relaxing breath: in 4 — hold 7 — out 8.
    static let relax = BreathingPreset(
        id: "relax",
        name: "Relax",
        caption: "In 4 · hold 7 · out 8",
        phases: [
            BreathPhase(label: "Breathe in", seconds: 4, targetScale: 1.0),
            BreathPhase(label: "Hold", seconds: 7, targetScale: 1.0),
            BreathPhase(label: "Breathe out", seconds: 8, targetScale: 0.55)
        ]
    )

    static let all: [BreathingPreset] = [.box, .relax]
}

struct BreathingExerciseView: View {
    /// Called once when a session runs to its full chosen length (not when abandoned early).
    var onSessionComplete: (_ start: Date, _ end: Date) -> Void

    @State private var preset: BreathingPreset = .box
    @State private var minutes = 1
    @State private var hapticsEnabled = true

    @State private var isRunning = false
    @State private var isFinished = false
    @State private var phaseLabel = "Ready when you are"
    @State private var circleScale: CGFloat = 0.6
    @State private var idleBreathing = false
    @State private var sessionTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

    /// The circle's small resting scale — it sways gently around this so the first
    /// "Breathe in" visibly swells out of it (mockup rests ~168px against a 280px full).
    private let restingScale: CGFloat = 0.6

    /// Top highlight stop of the core sphere gradient (mockup #AECC9F / #9DC08F) — a surface-local
    /// hue, so it's a plain constant rather than a shared token, per the GroundingView pattern.
    private static let mintHighlight = Color(light: Color(red: 0.682, green: 0.800, blue: 0.624),
                                             dark:  Color(red: 0.616, green: 0.753, blue: 0.561))

    /// Fixed warm parchment for label ink on the moss CTAs — stays light in both modes
    /// (the adaptive Color.parchment flips dark), matching the mockup's #F5EFE0 on-accent.
    private static let onMoss = Color(red: 0.961, green: 0.937, blue: 0.878)

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
        .onDisappear { sessionTask?.cancel() }
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
                        .foregroundStyle(Self.onMoss)
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
            Text(phaseLabel)
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.moss)
                .animation(.easeInOut(duration: 0.3), value: phaseLabel)
                .padding(.top, 90)

            breathingCircle
                .frame(maxHeight: .infinity)

            Button("End early") { stopSession() }
                .font(.fernlet(.label))
                .foregroundStyle(Color.softTaupe)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
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
                    .foregroundStyle(Self.onMoss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300)
            .padding(.bottom, 10)

            Button("Done for now") { finishToSetup() }
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
                Toggle("", isOn: $hapticsEnabled)
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
            preset = candidate
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
        phaseLabel = "Ready when you are"
        circleScale = restingScale
    }

    // MARK: - Session

    private func startSession() {
        guard !isRunning else { return }
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
            while Date().timeIntervalSince(start) < duration {
                for phase in phases {
                    guard !Task.isCancelled else { return }
                    phaseLabel = phase.label
                    tickHaptic()
                    withAnimation(.easeInOut(duration: phase.seconds)) {
                        circleScale = phase.targetScale
                    }
                    try? await Task.sleep(for: .seconds(phase.seconds))
                }
            }
            guard !Task.isCancelled else { return }
            completeSession(start: start)
        }
    }

    private func completeSession(start: Date) {
        phaseLabel = "All done"
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
        phaseLabel = "Ready when you are"
        withAnimation(.easeInOut(duration: 0.8)) { circleScale = restingScale }
    }

    private func tickHaptic() {
        #if canImport(UIKit)
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        #endif
    }
}
