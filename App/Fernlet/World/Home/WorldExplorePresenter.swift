import FernletUI
import SwiftUI
import WorldMapStore

/// Presents Home's city and landmark cards (World-Exploration-Spec §2) and watches the passport for new finds:
/// the landmark card floats over the dimmed map, the city card is a full-height sheet, and each landmark found
/// while Home is up reaches ``WorldExploreState/onLandmarkFound`` (left unattached: Sprout's lines read the discovery stream). DEBUG
/// screenshots open a card or the gallery (``UITestSupport/exploreScene``).
struct WorldExplorePresenter: ViewModifier {
    let store: FernletStore
    @Bindable var explore: WorldExploreState
    @State private var gallery: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let model = explore.openLandmark {
                    WorldLandmarkCard(model: model, images: explore.images) { explore.openLandmark = nil }
                }
            }
            .animation(.easeOut(duration: 0.18), value: explore.openLandmark)
            .sheet(item: $explore.openCity) { model in
                WorldCityCard(store: store, model: model, explore: explore)
            }
            .sheet(isPresented: galleryShown) {
                WorldExploreGallery(scene: gallery ?? "", images: explore.images)
            }
            .onChange(of: store.worldFog.atlas.book.count(of: .landmark), initial: true) { noteFinds() }
            .task { await applyTestScene() }
    }

    /// Whether the DEBUG gallery is up.
    private var galleryShown: Binding<Bool> {
        Binding(get: { gallery != nil }, set: { if !$0 { gallery = nil } })
    }

    /// Tells the seam about new finds (the first look only remembers what is found).
    private func noteFinds() {
        explore.noteFinds(in: store.worldFog.atlas.book, list: store.worldFog.atlas.landmarks,
                          isDecoy: store.duressSessionActive)
    }

    /// DEBUG `FERNLET_UI_TEST_EXPLORE`: `landmark:<token>` opens a found landmark's card, `city:<token>` a found
    /// city's card, `gallery:<board>` the art gallery; display only, nothing in release builds.
    private func applyTestScene() async {
        guard let scene = UITestSupport.exploreScene else { return }
        do {
            try await Task.sleep(for: .seconds(4))
        } catch {
            return
        }
        let book = WorldExploreState.book(store)
        let atlas = store.worldFog.atlas.openedAtlas
        let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "landmark":
            guard let landmark = store.worldFog.atlas.landmarks.landmark(token: parts[1]),
                  let date = book.firstVisit(.landmark, token: landmark.token) else { return }
            explore.openLandmark = explore.card(for: landmark, foundAt: date, atlas: atlas)
        case "city":
            guard let city = atlas?.city(token: parts[1]), let date = book.firstVisit(.city, token: city.token) else { return }
            explore.openCity = WorldCityCardModel(city: city, discoveredAt: date)
        case "gallery":
            gallery = parts[1]
        default:
            return
        }
    }
}
