import SwiftUI
import FernletDomainModel
import FernletUI

/// "Add an exercise" (and edit): the hand-made custom exercise form (idea 15).
///
/// Asks for every field a bundled catalog row carries (``CustomExerciseDraft``) — the name, main and
/// other muscles, movement and its direction, kind of training, main equipment and what else it works
/// with, gear it can't be done without, reps or seconds, one side at a time, and difficulty — so
/// ``WorkoutSafetyFilter`` and slot eligibility treat the saved exercise exactly like a bundled one.
/// The checks are ``CustomExerciseLibrary``'s: a name, no clash with a Fernlet exercise or another of
/// the user's, at least one main muscle, and room under the 500-exercise cap.
///
/// Name problems show as they are typed; the rest after a first Save, when the first problem is also
/// announced for VoiceOver. Every choice is a chip named by its visible word ("Chest", "Push"),
/// carrying the selected trait, so VoiceOver reads "Chest, selected, button" and Voice Control
/// answers to "Tap Chest"; the chips wrap (`FlowLayout`) at every text size. The sheet guards its
/// draft like the other entry sheets (Cancel asks before discarding).
struct CustomExerciseFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    /// The exercise being edited; nil adds a new one.
    let editing: ExerciseTarget?

    @State private var draft: CustomExerciseDraft
    @State private var attemptedSave = false
    private let initialDraft: CustomExerciseDraft

    init(store: FernletStore, editing: ExerciseTarget?) {
        self.store = store
        self.editing = editing
        let seed = editing.map { CustomExerciseDraft($0) } ?? CustomExerciseDraft()
        _draft = State(initialValue: seed)
        initialDraft = seed
    }

    private var issues: [CustomExerciseIssue] {
        CustomExerciseLibrary.issues(
            for: draft, existing: store.settings.customExercises,
            base: WorkoutExerciseCatalog.baseExercises, editing: editing?.name
        )
    }

    /// The name problem to show now: a clash or length as soon as it is typed, an empty name only
    /// after a Save attempt.
    private var nameIssue: CustomExerciseIssue? {
        issues.first { issue in
            switch issue {
            case .nameTooLong, .clashesWithCatalog, .duplicateName: true
            case .emptyName: attemptedSave
            case .noPrimaryMuscle, .atCapacity: false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Fernlet plans and checks this like its own exercises: your equipment and the areas you work around decide when it fits.",
                         comment: "Custom exercise form: what the fields are for")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    if issues.contains(.atCapacity) { CustomExerciseIssueLine(issue: .atCapacity) }
                    nameField
                    CustomExerciseMuscleFields(draft: $draft,
                                               showsMissing: attemptedSave && issues.contains(.noPrimaryMuscle))
                    CustomExerciseMovementFields(draft: $draft)
                    CustomExerciseEquipmentFields(draft: $draft)
                    CustomExerciseSetFields(draft: $draft)
                }
                .padding(20)
                .padding(.bottom, 10)
            }
            saveBar
        }
        .background(Color.parchment)
        .tint(Color.moss)
        .keyboardDoneToolbar()
        .fernletDraftGuard(isDirty: draft != initialDraft,
                           title: editing == nil ? Text("Add an exercise") : Text("Edit exercise")) { dismiss() }
    }

    private var nameField: some View {
        SheetField("Name") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. Landmine press", text: $draft.name, prompt: .fieldPrompt("e.g. Landmine press"))
                    .sheetTextInput()
                    .accessibilityLabel(Text("Exercise name"))
                    .accessibilityIdentifier("workout.customExercise.name")
                if let nameIssue { CustomExerciseIssueLine(issue: nameIssue) }
            }
        }
    }

    @ViewBuilder private var saveBar: some View {
        if editing == nil {
            SheetSaveBar(label: "Add exercise") { save() }
        } else {
            SheetSaveBar(label: "Save changes") { save() }
        }
    }

    /// Saves through the store, which re-checks against the live list; on a problem the sheet stays,
    /// shows every problem, and speaks the first.
    private func save() {
        attemptedSave = true
        let issue: CustomExerciseIssue?
        if let editing {
            issue = store.updateCustomExercise(named: editing.name, with: draft)
        } else {
            issue = store.addCustomExercise(draft)
        }
        guard let issue else {
            dismiss()
            return
        }
        FernletAnnouncer.system.announce(resolved: issue.message)
    }
}

/// One form problem: a warning glyph (so it never rests on color alone) and the message.
private struct CustomExerciseIssueLine: View {
    let issue: CustomExerciseIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            Text(verbatim: issue.message)
                .fernletWrappingText()
        }
        .font(.fernlet(.bodySmall))
        .foregroundStyle(Color.terracottaInk)
    }
}

/// A wrapping row of chips, one per option, each a button named by its visible word.
private struct CustomExerciseChips<Option: Hashable>: View {
    let options: [Option]
    let name: (Option) -> String
    let isSelected: (Option) -> Bool
    let identifier: String
    let toggle: (Option) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button(name(option)) { toggle(option) }
                    .buttonStyle(ChipButtonStyle(selected: isSelected(option)))
                    .accessibilityIdentifier(identifier)
            }
        }
    }
}

