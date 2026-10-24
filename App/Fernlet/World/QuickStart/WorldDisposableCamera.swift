import FernletUI
import ProximityKit
import SwiftUI

/// The one way the World Home opens the disposable camera (owner, 2026-10-24: the camera moves to the
/// blue button, in a session and during a hike, run or workout; designs `b3-qs-session`, `b3-qs-hike`).
///
/// **In a session** it is today's camera, unchanged: the session's shared film, its rules and its
/// Develop review (`DisposableCameraView`).
///
/// **On your own** (10 photos a day, no Develop, the photos appear after the companion sleeps;
/// `b3-camera-solo`) is being built alongside this, in the camera's own views. Until it lands,
/// ``soloIsAvailable`` is false, so the blue button offers the camera only in a session, and never
/// opens the session's film outside one (a photo taken there with no session would be held for a
/// review that never comes).
nonisolated enum WorldDisposableCamera {
    /// Which film the camera shoots on.
    enum Mode: Equatable, Sendable {
        /// The friend session's shared film.
        case session
        /// The person's own film, 10 a day.
        case solo
    }

    /// Whether the on-your-own camera exists yet.
    // INTEGRATOR: set this true once lane FRIENDS' solo mode (10 a day, no Develop) is merged, and open
    // it from `view(store:mode:)` below.
    static let soloIsAvailable = false
}

extension WorldDisposableCamera {
    /// The camera for `mode`, full screen over everything (a focused flow: no grabber; it closes itself).
    @MainActor @ViewBuilder
    static func view(store: FernletStore, mode: Mode) -> some View {
        switch mode {
        case .session:
            DisposableCameraView(store: store)
        case .solo:
            // INTEGRATOR: solo mode plugs in here (lane FRIENDS' camera with its own 10-a-day film). Today's
            // camera only knows the session film, so this stays the session camera and is never reached
            // while `soloIsAvailable` is false.
            DisposableCameraView(store: store)
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
