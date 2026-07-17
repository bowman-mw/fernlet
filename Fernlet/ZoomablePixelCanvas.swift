import SwiftUI
import UIKit
import FernletDomainModel

/// A zoomable, pannable pixel-painting surface for the clothing editor (#15). The grid cells are ~6.7pt
/// at 1×, too small to place pixels precisely, so this wraps the canvas in a `UIScrollView` for the
/// drawing-app interaction the tester asked for:
///
/// - **Pinch** to zoom (1×–8×).
/// - **Two-finger drag** to pan (the scroll view's own pan is set to require two touches).
/// - **One finger** paints — a single-touch pan/tap that the scroll view leaves alone, mapped to a grid
///   cell and reported back so the SwiftUI editor keeps owning the pixel/undo/symmetry logic.
///
/// The pixels render through the shared `ItemTextureRenderer` (one image pixel per cell) shown in a
/// `UIImageView` with a `.nearest` magnification filter, so blocks stay crisp at every zoom level for
/// free — no redraw-on-zoom needed.
struct ZoomablePixelCanvas: UIViewRepresentable {
    @Binding var pixels: [Int]
    let cols: Int
    let rows: Int
    let palette: [String]
    /// Called once at the start of each paint stroke (a drag or a tap), so the editor can snapshot for undo.
    var onStrokeBegan: () -> Void
    /// Called with the grid cell under the touch for every paint sample. The editor applies the colour +
    /// symmetry.
    var onPaintCell: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.delegate = context.coordinator

        let paintPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePaintPan(_:)))
        paintPan.maximumNumberOfTouches = 1
        paintPan.delegate = context.coordinator
        view.content.addGestureRecognizer(paintPan)

        let paintTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePaintTap(_:)))
        paintTap.delegate = context.coordinator
        view.content.addGestureRecognizer(paintTap)

        return view
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        uiView.gridCols = cols
        uiView.gridRows = rows
        let texture = ItemGridTexture(cols: cols, rows: rows, palette: palette, pixels: pixels)
        uiView.content.image = ItemTextureRenderer.image(for: texture).map { UIImage(cgImage: $0) }
        // A grid resize (slot change) invalidates any current zoom/scroll; snap back so the fresh grid
        // fills the frame.
        if uiView.gridColsRowsChanged {
            uiView.setZoomScale(1, animated: false)
            uiView.gridColsRowsChanged = false
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomablePixelCanvas
        private var isStroking = false

        init(_ parent: ZoomablePixelCanvas) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.content
        }

        // One-finger paint must coexist with the scroll view's pinch (and its 2-finger pan) — they engage
        // at different touch counts, so allow simultaneous recognition rather than one starving the other.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePaintPan(_ gesture: UIPanGestureRecognizer) {
            guard let content = gesture.view else { return }
            switch gesture.state {
            case .began:
                beginStroke()
                paint(at: gesture.location(in: content), in: content)
            case .changed:
                paint(at: gesture.location(in: content), in: content)
            case .ended, .cancelled, .failed:
                isStroking = false
            default:
                break
            }
        }

        @objc func handlePaintTap(_ gesture: UITapGestureRecognizer) {
            guard let content = gesture.view else { return }
            beginStroke()
            paint(at: gesture.location(in: content), in: content)
            isStroking = false
        }

        private func beginStroke() {
            guard !isStroking else { return }
            isStroking = true
            parent.onStrokeBegan()
        }

        private func paint(at location: CGPoint, in content: UIView) {
            let width = content.bounds.width
            let height = content.bounds.height
            guard width > 0, height > 0, parent.cols > 0, parent.rows > 0 else { return }
            let x = Int((location.x / width * CGFloat(parent.cols)).rounded(.down))
            let y = Int((location.y / height * CGFloat(parent.rows)).rounded(.down))
            guard x >= 0, x < parent.cols, y >= 0, y < parent.rows else { return }
            parent.onPaintCell(x, y)
        }
    }
}

/// A `UIScrollView` set up for pinch-zoom + two-finger pan over a single content view, leaving one-finger
/// touches free for the caller's paint gestures.
final class ZoomScrollView: UIScrollView {
    let content = UIImageView()
    var gridCols = 0 { didSet { if gridCols != oldValue { gridColsRowsChanged = true } } }
    var gridRows = 0 { didSet { if gridRows != oldValue { gridColsRowsChanged = true } } }
    var gridColsRowsChanged = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        // Two fingers to pan, so a single finger is free to paint.
        panGestureRecognizer.minimumNumberOfTouches = 2

        content.contentMode = .scaleToFill
        content.backgroundColor = .clear
        content.isUserInteractionEnabled = true
        // Nearest-neighbour magnification keeps painted blocks crisp at every zoom level.
        content.layer.magnificationFilter = .nearest
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At 1× the content fills the (already aspect-ratio-constrained) frame; zooming scales it via the
        // scroll view transform, so only re-lay-out when not zoomed.
        if zoomScale == 1 {
            content.frame = bounds
            contentSize = bounds.size
        }
    }
}
