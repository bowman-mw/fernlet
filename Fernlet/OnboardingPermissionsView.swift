import SwiftUI

struct OnboardingPermissionsView: View {
    var stepText: String
    var finishAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Permissions when needed",
                subtitle: "Fernlet asks at first use where practical, so you can start without granting everything now."
            ) {
                VStack(spacing: 10) {
                    permissionRow("heart.text.square.fill", title: "Health", body: "Used for workouts, sleep, steps, and optional cycle context.")
                    permissionRow("figure.run", title: HealthCapability.workoutLogging.title, body: HealthCapability.workoutLogging.summary)
                    permissionRow("camera.fill", title: "Camera", body: "Used when scanning nutrition labels.")
                    permissionRow("bell.badge.fill", title: "Notifications", body: "Used for gentle reminders you choose.")
                    permissionRow("location.fill", title: "Coarse location", body: "Used only for weather-aware recovery prompts.")
                }
            }
            SheetSaveBar(label: "Start Fernlet") { finishAction() }
        }
        .accessibilityIdentifier("onboarding.permissions")
    }

    private func permissionRow(_ systemImage: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                Text(body)
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }
}
