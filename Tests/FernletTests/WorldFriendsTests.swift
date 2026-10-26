import Foundation
import Testing
import FernletDomainModel
import SwiftUI
@testable import Fernlet

/// The World build's Friends lane: your shop's partition and price arithmetic (`b2-shop-editor`), the
/// session row's and session button's name lists (`b3-friends-session`, `b3-home-session`), and the
/// Friends album's routes.
@MainActor
struct WorldFriendsTests {

    private let mine = ItemDesigner(id: UUID())
    private let friend = ItemDesigner(id: UUID())

    private func item(_ name: String, by designer: ItemDesigner, listed: Bool, price: Int = 20) -> CustomizationItem {
        CustomizationItem(name: name, slot: .body,
                          texture: ItemGridTexture.blank(for: .body, palette: ItemDesignPalette.hexes),
                          designer: designer, isShareable: listed, price: price)
    }

    /// Only your own designs are in your shop or offered for it; a friend's item never is, listed or
    /// not (provenance: no reselling), and the closet's order is kept.
    @Test func yourShopSplitsYourOwnDesignsOnly() {
        let items = [
            item("Blue beanie", by: mine, listed: true),
            item("Gift scarf", by: friend, listed: true),
            item("Moss mittens", by: mine, listed: false),
            item("Star scarf", by: mine, listed: true),
            item("Borrowed cap", by: friend, listed: false)
        ]
        let plan = YourShopPlan.partition(items) { $0.designer.id == mine.id }
        #expect(plan.listed.map(\.name) == ["Blue beanie", "Star scarf"])
        #expect(plan.unlisted.map(\.name) == ["Moss mittens"])
    }

    /// The price stepper keeps to 1…100 coins, and an out-of-range stored price is clamped first.
    @Test func yourShopPricesStayBetweenOneAndAHundred() {
        #expect(YourShopPlan.stepped(20, by: 1) == 21)
        #expect(YourShopPlan.stepped(20, by: -1) == 19)
        #expect(YourShopPlan.stepped(100, by: 1) == 100)
        #expect(YourShopPlan.stepped(1, by: -1) == 1)
        #expect(!YourShopPlan.canStep(100, by: 1) && YourShopPlan.canStep(100, by: -1))
        #expect(!YourShopPlan.canStep(1, by: -1) && YourShopPlan.canStep(1, by: 1))
        #expect(YourShopPlan.stepped(0, by: 1) == 2, "a stored 0 reads as the 1-coin floor before the step")
        #expect(YourShopPlan.stepped(140, by: -1) == 99)
    }

    /// The session row's short list and the button's sentence, in English.
    @Test func sessionNamesReadAsOneList() {
        #expect(FriendsSessionNames.sentence(["Sam"]) == "Sam")
        #expect(FriendsSessionNames.sentence(["Sam", "Rae"]).contains("Rae"))
        #expect(FriendsSessionNames.narrow(["Sam", "Rae"]).contains("Sam"))
        #expect(FriendsSessionNames.narrow([]).isEmpty)
    }

    /// The camera's framed window (`b3-camera-session`): under the title row, 24 pt in, about 4:5 in
    /// portrait and never into the controls; 4:3 and clear of the side rails in landscape.
    @Test func theViewfinderWindowFitsBetweenTheTitleAndTheControls() {
        let insets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        let portrait = DisposableCameraView.viewfinderRect(in: CGSize(width: 402, height: 778), safeArea: insets, landscape: false)
        #expect(portrait.minX == 24 && portrait.width == 354)
        #expect(abs(portrait.minY - 126) < 0.001, "under the title row")
        #expect(abs(portrait.height - 354 * 1.21) < 0.5, "4:5-ish when there is room")
        let short = DisposableCameraView.viewfinderRect(in: CGSize(width: 402, height: 600), safeArea: insets, landscape: false)
        #expect(abs(short.height - 336) < 0.001, "never down into the controls")
        let wide = DisposableCameraView.viewfinderRect(in: CGSize(width: 800, height: 380),
                                                       safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
                                                       landscape: true)
        #expect(wide.width <= 800 - 260, "clear of the film rail and the shutter")
        #expect(abs(wide.width / wide.height - 4 / 3) < 0.01)
        #expect(abs(wide.midX - 459) < 0.001, "centred in the safe area")
    }

    /// Your shop sits above Friend shops, so the shop window lapsing takes both off the stack.
    @Test func yourShopClosesWithTheFriendShopWindow() {
        let path: [FriendsRoute] = [.friendShop, .yourShop]
        #expect(FriendsRoute.closingShop(path).isEmpty)
        #expect(FriendsRoute.closingShop([.activities]) == [.activities])
    }
}
