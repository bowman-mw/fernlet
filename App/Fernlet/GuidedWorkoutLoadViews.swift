import SwiftUI
import FernletDomainModel
import FernletUI

// MARK: - Store seam

extension FernletStore {
    /// The weight the lifter will use on a tracked lift (nil clears it).
    func guidedSelectWeight(_ weight: Double?, exerciseID: UUID) {
        editGuidedRun { $0.selectWeight(weight, forExercise: exerciseID) }
    }

    /// The reps each set actually got; all-on-target reads as "completed as prescribed" again.
    func guidedSetActualReps(_ reps: [Int], exerciseID: UUID) {
        editGuidedRun { $0.setActualReps(reps, forExercise: exerciseID) }
    }

    /// The optional effort tap; nil clears it.
    func guidedSetEffort(_ effort: ExerciseEffort?, exerciseID: UUID) {
        editGuidedRun { $0.setEffort(effort?.rawValue, forExercise: exerciseID) }
    }

    /// Why the lifter left the range; nil clears it.
    func guidedSetOverrideReason(_ reason: OverrideReason?, exerciseID: UUID) {
        editGuidedRun { $0.setOverrideReason(reason?.rawValue, forExercise: exerciseID) }
    }
}

// MARK: - Formatting

/// Weights as the runner shows them: the locale's number format and unit abbreviation ("62,5 kg").
///
/// The formatting itself is ``WorkoutActivityLoadText``'s, shared with the Live Activity, so the
/// weight panel and the Lock Screen never draw one weight two ways.
enum GuidedLoadFormat {
    /// The unit a tracked lift is weighed in.
    static func unit(_ tracking: GuidedWorkoutRunState.Tracking) -> UnitMass {
        tracking.unitRaw == LoadUnit.kg.rawValue ? .kilograms : .pounds
    }

    static func weight(_ value: Double, unit: UnitMass) -> String {
        WorkoutActivityLoadText.weight(value, unit: unit, width: .abbreviated, locale: .current)
    }

    /// "95–110 lb", or one weight when the range is a single step.
    static func range(_ tracking: GuidedWorkoutRunState.Tracking) -> String? {
        WorkoutActivityLoadText.range(low: tracking.rangeLow, high: tracking.rangeHigh, unit: unit(tracking), locale: .current)
    }

    /// Where the picker starts when there is no suggestion yet: an empty bar, a light dumbbell, a
    /// light stack.
    static func startWeight(_ tracking: GuidedWorkoutRunState.Tracking) -> Double {
        let pounds = tracking.unitRaw != LoadUnit.kg.rawValue
        switch tracking.equipmentRaw {
        case Equipment.barbell.rawValue: return pounds ? 45 : 20
        case Equipment.dumbbell.rawValue, Equipment.kettlebell.rawValue: return pounds ? 10 : 4
        default: return pounds ? 20 : 10
        }
    }
}

// MARK: - The load panel

/// The panel under a tracked lift's card: the calibration cue, the weight picker (the suggestion
/// preselected, so an untouched lift logs as done at that weight), the override question, the
/// optional effort tap on the last set, and Edit reps.
struct GuidedLoadPanel: View {
    var store: FernletStore
    let exercise: GuidedWorkoutRunState.Exercise
    let isLastSet: Bool
    @State private var editingReps = false

