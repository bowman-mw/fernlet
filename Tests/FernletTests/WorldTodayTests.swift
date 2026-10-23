import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The World Today panel and Arrange Today (World app plan step 4): what Today lists, how the editor
/// changes the stored Home order, and the wiring that puts both on screen.
@MainActor
struct WorldTodayTests {
    private let order: [HomeWidget] = [.companion, .todaySummary, .todayIntent, .ambient, .quickLog, .macros, .trends]

    /// Today lists every card in the person's order except the companion and Quick log.
    @Test func todayListsTheHomeOrderWithoutTheCompanionAndQuickLog() {
        #expect(TodayLayout.shown(order) == [.todaySummary, .todayIntent, .ambient, .macros, .trends])
        #expect(HomePresentation.today.widgets(from: order) == TodayLayout.shown(order))
        let hidden = TodayLayout.hidden(order)
        #expect(!hidden.contains(.companion) && !hidden.contains(.quickLog))
        #expect(Set(hidden).isDisjoint(with: Set(order)))
        #expect(hidden.count + TodayLayout.shown(order).count == HomeWidget.allCases.count - 2)
    }

    /// A switch shows a card at the end or hides it; the companion and Quick log cannot be switched.
    @Test func switchesShowAtTheEndAndHide() {
        #expect(TodayLayout.setting(order, .firstAid, shown: true) == order + [.firstAid])
        #expect(TodayLayout.setting(order, .macros, shown: false) == order.filter { $0 != .macros })
        #expect(TodayLayout.setting(order, .companion, shown: false) == order)
        #expect(TodayLayout.setting(order, .quickLog, shown: false) == order)
        #expect(TodayLayout.setting(order, .macros, shown: true) == order, "showing a shown card changes nothing")
    }

    /// A drag reorders the shown cards and leaves the companion and Quick log in their stored slots.
    @Test func aDragKeepsTheCompanionAndQuickLogInTheirSlots() {
        // Drag Trends (shown index 4) to the top.
        let moved = TodayLayout.moving(order, from: IndexSet(integer: 4), to: 0)
        #expect(moved == [.companion, .trends, .todaySummary, .todayIntent, .quickLog, .ambient, .macros])
        #expect(moved.firstIndex(of: .companion) == 0 && moved.firstIndex(of: .quickLog) == 4)
        #expect(TodayLayout.moving(order, from: IndexSet(integer: 9), to: 0) == order, "an out-of-range drag changes nothing")
    }

    /// The VoiceOver move actions step one place among the shown cards, and stop at the ends.
    @Test func moveUpAndDownStepAmongTheShownCards() {
        #expect(TodayLayout.stepping(order, .todayIntent, by: -1)
                == [.companion, .todayIntent, .todaySummary, .ambient, .quickLog, .macros, .trends])
        #expect(TodayLayout.stepping(order, .ambient, by: 1)
                == [.companion, .todaySummary, .todayIntent, .macros, .quickLog, .ambient, .trends], "Quick log keeps its slot")
        #expect(TodayLayout.stepping(order, .todaySummary, by: -1) == order)
        #expect(TodayLayout.stepping(order, .trends, by: 1) == order)
    }

    /// The Today panel draws the `.today` presentation, Settings opens Arrange Today in place of the old
    /// Home widgets editor, and the panel frame closes the editor with Done.
    @Test func theTodayPanelAndSettingsOpenArrangeToday() throws {
        let content = try RepoRoot.source("App/Fernlet/ContentView.swift")
        #expect(content.contains("presentation: panel == .log ? .quickLog : .today"))
        let settings = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(settings.contains("WorldTodayEditor(store: store)"))
        #expect(!settings.contains("Reset home widgets"), "the old Home widgets editor is back beside Arrange Today")
        let home = try RepoRoot.source("App/Fernlet/HomeView.swift")
        #expect(home.contains("closesWithDone: true"))
        #expect(home.contains(".environment(\\.fernletFramedLook, framedLook)"))
    }

    /// The gold hearts card shows only while a friend's heart is gold, and only with an end time.
    @Test func theGoldHeartsCardShowsOnlyWhileAHeartIsGold() throws {
        let home = try RepoRoot.source("App/Fernlet/HomeView.swift")
        #expect(home.contains("if store.goldHeartCount() > 0, let until = store.goldHeartsEnd()"))
    }
}
