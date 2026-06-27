import Foundation
import Testing
@testable import Fernlet

@MainActor
struct AIRetryQueueServiceTests {

    private func makeRecord(payloadType: String = "meal") -> AIAnalysisRetryRecord {
        AIAnalysisRetryRecord(payloadType: payloadType, sourceId: UUID(), note: "test")
    }

    private func makeMeal(name: String = "Test Meal", mealType: MealType = .lunch) -> Meal {
        let macros = Macros(protein: 10, carbs: 20, fat: 5)
        return Meal(
            name: name,
            mealType: mealType,
            macros: macros,
            macroSnapshot: macros,
            calorieSnapshot: 165,
            micronutrientSnapshot: Micronutrients(),
            quality: .good,
            confidence: "high",
            note: "",
            source: "manual"
        )
    }

    @Test func queueMealRetryAppendsRecord() {
        let service = AIRetryQueueService()
        let meal = makeMeal(name: "Test", mealType: .lunch)
        service.queueMealRetry(meal)

        #expect(service.retryQueue.count == 1)
        #expect(service.retryQueue[0].payloadType == "meal")
        #expect(service.retryQueue[0].sourceId == meal.id)
        #expect(service.pendingCount == 1)
    }

    /// Regression for prior finding #7: the queued record carries the meal's day so
    /// retryOldestMeal can resolve a back-filled (non-today) meal on its own date instead of
    /// failing to find it in today's meals and silently discarding the retry.
    @Test func queueMealRetryRecordsDayKey() {
        let service = AIRetryQueueService()
        let meal = makeMeal()
        service.queueMealRetry(meal, dayKey: "2026-05-20")

        #expect(service.retryQueue.first?.dayKey == "2026-05-20")
    }

    /// Regression for prior finding #16: stale records are aged out so they don't occupy slots
    /// indefinitely. The first record is created at the real wall clock; advancing the injected
    /// clock past the 14-day TTL prunes it on the next enqueue.
    @Test func staleRecordsAreAgedOutOnNextEnqueue() {
        let service = AIRetryQueueService(now: { Date().addingTimeInterval(20 * 24 * 60 * 60) })
        let stale = makeMeal(name: "Stale")
        let fresh = makeMeal(name: "Fresh")
        service.queueMealRetry(stale)
        service.queueMealRetry(fresh)

        #expect(service.retryQueue.count == 1)
        #expect(service.retryQueue.first?.sourceId == fresh.id)
    }

    /// On overflow the queue stays at the cap, evicting the oldest (the newest is retained).
    @Test func overflowStaysAtCapEvictingOldest() {
        let service = AIRetryQueueService()
        var meals: [Meal] = []
        for i in 0..<21 {
            let meal = makeMeal(name: "m\(i)")
            meals.append(meal)
            service.queueMealRetry(meal)
        }

        #expect(service.retryQueue.count == 20)
        #expect(!service.retryQueue.contains { $0.sourceId == meals[0].id })
        #expect(service.retryQueue.contains { $0.sourceId == meals[20].id })
    }

    /// Records persisted before `dayKey` existed must still decode (optional field → nil).
    @Test func legacyRecordWithoutDayKeyDecodes() throws {
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","payloadType":"meal",\
        "sourceId":"00000000-0000-0000-0000-000000000002","createdAt":0,\
        "attemptCount":0,"note":"legacy"}
        """
        let record = try JSONDecoder().decode(AIAnalysisRetryRecord.self, from: Data(legacyJSON.utf8))
        #expect(record.dayKey == nil)
        #expect(record.note == "legacy")
    }

    @Test func clearByIdRemovesMatchingRecord() {
        let service = AIRetryQueueService()
        let meal = makeMeal(name: "Lunch", mealType: .lunch)
        service.queueMealRetry(meal)
        let id = service.retryQueue[0].id

        service.clear(id: id)
        #expect(service.retryQueue.isEmpty)
    }

    @Test func clearWithUnknownIdIsNoOp() {
        let service = AIRetryQueueService()
        let meal = makeMeal(name: "Dinner", mealType: .dinner)
        service.queueMealRetry(meal)

        service.clear(id: UUID())
        #expect(service.retryQueue.count == 1)
    }

    @Test func onChangeCalledExactlyOncePerMutation() {
        var callCount = 0
        let service = AIRetryQueueService(onChange: { callCount += 1 })
        let meal = makeMeal(name: "Snack", mealType: .snack)

        service.queueMealRetry(meal)
        #expect(callCount == 1)

        let id = service.retryQueue[0].id
        service.clear(id: id)
        #expect(callCount == 2)
    }

    @Test func applyReplacesQueueAtomically() {
        let service = AIRetryQueueService()
        let meal = makeMeal(name: "Breakfast", mealType: .breakfast)
        service.queueMealRetry(meal)

        let newRecords = [makeRecord(), makeRecord()]
        service.apply(newRecords)

        #expect(service.retryQueue.count == 2)
        #expect(service.retryQueue[0].id == newRecords[0].id)
    }

    @Test func resetClearsQueue() {
        let service = AIRetryQueueService()
        let meal = makeMeal(name: "Snack", mealType: .snack)
        service.queueMealRetry(meal)
        service.reset()
        #expect(service.retryQueue.isEmpty)
    }

    @Test func initializesWithInitialData() {
        let records = [makeRecord(), makeRecord()]
        let service = AIRetryQueueService(initial: records)
        #expect(service.retryQueue.count == 2)
        #expect(service.pendingCount == 2)
    }
}
