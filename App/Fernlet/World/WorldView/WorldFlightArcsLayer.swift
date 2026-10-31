import FernletUI
import SwiftUI
import WorldMapStore

/// Your world's flight words (World-Airports-Spec §8 and §12; the mockup's `arc()` and `worldArcs()` give the
/// Spanish). Display text only: the IATA codes and the routes' IDs are tokens and stay as they are.
nonisolated enum WorldFlightCopy {
    /// "1 flight" / "53 flights".
    static func flights(_ count: Int) -> String {
        count == 1
            ? String(localized: LocalizedStringResource("worldView.flights.count.one", defaultValue: "1 flight",
                                                        comment: "Your world: one flight (on the plate, an arc's card and its VoiceOver name)"))
            : String(localized: LocalizedStringResource("worldView.flights.count.other", defaultValue: "\(count) flights",
                                                        comment: "Your world: the number of flights (never one), on the plate, an arc's card and its VoiceOver name"))
    }

    /// "1 airport" / "6 airports".
    static func airports(_ count: Int) -> String {
        count == 1
            ? String(localized: LocalizedStringResource("worldView.airports.count.one", defaultValue: "1 airport",
                                                        comment: "Your world plate: one airport found"))
            : String(localized: LocalizedStringResource("worldView.airports.count.other", defaultValue: "\(count) airports",
                                                        comment: "Your world plate: the number of airports found (never one)"))
    }

    /// The plate's second line: "6 airports · 53 flights".
    static func plate(airports: Int, flights: Int) -> String {
        let airportWords = Self.airports(airports), flightWords = Self.flights(flights)
        return String(localized: LocalizedStringResource("worldView.plate.flights", defaultValue: "\(airportWords) · \(flightWords)",
                                                         comment: "Your world plate: the airports found, then every flight flown, e.g. 6 airports · 53 flights"))
    }

    /// A distance on an arc's card: "3,620 km" ("3.620 km" in Spanish), to the nearest 10 km.
    static func distance(_ kilometres: Double) -> String {
        let number = WorldFlightArcs.groupedKilometres(kilometres, spanish: WorldViewNames.language == .spanish)
        return String(localized: LocalizedStringResource("worldView.flights.km", defaultValue: "\(number) km",
                                                         comment: "Your world: a flight route's great-circle distance in kilometres, e.g. 3,620 km"))
    }

    /// An arc's card line: "Portland – Mexico City · 2 flights · 3,620 km".
    static func card(_ arc: WorldFlightArc) -> String {
        let from = arc.fromName, to = arc.toName, count = flights(arc.flights), length = distance(arc.kilometres)
        return String(localized: LocalizedStringResource("worldView.flights.card", defaultValue: "\(from) – \(to) · \(count) · \(length)",
                                                         comment: "Your world: the card of a tapped flight arc: the two cities, the flights both ways, the distance"))
    }

    /// An arc's VoiceOver name: "Flights, Portland and Mexico City, 2 flights", plus ", imported" when every
    /// flight on it was imported.
    static func spoken(_ arc: WorldFlightArc) -> String {
        let from = arc.fromName, to = arc.toName, count = flights(arc.flights)
        guard arc.allImported else {
            return String(localized: LocalizedStringResource("worldView.flights.arc.spoken", defaultValue: "Flights, \(from) and \(to), \(count)",
                                                             comment: "Your world: VoiceOver name of a flight arc, a button that opens its card"))
        }
        return String(localized: LocalizedStringResource("worldView.flights.arc.spoken.imported",
                                                         defaultValue: "Flights, \(from) and \(to), \(count), imported",
                                                         comment: "Your world: VoiceOver name of a flight arc whose flights were all imported (Flighty or the calendar)"))
    }

    /// A found airport's VoiceOver name: "Portland airport, PDX".
    static func foundSpoken(_ mark: WorldFlightAirportMark) -> String {
        let name = mark.name, code = mark.code
        return String(localized: LocalizedStringResource("worldView.airport.found.spoken", defaultValue: "\(name) airport, \(code)",
                                                         comment: "Your world: VoiceOver name of a found airport's marker: its city, then its code"))
    }

    /// A named ring's VoiceOver name: "HNL, flown through".
    static func ringSpoken(_ mark: WorldFlightAirportMark) -> String {
        let code = mark.code
        return String(localized: LocalizedStringResource("worldView.airport.ring.spoken", defaultValue: "\(code), flown through",
                                                         comment: "Your world: VoiceOver name of a small ring for an airport only flown through, shown when zoomed in or tapped"))
    }
}

/// The arcs' colours (`--ap-arc`, `--ap-arc-edge`): a bark ink line on a cream edge by day, cream on charcoal
/// at night, and the edge's opacity and the two widths (spec §8: a 5-pt edge under a 2.6-pt dot line).
nonisolated enum WorldFlightInk {
    /// The dot line's ink.
    static func line(dark: Bool) -> UInt32 { dark ? 0xFFF1CF : 0x4A2E1C }
    /// The edge under it.
    static func edge(dark: Bool) -> UInt32 { dark ? 0x1D2228 : 0xFFF6E2 }
    /// The edge's opacity.
    static let edgeOpacity = 0.55
    /// The edge's width.
    static let edgeWidth = 5.0
    /// The dot line's width.
    static let lineWidth = 2.6
    /// The dot line's dash: a dot every 6 pt.
    static let dash: [CGFloat] = [0.1, 6]
    /// How far (points) a tap may land from an arc and still pick it.
    static let tapReach = 16.0
    /// How far (points) a tap may land from a ring and still name it.
    static let ringReach = 14.0
    /// Points past the screen's edges an arc piece may lie and still be drawn.
    static let cullMargin = 24.0
}

