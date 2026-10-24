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

/// A radio card's framed tick box (`.rc3 .ck`): 26 pt raised paper in a 2-pt ink frame, the accent
/// with a pixel tick when chosen. Decorative: the card's button carries the selected trait.
struct GoalTickBox: View {
    let isOn: Bool
    let look: FernletFramedLook

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        ZStack {
            shape.fill(isOn ? look.accent : look.raised)
            if isOn { FernletIcon(.check, scale: 2, tint: look.onAccent) }
        }
        .frame(width: 26, height: 26)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        .accessibilityHidden(true)
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
    /// The World's framed look: a framed radio card (`b2-settings-goal`, `.rc3`), the chosen one ringed
    /// in moss with a framed tick, pixel icons on the summary lines.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: onTap) {
            if let look {
                framedCard(look)
            } else {
                standardCard
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isSelected)
        // A Button already exposes its label as one accessible element; an extra
        // `.accessibilityElement(children: .combine)` here swallowed the identifier, so it's omitted.
        .accessibilityIdentifier("goalPreset.\(goal.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Voice Control: the card's name runs through its tagline and both summary lines; the goal
        // name at its top is what a user says.
        .accessibilityInputLabels([Text(verbatim: goal.displayName)])
    }

    /// Today's card: cream, a moss outline when chosen, SF Symbols.
    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(goal.displayName)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.moss : Color.slate)
            }
            Text(goal.tagline)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            summaryRow(icon: "fork.knife", text: nutritionSummary)
            summaryRow(icon: "figure.run", text: goal.trainingSummary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.moss : Color.bark.opacity(0.10), lineWidth: isSelected ? 2 : 1)
        )
    }

    /// The framed radio card: the goal's name in Fraunces with the framed tick box, its tagline, then
    /// the nutrition and training lines after the pixel rice ball and shoe. Paper in a 2-pt ink frame
    /// with the solid shadow; the chosen card adds a 3-pt moss ring outside its frame.
    private func framedCard(_ look: FernletFramedLook) -> some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(goal.displayName)
                    .font(FernletFramedFont.cardTitle)
                    .foregroundStyle(look.text)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                GoalTickBox(isOn: isSelected, look: look)
            }
            Text(goal.tagline)
                .font(FernletFramedFont.body)
                .foregroundStyle(look.dim)
                .fernletWrappingText()
            framedSummaryRow(WorldSprites.onigiri, text: nutritionSummary, look: look)
            if !goal.trainingSummary.isEmpty {
                framedSummaryRow(WorldSprites.shoe, text: goal.trainingSummary, look: look)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
        .background(look.paper, in: shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(look.shadow).offset(y: 3) }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius + 3, style: .continuous)
                    .strokeBorder(WorldPalette.moss, lineWidth: 3)
                    .padding(-3)
            }
        }
        // Room for the ring either way, so choosing a goal never shifts the cards.
        .padding(3)
    }

    /// A summary line after its pixel icon.
    private func framedSummaryRow(_ sprite: WorldSprite, text: String, look: FernletFramedLook) -> some View {
        HStack(alignment: .top, spacing: 10) {
            WorldSpriteView(sprite: sprite, scale: 2)
            Text(text)
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(look.text)
                .fernletWrappingText()
        }
    }

    private func summaryRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.fern)
                .frame(width: 16)
            Text(text)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark.opacity(0.75))
                .fernletWrappingText()
        }
    }
}
