import CoreMotion
import FernletFoundation
import Foundation

/// The person's Motion & Fitness answer, as the World map reads it.
nonisolated enum WorldMotionPermission: Equatable, Sendable {
    /// Not asked yet.
    case notAsked
    /// Declined, or restricted on this phone.
    case denied
    case allowed
    /// This iPhone has no motion coprocessor activity.
    case unavailable
}

/// Where motion activity comes from: CoreMotion on the phone, a scripted stream in tests.
@MainActor
protocol WorldMotionReading: AnyObject {
    /// The person's answer now.
    var permission: WorldMotionPermission { get }
    /// Asks for Motion & Fitness (iOS asks on the first query); whether it is allowed afterwards.
    func requestAccess() async -> Bool
    /// The activity samples from `start` to `end`, oldest first; empty without permission.
    func samples(from start: Date, to end: Date) async -> [WorldMotionSample]
}

/// The motion coprocessor's activity for car and bike detection (round 7). **The only file in the app
/// that imports CoreMotion** (`MapAndLocationConfinementBoundaryTests`). Asked only when "Log my bike
/// rides" is turned on; the samples are handed on as plain values and never kept.
@MainActor
final class WorldMotionSource: WorldMotionReading {
    private let manager = CMMotionActivityManager()

    var permission: WorldMotionPermission {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        return Self.permission(for: CMMotionActivityManager.authorizationStatus())
    }

    func requestAccess() async -> Bool {
        guard permission == .notAsked || permission == .allowed else { return false }
        // iOS shows its Motion & Fitness prompt on the first query; a one-second look-back is enough to ask.
        let now = Date()
        _ = await query(from: now.addingTimeInterval(-1), to: now)
        return permission == .allowed
    }

    func samples(from start: Date, to end: Date) async -> [WorldMotionSample] {
        guard permission == .allowed, start < end else { return [] }
        return await query(from: start, to: end)
    }

    /// The activity between `start` and `end` as plain samples (empty on any error).
    private func query(from start: Date, to end: Date) async -> [WorldMotionSample] {
        await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                if error != nil { FernletAuditLog.log("worldMap.motion.queryFailed") }
                continuation.resume(returning: Self.samples(from: activities ?? []))
            }
        }
    }

    /// CoreMotion activities as plain samples, oldest first (at most ``maxSamples``, the newest).
    nonisolated static func samples(from activities: [CMMotionActivity]) -> [WorldMotionSample] {
        activities.suffix(maxSamples).map { activity in
            WorldMotionSample(kind: kind(of: activity), isConfident: activity.confidence != .low, at: activity.startDate)
        }
    }

    /// The most samples one query hands on (a bound; a day of activity is far fewer).
    nonisolated static let maxSamples = 2_000

    /// One activity's kind, the most specific first.
    nonisolated static func kind(of activity: CMMotionActivity) -> WorldMotionKind {
        if activity.automotive { return .automotive }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return .unknown
    }

    /// The World map's reading of a CoreMotion status.
    nonisolated static func permission(for status: CMAuthorizationStatus) -> WorldMotionPermission {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        default: .denied
        }
    }
}
