import Foundation
import os
import UserNotifications
import FernletDomainModel

/// Thin wrapper around `UNUserNotificationCenter` for the optional gentle daily check-in reminder.
/// Local notifications only — no remote push — and entirely opt-in.
///
/// A stateless, caseless namespace of async statics covering the app's entire notification surface:
/// authorization (`requestAuthorization()` / `isAuthorized()`), the repeating daily check-in
/// (`scheduleDailyCheckIn(hour:minute:)` / `cancelDailyCheckIn()` / `scheduledDailyCheckIn()`),
/// the best-effort mesh session-message ping (`postSessionMessage(from:)`), and the guided workout's
/// in-session rest-end and hold-end cues for a phone in the background (`replaceWorkoutCues(_:soundFileName:now:)`).
/// Callers are the app's onboarding permissions screen, `SettingsSheet`, `FernletNotificationDelegate`
/// (which matches ``dailyCheckInID`` to deep-link a tapped check-in, and ``isWorkoutCue(_:)`` to keep a
/// cue quiet while the app is open), the mesh chat surface in `DisposableCameraView`, and the guided
/// runner's `GuidedRunCueDirector`.
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
        // T2-19: the daily check-in is delivered to Announce Notifications and to a Braille
        // display as well as to the Lock Screen, and it is the one sentence of Fernlet many users
        // hear each day. `bundle: .module` because this is an SPM module — without it the lookup
        // goes to Bundle.main, misses this module's catalog, and speaks English forever.
        content.title = String(localized: "notification.dailyCheckIn.title",
                               defaultValue: "A gentle check-in", bundle: .module,
                               comment: "Title of the once-a-day reminder notification. An invitation, never a streak warning or a nag.")
        content.body = String(localized: "notification.dailyCheckIn.body",
                              defaultValue: "However today went, a small note of care still counts.",
                              bundle: .module,
                              comment: "Body of the once-a-day reminder notification. Must stay unconditional — care counts regardless of how the day went.")
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
    /// message lands while the app is backgrounded mid-session (the mesh radio usually suspends in
    /// the background — MultipeerConnectivity did, the QUIC radio does — so this is genuinely
    /// best-effort).
    public static let sessionMessageID = "fernlet.sessionMessage"

    /// Best-effort local notification that a session message arrived while the app was NOT active
    /// (TF b19 item 6). No-op unless notifications are already authorized (never prompts here — the
    /// permission flow lives in onboarding/Settings). The `senderName` is defensively re-sanitized
    /// (control/zero-width/bidi scalars out, length-capped) before it enters notification content,
    /// even though the caller already hands over a sanitized transcript name.
    public static func postSessionMessage(from senderName: String) async {
        guard await isAuthorized() else { return }
        var name = ItemNameModeration.sanitizedName(senderName)
        if name.isEmpty {
            name = String(localized: "notification.sessionMessage.unknownSender",
                          defaultValue: "a friend", bundle: .module,
                          comment: "Stands in for a session peer whose name sanitized away to nothing. Reads inside the sentence 'New message from …', so it is lower-case.")
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.sessionMessage.title",
                               defaultValue: "New message from \(name)", bundle: .module,
                               comment: "Title of the notification for a mesh session message that arrived while the app was backgrounded. The argument is the sender's sanitized display name.")
        content.body = String(localized: "notification.sessionMessage.body",
                              defaultValue: "Open Fernlet to reply — session messages disappear when the session ends.",
                              bundle: .module,
                              comment: "Body of the session-message notification. The disappearance is the important half: session chat is not stored anywhere after the session.")
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

// MARK: - Guided workout cues (in-session, background only)

extension NotificationService {
    /// What a background workout cue says has ended. The raw value is FROZEN — it is the tail of the
    /// pending request's identifier, so a renamed case would orphan a cue scheduled by the previous build.
    public enum WorkoutCueKind: String, CaseIterable, Sendable {
        /// A rest's countdown reached zero.
        case restEnded
        /// A timed hold ran out.
        case holdEnded
    }

    /// One in-session cue for a phone in the background: what ends, and when.
    ///
    /// Built by the app from the live guided run; carries no exercise name or other content, so the
    /// notification says only that a timer ran out.
    public struct WorkoutCue: Equatable, Sendable {
        /// What ends.
        public let kind: WorkoutCueKind
        /// When it ends.
        public let fireAt: Date

        /// Creates a cue.
        public init(kind: WorkoutCueKind, fireAt: Date) {
            self.kind = kind
            self.fireAt = fireAt
        }
    }

    /// The identifier prefix every workout cue request shares — the delegate's match for "keep this
    /// quiet while the app is open, the in-app cue already played".
    public static let workoutCueIDPrefix = "fernlet.workoutCue."

    /// The fixed request identifier for one kind of cue. One per kind, so a new rest's cue REPLACES the
    /// previous one rather than stacking beside it.
    public static func workoutCueID(for kind: WorkoutCueKind) -> String {
        workoutCueIDPrefix + kind.rawValue
    }

    /// Whether a notification identifier is one of the guided workout's cues.
    public static func isWorkoutCue(_ identifier: String) -> Bool {
        identifier.hasPrefix(workoutCueIDPrefix)
    }

    /// Replaces every pending AND delivered workout cue with `cues`, so the Lock Screen only ever
    /// holds the cue for the rest or hold that is running now.
    ///
    /// An in-session cue, never a nudge: it is scheduled only while a guided run is live, for the
    /// moment its current timer ends, and the app replaces it on every move of the run (an empty
    /// `cues` cancels everything when the run ends). It **never prompts** for permission — like
    /// ``postSessionMessage(from:)`` it is a no-op unless notifications are already allowed — and it
    /// stays at the default `.active` interruption level: breaking through a Focus as Time Sensitive
    /// would need the Time Sensitive Notifications entitlement, an owner decision not taken.
    ///
    /// - Parameters:
    ///   - cues: The cues to schedule; any whose time has passed is skipped.
    ///   - soundFileName: The bundled sound the cue plays (a quiet chime, or a silent file that still
    ///     lets the system's notification haptic fire), or nil for a silent banner.
    ///   - now: The clock, injectable for tests.
    public static func replaceWorkoutCues(_ cues: [WorkoutCue], soundFileName: String?, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let identifiers = WorkoutCueKind.allCases.map { workoutCueID(for: $0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        // Bounded: at most one cue per kind is ever live (a run is resting OR holding).
        let upcoming = Array(cues.filter { $0.fireAt > now }.prefix(WorkoutCueKind.allCases.count))
        guard !upcoming.isEmpty, await isAuthorized() else { return }
        for cue in upcoming {
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, cue.fireAt.timeIntervalSince(now)), repeats: false)
            let request = UNNotificationRequest(
                identifier: workoutCueID(for: cue.kind),
                content: workoutCueContent(for: cue.kind, soundFileName: soundFileName),
                trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                // Recovery: none needed — the cue is a convenience for a phone in a pocket; the Live
                // Activity's countdown still shows the time. Logged so a systematic failure is visible.
                logger.notice("notifications.workoutCue.addFailed (best-effort; the Live Activity still counts down): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The content of one workout cue: a short title and body naming the timer that ended — never an
    /// exercise, a weight or anything else from the person's log — and the bundled sound, if any.
    static func workoutCueContent(for kind: WorkoutCueKind, soundFileName: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch kind {
        case .restEnded:
            content.title = String(localized: "notification.workoutCue.restEnded.title",
                                   defaultValue: "Rest's over", bundle: .module,
                                   comment: "Title of the in-session cue delivered when a guided workout's rest timer reaches zero while Fernlet is in the background. Gentle: the rest waits for the person; this only says the timer ran out.")
            content.body = String(localized: "notification.workoutCue.restEnded.body",
                                  defaultValue: "Start your next set when you're ready.", bundle: .module,
                                  comment: "Body of the rest-ended workout cue. An invitation, never a command or a hurry.")
        case .holdEnded:
            content.title = String(localized: "notification.workoutCue.holdEnded.title",
                                   defaultValue: "Hold's done", bundle: .module,
                                   comment: "Title of the in-session cue delivered when a timed hold (a stretch, a plank, a carry) runs out while Fernlet is in the background.")
            content.body = String(localized: "notification.workoutCue.holdEnded.body",
                                  defaultValue: "Ease out of it. The next step is ready when you are.", bundle: .module,
                                  comment: "Body of the hold-ended workout cue. Calm wording; the run moves on when the person opens Fernlet.")
        }
        content.sound = soundFileName.map { UNNotificationSound(named: UNNotificationSoundName(rawValue: $0)) }
        content.interruptionLevel = .active
        content.threadIdentifier = workoutCueIDPrefix + "thread"
        return content
    }
}
