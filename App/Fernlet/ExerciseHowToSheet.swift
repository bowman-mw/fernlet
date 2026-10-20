//
//  ExerciseHowToSheet.swift
//  Fernlet
//
//  The exercise how-to sheet (comparison report idea 3): an exercise's drawn name, primary muscles
//  and equipment, three to five cues, the common mistake, an easier version and the one safety line,
//  reached from the guided runner's exercise card and the plan's exercise rows. The text is the
//  domain's bundled, localized `ExerciseHowToCatalog`; this file only lays it out. A slot at the top
//  is reserved for the demonstration media a later task adds.
//

import SwiftUI
import FernletDomainModel
import FernletUI

/// Which exercise's how-to sheet is open, by its FROZEN catalog name — the item a presenter binds.
struct ExerciseHowToRequest: Identifiable, Equatable {
    /// The frozen catalog name (`ExerciseTarget.name`), never a display name.
    let name: String
    var id: String { name }
}

extension View {
    /// Presents the how-to sheet for `request`'s exercise while it is non-nil. One presenter per
    /// screen: every info button on it sets the same binding.
    func exerciseHowToSheet(_ request: Binding<ExerciseHowToRequest?>) -> some View {
        sheet(item: request) { shown in
            ExerciseHowToSheet(exerciseName: shown.name)
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

/// How to do one catalog exercise, as a read-only sheet: Done top-right is the whole exit.
///
/// Reading order is layout order, top to bottom: the name (the sheet's heading), the media slot, the
/// main muscles and equipment, then three headed sections — the cues as numbered steps, the common
/// mistake, the easier version — and the safety line last. Each cue is one VoiceOver element with its
/// number. Everything scrolls and wraps, so the largest text sizes reflow rather than truncate.
struct ExerciseHowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The frozen catalog name of the exercise shown.
    let exerciseName: String

    private var entry: ExerciseHowTo? { ExerciseHowToCatalog.entry(for: exerciseName) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: Text(verbatim: ExerciseHowToCatalog.displayName(for: exerciseName)),
                onDone: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ExerciseDemonstrationSlot(exerciseName: exerciseName)
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
                }
                .padding(20)
            }
        }
        .background(Color.parchment)
        .uxScreenAnchor("sheet.exerciseHowTo")
    }
}

/// The reserved demonstration slot at the top of the how-to sheet.
///
/// The demonstration-media task fills it (a still or a silent loop matched to the profile, with the
/// cues as its alternative text). Until then it draws nothing and adds nothing to the accessibility
/// tree, so the sheet opens straight onto the name and the cues.
struct ExerciseDemonstrationSlot: View {
    /// The frozen catalog name the media will be looked up by.
    let exerciseName: String

    var body: some View {
        EmptyView()
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
