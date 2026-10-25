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
/// It records, and it tells a walk from a run by the pace (`ref-run-first`, approved 2026-10-25: "Walk or run
/// together" asks nothing up front). The moving pace comes from the GPS readings themselves: the time and
/// distance between kept points where the person was moving (``minMovingSpeed`` or faster, no gap longer
/// than ``maxGap``); stops and lost signal don't count. A moving pace of ``runningSpeed`` or faster is a
/// run (``paceKind(metres:seconds:)``). No motion sensor is read: CoreMotion's activity would need the
/// Motion & Fitness permission, which is asked only when "Log my bike rides" is turned on (decided
/// 2026-10-22). Move can change a walk to a run afterwards (and back). `FernletStore.finishWorldWalk`
/// turns a finished walk into a logged workout and, when "Save new routes" is on and no decoy is open, a
/// sealed line (a run's line too).
@MainActor
final class WorldWalkRecorder {
    /// What is being recorded (World build step 5c, owner's Q12: runs save their line too). The raw
    /// values are frozen tokens.
    nonisolated enum Kind: String, Equatable, Sendable {
        /// A saved walk again, or Walk or run together at a walking pace: logged as a walk.
        case walk
        /// A saved run route again, or Walk or run together at a running pace: logged as a run.
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
    /// The moving pace at or above which Walk or run together logs a run, in metres a second (2.2 m/s is
    /// about 7.9 km/h: a 7:35 kilometre, a 12:12 mile; brisk walking stays under it, an easy jog over).
    static let runningSpeed = 2.2
    /// The slowest step between two kept points that still counts as moving, in metres a second.
    static let minMovingSpeed = 0.5
    /// The longest gap between two kept points that still counts as moving, in seconds (longer is a stop
    /// or lost signal).
    static let maxGap = 30.0
    /// Below this much moving time or distance the pace says nothing, and the outing stays a walk.
    static let minMovingSeconds = 60.0
    static let minMovingMetres = 150.0

    /// When the walk running now started, or nil when none is.
    private(set) var started: Date?
    /// The points kept so far.
    private(set) var points: [RoutePoint] = []
    /// What the recording now is (a walk when none is running; Walk or run together stays a walk until
    /// its pace decides at the end).
    private(set) var kind: Kind = .walk
    /// Whether the pace decides walk or run when the recording ends (Walk or run together).
    private(set) var decidesByPace = false
    /// When the last point joined the line.
    private var lastKeptAt: Date?
    /// The time and distance spent moving so far (between kept points, stops left out).
    private(set) var movingSeconds = 0.0
    private(set) var movingMetres = 0.0

    /// Whether a walk is recording.
    var isRecording: Bool { started != nil }

    /// Starts a walk (or a run) at `date`; a no-op while one is already running. With `decidesByPace`
    /// (Walk or run together) the pace picks walk or run when it ends.
    func start(at date: Date, kind: Kind = .walk, decidesByPace: Bool = false) {
        guard started == nil else { return }
        started = date
        points = []
        self.kind = kind
        self.decidesByPace = decidesByPace
        lastKeptAt = nil
        movingSeconds = 0
        movingMetres = 0
    }

    /// Adds a reading to the line when it is good enough and far enough from the last one, and counts
    /// the step towards the moving pace when it was a moving one.
    func record(_ fix: WorldFix) {
        guard started != nil, fix.isPrecise, fix.accuracy <= Self.maxAccuracy, points.count < Self.maxPoints else { return }
        if let last = points.last {
            let step = last.point.distance(to: fix.point)
            if step < Self.minStep { return }
            if let lastKeptAt { countStep(metres: step, seconds: fix.at.timeIntervalSince(lastKeptAt)) }
        }
        points.append(RoutePoint(fix.point))
        lastKeptAt = fix.at
    }

    /// Counts one step between kept points as moving when it was quick enough and had no long gap.
    private func countStep(metres: Double, seconds: Double) {
        guard seconds > 0, seconds <= Self.maxGap, metres / seconds >= Self.minMovingSpeed else { return }
        movingSeconds += seconds
        movingMetres += metres
    }

    /// Ends the walk at `date` and hands it back; nil when none was running. Walk or run together is
    /// logged as the pace says.
    func finish(at date: Date) -> Walk? {
        guard let started else { return nil }
        let decided = decidesByPace ? Self.paceKind(metres: movingMetres, seconds: movingSeconds) : kind
        let walk = Walk(points: points, started: started, ended: max(date, started), kind: decided)
        cancel()
        return walk
    }

    /// A run when `metres` covered while moving for `seconds` is a running pace; otherwise, or with too
    /// little to go on, a walk.
    static func paceKind(metres: Double, seconds: Double) -> Kind {
        guard seconds >= minMovingSeconds, metres >= minMovingMetres else { return .walk }
        return metres / seconds >= runningSpeed ? .run : .walk
    }

    /// Drops the walk without keeping anything (a decoy opening mid-walk).
    func cancel() {
        started = nil
        points = []
        kind = .walk
        decidesByPace = false
        lastKeptAt = nil
        movingSeconds = 0
        movingMetres = 0
    }
}
