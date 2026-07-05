//
//  FernletNotificationDelegate.swift
//  Fernlet
//
//  Minimal UNUserNotificationCenterDelegate: lets Fernlet's gentle local notifications
//  present while the app is foregrounded (previously they were silently swallowed), and
//  routes a tap on the daily check-in to the journal sheet via a pending-open flag that
//  ContentView consumes — the same "set a flag, present from ContentView" shape as the
//  FERNLET_UI_TEST_OPEN_SHEET launch hook.
//
//  Installed once in FernletApp.init (the delegate must be set before launch finishes so
//  a cold-launch tap is delivered). `shared` also keeps the strong reference the weak
//  UNUserNotificationCenter.delegate needs.
//

import Foundation
import UserNotifications
import AppServices

final class FernletNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FernletNotificationDelegate()

    /// Posted after a tap stores `pendingSheetID`, so a live ContentView reacts immediately;
    /// cold launches consume the flag from ContentView's startup task instead.
    nonisolated static let pendingSheetRequestNotification = Notification.Name("fernlet.notification.pendingSheetRequest")

    /// The `FernletSheet` id a notification tap asked to open. Consumed (and cleared) by
    /// `ContentView.consumePendingNotificationSheet()`.
    var pendingSheetID: String?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present gently even in the foreground — a check-in that never appears is confusing.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if identifier == NotificationService.dailyCheckInID {
                // The check-in invites a small note of care → deep-link to the journal sheet.
                FernletNotificationDelegate.shared.pendingSheetID = "journal"
                NotificationCenter.default.post(name: Self.pendingSheetRequestNotification, object: nil)
            }
            completionHandler()
        }
    }
}
