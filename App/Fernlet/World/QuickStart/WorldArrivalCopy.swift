import Foundation

/// The arrival offers' words on the blue button (owner's picks N2 to N4, 2026-11-27), in the person's language. No
/// place name in any of them (N4-B): the card's heading, its choices and the words beside the button say what to
/// start, not where.
nonisolated enum WorldArrivalCopy {
    /// The card's heading at a restaurant the person arrived at.
    static var eatingOut: String {
        String(localized: "worldQuickStart.arrival.heading.eatingOut", defaultValue: "Eating out",
               comment: "World Home quick-start card heading at a restaurant the person just arrived at; no place name (Spanish: Comiendo fuera)")
    }

    /// The card's heading at a gym the person arrived at.
    static var atTheGym: String {
        String(localized: "worldQuickStart.arrival.heading.gym", defaultValue: "At the gym",
               comment: "World Home quick-start card heading at a gym the person just arrived at; no place name (Spanish: En el gimnasio)")
    }

    /// The words beside the button for an arrival offer of `kind`: "Log a meal here", "Start a workout here".
    static func buttonLabel(_ kind: WorldArrivalKind) -> String {
        switch kind {
        case .restaurant:
            String(localized: "worldQuickStart.arrival.label.meal", defaultValue: "Log a meal here",
                   comment: "World Home: the words beside the blue button after arriving at a restaurant; opens Log meal (Spanish: Registrar una comida aquí)")
        case .gym:
            String(localized: "worldQuickStart.arrival.label.workout", defaultValue: "Start a workout here",
                   comment: "World Home: the words beside the blue button after arriving at a gym (Spanish: Empezar un entreno aquí)")
        }
    }

    /// A choice's name.
    static func title(_ choice: WorldArrivalChoice) -> String {
        switch choice {
        case .logMeal:
            String(localized: "worldQuickStart.arrival.logMeal", defaultValue: "Log a meal",
                   comment: "World Home quick start at a restaurant the person just arrived at: opens Log meal (Spanish: Registrar una comida)")
        case .findMenu:
            String(localized: "worldQuickStart.arrival.findMenu", defaultValue: "Find the menu",
                   comment: "World Home quick start at a restaurant the person just arrived at: searches the web for its menu by the place's name, which is not shown (Spanish: Buscar el menú)")
        case .startPlan:
            String(localized: "worldQuickStart.arrival.startPlan", defaultValue: "Start today's plan",
                   comment: "World Home quick start at a gym the person just arrived at, with a plan due today: starts its next guided session (Spanish: Empezar el plan de hoy)")
        case .logWorkout:
            String(localized: "worldQuickStart.arrival.logWorkout", defaultValue: "Log a workout",
                   comment: "World Home quick start at a gym the person just arrived at, with no plan due: opens Log workout (Spanish: Registrar un entreno)")
        case .suggestWorkout:
            String(localized: "worldQuickStart.arrival.suggestWorkout", defaultValue: "Suggest a workout",
                   comment: "World Home quick start at a gym the person just arrived at, below 'Log a workout': opens Move's workout suggestion (Spanish: Sugerir un entreno)")
        }
    }

    /// A choice's line.
    static func detail(_ choice: WorldArrivalChoice) -> String {
        switch choice {
        case .logMeal:
            String(localized: "worldQuickStart.arrival.logMeal.detail", defaultValue: "Picks the meal by the time of day",
                   comment: "World Home quick start at a restaurant: under 'Log a meal'; breakfast, lunch, snack or dinner is chosen from the time now (Spanish: Elige la comida según la hora)")
        case .findMenu:
            // The favourite place's line, word for word: the search goes by the name, never the location.
            WorldQuickStartCopy.detail(.findMenu(place: ""))
        case .startPlan(let session):
            session
        case .logWorkout:
            String(localized: "worldQuickStart.arrival.logWorkout.detail", defaultValue: "Add what you did",
                   comment: "World Home quick start at a gym: under 'Log a workout' (Spanish: Añade lo que hiciste)")
        case .suggestWorkout:
            String(localized: "worldQuickStart.arrival.suggestWorkout.detail", defaultValue: "Picked for how you are today",
                   comment: "World Home quick start at a gym: under 'Suggest a workout'; Move's suggestion follows today's readiness (Spanish: Elegido según cómo estás hoy)")
        }
    }
}
