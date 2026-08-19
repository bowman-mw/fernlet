import SwiftUI
import FernletDomainModel
import FernletUI
import FernletLock
import FernletLockUI

/// Onboarding step for lock setup: set a passcode now, or move on and set one when a lockable
/// feature asks.
///
/// "Set a passcode" presents `FernletLockSetupView` (from `FernletLockUI`) as a sheet and reports
/// completion via `setPasscodeAction` on dismiss; the other choices call straight through, and the
/// coordinator model records the deferral in `UserDefaults` (``OnboardingDefaults``) and advances.
///
/// Note on the middle card: it is a DEFERRAL, not a lock. Fernlet's rule is passcode-before-
/// biometrics (`FernletLockService.setBiometricEnabled` requires the passcode), so there is no
/// biometrics-only lock to configure — the card used to promise "device biometrics as your
/// preferred lock path" and silently set nothing, leaving the Private tab on its "Set up app lock"
/// gate. Its copy now says what actually happens. It keeps the `onboarding.lock.biometrics`
/// identifier and its advance-without-a-lock behavior because the onboarding UI tests tap it to
/// walk the flow; collapsing the two deferral cards into one is a follow-up that has to land with
/// that test change.
struct OnboardingLockSetupView: View {
    var stepText: String
    var backAction: (() -> Void)?
    var setPasscodeAction: () -> Void
    /// "Face ID later" — a deferral, identical in effect to `skipAction`.
    var laterAction: () -> Void
    var skipAction: () -> Void

    /// Read on the setup sheet's dismissal so a CANCELLED sheet records a deferral rather than a
    /// choice. Injected on `OnboardingCoordinator` by `FernletApp`.
    @Environment(FernletLockService.self) private var lockService

    @State private var isShowingPasscodeSetup = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Protect private spaces",
                subtitle: "The lock guards period, intimacy, and other sensitive areas before they open.",
                backAction: backAction
            ) {
                VStack(spacing: 10) {
                    lockChoice(
                        title: "Set a passcode",
                        subtitle: "Create a PIN or password for lockable features — you can turn on Face ID with it here too.",
                        systemImage: "key.fill"
                    ) {
                        isShowingPasscodeSetup = true
                    }
                    .accessibilityIdentifier("onboarding.lock.passcode")

                    lockChoice(
                        title: "Set up Face ID later",
                        subtitle: "Face ID needs a Fernlet passcode first. Nothing is locked until you set one.",
                        systemImage: "faceid"
                    ) {
                        laterAction()
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
        .sheet(isPresented: $isShowingPasscodeSetup, onDismiss: recordPasscodeSetupOutcome) {
            // No locked surface is on screen during onboarding; grant the Private Hub, which is what
            // the user just agreed to protect and the first place they'll go looking for it.
            FernletLockSetupView(grantingScope: .privateHub)
        }
    }

    /// Checks what the setup sheet actually did before reporting it. Dismissal alone is not a
    /// result: a user who opened the sheet and backed out configured nothing, so recording
    /// "chosen" there would clear the deferral and stop lockable features ever offering setup.
    private func recordPasscodeSetupOutcome() {
        guard lockService.state != .notConfigured else {
            skipAction()
            return
        }
        setPasscodeAction()
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
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(subtitle)
                        .font(.fernlet(.bodySmall))
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
