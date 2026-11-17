import SwiftUI
import WorldMapStore

/// How worn paths and frequent roads look (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §3, §8), beside
/// ``WorldRoadStyle``: a footpath is worn dirt about 2 art pixels wide with square ends and no dash, darkening in three
/// steps, the top one with a darker edge; a road is grey with a pale centre dash about 4 art pixels wide, brightening
/// in three steps to the crossed roads' amber; an abandoned way is faint and broken, a path with grass growing through.
/// A railway (Docs/World-Transit-Paths-Exploration-2026-11-15.md §3) is the classic pixel railway, two thin grey rails
/// over brown sleepers every three art pixels, brightening in three steps; abandoned, rusty rails with grass between
/// the sleepers. A ferry crossing (§2) is a dashed white wake over the water, lighter at the lower levels; abandoned,
/// very faint and sparse.
/// Dark Mode mixes every colour toward the nature fog's night ground as the fog's fixed colours do; Increase Contrast
/// gives every footpath level the dark edge, darkens the road edge, edges the rails and the wake and lifts the
/// abandoned looks.
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

    // MARK: Railways (rails over sleepers)

    /// The rails by level: abandoned (rust), light, often, the most (bright steel).
    static let rail: [UInt32] = [0x9A5536, 0x8A8782, 0xA9A59F, 0xD0CCC4]
    /// The sleepers by level, brown, warming with use.
    static let sleeper: [UInt32] = [0x6E5A48, 0x6B4A2E, 0x75502F, 0x83592F]
    /// The rails' edge under Increase Contrast.
    static let railEdgeHighContrast: UInt32 = 0x2A2724

    // MARK: Ferry wakes

    /// The wake's white.
    static let wake: UInt32 = 0xFFFFFF
    /// How strongly the wake shows by level: abandoned (very faint), light, often, the most.
    static let wakeOpacity: [Double] = [0.3, 0.55, 0.75, 0.95]
    /// The wake's edge under Increase Contrast (deep water).
    static let wakeEdgeHighContrast: UInt32 = 0x1F4E6E

    // MARK: Your world

    /// Your world's long railways: a thin dark line with ticks.
    static let yourWorldRail: UInt32 = 0x3A332D
    /// Your world's long ferry crossings: a thin dashed line.
    static let yourWorldWake: UInt32 = 0x2F5D7C

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

/// Strokes a ``WornWaysDrawing`` into Home's ground Canvas, under the fog: the ferry wakes, the roads, the railways,
/// then the footpaths, only the pieces in view, each clipped by ``WorldRoadPainter``. Zoomed out a step, trodden
/// footpaths drop and roads, railways and wakes thin.
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
            let path = WorldRoadPainter.path(drawing.ferriesByLevel[level.rawValue], size: size, projection: projection)
            guard !path.isEmpty else { continue }
            strokeWake(path, level: level, unit: unit, reduced: reduced, dark: dark, highContrast: highContrast, in: &context)
        }
        // Bounded: the four levels.
        for level in WornLevel.allCases {
            let path = WorldRoadPainter.path(drawing.roadsByLevel[level.rawValue], size: size, projection: projection)
            guard !path.isEmpty else { continue }
            strokeRoad(path, level: level, unit: unit, reduced: reduced, dark: dark, highContrast: highContrast, in: &context)
        }
        // Bounded: the four levels.
        for level in WornLevel.allCases {
            let path = WorldRoadPainter.path(drawing.railsByLevel[level.rawValue], size: size, projection: projection)
            guard !path.isEmpty else { continue }
            strokeRail(path, level: level, unit: unit, reduced: reduced, dark: dark, highContrast: highContrast, in: &context)
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

    /// One level's railway `path`: brown sleepers 1 art pixel thick every 3, across two thin rails 3 art pixels apart
    /// (2 zoomed out); the rails' gap is cut out of one wide stroke in a layer, so the sleepers show between them.
    /// Abandoned: faint rusty rails, with grass pixels between the sleepers.
    static func strokeRail(_ path: Path, level: WornLevel, unit: CGFloat, reduced: Bool, dark: Bool, highContrast: Bool,
                           in context: inout GraphicsContext) {
        let gauge = unit * (reduced ? 2.4 : 3.6), railWidth = max(0.5, unit * (reduced ? 0.6 : 0.8))
        let abandoned = level == .abandoned
        let opacity = abandoned ? (highContrast ? WornWaysStyle.abandonedOpacityHighContrast : WornWaysStyle.abandonedOpacity) : 1
        let sleeper = WornWaysStyle.ink(WornWaysStyle.sleeper[level.rawValue], dark: dark).opacity(opacity)
        context.stroke(path, with: .color(sleeper),
                       style: StrokeStyle(lineWidth: gauge + unit * (reduced ? 1 : 2), lineCap: .butt, lineJoin: .bevel, dash: [unit, 2 * unit]))
        if abandoned {
            context.stroke(path, with: .color(WornWaysStyle.ink(WornWaysStyle.grass, dark: dark).opacity(opacity)),
                           style: StrokeStyle(lineWidth: gauge * 0.6, lineCap: .butt, dash: [unit, 5 * unit], dashPhase: -1.5 * unit))
        }
        if highContrast {
            railPair(path, color: WornWaysStyle.ink(WornWaysStyle.railEdgeHighContrast, dark: dark).opacity(opacity),
                     gauge: gauge + unit / 2, railWidth: railWidth + unit / 2, in: &context)
        }
        railPair(path, color: WornWaysStyle.ink(WornWaysStyle.rail[level.rawValue], dark: dark).opacity(opacity),
                 gauge: gauge, railWidth: railWidth, in: &context)
    }

    /// Two rails `railWidth` wide along `path`, `gauge` apart outside to outside.
    private static func railPair(_ path: Path, color: Color, gauge: CGFloat, railWidth: CGFloat, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: gauge, lineCap: .butt, lineJoin: .round))
            layer.blendMode = .destinationOut
            layer.stroke(path, with: .color(.black),
                         style: StrokeStyle(lineWidth: max(0, gauge - 2 * railWidth), lineCap: .square, lineJoin: .round))
        }
    }

    /// One level's ferry wake `path`: a white dash 1.5 art pixels wide (1 zoomed out), lighter and shorter at the
    /// lower levels; abandoned, very faint and sparse. Increase Contrast edges it in deep water blue.
    static func strokeWake(_ path: Path, level: WornLevel, unit: CGFloat, reduced: Bool, dark: Bool, highContrast: Bool,
                           in context: inout GraphicsContext) {
        let width = unit * (reduced ? 1 : 1.5)
        let dash: [CGFloat] = switch level {
        case .abandoned: [unit, 5 * unit]
        case .one: [2 * unit, 3 * unit]
        case .two, .three: [3 * unit, 2 * unit]
        }
        let base = WornWaysStyle.wakeOpacity[level.rawValue]
        let opacity = highContrast ? min(1, base + 0.25) : base
        if highContrast {
            context.stroke(path, with: .color(WornWaysStyle.ink(WornWaysStyle.wakeEdgeHighContrast, dark: dark).opacity(opacity)),
                           style: StrokeStyle(lineWidth: width + unit, lineCap: .butt, lineJoin: .round, dash: dash))
        }
        context.stroke(path, with: .color(WornWaysStyle.ink(WornWaysStyle.wake, dark: dark).opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round, dash: dash))
    }
}
