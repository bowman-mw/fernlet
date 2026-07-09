import SwiftUI
import FernletDomainModel

/// The closet: every item the user owns, grouped by slot. Tap a row to edit; swipe to equip/unequip or
/// delete. Items received from friends show "designed by <friend>". Pushed within the customization
/// sheet's navigation stack, so it pushes the Creation Studio without nesting sheets.
struct WardrobeView: View {
    var store: FernletStore

    @State private var shopAlert: ShopAlert?

    private enum ShopAlert: Identifiable {
        case nameFlagged
        case capReached
        var id: Int { self == .nameFlagged ? 0 : 1 }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CreationStudioView(store: store)
                } label: {
                    Label("Design a new item", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.moss)
                }
            }

            if !store.listedShopItems.isEmpty || store.shopUpdatedToday {
                Section {
                    Label(shopStatusText, systemImage: "bag")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }

            ForEach(ItemSlot.allCases) { slot in
                let items = store.customItems.filter { $0.slot == slot }
                if !items.isEmpty {
                    Section(slot.label) {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                }
            }

            if store.customItems.isEmpty {
                Section {
                    Text("No items yet — design your first one above. New creations appear on your companion right away.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .listRowBackground(Color.cream)
        .navigationTitle("Wardrobe")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $shopAlert) { alert in
            switch alert {
            case .nameFlagged:
                return Alert(
                    title: Text("Pick a friendlier name"),
                    message: Text("This name can't be used in your shop. Rename it in the editor, then list it again. (Private items can be named anything.)"),
                    dismissButton: .default(Text("OK"))
                )
            case .capReached:
                return Alert(
                    title: Text("Your shop is full"),
                    message: Text("You can list up to \(ClothingShopLimits.maxListedItems) items at once. Unlist one to make room."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var shopStatusText: String {
        let listed = store.listedShopItems.count
        if store.shopUpdatedToday {
            return "\(listed) of \(ClothingShopLimits.maxListedItems) in your shop · you've refreshed it today"
        }
        return "\(listed) of \(ClothingShopLimits.maxListedItems) in your shop"
    }

    @ViewBuilder
    private func row(for item: CustomizationItem) -> some View {
        let isEquipped = store.equippedCustomItems.contains { $0.id == item.id }
        NavigationLink {
            CreationStudioView(store: store, editingItem: item)
        } label: {
            HStack(spacing: 12) {
                CustomItemThumbnail(texture: item.texture, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name.isEmpty ? item.slot.label : item.name)
                        .font(.fernlet(.label))
                    if store.isSelfDesigned(item) {
                        if item.isShareable {
                            Label("In your shop · \(item.price) coins", systemImage: "bag")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.moss)
                        }
                    } else {
                        Text("Designed by \(store.designerDisplayName(for: item))")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                }
                Spacer()
                if isEquipped {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.moss)
                        .accessibilityLabel("Equipped")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                if isEquipped {
                    store.unequipCustomSlot(item.slot)
                } else {
                    store.equipCustomItem(id: item.id, slot: item.slot)
                }
            } label: {
                Label(isEquipped ? "Unequip" : "Equip", systemImage: isEquipped ? "minus.circle" : "checkmark.circle")
            }
            .tint(Color.moss)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.deleteCustomItem(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            // Only your own designs can be listed for sale (provenance / no reselling).
            if store.isSelfDesigned(item) {
                Button {
                    toggleListing(item)
                } label: {
                    Label(item.isShareable ? "Unlist" : "Sell", systemImage: item.isShareable ? "bag.badge.minus" : "bag.badge.plus")
                }
                .tint(Color.sun)
            }
        }
    }

    /// Unlisting is always allowed. Listing goes through the store gate (cap + name moderation); the price
    /// is the item's current price (set it precisely in the editor), clamped into range.
    private func toggleListing(_ item: CustomizationItem) {
        if item.isShareable {
            store.unlistCustomItem(id: item.id)
            return
        }
        let price = ClothingShopLimits.clampedPrice(item.price)
        switch store.listCustomItemForSale(id: item.id, price: price) {
        case .listed, .notAllowed: break
        case .nameFlagged: shopAlert = .nameFlagged
        case .capReached: shopAlert = .capReached
        }
    }
}
