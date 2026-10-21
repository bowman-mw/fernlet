import SwiftUI
import FernletDomainModel
import FernletUI

// The two places food reaches the workout (G12, G13, 2026-10-20): Workout setup's "Use food logs in
// workout notes" switch, and the runner's one optional question before a long, high-volume session.
// Food never cuts a weight or speeds progress: the switch only lets the notes mention logged protein
// and body weight once the logs are good enough to read, and a "no" to the question only stops a
// shortfall in the later sets from counting as a miss.

extension FernletStore {
    /// Saves Workout setup's food-logs switch (`FernletSettings.workoutFoodAware`, G13). Writes only
    /// on a change; synced like the rest of the workout settings.
    func setWorkoutFoodAware(_ choice: Bool?) {
        guard settings.workoutFoodAware != choice else { return }
        settings.workoutFoodAware = choice
    }
}

/// "Use food logs in workout notes" in Workout setup: on until switched off.
struct FoodLogsToggle: View {
    /// The draft choice: nil until the person flips the switch, which reads as on.
    @Binding var choice: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { choice ?? true }, set: { choice = $0 })) {
                Text("Use food logs in workout notes",
                     comment: "Workout setup: the switch that lets workout notes mention logged protein and body weight, and lets the runner ask about food before a long session.")
                    .foregroundStyle(Color.bark)
            }
            .accessibilityIdentifier("workout.setup.foodLogs")
            .accessibilityInputLabels([Text("Use food logs", comment: "Voice Control name for Workout setup's food-logs switch.")])
            Text("Once you've logged meals most days for two weeks, workout notes may mention protein. Before a long session, the workout may ask if you've eaten. Food never changes your weights.",
                 comment: "Workout setup: the note under 'Use food logs in workout notes'.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }
}

/// The Ready screen's optional "Eaten in the last few hours?" (G12): two chips, either one tapped
/// again to clear it. Only a "no" changes anything, and only how the later sets are read.
struct GuidedFuelQuestion: View {
    /// nil until answered; `true` for yes, `false` for no.
    @Binding var answer: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Eaten in the last few hours?",
                 comment: "Guided workout ready screen: an optional question before a long, high-volume lifting session.")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            FlowLayout(spacing: 8) {
                chip(true)
                chip(false)
            }
            Text("Optional. In a long session, later sets can come up short without food — a “no” keeps that from counting as a miss.",
                 comment: "Guided workout ready screen: the note under 'Eaten in the last few hours?'.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ value: Bool) -> some View {
        Button {
            // B6: a tap always changes the answer (a second tap clears it), so every tap ticks.
            FernletFeedback.system.select(answer == value ? nil : value, in: &answer)
        } label: {
            if value {
                Text("Yes", comment: "Guided workout ready screen: the answer that food was eaten in the last few hours.")
            } else {
                Text("No", comment: "Guided workout ready screen: the answer that nothing was eaten in the last few hours.")
            }
        }
        .buttonStyle(ChipButtonStyle(selected: answer == value))
        .accessibilityLabel(value
            ? Text("Yes, I've eaten", comment: "VoiceOver label for the ready screen's 'Yes' to 'Eaten in the last few hours?'.")
            : Text("No, I haven't eaten", comment: "VoiceOver label for the ready screen's 'No' to 'Eaten in the last few hours?'."))
        .accessibilityInputLabels(value
            ? [Text("Yes", comment: "Guided workout ready screen: the answer that food was eaten in the last few hours.")]
            : [Text("No", comment: "Guided workout ready screen: the answer that nothing was eaten in the last few hours.")])
        .accessibilityIdentifier(value ? "workout.guided.fuel.yes" : "workout.guided.fuel.no")
    }
}
