import SwiftUI
import FernletDomainModel
import FernletUI

// A lighter week under any goal (G2, 2026-11-13, a #143 leftover): a marked deload week used to be read
// only while Bodybuilding was the goal, the only time its calendar, and so the way to mark a week, was on
// screen. Workout setup's switch marks this week the same way, so every goal's plan lightens in it and
// the mark can always be seen and cleared.

/// "Lighter week" in Workout setup: marks or clears this week as a deload week. Same weights, about half
/// the sets, and nothing steps up (``WorkoutLoadEngine``'s w5 rule); a draft, saved with the sheet.
struct DeloadWeekToggle: View {
    /// The draft: whether this week is marked.
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Text("Lighter week",
                     comment: "Workout setup: the switch that marks this week as a deload week (a planned lighter week)")
                    .foregroundStyle(Color.bark)
            }
            .accessibilityIdentifier("workout.setup.deloadWeek")
            .accessibilityInputLabels([Text("Lighter week", comment: "Voice Control name for Workout setup's lighter-week switch.")])
            Text("For this week only: the same weights as last time and about half the sets. Nothing steps up, and next week picks up from where you were.",
                 comment: "Workout setup: the note under 'Lighter week'.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }
}
