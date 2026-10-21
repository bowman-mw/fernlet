import SwiftUI
import FernletDomainModel
import FernletUI

/// Workout setup's session fields: how long a session may run, how much of the warm-up stretch flow
/// it walks, and whether it ends with the cool-down (``WorkoutSessionOptions``).
///
/// The length and the warm-up are chip rows like Experience: each chip is a button named by its
/// visible text ("30 min", "Short") and carries the selected trait, so VoiceOver reads "30 min,
/// selected, button" after the caption and Voice Control answers to "Tap 30 min". The cool-down is a
/// switch. Chips wrap (`FlowLayout`) and the captions wrap at every text size. The plan sheet can
/// still pick another length for one day; this is the standing choice.
struct WorkoutSessionSection: View {
    @Binding var options: WorkoutSessionOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            lengthField
            warmUpField
            coolDownSwitch
        }
    }

    private var lengthField: some View {
        SheetField("Session length") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(WorkoutSessionLength.allCases) { length in
                        Button(length.displayName) { FernletFeedback.system.select(length, in: &options.length) }
                            .buttonStyle(ChipButtonStyle(selected: options.length == length))
                            .accessibilityIdentifier("workout.setup.length.\(length.rawValue)")
                    }
                }
                Text("Fernlet fits each session into this time: a shorter warm-up first, then fewer extra exercises, then fewer sets. Your main lifts always stay.",
                     comment: "Workout setup: how the session-length choice shapes each planned session")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    private var warmUpField: some View {
        SheetField("Warm-up stretches") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(WorkoutWarmUpMode.allCases) { mode in
                        Button(mode.displayName) { FernletFeedback.system.select(mode, in: &options.warmUp) }
                            .buttonStyle(ChipButtonStyle(selected: options.warmUp == mode))
                            .accessibilityIdentifier("workout.setup.warmUp.\(mode.rawValue)")
                    }
                }
                Text("Short is about four minutes of the stretch flow, picked for the muscles you're training. Off skips it.",
                     comment: "Workout setup: what the Short and Off warm-up choices do")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// On keeps the cool-down (a time limit can still trim it to two stretches); off leaves it out.
    private var coolDownSwitch: some View {
        Toggle(isOn: Binding(
            get: { options.coolDown != .off },
            set: { options.coolDown = $0 ? .full : .off }
        )) {
            Text("Cool-down stretches", comment: "Workout setup: switch for the stretches that end a lifting session")
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
        .accessibilityIdentifier("workout.setup.coolDown")
    }
}
