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
//  A log can also land with something to read beside it: the meal sheet keeps a meal whose photo
//  couldn't be sealed, and says so (B9). The report carries that too, and the toast plays `caveat` in
//  place of its `done`. The sheet used to play its own `caveat` right after the toast's `done`: two
//  notification haptics in one instant, felt as a blur rather than as what happened.
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
/// `onLogged(meals, landedWithCaveat: true)` is a log to today that kept something the person needs to
/// read beside it: the meal sheet's photo that couldn't be sealed. The toast then lands with `caveat`
/// instead of `done`, so the log is felt once, as what it was.
///
/// A value, not a bare closure, so the calls read as what they are and ``none`` can stand in at a
/// construction site with no toast host.
struct MealLogReporter {
    /// Hands the meals, the day they were logged to (`nil` = today), and whether they landed with a
    /// caveat, to the toast.
    private let report: ([Meal], String?, Bool) -> Void

    /// Creates a reporter around the host's presenter.
    ///
    /// - Parameter report: Receives the logged meals, their day key (`nil` for today), and whether
    ///   they landed with something the person needs to read beside them.
    init(report: @escaping ([Meal], String?, Bool) -> Void) {
        self.report = report
    }

    /// A reporter that reports nowhere: the default for a view built outside a toast host.
    static let none = MealLogReporter { _, _, _ in }

    /// Reports meals logged to today.
    func callAsFunction(_ meals: [Meal]) {
        report(meals, nil, false)
    }

    /// Reports meals logged to `dayKey`, which may be a day other than today.
    func callAsFunction(_ meals: [Meal], loggedTo dayKey: String) {
        report(meals, dayKey, false)
    }

    /// Reports meals logged to today that landed with a caveat when `landedWithCaveat` is true: the log
    /// stands, and the reporting surface shows a line about what didn't (the meal sheet's photo that
    /// couldn't be sealed). The toast then plays `caveat` in place of its `done`, so the surface plays
    /// nothing of its own.
    func callAsFunction(_ meals: [Meal], landedWithCaveat: Bool) {
        report(meals, nil, landedWithCaveat)
    }

    /// This reporter, followed by `after` once the meals have been handed on.
    ///
    /// The recipe book uses it to close itself when it is a sheet: the toast overlays the tab pages,
    /// so a sheet left standing would hide it, and its Undo, from the person who just logged.
    func then(_ after: @escaping () -> Void) -> MealLogReporter {
        MealLogReporter { meals, dayKey, landedWithCaveat in
            report(meals, dayKey, landedWithCaveat)
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
