import SwiftUI
import FernletDomainModel
import FernletUI

// MARK: - Formatting

/// Weight-unit words for the set editor, from the system's measurement formatter so they follow the
/// person's language with no catalog strings of their own ("lb" / "kg" drawn, "pounds" /
/// "kilograms" spoken).
enum SetLoadFormat {
    /// The unit as drawn beside a weight field ("lb").
    static func symbol(_ unit: LoadUnit) -> String {
        name(unit, style: .medium)
    }

    /// The unit as VoiceOver says it ("pounds").
    static func spokenName(_ unit: LoadUnit) -> String {
        name(unit, style: .long)
    }

    private static func name(_ unit: LoadUnit, style: Formatter.UnitStyle) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = style
        formatter.unitOptions = .providedUnit
        return formatter.string(from: unit == .kg ? UnitMass.kilograms : UnitMass.pounds)
    }
}

// MARK: - One lift

/// One lift's set-by-set editor: a row per set (reps on a stepper, the weight typed), Add set and
/// Repeat last set, the weight unit, and — where the lift records them — how it felt and why the
/// weight left the prescribed range.
///
/// Shared by the Edit sheet (correcting a logged lift) and the Log sheet's set-by-set entry, so the
/// two can never disagree about what a row means. Every control names its set for VoiceOver and
/// Voice Control ("Set 2 weight"), and each row stacks at accessibility sizes so no number is cut.
struct ExerciseSetsEditor: View {
    @Binding var draft: ExerciseSetsDraft
    /// Prefix of this editor's accessibility identifiers ("workout.edit.sets.0").
    let identifier: String
    /// Shows the lift's name as a heading — off in the Log sheet, whose picker already names it.
    var showsName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsName {
                Text(verbatim: draft.name)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                    .accessibilityAddTraits(.isHeader)
            }
            unitPicker
            ForEach($draft.rows) { $row in
                let index = draft.rows.firstIndex { $0.id == row.id } ?? 0
                SetRowEditor(
                    row: $row, number: index + 1, unit: draft.unit,
                    inheritedWeight: draft.inheritedWeight(before: index), canRemove: draft.rows.count > 1,
                    identifier: "\(identifier).set\(index + 1)"
                ) { draft.removeSet(id: row.id) }
            }
            setButtons
            if draft.asksEffort {
                SetEffortChips(selected: $draft.effort, identifier: "\(identifier).effort")
            }
            if draft.hasRange {
                SetOverrideReasonChips(selected: $draft.overrideReason, identifier: "\(identifier).reason")
            }
        }
    }

    /// lb / kg, for every weight in this lift.
    private var unitPicker: some View {
        SheetField("Weight unit", namesControl: true) {
            Picker(selection: $draft.unit) {
                ForEach(LoadUnit.allCases, id: \.self) { unit in
                    Text(verbatim: SetLoadFormat.symbol(unit))
                        .accessibilityLabel(Text(verbatim: SetLoadFormat.spokenName(unit)))
                        .tag(unit)
                }
            } label: {
                Text("Weight unit")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .accessibilityIdentifier("\(identifier).unit")
        }
    }

    /// Add set (a row at the last reps, its weight repeating the set above) and Repeat last set.
    private var setButtons: some View {
        FlowLayout(spacing: 8) {
            Button("Add set") { draft.addSet() }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .disabled(draft.rows.count >= ExerciseResult.maxSets)
                .accessibilityIdentifier("\(identifier).addSet")
            Button("Repeat last set") { draft.repeatLastSet() }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .disabled(draft.rows.count >= ExerciseResult.maxSets)
                .accessibilityIdentifier("\(identifier).repeatLast")
        }
    }
}

// MARK: - One set

