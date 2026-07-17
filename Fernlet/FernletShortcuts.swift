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
    }
}
