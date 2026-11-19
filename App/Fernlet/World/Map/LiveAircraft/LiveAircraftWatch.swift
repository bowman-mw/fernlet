import FernletFoundation
import Foundation
import WorldMapStore

/// The planes in the sky over the map, held in memory only (owner 2026-11-19: "Nothing about the planes is saved").
/// Pure: each fetch's answer merges in, and a plane no answer has seen for ``fadeAfter`` is gone.
nonisolated struct LiveAircraftSky: Equatable, Sendable {
    /// How long a plane stays after its last reading, in seconds, fading over the last ``fadeSpan``.
    static let fadeAfter: TimeInterval = 60
    /// How long the fade takes, in seconds.
    static let fadeSpan: TimeInterval = 15
    /// The longest a plane is carried forward along its track, in seconds.
    static let longestGlide: TimeInterval = 75
    /// The most planes held at once.
    static let maxPlanes = 600

    /// The planes, by transponder address.
    var planes: [String: LiveAircraft] = [:]

    /// The sky after a fetch's `answer` at `now`: every plane in the answer as it reads now, plus the planes the answer
    /// missed that were seen in the last ``fadeAfter``.
    func merging(_ answer: [LiveAircraft], at now: Date) -> LiveAircraftSky {
        var next = planes.filter { now.timeIntervalSince($0.value.seenAt) < Self.fadeAfter }
        // Bounded: at most `LiveAircraftFeed.maxAircraft` planes.
        for plane in answer.prefix(LiveAircraftFeed.maxAircraft) {
            if let held = next[plane.id], held.seenAt > plane.seenAt { continue }
            next[plane.id] = plane
        }
        guard next.count > Self.maxPlanes else { return LiveAircraftSky(planes: next) }
        let newest = next.values.sorted { $0.seenAt > $1.seenAt }.prefix(Self.maxPlanes)
        return LiveAircraftSky(planes: Dictionary(uniqueKeysWithValues: newest.map { ($0.id, $0) }))
    }

    /// The planes still showing at `now`.
    func showing(at now: Date) -> [LiveAircraft] {
        planes.values.filter { opacity(of: $0, at: now) > 0 }.sorted { $0.id < $1.id }
    }

    /// How opaque `plane` draws at `now`: whole until the fade, then down to nothing at ``fadeAfter``.
    func opacity(of plane: LiveAircraft, at now: Date) -> Double {
        let age = now.timeIntervalSince(plane.seenAt)
        guard age < Self.fadeAfter else { return 0 }
        return min(1, max(0, (Self.fadeAfter - age) / Self.fadeSpan))
    }

    /// Where `plane` is at `now`: carried along its track at its ground speed since its reading (``longestGlide`` at
    /// most), or where it was read when `glides` is false (Reduce Motion: placed at each fetch, no glide).
    static func position(of plane: LiveAircraft, at now: Date, glides: Bool) -> GeoPoint {
        guard glides, let track = plane.trackDegrees, let knots = plane.groundSpeedKnots, knots > 0 else { return plane.position }
        let seconds = min(max(0, now.timeIntervalSince(plane.seenAt)), longestGlide)
        let metres = knots * 1_852 / 3_600 * seconds
        let radians = track * .pi / 180
        return plane.position.offset(east: sin(radians) * metres, north: cos(radians) * metres)
    }
}

/// The planes the person has flown on, from their own flight records (owner 2026-11-19: "label it if it's a plane
/// you've been on before"): tail numbers, and types as ICAO codes. Matched on the phone; nothing leaves it. Pure.
nonisolated struct LiveAircraftFlown: Equatable, Sendable {
    /// The tails flown on, as ``PassportFlight/tailKey(_:)`` keys.
    var tails: Set<String> = []
    /// The types flown, as ICAO codes.
    var types: Set<String> = []

    /// The most flights read.
    static let maxFlights = 5_000

    /// What `flights` say was flown.
    init(flights: [PassportFlight]) {
        // Bounded: at most `maxFlights` flights.
        for flight in flights.prefix(Self.maxFlights) {
            if let tail = flight.tailNumber {
                let key = PassportFlight.tailKey(tail)
                if !key.isEmpty { tails.insert(key) }
            }
            types.formUnion(LiveAircraftTypes.codes(forName: flight.aircraftType))
        }
    }

    /// Nothing flown.
    init() {}

    /// How `plane` matches what was flown.
    func match(_ plane: LiveAircraft) -> LiveAircraftFlownMatch {
        if let registration = plane.registration, tails.contains(PassportFlight.tailKey(registration)) { return .samePlane }
        if let code = plane.typeCode, types.contains(code) { return .sameType }
        return .none
    }
}

/// How a live plane matches the person's own flights.
nonisolated enum LiveAircraftFlownMatch: Equatable, Sendable {
    /// Not flown.
    case none
    /// The same type as a plane flown on: a light label.
    case sameType
    /// The very plane (same tail number): a label.
    case samePlane
}

