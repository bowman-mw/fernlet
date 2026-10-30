import SwiftUI
import WorldMapStore

/// The world view's colours (the mockup's `fogInk`, `worldZoom` and `kit-explore.css`): faint land and sea
/// under the fog, the found ones in full, the lines on hex edges, and the framed chips' paper and ink.
nonisolated enum WorldViewInk {
    /// A hex's fill and its 0.8-pt edge: found land is green and found water blue (both modes); fogged land
    /// is pale sand and fogged sea pale blue, both darker at night.
    static func hex(land: Bool, found: Bool, dark: Bool) -> (fill: UInt32, edge: UInt32) {
        if found { return land ? (0x9DC27A, 0x8DB46B) : (0x6FA8D0, 0x629BC4) }
        if land { return dark ? (0x5A513E, 0x4E4636) : (0xD9C9A2, 0xCDBD96) }
        return dark ? (0x2B3743, 0x25303A) : (0xC3D7E3, 0xB7CCD9)
    }

    /// The sea behind every hex (the page's background).
    static func sea(dark: Bool) -> UInt32 { dark ? 0x2B3743 : 0xC3D7E3 }

    /// The ink of the country and state lines: dark brown by day, cream at night (the closest-zoom drawing).
    static func line(dark: Bool) -> UInt32 { dark ? 0xF3E6C8 : 0x3A2414 }
    /// The state and province line: 2.6 pt at 85 % (`ex-world-zoom`, approved).
    static let regionLineWidth = 2.6
    /// The country line: a little heavier than the state line.
    static let countryLineWidth = 3.4
    /// The lines' opacity.
    static let lineOpacity = 0.85
    /// A hex's edge line.
    static let hexEdgeWidth = 0.8

    /// The chips' paper (`#FFF6E2`, in both modes as drawn).
    static let paper = WorldPalette.rgb(0xFFF6E2)
    /// The chips' text: the bark ink, darker under Increase Contrast (11:1 on the paper).
    static let text = WorldPalette.adaptive(light: 0x3A2414, dark: 0x3A2414, lightHC: 0x2A1808, darkHC: 0x2A1808)
    /// The chips' frame: the World ink.
    static let frame = WorldPalette.ink
    /// A dimmed + or −.
    static let dimmed = WorldPalette.rgb(0x8C7A66)
    /// The shade under a chip's bottom edge (`0 2px 0 rgba(40, 20, 8, .25)`).
    static let shade = Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 8 / 255, opacity: 0.25)
    /// The far markers' square.
    static let markerGold = WorldPalette.rgb(0xF2D58A)
}

