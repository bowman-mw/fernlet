//
//  SillyStampTests.swift
//  FernletTests
//
//  The silly stats' stamps: a stat earns its stamp the first time it appears, and only a stamp
//  earned since the book began on this device raises a banner; the stamp is never lost (a stat that
//  hides again keeps it, and it is never earned or announced twice); the book is append-only and
//  keeps rows a newer build wrote; stamps are dated from the diary replayed day by day; the stamp
//  ids are frozen tokens; and "Delete everything" takes the whole book.
//

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

// MARK: - Fixtures

private func cookieDay(_ date: String) -> FernletDay {
    FernletDay(date: date, meals: [
        Meal(
            name: "Oatmeal raisin cookies", mealType: .snack, macros: Macros(protein: 0, carbs: 0, fat: 0),
            componentSnapshots: [], mealSource: .manual, quality: .ok, confidence: "logged", note: "", source: "manual"),
    ])
}

private func eggDay(_ date: String) -> FernletDay {
    FernletDay(date: date, meals: [
        Meal(
            name: "2 eggs", mealType: .breakfast, macros: Macros(protein: 0, carbs: 0, fat: 0),
            componentSnapshots: [], mealSource: .manual, quality: .ok, confidence: "logged", note: "", source: "manual"),
    ])
}

private func inputs(_ days: [FernletDay], today: String, pats: Int = 0) -> SillyStatsTallier.Inputs {
    SillyStatsTallier.Inputs(
        days: days, todayKey: today, bottleOunces: 24, healthSteps: nil, pats: pats, unitlessLoadIsPounds: true)
}

