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
///
/// Edits the LIFTING block only. The warm-up, activation, cardio and cool-down blocks around it are
/// generated, are not what anyone means by "edit my workout", and would blow the row cap (the warm-up
/// alone is twenty-odd stretches); saving puts them back around the edited lifting rows unchanged. A
/// heavy lift's warm-up sets are generated the same way: hidden here, and put back in front of their
/// lift on save (a lift moved keeps them, a lift removed takes them along).
///
/// Each catalog row also carries the exercise preferences (idea 15): "Swap" replaces it in place
/// from ``ExerciseSwapSheet``, after which the card offers "Always use this instead"; "Don't
/// suggest" marks it for the planner to leave out from now on. Both are pending until Save, which
/// writes them with the edited rows (``FernletStore/applyExercisePreferenceEdits(hidden:alternates:)``)
/// — Cancel drops them like any other edit.
struct GuidedWorkoutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    let session: WorkoutProgram.SessionSuggestion

    @State private var rows: [PrescribedExercise]
    @State private var pickerSelection: ExerciseTarget?
    @State private var pickerResetToken = 0
    @State private var showDiscardConfirm = false
    @State private var showCouldNotSave = false
    /// The row being swapped, with its options; nil = the swap sheet is closed.
    @State private var swapRequest: EditorSwapRequest?
    /// Pending preferences, written on Save (``GuidedEditorPreferences``).
    @State private var preferenceEdits = GuidedEditorPreferences()

    /// The resolved "Last time" recall values keyed by row name — held as state so the per-name
    /// history rollups run once per name-set change (see ``refreshLastTime()``), not on every
    /// sets/reps/rest edit.
    @State private var lastTimeByName: [String: String] = [:]

    init(store: FernletStore, session: WorkoutProgram.SessionSuggestion) {
        self.store = store
        self.session = session
        _rows = State(initialValue: Self.liftingRows(of: session))
    }

    /// The session's lifting-block rows — what this editor shows and edits — without the warm-up sets.
    static func liftingRows(of session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        WorkoutWarmUpSets.removingWarmUpSets(from: session.exercises.filter { $0.block == .lifting })
    }

    private var goal: GoalType { store.settings.selectedGoal }

    /// The note under the editor's rows: one whole sentence per goal. It used to lowercase the goal's
    /// display name and splice it in ("your strength goal"), which a translator can neither inflect
    /// nor reorder, and which lowercases German nouns.
    static func restDefaultsNote(for goal: GoalType) -> Text {
        switch goal {
        case .wellness: Text("Rest defaults come from your wellness goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        case .strength: Text("Rest defaults come from your strength goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        case .weightManagement: Text("Rest defaults come from your weight management goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        case .mentalHealth: Text("Rest defaults come from your mental health goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        case .recovery: Text("Rest defaults come from your recovery goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        case .exploring: Text("Rest defaults come from your exploring goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        case .sportsPrep: Text("Rest defaults come from your sports prep goal and the movement — tune any of them here. Changes apply the next time you start this workout.")
        }
    }

    /// The row list diverges from the session this editor opened on (reorder, add, remove, or a
    /// sets/reps/rest tweak). `PrescribedExercise` is Equatable, so this is an honest compare.
    private var isDirty: Bool { rows != Self.liftingRows(of: session) || preferenceEdits.hasPending }

    private func attemptCancel() {
        if isDirty { showDiscardConfirm = true } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The 2026-08-21 template header: Cancel top-left (wired to the discard prompt via
            // `attemptCancel`), Fraunces title, and the session name as the runtime subtitle —
            // `Text(verbatim:)` because a session name is user/planner data, never a catalog key; a
            // planner session's frozen name is drawn in the user's language.
            SheetHeader(
                title: Text("Edit workout"),
                subtitle: Text(verbatim: session.displayedName),
                onCancel: { attemptCancel() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        exerciseCard(index: index, row: row)
                    }

                    addExerciseSection

                    Self.restDefaultsNote(for: goal)
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
        .sheet(item: $swapRequest) { request in
            ExerciseSwapSheet(originalName: request.name, options: request.options) { target in
                swapRow(request.id, to: target)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
    }

    // MARK: Exercise card

    @ViewBuilder private func exerciseCard(index: Int, row: PrescribedExercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: row.displayName)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GuidedEditorRowControls(
                    exerciseName: row.displayName,
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
                        TextField("8-12", text: repsBinding(index), prompt: .fieldPrompt("8-12"))
                            .sheetTextInput()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                stepperField(title: "Rest", value: restLabel(effectiveRest(row)),
                             decrementLabel: "Shorter rest", incrementLabel: "Longer rest",
                             onDecrement: { setRest(index, effectiveRest(row) - 15) },
                             onIncrement: { setRest(index, effectiveRest(row) + 15) },
                             fullWidth: true)

                preferenceActions(for: row)
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

    // MARK: Exercise preferences

    /// The card's Swap and Don't-suggest actions and the lines that say what is pending.
    private func preferenceActions(for row: PrescribedExercise) -> some View {
        let original = preferenceEdits.swappedFrom[row.id]
        return GuidedEditorPreferenceActions(
            exerciseName: row.name,
            swappedFrom: original,
            alwaysChosen: original.map { preferenceEdits.alternates[$0] == row.name } ?? false,
            hidden: preferenceEdits.hiddenState(of: row.name,
                                                saved: store.settings.workoutExercisePreferences),
            onSwap: { openSwap(for: row) },
            onAlways: { preferenceEdits.chooseAlways(row.name, for: original) },
            onUndoAlways: { preferenceEdits.undoAlways(for: original) },
            onHide: { preferenceEdits.hide(row.name) },
            onUndoHide: { preferenceEdits.undoHide(row.name) }
        )
    }

    /// Opens the swap sheet for `row`, with options that skip everything already in the session.
    private func openSwap(for row: PrescribedExercise) {
        let options = store.exerciseSwapOptions(
            for: row.name, excluding: Set(rows.map(\.name)), alsoHidden: preferenceEdits.hidden,
            harder: row.guidance?.harderVariation
        )
        swapRequest = EditorSwapRequest(id: row.id, name: row.name, options: options)
    }

    /// Replaces the row `id` with `target` in place, keeping its prescription
    /// (``swapped(_:to:goal:)``), and records what it was swapped from.
    private func swapRow(_ id: UUID, to target: ExerciseTarget) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        preferenceEdits.recordSwap(row: id, from: rows[index].name, to: target.name)
        rows[index] = Self.swapped(rows[index], to: target, goal: goal)
    }

    /// `row` with `target` in its place: the same slot role, sets, rest and position, a hold when the
    /// new exercise is timed (and reps when it is not), and no load guidance — the weight range
    /// belonged to the lift that left. `static` so it is testable without the view.
    static func swapped(_ row: PrescribedExercise, to target: ExerciseTarget, goal: GoalType) -> PrescribedExercise {
        var replaced = row
        let style = WorkoutGoalStyle.style(for: goal, energy: .moderate, sport: "")
        replaced.name = target.name
        replaced.fromCatalog = true
        replaced.side = nil
        replaced.guidance = nil
        if target.measure == .seconds {
            let hold = row.holdSeconds ?? style.holdSeconds
            replaced.holdSeconds = hold
            replaced.reps = PrescribedExercise.holdText(seconds: hold)
        } else {
            replaced.holdSeconds = nil
            replaced.reps = row.holdSeconds == nil ? row.reps : style.reps(for: row.role)
        }
        return replaced
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

    /// The reps field. For a timed row (a plank, a carry) it edits the hold: the digits typed become
    /// `holdSeconds`, and `reps` stays the matching "40 s" display text the runner and plan show.
    private func repsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { rows.indices.contains(index) ? rows[index].reps : "" },
            set: { newValue in
                guard rows.indices.contains(index) else { return }
                guard rows[index].holdSeconds != nil else {
                    rows[index].reps = newValue
                    return
                }
                let digits = newValue.filter(\.isNumber).prefix(3)
                guard let seconds = Int(digits), seconds > 0 else { return }
                rows[index].holdSeconds = seconds
                rows[index].reps = PrescribedExercise.holdText(seconds: seconds)
            }
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
        let hold: Int? = target.measure == .seconds ? style.holdSeconds : nil
        return PrescribedExercise(
            name: target.name,
            sets: style.adjustedSets(for: role, energy: .moderate),
            reps: hold.map { PrescribedExercise.holdText(seconds: $0) } ?? style.reps(for: role),
            role: role,
            fromCatalog: true,
            holdSeconds: hold
        )
    }

    // MARK: Save

    private func save() {
        var updated = session
        let before = session.exercises.filter { $0.block == .warmUp || $0.block == .activation }
        let after = session.exercises.filter { $0.block == .cardio || $0.block == .coolDown }
        let lifting = WorkoutWarmUpSets.reattach(rows, from: session.exercises.filter { $0.block == .lifting })
        updated.exercises = before + lifting + after
        // Rebuild the display list so the sheet card and the logged workout reflect the edits.
        let lines = WorkoutSessionBlocks.planText(for: updated.exercises)
        updated.suggestion.exercises = lines.isEmpty ? session.suggestion.exercises : lines
        // R7: the store refuses the save when the plan moved on or the session already started —
        // say so instead of dismissing as if the edits landed.
        guard store.updateGuidedSession(updated) else {
            FernletAuditLog.log("workout.guided.editRefused")
            showCouldNotSave = true
            return
        }
        // Only once the rows landed, so a refused save never half-applies the sheet.
        store.applyExercisePreferenceEdits(hidden: preferenceEdits.hidden, alternates: preferenceEdits.alternates)
        dismiss()
    }
}

/// The swap sheet's subject in ``GuidedWorkoutEditorSheet``: the row being swapped (its id), its
/// name, and the options computed when Swap was tapped.
struct EditorSwapRequest: Identifiable {
    let id: UUID
    let name: String
    let options: [ExerciseTarget]
}

/// Whether the planner will still suggest an exercise, as one card in the editor sees it.
enum GuidedEditorHiddenState: Equatable {
    /// Suggested as usual — the card offers "Don't suggest".
    case suggested
    /// Marked in this sheet, written on Save — the card offers "Undo".
    case pending
    /// Already hidden in Workout setup — shown again only from there.
    case saved
}

/// The editor's pending exercise preferences, written on Save.
///
/// `swappedFrom` remembers, per row id, the exercise the plan had there before any swap, so a row
/// swapped twice still pairs the plan's original with the final pick, and a row swapped back to its
/// original pairs nothing. Pure, so the rules are testable without the view.
struct GuidedEditorPreferences: Equatable {
    /// Row id → the frozen name the plan had in that row before it was swapped.
    var swappedFrom: [UUID: String] = [:]
    /// "Always use this instead" picks: the plan's original → the alternate.
    var alternates: [String: String] = [:]
    /// "Don't suggest this" marks, in the order they were made.
    var hidden: [String] = []

    /// Anything waiting for Save.
    var hasPending: Bool { !alternates.isEmpty || !hidden.isEmpty }

    /// Records a swap of row `row` from `old` to `new`. A pending "always" for the row's original is
    /// dropped (it named the exercise that just left); swapping back to the original clears the row.
    mutating func recordSwap(row: UUID, from old: String, to new: String) {
        let original = swappedFrom[row] ?? old
        alternates[original] = nil
        let same = WorkoutExerciseCatalog.normalizedName(original) == WorkoutExerciseCatalog.normalizedName(new)
        swappedFrom[row] = same ? nil : original
    }

    /// "Always use `name` instead of `original`."
    mutating func chooseAlways(_ name: String, for original: String?) {
        guard let original else { return }
        alternates[original] = name
    }

    /// Takes back a pending "always" for `original`.
    mutating func undoAlways(for original: String?) {
        guard let original else { return }
        alternates[original] = nil
    }

    /// Marks `name` "Don't suggest this".
    mutating func hide(_ name: String) {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        guard !hidden.contains(where: { WorkoutExerciseCatalog.normalizedName($0) == key }) else { return }
        hidden.append(name)
    }

    /// Takes back a pending "Don't suggest this".
    mutating func undoHide(_ name: String) {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        hidden.removeAll { WorkoutExerciseCatalog.normalizedName($0) == key }
    }

    /// Where `name` stands: hidden already (`saved`), marked here, or suggested.
    func hiddenState(of name: String, saved: WorkoutExercisePreferences) -> GuidedEditorHiddenState {
        if saved.isHidden(name) { return .saved }
        let key = WorkoutExerciseCatalog.normalizedName(name)
        return hidden.contains { WorkoutExerciseCatalog.normalizedName($0) == key } ? .pending : .suggested
    }
}

/// One editor card's preference row: "Swap" and "Don't suggest" as text buttons, then a line for a
/// swap ("Swapped in for Back squat." with "Always use this instead", or what was chosen with
/// "Undo") and a line for a pending or saved hide.
///
/// The buttons wrap (`FlowLayout`) and every line wraps, so nothing truncates at accessibility text
/// sizes. VoiceOver hears each button with the exercise it acts on ("Swap Goblet squat"); Voice
/// Control answers to the visible words ("Swap", "Undo"), numbering the repeats across cards.
private struct GuidedEditorPreferenceActions: View {
    let exerciseName: String
    let swappedFrom: String?
    let alwaysChosen: Bool
    let hidden: GuidedEditorHiddenState
    let onSwap: () -> Void
    let onAlways: () -> Void
    let onUndoAlways: () -> Void
    let onHide: () -> Void
    let onUndoHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 16) {
                actionButton(Text("Swap"),
                             systemImage: "arrow.left.arrow.right", action: onSwap)
                    .accessibilityLabel(Text("Swap \(exerciseName)"))
                    .accessibilityInputLabels([Text("Swap")])
                    .accessibilityIdentifier("workout.editor.swap")
                if hidden == .suggested {
                    actionButton(Text("Don't suggest", comment: "Plan editor: stop Fernlet suggesting this exercise"),
                                 systemImage: "eye.slash", action: onHide)
                        .accessibilityLabel(Text("Don't suggest \(exerciseName)", comment: "Spoken name of the plan editor's Don't suggest button; the argument is the exercise"))
                        .accessibilityInputLabels([Text("Don't suggest")])
                        .accessibilityIdentifier("workout.editor.hide")
                }
            }
            if let swappedFrom { swapLine(swappedFrom) }
            hiddenLine
        }
    }

    @ViewBuilder private func swapLine(_ original: String) -> some View {
        if alwaysChosen {
            statusLine(Text("From now on, Fernlet plans \(exerciseName) instead of \(original).",
                            comment: "Plan editor: a saved swap, written on Save; the arguments are the new and the original exercise"))
            actionButton(Text("Undo"), systemImage: "arrow.uturn.backward", action: onUndoAlways)
                .accessibilityLabel(Text("Stop always using \(exerciseName)", comment: "Spoken name of the Undo button under a saved swap; the argument is the exercise"))
                .accessibilityInputLabels([Text("Undo")])
                .accessibilityIdentifier("workout.editor.undoAlways")
        } else {
            statusLine(Text("Swapped in for \(original).", comment: "Plan editor: this exercise replaced another; the argument is the one it replaced"))
            actionButton(Text("Always use this instead", comment: "Plan editor: always plan this exercise where the one it replaced would be"),
                         systemImage: "pin", action: onAlways)
                .accessibilityInputLabels([Text("Always use this instead"), Text("Always")])
                .accessibilityIdentifier("workout.editor.always")
        }
    }

    @ViewBuilder private var hiddenLine: some View {
        switch hidden {
        case .suggested:
            EmptyView()
        case .pending:
            statusLine(Text("Fernlet won't suggest this again.", comment: "Plan editor: this exercise is marked Don't suggest, written on Save"))
            actionButton(Text("Undo"), systemImage: "arrow.uturn.backward", action: onUndoHide)
                .accessibilityLabel(Text("Keep suggesting \(exerciseName)", comment: "Spoken name of the Undo button under a Don't suggest mark; the argument is the exercise"))
                .accessibilityInputLabels([Text("Undo")])
                .accessibilityIdentifier("workout.editor.undoHide")
        case .saved:
            statusLine(Text("Hidden from suggestions. You can show it again in Workout setup.",
                            comment: "Plan editor: this exercise was already hidden in Workout setup"))
        }
    }

    private func statusLine(_ text: Text) -> some View {
        text
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// A text button in the moss text ink, with its glyph decorative, grown to a 44pt target.
    private func actionButton(_ title: Text, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                title
                    .font(.fernlet(.label))
                    .fernletWrappingText()
            }
            .foregroundStyle(Color.mossInk)
        }
        .buttonStyle(.plain)
        .fernletTapTarget()
    }
}

/// The reorder-up / reorder-down / remove chips on one exercise card in ``GuidedWorkoutEditorSheet``.
///
/// Split out of the card body so it stays inside the Power-of-10 length budget; the enclosing
/// `HStack` still lays the three chips out exactly as before.
private struct GuidedEditorRowControls: View {
    /// Named in each chip's VoiceOver label — "Move up" alone doesn't say what moves. The drawn
    /// name (`displayName`), so it is spoken as the card shows it.
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
