import Foundation
import FernletDomainModel

/// The painter's name for the companion's band, so the twin region below reads the same in the app
/// and in the widget (whose own mirror of the band is `WidgetCompanionState`).
typealias WorldCompanionMood = CompanionState

// The pixel companion: the approved art (design `b1-home-day`'s `pixComp`), the built-in wardrobe in
// pixels (phone test W-02 and W-03, approved 2026-10-25) and the 24 × 24 item frame round the body that
// Creation Studio pieces draw in (W-07, draft 2). Every coordinate the painter takes is the BODY's
// (0…19 × 0…21); the frame adds two columns each side and a row above and below.
//
// The region between the two twin markers is copied into the widget's
// `App/FernletWidgets/WidgetPixelCompanion.swift` word for word, with `WorldCompanionLook` spelled
// `WidgetPixelLook`, every other `WorldCompanion` spelled `WidgetCompanion` and no `nonisolated`
// (the widget target has no default isolation). `WidgetWorldTests` holds the two copies equal, and
// `WorldCompanionWardrobeTests` diffs this painter pixel for pixel against the design session's
// reference painter (`Docs/World-Companion-Reference-Grids.txt`). Since Refinements group 17
// (2026-10-26) each face and the highlight fit the body's shape (`WorldCompanionFaceLayout`, pinned by
// `WorldCompanionBodyShapeTests`); the widget's feeling faces use the same layout. Each cell also records the
// piece that painted it (`WorldCompanionPiece`), for the one-colour rule (phone test W-11,
// `WorldCompanionGrid.takesOneColour`) and where a motif goes beside a worn piece (Refinements group 16,
// `WorldCompanionMotifPlacement`), both pinned by `WorldCompanionOneColourTests` against
// `Docs/World-Companion-OneColour-Grids.txt`.

// MARK: - Twin: begin

/// One frame of the companion: the 24 × 24 item frame round the 20 × 22 body, each cell an opaque
/// colour or clear (nil), and the piece that painted it. Paint at body coordinates; the frame keeps the
/// body at (2, 1). Read in frame coordinates, it says which cells take the one colour
/// (``takesOneColour(frameX:y:)``) and whether a picture beside it touches it
/// (``touches(_:frameX:y:wornOnly:)``).
nonisolated struct WorldCompanionGrid: Equatable, Sendable {
    /// The body's columns: every built-in piece stays inside them.
    static let width = 20
    /// The body's rows.
    static let height = 22
    /// The item frame's columns: two more on each side, so items can reach past the body.
    static let frameWidth = 24
    /// The item frame's rows: one more above and below.
    static let frameHeight = 24
    /// Where the body's left column sits in the frame.
    static let frameX = 2
    /// Where the body's top row sits in the frame.
    static let frameY = 1
    private(set) var cells = [UInt32?](repeating: nil, count: frameWidth * frameHeight)
    /// Which piece painted each cell (nil where clear): the one-colour rule and a motif's placement read it.
    private(set) var pieces = [WorldCompanionPiece?](repeating: nil, count: frameWidth * frameHeight)

    /// A cell's left, right, upper and lower neighbours, as (dx, dy).
    static let sides = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    /// The colour at body coordinates (x, y), or nil when clear or outside the frame.
    func color(x: Int, y: Int) -> UInt32? {
        frameColor(x: x + Self.frameX, y: y + Self.frameY)
    }

    /// The colour at frame coordinates (x, y), or nil when clear or out of range.
    func frameColor(x: Int, y: Int) -> UInt32? {
        guard x >= 0, x < Self.frameWidth, y >= 0, y < Self.frameHeight else { return nil }
        return cells[y * Self.frameWidth + x]
    }

    /// The piece that painted the cell at frame coordinates (x, y), or nil when clear or out of range.
    func piece(frameX x: Int, y: Int) -> WorldCompanionPiece? {
        guard x >= 0, x < Self.frameWidth, y >= 0, y < Self.frameHeight else { return nil }
        return pieces[y * Self.frameWidth + x]
    }

    /// Whether the cell at frame coordinates (x, y) is part of the face (eyes, mouth, blush, the tear,
    /// the glasses).
    func isFace(frameX x: Int, y: Int) -> Bool {
        piece(frameX: x, y: y)?.isFace ?? false
    }

    /// Paints one pixel at body coordinates, painted by `piece`; anything outside the frame is ignored.
    /// A later paint over it takes the cell, piece and all.
    mutating func put(_ x: Int, _ y: Int, _ hex: UInt32, as piece: WorldCompanionPiece) {
        let fx = x + Self.frameX, fy = y + Self.frameY
        guard fx >= 0, fx < Self.frameWidth, fy >= 0, fy < Self.frameHeight else { return }
        cells[fy * Self.frameWidth + fx] = hex
        pieces[fy * Self.frameWidth + fx] = piece
    }

    // MARK: The one-colour rule (phone test W-11, approved 2026-10-26)

    /// Whether the cell at frame coordinates (x, y) takes the one colour on the Lock Screen and the
    /// tinted and clear Home Screens. It doesn't when it is clear (holes stay open), cut out (the face,
    /// the glasses with the eyes behind them, the flower's centre), or a cell of a lower-ranked piece
    /// beside (left, right, above or below) a higher-ranked one: a 1-pixel cut line wherever a piece
    /// meets the body or a piece worn under it, which stays filled when any of its 8 neighbours is cut
    /// out, so a line never runs into the face.
    func takesOneColour(frameX x: Int, y: Int) -> Bool {
        guard let cell = piece(frameX: x, y: y), !cell.isCutOut else { return false }
        guard let rank = cell.rank, !isNearCutOut(frameX: x, y: y) else { return true }
        for (dx, dy) in Self.sides {
            if let other = piece(frameX: x + dx, y: y + dy)?.rank, other > rank { return false }
        }
        return true
    }

    /// Whether the cell at frame coordinates (x, y), or one of its 8 neighbours, is cut out.
    private func isNearCutOut(frameX x: Int, y: Int) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 where piece(frameX: x + dx, y: y + dy)?.isCutOut == true {
                return true
            }
        }
        return false
    }

    // MARK: Touching (Refinements group 16, approved 2026-10-26)

    /// Whether the cell at frame coordinates (x, y), or its left, right, upper or lower neighbour, is
    /// painted; with `wornOnly`, painted by a worn piece (``WorldCompanionPiece/isWorn``).
    func touchesCell(frameX x: Int, y: Int, wornOnly: Bool) -> Bool {
        let counts = { (cell: WorldCompanionPiece?) in cell.map { !wornOnly || $0.isWorn } ?? false }
        guard !counts(piece(frameX: x, y: y)) else { return true }
        return Self.sides.contains { counts(piece(frameX: x + $0.0, y: y + $0.1)) }
    }

    /// Whether a picture's drawn cells (`rows`, `.` clear), its top-left at frame coordinates (x, y),
    /// touch the companion: lie on a painted cell, or side by side or above or below one (corner to
    /// corner doesn't count); with `wornOnly`, a cell of a worn piece.
    func touches(_ rows: [String], frameX x: Int, y: Int, wornOnly: Bool) -> Bool {
        for (j, row) in rows.enumerated() {
            for (i, key) in row.enumerated() where key != "." {
                if touchesCell(frameX: x + i, y: y + j, wornOnly: wornOnly) { return true }
            }
        }
        return false
    }
}

