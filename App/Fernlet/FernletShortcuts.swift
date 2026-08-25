import AppIntents

/// Surfaces Fernlet's App Intents to Spotlight and Siri (#6).
///
/// Auto-discovered by the system; each `AppShortcut` carries a few natural phrases (all must
/// include `\(.applicationName)`). Covers the water/meal/journal intents plus the two cooking-mode
/// and two guided-workout `LiveActivityIntent`s, so a cook or a lifter can drive the run hands-free.
///
/// **The system caps a provider at 10 shortcuts** and fails the extras at *runtime*, not build
/// time — `AppIntentsTests` pins the count, the intent list, and the phrase shape, so a silent
/// de-registration can never ship. All ten slots are used today.
///
/// **Every registration is written out literally in ``appShortcuts``, and must stay that way** — but
/// not for the reason an earlier version of this comment gave. The measured behaviour (probed
/// against the iOS 26.5 SDK's `AppIntents.swiftinterface` and `swiftc -typecheck`):
///
/// - `systemImageName` is declared `_const Swift.String`. Passing anything but a literal — a
///   `static let`, a computed property — is a **hard build error**, `expect a compile-time constant
///   literal`. It is *not* silently dropped, so no wall is needed for it.
/// - `phrases` is **not** `_const`: it is `[AppShortcutPhrase<Intent>]`, which is merely
///   `ExpressibleByStringInterpolation`. Hoisting the array into a `static let` also fails to build,
///   for an unrelated reason — `AppShortcutPhrase` is not `Sendable`, so Swift 6 rejects the stored
///   global.
/// - What genuinely fails *silently, at runtime* is the ten-per-provider cap and a phrase that omits
///   `\(.applicationName)`. That is the whole reason `AppIntentsTests` carries a wall.
///
/// So the literal form is kept for two concrete reasons, neither of them a const-evaluated silent
/// drop: the App Intents metadata processor harvests this property at build time, and
/// `AppIntentsTests` *parses this file* — `intent: SomeIntent(),` lines and `phrases: [ … ]` arrays
/// — because `AppShortcut` exposes no readable stored properties. Moving a registration into a
/// helper (or another file) takes it out of the wall's view. That is why the argument lists are
/// packed rather than split: rule 4's 60-line ceiling is met by formatting, never by extraction.
/// (Both cooking and workout pairs are `LiveActivityIntent`s: the same two types the Lock Screen
/// buttons use, here answering a voice phrase as well. The two guided-workout intents return a
/// `ProvidesDialog` result, so a phrase spoken in the wrong phase is *said*, not chimed at — a11y
/// #15. `NextCookingStepIntent` / `RepeatCookingStepIntent` still return a bare `.result()` and
/// carry the same defect; they are the matching residual, not a deliberate difference.)
///
/// Nothing here writes sealed data. Registering a background intent that wrote journal, cycle, or
/// intimacy content would put a write outside the app-lock gate — a security decision, not an
/// accessibility one — so those surfaces stay foreground-only (`LogMealIntent` / `OpenJournalIntent`
/// open the app and let the normal gate run).
struct FernletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogWaterIntent(),
            phrases: ["Log water in \(.applicationName)", "Log a bottle of water in \(.applicationName)",
                      "Add water to \(.applicationName)"],
            shortTitle: "Log water", systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: LogMealIntent(),
            phrases: ["Log a meal in \(.applicationName)",
                      "Log food in \(.applicationName)"],
            shortTitle: "Log a meal", systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: OpenJournalIntent(),
            phrases: ["Write in my \(.applicationName) journal",
                      "Open my \(.applicationName) journal"],
            shortTitle: "Write in journal", systemImageName: "book.closed"
        )
        // F5 cooking mode — the hands-free voice path for the recipe walker, so a cook with messy
        // hands can advance or re-fire the step timer without touching the phone.
        AppShortcut(
            intent: NextCookingStepIntent(),
            phrases: ["Next step in \(.applicationName)", "Next cooking step in \(.applicationName)",
                      "\(.applicationName) next step"],
            shortTitle: "Next cooking step", systemImageName: "chevron.right"
        )
        AppShortcut(
            intent: RepeatCookingStepIntent(),
            phrases: ["Repeat step in \(.applicationName)", "Repeat cooking step in \(.applicationName)",
                      "Restart my \(.applicationName) timer"],
            shortTitle: "Repeat cooking step", systemImageName: "arrow.counterclockwise"
        )
        // Guided workout (T2-9) — the same hands-free argument the cooking pair was accepted on.
        // Someone mid-set, or anyone who cannot reliably hit a small button on a Lock Screen that
        // keeps re-laying out, can advance the run by voice. Both transitions are phase-guarded in
        // GuidedWorkoutIntentRunner, so a phrase spoken in the wrong phase is a harmless no-op.
        AppShortcut(
            intent: GuidedWorkoutMarkSetDoneIntent(),
            phrases: ["Done set in \(.applicationName)", "Mark my \(.applicationName) set done",
                      "Finish my set in \(.applicationName)"],
            shortTitle: "Done set", systemImageName: "checkmark"
        )
        AppShortcut(
            intent: GuidedWorkoutSkipRestIntent(),
            phrases: ["Skip rest in \(.applicationName)", "Skip my \(.applicationName) rest",
                      "\(.applicationName) skip rest"],
            shortTitle: "Skip rest", systemImageName: "forward.fill"
        )
        // Trainer handoff — foreground-only so summary creation, clipboard consent, paste, and plan
        // review all stay behind the app's existing visible privacy boundary.
        AppShortcut(
            intent: PrepareTrainerSummaryIntent(),
            phrases: ["Prepare my training summary in \(.applicationName)",
                      "Prepare a trainer summary in \(.applicationName)"],
            shortTitle: "Prepare summary", systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: CopyTrainerSummaryPromptIntent(),
            phrases: ["Copy my training summary and prompt in \(.applicationName)",
                      "Copy my trainer prompt in \(.applicationName)"],
            shortTitle: "Copy summary + prompt", systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: PasteTrainerPlanIntent(),
            phrases: ["Paste my workout plan in \(.applicationName)",
                      "Bring my trainer plan into \(.applicationName)"],
            shortTitle: "Paste a plan", systemImageName: "square.and.arrow.down"
        )
    }
}
