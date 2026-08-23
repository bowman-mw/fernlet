import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

/// Manual editor for a suggested workout session: adjust sets / reps / rest per exercise, remove,
/// reorder, and add exercises from the catalog. Saving replaces the session in today's committed plan
/// (preserving its `SessionSuggestion.id` so completions stay valid). Rest is stored as a per-exercise
/// override — the same field the guided runner reads and the future coach app will write — so an edit
/// here changes the rest timer for that exercise. Each exercise card also carries the same one-line
/// factual "last time" recall the shared row editor shows (``WorkoutExerciseBuilder``) — refreshed
/// when the set of exercise names changes, absent when an exercise has no parsed history.
struct GuidedWorkoutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    let session: WorkoutProgram.SessionSuggestion

    @State private var rows: [PrescribedExercise]
    @State private var pickerSelection: ExerciseTarget?
    @State private var pickerResetToken = 0
    @State private var showDiscardConfirm = false
    @State private var showCouldNotSave = false

    /// The resolved "Last time" recall values keyed by row name — held as state so the per-name
    /// history rollups run once per name-set change (see ``refreshLastTime()``), not on every
    /// sets/reps/rest edit.
    @State private var lastTimeByName: [String: String] = [:]

    init(store: FernletStore, session: WorkoutProgram.SessionSuggestion) {
        self.store = store
        self.session = session
        _rows = State(initialValue: session.exercises)
    }

    private var goal: GoalType { store.settings.selectedGoal }

    /// The row list diverges from the session this editor opened on (reorder, add, remove, or a
    /// sets/reps/rest tweak). `PrescribedExercise` is Equatable, so this is an honest compare.
    private var isDirty: Bool { rows != session.exercises }

    private func attemptCancel() {
        if isDirty { showDiscardConfirm = true } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The 2026-08-21 template header: Cancel top-left (wired to the discard prompt via
            // `attemptCancel`), Fraunces title, and the session name as the runtime subtitle —
            // `Text(verbatim:)` because a session name is user/planner data, never a catalog key.
            SheetHeader(
                title: Text("Edit workout"),
                subtitle: Text(verbatim: session.suggestion.name),
                onCancel: { attemptCancel() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        exerciseCard(index: index, row: row)
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
        // Attached to the always-rendered VStack, never to the conditional recall line — an empty
        // view's onAppear/onChange silently never fire (same discipline as ``WorkoutExerciseBuilder``).
        .onAppear { refreshLastTime() }
        .onChange(of: rows.map(\.name)) { _, _ in refreshLastTime() }
        .background(Color.parchment)
        .keyboardDoneToolbar()
        .interactiveDismissDisabled(isDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .alert("Couldn't save those changes", isPresented: $showCouldNotSave) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("That workout has already started or changed. Close this and open it again to edit.")
        }
    }

    // MARK: Exercise card

    @ViewBuilder private func exerciseCard(index: Int, row: PrescribedExercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(row.name)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GuidedEditorRowControls(
                    exerciseName: row.name,
                    canMoveUp: index > 0,
                    canMoveDown: index < rows.count - 1,
                    // Keep at least one exercise — an empty session isn't guidable and would leave a
                    // contradictory plan (no exercises, but stale display text).
                    canRemove: rows.count > 1,
                    onMoveUp: { move(from: index, by: -1) },
                    onMoveDown: { move(from: index, by: 1) },
                    onRemove: { removeRow(at: index) }
                )
            }

            lastTimeLine(for: row.name)

            if row.fromCatalog {
                HStack(alignment: .center, spacing: 12) {
                    stepperField(title: "Sets", value: "\(row.sets)",
                                 decrementLabel: "Fewer sets", incrementLabel: "More sets",
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
                             decrementLabel: "Shorter rest", incrementLabel: "Longer rest",
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

    /// - Parameters:
    ///   - title: The caption above the stepper. Uppercased with `.textCase`, never
    ///     `String.uppercased()`, so the transform runs on the translation and not on the key.
    ///   - decrementLabel: The minus button's spoken name, written out per call site. It used to be
    ///     spliced as `"Fewer \(title.lowercased())"`, and the note that replaced was right that
    ///     lower-casing an English noun into a sentence does not survive translation — the fix is
    ///     per-call-site copy, and with two call sites that is four short strings (T2-1).
    ///   - incrementLabel: The plus button's spoken name.
    private func stepperField(
        title: LocalizedStringKey,
        value: String,
        decrementLabel: LocalizedStringKey,
        incrementLabel: LocalizedStringKey,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void,
        fullWidth: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.fernlet(.labelSmall)).tracking(0.6)
                .foregroundStyle(Color.slate)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                stepButton(system: "minus", label: decrementLabel, action: onDecrement)
                Text(value)
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                    .frame(minWidth: fullWidth ? 80 : 40)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .multilineTextAlignment(.center)
                stepButton(system: "plus", label: incrementLabel, action: onIncrement)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
    }

    private func stepButton(system: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        // The drawn circle stays 30pt; the target and the VoiceOver label ("More sets") come from
        // the shared helper — without it these read as "plus" and "minus".
        // The label is a `LocalizedStringKey` now: T2-1 did the copy task the earlier note deferred
        // to, so each call site writes its own ("Fewer sets", "Shorter rest") instead of splicing a
        // lower-cased noun into a sentence.
        .fernletIconButton(label)
    }

    // MARK: Last-time recall

    /// The one-line factual recall of the last logged session for `name` — the same phrasing,
    /// styling, and round-2.1 constraint (no praise, deltas, or trends) as
    /// ``WorkoutExerciseBuilder``'s line. Renders nothing when the exercise has no parsed history.
    @ViewBuilder private func lastTimeLine(for name: String) -> some View {
        if let values = lastTimeByName[name] {
            Text("Last time: \(values)")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("workout.editor.lastTime")
        }
    }

    /// Recomputes ``lastTimeByName`` for the current rows, reading the store's day history once.
    private func refreshLastTime() {
        lastTimeByName = Self.lastTimeRecall(names: rows.map(\.name),
                                             days: Array(store.loadDays().values))
    }

    /// The "Last time" recall values for each name in `names` that has parsed history in `days`,
    /// keyed by the name exactly as the row spells it (the matching itself is case/whitespace-
    /// insensitive via ``FernletStore/exerciseHistoryEntry(named:days:)``, so "bench PRESS" still
    /// finds "Bench press"). A name with no history is absent from the map — the card's `if let`
    /// then renders no line at all, the honest display for "never logged".
    @MainActor static func lastTimeRecall(names: [String], days: [FernletDay]) -> [String: String] {
        var values: [String: String] = [:]
        // Bounded: `names` comes from `rows`, capped at ``maxExercises``.
        for name in names {
            guard values[name] == nil else { continue }
            values[name] = FernletStore.exerciseHistoryEntry(named: name, days: days)?
                .lastTimeRecallValues
        }
        return values
    }

    // MARK: Add exercise

    private var addExerciseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.count >= Self.maxExercises {
                Text("This workout is full at \(Self.maxExercises) exercises — remove one to add another.")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            } else {
                ExerciseSearchPicker(
                    selectedExercise: $pickerSelection,
                    resetToken: $pickerResetToken,
                    title: "Add exercise",
                    placeholder: "Search exercise or muscle"
                )
            }
        }
        .onChange(of: pickerSelection) { _, newValue in
            guard let target = newValue else { return }
            appendRow(from: target)
            // Clear the selection so the picker is ready for another add.
            pickerSelection = nil
            pickerResetToken += 1
        }
    }

    // MARK: Mutations

    /// R3: a hand-edited session is capped at the same size an imported one is, so repeated picker
    /// selections cannot grow the persisted plan (and its app-group run state) without bound.
    private static let maxExercises = CoachPlanLimits.maxExercisesPerSession

    /// Adds a catalog pick, refusing once the session is at ``maxExercises``.
    private func appendRow(from target: ExerciseTarget) {
        guard rows.count < Self.maxExercises else { return }
        rows.append(makeRow(from: target))
    }

    /// Removes a row, keeping at least one exercise and never indexing out of range.
    private func removeRow(at index: Int) {
        guard rows.count > 1, rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

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
        // R7: the store refuses the save when the plan moved on or the session already started —
        // say so instead of dismissing as if the edits landed.
        guard store.updateGuidedSession(updated) else {
            FernletAuditLog.log("workout.guided.editRefused")
            showCouldNotSave = true
            return
        }
        dismiss()
    }
}

/// The reorder-up / reorder-down / remove chips on one exercise card in ``GuidedWorkoutEditorSheet``.
///
/// Split out of the card body so it stays inside the Power-of-10 length budget; the enclosing
/// `HStack` still lays the three chips out exactly as before.
private struct GuidedEditorRowControls: View {
    /// Named in each chip's VoiceOver label — "Move up" alone doesn't say what moves.
    let exerciseName: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Group {
            Button {
                onMoveUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canMoveUp ? Color.moss : Color.slate.opacity(0.3))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            // Glyph stays 30pt; the tap target and the VoiceOver label come from the shared helper.
            .fernletIconButton("Move \(exerciseName) up")
            .accessibilityIdentifier("workout.editor.moveUp")
            Button {
                onMoveDown()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canMoveDown ? Color.moss : Color.slate.opacity(0.3))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .fernletIconButton("Move \(exerciseName) down")
            .accessibilityIdentifier("workout.editor.moveDown")
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    // The destructive token's row form: terracotta ink, with disabled as an
                    // opacity drop on the whole glyph — opacity, never a colour change (2b).
                    .foregroundStyle(Color.terracottaInk)
                    .frame(width: 30, height: 30)
                    .opacity(canRemove ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .fernletIconButton("Remove \(exerciseName)")
            .accessibilityIdentifier("workout.editor.remove")
        }
    }
}
