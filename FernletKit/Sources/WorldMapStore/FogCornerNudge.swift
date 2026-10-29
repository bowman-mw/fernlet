import Foundation

/// One of the eight compass points a corner lies towards from home, for VoiceOver's "300 metres north-east"
/// (the screen formats the words). Frozen tokens.
public nonisolated enum CompassPoint: String, CaseIterable, Sendable {
    case n, ne, e, se, s, sw, w, nw
}

/// How far a corner's centre lies from home, and towards which compass point.
public nonisolated struct FogCornerBearing: Equatable, Sendable {
    /// The straight-line distance from home to the corner's centre, in metres.
    public var metres: Double
    /// The compass point nearest the bearing (45° sectors centred on north, north-east, …).
    public var compass: CompassPoint

    /// A bearing of `metres` towards `compass`.
    public init(metres: Double, compass: CompassPoint) {
        self.metres = metres
        self.compass = compass
    }
}

/// The weekly "one new corner" (round 7, spec §5, owner's option 1): once a week Sprout points at the
/// nearest still-fogged patch within about 1 km of home, a walk away. It is done when the person walks into
/// it (the fog keeper lifts it) and lapses at the end of the week. No streak, no penalty: nothing counts.
///
/// **Fogged** means not in the fog history (``FogCellStore/cells``), even where Home draws its 1 km home
/// circle clear (``MercatorHexGrid/disc(around:radius:)`` is drawn, never written).
///
/// **The rule** (``pick(home:revealed:weekStart:avoiding:)``). A candidate is a cell whose centre lies
/// between ``minimumMetres`` and ``searchMetres`` of home, that is not revealed, and at least
/// ``minimumFoggedNeighbours`` of whose six neighbours are not revealed either: a patch, not a one-cell gap.
/// The nearest ``bandMetres``-wide distance band wins, and within it a stable hash of the week and the cell
/// decides, so the same week always picks the same cell and weeks differ. Swift's `Hasher` is seeded per
/// process, so the hash is SplitMix64, the same on every launch.
///
/// **Weeks** run Monday 00:00 to Monday 00:00 in the calendar's time zone (ISO 8601's first weekday,
/// whatever the calendar's own first weekday is: ``weekStart(for:calendar:)``). A week's identity
/// (``weekIndex(of:)``) is its count of weeks since Monday 1970-01-05, rounded, so the same week keeps the
/// same pick in any time zone.
///
/// Bounded (Power of 10): one pick examines at most ``maxExamined`` cells of the home disc (at most 63 rings,
/// ``MercatorHexGrid/maxDiscRings``: north of about 60° the disc reaches less than 1 km), each with six
/// lookups. Pure: no state, no display strings.
public nonisolated enum FogCornerNudge {
    /// How far from home a corner may lie, in metres (spec: "about 1 km of home").
    public static let searchMetres = 1_000.0
    /// How near home a corner may lie, in metres: a walk, not the doorstep.
    public static let minimumMetres = 120.0
    /// The width of a distance band, in metres; the nearest band with a candidate wins.
    public static let bandMetres = 100.0
    /// How many of a candidate's six neighbours must be fogged too.
    public static let minimumFoggedNeighbours = 4
    /// The most disc cells one pick examines: the disc's full square at ``MercatorHexGrid/maxDiscRings``
    /// (129 × 129 = 16,641) rounded up.
    public static let maxExamined = 17_000
    /// Seconds in a week.
    static let weekSeconds = 7.0 * 24 * 60 * 60
    /// Monday 1970-01-05 00:00 UTC, the first ISO week start after the epoch.
    static let firstMonday = 4.0 * 24 * 60 * 60

    /// One candidate: a cell and how far its centre is from home.
    struct Candidate {
        /// The cell.
        let cell: HexCell
        /// Metres from home to its centre.
        let metres: Double
    }

    /// This week's corner near `home`: the nearest band's cell the week's hash picks, or nil when nothing
    /// within ``searchMetres`` is a fogged patch at least ``minimumMetres`` away. `avoiding` (last week's
    /// corner) is passed over when any other candidate exists, so a new week moves on when it can.
    public static func pick(home: GeoPoint, revealed: Set<HexCell>, weekStart: Date,
                            avoiding: HexCell? = nil) -> HexCell? {
        guard home.isValid, weekStart.timeIntervalSince1970.isFinite else { return nil }
        let all = candidates(home: home, revealed: revealed)
        let others = all.filter { $0.cell != avoiding }
        let pool = others.isEmpty ? all : others
        guard let nearest = pool.map({ band(of: $0.metres) }).min() else { return nil }
        let key = UInt64(bitPattern: weekIndex(of: weekStart))
        let ranked = pool.filter { band(of: $0.metres) == nearest }
            .map { (cell: $0.cell, rank: mix(key, UInt64(bitPattern: $0.cell.id))) }
        return ranked.min { ($0.rank, $0.cell) < ($1.rank, $1.cell) }?.cell
    }

    /// Whether `cell` is still a corner of `home`: its centre within ``searchMetres`` of it. A corner picked
    /// for a home the person since moved is picked again.
    public static func isCorner(_ cell: HexCell, of home: GeoPoint) -> Bool {
        guard home.isValid else { return false }
        return home.distance(to: MercatorHexGrid.centreGeo(of: cell)) <= searchMetres
    }

    /// Whether `cell` is a fogged patch in `revealed`: not revealed, and at least
    /// ``minimumFoggedNeighbours`` of its six neighbours not revealed either.
    public static func isFoggedPatch(_ cell: HexCell, in revealed: Set<HexCell>) -> Bool {
        guard !revealed.contains(cell) else { return false }
        let fogged = MercatorHexGrid.neighbours(of: cell).filter { !revealed.contains($0) }.count
        return fogged >= minimumFoggedNeighbours
    }

    /// The fogged patches within ``minimumMetres``...``searchMetres`` of `home`, from at most
    /// ``maxExamined`` disc cells (the loop's bound).
    static func candidates(home: GeoPoint, revealed: Set<HexCell>) -> [Candidate] {
        guard home.isValid else { return [] }
        var found: [Candidate] = []
        for cell in MercatorHexGrid.disc(around: home, radius: searchMetres).prefix(maxExamined)
        where isFoggedPatch(cell, in: revealed) {
            let metres = home.distance(to: MercatorHexGrid.centreGeo(of: cell))
            guard metres >= minimumMetres, metres <= searchMetres else { continue }
            found.append(Candidate(cell: cell, metres: metres))
        }
        return found
    }

    /// The distance band `metres` falls in: 0 for ``minimumMetres`` up to ``bandMetres`` beyond it, and so on.
    static func band(of metres: Double) -> Int {
        guard metres.isFinite, metres >= minimumMetres else { return 0 }
        return Int(((metres - minimumMetres) / bandMetres).rounded(.down))
    }

    /// The Monday 00:00 that starts the week holding `date`, in `calendar`'s time zone, whatever the
    /// calendar's own first weekday (ISO 8601 weeks). Falls back to the start of `date`'s day when the
    /// calendar has no answer.
    public static func weekStart(for date: Date, calendar: Calendar) -> Date {
        var iso = calendar
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4
        guard date.timeIntervalSince1970.isFinite,
              let interval = iso.dateInterval(of: .weekOfYear, for: date) else {
            return calendar.startOfDay(for: date)
        }
        return interval.start
    }

    /// The week a ``weekStart(for:calendar:)`` names: whole weeks since Monday 1970-01-05, rounded so any
    /// time zone's Monday midnight (UTC−12 to UTC+14) gives the same number. 0 for a date that is not finite.
    public static func weekIndex(of weekStart: Date) -> Int64 {
        let weeks = (weekStart.timeIntervalSince1970 - firstMonday) / weekSeconds
        guard weeks.isFinite, abs(weeks) < 1e12 else { return 0 }
        return Int64(weeks.rounded())
    }

    /// How far `cell`'s centre lies from `home`, and towards which compass point (0 m and north when they
    /// are under a metre apart, where a bearing means nothing).
    public static func bearingAndDistance(from home: GeoPoint, to cell: HexCell) -> FogCornerBearing {
        let step = MercatorHexGrid.centreGeo(of: cell).metres(from: home)
        let metres = (step.east * step.east + step.north * step.north).squareRoot()
        guard metres.isFinite, metres >= 1 else { return FogCornerBearing(metres: 0, compass: .n) }
        var degrees = atan2(step.east, step.north) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let sector = Int(((degrees + 22.5) / 45).rounded(.down)) % CompassPoint.allCases.count
        let points = CompassPoint.allCases
        guard points.indices.contains(sector) else { return FogCornerBearing(metres: metres, compass: .n) }
        return FogCornerBearing(metres: metres, compass: points[sector])
    }

    /// SplitMix64 of `key` and `value`: a stable, well-spread rank for the week's tie-break.
    static func mix(_ key: UInt64, _ value: UInt64) -> UInt64 {
        var z = key &* 0x9E37_79B9_7F4A_7C15 ^ value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
