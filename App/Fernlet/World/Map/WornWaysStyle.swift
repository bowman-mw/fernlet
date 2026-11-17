import SwiftUI
import WorldMapStore

/// How worn paths and frequent roads look (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §3, §8), beside
/// ``WorldRoadStyle``: a footpath is worn dirt about 2 art pixels wide with square ends and no dash, darkening in three
/// steps, the top one with a darker edge; a road is grey with a pale centre dash about 4 art pixels wide, brightening
/// in three steps to the crossed roads' amber; an abandoned way is faint and broken, a path with grass growing through.
/// Dark Mode mixes every colour toward the nature fog's night ground as the fog's fixed colours do; Increase Contrast
/// gives every footpath level the dark edge, darkens the road edge and lifts the abandoned looks.
nonisolated enum WornWaysStyle {
    // MARK: Footpaths (worn dirt)

    /// The dirt by level: abandoned, trodden, worn, well worn.
    static let dirt: [UInt32] = [0xC9A97C, 0xC49A66, 0xA9794A, 0x8C5D33]
    /// The well-worn path's darker edge (every level's under Increase Contrast).
    static let dirtEdge: UInt32 = 0x5A3A1E
    /// The grass growing through an abandoned path (the fog's seam green).
    static let grass: UInt32 = 0x7FA762

    // MARK: Roads (lit with use)

    /// The road by level: abandoned, light, often, the most (the crossed roads' amber).
    static let road: [UInt32] = [0x9C9893, 0x8E8B87, 0xB9B5AF, WorldRoadStyle.amber]
    /// A grey road's edge, and its edge under Increase Contrast.
    static let roadEdge: UInt32 = 0x4A4642
    static let roadEdgeHighContrast: UInt32 = 0x2A2724
    /// A grey road's pale centre dash.
    static let roadDash: UInt32 = 0xF4F1EA

    /// How strongly an abandoned way shows, and under Increase Contrast.
    static let abandonedOpacity = 0.6
    static let abandonedOpacityHighContrast = 0.85

    /// The passport's Your world road width at `level`: a thin line, under the crossed main roads' width there.
    static func yourWorldWidth(at level: AtlasZoomLevel) -> CGFloat {
        WorldRoadStyle.worldWidth(at: level, kind: .mainRoad) * 0.6
    }

    /// `value` (0xRRGGBB) for the appearance: mixed toward the night ground in Dark Mode.
    static func ink(_ value: UInt32, dark: Bool) -> Color {
        WorldPalette.rgb(dark ? NatureFogPalette.mix(value, toward: NatureFogPalette.night, by: NatureInk.fixedDarkShare) : value)
    }

    /// The art pixel on Home at `viewport` drawn in `size`: a hex's radius over 8, at least 1.6 pt when `reduced` (the
    /// nature fog's own unit).
    static func artPixel(_ viewport: MapViewport, in size: CGSize, reduced: Bool) -> CGFloat {
        let radius = MercatorHexGrid.radius * Double(size.width) / viewport.width
        let unit = radius / 8
        return CGFloat(reduced ? max(unit, 1.6) : unit)
    }
}

/// Strokes a ``WornWaysDrawing`` into Home's ground Canvas, under the fog: the roads, then the footpaths, only the
/// pieces in view, each clipped by ``WorldRoadPainter``. Zoomed out a step, trodden footpaths drop and roads thin.
enum WornWaysPainter {
    /// Draws `drawing` over `viewport` into `size`.
    static func draw(_ drawing: WornWaysDrawing, in context: inout GraphicsContext, size: CGSize, viewport: MapViewport,
                     dark: Bool, highContrast: Bool) {
        guard !drawing.isEmpty, WorldLayerGuard.accepts(viewport, in: size) else { return }
        let projection = WorldRoadPainter.Projection(originX: viewport.minX, originY: viewport.minY,
                                                     scale: Double(size.width) / viewport.width)
        let reduced = WorldExploreSelection.isZoomedOut(viewport)
        let unit = WornWaysStyle.artPixel(viewport, in: size, reduced: reduced)
        // Bounded: the four levels.
        for level in WornLevel.allCases {
            let path = WorldRoadPainter.path(drawing.roadsByLevel[level.rawValue], size: size, projection: projection)
            guard !path.isEmpty else { continue }
            strokeRoad(path, level: level, unit: unit, reduced: reduced, dark: dark, highContrast: highContrast, in: &context)
        }
        // Bounded: the four levels.
        for level in WornLevel.allCases where !(reduced && level == .one) {
            let path = WorldRoadPainter.path(drawing.footpathsByLevel[level.rawValue], size: size, projection: projection)
            guard !path.isEmpty else { continue }
            strokeFootpath(path, level: level, width: unit * 2, dark: dark, highContrast: highContrast, in: &context)
        }
    }

    /// One level's footpath `path`, `width` wide.
    static func strokeFootpath(_ path: Path, level: WornLevel, width: CGFloat, dark: Bool, highContrast: Bool,
                               in context: inout GraphicsContext) {
        let dirt = WornWaysStyle.ink(WornWaysStyle.dirt[level.rawValue], dark: dark)
        guard level != .abandoned else {
            let unit = width / 2, opacity = highContrast ? WornWaysStyle.abandonedOpacityHighContrast : WornWaysStyle.abandonedOpacity
            context.stroke(path, with: .color(dirt.opacity(opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .miter, dash: [2 * unit, 2 * unit]))
            context.stroke(path, with: .color(WornWaysStyle.ink(WornWaysStyle.grass, dark: dark).opacity(opacity)),
                           style: StrokeStyle(lineWidth: width * 0.8, lineCap: .butt, dash: [unit, 3 * unit], dashPhase: -2.5 * unit))
            return
        }
        if level == .three || highContrast {
            context.stroke(path, with: .color(WornWaysStyle.ink(WornWaysStyle.dirtEdge, dark: dark)),
                           style: StrokeStyle(lineWidth: width + width / 2, lineCap: .square, lineJoin: .miter))
        }
        context.stroke(path, with: .color(dirt), style: StrokeStyle(lineWidth: width, lineCap: .square, lineJoin: .miter))
    }

    /// One level's road `path`: 4 art pixels wide (2 zoomed out, with no dash), an edge, the road, the pale dash.
    static func strokeRoad(_ path: Path, level: WornLevel, unit: CGFloat, reduced: Bool, dark: Bool, highContrast: Bool,
                           in context: inout GraphicsContext) {
        let width = unit * (reduced ? 2 : 4)
        let road = WornWaysStyle.ink(WornWaysStyle.road[level.rawValue], dark: dark)
        guard level != .abandoned else {
            let opacity = highContrast ? WornWaysStyle.abandonedOpacityHighContrast : WornWaysStyle.abandonedOpacity
            context.stroke(path, with: .color(road.opacity(opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round, dash: [3 * unit, 2 * unit]))
            return
        }
        let edge = level == .three ? WorldRoadStyle.ink : (highContrast ? WornWaysStyle.roadEdgeHighContrast : WornWaysStyle.roadEdge)
        context.stroke(path, with: .color(WornWaysStyle.ink(edge, dark: dark)),
                       style: StrokeStyle(lineWidth: width + unit, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(road), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        guard !reduced else { return }
        let dash = level == .three ? WorldRoadStyle.dash : WornWaysStyle.roadDash
        context.stroke(path, with: .color(WornWaysStyle.ink(dash, dark: dark)),
                       style: StrokeStyle(lineWidth: max(1, unit / 2), dash: [2 * unit, 2.5 * unit]))
    }
}
