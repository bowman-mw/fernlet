import Foundation
import Observation

@MainActor
@Observable
final class BundledFoodSeedingService {
    enum State {
        case notStarted
        case seeding
        case done
        case failed
    }

    private(set) var state: State = .notStarted

    @ObservationIgnored private let loadBundledItems: () async -> [FoodItem]

    init(loadBundledItems: @escaping () async -> [FoodItem] = {
        await Task.detached(priority: .utility) {
            FoodDataCatalog.bundledFoodItems()
        }.value
    }) {
        self.loadBundledItems = loadBundledItems
    }

    func load() async -> [FoodItem] {
        guard state == .notStarted else { return [] }
        state = .seeding
        let items = await loadBundledItems()
        state = .done
        return items
    }
}
