import Foundation

/// One run of sprite pixels in one key: row `y`, columns `from` through `to`.
nonisolated struct WorldSideJetRun: Equatable, Sendable {
    let y: Int
    let from: Int
    let to: Int
    let key: Character
}

/// One horizontal run of one colour in a ``WorldSprite``, for drawing a large sprite as few rectangles.
nonisolated struct WorldSpriteColourRun: Equatable, Sendable {
    let x: Int
    let y: Int
    let length: Int
    let colour: UInt32
}

/// Sprout's plane seen side-on, nose right (owner 2026-11-18, the boarding hop): the cream 737 of the in-flight view
/// (``WorldFlyingPalette``) with its red cheat line and yellow pinstripe, a swept red fin, a row of windows, the
/// cockpit glass, the front door Sprout uses, the wing root and an engine; 132 × 50 sprite pixels. Pure data, kept
/// apart from any one scene so whatever draws a plane side-on takes the same art (the boarding hop now; live planes
/// on the map may follow).
///
/// The base rows are wheels up with the door shut. ``sprite(gearDown:doorOpen:)`` lays the wheels and the open
/// doorway over them as pixel runs; ``parked``, ``rolling`` and ``flying`` are the three looks the hop draws.
nonisolated enum WorldSideJetSprite {
    /// The sprite's size in sprite pixels.
    static let width = 132
    static let height = 50
    /// The top-left pixel of Sprout's window, the window just behind the door; its glass is ``windowSize`` square.
    static let sproutWindow = (x: 90, y: 22)
    static let windowSize = 3
    /// The door's frame: its columns, and its sill (the frame's bottom row).
    static let doorColumns = 101...110
    static let doorSill = 37
    /// The bottom row of the wheels; the ground is under it.
    static let wheelsRow = 49

    /// The plane's colours (``WorldFlyingPalette``'s, fixed in Dark Mode as the plane is the same plane).
    static let palette: [Character: UInt32] = [
        "k": WorldSprite.ink, "s": 0xF4F0E6, "h": 0xFFFFFF, "H": 0xE6E0D3, "b": 0xDCD5C6, "l": 0xC9C1B0, "w": 0x55697B,
        "r": 0xC8553D, "y": 0xF2C14E, "t": 0xC8553D, "f": 0xB7BEC4, "D": 0x2E3A44, "e": 0xB7BEC4, "E": 0x55697B,
    ]

    /// On the ground with the door open (the hop's first and last moments).
    static let parked = sprite(gearDown: true, doorOpen: true)
    /// On the ground with the door shut (rolling, touching down).
    static let rolling = sprite(gearDown: true, doorOpen: false)
    /// In the air, wheels up.
    static let flying = sprite(gearDown: false, doorOpen: false)

    /// The plane with its wheels down or up and its door open or shut.
    static func sprite(gearDown: Bool, doorOpen: Bool) -> WorldSprite {
        var grid = rows.map { Array($0) }
        if gearDown { lay(gearRuns, on: &grid) }
        if doorOpen { lay(openDoorRuns, on: &grid) }
        return WorldSprite(rows: grid.map { String($0) }, palette: palette)
    }

    /// `runs` written over `grid`; a run outside the grid, or backwards, is skipped.
    private static func lay(_ runs: [WorldSideJetRun], on grid: inout [[Character]]) {
        // Bounded: the runs given (at most a few dozen), each at most the sprite's width.
        for run in runs where grid.indices.contains(run.y) && run.from <= run.to {
            for x in run.from...run.to where grid[run.y].indices.contains(x) { grid[run.y][x] = run.key }
        }
    }

    /// `sprite`'s pixels as runs of one colour along each row, left to right, top to bottom. Bounded: at most
    /// 64 rows of 160 pixels are read.
    static func colourRuns(of sprite: WorldSprite) -> [WorldSpriteColourRun] {
        var runs: [WorldSpriteColourRun] = []
        // Bounded: at most 64 rows.
        for (y, row) in sprite.rows.prefix(64).enumerated() {
            var pending: WorldSpriteColourRun?
            // Bounded: at most 160 pixels a row.
            for (x, key) in row.prefix(160).enumerated() {
                let colour = sprite.palette[key]
                if let current = pending, current.colour == colour, current.x + current.length == x {
                    pending = WorldSpriteColourRun(x: current.x, y: y, length: current.length + 1, colour: current.colour)
                    continue
                }
                if let current = pending { runs.append(current) }
                pending = colour.map { WorldSpriteColourRun(x: x, y: y, length: 1, colour: $0) }
            }
            if let current = pending { runs.append(current) }
        }
        return runs
    }

    // MARK: Pixels (drawn from the approved storyboard, page UABPFeySzGuLEisj7bMKn3)

    static let rows = [
        "...............kkkkkkkkkkkkk........................................................................................................",
        "..............ktttttttttttttkk......................................................................................................",
        "..............ktttttttttttttttk.....................................................................................................",
        "...............ktttttttttttttttkk...................................................................................................",
        "...............ktttttttttttttttttk..................................................................................................",
        "...............kttttttttttttttttttkk................................................................................................",
        "................ktttttttttttttttttttk...............................................................................................",
        "................kttttttttttttttttttttkk.............................................................................................",
        "................kttttttttttttttttttttttk............................................................................................",
        ".................kttttttttttttttttttttttkk..........................................................................................",
        ".................kttttttttttttttttttttttttkk........................................................................................",
        ".................kttttttttttttttttttttttttttk.......................................................................................",
        "..................kttttttttttttttttttttttttttkk.....................................................................................",
        "..................kttttttttttttttttttttttttttttk....................................................................................",
        "..................ktttttttttttttttttttttttttttttkk..................................................................................",
        "................kkkkttttttttttttttttttttttttttttttkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk...............",
        "...............khhhhttttttttttttttttttttttttttttttthhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkkkk...........",
        "...............khhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhkk.........",
        "...............khhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhk........",
        "..............khhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhffffffffffhhhhhhhhhhhhhk.......",
        "..............kHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHfHHHHHHHHfHHHHHHHHHHHHHHk......",
        "...............ksssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfsssssssssssssssk.....",
        "...............ksssssssssssssssssssssssswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsssfssssssssfsswwwwwwwwwsssssk....",
        "................kssssssssssssssssssssssswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsssfssssssssfsswwwwwwwwssssssk....",
        ".................ksssssssssssssssssssssswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsswwwsssfssssssssfsssssssssssssssssk...",
        ".................ksssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfsssssssssssssssssk...",
        "..................kssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfssssssssssssssssssk..",
        "...................ksssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfssssssssssssssssssk..",
        "....................kssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfssssssssssssssssssk..",
        ".....................ksssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfssssssssssssssssssk..",
        "......................krrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrfrrrrrrrrfrrrrrrrrrrrrrrrrrrk..",
        ".......................krrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrfrrrrrrrrfrrrrrrrrrrrrrrrrrrk..",
        "........................krrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrfrrrrrrrrfrrrrrrrrrrrrrrrrrrk..",
        ".........................kyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyfyyyyyyyyfyyyyyyyyyyyyyyyyyyk..",
        "..........................kksssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfsssssssssssssssssk...",
        "............................kssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssfssssssssfsssssssssssssssssk...",
        ".............................kbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbfbbbbbbbbfbbbbbbbbbbbbbbbbk....",
        "..............................kbbbbbbbbbbbbbkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkbbbbbbbbbbbbbbbbbbbbbffffffffffbbbbbbbbbbbbbbbbk....",
        "...............................kkbbbbbbbbbbbbbbbbbbbkkkkkkkkkkkkkkkkkkkkbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbk.....",
        ".................................kbbbbbbbbbbbbbbbbEEEEEeeeeeeeeeeeeeeeeebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbk......",
        "..................................kkllllllllllllllEEEEEeeeeeeeeeeeeeeeeellllllllllllllllllllllllllllllllllllllllllllllllllllk.......",
        "....................................klllllllllllllEEEEEeeeeeeeeeeeeeeeeelllllllllllllllllllllllllllllllllllllllllllllllllllk........",
        ".....................................kllllllllllllEEEEEeeeeeeeeeeeeeeeeelllllllllllllllllllllllllllllllllllllllllllllllllkk.........",
        "......................................kkllllllllllEEEEEeeeeeeeeeeeeeeeeellllllllllllllllllllllllllllllllllllllllllllkkkkk...........",
        "........................................kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk................",
        "....................................................kkkkkkkkkkkkkkkkkkkk............................................................",
        "....................................................................................................................................",
        "....................................................................................................................................",
        "....................................................................................................................................",
        "....................................................................................................................................",
    ]
    static let gearRuns: [WorldSideJetRun] = [
        WorldSideJetRun(y: 44, from: 116, to: 117, key: "k"),
        WorldSideJetRun(y: 45, from: 115, to: 117, key: "k"),
        WorldSideJetRun(y: 46, from: 59, to: 61, key: "k"),
        WorldSideJetRun(y: 46, from: 115, to: 117, key: "k"),
        WorldSideJetRun(y: 47, from: 58, to: 62, key: "k"),
        WorldSideJetRun(y: 47, from: 114, to: 118, key: "k"),
        WorldSideJetRun(y: 48, from: 58, to: 62, key: "k"),
        WorldSideJetRun(y: 48, from: 114, to: 118, key: "k"),
        WorldSideJetRun(y: 49, from: 59, to: 61, key: "k"),
        WorldSideJetRun(y: 49, from: 115, to: 117, key: "k"),
    ]
    static let openDoorRuns: [WorldSideJetRun] = [
        WorldSideJetRun(y: 20, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 21, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 22, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 23, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 24, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 25, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 26, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 27, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 28, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 29, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 30, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 31, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 32, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 33, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 34, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 35, from: 102, to: 109, key: "D"),
        WorldSideJetRun(y: 36, from: 102, to: 109, key: "D"),
    ]
}
