import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Subway hops (owner 2026-11-21): a ride with no GPS is told afterwards from a gap in good readings, Motion's
/// history for the gap and the distance between the readings either side; it is kept as a trip of two points that
/// lifts no fog and counts on no way, drawn dotted, and its sheet asks Apple Maps for the stations. And the replay
/// of the side effect the city-walk investigation suspected: a drive dated back from Motion's history that ends on
/// foot in the same step must not look up a hotel.
@MainActor
struct WorldSubwayHopTests {
    typealias Stream = WorldRidesTests.Stream
    private static let here = Stream.here
    private static let start = Stream.start

    /// A reading `east` metres along at `second`.
    private static func fix(_ east: Double, _ second: Double, accuracy: Double = 8, speed: Double? = nil,
                            carLinked: Bool = false, atAirport: Bool = false) -> WorldFix {
        WorldFix(point: here.offset(east: east, north: 0), accuracy: accuracy, at: start.addingTimeInterval(second),
                 isPrecise: true, speed: speed, carLinked: carLinked, atAirport: atAirport)
    }

    private static func sample(_ kind: WorldMotionKind, _ second: Double, confident: Bool = true) -> WorldMotionSample {
        WorldMotionSample(kind: kind, isConfident: confident, at: start.addingTimeInterval(second))
    }

    /// The owner's ride of 2026-11-20 in outline: 3 km in a 15-minute gap, about nine minutes of it on the train.
    private static let ride = WorldSubwayHopCandidate(from: here, left: start, to: here.offset(east: 3_000, north: 0),
                                                      arrived: start.addingTimeInterval(900))
    private static let rideMotion = [sample(.walking, 5), sample(.stationary, 150), sample(.automotive, 240),
                                     sample(.walking, 780)]

    // MARK: The rules

    /// A good reading 3 km on after a quarter of an hour without one is a candidate; rough readings in the gap (a
    /// metro with mobile coverage hands some on) neither end it nor start it.
    @Test func aGapInGoodReadingsIsACandidate() {
        var watch = WorldSubwayHopWatch()
        #expect(watch.observe(Self.fix(0, 0), moving: false) == nil)
        for (east, second) in [(600.0, 200.0), (1_400, 460), (2_300, 770)] {
            #expect(watch.observe(Self.fix(east, second, accuracy: 900), moving: false) == nil, "a rough reading underground")
        }
        let found = watch.observe(Self.fix(3_000, 900), moving: false)
        #expect(found == Self.ride)
        #expect(watch.observe(Self.fix(3_010, 908), moving: false) == nil, "the gap is over")
    }

    /// No candidate from a short gap, a short way, a speed no train reaches, a drive or a ride under way, a known
    /// car connected at either end, an airport, or approximate location.
    @Test func whatIsNoCandidate() {
        func found(_ before: WorldFix, _ after: WorldFix, moving: Bool = false) -> Bool {
            var watch = WorldSubwayHopWatch()
            _ = watch.observe(before, moving: false)
            return watch.observe(after, moving: moving) != nil
        }
        #expect(found(Self.fix(0, 0), Self.fix(3_000, 900)))
        #expect(!found(Self.fix(0, 0), Self.fix(3_000, 170)), "under three minutes")
        #expect(!found(Self.fix(0, 0), Self.fix(450, 900)), "under 500 m")
        #expect(!found(Self.fix(0, 0), Self.fix(30_000, 900)), "120 km/h: no subway")
        #expect(!found(Self.fix(0, 0), Self.fix(90_000, 3 * 3_600)), "longer than two hours")
        #expect(!found(Self.fix(0, 0), Self.fix(3_000, 900), moving: true))
        #expect(!found(Self.fix(0, 0, carLinked: true), Self.fix(3_000, 900)))
        #expect(!found(Self.fix(0, 0), Self.fix(3_000, 900, carLinked: true)))
        #expect(!found(Self.fix(0, 0), Self.fix(3_000, 900, atAirport: true)), "the plane train")
        var approximate = WorldSubwayHopWatch()
        _ = approximate.observe(Self.fix(0, 0), moving: false)
        let rough = WorldFix(point: Self.here.offset(east: 3_000, north: 0), accuracy: 8, at: Self.start.addingTimeInterval(900), isPrecise: false)
        #expect(approximate.observe(rough, moving: false) == nil)
    }

