import Foundation
import Testing
import FernletDomainModel
import DiaryStore
@testable import Fernlet

/// The Day calendar's view-free logic (World round 7, piece C): the free-meal tag of a deleted meal, the
/// month grid's rows with next week drawn in, what each cell and row says to VoiceOver, the suggestion
/// card's visibility, and the weight reader's one value a day.
@MainActor
struct BodybuildingCalendarPageTests {
    /// A Monday-first calendar in UTC, so keys and dates agree whatever the device's zone.
    static let calendar = BodybuildingWeeks.calendar(timeZone: TimeZone(identifier: "UTC") ?? .current)

    /// October 2026 (the 1st is a Thursday).
    static var october: BodybuildingMonthLayout {
        let date = BodybuildingWeeks.date(fromDayKey: "2026-10-15", calendar: calendar) ?? Date()
        return BodybuildingWeeks.monthLayout(containing: date, calendar: calendar)
    }

    /// The seven keys of the week starting on `monday`.
    static func week(_ monday: String) -> [String] {
        BodybuildingWeeks.weekDayKeys(weekStart: monday, calendar: calendar)
    }

    /// A day of the calendar with `body` applied, built in a week context where `deload` is marked.
    static func day(_ key: String, today: String = "2026-10-29", deload: String? = nil,
                    _ body: (inout BodybuildingDay) -> Void = { _ in }) -> BodybuildingDay {
        let context = BodybuildingDayContext(todayKey: today, deloadWeeks: Set([deload].compactMap { $0 }),
                                             suggestedWeek: nil, calendar: calendar)
        var day = BodybuildingDay(emptyOn: key, context: context)
        body(&day)
        return day
    }

    // MARK: Free meals

    @Test func aFreeMealTagShowsOnlyWhileItsMealIsStillLogged() {
        let kept = UUID(), deleted = UUID()
        #expect(BodybuildingCalendarInputs.hasLiveFreeMeal(taggedMealIDs: [kept], loggedMealIDs: [kept]))
        #expect(!BodybuildingCalendarInputs.hasLiveFreeMeal(taggedMealIDs: [deleted], loggedMealIDs: [kept]))
        #expect(!BodybuildingCalendarInputs.hasLiveFreeMeal(taggedMealIDs: [], loggedMealIDs: [kept]))
    }

    @Test func theInputsDropADeletedMealsTagAndAZeroCount() {
        var record = FernletDay(date: "2026-10-20")
        let meal = Meal(name: "Pizza", mealType: .dinner, macros: Macros(protein: 20, carbs: 60, fat: 20),
                        mealSource: .manual, isAIFallback: false, quality: .good,
                        confidence: MealConfidence.logged.token, note: "", source: "manual")
        record.meals = [meal]
        let records = ["2026-10-20": record, "2026-10-21": FernletDay(date: "2026-10-21")]
        let tags = ["2026-10-20": [meal.id], "2026-10-21": [UUID()]]
        let visits = ["2026-10-20": 3, "2026-10-21": 0]
        let live = BodybuildingCalendarInputs.inputs(for: "2026-10-20", bathroomVisits: visits, freeMealTags: tags,
                                                     records: records, weights: ["2026-10-20": 80.5], careScores: ["2026-10-20": 72])
        #expect(live == BodybuildingDayInputs(bathroomVisits: 3, freeMeal: true, weightKilograms: 80.5, careScore: 72))
        let stale = BodybuildingCalendarInputs.inputs(for: "2026-10-21", bathroomVisits: visits, freeMealTags: tags,
                                                      records: records, weights: [:], careScores: [:])
        #expect(stale == .empty, "a tag whose meal was deleted does not show, and zero visits draw no dots")
    }

    @Test func theCareScoreReadsAsAWholePercent() {
        #expect(BodybuildingCalendarInputs.carePercent(0.724) == 72)
        #expect(BodybuildingCalendarInputs.carePercent(1) == 100)
        #expect(BodybuildingCalendarInputs.carePercent(64) == 64)
        #expect(BodybuildingCalendarInputs.carePercent(-0.2) == 0)
        #expect(BodybuildingCalendarInputs.carePercent(.nan) == nil)
    }

    // MARK: The grid

    @Test func nextWeekAfterTheMonthIsARowOfItsOwn() {
        let rows = BodybuildingCalendarGrid.rows(layout: Self.october, extraWeek: Self.week("2026-11-02"))
        #expect(rows.count == Self.october.rows.count + 1)
        #expect(rows.last == Self.week("2026-11-02").map { Optional($0) })
    }

    @Test func nextWeekInsideTheMonthFillsTheBlanksOfItsRow() {
        let rows = BodybuildingCalendarGrid.rows(layout: Self.october, extraWeek: Self.week("2026-10-26"))
        #expect(rows.count == Self.october.rows.count)
        #expect(rows.last?.last == "2026-11-01", "the Sunday after the 31st is drawn for that week")
        let firstCell: String?? = rows.first?.first
        #expect(firstCell == .some(nil), "blanks of other rows stay blank")
    }

