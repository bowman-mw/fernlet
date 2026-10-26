import SwiftUI
import FernletUI

/// When "Your spaces" asks the workout-space pin question (`b1-pin-question`, approved 2026-10-23):
/// once, the first time the person opens it, until they answer — and never in a decoy session, which
/// shows and keeps nothing real (its answer would otherwise outlive the decoy as a device setting).
enum WorkoutSpacePinQuestion {
    /// Whether to ask, given the saved answer (nil until asked) and whether a decoy session is running.
    static func asks(answer: Bool?, decoy: Bool) -> Bool {
        answer == nil && !decoy
    }
}

/// The pin question's card in "Your spaces": "Remember where your workout spaces are?", why, and
/// Remember / Not now. Remember turns on the standing setting (every space gets its pin the first time
/// a guided workout starts there); Not now can be changed later. Either answer is device-only.
struct WorkoutSpacePinQuestionCard: View {
    /// Records the answer (``WorldMapPreferences/setRememberSpaces(_:in:)``).
    let onAnswer: (Bool) -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remember where your workout spaces are?",
                 comment: "Your spaces: the one-time question before Fernlet pins a workout space on the map")
                .font(MoveFont.rowTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
                .accessibilityAddTraits(.isHeader)
            Text("Each space gets its pin the first time you work out there, so the blue button can start your plan when you arrive. Pins stay on this iPhone and never sync.",
                 comment: "Your spaces: what saying yes to remembering workout spaces does")
                .font(FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
            AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                Button { onAnswer(true) } label: { Text("Remember").frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityIdentifier("workout.location.pins.remember")
                Button { onAnswer(false) } label: { Text("Not now").frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .accessibilityIdentifier("workout.location.pins.notNow")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MoveInsetCardFrame())
        .accessibilityElement(children: .contain)
    }
}
