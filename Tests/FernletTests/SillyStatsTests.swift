//
//  SillyStatsTests.swift
//  FernletTests
//
//  The silly stats: the cookie table and food matching, the tally fold (tonnage from exercise
//  lines, stairs/swims/rides by activity, sleep, care, days known), the reveal rules (0.1% of the
//  very long trips, everything else as soon as it is logged), the comparison ladders, the copy's
//  grammar, the companion's every-two-or-three-days pacing, and the frozen kind tokens.
//

import Foundation
import Testing
import FernletDomainModel
import LocalPersistence
@testable import Fernlet

// MARK: - Fixtures

private func meal(_ name: String, source: MealSource = .manual, components: [MealComponentSnapshot] = []) -> Meal {
    Meal(
        name: name, mealType: .snack, macros: Macros(protein: 0, carbs: 0, fat: 0),
        componentSnapshots: components, mealSource: source, quality: .ok,
        confidence: "logged", note: "", source: "manual")
}

private func component(_ name: String, _ quantity: Double, _ unit: String) -> MealComponentSnapshot {
    MealComponentSnapshot(
        name: name, quantity: quantity, unit: unit,
        macros: Macros(protein: 0, carbs: 0, fat: 0), micronutrients: Micronutrients())
}

private func workout(_ exercises: String = "", activity: WorkoutActivityType? = nil, minutes: Int? = nil, miles: Double? = nil) -> Workout {
    Workout(
        name: "Session", type: .mixed, activityType: activity, exercises: exercises, rpe: nil, notes: "",
        duration: minutes, distanceMiles: miles, intensity: .moderate)
}

private func inputs(_ days: [FernletDay], today: String = "2026-10-10", steps: Int? = nil, pats: Int = 0) -> SillyStatsTallier.Inputs {
    SillyStatsTallier.Inputs(
        days: days, todayKey: today, bottleOunces: 24, healthSteps: steps, pats: pats, unitlessLoadIsPounds: true)
}

private let english = Locale(identifier: "en_US")

// MARK: - The cookie table

@MainActor
struct SillyCookieTableTests {
    @Test func aServingOfOreosIsThreeHalfCookies() {
        let oreos = meal("Snack", components: [component("Oreo Chocolate Sandwich Cookies", 1, "serving")])
        #expect(SillyFoodCounter.cookieEquivalents(in: oreos) == 1.5)
    }

    @Test func homemadeIsAlwaysOneWholeCookieWhateverItsKind() {
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Grandma's chocolate chip cookies", source: .recipe)) == 1)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Copycat Thin Mints", source: .recipe)) == 1)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Lentil soup", source: .recipe)) == 0)
    }

    @Test func girlScoutCookiesSplitBetweenHalfAndWhole() {
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("2 Thin Mints")) == 1)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("2 Samoas")) == 2)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Do-si-dos")) == 2)  // one serving: 4 × ½
    }

    @Test func theMostSpecificRowWins() {
        #expect(SillyFoodCounter.cookieRule(matching: "Fortune cookie")?.kind == .fortune)
        #expect(SillyFoodCounter.cookieRule(matching: "Giant bakery cookie")?.kind == .giantBakery)
        #expect(SillyFoodCounter.cookieRule(matching: "Oatmeal raisin cookies")?.kind == .standard)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Fortune cookie")) == 0.25)
    }

    @Test func cookieShapedThingsThatAreNotCookiesDoNotCount() {
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Cookie dough ice cream")) == 0)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Cookies & cream milkshake")) == 0)
        #expect(SillyFoodCounter.cookieEquivalents(in: meal("Cookie Crisp cereal")) == 0)
    }

    @Test func weighedCookiesCountByTheirWeight() {
        let thinMints = meal("Snack", components: [component("Thin Mints", 32, "g")])
        #expect(SillyFoodCounter.cookieEquivalents(in: thinMints) == 2)  // 32 g ÷ 8 g × ½
    }

    @Test func oneMealCannotSwampTheTotal() {
        let absurd = meal("Snack", components: [component("Cookie", 1_000_000, "serving")])
        #expect(SillyFoodCounter.cookieEquivalents(in: absurd) == SillyFoodCounter.maxItemsPerMeal)
    }
}

