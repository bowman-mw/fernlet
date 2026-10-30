import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletUI

/// The companion customization sheet, for the World map's hold on the companion: ``CompanionCustomizationPage``
/// in its own stack under the sheet's paper header, “Customize” with Done.
///
/// The Today panel pushes the same page under its plate (design `b2-customize`). Here the sheet blocks
/// swipe-to-dismiss while a Creation Studio pushed anywhere on its stack holds unsaved paint.
struct CompanionCustomizationSheet: View {
    var store: FernletStore
    @Binding var petCount: Int
    @Environment(\.dismiss) private var dismiss
    /// Raised by a ``CreationStudioView`` pushed anywhere on this stack while it holds unsaved paint.
    @State private var isStudioDraftDirty = false

    var body: some View {
        NavigationStack {
            CompanionCustomizationPage(store: store, petCount: $petCount, isStudioDraftDirty: $isStudioDraftDirty)
                .fernletSheetToolbar(title: "Customize", onDone: { dismiss() })
        }
        .fernletSheet()
        .interactiveDismissDisabled(isStudioDraftDirty)
    }
}

/// Customize (design `b2-customize`, approved 2026-10-23): the coin pill, the close-up and on-the-map
/// previews, Wardrobe and Creation Studio, App colors, and one row per slot (body, accessory, clothing,
/// side item), each pushing its picker (`b2-slot-picker`).
///
/// A page inside the Today panel, opened from its Customize button (and in a sheet from the map's hold,
/// ``CompanionCustomizationSheet``). All writes go through `FernletStore.setCompanionAppearance` / the
/// equip APIs, so the previews and the map stay in lockstep. Wardrobe and Studio stay reachable only
/// through this stack's push wiring (binding-driven with `onExit`), so the studio's exit never tears
/// the stack down.
struct CompanionCustomizationPage: View {
    var store: FernletStore
    @Binding var petCount: Int
    /// Raised while a pushed ``CreationStudioView`` holds unsaved paint (the sheet blocks swipe-down).
    @Binding var isStudioDraftDirty: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Drives the root-level push into a NEW item's studio (HOME-30), binding-driven with `onExit`.
    @State private var isDesigningFromRoot = false
    /// "Hold to peek" at night, shared by the page and its slot pages (`comp-cust-night`).
    @State private var peek = CustomizePeek()

    /// "Customize", the page's title on the plate.
    static let title = LocalizedStringResource("Customize", comment: "Customize page title: the companion's look, Wardrobe and Creation Studio")

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                topRow
                CustomizePreviewSection(store: store, peek: $peek)
                libraryRows
                NavigationLink {
                    AppColorsPage(store: store)
                } label: {
                    CustomizeAppColorsCard()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("companion.appColors")
                FernletFramedSection {
                    ForEach(CustomizeSlotSummary.current(store: store), id: \.slot) { summary in
                        slotRow(summary)
                    }
                }
                unlockedFooter
            }
            .padding(20)
        }
        .fernletPageBackground()
        .navigationDestination(isPresented: $isDesigningFromRoot) {
            CreationStudioView(store: store,
                               draftIsDirty: $isStudioDraftDirty,
                               onExit: { isDesigningFromRoot = false })
        }
    }

    /// “Tap a slot to change it.” and the coin balance (moved here from the Wardrobe, HOME-22).
    private var topRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Tap a slot to change it.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
            Spacer(minLength: 8)
            CustomizeCoinPill(balance: store.coinBalance)
        }
    }

    /// Wardrobe and Creation Studio side by side, or stacked at accessibility text sizes.
    private var libraryRows: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            wardrobeRow
            studioRow
        }
    }

    /// The Wardrobe card: the closet with its item count. Carries the `companion.wardrobe` test token.
    private var wardrobeRow: some View {
        NavigationLink {
            WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
        } label: {
            CustomizeLinkCard(sprite: WorldSprites.face, title: Text("Wardrobe"), detail: wardrobeCountText,
                              keepsTitleOnOneLine: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.wardrobe")
    }

    private var wardrobeCountText: Text? {
        let count = store.customItems.count
        guard count > 0 else { return nil }
        return Text(verbatim: HomeCopy.wardrobeItemCount(count))
    }

    /// The Creation Studio card — a straight door to designing a new item.
    private var studioRow: some View {
        Button {
            isDesigningFromRoot = true
        } label: {
            CustomizeLinkCard(sprite: WorldSprites.pen, title: Text("Creation Studio"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.studio")
    }

    /// The reassurance line closing the page.
    private var unlockedFooter: some View {
        Text("Everything you've unlocked stays unlocked.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    // MARK: Selector rows — one per slot, each showing what's worn and pushing its page.

    /// A slot's row: its piece, its name and what is worn there, pushing its page (``CustomizeSlotPage``).
    private func slotRow(_ summary: CustomizeSlotSummary) -> some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            CustomizeSlotPage(store: store, slot: summary.slot, peek: $peek, isStudioDraftDirty: $isStudioDraftDirty)
        } label: {
            CustomizeSlotRowLabel(slot: Text(summary.slot.title), value: summary.value, isEmpty: summary.isEmpty) {
                CustomizeSlotIcon(slot: summary.slot, appearance: appearance, state: store.liveCompanionState)
            }
        }
        .buttonStyle(FernletRowButtonStyle())
    }
}

/// The four slots' names, for their pages' titles on the plate (and the sheet's bar).
nonisolated enum CustomizeSlotTitle {
    static let body = LocalizedStringResource("Body", comment: "Customize: the body slot's page title and row name")
    static let accessory = LocalizedStringResource("Accessory", comment: "Customize: the accessory slot's page title and row name")
    static let clothing = LocalizedStringResource("Clothing", comment: "Customize: the clothing slot's page title and row name")
    static let sideItem = LocalizedStringResource("Side item", comment: "Customize: the side-item slot's page title and row name")
}