/// Main and other muscles. A main muscle is never offered again as an "other" one.
private struct CustomExerciseMuscleFields: View {
    @Binding var draft: CustomExerciseDraft
    let showsMissing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetField("Main muscles") {
                VStack(alignment: .leading, spacing: 6) {
                    CustomExerciseChips(
                        options: MuscleGroup.allCases, name: \.displayName,
                        isSelected: { draft.primaryMuscles.contains($0) },
                        identifier: "workout.customExercise.primary",
                        toggle: { togglePrimary($0) }
                    )
                    if showsMissing { CustomExerciseIssueLine(issue: .noPrimaryMuscle) }
                }
            }
            SheetField("Other muscles it works") {
                CustomExerciseChips(
                    options: MuscleGroup.allCases.filter { !draft.primaryMuscles.contains($0) }, name: \.displayName,
                    isSelected: { draft.secondaryMuscles.contains($0) },
                    identifier: "workout.customExercise.secondary",
                    toggle: { muscle in
                        if draft.secondaryMuscles.remove(muscle) == nil { draft.secondaryMuscles.insert(muscle) }
                    }
                )
            }
        }
    }

    private func togglePrimary(_ muscle: MuscleGroup) {
        if draft.primaryMuscles.remove(muscle) == nil {
            draft.primaryMuscles.insert(muscle)
            draft.secondaryMuscles.remove(muscle)
        }
    }
}

/// The movement, its direction (for a push or a pull only) and the kind of training.
private struct CustomExerciseMovementFields: View {
    @Binding var draft: CustomExerciseDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetField("Movement") {
                CustomExerciseChips(
                    options: MovementPattern.allCases, name: \.displayName,
                    isSelected: { draft.movementPattern == $0 },
                    identifier: "workout.customExercise.pattern",
                    toggle: { draft.movementPattern = $0 }
                )
            }
            if draft.patternHasPlane {
                SheetField("Direction") {
                    VStack(alignment: .leading, spacing: 6) {
                        FlowLayout(spacing: 8) {
                            Button { draft.plane = nil } label: {
                                Text("Either", comment: "Custom exercise form: the push or pull has no set direction")
                            }
                            .buttonStyle(ChipButtonStyle(selected: draft.plane == nil))
                            .accessibilityIdentifier("workout.customExercise.plane")
                            ForEach(MovementPlane.allCases, id: \.self) { plane in
                                Button(plane.displayName) { draft.plane = plane }
                                    .buttonStyle(ChipButtonStyle(selected: draft.plane == plane))
                                    .accessibilityIdentifier("workout.customExercise.plane")
                            }
                        }
                        caption(Text("Horizontal is straight out in front, like a row. Vertical is overhead, like a pull-up.",
                                     comment: "Custom exercise form: explains the two directions"))
                    }
                }
            }
            SheetField("Kind") {
                VStack(alignment: .leading, spacing: 6) {
                    CustomExerciseChips(
                        options: ExerciseModality.allCases, name: \.displayName,
                        isSelected: { draft.modality == $0 },
                        identifier: "workout.customExercise.modality",
                        toggle: { draft.modality = $0 }
                    )
                    caption(Text("Only strength exercises fill a session's lifting, and a mobility stretch can join the cool-down. Power, balance and cardio moves are there to log.",
                                 comment: "Custom exercise form: how the kind of training decides where the exercise is planned"))
                }
            }
        }
    }

    private func caption(_ text: Text) -> some View {
        text
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }
}

/// The main equipment, what else the movement works with, and gear it can't be done without.
private struct CustomExerciseEquipmentFields: View {
    @Binding var draft: CustomExerciseDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetField("Equipment") {
                CustomExerciseChips(
                    options: Equipment.allCases, name: \.displayName,
                    isSelected: { draft.equipment == $0 },
                    identifier: "workout.customExercise.equipment",
                    toggle: { tool in
                        draft.equipment = tool
                        draft.alternativeEquipment.remove(tool)
                    }
                )
            }
            SheetField("Also works with") {
                CustomExerciseChips(
                    options: Equipment.allCases.filter { $0 != draft.equipment }, name: \.displayName,
                    isSelected: { draft.alternativeEquipment.contains($0) },
                    identifier: "workout.customExercise.alternative",
                    toggle: { tool in
                        if draft.alternativeEquipment.remove(tool) == nil { draft.alternativeEquipment.insert(tool) }
                    }
                )
            }
            SheetField("Can't be done without") {
                VStack(alignment: .leading, spacing: 6) {
                    CustomExerciseChips(
                        options: GymEquipment.allCases, name: \.displayName,
                        isSelected: { draft.requiredGear.contains($0) },
                        identifier: "workout.customExercise.gear",
                        toggle: { gear in
                            if draft.requiredGear.remove(gear) == nil { draft.requiredGear.insert(gear) }
                        }
                    )
                    Text("Fernlet only plans it where you have one of its tools and every piece of gear picked here.",
                         comment: "Custom exercise form: how equipment and gear decide where the exercise is planned")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
        }
    }
}

/// How a set is counted, whether it is done one side at a time, and its difficulty.
private struct CustomExerciseSetFields: View {
    @Binding var draft: CustomExerciseDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetField("Counted in") {
                CustomExerciseChips(
                    options: CustomExerciseDraft.measures, name: \.displayName,
                    isSelected: { draft.measure == $0 },
                    identifier: "workout.customExercise.measure",
                    toggle: { draft.measure = $0 }
                )
            }
            Toggle(isOn: $draft.unilateral) {
                Text("One side at a time", comment: "Custom exercise form: switch for an exercise done one side, then the other")
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
            .accessibilityIdentifier("workout.customExercise.unilateral")
            SheetField("Difficulty") {
                CustomExerciseChips(
                    options: ExerciseDifficulty.allCases, name: \.displayName,
                    isSelected: { draft.difficulty == $0 },
                    identifier: "workout.customExercise.difficulty",
                    toggle: { draft.difficulty = $0 }
                )
            }
        }
    }
}
