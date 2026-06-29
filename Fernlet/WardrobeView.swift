import SwiftUI
import FernletDomainModel

/// The closet: every item the user owns, grouped by slot. Tap a row to edit; swipe to equip/unequip or
/// delete. Items received from friends show "designed by <friend>". Pushed within the customization
/// sheet's navigation stack, so it pushes the Creation Studio without nesting sheets.
struct WardrobeView: View {
    var store: FernletStore

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
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Wardrobe")
        .navigationBarTitleDisplayMode(.inline)
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
                        .font(.subheadline.weight(.medium))
                    if store.isSelfDesigned(item) {
                        if item.isShareable {
                            Label("In your shop", systemImage: "bag")
                                .font(.caption)
                                .foregroundStyle(Color.moss)
                        }
                    } else {
                        Text("Designed by \(store.designerDisplayName(for: item))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            Button {
                store.setCustomItemShareable(id: item.id, !item.isShareable)
            } label: {
                Label(item.isShareable ? "Unlist" : "Sell", systemImage: item.isShareable ? "bag.badge.minus" : "bag.badge.plus")
            }
            .tint(Color.sun)
        }
    }
}
