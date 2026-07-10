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
            VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                walletPill
            }
        }
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

    /// Coin wallet — a compact parchment pill carrying the live spendable balance, echoing the shop's
    /// own coin chips so the whole surface reads in one currency.
    private var walletPill: some View {
        HStack(spacing: 6) {
            CoinGlyph(diameter: 14)
            Text("\(store.coinBalance)")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(Color.cream)
        )
        .overlay(Capsule(style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        .fernletSmallShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.coinBalance) coins")
    }

    /// Searching state — a soft pulsing bag rather than a bare system spinner, so the wait reads as the
    /// shop looking for a friend nearby (never a forever-spinner with no way out shown to the user).
    private var emptyState: some View {
        VStack(spacing: FernletMetrics.spaceMd) {
            SearchingPulse()
            Text("Looking for shops nearby")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Connect with a friend in person and their shop appears here. It vanishes again when you part.")
                .font(.fernlet(.bodySmall))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FernletMetrics.spaceLg)
        .padding(.vertical, 56)
    }

    private func shopSection(_ catalog: ProximityClothingCatalog) -> some View {
        let items = ClothingShareCodec.sanitizedItems(from: catalog.payload)
        return VStack(alignment: .leading, spacing: FernletMetrics.spaceMd) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sellerName(catalog))’s shop")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text("Made by \(sellerName(catalog)), for your companion.")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
            }

            if items.isEmpty {
                Text("Nothing for sale right now.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FernletMetrics.spaceMd)
                    .background(
                        RoundedRectangle(cornerRadius: FernletMetrics.radiusMd, style: .continuous)
                            .fill(Color.cream)
                    )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: FernletMetrics.spaceMd)],
                          spacing: FernletMetrics.spaceMd) {
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
        return VStack(alignment: .leading, spacing: FernletMetrics.spaceSm) {
            CustomItemThumbnail(texture: item.texture, size: 74)
                .frame(maxWidth: .infinity)
                .frame(height: 74)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: FernletMetrics.radiusSm, style: .continuous)
                        .fill(Color.parchment)
                )

            Text(item.name.isEmpty ? item.slot.label : item.name)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
                .lineLimit(1)
            Text("designed by \(sellerName(catalog))")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .lineLimit(1)

            Button {
                buy(item, from: catalog)
            } label: {
                buyLabel(owned: owned, price: item.price, affordable: affordable)
            }
            .buttonStyle(.plain)
            .disabled(owned || !affordable)

            if !owned && !affordable {
                Text("Not enough coins yet")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FernletMetrics.spaceMd - 4)
        .background(
            RoundedRectangle(cornerRadius: FernletMetrics.radiusMd, style: .continuous)
                .fill(Color.cream)
        )
        .fernletSmallShadow()
    }

    /// Themed buy affordance — a moss coin chip when purchasable, a muted "Owned" checkmark chip when
    /// already in the closet, and a dimmed chip when the balance can't cover it. Replaces the old system
    /// `.borderedProminent` button so the whole tile stays on-brand parchment.
    @ViewBuilder
    private func buyLabel(owned: Bool, price: Int, affordable: Bool) -> some View {
        if owned {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text("Owned")
                    .font(.fernlet(.label))
            }
            .foregroundStyle(Color.slate)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Color.parchment)
            )
        } else {
            HStack(spacing: 5) {
                CoinGlyph(diameter: 11)
                Text("\(price)")
                    .font(.fernlet(.label))
            }
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Color.moss)
            )
            .opacity(affordable ? 1 : 0.5)
        }
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

