import SwiftUI
import WorldMapStore

/// The base map with no map at all: a plain ground with a faint survey grid.
///
/// Two jobs. It is the offline look until phase 2 (design page answer 30: GPS needs no signal, so the
/// fog, lines and companion still draw), and it proves the seam: the same layers sit on it unchanged,
/// placed by the `MapViewport` it computes itself from Fernlet's camera. It also stands in before the
/// person has allowed location, when there is no place to show.
struct PlainBaseMap: WorldBaseMap {
    var drawsOwnCredit: Bool { false }

    /// Visible height per metre of camera distance, measured off Apple's map on an iPhone 17 (World
    /// Shell), so switching base maps keeps the same zoom (the Home also places the companion by it).
    static let heightPerDistance = 0.57

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

    /// Survey-line spacing in Mercator units: 200 m at the fog grid's reference latitude. A fixed unit
    /// step keeps the lines put while the person pans.
    private static let gridStep = 200 * WebMercator.unitsPerMetre(at: MercatorHexGrid.referenceLatitude)

    var body: some View {
        GeometryReader { proxy in
            let viewport = MapViewport.around(camera.center, heightMetres: camera.distance * PlainBaseMap.heightPerDistance,
                                              size: proxy.size)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(darkStyle ? WorldPalette.nightPlainGround : WorldPalette.plainGround))
                drawGrid(&context, size: size, viewport: viewport)
            }
            .contentShape(Rectangle())
            .gesture(drag(viewport: viewport, size: proxy.size))
            .simultaneousGesture(pinch)
            .onAppear { onViewport(viewport) }
            .onChange(of: viewport) { onViewport(viewport) }
        }
    }

    /// Survey lines on a fixed Mercator step, so movement still reads with nothing else on the ground.
    /// At most 200 lines each way; none once they would sit closer than 8 points.
    private func drawGrid(_ context: inout GraphicsContext, size: CGSize, viewport: MapViewport) {
        let perUnit = viewport.pointsPerUnit(in: size)
        guard perUnit > 0, Self.gridStep * perUnit > 8 else { return }
        var path = Path()
        let firstColumn = Int((viewport.minX / Self.gridStep).rounded(.down))
        let firstRow = Int((viewport.minY / Self.gridStep).rounded(.down))
        for index in 0...min(Int(viewport.width / Self.gridStep) + 1, 200) {
            let x = viewport.screenPoint(x: Double(firstColumn + index) * Self.gridStep, y: viewport.minY, in: size).x
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for index in 0...min(Int(viewport.height / Self.gridStep) + 1, 200) {
            let y = viewport.screenPoint(x: viewport.minX, y: Double(firstRow + index) * Self.gridStep, in: size).y
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(WorldPalette.bark.opacity(0.08)), lineWidth: 1)
    }

    /// Dragging moves the ground under the finger and stops the camera following the companion.
    private func drag(viewport: MapViewport, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStart ?? camera.center
                if dragStart == nil { dragStart = start }
                let perMetre = viewport.pointsPerMetre(at: start.latitude, in: size)
                guard perMetre > 0 else { return }
                camera.center = start.offset(east: -Double(value.translation.width) / perMetre,
                                             north: Double(value.translation.height) / perMetre)
                camera.follows = false
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Pinching zooms within the camera's range, as Apple's map is bounded.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? camera.distance
                if pinchStart == nil { pinchStart = start }
                let range = WorldCamera.distanceRange
                camera.distance = min(range.upperBound, max(range.lowerBound, start / Double(max(value.magnification, 0.01))))
            }
            .onEnded { _ in pinchStart = nil }
    }
}
