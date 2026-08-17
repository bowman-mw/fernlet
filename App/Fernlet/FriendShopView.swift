import SwiftUI
import FernletDomainModel
import ProximityKit
import FernletUI

/// Browse the shops of friends from your last session and buy items with coins.
///
/// Catalogs are exchanged over the friend mesh while you're together; the shop OPENS when the
/// session ends and stays browsable for one hour (Phase 3a post-session window — the entry card
/// on the Friends tab carries the countdown). Only items you actually buy persist (stamped
/// "designed by <friend>"). Every rendered item is re-sanitized through ``ClothingShareCodec``
/// and filtered against hidden items and banned sellers; the ••• menu is the report path App
/// Store UGC compliance points at, and purchases run through `FernletStore.buyClothingItem`
/// against the coin ledger.
struct FriendShopView: View {
    var store: FernletStore
    var shop: MeshClothingShop

    @State private var feedback: String?
    @State private var reportTarget: ReportTarget?

    /// The item (plus its seller's identity) a report confirmation is currently about.
    ///
    /// Captured at ••• time so the dialog keeps a stable target even if the catalog refreshes;
    /// the seller keys let `reportClothingItem` both hide the item and block its sender.
    private struct ReportTarget: Identifiable {
        let id = UUID()
        let item: CustomizationItem
        let sellerFingerprint: String?
        let sellerSigningPublicKey: Data?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FernletMetrics.spaceLg) {
                if shop.peerCatalogs.isEmpty {
                    emptyState
                } else {
                    ForEach(shop.peerCatalogs.filter { !store.isProximitySellerBanned(fingerprint: $0.senderFingerprint) }) { catalog in
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
                CoinBalancePill(balance: store.coinBalance)
                    .accessibilityIdentifier("friendShop.coinBalance")
            }
        }
        .onAppear {
            // Lazy window expiry: entering the shop is a natural moment to drop a lapsed window's
            // catalogs (no background timers — the entry card already hides itself on expiry).
            shop.cleanupIfExpired()
            learnDesignerNames()
        }
        .onChange(of: shop.peerCatalogs.count) { _, _ in learnDesignerNames() }
        .alert("Shop", isPresented: $feedback.isPresent()) {
            Button("OK", role: .cancel) { feedback = nil }
        } message: {
            Text(feedback ?? "")
        }
        .confirmationDialog(
            "Report this item?",
            isPresented: $reportTarget.isPresent(),
            presenting: reportTarget
        ) { target in
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label, role: .destructive) {
                    store.reportClothingItem(target.item, sellerFingerprint: target.sellerFingerprint,
                                             sellerSigningPublicKey: target.sellerSigningPublicKey, reason: reason)
                    reportTarget = nil
                    feedback = "Thanks for letting us know. We've hidden this item and blocked its sender on your device."
                }
            }
            Button("Cancel", role: .cancel) { reportTarget = nil }
        } message: { _ in
            Text("Reporting hides this item and blocks the sender on your device.")
        }
    }

    // MARK: - Sections

    /// Shown when no catalogs are held (the window closed mid-browse, or the entry was reached with
    /// nothing exchanged): explains the post-session model rather than spinning forever.
    private var emptyState: some View {
        VStack(spacing: FernletMetrics.spaceMd) {
            Image(systemName: "bag")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.moss)
            Text("No shops right now")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Spend time with a friend and their shop opens here for an hour after you part.")
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
            .filter { !store.isClothingItemHidden($0, sellerFingerprint: catalog.senderFingerprint) }
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
        .overlay(alignment: .topTrailing) {
            Menu {
                Button(role: .destructive) {
                    reportTarget = ReportTarget(item: item, sellerFingerprint: catalog.senderFingerprint,
                                                sellerSigningPublicKey: catalog.senderSigningPublicKey)
                } label: {
                    Label("Report item…", systemImage: "flag")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.slate)
                    .padding(7)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("friendShop.report")
        }
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

    /// The seller's display name, sanitized with the SAME rule the store applies before persisting
    /// it (`DiaryStore.setKnownDesignerName`), so a hostile wire-claimed name — multi-kilobyte, or
    /// carrying bidi overrides — can neither render raw here nor disagree with what is stored.
    private func sellerName(_ catalog: ProximityClothingCatalog) -> String {
        let name = ItemNameModeration.sanitizedName(catalog.payload.displayName)
        return name.isEmpty ? catalog.senderDisplayName : name
    }

    private func buy(_ item: CustomizationItem, from catalog: ProximityClothingCatalog) {
        let result = store.buyClothingItem(
            item,
            fromDesignerID: catalog.payload.designerID,
            sellerName: sellerName(catalog),
            sellerFingerprint: catalog.senderFingerprint
        )
        let label = item.name.isEmpty ? item.slot.label : item.name
        switch result {
        case .bought:
            feedback = "Added “\(label)” to your closet."
        case .alreadyOwned:
            feedback = "You already own “\(label)”."
        case .insufficientCoins:
            feedback = "Not enough coins for “\(label)” yet — keep showing up!"
        case .unavailable:
            feedback = "“\(label)” is no longer available."
        }
    }

    /// Learn each seller's name so bought items resolve "designed by <friend>" in the closet.
    private func learnDesignerNames() {
        for catalog in shop.peerCatalogs {
            store.learnDesignerName(id: catalog.payload.designerID, name: sellerName(catalog))
        }
    }
}