/// When live planes are fetched, and what came back (owner 2026-11-19, calls 3, 4 and 6): the 0.5° cell under the
/// visible map's centre, wherever the map is, every ``LiveAircraftBudget/interval`` while Home's map is in front and the
/// app is active, within the daily cap and the budget's rests (after a 429, and doubling after failed fetches). Main actor, held by ``LiveAircraftLayer``; its loop is the layer's task, so it
/// stops the moment the map leaves the front, the app leaves the foreground or the mid-flight screen takes Home.
@MainActor
@Observable
final class LiveAircraftWatch {
    /// How long a pan rests on a new cell before it is fetched, so a long pan doesn't fetch every cell it crosses.
    static let settle: Duration = .milliseconds(1_500)
    /// The most fetches one session of the loop makes (four hours at 30 s); the loop ends sooner when the map leaves.
    static let maxFetches = 480
    /// The widest view live planes are fetched for, in metres tall: past this a 50 NM circle is a dot.
    static let maxViewHeightMetres = 700_000.0

    /// The sky now.
    private(set) var sky = LiveAircraftSky()
    /// The cell `sky` was fetched for.
    private(set) var cell: LiveAircraftCell?
    /// Whether today's cap is spent (the planes rest until tomorrow).
    private(set) var isSpent = false
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private let transport: any LiveAircraftTransporting
    @ObservationIgnored private let defaults: UserDefaults

    /// A watch fetching through `transport`, its daily tally in `defaults`.
    init(transport: any LiveAircraftTransporting = EphemeralLiveAircraftTransport(), defaults: UserDefaults = .standard) {
        self.transport = transport
        self.defaults = defaults
    }

    /// Fetches `cell` now and every ``LiveAircraftBudget/interval`` after, while the task lives and the switch stays on.
    func watch(_ cell: LiveAircraftCell) async {
        if cell != self.cell { sky = LiveAircraftSky() }
        self.cell = cell
        FernletAuditLog.log("liveAircraft.watch.started")
        do {
            try await Task.sleep(for: Self.settle)
            // Bounded: at most `maxFetches` fetches; the task is cancelled when the map leaves the front.
            for _ in 0..<Self.maxFetches {
                if let lastFetch {
                    let wait = LiveAircraftBudget.interval - Date().timeIntervalSince(lastFetch)
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                }
                await fetchOnce(cell)
                try await Task.sleep(for: .seconds(LiveAircraftBudget.interval))
            }
        } catch {
            return
        }
    }

    /// One fetch of `cell`, if the switch is on and the budget allows (the cap, and no rest after a 429 or failed
    /// fetches). A fetch that failed because its task was cancelled (the map left the front, or panned to another
    /// cell) is no failure of adsb.lol's and earns no rest.
    func fetchOnce(_ cell: LiveAircraftCell, now: Date = Date()) async {
        let enabled = WorldMapPreferences.showsLivePlanes(in: defaults)
        var budget = WorldMapPreferences.livePlanesBudget(in: defaults, now: now)
        isSpent = budget.isSpent(at: now)
        guard enabled, budget.allows(at: now) else {
            FernletAuditLog.log(enabled ? "liveAircraft.fetch.resting" : "liveAircraft.fetch.off")
            return
        }
        budget = budget.spending(at: now)
        WorldMapPreferences.setLivePlanesBudget(budget, in: defaults)
        lastFetch = now
        let outcome = await LiveAircraftClient.fetch(cell, enabled: enabled, appVersion: Self.appVersion, transport: transport)
        let answered = Date()
        FernletAuditLog.log("liveAircraft.fetch." + Self.outcomeName(outcome))
        if !(Task.isCancelled && outcome == .failed) {
            WorldMapPreferences.setLivePlanesBudget(
                WorldMapPreferences.livePlanesBudget(in: defaults, now: answered).answered(outcome, at: answered), in: defaults)
        }
        guard !Task.isCancelled, self.cell == cell, case .planes(let planes) = outcome else { return }
        sky = sky.merging(planes, at: answered)
    }

    /// An outcome's name for the audit log: its kind only, never a plane, a cell or a count.
    static func outcomeName(_ outcome: LiveAircraftFetchOutcome) -> String {
        switch outcome {
        case .planes: "answered"
        case .rateLimited: "rateLimited"
        case .notPermitted: "notPermitted"
        case .failed: "failed"
        }
    }

    /// Forgets the sky (the switch turned off, or a decoy began).
    func clear() {
        sky = LiveAircraftSky()
        cell = nil
    }

    /// The app's version, digits and dots, for the User-Agent.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// The cell to fetch for a map showing `viewport`, or nil when the view is too wide to be worth it.
    static func cell(for viewport: MapViewport, size: CGSize) -> LiveAircraftCell? {
        guard viewport.isUsable, size.height > 0 else { return nil }
        let centre = viewport.center
        let metresTall = Double(size.height) / max(viewport.pointsPerMetre(at: centre.latitude, in: size), 1e-12)
        guard metresTall <= maxViewHeightMetres else { return nil }
        return LiveAircraftCell(containing: centre)
    }
}
