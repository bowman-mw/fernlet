import FernletFoundation
import Foundation
import WorldMapStore

/// The flight gate (World-Airports-Spec §6.1; owner 2026-10-31: "Don't track anything that the user flies over"):
/// every reading the map's location source hears is weighed by the ``FlightDetector`` first, and only a reading it
/// lets through goes on to car and bike detection, the fog, the passport, the route store and Private history.
/// Owned by `WorldLocationSource` (`flights`), so the foreground, Always mode's low-power readings and a traced
/// drive or followed ride all pass through it.
///
/// - **Home reads** ``isFlying`` (the plane in place of the map, §6.2, the UI lane's), ``layoverAirport`` and
///   ``layoverStart`` (the layover counter, §5), ``currentAirport`` (the tag "At the airport · PDX"),
///   ``isOnTrip`` and ``showsTravelLook`` (Sprout's suitcase and mask, §5), and ``latestFind`` (the airport
///   banners and Sprout's landing lines, §3, §6.3). DEBUG `FERNLET_UI_TEST_AIRPORT` stands a made-up state in for
///   all of them (``UITestSupport/airportHomeState(now:)``), with no readings.
/// - **Take a trip** (§7, the trip lane's) adds `startTrip(at:)` and `endTrip(at:)` here: each calls the
///   detector's own, then hands its events on as ``admits(_:)`` does (``rememberFlights(in:)``, ``publish()``,
///   `save(at:changed: true)`, ``hand(_:)``).
/// - **The passport hears** each airport found, each flight landed and each layover through ``onEvents``
///   (`FernletStore+WorldFlights`); the passport itself keeps nothing in a decoy.
/// - **A late reading** (older than the newest one weighed: a low-power visit's arrival, a batch out of order) is
///   never shown to the detector. It is kept unless it falls inside a flight: the one under way, or one of the last
///   ``maxRecentFlights`` that ended.
/// - **The passport opens only while the phone is unlocked:** what ``onEvents`` could not take (it answers false)
///   waits in memory, at most ``maxPendingEvents``, and is handed again with the next reading's changes (a landing
///   read with the phone locked still finds the airport once it is unlocked).
/// - **Kept across relaunches** (a phone switched off for the flight still lands): the detector's state is sealed in
///   the map's vault under the buffer key (readings arrive with the phone locked), at most every ``saveInterval``
///   or at once when something changed; never in a decoy, and every wipe removes it with the vault's folder.
@MainActor
@Observable
final class WorldFlightKeeper {
    /// Whether a flight is under way.
    private(set) var isFlying = false
    /// The airport just landed at, while the person is still inside its grounds: its country and continent wait
    /// until they leave (§4.2, the owner's note on 9).
    private(set) var layoverAirport: String?
    /// When the person landed at ``layoverAirport``, while still inside its grounds ("Layover at Helsinki · 2 h
    /// 14 min", §5).
    private(set) var layoverStart: Date?
    /// The airport whose grounds held the last placed reading, when not flying (Home's tag, §5).
    private(set) var currentAirport: String?
    /// Whether a trip is on: a ticket, or a flight found by its speed (§5, §7).
    private(set) var isOnTrip = false
    /// Whether Sprout wears the travel look: on a trip, inside an airport's grounds (§5, amended by 18).
    private(set) var showsTravelLook = false
    /// The latest airport the gate found, and how (Home's banner says "Ten minutes at the airport found it" or
    /// "Landed at Heathrow", and a landing brings Sprout's landing line, §3, §6.3). Kept in memory only.
    private(set) var latestFind: WorldAirportFind?

    /// Called with what each reading changed (airports found, flights started and landed, layovers), after any
    /// it could not take before; answers whether it took them.
    @ObservationIgnored var onEvents: (([FlightEvent]) -> Bool)?
    /// Whether a point is at one of the person's homes (a trip ends on getting home, §7).
    @ObservationIgnored var isHome: (GeoPoint) -> Bool = { _ in false }
    /// Whether the state may be written now (false in a decoy).
    @ObservationIgnored var mayWrite: () -> Bool = { true }

