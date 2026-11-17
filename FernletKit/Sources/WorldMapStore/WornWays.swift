import Foundation

// Worn paths and frequent roads (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §8, owner 2026-11-15):
// footpaths come from the saved walk, run and ride lines (`WorldRouteStore`, dated by each workout's
// `completedAt`); roads, rail and ferry ways come from the sealed per-cell counter (`WornWayStore`). Both use the
// same tally: a count of trips and the day of the last one, which climbs through three levels and fades one level
// for every 30 days without a trip, down to an "abandoned" look that never disappears.

/// What travelled along a counted way. The counter is keyed by (cell, kind) so a level crossing, a road beside a
/// railway or a ferry dock can hold two kinds (World-Transit-Paths-Exploration §6). Only ``road`` is written today;
/// ``rail`` and ``ferry`` are reserved in the file format for the train and ferry build.
public nonisolated enum WornWayKind: UInt8, Sendable, CaseIterable, Hashable {
    /// A drive, a bus, or (until transit detection lands) a train or ferry counted as a drive.
    case road = 1
    /// A train (reserved).
    case rail = 2
    /// A ferry or any boat (reserved).
    case ferry = 3
}

/// How worn a path or road looks. ``abandoned`` is the fourth look (owner's call 8): a way that faded below level 1.
public nonisolated enum WornLevel: Int, Sendable, Comparable, CaseIterable, Hashable {
    /// Faded below level 1: faint and broken, never removed.
    case abandoned = 0
    /// Trodden (paths) or lightly used (roads).
    case one = 1
    /// Worn.
    case two = 2
    /// Well worn.
    case three = 3

    public static func < (lhs: WornLevel, rhs: WornLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The trip counts that reach levels 1, 2 and 3 (owner's call 2: the draft numbers).
public nonisolated struct WornThresholds: Sendable, Equatable {
    /// The counts for levels 1, 2 and 3, rising.
    public let counts: (UInt16, UInt16, UInt16)

    /// Walks, runs and rides: 2 / 5 / 15 trips.
    public static let footpath = WornThresholds(counts: (2, 5, 15))
    /// Drives (and later rail and ferry): 3 / 10 / 30 trips.
    public static let road = WornThresholds(counts: (3, 10, 30))

    /// The thresholds for a counted `kind` (rail and ferry follow roads, World-Transit-Paths-Exploration §3).
    public static func forKind(_ kind: WornWayKind) -> WornThresholds { .road }

    /// The lowest count at `level` (level 1 for ``WornLevel/abandoned``).
    public func minimumCount(for level: WornLevel) -> UInt16 {
        switch level {
        case .abandoned, .one: counts.0
        case .two: counts.1
        case .three: counts.2
        }
    }

    /// The level a fresh `count` reaches, or nil below level 1.
    public func level(forCount count: UInt16) -> WornLevel? {
        if count >= counts.2 { return .three }
        if count >= counts.1 { return .two }
        if count >= counts.0 { return .one }
        return nil
    }

    public static func == (lhs: WornThresholds, rhs: WornThresholds) -> Bool {
        lhs.counts == rhs.counts
    }
}

/// Day numbers for the tally: whole days since 2020-01-01 in the person's calendar, fitting a `UInt16` until 2199.
public nonisolated enum WornDay {
    /// Days without a trip that drop a way one level (owner's call 8).
    public static let fadeDays = 30

    /// The day number of `date` in `calendar` (0 before 2020, clamped to `UInt16.max`).
    public static func number(for date: Date, calendar: Calendar = .current) -> UInt16 {
        let epoch = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 1_577_836_800)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: epoch), to: calendar.startOfDay(for: date)).day ?? 0
        return UInt16(clamping: max(0, days))
    }
}

/// One way's tally: how many trips, and the day of the last. Five bytes on disk with its kind (World-Transit §6).
///
/// The rules (owner 2026-11-15, call 8):
/// - each trip adds one; the count sets the level by ``WornThresholds``;
/// - every ``WornDay/fadeDays`` days without a trip drops one level; below level 1 the way is ``WornLevel/abandoned``;
/// - a trip on a faded way first settles the count to its faded level's lowest count, so it climbs again from
///   there; the first trip back on an abandoned way brings it to exactly level 1;
/// - a count that never reached level 1 and sat idle a full fade period starts again from zero.
public nonisolated struct WornTally: Sendable, Equatable, Hashable {
    /// Trips counted (capped at `UInt16.max`).
    public private(set) var count: UInt16
    /// The day (``WornDay``) of the last trip.
    public private(set) var lastDay: UInt16

    /// A tally of `count` trips, the last on `lastDay`.
    public init(count: UInt16, lastDay: UInt16) {
        self.count = count
        self.lastDay = lastDay
    }

    /// Levels lost to idleness by `today`.
    private func fadedSteps(today: UInt16) -> Int {
        today > lastDay ? Int(today - lastDay) / WornDay.fadeDays : 0
    }

    /// How the way looks on `today`: nil when it never reached level 1.
    public func level(today: UInt16, thresholds: WornThresholds) -> WornLevel? {
        guard let reached = thresholds.level(forCount: count) else { return nil }
        let faded = reached.rawValue - fadedSteps(today: today)
        return faded >= WornLevel.one.rawValue ? WornLevel(rawValue: faded) : .abandoned
    }

    /// Counts one trip on `day` (a day before the last trip, from an older route file, only adds to the count).
    public mutating func pass(on day: UInt16, thresholds: WornThresholds) {
        if day > lastDay {
            switch level(today: day, thresholds: thresholds) {
            case nil:
                if fadedSteps(today: day) >= 1 { count = 0 }
            case .abandoned?:
                count = thresholds.minimumCount(for: .one) - 1
            case let faded?:
                count = min(count, thresholds.minimumCount(for: faded))
            }
            lastDay = day
        }
        count = count == UInt16.max ? count : count + 1
    }

    /// A first trip on `day`.
    public static func first(on day: UInt16) -> WornTally { WornTally(count: 1, lastDay: day) }
}

