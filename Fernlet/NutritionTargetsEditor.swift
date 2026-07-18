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

    /// True when the protein + fat targets in effect alone meet or exceed the calorie target — the
    /// strongest over-budget case, where the carbs residual bottoms out well below its floor.
    private var proteinAndFatExceedCalories: Bool {
        applied.protein * 4 + applied.fat * 9 > applied.calories
    }

    /// True whenever the macros THIS CARD SHOWS sum above the stated calorie target. The carbs floor
    /// (30% of calories / 50 g) kicks in long before protein + fat alone fill the budget — from roughly
    /// 70% — so this is the honest trigger for "the totals read high", keyed to the same
    /// `macroTotals.calories` math the rings use rather than to the protein + fat extreme only.
    private var totalsExceedCalories: Bool {
        applied.macroTotals.calories > applied.calories
    }

    /// The plan Fernlet would derive with every override cleared — the "back to automatic" values, so a
    /// very low manual target can be disclosed against what the app would otherwise pick.
    private var derivedTargets: NutritionTargets {
        var settings = store.settings
        settings.calorieTargetOverride = nil
        settings.proteinTargetOverride = nil
        settings.fatTargetOverride = nil
        return NutritionTargetCalculator.targets(for: settings)
    }

    /// The footer/caution copy. Swaps to a gentle heads-up whenever the displayed totals read above the
    /// stated calories — strongest when protein + fat alone clear the target, a softer variant when only
    /// the carb minimum pushes the sum over; otherwise it explains the residual honestly without
    /// promising the numbers always add up exactly.
    private var footerText: String {
        if proteinAndFatExceedCalories {
            return "Your protein and fat alone are above your calorie target, so carbs sit at a gentle minimum and the totals come out a little higher than your calories."
        }
        if totalsExceedCalories {
            return "Your protein and fat leave less room than the carb minimum, so the totals come out a little above your calories."
        }
        return hasAnyOverride
            ? "Carbs fill in the calories your protein and fat leave room for. Clear a field to let Fernlet set it from your goal and profile again."
            : "These come from your goal, profile, activity and eating pattern. Type a number to set your own — carbs fill in the calories your protein and fat leave room for."
    }

    /// A gentle, non-blocking note when a manual target sits implausibly low. It discloses and points at
    /// the derived value — it never blocks or hard-floors the input; staying in control is the point.
    private var lowTargetNote: String? {
        if let calories = store.settings.calorieTargetOverride, calories < 1_200 {
            return "That's a very low daily target — your derived value is about \(derivedTargets.calories) cal. Gentle fueling helps your companion too."
        }
        if let protein = store.settings.proteinTargetOverride, protein < max(derivedTargets.protein / 2, 20) {
            return "That's quite low on protein — your derived value is about \(derivedTargets.protein) g. Gentle, steady fueling helps your companion too."
        }
        return nil
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

                Text(footerText)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(totalsExceedCalories ? Color.bark : Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("nutritionTargets.footer")

                if let note = lowTargetNote {
                    Text(note)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                        .accessibilityIdentifier("nutritionTargets.lowTargetNote")
                }
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