/// Which piece painted a frame cell (phone test W-11): the one-colour rule cuts out the face and a
/// 1-pixel line where a piece meets one ranked under it, and a motif beside the head steps aside for
/// a worn piece (Refinements group 16).
nonisolated enum WorldCompanionPiece: Equatable, Sendable {
    /// The body, its outline, highlight and blanket.
    case body
    /// The sprout's stem and leaves.
    case sprout
    /// The flower's stem, leaf and petals.
    case flower
    /// The flower's sun centre.
    case flowerCentre
    /// An eye (open, half-lidded or closed), or a brow.
    case eye
    /// The mouth.
    case mouth
    /// A cheek's blush.
    case blush
    /// A sad face's tear.
    case tear
    /// The glasses' frames.
    case glasses
    /// The scarf.
    case scarf
    /// The sleep cap, brim and pompom.
    case cap
    /// The Creation Studio piece at this index of the look's pieces, in paint order.
    case studio(Int)
    /// The side item.
    case side
    /// The hair (G8): worn on the head, ranked between the body and the scarf.
    case hair

    /// Part of the face: eyes, mouth, blush, the tear and the glasses.
    var isFace: Bool {
        switch self {
        case .eye, .mouth, .blush, .tear, .glasses: true
        case .body, .sprout, .flower, .flowerCentre, .scarf, .cap, .studio, .side, .hair: false
        }
    }

    /// Cut out of the one colour: the face (the glasses with it) and the flower's centre.
    var isCutOut: Bool { isFace || self == .flowerCentre }

    /// Its place from the bottom in the one-colour rule: the body, sprout and flower 0, the hair 1, the
    /// scarf 2, the cap 3, Studio piece *i* 4 + *i*, the side item 9; nil for a cut-out, which takes no
    /// line.
    var rank: Int? {
        switch self {
        case .body, .sprout, .flower: 0
        case .hair: 1
        case .scarf: 2
        case .cap: 3
        case .studio(let index): 4 + index
        case .side: 9
        case .flowerCentre, .eye, .mouth, .blush, .tear, .glasses: nil
        }
    }

    /// Worn: anything but the bare body and its face. The sprout, the flower and the glasses count.
    var isWorn: Bool {
        switch self {
        case .body, .eye, .mouth, .blush, .tear: false
        case .sprout, .flower, .flowerCentre, .glasses, .scarf, .cap, .studio, .side, .hair: true
        }
    }
}

/// Where a small picture beside the companion's head goes (Refinements group 16, approved
/// 2026-10-26): top right, 3 pixels past the frame, as before; at the top-left corner, mirrored, when
/// a cell of it would touch a worn piece there; or, when the left corner touches too, at the top right
/// behind the companion.
nonisolated struct WorldCompanionMotifPlacement: Equatable, Sendable {
    /// The three spots.
    nonisolated enum Spot: Equatable, Sendable {
        /// Top right, over the companion: the spot it always had.
        case topRight
        /// Top left, mirrored so its tail points down-right at the head.
        case topLeft
        /// Top right, behind the companion: its painted cells hide the picture's.
        case behind
    }

    /// Its spot.
    let spot: Spot
    /// Its left column, at frame coordinates (negative left of the frame).
    let x: Int
    /// Its rows as drawn: mirrored at the left; behind, with each cell a painted one hides cleared.
    let rows: [String]

    /// How far past the frame's right edge the top-right spot reaches.
    static let rightOverhang = 3
    /// The top-left spot's columns, tried in turn: from 3 pixels left of the frame outward.
    static let leftColumns = [-3, -4, -5, -6]

    /// Places `rows` (`.` clear) beside the head of the companion painted in `grid`. A picture that
    /// isn't `movable` stays top right. It moves only when a cell would lie on, or side by side or above
    /// or below, a cell of a worn piece (the bare body never counts, so bare shapes keep the spot): then
    /// to the first left column where no cell touches any painted cell (the tail's tip may meet the
    /// companion corner to corner), else behind. Behind, a painted cell hides the cell over it, and in
    /// `oneColour` so does one side by side or above or below it: a 1-pixel cut line.
    init(rows: [String], on grid: WorldCompanionGrid, movable: Bool, oneColour: Bool) {
        let width = rows.first?.count ?? 0
        let right = WorldCompanionGrid.frameWidth + Self.rightOverhang - width
        guard movable, grid.touches(rows, frameX: right, y: 0, wornOnly: true) else {
            (spot, x, self.rows) = (.topRight, right, rows)
            return
        }
        let mirrored = rows.map { String($0.reversed()) }
        if let left = Self.leftColumns.first(where: { !grid.touches(mirrored, frameX: $0, y: 0, wornOnly: false) }) {
            (spot, x, self.rows) = (.topLeft, left, mirrored)
            return
        }
        let hidden = rows.enumerated().map { j, row in
            String(row.enumerated().map { i, key -> Character in
                let covered = oneColour ? grid.touchesCell(frameX: right + i, y: j, wornOnly: false)
                    : grid.frameColor(x: right + i, y: j) != nil
                return covered ? "." : key
            })
        }
        (spot, x, self.rows) = (.behind, right, hidden)
    }
}

/// The companion's body shapes (W-02): the approved circle, and three more.
nonisolated enum WorldCompanionShape: Equatable, Sendable {
    /// The approved round body; the only one that breathes and slumps.
    case circle
    /// Squarer, with soft corners: a superellipse.
    case soft
    /// Narrow on top, wide at the base.
    case pear
    /// Low and spread out, with a flat bottom.
    case puddle

    /// How many rows the face sits below the approved rows (group 17): Pear's whole face a row lower,
    /// where it is wider; Puddle's a row higher, clear of its flat bottom; Circle and Soft as approved.
    var faceRowOffset: Int {
        switch self {
        case .circle, .soft: 0
        case .pear: 1
        case .puddle: -1
        }
    }

    /// The highlight's centre, as a column and a row offset from the body's centre (group 17): Circle
    /// and Soft as approved, Pear lower and Puddle lower and left, where each shape is roomy.
    var highlightCentre: (x: Double, dy: Double) {
        switch self {
        case .circle, .soft: (7, -3.5)
        case .pear: (7, -2.2)
        case .puddle: (6.5, -2.1)
        }
    }

    /// Whether the highlight keeps one pixel off the outline: true for the moved centres (Pear,
    /// Puddle), so it never reads as a hole in Pear's narrow top or notches Puddle's edge. Circle and
    /// Soft keep the approved highlight pixel for pixel.
    var highlightKeepsClear: Bool { self == .pear || self == .puddle }
}

/// A face the twin lays out (group 17): the band's faces the painter draws (closed eyes are
/// `resting`, or `sick`'s own), and the four the Home Screen widgets draw over them (happy, sad,
/// hungry, thirsty). The map's painter only ever draws the band's; the widget's four are here so
/// one rule places every face.
nonisolated enum WorldCompanionFace: Equatable, Sendable, CaseIterable {
    /// Open eyes, a smile and a blush.
    case thriving
    /// Open eyes, a flat mouth.
    case okay
    /// Half-lidded eyes, a low mouth.
    case tired
    /// Closed eyes, a flat mouth: resting, winding down or asleep.
    case resting
    /// Closed eyes and the sick day's wavy mouth, one row up, clear of the blanket.
    case sick
    /// The widget's happy face: eyes bowed up, a wide smile, a blush.
    case happy
    /// The widget's sad face: eyes, brows lifted at the inner ends, a soft frown and a tear.
    case sad
    /// The widget's hungry face: eyes raised, an open mouth.
    case hungry
    /// The widget's thirsty face: eyes raised, a small open mouth.
    case thirsty

    /// The band's face the painter draws for `state` in `pose`.
    static func state(_ state: WorldCompanionMood, pose: WorldCompanionPose) -> WorldCompanionFace {
        if WorldCompanionPainter.closesEyes(state: state, pose: pose) { return state == .sick ? .sick : .resting }
        switch state {
        case .thriving: return .thriving
        case .okay: return .okay
        case .tired: return .tired
        case .resting: return .resting
        case .sick: return .sick
        }
    }

    /// Its ink cells, cheeks and tear aside, with the eyes on row `eye` and the mouth on row `mouth`.
    /// `lowered` leaves off the touches that need a row above the eyes: sad's brows, and hungry and
    /// thirsty's raised eyes, drawn level instead.
    func cells(eye: Int, mouth: Int, lowered: Bool) -> [(Int, Int)] {
        let columns = [7, 12]
        switch self {
        case .thriving, .okay, .tired, .resting, .sick:
            let closed = self == .resting || self == .sick
            let eyes = closed ? [(6, eye + 1), (7, eye + 1), (12, eye + 1), (13, eye + 1)]
                : columns.flatMap { x in [(x, eye), (x, eye + 1)] }
            let row = self == .sick ? mouth - 1 : mouth
            return eyes + bandMouth.map { ($0.0, row + $0.1) }
        case .happy:
            let eyes = columns.flatMap { x in [(x - 1, eye + 1), (x, eye), (x + 1, eye + 1)] }
            return eyes + [(7, mouth), (8, mouth + 1), (9, mouth + 1), (10, mouth + 1), (11, mouth + 1), (12, mouth)]
        case .sad:
            let eyes = columns.flatMap { x in [(x, eye), (x, eye + 1)] }
            let brows = lowered ? [] : [(6, eye - 1), (7, eye - 2), (13, eye - 1), (12, eye - 2)]
            return eyes + brows + [(8, mouth + 1), (9, mouth), (10, mouth), (11, mouth + 1)]
        case .hungry, .thirsty:
            let eyes = columns.flatMap { x in lowered ? [(x, eye), (x, eye + 1)] : [(x, eye - 1), (x, eye)] }
            let open = self == .hungry ? [(9, mouth), (10, mouth), (9, mouth + 1), (10, mouth + 1)] : [(9, mouth), (10, mouth)]
            return eyes + open
        }
    }

    /// A band's face's mouth, as the painter draws it (the widget's four draw their own, so none here).
    private var bandMouth: [(Int, Int)] {
        switch self {
        case .thriving: WorldCompanionPainter.mouth(for: .thriving)
        case .okay: WorldCompanionPainter.mouth(for: .okay)
        case .tired: WorldCompanionPainter.mouth(for: .tired)
        case .resting: WorldCompanionPainter.mouth(for: .resting)
        case .sick: WorldCompanionPainter.mouth(for: .sick)
        case .happy, .sad, .hungry, .thirsty: []
        }
    }
}