    @Test func noExtraWeekLeavesTheMonthAsItIs() {
        #expect(BodybuildingCalendarGrid.rows(layout: Self.october, extraWeek: []) == Self.october.rows)
        let keys = BodybuildingCalendarGrid.visibleKeys(rows: Self.october.rows, weekKeys: Self.week("2026-10-26"))
        #expect(keys.first == "2026-10-01" && keys.last == "2026-11-01" && keys.count == 32)
    }

    @Test func theWeekdayHeadersStartOnMonday() {
        let headers = BodybuildingCalendarCopy.weekdayHeaders(calendar: Self.calendar)
        var named = Self.calendar
        named.locale = .current
        #expect(headers.count == 7)
        #expect(headers.first == named.shortStandaloneWeekdaySymbols[1])
        #expect(headers.last == named.shortStandaloneWeekdaySymbols[0])
    }

    // MARK: Speech

    @Test func aCellReadsItsDayDeloadAndOnlyTheSignalsItDraws() {
        let day = Self.day("2026-10-21", deload: "2026-10-19") {
            $0.trained = true
            $0.trainingName = "Legs"
            $0.sleepHours = 8
            $0.bathroomVisits = 3
            $0.steps = 9_000
        }
        let summary = BodybuildingCalendarSpeech.summary(for: day, signals: [.training, .sleep, .bathroom, .freeMeals],
                                                         calendar: Self.calendar, address: .neutral)
        let placement = BodybuildingCalendarSpeech.placement(of: day)
        #expect(placement.count == 1, "a past day in a deload week: just the deload words")
        let training = BodybuildingCalendarSpeech.spoken(.training, day: day, address: .neutral) ?? ""
        #expect(training.contains("Legs"))
        let expected = [BodybuildingCalendarCopy.dayTitle("2026-10-21", calendar: Self.calendar)] + placement
            + [training, BodybuildingCalendarCopy.sleepSpoken(8), BodybuildingCalendarCopy.bathroomSpoken(3)]
        #expect(summary == expected.joined(separator: ", "))
        #expect(BodybuildingCalendarSpeech.spoken(.freeMeals, day: day, address: .neutral) == nil, "no tag, nothing read")
        #expect(!summary.contains(BodybuildingCalendarCopy.stepsSpoken(9_000)), "steps are not a cell signal here")
    }