/// The world view's map: the level's hexes over the whole screen, faint land and sea under the fog and what
/// the person uncovered in full, then the country lines (from Country) and state lines (from State) on the
/// hex edges. Only the hexes on screen are drawn, in one path per colour. Decoration to VoiceOver: the markers
/// and the zoom control carry the meaning.
struct WorldViewMapCanvas: View {
    let camera: WorldViewCamera
    let model: WorldViewModel
    /// Read so the map redraws when places, uncovered hexes or the raster arrive.
    let generation: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(WorldPalette.rgb(WorldViewInk.sea(dark: dark))))
            let hexes = camera.visibleHexes()
            drawHexes(hexes, in: &context, dark: dark)
            drawLines(hexes, in: &context, dark: dark)
        }
        .accessibilityHidden(true)
    }

    /// One path per fill colour, then their edges.
    private func drawHexes(_ hexes: [WorldViewVisibleHex], in context: inout GraphicsContext, dark: Bool) {
        let corners = cornerOffsets
        var paths: [UInt32: (path: Path, edge: UInt32)] = [:]
        // Bounded: the hexes on screen (WorldViewCamera.maxVisibleHexes).
        for hex in hexes {
            let land = model.isLand(hex.cell, x: hex.x, y: hex.y, at: camera.level)
            let ink = WorldViewInk.hex(land: land, found: model.isFound(hex.cell, at: camera.level), dark: dark)
            let centre = camera.screenPoint(x: hex.x, y: hex.y)
            var entry = paths[ink.fill] ?? (path: Path(), edge: ink.edge)
            entry.path.addLines(corners.map { CGPoint(x: centre.x + $0.x, y: centre.y + $0.y) })
            entry.path.closeSubpath()
            paths[ink.fill] = entry
        }
        for (fill, entry) in paths {
            context.fill(entry.path, with: .color(WorldPalette.rgb(fill)))
            context.stroke(entry.path, with: .color(WorldPalette.rgb(entry.edge)), lineWidth: WorldViewInk.hexEdgeWidth)
        }
    }

    /// The country and state lines on shared hex edges, where the level draws them.
    private func drawLines(_ hexes: [WorldViewVisibleHex], in context: inout GraphicsContext, dark: Bool) {
        let level = camera.level
        guard level.showsCountryLines else { return }
        let segments = WorldViewBorders.segments(hexes, level: level, model: model)
        let ink = WorldPalette.rgb(WorldViewInk.line(dark: dark)).opacity(WorldViewInk.lineOpacity)
        let style = { (width: Double) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        context.stroke(path(segments.region), with: .color(ink), style: style(WorldViewInk.regionLineWidth))
        context.stroke(path(segments.country), with: .color(ink), style: style(WorldViewInk.countryLineWidth))
    }

    /// A path of the edge segments, on screen.
    private func path(_ edges: [(x: Double, y: Double, corner: Int, next: Int)]) -> Path {
        let corners = cornerOffsets
        var path = Path()
        for edge in edges {
            let centre = camera.screenPoint(x: edge.x, y: edge.y)
            path.move(to: CGPoint(x: centre.x + corners[edge.corner].x, y: centre.y + corners[edge.corner].y))
            path.addLine(to: CGPoint(x: centre.x + corners[edge.next].x, y: centre.y + corners[edge.next].y))
        }
        return path
    }

    /// The six corners of a hex on screen, as offsets from its centre.
    private var cornerOffsets: [CGPoint] {
        let scale = camera.scale
        return camera.level.hexGrid.cornerOffsets.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
    }
}

/// The lines on hex edges (World-Exploration-Spec §2, "drawn on the hex edges"): each visible land hex is
/// compared with its east, south-east and south-west neighbours (so every edge is looked at once), and an
/// edge between two different places carries the line ``WorldAtlas/border(between:and:)`` names, when the
/// level draws it. A hex whose place is not looked up yet draws no line until it is.
nonisolated enum WorldViewBorders {
    /// One hex edge: the hex's unwrapped Mercator centre and the two corners (indices into the grid's
    /// ``WorldViewHexGrid/cornerOffsets``) that bound the edge.
    typealias Edge = (x: Double, y: Double, corner: Int, next: Int)

    /// The forward neighbours: the axial step and the edge's corners (pointy-top, corners from 30°, y down).
    static let forward: [(dq: Int, dr: Int, corner: Int, next: Int)] = [(1, 0, 5, 0), (0, 1, 0, 1), (-1, 1, 1, 2)]

    /// The state-line and country-line edges among `hexes` at `level`.
    @MainActor
    static func segments(_ hexes: [WorldViewVisibleHex], level: AtlasZoomLevel,
                         model: WorldViewModel) -> (region: [Edge], country: [Edge]) {
        let grid = level.hexGrid
        let across = 3.0.squareRoot() * grid.radius
        var region: [Edge] = [], country: [Edge] = []
        // Bounded: the hexes on screen, three edges each.
        for hex in hexes {
            guard let known = model.place(of: hex.cell, at: level), let here = known else { continue }
            for step in forward {
                let nx = hex.x + across * (Double(step.dq) + Double(step.dr) / 2), ny = hex.y + 1.5 * grid.radius * Double(step.dr)
                let cell = WorldViewCamera.canonical((nx, ny), in: grid)
                let there: AtlasPlaceName?
                if model.isLand(cell, x: nx, y: ny, at: level) {
                    guard let looked = model.place(of: cell, at: level) else { continue }
                    there = looked
                } else {
                    there = nil
                }
                let border = WorldAtlas.border(between: here, and: there)
                guard level.draws(border) else { continue }
                let edge: Edge = (hex.x, hex.y, step.corner, step.next)
                if border == .country { country.append(edge) } else { region.append(edge) }
            }
        }
        return (region, country)
    }
}
