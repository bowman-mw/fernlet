import SwiftUI
import FernletDomainModel
import ProximityKit

/// Browse the shops of friends you're connected with in person and buy items with coins. The catalog is
/// ephemeral — it lives only while you're near the friend and disappears when you part; only items you
/// actually buy persist (stamped "designed by <friend>"). Pushed from the Friends header.
struct FriendShopView: View {
    var store: FernletStore
    var manager: ProximityClothingShareManager

    @State private var feedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                walletBadge

                if manager.peerCatalogs.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.peerCatalogs) { catalog in
                        shopSection(catalog)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("Friend shops")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Respect the nearby-sharing opt-out: ContentView owns the manager's full lifecycle (setting +
            // scene phase + lock + tab), so starting it unconditionally here would begin Multipeer discovery
            // and broadcast this device's shop catalog even when `allowNearbyClothingShares` is off.
            if store.settings.allowNearbyClothingShares {
                manager.start()
            }
            learnDesignerNames()
        }
        .onChange(of: manager.peerCatalogs.count) { _, _ in learnDesignerNames() }
        .alert("Shop", isPresented: Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })) {
            Button("OK", role: .cancel) { feedback = nil }
        } message: {
            Text(feedback ?? "")
        }
    }

    // MARK: - Sections

    private var walletBadge: some View {
        HStack(spacing: 12) {
            Image(systemName: "circlebadge.2.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.sun)
            Text("\(store.coinBalance) coins")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                .contentTransition(.numericText())
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.coinBalance) coins")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Color.moss)
            Text("Looking for friends' shops nearby…")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
            Text("Connect with a friend in person and their shop appears here. It vanishes again when you part.")
                .font(.fernlet(.bodySmall))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.slate)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func shopSection(_ catalog: ProximityClothingCatalog) -> some View {
        let items = ClothingShareCodec.sanitizedItems(from: catalog.payload)
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(sellerName(catalog))’s shop")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)

            if items.isEmpty {
                Text("Nothing for sale right now.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        itemTile(item, catalog: catalog)
                    }
                }
            }
        }
    }

    private func itemTile(_ item: CustomizationItem, catalog: ProximityClothingCatalog) -> some View {
        let owned = store.customItems.contains { $0.id == item.id }
        let affordable = store.coinBalance >= item.price
        return VStack(spacing: 8) {
            CustomItemThumbnail(texture: item.texture, size: 72)
            Text(item.name.isEmpty ? item.slot.label : item.name)
                .font(.fernlet(.headerMedium))
                .lineLimit(1)
            Text("designed by \(sellerName(catalog))")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)

            Button {
                buy(item, from: catalog)
            } label: {
                if owned {
                    Label("Owned", systemImage: "checkmark.circle.fill")
                        .font(.fernlet(.label))
                } else {
                    Label("\(item.price) coins", systemImage: "bag")
                        .font(.fernlet(.label))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(owned ? Color.slate : Color.moss)
            .disabled(owned || !affordable)
            if !owned && !affordable {
                Text("Not enough coins yet")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream))
    }

    // MARK: - Behavior

    private func sellerName(_ catalog: ProximityClothingCatalog) -> String {
        let name = catalog.payload.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? catalog.senderDisplayName : name
    }

    private func buy(_ item: CustomizationItem, from catalog: ProximityClothingCatalog) {
        let result = store.buyClothingItem(
            item,
            fromDesignerID: catalog.payload.designerID,
            sellerName: sellerName(catalog)
        )
        let label = item.name.isEmpty ? item.slot.label : item.name
        switch result {
        case .bought:
            feedback = "Added “\(label)” to your closet."
        case .alreadyOwned:
            feedback = "You already own “\(label)”."
        case .insufficientCoins:
            feedback = "Not enough coins for “\(label)” yet — keep showing up!"
        }
    }

    /// Learn each connected seller's name so bought items resolve "designed by <friend>" in the closet.
    private func learnDesignerNames() {
        for catalog in manager.peerCatalogs {
            store.learnDesignerName(id: catalog.payload.designerID, name: sellerName(catalog))
        }
    }
}
