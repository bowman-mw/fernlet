import Foundation

/// The companion riding along in a little car, or pedalling a bike: the design page's `drawCar`
/// and `drawBike`, painted into a ``PixelGrid``. The companion's own colour shows through the
/// windscreen and on the saddle, so its state still reads while it travels.
nonisolated enum PixelRides {
    private static let outline: UInt32 = 0x4A2E1C

    /// A red car with the companion at the wheel.
    static func car(state: ShellCompanionState, step: Int) -> PixelGrid {
        var grid = PixelGrid()
        let bob = step % 2 == 1 ? 1 : 0
        let body = state.colorHex
        grid.fill(5, 7 - bob, 10, 1, outline)
        grid.fill(4, 8 - bob, 1, 5, outline)
        grid.fill(15, 8 - bob, 1, 5, outline)
        grid.fill(5, 8 - bob, 10, 5, 0xCFE7F0)
        grid.fill(8, 9 - bob, 4, 4, body)
        grid.fill(9, 8 - bob, 2, 1, body)
        grid.put(9, 10 - bob, PixelCompanionPainter.ink)
        grid.put(11, 10 - bob, PixelCompanionPainter.ink)
        grid.fill(10, 6 - bob, 1, 2, 0x4E7A48)
        grid.fill(11, 5 - bob, 2, 1, 0x72A364)
        grid.fill(1, 13 - bob, 18, 1, outline)
        grid.fill(0, 14 - bob, 1, 4, outline)
        grid.fill(19, 14 - bob, 1, 4, outline)
        grid.fill(1, 18 - bob, 18, 1, outline)
        grid.fill(1, 14 - bob, 18, 4, 0xC8553D)
        grid.fill(2, 14 - bob, 3, 1, 0xE0866E)
        grid.fill(17, 15 - bob, 2, 1, 0xF7D27A)
        grid.fill(1, 16 - bob, 18, 1, 0xA8432F)
        for x in [4, 13] {
            grid.fill(x, 17, 4, 4, outline)
            grid.fill(x + 1, 18, 2, 2, 0x9C9A92)
        }
        return grid
    }

    /// A teal bike with the companion on the saddle.
    static func bike(state: ShellCompanionState, step: Int) -> PixelGrid {
        var grid = PixelGrid()
        let bob = step % 2 == 1 ? 1 : 0
        let frame: UInt32 = 0x5FB8C9
        for wheel in [(5, 17), (15, 17)] {
            for dx in -3...3 {
                for dy in -3...3 where Int((Double(dx * dx + dy * dy)).squareRoot().rounded()) == 3 {
                    grid.put(wheel.0 + dx, wheel.1 + dy, outline)
                }
            }
            grid.put(wheel.0, wheel.1, 0x9C9A92)
        }
        let tubes = [(6, 16), (7, 15), (8, 14), (9, 13), (10, 13), (11, 13), (12, 13), (13, 14), (14, 15),
                     (10, 14), (11, 15), (12, 16), (9, 14), (8, 15), (7, 16)]
        for (x, y) in tubes { grid.put(x, y, frame) }
        grid.put(8, 12, outline); grid.put(9, 12, outline); grid.put(14, 11, outline)
        grid.put(14, 12, frame); grid.put(13, 13, frame)
        paintRider(&grid, state: state, centreRow: 8 - bob)
        return grid
    }

    /// The small round rider: body, outline, two eyes, a mouth and the sprout.
    private static func paintRider(_ grid: inout PixelGrid, state: ShellCompanionState, centreRow cy: Int) {
        let base = state.colorHex
        let dark = PixelCompanionPainter.mix(base, 0x1E1008, 0.55)
        func inside(_ px: Double, _ py: Double) -> Bool {
            let dx = (px + 0.5 - 10) / 3.6, dy = (py + 0.5 - Double(cy)) / 3.4
            return dx * dx + dy * dy <= 1
        }
        for py in (cy - 4)...(cy + 3) {
            for px in 6...13 where inside(Double(px), Double(py)) {
                let edge = !inside(Double(px - 1), Double(py)) || !inside(Double(px + 1), Double(py))
                    || !inside(Double(px), Double(py - 1)) || !inside(Double(px), Double(py + 1))
                grid.put(px, py, edge ? dark : base)
            }
        }
        grid.put(9, cy, PixelCompanionPainter.ink)
        grid.put(11, cy, PixelCompanionPainter.ink)
        grid.put(10, cy + 2, PixelCompanionPainter.ink)
        grid.put(10, cy - 4, 0x4E7A48)
        grid.put(11, cy - 5, 0x72A364)
        grid.put(12, cy - 5, 0x72A364)
    }
}
