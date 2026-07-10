//
//  GroundingView.swift
//  Fernlet
//
//  5-4-3-2-1 grounding: a stepped, tap-to-advance flow (no timers, no pressure) that
//  walks one gentle sense at a time and ends on a soft affirmation. Each sense fills the
//  screen with its own calm colour wash; tapping anywhere is the only pace.
//

import SwiftUI

struct GroundingView: View {
    private struct GroundingStep {
        let count: Int
        let icon: String
        let prompt: String
        let hint: String
        /// The calm colour that washes the whole screen for this sense.
        let tint: Color
        /// A deeper ink drawn from the same hue, for the big numeral + icon.
        let ink: Color
        /// A lighter mid-tone from the same hue, for the progress dots + kicker.
        let mid: Color
        /// How strongly this sense's wash tints the screen (see-to-taste, per sense).
        let washOpacity: Double
    }

    // Per-sense palette. These sit outside the shared adaptive-colour set (each sense needs
    // its own calm hue), so they're kept as local constants here — deliberately gentle, and
    // eased a touch lighter in dark mode so the deep inks stay legible.
    private static let seeTint = Color(light: Color(red: 0.541, green: 0.678, blue: 0.494),
                                       dark:  Color(red: 0.541, green: 0.678, blue: 0.494))
    private static let seeInk = Color(light: Color(red: 0.255, green: 0.384, blue: 0.227),
                                      dark:  Color(red: 0.682, green: 0.792, blue: 0.616))
    private static let seeMid = Color(red: 0.369, green: 0.486, blue: 0.329)
    // touchTint is the same hue as the shared okay-state token — one source of truth.
    private static let touchTint = Color.stateOkay
    private static let touchInk = Color(light: Color(red: 0.541, green: 0.384, blue: 0.141),
                                        dark:  Color(red: 0.831, green: 0.694, blue: 0.443))
    private static let touchMid = Color(red: 0.627, green: 0.486, blue: 0.235)
    private static let hearTint = Color(light: Color(red: 0.549, green: 0.651, blue: 0.714),
                                        dark:  Color(red: 0.549, green: 0.651, blue: 0.714))
    private static let hearInk = Color(light: Color(red: 0.298, green: 0.392, blue: 0.447),
                                       dark:  Color(red: 0.682, green: 0.776, blue: 0.831))
    private static let hearMid = Color(red: 0.384, green: 0.475, blue: 0.541)
    private static let smellTint = Color(light: Color(red: 0.663, green: 0.608, blue: 0.706),
                                         dark:  Color(red: 0.663, green: 0.608, blue: 0.706))
    private static let smellInk = Color(light: Color(red: 0.373, green: 0.329, blue: 0.439),
                                        dark:  Color(red: 0.749, green: 0.702, blue: 0.804))
    private static let smellMid = Color(red: 0.471, green: 0.416, blue: 0.529)
    private static let tasteTint = Color(light: Color(red: 0.753, green: 0.541, blue: 0.439),
                                         dark:  Color(red: 0.753, green: 0.541, blue: 0.439))
    private static let tasteInk = Color(light: Color(red: 0.478, green: 0.290, blue: 0.220),
                                        dark:  Color(red: 0.831, green: 0.639, blue: 0.549))
    private static let tasteMid = Color(red: 0.596, green: 0.392, blue: 0.322)

    private static let steps: [GroundingStep] = [
        GroundingStep(count: 5, icon: "eye", prompt: "Notice five things you can see", hint: "Anything at all — a corner of the ceiling, the light on your hand.", tint: seeTint, ink: seeInk, mid: seeMid, washOpacity: 0.16),
        GroundingStep(count: 4, icon: "hand.raised", prompt: "Notice four things you can touch", hint: "The fabric on your knee, a cool table edge, your own two hands.", tint: touchTint, ink: touchInk, mid: touchMid, washOpacity: 0.15),
        GroundingStep(count: 3, icon: "ear", prompt: "Notice three things you can hear", hint: "Near or far — a hum in the walls, a bird, your own breath.", tint: hearTint, ink: hearInk, mid: hearMid, washOpacity: 0.18),
        GroundingStep(count: 2, icon: "nose", prompt: "Notice two things you can smell", hint: "Faint is fine — the air itself has a scent, if you let it.", tint: smellTint, ink: smellInk, mid: smellMid, washOpacity: 0.18),
        GroundingStep(count: 1, icon: "mouth", prompt: "Notice one thing you can taste", hint: "Even just the inside of your mouth counts.", tint: tasteTint, ink: tasteInk, mid: tasteMid, washOpacity: 0.16)
    ]

