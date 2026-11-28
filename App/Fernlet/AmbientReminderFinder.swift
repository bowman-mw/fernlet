import Foundation
import FernletDomainModel
import FernletFoundation

// AmbientReminderFinder.swift
//
// Which gentle reminders have something to say today: the forgotten good things (a recipe, a calm
// tool), a quiet place (AmbientPlaces.swift), short days (AmbientShortDays.swift) and the seasonal
// rhythms (soup, walks, workouts, water). Pure, with the clock injected; the caps that decide which of
// them actually show live in `AmbientReminderSchedule`. CAP-2: reads only the unsealed history in
// `AmbientHistory` and the place summary's values (see AmbientReminders.swift).

/// The unsealed history the finders read, gathered once from the diary.
nonisolated struct AmbientHistory: Equatable, Sendable {
    /// Every recipe made from the person's own recipes, with the days it was logged.
    var recipeUses: [AmbientRecipeUse] = []
    /// One entry per day with a soup, stew, chili or broth meal.
    var soupDays: [AmbientDatedAmount] = []
    /// One entry per walk or hike.
    var walks: [AmbientDatedAmount] = []
    /// One entry per workout of any kind.
    var workouts: [AmbientDatedAmount] = []
    /// One entry per day with water logged, its amount the bottles.
    var water: [AmbientDatedAmount] = []
    /// One entry per day with a nightly sleep total, its amount the hours (S2-A: totals only, no wake times).
    var nights: [AmbientDatedAmount] = []
    /// The earliest day with a meal, workout or water logged: the one-year gate's clock.
    var firstDataDate: Date?

    /// How far back the gather reads: two years covers last year's season and the rest of that year.
    static let lookbackDays = 730

    /// Gathers the history from `days` (the diary, keyed by `yyyy-MM-dd`) and the person's `recipes`.
    ///
    /// Reads meals, workouts, bottle counts and nightly sleep totals only, never a day's journals or
    /// anything sealed.
    static func gather(days: [String: FernletDay], recipes: [RecipeDefinition], now: Date,
                       calendar: Calendar = .current) -> AmbientHistory {
        var history = AmbientHistory()
        let recipesByName = Dictionary(recipes.map { (AmbientSoupWords.folded($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var recipeDates: [UUID: [Date]] = [:]
        guard let start = calendar.date(byAdding: .day, value: -lookbackDays, to: now) else { return history }
        for (key, day) in days {
            guard let date = FernletDate.date(fromDayKey: key) else { continue }
            let logged = !day.meals.isEmpty || !day.workouts.isEmpty || day.bottleCount > 0
            if logged, history.firstDataDate.map({ date < $0 }) ?? true { history.firstDataDate = date }
            guard date >= start, date <= now else { continue }
            history.noteMeals(day.meals, on: date, recipesByName: recipesByName, recipeDates: &recipeDates)
            for workout in day.workouts {
                history.workouts.append(AmbientDatedAmount(date: date, amount: 1))
                if workout.activityType == .walking || workout.activityType == .hiking {
                    history.walks.append(AmbientDatedAmount(date: date, amount: 1))
                }
            }
            if day.bottleCount > 0 { history.water.append(AmbientDatedAmount(date: date, amount: Double(day.bottleCount))) }
            if let hours = day.sleep?.hours ?? day.healthContext?.body?.sleepHours {
                history.nights.append(AmbientDatedAmount(date: date, amount: hours))
            }
        }
        history.recipeUses = recipes.compactMap { recipe in
            recipeDates[recipe.id].map { AmbientRecipeUse(id: recipe.id, name: recipe.name, dates: $0.sorted()) }
        }
        // The diary is a dictionary, so its order is not stable: oldest first, always.
        history.soupDays.sort { $0.date < $1.date }
        history.walks.sort { $0.date < $1.date }
        history.workouts.sort { $0.date < $1.date }
        history.water.sort { $0.date < $1.date }
        history.nights.sort { $0.date < $1.date }
        return history
    }

    /// Notes one day's meals: a recipe meal against its recipe, and the day once if any meal is a soup.
    private mutating func noteMeals(_ meals: [Meal], on date: Date, recipesByName: [String: RecipeDefinition],
                                    recipeDates: inout [UUID: [Date]]) {
        var hadSoup = false
        for meal in meals {
            if meal.mealSource == .recipe, let recipe = recipesByName[AmbientSoupWords.folded(meal.name)] {
                recipeDates[recipe.id, default: []].append(date)
            }
            if AmbientSoupWords.isSoup(meal.name) { hadSoup = true }
        }
        if hadSoup { soupDays.append(AmbientDatedAmount(date: date, amount: 1)) }
    }
}

/// The words that make a meal a soup for "Soup season", in English and Spanish (the app's languages).
///
/// A judgement call: a bowl of something brothy. Matched as whole words, case- and accent-blind.
nonisolated enum AmbientSoupWords {
    /// The English and Spanish words (es and es-MX share them).
    static let words: Set<String> = [
        "soup", "soups", "stew", "stews", "chili", "chilli", "broth", "chowder", "bisque", "ramen", "pho",
        "minestrone", "gumbo", "sopa", "sopas", "caldo", "caldos", "guiso", "estofado", "pozole", "menudo",
        "consome", "puchero", "cocido", "potaje", "crema"
    ]

    /// `text` lowercased, accents folded and trimmed, for matching.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a meal named `name` is a soup.
    static func isSoup(_ name: String) -> Bool {
        let tokens = folded(name).split { !$0.isLetter }
        guard !tokens.isEmpty else { return false }
        return tokens.contains { words.contains(String($0)) }
    }
}

/// Last year's same season and the rest of that year, as two date intervals.
nonisolated struct AmbientSeasonWindow: Equatable, Sendable {
    /// The season the window is about.
    let season: AmbientSeason
    /// Last year's three months of that season.
    let lastYear: DateInterval
    /// The months after it, up to a month before today: never this season, never now.
    let restOfYear: DateInterval

    /// The window for the season containing `date`, ending its comparison a month before `now`.
    ///
    /// `date` is today, or a month ahead for "Warm days ahead". Nil when the dates cannot be built or
    /// the rest of the year is too short to compare with (under two months).
    static func around(_ date: Date, now: Date, southern: Bool, calendar: Calendar) -> AmbientSeasonWindow? {
        let month = calendar.component(.month, from: date)
        let season = AmbientSeason.season(forMonth: month, southern: southern)
        let monthsIntoSeason = (month - 3 + 12) % 3
        var parts = calendar.dateComponents([.year, .month], from: date)
        parts.day = 1
        guard let monthStart = calendar.date(from: parts),
              let seasonStart = calendar.date(byAdding: .month, value: -monthsIntoSeason, to: monthStart),
              let lastStart = calendar.date(byAdding: .month, value: -12, to: seasonStart),
              let lastEnd = calendar.date(byAdding: .month, value: 3, to: lastStart),
              let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) else { return nil }
        let restEnd = min(seasonStart, monthAgo)
        guard restEnd.timeIntervalSince(lastEnd) >= 60 * 86_400 else { return nil }
        return AmbientSeasonWindow(season: season, lastYear: DateInterval(start: lastStart, end: lastEnd),
                                   restOfYear: DateInterval(start: lastEnd, end: restEnd))
    }

    /// Whether `events` clearly stood out in last year's season: at least `minimum` in all, and a
    /// daily rate at least `ratio` times the rest of that year's. Reads nothing outside the window.
    func stoodOut(_ events: [AmbientDatedAmount], minimum: Double, ratio: Double = 1.5) -> Bool {
        assert(minimum > 0 && ratio > 1, "a rhythm needs a floor and a real lift")
        let inSeason = events.filter { $0.date >= lastYear.start && $0.date < lastYear.end }.reduce(0) { $0 + $1.amount }
        guard inSeason >= minimum else { return false }
        let rest = events.filter { $0.date >= restOfYear.start && $0.date < restOfYear.end }.reduce(0) { $0 + $1.amount }
        let seasonRate = inSeason / max(lastYear.duration / 86_400, 1)
        let restRate = rest / max(restOfYear.duration / 86_400, 1)
        return seasonRate >= ratio * restRate
    }
}

/// Finds which reminders have something to say today. Pure: the clock and calendar are injected.
nonisolated enum AmbientReminderFinder {
    /// A recipe counts as forgotten after this long.
    static let recipeQuietDays = 60
    /// A calm tool counts as forgotten after this long.
    static let calmQuietDays = 30
    /// How many finishes make a calm tool one that helped before.
    static let calmMinimumFinishes = 3
    /// About a year: the seasonal cards wait until the first data is at least this old.
    static let seasonalGateDays = 330

    /// Every reminder with something to say today, in priority order: the recipe, the calm tool, the
    /// meal chips and the workout (when Home found them), short days, a quiet place, then the seasonal
    /// rhythms. The caps in `AmbientReminderSchedule` then pick at most two.
    ///
    /// `places` and `indoorPlaceAllowed` feed the quiet place (``AmbientQuietPlaceFinder``); `latitude`
    /// (the weather's, rounded to 1°, or nil) feeds short days (``AmbientShortDaysFinder``).
    static func candidates(history: AmbientHistory, calmFinishes: [AmbientCalmTool: [Date]],
                           hasForgottenMeals: Bool, hasForgottenWorkout: Bool, now: Date, southern: Bool,
                           places: [AmbientQuietPlace] = [], indoorPlaceAllowed: Bool = true, latitude: Int? = nil,
                           calendar: Calendar = .current) -> [AmbientReminder] {
        var found: [AmbientReminder] = []
        if let recipe = forgottenRecipe(history.recipeUses, now: now) { found.append(recipe) }
        if let calm = forgottenCalm(calmFinishes, now: now) { found.append(calm) }
        if hasForgottenMeals { found.append(AmbientReminder(kind: .forgottenMeal, subject: .none)) }
        if hasForgottenWorkout { found.append(AmbientReminder(kind: .forgottenWorkout, subject: .none)) }
        if let short = AmbientShortDaysFinder.reminder(latitude: latitude, nights: history.nights, now: now, calendar: calendar) {
            found.append(short)
        }
        if let place = AmbientQuietPlaceFinder.reminder(places, indoorAllowed: indoorPlaceAllowed, now: now, calendar: calendar) {
            found.append(place)
        }
        found += seasonal(history, now: now, southern: southern, calendar: calendar)
        assert(Set(found.map(\.kind)).count == found.count, "one reminder per kind")
        return found
    }

    /// The recipe made most (at least twice) whose last time is over `recipeQuietDays` ago.
    static func forgottenRecipe(_ uses: [AmbientRecipeUse], now: Date) -> AmbientReminder? {
        let quiet = now.addingTimeInterval(-Double(recipeQuietDays) * 86_400)
        let forgotten = uses.filter { use in
            guard use.dates.count >= 2, let last = use.dates.max() else { return false }
            return last < quiet
        }
        guard let pick = forgotten.max(by: { ($0.dates.count, $1.name) < ($1.dates.count, $0.name) }) else { return nil }
        return AmbientReminder(kind: .forgottenRecipe, subject: .recipe(id: pick.id, name: pick.name))
    }

    /// The calm tool finished most (at least `calmMinimumFinishes` times) and not in `calmQuietDays`.
    static func forgottenCalm(_ finishes: [AmbientCalmTool: [Date]], now: Date) -> AmbientReminder? {
        let quiet = now.addingTimeInterval(-Double(calmQuietDays) * 86_400)
        let forgotten = AmbientCalmTool.allCases.filter { tool in
            let dates = finishes[tool] ?? []
            guard dates.count >= calmMinimumFinishes, let last = dates.max() else { return false }
            return last < quiet
        }
        guard let pick = forgotten.max(by: { (finishes[$0]?.count ?? 0) < (finishes[$1]?.count ?? 0) }) else { return nil }
        return AmbientReminder(kind: .forgottenCalm, subject: .calm(pick))
    }

    /// The seasonal rhythms that stood out last year, in card order (soup, walks, workouts, water).
    ///
    /// Empty until the first data is about a year old. Reads only last year's season and the months
    /// after it, ending a month before `now`, so it never compares with now.
    static func seasonal(_ history: AmbientHistory, now: Date, southern: Bool,
                         calendar: Calendar = .current) -> [AmbientReminder] {
        guard let first = history.firstDataDate,
              now.timeIntervalSince(first) >= Double(seasonalGateDays) * 86_400 else { return [] }
        var found: [AmbientReminder] = []
        if let window = AmbientSeasonWindow.around(now, now: now, southern: southern, calendar: calendar) {
            if window.stoodOut(history.soupDays, minimum: 4) {
                found.append(AmbientReminder(kind: .seasonalSoup, subject: .season(window.season)))
            }
            if window.stoodOut(history.walks, minimum: 6) {
                found.append(AmbientReminder(kind: .seasonalWalks, subject: .season(window.season)))
            }
            if window.stoodOut(history.workouts, minimum: 8) {
                found.append(AmbientReminder(kind: .seasonalWorkouts, subject: .season(window.season)))
            }
        }
        if let water = warmDaysWindow(now: now, southern: southern, calendar: calendar),
           water.stoodOut(history.water, minimum: 30) {
            found.append(AmbientReminder(kind: .seasonalWater, subject: .season(.summer)))
        }
        return found
    }

    /// Last summer's window while summer is about to start or has just started (a month either side
    /// of its first day): "Warm days ahead". Nil the rest of the year.
    static func warmDaysWindow(now: Date, southern: Bool, calendar: Calendar) -> AmbientSeasonWindow? {
        guard let ahead = calendar.date(byAdding: .day, value: 30, to: now),
              let behind = calendar.date(byAdding: .day, value: -30, to: now) else { return nil }
        let seasonAhead = AmbientSeason.season(forMonth: calendar.component(.month, from: ahead), southern: southern)
        let seasonBehind = AmbientSeason.season(forMonth: calendar.component(.month, from: behind), southern: southern)
        guard seasonAhead == .summer, seasonBehind != .summer else { return nil }
        return AmbientSeasonWindow.around(ahead, now: now, southern: southern, calendar: calendar)
    }
}

/// The caps on the gentle reminders, kept as a small device-local record (`AmbientReminderMemory`).
///
/// - Each kind shows at most once a month: once shown on a day it may stay that day, then rests 30 days.
/// - The seasonal kinds share that: one seasonal card a month in all.
/// - At most two reminders on one day (a dismissed one still counts).
/// - "Not now" hides that kind for a month.
///
/// Keys are the kinds' frozen raw values, so an unknown token from a later build is simply ignored.
nonisolated struct AmbientReminderSchedule: Codable, Equatable, Sendable {
    /// The day `shownToday` is about (`yyyy-MM-dd`).
    var dayKey = ""
    /// The kinds shown on `dayKey`, in the order they were first shown.
    var shownToday: [String] = []
    /// When each kind was last shown.
    var lastShown: [String: Date] = [:]
    /// Until when each dismissed kind stays hidden.
    var hiddenUntil: [String: Date] = [:]

    /// At most this many reminders on one day.
    static let dailyLimit = 2
    /// A kind (and the seasonal kinds together) rests this long after showing, and a "Not now" lasts it.
    static let restDays = 30

    /// Picks today's reminders from `candidates` (in priority order) and records what was shown.
    ///
    /// Kinds already shown today stay (unless dismissed); new ones join while the day has room and
    /// their monthly rest is over. Returns the kinds to draw, in `candidates` order.
    mutating func choose(from candidates: [AmbientReminderKind], dayKey: String, now: Date) -> [AmbientReminderKind] {
        assert(!dayKey.isEmpty, "a schedule needs the day it is choosing for")
        roll(to: dayKey)
        for kind in candidates where shownToday.count < Self.dailyLimit && !shownToday.contains(kind.rawValue) {
            guard !isHidden(kind, now: now), isRested(kind, now: now) else { continue }
            shownToday.append(kind.rawValue)
            lastShown[kind.rawValue] = now
        }
        return candidates.filter { shownToday.contains($0.rawValue) && !isHidden($0, now: now) }
    }

    /// Starts a new day's count when `dayKey` is not the day `shownToday` is about.
    mutating func roll(to dayKey: String) {
        guard self.dayKey != dayKey else { return }
        self.dayKey = dayKey
        shownToday = []
    }

    /// "Not now": hides `kind` for a month from `now`.
    mutating func hide(_ kind: AmbientReminderKind, now: Date) {
        hiddenUntil[kind.rawValue] = now.addingTimeInterval(Double(Self.restDays) * 86_400)
    }

    /// Whether `kind` is dismissed until after `now`.
    func isHidden(_ kind: AmbientReminderKind, now: Date) -> Bool {
        guard let until = hiddenUntil[kind.rawValue] else { return false }
        return until > now
    }

    /// Whether `kind` (and, for a seasonal kind, every seasonal kind) has rested a month since showing.
    func isRested(_ kind: AmbientReminderKind, now: Date) -> Bool {
        let rest = Double(Self.restDays) * 86_400
        let group = kind.isSeasonal ? AmbientReminderKind.allCases.filter(\.isSeasonal) : [kind]
        return group.allSatisfy { member in
            guard let shown = lastShown[member.rawValue] else { return true }
            return now.timeIntervalSince(shown) >= rest
        }
    }
}
