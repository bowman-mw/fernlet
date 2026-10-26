import Foundation
import Testing
import FernletUI
import SwiftUI
@testable import Fernlet

/// The World build's foundation (lane "foundation"): the plate that pushed pages hand their title and
/// Back to, the Back's long-title rule, the stepper's arithmetic, the tile grid's columns, the pixel
/// icons behind FernletUI's framed primitives, and the one-colour icons that take the ink token in dark
/// mode.
@MainActor
struct WorldFoundationTests {

    /// A clock the tests move by hand.
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func plate(_ clock: Clock) -> FernletPlateNavigation {
        FernletPlateNavigation(rootTitle: "Settings", now: { clock.now })
    }

    @Test func aPushedPageShowsItsTitleAndBacksToThePanel() {
        let clock = Clock()
        let nav = plate(clock)
        #expect(nav.top == nil, "the panel's own page shows the panel's title")
        var popped = 0
        nav.show(id: UUID(), title: "Appearance", pop: { popped += 1 })
        #expect(nav.top?.title == "Appearance")
        #expect(nav.topBackTitle == "Settings")
        // The plate's Back pops it, and a bottom page goes at once.
        nav.popTop()
        #expect(popped == 1)
        #expect(nav.top == nil && nav.pages.isEmpty)
    }

    /// A push reports the new page's appearance and the covered page's disappearance in either order;
    /// a pop reports the popped page's disappearance and the revealed page's appearance in either order.
    @Test func pushAndPopHoldWhicheverEventComesFirst() {
        let clock = Clock()
        for (coverFirst, revealFirst) in [(false, false), (false, true), (true, false), (true, true)] {
            let nav = plate(clock)
            let first = UUID(), second = UUID()
            nav.show(id: first, title: "Privacy & Data", pop: {})
            if coverFirst { nav.hide(id: first) }
            nav.show(id: second, title: "Export", pop: {})
            if !coverFirst { nav.hide(id: first) }
            #expect(nav.top?.title == "Export")
            #expect(nav.topBackTitle == "Privacy & Data", "Back names the page under it")
            if revealFirst {
                nav.show(id: first, title: "Privacy & Data", pop: {})
                nav.hide(id: second)
            } else {
                nav.hide(id: second)
                nav.show(id: first, title: "Privacy & Data", pop: {})
            }
            #expect(nav.top?.title == "Privacy & Data")
            #expect(nav.topBackTitle == "Settings")
            #expect(nav.pages.count == 1, "the popped page is gone")
        }
    }

    /// An edge swipe let go halfway reveals the page under for a moment and hides it again: the plate
    /// keeps the page that stayed.
    @Test func aCancelledSwipeKeepsThePageShowing() {
        let clock = Clock()
        let nav = plate(clock)
        let first = UUID(), second = UUID()
        nav.show(id: first, title: "Appearance", pop: {})
        nav.show(id: second, title: "App colors", pop: {})
        nav.hide(id: first)
        nav.show(id: first, title: "Appearance", pop: {})
        #expect(nav.top?.title == "App colors", "the page on top is still showing")
        nav.hide(id: first)
        #expect(nav.top?.title == "App colors" && nav.topBackTitle == "Appearance")
    }

    @Test func aCoverHidesThePageWithoutForgettingIt() {
        let clock = Clock()
        let nav = plate(clock)
        let first = UUID(), second = UUID()
        nav.show(id: first, title: "Appearance", pop: {})
        nav.show(id: second, title: "App colors", pop: {})
        nav.hide(id: first)
        nav.hide(id: second)
        #expect(nav.top == nil, "nothing on the plate while a full-screen cover hides the page")
        clock.now += 30
        nav.show(id: second, title: "App colors", pop: {})
        #expect(nav.top?.title == "App colors" && nav.topBackTitle == "Appearance")
    }

    /// A stack opened two deep at once records only the page that shows; the plate's own Back drops it
    /// at once, so the page revealed under it backs to the panel.
    @Test func backFromAStackOpenedDeepLandsOnAPageThatBacksToThePanel() {
        let clock = Clock()
        let nav = plate(clock)
        nav.show(id: UUID(), title: "App colors", pop: {})
        #expect(nav.topBackTitle == "Settings", "the page under it never showed")
        nav.popTop()
        nav.show(id: UUID(), title: "Appearance", pop: {})
        #expect(nav.top?.title == "Appearance" && nav.topBackTitle == "Settings")
    }

    @Test func pagesLeftBehindByAPopToRootAreDroppedOnTheNextPush() {
        let clock = Clock()
        let nav = plate(clock)
        let first = UUID(), second = UUID()
        nav.show(id: first, title: "Appearance", pop: {})
        nav.show(id: second, title: "App colors", pop: {})
        nav.hide(id: first)
        nav.hide(id: second)
        #expect(nav.top == nil, "the panel's page shows after a pop to the root")
        clock.now += FernletPlateNavigation.staleAfter + 1
        nav.show(id: UUID(), title: "Health", pop: {})
        #expect(nav.pages.count == 1)
        #expect(nav.topBackTitle == "Settings", "a stale page never becomes a Back")
    }

    @Test func thePlateKeepsABoundedRecordAndBackPopsTheTop() {
        let clock = Clock()
        let nav = plate(clock)
        var popped = 0
        for index in 0..<(FernletPlateNavigation.capacity + 5) {
            nav.show(id: UUID(), title: "Page \(index)", pop: { popped += 1 })
        }
        #expect(nav.pages.count == FernletPlateNavigation.capacity)
        #expect(nav.topBackTitle == "Page \(FernletPlateNavigation.capacity + 3)")
        nav.popTop()
        #expect(popped == 1)
        #expect(nav.pages.count == FernletPlateNavigation.capacity, "a page above another waits for its own pop")
    }

