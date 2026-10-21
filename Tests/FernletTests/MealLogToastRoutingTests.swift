// MealLogToastRoutingTests.swift
// FernletTests
//
// Pins B1 of the sounds-and-haptics investigation (2026-10-20, owner: "meal toasts should be added"):
// every meal-logging path confirms itself with the meal-logged toast (Undo, Adjust and the spoken
// "Meal logged"), and a back-dated log, a cook that began before midnight, is undone from and named
// as the day it went to.
//
// The value halves are tested directly: what a reporter hands on, what a cooking cover holds until it
// has gone, what the toast offers for a log to another day, and the store's day-aware Undo. The view
// wiring is source-pinned, as `MealDataAttributionTests` pins its screens: SwiftUI bodies are not
// inspectable here, and a log that stops reporting to the toast compiles clean. The census at the end
// is a ratchet: a new meal-logging call in the app that hands nothing to the toast fails it.
//
// B9's meal kept without its photo lands on the toast as a caveat: the flag rides the reporter to the
// toast's payload, and the player is asked for one haptic, `caveat` in place of `done`. That chain is
// driven through the player's `perform` seam; that ContentView and the meal sheet are wired to it is
// source-pinned.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletUI
@testable import Fernlet

/// Records every report a ``MealLogReporter`` makes, in order.
@MainActor
private final class ReportLog {
    /// One report: the logged meals' names, the day key it carried (`nil` = today), and whether the
    /// log landed with a caveat.
    struct Report: Equatable {
        let names: [String]
        let dayKey: String?
        var landedWithCaveat = false
    }

    var reports: [Report] = []

    var reporter: MealLogReporter {
        MealLogReporter { [self] meals, dayKey, landedWithCaveat in
            reports.append(Report(names: meals.map(\.name), dayKey: dayKey, landedWithCaveat: landedWithCaveat))
        }
    }
}

/// Records the events a ``FernletFeedback`` was asked to play.
@MainActor
private final class PlayedLog {
    /// Every event that reached the player, in order.
    var events: [FernletFeedbackEvent] = []
    /// ONE player for the log's life.
    lazy var feedback = FernletFeedback(perform: { [unowned self] in events.append($0.event) })
}

@MainActor
@Suite struct MealLogToastRoutingTests {

    private func meal(_ name: String = "Ragù", type: MealType = .dinner) -> Meal {
        Meal(name: name, mealType: type, macros: Macros(protein: 20, carbs: 30, fat: 10),
             quality: .good, confidence: "high", note: "", source: "recipe")
    }

    // MARK: Reporter

