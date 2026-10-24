import SwiftUI
import FernletDomainModel
import FernletUI

/// Which of the person's own designs are in their shop and which could be (`b2-shop-editor`): the pure
/// half of ``YourShopView``, kept apart so it is tested without a view.
///
/// Only the person's own designs can be sold (provenance: no reselling a friend's item), exactly the
/// rule `FernletStore.isSelfDesigned` and `listCustomItemForSale(id:price:)` enforce.
nonisolated enum YourShopPlan {
    /// The listed items and the closet items that could be listed, each in the closet's order.
    ///
    /// - Parameters:
    ///   - items: Every item the person owns.
    ///   - isSelfDesigned: Whether an item is one of their own designs.
    /// - Returns: `listed` (own designs in the shop) and `unlisted` (own designs not in it).
    static func partition(_ items: [CustomizationItem],
                          isSelfDesigned: (CustomizationItem) -> Bool) -> (listed: [CustomizationItem], unlisted: [CustomizationItem]) {
        let own = items.filter(isSelfDesigned)
        return (own.filter(\.isShareable), own.filter { !$0.isShareable })
    }

    /// The price one step from `price`, kept in the shop's 1-to-100 range.
    static func stepped(_ price: Int, by step: Int) -> Int {
        FernletStepperMath.stepped(ClothingShopLimits.clampedPrice(price), by: step,
                                   in: ClothingShopLimits.minPrice...ClothingShopLimits.maxPrice)
    }

    /// Whether a step of `step` from `price` stays in range.
    static func canStep(_ price: Int, by step: Int) -> Bool {
        FernletStepperMath.canStep(ClothingShopLimits.clampedPrice(price), by: step,
                                   in: ClothingShopLimits.minPrice...ClothingShopLimits.maxPrice)
    }
}

/// Your shop (`b2-shop-editor`, approved 2026-10-24): what friends nearby can buy from you. The six
/// spots as a framed bar, each listed item with a − + price stepper (1 to 100 coins) and Unlist, your
/// own designs not yet listed with Sell, and Design a new item, which opens the Creation Studio.
///
/// It gathers what lived in two places: the Creation Studio's save step (list, price) and the
/// Wardrobe's swipe (Sell, Unlist). Listing goes through the same store gate
/// (`listCustomItemForSale`: the cap, the name check, a closed shop) with the Wardrobe's refusal
/// alerts; unlisting is never refused. Pushed from Friend shops; the Wardrobe's link is the
/// integrator's (it is another lane's file).
struct YourShopView: View {
    var store: FernletStore
    @State private var shopAlert: ShopAlert?
    @State private var isDesigningNewItem = false

