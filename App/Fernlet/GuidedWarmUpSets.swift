//
//  GuidedWarmUpSets.swift
//  Fernlet
//
//  Warm-up sets and the plate calculator in the guided runner (comparison report idea 12, 2026-10-20).
//
//  The planner puts two or three lighter sets in front of a heavy main lift (`WorkoutWarmUpSets` in the
//  domain); each runs as its own single-set step tagged as a ramp-up, which the run state reads as
//  `isRampSet`. This file is the app's side of that: the words the runner shows and says for a warm-up
//  set ("Warm-up set 1 of 3", "Skip warm-up sets"), the plan lists' one-row summary of a lift's warm-ups,
//  the "Warm-up sets before heavy lifts" switch in Workout setup, and the "Plates" disclosure under a
//  barbell lift's weight — which plates go on each side of a standard bar, in the lift's own unit.
//
//  Every phrase is catalog text. Plate weights are formatted here with up to two decimals, because a
//  1.25 kg plate is the one weight the runner's usual one-decimal format would round.
//

import SwiftUI
import FernletDomainModel
import FernletUI

// MARK: - Words

/// What the runner shows and says for a lift's warm-up sets.
enum GuidedWarmUpWords {

    /// The card's label on a warm-up set: "Warm-up set 1 of 3".
    static func setLabel(index: Int, count: Int) -> Text {
        Text("Warm-up set \(index) of \(count)",
             comment: "Guided workout: the label on a lighter warm-up set before a lift's working sets, e.g. 'Warm-up set 1 of 3'.")
    }

    /// The spoken line for a move onto a warm-up set: "Warm-up set 1 of 3: Back squat." — VoiceOver's
    /// own line, and what spoken cues say for the step.
    static func setLine(index: Int, count: Int, name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "Warm-up set \(index) of \(count): \(name).",
            comment: "Guided workout, VoiceOver and spoken cues: the run moved onto a lighter warm-up set, e.g. 'Warm-up set 1 of 3: Back squat.'"
        )
    }

    /// What VoiceOver hears when a move lands on or leaves a lift's warm-up sets, or nil for any other
    /// move: "Warm-up set 2 of 3: Back squat." onto a warm-up set, and "Working sets: Back squat. Set 1
    /// of 3." from the last warm-up set onto the lift itself (a calibration's test set after its ramp
    /// keeps the usual "Next exercise" line).
    static func changeLine(from before: GuidedWorkoutRunState, to after: GuidedWorkoutRunState) -> LocalizedStringResource? {
        guard let exercise = after.currentExercise else { return nil }
        if let position = after.warmUpPosition {
            return setLine(index: position.index, count: position.count, name: exercise.name)
        }
        guard let previous = before.currentExercise, previous.isRampSet, previous.name == exercise.name,
              exercise.tracking?.calibrationRaw == nil else { return nil }
        return LocalizedStringResource(
            "Working sets: \(exercise.name). Set 1 of \(after.totalSetsForCurrent).",
            comment: "Guided workout, VoiceOver: the warm-up sets are done and the lift's working sets begin, e.g. 'Working sets: Back squat. Set 1 of 3.'"
        )
    }

    /// The gentle line under the card while the lifting block runs: on a warm-up set, a reminder that
    /// it is light on purpose; otherwise the usual first-set and later-set lines.
    static func liftingEncouragement(_ run: GuidedWorkoutRunState) -> Text {
        if run.currentExercise?.isRampSet == true {
            return Text("Smooth, easy reps — save your effort for the working sets.",
                        comment: "Guided workout: the gentle line under a warm-up set's card.")
        }
        return run.currentSet == 1 ? Text("No rush getting started.") : Text("Steady — you've got this.")
    }

    /// "3 warm-up sets" — a lift's warm-ups folded into one plan row.
    static func count(_ count: Int) -> Text {
        Text("\(count) warm-up sets",
             comment: "Workout plan and the runner's Ready list: a lift's lighter warm-up sets, folded into one row, e.g. '3 warm-up sets'. Needs a plural variation per language; English also needs the one-set form.")
    }

    /// "Back squat · 3 warm-up sets" — the Ready list's one row for a lift's warm-ups.
    static func summary(name: String, count: Int) -> Text {
        Text("\(Text(verbatim: name)) · \(Self.count(count))")
    }

    /// The caption a warm-up set carries in the runner's Up next list.
    static var upNextCaption: Text {
        Text("Warm-up set", comment: "Guided workout, Up next list: the caption under a lighter warm-up set before a lift.")
    }
}

// MARK: - Plan rows

