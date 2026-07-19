import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The pure 7-day window behind Home's "Recent bites" strip: which photographed meals show, in what
/// order, and what gets filtered out.
@MainActor
struct RecentBitesTests {

    /// A meal that carries a photo, logged at `loggedAt`.
    private func photographedMeal(name: String, loggedAt: Date) -> Meal {
        let macros = Macros(protein: 1, carbs: 1, fat: 1)
        var meal = Meal(
            name: name, mealType: .lunch, macros: macros, macroSnapshot: macros,
            calorieSnapshot: 10, micronutrientSnapshot: Micronutrients(),
            quality: .good, confidence: "high", note: "", source: "manual")
        meal.loggedAt = loggedAt
        meal.photoID = UUID()
        return meal
    }

    /// A meal with no photo — should never become a bite.
    private func plainMeal(name: String, loggedAt: Date) -> Meal {
        var meal = photographedMeal(name: name, loggedAt: loggedAt)
        meal.photoID = nil
        return meal
    }

    private func daysAgo(_ n: Int, from today: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: today)!
    }

    private func day(_ key: String, _ meals: [Meal]) -> FernletDay {
        FernletDay(date: key, meals: meals)
    }

    @Test func showsRecentPhotographedMealsNewestFirst() {
        let today = Date()
        let days = [
            day("d0", [photographedMeal(name: "Today", loggedAt: today)]),
            day("d2", [photographedMeal(name: "Two days ago", loggedAt: daysAgo(2, from: today))]),
            day("d5", [photographedMeal(name: "Five days ago", loggedAt: daysAgo(5, from: today))]),
        ]

        let bites = RecentBites.recent(from: days, today: today)

        #expect(bites.map(\.name) == ["Today", "Two days ago", "Five days ago"])
    }

    @Test func excludesMealsOlderThanTheSevenDayWindow() {
        let today = Date()
        // 6 days back is inside a 7-days-inclusive window; 7 and 10 days back are outside it.
        let days = [
            day("inside", [photographedMeal(name: "Inside", loggedAt: daysAgo(6, from: today))]),
            day("edge", [photographedMeal(name: "JustOut", loggedAt: daysAgo(7, from: today))]),
            day("old", [photographedMeal(name: "Old", loggedAt: daysAgo(10, from: today))]),
        ]

        let bites = RecentBites.recent(from: days, today: today)

        #expect(bites.map(\.name) == ["Inside"])
    }

    @Test func excludesMealsWithoutAPhoto() {
        let today = Date()
        let days = [
            day("d0", [
                photographedMeal(name: "Snapped", loggedAt: today),
                plainMeal(name: "Unphotographed", loggedAt: today),
            ]),
        ]

        let bites = RecentBites.recent(from: days, today: today)

        #expect(bites.map(\.name) == ["Snapped"])
    }

    @Test func capsAtTheLimitKeepingTheNewest() {
        let today = Date()
        // Eight photographed meals across today, each an hour apart; the strip caps at six newest.
        let meals = (0..<8).map { i in
            photographedMeal(name: "m\(i)", loggedAt: Calendar.current.date(byAdding: .hour, value: -i, to: today)!)
        }
        let bites = RecentBites.recent(from: [day("d0", meals)], today: today)

        #expect(bites.count == 6)
        #expect(bites.first?.name == "m0")   // newest
        #expect(bites.last?.name == "m5")    // sixth-newest; m6/m7 dropped
    }

    @Test func emptyWhenNoPhotographedMealsInWindow() {
        let today = Date()
        let days = [day("d0", [plainMeal(name: "None", loggedAt: today)])]
        #expect(RecentBites.recent(from: days, today: today).isEmpty)
    }
}