/// Where a face goes on a body (group 17, approved 2026-10-26). The eyes sit on row round(cy − 1)
/// and the mouth on round(cy + 2), moved by the shape's ``WorldCompanionShape/faceRowOffset``. If
/// the face's cells are not all *clear* there (``WorldCompanionBody/isClear(_:_:)``: one bare body
/// pixel between them and the outline every way round), it is `lowered` (in practice only on
/// Puddle). The cheeks take the first clear pair of (5, 14) on the row above the mouth, (6, 13)
/// there, (6, 13) on the mouth row, (5, 14) on the mouth row, or none, never on one of the face's
/// own cells; the tear takes column 5 when both its rows are clear and free there, else 6. A
/// feeling on a sick day draws its mouth a row above ``mouth``, clear of the blanket, as built.
nonisolated struct WorldCompanionFaceLayout: Equatable, Sendable {
    /// The cheeks' two columns and their row, as an offset from the mouth's row.
    nonisolated struct Cheeks: Equatable, Sendable {
        /// The left cheek's column.
        let left: Int
        /// The right cheek's column.
        let right: Int
        /// The cheeks' row less the mouth's.
        let rowOffset: Int
    }

    /// The eyes' row (raised eyes sit a row above it).
    let eye: Int
    /// The mouth's row (a sick day's wavy mouth sits a row above it).
    let mouth: Int
    /// Whether the touches above the eyes are left off (``WorldCompanionFace/cells(eye:mouth:lowered:)``).
    let lowered: Bool
    /// The cheeks, or nil when no pair fits.
    let cheeks: Cheeks?
    /// The tear's column, on rows eye + 2 and eye + 3.
    let tear: Int

    /// The layout of `face` on `body`.
    init(body: WorldCompanionBody, face: WorldCompanionFace) {
        let offset = body.shape.faceRowOffset
        let eye = Int((body.cy - 1).rounded()) + offset, mouth = Int((body.cy + 2).rounded()) + offset
        let lowered = !face.cells(eye: eye, mouth: mouth, lowered: false).allSatisfy { body.isClear($0.0, $0.1) }
        let taken = face.cells(eye: eye, mouth: mouth, lowered: lowered)
        let free = { (x: Int, y: Int) in body.isClear(x, y) && !taken.contains { $0 == (x, y) } }
        let pairs = [Cheeks(left: 5, right: 14, rowOffset: -1), Cheeks(left: 6, right: 13, rowOffset: -1),
                     Cheeks(left: 6, right: 13, rowOffset: 0), Cheeks(left: 5, right: 14, rowOffset: 0)]
        self.eye = eye
        self.mouth = mouth
        self.lowered = lowered
        cheeks = pairs.first { free($0.left, mouth + $0.rowOffset) && free($0.right, mouth + $0.rowOffset) }
        tear = free(5, eye + 2) && free(5, eye + 3) ? 5 : 6
    }

    /// `face`'s ink cells at this layout, cheeks and tear aside.
    func cells(for face: WorldCompanionFace) -> [(Int, Int)] {
        face.cells(eye: eye, mouth: mouth, lowered: lowered)
    }
}

/// What sits on the head.
nonisolated enum WorldCompanionTopper: Equatable, Sendable {
    /// Nothing.
    case none
    /// The sprout: a stem and two leaves.
    case sprout
    /// The flower: a 3 × 3 bloom on a stem with a leaf.
    case flower
    /// The round glasses (on the face; off while the eyes are closed).
    case glasses
}

/// The built-in side item, held against the body's right edge.
nonisolated enum WorldCompanionSide: Equatable, Sendable {
    /// Nothing held.
    case none
    /// The water bottle.
    case bottle
    /// The mug, steaming while the companion is awake.
    case mug
    /// The book.
    case book
    /// The dumbbell.
    case dumbbell
}

/// One drawn piece in its place on the frame (a Creation Studio item, already sized to its box):
/// the top-left cell at body coordinates and its colours, row by row.
nonisolated struct WorldCompanionItemArt: Equatable, Sendable {
    /// The left column, at body coordinates.
    var x: Int
    /// The top row, at body coordinates.
    var y: Int
    /// Its columns.
    var width: Int
    /// Its rows.
    var height: Int
    /// Row-major colours (`width × height`); nil is clear.
    var cells: [UInt32?]
    /// Whether it sits on the head (a hat), so the sprout and the flower step aside.
    var coversHead: Bool

    /// The colour of its cell (x, y), or nil when clear or out of range.
    func color(x: Int, y: Int) -> UInt32? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let index = y * width + x
        guard index < cells.count else { return nil }
        return cells[index]
    }
}

/// What the companion wears and how it is coloured, as plain values the painter reads.
nonisolated struct WorldCompanionLook: Equatable, Sendable {
    /// The body's shape.
    var shape: WorldCompanionShape
    /// The body's colour.
    var body: UInt32
    /// What sits on the head.
    var topper: WorldCompanionTopper
    /// The topper's colour; nil when the slot is left on Fern (the sprout's fern, the flower's soft
    /// rose, the glasses' ink).
    var topperColor: UInt32?
    /// The scarf's colour, when it wears the scarf.
    var scarf: UInt32?
    /// The sleep cap's colour, when it wears the cap (the clothing slot, like the scarf).
    var cap: UInt32?
    /// The built-in side item.
    var side: WorldCompanionSide
    /// The side item's colour.
    var sideColor: UInt32
    /// Creation Studio pieces, in paint order (outfit, held item, face, hat).
    var items: [WorldCompanionItemArt]
    /// The hair (G8); none paints nothing.
    var hair: WorldCompanionHair = .none
    /// The hair's colour.
    var hairColor: UInt32 = WorldCompanionLook.hairBrown
    /// The eyes (G8); round is the original face.
    var eyes: WorldCompanionEyes = .round
    /// The eyes' colour: shown by the large eyes only, the others stay ink.
    var eyeColor: UInt32 = WorldCompanionPainter.ink
    /// The body's pattern (G8); plain paints nothing.
    var pattern: WorldCompanionPattern = .plain

    /// The design's leaf and the app's fern, which the sprout keeps when its slot is left on Fern.
    static let leaf: UInt32 = 0x72A364
    /// The night's neutral body colour (`Color.softTaupe` in light mode), worn asleep.
    static let nightBody: UInt32 = 0xB8A892
    /// The design's scarf red, when the scarf follows the state.
    static let scarfRed: UInt32 = 0xD9532F
    /// The sleep cap's night blue, when the cap follows the state.
    static let capBlue: UInt32 = 0x6E86B0
    /// The side items' bark, when the side item follows the state.
    static let bark: UInt32 = 0x3A2414
    /// The hair's colour until the person picks one: a warm brown.
    static let hairBrown: UInt32 = 0x6B4A2E

    /// A look built from plain values.
    init(body: UInt32, shape: WorldCompanionShape = .circle, topper: WorldCompanionTopper = .sprout,
         topperColor: UInt32? = nil, scarf: UInt32? = nil, cap: UInt32? = nil, side: WorldCompanionSide = .none,
         sideColor: UInt32 = WorldCompanionLook.bark, items: [WorldCompanionItemArt] = []) {
        self.shape = shape
        self.body = body
        self.topper = topper
        self.topperColor = topperColor
        self.scarf = scarf
        self.cap = cap
        self.side = side
        self.sideColor = sideColor
        self.items = items
    }

    /// The body colour of each band, as `CompanionState.color` resolves in light mode.
    static func stateHex(_ state: WorldCompanionMood) -> UInt32 {
        switch state {
        case .thriving: 0x5E844D
        case .okay: 0xD2973B
        case .tired: 0xB67073
        case .resting: 0x5C6B78
        case .sick: 0xB9543D
        }
    }

    /// `#RRGGBB` as a number; nil for nil or anything malformed.
    static func value(_ hex: String?) -> UInt32? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }
}

