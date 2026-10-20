//
//  ExerciseHowToSheet.swift
//  Fernlet
//
//  The exercise how-to sheet (comparison report idea 3): an exercise's drawn name, primary muscles
//  and equipment, three to five cues, the common mistake, an easier version and the one safety line,
//  reached from the guided runner's exercise card and the plan's exercise rows. The text is the
//  domain's bundled, localized `ExerciseHowToCatalog`; this file only lays it out. The slot at the top
//  draws the exercise's demonstration (idea 8, `ExerciseDemonstrationView.swift`): the licensed media
//  this build carries for the profile's sex, or a placeholder square with the exercise's name when it
//  carries none. The square is about half the visible height at the medium detent and full size when
//  expanded. Opened from a plan or the runner, the sheet ends with idea 15's "Don't suggest this"
//  (tracker row N6), written through the same store calls as the plan editor's.
//

import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

/// Which exercise's how-to sheet is open, by its FROZEN catalog name — the item a presenter binds.
struct ExerciseHowToRequest: Identifiable, Equatable {
    /// The frozen catalog name (`ExerciseTarget.name`), never a display name.
    let name: String
    var id: String { name }
}

extension View {
    /// Presents the how-to sheet for `request`'s exercise while it is non-nil. One presenter per
    /// screen: every info button on it sets the same binding. `sex` is the profile's, which picks
    /// the demonstration's version. `preferences` is the store whose exercise preferences the
    /// sheet's "Don't suggest this" writes: the plan and the runner pass it, because there the
    /// exercise is one Fernlet suggested; any other presenter leaves it nil and the sheet stays
    /// read-only.
    func exerciseHowToSheet(
        _ request: Binding<ExerciseHowToRequest?>, sex: BiologicalSex, preferences: FernletStore? = nil
    ) -> some View {
        sheet(item: request) { shown in
            ExerciseHowToSheet(exerciseName: shown.name, sex: sex, preferences: preferences)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

/// The small info button beside an exercise's name that opens its how-to sheet.
///
/// The glyph draws at body size (it grows with Dynamic Type) inside a 44pt target. VoiceOver hears
/// "How to do Bulgarian split squat"; Voice Control answers to the short "Info" and "How to", and
/// numbers the matches when a plan shows several.
struct ExerciseHowToButton: View {
    /// The frozen catalog name; the spoken label draws its display name.
    let exerciseName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.moss)
        }
        .buttonStyle(.plain)
        .fernletIconButton("How to do \(ExerciseHowToCatalog.displayName(for: exerciseName))")
        .accessibilityInputLabels([Text("Info"), Text("How to")])
        .accessibilityIdentifier("workout.howTo.open")
    }
}

/// How to do one catalog exercise: Done top-right is the whole exit.
///
/// Reading order is layout order, top to bottom: the name (the sheet's heading), the demonstration
/// (one image element, or nothing when it is the decorative placeholder), the main muscles and
/// equipment, then three headed sections — the cues as numbered steps, the common mistake, the
/// easier version — and the safety line. Each cue is one VoiceOver element with its
/// number. Everything scrolls and wraps, so the largest text sizes reflow rather than truncate.
///
/// Opened from a plan or the runner (`preferences` set) for a catalog exercise, the sheet ends with
/// ``ExerciseHowToHideControl``, "Don't suggest this", the one thing on it that changes anything.
/// Opened from anywhere else it is read-only.
struct ExerciseHowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The frozen catalog name of the exercise shown.
    let exerciseName: String
    /// The profile's sex: the demonstration shows that version first.
    let sex: BiologicalSex
    /// The store "Don't suggest this" writes to; nil keeps the sheet read-only.
    var preferences: FernletStore?
    /// The scroll area's height, which sizes the demonstration; zero until first measured.
    @State private var visibleHeight: CGFloat = 0

    private var entry: ExerciseHowTo? { ExerciseHowToCatalog.entry(for: exerciseName) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: Text(verbatim: ExerciseHowToCatalog.displayName(for: exerciseName)),
                onDone: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ExerciseDemonstrationSlot(
                        exerciseName: exerciseName, sex: sex,
                        side: ExerciseDemonstrationLayout.side(forVisibleHeight: visibleHeight))
                    if let entry {
                        ExerciseHowToFacts(target: WorkoutExerciseCatalog.exercise(named: exerciseName))
                        ExerciseHowToSteps(cues: entry.cues)
                        ExerciseHowToNote(title: "Common mistake", text: entry.mistake)
                        ExerciseHowToNote(title: "Easier version", text: entry.easier)
                    } else {
                        Text("There's no how-to for this exercise yet.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    ExerciseHowToSafetyLine()
                    if let preferences, ExerciseHowToHideControl.isOffered(for: exerciseName) {
                        ExerciseHowToHideControl(exerciseName: exerciseName, store: preferences)
                    }
                }
                .padding(20)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
        }
        .background(Color.parchment)
        .uxScreenAnchor("sheet.exerciseHowTo")
    }
}

