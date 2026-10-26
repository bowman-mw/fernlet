import Foundation
import Observation

/// Everything the shell shows, all of it fixture data, in one observable model.
///
/// Nothing persists and nothing leaves the phone: relaunching resets it all. The fixture controls
/// (where you are, how you're moving, decoy, time of day, the companion's day, time with Fernlet,
/// the base map) live in the Settings panel's "Prototype fixtures" card and in launch arguments
/// (``ShellLaunchOptions``). Actions live in `WorldShellModel+Actions.swift`.
@Observable
final class WorldShellModel {
    // MARK: Fixture controls

    var careState: ShellCompanionState = .okay
    var level: TimeWithFernlet = .month
    private(set) var spot: FixtureSpot = .home
    private(set) var ride: CompanionRide = .onFoot
    private(set) var decoy = false
    /// A fixed time of day, or nil to follow the clock.
    var phaseOverride: SkyPhase?
    var baseMap: BaseMapKind = .appleMuted

    // MARK: Today's fixture numbers

    var water = 4
    var protein = 38
    var carbs = 120
    var fat = 22
    var outfit: Outfit = .none
    /// Stamps earned in this session (the stamp book adds them to the fixture's own).
    var sessionStamps: [String] = []

    // MARK: On screen

    var panel: PanelKind?
    var quickStartOpen = false
    var privateUnlocked = false
    var toast: ShellToast?
    var banner: ShellBanner?
    var speech: ShellSpeech?
    /// The settled pet pose lasts until this moment.
    var settledUntil = Date.distantPast
    /// Goes up on every pet, so the hop and the floating heart replay.
    var petCount = 0
    var lastPet = Date.distantPast

    // MARK: The map

    var camera: WorldCamera
    var viewport: MapViewport?
    private(set) var companionPosition: GeoPoint
    private(set) var facingLeft = false
    private(set) var replay: RouteReplay?
    /// Walks finished this session; a decoy session keeps its own and drops them when it ends.
    private(set) var sessionTraces: [[GeoPoint]] = []
    private(set) var decoyTraces: [[GeoPoint]] = []
    private(set) var rideTraces: [(kind: RouteReplay.Kind, points: [GeoPoint])] = []
    private(set) var lifted: Set<HexCell> = []
    /// Whether the launch zoom has been corrected from the first real viewport.
    @ObservationIgnored var zoomCalibrated = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var noticeTasks: [String: Task<Void, Never>] = [:]

    init(options: ShellLaunchOptions = ShellLaunchOptions()) {
        let start = options.spot ?? .home
        spot = start
        companionPosition = start.location
        camera = WorldCamera(center: start.location, distance: 1_700)
        careState = options.state ?? .okay
        level = options.level ?? .month
        phaseOverride = options.phase
        baseMap = options.baseMap ?? .appleMuted
        decoy = options.decoy
        recomputeFog()
        apply(options)
    }

    // MARK: Derived

    /// The time of day the map and clock show.
    func phase(at date: Date) -> SkyPhase {
        phaseOverride ?? SkyPhase.phase(forHour: Calendar.current.component(.hour, from: date))
    }

    /// The known place you're standing at, if any (the blue button's match).
    var matchedSpot: FixtureSpot? {
        QuickStart.match(position: companionPosition, level: level, decoy: decoy)
    }

    /// Whether the companion is out walking or hiking right now.
    var isWalking: Bool { replay?.kind == .walk || replay?.kind == .hike }

    /// Whether quick starts are available: on foot, not mid-walk.
    var quickStartsAvailable: Bool { ride == .onFoot && !isWalking }

    /// Saved trails drawn on the map; a decoy session shows none.
    var visibleTrails: [[GeoPoint]] { decoy ? [] : level.savedTrails }

    /// Dotted traces: this session's walks, plus the one in progress.
    var visibleTraces: [[GeoPoint]] {
        let finished = decoy ? decoyTraces : sessionTraces
        guard let replay, isWalking else { return finished }
        return finished + [replay.trace]
    }

    /// Whether the settled pet pose is showing.
    func isSettled(at date: Date) -> Bool { date < settledUntil }

    /// Stamps in the book: the fixture's, plus any earned this session.
    var stampBook: [String] {
        let fixture: [String] = switch level {
        case .dayOne: []
        case .month: ["Rubber Duck", "Bean Counter", "Starting Line"]
        case .year: ["Rubber Duck", "Bean Counter", "Starting Line", "Slice of Life", "Piano Mover",
                     "Eucalyptus Dreams", "Encore", "Good Bean", "Small Step"]
        }
        return sessionStamps + fixture
    }

    // MARK: Fog

    /// Rebuilds the lifted cells from the fixture's history, this session's walks and rides, and
    /// where you stand. A decoy session lifts only where you stand and its own walks. The radii are
    /// the mockup's (home 125, where you stand 70, trails 32, walks 40, drives 16 and rides 26 of
    /// its units, at 1.4 m each).
    func recomputeFog() {
        let grid = WorldFixtures.grid
        var cells = Set<HexCell>()
        func lift(_ point: GeoPoint, _ metres: Double) { cells.formUnion(grid.cells(around: point, within: metres)) }
        func lift(along points: [GeoPoint], _ metres: Double) {
            for sample in Polyline(points).samples(every: grid.radius * 0.6) { lift(sample, metres) }
        }
        if decoy {
            for trace in decoyTraces { lift(along: trace, 56) }
        } else {
            if level != .dayOne { lift(FixtureSpot.home.location, 175) }
            for trail in level.savedTrails { lift(along: trail, 45) }
            for known in FixtureSpot.allCases where level.visits(to: known) > 0 { lift(known.location, 70) }
            for trace in sessionTraces { lift(along: trace, 56) }
            for ride in rideTraces { lift(along: ride.points, ride.kind == .car ? 22 : 36) }
        }
        lift(companionPosition, 98)
        lifted = cells
    }

    /// Lifts the cells around one point of a replay, counting the new ones.
    func liftLive(at point: GeoPoint, radius: Double) -> Int {
        let fresh = WorldFixtures.grid.cells(around: point, within: radius).filter { !lifted.contains($0) }
        lifted.formUnion(fresh)
        return fresh.count
    }

    // MARK: Internal setters for the actions extension

    func setSpot(_ value: FixtureSpot) { spot = value }
    func setRide(_ value: CompanionRide) { ride = value }
    func setDecoy(_ value: Bool) { decoy = value }
    func setReplay(_ value: RouteReplay?) { replay = value }
    func setCompanion(_ position: GeoPoint) {
        if abs(position.longitude - companionPosition.longitude) > 1e-7 { facingLeft = position.longitude < companionPosition.longitude }
        companionPosition = position
    }
    func addTrace(_ trace: [GeoPoint]) { if decoy { decoyTraces.append(trace) } else { sessionTraces.append(trace) } }
    func addRideTrace(kind: RouteReplay.Kind, points: [GeoPoint]) { if !decoy { rideTraces.append((kind, points)) } }
    func dropDecoyTraces() { decoyTraces = [] }

    /// Replaces the running ticker task (nil stops it).
    func setTicker(_ task: Task<Void, Never>?) {
        ticker?.cancel()
        ticker = task
    }

    /// Runs `clear` after `seconds` unless another notice of the same `key` replaced this one.
    func schedule(_ key: String, after seconds: Double, _ clear: @escaping @MainActor () -> Void) {
        noticeTasks[key]?.cancel()
        noticeTasks[key] = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            clear()
        }
    }
}
