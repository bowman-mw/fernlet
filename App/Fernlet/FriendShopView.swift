import SwiftUI
import FernletDomainModel
import ProximityKit
import FernletSocial
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
            VStack(alignment: .leading, spacing: 16) {
                topRow
                if visibleCatalogs.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleCatalogs) { catalog in
                        shopSection(catalog, isFirst: catalog.id == visibleCatalogs.first?.id)
                    }
                }
                // The empty state already says when shops open; the note is for a page with shops.
                if !visibleCatalogs.isEmpty {
                    Text("A friend's shop opens here for an hour after you part. Report an item from its ··· menu.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                yourShopLink
            }
            .padding(16)
        }
        // The title is on the panel's plate (`fernletPushedPage` at the push); the dots show here.
        .fernletPageBackground()
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
            reportButtons(target)
        } message: { _ in
            // Disclosure (L21): stated BEFORE the report is made, because the report is not
            // anonymous and not device-local — it is signed and handed to friends met in person,
            // the person reported among them.
            // ONE literal: `+` between literals builds a `String`, which `Text` draws verbatim.
            Text("Reporting hides this item and blocks the sender on your device. Your report is also signed by your device and shared with friends you meet in person — including the person reported — so several reports of the same item can be counted together.")
        }
    }

    /// The catalogs drawn: every one held, minus sellers banned on this phone.
    private var visibleCatalogs: [ProximityClothingCatalog] {
        shop.peerCatalogs.filter { !store.isProximitySellerBanned(fingerprint: $0.senderFingerprint) }
    }

    /// The first shop's "Made by …" line beside the framed coin balance (b2-friend-shop draft 2).
    private var topRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if let first = visibleCatalogs.first {
                Text("Made by \(sellerName(first)), for your companion.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            FriendsCoinPill(balance: store.coinBalance)
                .accessibilityIdentifier("friendShop.coinBalance")
        }
    }

    /// The report reasons, each filing the report and saying what happened.
    @ViewBuilder
    private func reportButtons(_ target: ReportTarget) -> some View {
        ForEach(ReportReason.allCases) { reason in
            Button(reason.label, role: .destructive) {
                store.reportClothingItem(target.item, sellerFingerprint: target.sellerFingerprint,
                                         sellerSigningPublicKey: target.sellerSigningPublicKey, reason: reason)
                reportTarget = nil
                // Disclosure (L21): the row we relay is SIGNED by this device and goes to friends
                // we meet in person — including the person reported, who is the only party that
                // can act on it as a self-ban. Saying only "on your device" understated that.
                feedback = String(
                    localized: "shop.report.thanks",
                    defaultValue: "Thanks for letting us know. We've hidden this item and blocked its sender on your device. Your report is signed by your device and travels to friends you meet in person, including the person you reported.",
                    comment: "Alert after reporting an item in a friend's shop: what happened, and who the signed report is shared with")
            }
        }
        Button("Cancel", role: .cancel) { reportTarget = nil }
    }

    /// Your own shop (b2-shop-editor), one tap away from the friends' shops.
    private var yourShopLink: some View {
        NavigationLink(value: FriendsRoute.yourShop) {
            FriendsLinkCard(title: Text("Your shop"),
                            detail: Text("\(store.listedShopItems.count) of \(ClothingShopLimits.maxListedItems) listed"),
                            sprite: FriendsSprites.shop, spriteScale: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friendShop.yourShop")
    }

    // MARK: - Sections

    /// Shown when no catalogs are held (the window closed mid-browse, or the entry was reached with
    /// nothing exchanged): explains the post-session model rather than spinning forever.
    private var emptyState: some View {
        FriendsEmptyNote(
            text: Text("No shops right now. Spend time with a friend and their shop opens here for an hour after you part."),
            systemImage: "bag"
        )
        .padding(.vertical, 20)
    }

    private func shopSection(_ catalog: ProximityClothingCatalog, isFirst: Bool) -> some View {
        let items = ClothingShareCodec.sanitizedItems(from: catalog.payload)
            .filter { !store.isClothingItemHidden($0, sellerFingerprint: catalog.senderFingerprint) }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sellerName(catalog))’s shop")
                    .font(FernletFramedFont.cardTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityAddTraits(.isHeader)
                // The first shop's line is in the top row, beside the coins.
                if !isFirst {
                    Text("Made by \(sellerName(catalog)), for your companion.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                }
            }
            if items.isEmpty {
                FernletCard {
                    Text("Nothing for sale right now.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                FernletTileGrid {
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
        return FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                FriendsItemPreview(texture: item.texture, height: 74)
                // T2-11: both labels wrap instead of truncating at Larger Text sizes; every rendered
                // name comes through `ItemNameModeration.sanitizedName` (24 characters at most), so a
                // hostile catalog cannot stretch the grid.
                Text(item.name.isEmpty ? item.slot.label : item.name)
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()
                Text("designed by \(sellerName(catalog))")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                buyButton(item, from: catalog, owned: owned, affordable: affordable)
                if !owned && !affordable {
                    Text("Not enough coins yet")
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) { reportMenu(item, catalog: catalog) }
    }

    /// The framed buy button: the coin price on the accent (dimmed when the balance can't cover it),
    /// or a framed "Owned" with a tick once it is in the closet.
    @ViewBuilder
    private func buyButton(_ item: CustomizationItem, from catalog: ProximityClothingCatalog,
                           owned: Bool, affordable: Bool) -> some View {
        if owned {
            Button {} label: {
                HStack(spacing: 6) {
                    FernletIcon(.check, scale: 2)
                    Text("Owned")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
            .disabled(true)
        } else {
            Button { buy(item, from: catalog) } label: {
                HStack(spacing: 6) {
                    WorldSpriteView(sprite: WorldSprites.coin, scale: 2)
                    Text(verbatim: item.price.formatted(.number))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary, size: .small))
            .disabled(!affordable)
            .accessibilityLabel(Text(verbatim: FernletUICopy.coinBalance(item.price)))
        }
    }

    /// The ••• menu on a tile: the App Store UGC report path, so it has to be both reachable and
    /// nameable.
    private func reportMenu(_ item: CustomizationItem, catalog: ProximityClothingCatalog) -> some View {
        Menu {
            Button(role: .destructive) {
                reportTarget = ReportTarget(item: item, sellerFingerprint: catalog.senderFingerprint,
                                            sellerSigningPublicKey: catalog.senderSigningPublicKey)
            } label: {
                Label("Report item…", systemImage: "flag")
            }
        } label: {
            Text(verbatim: "···")
                .font(FernletFramedFont.button)
                .foregroundStyle(WorldPalette.dim)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options for \(item.name.isEmpty ? item.slot.label : item.name)")
        .accessibilityIdentifier("friendShop.report")
    }

    // MARK: - Behavior

    /// The seller's display name, sanitized with the SAME rule the store applies before persisting
    /// it (`DiaryStore.setKnownDesignerName`), so a hostile wire-claimed name — multi-kilobyte, or
    /// carrying bidi overrides — can neither render raw here nor disagree with what is stored.
    ///
    /// The envelope's own `senderDisplayName` is sanitized too, not just the payload's: it is the
    /// FALLBACK, it comes off the same wire, and nothing bounds it there — so the branch that
    /// rendered it raw was the one case the paragraph above already claimed was impossible. It
    /// mattered less while the byline was pinned to one line; now that it wraps for Dynamic Type
    /// (T2-11), an unbounded name would be an unbounded tile.
    private func sellerName(_ catalog: ProximityClothingCatalog) -> String {
        let name = ItemNameModeration.sanitizedName(catalog.payload.displayName)
        guard name.isEmpty else { return name }
        return ItemNameModeration.sanitizedName(catalog.senderDisplayName)
    }

    private func buy(_ item: CustomizationItem, from catalog: ProximityClothingCatalog) {
        let result = store.buyClothingItem(
            item,
            fromDesignerID: catalog.payload.designerID,
            sellerName: sellerName(catalog),
            sellerFingerprint: catalog.senderFingerprint
        )
        let label = item.name.isEmpty ? item.slot.label : item.name
        // B25: the alert below is the result, and this is its feel.
        FernletFeedback.system.play(Self.purchaseEvent(for: result))
        switch result {
        case .bought:
            feedback = String(localized: "shop.purchase.bought", defaultValue: "Added “\(label)” to your closet.",
                              comment: "Alert after buying an item in a friend's shop. %@ is the item's name.")
        case .alreadyOwned:
            feedback = String(localized: "shop.purchase.alreadyOwned", defaultValue: "You already own “\(label)”.",
                              comment: "Alert when trying to buy an item from a friend's shop that is already in your closet. %@ is the item's name.")
        case .insufficientCoins:
            feedback = String(localized: "shop.purchase.insufficientCoins",
                              defaultValue: "Not enough coins for “\(label)” yet — keep showing up!",
                              comment: "Alert when there are not enough coins to buy an item in a friend's shop. %@ is the item's name.")
        case .unavailable:
            feedback = String(localized: "shop.purchase.unavailable", defaultValue: "“\(label)” is no longer available.",
                              comment: "Alert when an item in a friend's shop can no longer be bought. %@ is the item's name.")
        }
    }

    /// What a purchase's result feels like (report B25): `done` when the item is in the closet, and
    /// `caveat` for a purchase that did not go through but is no error — not enough coins yet,
    /// already owned, or gone from the shop. Each one's alert says which.
    static func purchaseEvent(for result: FernletStore.ClothingPurchaseResult) -> FernletFeedbackEvent {
        switch result {
        case .bought: .done
        case .alreadyOwned, .insufficientCoins, .unavailable: .caveat
        }
    }

    /// Learn each seller's name so bought items resolve "designed by <friend>" in the closet.
    private func learnDesignerNames() {
        for catalog in shop.peerCatalogs {
            store.learnDesignerName(id: catalog.payload.designerID, name: sellerName(catalog))
        }
    }
}