/// One set's row: "Set 2" with its remove button, then its reps on a stepper and its weight.
///
/// The reps and the weight sit side by side at standard sizes and stack at accessibility sizes
/// (``AdaptiveStack``), where each gets the full width and the numbers wrap rather than truncate.
/// The visible "Set 2" and "8 reps" are hidden from VoiceOver because the stepper already says both
/// ("Set 2: 8 reps").
struct SetRowEditor: View {
    @Binding var row: SetRowDraft
    let number: Int
    let unit: LoadUnit
    /// What a blank weight will repeat — shown as the field's prompt.
    let inheritedWeight: Double?
    let canRemove: Bool
    let identifier: String
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Set \(number)")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.slate)
                    }
                    .buttonStyle(.plain)
                    .fernletIconButton("Remove set \(number)")
                    .accessibilityInputLabels([Text("Remove set \(number)")])
                    .accessibilityIdentifier("\(identifier).remove")
                }
            }
            AdaptiveStack(spacing: 12, horizontalAlignment: .leading) {
                repsControl
                weightField
            }
        }
    }

    /// "8 reps" and the − / + stepper that changes it.
    private var repsControl: some View {
        HStack(spacing: 8) {
            Text("\(row.reps) reps")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
                .accessibilityHidden(true)
            Stepper(value: $row.reps, in: 0...LoggedSet.maxReps) {
                Text("Set \(number): \(row.reps) reps")
            }
            .labelsHidden()
            .accessibilityInputLabels([Text("Set \(number) reps")])
            .accessibilityIdentifier("\(identifier).reps")
        }
    }

    /// The weight, typed on the decimal pad, with the unit beside it. Blank repeats the set above,
    /// which the prompt shows.
    private var weightField: some View {
        HStack(spacing: 6) {
            TextField("Weight", text: $row.weight, prompt: .fieldPrompt(verbatim: promptText))
                .keyboardType(.decimalPad)
                .sheetTextInput(font: .fernlet(.label))
                .frame(minWidth: 80)
                // The unit beside the field is drawn only, so the spoken name carries it.
                .accessibilityLabel(Text("Set \(number) weight, \(SetLoadFormat.spokenName(unit))"))
                .accessibilityInputLabels([Text("Set \(number) weight")])
                .accessibilityIdentifier("\(identifier).weight")
            Text(verbatim: SetLoadFormat.symbol(unit))
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    /// The prompt: the weight a blank repeats, or "Weight" on a first set.
    private var promptText: String {
        guard let inheritedWeight else {
            return String(localized: "workout.sets.weightPrompt", defaultValue: "Weight",
                          comment: "Prompt in an empty per-set weight field (Edit workout, Log workout set by set).")
        }
        return SetRowDraft.text(for: inheritedWeight)
    }
}

// MARK: - Effort and reason

/// "How did it feel?" — Easy · Good · Tough, optional, tap again to clear (the runner's chips, after
/// the fact).
struct SetEffortChips: View {
    @Binding var selected: ExerciseEffort?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How did it feel?")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            FlowLayout(spacing: 8) {
                ForEach(ExerciseEffort.allCases, id: \.self) { effort in
                    Button { selected = selected == effort ? nil : effort } label: {
                        GuidedEffortPicker.label(effort)
                    }
                    .buttonStyle(ChipButtonStyle(selected: selected == effort))
                    .accessibilityIdentifier("\(identifier).\(effort.rawValue)")
                }
            }
        }
    }
}

/// Why the weight left the prescribed range — the runner's override question, answerable or
/// correctable after the fact. Offered only for a lift that had a range.
struct SetOverrideReasonChips: View {
    @Binding var selected: OverrideReason?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If you went outside the range, why?")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            FlowLayout(spacing: 8) {
                ForEach(OverrideReason.allCases, id: \.self) { reason in
                    Button { selected = selected == reason ? nil : reason } label: {
                        GuidedOverrideReasonPicker.label(reason)
                    }
                    .buttonStyle(ChipButtonStyle(selected: selected == reason))
                    .accessibilityIdentifier("\(identifier).\(reason.rawValue)")
                }
            }
        }
    }
}
