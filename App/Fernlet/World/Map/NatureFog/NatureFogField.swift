import CoreGraphics
import Foundation
import WorldMapStore

/// The size the fog draws at: a hex's centre-to-corner radius in points, and whether it draws its reduced
/// detail (spec "Zoomed out, and the widget": a hex under 13 pt).
///
/// Positions are "global points": Mercator units times ``pointsPerUnit``, so the same hex sits at the same
/// place in every tile of one scale and pieces snap to one global grid of ``unit``.
nonisolated struct NatureFogScale: Hashable {
    /// Centre to corner, in points.
    let radius: Double
    /// Reduced detail: no tufts or specks, 3-pixel flowers, no boulders, plain ponds; trees stay.
    let reduced: Bool

    /// Below this radius on screen the fog draws its reduced detail.
    static let detailFloor = 13.0
    /// Below this radius the fog isn't drawn at all (zoomed too far out), as the plain fog before it.
    static let minimumRadius = 2.0
    /// Today's zoom: the tile scales step by half octaves from here.
    static let todayRadius = 19.0

    /// The pixel unit `s`: R / 8, at least 1.6 pt in reduced detail.
    var unit: Double { reduced ? max(radius / 8, 1.6) : radius / 8 }
    /// Points per Mercator unit.
    var pointsPerUnit: Double { radius / MercatorHexGrid.radius }
    /// A hex's width, R·√3.
    var hexWidth: Double { radius * 3.0.squareRoot() }

    /// `cell`'s centre in global points.
    func centre(of cell: HexCell) -> CGPoint {
        CGPoint(x: hexWidth * (Double(cell.q) + Double(cell.r) / 2), y: radius * 1.5 * Double(cell.r))
    }

    /// The scale the live map's tiles draw at for a hex `screenRadius` points across on screen: the nearest
    /// half octave from today's zoom (so a tile shows at 0.84–1.19 of its size), with the reduced detail
    /// decided by the size on screen; nil when the fog is too small to draw.
    static func tiles(forScreenRadius screenRadius: Double) -> NatureFogScale? {
        guard screenRadius.isFinite, screenRadius >= minimumRadius, screenRadius < 4_000 else { return nil }
        let step = (2 * log2(screenRadius / todayRadius)).rounded()
        return NatureFogScale(radius: todayRadius * pow(2, step / 2), reduced: screenRadius < detailFloor)
    }
}

/// Which cells are uncovered: the lifted history and the circles drawn clear round homes and kept places.
nonisolated struct NatureFogClearing: Equatable {
    /// Cells the fog has lifted from.
    var lifted: Set<HexCell> = []
    /// Cells drawn clear round homes, a hotel and kept places.
    var uncovered: Set<HexCell> = []

    /// Whether `cell` shows the map.
    func isClear(_ cell: HexCell) -> Bool {
        lifted.contains(cell) || uncovered.contains(cell)
    }
}

/// What a cell is: the uncovered map, or wild ground of one kind.
nonisolated enum NatureCellState: Equatable {
    case clear
    case wild(NatureHexKind)
}

/// One growing piece placed on the map: a sprite, its frame in global points, and its place in the depth sort.
struct NaturePiece {
    let sprite: NatureSprite
    let frame: CGRect
    /// Sorted by y then x (spec "Draw order").
    let sortY: Double
    let sortX: Double
    /// The sway phase group (0, 1, 2) for long grass and flowers; nil for what stays still.
    let swayGroup: Int?
    /// The terrain colours the sprite is painted in (the approved nature fog's unless the land says otherwise).
    var look: TerrainLook = .approved
}

/// A filled block of the ground: a speck, a ripple, a lily pad or a far-off flower, in its hex's look.
struct NatureFogBlock {
    let rect: CGRect
    let paint: NaturePaint
    var look: TerrainLook = .approved
}

/// A terrain mark on the ground (sea waves, sand ripples, scree, lichen, ice cracks, snow, a desert or tundra
/// speck), in a palette role of its hex's look or a fixed colour.
struct NatureFogMark {
    let rect: CGRect
    let ink: NatureInk
    let look: TerrainLook
}

/// A tree that stands, for the leaves it scatters when it lifts.
struct NatureStandingTree: Hashable {
    let anchor: HexCell
    /// The canopy's centre, in global points.
    let canopy: CGPoint

    static func == (lhs: NatureStandingTree, rhs: NatureStandingTree) -> Bool { lhs.anchor == rhs.anchor }
    func hash(into hasher: inout Hasher) { hasher.combine(anchor) }
}

/// Everything one area of fog draws, back to front (spec "Draw order"): ground hexes with their seams, the
/// sea's hexes (no seams), specks and terrain marks, water with its shores, ripples and lilies and the sand line
/// along the coast, then the growing pieces sorted top of screen to bottom. Each land hex keeps its terrain
/// look; with no atlas every look is the approved one and the layout is today's nature fog exactly.
struct NatureFogLayout {
    var hexes: [(centre: CGPoint, paint: NaturePaint, look: TerrainLook)] = []
    /// Water-set hexes (World-Exploration-Spec §1: no seams), in the water look.
    var seas: [(centre: CGPoint, paint: NaturePaint)] = []
    var specks: [NatureFogBlock] = []
    var marks: [NatureFogMark] = []
    var ponds: [CGPoint] = []
    var shores: [(from: CGPoint, to: CGPoint)] = []
    /// The sand line along a sea hex's sides that meet land.
    var coasts: [(from: CGPoint, to: CGPoint)] = []
    var waterMarks: [NatureFogBlock] = []
    var pieces: [NaturePiece] = []
    var trees: [NatureStandingTree] = []
}

/// A tree (or palm, cactus or peak) a hex may stand: its sprite, root and canopy, before the wildness check.
struct NatureTreePlan {
    let anchor: HexCell
    let sprite: NatureSprite
    /// Where the sprite's anchor sits (the snapped hex centre, 3 units down), in global points.
    let root: CGPoint
    /// The canopy's centre and radius, in global points.
    let canopy: CGPoint
    let canopyRadius: Double
    /// The colours it is painted in.
    var look: TerrainLook = .approved
}