    /// The panel's ✕ asks the page showing when it holds unsaved work (the Creation Studio's paint):
    /// a guard that says no keeps the panel open; a covered page is not asked; a popped page's guard
    /// goes with it.
    @Test func thePanelCloseAsksAGuardedPageShowing() {
        let clock = Clock()
        let nav = plate(clock)
        #expect(nav.allowsClose(), "no pushed page: ✕ closes")
        let studio = UUID()
        nav.show(id: studio, title: "New item", pop: {})
        let paint = StudioPaint()
        nav.setCloseGuard(id: studio) { [paint] in
            guard paint.unsaved else { return true }
            paint.asked += 1
            return false
        }
        #expect(!nav.allowsClose() && paint.asked == 1, "unsaved paint: the studio asks and the panel stays")
        paint.unsaved = false
        #expect(nav.allowsClose(), "a blank canvas lets ✕ close")
        paint.unsaved = true
        // Save item pushed over the studio: the covered studio is not asked.
        let save = UUID()
        nav.hide(id: studio)
        nav.show(id: save, title: "Save item", pop: {})
        #expect(nav.allowsClose() && paint.asked == 1)
        // Back to the studio, then the studio popped: its guard goes with it.
        nav.hide(id: save)
        nav.show(id: studio, title: "New item", pop: {})
        #expect(!nav.allowsClose() && paint.asked == 2)
        nav.popTop()
        nav.setCloseGuard(id: UUID(), nil)
        #expect(nav.allowsClose() && paint.asked == 2)
    }

    /// A held plate (Delete everything's wipe running on Settings or Privacy & Data): Back pops nothing
    /// and ✕ may not close; released, both work again.
    @Test func aHeldPlateKeepsItsPageAndThePanel() {
        let clock = Clock()
        let nav = plate(clock)
        var popped = 0
        nav.show(id: UUID(), title: "Privacy & Data", pop: { popped += 1 })
        nav.isHeld = true
        nav.popTop()
        #expect(popped == 0 && nav.top?.title == "Privacy & Data", "held: Back does nothing")
        #expect(!nav.allowsClose(), "held: the panel's ✕ stays shut")
        nav.isHeld = false
        #expect(nav.allowsClose())
        nav.popTop()
        #expect(popped == 1)
    }

    /// The studio's unsaved paint and how often its close guard asked, for the test above.
    @MainActor final class StudioPaint {
        var unsaved = true
        var asked = 0
    }

    @Test func backShowsItsArrowAloneForALongTitle() {
        #expect(!FernletBackButton.isCompact(title: "Appearance"))
        #expect(!FernletBackButton.isCompact(title: "Thirteen char"))
        #expect(FernletBackButton.isCompact(title: "App colors and backgrounds"), "the kit's 13-letter rule")
    }

    @Test func theStepperStaysInsideItsRange() {
        #expect(FernletStepperMath.stepped(3, by: 1, in: 1...5) == 4)
        #expect(FernletStepperMath.stepped(5, by: 1, in: 1...5) == 5)
        #expect(FernletStepperMath.stepped(1, by: -1, in: 1...5) == 1)
        #expect(FernletStepperMath.stepped(2.5, by: 2.5, in: 0.0...4.0) == 4.0)
        #expect(!FernletStepperMath.canStep(5, by: 1, in: 1...5))
        #expect(FernletStepperMath.canStep(5, by: -1, in: 1...5))
    }

    @Test func theTileGridIsTwoWideUntilTheLargestTextSizes() {
        #expect(FernletTileGrid<EmptyView>.columnCount(accessibilitySize: false) == 2)
        #expect(FernletTileGrid<EmptyView>.columnCount(accessibilitySize: true) == 1)
    }

    /// Every framed icon has a pixel sprite, and the one-colour ones (all of them but the lock) take
    /// the ink token in dark mode.
    @Test func everyFramedIconIsAPixelSpriteAndTheInkOnesFollowDarkMode() {
        for icon in FernletFramedIcon.allCases {
            let sprite = WorldSprites.sprite(for: icon)
            #expect(sprite.width > 0 && sprite.rows.allSatisfy { $0.count == sprite.width }, "\(icon)")
            let keys = Set(sprite.rows.joined()).subtracting(["."])
            #expect(keys.isSubset(of: Set(sprite.palette.keys)), "\(icon)")
            #expect(sprite.isMonoInk == (icon != .lock), "\(icon)")
        }
        #expect(!WorldSprites.heart.isMonoInk && !WorldSprites.onigiri.isMonoInk, "art keeps its own colours")
        #expect(WorldSprites.grip.isMonoInk && WorldSprites.chart.isMonoInk)
    }

    /// The root's one design language carries the Form style and the pixel icon renderer, so every
    /// Form and every framed icon below it inherits them.
    @Test func theDesignLanguageSetsTheFormStyleAndTheIcons() throws {
        let theme = try RepoRoot.source("App/Fernlet/World/Theme/WorldTheme.swift")
        #expect(theme.contains(".formStyle(FernletFormStyle())"))
        #expect(theme.contains(".environment(\\.fernletIconRenderer, WorldTheme.iconRenderer)"))
        let frame = try RepoRoot.source("App/Fernlet/World/Shell/WorldPanelFrame.swift")
        #expect(frame.contains(".environment(\\.fernletPlateNavigation, showsPlate ? navigation : nil)"))
    }
}
