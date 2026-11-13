import SwiftUI
import FernletDomainModel
import FernletFoundation
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
/// - "No longer an issue" (the owner's fix s5, 2026-11-10; `InjuryEasing`): an area with the switch
///   on keeps its token in ``easing``. It is taken out of the mirror — the area is being eased back
///   in, not left out — and a limit the note gave it stops applying. Choosing a severity for the area
///   again turns the switch off: a new limit is a new injury. Once an area's two weeks are over it
///   opens as None; its token stays only while the note still names the area, so the note does not
///   start applying again.
struct WorkoutInjuryDraft: Equatable {
    /// Each area's severity; an area that isn't in the map has no limit.
    var areas: [BodyArea: InjurySeverity]
    /// Muscles avoided outright through the chips beside the picker.
    var restedMuscles: Set<MuscleGroup>
    /// The areas marked "No longer an issue", each with its stored token (`InjuryEasing`).
    var easing: [BodyArea: String]

    /// The single-muscle chips the old sheet offered that no body area covers.
    static let restableMuscles: [MuscleGroup] = [.chest, .hamstrings, .calves]

    init(areas: [BodyArea: InjurySeverity] = [:], restedMuscles: Set<MuscleGroup> = [], easing: [BodyArea: String] = [:]) {
        self.areas = areas
        self.restedMuscles = restedMuscles
        self.easing = easing
    }

    /// The draft a sheet opens on for `profile` on `todayKey` (today, outside tests).
    init(profile: WorkoutProfile, todayKey: String = FernletDate.dayKey(for: Date())) {
        let note = InjuryNoteMatcher.match(profile.injuryNotes)
        let legacy = BodyArea.legacyAreas(
            avoidedMuscles: profile.avoidedMuscles, avoidedMovements: profile.avoidedMovements
        )
        var areas = profile.injuryAreas
        var easing = profile.injuryEasing
        for area in legacy.subtracting(note.areas) where areas[area] == nil && easing[area] == nil { areas[area] = .severe }
        // An area whose two weeks are over is back to normal: no severity, and no token unless the
        // note still names it.
        for (area, token) in easing where InjuryEasing.state(token: token, todayKey: todayKey) == .healed {
            areas[area] = nil
            if !note.areas.contains(area) { easing[area] = nil }
        }
        let severe = Set(areas.filter { $0.value == .severe }.keys).union(note.areas).subtracting(easing.keys)
        let covered = severe.reduce(into: Set<MuscleGroup>()) { $0.formUnion($1.muscles) }
        let rested = profile.avoidedMuscles.subtracting(covered).subtracting(note.muscles)
        self.init(areas: areas, restedMuscles: Set(Self.restableMuscles).intersection(rested), easing: easing)
    }

    /// `profile` with this draft saved (see the type's note for what is mirrored where).
    func applied(to profile: WorkoutProfile) -> WorkoutProfile {
        var updated = profile
        updated.injuryAreas = areas
        updated.setInjuryEasing(easing)
        let note = InjuryNoteMatcher.match(profile.injuryNotes)
        let severe = Set(areas.filter { $0.value == .severe }.keys).union(note.areas.subtracting(areas.keys))
            .subtracting(easing.keys)
        updated.avoidedMuscles = severe.reduce(into: restedMuscles.union(note.muscles)) { $0.formUnion($1.muscles) }
        updated.avoidedMovements = severe.reduce(into: Set<MovementPattern>()) { $0.formUnion($1.movements) }
        return updated
    }

    /// Sets an area's severity from the picker. A severity chosen by hand is the latest word on the
    /// area, so its "No longer an issue" switch goes off.
    mutating func setSeverity(_ severity: InjurySeverity?, for area: BodyArea) {
        guard areas[area] != severity else { return }
        areas[area] = severity
        easing[area] = nil
    }

    /// Whether `area` is marked "No longer an issue".
    func isNoLongerAnIssue(_ area: BodyArea) -> Bool {
        easing[area] != nil
    }

    /// Turns an area's "No longer an issue" switch on (waiting for the next workout, unless it was
    /// already on) or off (the area is what the picker and the note say again).
    mutating func setNoLongerAnIssue(_ on: Bool, for area: BodyArea) {
        guard on else {
            easing[area] = nil
            return
        }
        if easing[area] == nil { easing[area] = InjuryEasing.pendingToken }
    }

    /// Whether `area`'s row offers the switch: it has a limit to end — from the picker or from
    /// `note` — or the switch is already on.
    func offersNoLongerAnIssue(_ area: BodyArea, note: String) -> Bool {
        areas[area] != nil || easing[area] != nil || InjuryNoteMatcher.match(note).areas.contains(area)
    }