/// The companion's pose for one frame.
nonisolated struct WorldCompanionPose: Equatable, Sendable {
    /// The in-breath frame: a touch taller and wider, as Home's breathing scale (the circle only).
    var breathIn = false
    /// The pet-cooldown "settled" slump: happy-arc eyes and a blush (closed lids on a low-energy day).
    var settled = false
    /// Asleep at night: closed eyes, whatever the band; the mug stops steaming.
    var asleep = false
    /// Winding down (`b1-home-night`): the map's night, or the companion's own bedtime before it falls
    /// asleep. The sleepy face (closed eyes, the resting mouth, no blush) in the band's own colour;
    /// asleep adds the night's body colour.
    var drowsy = false
}

/// The body for one frame, with its colours: the shape's centre and radii (the circle grows on the
/// in-breath and slumps when settled), a resting day sitting it lower, and the outline darker with
/// Increase Contrast.
nonisolated struct WorldCompanionBody: Sendable {
    let shape: WorldCompanionShape
    let cx: Double
    let cy: Double
    let rx: Double
    let ry: Double
    let base: UInt32
    let dark: UInt32
    let light: UInt32
    let low: UInt32

    init(state: WorldCompanionMood, shape: WorldCompanionShape, color: UInt32, pose: WorldCompanionPose,
         increasedContrast: Bool) {
        let sink = state == .resting ? 0.6 : 0
        self.shape = shape
        switch shape {
        case .soft: (cx, cy, rx, ry) = (10, 13.4 + sink, 7.3, 6.7)
        case .pear: (cx, cy, rx, ry) = (10, 13.2 + sink, 8.2, 6.9)
        case .puddle: (cx, cy, rx, ry) = (10, 15.3 + sink * 0.5, 8.7, 5.0)
        case .circle where pose.settled: (cx, cy, rx, ry) = (10, 13.7 + sink, 7.9, 6.5)
        case .circle:
            (cx, cy, rx, ry) = (10, (pose.breathIn ? 12.8 : 13.2) + sink, pose.breathIn ? 7.6 : 7.4, pose.breathIn ? 7.3 : 6.9)
        }
        base = color
        dark = WorldCompanionPainter.mix(color, WorldCompanionPainter.shade, increasedContrast ? 0.75 : 0.55)
        light = WorldCompanionPainter.mix(color, 0xFFFFFF, 0.38)
        low = WorldCompanionPainter.mix(color, WorldCompanionPainter.shade, 0.18)
    }

    /// The head's top row, where the sprout grows and the cap sits.
    var top: Int { Int((cy - ry).rounded(.up)) }

    /// Whether pixel (px, py)'s centre lies inside the shape.
    func contains(_ px: Int, _ py: Int) -> Bool {
        let dy = (Double(py) + 0.5 - cy) / ry
        switch shape {
        case .soft:
            let dx = (Double(px) + 0.5 - cx) / rx
            return pow(abs(dx), 2.6) + pow(abs(dy), 2.6) <= 1
        case .pear:
            guard abs(dy) <= 1 else { return false }
            let dx = (Double(px) + 0.5 - cx) / (4.5 + 4.0 * ((dy + 1) / 2))
            return dx * dx + dy * dy <= 1
        case .puddle where dy > 0:
            let dx = (Double(px) + 0.5 - cx) / rx
            return pow(abs(dx), 4) + pow(abs(dy), 4) <= 1
        case .circle, .puddle:
            let dx = (Double(px) + 0.5 - cx) / rx
            return dx * dx + dy * dy <= 1
        }
    }

    /// Whether (px, py) is an outline cell: inside the shape, with a side or top/bottom neighbour
    /// outside it.
    func isOutline(_ px: Int, _ py: Int) -> Bool {
        contains(px, py) && (!contains(px - 1, py) || !contains(px + 1, py) || !contains(px, py - 1) || !contains(px, py + 1))
    }

    /// Whether (px, py) is *clear* (group 17): it and its 8 neighbours are all inside the shape and
    /// none is an outline cell, so one bare body pixel lies between it and the outline every way round.
    func isClear(_ px: Int, _ py: Int) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 where !contains(px + dx, py + dy) || isOutline(px + dx, py + dy) {
                return false
            }
        }
        return true
    }

    /// Whether (px, py) takes the highlight: within radius² 2.3 of the shape's
    /// ``WorldCompanionShape/highlightCentre``, and, on a shape whose highlight keeps clear, not
    /// beside an outline cell (left, right, above or below).
    func inHighlight(_ px: Int, _ py: Int) -> Bool {
        let centre = shape.highlightCentre
        let hx = Double(px) - centre.x, hy = Double(py) - (cy + centre.dy)
        guard hx * hx + hy * hy <= 2.3 else { return false }
        guard shape.highlightKeepsClear else { return true }
        return !(isOutline(px - 1, py) || isOutline(px + 1, py) || isOutline(px, py - 1) || isOutline(px, py + 1))
    }

    /// The body's own colour at (px, py), or nil outside it: the outline, the highlight, the lower
    /// shade, the body colour, and on a sick day the blanket over the lower body. The painter fills
    /// the body with it, and the widget's feeling faces erase a face back to it.
    func pixelColor(_ px: Int, _ py: Int, sick: Bool) -> UInt32? {
        guard contains(px, py) else { return nil }
        let edge = isOutline(px, py)
        if sick && !edge && Double(py) >= (cy + 1.5).rounded() { return px % 3 == 0 ? 0xD9A57E : 0xF3E6CB }
        if edge { return dark }
        if inHighlight(px, py) { return light }
        return Double(py) >= cy + ry - 2.2 ? low : base
    }
}

