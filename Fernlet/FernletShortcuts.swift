import AppIntents

/// Surfaces Fernlet's App Intents to Spotlight and Siri (#6). Auto-discovered by the system; each
/// `AppShortcut` carries a few natural phrases (all must include `\(.applicationName)`).
struct FernletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Log a bottle of water in \(.applicationName)",
                "Add water to \(.applicationName)"
            ],
            shortTitle: "Log water",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: LogMealIntent(),
            phrases: [
                "Log a meal in \(.applicationName)",
                "Log food in \(.applicationName)"
            ],
            shortTitle: "Log a meal",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: OpenJournalIntent(),
            phrases: [
                "Write in my \(.applicationName) journal",
                "Open my \(.applicationName) journal"
            ],
            shortTitle: "Write in journal",
            systemImageName: "book.closed"
        )
        // F5 cooking mode — the hands-free voice path for the recipe walker. The same two
        // LiveActivityIntents that back the Lock Screen "Next" button; here they answer Siri phrases so
        // a cook with messy hands can advance or re-fire the step timer without touching the phone.
        AppShortcut(
            intent: NextCookingStepIntent(),
            phrases: [
                "Next step in \(.applicationName)",
                "Next cooking step in \(.applicationName)",
                "\(.applicationName) next step"
            ],
            shortTitle: "Next cooking step",
            systemImageName: "chevron.right"
        )
        AppShortcut(
            intent: RepeatCookingStepIntent(),
            phrases: [
                "Repeat step in \(.applicationName)",
                "Repeat cooking step in \(.applicationName)",
                "Restart my \(.applicationName) timer"
            ],
            shortTitle: "Repeat cooking step",
            systemImageName: "arrow.counterclockwise"
        )
    }
}
