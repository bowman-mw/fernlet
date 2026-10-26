import SwiftUI
import FernletDomainModel
import FernletUI

/// The first onboarding screen: the companion at its happiest plus Fernlet's three privacy pillars
/// (private by default, no shame loops, share only what you choose).
///
/// Purely informational — the only interaction is Continue, which advances the
/// ``OnboardingCoordinatorModel``. Sets the tone before any question is asked.
struct OnboardingWelcomeView: View {
    var stepText: String
    var continueAction: () -> Void
    /// The term of address onboarding derives from the profile it is editing: masculine here, on the
    /// first screen, because the Sex question has not been asked yet (an unanswered profile's own
    /// default), and it follows the answer if the person comes back.
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: Text(AddressedCopy.attributed("Welcome to Fernlet", addressing: termOfAddress)),
                subtitle: "A small daily care companion built around privacy, local control, and enoughness."
            ) {
                VStack(spacing: 18) {
                    OnboardingPixelCompanion(scale: 7)
                        .padding(.vertical, 6)

                    VStack(spacing: 10) {
                        privacyRow(WorldSprites.lock, title: "Private by default", body: "Your personal logs stay in your own storage unless you choose iCloud sync.")
                        privacyRow(WorldSprites.check, title: "No shame loops", body: "Fernlet avoids streaks, ranking, and body-goal pressure.")
                        privacyRow(WorldSprites.face, title: "You choose what to share", body: "Friends and helpers only see data you explicitly share.")
                    }
                }
            }
            SheetSaveBar(label: "Continue") { continueAction() }
        }
        .accessibilityIdentifier("onboarding.welcome")
    }

    /// One privacy pillar. `LocalizedStringKey`, not `String`: every caller passes authored literals,
    /// and the `String` this took sent all six through `Text`'s verbatim overload, so the first
    /// screen of the app was English in every language.
    private func privacyRow(_ sprite: WorldSprite, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        OnboardingCard(sprite: sprite, title: Text(title), detail: Text(body))
            .accessibilityElement(children: .combine)
    }
}