    @State private var stepIndex = 0
    @State private var isComplete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // The calm wash for the current sense (or a soft moss for the final screen),
            // crossfading gently as the senses change.
            (isComplete ? Color.moss : Self.steps[stepIndex].tint)
                .opacity(isComplete ? 0.12 : Self.steps[stepIndex].washOpacity)
                .background(Color.parchment)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: stepIndex)
                .animation(.easeInOut(duration: 0.5), value: isComplete)

            VStack(spacing: 0) {
                Text("Grounding")
                    .font(.custom(FernletFontName.dmSansMedium, size: 12, relativeTo: .caption))
                    .tracking(2.6)
                    .foregroundStyle(isComplete ? Color.moss : Self.steps[stepIndex].mid)
                    .textCase(.uppercase)

                Spacer(minLength: 12)

                if isComplete {
                    completion
                } else {
                    stepContent(Self.steps[stepIndex])
                }

                Spacer(minLength: 12)

                footer
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .navigationTitle("Grounding")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepContent(_ step: GroundingStep) -> some View {
        VStack(spacing: 16) {
            Text("\(step.count)")
                .font(.custom(FernletFontName.frauncesSemiBold, size: 128, relativeTo: .largeTitle))
                .foregroundStyle(step.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Image(systemName: step.icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(step.ink)
                .frame(width: 58, height: 58)
                .background(step.tint.opacity(0.3), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            Text(step.prompt)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Text(step.hint)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: 280)
        }
        .transition(.opacity)
        .id(stepIndex)
    }

    private var completion: some View {
        VStack(spacing: 20) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.parchment)
                .frame(width: 118, height: 118)
                .background(
                    RadialGradient(
                        colors: [Color.fern, Color.moss],
                        center: UnitPoint(x: 0.42, y: 0.36),
                        startRadius: 4,
                        endRadius: 90
                    ),
                    in: Circle()
                )
                .shadow(color: Color.moss.opacity(0.3), radius: 16, x: 0, y: 10)
            Text("You're here.")
                .font(.custom(FernletFontName.frauncesSemiBold, size: 42, relativeTo: .largeTitle))
                .foregroundStyle(Color.bark)
            Text("That's enough. Take the calm with you — there's nothing else to do.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: 280)
        }
        .transition(.opacity)
    }

    private var footer: some View {
        Group {
            if isComplete {
                VStack(spacing: 16) {
                    Button { restart() } label: {
                        Text("Begin again")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.moss)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 26)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.moss.opacity(0.4), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)

                    Button("Done") { dismiss() }
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                }
            } else {
                VStack(spacing: 16) {
                    progressDots
                    Text("Tap anywhere when you're ready for the next one — take all the time you like.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                        .frame(maxWidth: 260)
                }
            }
        }
    }

    /// Five dots that fill in as the senses pass — a quiet sense of progress, no numbers racing.
    private var progressDots: some View {
        let mid = Self.steps[stepIndex].mid
        return HStack(spacing: 8) {
            ForEach(Self.steps.indices, id: \.self) { index in
                Circle()
                    .fill(index <= stepIndex ? mid : mid.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: stepIndex)
    }

    private func advance() {
        guard !isComplete else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            if stepIndex < Self.steps.count - 1 {
                stepIndex += 1
            } else {
                isComplete = true
            }
        }
    }

    private func restart() {
        withAnimation(.easeInOut(duration: 0.35)) {
            stepIndex = 0
            isComplete = false
        }
    }
}