/// Paints the companion as the approved pixel art: the body with its outline, highlight and lower
/// shade, the sick day's blanket, the band's face in ink (round eyes, half-lidded when tired, closed
/// when resting, sick, winding down or asleep; the band's mouth; a blush on a thriving day), the
/// built-in wardrobe and the Creation Studio pieces.
nonisolated enum WorldCompanionPainter {
    static let ink: UInt32 = 0x2A1A10
    static let blush: UInt32 = 0xE8A3A0
    /// What the darker tones (outline, stem, lower body) mix toward.
    static let shade: UInt32 = 0x1E1008
    /// The cap's brim and pompom, the bottle's cap and the book's pages.
    static let cream: UInt32 = 0xF3E6CB
    /// The flower's centre.
    static let sun: UInt32 = 0xEBB551
    /// The rose the flower's petals soften from when its slot is left on Fern.
    static let rose: UInt32 = 0xB67073

    /// The whole frame.
    static func paint(state: WorldCompanionMood, look: WorldCompanionLook, pose: WorldCompanionPose,
                      increasedContrast: Bool = false) -> WorldCompanionGrid {
        var grid = WorldCompanionGrid()
        let body = WorldCompanionBody(state: state, shape: look.shape, color: look.body, pose: pose,
                                      increasedContrast: increasedContrast)
        paintBody(&grid, body: body, sick: state == .sick)
        let layout = WorldCompanionFaceLayout(body: body, face: .state(state, pose: pose))
        paintPattern(&grid, body: body, layout: layout, pattern: look.pattern, sick: state == .sick)
        // The cap and a drawn hat cover the head, so the hair, the sprout and the flower step aside.
        if look.cap == nil && !look.items.contains(where: \.coversHead) {
            paintHair(&grid, body: body, hair: look.hair, color: look.hairColor)
            let top = body.top - look.hair.lift
            if look.topper == .sprout { paintSprout(&grid, top: top, leaf: look.topperColor) }
            if look.topper == .flower { paintFlower(&grid, top: top, petal: look.topperColor) }
        }
        paintFace(&grid, body: body, layout: layout, state: state, pose: pose, eyes: look.eyes, eyeColor: look.eyeColor)
        if look.topper == .glasses && !closesEyes(state: state, pose: pose) {
            paintGlasses(&grid, eyeRow: layout.eye, color: glassesColor(look.topperColor), eyes: look.eyes)
        }
        if let scarf = look.scarf { paintScarf(&grid, body: body, color: scarf) }
        if let cap = look.cap { paintCap(&grid, body: body, color: cap) }
        for (index, item) in look.items.enumerated() { paintItem(&grid, item, as: .studio(index)) }
        if look.side != .none { paintSide(&grid, body: body, item: look.side, color: look.sideColor, asleep: pose.asleep) }
        return grid
    }

    /// Whether the eyes are closed lines: resting, sick, winding down or asleep (and settled on a
    /// low-energy day).
    static func closesEyes(state: WorldCompanionMood, pose: WorldCompanionPose) -> Bool {
        pose.asleep || pose.drowsy || state == .resting || state == .sick
    }

    /// Fills the shape with its outline, highlight, lower shade and (when sick) the blanket
    /// (``WorldCompanionBody/pixelColor(_:_:sick:)``).
    private static func paintBody(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, sick: Bool) {
        for py in 0..<WorldCompanionGrid.height {
            for px in 0..<WorldCompanionGrid.width {
                guard let hex = body.pixelColor(px, py, sick: sick) else { continue }
                grid.put(px, py, hex, as: .body)
            }
        }
    }

    /// The sprout: a darker stem and two leaves, in fern unless the person picked another colour.
    private static func paintSprout(_ grid: inout WorldCompanionGrid, top: Int, leaf: UInt32?) {
        let leafColor = leaf ?? WorldCompanionLook.leaf
        let stem = mix(leafColor, shade, 0.3)
        grid.put(10, top - 1, stem, as: .sprout)
        grid.put(10, top - 2, stem, as: .sprout)
        for (x, y) in [(11, top - 3), (12, top - 3), (12, top - 4), (9, top - 3), (8, top - 3)] { grid.put(x, y, leafColor, as: .sprout) }
    }

    /// The flower: a fern stem and leaf where the sprout grows, petals in the accessory colour (a soft
    /// rose when the slot is left on Fern) with darker corners, and a sun centre.
    private static func paintFlower(_ grid: inout WorldCompanionGrid, top: Int, petal: UInt32?) {
        let petals = petal ?? mix(rose, 0xFFFFFF, 0.3)
        let corners = mix(petals, shade, 0.25), stem = mix(WorldCompanionLook.leaf, shade, 0.3)
        grid.put(10, top - 1, stem, as: .flower)
        grid.put(10, top - 2, stem, as: .flower)
        grid.put(11, top - 2, WorldCompanionLook.leaf, as: .flower)
        grid.put(12, top - 3, WorldCompanionLook.leaf, as: .flower)
        for (x, y) in [(10, top - 5), (9, top - 4), (11, top - 4), (10, top - 3)] { grid.put(x, y, petals, as: .flower) }
        for (x, y) in [(9, top - 5), (11, top - 5), (9, top - 3), (11, top - 3)] { grid.put(x, y, corners, as: .flower) }
        grid.put(10, top - 4, sun, as: .flowerCentre)
    }

    /// Eyes, mouth and blush, by the band (the design's table) or the settled pose, on the rows and
    /// cheeks the body's ``WorldCompanionFaceLayout`` gives the band's face.
    private static func paintFace(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, layout: WorldCompanionFaceLayout,
                                  state: WorldCompanionMood, pose: WorldCompanionPose,
                                  eyes: WorldCompanionEyes = .round, eyeColor: UInt32 = ink) {
        let eyeRow = layout.eye, mouthRow = layout.mouth
        let closed = closesEyes(state: state, pose: pose)
        if pose.settled {
            // Petted (owner, 2026-11-15): the round eyes keep today's happy arcs; every other style keeps
            // its own eyes, under the same smile and blush.
            guard eyes != .round, !closed, state != .tired else {
                paintSettledFace(&grid, layout: layout, closed: closed || state == .tired, eyes: eyes)
                return
            }
            paintEyes(&grid, body: body, eyeRow: eyeRow, eyes: eyes, color: eyeColor, tired: false)
            paintSettledMouth(&grid, layout: layout)
            return
        }
        if closed {
            paintClosedEyes(&grid, eyeRow: eyeRow, eyes: eyes)
        } else {
            paintEyes(&grid, body: body, eyeRow: eyeRow, eyes: eyes, color: eyeColor, tired: state == .tired)
        }
        let row = state == .sick ? mouthRow - 1 : mouthRow
        // Winding down (`b1-home-night`) draws the sleepy face whatever the band: the resting mouth, no
        // blush. A sick day keeps its own face.
        let face = pose.drowsy && state != .sick ? WorldCompanionMood.resting : state
        for (x, dy) in mouth(for: face) { grid.put(x, row + dy, ink, as: .mouth) }
        if face == .thriving { paintCheeks(&grid, layout: layout) }
    }

    /// The blush, where the layout found room for it (none when no pair fits).
    private static func paintCheeks(_ grid: inout WorldCompanionGrid, layout: WorldCompanionFaceLayout) {
        guard let cheeks = layout.cheeks else { return }
        grid.put(cheeks.left, layout.mouth + cheeks.rowOffset, blush, as: .blush)
        grid.put(cheeks.right, layout.mouth + cheeks.rowOffset, blush, as: .blush)
    }

    /// The band's mouth, as (column, row offset) pixels.
    static func mouth(for state: WorldCompanionMood) -> [(Int, Int)] {
        switch state {
        case .thriving: [(8, 0), (9, 1), (10, 1), (11, 0)]
        case .okay, .resting: [(9, 0), (10, 0)]
        case .tired: [(9, 1), (10, 1)]
        case .sick: [(8, 0), (9, -1), (10, 0), (11, -1)]
        }
    }

    /// The settled pose: happy-arc eyes (closed lids on a low-energy day), a wide smile and a blush.
    private static func paintSettledFace(_ grid: inout WorldCompanionGrid, layout: WorldCompanionFaceLayout, closed: Bool,
                                         eyes: WorldCompanionEyes = .round) {
        let eyeRow = layout.eye
        for x in [7, 12] {
            grid.put(x - 1, eyeRow + 1, ink, as: .eye)
            grid.put(x, closed ? eyeRow + 1 : eyeRow, ink, as: .eye)
            if !closed { grid.put(x + 1, eyeRow + 1, ink, as: .eye) }
        }
        if closed && eyes == .lashes {
            grid.put(5, eyeRow + 1, ink, as: .eye)
            grid.put(13, eyeRow + 1, ink, as: .eye)
        }
        paintSettledMouth(&grid, layout: layout)
    }

    /// The settled pose's wide smile and blush.
    private static func paintSettledMouth(_ grid: inout WorldCompanionGrid, layout: WorldCompanionFaceLayout) {
        for (x, dy) in [(8, 0), (9, 1), (10, 1), (11, 0)] { grid.put(x, layout.mouth + dy, ink, as: .mouth) }
        paintCheeks(&grid, layout: layout)
    }

    /// The glasses' frames (W-03): ink when the slot is left on Fern, else the accessory colour mixed
    /// 30 % toward ink, or 50 % for a light colour (Sun, Cream), so they still read on a body of the
    /// same colour.
    static func glassesColor(_ accessory: UInt32?) -> UInt32 {
        guard let accessory else { return ink }
        return mix(accessory, ink, luminance(accessory) > 0.62 ? 0.5 : 0.3)
    }

    /// A colour's perceived lightness, 0 (black) to 1 (white).
    static func luminance(_ hex: UInt32) -> Double {
        let red = Double((hex >> 16) & 0xFF), green = Double((hex >> 8) & 0xFF), blue = Double(hex & 0xFF)
        return (0.299 * red + 0.587 * green + 0.114 * blue) / 255
    }

    /// Round glasses over both eyes, joined by a bridge. The lenses follow the eyes (owner, 2026-11-15):
    /// round over the small eyes, set wider for wide-set eyes, and bigger round the big and button eyes.
    private static func paintGlasses(_ grid: inout WorldCompanionGrid, eyeRow: Int, color: UInt32,
                                     eyes: WorldCompanionEyes = .round) {
        let lens = eyes.lens
        for left in lens.lefts {
            let right = left + lens.width - 1
            for gx in left...right {
                grid.put(gx, eyeRow + lens.top, color, as: .glasses)
                grid.put(gx, eyeRow + lens.bottom, color, as: .glasses)
            }
            for gy in (eyeRow + lens.top + 1)..<(eyeRow + lens.bottom) {
                grid.put(left, gy, color, as: .glasses)
                grid.put(right, gy, color, as: .glasses)
            }
        }
        let bridgeFrom = lens.lefts[0] + lens.width, bridgeTo = lens.lefts[1] - 1
        for gx in bridgeFrom...bridgeTo { grid.put(gx, eyeRow + lens.top + 1, color, as: .glasses) }
    }

    /// Open eyes in `eyes`' style. A tired day's upper lid is body, so one colour keeps it filled and the
    /// eye half-lidded (W-11). Only the large eyes take `color`; the others stay ink.
    private static func paintEyes(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, eyeRow e: Int,
                                  eyes: WorldCompanionEyes, color: UInt32, tired: Bool) {
        let fill = eyes.isLarge ? color : ink
        for column in eyes.columns {
            for (dx, dy) in eyes.cells {
                let lid = tired && dy < eyes.lidBelow
                let shine = !tired && eyes == .big && dx == 0 && dy == -1
                let hex: UInt32 = lid ? body.dark : (shine ? 0xFFFFFF : fill)
                grid.put(column + dx, e + dy, hex, as: lid ? .body : .eye)
            }
        }
        if eyes == .lashes {
            grid.put(6, e - 1, ink, as: .eye)
            grid.put(13, e - 1, ink, as: .eye)
        }
    }

    /// Closed eyes: today's two short lines for every style, with the lashes' outer flick.
    private static func paintClosedEyes(_ grid: inout WorldCompanionGrid, eyeRow: Int, eyes: WorldCompanionEyes) {
        for x in [6, 7, 12, 13] { grid.put(x, eyeRow + 1, ink, as: .eye) }
        if eyes == .lashes {
            grid.put(5, eyeRow + 1, ink, as: .eye)
            grid.put(14, eyeRow + 1, ink, as: .eye)
        }
    }

    /// The hair (G8): a cap of hair over the head's top rows inside the outline, darker at its edge, and
    /// each style's own pixels above or below it.
    private static func paintHair(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, hair: WorldCompanionHair,
                                  color: UInt32) {
        guard hair != .none else { return }
        let top = body.top, dark = mix(color, shade, 0.3), light = mix(color, 0xFFFFFF, 0.25)
        let palette: [Character: UInt32] = ["c": color, "d": dark, "l": light]
        for y in top..<(top + hair.capRows) {
            for x in 0..<WorldCompanionGrid.width where body.contains(x, y) {
                grid.put(x, y, body.isOutline(x, y) ? dark : color, as: .hair)
            }
        }
        if hair == .long { paintLongSides(&grid, body: body, color: color, dark: dark) }
        if hair == .curly {
            // A row of curls above the head, one pair for every other column the head is wide.
            for x in stride(from: 4, through: 15, by: 2) where body.contains(x, top + 1) {
                grid.put(x, top - 1, color, as: .hair)
                grid.put(x + 1, top - 1, dark, as: .hair)
            }
        }
        for (x, dy, key) in hair.extras {
            guard let hex = palette[key] else { continue }
            if hair.extrasInsideOnly && !body.contains(x, top + dy) { continue }
            grid.put(x, top + dy, hex, as: .hair)
        }
    }

    /// Long hair's sides: two pixels in from each edge, down to the cheeks.
    private static func paintLongSides(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, color: UInt32, dark: UInt32) {
        for y in (body.top + 3)...(body.top + 8) {
            for x in 0..<WorldCompanionGrid.width where body.contains(x, y) && (!body.contains(x - 2, y) || !body.contains(x + 2, y)) {
                grid.put(x, y, body.isOutline(x, y) ? dark : color, as: .hair)
            }
        }
    }

    /// The body's pattern (G8), in shades of the body's own colour (moss is always green), painted as
    /// body so the one-colour widgets drop it, and never on the outline or under the sick day's blanket.
    private static func paintPattern(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, layout: WorldCompanionFaceLayout,
                                     pattern: WorldCompanionPattern, sick: Bool) {
        guard pattern != .plain else { return }
        let darker = mix(body.base, shade, 0.38), lighter = mix(body.base, 0xFFFFFF, 0.45)
        for (x, y, tone) in pattern.cells(body: body, eye: layout.eye, mouth: layout.mouth) {
            guard body.contains(x, y), !body.isOutline(x, y) else { continue }
            if sick && Double(y) >= (body.cy + 1.5).rounded() { continue }
            let hex: UInt32 = switch tone {
            case .darker: darker
            case .lighter: lighter
            case .moss: WorldCompanionLook.leaf
            case .mossDark: 0x557E4A
            }
            grid.put(x, y, hex, as: .body)
        }
    }

    /// A scarf wrapped low on the body, with a tail.
    private static func paintScarf(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, color: UInt32) {
        let row = Int((body.cy + 3.5).rounded())
        for x in 4...15 where body.contains(x, row) { grid.put(x, row, color, as: .scarf) }
        grid.put(13, row + 1, color, as: .scarf)
        grid.put(13, row + 2, mix(color, shade, 0.25), as: .scarf)
    }

    /// The sleep cap: a cream brim on the head's top row + 1, a cone drooping to the right with its
    /// darker edge, and a cream 2 × 2 pompom at columns 16–17.
    private static func paintCap(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, color: UInt32) {
        let top = body.top, edge = mix(color, shade, 0.25)
        for x in 4...15 where body.contains(x, top + 1) { grid.put(x, top + 1, cream, as: .cap) }
        for (row, from, to) in [(top, 6, 13), (top - 1, 7, 13), (top - 2, 8, 13), (top - 3, 10, 14), (top - 4, 12, 15)] {
            for x in from...to { grid.put(x, row, x == to ? edge : color, as: .cap) }
        }
        grid.put(16, top - 3, edge, as: .cap)
        grid.put(16, top - 2, edge, as: .cap)
        for (x, y) in [(16, top - 1), (17, top - 1), (16, top), (17, top)] { grid.put(x, y, cream, as: .cap) }
    }

    /// A side item's 6 × 8 picture, row by row: `k` ink, `c` its colour, `l` lighter, `d` darker,
    /// `w` cream, `b` water, `h` the dumbbell's grip, `s` the mug's steam.
    static func sideRows(_ item: WorldCompanionSide) -> [String] {
        switch item {
        case .none: []
        case .bottle: ["..ww..", "..kk..", ".kcck.", ".kclk.", ".kbbk.", ".kcck.", ".kcck.", "..kk.."]
        case .mug: [".s.s..", "..s...", "......", "kkkk..", "kclkk.", "kcck.k", "kcckk.", "kkkk.."]
        case .book: ["......", "kkkkk.", "kdcck.", "kdwck.", "kdcck.", "kdcck.", "kdcck.", "kkkkk."]
        case .dumbbell: ["......", "kk..kk", "cc..cc", "cchhcc", "cc..cc", "kk..kk", "......", "......"]
        }
    }

    /// The side item at columns 14–19, from the row above the body's centre: held against its right
    /// edge. The mug's steam stops while the companion sleeps.
    private static func paintSide(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, item: WorldCompanionSide,
                                  color: UInt32, asleep: Bool) {
        var palette: [Character: UInt32] = ["k": ink, "c": color, "l": mix(color, 0xFFFFFF, 0.4), "d": mix(color, shade, 0.35),
                                            "w": cream, "b": 0x9CC9E4, "h": 0x9A948C]
        if !asleep { palette["s"] = 0xE9E1D0 }
        let x0 = 14, y0 = Int(body.cy.rounded()) - 1
        for (dy, row) in sideRows(item).enumerated() {
            for (dx, key) in row.enumerated() {
                guard let hex = palette[key] else { continue }
                grid.put(x0 + dx, y0 + dy, hex, as: .side)
            }
        }
    }

    /// A Creation Studio piece, cell for cell in its place, painted as `piece` (its place in the look).
    private static func paintItem(_ grid: inout WorldCompanionGrid, _ item: WorldCompanionItemArt, as piece: WorldCompanionPiece) {
        for y in 0..<max(0, item.height) {
            for x in 0..<max(0, item.width) {
                guard let hex = item.color(x: x, y: y) else { continue }
                grid.put(item.x + x, item.y + y, hex, as: piece)
            }
        }
    }

    /// Blends `hex` toward `target` by `fraction` (0 keeps `hex`).
    static func mix(_ hex: UInt32, _ target: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) }
        func blend(_ shift: UInt32) -> UInt32 {
            let value = channel(hex, shift) + (channel(target, shift) - channel(hex, shift)) * fraction
            return UInt32(min(max(value.rounded(), 0), 255)) << shift
        }
        return blend(16) | blend(8) | blend(0)
    }
}

