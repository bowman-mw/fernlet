import Foundation
import Testing
@testable import Fernlet

@MainActor
struct BundledFoodSeedingServiceTests {
    @Test func firstCallReturnsBundledItemsAndFinishesDone() async {
        let item1 = makeFoodItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Apple")
        let item2 = makeFoodItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Banana")
        let service = BundledFoodSeedingService(loadBundledItems: {
            [item1, item2]
        })

        let returned = await service.load()

        #expect(service.state == .done)
        #expect(returned == [item1, item2])
    }

    @Test func secondCallAfterDoneReturnsEmptyAndStaysDone() async {
        let bundledItem = makeFoodItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Bundled")
        var loadCount = 0
        let service = BundledFoodSeedingService(loadBundledItems: {
            loadCount += 1
            return [bundledItem]
        })

        let firstItems = await service.load()
        let secondItems = await service.load()

        #expect(firstItems == [bundledItem])
        #expect(secondItems.isEmpty)
        #expect(service.state == .done)
        #expect(loadCount == 1)
    }

    @Test func emptyBundledItemsReturnsEmptyAndFinishesDone() async {
        let service = BundledFoodSeedingService(loadBundledItems: { [] })

        let returned = await service.load()

        #expect(returned.isEmpty)
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
