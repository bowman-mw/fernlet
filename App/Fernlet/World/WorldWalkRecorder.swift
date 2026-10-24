import Foundation
import WorldMapStore

/// A walk being recorded for the World map (World app plan step 5b): the line it draws, from the
/// readings ``WorldLocationSource`` hands on while a walk runs. Plain values only; no CoreLocation here,
/// so the recorder is driven in tests by the same ``WorldFix`` readings the phone produces.
///
/// Only good readings join the line: precise ones (with approximate location iOS hands over a point
/// somewhere in the area, which would draw a scribble), at most ``maxAccuracy`` metres out, and at least
/// ``minStep`` metres from the last kept point, so standing still adds nothing. Bounded: at most
/// ``maxPoints`` points (the codec's own cap); past it the walk still runs and only stops growing its line.
///
/// It records; it decides nothing. `FernletStore.finishWorldWalk` turns a finished walk into a logged
/// workout and, when "Save new routes" is on and no decoy is open, a sealed line.
@MainActor
final class WorldWalkRecorder {
    /// What is being recorded (World build step 5c, owner's Q12: runs save their line too). The raw
    /// values are frozen tokens.
    nonisolated enum Kind: String, Equatable, Sendable {
        /// Walk together, or a saved walk again: logged as a walk.
        case walk
        /// A saved run route again: logged as a run.
        case run
    }

    /// A finished walk or run.
    struct Walk: Equatable {
        /// The kept readings, in order.
        let points: [RoutePoint]
        /// When the walk started and ended.
        let started: Date
        let ended: Date
        /// A walk or a run.
        var kind: Kind = .walk

        /// The line's length in metres.
        var metres: Double { WorldRouteCodec.length(of: points) }
        /// The walk's length in whole minutes, at least one.
        var minutes: Int { max(1, Int((ended.timeIntervalSince(started) / 60).rounded())) }
    }

    /// The worst accuracy a reading may have and still join the line, in metres.
    static let maxAccuracy = 25.0
    /// The least distance from the last kept point for a reading to be kept, in metres.
    static let minStep = 3.0
    /// The most points one walk keeps.
    static let maxPoints = WorldRouteCodec.maxPoints

    /// When the walk running now started, or nil when none is.
    private(set) var started: Date?
    /// The points kept so far.
    private(set) var points: [RoutePoint] = []
    /// What the recording now is (a walk when none is running).
    private(set) var kind: Kind = .walk

    /// Whether a walk is recording.
    var isRecording: Bool { started != nil }

    /// Starts a walk (or a run) at `date`; a no-op while one is already running.
    func start(at date: Date, kind: Kind = .walk) {
        guard started == nil else { return }
        started = date
        points = []
        self.kind = kind
    }

    /// Adds a reading to the line when it is good enough and far enough from the last one.
    func record(_ fix: WorldFix) {
        guard started != nil, fix.isPrecise, fix.accuracy <= Self.maxAccuracy, points.count < Self.maxPoints else { return }
        if let last = points.last, last.point.distance(to: fix.point) < Self.minStep { return }
        points.append(RoutePoint(fix.point))
    }

    /// Ends the walk at `date` and hands it back; nil when none was running.
    func finish(at date: Date) -> Walk? {
        guard let started else { return nil }
        let walk = Walk(points: points, started: started, ended: max(date, started), kind: kind)
        cancel()
        return walk
    }

    /// Drops the walk without keeping anything (a decoy opening mid-walk).
    func cancel() {
        started = nil
        points = []
        kind = .walk
    }
}
