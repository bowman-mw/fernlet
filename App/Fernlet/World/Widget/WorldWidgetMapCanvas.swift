import SwiftUI
import UIKit
import WorldMapStore

/// What the map widget's picture draws over Apple's map (owner's Q36: "Places + trails, not history"):
/// the person's marked places — their homes and the hotel of a stay, and the places they keep to eat and
/// train — their saved trails, and the paths and roads they use most (owner 2026-11-15, call 6; none while "Show
/// worn paths" is off). Never a visit count, a day, a photo or Where you've been: those stay sealed in Private.
struct WorldWidgetMapContent: Equatable {
    /// The homes and the current hotel in the picture.
    var homes: [HomePlace] = []
    /// The kept places to eat and train in the picture (no photos on them).
    var places: [WorldMapMarker] = []
    /// The saved walk and run lines that cross the picture, each simplified.
    var trails: [[GeoPoint]] = []
    /// The worn paths and frequent roads in the picture.
    var worn: [WorldWidgetWornLine] = []

    /// Nothing to draw (a decoy, or nothing marked nearby).
    static let empty = WorldWidgetMapContent()

    /// The most places and trails one picture draws.
    static let maxPlaces = 60
    static let maxTrails = 40
    /// The most points one drawn trail keeps.
    static let maxTrailPoints = 400
    /// The most worn lines one picture draws (the most worn first).
    static let maxWornLines = 300

    /// `drawing`'s pieces whose box meets `viewport` (grown by a tenth each way), most worn first, roads before paths
    /// at a level, at most ``maxWornLines``.
    static func wornLines(_ drawing: WornWaysDrawing, in viewport: MapViewport) -> [WorldWidgetWornLine] {
        guard viewport.isUsable, !drawing.isEmpty else { return [] }
        let padX = viewport.width * 0.1, padY = viewport.height * 0.1
        let meets = { (line: WorldRoadPiece) in
            line.maxX >= viewport.minX - padX && line.minX <= viewport.minX + viewport.width + padX
                && line.maxY >= viewport.minY - padY && line.minY <= viewport.minY + viewport.height + padY
        }
        let tagged = drawing.roads.map { ($0, true) } + drawing.footpaths.map { ($0, false) }
        // Bounded: the drawing's pieces (WornWaysDrawing.maxPieces of each kind), then maxWornLines.
        return tagged.filter { meets($0.0.line) }
            .sorted { ($0.0.level, $0.1 ? 1 : 0) > ($1.0.level, $1.1 ? 1 : 0) }
            .prefix(maxWornLines)
            .map { piece, isRoad in
                WorldWidgetWornLine(level: piece.level, isRoad: isRoad,
                                    points: zip(piece.line.xs, piece.line.ys).map { WebMercator.geo(x: $0, y: $1) })
            }
    }

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

/// One worn path or frequent road in the map widget's picture.
struct WorldWidgetWornLine: Equatable {
    /// How worn.
    let level: WornLevel
    /// A road (else a footpath).
    let isRoad: Bool
    /// Its points.
    let points: [GeoPoint]
}

/// The map widget's picture for one appearance: Apple's muted map, the worn paths and roads, Fernlet's saved trails, a decorative
/// nature-fog ring at the edges (Home's look, in its reduced detail and still; never the fog of where you've been, which stays sealed), and the
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

    /// The worn ways, the trails, then the fog ring: lifted in a disc round the person (the picture's middle) and
    /// round each home and kept place, as the map uncovers them.
    private var ground: some View {
        Canvas { context, canvasSize in
            drawWorn(in: &context, size: canvasSize)
            let trailColor = dark ? WorldPalette.nightTrail : WorldPalette.trail
            for trail in content.trails {
                var path = Path()
                for (index, point) in trail.enumerated() {
                    let screen = viewport.screenPoint(for: point, in: canvasSize)
                    if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
                }
                context.stroke(path, with: .color(trailColor), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            NatureFogPicturePainter(viewport: viewport, clearing: Self.clearing(viewport: viewport, size: size, content: content),
                                    palette: NatureFogPalette(dark: dark, highContrast: false))
                .paint(&context, size: canvasSize)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The worn ways as Home draws them, at a fixed art pixel: the roads, then the footpaths.
    private func drawWorn(in context: inout GraphicsContext, size: CGSize) {
        // Bounded: maxWornLines lines.
        for road in [true, false] {
            for line in content.worn where line.isRoad == road {
                let path = Self.path(line.points, viewport: viewport, size: size)
                if road {
                    WornWaysPainter.strokeRoad(path, level: line.level, unit: Self.wornUnit, reduced: false, dark: dark,
                                               highContrast: false, in: &context)
                } else {
                    WornWaysPainter.strokeFootpath(path, level: line.level, width: Self.wornUnit * 2, dark: dark,
                                                   highContrast: false, in: &context)
                }
            }
        }
    }

    /// The art pixel the picture draws worn ways at, in points (a road 3.6 pt, a path 1.8 pt, under the 4-pt trails).
    static let wornUnit: CGFloat = 0.9

    /// A line through `points` in the picture's points.
    static func path(_ points: [GeoPoint], viewport: MapViewport, size: CGSize) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let screen = viewport.screenPoint(for: point, in: size)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        return path
    }

    /// The fog ring's clearing, shared with the one-colour picture (``WorldWidgetMonoCanvas``): the clear
    /// middle, a disc round the person reaching most of the way to the picture's nearer edge, and the cells
    /// drawn clear round the homes, the hotel and the kept places, as Home's map draws them.
    static func clearing(viewport: MapViewport, size: CGSize, content: WorldWidgetMapContent) -> NatureFogClearing {
        let radius = Double(min(size.width, size.height)) * 0.44 * WorldWidgetMap.metresPerPoint
        let opening = Set(MercatorHexGrid.disc(around: viewport.center, radius: radius))
        var uncovered = Set<HexCell>()
        for home in content.homes { uncovered.formUnion(MercatorHexGrid.disc(around: home.point, radius: home.uncoverRadius)) }
        for place in content.places { uncovered.formUnion(MercatorHexGrid.disc(around: place.point, radius: WorldMapMarker.uncoverRadius)) }
        return NatureFogClearing(lifted: opening, uncovered: uncovered)
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