    /// The plain call is a log to today; the dated call carries its day to the toast.
    @Test func plainReportIsTodayAndDatedReportCarriesItsDay() {
        let log = ReportLog()
        let reporter = log.reporter
        reporter([meal("Oats")])
        reporter([meal("Stew")], loggedTo: "2026-10-19")

        #expect(log.reports == [
            ReportLog.Report(names: ["Oats"], dayKey: nil),
            ReportLog.Report(names: ["Stew"], dayKey: "2026-10-19")
        ])
    }

    /// `then` hands the meals on first and runs its follow-up after: the book closes once the toast
    /// has its meals, never instead of it.
    @Test func thenRunsAfterTheReport() {
        let log = ReportLog()
        var reportsSeenByFollowUp: [ReportLog.Report] = []
        let reporter = log.reporter.then { reportsSeenByFollowUp = log.reports }
        reporter([meal("Oats")])

        #expect(log.reports.count == 1)
        #expect(reportsSeenByFollowUp == log.reports)
    }

    // MARK: Cooking cover handoff

    /// The finish screen's meal is reported once, with the day the cook began, when the cover goes.
    @Test func cookedMealIsReportedOnceWithItsDayAfterTheCoverGoes() {
        let log = ReportLog()
        var handoff = CookedMealHandoff()
        handoff.hold(meal("Overnight Stew"), loggedTo: "2026-10-19")
        #expect(log.reports.isEmpty)

        handoff.release(to: log.reporter)
        handoff.release(to: log.reporter)

        #expect(log.reports == [ReportLog.Report(names: ["Overnight Stew"], dayKey: "2026-10-19")])
    }

    /// A cover closed without logging, or a recipe that built no meal, confirms nothing.
    @Test func coverClosedWithoutALoggedMealReportsNothing() {
        let log = ReportLog()
        var closedEarly = CookedMealHandoff()
        closedEarly.release(to: log.reporter)

        var builtNothing = CookedMealHandoff()
        builtNothing.hold(nil, loggedTo: "2026-10-20")
        builtNothing.release(to: log.reporter)

        #expect(log.reports.isEmpty)
    }

    // MARK: The toast's payload

    /// A single meal logged to today keeps the toast exactly as it was: Adjust offered, no day named.
    @Test func todayLogOffersAdjustAndNamesNoDay() {
        let logged = meal()
        let notification = MealLogNotification(meals: [logged], dayKey: "2026-10-20", todayKey: "2026-10-20")

        #expect(notification.isLoggedToToday)
        #expect(notification.adjustableMeal == logged)
        #expect(notification.otherLoggedDay == nil)
    }

    /// A cook that began yesterday names yesterday, and offers no Adjust: the correction sheet edits
    /// today's meals only, so it would have saved nothing over the meal it was opened for.
    @Test func backDatedLogNamesItsDayAndOffersNoAdjust() {
        let logged = meal()
        let notification = MealLogNotification(meals: [logged], dayKey: "2026-10-19", todayKey: "2026-10-20")

        #expect(!notification.isLoggedToToday)
        #expect(notification.singleMeal == logged)
        #expect(notification.adjustableMeal == nil)
        #expect(notification.otherLoggedDay == FernletDate.date(fromDayKey: "2026-10-19"))
        #expect(notification.dayKey == "2026-10-19")
    }

    /// Several meals have no single Adjust target, on any day.
    @Test func multiMealLogOffersNoAdjust() {
        let notification = MealLogNotification(meals: [meal("A"), meal("B")], dayKey: "2026-10-20", todayKey: "2026-10-20")
        #expect(notification.adjustableMeal == nil)
    }

    // MARK: The store's day-aware Undo

    private func stewRecipe(in store: FernletStore) -> RecipeDefinition {
        store.addRecipe(
            name: "Overnight Stew",
            servings: 1,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Beef", quantity: 100, unit: "g", protein: 26, carbs: 0, fat: 15)],
            steps: [RecipeStep(text: "Simmer", durationSeconds: 3600)]
        )
    }

    /// Undo of a back-dated cook removes it from the day it went to, and leaves today alone. Today's
    /// `deleteMeal(_:)` alone looked only at today and removed nothing, while the toast said "removed".
    @Test func undoRemovesABackDatedCookFromTheDayItWentTo() throws {
        let store = makeTestStore(date: Date(timeIntervalSince1970: 1_779_664_800))
        let startDay = "2020-01-01"
        #expect(startDay != store.todayKey)
        let recipe = stewRecipe(in: store)
        let cooked = try #require(store.logRecipe(recipe, mealType: .dinner, date: startDay))
        let todays = try #require(store.logRecipe(recipe, mealType: .lunch))

        #expect(store.deleteMeal(cooked, loggedTo: startDay))

        #expect(!store.loadDay(for: startDay).meals.contains { $0.id == cooked.id })
        #expect(store.day.meals.map(\.id) == [todays.id])
    }

    /// Undo of a log to today is today's `deleteMeal(_:)`, unchanged.
    @Test func undoOfATodayLogRemovesItFromToday() throws {
        let store = makeTestStore(date: Date(timeIntervalSince1970: 1_779_664_800))
        let logged = try #require(store.logRecipe(stewRecipe(in: store), mealType: .lunch))

        #expect(store.deleteMeal(logged, loggedTo: store.todayKey))
        #expect(store.day.meals.isEmpty)
    }

    // MARK: Wiring (source pins)

    /// The text of `source` from the first `start` to the first `end` after it, or nil if either is
    /// missing, so a pin reads one function or one button's action rather than the whole file.
    private func region(_ source: String, from start: String, to end: String) -> Substring? {
        guard let lower = source.range(of: start),
              let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else { return nil }
        return source[lower.lowerBound..<upper.upperBound]
    }

    /// Both cooking covers hand their meal to the toast from `onDismiss`, after the cover has gone,
    /// and hold what the finish screen logged until then.
    @Test func theCookingCoversReportAfterTheyHaveGone() throws {
        let food = try RepoRoot.source("App/Fernlet/FoodView.swift")
        #expect(food.contains(".fullScreenCover(isPresented: $showingCookingMode, onDismiss: { cookedMeal.release(to: onMealsLogged) })"),
                "the recipe detail's cooking cover no longer reports its meal when it has gone")
        #expect(food.contains(".fullScreenCover(item: $cookingResume, onDismiss: { cookedMeal.release(to: onMealsLogged) })"),
                "the resume card's cooking cover no longer reports its meal when it has gone")
        #expect(food.components(separatedBy: "cookedMeal.hold(").count - 1 == 2,
                "each cooking cover must hold the meal its finish screen logged")
    }

    /// Every host of a recipe detail passes it a toast route, so a cook started there is confirmed.
    @Test func everyRecipeDetailHostPassesTheToastRoute() throws {
        let food = try RepoRoot.source("App/Fernlet/FoodView.swift")
        let hosts = [
            ("FoodView's recent recipes", "private func recipeDetail(for recipe: RecipeDefinition, isSaved: Bool)", "onMealsLogged: onMealsLogged"),
            ("the import screen's matched recipe", "private func existingRecipeDetail(", "onMealsLogged: onMealsLogged"),
            ("the recipe book", "/// The read-only detail for a recipe-book row", "onMealsLogged: loggedInBook")
        ]
        for (name, start, route) in hosts {
            let body = try #require(region(food, from: start, to: "#endif"), "\(name): detail builder not found")
            #expect(body.contains(route), "\(name) builds a recipe detail without a toast route")
        }
    }

    /// The recipe editor's "Log & save" reports its meal before the save finishes, and the book's
    /// create branch then leaves the spoken confirmation to the toast.
    @Test func logAndSaveReportsItsMeal() throws {
        let food = try RepoRoot.source("App/Fernlet/FoodView.swift")
        let action = try #require(region(food, from: "Button(\"Log & save\") {", to: "finishAfterSave(named: name)"))
        #expect(action.contains("onMealsLogged([meal])"), "\"Log & save\" logs without reporting to the toast")
        #expect(food.contains("onMealsLogged: onMealsLogged.then(onCreatedRecipeLogged)"),
                "the book's create branch no longer learns that \"Log & save\" logged")
        let finish = try #require(region(food, from: "private func finishCreation(named recipeName: String)", to: "announceAfterSheetCloses()"))
        #expect(finish.contains("guard !createdRecipeWasLogged"), "\"Log & save\" would speak two confirmations at once")
    }

    /// The planner's Log pill reports to the toast, and its old inline line (no Undo, never spoken)
    /// is gone; the planner is reached through the book's toast route.
    @Test func plannerLogsThroughTheToast() throws {
        let planner = try RepoRoot.source("App/Fernlet/GroceryPlannerView.swift")
        let logPlanned = try #require(region(planner, from: "private func logPlanned(", to: "\n    }\n"))
        #expect(logPlanned.components(separatedBy: "onMealsLogged(").count - 1 == 2)
        #expect(!planner.contains("loggedRecipeName"), "the planner's inline logged line is back")
        let food = try RepoRoot.source("App/Fernlet/FoodView.swift")
        #expect(food.contains("WeeklyMealPlannerView(store: store, onMealsLogged: loggedInBook)"))
    }

    /// ContentView hands the toast to every surface that logs: Home (for its meal chips), the Food
    /// tab, the Home-presented recipe book and the Home-presented recipe editor.
    @Test func contentViewWiresTheToastToEveryHost() throws {
        let content = try RepoRoot.source("App/Fernlet/ContentView.swift")
        #expect(content.components(separatedBy: "onMealsLogged: mealLogReporter").count - 1 == 4)
        #expect(content.contains("RecipeSheet(store: store, onMealsLogged: mealLogReporter)"))
        let home = try RepoRoot.source("App/Fernlet/HomeView.swift")
        #expect(home.contains("onMealsLogged: onMealsLogged"), "Home no longer passes the toast to its ambient cards")
    }

    // MARK: Landing with a caveat (B9)

    /// The caveat call carries its flag, the plain and dated calls never do, and `then` hands it on.
    @Test func aCaveatReportCarriesItsFlagAndThenHandsItOn() {
        let log = ReportLog()
        let reporter = log.reporter.then {}
        reporter([meal("Oats")])
        reporter([meal("Stew")], loggedTo: "2026-10-19")
        reporter([meal("Toast")], landedWithCaveat: true)
        reporter([meal("Soup")], landedWithCaveat: false)

        #expect(log.reports == [
            ReportLog.Report(names: ["Oats"], dayKey: nil),
            ReportLog.Report(names: ["Stew"], dayKey: "2026-10-19"),
            ReportLog.Report(names: ["Toast"], dayKey: nil, landedWithCaveat: true),
            ReportLog.Report(names: ["Soup"], dayKey: nil)
        ])
    }

    /// The seam end to end: a report reaches the toast's payload the way ContentView builds it (pinned
    /// below), and the player is asked for exactly one notification haptic: `caveat` in place of `done`
    /// for a meal kept without its photo, `done` for every other log.
    @Test func theToastPlaysOneHapticAndACaveatReplacesTheDone() {
        let allOn = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false)
        func landing(_ log: (MealLogReporter) -> Void) -> [FernletFeedbackEvent] {
            let played = PlayedLog()
            let toast = MealLogReporter { meals, dayKey, landedWithCaveat in
                let notification = MealLogNotification(
                    meals: meals, dayKey: dayKey ?? "2026-10-20", todayKey: "2026-10-20",
                    landedWithCaveat: landedWithCaveat)
                played.feedback.play(notification.landingEvent, preferences: allOn)
            }
            log(toast)
            return played.events
        }

        #expect(landing { $0([meal()], landedWithCaveat: true) } == [.caveat])
        #expect(landing { $0.then {}([meal()], landedWithCaveat: true) } == [.caveat])
        #expect(landing { $0([meal()], landedWithCaveat: false) } == [.done])
        #expect(landing { $0([meal()]) } == [.done])
        #expect(landing { $0([meal()], loggedTo: "2026-10-19") } == [.done])
    }

    /// ContentView hands the meal sheet the reporter and plays the payload's one landing haptic; the
    /// meal sheet reports each commit's photo outcome and plays nothing of its own as it stays open on
    /// the notice. A `caveat` there would land in the same instant as the toast's haptic.
    @Test func theMealSheetLeavesItsCaveatToTheToast() throws {
        let content = try RepoRoot.source("App/Fernlet/ContentView.swift")
        #expect(content.contains("MealSheet(store: store, onLogged: mealLogReporter)"),
                "the meal sheet no longer reports through the toast's reporter, so its caveat can't reach the toast")
        let present = try #require(region(content, from: "private func showMealLogNotification(", to: "announceAfterSheetCloses()"))
        #expect(present.contains("landedWithCaveat: landedWithCaveat"), "the toast drops the caveat flag")
        #expect(present.contains("FernletFeedback.system.play(notification.landingEvent)"),
                "the toast no longer lands with the payload's haptic")
        #expect(present.components(separatedBy: "FernletFeedback.system.play(").count - 1 == 1,
                "the toast plays more than its one landing haptic")

        let food = try RepoRoot.source("App/Fernlet/FoodView.swift")
        let close = try #require(region(food, from: "private func closeAfterLogging(photoAttached: Bool) {", to: "\n    }\n"))
        #expect(!close.contains("FernletFeedback"), "the meal sheet plays its own haptic again, beside the toast's")
        let lines = food.components(separatedBy: "\n")
        let closes = lines.indices.filter { lines[$0].contains("closeAfterLogging(photoAttached: photoAttached)") }
        #expect(closes.count >= 4, "found only \(closes.count) of the meal sheet's commit paths")
        for index in closes where index > 0 {
            #expect(lines[index - 1].contains("onLogged(") && lines[index - 1].contains("landedWithCaveat: !photoAttached)"),
                    "FoodView.swift:\(index + 1) closes after a log that never told the toast about its photo")
        }
    }

    // MARK: Census

    /// The store calls that log a meal. A view that calls one must hand the result to the toast.
    private static let mealLoggingCall = #/\bstore\.(logRecipe|logSavedRecipe|addMeal|addResolvedMeals?|commitResolution|copyMeal|logNutrientSuggestionFood|logCatalogFoodItem|logWebImportedFoodProduct|logBarcodeScannedFoodItem|logLabelScannedFoodItem|logHandEnteredMacroMeal)\(/#

    /// What counts as handing a logged meal to the toast near the call: the reporter, the meal
    /// sheet's `onLogged`, or a cooking cover's hold.
    private static let handOffs = ["onMealsLogged(", "onLogged(", "cookedMeal.hold("]

    /// Logging calls that deliberately raise no meal toast, each with the reason. Adding to this list
    /// is a product decision, not a way to make the census pass.
    private static let exemptions: [String: String] = [
        // The day editor (DayDetailView's "Edit day") saves a whole day at once: a journal entry, a
        // meal, a workout, water, sleep and care, usually for a past day, on one Save. None of those
        // fields confirms itself today; a confirmation for the whole save is a separate design.
        "JournalView.swift": "store.addMeal(from: mealTrimmed, date: dateKey)"
    ]

    /// Every meal-logging call in the app hands what it logged to the toast within a few lines, or
    /// returns it from a recipe detail's `onCookLog` (whose cover hands it on; pinned above). A
    /// heuristic window, not a parse: it exists so the next logging path cannot ship silent.
    @Test func everyMealLoggingCallReachesTheToast() throws {
        let appRoot = RepoRoot.url("App")
        let files = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(Self.mealLoggingCall) {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                checked += 1
                if let exempt = Self.exemptions[url.lastPathComponent], line.contains(exempt) { continue }
                let after = lines[index..<min(index + 17, lines.count)].joined(separator: "\n")
                let before = lines[max(0, index - 6)...index].joined(separator: "\n")
                let reported = Self.handOffs.contains { after.contains($0) } || before.contains("onCookLog:")
                #expect(reported, "\(url.lastPathComponent):\(index + 1) logs a meal the toast never hears about")
            }
        }
        #expect(checked >= 25, "the census found only \(checked) logging calls; is it scanning App/?")
    }
}
