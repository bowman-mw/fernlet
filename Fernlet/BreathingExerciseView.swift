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
    @State private var sessionStart: Date?
    @State private var sessionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            breathingCircle

            Text(phaseLabel)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.bark)
                .animation(.easeInOut(duration: 0.3), value: phaseLabel)

            Spacer(minLength: 8)

            if isFinished {
                finishedFooter
            } else if isRunning {
                Button("End early") { stopSession() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.slate)
            } else {
                setupControls
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.parchment)
        .navigationTitle("Slow breathing")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { sessionTask?.cancel() }
    }

    private var breathingCircle: some View {
        ZStack {
            Circle()
                .fill(Color.moss.opacity(0.10))
                .frame(width: 240, height: 240)
            Circle()
                .fill(Color.moss.opacity(0.22))
                .frame(width: 220, height: 220)
                .scaleEffect(circleScale)
            Circle()
                .fill(Color.moss.opacity(0.30))
                .frame(width: 150, height: 150)
                .scaleEffect(circleScale)
        }
        .accessibilityHidden(true)
    }

    private var setupControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(BreathingPreset.all) { candidate in
                    Button {
                        preset = candidate
                    } label: {
                        VStack(spacing: 2) {
                            Text(candidate.name).font(.subheadline.weight(.semibold))
                            Text(candidate.caption).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(ChipButtonStyle(selected: preset == candidate))
                }
            }

            HStack(spacing: 8) {
                ForEach(1...3, id: \.self) { candidate in
                    Button("\(candidate) min") { minutes = candidate }
                        .buttonStyle(ChipButtonStyle(selected: minutes == candidate))
                }
            }

            Toggle("Gentle haptics", isOn: $hapticsEnabled)
                .font(.subheadline)
                .padding(.horizontal, 4)

            Button {
                startSession()
            } label: {
                Text("Begin")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("firstAid.breathing.begin")
        }
    }

    private var finishedFooter: some View {
        VStack(spacing: 10) {
            Text("That was a whole \(minutes == 1 ? "minute" : "\(minutes) minutes") of care. Nicely done.")
                .font(.subheadline)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Button("Once more") {
                isFinished = false
                phaseLabel = "Ready when you are"
                circleScale = 0.55
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.moss)
        }
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
