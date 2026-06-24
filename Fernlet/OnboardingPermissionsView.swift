import SwiftUI

struct OnboardingPermissionsView: View {
    var stepText: String
    var finishAction: () -> Void

    private enum OptIn { case undecided, on, off }
    @State private var notifications: OptIn = .undecided
    @State private var requestingNotifications = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Permissions when needed",
                subtitle: "Fernlet asks at first use where practical, so you can start without granting everything now."
            ) {
                VStack(spacing: 10) {
                    permissionRow("heart.text.square.fill", title: "Health", body: "Asked the first time you log a workout or open a health feature.")
                    permissionRow("figure.run", title: HealthCapability.workoutLogging.title, body: HealthCapability.workoutLogging.summary)
                    permissionRow("camera.fill", title: "Camera", body: "Asked when you first scan a nutrition label.")
                    notificationsRow
                    permissionRow("location.fill", title: "Coarse location", body: "Asked only if you turn on weather-aware recovery prompts.")
                }
            }
            SheetSaveBar(label: "Start Fernlet") { finishAction() }
        }
        .accessibilityIdentifier("onboarding.permissions")
        .task { await refreshNotificationStatus() }
    }

    /// The one permission with no natural in-app trigger, so it is offered here explicitly.
    private var notificationsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("bell.badge.fill")
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                Text("A gentle daily check-in reminder, only if you want one.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            Spacer(minLength: 8)
            notificationsControl
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var notificationsControl: some View {
        switch notifications {
        case .on:
            Label("On", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.moss)
        case .off:
            Text("Off in Settings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.slate)
        case .undecided:
            Button { requestNotifications() } label: {
                Text(requestingNotifications ? "…" : "Turn on")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.moss.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(requestingNotifications)
            .accessibilityIdentifier("onboarding.permissions.notifications")
        }
    }

    private func requestNotifications() {
        requestingNotifications = true
        Task {
            let granted = await NotificationService.requestAuthorization()
            if granted { await NotificationService.scheduleDailyCheckIn() }
            await MainActor.run {
                notifications = granted ? .on : .off
                requestingNotifications = false
            }
        }
    }

    private func refreshNotificationStatus() async {
        if await NotificationService.isAuthorized() {
            await MainActor.run { notifications = .on }
        }
    }

    private func permissionRow(_ systemImage: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImage)
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

    private func rowIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.moss)
            .frame(width: 30, height: 30)
            .background(Color.moss.opacity(0.10), in: Circle())
    }
}