/// The hair's styles in pixels (G8, the owner's picks on 2026-11-15).
nonisolated enum WorldCompanionHair: Equatable, Sendable, CaseIterable {
    case none, tuft, fringe, spiky, bun, curly, long, swoop

    /// Rows of hair over the head, from its top row, inside the outline.
    var capRows: Int {
        switch self {
        case .none, .tuft: 0
        case .spiky, .bun, .swoop: 2
        case .fringe, .curly, .long: 3
        }
    }

    /// How many rows higher the sprout and the flower grow, so they come up through the hair.
    var lift: Int {
        switch self {
        case .curly, .bun, .swoop: 1
        case .none, .tuft, .fringe, .spiky, .long: 0
        }
    }

    /// Whether the extras are kept inside the body (the fringe's and curls' lower ends).
    var extrasInsideOnly: Bool { self == .fringe || self == .curly }

    /// The style's own pixels: (column, row from the head's top row, `c` colour / `d` darker / `l` lighter).
    var extras: [(Int, Int, Character)] {
        switch self {
        case .none, .long: []
        case .tuft: [(9, -1, "c"), (10, -1, "c"), (11, -2, "c"), (8, -2, "d"), (12, -3, "c"), (9, 0, "c"), (10, 0, "c"), (11, 0, "c")]
        case .fringe: [(5, 3, "c"), (8, 3, "c"), (11, 3, "c"), (14, 3, "c"), (6, 2, "l"), (9, 2, "l"), (12, 2, "l")]
        case .spiky: [(5, -1, "d"), (7, -1, "c"), (7, -2, "d"), (9, -1, "d"), (12, -1, "c"), (12, -2, "d"), (14, -1, "d")]
        case .bun: [(9, -1, "d"), (10, -1, "c"), (11, -1, "d"), (9, -2, "c"), (10, -2, "l"), (11, -2, "c"), (10, -3, "d")]
        case .curly: [(5, 3, "c"), (9, 3, "c"), (13, 3, "c")]
        case .swoop: [(8, -1, "c"), (9, -1, "l"), (10, -1, "l"), (11, -1, "c"), (12, -1, "c"), (13, 0, "c"), (13, 1, "c"), (12, 2, "c"), (14, 2, "c")]
        }
    }
}

