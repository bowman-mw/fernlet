//
//  MealLogToastRouting.swift
//  Fernlet
//
//  How a food surface hands the meals it just logged to the host's meal-logged toast
//  (`ContentView.showMealLogNotification`), and how a cooking cover holds its meal until it has gone.
//
//  The sounds-and-haptics investigation (2026-10-20, item B1) found six logging paths that confirmed
//  nothing: cooking mode's "Log this meal", the recipe editor's "Log & save", the meal planner's Log
//  pill, the import screen's "already saved" recipe, and Home's forgotten-favorite and nutrient
//  "add it" chips. No toast, no Undo, and nothing for VoiceOver to say. The owner's call the same day:
//  "meal toasts should be added". Every one of them now reports here.
//
//  One of them can log to a day that is not today: a cook that began before midnight logs to the day
//  it began. So the report carries the day, and the toast undoes the meals from the day they went to.
//

import FernletDomainModel

/// The host's meal-logged toast, as the food surfaces that report to it see it.
///
/// Call it with the meals a log just committed. `onMealsLogged([meal])` is a log to today, the common
/// case and every call site that predates back-dated logs. `onMealsLogged([meal], loggedTo: dayKey)` is a
/// log filed on a named day: a cooking run that began before midnight. The day travels to the toast so
/// its Undo removes the meals from the day they went to, and so the toast never passes a meal on another
/// day off as today's.
///
/// A value, not a bare closure, so the two calls read as what they are and ``none`` can stand in at a
/// construction site with no toast host.
struct MealLogReporter {
    /// Hands the meals, and the day they were logged to (`nil` = today), to the toast.
    private let report: ([Meal], String?) -> Void

    /// Creates a reporter around the host's presenter.
    ///
    /// - Parameter report: Receives the logged meals and their day key, `nil` for today.
    init(report: @escaping ([Meal], String?) -> Void) {
        self.report = report
    }

    /// A reporter that reports nowhere: the default for a view built outside a toast host.
    static let none = MealLogReporter { _, _ in }

    /// Reports meals logged to today.
    func callAsFunction(_ meals: [Meal]) {
        report(meals, nil)
    }

    /// Reports meals logged to `dayKey`, which may be a day other than today.
    func callAsFunction(_ meals: [Meal], loggedTo dayKey: String) {
        report(meals, dayKey)
    }

    /// This reporter, followed by `after` once the meals have been handed on.
    ///
    /// The recipe book uses it to close itself when it is a sheet: the toast overlays the tab pages,
    /// so a sheet left standing would hide it, and its Undo, from the person who just logged.
    func then(_ after: @escaping () -> Void) -> MealLogReporter {
        MealLogReporter { meals, dayKey in
            report(meals, dayKey)
            after()
        }
    }
}

/// The meal a cooking cover logged, held until the cover has finished leaving.
///
/// Cooking mode is a full-screen cover, and the meal-logged toast overlays the tab pages beneath it.
/// Raised the moment "Log this meal" is tapped, the toast would spend the start of its window behind the
/// closing cover, and its announcement would race the cover's own dismissal. So the cover's owner holds
/// what the finish screen logged and releases it from the cover's `onDismiss`, once the cover is gone.
///
/// A plain value in the owner's `@State`: ``hold(_:loggedTo:)`` from the cover's log callback,
/// ``release(to:)`` from its `onDismiss`. A cover closed without logging releases nothing.
struct CookedMealHandoff {
    /// The meal the finish screen logged, if it logged one and it has not been released yet.
    private var meal: Meal?
    /// The day key `meal` was logged to: the day the cook began.
    private var dayKey = ""

    /// Holds what the finish screen logged, replacing anything held before.
    ///
    /// - Parameters:
    ///   - meal: The logged meal, or `nil` when the recipe built none (nothing was logged, so nothing
    ///     is confirmed).
    ///   - dayKey: The day the meal was logged to.
    mutating func hold(_ meal: Meal?, loggedTo dayKey: String) {
        self.meal = meal
        self.dayKey = dayKey
    }

    /// Hands the held meal to `reporter` with its day, then forgets it, so a second dismissal cannot
    /// confirm the same meal twice. Holding nothing reports nothing.
    mutating func release(to reporter: MealLogReporter) {
        guard let meal else { return }
        self.meal = nil
        reporter([meal], loggedTo: dayKey)
    }
}