/// What the person tapped on the flights layer: an arc (its card shows) or a ring (its code shows).
nonisolated struct WorldFlightPick: Equatable, Sendable {
    /// The tapped arc's route ID.
    var arc: String?
    /// The tapped ring's code.
    var ring: String?

    /// What a tap at `point` picks: a ring within reach (toggling its name), else an arc within reach, else
    /// nothing (the card closes).
    static func at(_ point: CGPoint, camera: WorldViewCamera, flights: WorldFlightMap, current: WorldFlightPick) -> WorldFlightPick {
        // Bounded: the rings (WorldFlightArcs.maxMarks).
        let ring = flights.rings.first { mark in
            let spot = camera.screenPoint(x: Double(mark.mercator.x), y: Double(mark.mercator.y))
            return hypot(Double(spot.x - point.x), Double(spot.y - point.y)) <= WorldFlightInk.ringReach
        }
        if let ring {
            return WorldFlightPick(arc: current.arc, ring: current.ring == ring.code ? nil : ring.code)
        }
        let drawn = WorldFlightArcs.projected(flights.arcs, camera: camera, margin: WorldFlightInk.cullMargin)
        let arc = WorldFlightArcs.arc(at: point, among: drawn, reach: WorldFlightInk.tapReach)
        return WorldFlightPick(arc: arc, ring: nil)
    }
}

/// The flights' dotted great-circle arcs on Your world (spec §8, screen 22): every route one arc, a 5-pt edge
/// at 55 % under a 2.6-pt dot line (dash 0.1 6, round caps), all in two strokes so crossings never darken; the
/// picked arc's edge is drawn solid and wider. Cut where an arc wraps round the world, and only the pieces on
/// screen are drawn. Decoration to VoiceOver (``WorldFlightArcButtons`` carries each arc).
struct WorldFlightArcsLayer: View {
    let camera: WorldViewCamera
    let arcs: [WorldFlightArc]
    /// The picked arc's route ID.
    let picked: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Canvas(rendersAsynchronously: false) { context, _ in
            let drawn = WorldFlightArcs.projected(arcs, camera: camera, margin: WorldFlightInk.cullMargin)
            var all = Path(), chosen = Path()
            // Bounded: the arcs drawn (WorldFlightArcs.maxRoutes), pointsPerArc points each.
            for arc in drawn {
                for piece in arc.pieces {
                    all.addLines(piece)
                    if arc.id == picked { chosen.addLines(piece) }
                }
            }
            let edge = WorldPalette.rgb(WorldFlightInk.edge(dark: dark)), ink = WorldPalette.rgb(WorldFlightInk.line(dark: dark))
            let round = { (width: Double) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
            context.stroke(all, with: .color(edge.opacity(WorldFlightInk.edgeOpacity)), style: round(WorldFlightInk.edgeWidth))
            context.stroke(chosen, with: .color(edge), style: round(WorldFlightInk.edgeWidth + 3))
            context.stroke(all, with: .color(ink), style: StrokeStyle(lineWidth: WorldFlightInk.lineWidth, lineCap: .round,
                                                                       lineJoin: .round, dash: WorldFlightInk.dash))
        }
        .frame(width: camera.size.width, height: camera.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Each arc on screen as a VoiceOver button at its middle (spec §8): "Flights, Portland and Mexico City,
/// 2 flights", plus ", imported" when every flight on it was imported; activating one opens its card. Synthetic
/// elements only, so nothing here takes a touch from the map's pan and pinch.
struct WorldFlightArcButtons: View {
    let camera: WorldViewCamera
    let arcs: [WorldFlightArc]
    let onPick: (WorldFlightArc) -> Void

    /// The most arcs offered to VoiceOver at once (the most-flown first).
    static let maxButtons = 60

    var body: some View {
        Color.clear
            .frame(width: camera.size.width, height: camera.size.height)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
            .accessibilityChildren {
                ZStack(alignment: .topLeading) {
                    ForEach(onScreen) { item in
                        Color.clear
                            .frame(width: 44, height: 44)
                            .position(item.point)
                            .accessibilityElement()
                            .accessibilityLabel(Text(verbatim: WorldFlightCopy.spoken(item.cluster)))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("worldAtlas.flights.\(item.id)")
                            .accessibilityAction { onPick(item.cluster) }
                    }
                }
                .frame(width: camera.size.width, height: camera.size.height)
            }
    }

    /// The arcs whose middle is on screen, with where, at most ``maxButtons``.
    private var onScreen: [WorldAtlasPlaced<WorldFlightArc>] {
        let screen = CGRect(origin: .zero, size: camera.size)
        // Bounded: the arcs (WorldFlightArcs.maxRoutes), at most maxButtons kept.
        let placed = arcs.lazy.map { arc in
            WorldAtlasPlaced(id: arc.id, cluster: arc, point: camera.screenPoint(x: Double(arc.middle.x), y: Double(arc.middle.y)))
        }
        return Array(placed.filter { screen.contains($0.point) }.prefix(Self.maxButtons))
    }
}
