// make-routes.swift — a developer tool, not part of the WorldShell app.
//
// Asks Apple's directions service for walking or driving routes between the fixture waypoints and
// prints `RecordedRoutes.swift`, so the shell's trails and replayed walks follow real streets and
// park paths. It sends only these fixed public waypoints (a park in Portland, Oregon), never anyone's
// location. Run it from the repository root on a Mac, then move the output into place:
//
//   swiftc -O -o /tmp/make-routes Prototypes/WorldShell/Tools/make-routes.swift
//   /tmp/make-routes > Prototypes/WorldShell/WorldShell/Fixtures/RecordedRoutes.swift
//
// To move the fixture somewhere else, change the waypoints below and the anchor in WorldFixtures.swift.

import Foundation
import MapKit

/// One route to fetch: its Swift name, its waypoints in order, and how it is travelled.
struct RouteSpec {
    let name: String
    let doc: String
    let waypoints: [(Double, Double)]
    let transport: MKDirectionsTransportType
}

let home = (45.517934, -122.617795)        // SE 43rd Ave & SE Alder St: the fixture "Home space"
let trailhead = (45.520273, -122.623031)   // SE Cesar E Chavez Blvd & SE Oak St: the park's east gate
let gym = (45.516447, -122.629556)         // SE 34th Ave & SE Belmont St: "Riverside Gym"
let noodle = (45.516440, -122.625855)      // SE 37th Ave & SE Belmont St: "Hoshi Noodle Bar"
let fresh = (45.526447, -122.614988)       // NE 47th Ave & NE Glisan St: "Somewhere new"

let specs: [RouteSpec] = [
    RouteSpec(name: "homeToPark", doc: "The saved route from the Home space to the park's east gate.",
              waypoints: [home, (45.520268, -122.620027), trailhead], transport: .walking),
    RouteSpec(name: "parkLoop", doc: "The saved trail: the Oak Park loop, from the east gate round the lake and back.",
              waypoints: [trailhead, (45.5222, -122.6250), (45.5214, -122.6292), (45.5197, -122.6283),
                          (45.5196, -122.6248), trailhead], transport: .walking),
    RouteSpec(name: "riverRoad", doc: "A saved run route south of the park, used on the year fixture.",
              waypoints: [noodle, gym, (45.5130, -122.6296), (45.5130, -122.6178), home], transport: .walking),
    RouteSpec(name: "walkTogether", doc: "The recorded walk the shell replays from the Home space.",
              waypoints: [home, (45.520268, -122.620027), (45.522785, -122.623018), (45.5245, -122.6185),
                          (45.519278, -122.617296), home], transport: .walking),
    RouteSpec(name: "freshWalk", doc: "The recorded walk the shell replays from somewhere new.",
              waypoints: [fresh, (45.5290, -122.6150), (45.5290, -122.6195), (45.5264, -122.6195), fresh],
              transport: .walking),
    RouteSpec(name: "gymWalk", doc: "The recorded walk the shell replays from Riverside Gym.",
              waypoints: [gym, (45.5193, -122.6296), (45.5193, -122.6262), noodle, gym], transport: .walking),
    RouteSpec(name: "noodleWalk", doc: "The recorded walk the shell replays from the noodle bar.",
              waypoints: [noodle, (45.5193, -122.6258), (45.5193, -122.6230), (45.5164, -122.6230), noodle],
              transport: .walking),
    RouteSpec(name: "carLoop", doc: "A recorded drive on the main roads, for the riding-along state.",
              waypoints: [home, fresh, (45.522785, -122.623018), noodle, home], transport: .automobile),
    RouteSpec(name: "bikeLoop", doc: "A recorded bike ride through the park and back, for the bike state.",
              waypoints: [home, trailhead, (45.5214, -122.6292), gym, noodle, home], transport: .walking),
]

/// Fetches one leg between two coordinates and returns its polyline vertices.
func leg(from a: (Double, Double), to b: (Double, Double), by transport: MKDirectionsTransportType) -> [CLLocationCoordinate2D] {
    let request = MKDirections.Request()
    request.source = MKMapItem(location: CLLocation(latitude: a.0, longitude: a.1), address: nil)
    request.destination = MKMapItem(location: CLLocation(latitude: b.0, longitude: b.1), address: nil)
    request.transportType = transport
    var result: [CLLocationCoordinate2D] = []
    var done = false
    MKDirections(request: request).calculate { response, _ in
        if let line = response?.routes.first?.polyline {
            let points = line.points()
            result = (0..<line.pointCount).map { points[$0].coordinate }
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    return result
}

/// Drops vertices closer than `spacing` metres to the last kept one, keeping the final vertex.
func thin(_ points: [CLLocationCoordinate2D], spacing: Double) -> [CLLocationCoordinate2D] {
    guard let first = points.first, let last = points.last else { return [] }
    var kept = [first]
    for point in points.dropFirst() {
        let previous = kept[kept.count - 1]
        let metres = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
        if metres >= spacing { kept.append(point) }
    }
    if kept.count > 1, kept[kept.count - 1].latitude != last.latitude { kept.append(last) }
    return kept
}

print("""
// RecordedRoutes.swift — GENERATED by Prototypes/WorldShell/Tools/make-routes.swift. Do not edit by hand.
//
// Fixture routes around Laurelhurst Park, Portland, Oregon (a public park, picked as a neutral
// example). Each is a list of plain latitude/longitude pairs from Apple's walking or driving
// directions, thinned to about one point every 6 m. None of this is anyone's real history.

/// The shell's recorded routes: saved trails, replayed walks, and the car and bike loops.
nonisolated enum RecordedRoutes {
""")
for spec in specs {
    var coordinates: [CLLocationCoordinate2D] = []
    for index in 0..<(spec.waypoints.count - 1) {
        let piece = leg(from: spec.waypoints[index], to: spec.waypoints[index + 1], by: spec.transport)
        coordinates.append(contentsOf: coordinates.isEmpty ? piece : Array(piece.dropFirst()))
    }
    let thinned = thin(coordinates, spacing: 6)
    print("    /// \(spec.doc) \(thinned.count) points.")
    print("    static let \(spec.name): [GeoPoint] = [")
    for coordinate in thinned {
        print(String(format: "        GeoPoint(%.6f, %.6f),", coordinate.latitude, coordinate.longitude))
    }
    print("    ]")
}
print("}")
