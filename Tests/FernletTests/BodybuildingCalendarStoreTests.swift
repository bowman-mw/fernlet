import Foundation
import Testing
import FernletDomainModel
import DiaryStore
@testable import Fernlet

/// The day calendar on the store (`FernletStore+BodybuildingCalendar`): on only for Bodybuilding, deload
/// weeks saved with the settings, the suggestion's two answers, and a decoy that keeps nothing.
@MainActor
struct BodybuildingCalendarStoreTests {
    /// Wednesday 28 October 2026, noon, on this device's clock.
    static var wednesday: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12)) ?? Date()
    }

    private func makeStore() -> FernletStore {
        let store = makeTestStore(date: Self.wednesday)
        store.settings.selectedGoal = .bodybuilding
        return store
    }

    /// Logs `count` workouts on each of the `weeks` weeks before the current one (Monday to Wednesday).
    private func logHardWeeks(_ weeks: Int, in store: FernletStore) {
        let calendar = store.bodybuildingWeekCalendar
        guard let thisWeek = store.bodybuildingWeekStart() else { return }
        for back in 1...weeks {
            for day in 0..<3 {
                guard let key = BodybuildingWeeks.dayKey(thisWeek, addingDays: -7 * back + day, calendar: calendar) else { continue }
                let workout = BodybuildingDeloadRuleTests.workout()
                let saved = store.diary.mutateDay(date: key) { $0.workouts.append(workout) }
                #expect(saved)
            }
        }
    }

    @Test func theCalendarIsOnOnlyForBodybuilding() {
        let store = makeStore()
        #expect(store.todayKey == "2026-10-28")
        #expect(store.isBodybuildingCalendarOn)
        store.settings.selectedGoal = .strength
        #expect(!store.isBodybuildingCalendarOn)
    }

    @Test func markingADeloadWeekSavesItsMondayAndSwitchingGoalsKeepsIt() {
        let store = makeStore()
        store.markDeloadWeek(start: "2026-10-21", isDeload: true)
        #expect(store.bodybuildingCalendarSettings.deloadWeekStarts == ["2026-10-19"])
        store.settings.selectedGoal = .wellness
        store.settings.selectedGoal = .bodybuilding
        #expect(store.bodybuildingCalendarSettings.deloadWeekStarts == ["2026-10-19"], "nothing is deleted")
        store.markDeloadWeek(start: "2026-10-19", isDeload: false)
        #expect(store.bodybuildingCalendarSettings.deloadWeekStarts.isEmpty)
    }

    @Test func sixHardWeeksSuggestNextWeekAndAcceptMarksIt() {
        let store = makeStore()
        logHardWeeks(6, in: store)
        #expect(store.deloadSuggestion() == "2026-11-02")
        store.acceptDeloadSuggestion()
        #expect(store.bodybuildingCalendarSettings.isDeload(weekStart: "2026-11-02"))
        #expect(store.deloadSuggestion() == nil)
    }

    @Test func notNowHidesTheSuggestion() {
        let store = makeStore()
        logHardWeeks(6, in: store)
        store.declineDeloadSuggestion()
        #expect(store.deloadSuggestion() == nil)
        #expect(store.bodybuildingCalendarSettings.deloadSuggestionDecline?.runLength == 6)
    }

    @Test func anotherGoalGetsNoSuggestion() {
        let store = makeStore()
        logHardWeeks(6, in: store)
        store.settings.selectedGoal = .strength
        #expect(store.deloadSuggestion() == nil)
    }

    @Test func aDecoySessionReadsNoSuggestionAndWritesNothing() {
        let store = makeStore()
        logHardWeeks(6, in: store)
        store.duressSessionActive = true
        #expect(store.deloadSuggestion() == nil)
        store.markDeloadWeek(start: "2026-10-19", isDeload: true)
        store.acceptDeloadSuggestion()
        store.declineDeloadSuggestion()
        #expect(store.bodybuildingCalendarSettings == BodybuildingCalendarSettings())
    }

    @Test func calendarDaysComeFromTheRecordsWithTheSuggestedWeekMarked() {
        let store = makeStore()
        logHardWeeks(6, in: store)
        let keys = BodybuildingWeeks.weekDayKeys(weekStart: "2026-10-19", calendar: store.bodybuildingWeekCalendar)
            + BodybuildingWeeks.weekDayKeys(weekStart: "2026-11-02", calendar: store.bodybuildingWeekCalendar)
        let days = store.calendarDays(for: keys) { key in
            key == "2026-10-20" ? BodybuildingDayInputs(bathroomVisits: 2) : .empty
        }
        #expect(days.count == 14)
        #expect(days[0].trained && days[1].trained && days[2].trained && !days[3].trained)
        #expect(days[1].bathroomVisits == 2)
        #expect(days[7...].allSatisfy { $0.isSuggestedDeload && $0.isFuture })
        #expect(days[0].macroTargets != nil)
    }
}
