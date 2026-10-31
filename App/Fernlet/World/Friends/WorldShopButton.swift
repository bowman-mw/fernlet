import FernletConnections
import FernletDomainModel
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI

/// Friend shops on Home (World Review Batch 4, `b4-mem-home-shop`, approved 2026-10-24): while a
/// friend's shop is open after a hangout, the bottom-left button — where the session button sits during
/// one — is a gold shop button with a pixel bag and a tag with how many shops are open ("8", World
/// Friends §3, `fr-shop-line`). It opens Friend shops (`b2-friend-shop`) on the newest shop, where Your
/// shop is still the bottom row.
///
/// It is the shops' entry point now that the Album page has no shop row: drawn while any friend's shop
/// is open (``WorldFriendShops/open(store:at:)``, each shop lazily closing at the end of its own hour),
/// never during a hangout (the session button holds the corner then) and never in a decoy; it goes when
/// the last shop closes. A minute tick redraws the count. Like the session button, it fills the frame it
/// is given and anchors itself to the bottom-left corner.
struct WorldShopButton: View {
    var store: FernletStore
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack(alignment: .bottomLeading) {
                if let count = Self.openCount(store: store, at: context.date) {
                    button(count: count)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// Minutes left in the newest open shop's hour (the last to close), or nil when the button hides.
    /// Page 1 of Sprout's passport reads it for its gold Friend shops row, over the same list.
    static func minutesLeft(store: FernletStore, at date: Date) -> Int? {
        let manager = store.meshNetworkManager
        guard !manager.isInSession, !store.duressSessionActive else { return nil }
        if let staged = FriendsUITestHooks.shopWindowMinutes { return staged }
        return WorldFriendShops.open(store: store, at: date).first?.minutesLeft(at: date)
    }

    /// How many friends' shops are open, the badge's number, or nil when the button hides. The DEBUG
    /// screenshot hook's staged window reads as one shop.
    static func openCount(store: FernletStore, at date: Date) -> Int? {
        guard !store.meshNetworkManager.isInSession, !store.duressSessionActive else { return nil }
        if FriendsUITestHooks.shopWindowMinutes != nil { return 1 }
        let count = WorldFriendShops.open(store: store, at: date).count
        return count > 0 ? count : nil
    }

    /// The gold 58-pt framed square with the bag, and the count tag on its corner.
    private func button(count: Int) -> some View {
        Button(action: onOpen) {
            WorldSpriteView(sprite: FriendsSprites.bag, scale: dynamicTypeSize.isAccessibilitySize ? 5 : 4)
                .frame(width: 58, height: 58)
                .background(Self.gold, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) { Self.goldLow.frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
                .overlay(alignment: .top) { Self.goldHigh.frame(height: 3).padding(.horizontal, 3).padding(.top, 3) }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Self.goldEdge, lineWidth: 3))
                .background { RoundedRectangle(cornerRadius: 12).fill(WorldPalette.ink.opacity(0.4)).offset(y: 3) }
                .overlay(alignment: .topTrailing) { countTag(count).offset(x: 14, y: -12) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .accessibilityLabel(Text(verbatim: WorldShopCopy.buttonSpoken(open: count)))
        // Voice Control: the shops' name, without the count that changes as shops close.
        .accessibilityInputLabels([Text("Friend shops"), Text("Shops")])
        .accessibilityIdentifier("world.shop.button")
    }

    /// "8" on paper in the ink frame, as the session button's count badge.
    private func countTag(_ count: Int) -> some View {
        Text(count, format: .number)
            .font(FernletFramedFont.buttonSmall)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .foregroundStyle(WorldPalette.rgb(0x3A2414))
            .padding(.horizontal, 6)
            .frame(minWidth: 26, minHeight: 26)
            .background(WorldPalette.rgb(0xFFFDF8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .accessibilityHidden(true)
    }

    /// The button's gold face, frame and inset edges (the design's `#E2B65E` family), the same in dark
    /// mode: the bag is drawn in its own ink on it.
    static let gold = WorldPalette.rgb(0xE2B65E)
    static let goldEdge = WorldPalette.rgb(0x8A5A1E)
    static let goldLow = WorldPalette.rgb(0xC99A3E)
    static let goldHigh = WorldPalette.rgb(0xF2D58A)
}
