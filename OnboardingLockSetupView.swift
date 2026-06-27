import SwiftUI

struct OnboardingLockSetupView: View {
    var stepText: String
    var setPasscodeAction: () -> Void
    var biometricsOnlyAction: () -> Void
    var skipAction: () -> Void

    @State private var isShowingPasscodeSetup = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Protect private spaces",
                subtitle: "The lock guards period, intimacy, and other sensitive areas before they open."
            ) {
                VStack(spacing: 10) {
                    lockChoice(
                        title: "Set a passcode",
                        subtitle: "Create a PIN or password for lockable features.",
                        systemImage: "key.fill"
                    ) {
                        isShowingPasscodeSetup = true
                    }
                    .accessibilityIdentifier("onboarding.lock.passcode")

                    lockChoice(
                        title: "Use biometrics only",
                        subtitle: "Continue with device biometrics as your preferred lock path.",
                        systemImage: "faceid"
                    ) {
                        biometricsOnlyAction()
                    }
                    .accessibilityIdentifier("onboarding.lock.biometrics")

                    lockChoice(
                        title: "Skip for now",
                        subtitle: "Lockable features will ask you to set up your lock first.",
                        systemImage: "clock.arrow.circlepath"
                    ) {
                        skipAction()
                    }
                    .accessibilityIdentifier("onboarding.lock.skip")
                }
            }
        }
        .accessibilityIdentifier("onboarding.lock")
        .sheet(isPresented: $isShowingPasscodeSetup, onDismiss: setPasscodeAction) {
            FernletLockSetupView()
        }
    }

    private func lockChoice(title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 32, height: 32)
                    .background(Color.moss.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.slate.opacity(0.6))
            }
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
