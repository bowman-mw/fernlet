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
        PendingWidgetActionQueue().append(
            PendingWidgetAction(
                id: UUID(),
                dateKey: FernletDate.dayKey(for: now),
                action: PendingWidgetAction.waterPlusOne,
                createdAt: now
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
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

    private static let defaultsKey = "fernlet.intent.pendingSheet"

    static func request(_ target: Target) {
        UserDefaults.standard.set(target.rawValue, forKey: defaultsKey)
    }

    /// Returns the requested target and clears it, so it's honored exactly once.
    static func consume() -> Target? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return Target(rawValue: raw)
    }
}
