import SwiftUI

/// Puts the map intro (``WorldLocationIntro``, `b1-loc-intro`) up over Home once, before iOS has asked for
/// location: while the map is in front and the app active, iOS hasn't asked yet, the intro hasn't been
/// answered on this iPhone, and no decoy is open (a decoy never asks for anything). Under a test harness it
/// waits for the DEBUG scene `intro`, so UI tests on a fresh simulator aren't stopped by it.
///
/// `isUp` reports the cover to Home, which holds the stamp banner and the session button back meanwhile
/// (the camera's binding does the same). Turn on location asks iOS for While Using; both answers are kept
/// (``WorldMapPreferences/setLocationIntroAnswered(in:)``).
struct WorldLocationIntroPresenter: ViewModifier {
    var store: FernletStore
    /// Whether the map is what the person sees.
    let isFrontmost: Bool
    @Binding var isUp: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isUp) {
                WorldLocationIntro(onTurnOn: turnOn, onNotNow: notNow)
            }
            .task(id: isDue) {
                if isDue { isUp = true }
            }
    }

    /// Whether the intro should be up now.
    private var isDue: Bool {
        guard isFrontmost, scenePhase == .active, !store.duressSessionActive,
              store.worldLocation.permission == .notAsked, !WorldMapPreferences.locationIntroAnswered() else { return false }
        return Self.allowedHere
    }

    /// Whether this process may show the intro: always for a person; under a test harness only when a
    /// screenshot asks for it (`FERNLET_UI_TEST_WORLD_HOME=intro`).
    static var allowedHere: Bool {
        !UITestSupport.isTestHarnessActive || UITestSupport.worldHomeScenes.contains("intro")
    }

    /// Turn on location: the intro is answered and iOS asks (While Using, Precise on).
    private func turnOn() {
        WorldMapPreferences.setLocationIntroAnswered()
        isUp = false
        store.worldLocation.requestWhileUsing()
    }

    /// Not now, or ✕: the intro is answered and Home stays on its open scene.
    private func notNow() {
        WorldMapPreferences.setLocationIntroAnswered()
        isUp = false
    }
}
