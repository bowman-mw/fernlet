import Foundation

// Ferry and train paths (Docs/World-Transit-Paths-Exploration-2026-11-15.md §9, owner 2026-11-15): inside the
// frequent-roads build. A drive-speed trip is classified when it ends as road, rail or ferry; its cells are counted
// under that kind in `WornWayStore`, and the trip itself is kept as a `WornTrip` (forever, until forgotten or the map
// is cleared) so one ride can be changed or forgotten. Subway hops are a later build.

/// One reading of a trip, as the classifier sees it.
public nonisolated struct WornRideSample: Sendable, Equatable {
    /// Where.
    public let point: GeoPoint
    /// When.
    public let at: Date
    /// CoreLocation's speed in m/s, when it had one.
    public let speed: Double?
    /// Whether CarPlay or a known car's Bluetooth was connected (nil: unknown).
    public let inCar: Bool?

    /// A sample.
    public init(point: GeoPoint, at: Date, speed: Double?, inCar: Bool?) {
        self.point = point
        self.at = at
        self.speed = speed
        self.inCar = inCar
    }
}

/// What the phone knows about the ground under a trip: the bundled shore pack, the atlas's major roads, and the rail
/// pack's rail lines and ferry routes. The app conforms its loaded packs; tests use fakes.
public protocol WornTransitGeography: Sendable {
    /// Whether `point` is over water (the shore pack, falling back to the atlas).
    func isWater(_ point: GeoPoint) -> Bool
    /// Whether a major road (`WorldAtlas` roads) passes within `metres` of `point`.
    func isNearMajorRoad(_ point: GeoPoint, within metres: Double) -> Bool
    /// Whether a rail line (`WorldRail.pack`) passes within `metres` of `point`.
    func isNearRail(_ point: GeoPoint, within metres: Double) -> Bool
    /// Whether a bundled ferry route (Natural Earth, in `WorldRail.pack`) passes within `metres` of `point`.
    func isNearFerryRoute(_ point: GeoPoint, within metres: Double) -> Bool
}

/// How sure a classification is.
public nonisolated enum WornRideConfidence: UInt8, Sendable, Equatable {
    /// Sure: counted under the kind without asking.
    case sure = 1
    /// In the middle: counted under the guess, and Home may ask "Was that a train?" (owner's C1, at most once a day).
    case unsure = 2
}

/// A finished trip's classification.
public nonisolated struct WornRideVerdict: Sendable, Equatable {
    /// The kind its cells count under.
    public let kind: WornWayKind
    /// How sure.
    public let confidence: WornRideConfidence

    /// A verdict.
    public init(kind: WornWayKind, confidence: WornRideConfidence) {
        self.kind = kind
        self.confidence = confidence
    }

    /// A road, sure (the default: a car, a bus, anything not a ferry or a train).
    public static let road = WornRideVerdict(kind: .road, confidence: .sure)
}

/// A kept trip (owner's C2 note "Add a per trip record", kept forever, 2026-11-15): its kind, its day, when it started
/// and ended, and the way it went (thinned). Sealed in the World map vault; never synced, backed up, exported, given to
/// the AI or sent to friends. Its passes in the counter are the cells of ``line`` (``WornFootpaths/cells(along:)``),
/// so changing its kind moves exactly those.
public nonisolated struct WornTrip: Sendable, Equatable, Identifiable {
    /// The trip's own id.
    public let id: UUID
    /// What it was (changed by the person's answer or a tap on the path).
    public var kind: WornWayKind
    /// Whether the person said so (an answer or a correction): never asked about again.
    public var confirmed: Bool
    /// Whether the person said it was a train (Home's "Train" answer, or Train picked on the path's sheet). Only these
    /// rides teach the person's own rail lines (F13 3B, owner 2026-11-19); "Not sure" and the classifier's own sure
    /// guesses never do.
    public var markedTrain: Bool
    /// The ``WornDay`` it counts on (its start).
    public let day: UInt16
    /// When it started and ended.
    public let start: Date
    public let end: Date
    /// The way it went, thinned (at most ``maxLinePoints`` points).
    public let line: [GeoPoint]

    /// The most points a trip keeps.
    public static let maxLinePoints = 2_000

    /// A trip.
    public init(id: UUID = UUID(), kind: WornWayKind, confirmed: Bool, markedTrain: Bool = false, day: UInt16, start: Date,
                end: Date, line: [GeoPoint]) {
        self.id = id
        self.kind = kind
        self.confirmed = confirmed
        self.markedTrain = markedTrain
        self.day = day
        self.start = start
        self.end = end
        self.line = Array(line.prefix(Self.maxLinePoints))
    }
}