/// A key in the counter: a cell and what travelled through it.
public nonisolated struct WornWayKey: Hashable, Sendable, Comparable {
    /// The hex cell.
    public let cell: HexCell
    /// What travelled through it.
    public let kind: WornWayKind

    /// The key for `cell` and `kind`.
    public init(cell: HexCell, kind: WornWayKind) {
        self.cell = cell
        self.kind = kind
    }

    public static func < (lhs: WornWayKey, rhs: WornWayKey) -> Bool {
        lhs.cell == rhs.cell ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.cell < rhs.cell
    }
}

/// Footpath tallies from the saved lines, derived at draw time (nothing stored, option A).
public nonisolated enum WornFootpaths {
    /// The most lines read (the route store's cap, ``WorldRouteStore/maxRoutes``).
    public static let maxRoutes = 2_000
    /// The most points read from one line.
    public static let maxPointsPerRoute = 50_000
    /// How far apart a line is sampled, in metres: under a hex's 17.5 m radius, so no cell it crosses is skipped.
    public static let sampleStep = 8.0

    /// The cells `line` passes through, each once (one trip per line), in no order. Bounded: at most
    /// ``maxPointsPerRoute`` points and a fixed number of samples per segment.
    public static func cells(along line: [GeoPoint]) -> Set<HexCell> {
        var cells = Set<HexCell>()
        guard let first = line.first else { return cells }
        cells.insert(MercatorHexGrid.cell(containing: first))
        var previous = first
        for point in line.prefix(maxPointsPerRoute).dropFirst() {
            let steps = min(256, max(1, Int((previous.distance(to: point) / sampleStep).rounded(.up))))
            for step in 1...steps {
                cells.insert(MercatorHexGrid.cell(containing: previous.lerp(to: point, Double(step) / Double(steps))))
            }
            previous = point
        }
        return cells
    }

    /// Each cell's tally from `routes` (a day and a line each), replayed oldest first so fading and revival apply
    /// in order. Bounded: at most ``maxRoutes`` routes.
    public static func tallies(routes: [(day: UInt16, line: [GeoPoint])]) -> [HexCell: WornTally] {
        var tallies: [HexCell: WornTally] = [:]
        for route in routes.prefix(maxRoutes).sorted(by: { $0.day < $1.day }) {
            for cell in cells(along: route.line) {
                if var tally = tallies[cell] {
                    tally.pass(on: route.day, thresholds: .footpath)
                    tallies[cell] = tally
                } else {
                    tallies[cell] = .first(on: route.day)
                }
            }
        }
        return tallies
    }
}

/// Long runs of frequent road cells, for the passport's Your world (owner's call 4: roads show there when "long
/// enough", 2 km of connected frequent cells, confirmed 2026-11-15).
public nonisolated enum WornWayRuns {
    /// The shortest run Your world draws, in metres.
    public static let minimumRunMetres = 2_000.0
    /// The most cells looked at.
    public static let maxCells = 250_000

    /// The groups of `cells` that touch (hex neighbours) whose length, the longest straight span between two of its
    /// cell centres, is at least `minimumMetres`. Bounded: each cell is visited once, at most ``maxCells``.
    public static func longRuns(_ cells: Set<HexCell>, minimumMetres: Double = minimumRunMetres) -> [Set<HexCell>] {
        var unvisited = Set(cells.prefix(maxCells))
        var runs: [Set<HexCell>] = []
        while let seed = unvisited.popFirst() {
            var run: Set<HexCell> = [seed]
            var queue = [seed]
            while let cell = queue.popLast() {
                for neighbour in MercatorHexGrid.neighbours(of: cell) where unvisited.contains(neighbour) {
                    unvisited.remove(neighbour)
                    run.insert(neighbour)
                    queue.append(neighbour)
                }
            }
            if span(of: run) >= minimumMetres { runs.append(run) }
        }
        return runs
    }

    /// The run's length: the distance between the two cell centres furthest apart along its bounding box's long
    /// side (a fair stand-in for a road's length, cheap for long runs).
    static func span(of run: Set<HexCell>) -> Double {
        guard run.count > 1 else { return 0 }
        let points = run.map { MercatorHexGrid.centreGeo(of: $0) }
        guard let west = points.min(by: { $0.longitude < $1.longitude }), let east = points.max(by: { $0.longitude < $1.longitude }),
              let south = points.min(by: { $0.latitude < $1.latitude }), let north = points.max(by: { $0.latitude < $1.latitude })
        else { return 0 }
        return max(west.distance(to: east), south.distance(to: north))
    }
}
