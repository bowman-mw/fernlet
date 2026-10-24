import SwiftUI
import FernletDomainModel
import FernletUI

/// Arrange Today, the Today panel's layout editor (design `b1-today-editor`, draft 2, approved
/// 2026-10-23; World app plan step 4). It replaces Settings' Home widgets editor and opens from the
/// bottom of the Today panel and from Settings → Appearance → Today panel.
///
/// One list: the cards Today shows, in their order, then the ones it hides. Drag handles reorder the
/// shown cards and a switch shows or hides each one, in place of the old arrows and ✕. The companion
/// lives on the map and Quick log moved to Log, so neither is in the list; both keep their place in
/// the stored order, which is the same `homeWidgets` array with the same ids, so a saved layout
/// carries over unchanged (``TodayLayout``).
///
/// VoiceOver and Voice Control: each row is its switch, named for the card, with "Move up" and "Move
/// down" actions (Voice Control: "Move Trends up").
struct WorldTodayEditor: View {
    var store: FernletStore

    var body: some View {
        List {
            Section {
                ForEach(shown) { row($0, isShown: true) }
                    .onMove { from, to in apply(TodayLayout.moving(store.settings.homeWidgets, from: from, to: to)) }
                ForEach(hidden) { row($0, isShown: false) }
            } header: {
                Text("Drag to reorder. Hidden cards stay one tap away in Settings.")
                    .font(.fernlet(.body))
                    .foregroundStyle(WorldPalette.dim)
                    .textCase(nil)
                    .fernletWrappingText()
            } footer: {
                Text("The companion lives on the map, and Quick log moved to Log, so neither is in this list.")
                    .font(.fernlet(.body))
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            .listRowBackground(WorldPalette.paper)
            .listRowSeparatorTint(WorldPalette.ink.opacity(0.25))
        }
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .accessibilityIdentifier("world.todayEditor")
    }

    /// The cards Today shows, in order.
    private var shown: [HomeWidget] { TodayLayout.shown(store.settings.homeWidgets) }
    /// The cards Today hides, in their catalogue order.
    private var hidden: [HomeWidget] { TodayLayout.hidden(store.settings.homeWidgets) }

    /// One card: its name (dimmed when hidden) and its switch, with the move actions.
    private func row(_ widget: HomeWidget, isShown: Bool) -> some View {
        Toggle(isOn: Binding(get: { isShown }, set: { apply(TodayLayout.setting(store.settings.homeWidgets, widget, shown: $0)) })) {
            Text(verbatim: widget.title)
                .font(.fernlet(.label))
                .foregroundStyle(isShown ? WorldPalette.bark : WorldPalette.dim)
                .fernletWrappingText()
        }
        .accessibilityAction(named: Text("Move up")) { move(widget, by: -1) }
        .accessibilityAction(named: Text("Move down")) { move(widget, by: 1) }
        .accessibilityInputLabels([Text(widget.title)])
        .accessibilityIdentifier("world.todayEditor.\(widget.rawValue)")
    }

    /// One step up or down among the shown cards (the arrows' VoiceOver twin).
    private func move(_ widget: HomeWidget, by offset: Int) {
        apply(TodayLayout.stepping(store.settings.homeWidgets, widget, by: offset))
    }

    /// Saves a new order when it differs, with the layout cue (report B13), as the old editor did.
    private func apply(_ widgets: [HomeWidget]) {
        guard widgets != store.settings.homeWidgets else { return }
        FernletFeedback.system.play(.moved)
        store.setHomeWidgets(widgets)
    }
}

/// The Today panel's layout rules on the stored Home order (pure; `WorldTodayEditor` and the Today
/// panel read them). The companion and Quick log stay wherever they are in the stored array: Today
/// draws neither, and every edit here keeps their slots, so the order means the same thing to any
/// other build reading it.
nonisolated enum TodayLayout {
    /// The cards Today never lists: the companion is on the map, Quick log is the Log panel.
    static let elsewhere: Set<HomeWidget> = [.companion, .quickLog]

    /// The cards Today shows, in their stored order.
    static func shown(_ widgets: [HomeWidget]) -> [HomeWidget] {
        widgets.filter { !elsewhere.contains($0) }
    }

    /// The cards Today could show but hides, in the catalogue's order.
    static func hidden(_ widgets: [HomeWidget]) -> [HomeWidget] {
        HomeWidget.allCases.filter { !elsewhere.contains($0) && !widgets.contains($0) }
    }

    /// `widgets` with `widget` shown (appended at the end) or hidden (removed).
    static func setting(_ widgets: [HomeWidget], _ widget: HomeWidget, shown: Bool) -> [HomeWidget] {
        guard !elsewhere.contains(widget) else { return widgets }
        if shown {
            return widgets.contains(widget) ? widgets : widgets + [widget]
        }
        return widgets.filter { $0 != widget }
    }

    /// `widgets` after a drag among the shown cards (List's `onMove` offsets into ``shown(_:)``).
    static func moving(_ widgets: [HomeWidget], from source: IndexSet, to destination: Int) -> [HomeWidget] {
        var visible = shown(widgets)
        guard source.allSatisfy({ visible.indices.contains($0) }), destination >= 0, destination <= visible.count else {
            return widgets
        }
        visible.move(fromOffsets: source, toOffset: destination)
        return refilling(widgets, with: visible)
    }

    /// `widgets` with `widget` one place up (-1) or down (+1) among the shown cards.
    static func stepping(_ widgets: [HomeWidget], _ widget: HomeWidget, by offset: Int) -> [HomeWidget] {
        var visible = shown(widgets)
        guard let index = visible.firstIndex(of: widget), visible.indices.contains(index + offset) else { return widgets }
        visible.swapAt(index, index + offset)
        return refilling(widgets, with: visible)
    }

    /// The stored order with the companion and Quick log in their slots and `visible` in the rest.
    private static func refilling(_ widgets: [HomeWidget], with visible: [HomeWidget]) -> [HomeWidget] {
        var remaining = visible[...]
        return widgets.compactMap { widget in
            if elsewhere.contains(widget) { return widget }
            return remaining.popFirst()
        }
    }
}
