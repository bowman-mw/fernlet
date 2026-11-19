import Foundation

/// The live planes' pixel art (owner 2026-11-19, call 5): one design per ``LiveAircraftFamily``, seen from above with
/// the nose up, sized to each other (a jumbo dwarfs a Cessna), in the airport jets' ink. Pure data.
///
/// Keys: `k` the ink outline, `b` the fuselage, `w` the wings, `t` the tail, `e` the engines (or a stripe), `c` the
/// cockpit glass, `p` a propeller's blur, `r` a rotor's blur. A ``LiveAircraftLivery`` fills b, w, t and e.
///
/// Pixel art rotates badly, so a plane is drawn at the nearest of eight headings: the quarter turns exactly, the
/// diagonals by a nearest-pixel turn (``turned(_:eighths:)``), which keeps every pixel square and crisp.
nonisolated enum LiveAircraftSprites {
    /// The design's ink (the airport jets').
    static let ink: UInt32 = WorldAirportSprites.ink
    /// The cockpit glass.
    static let glass: UInt32 = 0x3B5B78
    /// A propeller's or rotor's blur.
    static let blur: UInt32 = 0xA8B0B6

    /// A small plane for a 46-point tile (onboarding's card): the airport's jet, nose up, with a blue tail.
    static let icon = WorldSprite(rows: WorldAirportSprites.jetUpRows, palette: ["k": ink, "s": 0xF6F1E4, "h": 0x3F7FB3])

    /// The nose-up rows of `family`.
    static func rows(_ family: LiveAircraftFamily) -> [String] {
        switch family {
        case .narrowbody: narrowbodyRows
        case .widebody: widebodyRows
        case .jumbo: jumboRows
        case .regionalJet: regionalJetRows
        case .bizjet: bizjetRows
        case .turboprop: turbopropRows
        case .lightSingle: lightSingleRows
        case .lightTwin: lightTwinRows
        case .helicopter: helicopterRows
        case .fighter: fighterRows
        }
    }

    /// The colour of every key under `livery`.
    static func palette(_ livery: LiveAircraftLivery) -> [Character: UInt32] {
        ["k": ink, "b": livery.body, "w": livery.wing, "t": livery.tail, "e": livery.accent, "c": glass,
         "p": blur, "r": blur]
    }

    /// `family` in `livery`, turned to `eighths` of a full turn clockwise from nose-up (0…7).
    static func sprite(_ family: LiveAircraftFamily, livery: LiveAircraftLivery, eighths: Int) -> WorldSprite {
        let headings = turnedRows[family] ?? []
        let index = ((eighths % 8) + 8) % 8
        return WorldSprite(rows: index < headings.count ? headings[index] : rows(family), palette: palette(livery))
    }

    /// Every family at its eight headings, turned once on first use (the diagonal turn samples nine points a pixel,
    /// too much to redo for each plane on each frame).
    static let turnedRows: [LiveAircraftFamily: [[String]]] = {
        var table: [LiveAircraftFamily: [[String]]] = [:]
        // Bounded: ten families, eight headings each.
        for family in LiveAircraftFamily.allCases {
            table[family] = (0..<8).map { turned(rows(family), eighths: $0) }
        }
        return table
    }()

    /// The eighth of a turn nearest `trackDegrees` (0 north, clockwise); north when there's no track.
    static func eighths(for trackDegrees: Double?) -> Int {
        guard let track = trackDegrees, track.isFinite else { return 0 }
        let turn = (track.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((turn / 45).rounded()) % 8
    }

    /// `rows` turned `eighths` of a turn clockwise: quarter turns exactly, then one eighth more by a nearest-pixel
    /// turn when `eighths` is odd. Bounded: at most 64 × 64 pixels in, 92 × 92 out.
    static func turned(_ rows: [String], eighths: Int) -> [String] {
        let steps = ((eighths % 8) + 8) % 8
        var grid = rows
        // Bounded: at most three quarter turns.
        for _ in 0..<(steps / 2) { grid = WorldAirportSprites.turnedRight(grid) }
        return steps % 2 == 1 ? turnedEighth(grid) : grid
    }

    /// The nine sample offsets inside one turned pixel.
    private static let samples: [Double] = [-1.0 / 3, 0, 1.0 / 3]

    /// `rows` turned 45° clockwise. A plain nearest-pixel turn shatters one-pixel outlines, so each pixel of the turned
    /// canvas samples nine points of the source: it is art when three or more land on art, and takes the fill colour
    /// most of them saw (ink when ink outnumbers fill). Then the ink outline is drawn again round the turned shape, and
    /// the result trimmed to the art.
    static func turnedEighth(_ rows: [String]) -> [String] {
        let grid = rows.prefix(64).map { Array($0.prefix(64)) }
        let height = grid.count, width = grid.first?.count ?? 0
        guard width > 0 else { return [] }
        let side = min(Int((Double(width + height) / 2.0.squareRoot()).rounded(.up)) + 3, 92)
        let centre = Double(side - 1) / 2
        var turned: [[Character]] = []
        // Bounded: `side` rows of `side` pixels, at most 92 each.
        for y in 0..<side {
            turned.append((0..<side).map { x in
                sampledKey(grid, at: Double(x) - centre, Double(y) - centre, width: width, height: height)
            })
        }
        return trimmed(outlined(turned).map { String($0) })
    }

    /// The key a turned pixel at offset (`dx`, `dy`) from the canvas centre takes (see ``turnedEighth(_:)``).
    private static func sampledKey(_ grid: [[Character]], at dx: Double, _ dy: Double, width: Int, height: Int) -> Character {
        let cosine = 2.0.squareRoot() / 2
        let sourceX = Double(width - 1) / 2, sourceY = Double(height - 1) / 2
        var counts: [Character: Int] = [:]
        // Bounded: nine samples.
        for oy in samples {
            for ox in samples {
                // The inverse turn (45° anticlockwise) finds the source pixel.
                let px = dx + ox, py = dy + oy
                let sx = Int((px * cosine + py * cosine + sourceX).rounded())
                let sy = Int((-px * cosine + py * cosine + sourceY).rounded())
                guard sy >= 0, sy < height, sx >= 0, sx < grid[sy].count, grid[sy][sx] != "." else { continue }
                counts[grid[sy][sx], default: 0] += 1
            }
        }
        guard counts.values.reduce(0, +) >= 3 else { return "." }
        let inkCount = counts["k"] ?? 0
        let fills = counts.filter { $0.key != "k" }
        guard let fill = fills.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }),
              Double(fills.values.reduce(0, +)) >= Double(inkCount) * 0.6 else { return "k" }
        return fill.key
    }

    /// `grid` with every art pixel that touches a clear pixel (or the edge) turned to ink, blurs excepted.
    private static func outlined(_ grid: [[Character]]) -> [[Character]] {
        var out = grid
        let height = grid.count
        // Bounded: at most 92 × 92 pixels, four neighbours each.
        for y in 0..<height {
            for x in grid[y].indices where grid[y][x] != "." && grid[y][x] != "p" && grid[y][x] != "r" {
                let touchesClear = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                    let nx = x + dx, ny = y + dy
                    return ny < 0 || ny >= height || nx < 0 || nx >= grid[ny].count || grid[ny][nx] == "."
                }
                if touchesClear { out[y][x] = "k" }
            }
        }
        return out
    }

    /// `rows` without the clear rows and columns round the art. Bounded: at most 92 × 92 pixels.
    static func trimmed(_ rows: [String]) -> [String] {
        let grid = rows.prefix(92).map { Array($0.prefix(92)) }
        let filled = grid.indices.filter { grid[$0].contains { $0 != "." } }
        guard let top = filled.first, let bottom = filled.last else { return [] }
        let columns = grid[top...bottom].flatMap { row in row.indices.filter { row[$0] != "." } }
        guard let left = columns.min(), let right = columns.max() else { return [] }
        return grid[top...bottom].map { String($0[left...right]) }
    }

    // MARK: The designs, nose up
    //
    // Drawn from proportions (owner 2026-11-19, review call 1: wings in proportion to the fuselage): each design is laid
    // out from its fuselage length and width, wing root, sweep and span, engines and tail, mirrored about the centre,
    // with the ink outline drawn round the shape.

    /// A 737 / A320: a swept wing at mid-body, an engine under each, a swept tailplane: 23 × 24.
    static let narrowbodyRows = [
        "...........k...........", "..........kbk..........", ".........kccck.........", ".........kbbbk.........",
        ".........kbbbk.........", ".........kbbbk.........", ".........kbbbk.........", ".........kbbbk.........",
        ".......k.kbbbk.k.......", "......kekkbbbkkek......", "......kekwbbbwkek......", ".....kkekwbbbwkekk.....",
        "...kkwwkwwbbbwwkwwkk...", "..kwwwwwwwbbbwwwwwwwk..", ".kwwwwwwwkbbbkwwwwwwwk.", ".kwwkkkkkkbbbkkkkkkwwk.",
        "..kk.....kbbbk.....kk..", ".........kbbbk.........", ".........kbbbk.........", "........ktbtbtk........",
        ".......kttbtbttk.......", ".......kttktkttk.......", "........kkktkkk........", "...........k...........",
    ]

    /// A 787 / 777 / A330: a wider, longer body, long swept wings and big engines: 29 × 30.
    static let widebodyRows = [
        ".............kkk.............", "............kbbbk............", "...........kbcccbk...........",
        "...........kbbbbbk...........", "...........kbbbbbk...........", "...........kbbbbbk...........",
        "...........kbbbbbk...........", "...........kbbbbbk...........", "...........kbbbbbk...........",
        "........kk.kbbbbbk.kk........", ".......keekkbbbbbkkeek.......", ".......keekkbbbbbkkeek.......",
        ".......keekwbbbbbwkeek.......", ".......keekwbbbbbwkeek.......", "......kwkkwwbbbbbwwkkwk......",
        "....kkwwwwwwbbbbbwwwwwwkk....", "..kkwwwwwwwwbbbbbwwwwwwwwkk..", ".kwwwwwwwwwwbbbbbwwwwwwwwwwk.",
        ".kwwwwwwkkkkbbbbbkkkkwwwwwwk.", ".kwwkkkk...kbbbbbk...kkkkwwk.", "..kk.......kbbbbbk.......kk..",
        "...........kbbbbbk...........", "...........kbbbbbk...........", "...........kbbbbbk...........",
        "..........kkbbtbbkk..........", ".........kttbbtbbttk.........", ".........kttbbtbbttk.........",
        ".........kttkbtbkttk.........", "..........kk.ktk.kk..........", "..............k..............",
    ]

    /// A 747 / A380: the longest body and four engines: 31 × 33.
    static let jumboRows = [
        "..............kkk..............", ".............kbbbk.............", "............kbcccbk............",
        "............kbbbbbk............", "............kbbbbbk............", "............kbbbbbk............",
        "............kbbbbbk............", "............kbbbbbk............", "............kbbbbbk............",
        "............kbbbbbk............", "..........k.kbbbbbk.k..........", ".........kekkbbbbbkkek.........",
        ".........kekkbbbbbkkek.........", "......k..kekwbbbbbwkek..k......", ".....kek.kekwbbbbbwkek.kek.....",
        ".....kekkwkwwbbbbbwwkwkkek.....", ".....kekwwwwwbbbbbwwwwwkek.....", "....kkekwwwwwbbbbbwwwwwkekk....",
        "..kkwwkwwwwwwbbbbbwwwwwwkwwkk..", ".kwwwwwwwwkkkbbbbbkkkwwwwwwwwk.", ".kwwwwwkkk..kbbbbbk..kkkwwwwwk.",
        ".kwkkkk.....kbbbbbk.....kkkkwk.", "..k.........kbbbbbk.........k..", "............kbbbbbk............",
        "............kbbbbbk............", "............kbbbbbk............", "............kbbbbbk............",
        "...........kkbbtbbkk...........", "..........kttbbtbbttk..........", ".........ktttbbtbbtttk.........",
        ".........ktttkbtbktttk.........", "..........kkk.ktk.kkk..........", "...............k...............",
    ]

    /// A CRJ / ERJ: a slim body, engines at the tail under a T-tail: 19 × 22.
    static let regionalJetRows = [
        ".........k.........", "........kbk........", ".......kccck.......", ".......kbbbk.......",
        ".......kbbbk.......", ".......kbbbk.......", ".......kbbbk.......", ".......kbbbk.......",
        ".......kbbbk.......", "......kkbbbkk......", "...kkkwwbbbwwkkk...", "..kwwwwwbbbwwwwwk..",
        ".kwwwwwwbbbwwwwwwk.", ".kwwwwkkbbbkkwwwwk.", "..kkkkkebbbekkkkk..", "......kebbbek......",
        "......kebtbek......", ".......kbtbk.......", "......kkbtbkk......", ".....ktttttttk.....",
        ".....kttktkttk.....", "......kk.k.kk......",
    ]

    /// A Citation / Gulfstream: short and swept, engines at the tail: 17 × 19.
    static let bizjetRows = [
        "........k........", ".......kbk.......", "......kccck......", "......kbbbk......", "......kbbbk......",
        "......kbbbk......", "......kbbbk......", "......kbbbk......", ".....kkbbbkk.....", "...kkwwbbbwwkk...",
        "..kwwwwbbbwwwwk..", ".kwwwwkbbbkwwwwk.", "..kkkkebbbekkkk..", ".....kebbbek.....", ".....kebtbek.....",
        "......kbtbk......", ".....ktttttk.....", "......kktkk......", "........k........",
    ]

    /// An ATR / Dash 8 / King Air: a straight wing, two nacelles with propellers: 23 × 21.
    static let turbopropRows = [
        "...........k...........", "..........kbk..........", ".........kbcbk.........", ".........kbbbk.........",
        ".........kbbbk.........", "......pppkbbbkppp......", "..kkkkkekkbbbkkekkkkk..", ".kwwwwkekwbbbwkekwwwwk.",
        ".kwwwwkekwbbbwkekwwwwk.", "..kkkkkekwbbbwkekkkkk..", ".......kkkbbbkkk.......", ".........kbbbk.........",
        ".........kbbbk.........", ".........kbbbk.........", ".........kbbbk.........", ".........kbbbk.........",
        "........kkbbbkk........", ".......kttbbbttk.......", ".......ktttbtttk.......", "........kkkbkkk........",
        "...........k...........",
    ]

    /// A Cessna / Piper: a propeller at the nose and a long straight wing: 17 × 13.
    static let lightSingleRows = [
        "......ppppp......", ".......kek.......", "..kkkkkkbkkkkkk..", ".kwwwwwwbwwwwwwk.", ".kwwwwwwbwwwwwwk.",
        "..kkkkkkbkkkkkk..", ".......kbk.......", ".......kbk.......", ".......kbk.......", "......kkbkk......",
        ".....kttbttk.....", "......kkbkk......", "........k........",
    ]

    /// A Baron / Seneca: a propeller on each wing: 17 × 15.
    static let lightTwinRows = [
        "........k........", ".......kbk.......", "......kbcbk......", "....pppbbbppp....", "..kkkekbbbkekkk..",
        ".kwwkekbbbkekwwk.", ".kwwkekbbbkekwwk.", "..kkkkkbbbkkkkk..", "......kbbbk......", "......kbbbk......",
        "......kbbbk......", "......kbbbk......", ".....kttbttk.....", "......kkbkk......", "........k........",
    ]

    /// A helicopter: its rotor's blur across the cabin, a tail boom and tail rotor: 19 × 20.
    static let helicopterRows = [
        "...r....kkk....r...", "....r..kccck..r....", ".....r.kbbbk.r.....", "......kbbbbbk......",
        "......kbbbbbk......", "......kbbbbbk......", "......kbbbbbk......", ".......kbbbk.......",
        ".......rkbkr.......", "......r.kbk.r......", ".....r..kbk..r.....", "....r...kbk...r....",
        "...r....kbk....r...", "..r.....kbk.....r..", ".r......kbk......r.", ".......kkbkk.......",
        "......ktttttk......", ".......kktkk.......", "........ktk........", ".........k.........",
    ]

    /// An F-16 / F/A-18: a pointed nose, the canopy, cropped-delta wings and one fin: 17 × 23.
    static let fighterRows = [
        "........k........", ".......kbk.......", ".......kbk.......", ".......kbk.......", "......kbbbk......",
        "......kbcbk......", "......kbcbk......", "......kbbbk......", "......kbbbk......", "......kbbbk......",
        "......kbbbk......", ".....kwbbbwk.....", "....kwwbbbwwk....", "..kkwwwbbbwwwkk..", ".kwwwwwbbbwwwwwk.",
        ".kwwwwwbbbwwwwwk.", "..kkkwwbbbwwkkk..", ".....kkbtbkk.....", "......kbtbk......", ".....ktbtbtk.....",
        "....kttbtbttk....", ".....kkeeekk.....", ".......kkk.......",
    ]
}
