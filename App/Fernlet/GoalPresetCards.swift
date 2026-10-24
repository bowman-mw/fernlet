import SwiftUI
import FernletDomainModel
import FernletUI

/// Selectable goal preset cards for the Goal & nutrition settings — one per `GoalType`, each showing the
/// paired **nutrition** and **training** setup that goal configures. Picking one goal therefore reads as
/// configuring both at once, which is the "make the goal options match the workout options" the tester
/// asked for. Replaces the bare goal `Picker` + lone tagline.
///
/// This is presentation only: the goal already drives nutrition (`NutritionTargetCalculator`) and the
/// training split; the cards just surface both summaries so the choice is legible.
struct GoalPresetCards: View {
    @Binding var selectedGoal: GoalType
    /// The Weight Management deficit in effect, in whole percent, so that card states the user's own
    /// choice rather than the default (2026-09-24). Settings passes
    /// `NutritionTargetCalculator.weightManagementDeficitPercent(for:)`; onboarding runs before anyone
    /// could have changed it, so the default is the truth there.
    var weightManagementDeficitPercent: Int = NutritionTargetCalculator.defaultWeightManagementDeficitPercent

    var body: some View {
        VStack(spacing: 10) {
            ForEach(GoalType.allCases) { goal in
                GoalPresetCard(goal: goal, isSelected: goal == selectedGoal,
                               nutritionSummary: goal.nutritionSummary(
                                   weightManagementDeficitPercent: weightManagementDeficitPercent)) {
                    // B6: picking another goal ticks, in onboarding and in Settings alike.
                    FernletFeedback.system.select(goal, in: &selectedGoal)
                }
            }
        }
        // NOTE: no `.accessibilityIdentifier` on this container — a container identifier propagates down
        // and OVERRIDES each card's own `goalPreset.<goal>` id (every card would report "goalPresetCards").
    }
}

/// One selectable goal card: the goal's name and tagline plus its nutrition and training summary rows.
///
/// Rendered by ``GoalPresetCards`` for each `GoalType`; selection state draws the checkmark and moss
/// outline, and the card carries its own `goalPreset.<goal>` accessibility identifier (which is why
/// the container above deliberately has none).
private struct GoalPresetCard: View {
    let goal: GoalType
    let isSelected: Bool
    /// The card's nutrition line, resolved by ``GoalPresetCards`` against the user's settings.
    let nutritionSummary: String
    let onTap: () -> Void

    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: onTap) {
            // Design `b2-onb-4`: a framed card with the Fraunces name, the tick square at its end, and
            // the nutrition and training lines beside their pixel art; the chosen one wears the moss ring.
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(goal.displayName)
                            .font(FernletFramedFont.cardTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                        Spacer()
                        GoalPresetTick(isSelected: isSelected)
                    }
                    Text(goal.tagline)
                        .font(FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                    summaryRow(sprite: WorldSprites.onigiri, text: nutritionSummary)
                    summaryRow(sprite: WorldSprites.shoe, text: goal.trainingSummary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay { OnboardingSelectionRing(isSelected: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isSelected)
        .accessibilityIdentifier("goalPreset.\(goal.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityInputLabels([Text(verbatim: goal.displayName)])
    }

    private func summaryRow(sprite: WorldSprite, text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            WorldSpriteView(sprite: sprite, scale: 2)
            Text(text)
                .font(FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
    }
}

/// The tick square at a goal card's end: moss with a white tick when chosen, paper when not.
private struct GoalPresetTick: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? WorldPalette.accent : WorldPalette.paperLight)
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .overlay { if isSelected { WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: WorldPalette.onAccent) } }
            .accessibilityHidden(true)
    }
}