/// The eyes' styles in pixels (G8). Every style keeps today's closed lines and its half lid when tired.
nonisolated enum WorldCompanionEyes: Equatable, Sendable, CaseIterable {
    case round, dot, big, button, lashes, wide

    /// The large eyes: they show a colour, and the glasses' lenses grow round them.
    var isLarge: Bool { self == .big || self == .button }

    /// Each eye's left column.
    var columns: [Int] {
        switch self {
        case .round, .dot, .lashes: [7, 12]
        case .big, .button: [6, 12]
        case .wide: [6, 13]
        }
    }

    /// One eye's cells from its left column and the eye row.
    var cells: [(Int, Int)] {
        switch self {
        case .round, .lashes, .wide: [(0, 0), (0, 1)]
        case .dot: [(0, 1)]
        case .big: [(0, -1), (1, -1), (0, 0), (1, 0), (0, 1), (1, 1)]
        case .button: [(0, 0), (1, 0), (0, 1), (1, 1)]
        }
    }

    /// A tired day's lid covers every cell of the eye on a row above this offset from the eye row.
    var lidBelow: Int {
        switch self {
        case .round, .lashes, .wide: 1
        case .dot: 0
        case .big, .button: 1
        }
    }

    /// The glasses' lenses round these eyes: each lens's left column, its width, and its top and
    /// bottom rows from the eye row.
    var lens: (lefts: [Int], width: Int, top: Int, bottom: Int) {
        switch self {
        case .round, .dot, .lashes: ([6, 11], 3, -1, 2)
        case .wide: ([5, 12], 3, -1, 2)
        case .big, .button: ([5, 11], 4, -2, 2)
        }
    }
}

/// The body's patterns in pixels (G8).
nonisolated enum WorldCompanionPattern: Equatable, Sendable, CaseIterable {
    case plain, freckles, belly, stripes, moss

    /// A pattern cell's shade.
    enum Tone: Equatable, Sendable { case darker, lighter, moss, mossDark }

    /// The pattern's cells on `body`, around the face at `eye` and `mouth`; the painter skips the
    /// outline and anything outside the body.
    func cells(body: WorldCompanionBody, eye: Int, mouth: Int) -> [(Int, Int, Tone)] {
        switch self {
        case .plain: []
        case .freckles:
            [(4, eye + 2, .darker), (5, eye + 3, .darker), (4, eye + 4, .darker),
             (15, eye + 2, .darker), (14, eye + 3, .darker), (15, eye + 4, .darker)]
        case .belly: bellyCells(body: body, mouth: mouth)
        case .stripes:
            stride(from: body.top + 1, to: eye - 1, by: 2).flatMap { y in (0..<WorldCompanionGrid.width).map { ($0, y, Tone.darker) } }
                + [mouth + 3, mouth + 5].flatMap { y in (0..<WorldCompanionGrid.width).filter { $0 < 6 || $0 > 13 }.map { ($0, y, Tone.darker) } }
        case .moss:
            (body.top...(body.top + 3)).flatMap { y in
                (0..<WorldCompanionGrid.width).filter { ($0 * 3 + y * 7) % 5 < 2 }.map { ($0, y, ($0 + y) % 3 == 0 ? Tone.mossDark : Tone.moss) }
            }
        }
    }

    /// A lighter oval on the lower middle of the body.
    private func bellyCells(body: WorldCompanionBody, mouth: Int) -> [(Int, Int, Tone)] {
        var cells: [(Int, Int, Tone)] = []
        for y in (mouth + 1)..<WorldCompanionGrid.height {
            for x in 6...13 {
                let dx = (Double(x) + 0.5 - 10) / 4.2, dy = (Double(y) + 0.5 - (body.cy + body.ry - 1.5)) / 3.4
                if dx * dx + dy * dy <= 1 { cells.append((x, y, .lighter)) }
            }
        }
        return cells
    }
}

/// The light a background scene is drawn in: it follows the map's day (owner, 2026-11-15).
nonisolated enum WorldSceneLight: Equatable, Sendable {
    case day, dusk, night

    /// How far the scene's colours move toward the night's blue.
    var dimming: Double {
        switch self {
        case .day: 0
        case .dusk: 0.25
        case .night: 0.45
        }
    }
}