    @ObservationIgnored private var detector = FlightDetector()
    @ObservationIgnored private var grounds: () -> any AirportGroundsLookup
    @ObservationIgnored private var iataCode: (String) -> String?
    @ObservationIgnored private var vault: WorldMapVault?
    @ObservationIgnored private var lastAt: Date?
    @ObservationIgnored private var recentFlights: [DateInterval] = []
    @ObservationIgnored private var savedAt: Date?
    @ObservationIgnored private var pending: [FlightEvent] = []
    /// The bundled airport list, opened once on first use (the import sheet and the Flights page read it too).
    @ObservationIgnored let airportsShelf: WorldAirportsShelf

    /// The sealed file the detector's state is kept in: the device side's purpose and buffer key, bound to its
    /// own context so it never opens as another file (as "Remember this place" does).
    static let stateFile = WorldMapVault.File(name: "flight-state.bin",
                                              purpose: WorldMapVault.File.placesDevice.purpose,
                                              role: .buffer, context: Data("flightDetector".utf8))
    /// The state is written at most this often while nothing changes.
    static let saveInterval: TimeInterval = 60
    /// How many ended flights a late reading is checked against.
    static let maxRecentFlights = 8
    /// The most changes kept waiting for the passport (the newest kept).
    static let maxPendingEvents = 32

    /// A keeper placing readings in `grounds` and naming airports by `iataCode` (a token's IATA code); the
    /// bundled `WorldAirports.pack` by default, opened on first use.
    init(grounds: (() -> any AirportGroundsLookup)? = nil, iataCode: ((String) -> String?)? = nil) {
        let shelf = WorldAirportsShelf()
        airportsShelf = shelf
        self.grounds = grounds ?? { shelf.lookup() }
        self.iataCode = iataCode ?? { shelf.iata(of: $0) }
        publish()
        latestFind = UITestSupport.airportHomeFind(now: Date())
    }

    /// Places readings in `grounds` and names airports by `iataCode` from now on (tests' made-up airports).
    func useAirports(_ grounds: @escaping () -> any AirportGroundsLookup, iataCode: @escaping (String) -> String?) {
        self.grounds = grounds
        self.iataCode = iataCode
    }

    /// Keeps the state in `vault`, reading what was kept there (the store, once its vault is ready).
    func attach(vault: WorldMapVault) {
        guard self.vault == nil else { return }
        self.vault = vault
        do {
            if let data = try vault.read(Self.stateFile) {
                detector = try JSONDecoder().decode(FlightDetector.self, from: data)
                publish()
            }
        } catch {
            FernletAuditLog.log("worldMap.flight.stateUnreadable")
        }
    }

    /// Whether `fix` may go on to the map's keepers: false while flying, for a reading that may be in the air, and
    /// for a late reading inside a flight.
    func admits(_ fix: WorldFix) -> Bool {
        if let lastAt, fix.at <= lastAt { return !isInFlight(fix.at) }
        lastAt = fix.at
        let reading = FlightFix(point: fix.point, at: fix.at, accuracy: fix.accuracy, speed: fix.speed,
                                altitude: fix.altitude, verticalAccuracy: fix.verticalAccuracy)
        let verdict = detector.observe(reading, airports: grounds(), isHome: isHome)
        rememberFlights(in: verdict.events)
        noteFinds(in: verdict.events)
        publish()
        save(at: fix.at, changed: !verdict.events.isEmpty)
        hand(pending + verdict.events)
        return verdict.mayKeep
    }