    /// Motion's automotive time is counted inside the gap only, from confident samples, each holding until the next.
    @Test func automotiveTimeIsCountedInsideTheGap() {
        let end = Self.start.addingTimeInterval(900)
        #expect(WorldSubwayHopWatch.automotiveSeconds(in: Self.rideMotion, from: Self.start, to: end) == 540)
        #expect(WorldSubwayHopWatch.automotiveSeconds(in: [], from: Self.start, to: end) == 0)
        let still = [Self.sample(.automotive, 600)]
        #expect(WorldSubwayHopWatch.automotiveSeconds(in: still, from: Self.start, to: end) == 300, "still automotive at the end")
        let early = [Self.sample(.automotive, -300), Self.sample(.walking, 200)]
        #expect(WorldSubwayHopWatch.automotiveSeconds(in: early, from: Self.start, to: end) == 200, "clamped to the gap")
        let unsure = [Self.sample(.automotive, 100), Self.sample(.walking, 160, confident: false), Self.sample(.walking, 400)]
        #expect(WorldSubwayHopWatch.automotiveSeconds(in: unsure, from: Self.start, to: end) == 300, "a low-confidence sample decides nothing")
    }

    /// A hop needs Motion to have said automotive for most of the gap, at a train's pace over that time: a walk, a
    /// long wait, a crawl and a sprint are none.
    @Test func aHopNeedsMotionsAutomotiveAtATrainsPace() {
        #expect(WorldSubwayHopWatch.isHop(Self.ride, automotive: 540), "3 km in nine minutes: 20 km/h")
        #expect(!WorldSubwayHopWatch.isHop(Self.ride, automotive: 0), "Motion never said automotive: a walk, or no Motion")
        #expect(!WorldSubwayHopWatch.isHop(Self.ride, automotive: 300), "under half the gap")
        #expect(!WorldSubwayHopWatch.isHop(Self.ride, automotive: 100), "under two minutes")
        let slow = WorldSubwayHopCandidate(from: Self.here, left: Self.start, to: Self.here.offset(east: 600, north: 0),
                                           arrived: Self.start.addingTimeInterval(600))
        #expect(!WorldSubwayHopWatch.isHop(slow, automotive: 500), "4 km/h: a jam, not a train")
        #expect(abs(WorldSubwayHopWatch.minSpeed * 3.6 - 15) < 0.001 && abs(WorldSubwayHopWatch.maxSpeed * 3.6 - 80) < 0.001)
        #expect(WorldSubwayHopWatch.minMetres == 500 && WorldSubwayHopWatch.minGap == 180)
    }

    // MARK: The location source

    /// The source asks Motion about a candidate's gap and hands the hop on; with Motion not read it asks
    /// nothing and finds none.
    @Test func theSourceAsksMotionOnceAndHandsTheHopOn() async {
        for usesMotion in [true, false] {
            let motion = HopMotion(script: Self.rideMotion)
            let source = WorldLocationSource(backgroundMapping: { true })
            source.rides.replaceMotion(with: motion)
            source.rides.usesMotion = usesMotion
            var hops: [WorldSubwayHopCandidate] = []
            source.onSubwayHop = { hops.append($0) }
            source.deliver(Self.fix(0, 0, speed: 1.2))
            await source.rides.motionQuery?.value
            source.deliver(Self.fix(3_000, 900, speed: 1.2))
            await source.hopQuery?.value
            await source.rides.motionQuery?.value
            #expect(hops == (usesMotion ? [Self.ride] : []), "usesMotion \(usesMotion)")
            #expect(motion.queries.isEmpty == !usesMotion, "Motion not read: nothing is asked")
        }
    }

    // MARK: The suspected side effect (investigation section 2), replayed

    /// Surfacing after a ride: the first reading (no speed of its own, too long after the last for a pace) asks for
    /// Motion's history, which says automotive for the ride and walking since. Before 2026-11-20 that started a
    /// drive dated back to when the train left and ended it on foot in the same step. Nothing may start: the ride
    /// is over, and there is nothing to trace.
    @Test func aRideAlreadyOverInMotionsHistoryStartsNoDrive() {
        var stream = Stream(usesMotion: true)
        stream.read(0, 0, speed: 1.2)
        stream.motion(.walking, 5, through: 30)
        stream.read(3_000, 900)
        stream.query([(.automotive, 240, true), (.walking, 780, true)], through: 900)
        #expect(stream.drivesStarted == 0 && stream.drivesEnded == 0, "\(stream.events)")
        #expect(!stream.watch.isDriving && stream.watch.lastDriveEnd == nil)
    }

    /// A drive still on when the history ends is found as ever (a wake in the middle of a real drive), and so is one
    /// whose car is connected, which Motion's walking never ends.
    @Test func aDriveStillOnInMotionsHistoryIsFoundAsEver() {
        var stream = Stream(usesMotion: true)
        stream.read(0, 0, speed: 1.2)
        stream.read(3_000, 900)
        stream.query([(.automotive, 240, true)], through: 900)
        #expect(stream.drivesStarted == 1 && stream.watch.isDriving)
        var linked = Stream(usesMotion: true)
        linked.watch.carLinked = true
        linked.read(0, 0, speed: 1.2)
        linked.read(3_000, 900)
        linked.query([(.automotive, 240, true), (.walking, 780, true)], through: 900)
        #expect(linked.drivesStarted == 1 && linked.watch.isDriving, "\(linked.events)")
    }

