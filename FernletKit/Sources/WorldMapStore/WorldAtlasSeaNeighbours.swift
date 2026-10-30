import Foundation

/// Which seas touch which, for the passport's sea inks (World-Exploration-Spec §3, `ex-pass-oceans` draft 2: each
/// sea takes its own bright blue "by a stable hash of the sea's id", keeping neighbouring seas apart).
extension WorldAtlas {
    /// The `OCEA` code of sea 0 of ``seas`` (codes 1–5 are the five oceans).
    static let firstSeaCode = 6

    /// For each sea, by its frozen token, the seas whose water touches it on the atlas grid: a cell of one beside a
    /// cell of the other, east–west (round the antimeridian) or north–south. Symmetric; a sea that touches no other
    /// sea maps to an empty set. Public data only (the bundled pack), so it may be computed anywhere.
    ///
    /// Bounded: one pass over the `OCEA` raster, at most ``AtlasGrid/cellCount`` cells with two comparisons each,
    /// then one pass over the seas. About 6.5 million cells at the shipped 0.1° grid, so a screen computes it once
    /// and keeps the answer.
    public func seaNeighbours() -> [String: Set<String>] {
        let count = seas.count, rows = grid.rows, cols = grid.cols
        guard count > 0, rows > 0, cols > 0, oceans.count == rows * cols else { return [:] }
        var touching = [Set<Int>](repeating: [], count: count)
        for row in 0..<rows {
            let base = row * cols
            for col in 0..<cols {
                guard let here = seaPosition(code: oceans[base + col], count: count) else { continue }
                if let east = seaPosition(code: oceans[base + (col + 1) % cols], count: count), east != here {
                    touching[here].insert(east)
                    touching[east].insert(here)
                }
                guard row + 1 < rows,
                      let south = seaPosition(code: oceans[base + cols + col], count: count), south != here else { continue }
                touching[here].insert(south)
                touching[south].insert(here)
            }
        }
        var result: [String: Set<String>] = [:]
        for (index, sea) in seas.enumerated() {
            result[sea.token, default: []].formUnion(touching[index].map { seas[$0].token })
        }
        return result
    }

    /// The index into ``seas`` an `OCEA` code names, or nil for land, an ocean or a code past the table.
    private func seaPosition(code: UInt8, count: Int) -> Int? {
        let index = Int(code) - Self.firstSeaCode
        return index >= 0 && index < count ? index : nil
    }
}