// MARK: - Other foods

@MainActor
struct SillyFoodMatchingTests {
    @Test func wordsMatchWholeWordsNotFragments() {
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.egg, in: meal("Scrambled eggs")) == 1)
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.egg, in: meal("Roasted eggplant")) == 0)
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.egg, in: meal("Veggie wrap")) == 0)
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.cupOfCoffeeOrTea, in: meal("Steak")) == 0)
    }

    @Test func aLeadingNumberIsTheCount() {
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.banana, in: meal("2 bananas")) == 2)
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.egg, in: meal("3 eggs, fried")) == 3)
    }

    @Test func bananaBreadIsNotABanana() {
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.banana, in: meal("Banana bread")) == 0)
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.cupOfCoffeeOrTea, in: meal("Coffee cake")) == 0)
    }

    @Test func componentsOutrankTheMealName() {
        let breakfast = meal("2 egg breakfast", components: [component("Egg, whole", 150, "g")])
        #expect(SillyFoodCounter.items(of: SillyFoodCounter.egg, in: breakfast) == 3)
    }
}

// MARK: - The tally

@MainActor
struct SillyStatsTallyTests {
    @Test func tonnageIsSetsTimesRepsTimesLoadInKilograms() {
        let pounds = SillyStatsTallier.liftedKilograms(line: "Squat 3x8 @135 lb", unitlessLoadIsPounds: false)
        #expect(abs(pounds - 3 * 8 * 135 * 0.45359237) < 0.001)
        #expect(SillyStatsTallier.liftedKilograms(line: "Bench press 3 x 10 @ 60kg", unitlessLoadIsPounds: true) == 1_800)
        // A range reads as its first number; a unitless load follows the locale's unit.
        #expect(SillyStatsTallier.liftedKilograms(line: "Row 4x8-10 @50", unitlessLoadIsPounds: false) == 1_600)
    }

    @Test func linesWithoutALoadMoveNothing() {
        #expect(SillyStatsTallier.liftedKilograms(line: "Bench press - 3 x 8 (RPE 7)", unitlessLoadIsPounds: true) == 0)
        #expect(SillyStatsTallier.liftedKilograms(line: "Push-ups 3xAMRAP", unitlessLoadIsPounds: true) == 0)
        #expect(SillyStatsTallier.liftedKilograms(line: "20 min row", unitlessLoadIsPounds: true) == 0)
    }

    @Test func workoutsLandByActivity() {
        let day = FernletDay(date: "2026-10-01", workouts: [
            workout(activity: .stairClimbing, minutes: 30),
            workout(activity: .swimmingPool, miles: 1),
            workout(activity: .cycling, miles: 10),
            workout(activity: .walking, miles: 2),
            workout(activity: .yoga, minutes: 60, miles: 5),
        ])
        let tally = SillyStatsTallier.tally(inputs([day]))
        #expect(tally.stairMeters == 300)
        #expect(abs(tally.swimKilometers - 1.609344) < 0.0001)
        #expect(abs(tally.cycleKilometers - 16.09344) < 0.0001)
        #expect(abs(tally.workoutFootKilometers - 3.218688) < 0.0001)
    }

    @Test func sleepWaterAndCareAddUp() {
        let rem = HealthDailyContext(body: HealthBodyContext(sleepHours: 7, sleepStages: SleepStagesData(remMinutes: 95)))
        let days = [
            FernletDay(date: "2026-10-01", sleep: SleepLog(hours: 8, quality: .good, note: ""), bottleCount: 2,
                       hygiene: [.teethAM, .teethPM, .floss, .shower]),
            FernletDay(date: "2026-10-02", hygiene: [.teethAM], healthContext: rem),
        ]
        let tally = SillyStatsTallier.tally(inputs(days))
        #expect(tally.sleepHours == 15)
        #expect(tally.remMinutes == 95)
        #expect(abs(tally.waterLiters - 2 * 24 * 0.0295735) < 0.0001)
        #expect(tally.brushCount == 3)
        #expect(tally.flossCount == 1)
        #expect(tally.showerCount == 1)
    }

