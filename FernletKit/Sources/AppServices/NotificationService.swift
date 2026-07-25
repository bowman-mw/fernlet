import Foundation
import UserNotifications
import FernletDomainModel

/// Thin wrapper around `UNUserNotificationCenter` for the optional gentle daily check-in reminder.
/// Local notifications only — no remote push — and entirely opt-in.
public enum NotificationService {
    /// Public so the app's notification delegate can recognize a tapped daily check-in and
    /// deep-link it (via the pending-open flag consumed by `ContentView`).
    public static let dailyCheckInID = "fernlet.dailyCheckIn"

    /// Requests local-notification authorization. Returns whether it was granted.
    @discardableResult
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Whether notifications are currently authorized (authorized / provisional / ephemeral).
    public static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Schedules a single repeating, gentle daily check-in at the given local time.
    public static func scheduleDailyCheckIn(hour: Int = 19, minute: Int = 0) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyCheckInID])

        let content = UNMutableNotificationContent()
        content.title = "A gentle check-in"
        content.body = "However today went, a small note of care still counts."
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: dailyCheckInID, content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// Cancels the daily check-in reminder. Public so the Settings toggle can turn it off
    /// (previously internal with zero callers — onboarding could only ever turn it on).
    public static func cancelDailyCheckIn() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailyCheckInID])
    }

    /// Identifier for the best-effort "new session message" local notification (TF b19 item 6).
    /// A single fixed id so successive messages COALESCE into one pending notification rather than
    /// stacking — the badge/haptic is the reliable in-app signal; this only fires the rare times a
    /// message lands while the app is backgrounded mid-session (MultipeerConnectivity usually
    /// suspends in the background, so this is genuinely best-effort).
    public static let sessionMessageID = "fernlet.sessionMessage"

    /// Best-effort local notification that a session message arrived while the app was NOT active
    /// (TF b19 item 6). No-op unless notifications are already authorized (never prompts here — the
    /// permission flow lives in onboarding/Settings). The `senderName` is defensively re-sanitized
    /// (control/zero-width/bidi scalars out, length-capped) before it enters notification content,
    /// even though the caller already hands over a sanitized transcript name.
    public static func postSessionMessage(from senderName: String) async {
        guard await isAuthorized() else { return }
        var name = ItemNameModeration.sanitizedName(senderName)
        if name.isEmpty { name = "a friend" }
        let content = UNMutableNotificationContent()
        content.title = "New message from \(name)"
        content.body = "Open Fernlet to reply — session messages disappear when the session ends."
        content.sound = .default
        // nil trigger → deliver as soon as possible; the fixed id coalesces rapid arrivals.
        let request = UNNotificationRequest(identifier: sessionMessageID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The currently scheduled daily check-in time, or `nil` when none is pending. The pending
    /// notification request IS the persistence for this preference (it survives relaunches), so
    /// Settings reads the truth from here instead of keeping a shadow flag that could drift —
    /// this also stays consistent with the check-in that onboarding may have scheduled.
    public static func scheduledDailyCheckIn() async -> (hour: Int, minute: Int)? {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard let request = requests.first(where: { $0.identifier == dailyCheckInID }),
              let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
        return (trigger.dateComponents.hour ?? 19, trigger.dateComponents.minute ?? 0)
    }
}
