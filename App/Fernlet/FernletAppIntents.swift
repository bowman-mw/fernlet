import AppIntents
import WidgetKit
import Foundation
import FernletFoundation

// Siri / Shortcuts / Spotlight actions (#6). Two shapes:
// - `LogWaterIntent` runs WITHOUT opening the app — it appends to the same app-group pending-action
//   queue the widget's "+1 water" button uses, which the app drains on next foreground (day-rollover
//   safe). So "Hey Siri, log water in Fernlet" works even with the app closed.
// - `LogMealIntent` / `OpenJournalIntent` OPEN the app to the matching sheet, via a small persisted
//   deep-link the app consumes when it becomes active.

/// The background "log water" App Intent — works with the app closed.
///
/// Appends one `waterPlusOne` row per requested bottle to ``PendingWidgetActionQueue`` (the same
/// app-group queue the widget's "+1" button writes), optimistically bumps the mirrored widget
/// snapshot so the count updates instantly, and only claims in the Siri dialog the bottles that
/// durably enqueued. The app applies the canonical diary mutations when it next drains the queue.
///
/// **T2-9:** ``bottles`` is a real `@Parameter`, so a Voice Control or Shortcuts user can log a
/// glass count in one action instead of repeating a fixed one-bottle phrase. It defaults to `1`, so
/// every shortcut built against the old unparameterized intent — and the widget's own separate
/// `WaterPlusOneIntent` "+1" button — keeps its exact previous behaviour. The count is deliberately
/// *not* interpolated into a ``FernletShortcuts`` phrase: App Shortcut phrase parameters must be
/// `AppEnum`- or `AppEntity`-typed (Siri needs a closed vocabulary), and an unsupported phrase
/// parameter de-registers the shortcut at runtime rather than failing the build.
struct LogWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Log water"
    static let description = IntentDescription("Adds bottles of water to today's Fernlet diary.")
    // Runs in the background — no need to bring the app forward for a one-tap log.
    static let openAppWhenRun = false

    /// Floor on one invocation. Below this there is nothing to log, so ``perform()`` declines and
    /// says so rather than inventing a bottle nobody asked for.
    ///
    /// Pinned to the `inclusiveRange` literal below by
    /// `AppIntentsTests.theDeclaredBottleRangeMatchesTheEnforcedCap`.
    static let minBottlesPerRun = 1

    /// Hard ceiling on one invocation (rule 2/3): a mis-heard "log a hundred bottles" can neither
    /// spin an unbounded loop nor flood the shared app-group queue. Ten is already well past a
    /// realistic single log, and the widget snapshot clamps the displayed count at 30 regardless.
    ///
    /// This CANNOT be spliced into the `inclusiveRange` below: that parameter is declared
    /// `_const AppIntents.IntentParameter<Value>.InclusiveRange<…>?`, which accepts only a literal —
    /// a `static let` is rejected outright (a build error, not a silent drop). So the two are pinned
    /// together by a test instead: `AppIntentsTests.theDeclaredBottleRangeMatchesTheEnforcedCap`
    /// reads the literal back out of this file and asserts it equals ``minBottlesPerRun`` and this
    /// constant. Nothing else would notice them drifting — Shortcuts would keep offering a stepper
    /// that runs past what ``perform()`` honours, and the extra bottles would simply vanish.
    static let maxBottlesPerRun = 10

    /// How many bottles this run logs. Defaults to one, so the unparameterized behaviour is
    /// unchanged; the range keeps Shortcuts' stepper — and any spoken value — inside the cap.
    /// The literal `(1, 10)` must equal (``minBottlesPerRun``, ``maxBottlesPerRun``); see above.
    @Parameter(title: "Bottles", description: "How many bottles of water to log.",
               default: 1, inclusiveRange: (1, 10))
    var bottles: Int

    // @MainActor: the app target has default-MainActor isolation, so the app-group queue, snapshot
    // store, and `WidgetSnapshotMirror.widgetKind` are all implicitly main-actor-isolated. AppIntent's
    // `perform()` is `nonisolated` by default; hop onto the main actor once here (this runs in the app
    // process, where the work is trivial file I/O) rather than sprinkling `await`s across an implicit hop.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Same app-group queue the widget's "+1 water" button appends to; the app drains it on next
        // foreground and applies the canonical diary mutation against each row's own day key.
        let now = Date()
        let dayKey = FernletDate.dayKey(for: now)
        // Rule 5, validate at entry. `inclusiveRange` is a Shortcuts UI/resolution HINT, not a
        // contract: `bottles` arrives from outside the app and can be zero or negative (a Shortcuts
        // variable, a mis-resolved spoken value), and `0..<bottles` traps outright on a negative.
        // Below the floor is DECLINED and said aloud rather than quietly rewritten to 1 — logging a
        // bottle nobody asked for is worse than saying no. Above the ceiling is clamped instead,
        // because "log a hundred bottles" IS a request to log as much as we allow, and the dialog
        // below only ever claims what actually landed.
        guard bottles >= Self.minBottlesPerRun else {
            return .result(dialog: "I need at least one bottle to log.")
        }
        let requested = min(bottles, Self.maxBottlesPerRun)
        let queue = PendingWidgetActionQueue()
        var logged = 0
        // Rule 2: bounded by the clamp above. `append` reports durability per row, so a queue that
        // hits its cap part-way through stops here and the dialog claims only what actually landed.
        for _ in 0..<requested {
            let row = PendingWidgetAction(id: UUID(), dateKey: dayKey,
                                          action: PendingWidgetAction.waterPlusOne, createdAt: now)
            guard queue.append(row) else { break }
            logged += 1
        }
        // The queue write silently swallows I/O errors; only claim success when a row is durably
        // enqueued, so the dialog doesn't promise a log that never happened.
        guard logged > 0 else {
            return .result(dialog: "Couldn't log that just now — please try again in a moment.")
        }
        bumpWidgetSnapshot(dayKey: dayKey, bottles: logged)
        return .result(dialog: Self.loggedDialog(bottles: logged))
    }

    /// Optimistically bump the mirrored snapshot once per durably queued bottle, exactly like the
    /// widget's own "+1" button, so the count updates instantly instead of showing a stale value
    /// until the app is next foregrounded. The app's authoritative store-drain publish overwrites
    /// these values, same as for widget taps. A run where no bump landed skips the reload —
    /// re-rendering the same stale bytes buys nothing, and the rows ARE durably queued, so the app
    /// corrects the widget on its next publish.
    ///
    /// Rule 5: `bottles` is validated here rather than assumed. A count of zero or less means no row
    /// durably landed, so there is nothing to bump and nothing to reload — and, critically,
    /// `0..<bottles` is a *trap*, not an empty loop, once `bottles` is negative (`Range` requires
    /// `lowerBound <= upperBound`). Guarding at entry keeps that trap unreachable no matter what the
    /// caller does later.
    @MainActor
    private func bumpWidgetSnapshot(dayKey: String, bottles: Int) {
        guard bottles > 0 else { return }
        let store = WidgetSnapshotFileStore()
        var bumped = false
        // Rule 2: bounded by a fixed constant here as well as by the caller's clamp, so the bound
        // does not depend on a second function staying correct.
        for _ in 0..<min(bottles, Self.maxBottlesPerRun) {
            if store.applyOptimisticWaterPlusOne(dayKey: dayKey) { bumped = true }
        }
        if bumped {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotMirror.widgetKind)
        }
    }

    /// The Siri confirmation line, as a plural-ruled catalog key.
    ///
    /// The count decides the WORDING, so the plural belongs in the catalog, not in Swift: an
    /// `if bottles > 1` fork offers exactly the two forms English happens to need, and every
    /// language with more (Polish three, Arabic six) is stuck agreeing in the wrong number forever —
    /// with a clean build and no failing test. `intent.water.logged` carries `one`/`other`
    /// variations in `App/Fernlet/Localizable.xcstrings`, and `one` keeps the original wording
    /// ("Logged a bottle of water."), so an existing unparameterized shortcut sounds exactly as it
    /// did before the `bottles` parameter landed.
    private static func loggedDialog(bottles: Int) -> IntentDialog {
        IntentDialog(LocalizedStringResource(
            "intent.water.logged",
            defaultValue: "Logged \(bottles) bottles of water.",
            comment: "Siri confirmation after logging water. The number is how many bottles were logged; needs a plural variation per language, and English also needs the one-bottle form."))
    }
}

