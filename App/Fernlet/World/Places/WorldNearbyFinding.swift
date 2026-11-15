import Foundation
import WorldMapStore

/// A kind of place Apple Maps can be asked for around a point (owner, 2026-11-15: "Can be used for things like
/// food tracking and workouts too"). Only the hotel is asked for today; the others are here so the meal and workout
/// screens can use the same seam later. Frozen tokens.
nonisolated enum WorldNearbyCategory: String, CaseIterable, Sendable {
    /// A hotel (the drive-end check-in offer).
    case hotel
    /// A restaurant (for food tracking, later).
    case restaurant
    /// A gym (for workouts, later).
    case gym
}

/// One place an Apple Maps lookup returned: its kind, Apple's name for it and where it is. Plain values, held in
/// memory only and never written; nothing else of Apple's comes with it.
nonisolated struct WorldNearbyPlace: Equatable, Sendable {
    /// Which of the asked-for kinds it is.
    let category: WorldNearbyCategory
    /// Apple's name for it ("The Ace Hotel").
    let name: String
    /// Where it is.
    let point: GeoPoint
}

/// Asks what is near a point (owner, 2026-11-15, the hotel check-in). Only the point, the radius and the kinds go
/// out (to Apple Maps, the map's own destination: `AppleNearbyFinder`); what comes back is plain values. Tests stand
/// in a fake.
@MainActor
protocol WorldNearbyFinding {
    /// The places of `categories` within `radius` metres of `point`, or nil when there is no answer (offline, a
    /// throttle, an invalid point). "Nothing here" is an empty list.
    func places(around point: GeoPoint, radius: Double, categories: [WorldNearbyCategory]) async -> [WorldNearbyPlace]?
}

/// The check-in offer the blue button shows after a drive ends at a hotel (owner, 2026-11-15): Apple's name for the
/// hotel and where it is. In memory only, never written; tapping it checks in through the person's own hotel book.
nonisolated struct WorldHotelOffer: Equatable, Sendable {
    /// The hotel's name, as Apple Maps gives it.
    let name: String
    /// Where it is.
    let point: GeoPoint
}
