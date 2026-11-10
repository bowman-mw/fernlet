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

    /// Each set's reps and weight, and which are drop sets (`b3-edit-reps` draft 2).
    func guidedSetActualSets(_ rows: [GuidedRepsRow], exerciseID: UUID) {
        let sets = GuidedRepsRow.saved(rows)
        editGuidedRun { $0.setActualSets(reps: sets.reps, weights: sets.weights, drops: sets.drops, forExercise: exerciseID) }
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

// MARK: - Touch cues

/// The runner's touch cues (report B7): a weight step, an effort chip, a rest chip. One detent per
/// step under the thumb, played from the tap — never from the run changing, which a Live Activity
/// button also does — under the person's Workout haptics switch and the app-wide level
/// (``WorkoutCuePreferences/current(in:)``). They are `touch` events, so the "Fewer" level drops them.
enum GuidedTouchCue {
    /// Plays `event` under the runner's switches, read now.
    static func play(_ event: FernletFeedbackEvent) {
        FernletFeedback.system.play(event, preferences: WorkoutCuePreferences.current())
    }

    /// `tick` when a −/+ tap really changed the weight; `limit` when it couldn't — "Lighter" at the
    /// one-step floor, "Heavier" past the location's heaviest owned load — so a tap that changes
    /// nothing never feels like one that did.
    static func weightStep(before: Double?, after: Double?) -> FernletFeedbackEvent {
        switch (before, after) {
        case let (before?, after?): abs(after - before) > 0.001 ? .tick : .limit
        case (nil, nil): .limit
        case (nil, _?), (_?, nil): .tick
        }
    }

    /// `tick` when a "−15 s" / "+15 s" moved the rest's end; `limit` at its bounds (five seconds
    /// left, ten minutes long), where nothing on screen moves.
    static func restAdjust(moved: Bool) -> FernletFeedbackEvent {
        moved ? .tick : .limit
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

    /// Where the picker starts when there is no suggestion yet and the location's weights are not
    /// known: an empty bar, a light dumbbell, a light stack. With its weights known it starts at the
    /// lightest load the location owns (``GuidedWorkoutRunState/Tracking/steppedWeight(direction:start:)``, w1).
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

/// The panel under a tracked lift's card: the calibration cue — with "Not now" on a strength check
/// (``GuidedStrengthCheckNotNow``, w4) — the weight picker (the suggestion preselected, so an untouched
/// lift logs as done at that weight), the "Plates" disclosure on a barbell lift
/// (``GuidedPlatesDisclosure``), the override question, the optional effort tap on the last set, and
/// Edit reps — which a warm-up set does without: its reps are never read.
struct GuidedLoadPanel: View {
    var store: FernletStore
    let exercise: GuidedWorkoutRunState.Exercise
    let isLastSet: Bool
    /// Runs "Not now" on a strength check — the runner passes its announced transition, so the move
    /// past the check is spoken and cued like any skip; nil runs the store's transition as it is.
    var onPutOffStrengthCheck: (() -> Void)?
    @State private var editingReps = false
    /// World build (`b3-runner-set`): a framed card, the weight centred between framed − and +.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let tracking = exercise.tracking {
            VStack(alignment: look == nil ? .leading : .center, spacing: 14) {
                if let cue = GuidedCalibrationCue.text(for: tracking.calibrationRaw) {
                    cue.font(.fernlet(.body)).foregroundStyle(look?.text ?? Color.bark).fernletWrappingText()
                }
                if tracking.calibrationRaw != nil, store.guidedRunState?.canPutOffStrengthCheck == true,
                   store.guidedRunState?.currentExercise?.id == exercise.id {
                    GuidedStrengthCheckNotNow(action: onPutOffStrengthCheck ?? store.guidedPutOffStrengthCheck)
                }
                if tracking.isLoadable {
                    GuidedWeightPicker(store: store, exerciseID: exercise.id, tracking: tracking)
                }
                if tracking.equipmentRaw == Equipment.barbell.rawValue, tracking.isLoadable, let selected = tracking.selected {
                    GuidedPlatesDisclosure(weight: selected, unit: LoadUnit(rawValue: tracking.unitRaw ?? "") ?? .lb)
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
                if !exercise.isRampSet {
                    GuidedEditRepsButton(store: store, exercise: exercise, label: Text("Edit reps"))
                }
            }
            .frame(maxWidth: .infinity, alignment: look == nil ? .leading : .center)
            .padding(16)
            .modifier(MoveInsetCardFrame(cornerRadius: look == nil ? 16 : 14))
        }
    }
}

/// The cue a calibration step carries in the runner.
enum GuidedCalibrationCue {
    static func text(for raw: String?) -> Text? {
        switch raw {
        case GuidedWorkoutRunState.CalibrationToken.ramp:
            return Text("Light on purpose — just getting ready.",
                        comment: "Guided workout: the cue on a warm-up set (a lighter set before a lift's working sets or a strength check).")
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

/// "Not now" on a strength check (w4, 2026-11-10): a quiet button under the check's cue, with the one
/// line that says what it does. Tapping it puts the check off for two weeks
/// (``WorkoutCalibrationDeferral``) and moves the run on to what follows the check — never a penalty,
/// and nothing about it is logged as a miss.
struct GuidedStrengthCheckNotNow: View {
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: look == nil ? .leading : .center, spacing: 4) {
            Button(action: action) {
                Text("Not now")
                    .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                    .foregroundStyle(look?.link ?? Color.moss)
                    .underline(look == nil)
            }
            .buttonStyle(.plain)
            .fernletTapTarget()
            .accessibilityHint(Text("Skips the strength check today. Fernlet will ask again in 2 weeks."))
            .accessibilityInputLabels([Text("Not now"), Text("Skip strength check")])
            .accessibilityIdentifier("workout.guided.strengthCheck.notNow")
            Text("Fernlet will ask again in 2 weeks.",
                 comment: "Guided workout: the line under 'Not now' on a strength check, saying the check comes back in two weeks.")
                .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
                .accessibilityHidden(true)
        }
    }
}

/// The −/+ weight picker: one equipment step a tap, starting from the suggestion.
struct GuidedWeightPicker: View {
    var store: FernletStore
    let exerciseID: UUID
    let tracking: GuidedWorkoutRunState.Tracking
    /// World build (`b3-runner-set`): the weight in big Fraunces between framed − and + squares.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: look == nil ? .leading : .center, spacing: 8) {
            guide
                .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
            HStack(spacing: 16) {
                stepButton(systemImage: "minus", label: isAssisted ? Text("Less help") : Text("Lighter"),
                           identifier: "workout.guided.weight.lighter", direction: -1)
                selectedText
                    .font(look == nil ? .fernlet(.stat) : .custom(FernletFontName.frauncesSemiBold, size: 40, relativeTo: .largeTitle))
                    .foregroundStyle(look?.text ?? Color.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: 96)
                    .accessibilityIdentifier("workout.guided.weight")
                stepButton(systemImage: "plus", label: isAssisted ? Text("More help") : Text("Heavier"),
                           identifier: "workout.guided.weight.heavier", direction: 1)
            }
        }
    }

    /// The range and the suggestion; the suggestion alone for a set with one fixed weight (a warm-up
    /// set, a calibration step); the first-time ask with neither.
    private var guide: Text {
        // A weight a planned workout's line named: the plan's own, not a range of Fernlet's.
        if tracking.asWritten == true, let planned = tracking.suggested {
            return Text("As planned: \(GuidedLoadFormat.weight(planned, unit: GuidedLoadFormat.unit(tracking)))")
        }
        guard let suggested = tracking.suggested else {
            guard !isAssisted else {
                return Text("The weight here is help. Pick the help that leaves you about 2 reps to spare.",
                            comment: "Guided workout: the first-time ask on an assisted machine (assisted pull-up, assisted dip), where the weight on the stack helps the person, so a bigger number is easier.")
            }
            return Text("Pick a weight you could lift about 2 more times than asked.")
        }
        let suggestion = GuidedLoadFormat.weight(suggested, unit: GuidedLoadFormat.unit(tracking))
        guard let range = GuidedLoadFormat.range(tracking) else {
            return Text("Suggested \(suggestion)",
                        comment: "Guided workout: the weight Fernlet suggests for a set with one fixed weight (a warm-up set or a strength check), e.g. 'Suggested 95 lb'.")
        }
        return Text("Range \(range) · suggested \(suggestion)")
    }

    /// The lift is on an assisted machine, where the number is help (``WorkoutAssistedLifts``, w3):
    /// the − and + buttons are named "Less help" and "More help" for VoiceOver and Voice Control.
    private var isAssisted: Bool {
        store.guidedRunState?.exercises.first { $0.id == exerciseID }.map { WorkoutAssistedLifts.contains($0.name) } ?? false
    }

    private var selectedText: Text {
        guard let selected = tracking.selected else { return Text("Not set") }
        return Text(verbatim: GuidedLoadFormat.weight(selected, unit: GuidedLoadFormat.unit(tracking)))
    }

    /// The weight the run holds for this lift right now.
    private func runWeight() -> Double? {
        store.guidedRunState?.exercises.first { $0.id == exerciseID }?.tracking?.selected
    }

    private func stepButton(systemImage: String, label: Text, identifier: String, direction: Double) -> some View {
        Button {
            // R6: through the weights this location owns when the run knows them, else by the step.
            let next = tracking.steppedWeight(direction: Int(direction), start: GuidedLoadFormat.startWeight(tracking))
            // B7: "changed" is read off the run on both sides — the store snaps the pick to an owned
            // load or the step, and a quick second tap can land before this view redraws.
            let before = runWeight()
            store.guidedSelectWeight(next, exerciseID: exerciseID)
            GuidedTouchCue.play(GuidedTouchCue.weightStep(before: before, after: runWeight()))
        } label: {
            if let look {
                Text(verbatim: direction < 0 ? "\u{2212}" : "+")
                    .font(FernletFramedFont.stepperGlyph)
                    .foregroundStyle(look.text)
                    .frame(width: 44, height: 44)
                    .fernletFramed(look, cornerRadius: 9)
            } else {
                Image(systemName: systemImage)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.onMoss)
                    .frame(width: 44, height: 44)
                    .background(Color.mossFill, in: Circle())
            }
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
                    Button {
                        store.guidedSetOverrideReason(selected == reason ? nil : reason, exerciseID: exerciseID)
                        // B7, as the effort chips below: every tap picks or clears a reason, so every
                        // tap is one detent, and it answers to the Workout haptics switch.
                        GuidedTouchCue.play(.tick)
                    } label: {
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
                    Button {
                        store.guidedSetEffort(selected == effort ? nil : effort, exerciseID: exerciseID)
                        // B7: every tap picks or clears a chip, so every tap is one detent.
                        GuidedTouchCue.play(.tick)
                    } label: {
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

    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button { editing = true } label: {
            label
                .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                .foregroundStyle(look?.link ?? Color.moss)
                .underline(look == nil)
        }
        .buttonStyle(.plain)
        .fernletTapTarget()
        .accessibilityIdentifier("workout.guided.editReps")
        .sheet(isPresented: $editing) {
            // World build: full height in the sheet frame, like every sheet.
            GuidedRepsEditor(store: store, exercise: exercise)
                .fernletSheet()
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

    /// The tracked lift just finished, while the step after it is on its first set — never a warm-up
    /// set, whose reps are never read.
    private var previous: GuidedWorkoutRunState.Exercise? {
        guard run.isWorking, run.currentSet == 1, run.exerciseIndex > 0,
              run.exercises.indices.contains(run.exerciseIndex - 1) else { return nil }
        let candidate = run.exercises[run.exerciseIndex - 1]
        guard candidate.tracking != nil, candidate.tracking?.skipped != true, !candidate.isRampSet else { return nil }
        return candidate
    }
}

/// One set in the reps editor (`b3-edit-reps` draft 2): its reps, its weight as typed, and whether it is
/// a drop set (a lighter set straight after the one before it, marked ↳).
struct GuidedRepsRow: Identifiable, Equatable {
    var id = UUID()
    var reps: Int
    /// The weight as typed; blank repeats the set above, like the Log sheet's set rows.
    var weight: String
    var isDrop = false

    /// The editor's rows for a tracked lift: the saved reps (or the target for each set), each at its
    /// saved weight — else the weight the set was done at when its Done was tapped, else the selected
    /// one (s4, ``GuidedWorkoutRunState/Tracking/setWeights(count:)``) — with the saved drop marks. So
    /// the sheet opens on what the taps recorded, and saving it untouched changes nothing.
    static func rows(for tracking: GuidedWorkoutRunState.Tracking?, sets: Int) -> [GuidedRepsRow] {
        let target = tracking?.targetReps ?? 0
        let reps = tracking?.actualReps
            ?? Array(repeating: target, count: min(max(1, sets), GuidedWorkoutRunState.Tracking.maxSets))
        let weights = tracking?.actualWeights
        let tapped = tracking?.setWeights(count: reps.count)
        let drops = tracking?.actualDrops
        return reps.prefix(GuidedWorkoutRunState.Tracking.maxSets).enumerated().map { index, count in
            let weight = weights.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                ?? tapped.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? tracking?.selected
            let drop = drops.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? false
            return GuidedRepsRow(reps: count, weight: SetRowDraft.text(for: weight), isDrop: drop)
        }
    }

    /// The rows with a drop set added under the last one: its reps, and about three quarters of its
    /// weight rounded down to the lift's step (never below one step). Unchanged at the set cap.
    static func addingDrop(to rows: [GuidedRepsRow], step: Double?) -> [GuidedRepsRow] {
        guard rows.count < GuidedWorkoutRunState.Tracking.maxSets, let last = rows.last else { return rows }
        let heavier = filledWeights(rows).last ?? nil
        let unit = max(step ?? 5, 0.5)
        let lighter = heavier.map { max(unit, ($0 * 0.75 / unit).rounded(.down) * unit) }
        return rows + [GuidedRepsRow(reps: last.reps, weight: SetRowDraft.text(for: lighter), isDrop: true)]
    }

    /// Each row's weight, a blank one repeating the row above (nil until any row has one).
    static func filledWeights(_ rows: [GuidedRepsRow]) -> [Double?] {
        var carried: Double?
        return rows.prefix(GuidedWorkoutRunState.Tracking.maxSets).map { row in
            carried = SetRowDraft.weight(from: row.weight) ?? carried
            return carried
        }
    }

    /// What the editor saves: the reps, each set's weight (0 where none was ever given), the drop marks.
    static func saved(_ rows: [GuidedRepsRow]) -> (reps: [Int], weights: [Double], drops: [Bool]) {
        let capped = Array(rows.prefix(GuidedWorkoutRunState.Tracking.maxSets))
        return (capped.map { min(max($0.reps, 0), 50) }, filledWeights(capped).map { $0 ?? 0 }, capped.map(\.isDrop))
    }

    /// The question the rows' typed weights raise before the reps editor saves (w2,
    /// ``SetWeightCheck``): the heaviest against last time's weight (in the lift's unit), else against
    /// the lift's other sets. Nil when nothing stands out, or the value is `settled`.
    static func weightQuestion(
        for rows: [GuidedRepsRow], lift: String, tracking: GuidedWorkoutRunState.Tracking?,
        lastTime: GuidedWorkoutRunState.LastTime?, settled: Set<String>
    ) -> SetWeightQuestion? {
        let unit: LoadUnit = tracking?.unitRaw == LoadUnit.kg.rawValue ? .kg : .lb
        return SetWeightCheck.question(
            lift: lift, weights: filledWeights(rows),
            lastTime: SetWeightCheck.weight(lastTime?.weight, unitToken: lastTime?.unitRaw, in: unit),
            unit: unit, settled: settled
        )
    }

    /// The row's set number, counting only the sets that are not drop sets; nil for a drop set.
    static func setNumber(at index: Int, in rows: [GuidedRepsRow]) -> Int? {
        guard rows.indices.contains(index), !rows[index].isDrop else { return nil }
        return rows.prefix(index + 1).filter { !$0.isDrop }.count
    }

    /// The row's name: "Set 3" (``setNumber(at:in:)``), or "Drop set".
    static func label(at index: Int, in rows: [GuidedRepsRow]) -> Text {
        guard let number = setNumber(at: index, in: rows) else { return Text("Drop set") }
        return Text("Set \(number)")
    }
}

/// Per-set reps and weight for one lift, and drop sets (`b3-edit-reps` draft 2). Only the sets that
/// went differently need touching.
struct GuidedRepsEditor: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    let exercise: GuidedWorkoutRunState.Exercise
    @State private var rows: [GuidedRepsRow]
    /// The question a typed weight raised on Save (w2), while its alert is up.
    @State private var weightQuestion: SetWeightQuestion?
    /// Values never asked about (again): the weights the sheet opened with, and any already asked.
    @State private var settledWeights: Set<String>
    @Environment(\.fernletFramedLook) private var look

    /// Reps a set may be edited to.
    static let repsRange = 0...50

    init(store: FernletStore, exercise: GuidedWorkoutRunState.Exercise) {
        self.store = store
        self.exercise = exercise
        let opened = GuidedRepsRow.rows(for: exercise.tracking, sets: exercise.sets)
        _rows = State(initialValue: opened)
        _settledWeights = State(initialValue: SetWeightCheck.keys(lift: exercise.name, weights: GuidedRepsRow.filledWeights(opened)))
    }

    /// Save: asks first when a typed weight stands far above last time's or the other sets'
    /// (``GuidedRepsRow/weightQuestion(for:lift:tracking:lastTime:settled:)``), once per value.
    private func saveTapped() {
        if takesLoad, let asked = GuidedRepsRow.weightQuestion(
            for: rows, lift: exercise.name, tracking: exercise.tracking, lastTime: exercise.lastTime, settled: settledWeights
        ) {
            settledWeights.insert(asked.key)
            weightQuestion = asked
            return
        }
        save()
    }

    /// Writes the rows to the run and closes the sheet.
    private func save() {
        store.guidedSetActualSets(rows, exerciseID: exercise.id)
        dismiss()
    }

    /// Whether the lift takes a load, so each set shows its weight and a drop set can be added.
    private var takesLoad: Bool { exercise.tracking?.isLoadable == true }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Text("Edit reps"), subtitle: Text(verbatim: exercise.displayedName), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Change only the sets that went differently.")
                        .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                    FernletFramedSection {
                        ForEach($rows) { $row in
                            let index = rows.firstIndex { $0.id == row.id } ?? 0
                            GuidedRepsRowEditor(row: $row, label: GuidedRepsRow.label(at: index, in: rows), number: index + 1,
                                                showsWeight: takesLoad, unit: exercise.tracking?.unitRaw,
                                                onRemove: row.isDrop ? { rows.removeAll { $0.id == row.id } } : nil)
                        }
                    }
                    if takesLoad && rows.count < GuidedWorkoutRunState.Tracking.maxSets {
                        Button { rows = GuidedRepsRow.addingDrop(to: rows, step: exercise.tracking?.step) } label: {
                            HStack(spacing: 8) {
                                FernletIcon(.plus, scale: 2)
                                Text("Add a drop set")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                        .accessibilityHint(Text("Adds a lighter set under the last one."))
                        .accessibilityIdentifier("workout.guided.editReps.addDrop")
                    }
                }
                .padding(20)
            }
            SheetSaveBar(label: "Save", action: saveTapped)
        }
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
        .tint(Color.moss)
        .setWeightQuestion($weightQuestion, onKeep: save)
    }
}

/// One set's row in the reps editor: "Set 1: 10 reps" (or "↳ Drop set: 8 reps"), the framed − + stepper,
/// and its weight with the unit; a drop set can be removed. Stacks at accessibility sizes.
private struct GuidedRepsRowEditor: View {
    @Binding var row: GuidedRepsRow
    let label: Text
    let number: Int
    let showsWeight: Bool
    let unit: String?
    let onRemove: (() -> Void)?
    @Environment(\.fernletFramedLook) private var look

    /// The lift's unit (pounds unless the run says kilograms).
    private var loadUnit: LoadUnit { unit == LoadUnit.kg.rawValue ? .kg : .lb }
    private var unitSymbol: String { SetLoadFormat.symbol(loadUnit) }
    /// The unit as VoiceOver says it ("pounds").
    private var unitSpoken: String { SetLoadFormat.spokenName(loadUnit) }

    var body: some View {
        Group {
            if row.isDrop && look != nil {
                // World build (`b3-edit-reps` draft 2): a drop set's line sits over its controls, so its ✕
                // never squeezes the words into three lines.
                VStack(alignment: .leading, spacing: 6) {
                    rowLabel
                    controls.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                    rowLabel
                    controls
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// "Set 1: 10 reps", or "↳ Drop set: 8 reps"; the stepper speaks it, so the words are hidden.
    private var rowLabel: some View {
        HStack(spacing: 4) {
            if row.isDrop { Text(verbatim: "\u{21B3}").accessibilityHidden(true) }
            Text("\(label): \(row.reps) reps")
        }
        // The kit's 15-pt strong face (`b3-edit-reps` draft 2).
        .font(look == nil ? .fernlet(.body) : MoveFont.body)
        .foregroundStyle(look?.text ?? Color.bark)
        .padding(.leading, row.isDrop ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// The reps stepper, the weight and its unit, and a drop set's ✕.
    private var controls: some View {
        HStack(spacing: 8) {
            FernletStepper("Set \(number) reps", value: $row.reps, in: GuidedRepsEditor.repsRange, step: 1)
                .accessibilityLabel(Text("\(label): \(row.reps) reps"))
                .accessibilityIdentifier("workout.guided.editReps.set\(number)")
            if showsWeight { weightField }
            if let onRemove {
                Button(action: onRemove) { FernletIcon(.close, scale: 2).frame(width: 30, height: 44) }
                    .buttonStyle(.plain)
                    .fernletIconButton("Remove drop set")
                    .accessibilityIdentifier("workout.guided.editReps.removeDrop")
            }
        }
        // The controls take their full width first; the row's words wrap instead (the unit was
        // squeezed out when the two shared the row evenly).
        .layoutPriority(1)
    }

    /// The set's weight, typed on the decimal pad, with the unit after it.
    private var weightField: some View {
        HStack(spacing: 6) {
            TextField("Weight", text: $row.weight, prompt: .fieldPrompt("Weight"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                // Under the look the framed field's 14-pt insets need a little more room for "Weight".
                .sheetTextInput(font: look == nil ? .fernlet(.label) : MoveFont.body)
                .frame(width: look == nil ? 70 : 78)
                .accessibilityLabel(Text("\(label) weight, \(unitSpoken)"))
                .accessibilityIdentifier("workout.guided.editReps.weight\(number)")
            Text(verbatim: unitSymbol)
                .font(.fernlet(.label))
                .foregroundStyle(look?.dim ?? Color.slate)
                .accessibilityHidden(true)
        }
    }
}