/// The foreground "log a meal" App Intent: opens the app and requests the meal sheet.
///
/// Records its target via ``PendingIntentSheet`` before the system foregrounds (or after, on the
/// warm path — the posted notification covers that ordering); `ContentView` consumes the token
/// and presents `.meal`.
struct LogMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a meal"
    static let description = IntentDescription("Opens Fernlet to log a meal.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.meal)
        return .result()
    }
}

/// The foreground "write in my journal" App Intent: opens the app and requests the journal sheet.
///
/// Same ``PendingIntentSheet`` deep-link mechanics as ``LogMealIntent``, targeting `.journal`.
struct OpenJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Write in my journal"
    static let description = IntentDescription("Opens Fernlet to a new journal entry.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.journal)
        return .result()
    }
}

/// Opens the trainer handoff and prepares its temporary summary file. The file remains inside
/// Fernlet until the user explicitly opens the system share sheet.
struct PrepareTrainerSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare training summary"
    static let description = IntentDescription("Opens Fernlet and prepares a trainer summary for sharing.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.trainerPrepareSummary)
        return .result()
    }
}

/// Opens the trainer handoff at its existing clipboard privacy confirmation. The intent never writes
/// health data to the pasteboard in the background.
struct CopyTrainerSummaryPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy training summary and prompt"
    static let description = IntentDescription("Opens Fernlet to confirm copying a training summary and prompt.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.trainerCopySummaryAndPrompt)
        return .result()
    }
}

/// Opens the foreground paste-and-review flow. Import remains impossible until the user supplies a
/// plan and approves its safety review in the app.
struct PasteTrainerPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste workout plan"
    static let description = IntentDescription("Opens Fernlet to paste and review a workout plan.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentSheet.request(.trainerPastePlan)
        return .result()
    }
}

/// A tiny persisted deep-link for foreground intents: the intent records which sheet it wants, the app
/// reads and clears it when it becomes active.
///
/// Backed by `UserDefaults.standard` because a foreground App Intent and the app UI don't share
/// in-memory state reliably across the launch. `ContentView.consumePendingNotificationSheet()`
/// honors a consumed token before the notification deep-link path.
///
/// `nonisolated` (overriding the app target's MainActor default): it holds no state of its own —
/// `UserDefaults` is thread-safe and the wake-up notification is explicitly hopped to the main
/// queue — so `request`/`consume` are callable from anywhere, including the `AppIntentsTests`
/// harness's `deinit`, which drains the token so a failing test can never leak one into the next.
nonisolated enum PendingIntentSheet {
    /// The sheets a foreground intent can request; raw values are the persisted token strings.
    ///
    /// `ContentView` switches on the consumed target to present the matching `FernletSheet`.
    enum Target: String {
        case meal
        case journal
        case trainerPrepareSummary
        case trainerCopySummaryAndPrompt
        case trainerPastePlan
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
    ///
    /// JSON-encoded into `UserDefaults` by `request(_:createdAt:)` and decoded by `consume()`.
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