    var body: some View {
        if let tracking = exercise.tracking {
            VStack(alignment: .leading, spacing: 14) {
                if let cue = GuidedCalibrationCue.text(for: tracking.calibrationRaw) {
                    cue.font(.fernlet(.body)).foregroundStyle(Color.bark).fernletWrappingText()
                }
                if tracking.isLoadable {
                    GuidedWeightPicker(store: store, exerciseID: exercise.id, tracking: tracking)
                }
                if tracking.isOutsideRange && tracking.askReasonOnOverride {
                    GuidedOverrideReasonPicker(
                        store: store, exerciseID: exercise.id,
                        selected: tracking.overrideReasonRaw.flatMap(OverrideReason.init(rawValue:))
                    )
                }
                if isLastSet && GuidedCalibrationCue.asksEffort(tracking.calibrationRaw) {
                    GuidedEffortPicker(
                        store: store, exerciseID: exercise.id,
                        selected: tracking.effortRaw.flatMap(ExerciseEffort.init(rawValue:))
                    )
                }
                GuidedEditRepsButton(store: store, exercise: exercise, label: Text("Edit reps"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// The cue a calibration step carries in the runner.
enum GuidedCalibrationCue {
    static func text(for raw: String?) -> Text? {
        switch raw {
        case GuidedWorkoutRunState.CalibrationToken.ramp:
            return Text("Ramp-up set — light, just getting ready.")
        case GuidedWorkoutRunState.CalibrationToken.test:
            return Text("Test set: as many good reps as you can, stopping with 1–2 left. Edit the reps when you're done.")
        case GuidedWorkoutRunState.CalibrationToken.attempt:
            return Text("Max attempt — use a spotter or safety arms, and stop if your form breaks. Missed it? Set the reps to 0 and the rest are skipped.")
        default:
            return nil
        }
    }

    /// Ramp sets and max singles don't ask how they felt.
    static func asksEffort(_ raw: String?) -> Bool {
        raw != GuidedWorkoutRunState.CalibrationToken.ramp && raw != GuidedWorkoutRunState.CalibrationToken.attempt
    }
}

/// The −/+ weight picker: one equipment step a tap, starting from the suggestion.
struct GuidedWeightPicker: View {
    var store: FernletStore
    let exerciseID: UUID
    let tracking: GuidedWorkoutRunState.Tracking

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            guide
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            HStack(spacing: 16) {
                stepButton(systemImage: "minus", label: Text("Lighter"), identifier: "workout.guided.weight.lighter", direction: -1)
                selectedText
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                    .frame(minWidth: 96)
                    .accessibilityIdentifier("workout.guided.weight")
                stepButton(systemImage: "plus", label: Text("Heavier"), identifier: "workout.guided.weight.heavier", direction: 1)
            }
        }
    }

    private var guide: Text {
        // A weight a planned workout's line named: the plan's own, not a range of Fernlet's.
        if tracking.asWritten == true, let planned = tracking.suggested {
            return Text("As planned: \(GuidedLoadFormat.weight(planned, unit: GuidedLoadFormat.unit(tracking)))")
        }
        guard let range = GuidedLoadFormat.range(tracking), let suggested = tracking.suggested else {
            return Text("Pick a weight you could lift about 2 more times than asked.")
        }
        let suggestion = GuidedLoadFormat.weight(suggested, unit: GuidedLoadFormat.unit(tracking))
        return Text("Range \(range) · suggested \(suggestion)")
    }

    private var selectedText: Text {
        guard let selected = tracking.selected else { return Text("Not set") }
        return Text(verbatim: GuidedLoadFormat.weight(selected, unit: GuidedLoadFormat.unit(tracking)))
    }

    private func stepButton(systemImage: String, label: Text, identifier: String, direction: Double) -> some View {
        Button {
            let step = tracking.step ?? 0
            let next = tracking.selected.map { $0 + direction * step } ?? GuidedLoadFormat.startWeight(tracking)
            store.guidedSelectWeight(next, exerciseID: exerciseID)
        } label: {
            Image(systemName: systemImage)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .frame(width: 44, height: 44)
                .background(Color.mossFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The once-in-a-while question after repeated picks outside the range.
struct GuidedOverrideReasonPicker: View {
    var store: FernletStore
    let exerciseID: UUID
    let selected: OverrideReason?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You've picked outside the range a few times. What's up?")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            FlowLayout(spacing: 8) {
                ForEach(OverrideReason.allCases, id: \.self) { reason in
                    Button { store.guidedSetOverrideReason(selected == reason ? nil : reason, exerciseID: exerciseID) } label: {
                        Self.label(reason)
                    }
                    .buttonStyle(ChipButtonStyle(selected: selected == reason))
                    .accessibilityIdentifier("workout.guided.reason.\(reason.rawValue)")
                }
            }
            if let selected {
                (selected == .pain
                    ? Text("Thanks — Fernlet will hold this lift steady. If it keeps hurting, try a different exercise or check with a professional.")
                    : Text("Thanks — Fernlet will adjust from here."))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    static func label(_ reason: OverrideReason) -> Text {
        switch reason {
        case .tooHeavy: Text("Too heavy")
        case .tooLight: Text("Too light")
        case .equipment: Text("Equipment")
        case .pain: Text("Pain")
        case .preference: Text("Preference")
        case .other: Text("Other")
        }
    }
}

/// The optional effort tap on a lift's last set: Easy · Good · Tough. No tap reads as Good.
struct GuidedEffortPicker: View {
    var store: FernletStore
    let exerciseID: UUID
    let selected: ExerciseEffort?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How's it feeling?")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            FlowLayout(spacing: 8) {
                ForEach(ExerciseEffort.allCases, id: \.self) { effort in
                    Button { store.guidedSetEffort(selected == effort ? nil : effort, exerciseID: exerciseID) } label: {
                        Self.label(effort)
                    }
                    .buttonStyle(ChipButtonStyle(selected: selected == effort))
                    .accessibilityIdentifier("workout.guided.effort.\(effort.rawValue)")
                }
            }
        }
    }

    static func label(_ effort: ExerciseEffort) -> Text {
        switch effort {
        case .easy: Text("Easy")
        case .good: Text("Good")
        case .tough: Text("Tough")
        }
    }
}

// MARK: - Editing reps

/// A quiet button that opens the reps editor for one tracked lift.
struct GuidedEditRepsButton: View {
    var store: FernletStore
    let exercise: GuidedWorkoutRunState.Exercise
    let label: Text
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            label
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.guided.editReps")
        .sheet(isPresented: $editing) {
            GuidedRepsEditor(store: store, exercise: exercise)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// "Edit reps for Bench press" — on the first set of the step after a tracked lift, because the runner
/// moves straight on after a lift's last set and a miss on it is noticed only then.
struct GuidedPreviousLiftFix: View {
    var store: FernletStore
    let run: GuidedWorkoutRunState

    var body: some View {
        if let previous {
            GuidedEditRepsButton(store: store, exercise: previous, label: Text("Edit reps for \(previous.displayedName)"))
        }
    }

    /// The tracked lift just finished, while the step after it is on its first set.
    private var previous: GuidedWorkoutRunState.Exercise? {
        guard run.isWorking, run.currentSet == 1, run.exerciseIndex > 0,
              run.exercises.indices.contains(run.exerciseIndex - 1) else { return nil }
        let candidate = run.exercises[run.exerciseIndex - 1]
        guard candidate.tracking != nil, candidate.tracking?.skipped != true else { return nil }
        return candidate
    }
}

/// Per-set reps for one lift. Only the sets that went differently need touching.
struct GuidedRepsEditor: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    let exercise: GuidedWorkoutRunState.Exercise
    @State private var reps: [Int]

    /// Reps a set may be edited to.
    static let repsRange = 0...50

    init(store: FernletStore, exercise: GuidedWorkoutRunState.Exercise) {
        self.store = store
        self.exercise = exercise
        let target = exercise.tracking?.targetReps ?? 0
        _reps = State(initialValue: exercise.tracking?.actualReps
            ?? Array(repeating: target, count: min(max(1, exercise.sets), GuidedWorkoutRunState.Tracking.maxSets)))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Text("Edit reps"), subtitle: Text(verbatim: exercise.displayedName), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Change only the sets that went differently.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    ForEach(reps.indices, id: \.self) { index in
                        Stepper(value: $reps[index], in: Self.repsRange) {
                            Text("Set \(index + 1): \(reps[index]) reps")
                                .foregroundStyle(Color.bark)
                        }
                        .accessibilityIdentifier("workout.guided.editReps.set\(index + 1)")
                    }
                }
                .padding(20)
            }
            SheetSaveBar(label: "Save") {
                store.guidedSetActualReps(reps, exerciseID: exercise.id)
                dismiss()
            }
        }
        .background(Color.parchment)
        .tint(Color.moss)
    }
}