/// One row of a plan list: a step, or a lift's ramp-up sets folded into one row ("Back squat · 3
/// warm-up sets") — so a plan with warm-ups lists each lift once, as it did before.
///
/// Warm-up sets and a calibration's ramp fold alike: both are light sets of the lift that follows.
struct GuidedPlanRow: Identifiable {
    /// The first folded step's id, or the step's own.
    let id: UUID
    /// The step, or the first of the folded ramp-up sets.
    let step: PrescribedExercise
    /// How many ramp-up sets the row stands for; 0 for an ordinary step.
    let warmUpCount: Int

    /// `steps` as rows, in order: consecutive ramp-up sets of one lift become one row. Bounded by `steps`.
    static func rows(_ steps: [PrescribedExercise]) -> [GuidedPlanRow] {
        var rows: [GuidedPlanRow] = []
        for step in steps {
            guard step.guidance?.calibration == .ramp else {
                rows.append(GuidedPlanRow(id: step.id, step: step, warmUpCount: 0))
                continue
            }
            if let last = rows.last, last.warmUpCount > 0, last.step.name == step.name {
                rows[rows.count - 1] = GuidedPlanRow(id: last.id, step: last.step, warmUpCount: last.warmUpCount + 1)
            } else {
                rows.append(GuidedPlanRow(id: step.id, step: step, warmUpCount: 1))
            }
        }
        return rows
    }

    /// The movements a plan lists, a lift's warm-ups not counted — the plan card's "5 exercises".
    static func movementCount(_ steps: [PrescribedExercise]) -> Int {
        rows(steps).filter { $0.warmUpCount == 0 }.count
    }
}

/// A plan card row for a lift's warm-ups: the lift's name beside "3 warm-up sets", stacked at
/// accessibility sizes like the card's other rows.
struct GuidedWarmUpPlanRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    let count: Int

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        layout {
            Text(verbatim: name)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            GuidedWarmUpWords.count(count)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
    }
}

// MARK: - The setting

extension FernletStore {
    /// Saves "Warm-up sets before heavy lifts" (`FernletSettings.workoutWarmUpSets`): the lifter's
    /// choice, or nil to follow their level's default. Writes only on a change; synced like the rest of
    /// the workout settings.
    func setWorkoutWarmUpSets(_ choice: Bool?) {
        guard settings.workoutWarmUpSets != choice else { return }
        settings.workoutWarmUpSets = choice
    }

    /// Saves Workout setup's training focus (`FernletSettings.workoutStrengthFocus`, G6). Writes only on
    /// a change; synced like the rest of the workout settings.
    func setWorkoutStrengthFocus(_ focus: WorkoutStrengthFocus) {
        guard settings.workoutStrengthFocus != focus else { return }
        settings.workoutStrengthFocus = focus
    }
}

/// "Warm-up sets before heavy lifts" in Workout setup. Shows the saved choice, or the default for the
/// level being edited (on for intermediate and advanced, off for beginners) until the lifter picks one,
/// so changing Experience moves an untouched switch with it.
struct WarmUpSetsToggle: View {
    /// The draft choice: nil until the lifter flips the switch.
    @Binding var choice: Bool?
    let experience: ExperienceLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { WorkoutWarmUpSets.isEnabled(preference: choice, experience: experience) },
                set: { choice = $0 }
            )) {
                Text("Warm-up sets before heavy lifts",
                     comment: "Workout setup: the switch that puts lighter warm-up sets before barbell and other big lifts.")
                    .foregroundStyle(Color.bark)
            }
            .accessibilityIdentifier("workout.setup.warmUpSets")
            Text("Two or three lighter sets that build up to the working weight on barbell and other big lifts. Never on a light day, or before a lift has a weight to build up to.",
                 comment: "Workout setup: the note under 'Warm-up sets before heavy lifts'.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }
}

// MARK: - Plates