    @Test func healthStepsWinOverTheDeviceResidueWhenLarger() {
        let residue = HealthDailyContext(activity: HealthActivitySummary(steps: 4_000))
        let day = FernletDay(date: "2026-10-01", healthContext: residue)
        #expect(SillyStatsTallier.tally(inputs([day], steps: 90_000)).steps == 90_000)
        #expect(SillyStatsTallier.tally(inputs([day], steps: nil)).steps == 4_000)
    }

    @Test func daysKnownCountsFromTheFirstLoggedDayInclusive() {
        let days = [
            FernletDay(date: "2026-09-30"),  // nothing logged: does not start the clock
            FernletDay(date: "2026-10-01", bottleCount: 1),
        ]
        #expect(SillyStatsTallier.daysKnown(days: days, todayKey: "2026-10-10") == 10)
        #expect(SillyStatsTallier.daysKnown(days: [], todayKey: "2026-10-10") == 1)
    }

    @Test func theSignatureDishIsTheMostLoggedRecipe() {
        let days = [FernletDay(date: "2026-10-01", meals: [
            meal("Banana bread", source: .recipe), meal("banana bread ", source: .recipe),
            meal("Banana Bread", source: .recipe), meal("Chili", source: .recipe), meal("Toast"),
        ])]
        let dish = SillyStatsTallier.tally(inputs(days)).signatureDish
        #expect(dish?.count == 3)
        #expect(dish?.name.lowercased() == "banana bread")
    }
}

// MARK: - Reveal rules and ladders

@MainActor
struct SillyStatsRevealTests {
    @Test func nothingShowsOnAnEmptyTally() {
        #expect(SillyStatsEngine.revealed(in: SillyStatsTally()).isEmpty)
    }

    @Test func theMoonWaitsForATenthOfAPercent() {
        var tally = SillyStatsTally()
        tally.workoutFootKilometers = 384
        #expect(!SillyStatsEngine.isRevealed(.moonwalk, in: tally))
        tally.workoutFootKilometers = 384.4
        #expect(SillyStatsEngine.isRevealed(.moonwalk, in: tally))
        // Steps alone get there too: 504,500 steps at 0.762 m is just over 384.4 km.
        var walker = SillyStatsTally()
        walker.steps = 504_500
        #expect(SillyStatsEngine.isRevealed(.moonwalk, in: walker))
    }

    @Test func grandToursWaitForATenthOfAPercentOfEitherRoute() {
        var tally = SillyStatsTally()
        tally.cycleKilometers = 3.3
        #expect(!SillyStatsEngine.isRevealed(.grandTours, in: tally))
        tally.cycleKilometers = 3.4
        #expect(SillyStatsEngine.isRevealed(.grandTours, in: tally))
        var swimmer = SillyStatsTally()
        swimmer.swimKilometers = 0.04
        #expect(SillyStatsEngine.isRevealed(.grandTours, in: swimmer))
    }

    @Test func everyDayStatsShowAsSoonAsSomethingIsLogged() {
        var tally = SillyStatsTally()
        tally.cookieEquivalents = 0.5
        tally.showerCount = 1
        tally.pats = 1
        #expect(SillyStatsEngine.revealed(in: tally) == [.cookiesPerDay, .showerConcerts, .patsGiven])
    }

    @Test func slowStatsWaitForTheirFirstWholeUnit() {
        var tally = SillyStatsTally()
        tally.sleepHours = 19
        tally.remMinutes = 119
        tally.daysKnown = 2
        tally.steps = 30_000
        tally.signatureDish = SillySignatureDish(name: "Chili", count: 2)
        #expect(SillyStatsEngine.revealed(in: tally).isEmpty)
        tally.sleepHours = 20
        tally.remMinutes = 120
        tally.daysKnown = 3
        tally.steps = 30_557
        tally.signatureDish?.count = 3
        #expect(SillyStatsEngine.revealed(in: tally) == [.signatureDish, .shakespeareSteps, .koalaDays, .dreamCinema, .gastrotrichLifetimes])
    }

