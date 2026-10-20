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

/// The app's `UNUserNotificationCenterDelegate`: foreground presentation for the gentle local
/// notifications, plus tap-to-sheet deep-linking.
///
/// `willPresent` opts the daily check-in into a banner WITHOUT sound while the app is foregrounded
/// (otherwise the system swallows it; owner's decision 6, 2026-10-20: the check-in never rings),
/// keeps a guided workout's cue notification quiet there, since the open runner has already cued
/// that moment itself, and presents anything else (the best-effort session-message ping) as banner
/// and sound; `didReceive` maps a tap on the check-in to the journal
/// sheet by storing `pendingSheetID` and posting `pendingSheetRequestNotification`, which
/// `ContentView.consumePendingNotificationSheet()` consumes (cold launches read the flag from the
/// startup task instead). Installed in `FernletApp.init` before launch finishes — the delegate
/// must exist for a cold-launch tap to be delivered — and `shared` holds the strong reference the
/// center's weak delegate slot needs. Delegate callbacks are `nonisolated`; the state write hops
/// to the main actor.
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
        completionHandler(Self.foregroundPresentation(for: notification.request.identifier))
    }

    /// How a notification shows while Fernlet is open, by its identifier.
    ///
    /// The daily check-in shows as a quiet banner (decision 6: delivered without sound, and never with
    /// sound in the foreground either — even a request an older build filed with the default sound).
    /// A workout cue never shows here. Anything else presents gently, banner and
    /// sound — a notification that never appears is confusing.
    nonisolated static func foregroundPresentation(for identifier: String) -> UNNotificationPresentationOptions {
        // A guided workout's rest-end or hold-end cue is for a phone in the background. With Fernlet
        // open, the runner has already played its own haptic or sound (GuidedRunCueDirector), and a
        // banner on top would cue the same moment twice — and, under VoiceOver, speak it twice.
        if NotificationService.isWorkoutCue(identifier) { return [] }
        if identifier == NotificationService.dailyCheckInID { return [.banner, .list] }
        return [.banner, .sound]
    }

    /// Re-files a daily check-in an older build scheduled with the default sound, at the same time, so
    /// it stops ringing (decision 6). Fire-and-forget at launch: nothing waits on it, and it changes
    /// nothing when the check-in is already quiet or off.
    static func silenceLegacyCheckIn() {
        Task { await NotificationService.silenceDailyCheckInIfNeeded() }
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