    /// The same replay through the location source: no drive callback, no cool-down, and Apple Maps is asked
    /// nothing about hotels; the hop is found instead.
    @Test func surfacingAfterARideLooksUpNoHotel() async {
        let source = WorldLocationSource(backgroundMapping: { true })
        source.rides.replaceMotion(with: HopMotion(script: Self.rideMotion))
        source.rides.usesMotion = true
        let finder = CountingFinder()
        source.hotelOffers.finder = finder
        source.hotelOffers.mayLook = { _ in true }
        var driving: [Bool] = []
        let heard = source.rides.onDrivingChanged
        source.rides.onDrivingChanged = { on in
            driving.append(on)
            heard?(on)
        }
        var hops = 0
        source.onSubwayHop = { _ in hops += 1 }
        source.deliver(Self.fix(0, 0, speed: 1.2))
        await source.rides.motionQuery?.value
        source.deliver(Self.fix(3_000, 900))
        await source.rides.motionQuery?.value
        await source.hopQuery?.value
        await source.hotelOffers.lookup?.value
        #expect(driving.isEmpty, "\(driving)")
        #expect(finder.asked == 0 && source.hotelOffers.offer == nil)
        #expect(!source.isCoolingDown && source.trace == nil)
        #expect(hops == 1)
    }

    // MARK: Kept as a trip

    private static func keeper(_ vault: WorldMapVault, mapping: Bool = true) throws -> WorldFogKeeper {
        let defaults = try #require(UserDefaults(suiteName: "WorldSubwayHopTests.\(UUID().uuidString)"))
        defaults.set(mapping, forKey: WorldMapPreferences.Key.alwaysLowPower)
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        keeper.load()
        return keeper
    }

