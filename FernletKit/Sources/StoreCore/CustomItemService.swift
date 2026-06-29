import Foundation
import Observation
import FernletPersistence
import FernletDomainModel

/// Owns the user's custom-item collection in memory and persists it to its own per-row store (separate
/// from the snapshot blob). Mirrors `SavedRecipeService`: mutations are debounced and flushed via the
/// repository. Equip state is NOT here — it lives in settings (`DiaryStore`) as a tiny UUID map.
@MainActor
@Observable
public final class CustomItemService {
    public private(set) var items: [CustomizationItem] = []

    @ObservationIgnored private let repository: any CustomItemRepositoring
    @ObservationIgnored private var saveScheduled = false

    public init(repository: any CustomItemRepositoring, initialItems: [CustomizationItem] = []) {
        self.repository = repository
        self.items = initialItems
    }

    public func loadSync() {
        items = repository.load()
    }

    public func loadAsync() async {
        items = await repository.loadAsync()
    }

    /// Inserts a new item or replaces the existing one with the same id.
    public func upsert(_ item: CustomizationItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        scheduleSave()
    }

    public func delete(id: UUID) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    public func setShareable(id: UUID, _ shareable: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isShareable = shareable
        scheduleSave()
    }

    public func reset() {
        items = []
        scheduleSave()
    }

    public func flushPendingSave() {
        guard saveScheduled else { return }
        saveScheduled = false
        let saved = repository.save(items)
        assert(saved, "custom items should save")
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            await Task.yield()
            await MainActor.run {
                guard let self else { return }
                self.flushPendingSave()
            }
        }
    }
}
