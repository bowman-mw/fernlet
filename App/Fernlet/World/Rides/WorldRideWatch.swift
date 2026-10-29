import Foundation
import WorldMapStore

/// Whether the person is driving, cycling or on foot, from the map's readings and, when allowed, the
/// motion coprocessor's activity (round 7, car and bike detection; `b1-home-car`, `b1-home-bike`). Plain
/// values, in memory only: the motion samples it is shown are never kept.
///
/// - **Driving, by speed first:** sustained readings faster than a car's speed. With Motion, the
///   coprocessor's automotive activity starts and holds a drive too, and its cycling activity keeps a fast
///   bike ride from being read as a drive.
/// - **Cycling** only with Motion ("Log my bike rides" on and allowed): the coprocessor's cycling activity.
/// - A ride long enough to count ends as ``WorldRideEvent/rideEnded(_:)`` with its minutes and, from the
///   readings, its distance.
nonisolated struct WorldRideWatch: Equatable, Sendable {
    /// How the person is moving now.
    private(set) var mode: WorldRideMode = .onFoot
    /// Whether motion samples are being shown (Log my bike rides on and Motion allowed); without them the
    /// watch decides by speed alone and never sees a bike.
    var usesMotion = false

    /// Whether the person is driving now.
    var isDriving: Bool {
        if case .driving = mode { return true }
        return false
    }

    /// Whether the person is cycling now.
    var isCycling: Bool {
        if case .cycling = mode { return true }
        return false
    }

    /// Takes a location reading; what changed.
    mutating func observe(_ fix: WorldFix) -> [WorldRideEvent] {
        []
    }

    /// Takes motion samples (oldest first); what changed.
    mutating func observe(_ samples: [WorldMotionSample]) -> [WorldRideEvent] {
        []
    }

    /// Ends a drive or ride that has gone quiet, as of `date`; what changed.
    mutating func tick(at date: Date) -> [WorldRideEvent] {
        []
    }

    /// The bike rides in a stretch of motion history (the app was closed through them), oldest first.
    static func rides(in samples: [WorldMotionSample], until end: Date) -> [WorldBikeRide] {
        []
    }
}
