import SwiftUI

/// The base map with no map at all: a plain parchment ground with a faint survey grid.
///
/// Two jobs. It is the offline look until phase 2 (answer 30: GPS needs no signal, so the line,
/// the fog and the companion still draw), and it proves the seam: the same layers sit on it
/// unchanged, placed by the ``MapViewport`` it computes itself from Fernlet's camera.
struct PlainBaseMap: WorldBaseMap {
    var creditText: String? { "No base map · offline look" }

    func makeBody(camera: Binding<WorldCamera>, darkStyle: Bool, bottomInset: CGFloat,
                  onViewport: @escaping (MapViewport) -> Void) -> some View {
        PlainMapView(camera: camera, darkStyle: darkStyle, onViewport: onViewport)
    }
}

/// The view behind ``PlainBaseMap``: pans with a drag, zooms with a pinch.
private struct PlainMapView: View {
    @Binding var camera: WorldCamera
    let darkStyle: Bool
    let onViewport: (MapViewport) -> Void
    @State private var dragStart: GeoPoint?
    @State private var pinchStart: Double?

    /// Visible height per metre of camera distance, measured off Apple's map on an iPhone 17, so
    /// switching base maps keeps the same zoom.
    private static let heightPerDistance = 0.57

    var body: some View {
        GeometryReader { proxy in
            let viewport = MapViewport.around(camera.center, heightMetres: camera.distance * Self.heightPerDistance, size: proxy.size)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(darkStyle ? FernColors.rgb(0x2E2A24) : FernColors.rgb(0xEDE6D3)))
                drawGrid(&context, size: size, viewport: viewport)
            }
            .contentShape(Rectangle())
            .gesture(drag(viewport: viewport, size: proxy.size))
            .simultaneousGesture(pinch)
            .onAppear { onViewport(viewport) }
            .onChange(of: viewport) { onViewport(viewport) }
        }
    }

    /// Survey lines every 200 m, so movement still reads with nothing else on the ground.
    private func drawGrid(_ context: inout GraphicsContext, size: CGSize, viewport: MapViewport) {
        let origin = WorldFixtures.grid.origin
        let ppm = viewport.pointsPerMetre(at: origin.latitude, in: size)
        let originPoint = viewport.screenPoint(for: origin, in: size)
        let step = 200 * ppm
        guard step > 8 else { return }
        var path = Path()
        let columns = Int(size.width / step) + 2, rows = Int(size.height / step) + 2
        let startX = originPoint.x.truncatingRemainder(dividingBy: step), startY = originPoint.y.truncatingRemainder(dividingBy: step)
        for index in -1...min(columns, 400) { let x = startX + CGFloat(index) * step; path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
        for index in -1...min(rows, 400) { let y = startY + CGFloat(index) * step; path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
        context.stroke(path, with: .color(FernColors.bark.opacity(0.08)), lineWidth: 1)
    }

    /// Dragging moves the ground under the finger and stops the camera following the companion.
    private func drag(viewport: MapViewport, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStart ?? camera.center
                if dragStart == nil { dragStart = start }
                let ppm = viewport.pointsPerMetre(at: start.latitude, in: size)
                guard ppm > 0 else { return }
                camera.center = start.offset(east: -Double(value.translation.width) / ppm,
                                             north: Double(value.translation.height) / ppm)
                camera.follows = false
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Pinching zooms between 300 m and 7 km, as Apple's map is bounded.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? camera.distance
                if pinchStart == nil { pinchStart = start }
                camera.distance = min(7_000, max(300, start / Double(value.magnification)))
            }
            .onEnded { _ in pinchStart = nil }
    }
}
