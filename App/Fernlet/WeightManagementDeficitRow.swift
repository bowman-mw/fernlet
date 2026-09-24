import SwiftUI
import FernletDomainModel
import FernletUI

/// What the Nutrition targets card shows for the Weight Management deficit: the view-free half of
/// ``WeightManagementDeficitRow``, so its rules can be tested without rendering.
///
/// Owner decision, 2026-09-24: "do 10% as a baseline, users can change this as afterwards". The range,
/// step, default and floors all live in `NutritionTargetCalculator`. This only decides whether the row
/// appears, what it reads, and whether it is in effect.
struct WeightManagementDeficitControl: Equatable {
    /// Whether the row appears at all: only while Weight Management is the goal, the one goal with a
    /// calorie deficit.
    let isShown: Bool
    /// The deficit in effect, in whole percent: the user's choice, or the default when they never made one.
    let percent: Int
    /// False while the user has pinned their own calorie target, which outranks any deficit.
    let isInEffect: Bool

    init(settings: FernletSettings) {
        isShown = settings.selectedGoal == .weightManagement
        percent = NutritionTargetCalculator.weightManagementDeficitPercent(for: settings)
        isInEffect = settings.calorieTargetOverride == nil
    }

    /// Whether the value in effect is Fernlet's default (10%).
    var isDefault: Bool {
        percent == NutritionTargetCalculator.defaultWeightManagementDeficitPercent
    }
}

/// The Weight Management deficit row on the Nutrition targets card. A stepper walks the choosable
/// percentages (none to 20%, in 5% steps, 10% by default), and one line says what the number does.
///
/// It sits above the Calories row because it moves that row's derived value, and it rides the card
/// into both places targets are edited: Settings › Goal & nutrition, and the Food tab's targets sheet.
/// The goal card reads the same value (`GoalType.nutritionSummary(weightManagementDeficitPercent:)`),
/// so the two can never disagree. While a pinned calorie target outranks the deficit, the stepper is
/// disabled and the line says why instead of pretending the choice still applies.
struct WeightManagementDeficitRow: View {
    var store: FernletStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let control = WeightManagementDeficitControl(settings: store.settings)
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                // Seen at AX3: beside the stepper, the title and "10% (default)" broke mid-word.
                // The title gets its own line; the stepper still carries the name for VoiceOver.
                title
                    .fernletWrappingText()
                    .accessibilityHidden(true)
                stepper(control) {
                    styledValue(control)
                }
            } else {
                stepper(control) {
                    HStack {
                        title
                        Spacer()
                        styledValue(control)
                    }
                }
            }

            note(control)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("nutritionTargets.deficitNote")
        }
    }

    /// The row's name, drawn beside the stepper (or above it at accessibility sizes).
    private var title: some View {
        Text("Calorie deficit")
            .font(.fernlet(.body))
            .foregroundStyle(Color.bark)
    }

    /// The stepper over the choosable percentages, named and valued for VoiceOver whatever its
    /// visible label, and disabled while a pinned calorie target outranks it.
    ///
    /// Also dimmed then: seen on the iOS 26 simulator, a disabled stepper still draws its "−"
    /// at full strength, so it looked tappable while doing nothing.
    private func stepper<Label: View>(_ control: WeightManagementDeficitControl,
                                      @ViewBuilder label: () -> Label) -> some View {
        Stepper(value: percentBinding,
                in: NutritionTargetCalculator.weightManagementDeficitPercentRange,
                step: NutritionTargetCalculator.weightManagementDeficitPercentStep,
                label: label)
            .disabled(!control.isInEffect)
            .opacity(control.isInEffect ? 1 : 0.5)
            .accessibilityLabel(Text("Calorie deficit"))
            .accessibilityValue(valueText(control))
            .accessibilityHint(rangeHint)
            .accessibilityIdentifier("nutritionTargets.deficit")
    }

    /// ``valueText(_:)`` in the row's stat style.
    private func styledValue(_ control: WeightManagementDeficitControl) -> some View {
        valueText(control)
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
    }

    /// The percentage in effect, marked when it is the default.
    private func valueText(_ control: WeightManagementDeficitControl) -> Text {
        if control.isDefault {
            return Text("\(control.percent, format: .percent) (default)")
        }
        return Text(control.percent, format: .percent)
    }

    /// What the number does, or why it does nothing right now.
    private func note(_ control: WeightManagementDeficitControl) -> Text {
        if control.isInEffect {
            return Text("Up to this much below what your body is estimated to use in a day. Your calories never go under a safe floor for your body, whatever you choose.")
        }
        return Text("You've set your own calorie target, so the deficit isn't used. Clear the Calories field to use it again.")
    }

    /// The choosable range, read from the calculator so the hint cannot drift from the stepper.
    private var rangeHint: Text {
        let range = NutritionTargetCalculator.weightManagementDeficitPercentRange
        let step = NutritionTargetCalculator.weightManagementDeficitPercentStep
        return Text("From \(range.lowerBound, format: .percent) to \(range.upperBound, format: .percent), in steps of \(step, format: .percent).")
    }

    /// Reads the percentage in effect and writes through the store, which normalizes the value,
    /// stores the default as "no choice", and schedules the save.
    private var percentBinding: Binding<Int> {
        Binding(
            get: { NutritionTargetCalculator.weightManagementDeficitPercent(for: store.settings) },
            set: { store.setWeightManagementDeficitPercent($0) }
        )
    }
}
