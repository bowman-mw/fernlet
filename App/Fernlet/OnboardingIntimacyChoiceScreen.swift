import SwiftUI
import FernletUI

/// The one follow-up the onboarding age check can raise: for a user the 16+ intimacy gate admits, a
/// neutral choice to keep intimacy tracking — the default — or turn it off.
///
/// The second page of the personal-details step, shown only when
/// ``OnboardingCoordinatorModel/ageCheckFinished()`` finds the gate open. It is not a ninth step: it
/// carries the step's own "N of 8" caption, so the count never depends on an age answer, and a user
/// who is under 16 or undetermined never meets a page that isn't there for them. It swaps in inside
/// the flow's own view tree rather than being presented as a sheet, because it appears the moment
/// the SYSTEM age-range sheet returns — see the model's note on why a presentation there can fail.
///
/// Neutral on purpose. The two cards carry equal weight, the copy states what each one does without
/// recommending either, and "keep" is pre-selected only because it is what the setting already says
/// (`intimacyTrackingVisible` defaults on for users the gate admits).
///
/// Draft semantics, like the rest of onboarding: the selection is local `@State` until Continue
/// hands it to ``OnboardingCoordinatorModel/confirmIntimacyTrackingChoice(keep:)``. Back returns to
/// the personal-details form with nothing recorded. The answer lands in the same setting the
/// Settings toggle drives, and turning it off HIDES the feature — it never deletes anything; the
/// copy says both.
struct OnboardingIntimacyChoiceScreen: View {
    var stepText: String
    /// Back to the personal-details form (``OnboardingCoordinatorModel/leaveIntimacyChoice()``).
    var backAction: () -> Void
    /// Receives the selection on Continue: `true` keeps intimacy tracking.
    var continueAction: (Bool) -> Void

    /// The card currently selected — seeded from the model, so a user who comes back to this page
    /// sees the answer they gave last time.
    @State private var keepsIntimacyTracking: Bool

    /// - Parameter keepsIntimacyTracking: The selection to open on — the model's draft once answered,
    ///   else the setting as it stands.
    init(
        stepText: String,
        keepsIntimacyTracking: Bool,
        backAction: @escaping () -> Void,
        continueAction: @escaping (Bool) -> Void
    ) {
        self.stepText = stepText
        self.backAction = backAction
        self.continueAction = continueAction
        _keepsIntimacyTracking = State(initialValue: keepsIntimacyTracking)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Intimacy tracking",
                subtitle: "Keep it, or turn it off. Either way, you can change it later.",
                backAction: backAction
            ) {
                choiceContent
            }
            SheetSaveBar(label: "Continue") { continueAction(keepsIntimacyTracking) }
        }
        .accessibilityIdentifier("onboarding.intimacy")
    }

    /// The explainer, the two choices, and where the setting lives afterwards.
    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fernlet includes a private log for intimate activity. Any notes you add are sealed on this device. It starts turned on.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            VStack(spacing: 10) {
                choiceCard(
                    keep: true,
                    title: "Keep intimacy tracking",
                    detail: "It stays on your Private tab.",
                    identifier: "onboarding.intimacy.keep"
                )
                choiceCard(
                    keep: false,
                    title: "Turn it off",
                    detail: "Fernlet hides the feature and stops reading it. Nothing is deleted — turn it back on any time.",
                    identifier: "onboarding.intimacy.turnOff"
                )
            }
            Text("It's in Settings → Period & sensitive content whenever you want to change it.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("onboarding.intimacy.settingsNote")
        }
    }

    /// One selectable card, in the onboarding card style (moss tint and stroke when chosen).
    ///
    /// The Button's own label is what VoiceOver reads — title, then detail. Deliberately not a hint:
    /// hints can be switched off, and "Nothing is deleted" is the fact that makes turning it off
    /// safe. Display text arrives as `LocalizedStringKey`, never `String`, so both lines reach the
    /// catalog; the identifier is a test token and stays a `String`.
    private func choiceCard(
        keep: Bool,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        identifier: String
    ) -> some View {
        let isSelected = keepsIntimacyTracking == keep
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { keepsIntimacyTracking = keep } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.moss : Color.slate.opacity(0.45))
                    .frame(width: 28, height: 28)
                    // The selected trait below says the same thing, in words.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Text(detail)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
            }
            .padding(16)
            .background(isSelected ? Color.moss.opacity(0.07) : Color.cream, in: shape)
            .overlay(shape.stroke(isSelected ? Color.moss.opacity(0.42) : Color.bark.opacity(0.08), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // A hand-rolled selection card: without this the glyph swap and the tint are the only signal.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
