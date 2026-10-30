import Foundation
import WorldMapStore

/// What the motion coprocessor says the person is doing, in plain values: no CoreMotion type leaves
/// `WorldMotionSource.swift` (round 7, car and bike detection). Read only while "Log my bike rides" is on
/// and Motion & Fitness is allowed, held in memory, never kept.
nonisolated enum WorldMotionKind: String, Equatable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    /// The coprocessor could not tell.
    case unknown
}

/// One motion activity sample: what, how sure, and from when (CoreMotion's activity start).
nonisolated struct WorldMotionSample: Equatable, Sendable {
    let kind: WorldMotionKind
    /// Medium or high confidence (low-confidence samples never start or end a ride on their own).
    let isConfident: Bool
    let at: Date
}

/// How the person is moving now, as the World map reads it (`b1-home-car`, `b1-home-bike`).
nonisolated enum WorldRideMode: Equatable, Sendable {
    /// Walking, running, or standing: the map as usual.
    case onFoot
    /// In a car or bus since `since`: the companion rides along, quick starts and banners pause, only a
    /// lane of fog lifts along the road, and with background mapping the road is traced.
    case driving(since: Date)
    /// On a bike since `since` (only with Motion: "Log my bike rides" on and allowed).
    case cycling(since: Date)
}

/// A finished bike ride, ready to log as exercise.
nonisolated struct WorldBikeRide: Equatable, Sendable {
    let started: Date
    let ended: Date
    /// The distance from the location readings during the ride, in metres; nil when there were too few
    /// readings to say (a ride found afterwards in the motion history, with the app closed).
    let metres: Double?
    /// The ride's line, from the same readings (Refinements group 19, `ref-ride-line`); empty for a ride
    /// found afterwards in the motion history, which had no readings to draw.
    var points: [RoutePoint] = []

    /// The ride's length in whole minutes, at least one.
    var minutes: Int { max(1, Int((ended.timeIntervalSince(started) / 60).rounded())) }
}

/// What changed as one reading, sample or tick was taken.
nonisolated enum WorldRideEvent: Equatable, Sendable {
    case driveStarted(Date)
    case driveEnded(Date)
    case rideStarted(Date)
    /// A bike ride ended and is long enough to log.
    case rideEnded(WorldBikeRide)

    /// The finished ride this event carries; nil for any other event.
    var bikeRide: WorldBikeRide? {
        guard case .rideEnded(let ride) = self else { return nil }
        return ride
    }
}

/// A bike ride just logged, for Home's note and its Undo (the approved `b1-home-bike` note).
nonisolated struct WorldLoggedRide: Equatable, Identifiable, Sendable {
    /// The logged workout's id (Undo removes it).
    let id: UUID
    /// The day it was logged to.
    let dayKey: String
    let metres: Double?
    let minutes: Int
    /// Whether it was logged (false in a decoy, which keeps nothing; Undo then only closes the note).
    let isKept: Bool
}
