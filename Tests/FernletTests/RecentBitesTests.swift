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

    // MARK: - Midnight rollover (day T → T+1)

    /// The window where the app is foreground-resident across local midnight: the strip's prior-day fetch
    /// has re-run for T+1, but the store hasn't advanced off T yet — so asking it for T returns the very
    /// row it already handed over as "today", and day T arrives twice. Each of T's photographed meals
    /// would otherwise yield two bites sharing one id, which the strip's `ForEach` identifies by.
    @Test func collapsesTheSameDayArrivingTwiceAcrossMidnight() {
        let today = Date()
        let liveToday = day("T", [photographedMeal(name: "Snapped on T", loggedAt: today)])
        // Offsets 1...6 measured from T+1 → the first is T itself, which `loadDay` answers with the
        // in-memory row; the rest are genuine prior days.
        let asPriorDay = liveToday
        let days = [liveToday, asPriorDay, day("T-1", [photographedMeal(name: "Yesterday", loggedAt: daysAgo(1, from: today))])]

        let bites = RecentBites.recent(from: days, today: today)

        #expect(bites.map(\.name) == ["Snapped on T", "Yesterday"])
        #expect(Set(bites.map(\.id)).count == bites.count)   // ids the ForEach can key on
    }

    /// First row wins when a day key repeats: the caller hands today's live row first, so a meal logged
    /// after the prior-day fetch snapshotted that day still shows.
    @Test func prefersTheFirstRowWhenADayKeyRepeats() {
        let today = Date()
        let breakfast = photographedMeal(
            name: "Breakfast", loggedAt: Calendar.current.date(byAdding: .hour, value: -3, to: today)!)
        let snapshot = day("T", [breakfast])
        let live = day("T", [breakfast, photographedMeal(name: "Lunch just logged", loggedAt: today)])

        let bites = RecentBites.recent(from: [live, snapshot], today: today)

        #expect(bites.map(\.name) == ["Lunch just logged", "Breakfast"])
    }

    /// Once the store advances to T+1, the cached copy of T is what keeps T's meals in the strip — the
    /// keys now differ, so nothing collapses and both days show.
    @Test func keepsBothDaysOnceTheStoreAdvancesPastMidnight() {
        let today = Date()
        let days = [
            day("T+1", [photographedMeal(name: "New day", loggedAt: today)]),
            day("T", [photographedMeal(name: "Snapped on T", loggedAt: daysAgo(1, from: today))]),
        ]

        let bites = RecentBites.recent(from: days, today: today)

        #expect(bites.map(\.name) == ["New day", "Snapped on T"])
    }

    // MARK: - Photo presence classification (Item C: "on your other device")

    @Test func classifyDistinguishesNoPhotoMissingFileAndBrokenFile() {
        // No photo at all → nothing to render, regardless of the file/bytes signals.
        #expect(MealPhotoPresence.classify(hasPhoto: false, sealedFileExists: false, bytesAvailable: false) == .none)
        #expect(MealPhotoPresence.classify(hasPhoto: false, sealedFileExists: true, bytesAvailable: true) == .none)
        // Has a photo, bytes opened → show the picture (file presence is moot once bytes are readable).
        #expect(MealPhotoPresence.classify(hasPhoto: true, sealedFileExists: true, bytesAvailable: true) == .onThisDevice)
        #expect(MealPhotoPresence.classify(hasPhoto: true, sealedFileExists: false, bytesAvailable: true) == .onThisDevice)
        // Has a photo, no openable bytes, NO file here → it lives on the device it was taken on.
        #expect(MealPhotoPresence.classify(hasPhoto: true, sealedFileExists: false, bytesAvailable: false) == .onOtherDevice)
        // Has a photo, no openable bytes, but a file IS here → it's here and broken, not elsewhere.
        #expect(MealPhotoPresence.classify(hasPhoto: true, sealedFileExists: true, bytesAvailable: false) == .unavailable)
    }
}
