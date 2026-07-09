import SwiftUI
import FernletDomainModel

struct OnboardingWelcomeView: View {
    var stepText: String
    var continueAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Welcome to Fernlet",
                subtitle: "A small daily care companion built around privacy, local control, and enoughness."
            ) {
                VStack(spacing: 18) {
                    CompanionView(state: .thriving, size: 132)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)

                    VStack(spacing: 10) {
                        privacyRow("lock.shield.fill", title: "Private by default", body: "Your personal logs stay in your own storage unless you choose iCloud sync.")
                        privacyRow("heart.text.square.fill", title: "No shame loops", body: "Fernlet avoids streaks, ranking, and body-goal pressure.")
                        privacyRow("person.crop.circle.badge.checkmark", title: "You choose what to share", body: "Friends and helpers only see data you explicitly share.")
                    }
                }
            }
            SheetSaveBar(label: "Continue") { continueAction() }
        }
        .accessibilityIdentifier("onboarding.welcome")
    }

    private func privacyRow(_ systemImage: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text(body)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }
}
