import Foundation
import Testing
import FernletDomainModel
import LocalPersistence
import CloudKitSync
import ProximityKit
@testable import Fernlet

/// Increment 3 — the in-person friend shop. Covers the store-level buy flow (debits coins idempotently,
/// preserves the seller's anonymized provenance, de-dups owned items, refuses when short), the listing
/// management gates (cap of six, name moderation, the once-per-day note), and the ephemeral peer catalog
/// (held while connected, cleared on disconnect).
@MainActor
struct FriendShopTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Buying

    @Test func buyDebitsCoinsAndStampsSellerProvenance() throws {
        let store = makeShopStore(seedCoins: 20)
        let sellerID = UUID()
        let item = sellerItem(price: 12, designer: sellerID)
        #expect(store.coinBalance == 20)

        let result = store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin")

        #expect(result == .bought)
        #expect(store.coinBalance == 8)                                              // debited the price
        let bought = try #require(store.customItems.first { $0.id == item.id })
        #expect(bought.designer.id == sellerID)                                      // seller provenance preserved
        #expect(bought.isShareable == false)                                         // not re-listed
        #expect(store.isSelfDesigned(bought) == false)                              // never claims "You"
        #expect(store.designerDisplayName(for: bought) == "Robin")                   // learned in person
    }

    @Test func buyingTheSameItemTwiceDoesNotDoubleCharge() {
        let store = makeShopStore(seedCoins: 20)
        let sellerID = UUID()
        let item = sellerItem(price: 12, designer: sellerID)

        #expect(store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin") == .bought)
        #expect(store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin") == .alreadyOwned)
        #expect(store.customItems.filter { $0.id == item.id }.count == 1)            // de-duped
        #expect(store.coinBalance == 8)                                              // charged once
    }

    @Test func buyRefusesWhenShortOnCoins() {
        let store = makeShopStore(seedCoins: 5)
        let item = sellerItem(price: 50, designer: UUID())

        #expect(store.buyClothingItem(item, fromDesignerID: item.designer.id, sellerName: "Robin") == .insufficientCoins)
        #expect(store.coinBalance == 5)                                              // untouched
        #expect(!store.customItems.contains { $0.id == item.id })                    // not granted
    }

    @Test func reBuyingAfterDeletingARecoversItemForFree() {
        // The spend ref is the item id, so a second buy of an already-paid item can't debit again — it
        // re-grants the item for FREE and reports `.bought` (the item is now back in the closet), never
        // `.alreadyOwned` (which is reserved for an item still present).
        let store = makeShopStore(seedCoins: 30)
        let sellerID = UUID()
        let item = sellerItem(price: 12, designer: sellerID)

        #expect(store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin") == .bought)
        #expect(store.coinBalance == 18)
        store.deleteCustomItem(id: item.id)
        #expect(!store.customItems.contains { $0.id == item.id })

        #expect(store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin") == .bought)  // free re-grant
        #expect(store.coinBalance == 18)                                             // not charged again
        #expect(store.customItems.contains { $0.id == item.id })                     // re-granted
    }

    @Test func reBuyingAPaidItemWithTooFewCoinsStillReGrantsForFree() {
        // The regression this guards: the balance check used to run BEFORE the spend's per-ref idempotency
        // check, so a user who paid for an item, deleted it, and re-bought with a now-insufficient balance
        // got `.insufficientCoins` and permanently lost access. A paid-for item must come back for free even
        // at a zero balance ("buy once, own forever, never charged twice").
        let store = makeShopStore(seedCoins: 12)
        let sellerID = UUID()
        let item = sellerItem(price: 12, designer: sellerID)

        #expect(store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin") == .bought)
        #expect(store.coinBalance == 0)                                              // spent it all
        store.deleteCustomItem(id: item.id)
        #expect(!store.customItems.contains { $0.id == item.id })

        // Balance (0) is now below the price (12) — a NEW purchase would be refused, but this ref was
        // already paid, so it must re-grant for free rather than return `.insufficientCoins`.
        #expect(store.buyClothingItem(item, fromDesignerID: sellerID, sellerName: "Robin") == .bought)
        #expect(store.coinBalance == 0)                                             // still not charged
        #expect(store.customItems.contains { $0.id == item.id })                     // recovered for free
    }

    // MARK: - Listing management

    @Test func listingEnforcesCapOfSix() {
        let store = makeShopStore()
        let ids = (0..<7).map { _ -> UUID in
            let item = ownItem(store: store, name: "Item")
            store.saveCustomItem(item)
            return item.id
        }
        for i in 0..<ClothingShopLimits.maxListedItems {
            #expect(store.listCustomItemForSale(id: ids[i], price: 10) == .listed)
        }
        #expect(store.listCustomItemForSale(id: ids[6], price: 10) == .capReached)
        #expect(store.listedShopItems.count == ClothingShopLimits.maxListedItems)
    }

    @Test func listingFlagsAProfaneName() {
        let store = makeShopStore()
        let item = ownItem(store: store, name: "shit hat")
        store.saveCustomItem(item)

        #expect(store.listCustomItemForSale(id: item.id, price: 10) == .nameFlagged)
        #expect(store.customItems.first { $0.id == item.id }?.isShareable == false)  // kept unlisted
    }

    @Test func listingRecordsTheDayAndUnlistingIsAlwaysFree() {
        let store = makeShopStore()
        let item = ownItem(store: store, name: "Sun Hat")
        store.saveCustomItem(item)
        #expect(store.shopUpdatedToday == false)

        #expect(store.listCustomItemForSale(id: item.id, price: 7) == .listed)
        #expect(store.shopUpdatedToday == true)
        #expect(store.settings.shopLastPublishedDayKey == store.todayKey)
        #expect(store.customItems.first { $0.id == item.id }?.price == 7)

        store.unlistCustomItem(id: item.id)
        #expect(store.customItems.first { $0.id == item.id }?.isShareable == false)
    }

    @Test func aFriendsDesignCannotBeListedForSale() {
        let store = makeShopStore(seedCoins: 20)
        let sellerID = UUID()
        let bought = sellerItem(price: 5, designer: sellerID)
        #expect(store.buyClothingItem(bought, fromDesignerID: sellerID, sellerName: "Robin") == .bought)

        #expect(store.listCustomItemForSale(id: bought.id, price: 5) == .notAllowed)  // not yours → refused
        #expect(store.customItems.first { $0.id == bought.id }?.isShareable == false)
    }

    // MARK: - Broadcast catalog

    @Test func broadcastCatalogIncludesItemsUnderAnyOwnedDesignerID() throws {
        // An item designed under a superseded-but-still-owned designer id counts as self-made
        // (`isSelfDesigned`), reads as "In your shop", and consumes the listing cap — so it must actually be
        // broadcast. The build filter therefore keys off the whole owned-id SET, not equality to the single
        // last-writer-wins `localDesignerID`.
        let store = makeShopStore()
        let supersededID = UUID()
        var settings = store.settings
        settings.ownedDesignerIDs.insert(supersededID)               // an owned id that is NOT localDesignerID
        store.settings = settings

        var underOldID = ownItem(store: store, name: "Legacy Hat")
        underOldID.designer = ItemDesigner(id: supersededID)
        underOldID.isShareable = true
        store.saveCustomItem(underOldID)

        // A non-self item, marked shareable — must NEVER be broadcast (its designer id isn't owned).
        let friendItem = sellerItem(name: "Friend Cape", price: 5, designer: UUID())
        store.saveCustomItem(friendItem)

        let catalog = store.buildShopCatalog()
        #expect(catalog.items.contains { $0.id == underOldID.id })                   // owned-but-not-local → broadcast
        #expect(store.isSelfDesigned(underOldID))                                    // matches the listing predicate
        #expect(!catalog.items.contains { $0.id == friendItem.id })                  // bought (non-self) never broadcast
    }

    // NOTE (Phase 3a): the delivery half of this suite (catalog held while connected, cleared on
    // disconnect) drove the deleted standalone-radio `ProximityClothingShareManager`. The mesh-owned
    // replacement lifecycle — in-session accumulation, the 1-hour post-session window, early close on
    // the next session / opt-out — is covered by `MeshClothingShopTests`. The buy flow below is
    // untouched by the port: buying was always fully local.

    // MARK: - Helpers

    private func sellerItem(name: String = "Star Cape", slot: ItemSlot = .hat, price: Int, designer: UUID) -> CustomizationItem {
        CustomizationItem(
            name: name,
            slot: slot,
            texture: ItemGridTexture.blank(for: slot, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: designer),
            isShareable: true,
            price: price
        )
    }

    private func ownItem(store: FernletStore, name: String) -> CustomizationItem {
        CustomizationItem(
            name: name,
            slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: store.localDesignerID)
        )
    }

    private func makeShopStore(seedCoins: Int = 0) -> FernletStore {
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let coinRepo = CoinLedgerRepository(controller: controller)
        if seedCoins > 0 {
            var rows: [CoinLedgerEntry] = []
            var remaining = seedCoins
            var dayN = 1
            while remaining > 0 {
                let amount = min(CoinEconomy.coinsPerActiveDay, remaining)
                rows.append(.earn(dayKey: String(format: "2026-01-%02d", dayN), amount: amount, at: day))
                remaining -= amount
                dayN += 1
            }
            coinRepo.append(rows)
        }
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
            coinLedgerRepository: coinRepo,
            // Same in-memory controller as the coin ledger: falling back to MilestoneLedgerRepository()
            // (PersistenceController.shared) leaks milestone rows accumulated by other suites into this
            // fixture's reconcile, minting order-dependent extra coins.
            milestoneLedgerRepository: MilestoneLedgerRepository(controller: controller)
        )
    }
}
