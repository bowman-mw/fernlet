import FernletFoundation
import Foundation
import WorldMapStore

/// A kept subway hop as the map draws it and its sheet reads it: a straight dotted line between two points.
nonisolated struct WorldSubwayHop: Equatable, Identifiable, Sendable {
    /// The kept trip's id.
    let id: UUID
    /// The last good reading before the ride, and the first after it.
    let from: GeoPoint
    let to: GeoPoint
    /// When those readings were taken.
    let start: Date
    let end: Date

    /// The most hops the map draws and a tap searches (the newest; a bound).
    static let maxDrawn = 500
}

/// Subway hops in the fog keeper (owner 2026-11-21): each is a trip of kind ``WornWayKind/subway`` in the kept
/// trips (`WornTripStore`, under the buffer key, so one found with the phone locked is kept), its line the two
/// points either side of the ride. It lifts no fog, counts on no way (the counter never holds a subway key), is
/// kept unconfirmed because it is an inference, and is forgotten like any trip (``forgetTrip(_:)``) or with the
/// map's history. Nothing is kept in a decoy or with background mapping off.
extension WorldFogKeeper {
    /// Keeps a hop the location source found; whether it was kept.
    @discardableResult
    func keepSubwayHop(_ hop: WorldSubwayHopCandidate) -> Bool {
        guard !isDecoy, countsRides(), hop.from.isValid, hop.to.isValid, hop.arrived > hop.left else { return false }
        if !tripStore.isLoaded { loadTrips() }
        guard tripStore.isLoaded else { return false }
        let trip = WornTrip(kind: .subway, confirmed: false, day: WornDay.number(for: hop.left), start: hop.left,
                            end: hop.arrived, line: WornTripCodec.quantized([hop.from, hop.to]))
        do {
            guard try tripStore.append(trip, unsure: false) else { return false }
        } catch {
            FernletAuditLog.log("worldMap.trips.hopUnsaved")
            return false
        }
        wornTrips = tripStore.summaries
        flush()
        return true
    }

    /// The kept hops, newest first (at most ``WorldSubwayHop/maxDrawn``); none in a decoy or before the trips are read.
    func subwayHops() -> [WorldSubwayHop] {
        guard !isDecoy, tripStore.isLoaded, wornTrips.contains(where: { $0.kind == .subway }) else { return [] }
        do {
            return try tripStore.trips(kind: .subway, limit: WorldSubwayHop.maxDrawn).compactMap(Self.hop)
        } catch {
            FernletAuditLog.log("worldMap.trips.readFailed")
            return []
        }
    }

    /// A kept subway trip as a hop; nil when its line is not two points.
    static func hop(_ trip: WornTrip) -> WorldSubwayHop? {
        guard trip.kind == .subway, let from = trip.line.first, let to = trip.line.last, trip.line.count >= 2 else {
            return nil
        }
        return WorldSubwayHop(id: trip.id, from: from, to: to, start: trip.start, end: trip.end)
    }
}