    @Test func aDayToComeReadsOnlyWhereItSits() {
        var future = Self.day("2026-11-04")
        future.isSuggestedDeload = true
        let summary = BodybuildingCalendarSpeech.summary(for: future, signals: BodybuildingSignal.allCases,
                                                         calendar: Self.calendar, address: .neutral)
        let placement = BodybuildingCalendarSpeech.placement(of: future)
        #expect(placement.count == 2, "still to come, and the suggested week")
        #expect(summary == ([BodybuildingCalendarCopy.dayTitle("2026-11-04", calendar: Self.calendar)] + placement)
            .joined(separator: ", "))
    }

    @Test func aRestDayWithNothingElseReadsRestAndSkipsTheGaps() {
        let day = Self.day("2026-10-20")
        let summary = BodybuildingCalendarSpeech.summary(for: day, signals: [.training, .sleep, .bathroom],
                                                         calendar: Self.calendar, address: .neutral)
        let rest = BodybuildingCalendarSpeech.spoken(.training, day: day, address: .neutral) ?? ""
        #expect(!rest.isEmpty && summary.hasSuffix(rest))
        #expect(BodybuildingCalendarSpeech.spoken(.sleep, day: day, address: .neutral) == nil)
        #expect(BodybuildingCalendarSpeech.spoken(.bathroom, day: day, address: .neutral) == nil)
    }

    @Test func theDayCardDrawsADashAndReadsNoneForAnEmptySignal() {
        let day = Self.day("2026-10-20") { $0.freeMeal = false }
        let weight = BodybuildingCalendarSpeech.cardValue(.weight, day: day, address: .neutral)
        #expect(weight.shown == "–")
        #expect(!weight.spoken.isEmpty && weight.spoken != "–")
        let free = BodybuildingCalendarSpeech.cardValue(.freeMeals, day: day, address: .neutral)
        #expect(free.shown == free.spoken && free.shown != "–", "the free-meal row always says yes or no")
    }

    @Test func aDeloadDaysTrainingReadsLighter() {
        let day = Self.day("2026-10-21", deload: "2026-10-19") {
            $0.trained = true
            $0.trainingName = "Legs"
        }
        let lighter = BodybuildingCalendarCopy.training(day)
        #expect(lighter.contains("Legs") && lighter != "Legs")
    }

    @Test func heartsCountOnlyWhatIsThere() {
        #expect(BodybuildingDayFeltMark.hearts(for: 0) == 1)
        #expect(BodybuildingDayFeltMark.hearts(for: 41) == 3)
        #expect(BodybuildingDayFeltMark.hearts(for: 100) == 5)
        #expect(BodybuildingDayFeltMark.hearts(for: 250) == 5)
    }

    // MARK: The suggestion card and the store

    @Test func theSuggestionCardShowsOnlyWhileAWeekIsSuggested() {
        var snapshot = BodybuildingCalendarSnapshot.empty
        #expect(!snapshot.showsSuggestionCard)
        snapshot.suggestedWeek = "2026-11-02"
        #expect(snapshot.showsSuggestionCard)
    }

    @Test func theSnapshotDrawsTheSuggestedWeekAfterTheMonthUntilTheChoice() {
        let store = makeTestStore(date: BodybuildingCalendarStoreTests.wednesday)
        store.settings.selectedGoal = .bodybuilding
        logHardWeeks(6, in: store)
        let suggested = store.bodybuildingCalendarSnapshot(weights: [:])
        #expect(suggested.suggestedWeek == "2026-11-02")
        #expect(suggested.gridRows.last?.first == "2026-11-02")
        #expect(suggested.days["2026-11-04"]?.isSuggestedDeload == true)
        #expect(suggested.weekDays.count == 7)
        store.declineDeloadSuggestion()
        let declined = store.bodybuildingCalendarSnapshot(weights: [:])
        #expect(!declined.showsSuggestionCard)
        #expect(declined.gridRows.last?.first != "2026-11-02", "Not now: the dashes go")
    }

    @Test func aDecoySnapshotShowsNoSuggestion() {
        let store = makeTestStore(date: BodybuildingCalendarStoreTests.wednesday)
        store.settings.selectedGoal = .bodybuilding
        logHardWeeks(6, in: store)
        store.duressSessionActive = true
        #expect(!store.bodybuildingCalendarSnapshot(weights: [:]).showsSuggestionCard)
    }

    /// Three workouts on each of the `weeks` weeks before the current one.
    private func logHardWeeks(_ weeks: Int, in store: FernletStore) {
        let calendar = store.bodybuildingWeekCalendar
        guard let thisWeek = store.bodybuildingWeekStart() else { return }
        for back in 1...weeks {
            for day in 0..<3 {
                guard let key = BodybuildingWeeks.dayKey(thisWeek, addingDays: -7 * back + day, calendar: calendar) else { continue }
                let saved = store.diary.mutateDay(date: key) { $0.workouts.append(BodybuildingDeloadRuleTests.workout()) }
                #expect(saved)
            }
        }
    }

    // MARK: Weight

    @Test func weightIsOneAverageADayInsideTheRange() {
        let noon = { (key: String) in
            (BodybuildingWeeks.date(fromDayKey: key, calendar: Self.calendar) ?? Date()).addingTimeInterval(12 * 3_600)
        }
        let samples = [BodyWeightSample(date: noon("2026-10-20"), kilograms: 80),
                       BodyWeightSample(date: noon("2026-10-20").addingTimeInterval(3_600), kilograms: 81),
                       BodyWeightSample(date: noon("2026-10-21"), kilograms: 1_000),
                       BodyWeightSample(date: noon("2026-10-22"), kilograms: 79.94),
                       BodyWeightSample(date: noon("2026-11-30"), kilograms: 79)]
        let days = BodyWeightReader.dailyKilograms(samples, from: "2026-10-01", through: "2026-10-31", calendar: Self.calendar)
        #expect(days == ["2026-10-20": 80.5, "2026-10-22": 79.9])
    }

    @Test func weightLoadsFromTheInjectedSourceAndNothingInADecoy() async {
        let source = CannedWeightSource(readings: [
            BodyWeightSample(date: BodybuildingWeeks.date(fromDayKey: "2026-10-20", calendar: Self.calendar) ?? Date(), kilograms: 82)])
        let read = await BodyWeightReader.load(from: "2026-10-01", through: "2026-10-31", isDecoy: false,
                                               source: source, calendar: Self.calendar)
        #expect(read == ["2026-10-20": 82])
        let decoy = await BodyWeightReader.load(from: "2026-10-01", through: "2026-10-31", isDecoy: true,
                                                source: source, calendar: Self.calendar)
        #expect(decoy.isEmpty)
    }

    @Test func theWeightLineSpansTheMonthLowToHigh() {
        let points = BodybuildingWeightLineGeometry.unitPoints(
            [(key: "2026-10-01", kilograms: 80), (key: "2026-10-31", kilograms: 82)], dayKeys: Self.october.dayKeys)
        #expect(points == [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)])
    }
}

/// A weight source with fixed readings.
@MainActor
struct CannedWeightSource: BodyWeightSampleSource {
    let readings: [BodyWeightSample]

    func samples(from start: Date, through end: Date) async -> [BodyWeightSample] {
        readings.filter { $0.date >= start && $0.date < end }
    }
}