/// A private `UserDefaults` suite, emptied first.
private func freshDefaults() -> UserDefaults {
    let suite = "SillyStampTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private let noon = Date(timeIntervalSince1970: 1_791_000_000)

// MARK: - When a stamp is earned

@MainActor
struct SillyStampRuleTests {
    private func award(
        revealed: [SillyStatKind], held: Set<SillyStatKind> = [], start: String?, dated: [SillyStatKind: String] = [:],
        today: String = "2026-10-10"
    ) -> SillyStampRules.Award {
        SillyStampRules.award(
            revealed: revealed, held: held, bookStartDay: start, firstRevealDays: { dated }, todayKey: today, now: noon)
    }

    @Test func aStatAppearingForTheFirstTimeEarnsItsStampAndItsBanner() {
        let result = award(revealed: [.cookiesPerDay], start: "2026-10-01", dated: [.cookiesPerDay: "2026-10-10"])
        #expect(result.entries == [SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-10", createdAt: noon)])
        #expect(result.announced == [.cookiesPerDay])
    }

    @Test func theBooksFirstCheckFilesEverythingAlreadyShowingWithoutABanner() {
        // An update reaching someone with history: their stamps go in under the days they were
        // earned, and nobody gets a dozen banners for things done weeks ago.
        let result = award(revealed: [.cookiesPerDay, .patsGiven], start: nil, dated: [.cookiesPerDay: "2026-09-01"])
        #expect(result.entries.map(\.dayKey) == ["2026-09-01", "2026-10-10"])
        #expect(result.announced.isEmpty)
    }

    @Test func historyThatArrivesAfterTheBookBeganIsFiledQuietly() {
        // A new phone: the book began before iCloud brought the diary down.
        let result = award(revealed: [.eggonomics], start: "2026-10-10", dated: [.eggonomics: "2026-08-03"])
        #expect(result.entries.map(\.dayKey) == ["2026-08-03"])
        #expect(result.announced.isEmpty)
    }

    @Test func aCookieLoggedToYesterdayIsStillNews() {
        let result = award(revealed: [.cookiesPerDay], start: "2026-10-01", dated: [.cookiesPerDay: "2026-10-09"])
        #expect(result.entries.map(\.dayKey) == ["2026-10-09"])
        #expect(result.announced == [.cookiesPerDay])
    }

    @Test func aStatTheDiaryCannotDateIsStampedTodayAndAnnounced() {
        // Pats and Health's lifetime steps carry no dates.
        let result = award(revealed: [.patsGiven], start: "2026-10-01")
        #expect(result.entries.map(\.dayKey) == ["2026-10-10"])
        #expect(result.announced == [.patsGiven])
    }

    @Test func aStampIsNeverDatedAfterToday() {
        let result = award(revealed: [.cookiesPerDay], start: "2026-10-01", dated: [.cookiesPerDay: "2026-12-25"])
        #expect(result.entries.map(\.dayKey) == ["2026-10-10"])
    }

    @Test func aHeldStampIsNeverEarnedAgainAndTheDiaryIsNotReplayed() {
        var replayed = false
        let result = SillyStampRules.award(
            revealed: [.cookiesPerDay], held: [.cookiesPerDay], bookStartDay: "2026-10-01",
            firstRevealDays: { replayed = true; return [:] }, todayKey: "2026-10-10", now: noon)
        #expect(result == SillyStampRules.Award())
        #expect(!replayed)
    }
}

// MARK: - Dating stamps from the diary

@MainActor
struct SillyStampDatingTests {
    @Test func eachStatIsDatedToTheDayItFirstShowed() {
        let days = [FernletDay(date: "2026-10-01"), cookieDay("2026-10-02"), eggDay("2026-10-05"), cookieDay("2026-10-06")]
        let dated = SillyStatsTallier.firstRevealDays(inputs(days, today: "2026-10-10"), calendar: Calendar(identifier: .gregorian))
        #expect(dated[.cookiesPerDay] == "2026-10-02")
        #expect(dated[.eggonomics] == "2026-10-05")
        // Three days from the first day with anything logged, whether or not that day has a record.
        #expect(dated[.gastrotrichLifetimes] == "2026-10-04")
        // Pats carry no dates.
        #expect(dated[.patsGiven] == nil)
    }

    @Test func theCompanionsAgeIsNotDatedBeforeItArrives() {
        let dated = SillyStatsTallier.firstRevealDays(inputs([cookieDay("2026-10-09")], today: "2026-10-10"))
        #expect(dated[.gastrotrichLifetimes] == nil)
    }

    @Test func daysAfterTodayAreNotReplayed() {
        let dated = SillyStatsTallier.firstRevealDays(inputs([cookieDay("2026-10-12")], today: "2026-10-10"))
        #expect(dated[.cookiesPerDay] == nil)
    }
}

// MARK: - The book: append-only, forward-compatible, device-local

@MainActor
struct SillyStampStoreTests {
    @Test func recordingIsAppendOnlyAndTheFirstEarnedRowWins() {
        let store = SillyStampStore(defaults: freshDefaults())
        let first = SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-02", createdAt: noon)
        #expect(store.record([first]) == [first])
        let again = SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-09", createdAt: noon.addingTimeInterval(60))
        #expect(store.record([again]).isEmpty)
        #expect(store.entries() == [first])
    }

    @Test func aRowANewerBuildWroteIsKeptByteForByte() throws {
        let defaults = freshDefaults()
        let future = Data(#"{"id":"stamp:tinyRaft","kind":"tinyRaft","dayKey":"2026-10-01","createdAt":0}"#.utf8)
        defaults.set(["stamp:tinyRaft": future], forKey: "fernlet.sillyStats.stamps")
        let store = SillyStampStore(defaults: defaults)
        #expect(store.entries().isEmpty)
        let cookie = SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-02", createdAt: noon)
        #expect(store.record([cookie]) == [cookie])
        let rows = try #require(defaults.dictionary(forKey: "fernlet.sillyStats.stamps"))
        #expect(rows["stamp:tinyRaft"] as? Data == future)
        #expect(store.entries() == [cookie])
    }

    @Test func theBookKeepsItsFirstDay() {
        let store = SillyStampStore(defaults: freshDefaults())
        #expect(store.startDay == nil)
        store.begin(on: "2026-10-01")
        store.begin(on: "2026-10-05")
        #expect(store.startDay == "2026-10-01")
    }

    @Test func theBookIsCapped() {
        let defaults = freshDefaults()
        var rows: [String: Data] = [:]
        for index in 0..<SillyStampStore.maxRows {
            rows["stamp:future\(index)"] = Data("{}".utf8)
        }
        defaults.set(rows, forKey: "fernlet.sillyStats.stamps")
        let store = SillyStampStore(defaults: defaults)
        #expect(store.record([SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-02", createdAt: noon)]).isEmpty)
    }

    @Test func deleteEverythingTakesTheWholeBook() {
        let defaults = freshDefaults()
        let store = SillyStampStore(defaults: defaults)
        store.begin(on: "2026-10-01")
        #expect(store.record([SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-02", createdAt: noon)]).count == 1)
        SillyStampStore.clearPersistentState(in: defaults)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fernlet.sillyStats.") }.isEmpty)
        #expect(SillyStampStore(defaults: defaults).entries().isEmpty)
    }
}

// MARK: - The service: first reveal, and never lost

@MainActor
struct SillyStampServiceTests {
    private func service(_ defaults: UserDefaults) -> SillyStatsService {
        SillyStatsService(
            pacer: SillyStatsCompanionPacer(defaults: defaults), stampStore: SillyStampStore(defaults: defaults))
    }

    @Test func theFirstCookieEarnsTheCrumbGoblinWithABannerAndALine() {
        let stats = service(freshDefaults())
        stats.update(with: inputs([], today: "2026-10-10"), now: noon)  // the book begins, empty
        #expect(stats.stamps.isEmpty)
        stats.update(with: inputs([cookieDay("2026-10-10")], today: "2026-10-10"), now: noon)
        #expect(stats.stamps.map(\.kind) == [.cookiesPerDay])
        #expect(stats.pendingStampBanners == [.cookiesPerDay])
        #expect(stats.stampLine(todayKey: "2026-10-10", latestJournal: nil) == SillyStampCopy.companionLine(for: .cookiesPerDay))
        // A journal entry written after it, or another day, and the companion moves on.
        #expect(stats.stampLine(todayKey: "2026-10-10", latestJournal: noon.addingTimeInterval(60)) == nil)
        #expect(stats.stampLine(todayKey: "2026-10-11", latestJournal: nil) == nil)
        stats.bannerShown(.cookiesPerDay)
        #expect(stats.pendingStampBanners.isEmpty)
    }

    @Test func aStampIsNeverLostAndNeverEarnedTwice() {
        let defaults = freshDefaults()
        let stats = service(defaults)
        stats.update(with: inputs([], today: "2026-10-10"), now: noon)
        stats.update(with: inputs([cookieDay("2026-10-10")], today: "2026-10-10"), now: noon)
        stats.bannerShown(.cookiesPerDay)

        // The meal is deleted: Cookies Per Day hides again, and the stamp stays.
        stats.update(with: inputs([], today: "2026-10-10"), now: noon.addingTimeInterval(60))
        #expect(stats.revealed.isEmpty)
        #expect(stats.stamps.map(\.kind) == [.cookiesPerDay])

        // A cookie the next day shows the stat again: no second stamp, no second banner.
        stats.update(with: inputs([cookieDay("2026-10-11")], today: "2026-10-11"), now: noon.addingTimeInterval(86_400))
        #expect(stats.stamps == [SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-10", createdAt: noon)])
        #expect(stats.pendingStampBanners.isEmpty)

        // And it is still there after a relaunch.
        #expect(service(defaults).stamps.map(\.kind) == [.cookiesPerDay])
    }

    @Test func anUpdateReachingExistingHistoryRaisesNoBanners() {
        let stats = service(freshDefaults())
        stats.update(with: inputs([cookieDay("2026-09-01"), eggDay("2026-09-02")], today: "2026-10-10", pats: 12), now: noon)
        #expect(stats.stamps.map(\.kind) == [.cookiesPerDay, .eggonomics, .gastrotrichLifetimes, .patsGiven])
        #expect(stats.stamps.map(\.dayKey) == ["2026-09-01", "2026-09-02", "2026-09-03", "2026-10-10"])
        #expect(stats.pendingStampBanners.isEmpty)
        #expect(stats.stampLine(todayKey: "2026-10-10", latestJournal: nil) == nil)
    }

    @Test func clearingForgetsTheBookInMemory() {
        let stats = service(freshDefaults())
        stats.update(with: inputs([], today: "2026-10-10"), now: noon)
        stats.update(with: inputs([cookieDay("2026-10-10")], today: "2026-10-10"), now: noon)
        stats.clear()
        #expect(stats.stamps.isEmpty)
        #expect(stats.pendingStampBanners.isEmpty)
        #expect(stats.stampLine(todayKey: "2026-10-10", latestJournal: nil) == nil)
    }
}

// MARK: - Tokens and names

@MainActor
struct SillyStampTokenTests {
    /// Every stamp's row id and persisted kind are its stat's frozen token, never its name.
    @Test func stampIDsAreFrozenTokens() throws {
        #expect(SillyStatKind.allCases.map(SillyStampEntry.id(for:)) == SillyStatKind.allCases.map { "stamp:\($0.rawValue)" })
        let data = try JSONEncoder().encode(SillyStampEntry(kind: .shakespeareSteps, dayKey: "2026-10-01", createdAt: noon))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""kind":"shakespeareSteps""#))
        #expect(json.contains(#""id":"stamp:shakespeareSteps""#))
    }

    /// One stamp per stat and nothing else: no streak, body weight or calorie stamp can exist.
    @Test func everyStatHasOneOriginalNamedStamp() {
        let english = Locale(identifier: "en_US")
        let names = SillyStatKind.allCases.map { SillyStampCopy.name(for: $0, locale: english) }
        #expect(names == [
            "Crumb Goblin", "Top Banana", "Sunny Side Up", "Slice of Life", "Rubber Duck", "Bean Counter",
            "House Special", "Piano Mover", "Small Step", "Up and Up", "Wheels and Waves", "To Step or Not to Step",
            "Eucalyptus Dreams", "Opening Night", "Floss Boss", "Starting Line", "Encore", "Good Bean",
            "Outlived a Gastrotrich",
        ])
        #expect(Set(names).count == names.count)
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("monster") })
        let lines = SillyStatKind.allCases.map { SillyStampCopy.companionLine(for: $0, locale: english) }
        #expect(Set(lines).count == lines.count && lines.allSatisfy { !$0.isEmpty })
    }

    @Test func theBannerReadsNameThenStat() {
        let english = Locale(identifier: "en_US")
        #expect(SillyStampCopy.bannerTitle(for: .cookiesPerDay, locale: english) == "New stamp: Crumb Goblin")
        #expect(SillyStampCopy.bannerDetail(for: .cookiesPerDay, locale: english) == "Cookies Per Day has begun.")
        #expect(SillyStampCopy.announcement(for: .cookiesPerDay, locale: english) == "New stamp: Crumb Goblin. Cookies Per Day has begun.")
    }
}
