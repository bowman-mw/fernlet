import Foundation
import os
import UserNotifications
import FernletDomainModel

/// Thin wrapper around `UNUserNotificationCenter` for the optional gentle daily check-in reminder.
/// Local notifications only — no remote push — and entirely opt-in.
///
/// A stateless, caseless namespace of async statics covering the app's entire notification surface:
/// authorization (`requestAuthorization()` / `isAuthorized()`), the repeating daily check-in
/// (`scheduleDailyCheckIn(hour:minute:)` / `cancelDailyCheckIn()` / `scheduledDailyCheckIn()`), and
/// the best-effort mesh session-message ping (`postSessionMessage(from:)`). Callers are the app's
/// onboarding permissions screen, `SettingsSheet`, `FernletNotificationDelegate` (which matches
/// ``dailyCheckInID`` to deep-link a tapped check-in), and the mesh chat surface in
/// `DisposableCameraView`.
///
/// Key invariant: the pending `UNNotificationRequest` under ``dailyCheckInID`` IS the persisted
/// check-in preference — there is deliberately no shadow flag anywhere else, so Settings always
/// reads the schedule back from the notification center. `postSessionMessage(from:)` never prompts
/// for permission and re-sanitizes the sender name defensively before it enters notification
/// content. Everything is fire-and-forget from the caller's point of view, but no failure is
/// silent: every scheduling/authorization error is named in the unified log (subsystem
/// `com.fernlet`, category `notifications`) with the reason it is survivable.
public enum NotificationService {
    /// Public so the app's notification delegate can recognize a tapped daily check-in and
    /// deep-link it (via the pending-open flag consumed by `ContentView`).
    public static let dailyCheckInID = "fernlet.dailyCheckIn"

    /// This module's unified-log sink. `AppServices` deliberately declares no `FernletFoundation`
    /// edge (see `Package.swift`), so `os.Logger` — not `FernletAuditLog` — is the audit surface here.
    private static let logger = Logger(subsystem: "com.fernlet", category: "notifications")

    /// Requests local-notification authorization. Returns whether it was granted.
    ///
    /// R7: not `@discardableResult` — the `Bool` IS the grant/deny signal, and every caller
    /// (onboarding, Settings) already branches on it.
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Recovery: report "not granted". The user can still enable notifications in Settings,
            // and every caller treats false as "leave the feature off".
            logger.error("notifications.requestAuthorization.failed: \(error.localizedDescription, privacy: .public)")
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
    ///
    /// R5: `hour`/`minute` are validated at entry — out-of-range components build a trigger that
    /// never fires while the pending request (which IS the persisted preference) still reads as
    /// scheduled. An invalid time leaves any existing schedule untouched.
    /// R7: the `add` error is caught and named; callers re-read ``scheduledDailyCheckIn()`` to show
    /// the truth rather than assuming the write landed.
    public static func scheduleDailyCheckIn(hour: Int = 19, minute: Int = 0) async {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else {
            logger.error("notifications.dailyCheckIn.invalidTime: hour=\(hour, privacy: .public) minute=\(minute, privacy: .public)")
            return
        }
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
        do {
            try await center.add(request)
        } catch {
            // Recovery: nothing is pending, so `scheduledDailyCheckIn()` reports nil and the
            // Settings toggle reads back off — the failure is visible to the user AND in the log.
            logger.error("notifications.dailyCheckIn.scheduleFailed: \(error.localizedDescription, privacy: .public)")
        }
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
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Recovery: none needed — the in-app badge/haptic is the reliable signal for a session
            // message; this ping only covers the rare backgrounded arrival. Logged so a SYSTEMATIC
            // failure (a malformed request) is still visible.
            logger.notice("notifications.sessionMessage.postFailed (best-effort; in-app badge is the reliable signal): \(error.localizedDescription, privacy: .public)")
        }
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
