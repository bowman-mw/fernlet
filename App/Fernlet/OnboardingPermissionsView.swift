import SwiftUI
import FernletDomainModel
import HealthKitGateway
import AppServices
import FernletUI

/// The final onboarding screen: explains that permissions (Health, camera, location) are asked at
/// first use, and offers the one permission with no natural in-app trigger — notifications — inline.
///
/// The notifications row requests authorization through `NotificationService` and schedules the
/// daily check-in on grant; every other row is informational only. "Start Fernlet" runs
/// `finishAction`, which is the coordinator model's `complete()`.
struct OnboardingPermissionsView: View {
    var stepText: String
    var backAction: (() -> Void)?
    var finishAction: () -> Void

    /// Tri-state for the notifications row: `undecided` shows the "Turn on" button, `on`/`off`
    /// reflect the answer the user gave (here or previously in iOS Settings).
    ///
    /// Refreshed on appear so a permission already granted elsewhere renders as On immediately.
    private enum OptIn { case undecided, on, off }
    @State private var notifications: OptIn = .undecided
    @State private var requestingNotifications = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Permissions when needed",
                subtitle: "Fernlet asks at first use where practical, so you can start without granting everything now.",
                backAction: backAction
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
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text("A gentle daily check-in reminder, only if you want one.")
                    .font(.fernlet(.bodySmall))
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
                .font(.fernlet(.labelSmall))
                // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                .foregroundStyle(Color.mossInk)
        case .off:
            Text("Off in Settings")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        case .undecided:
            Button { requestNotifications() } label: {
                Text(requestingNotifications ? "…" : "Turn on")
                    .font(.fernlet(.label))
                    // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                    .foregroundStyle(Color.mossInk)
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
                // The control the user just activated is REPLACED by a static line — the button
                // they were focused on stops existing, and VoiceOver's cursor lands nowhere in
                // particular. The review's §4.3 answer for that is to move focus; SwiftUI's focus
                // timing across a system permission prompt is not something this repo can verify
                // twice in a row, so the outcome is SPOKEN instead. Same information, no timing
                // dependency, and the announcement is the one channel the system alert's own
                // dismissal cannot swallow.
                FernletAnnouncer.system.announce(
                    .status,
                    granted
                        ? LocalizedStringResource("Daily check-in reminders are on.")
                        : LocalizedStringResource("Reminders stay off. You can turn them on in Settings whenever you like."))
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
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                Text(body)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            // Same width claim as `privacyRow` on the welcome step. More conspicuous here: the sibling
            // `notificationsRow` in this same VStack already has its Spacer, so the Notifications card
            // rendered full-width while these four rendered narrow and centred beside it.
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func rowIcon(_ systemImage: String) -> some View {
        // T1-8: `permissionRow`'s HStack isn't `.combine`d, so this glyph would otherwise be its
        // own VoiceOver stop announcing the raw SF Symbol name ahead of the row's title/body text.
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.moss)
            .frame(width: 30, height: 30)
            .background(Color.moss.opacity(0.10), in: Circle())
            .accessibilityHidden(true)
    }
}
