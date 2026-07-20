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

    var body: some View {
        VStack(spacing: 10) {
            ForEach(GoalType.allCases) { goal in
                GoalPresetCard(goal: goal, isSelected: goal == selectedGoal) {
                    selectedGoal = goal
                }
            }
        }
        // NOTE: no `.accessibilityIdentifier` on this container — a container identifier propagates down
        // and OVERRIDES each card's own `goalPreset.<goal>` id (every card would report "goalPresetCards").
    }
}

private struct GoalPresetCard: View {
    let goal: GoalType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(goal.displayName)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.moss : Color.slate.opacity(0.3))
                }
                Text(goal.tagline)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                summaryRow(icon: "fork.knife", text: goal.nutritionSummary)
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
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isSelected)
        // A Button already exposes its label as one accessible element; an extra
        // `.accessibilityElement(children: .combine)` here swallowed the identifier, so it's omitted.
        .accessibilityIdentifier("goalPreset.\(goal.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