/// The demonstration at the top of the how-to sheet (comparison report idea 8).
///
/// `ExerciseDemonstrationLibrary` picks the file from what this build carries: the profile's sex
/// first, then the other's, a still under Reduce Motion. A silent loop or a still reads as one image,
/// "Demonstration of <name>", with the numbered cues below as its description. With no licensed file
/// bundled (any build from a clean clone) it draws the decorative placeholder square, which shows the
/// exercise's name and which VoiceOver skips, so the sheet still reads name first, then the facts and cues.
struct ExerciseDemonstrationSlot: View {
    /// The frozen catalog name the media is looked up by.
    let exerciseName: String
    let sex: BiologicalSex
    /// The square's side, from ``ExerciseDemonstrationLayout/side(forVisibleHeight:)``.
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let demonstration = ExerciseDemonstrationLibrary.demonstration(
            for: exerciseName, sex: sex, reduceMotion: reduceMotion)
        if let fileName = demonstration.fileName {
            ExerciseDemonstrationMedia(
                fileName: fileName, animates: demonstration.animates, exerciseName: exerciseName, side: side)
        } else {
            ExerciseDemonstrationPlaceholder(
                exerciseName: exerciseName, target: WorkoutExerciseCatalog.exercise(named: exerciseName), side: side)
        }
    }
}

/// The main muscles and the equipment, each as a caption over its value and read as one element.
/// Draws nothing for an exercise the catalog does not know.
struct ExerciseHowToFacts: View {
    let target: ExerciseTarget?

