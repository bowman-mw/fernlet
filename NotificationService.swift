import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for the optional gentle daily check-in reminder.
/// Local notifications only — no remote push — and entirely opt-in.
enum NotificationService {
    private static let dailyCheckInID = "fernlet.dailyCheckIn"

    /// Requests local-notification authorization. Returns whether it was granted.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Whether notifications are currently authorized (authorized / provisional / ephemeral).
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Schedules a single repeating, gentle daily check-in at the given local time.
    static func scheduleDailyCheckIn(hour: Int = 19, minute: Int = 0) async {
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

    /// Cancels the daily check-in reminder.
    static func cancelDailyCheckIn() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailyCheckInID])
    }
}
