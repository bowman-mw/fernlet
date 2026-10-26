import FernletUI
import ProximityKit
import SwiftUI

/// The one way the World Home opens the disposable camera (owner, 2026-10-24: the camera moves to the
/// blue button, in a session and during a hike, run or workout; designs `b3-qs-session`, `b3-qs-hike`).
///
/// **In a session** it is today's camera, unchanged: the session's shared film, its rules and its
/// Develop review (`DisposableCameraView`).
///
/// **On your own** (`b3-camera-solo`: 10 photos a day, no Develop, the photos appear after the
/// companion sleeps) it is the same camera shooting into the sealed, device-only solo roll
/// (`FernletStore.soloCamera`), titled "Just you" or "Just you · <space>". The blue button offers it
/// during a walk or a workout when no session is running; a decoy keeps its shots in memory only.
nonisolated enum WorldDisposableCamera {
    /// Which film the camera shoots on.
    enum Mode: Equatable, Sendable {
        /// The friend session's shared film.
        case session
        /// The person's own film, 10 a day; `placeName` is the space they stand at, if any.
        case solo(placeName: String?)
    }

    /// Whether the on-your-own camera exists (lane friends-solo: the sealed solo corpus and its wipe
    /// leg are in).
    static let soloIsAvailable = true
}

extension WorldDisposableCamera {
    /// The camera for `mode`, full screen over everything (a focused flow: no grabber; it closes itself).
    @MainActor @ViewBuilder
    static func view(store: FernletStore, mode: Mode) -> some View {
        switch mode {
        case .session:
            DisposableCameraView(store: store)
        case .solo(let placeName):
            // Outside a session the camera shoots into the solo roll by itself; the place only titles it.
            DisposableCameraView(store: store, placeName: placeName)
        }
    }
}

/// Presents the disposable camera over the World Home: the one presenter (``WorldDisposableCamera``).
/// The camera keeps its own chrome and its own ways out (its ✕); a session that ends while it is open
/// closes it, as the Friends panel's camera closes today.
struct WorldDisposableCameraCover: ViewModifier {
    var store: FernletStore
    @Binding var mode: WorldDisposableCamera.Mode?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding(get: { mode != nil }, set: { if !$0 { mode = nil } })) {
                // The camera draws its own framed ✕ top right (`b3-camera-session`); it dismisses the
                // cover, which clears `mode`.
                WorldDisposableCamera.view(store: store, mode: mode ?? .session)
            }
            .onChange(of: store.meshNetworkManager.isInSession) { _, inSession in
                if mode == .session && !inSession { mode = nil }
            }
    }
}

extension View {
    /// Opens the disposable camera full screen while `mode` is set.
    func worldDisposableCamera(store: FernletStore, mode: Binding<WorldDisposableCamera.Mode?>) -> some View {
        modifier(WorldDisposableCameraCover(store: store, mode: mode))
    }
}