    var body: some View {
        if let target {
            VStack(alignment: .leading, spacing: 12) {
                fact("Main muscles", value: Self.muscles(of: target))
                if let equipment = Self.equipment(of: target) {
                    fact("Equipment", value: equipment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func fact(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.fernlet(.labelSmall))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.slate)
            Text(verbatim: value)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
        .accessibilityElement(children: .combine)
    }

    /// The primary muscles, localized, in the catalog's token order, joined as a list ("Quads and
    /// Glutes"). Token order, not display order, so the list reads the same way in every language.
    static func muscles(of target: ExerciseTarget) -> String {
        target.primaryMuscles
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
            .formatted(.list(type: .and))
    }

    /// The equipment and its alternatives ("Kettlebell or Dumbbell"), or nil when the catalog lists
    /// none to name.
    static func equipment(of target: ExerciseTarget) -> String? {
        let names = ([target.equipment] + target.alternativeEquipment)
            .filter { $0 != .none }
            .map(\.displayName)
        guard !names.isEmpty else { return nil }
        return names.formatted(.list(type: .or))
    }
}

/// The cues as numbered steps under a "How to do it" heading. Each step is one element ("1, Set the
/// safety arms…"), so VoiceOver reads the number with its cue.
struct ExerciseHowToSteps: View {
    let cues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("How to do it")
            // Bounded: an entry carries at most `ExerciseHowToCatalog.maxCues` cues.
            ForEach(Array(cues.enumerated()), id: \.offset) { index, cue in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: (index + 1).formatted())
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.moss)
                    Text(verbatim: cue)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fernletWrappingText()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One headed note — the common mistake, or the easier version.
struct ExerciseHowToNote: View {
    let title: LocalizedStringKey
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            Text(verbatim: text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fernletWrappingText()
        }
    }
}

/// The sheet's one safety line, shown once for every exercise rather than repeated in each entry.
struct ExerciseHowToSafetyLine: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.terracottaInk)
                // Decorative: the sentence beside it says everything.
                .accessibilityHidden(true)
            Text("Stop if you feel sharp pain.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fernletWrappingText()
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Where one exercise stands for the how-to sheet's "Don't suggest this" — the plan editor's three
/// states (``GuidedEditorHiddenState``), except that the sheet writes at once rather than on a Save.
enum ExerciseHowToHideState: Equatable {
    /// Suggested as usual: the sheet offers "Don't suggest this".
    case suggested
    /// Hidden from this sheet while it has been open: it says so and offers Undo.
    case hiddenHere
    /// Already hidden before the sheet opened: it says where to show it again.
    case hiddenEarlier

    /// The state from the saved preference (`isHidden`) and whether this sheet hid it (`hidHere`).
    /// The saved preference wins: an exercise shown again elsewhere reads as suggested.
    init(isHidden: Bool, hidHere: Bool) {
        if !isHidden {
            self = .suggested
        } else {
            self = hidHere ? .hiddenHere : .hiddenEarlier
        }
    }
}

/// "Don't suggest this" at the foot of the how-to sheet (tracker row N6): idea 15's preference,
/// reached from the exercise it names.
///
/// It writes the same store as the plan editor's "Don't suggest" — ``FernletStore/hideExercise(_:)``,
/// and ``FernletStore/showExerciseAgain(_:)`` for Undo — so the hidden list, its sync, its bounds and
/// Workout setup's "Show again" are idea 15's, not a copy. The editor's marks wait for its Save; this
/// sheet has no Save, so the mark lands at once and the sheet offers Undo while it stays open. An
/// exercise hidden before the sheet opened says where to show it again, in the editor's words.
///
/// Hiding changes plans built from now on. Today's committed plan and a live run keep the exercise:
/// both are their own stored copies, so a run in progress is never disturbed.
///
/// A calm text button in the moss text ink with its glyph decorative, under the safety line, wrapping
/// at every text size inside a 44 pt target. VoiceOver hears the drawn words; Undo speaks "Keep
/// suggesting <name>", as in the editor, and the confirmation is announced when the mark lands. Voice
/// Control answers to the drawn words and the editor's short "Don't suggest" (rule A9).
struct ExerciseHowToHideControl: View {
    /// The frozen catalog name the preference is stored under.
    let exerciseName: String
    let store: FernletStore
    /// This sheet hid the exercise, so Undo is offered.
    @State private var hidHere = false

    /// Whether the sheet offers the control for `name`: a bundled catalog exercise, one Fernlet's
    /// planner can suggest. Custom exercises have no how-to text, so they never reach the sheet.
    static func isOffered(for name: String) -> Bool {
        ExerciseHowToCatalog.entry(for: name) != nil && WorkoutExerciseCatalog.exercise(named: name) != nil
    }

    private var state: ExerciseHowToHideState {
        ExerciseHowToHideState(
            isHidden: store.settings.workoutExercisePreferences.isHidden(exerciseName), hidHere: hidHere)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .suggested:
                textButton(Text("Don't suggest this", comment: "Exercise how-to sheet: stop Fernlet suggesting this exercise in plans"),
                           systemImage: "eye.slash", action: hide)
                    .accessibilityInputLabels([
                        Text("Don't suggest this", comment: "Exercise how-to sheet: stop Fernlet suggesting this exercise in plans"),
                        Text("Don't suggest", comment: "Plan editor: stop Fernlet suggesting this exercise"),
                    ])
                    .accessibilityIdentifier("workout.howTo.hide")
            case .hiddenHere:
                statusLine(Text("Fernlet won't suggest this again.", comment: "Plan editor: this exercise is marked Don't suggest, written on Save"))
                textButton(Text("Undo"), systemImage: "arrow.uturn.backward", action: undo)
                    .accessibilityLabel(Text("Keep suggesting \(ExerciseHowToCatalog.displayName(for: exerciseName))",
                                             comment: "Spoken name of the Undo button under a Don't suggest mark; the argument is the exercise"))
                    .accessibilityInputLabels([Text("Undo")])
                    .accessibilityIdentifier("workout.howTo.undoHide")
            case .hiddenEarlier:
                statusLine(Text("Hidden from suggestions. You can show it again in Workout setup.",
                                comment: "Plan editor: this exercise was already hidden in Workout setup"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Marks the exercise "Don't suggest this" through the store and says so. A refusal (a full
    /// hidden list) changes nothing and is logged by count, like the editor's.
    private func hide() {
        guard store.hideExercise(exerciseName) else {
            FernletAuditLog.log("workout.preferences.refused", context: ["count": "1"])
            return
        }
        hidHere = true
        FernletAnnouncer.system.announce(.success, LocalizedStringResource(
            "Fernlet won't suggest this again.",
            comment: "Plan editor: this exercise is marked Don't suggest, written on Save"))
    }

    /// Takes the mark back: Fernlet suggests the exercise again.
    private func undo() {
        store.showExerciseAgain(exerciseName)
        hidHere = false
    }

    /// One line of state in the slate secondary ink, wrapping.
    private func statusLine(_ text: Text) -> some View {
        text
            .font(.fernlet(.bubble))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// A text button drawn like the plan editor's: the moss text ink, the glyph decorative, the words
    /// wrapping, grown to a 44 pt target.
    private func textButton(_ title: Text, systemImage: String, action: @escaping () -> Void) -> some View {
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
