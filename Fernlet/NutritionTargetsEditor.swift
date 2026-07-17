import SwiftUI
import FernletDomainModel

/// The Settings card for macro *targets*. It used to be a read-only summary that said targets "update
/// automatically" — testers wanted to set their own. Calories, protein and fat are each editable;
/// leaving a field blank (or typing 0) reverts it to the value Fernlet derives from goal + profile.
/// Carbs is never edited here: it is the residual of the other three against the calorie total, so it
/// is shown live and rebalances as the user types.
struct NutritionTargetsEditor: View {
    @Bindable var store: FernletStore

    /// The plan actually in effect (overrides applied). Its `carbs` is the live residual, and each of
    /// its macros is the grey placeholder for the matching row. Placeholders MUST come from here, not a
    /// "clear every override and re-derive" plan: a blank field shows its placeholder precisely when its
    /// own override is nil, and then `applied.<macro>` is the exact value in effect — the same number
    /// the Home/Food/Journal rings show. Fat derives from calories, so a "fully-derived" placeholder
    /// would show `fatTarget(derivedCalories)` while the rings used `fatTarget(overriddenCalories)`,
    /// making this very card contradict itself the moment a user pinned calories and left fat blank.
    private var applied: NutritionTargets { store.nutritionTargets }

    private var hasAnyOverride: Bool {
        store.settings.calorieTargetOverride != nil
            || store.settings.proteinTargetOverride != nil
            || store.settings.fatTargetOverride != nil
    }

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Nutrition targets")
                    Spacer()
                    if hasAnyOverride {
                        Button {
                            store.settings.calorieTargetOverride = nil
                            store.settings.proteinTargetOverride = nil
                            store.settings.fatTargetOverride = nil
                            store.scheduleSnapshotSave()
                        } label: {
                            Text("Reset")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.moss)
                        }
                        .accessibilityIdentifier("nutritionTargets.reset")
                    }
                }

                MacroTargetRow(label: "Calories", unit: "cal", placeholder: applied.calories,
                               maxValue: 9_999, value: binding(\.calorieTargetOverride))
                Divider().overlay(Color.bark.opacity(0.08))
                MacroTargetRow(label: "Protein", unit: "g", placeholder: applied.protein,
                               maxValue: 999, value: binding(\.proteinTargetOverride))
                Divider().overlay(Color.bark.opacity(0.08))
                MacroTargetRow(label: "Fat", unit: "g", placeholder: applied.fat,
                               maxValue: 999, value: binding(\.fatTargetOverride))
                Divider().overlay(Color.bark.opacity(0.08))

                // Carbs — the residual, never directly editable. Shown live so pinning the others reads
                // as "carbs rebalanced", not "carbs ignored".
                HStack {
                    Text("Carbs")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    Text("\(applied.carbs)g")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("nutritionTargets.carbs")

                Text(hasAnyOverride
                     ? "Carbs balance automatically to fit your calories. Clear a field to let Fernlet set it from your goal and profile again."
                     : "These come from your goal, profile, activity and eating pattern. Type a number to set your own — carbs always balance to fit your calories.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// A saving binding for one override keypath. The setter reassigns `store.settings` (which drives
    /// observation) and schedules the debounced snapshot save — the explicit persist every store
    /// mutation does, since a bare settings binding wouldn't otherwise be flushed on background.
    private func binding(_ keyPath: WritableKeyPath<FernletSettings, Int?>) -> Binding<Int?> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.scheduleSnapshotSave()
            }
        )
    }
}

/// One editable target row. The text field shows the override when set and, when blank, the value
/// actually in effect for this macro as a grey placeholder — so an untouched field reads as "Fernlet's
/// pick: 150" and matches the ring, and typing over it makes it yours. Blank or 0 maps back to `nil`
/// (derived); anything else is clamped to `maxValue` so a fat-fingered "99999" can't overflow the row
/// or the residual math.
private struct MacroTargetRow: View {
    let label: String
    let unit: String
    let placeholder: Int
    let maxValue: Int
    @Binding var value: Int?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            Spacer()
            TextField("\(placeholder)", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                .frame(width: 72)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("nutritionTargets.\(label.lowercased())")
            Text(unit)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .frame(width: 26, alignment: .leading)
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { value.map(String.init) ?? "" },
            set: { raw in
                let digits = raw.filter(\.isNumber)
                if let typed = Int(digits), typed > 0 {
                    value = min(typed, maxValue)
                } else {
                    value = nil
                }
            }
        )
    }
}