/// The plate calculator's words: which plates go on each side, the bar, and — for a weight the plates
/// can't make — the closest one. Drawn with abbreviated units ("Each side: 45, 10, and 2.5 lb") and
/// spoken in words ("Each side: 45, 10, and 2.5 pounds"); the locale's list and number formats.
/// `nonisolated`: pure functions of a loadout and a locale.
nonisolated enum GuidedPlateText {

    /// The mass unit a load unit draws in.
    static func massUnit(_ unit: LoadUnit) -> UnitMass {
        unit == .kg ? .kilograms : .pounds
    }

    /// One weight with up to two decimals, so a 1.25 kg plate reads as itself.
    static func weight(_ value: Double, unit: LoadUnit, width: Measurement<UnitMass>.FormatStyle.UnitWidth,
                       locale: Locale) -> String {
        let style = Measurement<UnitMass>.FormatStyle(width: width, locale: locale, usage: .asProvided,
                                                      numberFormatStyle: digits(locale))
        return Measurement(value: value, unit: massUnit(unit)).formatted(style)
    }

    /// A bare number with up to two decimals.
    static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(digits(locale))
    }

    static func digits(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(0...2))
    }

    /// "Each side: 45, 10, and 2.5 lb" (or "… pounds" spoken), or "Just the bar" with no plates. Every
    /// plate is listed, the unit once, after the last.
    static func sides(_ loadout: PlateLoadout, width: Measurement<UnitMass>.FormatStyle.UnitWidth,
                      locale: Locale) -> String {
        guard let last = loadout.perSide.last else {
            return String(localized: "Just the bar", locale: locale,
                          comment: "Guided workout, Plates: the weight is the empty bar, with no plates on it.")
        }
        let plates = loadout.perSide.dropLast().map { number($0, locale: locale) }
            + [weight(last, unit: loadout.unit, width: width, locale: locale)]
        let list = plates.formatted(.list(type: .and).locale(locale))
        return String(localized: "Each side: \(list)", locale: locale,
                      comment: "Guided workout, Plates: the plates on each side of the bar, heaviest first, e.g. 'Each side: 45, 10, and 2.5 lb'.")
    }

    /// "Bar: 45 lb" (or "… pounds" spoken).
    static func bar(_ loadout: PlateLoadout, width: Measurement<UnitMass>.FormatStyle.UnitWidth, locale: Locale) -> String {
        let bar = weight(loadout.bar, unit: loadout.unit, width: width, locale: locale)
        return String(localized: "Bar: \(bar)", locale: locale,
                      comment: "Guided workout, Plates: the bar the plates go on, e.g. 'Bar: 45 lb'.")
    }

    /// "Can't load 137 lb exactly." — or nil when the plates make the weight.
    static func notExact(_ loadout: PlateLoadout, width: Measurement<UnitMass>.FormatStyle.UnitWidth,
                         locale: Locale) -> String? {
        guard !loadout.isExact else { return nil }
        let asked = weight(loadout.requested, unit: loadout.unit, width: width, locale: locale)
        return String(localized: "Can't load \(asked) exactly.", locale: locale,
                      comment: "Guided workout, Plates: the chosen weight can't be made with the bar and plates, e.g. 'Can't load 137 lb exactly.' The closest weight follows.")
    }

    /// "Closest: 135 lb" — or nil when the plates make the weight.
    static func closest(_ loadout: PlateLoadout, width: Measurement<UnitMass>.FormatStyle.UnitWidth,
                        locale: Locale) -> String? {
        guard !loadout.isExact else { return nil }
        let total = weight(loadout.total, unit: loadout.unit, width: width, locale: locale)
        return String(localized: "Closest: \(total)", locale: locale,
                      comment: "Guided workout, Plates: the nearest weight the bar and plates can make, e.g. 'Closest: 135 lb'.")
    }
}

/// "Plates" under a barbell lift's weight picker: folded away until opened, then which plates go on
/// each side of a standard bar for the weight shown — in the lift's unit — or, for a weight they can't
/// make, the closest one. Each line is one VoiceOver element that says its weights in words.
struct GuidedPlatesDisclosure: View {
    /// The weight on the picker.
    let weight: Double
    let unit: LoadUnit
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            GuidedPlatesDetail(loadout: PlateCalculator.loadout(for: weight, on: .standard(unit)))
                .padding(.top, 6)
        } label: {
            Text("Plates", comment: "Guided workout: the disclosure under a barbell lift's weight that shows the plates for each side.")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
        }
        .tint(Color.bark)
        .accessibilityIdentifier("workout.guided.plates")
    }
}

/// The lines inside "Plates": the closest weight when the chosen one can't be made, each side's
/// plates, and the bar.
private struct GuidedPlatesDetail: View {
    let loadout: PlateLoadout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notExact = GuidedPlateText.notExact(loadout, width: .abbreviated, locale: .current),
               let closest = GuidedPlateText.closest(loadout, width: .abbreviated, locale: .current) {
                line(notExact, spoken: GuidedPlateText.notExact(loadout, width: .wide, locale: .current),
                     font: .fernlet(.bodySmall))
                line(closest, spoken: GuidedPlateText.closest(loadout, width: .wide, locale: .current),
                     font: .fernlet(.bodySmall))
            }
            line(GuidedPlateText.sides(loadout, width: .abbreviated, locale: .current),
                 spoken: GuidedPlateText.sides(loadout, width: .wide, locale: .current), font: .fernlet(.stat))
                .accessibilityIdentifier("workout.guided.plates.sides")
            line(GuidedPlateText.bar(loadout, width: .abbreviated, locale: .current),
                 spoken: GuidedPlateText.bar(loadout, width: .wide, locale: .current), font: .fernlet(.bodySmall))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line, drawn with abbreviated units and spoken in words.
    private func line(_ drawn: String, spoken: String?, font: Font) -> some View {
        Text(verbatim: drawn)
            .font(font)
            .foregroundStyle(Color.bark)
            .fernletWrappingText()
            .accessibilityLabel(Text(verbatim: spoken ?? drawn))
    }
}
