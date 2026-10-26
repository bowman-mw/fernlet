import SwiftUI
import FernletDomainModel
import FernletUI

/// The closet: every item the user owns, grouped by slot.
///
/// Tap a row to edit in ``CreationStudioView``; swipe leading to equip/unequip, trailing to
/// delete or (for self-designed items only — provenance forbids reselling) list/unlist in the
/// shop, with the same refusal alerts as the studio's confirmation step. Items received from
/// friends show "designed by <friend>", and a status line summarizes the shop (the coin balance
/// lives one screen up, in the customization sheet's leading header slot). Pushed within the
/// customization sheet's navigation stack, so it pushes the Creation Studio without nesting
/// sheets.
struct WardrobeView: View {
    var store: FernletStore
    /// Forwarded to every ``CreationStudioView`` pushed from here so the hosting customization sheet
    /// can block swipe-to-dismiss over an unsaved drawing. Nil when there is no host to tell.
    var studioDraftIsDirty: Binding<Bool>? = nil

    /// The listing refusals (`store.listCustomItemForSale`) surfaced from the swipe "Sell" action.
    @State private var shopAlert: ShopAlert?
    /// The pending swipe-to-delete. Deleting a designed item is irreversible, so the swipe only ever
    /// ASKS — the delete itself runs from the confirmation's `perform`.
    @State private var pendingDelete: DestructiveConfirmation?
    /// Drives the push into a NEW item's studio. Both entry points (the top row and the empty-closet
    /// invitation) are plain buttons feeding this, so neither inherits the `List`'s extra chevron.
    @State private var isDesigningNewItem = false
    /// Drives the push into an EXISTING item's studio, by id rather than by value: the studio saves
    /// through the store, so a value-keyed route would change identity on save and tear its own
    /// destination down mid-flight.
    ///
    /// A binding-driven push (not a `NavigationLink`) because the closet is what pops the studio —
    /// see ``CreationStudioView/leaveStudio()``: the studio's environment `dismiss` cannot pop
    /// itself from the confirmation step above it, and takes the whole customization sheet down
    /// with it when it tries.
    @State private var editingItemID: UUID?
    /// Drives the push into Your shop (`b2-shop-editor`, which opens from Friend shops and from here).
    /// A plain button + `navigationDestination`, like the studio's, so the `List` adds no second chevron.
    @State private var isShowingShop = false

    /// "Wardrobe", the page's title on the plate.
    static let title = LocalizedStringResource("Wardrobe", comment: "Wardrobe page title: the companion's closet of designed items")

