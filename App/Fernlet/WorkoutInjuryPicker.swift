import SwiftUI
import FernletDomainModel
import FernletUI

/// The setup sheet's injury state while it is being edited: the body-area picker and the single
/// muscles still offered as chips.
///
/// Pure, so the open and save rules are testable without a view:
/// - Opening reads the profile's picker areas, plus any area an older build saved as one of its
///   chips (as severe — that chip left the area out entirely). An area the note itself names is not
///   copied into the picker: the note keeps applying it live, and the section says so.
/// - Saving writes the picker, then mirrors everything severe — the picker's severe areas, the
///   note's areas the picker doesn't name, the note's muscles and the rested-muscle chips — into the
///   avoided sets, which is all an older build reads. Mild areas are not mirrored: an older build
///   cannot train around an area, and the avoided sets would turn mild into severe here.
struct WorkoutInjuryDraft: Equatable {
    /// Each area's severity; an area that isn't in the map has no limit.
    var areas: [BodyArea: InjurySeverity]
    /// Muscles avoided outright through the chips beside the picker.
    var restedMuscles: Set<MuscleGroup>

    /// The single-muscle chips the old sheet offered that no body area covers.
    static let restableMuscles: [MuscleGroup] = [.chest, .hamstrings, .calves]

    init(areas: [BodyArea: InjurySeverity] = [:], restedMuscles: Set<MuscleGroup> = []) {
        self.areas = areas
        self.restedMuscles = restedMuscles
    }

    /// The draft a sheet opens on for `profile`.
    init(profile: WorkoutProfile) {
        let note = InjuryNoteMatcher.match(profile.injuryNotes)
        let legacy = BodyArea.legacyAreas(
            avoidedMuscles: profile.avoidedMuscles, avoidedMovements: profile.avoidedMovements
        )
        var areas = profile.injuryAreas
        for area in legacy.subtracting(note.areas) where areas[area] == nil { areas[area] = .severe }
        let severe = Set(areas.filter { $0.value == .severe }.keys).union(note.areas)
        let covered = severe.reduce(into: Set<MuscleGroup>()) { $0.formUnion($1.muscles) }
        let rested = profile.avoidedMuscles.subtracting(covered).subtracting(note.muscles)
        self.init(areas: areas, restedMuscles: Set(Self.restableMuscles).intersection(rested))
    }

    /// `profile` with this draft saved (see the type's note for what is mirrored where).
    func applied(to profile: WorkoutProfile) -> WorkoutProfile {
        var updated = profile
        updated.injuryAreas = areas
        let note = InjuryNoteMatcher.match(profile.injuryNotes)
        let severe = Set(areas.filter { $0.value == .severe }.keys).union(note.areas.subtracting(areas.keys))
        updated.avoidedMuscles = severe.reduce(into: restedMuscles.union(note.muscles)) { $0.formUnion($1.muscles) }
        updated.avoidedMovements = severe.reduce(into: Set<MovementPattern>()) { $0.formUnion($1.movements) }
        return updated
    }

    /// The note's areas the picker leaves to it, in picker order — what the section lists as "left
    /// out because of your note".
    static func noteOnlyAreas(note: String, areas: [BodyArea: InjurySeverity]) -> [BodyArea] {
        let named = InjuryNoteMatcher.match(note).areas
        return BodyArea.allCases.filter { named.contains($0) && areas[$0] == nil }
    }
}

/// The "Areas to work around" section of the workout setup sheet: a severity picker per body area,
/// the rested-muscle chips, the free-text note, and a line naming what the note itself leaves out.
///
/// Each area row is a menu picker (None · Mild · Severe) whose accessibility label is the area's
/// name, so VoiceOver reads "Knee, Mild, pop-up button" and Voice Control answers to "Tap Knee". At
/// accessibility text sizes a row stacks its name above the picker instead of truncating either.
struct WorkoutInjurySection: View {
    @Binding var draft: WorkoutInjuryDraft
    @Binding var notes: String

    var body: some View {
        SheetField("Areas to work around") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mild: Fernlet trains around it, lighter and with supported moves. Severe: those moves are left out.",
                     comment: "Explains the two severities in the workout injury picker")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                VStack(spacing: 0) {
                    ForEach(BodyArea.allCases) { area in
                        InjuryAreaRow(area: area, severity: severityBinding(for: area))
                    }
                }
                restedMusclesRow
                TextField("Anything else to keep in mind (not medical advice)", text: $notes,
                          prompt: .fieldPrompt("Anything else to keep in mind (not medical advice)"))
                    .sheetTextInput()
                noteSummary
            }
        }
    }

    private var restedMusclesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Muscles to rest", comment: "Caption over the single-muscle chips in the workout injury section")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            FlowLayout(spacing: 8) {
                ForEach(WorkoutInjuryDraft.restableMuscles) { muscle in
                    Button(muscle.displayName) { toggle(muscle) }
                        .buttonStyle(ChipButtonStyle(selected: draft.restedMuscles.contains(muscle)))
                        .accessibilityIdentifier("workout.setup.rest.\(muscle.rawValue)")
                }
            }
        }
    }

    /// Names the areas the note leaves out on its own, so a "None" in the picker never hides a limit
    /// that still applies.
    @ViewBuilder private var noteSummary: some View {
        let fromNote = WorkoutInjuryDraft.noteOnlyAreas(note: notes, areas: draft.areas)
        if !fromNote.isEmpty {
            let names = fromNote.map(\.displayName).formatted(.list(type: .and))
            Text("Left out because of your note: \(names)",
                 comment: "Body areas the free-text injury note names, which the planner leaves out; the argument is a list of areas")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    private func severityBinding(for area: BodyArea) -> Binding<InjurySeverity?> {
        Binding(get: { draft.areas[area] }, set: { draft.areas[area] = $0 })
    }

    /// Flips one muscle's chip through ``FernletFeedback/select(_:in:preferences:)`` (report B6): a
    /// flip always changes the set, so every tap ticks.
    private func toggle(_ muscle: MuscleGroup) {
        var rested = draft.restedMuscles
        if rested.remove(muscle) == nil { rested.insert(muscle) }
        FernletFeedback.system.select(rested, in: &draft.restedMuscles)
    }
}

/// One body area: its name and a None · Mild · Severe menu. The name drawn beside the menu is hidden
/// from VoiceOver because the menu already carries it as its label.
private struct InjuryAreaRow: View {
    let area: BodyArea
    @Binding var severity: InjurySeverity?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(area.displayName)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Picker(selection: $severity) {
                Text("None", comment: "Injury picker option: no limit for this body area").tag(InjurySeverity?.none)
                Text("Mild", comment: "Injury picker option: train around this body area, lighter").tag(InjurySeverity?.some(.mild))
                Text("Severe", comment: "Injury picker option: leave this body area's exercises out").tag(InjurySeverity?.some(.severe))
            } label: {
                Text(area.displayName)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // A menu picker draws its value in the tint; the sheet's `moss` measures 3.74:1 on
            // parchment, under the 4.5:1 text floor, so the value takes the moss text token.
            .tint(Color.mossInk)
            .accessibilityIdentifier("workout.setup.injury.\(area.rawValue)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
