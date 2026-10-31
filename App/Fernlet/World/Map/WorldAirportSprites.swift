import Foundation

/// The airports' pixel art on Home (World-Airports-Spec §3, §5; the mockup's `TOWER`, `JET_U`, `CASE` and `MASK`
/// rows verbatim): the control tower with its one-pixel halo, grey before it's found; the parked and taking-off
/// jets in the four tail colours; and Sprout's travel look, the suitcase and the sleep mask. Pure data.
nonisolated enum WorldAirportSprites {
    /// The design's ink.
    static let ink: UInt32 = 0x4A2E1C

    /// The control tower, 13 × 17 (the mockup's `TOWER`).
    static let towerRows = [
        "......r......", "......k......", "..kkkkkkkkk..", ".kaaaaaaaaak.", "kaawaaaawaaak", ".kaaaaaaaaak.", "..kkkkkkkkk..",
        "...kdgggdk...", "....kgggk....", "....kgsgk....", "....kgggk....", "....kgsgk....", "....kgggk....", "....kgggk....",
        "...kggggdk...", "..kgggggggk..", ".kkkkkkkkkkk.",
    ]
    /// The tower's own colours.
    static let towerPalette: [Character: UInt32] = [
        "k": ink, "a": 0x6FA8D0, "w": 0xD8F2FF, "g": 0xD2C8B2, "d": 0xA39B88, "s": 0xF6F1E4, "r": 0xC8553D,
    ]
    /// The halo's key in ``haloed(_:)`` rows.
    static let haloKey: Character = "O"

    /// The tower on the map, 15 × 19 with its halo: full colour on a cream rim once found; before, every line grey
    /// and every fill a paler grey (the mockup's `tower()`), in light or dark.
    static func tower(found: Bool, dark: Bool) -> WorldSprite {
        let rows = haloed(towerRows)
        guard !found else {
            return WorldSprite(rows: rows, palette: towerPalette.merging([haloKey: dark ? 0xF3E6C8 : 0xFFF6E2]) { $1 })
        }
        let line: UInt32 = dark ? 0xA7AFB4 : 0x7E878C, fill: UInt32 = dark ? 0x5E676D : 0xC3C9CC
        var palette: [Character: UInt32] = [haloKey: dark ? 0x8B9398 : 0xF4F1EA]
        // Bounded: the tower's seven keys.
        for key in towerPalette.keys { palette[key] = key == "k" ? line : fill }
        return WorldSprite(rows: rows, palette: palette)
    }

    /// `rows` padded by one pixel all round, with every empty pixel that touches art (diagonals too) turned into
    /// ``haloKey`` (the mockup's `haloed()`). Bounded: at most 64 × 64 pixels, nine looks each.
    static func haloed(_ rows: [String]) -> [String] {
        let grid = rows.prefix(62).map { Array($0.prefix(62)) }
        let width = (grid.first?.count ?? 0) + 2, height = grid.count + 2
        func isArt(_ x: Int, _ y: Int) -> Bool {
            let gx = x - 1, gy = y - 1
            guard gy >= 0, gy < grid.count, gx >= 0, gx < grid[gy].count else { return false }
            return grid[gy][gx] != "."
        }
        var out: [String] = []
        // Bounded: the padded rows, at most 64.
        for y in 0..<height {
            var row = ""
            // Bounded: the padded columns, at most 64.
            for x in 0..<width {
                if isArt(x, y) {
                    row.append(grid[y - 1][x - 1])
                } else {
                    let touches = (-1...1).contains { dy in (-1...1).contains { dx in isArt(x + dx, y + dy) } }
                    row.append(touches ? haloKey : ".")
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: Jets

    /// A parked jet seen from above, nose up (the mockup's `JET_U`); "h" is the tail colour.
    static let jetUpRows = [
        "....kkk....", "....ksk....", "....ksk....", "...kkskk...", ".kkssssskk.", "ksssssssssk", "kkkkkskkkkk", "....ksk....",
        "....ksk....", "...kkhkk...", "..khhhhhk..", "..kkkkkkk..",
    ]
    /// The four tail colours (§5), in the mockup's order.
    static let tails: [UInt32] = [0xC8553D, 0x3F7FB3, 0x5E844D, 0xD9A92E]

    /// A parked jet at a gate, nose down (the mockup's `JET_D`), with tail colour `tail` (wrapping).
    static func parkedJet(tail: Int) -> WorldSprite {
        WorldSprite(rows: jetUpRows.reversed(), palette: jetPalette(tail: tail))
    }

    /// A jet rolling right along a runway (the mockup's `JET_R`, `JET_U` turned a quarter right).
    static func rollingJet(tail: Int) -> WorldSprite {
        WorldSprite(rows: turnedRight(jetUpRows), palette: jetPalette(tail: tail))
    }

    /// The jets' colours with tail colour `tail` (wrapping).
    private static func jetPalette(tail: Int) -> [Character: UInt32] {
        let index = ((tail % tails.count) + tails.count) % tails.count
        return ["k": ink, "s": 0xF6F1E4, "h": tails[index]]
    }

    /// `rows` turned a quarter clockwise (the mockup's `rotR`). Bounded: at most 64 × 64 pixels.
    static func turnedRight(_ rows: [String]) -> [String] {
        let grid = rows.prefix(64).map { Array($0.prefix(64)) }
        guard let width = grid.first?.count else { return [] }
        let height = grid.count
        // Bounded: the turned rows (the old width) and columns (the old height), at most 64 each.
        return (0..<width).map { y in
            String((0..<height).map { x in
                let source = grid[height - 1 - x]
                return y < source.count ? source[y] : "."
            })
        }
    }

    // MARK: Sprout's travel look

    /// The little rolling suitcase, 7 × 11 (the mockup's `CASE`).
    static let suitcase = WorldSprite(
        rows: ["..kkk..", "..k.k..", "..k.k..", "kkkkkkk", "kdddddk", "kyyyyyk", "kdddddk", "kdddddk", "kyyyyyk", "kkkkkkk", ".k...k."],
        palette: ["k": ink, "d": 0x7A4B2A, "y": 0xF2D58A])
    /// The sleep mask pushed up on Sprout's forehead, 14 × 4 (the mockup's `MASK`).
    static let sleepMask = WorldSprite(
        rows: ["k.kkkk..kkkk.k", "kkmmmmkkmmmmkk", "k.mMMmmmmMMm.k", "..kkkk..kkkk.."],
        palette: ["k": ink, "m": 0x4E5F96, "M": 0x8FA3D6])
}
