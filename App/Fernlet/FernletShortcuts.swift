import AppIntents

/// Surfaces Fernlet's App Intents to Spotlight and Siri (#6).
///
/// Auto-discovered by the system; each `AppShortcut` carries a few natural phrases (all must
/// include `\(.applicationName)`). Covers the water/meal/journal intents plus the two cooking-mode
/// plus consolidated cooking/workout controls and file exchange actions.
///
/// **The system caps a provider at 10 shortcuts** and fails the extras at *runtime*, not build
/// time — `AppIntentsTests` pins the count, the intent list, and the phrase shape, so a silent
/// de-registration can never ship. Nine slots are deliberately used; the tenth is reserved.
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
/// The original cooking/workout `LiveActivityIntent`s stay in the action library for saved
/// shortcuts and Lock Screen controls. Only their promoted Siri phrases are consolidated here.
///
/// Nothing here writes sealed data. Registering a background intent that wrote journal, cycle, or
/// intimacy content would put a write outside the app-lock gate — a security decision, not an
/// accessibility one — so those surfaces stay foreground-only (`LogMealIntent` / `OpenJournalIntent`
/// open the app and let the normal gate run).
struct FernletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
                    intent: LogWaterIntent(),
                    phrases: ["Log water in \(.applicationName)", "Log a bottle of water in \(.applicationName)", "Add water to \(.applicationName)"],
                    shortTitle: "Log water", systemImageName: "drop.fill")
        AppShortcut(
                    intent: LogMealIntent(),
                    phrases: ["Log a meal in \(.applicationName)", "Log food in \(.applicationName)"],
                    shortTitle: "Log a meal", systemImageName: "fork.knife")
        AppShortcut(
                    intent: OpenJournalIntent(),
                    phrases: ["Write in my \(.applicationName) journal", "Open my \(.applicationName) journal"],
                    shortTitle: "Write in journal", systemImageName: "book.closed")
        AppShortcut(
                    intent: ControlCookingIntent(),
                    phrases: ["Control cooking in \(.applicationName)", "Change a cooking step in \(.applicationName)"],
                    shortTitle: "Control cooking", systemImageName: "frying.pan")
        AppShortcut(
                    intent: ControlWorkoutIntent(),
                    phrases: ["Control workout in \(.applicationName)", "Change my workout in \(.applicationName)"],
                    shortTitle: "Control workout", systemImageName: "figure.strengthtraining.traditional")
        AppShortcut(
                    intent: ExportRecipeIntent(),
                    phrases: ["Export a recipe from \(.applicationName)", "Share a recipe file from \(.applicationName)"],
                    shortTitle: "Export recipe", systemImageName: "square.and.arrow.up")
        AppShortcut(
                    intent: ImportRecipeIntent(),
                    phrases: ["Import a recipe into \(.applicationName)", "Open a recipe file in \(.applicationName)"],
                    shortTitle: "Import recipe", systemImageName: "square.and.arrow.down")
        AppShortcut(
                    intent: ExportWorkoutPlanIntent(),
                    phrases: ["Export a workout plan from \(.applicationName)", "Share a workout plan file from \(.applicationName)"],
                    shortTitle: "Export workout plan", systemImageName: "square.and.arrow.up")
        AppShortcut(
                    intent: ImportWorkoutPlanIntent(),
                    phrases: ["Import a workout plan into \(.applicationName)", "Open a workout plan file in \(.applicationName)"],
                    shortTitle: "Import workout plan", systemImageName: "square.and.arrow.down")
    }
}
