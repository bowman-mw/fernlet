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
                    designNewItemRow
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !store.listedShopItems.isEmpty || store.shopUpdatedToday {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "bag")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.moss)
                        Text(shopStatusText)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 6, trailing: 24))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            if !store.customItems.isEmpty {
                Section {
                    sectionLabel("Your items")
                        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 4, trailing: 24))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            ForEach(ItemSlot.allCases) { slot in
                let items = store.customItems.filter { $0.slot == slot }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            row(for: item)
                                .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(slot.label)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .textCase(nil)
                    }
                }
            }

            if store.customItems.isEmpty {
                Section {
                    emptyCloset
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .tint(Color.moss)
        .navigationTitle("Wardrobe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The always-reachable coin-balance surface (Phase 3a): the friend shop is now a
            // post-session window, so the wallet lives here too, not only inside the shop.
            ToolbarItem(placement: .topBarTrailing) {
                CoinBalancePill(balance: store.coinBalance)
                    .accessibilityIdentifier("wardrobe.coinBalance")
            }
        }
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

    // MARK: - Rows

    /// The "Design a new item" affordance — a cream card with a moss-tinted icon tile.
    private var designNewItemRow: some View {
        HStack(spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 1) {
                Text("Design a new item")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                Text("Open the Creation Studio")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.bark.opacity(0.35))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fernletSmallShadow()
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.moss.opacity(0.14))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.moss)
            }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for item: CustomizationItem) -> some View {
        let isEquipped = store.equippedCustomItems.contains { $0.id == item.id }
        NavigationLink {
            CreationStudioView(store: store, editingItem: item)
        } label: {
            HStack(spacing: 12) {
                CustomItemThumbnail(texture: item.texture, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.isEmpty ? item.slot.label : item.name)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    provenance(for: item)
                }

                Spacer(minLength: 8)

                if isEquipped {
                    equippedPill
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .fernletSmallShadow()
        }
        .buttonStyle(.plain)
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
            .tint(Color.terracotta)
            // Only your own designs can be listed for sale (provenance / no reselling).
            if store.isSelfDesigned(item) {
                Button {
                    toggleListing(item)
                } label: {
                    Label(item.isShareable ? "Unlist" : "Sell", systemImage: item.isShareable ? "bag.badge.minus" : "bag.badge.plus")
                }
                .tint(Color.moss)
            }
        }
    }

    /// The provenance line: shop status for your own listed items, "designed by …" for the rest.
    @ViewBuilder
    private func provenance(for item: CustomizationItem) -> some View {
        if store.isSelfDesigned(item) {
            if item.isShareable {
                HStack(spacing: 5) {
                    Image(systemName: "bag")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.moss)
                    Text("In your shop · \(item.price) coins")
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.moss)
                }
            } else {
                Text("designed by you")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
            }
        } else {
            Text("Designed by \(store.designerDisplayName(for: item))")
                .font(.fernlet(.bodySmall))
                .italic()
                .foregroundStyle(Color.slate)
        }
    }

    private var equippedPill: some View {
        Text("Equipped")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.moss)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.moss.opacity(0.12), in: Capsule())
            .accessibilityLabel("Equipped")
    }

    // MARK: - Empty state

    private var emptyCloset: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.moss.opacity(0.16))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "tshirt")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.moss)
                }
                .padding(.bottom, 16)

            Text("Your closet is empty")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
                .padding(.bottom, 6)

            Text("Make the first little thing for your companion to wear. New creations appear on your companion right away.")
                .font(.fernlet(.body))
                .italic()
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)

            NavigationLink {
                CreationStudioView(store: store)
            } label: {
                Text("Design your first item")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.parchmentInk)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .background(Color.cream.opacity(0.6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
