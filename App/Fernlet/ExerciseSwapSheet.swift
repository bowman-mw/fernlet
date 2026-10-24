import SwiftUI
import FernletDomainModel
import FernletUI

/// "Swap" for one exercise in the plan editor (``GuidedWorkoutEditorSheet``): up to four exercises
/// that do the same work, then a search over the whole catalog.
///
/// The options come from ``FernletStore/exerciseSwapOptions(for:excluding:alsoHidden:)`` — what the
/// planner itself may suggest at this location with these injury limits, minus anything hidden and
/// anything already in the session — ranked by muscle fit (``WorkoutExerciseSwapOptions``). The
/// search is the log sheet's own picker, so any exercise, custom ones included, can be chosen.
/// Picking one hands it back and closes the sheet; the editor then offers "Always use this
/// instead". Reading order is layout order: the options under their caption, then the search. Each
/// option is the shared result row, named for Voice Control by the exercise.
struct ExerciseSwapSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The frozen name of the exercise being swapped out, drawn in the header.
    let originalName: String
    let options: [ExerciseTarget]
    let onPick: (ExerciseTarget) -> Void

    @State private var searchSelection: ExerciseTarget?
    @State private var searchResetToken = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: Text("Swap \(originalName)"),
                onCancel: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    optionsSection
                    ExerciseSearchPicker(
                        selectedExercise: $searchSelection,
                        resetToken: $searchResetToken,
                        title: "Or search",
                        placeholder: "Search exercise or muscle"
                    )
                }
                .padding(20)
            }
        }
        // World build (`b3-exercise-swap`): the sheet's paper; the options share one framed card.
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
        .onChange(of: searchSelection) { _, picked in
            guard let picked else { return }
            pick(picked)
        }
    }

    @Environment(\.fernletFramedLook) private var look

    @ViewBuilder private var optionsSection: some View {
        if options.isEmpty {
            Text("Nothing else here works the same muscles the same way. Search for any exercise below.",
                 comment: "Swap sheet: no ready alternatives for this exercise at this location")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        } else if look != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Works the same muscles").padding(.horizontal, 4)
                FernletCard {
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            if option.id != options.first?.id { FernletDottedRule() }
                            ExerciseSearchResultRow(exercise: option, isSelected: false, inCard: true) { pick(option) }
                                .accessibilityIdentifier("workout.swap.option")
                        }
                    }
                }
            }
        } else {
            SheetField("Works the same muscles") {
                VStack(spacing: 6) {
                    ForEach(options) { option in
                        ExerciseSearchResultRow(exercise: option, isSelected: false) { pick(option) }
                            .accessibilityIdentifier("workout.swap.option")
                    }
                }
            }
        }
    }

    private func pick(_ target: ExerciseTarget) {
        onPick(target)
        dismiss()
    }
}