/// The scenes behind the companion off the map (G8): 32 × 28 cells, the companion's 24 × 24 frame
/// standing at (4, 3) with its feet on the ground. Opaque; ``WorldCompanionSceneKind/none`` draws no scene.
nonisolated enum WorldCompanionScene {
    /// The scene's columns.
    static let width = 32
    /// The scene's rows.
    static let height = 28
    /// Where the companion's frame stands in the scene.
    static let frameOrigin = (x: 4, y: 3)
    /// The row the ground starts on.
    static let ground = 24
    /// The night blue a scene darkens toward at dusk and at night.
    static let nightTint: UInt32 = 0x1E2440

    /// `kind` in `light`, dimmed a little more in dark mode; nil for no scene.
    static func paint(_ kind: WorldCompanionSceneKind, light: WorldSceneLight, dark: Bool) -> [UInt32]? {
        guard kind != .none else { return nil }
        var cells = [UInt32](repeating: 0, count: width * height)
        draw(kind, into: &cells)
        // The night sky is already night: it only takes dark mode's dimming.
        let tint = kind == .night ? 0 : light.dimming
        return cells.map { hex in
            let lit = tint > 0 ? WorldCompanionPainter.mix(hex, nightTint, tint) : hex
            return dark ? WorldCompanionPainter.mix(lit, 0x000000, 0.2) : lit
        }
    }

    /// A scene's own drawing, by kind.
    private static func draw(_ kind: WorldCompanionSceneKind, into c: inout [UInt32]) {
        switch kind {
        case .none: return
        case .meadow: meadow(&c)
        case .forest: forest(&c)
        case .beach: beach(&c)
        case .night: night(&c)
        case .snow: snow(&c)
        case .room: room(&c)
        case .rain: rain(&c)
        }
    }

    private static func put(_ c: inout [UInt32], _ x: Int, _ y: Int, _ v: UInt32) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        c[y * width + x] = v
    }

    private static func fill(_ c: inout [UInt32], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: UInt32) {
        for y in y0...y1 { for x in x0...x1 { put(&c, x, y, v) } }
    }

    /// A fixed scatter: true for about one cell in `m`.
    private static func scatter(_ x: Int, _ y: Int, _ m: Int) -> Bool { (x * 73 + y * 151 + x * y * 7) % m == 0 }

    /// A small pixel sun, its top-left at (x, y).
    private static func sun(_ c: inout [UInt32], _ x: Int, _ y: Int) {
        for (dx, dy) in [(1, 1), (2, 1), (1, 2), (2, 2), (0, 1), (3, 2), (1, 0), (2, 3)] { put(&c, x + dx, y + dy, 0xF6D57A) }
    }

    private static func meadow(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, 9, 0xBFE0EC); fill(&c, 0, 10, 31, 17, 0xD3EBEF)
        fill(&c, 0, 18, 31, ground - 1, 0xA9D18E); fill(&c, 0, ground, 31, 27, 0x7FB069)
        sun(&c, 24, 2)
        for (x, y) in [(3, 5), (4, 5), (5, 5), (4, 4), (6, 6), (2, 6), (3, 6), (4, 6), (5, 6)] { put(&c, x, y, 0xFFFFFF) }
        for x in stride(from: 1, to: width, by: 5) { put(&c, x, ground + 1, 0xF3E6CB); put(&c, x + 2, ground + 2, 0xE8A3A0) }
        for x in 0..<width where scatter(x, 18, 3) { put(&c, x, 18, 0x93C27A) }
    }

    private static func forest(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, ground - 1, 0xCFE0C3); fill(&c, 0, ground, 31, 27, 0x5E844D)
        for tx in [2, 11, 22, 29] {
            let top = tx % 2 == 0 ? 4 : 6
            for y in top..<ground {
                let half = min((y - top) / 2 + 1, 4)
                for x in (tx - half)...(tx + half) {
                    let trunk = y > ground - 4 && abs(x - tx) < 1
                    put(&c, x, y, trunk ? 0x6B4A2E : (abs(x - tx) == half ? 0x3F6B3A : 0x4F7D45))
                }
            }
        }
        for x in 0..<width where scatter(x, 26, 4) { put(&c, x, 26, 0x72A364) }
    }

    private static func beach(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, 13, 0xBFE0EC); fill(&c, 0, 14, 31, 19, 0x6FA8C9)
        fill(&c, 0, 20, 31, 20, 0xF3F7F8); fill(&c, 0, 21, 31, 27, 0xEBD5A4)
        for x in 0..<width where scatter(x, 16, 4) { put(&c, x, 16, 0x8DBCD6) }
        sun(&c, 4, 2)
        for x in 0..<width where scatter(x, 24, 6) { put(&c, x, 24, 0xD9BF88) }
        put(&c, 27, 25, 0xE8A3A0); put(&c, 28, 25, 0xE8A3A0); put(&c, 27, 26, 0xD9532F)
    }

    private static func night(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, ground - 1, 0x26314F); fill(&c, 0, ground, 31, 27, 0x2F4A3A)
        for y in 0..<20 { for x in 0..<width where scatter(x, y, 37) { put(&c, x, y, 0xF3E6CB) } }
        for (x, y) in [(25, 3), (26, 3), (27, 4), (27, 5), (26, 6), (25, 6), (24, 5), (24, 4), (25, 4), (25, 5)] { put(&c, x, y, 0xF6EBC6) }
        put(&c, 26, 4, 0x26314F); put(&c, 26, 5, 0x26314F)
        for x in 0..<width where scatter(x, 25, 5) { put(&c, x, 25, 0x3D5C47) }
    }

    private static func snow(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, ground - 1, 0xDDE6EE); fill(&c, 0, ground, 31, 27, 0xF7F9FB)
        for y in 0..<ground { for x in 0..<width where scatter(x, y, 23) { put(&c, x, y, 0xFFFFFF) } }
        for x in 0..<width where scatter(x, ground, 3) { put(&c, x, ground - 1, 0xF7F9FB) }
        for tx in [3, 28] {
            for y in 12..<ground {
                let half = min((y - 12) / 3 + 1, 3)
                for x in (tx - half)...(tx + half) { put(&c, x, y, y % 3 == 0 ? 0xF7F9FB : 0x557E4A) }
            }
        }
    }

    private static func room(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, ground - 1, 0xEFD9B8); fill(&c, 0, ground, 31, 27, 0xB07A4F)
        for x in stride(from: 0, to: width, by: 6) { for y in ground...27 { put(&c, x, y, 0x8E5E3A) } }
        fill(&c, 20, 3, 29, 12, 0x6B4A2E); fill(&c, 21, 4, 28, 11, 0xBFE0EC)
        fill(&c, 24, 4, 25, 11, 0x6B4A2E); fill(&c, 21, 7, 28, 8, 0x6B4A2E)
        put(&c, 22, 10, 0x7FB069); put(&c, 27, 5, 0xFFFFFF)
        fill(&c, 2, 5, 6, 9, 0x8E5E3A); fill(&c, 3, 6, 5, 8, 0xE8A3A0)
        fill(&c, 1, 25, 30, 26, 0xD9532F)
        for x in stride(from: 2, to: 30, by: 3) { put(&c, x, 25, 0xF3E6CB) }
    }

    private static func rain(_ c: inout [UInt32]) {
        fill(&c, 0, 0, 31, ground - 1, 0xA9B4BE); fill(&c, 0, ground, 31, 27, 0x6E8463)
        fill(&c, 3, 2, 6, 2, 0xD6DCE1); fill(&c, 2, 3, 7, 3, 0xD6DCE1)
        fill(&c, 20, 4, 24, 4, 0xD6DCE1); fill(&c, 19, 5, 25, 5, 0xD6DCE1)
        for y in 6..<ground { for x in 0..<width where (x * 5 + y * 3) % 17 == 0 { put(&c, x, y, 0x7C93AB); put(&c, x, y + 1, 0x7C93AB) } }
        for x in [6, 7, 8, 24, 25, 26, 27] { put(&c, x, 26, 0x8AA6BE) }
    }
}

/// The painter's name for a background scene, as the app's `CompanionBackground` tokens name them.
nonisolated enum WorldCompanionSceneKind: Equatable, Sendable, CaseIterable {
    case none, meadow, forest, beach, night, snow, room, rain
}

// MARK: - Twin: end
