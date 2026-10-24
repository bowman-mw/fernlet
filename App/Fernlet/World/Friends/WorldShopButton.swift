import FernletConnections
import FernletUI
import ProximityKit
import SwiftUI

/// Friend shops on Home (World Review Batch 4, `b4-mem-home-shop`, approved 2026-10-24): for the hour
/// after a session, the bottom-left button — where the session button sits during one — is a gold shop
/// button with a pixel bag and a tag with the minutes left ("52m"). It opens Friend shops
/// (`b2-friend-shop`), where Your shop is still the bottom row.
///
/// It is the shop window's entry point now that the Album page has no shop row: drawn while the
/// post-session window is open (`MeshClothingShop.remainingWindowMinutes`, lazy — nil once lapsed) and
/// nearby clothing sharing is on, never during a session (the window closes when the next one starts,
/// so there's never both) and never in a decoy. A minute tick redraws the countdown. Like the session
/// button, it fills the frame it is given and anchors itself to the bottom-left corner.
struct WorldShopButton: View {
    var store: FernletStore
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ZStack(alignment: .bottomLeading) {
                if let minutes = minutesLeft(at: context.date) {
                    button(minutes: minutes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// Minutes left in the shop window, or nil when the button hides.
    private func minutesLeft(at date: Date) -> Int? {
        let manager = store.meshNetworkManager
        guard !manager.isInSession, !store.duressSessionActive else { return nil }
        if let staged = FriendsUITestHooks.shopWindowMinutes { return staged }
        guard store.settings.allowNearbyClothingShares else { return nil }
        return store.meshFeatures.clothingShop.remainingWindowMinutes(at: date)
    }

    /// The gold 58-pt framed square with the bag, and the minutes tag on its corner.
    private func button(minutes: Int) -> some View {
        Button(action: onOpen) {
            WorldSpriteView(sprite: FriendsSprites.bag, scale: dynamicTypeSize.isAccessibilitySize ? 5 : 4)
                .frame(width: 58, height: 58)
                .background(Self.gold, in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) { Self.goldLow.frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
                .overlay(alignment: .top) { Self.goldHigh.frame(height: 3).padding(.horizontal, 3).padding(.top, 3) }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Self.goldEdge, lineWidth: 3))
                .background { RoundedRectangle(cornerRadius: 12).fill(WorldPalette.ink.opacity(0.4)).offset(y: 3) }
                .overlay(alignment: .topTrailing) { minutesTag(minutes).offset(x: 14, y: -12) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .accessibilityLabel(Text("Friend shops open, \(minutes) minutes left"))
        // Voice Control: the shops' name, without the countdown that changes by the minute.
        .accessibilityInputLabels([Text("Friend shops"), Text("Shops")])
        .accessibilityIdentifier("world.shop.button")
    }

    /// "52m" on paper in the ink frame, as the session button's count badge.
    private func minutesTag(_ minutes: Int) -> some View {
        Text("\(minutes)m")
            .font(FernletFramedFont.buttonSmall)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .foregroundStyle(WorldPalette.rgb(0x3A2414))
            .padding(.horizontal, 6)
            .frame(minHeight: 26)
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
