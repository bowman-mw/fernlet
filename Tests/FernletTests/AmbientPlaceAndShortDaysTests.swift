// AmbientPlaceAndShortDaysTests.swift
// FernletTests
//
// The last two gentle reminders (owner's picks, 2026-11-27): the quiet place (P2-A, P3-B with the
// owner's note, P4-A) and "Short days" (S1-C, S2-A, S3-A). The pure finders with the clock injected,
// the day-length formula against known day lengths, the words, and the device-local quarter.

import Foundation
import Testing
@testable import Fernlet

/// A fixed UTC calendar, so a day boundary never moves with the machine's time zone.
private enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    static let now = date(2026, 12, 10)

    static func daysAgo(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
}

// MARK: - Day length (S3-A)

struct AmbientDaylightTests {
    private func hours(_ latitude: Double, _ month: Int, _ day: Int) -> Double {
        AmbientDaylight.hours(latitude: latitude, on: Fixture.date(2026, month, day), calendar: Fixture.calendar)
    }

    /// Published day lengths, to within ten minutes.
    @Test func knownDayLengths() {
        let tolerance = 10.0 / 60
        #expect(abs(hours(0, 12, 21) - 12.12) < tolerance, "the equator: about 12 h 7 min all year")
        #expect(abs(hours(0, 6, 21) - 12.12) < tolerance)
        #expect(abs(hours(51.5, 12, 21) - 7.83) < tolerance, "London at the December solstice: 7 h 50 min")
        #expect(abs(hours(51.5, 6, 21) - 16.63) < tolerance, "London at the June solstice: 16 h 38 min")
        #expect(abs(hours(59.9, 12, 21) - 5.88) < tolerance, "Oslo in December: 5 h 53 min")
        #expect(abs(hours(-33.9, 6, 21) - 9.88) < tolerance, "Sydney in June: 9 h 53 min")
        #expect(abs(hours(51.5, 3, 20) - 12.2) < 0.25, "around the March equinox, a little over 12 h")
    }

    @Test func polarNightMidnightSunAndThePoles() {
        #expect(hours(69.6, 12, 21) == 0, "Tromsø in December: polar night")
        #expect(hours(69.6, 6, 21) == 24, "Tromsø in June: midnight sun")
        #expect(hours(90, 12, 21) == 0, "the pole never divides by zero")
        #expect(hours(-90, 12, 21) == 24)
        #expect(AmbientDaylight.hours(latitude: .nan, dayOfYear: 10) == 12, "a broken reading is a plain 12 h")
        #expect(AmbientDaylight.hours(latitude: 40, dayOfYear: 9_999) == AmbientDaylight.hours(latitude: 40, dayOfYear: 366))
    }
}

// MARK: - Short nights (S1-C, S2-A)

struct AmbientShortNightsTests {
    /// A usual 8 h for the 28 nights before the last week, then `recent` (newest last) for the last week.
    private func nights(recent: [Double], usual: Double = 8, usualCount: Int = 28) -> [AmbientDatedAmount] {
        let before = (0..<usualCount).map { AmbientDatedAmount(date: Fixture.daysAgo(7 + $0), amount: usual) }
        let week = recent.enumerated().map { AmbientDatedAmount(date: Fixture.daysAgo(recent.count - 1 - $0.offset), amount: $0.element) }
        return before + week
    }

    private func short(_ nights: [AmbientDatedAmount]) -> Bool {
        AmbientShortNights.haveRunShort(nights, now: Fixture.now, calendar: Fixture.calendar)
    }

    @Test func fourShortNightsInAWeekHaveRunShort() {
        #expect(short(nights(recent: [8, 7, 7, 8, 7, 7.5, 8])))
        #expect(!short(nights(recent: [8, 7, 7, 8, 7, 8, 8])), "three short nights are not enough")
        #expect(!short(nights(recent: [7.6, 7.6, 7.6, 7.6, 7.6, 7.6, 7.6])), "under by less than half an hour is usual")
    }

