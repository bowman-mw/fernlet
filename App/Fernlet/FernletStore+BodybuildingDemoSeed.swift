//
//  FernletStore+BodybuildingDemoSeed.swift
//  Fernlet
//
//  DEBUG-only: past weeks for the Bodybuilding day calendar's screenshots (World round 7). Run from
//  `seedDemoContent` when `FERNLET_UI_TEST_GOAL=bodybuilding`. Day-record content (workouts with their
//  planned splits, sleep, meals, a quick mood, steps in the device-local Health context), sealed tallies
//  through the BodyTallyStore funnel, and fixture weights held in memory; nothing sent anywhere.
//

#if DEBUG && canImport(UIKit)
import DiaryStore
import FernletDomainModel
import Foundation

extension FernletStore {
    /// How many weeks back the seed reaches (six, so the `suggest` scenario holds six hard weeks).
    static let bodybuildingDemoWeeks = 6

    /// Seeds the past weeks once, then applies the scenario's deload marks on every seeded launch:
    /// `FERNLET_UI_TEST_BB_SCENARIO=suggest` leaves six hard weeks with no deload (the suggestion shows);
    /// anything else marks the week before last as a deload week (no suggestion).
    @MainActor
    func seedBodybuildingDemoWeeks() {
        let calendar = bodybuildingWeekCalendar
        guard let thisWeek = bodybuildingWeekStart(),
              let first = BodybuildingWeeks.dayKey(thisWeek, addingDays: -7 * Self.bodybuildingDemoWeeks, calendar: calendar)
        else { return }
        defer { seedBodybuildingDemoTallies(from: first) }
        var prefs = BodybuildingCalendarSettings()
        prefs.bathroomTileSeeded = settings.bodybuildingCalendar.bathroomTileSeeded
        if UITestSupport.bodybuildingScenario != "suggest",
           let deload = BodybuildingWeeks.dayKey(thisWeek, addingDays: -14, calendar: calendar) {
            prefs.setDeload(weekStart: deload, true)
        }
        settings.bodybuildingCalendar = prefs
        // Idempotent: the first seeded day already holding a workout means an earlier launch seeded them.
        guard loadDay(for: first).workouts.isEmpty else { return }
        for offset in 0..<(7 * Self.bodybuildingDemoWeeks + 7) {
            guard let key = BodybuildingWeeks.dayKey(first, addingDays: offset, calendar: calendar),
                  key < todayKey else { break }
            if !diary.mutateDay(date: key, { Self.fillBodybuildingDemoDay(&$0, index: offset) }) {
                assertionFailure("bodybuilding demo day failed to save")
            }
        }
        flushPendingSnapshotSave()
    }

    /// Seeds the sealed tallies once (one to three bathroom visits a day, a Free meal tag on each Sunday's
    /// first meal, through the BodyTallyStore funnel), and hands the Day calendar fixture weights in place
    /// of Health on every seeded launch. Screenshot data only.
    @MainActor
    private func seedBodybuildingDemoTallies(from first: String) {
        let calendar = bodybuildingWeekCalendar
        let alreadySeeded = bathroomVisits(on: first) > 0
        var weights: [String: Double] = [:]
        for offset in 0..<(7 * Self.bodybuildingDemoWeeks + 7) {
            guard let key = BodybuildingWeeks.dayKey(first, addingDays: offset, calendar: calendar),
                  key <= todayKey else { break }
            weights[key] = 81.4 - Double(offset) * 0.03 + Double((offset * 7) % 9) / 10
            guard !alreadySeeded else { continue }
            setBathroomVisits(1 + (offset * 5) % 3, on: key)
            if offset % 7 == 6, let meal = loadDay(for: key).meals.first {
                setFreeMeal(true, mealID: meal.id, on: key)
            }
        }
        BodyWeightReader.fixtureKilograms = weights
    }

    /// The Move pages `FERNLET_UI_TEST_MOVE_PAGE` pushes: `bb-month` and `bb-week` (the calendar opening on
    /// that view), `bb-signals`, `bb-day` (the deload week's Wednesday, or today's week's Monday). Nil
    /// for any other token, or when the Bodybuilding goal is not on.
    func uiTestMoveRoutes(for token: String?) -> [MoveRoute]? {
        guard let token, isBodybuildingCalendarOn, let thisWeek = bodybuildingWeekStart() else { return nil }
        switch token {
        case "bb-month", "bb-week":
            var prefs = bodybuildingCalendarSettings
            prefs.opensOn = token == "bb-week" ? .week : .month
            bodybuildingCalendarSettings = prefs
            return [.dayCalendar]
        case "bb-signals":
            return [.dayCalendar, .dayCalendarSignals]
        case "bb-day":
            let day = BodybuildingWeeks.dayKey(thisWeek, addingDays: -12, calendar: bodybuildingWeekCalendar) ?? thisWeek
            return [.dayCalendar, .dayCalendarDay(day)]
        default:
            return nil
        }
    }

    /// One seeded day: push, pull, legs, rest in turn, with sleep, steps, meals and a quick mood.
    private static func fillBodybuildingDemoDay(_ day: inout FernletDay, index: Int) {
        let splits: [WorkoutSplit?] = [.push, .pull, .legs, nil]
        if let split = splits[index % splits.count] {
            let plan = PlannedWorkout(name: split.defaultPlanName, split: split, source: .user,
                                      notes: "", duration: 55)
            day.plannedWorkouts.append(plan)
            var workout = plan.completedWorkout
            workout.notes = "Seeded bodybuilding demo workout."
            day.workouts.append(workout)
        }
        let wobble = Double((index * 37) % 23) / 10
        day.sleep = SleepLog(hours: 6.2 + wobble, quality: wobble > 1 ? .good : .ok, note: "")
        var context = day.healthContext ?? HealthDailyContext()
        context.activity = HealthActivitySummary(steps: 6_200 + (index * 911) % 6_000)
        day.healthContext = context
        day.meals.append(contentsOf: bodybuildingDemoMeals(index: index))
        let moods: [FeelingTag] = [.good, .bright, .neutral, .tired, .good]
        day.journals.append(JournalEntry(text: "", tag: moods[index % moods.count], isQuickMood: true))
    }

    /// Three meals with macros that move a little from day to day.
    private static func bodybuildingDemoMeals(index: Int) -> [Meal] {
        let shift = (index * 13) % 20
        let rows: [(String, MealType, Macros)] = [
            ("Oats with whey", .breakfast, Macros(protein: 38 + shift / 2, carbs: 70, fat: 12)),
            ("Chicken rice bowl", .lunch, Macros(protein: 48, carbs: 85 - shift, fat: 16)),
            ("Salmon, potatoes and greens", .dinner, Macros(protein: 42, carbs: 60, fat: 24 + shift / 4)),
        ]
        return rows.map { name, type, macros in
            Meal(name: name, mealType: type, macros: macros, mealSource: .manual, isAIFallback: false, quality: .good,
                 confidence: MealConfidence.logged.token, note: "Seeded bodybuilding demo meal.", source: "manual")
        }
    }
}
#endif
