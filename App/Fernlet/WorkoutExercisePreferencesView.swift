import SwiftUI
import FernletDomainModel
import FernletUI

/// Workout setup's "Your exercises" entry: one row that opens ``WorkoutExercisePreferencesSheet``.
///
/// Owns its own presentation, like a link, so the setup sheet's draft (split, days, injuries) is
/// untouched by it: everything inside the preferences sheet is saved as it happens.
struct WorkoutExercisePreferencesEntry: View {
    var store: FernletStore
    @State private var showing = false

    var body: some View {
        SheetField("Your exercises") {
            Button { showing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exercises and swaps", comment: "Workout setup: entry to custom exercises, hidden exercises and saved swaps")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        Text("Add your own, and choose what Fernlet suggests.",
                             comment: "Workout setup: what the exercises entry holds")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityInputLabels([Text("Exercises and swaps"), Text("Your exercises")])
            .accessibilityIdentifier("workout.setup.exercises")
        }
        .sheet(isPresented: $showing) {
            WorkoutExercisePreferencesSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

/// Which custom exercise the form opens on: a new one, or an existing one to edit.
struct CustomExerciseFormRequest: Identifiable {
    let id = UUID()
    /// The exercise being edited; nil adds a new one.
    let editing: ExerciseTarget?
}

/// One saved swap as a row: the plan's original and the exercise used instead.
struct SavedExerciseSwap: Identifiable {
    let original: String
    let alternate: String
    var id: String { original }
}

/// "Your exercises" (idea 15): the user's own exercises with "Add an exercise", the exercises hidden
/// from suggestions with "Show again", and the saved swaps with "Remove".
///
/// Every action saves as it happens (Done just closes): showing an exercise again or removing a swap
/// is one tap to reverse in the plan editor, and deleting an exercise asks first. Deleting an exercise
/// takes it out of the catalog only — workouts already logged with it keep it. Each list wraps at
/// every text size; at accessibility sizes a row's button moves under its name (``AdaptiveStack``).
/// Buttons are named for VoiceOver with the exercise they act on and answer Voice Control by their
/// visible word.
struct WorkoutExercisePreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var form: CustomExerciseFormRequest?
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    private var customs: [ExerciseTarget] {
        store.settings.customExercises.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hidden: [String] {
        store.settings.workoutExercisePreferences.hidden.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var swaps: [SavedExerciseSwap] {
        store.settings.workoutExercisePreferences.alternates
            .map { SavedExerciseSwap(original: $0.key, alternate: $0.value) }
            .sorted { $0.original.localizedCaseInsensitiveCompare($1.original) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Your exercises",
                subtitle: "Changes save as you make them.",
                onDone: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    customSection
                    hiddenSection
                    swapsSection
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
        .tint(Color.moss)
        .destructiveConfirmation($pendingDestructiveAction)
        .sheet(item: $form) { request in
            CustomExerciseFormSheet(store: store, editing: request.editing)
                .fernletSheet()
        }
    }

    /// World build (`b3-your-exercises`): the sheet's paper, framed rows, link-coloured row buttons.
    @Environment(\.fernletFramedLook) private var look

    // MARK: Your own exercises

    private var customSection: some View {
        SheetField("Your own exercises") {
            VStack(alignment: .leading, spacing: 10) {
                if customs.isEmpty {
                    caption(Text("Add an exercise Fernlet doesn't have, with its muscles and equipment. It's planned, checked against your equipment and limits, and logged like any other.",
                                 comment: "Your exercises: the empty custom-exercise list"))
                }
                LazyVStack(spacing: 8) {
                    ForEach(customs) { exercise in
                        CustomExerciseRow(
                            exercise: exercise,
                            onEdit: { form = CustomExerciseFormRequest(editing: exercise) },
                            onDelete: { confirmDelete(exercise) }
                        )
                    }
                }
                addButton
            }
        }
    }

    @ViewBuilder private var addButton: some View {
        if store.settings.customExercises.count >= WorkoutExerciseCatalog.maxCustomExercises {
            caption(Text(verbatim: CustomExerciseIssue.atCapacity.message))
        } else {
            Button { form = CustomExerciseFormRequest(editing: nil) } label: {
                Label {
                    Text("Add an exercise", comment: "Your exercises: opens the form for a new custom exercise")
                } icon: {
                    Image(systemName: "plus")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityIdentifier("workout.exercises.add")
        }
    }

    /// Deleting asks first: the exercise leaves the catalog for good, though its logs stay.
    private func confirmDelete(_ exercise: ExerciseTarget) {
        let name = exercise.name
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete \(name)?",
            message: "Fernlet stops planning it and it leaves your exercise list. Workouts you've already logged with it stay in your history.",
            confirmLabel: "Delete",
            auditEvent: "workout.customExercise.deleteConfirmed",
            perform: { store.deleteCustomExercise(named: name) }
        )
    }

    // MARK: Hidden

    private var hiddenSection: some View {
        SheetField("Hidden from suggestions") {
            VStack(alignment: .leading, spacing: 8) {
                if hidden.isEmpty {
                    caption(Text("Nothing is hidden. In a plan's Edit sheet, tap Don't suggest on an exercise to keep it out of your plans.",
                                 comment: "Your exercises: the empty hidden list"))
                }
                ForEach(hidden, id: \.self) { name in
                    PreferenceListRow(
                        title: Text(verbatim: name),
                        buttonTitle: Text("Show again", comment: "Your exercises: let Fernlet suggest this exercise again"),
                        buttonLabel: Text("Show \(name) again", comment: "Spoken name of the Show again button; the argument is the exercise"),
                        identifier: "workout.exercises.showAgain",
                        action: { store.showExerciseAgain(name) }
                    )
                }
            }
        }
    }

    // MARK: Saved swaps

    private var swapsSection: some View {
        SheetField("Saved swaps") {
            VStack(alignment: .leading, spacing: 8) {
                if swaps.isEmpty {
                    caption(Text("No saved swaps. Swap an exercise in a plan's Edit sheet, then tap Always use this instead.",
                                 comment: "Your exercises: the empty saved-swaps list"))
                }
                ForEach(swaps) { swap in
                    PreferenceListRow(
                        title: Text("\(swap.alternate) instead of \(swap.original)",
                                    comment: "A saved swap: the first argument is planned wherever the second would be"),
                        buttonTitle: Text("Remove"),
                        buttonLabel: Text("Stop swapping \(swap.original)", comment: "Spoken name of a saved swap's Remove button; the argument is the original exercise"),
                        identifier: "workout.exercises.removeSwap",
                        action: { store.removeExerciseAlternate(for: swap.original) }
                    )
                }
            }
        }
    }

    private func caption(_ text: Text) -> some View {
        text
            .font(.fernlet(.bodySmall))
            .foregroundStyle(look?.dim ?? Color.slate)
            .fernletWrappingText()
    }
}

/// One custom exercise: its name and pattern · main muscles (tap to edit) and a delete button.
private struct CustomExerciseRow: View {
    let exercise: ExerciseTarget
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// "Push · Chest, Triceps" — the drawn half of the row, localized names only.
    private var summary: String {
        let muscles = exercise.primaryMuscles.sorted { $0.rawValue < $1.rawValue }.map(\.displayName)
        return ([exercise.movementPattern.displayName] + [muscles.formatted(.list(type: .and))])
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: exercise.name)
                            .font(look == nil ? .fernlet(.body) : MoveFont.rowTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                            .fernletWrappingText()
                        Text(verbatim: summary)
                            .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 8)
                    if look != nil {
                        FernletIcon(.chevron)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens it to edit", comment: "Your exercises: what tapping a custom exercise does"))
            .accessibilityInputLabels([Text(verbatim: exercise.name)])
            .accessibilityIdentifier("workout.exercises.edit")
            Button(role: .destructive, action: onDelete) {
                if look != nil {
                    WorldSpriteView(sprite: MoveSprites.trash, scale: 2)
                } else {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.terracottaInk)
                }
            }
            .buttonStyle(.plain)
            .fernletIconButton("Delete \(exercise.name)")
            .accessibilityInputLabels([Text("Delete")])
            .accessibilityIdentifier("workout.exercises.delete")
        }
        .padding(look == nil ? 12 : 14)
        .modifier(MoveInsetCardFrame())
    }
}

/// A hidden exercise or a saved swap: its text and one text button, side by side, or the button
/// under the text at accessibility sizes.
private struct PreferenceListRow: View {
    let title: Text
    let buttonTitle: Text
    /// The button's spoken name, naming the exercise it acts on.
    let buttonLabel: Text
    let identifier: String
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        AdaptiveStack(spacing: 8, horizontalAlignment: .leading) {
            title
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.rowTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                buttonTitle
                    .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                    .foregroundStyle(look?.link ?? Color.mossInk)
                    .fernletWrappingText()
            }
            .buttonStyle(.plain)
            .fernletTapTarget()
            .accessibilityLabel(buttonLabel)
            .accessibilityInputLabels([buttonTitle])
            .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, look == nil ? 12 : 15)
        .padding(.vertical, look == nil ? 6 : 8)
        .modifier(MoveInsetCardFrame())
    }
}