    @Test func theLadderPicksTheLargestUnitReached() {
        #expect(SillyStatsEngine.comparison(720, ladder: SillyStatsEngine.massLadder) == SillyComparison(unit: .grandPiano, count: 1.6))
        #expect(SillyStatsEngine.comparison(12, ladder: SillyStatsEngine.massLadder) == SillyComparison(unit: .goldenRetriever, count: 0.4))
        #expect(SillyStatsEngine.comparison(-1, ladder: SillyStatsEngine.massLadder) == nil)
    }

    @Test func cpdIsCookiesOverDaysKnown() {
        var tally = SillyStatsTally()
        tally.cookieEquivalents = 6
        tally.daysKnown = 8
        #expect(SillyStatsEngine.cookiesPerDay(tally) == 0.75)
    }
}

// MARK: - Copy

@MainActor
struct SillyStatsCopyTests {
    @Test func nounsAgreeWithTheirCounts() {
        #expect(SillyStatsCopy.phrase(SillyComparison(unit: .grandPiano, count: 1), locale: english) == "1 grand piano")
        #expect(SillyStatsCopy.phrase(SillyComparison(unit: .grandPiano, count: 1.6), locale: english) == "1.6 grand pianos")
        #expect(SillyStatsCopy.phrase(SillyComparison(unit: .statueOfLiberty, count: 2), locale: english) == "2 Statues of Liberty")
    }

    @Test func everyRevealedStatHasEveryLine() {
        var tally = SillyStatsTally()
        tally.daysKnown = 30
        tally.cookieEquivalents = 12
        tally.bananas = 9
        tally.eggs = 40
        tally.pizzaSlices = 19
        tally.waterLiters = 60
        tally.coffeeCups = 50
        tally.signatureDish = SillySignatureDish(name: "Chili", count: 4)
        tally.liftedKilograms = 5_000
        tally.steps = 600_000
        tally.stairMeters = 400
        tally.swimKilometers = 2
        tally.cycleKilometers = 100
        tally.sleepHours = 240
        tally.remMinutes = 3_000
        tally.flossCount = 20
        tally.brushCount = 60
        tally.showerCount = 25
        tally.pats = 212
        tally.furthestFromHomeMeters = 8_400_000
        #expect(SillyStatsEngine.revealed(in: tally) == SillyStatKind.allCases)
        for kind in SillyStatKind.allCases {
            let text = SillyStatsCopy.text(for: kind, tally: tally, locale: english)
            #expect(!text.title.isEmpty && !text.headline.isEmpty && !text.detail.isEmpty, "\(kind)")
            #expect(!text.companionLine.isEmpty && !text.footnote.isEmpty, "\(kind)")
        }
        #expect(SillyStatsCopy.text(for: .cookiesPerDay, tally: tally, locale: english).headline == "0.40 CPD")
    }
}

// MARK: - Companion pacing

@MainActor
struct SillyStatsCompanionPacerTests {
    private func pacer() -> (SillyStatsCompanionPacer, UserDefaults) {
        let suite = "SillyStatsCompanionPacerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return (SillyStatsCompanionPacer(defaults: defaults, calendar: Calendar(identifier: .gregorian)), defaults)
    }

    private let candidates: [(kind: SillyStatKind, value: Double)] = [
        (.cookiesPerDay, 3), (.showerConcerts, 10), (.patsGiven, 40),
    ]

    @Test func aMentionRepeatsForTheRestOfItsDay() {
        let (pacer, _) = pacer()
        let first = pacer.mention(from: candidates, todayKey: "2026-10-01", isQuietDay: false)
        #expect(first != nil)
        #expect(pacer.mention(from: candidates, todayKey: "2026-10-01", isQuietDay: false) == first)
    }

    @Test func mentionsComeTwoOrThreeDaysApartAndNeverRepeatAStat() {
        let (pacer, _) = pacer()
        var mentions: [(day: Int, kind: SillyStatKind)] = []
        var values = candidates
        for day in 1...30 {
            let key = String(format: "2026-10-%02d", day)
            // Every number moves every day, so only the cadence and the no-repeat rule hold mentions back.
            values = values.map { ($0.kind, $0.value + 1) }
            if let kind = pacer.mention(from: values, todayKey: key, isQuietDay: false) {
                mentions.append((day, kind))
            }
        }
        #expect(mentions.count >= 9)
        for (previous, next) in zip(mentions, mentions.dropFirst()) {
            #expect(SillyStatsCompanionPacer.gapDays.contains(next.day - previous.day))
            #expect(previous.kind != next.kind)
        }
    }

