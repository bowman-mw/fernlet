import Foundation
import Testing
import WorldMapStore

/// Round 7, idea 7 ("odd hidden tiles"): a single fogged cell whose six neighbours are all revealed
/// closes; anything less enclosed, or bigger than one cell, never does; the passes stay bounded.
struct FogGapCloserTests {
    private static let portland = GeoPoint(45.5205, -122.6255)
    private static let hole = HexCell(q: 0, r: 0)
    private static var ring: [HexCell] { MercatorHexGrid.neighbours(of: hole) }

    /// Every cell within `rings` steps of `centre` (a solid hexagon of revealed ground).
    private static func patch(around centre: HexCell, rings: Int) -> Set<HexCell> {
        var cells = Set<HexCell>()
        for dq in -rings...rings {
            for dr in max(-rings, -dq - rings)...min(rings, -dq + rings) {
                cells.insert(HexCell(q: centre.q + dq, r: centre.r + dr))
            }
        }
        return cells
    }

    // MARK: What closes

    /// A ring of six around one hidden cell closes it, from any of the six as the cell just lifted.
    @Test func aRingOfSixClosesTheCellInside() {
        let revealed = Set(Self.ring)
        #expect(FogGapCloser.isEnclosed(Self.hole, in: revealed))
        for lifted in Self.ring {
            #expect(FogGapCloser.closing(around: [lifted], in: revealed) == [Self.hole])
        }
        #expect(FogGapCloser.sweep(revealed: revealed) == FogGapScan(gaps: [Self.hole], examined: 13, hitCap: false))
    }

    /// Five of six is not an enclosure, whichever one is missing.
    @Test func fiveOfSixDoesNotClose() {
        for missing in Self.ring {
            let revealed = Set(Self.ring.filter { $0 != missing })
            #expect(!FogGapCloser.isEnclosed(Self.hole, in: revealed))
            #expect(FogGapCloser.closing(around: Array(revealed), in: revealed).isEmpty)
            #expect(FogGapCloser.sweep(revealed: revealed).gaps.isEmpty)
        }
    }

    /// Two hidden cells side by side inside revealed ground stay hidden: only single cells close.
    @Test func twoAdjacentHiddenCellsDoNotClose() {
        let second = HexCell(q: 1, r: 0)
        let revealed = Self.patch(around: Self.hole, rings: 4).subtracting([Self.hole, second])
        #expect(!FogGapCloser.isEnclosed(Self.hole, in: revealed))
        #expect(!FogGapCloser.isEnclosed(second, in: revealed))
        #expect(FogGapCloser.closing(around: Array(revealed).sorted(), in: revealed).isEmpty)
        #expect(FogGapCloser.sweep(revealed: revealed).gaps.isEmpty)
    }

    /// A revealed cell is never "enclosed", and a cell the history does not hold is never read as lifted.
    @Test func revealedCellsAndUnheldLiftsAreIgnored() {
        let revealed = Set(Self.ring).union([Self.hole])
        #expect(!FogGapCloser.isEnclosed(Self.hole, in: revealed))
        let refused = HexCell(q: 2, r: 0)
        #expect(FogGapCloser.closingScan(around: [refused], in: Set(Self.ring)).examined == 0, "a refused lift reads nothing")
        #expect(FogGapCloser.closing(around: [], in: revealed).isEmpty)
        #expect(FogGapCloser.closing(around: Self.ring, in: []).isEmpty)
    }

    // MARK: Bounds

    /// Only the hidden neighbours of the cells just lifted are examined: an enclosed hole far away waits
    /// for the sweep.
    @Test func cellsFarAwayAreNotExamined() {
        let farHole = HexCell(q: 1_000, r: 1_000)
        let near = Self.patch(around: HexCell(q: -50, r: 0), rings: 2)
        let revealed = near.union(MercatorHexGrid.neighbours(of: farHole))
        let scan = FogGapCloser.closingScan(around: Array(near).sorted(), in: revealed)
        #expect(scan.gaps.isEmpty)
        #expect(scan.examined == 18, "only the ring just outside the lifted patch")
        #expect(!scan.hitCap)
        #expect(FogGapCloser.sweep(revealed: revealed).gaps == [farHole])
    }

    /// A pass reads at most 2,000 lifted cells (so examines at most 12,000); the rest set hitCap.
    @Test func theClosingPassCapHolds() {
        #expect(FogGapCloser.maxExaminedPerPass == 6 * FogGapCloser.maxLiftedPerPass)
        let filler = (0..<FogGapCloser.maxLiftedPerPass).map { HexCell(q: $0, r: 500) }
        let revealed = Set(Self.ring).union(filler)
        let late = FogGapCloser.closingScan(around: filler + [Self.ring[0]], in: revealed)
        #expect(late.gaps.isEmpty, "the ring cell past the cap is never read")
        #expect(late.hitCap)
        #expect(late.examined <= FogGapCloser.maxExaminedPerPass)
        let early = FogGapCloser.closingScan(around: [Self.ring[0]] + filler, in: revealed)
        #expect(early.gaps == [Self.hole])
        #expect(early.hitCap)
    }

    /// The sweep stops at its limit and says so; a limit is clamped, and a full sweep finds every hole.
    @Test func theSweepCapHolds() {
        let holes = [HexCell(q: 0, r: 0), HexCell(q: 10, r: 0), HexCell(q: 0, r: 10)]
        let revealed = Set(holes.flatMap { MercatorHexGrid.neighbours(of: $0) })
        let full = FogGapCloser.sweep(revealed: revealed)
        #expect(full.gaps == holes.sorted())
        #expect(!full.hitCap)
        let one = FogGapCloser.sweep(revealed: revealed, limit: 1)
        #expect(one.examined == 1 && one.hitCap && one.gaps.count <= 1)
        #expect(FogGapCloser.sweep(revealed: revealed, limit: 0) == FogGapScan(gaps: [], examined: 0, hitCap: true))
        #expect(FogGapCloser.sweep(revealed: revealed, limit: -5).hitCap)
        #expect(FogGapCloser.sweep(revealed: revealed, limit: .max) == full)
        #expect(FogGapCloser.sweep(revealed: []) == FogGapScan(gaps: [], examined: 0, hitCap: false))
    }

    // MARK: Real ground

    /// Two overlapping 50 m discs in Portland: intact, nothing closes; with one interior cell missing
    /// (hidden in the first disc, next to the second), lifting the second disc closes exactly that cell.
    @Test func twoOverlappingDiscsInPortlandCloseTheOneHole() throws {
        let first = MercatorHexGrid.cells(around: Self.portland, within: 50)
        let second = MercatorHexGrid.cells(around: Self.portland.offset(east: 40, north: 0), within: 50)
        let secondSet = Set(second)
        let union = Set(first).union(second)
        #expect(FogGapCloser.closing(around: second, in: union).isEmpty)
        #expect(FogGapCloser.sweep(revealed: union).gaps.isEmpty)
        let interior = first.filter { cell in
            let around = MercatorHexGrid.neighbours(of: cell)
            return !secondSet.contains(cell) && around.allSatisfy(union.contains) && around.contains(where: secondSet.contains)
        }
        let hole = try #require(interior.sorted().first)
        var revealed = union
        revealed.remove(hole)
        #expect(FogGapCloser.closing(around: second, in: revealed) == [hole])
        #expect(FogGapCloser.closing(around: [], in: revealed).isEmpty)
        #expect(FogGapCloser.sweep(revealed: revealed).gaps == [hole])
        revealed.insert(hole)
        #expect(FogGapCloser.sweep(revealed: revealed).gaps.isEmpty, "one round: filling encloses nothing new")
    }
}
