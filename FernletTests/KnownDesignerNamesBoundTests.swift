import Foundation
import Testing
import FernletDomainModel
import LocalPersistence
import CloudKitSync
import DiaryStore
@testable import Fernlet

/// Finding B regression: `knownDesignerNames` is fed purely by BROWSING a peer's shop (no purchase
/// required — the view learns id→name on appear and on every catalog-count change), and it lands in the
/// SYNCED settings blob. The setter caps each name's length but placed NO bound on the map's CARDINALITY,
/// so a hostile peer cycling disconnect/reconnect with a fresh random designerID each time added one
/// permanent entry per cycle, growing the synced aggregate toward CloudKit's ~1 MB per-record limit until
/// snapshot saves fail. The setter must bound the map, keep real friends, and never grow on updates.
@MainActor
struct KnownDesignerNamesBoundTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func learningMoreThanTheCapStaysBounded() {
        let store = makeShopStore()
        let cap = DiaryStore.maxKnownDesignerNames

        // A hostile peer cycles fresh random designer ids far past the cap.
        for i in 0..<(cap + 200) {
            store.learnDesignerName(id: UUID(), name: "Peer \(i)")
        }

        #expect(store.settings.knownDesignerNames.count == cap)             // bounded, not unbounded growth
    }

    @Test func updatingAnExistingIdDoesNotGrowOrEvict() {
        let store = makeShopStore()
        let cap = DiaryStore.maxKnownDesignerNames

        // Fill exactly to the cap with stable ids we keep references to.
        let ids = (0..<cap).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            store.learnDesignerName(id: id, name: "Friend \(i)")
        }
        #expect(store.settings.knownDesignerNames.count == cap)

        // Re-learning an EXISTING id's name is an update: it must not grow the map or evict anyone.
        store.learnDesignerName(id: ids[0], name: "Friend Zero Renamed")
        #expect(store.settings.knownDesignerNames.count == cap)            // no growth
        #expect(store.settings.knownDesignerNames[ids[0].uuidString] == "Friend Zero Renamed")
        // Every originally-learned id is still present (an update evicted nobody).
        for id in ids {
            #expect(store.settings.knownDesignerNames[id.uuidString] != nil)
        }
    }

    @Test func aRealisticFriendSetIsFullyRetained() {
        let store = makeShopStore()

        // A realistic number of real friends is far under the cap — all are kept, none evicted.
        let friends = (0..<24).map { i in (id: UUID(), name: "Friend \(i)") }
        for friend in friends {
            store.learnDesignerName(id: friend.id, name: friend.name)
        }

        #expect(store.settings.knownDesignerNames.count == friends.count)
        for friend in friends {
            #expect(store.settings.knownDesignerNames[friend.id.uuidString] == friend.name)
        }
    }

    @Test func emptyNameStillRemovesTheEntry() {
        let store = makeShopStore()
        let id = UUID()
        store.learnDesignerName(id: id, name: "Robin")
        #expect(store.settings.knownDesignerNames[id.uuidString] == "Robin")

        store.learnDesignerName(id: id, name: "   ")                        // sanitizes to empty → removal
        #expect(store.settings.knownDesignerNames[id.uuidString] == nil)
    }

    // MARK: - Helpers

    private func makeShopStore() -> FernletStore {
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        return FernletStore(
            date: day,
            repository: CoreDataFernletRepository(
                controller: controller,
                legacyRepository: LocalFernletRepository(fileURL: legacyURL)
            ),
            savedRecipeRepository: SavedRecipeRepository(
                controller: controller,
                legacyRepository: LegacySavedRecipeJSONRepository(fileURL: legacyURL)
            ),
            customItemRepository: CustomItemRepository(controller: controller),
            coinLedgerRepository: CoinLedgerRepository(controller: controller),
            // Hermetic: never fall back to MilestoneLedgerRepository() on PersistenceController.shared.
            milestoneLedgerRepository: MilestoneLedgerRepository(controller: controller)
        )
    }
}