    var body: some View {
        let plan = YourShopPlan.partition(store.customItems) { store.isSelfDesigned($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Friends nearby can buy these for their companion.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                listedHeader(count: plan.listed.count)
                YourShopSpotsBar(used: plan.listed.count)
                ForEach(plan.listed) { item in listedRow(item) }
                if !plan.unlisted.isEmpty {
                    SectionLabel("In your closet, not listed")
                        .padding(.top, 6)
                    ForEach(plan.unlisted) { item in unlistedRow(item) }
                }
                designNewItemLink
                Text("Names are checked before they go in your shop. Private items can be named anything.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .fernletPageBackground()
        .alert(item: $shopAlert) { $0.alert(in: .wardrobe) }
        .navigationDestination(isPresented: $isDesigningNewItem) {
            CreationStudioView(store: store, onExit: { isDesigningNewItem = false })
        }
    }

    /// "Listed" and the framed "3 of 6".
    private func listedHeader(count: Int) -> some View {
        HStack {
            SectionLabel("Listed")
            Spacer(minLength: 8)
            Text("\(count) of \(ClothingShopLimits.maxListedItems)")
                .font(FernletFramedFont.button)
                .foregroundStyle(WorldPalette.bark)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .fernletFramed(WorldTheme.framedLook, cornerRadius: 10)
                .accessibilityLabel("\(count) of \(ClothingShopLimits.maxListedItems) listed")
        }
    }

    /// One listed item: its preview, its name with Unlist, and the price stepper.
    private func listedRow(_ item: CustomizationItem) -> some View {
        FernletCard {
            HStack(alignment: .top, spacing: 14) {
                FriendsItemPreview(texture: item.texture, width: 62, height: 62)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        itemName(item)
                        Spacer(minLength: 6)
                        Button("Unlist") { store.unlistCustomItem(id: item.id) }
                            .font(FernletFramedFont.buttonSmall)
                            .foregroundStyle(WorldPalette.mossInk)
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Unlist \(displayName(item))")
                    }
                    priceRow(item)
                }
            }
        }
    }

    /// The − coin price + stepper and the range it keeps to.
    private func priceRow(_ item: CustomizationItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                priceStepper(item)
                rangeNote
            }
            VStack(alignment: .leading, spacing: 6) {
                priceStepper(item)
                rangeNote
            }
        }
    }

    private func priceStepper(_ item: CustomizationItem) -> some View {
        let price = ClothingShopLimits.clampedPrice(item.price)
        return FernletStepper("Price", value: Text("\(price) coins"),
                              canDecrement: YourShopPlan.canStep(price, by: -1),
                              canIncrement: YourShopPlan.canStep(price, by: 1),
                              onDecrement: { store.setCustomItemPrice(id: item.id, YourShopPlan.stepped(price, by: -1)) },
                              onIncrement: { store.setCustomItemPrice(id: item.id, YourShopPlan.stepped(price, by: 1)) })
            .accessibilityLabel("\(displayName(item)), price")
    }

    private var rangeNote: some View {
        Text("1 to 100 coins")
            .font(FernletFramedFont.rowDetail)
            .foregroundStyle(WorldPalette.dim)
    }

    /// One of your own designs not in the shop: its preview, its name, and Sell.
    private func unlistedRow(_ item: CustomizationItem) -> some View {
        FernletCard {
            HStack(spacing: 14) {
                FriendsItemPreview(texture: item.texture, width: 62, height: 62)
                VStack(alignment: .leading, spacing: 2) {
                    itemName(item)
                    Text("designed by you")
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
                Spacer(minLength: 8)
                Button("Sell") { list(item) }
                    .buttonStyle(ActionPillButtonStyle(.primary, size: .small))
                    .accessibilityLabel("Sell \(displayName(item))")
            }
        }
    }

    private func itemName(_ item: CustomizationItem) -> some View {
        Text(verbatim: displayName(item))
            .font(FernletFramedFont.rowTitle.weight(.semibold))
            .foregroundStyle(WorldPalette.bark)
            .fernletWrappingText()
    }

    /// Design a new item: the Creation Studio, pushed on this stack.
    private var designNewItemLink: some View {
        Button { isDesigningNewItem = true } label: {
            FriendsLinkCard(title: Text("Design a new item"), detail: Text("Open the Creation Studio"),
                            sprite: WorldSprites.plus, spriteScale: 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("yourShop.designNew")
    }

    /// The item's name, or its slot's name when it has none.
    private func displayName(_ item: CustomizationItem) -> String {
        item.name.isEmpty ? item.slot.label : item.name
    }

    /// Lists an item at its current price through the store's gate; a refusal shows the Wardrobe's
    /// alert for it, with the same feel (report B16).
    private func list(_ item: CustomizationItem) {
        let outcome = store.listCustomItemForSale(id: item.id, price: ClothingShopLimits.clampedPrice(item.price))
        if let cue = WardrobeView.listingFeedbackEvent(for: outcome) { FernletFeedback.system.play(cue) }
        switch outcome {
        case .listed, .notAllowed: break
        case .nameFlagged: shopAlert = .nameFlagged
        case .capReached: shopAlert = .capReached
        case .storeBanned(let remainingSeconds): shopAlert = .storeBanned(remainingSeconds: remainingSeconds)
        }
    }
}

/// The six shop spots as a framed bar (`b2-shop-editor`): one framed segment per spot, the used ones
/// in the look's mark colour. Decorative; the "3 of 6" beside the label says it.
struct YourShopSpotsBar: View {
    let used: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<ClothingShopLimits.maxListedItems, id: \.self) { spot in
                RoundedRectangle(cornerRadius: 3)
                    .fill(spot < used ? WorldPalette.moss : WorldPalette.paperLight)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
                    .frame(height: 14)
            }
        }
        .accessibilityHidden(true)
    }
}
