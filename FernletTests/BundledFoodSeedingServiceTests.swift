import Foundation
import Testing
@testable import Fernlet

@MainActor
struct BundledFoodSeedingServiceTests {
    @Test func firstCallReturnsBundledItemsMinusExistingAndFinishesDone() async {
        let existing = makeFoodItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Existing")
        let newItem = makeFoodItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "New")
        let service = BundledFoodSeedingService(loadBundledItems: {
            [existing, newItem]
        })

        let returnedItems = await service.ensureSeeded(existing: [existing])

        #expect(service.state == .done)
        #expect(returnedItems == [newItem])
    }

    @Test func secondCallAfterDoneReturnsEmptyAndStaysDone() async {
        let bundledItem = makeFoodItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Bundled")
        var loadCount = 0
        let service = BundledFoodSeedingService(loadBundledItems: {
            loadCount += 1
            return [bundledItem]
        })

        let firstItems = await service.ensureSeeded(existing: [])
        let secondItems = await service.ensureSeeded(existing: [])

        #expect(firstItems == [bundledItem])
        #expect(secondItems.isEmpty)
        #expect(service.state == .done)
        #expect(loadCount == 1)
    }

    @Test func emptyBundledItemsReturnsEmptyAndFinishesDone() async {
        let service = BundledFoodSeedingService(loadBundledItems: { [] })

        let returnedItems = await service.ensureSeeded(existing: [])

        #expect(returnedItems.isEmpty)
        #expect(service.state == .done)
    }

    private func makeFoodItem(id: UUID, name: String) -> FoodItem {
        FoodItem(
            id: id,
            name: name,
            brandSource: nil,
            servingSize: 1,
            servingUnit: "serving",
            macros: Macros(protein: 1, carbs: 2, fat: 3),
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: ["test"]
        )
    }
}
