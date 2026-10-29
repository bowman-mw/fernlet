import Foundation
import Testing
import FernletDomainModel

/// The suggested deload week's rule (`bb-deload-suggest`, owner's answer 1 of 2026-10-29: "Suggest, I
/// decide"): a hard week has three workouts and no deload; six in a row suggest next week; "Not now" waits
/// for two more hard weeks of the same run; a deload resets the run.
struct BodybuildingDeloadRuleTests {
    static let calendar = BodybuildingWeeks.calendar(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    /// Monday 26 October 2026.
    static let current = "2026-10-26"
    /// Monday 2 November 2026, the week after ``current``.
    static let next = "2026-11-02"

    /// The Monday `weeksBack` weeks before ``current`` (0 is ``current``).
    static func week(_ weeksBack: Int) -> String {
        BodybuildingWeeks.dayKey(current, addingDays: -7 * weeksBack, calendar: calendar) ?? ""
    }

    /// Workout counts: `hardWeeks` weeks right before the current one with `perWeek` workouts each, plus
    /// `currentWorkouts` in the current week.
    static func counts(hardWeeks: Int, perWeek: Int = 4, currentWorkouts: Int = 0) -> [String: Int] {
        var counts: [String: Int] = [:]
        for back in 0..<hardWeeks { counts[week(back + 1)] = perWeek }
        if currentWorkouts > 0 { counts[current] = currentWorkouts }
        return counts
    }

    static func suggestion(_ counts: [String: Int], _ settings: BodybuildingCalendarSettings = .init(),
                           currentWeek: String = current) -> String? {
        BodybuildingDeloadRule.suggestion(currentWeek: currentWeek, workoutsByWeek: counts, settings: settings, calendar: calendar)
    }

    static func run(_ counts: [String: Int], deloads: Set<String> = [], currentWeek: String = current) -> BodybuildingDeloadRule.Run {
        BodybuildingDeloadRule.run(currentWeek: currentWeek, workoutsByWeek: counts, deloadWeeks: deloads, calendar: calendar)
    }

    // MARK: - Hard weeks and the run

    @Test func aHardWeekHasThreeWorkoutsAndNoDeload() {
        #expect(BodybuildingDeloadRule.isHard("2026-10-19", workoutsByWeek: ["2026-10-19": 3], deloadWeeks: []))
        #expect(!BodybuildingDeloadRule.isHard("2026-10-19", workoutsByWeek: ["2026-10-19": 2], deloadWeeks: []))
        #expect(!BodybuildingDeloadRule.isHard("2026-10-19", workoutsByWeek: ["2026-10-19": 6], deloadWeeks: ["2026-10-19"]))
    }

    @Test func fiveHardWeeksSuggestNothingSixSuggestNextWeek() {
        #expect(Self.suggestion(Self.counts(hardWeeks: 5)) == nil)
        #expect(Self.suggestion(Self.counts(hardWeeks: 6)) == Self.next)
        #expect(Self.run(Self.counts(hardWeeks: 6)) == .init(start: Self.week(6), length: 6))
    }

    @Test func theCurrentWeekCountsOnceItIsHardAndNeverBreaksTheRunWhileInProgress() {
        // Five finished + a current week that already has three workouts: six.
        #expect(Self.suggestion(Self.counts(hardWeeks: 5, currentWorkouts: 3)) == Self.next)
        // Five finished + a current week with two so far: still five, and the run is not broken.
        #expect(Self.suggestion(Self.counts(hardWeeks: 5, currentWorkouts: 2)) == nil)
        #expect(Self.run(Self.counts(hardWeeks: 5, currentWorkouts: 2)).length == 5)
        #expect(Self.run(Self.counts(hardWeeks: 5, currentWorkouts: 3)) == .init(start: Self.week(5), length: 6))
    }

    @Test func anEasyWeekEndsTheRun() {
        var counts = Self.counts(hardWeeks: 8)
        counts[Self.week(3)] = 2
        #expect(Self.run(counts).length == 2)
        #expect(Self.suggestion(counts) == nil)
    }

    @Test func aDeloadInTheRunResetsIt() {
        var settings = BodybuildingCalendarSettings()
        settings.setDeload(weekStart: Self.week(3), true)
        let counts = Self.counts(hardWeeks: 9)
        #expect(Self.run(counts, deloads: Set(settings.deloadWeekStarts)).length == 2)
        #expect(Self.suggestion(counts, settings) == nil)
    }

    @Test func aCurrentDeloadWeekHoldsNoRun() {
        let counts = Self.counts(hardWeeks: 9, currentWorkouts: 4)
        #expect(Self.run(counts, deloads: [Self.current]) == .init(start: nil, length: 0))
    }

    @Test func nothingIsSuggestedWhenNextWeekIsAlreadyADeload() {
        var settings = BodybuildingCalendarSettings()
        settings.setDeload(weekStart: Self.next, true)
        #expect(Self.suggestion(Self.counts(hardWeeks: 7), settings) == nil)
    }

    // MARK: - Make next week a deload

    @Test func acceptingMarksNextWeekAndTheSuggestionStandsDown() {
        var settings = BodybuildingCalendarSettings()
        settings.deloadSuggestionDecline = BodybuildingDeloadDecline(runStart: Self.week(9), runLength: 6)
        BodybuildingDeloadRule.accept(currentWeek: Self.current, settings: &settings, calendar: Self.calendar)
        #expect(settings.deloadWeekStarts == [Self.next])
        #expect(settings.deloadSuggestionDecline == nil)
        #expect(Self.suggestion(Self.counts(hardWeeks: 8), settings) == nil)
        // When next week comes, it is a deload: the run resets.
        #expect(Self.run(Self.counts(hardWeeks: 8), deloads: [Self.next], currentWeek: Self.next).length == 0)
    }

    // MARK: - Not now

    @Test func notNowWaitsForTwoMoreHardWeeksOfTheSameRun() {
        var settings = BodybuildingCalendarSettings()
        let atDecline = Self.counts(hardWeeks: 6)
        BodybuildingDeloadRule.decline(run: Self.run(atDecline), settings: &settings)
        #expect(settings.deloadSuggestionDecline == BodybuildingDeloadDecline(runStart: Self.week(6), runLength: 6))
        #expect(Self.suggestion(atDecline, settings) == nil, "Not now hides it")
        // +1 hard week: the current week reaches three workouts.
        #expect(Self.suggestion(Self.counts(hardWeeks: 6, currentWorkouts: 3), settings) == nil)
        // +2 hard weeks: a week later, that week finished hard and the new one is hard too.
        var later = Self.counts(hardWeeks: 6)
        later[Self.current] = 4
        later[Self.next] = 3
        let afterNext = BodybuildingWeeks.dayKey(Self.next, addingDays: 7, calendar: Self.calendar)
        #expect(Self.suggestion(later, settings, currentWeek: Self.next) == afterNext)
    }

    @Test func notNowCountsTheDeclineWeekItselfWhenItTurnsHard() {
        var settings = BodybuildingCalendarSettings()
        // Declined with the current week already hard: run 6 = five finished + the current one.
        let atDecline = Self.counts(hardWeeks: 5, currentWorkouts: 3)
        BodybuildingDeloadRule.decline(run: Self.run(atDecline), settings: &settings)
        // Next week, nothing logged yet: the run is still 6.
        var nextWeek = Self.counts(hardWeeks: 5, currentWorkouts: 3)
        #expect(Self.suggestion(nextWeek, settings, currentWeek: Self.next) == nil)
        nextWeek[Self.next] = 3
        // 7: one more hard week. Not yet.
        #expect(Self.suggestion(nextWeek, settings, currentWeek: Self.next) == nil)
        // 8, the week after: two more. It asks again, for the week after that.
        let afterNext = BodybuildingWeeks.dayKey(Self.next, addingDays: 7, calendar: Self.calendar) ?? ""
        nextWeek[afterNext] = 3
        let target = BodybuildingWeeks.dayKey(afterNext, addingDays: 7, calendar: Self.calendar)
        #expect(Self.suggestion(nextWeek, settings, currentWeek: afterNext) == target)
    }

    @Test func aNewRunAfterTheDeclinedOneAsksAtSixAgain() {
        var settings = BodybuildingCalendarSettings()
        settings.deloadSuggestionDecline = BodybuildingDeloadDecline(runStart: Self.week(20), runLength: 9)
        #expect(Self.suggestion(Self.counts(hardWeeks: 6), settings) == Self.next,
                "the declined run broke long ago; this run is new")
    }

    @Test func declineWithNoRunChangesNothing() {
        var settings = BodybuildingCalendarSettings()
        BodybuildingDeloadRule.decline(run: .init(start: nil, length: 0), settings: &settings)
        #expect(settings.deloadSuggestionDecline == nil)
    }

    // MARK: - Counting workouts by week

    @Test func workoutsGroupIntoMondayToSundayWeeks() {
        let sunday = FernletDay(date: "2026-10-25", workouts: [Self.workout(), Self.workout()])
        let monday = FernletDay(date: "2026-10-26", workouts: [Self.workout()])
        let rest = FernletDay(date: "2026-10-27")
        let counts = BodybuildingDeloadRule.workoutsByWeek(
            ["2026-10-25": sunday, "2026-10-26": monday, "2026-10-27": rest], calendar: Self.calendar)
        #expect(counts == ["2026-10-19": 2, "2026-10-26": 1])
    }

    static func workout() -> Workout {
        Workout(name: "Push", type: .upper, exercises: "", rpe: nil, notes: "", duration: 50, intensity: .moderate)
    }
}
