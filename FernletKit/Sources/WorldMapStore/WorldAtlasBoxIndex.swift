import Foundation

/// A table of polygons (the countries, the states and provinces, the urban boundaries) bucketed by the
/// one-degree cells their boxes touch, built once when the atlas opens, so a point lookup tests the few
/// polygons listed in its own cell instead of every box in the table.
///
/// A polygon that holds a point has a box that holds it, and a box that holds a point touches the point's
/// cell (the cell is found by the same monotonic rule from the box's edges and from the point), so the cell's
/// list is a superset of the polygons that can answer. Each list keeps table order, so "the first polygon
/// that holds the point" is the same polygon the whole-table pass finds.
///
/// Bounded: ``rows`` × 2 ``rows`` cells; building is one pass over each box's cells to count and one to fill,
/// and the entries are capped at ``maxEntries`` (past that the index falls back to two cells, each polygon
/// listed at most twice). A table of more than ``maxPolygons`` keeps the fallback too.
nonisolated struct AtlasBoxIndex: Sendable {
    /// One-degree rows, north to south from 90°N.
    static let rows = 180
    /// The most entries the cells may hold together (the shipped pack's three tables need well under a
    /// million between them; the United States' and Russia's boxes span the globe).
    static let maxEntries = 4_000_000
    /// The most polygons a table may have for its indices to fit an entry.
    static let maxPolygons = Int(UInt16.max)

    /// Rows of cells (columns are twice as many).
    let rows: Int
    /// Where each cell's entries start in ``entries`` (`rows × 2 rows + 1` values, the last the total).
    let starts: [Int32]
    /// Each cell's polygons, as table indices in table order, cell after cell.
    let entries: [UInt16]

    /// The index of `polygons` (in table order).
    init(polygons: [AtlasPolygon]) {
        let made = Self.build(polygons, rows: Self.rows, cap: Self.maxEntries)
        let fallback = Self.build(polygons, rows: 1, cap: 2 * polygons.count)
        self = made ?? fallback ?? AtlasBoxIndex(rows: 1, starts: [0, 0, 0], entries: [])
    }

    /// An index with every field given.
    private init(rows: Int, starts: [Int32], entries: [UInt16]) {
        self.rows = rows
        self.starts = starts
        self.entries = entries
    }

    /// The table indices of the polygons whose boxes touch `point`'s cell, in table order (a superset of
    /// those whose boxes hold it); empty for an invalid point.
    func candidates(at point: GeoPoint) -> ArraySlice<UInt16> {
        guard point.isValid else { return [] }
        let x = point.longitude * AtlasPolygon.unitsPerDegree, y = point.latitude * AtlasPolygon.unitsPerDegree
        let cell = Self.row(of: y, rows: rows) * 2 * rows + Self.col(of: x, rows: rows)
        guard cell + 1 < starts.count else { return [] }
        let low = Int(starts[cell]), high = Int(starts[cell + 1])
        return low <= high && high <= entries.count ? entries[low..<high] : []
    }

    // MARK: Building

    /// The row of latitude `y` (1e-5 degrees) on a grid of `rows` rows, clamped; falls as `y` rises.
    private static func row(of y: Double, rows: Int) -> Int {
        let position = ((90 * AtlasPolygon.unitsPerDegree - y) / (180 * AtlasPolygon.unitsPerDegree / Double(rows)))
            .rounded(.down)
        guard position.isFinite, position > 0 else { return 0 }
        return position >= Double(rows - 1) ? rows - 1 : Int(position)
    }

    /// The column of longitude `x` (1e-5 degrees) on a grid of `rows` rows (2 `rows` columns), clamped; rises
    /// with `x`.
    private static func col(of x: Double, rows: Int) -> Int {
        let cols = 2 * rows
        let position = ((x + 180 * AtlasPolygon.unitsPerDegree) / (360 * AtlasPolygon.unitsPerDegree / Double(cols)))
            .rounded(.down)
        guard position.isFinite, position > 0 else { return 0 }
        return position >= Double(cols - 1) ? cols - 1 : Int(position)
    }

    /// The cells `polygon`'s box touches on a grid of `rows` rows: its rows and columns, north-west first.
    private static func cells(of polygon: AtlasPolygon, rows: Int) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>) {
        let north = row(of: Double(polygon.maxLat), rows: rows), south = row(of: Double(polygon.minLat), rows: rows)
        let west = col(of: Double(polygon.minLon), rows: rows), east = col(of: Double(polygon.maxLon), rows: rows)
        return (north...max(north, south), west...max(west, east))
    }

    /// The index of `polygons` on a grid of `rows` rows, or nil when it would hold more than `cap` entries or
    /// the table is too long for an entry.
    private static func build(_ polygons: [AtlasPolygon], rows: Int, cap: Int) -> AtlasBoxIndex? {
        guard rows >= 1, polygons.count <= maxPolygons else { return nil }
        let cellCount = rows * 2 * rows
        var tally = [Int](repeating: 0, count: cellCount), total = 0
        // Bounded: each polygon's box cells (at most cellCount each); the running total checked against cap.
        for polygon in polygons {
            let box = cells(of: polygon, rows: rows)
            total += box.rows.count * box.cols.count
            guard total <= cap else { return nil }
            for row in box.rows { for col in box.cols { tally[row * 2 * rows + col] += 1 } }
        }
        guard total < Int(Int32.max) else { return nil }
        var starts = [Int32](repeating: 0, count: cellCount + 1), running = 0
        // Bounded: one step per cell.
        for cell in 0..<cellCount {
            starts[cell] = Int32(running)
            running += tally[cell]
        }
        starts[cellCount] = Int32(running)
        var cursor = starts.map(Int.init), entries = [UInt16](repeating: 0, count: running)
        // Bounded: the same box cells again, `total` entries in all.
        for (index, polygon) in polygons.enumerated() {
            let box = cells(of: polygon, rows: rows)
            for row in box.rows {
                for col in box.cols {
                    entries[cursor[row * 2 * rows + col]] = UInt16(index)
                    cursor[row * 2 * rows + col] += 1
                }
            }
        }
        return AtlasBoxIndex(rows: rows, starts: starts, entries: entries)
    }
}