    @Test func noUsualTotalNoCard() {
        #expect(!short(nights(recent: [6, 6, 6, 6, 6, 6, 6], usualCount: 13)), "two weeks of nights before the last are needed")
        #expect(short(nights(recent: [6, 6, 6, 6, 6, 6, 6], usualCount: 14)))
        #expect(!short(nights(recent: [0, 0, 0, 0, 0, 0, 0])), "a zero is no night's sleep, never a short one")
    }

    @Test func theMedianIsTheUsualTotal() {
        #expect(AmbientShortNights.median([7, 9, 8]) == 8)
        #expect(AmbientShortNights.median([6, 8]) == 7)
        #expect(AmbientShortNights.median([]) == nil)
    }
}

// MARK: - The short days card (S1-C, S3-A)

struct AmbientShortDaysFinderTests {
    private let shortNights: [AmbientDatedAmount] = (0..<35).map {
        AmbientDatedAmount(date: Fixture.daysAgo($0), amount: $0 < 7 ? 6 : 8)
    }

    @Test func bothAShortDayAndShortNights() {
        let found = AmbientShortDaysFinder.reminder(latitude: 52, nights: shortNights, now: Fixture.now, calendar: Fixture.calendar)
        #expect(found == AmbientReminder(kind: .shortDays, subject: .shortDays))
    }

    @Test func noLocationALongDayOrUsualSleepSaysNothing() {
        let usual = shortNights.map { AmbientDatedAmount(date: $0.date, amount: 8) }
        #expect(AmbientShortDaysFinder.reminder(latitude: nil, nights: shortNights, now: Fixture.now, calendar: Fixture.calendar) == nil,
                "no location, no card: Home never asks for one")
        #expect(AmbientShortDaysFinder.reminder(latitude: 10, nights: shortNights, now: Fixture.now, calendar: Fixture.calendar) == nil,
                "11+ hours of daylight near the tropics")
        #expect(AmbientShortDaysFinder.reminder(latitude: 52, nights: usual, now: Fixture.now, calendar: Fixture.calendar) == nil)
        let june = Fixture.date(2026, 6, 20)
        let juneNights = shortNights.map { AmbientDatedAmount(date: $0.date.addingTimeInterval(june.timeIntervalSince(Fixture.now)), amount: $0.amount) }
        #expect(AmbientShortDaysFinder.reminder(latitude: 52, nights: juneNights, now: june, calendar: Fixture.calendar) == nil)
        #expect(AmbientShortDaysFinder.reminder(latitude: -34, nights: juneNights, now: june, calendar: Fixture.calendar)?.kind == .shortDays,
                "the southern winter is in June")
    }
}

// MARK: - The quiet place (P2-A, P3-B, P4-A)

struct AmbientQuietPlaceFinderTests {
    private func place(_ kind: AmbientPlaceKind?, label: String? = nil, quietDays: Int, visits: Int = 3) -> AmbientQuietPlace {
        AmbientQuietPlace(id: UUID(), label: label, kind: kind,
                          lastVisitDay: Fixture.calendar.startOfDay(for: Fixture.daysAgo(quietDays)), visits: visits)
    }

    private func pick(_ places: [AmbientQuietPlace], indoorAllowed: Bool = true) -> AmbientReminder? {
        AmbientQuietPlaceFinder.reminder(places, indoorAllowed: indoorAllowed, now: Fixture.now, calendar: Fixture.calendar)
    }

    @Test func aPlaceEnjoyedThreeTimesAndQuietForAMonth() {
        #expect(pick([place(.park, quietDays: 30)]) == AmbientReminder(kind: .quietPlace, subject: .place(label: nil, kind: .park)))
        #expect(pick([place(.park, quietDays: 29)]) == nil, "not quiet long enough")
        #expect(pick([place(.park, quietDays: 30, visits: 2)]) == nil, "not enjoyed often enough")
        #expect(pick([place(.beach, quietDays: 366)]) == nil, "over a year: the person may have moved on")
        #expect(pick([place(nil, quietDays: 90)]) == nil, "nothing to name it by")
    }

