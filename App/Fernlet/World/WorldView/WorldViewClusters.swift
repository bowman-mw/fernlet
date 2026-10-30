import Foundation
import WorldMapStore

/// One discovered city on the world view: its token, display name, size and Mercator position.
nonisolated struct WorldViewCityPin: Hashable, Sendable {
    /// The city's frozen token (``AtlasCity/token``).
    let token: String
    /// Its name in the app's language.
    let name: String
    /// Its size class.
    let sizeClass: WorldCitySizeClass
    /// Its population, for the biggest of a cluster.
    let population: Int
    /// Its Mercator position (`x` in `0..<1`).
    let x: Double, y: Double

    /// A pin with every field given.
    init(token: String, name: String, sizeClass: WorldCitySizeClass, population: Int, x: Double, y: Double) {
        self.token = token
        self.name = name
        self.sizeClass = sizeClass
        self.population = population
        self.x = x
        self.y = y
    }

    /// The pin of `city`, named in `language`.
    init(city: AtlasCity, name: String) {
        let unit = WebMercator.unit(city.point)
        self.init(token: city.token, name: name, sizeClass: WorldCitySizeClass(city: city), population: city.population,
                  x: WorldViewCamera.wrap(unit.x), y: unit.y)
    }

    /// Whether this pin is bigger than `other`: the bigger class, then more people, then the token (so the
    /// order never depends on the input's).
    func isBigger(than other: WorldViewCityPin) -> Bool {
        if sizeClass != other.sizeClass { return sizeClass > other.sizeClass }
        if population != other.population { return population > other.population }
        return token < other.token
    }
}

/// Cities closer than ``radius`` points on screen share one marker, named for the biggest ("Seattle +2"),
/// until you zoom in (World-Exploration-Spec §2, the mockup's `world()` grouping). The marker stands at the
/// biggest city; the rest join the first marker within reach, biggest first.
nonisolated struct WorldViewCluster: Hashable, Sendable {
    /// How near two cities must be on screen to share a marker, in points.
    static let radius = 30.0
    /// The most cities one clustering reads (the passport's own cap on cities).
    static let maxPins = 20_000

    /// The biggest city: the marker stands on it and is named for it.
    let anchor: WorldViewCityPin
    /// Every city in the marker, the biggest first.
    let members: [WorldViewCityPin]

    /// How many more cities share the marker (the "+N").
    var others: Int { max(members.count - 1, 0) }

    /// The markers for `pins` at `level`: biggest first, each pin joining the first marker whose anchor lies
    /// within ``radius`` points (the short way round the world), else starting its own. Bounded: at most
    /// ``maxPins`` pins, each comparing only the markers in the 3 × 3 buckets of `radius` around it.
    static func clusters(of pins: [WorldViewCityPin], at level: AtlasZoomLevel) -> [WorldViewCluster] {
        let scale = level.pointsPerMercatorUnit
        guard scale > 0, !pins.isEmpty else { return [] }
        let ordered = pins.prefix(maxPins).sorted { $0.isBigger(than: $1) }
        let columns = max(Int((scale / radius).rounded(.up)), 1)
        var anchors: [WorldViewCityPin] = [], members: [[WorldViewCityPin]] = []
        var buckets: [Int: [Int]] = [:]
        for pin in ordered {
            let col = Int((pin.x * scale / radius).rounded(.down)), row = Int((pin.y * scale / radius).rounded(.down))
            if let found = nearest(pin, col: col, row: row, columns: columns, buckets: buckets, anchors: anchors,
                                   scale: scale) {
                members[found].append(pin)
                continue
            }
            buckets[bucketKey(col: col, row: row, columns: columns), default: []].append(anchors.count)
            anchors.append(pin)
            members.append([pin])
        }
        return zip(anchors, members).map { WorldViewCluster(anchor: $0, members: $1) }
    }

    /// The first marker (in the order they were made) whose anchor lies within ``radius`` of `pin`.
    private static func nearest(_ pin: WorldViewCityPin, col: Int, row: Int, columns: Int, buckets: [Int: [Int]],
                                anchors: [WorldViewCityPin], scale: Double) -> Int? {
        var best: Int?
        // Bounded: nine buckets.
        for dRow in -1...1 {
            for dCol in -1...1 {
                for index in buckets[bucketKey(col: col + dCol, row: row + dRow, columns: columns)] ?? [] {
                    guard anchors.indices.contains(index), index < (best ?? .max) else { continue }
                    let anchor = anchors[index]
                    let dx = WorldViewCamera.wrappedDelta(pin.x - anchor.x) * scale, dy = (pin.y - anchor.y) * scale
                    if (dx * dx + dy * dy).squareRoot() < radius { best = index }
                }
            }
        }
        return best
    }

    /// A bucket's key, its column wrapped round the world.
    private static func bucketKey(col: Int, row: Int, columns: Int) -> Int {
        let wrapped = ((col % columns) + columns) % columns
        return row * columns + wrapped
    }
}
