import FernletFoundation
import FernletUI
import SwiftUI
import WorldMapStore

/// Finding the subway hop under a tap (owner 2026-11-21): a hop is a straight line between two points, so the test
/// is the distance from the tap to that line.
nonisolated enum WorldSubwayHopLookup {
    /// The hop whose line passes nearest `point` within `metres`; nil when none does.
    static func hop(at point: GeoPoint, within metres: Double, hops: [WorldSubwayHop]) -> WorldSubwayHop? {
        guard point.isValid, metres > 0 else { return nil }
        var best: (hop: WorldSubwayHop, metres: Double)?
        // Bounded: at most WorldSubwayHop.maxDrawn hops.
        for hop in hops.prefix(WorldSubwayHop.maxDrawn) {
            let away = distance(from: point, toLineFrom: hop.from, to: hop.to)
            if away <= metres, away < (best?.metres ?? .infinity) { best = (hop, away) }
        }
        return best?.hop
    }

    /// The distance from `point` to the straight line between `start` and `end`, in metres, on a flat sheet round
    /// `point` (a hop is a few kilometres, where that is exact enough for a finger).
    static func distance(from point: GeoPoint, toLineFrom start: GeoPoint, to end: GeoPoint) -> Double {
        let a = flat(start, round: point), b = flat(end, round: point)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(a.x, a.y) }
        let along = min(1, max(0, -(a.x * dx + a.y * dy) / length))
        return hypot(a.x + along * dx, a.y + along * dy)
    }

    /// `point` in metres east and north of `origin`.
    private static func flat(_ point: GeoPoint, round origin: GeoPoint) -> (x: Double, y: Double) {
        let metresPerDegree = 111_320.0
        let east = (point.longitude - origin.longitude) * metresPerDegree * cos(origin.latitude * .pi / 180)
        return (east, (point.latitude - origin.latitude) * metresPerDegree)
    }
}

/// The station names of one hop's two ends, as Apple Maps gave them.
nonisolated struct SubwayHopStations: Equatable, Sendable {
    /// The station nearest where the ride started and where it ended; nil when none was found there.
    let from: String?
    let to: String?

    /// How far round each end Apple Maps is asked, in metres: a station's entrance is rarely further from where the
    /// GPS was lost or came back.
    static let radius = 400.0

    /// Asks `finder` for the station nearest each end of `hop`; nil when there was no answer at all (offline).
    @MainActor
    static func look(for hop: WorldSubwayHop, finder: any WorldNearbyFinding) async -> SubwayHopStations? {
        let from = await finder.places(around: hop.from, radius: radius, categories: [.station])
        let to = await finder.places(around: hop.to, radius: radius, categories: [.station])
        guard from != nil || to != nil else { return nil }
        return SubwayHopStations(from: nearest(from ?? [], to: hop.from), to: nearest(to ?? [], to: hop.to))
    }

    /// The name of the station in `places` nearest `point`.
    static func nearest(_ places: [WorldNearbyPlace], to point: GeoPoint) -> String? {
        places.filter { $0.category == .station }
            .min { $0.point.distance(to: point) < $1.point.distance(to: point) }?.name
    }
}

/// The page a tap on a dotted subway hop opens (owner 2026-11-21; the station names asked of Apple Maps only here,
/// owner 2026-11-15): when it was and how long, the two stations once Apple Maps answers, that it is a guess, and
/// Forget. The wording is a draft for the owner.
struct SubwayHopDetail: View {
    let hop: WorldSubwayHop
    let book: WornWayBook
    let onClose: () -> Void
    /// Where the station names come from (Apple Maps; tests stand in a fake).
    var finder: any WorldNearbyFinding = AppleNearbyFinder()
    @State private var stations: SubwayHopStations?
    @State private var looked = false
    @State private var forgetting = false

    var body: some View {
        List {
            Section {
                Text(SubwayHopCopy.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("subwayHop.header")
                Text(verbatim: when)
                    .accessibilityIdentifier("subwayHop.when")
                Text(stationsLine)
                    .accessibilityIdentifier("subwayHop.stations")
            } footer: {
                Text(SubwayHopCopy.guess)
            }
            Section {
                Button(role: .destructive) { forgetting = true } label: { Text(WornWayCopy.forgetRide) }
                    .accessibilityIdentifier("subwayHop.forget")
            }
        }
        .navigationTitle(Text(SubwayHopCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            stations = await SubwayHopStations.look(for: hop, finder: finder)
            looked = true
        }
        .confirmationDialog(Text(WornWayCopy.forgetRideTitle), isPresented: $forgetting, titleVisibility: .visible) {
            Button(role: .destructive) { forget() } label: { Text(WornWayCopy.forgetRideConfirm) }
        } message: {
            Text(WornWayCopy.forgetRideBody)
        }
    }

    /// "Nov 20, 6:53 PM · 15 min".
    private var when: String {
        let start = hop.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let minutes = Duration.seconds(hop.end.timeIntervalSince(hop.start)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(start) · \(minutes)"
    }

    /// The stations line: looking, the two names, one name, or none found.
    private var stationsLine: LocalizedStringResource {
        guard looked else { return SubwayHopCopy.looking }
        return SubwayHopCopy.stations(from: stations?.from, to: stations?.to)
    }

    private func forget() {
        book.forgetTrip(hop.id)
        FernletFeedback.system.play(.moved)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: WornWayCopy.forgotten))
        onClose()
    }
}

/// The subway hop page's copy (drafts for the owner, 2026-11-21).
nonisolated enum SubwayHopCopy {
    static let title = LocalizedStringResource("subwayHop.title", defaultValue: "Possible subway ride",
                                               comment: "Subway hop sheet: title of a ride with no GPS that Fernlet guessed was a subway ride")
    static let guess = LocalizedStringResource(
        "subwayHop.guess", defaultValue: "Fernlet guessed this from a gap in GPS and your iPhone's motion data. It draws a straight dotted line between where the GPS stopped and where it came back.",
        comment: "Subway hop sheet: explains that the ride is a guess and why its line is straight")
    static let looking = LocalizedStringResource("subwayHop.looking", defaultValue: "Looking up the stations…",
                                                 comment: "Subway hop sheet: shown while Apple Maps is asked for the station names")
    static let noStations = LocalizedStringResource("subwayHop.noStations", defaultValue: "No station names found.",
                                                    comment: "Subway hop sheet: Apple Maps gave no station near either end of the ride")
    static let subway = LocalizedStringResource("subwayHop.kind", defaultValue: "Subway",
                                                comment: "The kind of a kept ride that went underground: a subway or metro")
    static let thisWasSubway = LocalizedStringResource("subwayHop.thisWas", defaultValue: "This was a subway",
                                                       comment: "Changes a kept ride to a subway or metro ride")

    /// "From Place-des-Arts to Lionel-Groulx", or the one end found, or that none was.
    static func stations(from: String?, to: String?) -> LocalizedStringResource {
        switch (from, to) {
        case let (from?, to?):
            LocalizedStringResource("subwayHop.fromTo", defaultValue: "From \(from) to \(to)",
                                    comment: "Subway hop sheet: the stations a ride started and ended at, as Apple Maps names them")
        case let (from?, nil):
            LocalizedStringResource("subwayHop.fromOnly", defaultValue: "From \(from)",
                                    comment: "Subway hop sheet: only the station the ride started at was found")
        case let (nil, to?):
            LocalizedStringResource("subwayHop.toOnly", defaultValue: "To \(to)",
                                    comment: "Subway hop sheet: only the station the ride ended at was found")
        case (nil, nil):
            noStations
        }
    }
}