    /// The note's areas the picker leaves to it, in picker order — what the section lists as "left
    /// out because of your note". An area marked "No longer an issue" is not one of them.
    static func noteOnlyAreas(
        note: String, areas: [BodyArea: InjurySeverity], easing: [BodyArea: String] = [:]
    ) -> [BodyArea] {
        let named = InjuryNoteMatcher.match(note).areas
        return BodyArea.allCases.filter { named.contains($0) && areas[$0] == nil && easing[$0] == nil }
    }

    /// The areas the note names that are marked "No longer an issue", in picker order — what the
    /// line under the note says it no longer applies to.
    static func noteAreasNoLongerApplied(note: String, easing: [BodyArea: String]) -> [BodyArea] {
        let named = InjuryNoteMatcher.match(note).areas
        return BodyArea.allCases.filter { named.contains($0) && easing[$0] != nil }
    }
}

/// The "Areas to work around" section of the workout setup sheet: a severity picker per body area,
/// the rested-muscle chips, the free-text note, and a line naming what the note itself leaves out.
///
/// Each area row is a menu picker (None · Mild · Severe) whose accessibility label is the area's
/// name, so VoiceOver reads "Knee, Mild, pop-up button" and Voice Control answers to "Tap Knee". At
/// accessibility text sizes a row stacks its name above the picker instead of truncating either.
/// A row with a limit to end — from the picker or from the note — carries the "No longer an issue"
/// switch under it, named for its area ("Knee: no longer an issue") so each one is its own spoken
/// and Voice Control target.
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
                        if draft.offersNoLongerAnIssue(area, note: notes) {
                            NoLongerAnIssueRow(area: area, isOn: noLongerAnIssueBinding(for: area))
                        }
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
        let fromNote = WorkoutInjuryDraft.noteOnlyAreas(note: notes, areas: draft.areas, easing: draft.easing)
        let notApplied = WorkoutInjuryDraft.noteAreasNoLongerApplied(note: notes, easing: draft.easing)
        if !notApplied.isEmpty {
            let names = notApplied.map(\.displayName).formatted(.list(type: .and))
            Text("Your note still mentions \(names). You marked it as no longer an issue, so the note isn't applied there.",
                 comment: "Under the free-text injury note: body areas the note names that the person has marked 'No longer an issue', so the planner ignores the note for them; the argument is a list of areas")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("workout.setup.injury.noteNotApplied")
        }
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
        Binding(get: { draft.areas[area] }, set: { draft.setSeverity($0, for: area) })
    }

    private func noLongerAnIssueBinding(for area: BodyArea) -> Binding<Bool> {
        Binding(get: { draft.isNoLongerAnIssue(area) }, set: { draft.setNoLongerAnIssue($0, for: area) })
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

/// The "No longer an issue" switch under an injured area's row (the owner's fix s5): on, the area gets
/// the Mild treatment for two weeks from the next workout and then returns to normal by itself.
///
/// The drawn label is the same on every row, so the switch's accessibility label carries the area:
/// VoiceOver reads "Knee: no longer an issue, switch, off" and Voice Control answers to that name. The
/// line under a switch that is on says what happens next; it wraps at every text size.
private struct NoLongerAnIssueRow: View {
    let area: BodyArea
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text("No longer an issue", comment: "Switch under an injured body area in Workout setup: the injury has cleared")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
            .toggleStyle(FernletFramedToggleStyle())
            .accessibilityLabel(Text("\(area.displayName): no longer an issue",
                                     comment: "Spoken and Voice Control name of the 'No longer an issue' switch for one body area; the argument is the area, e.g. Knee"))
            // Voice Control: the drawn words first, then the name with its area, which tells two
            // switches on screen apart ("Knee: no longer an issue").
            .accessibilityInputLabels([
                Text("No longer an issue", comment: "Switch under an injured body area in Workout setup: the injury has cleared"),
                Text("\(area.displayName): no longer an issue",
                     comment: "Spoken and Voice Control name of the 'No longer an issue' switch for one body area; the argument is the area, e.g. Knee")
            ])
            .accessibilityIdentifier("workout.setup.injury.\(area.rawValue).noLongerAnIssue")
            if isOn {
                Text("Fernlet goes easy on it for 2 weeks from your next workout: lighter, supported moves and no strength checks. Then it's back to normal.",
                     comment: "Under a 'No longer an issue' switch that is on: what the planner does for the body area for the next two weeks")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.bottom, 6)
    }
}

extension FernletStore {
    /// Starts the two weeks of every area marked "No longer an issue" that was still waiting for a
    /// workout (the owner's fix s5: "for 2 weeks from the next workout"). Called for every workout
    /// logged, with the day it was logged on; a workout back-dated to before today starts the clock
    /// today, since the switch cannot have been on any earlier than now. Saves only when an area
    /// was waiting.
    func startInjuryEasingForLoggedWorkout(on date: String) {
        var profile = settings.workoutProfile
        guard profile.startInjuryEasing(onDayKey: max(date, todayKey)) else { return }
        setWorkoutProfile(profile)
    }
}
