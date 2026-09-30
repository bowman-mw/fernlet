import SwiftUI
import Testing
import UIKit
import FernletDomainModel
@testable import Fernlet

/// Pins the gesture boundary of the Creation Studio's canvas: a touch that starts on the canvas
/// belongs to the canvas.
///
/// Owner report 2026-09-29: "On the item designer, it still scrolls when you're drawing." The
/// canvas's gesture delegate answered `true` to "recognize simultaneously?" for EVERY recognizer,
/// and UIKit honours a single `true` from either side — so a one-finger stroke also drove the
/// studio page's scroll view, dragged the customization sheet, and could start the iOS 26
/// swipe-back and pop the studio. These tests build the canvas exactly as `makeUIView` does
/// (through ``ZoomablePixelCanvas/Coordinator/install(on:)``), nest it in a page scroll view under
/// an ancestor carrying a foreign pan, and ask the delegate the two questions UIKit asks.
///
/// Against the old delegate (`shouldRecognizeSimultaneouslyWith` → `true`, no failure requirement)
/// both outside-recognizer tests fail.
@MainActor
struct ZoomablePixelCanvasGestureTests {

    /// A canvas wired as the app wires it, inside the page, inside a host with its own pan.
    @MainActor
    private struct Rig {
        let coordinator: ZoomablePixelCanvas.Coordinator
        let canvas: ZoomScrollView
        /// The studio page's scroll view (SwiftUI's `ScrollView` is a `UIScrollView`).
        let page: UIScrollView
        /// Stands in for the sheet's drag and the navigation stack's content swipe-back.
        let ancestorPan: UIPanGestureRecognizer
        /// The recognizers `install(on:)` added — every one whose delegate is the coordinator.
        let installed: [UIGestureRecognizer]

        /// Recognizers outside the canvas.
        var outside: [UIGestureRecognizer] { [page.panGestureRecognizer, ancestorPan] }
    }

    private func makeRig() throws -> Rig {
        let representable = ZoomablePixelCanvas(
            pixels: .constant(Array(repeating: ItemGridTexture.transparent, count: 4)),
            cols: 2,
            rows: 2,
            palette: [],
            onStrokeBegan: {},
            onStrokeCancelled: {},
            onPaintCell: { _, _ in }
        )
        let coordinator = representable.makeCoordinator()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let ancestorPan = UIPanGestureRecognizer()
        host.addGestureRecognizer(ancestorPan)
        let page = UIScrollView(frame: host.bounds)
        page.contentSize = CGSize(width: 400, height: 1_600)
        host.addSubview(page)
        let canvas = ZoomScrollView(frame: CGRect(x: 20, y: 100, width: 300, height: 300))
        canvas.delegate = coordinator
        page.addSubview(canvas)
        coordinator.install(on: canvas)

        let attached = (canvas.gestureRecognizers ?? []) + (canvas.content.gestureRecognizers ?? [])
        let installed = attached.filter { $0.delegate === coordinator }
        try #require(installed.count == 3, "install(on:) should add the paint pan, the paint tap and the touch owner")
        return Rig(coordinator: coordinator, canvas: canvas, page: page,
                   ancestorPan: ancestorPan, installed: installed)
    }

    /// The canvas's own zoom and two-finger pan, which a paint stroke must keep sharing touches with.
    private func canvasOwnScrollRecognizers(of canvas: ZoomScrollView) throws -> [UIGestureRecognizer] {
        let pinch = try #require(canvas.pinchGestureRecognizer, "zoom runs 1×–8×, so the pinch must exist")
        return [pinch, canvas.panGestureRecognizer]
    }

    /// The regression itself: no canvas recognizer shares its touch with the page scroll or an
    /// ancestor's pan. Pre-fix, every pair here answered `true`.
    @Test func canvasRecognizersDoNotShareTouchesWithRecognizersOutsideTheCanvas() throws {
        let rig = try makeRig()
        for recognizer in rig.installed {
            for other in rig.outside {
                #expect(!rig.coordinator.gestureRecognizer(recognizer, shouldRecognizeSimultaneouslyWith: other),
                        "\(type(of: recognizer)) must not share a stroke with \(type(of: other))")
            }
        }
    }

    /// The half that makes it certain: every recognizer outside the canvas waits for the canvas's
    /// recognizers to fail, whatever that recognizer's own delegate says about sharing.
    @Test func recognizersOutsideTheCanvasMustWaitForTheCanvasToFail() throws {
        let rig = try makeRig()
        for recognizer in rig.installed {
            for other in rig.outside {
                #expect(rig.coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: other),
                        "\(type(of: other)) must wait for \(type(of: recognizer)) to fail")
            }
        }
    }

    /// Pinch-zoom and two-finger pan still work: a paint stroke shares with the canvas's own zoom
    /// and pan (a pinch can start under a finger that is already painting), and neither of those
    /// has to wait for paint to fail.
    @Test func canvasRecognizersKeepSharingWithTheCanvasOwnZoomAndPan() throws {
        let rig = try makeRig()
        let own = try canvasOwnScrollRecognizers(of: rig.canvas) + rig.installed
        for recognizer in rig.installed {
            for other in own where other !== recognizer {
                #expect(rig.coordinator.gestureRecognizer(recognizer, shouldRecognizeSimultaneouslyWith: other))
                #expect(!rig.coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: other))
            }
        }
    }

    /// The shape of the three recognizers: painting stays one-finger (so the canvas's two-finger pan
    /// is never mistaken for a stroke), while the touch owner has no finger cap — it is what keeps a
    /// two-finger drag on an un-zoomed canvas from falling through to the page or the sheet.
    @Test func paintingIsOneFingerAndTheTouchOwnerCoversAnyFingerCount() throws {
        let rig = try makeRig()
        let pans = rig.installed.compactMap { $0 as? UIPanGestureRecognizer }
        #expect(pans.count == 2)
        #expect(pans.contains { $0.view === rig.canvas.content && $0.maximumNumberOfTouches == 1 })
        // UIKit's default cap is UINT_MAX; what matters is that two fingers are inside it.
        #expect(pans.contains { $0.view === rig.canvas && $0.maximumNumberOfTouches > 2 })
        #expect(rig.installed.contains { $0 is UITapGestureRecognizer && $0.view === rig.canvas.content })
        #expect(rig.canvas.panGestureRecognizer.minimumNumberOfTouches == 2)
    }

    /// Before `install(on:)` there is no canvas to be inside, so nothing counts as the canvas's
    /// own — the answer that errs towards the canvas keeping its touches.
    @Test func anUninstalledCoordinatorTreatsEveryRecognizerAsOutside() throws {
        let rig = try makeRig()
        let fresh = ZoomablePixelCanvas.Coordinator(rig.coordinator.parent)
        #expect(fresh.canvas == nil)
        #expect(!fresh.isCanvasOwn(rig.canvas.panGestureRecognizer))
        #expect(!fresh.isCanvasOwn(rig.page.panGestureRecognizer))
        #expect(rig.coordinator.canvas === rig.canvas)
    }
}
