import SwiftUI
import UIKit
import WorldMapStore

/// What the map widget's picture draws over Apple's map (owner's Q36: "Places + trails, not history"):
/// the person's marked places — their homes and the hotel of a stay, and the places they keep to eat and
/// train — and their saved trails. Never a visit count, a day, a photo or Where you've been: those stay
/// sealed in Private.
struct WorldWidgetMapContent: Equatable {
    /// The homes and the current hotel in the picture.
    var homes: [HomePlace] = []
    /// The kept places to eat and train in the picture (no photos on them).
    var places: [WorldMapMarker] = []
    /// The saved walk and run lines that cross the picture, each simplified.
    var trails: [[GeoPoint]] = []

    /// Nothing to draw (a decoy, or nothing marked nearby).
    static let empty = WorldWidgetMapContent()

    /// The most places and trails one picture draws.
    static let maxPlaces = 60
    static let maxTrails = 40
    /// The most points one drawn trail keeps.
    static let maxTrailPoints = 400

    /// Whether `point` falls in `viewport`, or within `margin` of it (a share of its size).
    static func contains(_ viewport: MapViewport, _ point: GeoPoint, margin: Double = 0.1) -> Bool {
        guard viewport.isUsable, point.isValid else { return false }
        let unit = WebMercator.unit(point)
        let padX = viewport.width * margin, padY = viewport.height * margin
        return unit.x >= viewport.minX - padX && unit.x <= viewport.minX + viewport.width + padX
            && unit.y >= viewport.minY - padY && unit.y <= viewport.minY + viewport.height + padY
    }

    /// `line` thinned for a picture of `size` over `viewport`: a point is kept once it is at least
    /// `step` points from the last kept one, at most ``maxTrailPoints``; nil when no point is in the
    /// picture, or fewer than two are left.
    static func drawable(_ line: [GeoPoint], in viewport: MapViewport, size: CGSize, step: CGFloat = 3) -> [GeoPoint]? {
        guard line.count >= 2, line.contains(where: { contains(viewport, $0) }) else { return nil }
        var kept: [GeoPoint] = []
        var last: CGPoint?
        for point in line.prefix(20_000) where kept.count < maxTrailPoints {
            let screen = viewport.screenPoint(for: point, in: size)
            if let last, hypot(screen.x - last.x, screen.y - last.y) < step { continue }
            kept.append(point)
            last = screen
        }
        if let end = line.last, kept.last != end, kept.count < maxTrailPoints { kept.append(end) }
        return kept.count >= 2 ? kept : nil
    }

    /// DEBUG screenshots (`FERNLET_UI_TEST_WORLD_HOME=trails`): a loop round `point` and a path through it,
    /// display only.
    static func testTrails(around point: GeoPoint) -> [[GeoPoint]] {
        let loop = (0...24).map { index -> GeoPoint in
            let angle = Double(index) / 24 * 2 * .pi
            return point.offset(east: 120 + 110 * cos(angle), north: -40 + 90 * sin(angle))
        }
        let path = [point.offset(east: -10, north: -260), point.offset(east: -4, north: -60), point,
                    point.offset(east: 6, north: 120), point.offset(east: 60, north: 260)]
        return [loop, path]
    }
}

/// The map widget's picture for one appearance: Apple's muted map, Fernlet's saved trails, a decorative
/// fog ring at the edges (Home's look; never the fog of where you've been, which stays sealed), and the
/// homes, hotel and kept places as the map draws them. Sprout, the hearts and "Map from 9:40" are the
/// widget's own, drawn over it live.
struct WorldWidgetMapCanvas: View {
    /// Apple's map of `viewport`.
    let base: UIImage
    let viewport: MapViewport
    let size: CGSize
    let content: WorldWidgetMapContent
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: base).resizable().accessibilityIgnoresInvertColors().frame(width: size.width, height: size.height)
            // Apple's "Maps" logo, which the snapshot draws bottom left, stays clear of the fog and the
            // lines (MapKit terms), as on the live map.
            ground.mask { WorldMapCreditClearance(bottomInset: 0, active: true) }
            ForEach(content.places) { place in
                WorldPlaceIconTile(marker: place)
                    .fixedSize()
                    .position(viewport.screenPoint(for: place.point, in: size))
            }
            ForEach(content.homes) { home in
                let at = viewport.screenPoint(for: home.point, in: size)
                let offset = WorldPlaceSprites.baseOffset(scale: 4)
                WorldHomeMarkerView(place: home, isNight: false, companion: "")
                    .fixedSize()
                    .position(x: at.x + offset.width, y: at.y + offset.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// The trails, then the fog ring: lifted in a disc round the person (the picture's middle) and round
    /// each home and kept place, as the map uncovers them.
    private var ground: some View {
        Canvas { context, canvasSize in
            let trailColor = dark ? WorldPalette.nightTrail : WorldPalette.trail
            for trail in content.trails {
                var path = Path()
                for (index, point) in trail.enumerated() {
                    let screen = viewport.screenPoint(for: point, in: canvasSize)
                    if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
                }
                context.stroke(path, with: .color(trailColor), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            WorldFogPainter(viewport: viewport, lifted: ringOpening, darkStyle: dark, uncovered: uncovered)
                .paint(&context, size: canvasSize)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The clear middle: a disc round the person reaching most of the way to the picture's nearer edge.
    private var ringOpening: Set<HexCell> {
        let radius = Double(min(size.width, size.height)) * 0.44 * WorldWidgetMap.metresPerPoint
        return Set(MercatorHexGrid.disc(around: viewport.center, radius: radius))
    }

    /// Drawn clear round the homes, the hotel and the kept places, as Home's map draws them.
    private var uncovered: Set<HexCell> {
        var cells = Set<HexCell>()
        for home in content.homes { cells.formUnion(MercatorHexGrid.disc(around: home.point, radius: HomeBook.uncoverRadius)) }
        for place in content.places { cells.formUnion(MercatorHexGrid.disc(around: place.point, radius: WorldMapMarker.uncoverRadius)) }
        return cells
    }

    /// The picture as PNG at `scale`, or nil when it can't be drawn.
    static func png(base: UIImage, viewport: MapViewport, content: WorldWidgetMapContent, dark: Bool,
                    size: CGSize, scale: CGFloat) -> Data? {
        guard viewport.isUsable, size.width > 0, size.height > 0 else { return nil }
        let renderer = ImageRenderer(content: WorldWidgetMapCanvas(base: base, viewport: viewport, size: size, content: content, dark: dark))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage?.pngData()
    }
}
