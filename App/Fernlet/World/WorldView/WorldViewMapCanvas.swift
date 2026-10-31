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
/// hex edges, then the crossed major roads in amber, clipped to the uncovered hexes (from Country in), in one
/// path per colour. Decoration to VoiceOver: the markers and the zoom control carry the meaning.
///
/// The paths are a ``WorldViewMapDrawing`` built off the main actor for a little more than the screen; a pan
/// frame only moves the last one, and a fresh one is built when the view has drifted, the data or the colours
/// changed (one build at a time, so a long pan never starves it). A level step builds the new level's drawing
/// at once, so the first frame at the new level is already right.
struct WorldViewMapCanvas: View {
    let camera: WorldViewCamera
    let model: WorldViewModel
    /// Read so the map redraws when places, uncovered hexes or the raster arrive.
    let generation: Int

    @Environment(\.colorScheme) private var colorScheme
    /// The drawing on screen (nil until the first lands: the sea alone).
    @State private var drawing: WorldViewMapDrawing?
    /// The drawing being built, or the last one built.
    @State private var request: WorldViewMapDrawing.Key?

    var body: some View {
        let dark = colorScheme == .dark
        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(WorldPalette.rgb(WorldViewInk.sea(dark: dark))))
            guard let drawing else { return }
            Self.draw(drawing, on: camera, in: &context)
        }
        .accessibilityHidden(true)
        .task(id: request) { await build() }
        .onAppear { refresh() }
        .onChange(of: wanted) { refresh() }
    }

    /// The key a drawing of the camera on screen now would have.
    private var wanted: WorldViewMapDrawing.Key {
        WorldViewMapDrawing.key(for: camera, generation: generation, dark: colorScheme == .dark)
    }

    // MARK: Building

    /// Asks for a fresh drawing when none is on its way and the one on screen is stale; a new level's is built
    /// at once.
    private func refresh() {
        let wanted = wanted
        guard let request else { self.request = wanted; return }
        if let drawing, drawing.key.camera.level != wanted.camera.level {
            var facts = model.facts(at: wanted.camera.level)
            self.drawing = WorldViewMapDrawing.build(wanted, facts: &facts)
            model.keepLands(facts.lands, at: wanted.camera.level)
            self.request = wanted
            return
        }
        guard drawing?.key == request, drawing?.isStale(for: wanted) ?? true else { return }
        self.request = wanted
    }

    /// Builds the requested drawing off the main actor, shows it, and looks again (the view may have moved on).
    private func build() async {
        guard let key = request, drawing?.key != key else { return }
        let start = model.facts(at: key.camera.level)
        let built = await Task.detached(priority: .userInitiated) {
            var facts = start
            let made = WorldViewMapDrawing.build(key, facts: &facts)
            return (drawing: made, lands: facts.lands)
        }.value
        guard !Task.isCancelled else { return }
        model.keepLands(built.lands, at: key.camera.level)
        drawing = built.drawing
        refresh()
    }

    // MARK: Drawing

    /// Draws `drawing` where it falls on a screen showing `camera`: the hexes and their edges, the lines, the
    /// roads on the uncovered hexes.
    private static func draw(_ drawing: WorldViewMapDrawing, on camera: WorldViewCamera, in context: inout GraphicsContext) {
        let placement = drawing.placement(on: camera), built = drawing.key.camera
        context.translateBy(x: placement.centre.x, y: placement.centre.y)
        context.scaleBy(x: placement.scale, y: placement.scale)
        context.translateBy(x: -built.size.width / 2, y: -built.size.height / 2)
        // Bounded: one entry per fill colour (four).
        for hexes in drawing.hexes {
            context.fill(hexes.path, with: .color(WorldPalette.rgb(hexes.fill)))
            context.stroke(hexes.path, with: .color(WorldPalette.rgb(hexes.edge)), lineWidth: WorldViewInk.hexEdgeWidth)
        }
        let ink = WorldPalette.rgb(WorldViewInk.line(dark: drawing.key.dark)).opacity(WorldViewInk.lineOpacity)
        let style = { (width: Double) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        context.stroke(drawing.region, with: .color(ink), style: style(WorldViewInk.regionLineWidth))
        context.stroke(drawing.country, with: .color(ink), style: style(WorldViewInk.countryLineWidth))
        guard !drawing.roads.isEmpty else { return }
        let level = built.level
        context.drawLayer { layer in
            layer.clip(to: drawing.uncovered)
            // Bounded: one entry per road kind.
            for road in drawing.roads {
                WorldRoadPainter.stroke(road.path, width: WorldRoadStyle.worldWidth(at: level, kind: road.kind), in: &layer)
            }
        }
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

    /// The state-line and country-line edges among `hexes` at the facts' level (whose land cache grows with
    /// the neighbours it looks up).
    static func segments(_ hexes: [WorldViewVisibleHex],
                         facts: inout WorldViewMapFacts) -> (region: [Edge], country: [Edge]) {
        let level = facts.level, grid = level.hexGrid
        let across = 3.0.squareRoot() * grid.radius
        var region: [Edge] = [], country: [Edge] = []
        // Bounded: the hexes drawn (WorldViewCamera.maxDrawnHexes), three edges each.
        for hex in hexes {
            guard let known = facts.place(of: hex.cell), let here = known else { continue }
            for step in forward {
                let nx = hex.x + across * (Double(step.dq) + Double(step.dr) / 2), ny = hex.y + 1.5 * grid.radius * Double(step.dr)
                let cell = WorldViewCamera.canonical((nx, ny), in: grid)
                let there: AtlasPlaceName?
                if facts.isLand(cell, x: nx, y: ny) {
                    guard let looked = facts.place(of: cell) else { continue }
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