    /// The owner's note: restaurants and gyms come up less often than other places.
    @Test func restaurantsAndGymsAreSuggestedLessOften() {
        #expect(pick([place(.gym, quietDays: 45)]) == nil, "a gym waits twice as long")
        #expect(pick([place(.restaurant, quietDays: 60)])?.subject == .place(label: nil, kind: .restaurant))
        #expect(pick([place(.restaurant, quietDays: 60)], indoorAllowed: false) == nil, "at most once a quarter")
        let gym = place(.gym, quietDays: 90, visits: 20)
        let park = place(.park, quietDays: 31, visits: 3)
        #expect(pick([gym, park])?.subject == .place(label: nil, kind: .park), "an outdoor place always comes first")
        #expect(pick([place(nil, label: "Ana's", quietDays: 45)]) == nil, "a place known only by name waits as long as a gym")
        #expect(AmbientQuietPlaceFinder.isIndoor(AmbientReminder(kind: .quietPlace, subject: .place(label: "Ana's", kind: nil))))
        #expect(!AmbientQuietPlaceFinder.isIndoor(AmbientReminder(kind: .quietPlace, subject: .place(label: nil, kind: .beach))))
    }

    @Test func theMostVisitedQuietPlaceIsOffered() {
        let few = place(.park, label: "Laurelhurst", quietDays: 40, visits: 3)
        let many = place(.beach, quietDays: 50, visits: 9)
        #expect(pick([few, many])?.subject == .place(label: nil, kind: .beach))
    }

    @Test func bothNewCardsJoinThePriorityOrder() {
        let nights = (0..<35).map { AmbientDatedAmount(date: Fixture.daysAgo($0), amount: $0 < 7 ? 6 : 8) }
        let found = AmbientReminderFinder.candidates(
            history: AmbientHistory(nights: nights), calmFinishes: [:], hasForgottenMeals: true, hasForgottenWorkout: false,
            now: Fixture.now, southern: false, places: [place(.park, quietDays: 40)], latitude: 52, calendar: Fixture.calendar)
        #expect(found.map(\.kind) == [.forgottenMeal, .shortDays, .quietPlace])
        #expect(!AmbientReminderKind.quietPlace.isSeasonal && !AmbientReminderKind.shortDays.isSeasonal)
    }

    /// The new kinds are appended frozen tokens; no older one moved.
    @Test func theNewTokensAreAppendedAndFrozen() {
        #expect(AmbientReminderKind.quietPlace.rawValue == "quietPlace")
        #expect(AmbientReminderKind.shortDays.rawValue == "shortDays")
        #expect(AmbientReminderKind.allCases.suffix(2) == [.quietPlace, .shortDays])
        #expect(AmbientReminderKind.allCases.prefix(8).map(\.rawValue) == [
            "forgottenMeal", "forgottenWorkout", "forgottenRecipe", "forgottenCalm",
            "seasonalSoup", "seasonalWalks", "seasonalWorkouts", "seasonalWater"
        ])
    }
}

// MARK: - The words

struct AmbientPlaceAndShortDaysCopyTests {
    private func body(label: String? = nil, _ kind: AmbientPlaceKind?) -> String? {
        AmbientReminderCopy.body(for: AmbientReminder(kind: .quietPlace, subject: .place(label: label, kind: kind)))
    }

