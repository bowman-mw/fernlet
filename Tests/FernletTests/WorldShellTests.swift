import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The World Home's shell (World app plan steps 1b and 2b): which panel is which tab, the item bar,
/// the Home cards each panel draws, the approved sprites, and the wiring that keeps every tab gate.
@MainActor
struct WorldShellTests {

    @Test func everyTabHasExactlyOnePanelAndHomeIsTheMap() {
        for tab in FernletTab.allCases where tab != .home {
            let panel = WorldPanel.panel(for: tab)
            #expect(panel?.tab == tab, "\(tab) has no panel")
        }
        #expect(WorldPanel.panel(for: .home) == nil, "Home is the map, not a panel")
        #expect([WorldPanel.today, .log, .settings].allSatisfy { $0.tab == nil }, "Today, Log and Settings leave the tab on Home")
    }

    @Test func theItemBarIsTheApprovedSixWithLogInTheMiddle() {
        #expect(WorldPanel.itemBar == [.food, .move, .log, .friends, .personal, .settings])
        #expect(Set(WorldPanel.itemBar.map(\.itemIdentifier)).count == 6)
        #expect(WorldPanel.itemBar.allSatisfy { !$0.barName.isEmpty && !$0.title.isEmpty })
    }

    @Test func theLogPanelDrawsHomesQuickLogEvenWhenHomeHidesIt() {
        let order: [HomeWidget] = [.companion, .macros, .milestones]
        #expect(HomePresentation.quickLog.widgets(from: order) == [.quickLog])
        #expect(HomePresentation.page.widgets(from: order) == order, "Today keeps the person's Home order")
    }

    @Test func everySpriteIsARectangleWhoseKeysAllHaveColours() {
        let sprites: [WorldSprite] = [
            WorldSprites.heart, WorldSprites.drop, WorldSprites.onigiri, WorldSprites.shoe, WorldSprites.basket,
            WorldSprites.face, WorldSprites.diary, WorldSprites.gear, WorldSprites.heartSm, WorldSprites.xx,
            WorldSprites.leaf, WorldSprites.pin, WorldSprites.chevR, WorldSprites.plus,
        ]
        for sprite in sprites {
            #expect(sprite.width > 0 && sprite.rows.allSatisfy { $0.count == sprite.width })
            let keys = Set(sprite.rows.joined()).subtracting(["."])
            #expect(keys.isSubset(of: Set(sprite.palette.keys)), "a key with no colour would draw nothing")
        }
        #expect(WorldTheme.pixel.icons.count == WorldPanel.allCases.count, "every panel has its pixel icon")
    }

    @Test func heartsAndDropsRecolourAsTheDesignDrawsThem() {
        #expect(WorldSpriteVariant.heart(.half).colour(for: "R", column: 1) == nil, "a half heart's left stays red")
        #expect(WorldSpriteVariant.heart(.half).colour(for: "R", column: 5) == 0x8E5E4A)
        #expect(WorldSpriteVariant.heart(.gold).colour(for: "R", column: 2) == 0xF2C14E)
        #expect(WorldSpriteVariant.heart(.empty).colour(for: "k", column: 0) == nil, "the outline never changes")
        #expect(WorldSpriteVariant.drop(full: false).colour(for: "B", column: 2) == 0xA9BCC2)
        #expect(WorldSpriteVariant.drop(full: true).colour(for: "B", column: 2) == nil)
    }

    /// The root keeps one `TabView` whose pages are Home and the four tab panels, builds `HomeView` once
    /// (for Today and Log), and keeps every gate keyed off the selected tab.
    @Test func theRootKeepsTheTabViewAndEveryGate() throws {
        let content = try RepoRoot.source("App/Fernlet/ContentView.swift")
        #expect(content.components(separatedBy: "TabView(selection: $selectedTab)").count - 1 == 1)
        #expect(content.components(separatedBy: "HomeView(").count - 1 == 1, "HomeView is built once, for the Today and Log panels")
        for page in [".tabPage(.home)", ".tabPage(.food)", ".tabPage(.move)", ".tabPage(.social)", ".tabPage(.personal)"] {
            #expect(content.contains(page), "\(page) is gone")
        }
        #expect(content.contains("isActive: selectedTab == .personal, isFrontmost: selectedTab == .personal && !rootSheetIsCoveringTabs"),
                "the Private hub's lock and capture gates still key off the tab")
        #expect(content.contains("if newTab != .home { worldOverlay = nil }"), "a card that opens a tab leaves the overlay")
    }
}
