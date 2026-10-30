import FernletUI
import SwiftUI
import WorldMapStore

/// Runs Sprout's discovery lines on Home (World-Exploration-Spec §4): listens to the passport's discoveries through
/// the one router (``WorldDiscoveryRouter``) for as long as Home's map lives, and clears a line once Sprout has
/// said it: the line waits while a panel or sheet covers the map or the bubble stays down (``isSaying`` false),
/// then stands for ``standing`` once said, and a line that waited past ``WorldDiscoveryRouter/staleAfter`` is
/// dropped unsaid. DEBUG screenshots force a line or open a lines board (``UITestSupport/linesScene``).
struct WorldDiscoveryLinesDriver: ViewModifier {
    let store: FernletStore
    let router: WorldDiscoveryRouter
    /// Whether Sprout's bubble can say a line now: Home in front and the bubble not held down.
    let isSaying: Bool
    @State private var board: WorldLineBoard?

    /// How long a said line stays Sprout's line (the bubble itself fades after its notice window).
    static let standing = Duration.seconds(20)

    func body(content: Content) -> some View {
        content
            .task { await listen() }
            .task(id: Clock(line: router.line, isSaying: isSaying)) { await sayThenClear() }
            .sheet(item: $board) { board in WorldLinesGallery(board: board) }
            .task { await applyTestScene() }
    }

    /// What restarts the line's clock: a new line, or the bubble able to say it again.
    private struct Clock: Equatable {
        let line: WorldDiscoveryLine?
        let isSaying: Bool
    }

    /// The router's one subscription, for as long as Home's map lives.
    private func listen() async {
        let keeper = store.worldFog.atlas
        await router.listen(to: keeper, places: .live(keeper), isDecoy: { store.duressSessionActive })
    }

    /// Lets the line stand once it can be said, then clears it; a stale line goes at once.
    private func sayThenClear() async {
        guard router.line != nil, isSaying else { return }
        guard !router.isStale() else {
            router.clearLine()
            return
        }
        guard !UITestSupport.worldHomeScenes.contains("hold"), UITestSupport.linesScene == nil else { return }
        do {
            try await Task.sleep(for: Self.standing)
        } catch {
            return
        }
        router.clearLine()
    }

    /// DEBUG `FERNLET_UI_TEST_LINES`: a forced line (`desert:1`, `city:1:Portland`) or a board (`board:towns`);
    /// display only, nothing in release builds or a decoy.
    private func applyTestScene() async {
        guard let scene = UITestSupport.linesScene, !store.duressSessionActive else { return }
        do {
            try await Task.sleep(for: .seconds(4))
        } catch {
            return
        }
        let parts = scene.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        if parts[0] == "board" {
            board = WorldLineBoard(rawValue: parts[1])
            return
        }
        guard let category = WorldLineCategory(rawValue: parts[0]), let number = Int(parts[1]) else { return }
        router.stage(WorldDiscoveryLine(category: category, index: number - 1, name: parts.count > 2 ? parts[2] : "",
                                        at: Date()))
    }
}
