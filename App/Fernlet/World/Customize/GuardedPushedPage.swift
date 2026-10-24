import SwiftUI
import UIKit
import FernletUI

extension View {
    /// ``SwiftUI/View/fernletPushedPage(_:)`` for a page holding work that must not be lost to a stray
    /// Back: the Creation Studio's unsaved paint (designs `b2-studio` and `b2-studio-save`). Under a World
    /// plate the page hands the plate its title and Back as any pushed page does, but while `isGuarded`
    /// the plate's Back and the panel's ✕ run `onBlockedBack` (the studio asks before discarding) and
    /// the edge swipe is off. Outside a plate (a sheet's own stack) it is `.navigationTitle(title)` and the page keeps its
    /// own toolbar guard.
    ///
    /// Built on the plate's own model (``FernletPlateNavigation``), so the plate draws it exactly like
    /// every other pushed page.
    func fernletGuardedPushedPage(_ title: LocalizedStringResource, isGuarded: Bool,
                                  onBlockedBack: @escaping () -> Void) -> some View {
        modifier(GuardedPushedPageModifier(title: String(localized: title), isGuarded: isGuarded,
                                           onBlockedBack: onBlockedBack))
    }
}

/// Implements ``SwiftUI/View/fernletGuardedPushedPage(_:isGuarded:onBlockedBack:)``.
private struct GuardedPushedPageModifier: ViewModifier {
    let title: String
    let isGuarded: Bool
    let onBlockedBack: () -> Void
    @Environment(\.fernletPlateNavigation) private var plate
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()
    /// What the plate's Back reads when it is tapped (its closure is registered once, on appear).
    @State private var gate = PlateBackGate()

    func body(content: Content) -> some View {
        if let plate {
            content
                .navigationTitle(Text(verbatim: title))
                .toolbar(.hidden, for: .navigationBar)
                .environment(\.fernletPageTitleOnPlate, true)
                .background {
                    EdgeSwipeGate(isEnabled: !isGuarded).frame(width: 0, height: 0).accessibilityHidden(true)
                }
                .onChange(of: isGuarded, initial: true) { _, guarded in gate.isGuarded = guarded }
                .onAppear {
                    gate.onBlocked = onBlockedBack
                    plate.show(id: id, title: title, pop: { [gate, dismiss] in
                        if gate.isGuarded { gate.onBlocked?() } else { dismiss() }
                    })
                    // The panel's ✕ asks too: with unsaved work it runs the same question and stays.
                    plate.setCloseGuard(id: id) { [gate] in
                        guard gate.isGuarded else { return true }
                        gate.onBlocked?()
                        return false
                    }
                }
                .onDisappear { plate.hide(id: id) }
        } else {
            content.navigationTitle(Text(verbatim: title))
        }
    }
}

/// The guard's state for the plate's Back, read when Back is tapped.
@MainActor
private final class PlateBackGate {
    var isGuarded = false
    var onBlocked: (() -> Void)?
}

/// Turns the navigation controller's edge swipe off while the page is guarded, and back on after.
private struct EdgeSwipeGate: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> GateController {
        GateController()
    }

    func updateUIViewController(_ controller: GateController, context: Context) {
        controller.isSwipeEnabled = isEnabled
    }

    /// An empty child of the page's hosting controller, there to reach its navigation controller.
    final class GateController: UIViewController {
        var isSwipeEnabled = true {
            didSet { apply() }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        private func apply() {
            guard viewIfLoaded?.window != nil else { return }
            navigationController?.interactivePopGestureRecognizer?.isEnabled = isSwipeEnabled
        }
    }
}
