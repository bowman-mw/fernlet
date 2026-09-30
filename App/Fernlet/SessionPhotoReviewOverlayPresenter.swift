// SessionPhotoReviewOverlayPresenter.swift
// Fernlet
//
// Session photos U3 (2026-09-30): where the session-end photo review draws. The owner asked for it
// to be "the first thing shown", on whatever tab or sheet the person is on. A SwiftUI sheet cannot
// be that: a request from one presenter REPLACES a standing sheet of a view above it and QUEUES
// behind a sheet of a view below it (measured on the iOS 26.5 simulator; `ConnectView`'s scheduling
// notes), and UIKit `present` on the top-most controller is dismissed along with whatever SwiftUI
// dismisses underneath it. A second `UIWindow` one level above the main window is above every
// sheet, cover and alert of the app — all of which live in the main window — without dismissing
// any of them, so a half-typed meal or journal entry underneath survives intact.

import SwiftUI
import UIKit

// MARK: - SessionPhotoReviewPresenting

/// Where ``SessionPhotoReviewCoordinator`` draws the review: the overlay window in the app
/// (``SessionPhotoReviewOverlayPresenter``), a recorder in tests.
///
/// Concurrency: `@MainActor` — windows and hosting controllers are main-actor UIKit state.
@MainActor
protocol SessionPhotoReviewPresenting: AnyObject {
    /// Whether the review is drawn right now.
    var isShowing: Bool { get }
    /// Adopts the window scene ContentView lives in (the overlay window is created on it).
    ///
    /// - Parameter windowScene: The scene.
    func attach(to windowScene: UIWindowScene)
    /// Draws the review for `coordinator`'s snapshot.
    ///
    /// - Parameter coordinator: The coordinator whose snapshot and actions the screen renders.
    /// - Returns: Whether it is now drawn — false when no scene has been adopted yet, and the
    ///   coordinator then stays hidden and asks again at the next edge.
    func show(_ coordinator: SessionPhotoReviewCoordinator) -> Bool
    /// Takes the review down (answering nothing — answers are the coordinator's).
    func hide()
}

// MARK: - SessionPhotoReviewOverlayPresenter

/// The review's own `UIWindow`, one level above the main window, hosting
/// ``SessionPhotoReviewScreen`` (design §4.5 "Where it draws").
///
/// On show: the main window's editing ends (the keyboard window is above ours), its accessibility
/// elements are hidden (VoiceOver reads the review only), the overlay window takes the main window's
/// appearance — the app's Light/Dark/System choice as the app root applied it, read off the window
/// rather than off the stored preference, so there is one source of truth and no second reader of
/// the setting — becomes key and fades in (a fade, never a slide — Reduce Motion), and
/// a screen-changed notification moves VoiceOver to it. On hide: the main window's accessibility is
/// restored and it becomes key again, the overlay window is hidden, detached from its scene and
/// released — no window outlives the review (the memory-lifecycle wall's rule).
///
/// Concurrency: `@MainActor`; owned by the coordinator. The scene and the covered main window are
/// held weakly; the overlay window strongly, only while showing.
@MainActor
final class SessionPhotoReviewOverlayPresenter: SessionPhotoReviewPresenting {

    /// The scene ContentView lives in, adopted by ``WindowSceneReader``.
    private weak var windowScene: UIWindowScene?
    /// The overlay window, while the review shows.
    private var overlayWindow: UIWindow?
    /// The main window the overlay covers, whose accessibility and key status are restored on hide.
    private weak var coveredWindow: UIWindow?
    /// The appearance the overlay window takes at each show, given the window it covers.
    private let appearance: @MainActor (UIWindow?) -> UIUserInterfaceStyle

    /// The accessibility identifier of the overlay window itself (a frozen token).
    static let windowIdentifier = "friends.review.overlayWindow"

    /// Creates the presenter.
    ///
    /// - Parameter appearance: The style for the overlay window, given the main window it covers;
    ///   defaults to ``mirroredAppearance(of:)``.
    init(appearance: @escaping @MainActor (UIWindow?) -> UIUserInterfaceStyle = SessionPhotoReviewOverlayPresenter.mirroredAppearance) {
        self.appearance = appearance
    }

    var isShowing: Bool { overlayWindow != nil }

    func attach(to windowScene: UIWindowScene) {
        self.windowScene = windowScene
    }

    func show(_ coordinator: SessionPhotoReviewCoordinator) -> Bool {
        guard overlayWindow == nil else { return true }
        guard let scene = windowScene else { return false }
        let covered = Self.mainWindow(in: scene)
        covered?.endEditing(true)
        covered?.accessibilityElementsHidden = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.overrideUserInterfaceStyle = appearance(covered)
        window.accessibilityIdentifier = Self.windowIdentifier
        let host = UIHostingController(rootView: SessionPhotoReviewScreen(coordinator: coordinator))
        window.rootViewController = host
        window.alpha = 0
        window.makeKeyAndVisible()
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
        overlayWindow = window
        coveredWindow = covered
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
        return true
    }

    func hide() {
        guard let window = overlayWindow else { return }
        overlayWindow = nil
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        if let covered = coveredWindow {
            covered.accessibilityElementsHidden = false
            covered.makeKey()
        }
        coveredWindow = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The window the overlay covers: the scene's key window, else its first visible normal-level
    /// window.
    ///
    /// - Parameter scene: The scene.
    /// - Returns: The main window, if the scene has one.
    static func mainWindow(in scene: UIWindowScene) -> UIWindow? {
        if let key = scene.keyWindow, key.windowLevel == .normal { return key }
        return scene.windows.first { $0.windowLevel == .normal && !$0.isHidden }
    }

    /// The main window's appearance as the overlay should take it: a style the app pinned on the
    /// window or its root (``FernletAppearanceMode`` Light or Dark, applied by the app root's
    /// `preferredColorScheme`), else the window's effective style when it differs from the scene's
    /// (a pin applied some other way), else `.unspecified` — follow the phone, as "System" does.
    ///
    /// - Parameter covered: The main window, if there is one.
    /// - Returns: The style the overlay window takes.
    static func mirroredAppearance(of covered: UIWindow?) -> UIUserInterfaceStyle {
        guard let covered else { return .unspecified }
        let pins = [covered.overrideUserInterfaceStyle, covered.rootViewController?.overrideUserInterfaceStyle ?? .unspecified]
        if let pinned = pins.first(where: { $0 != .unspecified }) { return pinned }
        let effective = covered.traitCollection.userInterfaceStyle
        let system = covered.windowScene?.traitCollection.userInterfaceStyle ?? effective
        return effective == system ? .unspecified : effective
    }
}

// MARK: - WindowSceneReader

/// A zero-size view that reports the `UIWindowScene` it is placed in — how the overlay presenter
/// learns which scene to create its window on, from inside ContentView's hierarchy.
struct WindowSceneReader: UIViewRepresentable {
    /// Called with the scene whenever the view joins a window.
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> WindowSceneReportingView {
        let view = WindowSceneReportingView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: WindowSceneReportingView, context: Context) {
        uiView.onScene = onScene
    }
}

/// The UIKit half of ``WindowSceneReader``: reports its window's scene on every move to a window.
final class WindowSceneReportingView: UIView {
    /// The report.
    var onScene: ((UIWindowScene) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene else { return }
        onScene?(scene)
    }
}