    /// How long since the landing, while still inside the grounds (the layover counter, §5); nil when not landed.
    func layoverDuration(at now: Date) -> TimeInterval? {
        layoverStart.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Whether `date` falls inside the flight under way or one that ended recently.
    func isInFlight(_ date: Date) -> Bool {
        if isFlying, let departed = detector.flightDeparted, date >= departed { return true }
        return recentFlights.contains { $0.contains(date) }
    }

    /// The passport's record of a flight Fernlet saw: its two airports' IATA codes and times; nil when either
    /// airport has no IATA code or is unknown.
    func flight(from origin: String?, to token: String, departed: Date, arrived: Date) -> PassportFlight? {
        guard let origin, let from = iataCode(origin), let to = iataCode(token) else { return nil }
        return PassportFlight(from: from, to: to, departure: departed, arrival: arrived, sources: .fernlet)
    }

    /// Hands `events` to ``onEvents``, keeping them (the newest ``maxPendingEvents``) when it could not take them.
    private func hand(_ events: [FlightEvent]) {
        guard !events.isEmpty else { return }
        let taken = onEvents?(events) ?? true
        pending = taken ? [] : Array(events.suffix(Self.maxPendingEvents))
    }

    /// Notes each flight that ended, for late readings (the newest ``maxRecentFlights``).
    private func rememberFlights(in events: [FlightEvent]) {
        for event in events {
            switch event {
            case .landed(_, _, let departed, let at), .endedWithoutAirport(_, let departed, let at):
                recentFlights.append(DateInterval(start: departed, end: max(departed, at)))
            default:
                continue
            }
        }
        if recentFlights.count > Self.maxRecentFlights { recentFlights.removeFirst(recentFlights.count - Self.maxRecentFlights) }
    }

    /// Notes the latest airport found among `events` (the last one wins: a landing's find comes with it).
    private func noteFinds(in events: [FlightEvent]) {
        for event in events {
            if case .airportFound(let token, let how, let at) = event {
                latestFind = WorldAirportFind(token: token, how: how, at: at)
            }
        }
    }

    /// Mirrors the detector's state for the screens (or the DEBUG scene's made-up state), writing only what changed.
    private func publish() {
        let state = UITestSupport.airportHomeState(now: Date()) ?? WorldFlightGateState(detector, at: lastAt)
        if isFlying != state.isFlying { isFlying = state.isFlying }
        if layoverAirport != state.layoverAirport { layoverAirport = state.layoverAirport }
        if layoverStart != state.layoverStart { layoverStart = state.layoverStart }
        if currentAirport != state.currentAirport { currentAirport = state.currentAirport }
        if isOnTrip != state.isOnTrip { isOnTrip = state.isOnTrip }
        if showsTravelLook != state.showsTravelLook { showsTravelLook = state.showsTravelLook }
    }

    /// Seals the detector's state when something changed, or ``saveInterval`` after the last write.
    private func save(at date: Date, changed: Bool) {
        guard let vault, mayWrite() else { return }
        guard changed || savedAt.map({ date.timeIntervalSince($0) >= Self.saveInterval }) ?? true else { return }
        do {
            try vault.write(JSONEncoder().encode(detector), to: Self.stateFile)
            savedAt = date
        } catch {
            FernletAuditLog.log("worldMap.flight.saveDeferred")
        }
    }
}

/// What Home reads of the flight gate at one moment (World-Airports-Spec §5, §6.2): a plain value mirrored from the
/// ``FlightDetector`` after each reading, or made up by a DEBUG scene. No display strings; airport tokens only.
nonisolated struct WorldFlightGateState: Equatable, Sendable {
    var isFlying = false
    /// The airport landed at, while still inside its grounds.
    var layoverAirport: String?
    /// When that landing was.
    var layoverStart: Date?
    /// The airport whose grounds hold the person, when not flying.
    var currentAirport: String?
    var isOnTrip = false
    var showsTravelLook = false

    /// A state with every field given (the DEBUG scenes').
    init(isFlying: Bool = false, layoverAirport: String? = nil, layoverStart: Date? = nil, currentAirport: String? = nil,
         isOnTrip: Bool = false, showsTravelLook: Bool = false) {
        self.isFlying = isFlying
        self.layoverAirport = layoverAirport
        self.layoverStart = layoverStart
        self.currentAirport = currentAirport
        self.isOnTrip = isOnTrip
        self.showsTravelLook = showsTravelLook
    }

    /// The detector's state as of its last reading at `lastAt`: the landing's time is that reading's less the
    /// layover so far (the detector keeps the landing itself private).
    init(_ detector: FlightDetector, at lastAt: Date?) {
        isFlying = detector.isFlying
        layoverAirport = detector.layoverAirport
        layoverStart = lastAt.flatMap { at in detector.layoverDuration(at: at).map { at.addingTimeInterval(-$0) } }
        currentAirport = detector.currentAirport
        isOnTrip = detector.isOnTrip
        showsTravelLook = detector.showsTravelLook
    }
}

/// An airport the flight gate found: its token, how, and when (the reading's own time, which the passport's first
/// visit or new trip carries too, so Home can tell a landing's stamp from a ten minutes' one).
nonisolated struct WorldAirportFind: Equatable, Sendable {
    let token: String
    let how: FlightFinding
    let at: Date
}

/// No airports: nothing is inside any grounds.
nonisolated struct NoAirports: AirportGroundsLookup {
    func airports(containing point: GeoPoint) -> [WorldAirport] { [] }
}
