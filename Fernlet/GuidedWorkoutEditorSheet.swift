import SwiftUI
import FernletDomainModel

/// Manual editor for a suggested workout session: adjust sets / reps / rest per exercise, remove,
/// reorder, and add exercises from the catalog. Saving replaces the session in today's committed plan
/// (preserving its `SessionSuggestion.id` so completions stay valid). Rest is stored as a per-exercise
/// override — the same field the guided runner reads and the future coach app will write — so an edit
/// here changes the rest timer for that exercise.
struct GuidedWorkoutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    let session: WorkoutProgram.SessionSuggestion

    @State private var rows: [PrescribedExercise]
    @State private var pickerSelection: ExerciseTarget?
    @State private var pickerResetToken = 0

    init(store: FernletStore, session: WorkoutProgram.SessionSuggestion) {
        self.store = store
        self.session = session
        _rows = State(initialValue: session.exercises)
    }

    private var goal: GoalType { store.settings.selectedGoal }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, _ in
                        exerciseCard(index: index)
                    }

                    addExerciseSection

                    Text("Rest defaults come from your \(goal.displayName.lowercased()) goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                        .padding(.top, 4)
                }
                .padding(20)
            }
            SheetSaveBar(label: "Save changes") { save() }
        }
        .background(Color.parchment)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit workout")
                    .font(.fernlet(.displayMedium))
                    .foregroundStyle(Color.bark)
                Text(session.suggestion.name)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.slate)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close editor")
            .accessibilityIdentifier("workout.editor.close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: Exercise card

    @ViewBuilder private func exerciseCard(index: Int) -> some View {
        let row = rows[index]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(row.name)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Reorder + remove.
                Button {
                    move(from: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(index == 0 ? Color.slate.opacity(0.3) : Color.moss)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityIdentifier("workout.editor.moveUp")
                Button {
                    move(from: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(index == rows.count - 1 ? Color.slate.opacity(0.3) : Color.moss)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(index == rows.count - 1)
                .accessibilityIdentifier("workout.editor.moveDown")
                Button(role: .destructive) {
                    rows.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rows.count <= 1 ? Color.terracotta.opacity(0.3) : Color.terracotta)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                // Keep at least one exercise — an empty session isn't guidable and would leave a
                // contradictory plan (no exercises, but stale display text).
                .disabled(rows.count <= 1)
                .accessibilityIdentifier("workout.editor.remove")
            }

            if row.fromCatalog {
                HStack(alignment: .center, spacing: 12) {
                    stepperField(title: "Sets", value: "\(row.sets)",
                                 onDecrement: { setSets(index, row.sets - 1) },
                                 onIncrement: { setSets(index, row.sets + 1) })
                    VStack(alignment: .leading, spacing: 4) {
                        Text("REPS")
                            .font(.fernlet(.labelSmall)).tracking(0.6)
                            .foregroundStyle(Color.slate)
                        TextField("8-12", text: repsBinding(index))
                            .sheetTextInput()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                stepperField(title: "Rest", value: restLabel(effectiveRest(row)),
                             onDecrement: { setRest(index, effectiveRest(row) - 15) },
                             onIncrement: { setRest(index, effectiveRest(row) + 15) },
                             fullWidth: true)
            } else {
                Text("Conditioning / mobility — walked as a single step, no rest timer.")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stepperField(title: String, value: String, onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void, fullWidth: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.fernlet(.labelSmall)).tracking(0.6)
                .foregroundStyle(Color.slate)
            HStack(spacing: 12) {
                stepButton(system: "minus", action: onDecrement)
                Text(value)
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                    .frame(minWidth: fullWidth ? 80 : 40)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .multilineTextAlignment(.center)
                stepButton(system: "plus", action: onIncrement)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Add exercise

    private var addExerciseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExerciseSearchPicker(
                selectedExercise: $pickerSelection,
                resetToken: $pickerResetToken,
                title: "Add exercise",
                placeholder: "Search exercise or muscle"
            )
        }
        .onChange(of: pickerSelection) { _, newValue in
            guard let target = newValue else { return }
            rows.append(makeRow(from: target))
            // Clear the selection so the picker is ready for another add.
            pickerSelection = nil
            pickerResetToken += 1
        }
    }

    // MARK: Mutations

    private func move(from index: Int, by delta: Int) {
        let target = index + delta
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }

    private func setSets(_ index: Int, _ newValue: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].sets = max(1, min(8, newValue))
    }

    private func repsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { rows.indices.contains(index) ? rows[index].reps : "" },
            set: { if rows.indices.contains(index) { rows[index].reps = $0 } }
        )
    }

    private func effectiveRest(_ row: PrescribedExercise) -> Int {
        row.restSecondsOverride ?? WorkoutRestGuidance.restSeconds(forExerciseNamed: row.name, role: row.role, goal: goal)
    }

    private func setRest(_ index: Int, _ newValue: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].restSecondsOverride = WorkoutRestGuidance.clamp(newValue)
    }

    private func restLabel(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m == 0 { return "\(s)s" }
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    /// Build a prescribed exercise for a catalog pick, inferring its role from the movement and seeding
    /// sets/reps from the goal style. Rest is left to its research-based default (override nil).
    private func makeRow(from target: ExerciseTarget) -> PrescribedExercise {
        let role: SlotRole
        if target.bodyRegion == .core {
            role = .core
        } else if target.movementPattern == .squat || target.movementPattern == .hinge {
            role = .main
        } else {
            role = .accessory
        }
        let style = WorkoutGoalStyle.style(for: goal, energy: .moderate, sport: "")
        return PrescribedExercise(
            name: target.name,
            sets: style.adjustedSets(for: role, energy: .moderate),
            reps: style.reps(for: role),
            role: role,
            fromCatalog: true
        )
    }

    // MARK: Save

    private func save() {
        var updated = session
        updated.exercises = rows
        // Rebuild the display list so the sheet card and the logged workout reflect the edits.
        let lines = rows.map(\.line).joined(separator: "\n")
        updated.suggestion.exercises = lines.isEmpty ? session.suggestion.exercises : lines
        store.updateGuidedSession(updated)
        dismiss()
    }
}
