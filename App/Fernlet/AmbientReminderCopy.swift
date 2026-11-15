import Foundation

/// The gentle reminders' words (owner-approved English, G8, 2026-11-13).
///
/// Every line is one whole sentence with its own catalog key — one per season where a season is
/// named, so a language can agree its article and adjective with the season ("el otoño pasado",
/// "la primavera pasada") instead of splicing a word into an English sentence. No line carries a
/// number, a comparison with now, or anything framed as absence.
nonisolated enum AmbientReminderCopy {
    /// "Not now" on every reminder: hides that kind for a month.
    static var notNow: String {
        String(localized: "home.ambient.notNow", defaultValue: "Not now",
               comment: "Home gentle reminder card: the button that puts the reminder away for a month. Calm, never a refusal.")
    }

    /// The card's title for the new reminders (nil for the meal chips and the workout, which keep
    /// their own long-standing titles and catalog keys in `AmbientCardsView`).
    static func title(for reminder: AmbientReminder) -> String? {
        switch reminder.kind {
        case .forgottenMeal, .forgottenWorkout:
            nil
        case .forgottenRecipe:
            String(localized: "home.forgotten.recipe.title", defaultValue: "Still sound good?",
                   comment: "Home card title over a recipe the person made a few times but not lately.")
        case .forgottenCalm:
            String(localized: "home.forgotten.calm.title", defaultValue: "It's still here",
                   comment: "Home card title over a breathing or grounding tool that helped the person before.")
        case .seasonalSoup:
            String(localized: "home.seasonal.soup.title", defaultValue: "Soup season",
                   comment: "Home card title: last year at this time of year the person made a lot of soup.")
        case .seasonalWalks, .seasonalWorkouts:
            String(localized: "home.seasonal.thisTimeLastYear.title", defaultValue: "This time last year",
                   comment: "Home card title over a note about what the person did around this time last year. Never a comparison with now.")
        case .seasonalWater:
            String(localized: "home.seasonal.water.title", defaultValue: "Warm days ahead",
                   comment: "Home card title as summer comes: last summer the person drank plenty of water on hot days.")
        }
    }

    /// The card's sentence for the new reminders (nil for the meal chips and the workout, which draw their own).
    static func body(for reminder: AmbientReminder) -> String? {
        switch reminder.subject {
        case .none:
            nil
        case .recipe(_, let name):
            String(localized: "home.forgotten.recipe.body", defaultValue: "You've made \(name) a few times, but not lately.",
                   comment: "Home 'Still sound good?' card. The placeholder is the name of one of the person's own recipes. Never a count, never a scold.")
        case .calm(let tool):
            calmBody(toolName(tool))
        case .season(let season):
            seasonalBody(reminder.kind, season)
        }
    }

    /// A seasonal card's sentence about last year's `season` (nil for a kind that is not seasonal).
    private static func seasonalBody(_ kind: AmbientReminderKind, _ season: AmbientSeason) -> String? {
        switch kind {
        case .seasonalSoup: soupBody(season)
        case .seasonalWorkouts: workoutsBody(season)
        case .seasonalWalks:
            String(localized: "home.seasonal.walks.body",
                   defaultValue: "Around now last year you went on lots of walks. The paths are still there.",
                   comment: "Home 'This time last year' card: around this time last year the person walked a lot. Never a comparison with now, never a count.")
        case .seasonalWater:
            String(localized: "home.seasonal.water.body.summer",
                   defaultValue: "Last summer you kept the water coming on the hot days. It's warming up again.",
                   comment: "Home 'Warm days ahead' card as summer comes. Never a comparison with now, never a count.")
        case .forgottenMeal, .forgottenWorkout, .forgottenRecipe, .forgottenCalm:
            nil
        }
    }

    /// "Soup season"'s sentence for last year's `season`.
    private static func soupBody(_ season: AmbientSeason) -> String {
        switch season {
        case .spring:
            String(localized: "home.seasonal.soup.body.spring", defaultValue: "Last spring you made a lot of soup. It's that time of year again.",
                   comment: "Home 'Soup season' card: last spring the person made a lot of soup. Never a comparison with now, never a count.")
        case .summer:
            String(localized: "home.seasonal.soup.body.summer", defaultValue: "Last summer you made a lot of soup. It's that time of year again.",
                   comment: "Home 'Soup season' card: last summer the person made a lot of soup. Never a comparison with now, never a count.")
        case .autumn:
            String(localized: "home.seasonal.soup.body.autumn", defaultValue: "Last autumn you made a lot of soup. It's that time of year again.",
                   comment: "Home 'Soup season' card: last autumn the person made a lot of soup. Never a comparison with now, never a count.")
        case .winter:
            String(localized: "home.seasonal.soup.body.winter", defaultValue: "Last winter you made a lot of soup. It's that time of year again.",
                   comment: "Home 'Soup season' card: last winter the person made a lot of soup. Never a comparison with now, never a count.")
        }
    }

    /// The workouts card's sentence for last year's `season`.
    private static func workoutsBody(_ season: AmbientSeason) -> String {
        switch season {
        case .spring:
            String(localized: "home.seasonal.workouts.body.spring",
                   defaultValue: "Last spring was a busy stretch of workouts for you. However this spring goes is fine.",
                   comment: "Home 'This time last year' card: last spring was a busy stretch of workouts; however this spring goes is fine. Never a comparison, never a count.")
        case .summer:
            String(localized: "home.seasonal.workouts.body.summer",
                   defaultValue: "Last summer was a busy stretch of workouts for you. However this summer goes is fine.",
                   comment: "Home 'This time last year' card: last summer was a busy stretch of workouts; however this summer goes is fine. Never a comparison, never a count.")
        case .autumn:
            String(localized: "home.seasonal.workouts.body.autumn",
                   defaultValue: "Last autumn was a busy stretch of workouts for you. However this autumn goes is fine.",
                   comment: "Home 'This time last year' card: last autumn was a busy stretch of workouts; however this autumn goes is fine. Never a comparison, never a count.")
        case .winter:
            String(localized: "home.seasonal.workouts.body.winter",
                   defaultValue: "Last winter was a busy stretch of workouts for you. However this winter goes is fine.",
                   comment: "Home 'This time last year' card: last winter was a busy stretch of workouts; however this winter goes is fine. Never a comparison, never a count.")
        }
    }

    /// The calm card's sentence for a tool named `tool`.
    private static func calmBody(_ tool: String) -> String {
        String(localized: "home.forgotten.calm.body", defaultValue: "\(tool) has helped you settle before. It's here whenever you want it.",
               comment: "Home 'It's still here' card. The placeholder is a calm tool's name, e.g. 'Box breathing' or 'Grounding', starting the sentence.")
    }

    /// A calm tool's name, as it starts the calm card's sentence.
    static func toolName(_ tool: AmbientCalmTool) -> String {
        switch tool {
        case .boxBreathing:
            String(localized: "home.forgotten.calm.tool.box", defaultValue: "Box breathing",
                   comment: "Name of the box breathing pattern (in 4, hold 4, out 4, hold 4), starting a sentence on a Home card.")
        case .relaxBreathing:
            String(localized: "home.forgotten.calm.tool.relax", defaultValue: "Relax breathing",
                   comment: "Name of the 4-7-8 relaxing breathing pattern, starting a sentence on a Home card.")
        case .grounding:
            String(localized: "home.forgotten.calm.tool.grounding", defaultValue: "Grounding",
                   comment: "Name of the 5-4-3-2-1 grounding exercise, starting a sentence on a Home card.")
        }
    }

    /// The card's open button, or nil when the card only has "Not now".
    static func action(for reminder: AmbientReminder) -> String? {
        switch reminder.kind {
        case .forgottenRecipe:
            String(localized: "home.forgotten.recipe.action", defaultValue: "Open recipe",
                   comment: "Home 'Still sound good?' card: opens the recipe.")
        case .forgottenCalm:
            calmAction(for: reminder.subject)
        case .seasonalSoup:
            String(localized: "home.seasonal.soup.action", defaultValue: "Find a soup",
                   comment: "Home 'Soup season' card: opens the recipe book to find a soup.")
        case .forgottenMeal, .forgottenWorkout, .seasonalWalks, .seasonalWorkouts, .seasonalWater:
            nil
        }
    }

    /// The calm card's open button: "Breathe now" for breathing, "Start grounding" for grounding.
    private static func calmAction(for subject: AmbientReminder.Subject) -> String {
        if case .calm(.grounding) = subject {
            return String(localized: "home.forgotten.calm.startGrounding", defaultValue: "Start grounding",
                          comment: "Home 'It's still here' card: opens the 5-4-3-2-1 grounding exercise.")
        }
        return String(localized: "home.forgotten.calm.breatheNow", defaultValue: "Breathe now",
                      comment: "Home 'It's still here' card: opens slow breathing on the pattern the card named.")
    }
}
