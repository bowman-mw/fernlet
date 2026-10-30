import Foundation
import Observation

/// What the World Home draws for the person's location (designs `b1-home-*`, Batch 1): the live map,
/// or the open scene when location is off.
nonisolated enum WorldMapPresence: Equatable, Sendable {
    /// Location is off: the open sky-and-grass scene (`b1-home-denied`, draft 4), after an actual denial,
    /// or after the map intro's Not now while iOS has not asked ("Not now leaves Home on plain parchment,
    /// as in 'Location turned off'", `b1-loc-intro`).
    case off
    /// Allowed, but approximate: the map zooms out to the area and the companion never stands on a street.
    case approximate
    /// Allowed and precise, or not answered yet: before the person answers (the intro still to come, or
    /// iOS's prompt up) Home is the map as on its first day (`b1-home-first`, and the map behind iOS's
    /// prompt in `b1-loc-prompt`), never the location-off scene.
    case precise

    /// The presence for a permission and accuracy. `awaitsAnswer`: iOS hasn't asked yet and the person's
    /// answer is still to come (the map intro not answered, or iOS's prompt up).
    static func make(permission: WorldLocationPermission, isPrecise: Bool, awaitsAnswer: Bool = false) -> WorldMapPresence {
        switch permission {
        case .denied: .off
        case .notAsked: awaitsAnswer ? .precise : .off
        case .whileUsing, .always: isPrecise ? .precise : .approximate
        }
    }
}

/// How Apple's map tiles are doing, as MapKit reports it (`AppleMutedBaseMap`).
nonisolated enum WorldTileState: Equatable, Sendable {
    /// Nothing reported yet, or tiles drawn.
    case ready
    /// Tiles are on their way.
    case loading
    /// Tiles could not load (no signal): the plain parchment stands in.
    case failed
}

/// The one live tile state, shared between the base map that reports it and the Home that reads it.
@MainActor
@Observable
final class WorldTileStatus {
    /// The latest report.
    private(set) var state: WorldTileState = .ready
    /// When the current load began; nil when none is under way.
    @ObservationIgnored private(set) var loadingSince: Date?

    /// MapKit started fetching tiles.
    func loading(at date: Date = Date()) {
        if loadingSince == nil { loadingSince = date }
        if state != .failed { state = .loading }
    }

    /// MapKit drew its tiles.
    func loaded() {
        loadingSince = nil
        state = .ready
    }

    /// MapKit could not fetch tiles.
    func failed() {
        loadingSince = nil
        state = .failed
    }
}

/// The plate under the status plate that names the map's state (the design kit's `.ntc` notice), one at
/// a time, most important first.
nonisolated enum WorldMapNoticeKind: Equatable, Sendable {
    /// "Riding along · Quick starts and banners pause until you're on foot." (`b1-home-car`, round 7), while
    /// car detection says the person is driving. First of all: it is what explains Home's paused controls,
    /// offline's line is about walks (none record in a car) and approximate's Use precise is no control to
    /// reach for on the road, so the other plates wait until the person is on foot.
    case ridingAlong
    /// "Offline · Walks still record. The map returns with signal." (`b1-home-offline`)
    case offline
    /// "Approximate location · The companion stands in your area, not on your street." with Use precise
    /// (`b1-home-approx`, draft 2).
    case approximate
    /// "Loading the map…" (`b1-home-loading`), only once loading has taken a moment.
    case loading
    /// "Your map starts here · It uncovers as you go, on this iPhone only." (`b1-home-first`), until the
    /// first walk.
    case firstDay

    /// The notice for these facts, or nil for none. A decoy never shows the first-day plate (it must look
    /// like any day), and neither does a walk under way, or a map set not to uncover as you go. While
    /// `isDriving` (``WorldRideKeeper/isDriving``) the riding-along plate stands in for every other one.
    static func make(presence: WorldMapPresence, tiles: WorldTileState, loadingLong: Bool,
                     liftedCells: Int, uncovers: Bool = true, isDecoy: Bool, isWalking: Bool,
                     isDriving: Bool = false) -> WorldMapNoticeKind? {
        guard presence != .off else { return nil }
        if isDriving { return .ridingAlong }
        if tiles == .failed { return .offline }
        if presence == .approximate { return .approximate }
        if tiles == .loading && loadingLong { return .loading }
        if uncovers, !isDecoy, !isWalking, liftedCells <= Self.firstDayCellLimit { return .firstDay }
        return nil
    }

    /// The most fog cells one standing reading lifts with a little room (about 50 m around you in ~30 m
    /// hexes): the map is still "starting here" until a walk lifts more than this.
    static let firstDayCellLimit = 24

    /// How long tiles must be loading before the plate shows (and it is spoken only after two seconds).
    static let loadingDelay: Duration = .seconds(1)
}