    var body: some View {
        List {
            designNewSection
            shopStatusSection
            yourItemsHeaderSection
            slotSections
            emptyClosetSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .fernletPageBackground()
        // Under the Today panel's plate: ‹ Customize, Wardrobe, ✕ (design `b2-wardrobe`).
        .fernletPushedPage(Self.title)
        // The coin balance moved to the customization sheet's leading header slot (3e /
        // XCUT-14): the wallet now greets the user one screen EARLIER on the same stack, so
        // the closet no longer needs its own copy in the toolbar.
        .alert(item: $shopAlert) { $0.alert(in: .wardrobe) }
        .destructiveConfirmation($pendingDelete)
        .navigationDestination(isPresented: $isDesigningNewItem) {
            CreationStudioView(store: store,
                               draftIsDirty: studioDraftIsDirty,
                               onExit: { isDesigningNewItem = false })
        }
        .navigationDestination(item: $editingItemID) { id in
            editor(forItemID: id)
        }
        .navigationDestination(isPresented: $isShowingShop) {
            YourShopView(store: store)
                .fernletPushedPage("Your shop")
        }
    }

    /// The edit-path studio, resolved from the live store so a save is reflected without re-pushing.
    /// The item can vanish underneath us (a delete from another surface); an empty closet screen is
    /// a better answer than a force-unwrap.
    @ViewBuilder
    private func editor(forItemID id: UUID) -> some View {
        if let item = store.customItems.first(where: { $0.id == id }) {
            CreationStudioView(store: store,
                               editingItem: item,
                               draftIsDirty: studioDraftIsDirty,
                               onExit: { editingItemID = nil })
        } else {
            Color.parchment.ignoresSafeArea()
        }
    }

    /// The row that pushes the Creation Studio.
    ///
    /// A plain `Button` + `navigationDestination`, not a `NavigationLink`: inside a `List` the link
    /// adds the system disclosure chevron OUTSIDE the cream card, next to the one the card already
    /// draws. One row, one chevron.
    private var designNewSection: some View {
        Section {
            Button { isDesigningNewItem = true } label: {
                designNewItemRow
            }
            .buttonStyle(.plain)
            .plainClosetRow(insets: EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
        }
    }

    /// Your shop (`b2-shop-editor`: the approved editor opens "from Friend shops and from the
    /// Wardrobe"), then the one-line shop summary, shown only when there is a shop to summarize.
    private var shopStatusSection: some View {
        Section {
            Button { isShowingShop = true } label: {
                CustomizeLinkCard(sprite: FriendsSprites.shop, title: Text("Your shop"),
                                  detail: Text("What friends nearby can buy from you"))
            }
            .buttonStyle(.plain)
            .plainClosetRow(insets: EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
            shopStatusLine
        }
    }

    /// The one-line shop summary, shown only when there is a shop to summarize.
    @ViewBuilder
    private var shopStatusLine: some View {
        if !store.listedShopItems.isEmpty || store.shopUpdatedToday {
            HStack(spacing: 6) {
                Image(systemName: "bag")
                    .font(.system(size: 13))
                    .foregroundStyle(WorldPalette.mossInk)
                Text(shopStatusText)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(WorldPalette.dim)
            }
            .plainClosetRow(insets: EdgeInsets(top: 2, leading: 24, bottom: 6, trailing: 24))
        }
    }

    /// The "Your items" label above the per-slot sections.
    @ViewBuilder
    private var yourItemsHeaderSection: some View {
        if !store.customItems.isEmpty {
            Section {
                sectionLabel("Your items")
                    .plainClosetRow(insets: EdgeInsets(top: 6, leading: 24, bottom: 4, trailing: 24))
            }
        }
    }

    /// One section per slot that actually holds items.
    private var slotSections: some View {
        ForEach(ItemSlot.allCases) { slot in
            let items = store.customItems.filter { $0.slot == slot }
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        row(for: item)
                            .plainClosetRow(insets: EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                    }
                } header: {
                    Text(slot.label)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(WorldPalette.dim)
                        .textCase(nil)
                }
            }
        }
    }

    /// The empty-closet invitation, shown only when nothing has been designed yet.
    @ViewBuilder
    private var emptyClosetSection: some View {
        if store.customItems.isEmpty {
            Section {
                emptyCloset
                    .plainClosetRow(insets: EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
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

    /// The "Design a new item" card (design `b2-wardrobe`): a framed plus tile, the title, the Studio line.
    private var designNewItemRow: some View {
        CustomizeLinkCard(sprite: WorldSprites.plus, title: Text("Design a new item"),
                          detail: Text("Open the Creation Studio"))
    }

    /// `LocalizedStringKey`, not `String` (review A4 follow-up F5). As a `String` the caption bound
    /// `Text`'s VERBATIM overload, so the word was never harvested and `.textCase` had no catalog
    /// lookup to run after — the modifier was inert and the string absent from every catalog. With
    /// the key type the transform does what its comment claims: it uppercases the TRANSLATION.
    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        SectionLabel(text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for item: CustomizationItem) -> some View {
        let isEquipped = store.equippedCustomItems.contains { $0.id == item.id }
        // A plain `Button` feeding `editingItemID`, not a `NavigationLink`, for the same two reasons
        // the "Design a new item" row is one: the closet has to be able to POP this studio, and
        // inside a `List` the link hangs the system disclosure chevron outside the cream card. The
        // card draws its own instead.
        Button { editingItemID = item.id } label: {
            FernletCard {
            HStack(spacing: 12) {
                CustomItemThumbnail(texture: item.texture, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.isEmpty ? item.slot.label : item.name)
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(WorldPalette.bark)
                    provenance(for: item)
                }

                Spacer(minLength: 8)

                if isEquipped {
                    equippedPill
                }

                FernletIcon(.chevron, scale: 2)
            }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                // Report B16: an equip landed in place (`logged`, with the "Equipped" pill as its
                // twin); taking one off is just a changed choice. The swipe's own system feel
                // stays as it is.
                FernletFeedback.system.play(isEquipped ? .tick : .logged)
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
        // `allowsFullSwipe: false`: a full swipe used to delete a hand-drawn (or bought) item
        // outright, with no confirmation and no undo. The swipe now only opens the question.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = deleteConfirmation(for: item)
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

    /// The "are you sure" behind the swipe Delete. Names the item and what leaving the closet costs
    /// (it comes off the companion too), and routes through the audited app-target confirmation so
    /// the deletion leaves the same trail every other destructive path does.
    private func deleteConfirmation(for item: CustomizationItem) -> DestructiveConfirmation {
        let label = item.name.isEmpty ? item.slot.label : item.name
        return DestructiveConfirmation(
            title: "Delete “\(label)”?",
            message: "It leaves your closet and your companion. This can't be undone.",
            confirmLabel: "Delete",
            auditEvent: "wardrobe.customItem.deleted",
            perform: { store.deleteCustomItem(id: item.id) }
        )
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
                        .font(FernletFramedFont.rowDetail)
                        // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                        .foregroundStyle(WorldPalette.mossInk)
                }
            } else {
                Text("designed by you")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
            }
        } else {
            Text("Designed by \(store.designerDisplayName(for: item))")
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
        }
    }

    private var equippedPill: some View {
        FernletTag("Equipped")
    }

    // MARK: - Empty state

    /// The empty closet (design `b2-wardrobe`): the pixel face, the title, the invitation and the button,
    /// in a framed card.
    private var emptyCloset: some View {
        FernletCard {
            VStack(spacing: 10) {
                WorldSpriteView(sprite: WorldSprites.face, scale: 4)
                    .padding(.top, 8)
                Text("Your closet is empty")
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(WorldPalette.bark)
                    .multilineTextAlignment(.center)
                // The end of this line was held back until the map drew custom pieces (owner Q6); it
                // shows since round 6 lane 2 ("wardrobe drawings on the map").
                Text("Make the first little thing for your companion to wear. New creations appear on your companion right away, and on the map as pixel art.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
                // A plain Button, not a NavigationLink: inside a `List` the link hung a stray system
                // chevron off the right of this pill.
                Button("Design your first item") { isDesigningNewItem = true }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
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
        let outcome = store.listCustomItemForSale(id: item.id, price: price)
        if let cue = Self.listingFeedbackEvent(for: outcome) { FernletFeedback.system.play(cue) }
        switch outcome {
        case .listed: break
        case .notAllowed:
            // Unreachable behind the `isShareable`/self-designed gate above — but an unreachable
            // refusal that does nothing is invisible if that gate ever drifts, so name it.
            assertionFailure("toggleListing reached .notAllowed behind the self-designed guard")
        case .nameFlagged: shopAlert = .nameFlagged
        case .capReached: shopAlert = .capReached
        case .storeBanned(let remainingSeconds): shopAlert = .storeBanned(remainingSeconds: remainingSeconds)
        }
    }
}

extension WardrobeView {
    /// What a swipe "Sell" feels like once the shop has answered (report B16): a refusal is a
    /// `caveat` — the item is fine, and the alert says why it isn't in the shop. A listing that
    /// lands plays nothing extra: the swipe has its own system feel, and the row's "In your shop"
    /// line shows it. Unlisting never refuses.
    static func listingFeedbackEvent(for outcome: FernletStore.ShopListingResult) -> FernletFeedbackEvent? {
        switch outcome {
        case .listed, .notAllowed: nil
        case .nameFlagged, .capReached, .storeBanned: .caveat
        }
    }
}

private extension View {
    /// The closet's repeated row chrome: custom insets, a clear background, and no separator.
    func plainClosetRow(insets: EdgeInsets) -> some View {
        listRowInsets(insets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