    @Test func theOwnersDrafts() {
        #expect(body(.park) == "You haven't been to the park in a while. It could be a nice spot today.")
        #expect(AmbientReminderCopy.body(for: AmbientReminder(kind: .shortDays, subject: .shortDays))
                == "Short days and short nights lately. Morning light and an early night might help.")
        #expect(AmbientReminderCopy.title(for: AmbientReminder(kind: .shortDays, subject: .shortDays)) == "Short days")
    }

    /// P4-A: the person's own name first, else the kind word.
    @Test func thePersonsOwnNameComesFirst() {
        #expect(body(label: "Laurelhurst", .park) == "You haven't been to Laurelhurst in a while. It could be a nice spot today.")
        #expect(body(label: "Hoshi's", .restaurant) == "Hoshi's is still there, whenever you feel like it.")
        #expect(body(label: "Ana's", nil) == "Ana's is still there, whenever you feel like it.")
        #expect(body(nil) == nil)
        #expect(body(.restaurant)?.contains("that restaurant") == true || body(.restaurant)?.contains("That restaurant") == true)
        #expect(body(.gym)?.contains("gym") == true)
    }

    /// P3-B: a restaurant's or gym's line never pressures eating or exercise; no line counts.
    @Test func noLinePressuresEatingOrExercise() {
        let pressure: Set<String> = ["eat", "eating", "ate", "food", "meal", "meals", "hungry", "exercise", "workout", "workouts",
                                     "train", "training", "fitness", "fit", "calories", "should", "must", "need"]
        var lines = AmbientPlaceKind.allCases.compactMap { body($0) }
        lines += [body(label: "Hoshi's", .restaurant), body(label: "Iron Den", .gym)].compactMap { $0 }
        lines += AmbientPlaceKind.allCases.compactMap {
            AmbientReminderCopy.title(for: AmbientReminder(kind: .quietPlace, subject: .place(label: nil, kind: $0)))
        }
        for line in lines {
            let words = Set(line.lowercased().split { !$0.isLetter }.map(String.init))
            #expect(words.isDisjoint(with: pressure), "\(line)")
            #expect(!line.contains { $0.isNumber }, "\(line)")
        }
    }

    @Test func outdoorAndIndoorTitles() {
        let park = AmbientReminder(kind: .quietPlace, subject: .place(label: nil, kind: .park))
        let gym = AmbientReminder(kind: .quietPlace, subject: .place(label: nil, kind: .gym))
        #expect(AmbientReminderCopy.title(for: park) == "A favourite spot")
        #expect(AmbientReminderCopy.title(for: gym) == "Still there")
        #expect(AmbientReminderCopy.action(for: park) == nil, "only Not now")
    }
}

// MARK: - The quarter for restaurants and gyms (P3-B)

struct AmbientIndoorPlaceMemoryTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "AmbientIndoorPlaceMemoryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    @Test func aRestaurantOrGymCardRestsAQuarter() {
        let defaults = makeDefaults()
        #expect(AmbientReminderMemory.indoorPlaceRested(now: Fixture.now, in: defaults))
        AmbientReminderMemory.recordIndoorPlaceShown(at: Fixture.now, in: defaults)
        #expect(!AmbientReminderMemory.indoorPlaceRested(now: Fixture.now.addingTimeInterval(89 * 86_400), in: defaults))
        #expect(AmbientReminderMemory.indoorPlaceRested(now: Fixture.now.addingTimeInterval(90 * 86_400), in: defaults))
        AmbientReminderMemory.clearAll(in: defaults)
        #expect(defaults.object(forKey: AmbientReminderMemory.indoorPlaceShownKey) == nil, "Delete everything clears it")
    }

    /// Both new cards ride the Gentle reminders switch: chooseReminders still starts with its guard.
    @Test func theSwitchHidesTheNewCards() throws {
        let cards = try RepoRoot.source("App/Fernlet/AmbientCards.swift")
        let start = try #require(cards.range(of: "private func chooseReminders"))
        let body = cards[start.lowerBound...].prefix(2_000)
        #expect(body.contains("guard store.settings.gentleRemindersEnabled else { return [] }"))
        #expect(body.contains("store.settings.weatherPromptsEnabled ? WeatherKitService.shared.coarseLatitude() : nil"),
                "the latitude is the weather's, only while weather prompts are on")
    }
}
