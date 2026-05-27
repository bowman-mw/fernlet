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

    /// Returns the bundled items that are not already present in `existingFoodItems`.
    func ensureSeeded(existing existingFoodItems: [FoodItem]) async -> [FoodItem] {
        guard state == .notStarted else { return [] }
        state = .seeding

        let bundledItems = await loadBundledItems()
        let existingIds = Set(existingFoodItems.map(\.id))
        let newItems = bundledItems.filter { !existingIds.contains($0.id) }
        state = .done
        return newItems
    }
}
