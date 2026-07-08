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
    @State private var circleScale: CGFloat = 0.55
    @State private var idleBreathing = false
    @State private var sessionStart: Date?
    @State private var sessionTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

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
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            VStack(spacing: 20) {
                breathingCircle
                    .scaleEffect(idleBreathing ? 1.0 : 0.94)
                    .onAppear {
                        // A gentle resting sway so the circle feels alive before Begin.
                        circleScale = 0.94
                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            idleBreathing = true
                        }
                    }
                    .onDisappear { idleBreathing = false }
                Text("Ready when you are.")
                    .font(.system(size: 19, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Color.slate)
            }

            Spacer(minLength: 8)

            setupControls

            Button {
                startSession()
            } label: {
                Text("Begin")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("firstAid.breathing.begin")
        }
        .padding(20)
    }

    // MARK: - Running

    private var runningScreen: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            Text(phaseLabel)
                .font(.system(size: 30, weight: .medium, design: .serif))
                .foregroundStyle(Color.moss)
                .animation(.easeInOut(duration: 0.3), value: phaseLabel)

            breathingCircle

            Spacer(minLength: 8)

            Button("End early") { stopSession() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.softTaupe)
        }
        .padding(20)
    }

    // MARK: - Finished

    private var finishedScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            checkMedallion
                .padding(.bottom, 30)

            Text("All done")
                .font(.system(size: 36, weight: .semibold, design: .serif))
                .foregroundStyle(Color.bark)
                .padding(.bottom, 12)

            Text("That was a whole \(minutes == 1 ? "minute" : "\(minutes) minutes") of care. Nicely done.")
                .font(.system(size: 19, weight: .regular, design: .serif))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: 260)
                .padding(.bottom, 34)

            Button {
                startSession()
            } label: {
                Text("Once more")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300)
            .padding(.bottom, 10)

            Button("Done for now") { finishToSetup() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.slate)

            Spacer()
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 40)
        .transition(.opacity)
    }

    /// Nested translucent moss circles with a soft highlight — the "breath" made visible.
    /// In setup it eases idly (a calm resting scale); in running it swells with `circleScale`.
    private var breathingCircle: some View {
        ZStack {
            Circle()
                .fill(Color.moss.opacity(0.12))
                .frame(width: 280, height: 280)
                .scaleEffect(circleScale)
            Circle()
                .fill(Color.moss.opacity(0.20))
                .frame(width: 216, height: 216)
                .scaleEffect(circleScale)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.fern, Color.moss],
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
            Circle()
                .fill(Color.goldenrod.opacity(0.14))
                .frame(width: 150, height: 150)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.fern, Color.moss],
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
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.bark)
                    Text("a soft tap on each turn")
                        .font(.system(size: 13, weight: .regular, design: .serif).italic())
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
        .shadow(color: .bark.opacity(0.05), radius: 3, x: 0, y: 1)
    }

    private func patternTile(_ candidate: BreathingPreset) -> some View {
        let selected = preset == candidate
        return Button {
            preset = candidate
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .foregroundStyle(Color.bark)
                Text(candidate.caption)
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.parchment, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.parchment, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        circleScale = 0.55
    }

    // MARK: - Session

    private func startSession() {
        guard !isRunning else { return }
        isRunning = true
        isFinished = false
        let start = Date()
        sessionStart = start
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
        isRunning = false
        isFinished = true
        phaseLabel = "All done"
        withAnimation(.easeInOut(duration: 1.2)) { circleScale = 0.55 }
        onSessionComplete(start, Date())
    }

    /// Ends the session early: no completion callback (no Health write, no achievement) —
    /// stopping early is always allowed and never judged.
    private func stopSession() {
        sessionTask?.cancel()
        sessionTask = nil
        isRunning = false
        sessionStart = nil
        phaseLabel = "Ready when you are"
        withAnimation(.easeInOut(duration: 0.8)) { circleScale = 0.55 }
    }

    private func tickHaptic() {
        #if canImport(UIKit)
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        #endif
    }
}
