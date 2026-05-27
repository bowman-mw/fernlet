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