    /// A hop is kept as an unconfirmed subway trip of two points: it lifts no fog, counts on no way, never shows
    /// among a road's rides, is never asked about, survives a relaunch, and Forget removes it.
    @Test func aHopIsKeptAsATripThatLiftsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault)
        #expect(keeper.keepSubwayHop(Self.ride))
        let summary = try #require(keeper.wornTrips.first)
        #expect(keeper.wornTrips.count == 1 && summary.kind == .subway && !summary.confirmed && !summary.unsure)
        #expect(keeper.visibleCells.isEmpty && keeper.drivenCells.isEmpty, "no fog lifted")
        #expect(keeper.wornWays.isEmpty, "nothing counted")
        let kept = try keeper.tripStore.trip(summary.id)
        #expect(keeper.transitQuestion == nil && kept != nil && WornTransitQuestion(kept) == nil)
        let hop = try #require(keeper.subwayHops().first)
        #expect(hop.id == summary.id && hop.start == Self.ride.left && hop.end == Self.ride.arrived)
        #expect(hop.from.distance(to: Self.ride.from) < 2 && hop.to.distance(to: Self.ride.to) < 2)
        let under = MercatorHexGrid.cell(containing: Self.here.offset(east: 40, north: 0))
        #expect(keeper.trips(through: under).isEmpty, "a road's sheet never lists a hop that crosses it")

        let reopened = try Self.keeper(vault)
        #expect(reopened.subwayHops() == [hop])
        reopened.forgetTrip(hop.id)
        #expect(reopened.wornTrips.isEmpty && reopened.subwayHops().isEmpty)
    }

    /// Nothing is kept in a decoy or with background mapping off, and a decoy shows no hop.
    @Test func noHopInADecoyOrWithBackgroundMappingOff() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let off = try Self.keeper(vault, mapping: false)
        #expect(!off.keepSubwayHop(Self.ride) && off.wornTrips.isEmpty)
        let keeper = try Self.keeper(vault)
        #expect(keeper.keepSubwayHop(Self.ride))
        keeper.setDecoy(true)
        #expect(!keeper.keepSubwayHop(Self.ride) && keeper.subwayHops().isEmpty)
        keeper.setDecoy(false)
        #expect(keeper.subwayHops().count == 1)
        _ = keeper.clearAll()
        #expect(keeper.wornTrips.isEmpty && keeper.subwayHops().isEmpty, "the wipe forgets it")
    }

    /// The subway kind is a new frozen token beside the three: 4, and the trip codec carries it.
    @Test func theSubwayKindIsAFrozenToken() throws {
        #expect(WornWayKind.road.rawValue == 1 && WornWayKind.rail.rawValue == 2 && WornWayKind.ferry.rawValue == 3)
        #expect(WornWayKind.subway.rawValue == 4 && WornWayKind.allCases.count == 4)
        let trip = WornTrip(kind: .subway, confirmed: false, day: 12, start: Self.start, end: Self.start.addingTimeInterval(900),
                            line: WornTripCodec.quantized([Self.ride.from, Self.ride.to]))
        let decoded = try #require(WornTripCodec.decode(WornTripCodec.encode([(trip, false)]), limit: 5))
        #expect(decoded.first?.trip == trip)
        #expect(!WornWayCopy.otherKinds(than: .road).contains(.subway) && !WornWayCopy.otherKinds(than: .rail).contains(.subway))
    }

    // MARK: The tap and the stations

    /// A tap within a finger of the dotted line finds the hop, anywhere along it and not beyond its ends.
    @Test func aTapOnTheDottedLineFindsTheHop() {
        let hop = WorldSubwayHop(id: UUID(), from: Self.here, to: Self.here.offset(east: 3_000, north: 0),
                                 start: Self.start, end: Self.start.addingTimeInterval(900))
        let other = WorldSubwayHop(id: UUID(), from: Self.here.offset(east: 0, north: 400), to: Self.here.offset(east: 3_000, north: 400),
                                   start: Self.start, end: Self.start.addingTimeInterval(900))
        let hops = [hop, other]
        #expect(WorldSubwayHopLookup.hop(at: Self.here.offset(east: 1_500, north: 20), within: 40, hops: hops) == hop)
        #expect(WorldSubwayHopLookup.hop(at: Self.here.offset(east: 1_500, north: 390), within: 40, hops: hops) == other)
        #expect(WorldSubwayHopLookup.hop(at: Self.here.offset(east: 1_500, north: 200), within: 40, hops: hops) == nil)
        #expect(WorldSubwayHopLookup.hop(at: Self.here.offset(east: 3_200, north: 0), within: 40, hops: hops) == nil, "past the end")
        #expect(WorldSubwayHopLookup.hop(at: Self.here, within: 40, hops: []) == nil)
        let away = WorldSubwayHopLookup.distance(from: Self.here.offset(east: 1_000, north: 100), toLineFrom: hop.from, to: hop.to)
        #expect(abs(away - 100) < 2)
    }

    /// The sheet asks Apple Maps for stations round each end, 400 m, the station kind only, and names the nearest;
    /// no answer at all is nil, and an end with no station is left unnamed.
    @Test func theSheetNamesTheNearestStationAtEachEnd() async {
        let hop = WorldSubwayHop(id: UUID(), from: Self.here, to: Self.here.offset(east: 3_000, north: 0),
                                 start: Self.start, end: Self.start.addingTimeInterval(900))
        let finder = CountingFinder()
        finder.answers = [
            [WorldNearbyPlace(category: .station, name: "Far", point: hop.from.offset(east: 300, north: 0)),
             WorldNearbyPlace(category: .station, name: "Place-des-Arts", point: hop.from.offset(east: 50, north: 0)),
             WorldNearbyPlace(category: .hotel, name: "An inn", point: hop.from)],
            []
        ]
        let found = await SubwayHopStations.look(for: hop, finder: finder)
        #expect(found?.from == "Place-des-Arts" && found?.to == nil)
        #expect(finder.asked == 2 && finder.radii == [400, 400] && finder.kinds == [[.station], [.station]])
        finder.answers = [nil, nil]
        #expect(await SubwayHopStations.look(for: hop, finder: finder) == nil, "offline")
        #expect(AppleNearbyFinder.category(of: AppleNearbyFinder.appleCategory(.station)) == .station)
    }
}

/// Motion's history as a test scripts it, with each query's interval.
@MainActor
private final class HopMotion: WorldMotionReading {
    var permission: WorldMotionPermission = .allowed
    let script: [WorldMotionSample]
    private(set) var queries: [(start: Date, end: Date)] = []

    init(script: [WorldMotionSample]) {
        self.script = script
    }

    func requestAccess() async -> Bool { true }

    func samples(from start: Date, to end: Date) async -> [WorldMotionSample] {
        queries.append((start, end))
        return script.filter { $0.at >= start && $0.at <= end }
    }
}

/// Apple Maps as a test sets it: the answers to hand back in turn (the last repeats), and what was asked.
@MainActor
private final class CountingFinder: WorldNearbyFinding {
    var answers: [[WorldNearbyPlace]?] = [[]]
    private(set) var asked = 0
    private(set) var radii: [Double] = []
    private(set) var kinds: [[WorldNearbyCategory]] = []

    func places(around point: GeoPoint, radius: Double, categories: [WorldNearbyCategory]) async -> [WorldNearbyPlace]? {
        let answer = answers[min(asked, answers.count - 1)]
        asked += 1
        radii.append(radius)
        kinds.append(categories)
        return answer
    }
}
