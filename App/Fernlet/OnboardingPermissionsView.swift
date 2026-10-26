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
                    permissionRow(WorldSprites.heartSm, title: "Health", body: "Asked the first time you log a workout or open a health feature.")
                    permissionRow(WorldSprites.shoe, verbatimTitle: HealthCapability.workoutLogging.title,
                                  verbatimBody: HealthCapability.workoutLogging.summary)
                    permissionRow(WorldSprites.photo, title: "Camera", body: "Asked when you first scan a nutrition label.")
                    notificationsRow
                    // Today's location card, kept as it is: the map's own location ask is step 5c.
                    permissionRow(WorldSprites.pin, title: "Coarse location", body: "Asked only if you turn on weather-aware recovery prompts.")
                }
            }
            SheetSaveBar(label: "Start Fernlet") { finishAction() }
        }
        .accessibilityIdentifier("onboarding.permissions")
        .task { await refreshNotificationStatus() }
    }

    /// The one permission with no natural in-app trigger, so it is offered here explicitly.
    private var notificationsRow: some View {
        OnboardingCard(sprite: OnboardingArt.bell, title: Text("Notifications"),
                       detail: Text("A gentle daily check-in reminder, only if you want one."),
                       accessory: AnyView(notificationsControl))
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
                .foregroundStyle(WorldPalette.dim)
        case .undecided:
            Button { requestNotifications() } label: {
                Text(requestingNotifications ? "…" : "Turn on")
            }
            .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
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

    /// One permission card named by authored copy. `LocalizedStringKey`, not `String`: the `String`
    /// this took sent every literal row through `Text`'s verbatim overload, so none localized.
    private func permissionRow(_ sprite: WorldSprite, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        permissionCard(sprite, title: Text(title), body: Text(body))
    }

    private func permissionRow(_ sprite: WorldSprite, verbatimTitle: String, verbatimBody: String) -> some View {
        permissionCard(sprite, title: Text(verbatim: verbatimTitle), body: Text(verbatim: verbatimBody))
    }

    /// One card (design `b2-onb-8`): a framed pixel tile, the permission and when it is asked.
    private func permissionCard(_ sprite: WorldSprite, title: Text, body: Text) -> some View {
        OnboardingCard(sprite: sprite, title: title, detail: body)
            .accessibilityElement(children: .combine)
    }
}