    @Test func aQuietDayUsesNothingUp() {
        let (pacer, _) = pacer()
        #expect(pacer.mention(from: candidates, todayKey: "2026-10-01", isQuietDay: true) == nil)
        #expect(pacer.mention(from: candidates, todayKey: "2026-10-01", isQuietDay: false) != nil)
    }

    @Test func aStatWhoseNumberHasNotMovedIsNotMentionedAgain() {
        let (pacer, _) = pacer()
        let only: [(kind: SillyStatKind, value: Double)] = [(.patsGiven, 40), (.showerConcerts, 10)]
        let first = pacer.mention(from: only, todayKey: "2026-10-01", isQuietDay: false)
        let second = pacer.mention(from: only, todayKey: "2026-10-04", isQuietDay: false)
        #expect(first != nil && second != nil && first != second)
        // Neither number moved, so a third mention has nothing new to say.
        #expect(pacer.mention(from: only, todayKey: "2026-10-08", isQuietDay: false) == nil)
    }

    @Test func clearingForgetsEverything() {
        let (pacer, defaults) = pacer()
        _ = pacer.mention(from: candidates, todayKey: "2026-10-01", isQuietDay: false)
        SillyStatsCompanionPacer.clearPersistentState(in: defaults)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fernlet.sillyStats.") }.isEmpty)
    }

    @Test func quietDaysFollowTheFrozenSignalVocabulary() {
        let rest = DerivedSignalRecord(signalName: "intensityReadiness", value: "needs rest", windowStart: "", windowEnd: "", sourceFields: [])
        let calm = DerivedSignalRecord(signalName: "moodTrend", value: "steady", windowStart: "", windowEnd: "", sourceFields: [])
        #expect(SillyStatsService.isQuietDay(signals: [rest]))
        #expect(!SillyStatsService.isQuietDay(signals: [calm]))
    }
}

// MARK: - Frozen tokens and the widget migration

@MainActor
struct SillyStatsTokenTests {
    /// The pacer persists these under device-local keys; renaming one makes the companion forget
    /// what it last said.
    @Test func frozenKindTokens() {
        #expect(SillyStatKind.allCases.map(\.rawValue) == [
            "cookiesPerDay", "bananasForScale", "eggonomics", "pizzaPieChart", "bathtubIndex", "coffeeTower",
            "signatureDish", "totalTonnage", "moonwalk", "stairwayToSomewhere", "grandTours", "furthestFromHome", "shakespeareSteps",
            "koalaDays", "dreamCinema", "flossRope", "brushMarathon", "showerConcerts", "patsGiven",
            "gastrotrichLifetimes",
        ])
        #expect(HomeWidget.sillyStats.rawValue == "sillyStats")
    }

    @Test func theSillyStatsWidgetIsAppendedOnceForExistingUsers() throws {
        let legacy = Data("""
        {"didMigrateMilestonesFirstAidWidgets": true, "didMigrateMealPhotosWidget": true,
         "homeWidgets": ["companion", "macros"]}
        """.utf8)
        let settings = try JSONDecoder().decode(FernletSettings.self, from: legacy)
        #expect(settings.homeWidgets == [.companion, .macros, .sillyStats])
        #expect(settings.didMigrateSillyStatsWidget)

        var edited = settings
        edited.homeWidgets = [.companion, .macros]
        let reloaded = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(edited))
        #expect(reloaded.homeWidgets == [.companion, .macros])
    }

    @Test func thePizzaShowsTheSlicesOfThePizzaInProgress() {
        #expect(SillyPizzaPie.slicesOnCurrentPizza(0) == 0)
        #expect(SillyPizzaPie.slicesOnCurrentPizza(3) == 3)
        #expect(SillyPizzaPie.slicesOnCurrentPizza(8) == 8)
        #expect(SillyPizzaPie.slicesOnCurrentPizza(19.5) == 3)
    }
}
