import FernletDomainModel
import FernletSocial
import FernletUI
import SwiftUI

/// The row of friends across the top of Friend shops (World Friends §3, `fr-shop-switch`, approved
/// 2026-10-31): one chip per open shop — the friend's companion, their name and the minutes left in
/// their shop's hour — newest hangout first. It scrolls sideways once the chips outgrow the page (a
/// hangout holds up to 16 people) and acts as tabs: the chip picked shows that friend's shop below, and
/// VoiceOver reads "Sam, 52 minutes left, selected". A minute tick redraws the minutes.
struct FriendShopSwitcher: View {
    /// The open shops, newest hangout first.
    let shops: [MeshClothingShop.OpenShop]
    /// The shop shown below the row.
    let selectedID: String?
    let onSelect: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(shops) { shop in
                            chip(shop, minutes: shop.minutesLeft(at: context.date), isSelected: shop.id == selectedID)
                                .id(shop.id)
                        }
                    }
                    // Room for the picked chip's 2-pt ink shadow and its frame.
                    .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Open shops"))
        .accessibilityIdentifier("friendShop.switcher")
    }

    /// One friend's chip: the companion over the name and the minutes, framed in the rule; picked, the
    /// lighter paper in the ink frame with an ink shadow under it.
    private func chip(_ shop: MeshClothingShop.OpenShop, minutes: Int, isSelected: Bool) -> some View {
        let name = WorldFriendShops.sellerName(shop.catalog)
        let shape = RoundedRectangle(cornerRadius: 10)
        return Button { onSelect(shop.id) } label: {
            VStack(spacing: 2) {
                WorldCompanionSprite(state: .thriving,
                                     look: WorldCompanionLook(appearance: .standard, state: .thriving, asleep: false),
                                     isActive: false, pixelScale: 1.4)
                Text(verbatim: name)
                    .font(.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .footnote))
                    .foregroundStyle(WorldPalette.bark)
                    .lineLimit(1)
                    .fixedSize()
                Text("\(minutes) min")
                    .font(.custom(FernletFontName.dmSans, size: 11.5, relativeTo: .caption))
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize()
            }
            .padding(EdgeInsets(top: 6, leading: 6, bottom: 5, trailing: 6))
            .frame(minWidth: 64, minHeight: 66, alignment: .top)
            .background(isSelected ? WorldPalette.paperLight : WorldPalette.paper, in: shape)
            .overlay(shape.strokeBorder(isSelected ? WorldPalette.ink : WorldPalette.rule, lineWidth: 2))
            .background { if isSelected { shape.fill(WorldPalette.ink).offset(y: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: WorldShopCopy.chipSpoken(name: name, minutes: minutes)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Voice Control: the friend's name, without the minutes that change by the minute.
        .accessibilityInputLabels([Text(verbatim: name)])
        .accessibilityIdentifier("friendShop.chip")
    }
}
