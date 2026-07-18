import AppIntents
import WidgetKit
import Foundation
import FernletFoundation

/// Siri / Shortcuts / Spotlight actions (#6). Two shapes:
/// - `LogWaterIntent` runs WITHOUT opening the app — it appends to the same app-group pending-action
///   queue the widget's "+1 water" button uses, which the app drains on next foreground (day-rollover
///   safe). So "Hey Siri, log water in Fernlet" works even with the app closed.
/// - `LogMealIntent` / `OpenJournalIntent` OPEN the app to the matching sheet, via a small persisted
///   deep-link the app consumes when it becomes active.

struct LogWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a bottle of water"
    static let description = IntentDescription("Adds one bottle of water to today's Fernlet diary.")
    // Runs in the background — no need to bring the app forward for a one-tap log.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Same app-group queue the widget's "+1 water" button appends to; the app drains it on next
        // foreground and applies the canonical diary mutation against this row's own day key.
        let now = Date()
        let dayKey = FernletDate.dayKey(for: now)
        let queued = PendingWidgetActionQueue().append(
            PendingWidgetAction(
                id: UUID(),
                dateKey: dayKey,
                action: PendingWidgetAction.waterPlusOne,
                createdAt: now
            )
        )
        // The queue write silently swallows I/O errors; only claim success when the row is durably
        // enqueued, so the dialog doesn't promise a log that never happened.
        guard queued else {
            return .result(dialog: "Couldn't log that just now — please try again in a moment.")
        }
        // Optimistically bump the mirrored snapshot exactly like the widget's own "+1" button, so the
        // count updates instantly instead of showing a stale value until the app is next foregrounded.
        // The app's authoritative store-drain publish overwrites this value, same as for widget taps.
        WidgetSnapshotFileStore().applyOptimisticWaterPlusOne(dayKey: dayKey)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotMirror.widgetKind)
        return .result(dialog: "Logged a bottle of water.")
    }
}

struct LogMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a meal"
    static let description = IntentDescription("Opens Fernlet to log a meal.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.meal)
        return .result()
    }
}

struct OpenJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Write in my journal"
    static let description = IntentDescription("Opens Fernlet to a new journal entry.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.journal)
        return .result()
    }
}

/// A tiny persisted deep-link for foreground intents: the intent records which sheet it wants, the app
/// reads and clears it when it becomes active. Backed by `UserDefaults.standard` because a foreground
/// App Intent and the app UI don't share in-memory state reliably across the launch.
enum PendingIntentSheet {
    enum Target: String {
        case meal
        case journal
    }

    /// Posted right after `request(_:)` writes the token, so a resident ContentView consumes it on the
    /// WARM path too. With `openAppWhenRun`, the system foregrounds an already-running app (scene goes
    /// `.active`) BEFORE `perform()` writes the token, so nothing would otherwise read it. This mirrors
    /// `FernletNotificationDelegate.pendingSheetRequestNotification`; cold launches still consume the
    /// token from ContentView's startup task.
    static let requestNotification = Notification.Name("fernlet.intent.pendingSheetRequest")

    /// An intent-driven open should land within seconds. A token older than this was stranded (onboarding
    /// still up, the app killed under a covering sheet, …) and must not hijack a later notification tap,
    /// cold launch, or unrelated sheet dismissal, so `consume()` discards it.
    private static let expiryWindow: TimeInterval = 120

    private static let defaultsKey = "fernlet.intent.pendingSheet"

    /// The persisted token: which sheet + when it was requested (for the expiry gate).
    private struct Request: Codable {
        var target: String
        var createdAt: Date
    }

    /// `createdAt` is injectable for tests only; call sites use the defaulted `request(.meal)` form.
    static func request(_ target: Target, createdAt: Date = Date()) {
        let payload = Request(target: target.rawValue, createdAt: createdAt)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        // Delivered on the main queue so the SwiftUI observer mutates state on the main actor; the token
        // is already written synchronously above, so the observer always sees it.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: requestNotification, object: nil)
        }
    }

    /// Returns the requested target and clears it, so it's honored exactly once. A token older than
    /// `expiryWindow` (or any legacy/corrupt value) is cleared and discarded.
    static func consume() -> Target? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode(Request.self, from: data) else {
            // Clear any stale/legacy value so it can't wedge the slot.
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return nil
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        guard Date().timeIntervalSince(payload.createdAt) <= expiryWindow else { return nil }
        return Target(rawValue: payload.target)
    }
}
