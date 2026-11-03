import SwiftUI
import UIKit

/// Lets the map's pan and pinch run together, so two fingers can move and zoom the map at once.
final class WorldMapGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer || other is UIPinchGestureRecognizer
    }
}

/// The world map's pan: one or two fingers, reported as the distance moved since the last report, so nothing it
/// holds can go stale. UIKit's recognizer follows the fingers' middle and takes a finger landing or lifting
/// without a jump, which SwiftUI's `DragGesture` does not.
struct WorldMapPanRecognizer: UIGestureRecognizerRepresentable {
    /// The fingers moved by this much since the last report.
    let onMove: (CGSize) -> Void
    /// The fingers lifted, or the system cancelled the pan.
    let onEnd: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> WorldMapGestureDelegate { WorldMapGestureDelegate() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            let moved = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            onMove(CGSize(width: moved.x, height: moved.y))
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }
}

/// The world map's pinch, reported as the ratio since the last report and the fingers' middle in the map's own
/// points, so the map zooms round the place between the fingers wherever they travel.
struct WorldMapPinchRecognizer: UIGestureRecognizerRepresentable {
    /// The fingers spread by this ratio since the last report, round this point.
    let onPinch: (CGFloat, CGPoint) -> Void
    /// The fingers lifted, or the system cancelled the pinch.
    let onEnd: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> WorldMapGestureDelegate { WorldMapGestureDelegate() }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let pinch = UIPinchGestureRecognizer()
        pinch.delegate = context.coordinator
        return pinch
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            let ratio = recognizer.scale
            recognizer.scale = 1
            guard recognizer.numberOfTouches >= 2 else { return }
            onPinch(ratio, context.converter.localLocation)
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }
}

extension View {
    /// Stands this view on `point` with its `alignment` guide exactly there, however big it or the views beside it
    /// are. Each mark lays out at zero size, so the marks of a `ZStack` never push each other about (a `ZStack`
    /// grows to hold every child's guide, which moved a whole layer of marks by the largest guide).
    func worldMapPinned(at point: CGPoint, _ alignment: Alignment) -> some View {
        fixedSize()
            .frame(width: 0, height: 0, alignment: alignment)
            .offset(x: point.x, y: point.y)
    }
}
