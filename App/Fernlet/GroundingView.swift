//
//  GroundingView.swift
//  Fernlet
//
//  5-4-3-2-1 grounding: a stepped, tap-to-advance flow (no timers, no pressure) that
//  walks one gentle sense at a time and ends on a soft affirmation. Each sense fills the
//  screen with its own calm colour wash; tapping anywhere is the only pace.
//

import SwiftUI
import FernletUI

/// The 5-4-3-2-1 grounding exercise: a stepped, tap-to-advance walk through the five senses,
/// ending on a soft affirmation.
///
/// Pushed from ``FirstAidView``. No timers and no pressure — tapping anywhere is the only pace,
/// and each sense fills the screen with its own calm color wash from the static `steps` table.
/// Entirely self-contained view state (step index + completion flag); nothing is recorded or
/// persisted.
struct GroundingView: View {
    /// One sense's step in the 5-4-3-2-1 sequence: its count, icon, prompt/hint copy, and the
    /// per-sense color trio (wash tint, deep ink, mid-tone).
    ///
    /// The five instances live in the static `steps` table; the view renders whichever one
    /// `stepIndex` points at. `prompt` and `hint` are `LocalizedStringKey`, so the table's literals
    /// are catalog keys: as `String` they reached `Text`'s verbatim initializer and never left
    /// English.
    private struct GroundingStep {
        let count: Int
        let icon: String
        let prompt: LocalizedStringKey
        let hint: LocalizedStringKey
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
    // Each `mid` needs a lighter dark-mode variant (like `ink` above) or the kicker text and
    // unfilled progress dots fall to ~2.7:1 / ~1.3:1 against the dark wash — the dark tones keep
    // each sense's hue but lift luminance to stay legible.
    private static let seeMid = Color(light: Color(red: 0.369, green: 0.486, blue: 0.329),
                                      dark:  Color(red: 0.643, green: 0.749, blue: 0.588))
    // touchTint is the same hue as the shared okay-state token — one source of truth.
    private static let touchTint = Color.stateOkay
    private static let touchInk = Color(light: Color(red: 0.541, green: 0.384, blue: 0.141),
                                        dark:  Color(red: 0.831, green: 0.694, blue: 0.443))
    private static let touchMid = Color(light: Color(red: 0.627, green: 0.486, blue: 0.235),
                                        dark:  Color(red: 0.816, green: 0.678, blue: 0.427))
    private static let hearTint = Color(light: Color(red: 0.549, green: 0.651, blue: 0.714),
                                        dark:  Color(red: 0.549, green: 0.651, blue: 0.714))
    private static let hearInk = Color(light: Color(red: 0.298, green: 0.392, blue: 0.447),
                                       dark:  Color(red: 0.682, green: 0.776, blue: 0.831))
    private static let hearMid = Color(light: Color(red: 0.384, green: 0.475, blue: 0.541),
                                       dark:  Color(red: 0.667, green: 0.761, blue: 0.816))
    private static let smellTint = Color(light: Color(red: 0.663, green: 0.608, blue: 0.706),
                                         dark:  Color(red: 0.663, green: 0.608, blue: 0.706))
    private static let smellInk = Color(light: Color(red: 0.373, green: 0.329, blue: 0.439),
                                        dark:  Color(red: 0.749, green: 0.702, blue: 0.804))
    private static let smellMid = Color(light: Color(red: 0.471, green: 0.416, blue: 0.529),
                                        dark:  Color(red: 0.733, green: 0.686, blue: 0.788))
    private static let tasteTint = Color(light: Color(red: 0.753, green: 0.541, blue: 0.439),
                                         dark:  Color(red: 0.753, green: 0.541, blue: 0.439))
    private static let tasteInk = Color(light: Color(red: 0.478, green: 0.290, blue: 0.220),
                                        dark:  Color(red: 0.831, green: 0.639, blue: 0.549))
    private static let tasteMid = Color(light: Color(red: 0.596, green: 0.392, blue: 0.322),
                                        dark:  Color(red: 0.816, green: 0.624, blue: 0.533))

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
        // World (b3-grounding): a page pushed inside the First aid sheet, on its paper, with
        // "‹ First aid" above the GROUNDING label; the sense's own tint stays on its icon tile.
        VStack(alignment: .leading, spacing: 0) {
            FirstAidToolHeader(title: nil)
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Grounding")
                    .padding(.top, 24)
                if isComplete {
                    Spacer(minLength: 12)
                    completion
                } else {
                    stepContent(Self.steps[stepIndex])
                        .padding(.top, 14)
                }
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fernletSheetStyle()
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        // Tap-anywhere is a bonus, never the only way through: a rotor action gives VoiceOver users
        // the same pace, and the Next/Back buttons in the footer give everyone a way back from a
        // sense they skipped by accident.
        .accessibilityAction(named: "Next") { advance() }
        .accessibilityAction(named: "Back") { goBack() }
        // The screen already carries a large "GROUNDING" kicker; the header carries the way back.
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    /// One sense (`b3-grounding`): the big numeral beside the sense's pixel icon on a framed tile in
    /// its tint, then the prompt in Fraunces and the hint in dim ink, left-aligned.
    private func stepContent(_ step: GroundingStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                Text("\(step.count)")
                    .font(.custom(FernletFontName.frauncesSemiBold, size: 110, relativeTo: .largeTitle))
                    .foregroundStyle(WorldPalette.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                FernletIconTile(size: 72, fill: step.tint.opacity(0.3)) {
                    WorldSpriteView(sprite: Self.sprite(for: step.icon), scale: 4)
                }
                .accessibilityHidden(true)
            }
            Text(step.prompt)
                .font(.custom(FernletFontName.frauncesSemiBold, size: 26, relativeTo: .title))
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
            Text(step.hint)
                .font(FernletFramedFont.field)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .id(stepIndex)
    }

    /// A sense's pixel icon, from its step's frozen SF Symbol name: see, touch, hear, smell, taste.
    private static func sprite(for symbol: String) -> WorldSprite {
        switch symbol {
        case "hand.raised": WorldSprites.hand
        case "ear": WorldSprites.ear
        case "nose": WorldSprites.nose
        case "mouth": WorldSprites.mouth
        default: WorldSprites.eye
        }
    }

    private var completion: some View {
        VStack(spacing: 18) {
            // World: the moss medal of the breathing finish, with the pixel leaf.
            ZStack {
                Circle().fill(WorldPalette.ink.opacity(0.22)).frame(width: 112, height: 112).offset(y: 5)
                Circle().fill(WorldPalette.moss).frame(width: 112, height: 112)
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 3))
                WorldSpriteView(sprite: WorldSprites.leaf, scale: 6, tint: Color.white)
            }
            .accessibilityHidden(true)
            Text("You're here.")
                .font(.custom(FernletFontName.frauncesSemiBold, size: 42, relativeTo: .largeTitle))
                .foregroundStyle(WorldPalette.bark)
                // T2-19: the completion screen's own heading — the arrival marker of the exercise.
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text("That's enough. Take the calm with you — there's nothing else to do.")
                .font(FernletFramedFont.field)
                .foregroundStyle(WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private var footer: some View {
        Group {
            if isComplete {
                // World: Begin again and Done as framed buttons, side by side.
                HStack(spacing: 12) {
                    Button { restart() } label: {
                        Text("Begin again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    Button { dismiss() } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                }
            } else {
                VStack(spacing: 10) {
                    // World (b3-grounding): Back (framed secondary, faded on the first sense), the
                    // five pixel steps, Next (framed primary).
                    HStack(spacing: 10) {
                        Button { goBack() } label: {
                            Text("Back").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                        .disabled(stepIndex == 0)
                        progressDots
                        Button { advance() } label: {
                            Text("Next").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionPillButtonStyle(.primary))
                    }
                    AddressedText("Tap anywhere when you're ready for the next one — take all the time you like.")
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Five framed squares that fill in moss as the senses pass — a quiet sense of progress.
    private var progressDots: some View {
        HStack(spacing: 4) {
            ForEach(Self.steps.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index <= stepIndex ? WorldPalette.moss : WorldPalette.paperLight)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(WorldPalette.ink, lineWidth: 2))
                    .frame(width: 14, height: 14)
            }
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.35), value: stepIndex)
        .accessibilityHidden(true)
    }

    private func advance() {
        guard !isComplete else { return }
        // B4: felt at the tap, as the next sense washes in or the affirmation arrives. Grounding has
        // no switch of its own, so the app-wide level alone decides.
        FernletFeedback.system.play(Self.advanceEvent(from: stepIndex, of: Self.steps.count))
        withAnimation(.easeInOut(duration: 0.35)) {
            if stepIndex < Self.steps.count - 1 {
                stepIndex += 1
            } else {
                isComplete = true
            }
        }
    }

    /// What moving on from `stepIndex` feels like (report B4): `pace` into the next sense, `done` on
    /// leaving the last one, which completes the exercise. Back and Begin again play nothing.
    static func advanceEvent(from stepIndex: Int, of stepCount: Int) -> FernletFeedbackEvent {
        stepIndex < stepCount - 1 ? .pace : .done
    }

    /// Steps back one sense. Nothing is recorded, so an accidental skip should cost a tap to undo,
    /// not a restart from "Begin again".
    private func goBack() {
        guard !isComplete, stepIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.35)) { stepIndex -= 1 }
    }

    private func restart() {
        withAnimation(.easeInOut(duration: 0.35)) {
            stepIndex = 0
            isComplete = false
        }
    }
}
