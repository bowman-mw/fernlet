import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import WorldMapStore
@testable import Fernlet

/// Car and bike detection's engine (round 7; `b1-home-car`, `b1-home-bike`): simulated streams of readings
/// and motion samples through ``WorldRideWatch`` and ``WorldRideKeeper``. A drive survives red lights and
/// traffic, a bike ride with Motion logs once, a fast bike is no drive, and a walk is neither.
@MainActor
struct WorldRidesTests {
    /// A watch fed a stream, collecting what changed.
    struct Stream {
        static let here = GeoPoint(45.5205, -122.6255)
        static let start = Date(timeIntervalSince1970: 2_000_000_000)

        var watch = WorldRideWatch()
        var events: [WorldRideEvent] = []

        init(usesMotion: Bool = false) {
            watch.usesMotion = usesMotion
        }

        /// A precise reading `east` (and `north`) metres along at `second`, with CoreLocation's `speed` when given.
        mutating func read(_ east: Double, _ second: Double, speed: Double? = nil, accuracy: Double = 8, north: Double = 0) {
            let fix = WorldFix(point: Self.here.offset(east: east, north: north), accuracy: accuracy,
                               at: Self.start.addingTimeInterval(second), isPrecise: true, speed: speed)
            events += watch.observe(fix)
        }

        /// A motion sample of `kind` from `second`, the activity known through `through` when given.
        mutating func motion(_ kind: WorldMotionKind, _ second: Double, confident: Bool = true, through: Double? = nil) {
            let sample = WorldMotionSample(kind: kind, isConfident: confident, at: Self.start.addingTimeInterval(second))
            events += watch.observe([sample], through: through.map { Self.start.addingTimeInterval($0) })
        }

        /// A motion query's samples (`kind`, second, confident) as the keeper hands them on, known through `through`.
        mutating func query(_ samples: [(WorldMotionKind, Double, Bool)], through: Double) {
            let batch = samples.map { WorldMotionSample(kind: $0.0, isConfident: $0.2, at: Self.start.addingTimeInterval($0.1)) }
            events += watch.observe(batch, through: Self.start.addingTimeInterval(through))
        }

        mutating func tick(_ second: Double) {
            events += watch.tick(at: Self.start.addingTimeInterval(second))
        }

        var drivesStarted: Int { events.filter { if case .driveStarted = $0 { true } else { false } }.count }
        var drivesEnded: Int { events.filter { if case .driveEnded = $0 { true } else { false } }.count }
        var rides: [WorldBikeRide] { events.compactMap(\.bikeRide) }
    }

    // MARK: Driving

    /// A drive with three 90-second red lights stays one drive and logs nothing, by CoreLocation's speed, by
    /// the pace between readings, and with Motion saying car (a low-confidence "walking" at a light decides
    /// nothing). Parked, it ends: five minutes with nothing faster than walking, and with Motion no car.
    @Test func aDriveWithThreeRedLightsIsOneDrive() {
        for variant in ["speed", "pace", "motion"] {
            var stream = Stream(usesMotion: variant == "motion")
            if variant == "motion" { stream.motion(.automotive, 3) }
            let speed: (Double) -> Double? = { variant == "pace" ? nil : $0 }
            var second = 0.0, east = 0.0
            for _ in 0..<3 {
                for _ in 0..<24 {
                    second += 5
                    east += 75
                    stream.read(east, second, speed: speed(15))
                }
                second += 4
                east += 20
                stream.read(east, second, speed: speed(2))
                if variant == "motion" { stream.motion(.walking, second + 30, confident: false) }
                second += 90
                east += 10
                stream.read(east, second, speed: speed(4.5))
            }
            for _ in 0..<12 {
                second += 5
                east += 75
                stream.read(east, second, speed: speed(15))
            }
            #expect(stream.drivesStarted == 1 && stream.drivesEnded == 0 && stream.watch.isDriving, "\(variant)")
            stream.read(east + 15, second + 8, speed: speed(0.2))
            if variant == "motion" { stream.motion(.stationary, second + 10) }
            stream.tick(second + 4 * 60)
            #expect(stream.watch.isDriving, "four minutes parked is still the drive (\(variant))")
            stream.tick(second + 10 + WorldRideWatch.parkTime + 5)
            #expect(stream.drivesStarted == 1 && stream.drivesEnded == 1 && !stream.watch.isDriving, "parked (\(variant))")
            #expect(stream.rides.isEmpty, "a drive never logs (\(variant))")
        }
    }

    /// Stop-and-go traffic after pulling away (forty seconds at speed, then twenty seconds moving, forty
    /// crawling, half a minute standing, eight times) stays one drive by speed alone; with Motion saying car, three minutes of crawling at walking pace is still
    /// the drive, and a confident walking sample ends it.
    @Test func stopAndGoTrafficIsOneDrive() {
        var stream = Stream()
        var second = 0.0, east = 0.0
        for _ in 0...8 {
            stream.read(east, second, speed: 15)
            second += 5
            east += 75
        }
        for _ in 0..<8 {
            for _ in 0..<4 {
                second += 5
                east += 45
                stream.read(east, second, speed: 9)
            }
            for _ in 0..<6 {
                second += 7
                east += 10.5
                stream.read(east, second, speed: 1.5)
            }
            second += 30
            east += 3
            stream.read(east, second, speed: 0.1)
        }
        #expect(stream.drivesStarted == 1 && stream.drivesEnded == 0)

        var jam = Stream(usesMotion: true)
        jam.motion(.automotive, 0, through: WorldRideWatch.motionHold)
        #expect(jam.watch.isDriving, "a minute of the car's activity is the drive")
        jam.read(0, 5, speed: 15)
        for step in 1...18 {
            jam.read(Double(step) * 15, 5 + Double(step) * 10, speed: 1.5)
        }
        #expect(jam.watch.isDriving && jam.drivesEnded == 0, "a crawl with Motion saying car is the drive")
        jam.motion(.walking, 200)
        #expect(!jam.watch.isDriving && jam.drivesEnded == 1, "walking away ends it")
    }

    /// Without Motion a drive starts by speed: readings at a car's speed spanning half a minute, each within a
    /// minute of the last (two further apart are not), and one alone never, even at highway speed; it ends on
    /// foot after a minute at walking pace.
    @Test func aSpeedOnlyDriveStartsAndEndsOnFoot() {
        var stream = Stream()
        stream.read(0, 0, speed: 8)
        stream.read(720, 90, speed: 8)
        #expect(stream.drivesStarted == 0, "two car-speed readings ninety seconds apart")
        stream.read(960, 120, speed: 8)
        #expect(stream.events == [.driveStarted(Stream.start.addingTimeInterval(90))])
        for step in 1...6 {
            stream.read(960 + Double(step) * 14, 120 + Double(step) * 10, speed: 1.4)
        }
        #expect(stream.watch.isDriving, "fifty seconds on foot")
        stream.read(960 + 7 * 14, 190, speed: 1.4)
        #expect(stream.drivesEnded == 1 && !stream.watch.isDriving)

        var highway = Stream()
        highway.read(0, 0, speed: 13)
        highway.read(260, 20, speed: 13)
        #expect(highway.drivesStarted == 0, "twenty seconds at highway speed")
        highway.read(390, 30, speed: 13)
        #expect(highway.events == [.driveStarted(Stream.start)])
    }

    // MARK: Walking is never the car (owner's phone test 2026-10-30)

    /// Ten minutes on foot with GPS jitter of ±10 m every second, readings 20–25 m out, and two 80 m jumps, with
    /// no CoreLocation speed: the pace is never a car's (a second's jitter once read as 20 m/s, past highway
    /// speed), with Motion saying walking or without Motion.
    @Test func gpsJitterAndJumpsOnFootAreNoDrive() {
        for usesMotion in [false, true] {
            var stream = Stream(usesMotion: usesMotion)
            if usesMotion { stream.motion(.walking, 0) }
            for step in 0...600 {
                let second = Double(step)
                let jitter = Double((step * 37) % 21) - 10
                let jump = step == 150 || step == 420 ? 80.0 : 0
                stream.read(second * 1.4 + jump, second, accuracy: [10, 15, 20, 25][step % 4], north: jitter)
            }
            stream.tick(900)
            #expect(stream.drivesStarted == 0 && !stream.watch.isDriving, "usesMotion \(usesMotion): \(stream.events)")
        }
    }

    /// CoreLocation speed spikes on a walk (15 m/s once, 12 two seconds later, 13 half a minute after with
    /// walking readings between) are no drive: one fast reading, or a burst shorter than half a minute, never is.
    @Test func aSpeedSpikeOnFootIsNoDrive() {
        var stream = Stream()
        var east = 0.0
        for step in 0...300 {
            let second = Double(step) * 2
            east += 2.8
            let speed: Double = switch second {
            case 100: 15
            case 102: 12
            case 140: 13
            case 400, 404, 410, 420: 9
            default: 1.4
            }
            stream.read(east, second, speed: speed)
        }
        #expect(stream.events.isEmpty, "\(stream.events)")
    }

    /// Motion flickering on a walk, fed as the keeper feeds it (a query each half minute): a confident car
    /// sample for 30 s between walking, one for 30 s between standing and walking, a long low-confidence car,
    /// and a confident car for two minutes while the readings walk (the speed floor) are all no drive; the
    /// flickers are none even with no readings at all.
    @Test func motionFlickerWhileWalkingIsNoDrive() {
        let flicker: [(WorldMotionKind, Double, Bool)] = [
            (.walking, 0, true), (.automotive, 50, true), (.walking, 80, true),
            (.stationary, 120, true), (.automotive, 200, true), (.stationary, 230, true), (.walking, 260, true),
            (.automotive, 300, false), (.walking, 500, false), (.walking, 520, true)
        ]
        for withReadings in [true, false] {
            let script = flicker + (withReadings ? [(.automotive, 600, true), (.walking, 720, true)] : [])
            var stream = Stream(usesMotion: true)
            for step in 0...160 {
                let second = Double(step) * 5
                if withReadings { stream.read(second * 1.4, second, speed: 1.4) }
                guard step % 6 == 0 else { continue }
                stream.query(script.filter { $0.1 > second - 30 && $0.1 <= second }, through: second)
            }
            #expect(stream.drivesStarted == 0 && !stream.watch.isDriving, "withReadings \(withReadings): \(stream.events)")
        }
    }

    /// A real drive still starts: after a walk with Motion saying walking, the car pulls away at 12 m/s (no
    /// CoreLocation speed, the pace alone) and the coprocessor says car from then; within a minute and a half
    /// it is the drive, once. Without Motion the pace alone starts it within the same.
    @Test func aRealDriveAfterAWalkStillStarts() {
        for usesMotion in [true, false] {
            var stream = Stream(usesMotion: usesMotion)
            var east = 0.0
            for step in 0...60 {
                let second = Double(step) * 5
                east += second <= 100 ? 7 : 60
                stream.read(east, second)
                guard usesMotion, step % 6 == 0 else { continue }
                let script: [(WorldMotionKind, Double, Bool)] = [(.walking, 0, true), (.automotive, 100, true)]
                stream.query(script.filter { $0.1 > second - 30 && $0.1 <= second }, through: second)
                if second == 180 { #expect(stream.watch.isDriving, "usesMotion \(usesMotion)") }
            }
            #expect(stream.drivesStarted == 1 && stream.watch.isDriving, "usesMotion \(usesMotion)")
            if case .driving(let since) = stream.watch.mode {
                #expect(since.timeIntervalSince(Stream.start) <= 140, "usesMotion \(usesMotion)")
            }
        }
    }

    // MARK: Cycling

    /// With Motion a bike ride logs once, with its minutes and the distance the readings covered; the keeper
    /// asks for motion in order (each query from the last one's end, half a minute apart) and calls the drive
    /// callback never.
    @Test func aBikeRideWithMotionLogsOnce() async throws {
        let motion = ScriptedMotion()
        motion.script = [.init(kind: .cycling, isConfident: true, at: Stream.start.addingTimeInterval(1)),
                         .init(kind: .walking, isConfident: true, at: Stream.start.addingTimeInterval(905))]
        let keeper = WorldRideKeeper(motion: motion)
        keeper.usesMotion = true
        var rides: [WorldBikeRide] = []
        var driving: [Bool] = []
        keeper.onBikeRide = { rides.append($0) }
        keeper.onDrivingChanged = { driving.append($0) }
        var sawCycling = false
        for step in 0...120 {
            let second = Double(step) * 10
            let east = second <= 900 ? second * 5 : 4_500 + (second - 900) * 1.4
            keeper.handle(WorldFix(point: Stream.here.offset(east: east, north: 0), accuracy: 8,
                                   at: Stream.start.addingTimeInterval(second), isPrecise: true))
            await keeper.motionQuery?.value
            if keeper.isCycling { sawCycling = true }
        }
        #expect(sawCycling && !keeper.isCycling && driving.isEmpty)
        let ride = try #require(rides.first)
        #expect(rides.count == 1)
        #expect(ride.started == Stream.start.addingTimeInterval(1) && ride.ended == Stream.start.addingTimeInterval(905))
        #expect(ride.minutes == 15)
        #expect(abs((ride.metres ?? 0) - 4_450) < 20)
        let queries = motion.queries
        #expect(queries.count > 20)
        #expect(zip(queries, queries.dropFirst()).allSatisfy { $0.end == $1.start && $1.end.timeIntervalSince($1.start) >= 30 },
                "queries overlap or come too often")
    }

    /// A fast downhill on a bike, with Motion saying cycling, is no drive, and the ride logs; without Motion
    /// the same speeds are a drive (speed alone).
    @Test func aFastDownhillBikeRideIsNoDrive() {
        for usesMotion in [true, false] {
            var stream = Stream(usesMotion: usesMotion)
            if usesMotion { stream.motion(.cycling, 0) }
            var second = 0.0, east = 0.0
            for speed in Array(repeating: 5.0, count: 24) + Array(repeating: 14.0, count: 36) + Array(repeating: 5.0, count: 24) {
                second += 5
                east += speed * 5
                stream.read(east, second, speed: speed)
            }
            if usesMotion {
                stream.motion(.stationary, second + 1)
                stream.tick(second + 200)
                #expect(stream.drivesStarted == 0 && stream.rides.count == 1)
                #expect(stream.rides.first?.minutes == 7)
            } else {
                #expect(stream.drivesStarted == 1 && stream.rides.isEmpty)
            }
        }
    }

    /// A half-hour walk is never a drive or a ride, with Motion or without, even with a wild reading 400 m off
    /// in the middle.
    @Test func aWalkIsNeverADriveOrARide() {
        for usesMotion in [true, false] {
            var stream = Stream(usesMotion: usesMotion)
            if usesMotion { stream.motion(.walking, 0) }
            for step in 0...180 {
                let second = Double(step) * 10
                if step == 90 { stream.read(second * 1.4 + 400, second - 1, accuracy: 150) }
                stream.read(second * 1.4, second)
            }
            stream.tick(181 * 10 + 600)
            #expect(stream.events.isEmpty, "usesMotion \(usesMotion): \(stream.events)")
        }
    }

    /// A three-minute ride is not logged, nor a six-minute wobble that covers 300 m.
    @Test func shortRidesAreNotLogged() {
        var short = Stream(usesMotion: true)
        short.motion(.cycling, 0)
        for step in 1...18 {
            short.read(Double(step) * 50, Double(step) * 10)
        }
        short.motion(.walking, 180)
        short.tick(400)
        #expect(short.events == [.rideStarted(Stream.start)] && !short.watch.isCycling)

        var wobble = Stream(usesMotion: true)
        wobble.motion(.cycling, 0)
        for step in 1...36 {
            wobble.read(Double(step) * 8.3, Double(step) * 10)
        }
        wobble.motion(.walking, 360)
        wobble.tick(600)
        #expect(wobble.rides.isEmpty && !wobble.watch.isCycling)
    }

    /// The motion history alone finds a ride (a two-minute stop at a light inside it), with no distance; one
    /// still going, or stopped less than three minutes, is not finished yet, and is the open ride.
    @Test func theHistoryFindsFinishedRidesOnly() {
        let at = { (second: Double) in Stream.start.addingTimeInterval(second) }
        let samples = [WorldMotionSample(kind: .cycling, isConfident: true, at: at(0)),
                       WorldMotionSample(kind: .stationary, isConfident: true, at: at(300)),
                       WorldMotionSample(kind: .cycling, isConfident: true, at: at(420)),
                       WorldMotionSample(kind: .walking, isConfident: true, at: at(900))]
        #expect(WorldRideWatch.rides(in: samples, until: at(1_200)) == [WorldBikeRide(started: at(0), ended: at(900), metres: nil)])
        #expect(WorldRideWatch.openRideStart(in: samples, until: at(1_200)) == nil)
        #expect(WorldRideWatch.rides(in: samples, until: at(1_000)).isEmpty)
        #expect(WorldRideWatch.openRideStart(in: samples, until: at(1_000)) == at(0))
    }

    /// Without Motion the stop watch hears nothing of the car; with Motion it hears whether the person drives.
    @Test func theInCarFlagFollowsMotion() {
        let keeper = WorldRideKeeper(motion: ScriptedMotion())
        keeper.handle(WorldFix(point: Stream.here, accuracy: 8, at: Stream.start, isPrecise: true, speed: 14))
        keeper.handle(WorldFix(point: Stream.here.offset(east: 420, north: 0), accuracy: 8,
                               at: Stream.start.addingTimeInterval(30), isPrecise: true, speed: 14))
        #expect(keeper.isDriving && keeper.inCarFlag == nil)
        keeper.usesMotion = true
        #expect(keeper.inCarFlag == true)
    }

    // MARK: The ride's line (Refinements group 19, ref-ride-line)

    /// A ride's line is its good readings from its start on, one per 5 m moved: the readings before its late
    /// start sample that fall inside it count, jitter of 2 m, a reading 100 m out and one 40 m out (good for the
    /// distance, past the walk line's 25 m) don't, and the finished
    /// ride carries exactly the line drawn live. Off the bike the line is empty.
    @Test func aRidesLineIsItsGoodReadingsFromItsStart() throws {
        var stream = Stream(usesMotion: true)
        stream.read(-30, -5)
        for step in 0...60 {
            stream.read(Double(step) * 50, Double(step) * 10)
            stream.read(Double(step) * 50 + 2, Double(step) * 10 + 1)
        }
        #expect(stream.watch.ridePoints.isEmpty, "no ride yet")
        stream.motion(.cycling, 1)
        #expect(stream.watch.isCycling)
        let live = stream.watch.ridePoints
        #expect(live.count == 60, "steps 1 to 60; step 0 came before the start, the jitter is dropped")
        #expect(live.first == RoutePoint(Stream.here.offset(east: 50, north: 0)))
        #expect(live.last == RoutePoint(Stream.here.offset(east: 3_000, north: 0)))
        stream.read(3_400, 605, accuracy: 100)
        #expect(stream.watch.ridePoints == live, "a reading 100 m out never joins the line")
        stream.read(3_200, 606, accuracy: 40)
        #expect(stream.watch.ridePoints == live, "a reading 40 m out counts for the distance, not the line")
        #expect(WorldRideWatch.lineAccuracy == WorldWalkRecorder.maxAccuracy, "the walk line's own limit")
        stream.motion(.walking, 610)
        stream.tick(810)
        let ride = try #require(stream.rides.first)
        #expect(ride.points == live)
        #expect(stream.watch.ridePoints.isEmpty && !stream.watch.isCycling)

        var drive = Stream()
        for step in 0...3 {
            drive.read(Double(step) * 140, Double(step) * 10, speed: 14)
        }
        #expect(drive.watch.isDriving && drive.watch.ridePoints.isEmpty, "a drive has no ride line")
    }

    /// The keeper publishes the line while the ride is on and clears it when it ends, and says when a ride
    /// starts and ends (the location source follows it); Motion turned off mid-ride ends it, line and all.
    @Test func theKeeperPublishesTheLineWhileCycling() async throws {
        let motion = ScriptedMotion()
        motion.script = [.init(kind: .cycling, isConfident: true, at: Stream.start.addingTimeInterval(1)),
                         .init(kind: .walking, isConfident: true, at: Stream.start.addingTimeInterval(905))]
        let keeper = WorldRideKeeper(motion: motion)
        keeper.usesMotion = true
        var rides: [WorldBikeRide] = []
        var cycling: [Bool] = []
        keeper.onBikeRide = { rides.append($0) }
        keeper.onCyclingChanged = { cycling.append($0) }
        var longest: [RoutePoint] = []
        for step in 0...120 {
            let second = Double(step) * 10
            let east = second <= 900 ? second * 5 : 4_500 + (second - 900) * 1.4
            keeper.handle(WorldFix(point: Stream.here.offset(east: east, north: 0), accuracy: 8,
                                   at: Stream.start.addingTimeInterval(second), isPrecise: true))
            await keeper.motionQuery?.value
            if keeper.ridePoints.count > longest.count { longest = keeper.ridePoints }
            #expect(keeper.isCycling || keeper.ridePoints.isEmpty, "a line off the bike at \(second)")
        }
        let ride = try #require(rides.first)
        #expect(cycling == [true, false])
        #expect(ride.points.count >= 80, "the ride's ninety readings, from its start to its end")
        #expect(Array(longest.prefix(ride.points.count)) == ride.points, "the finished ride carries the line drawn live")
        #expect(keeper.ridePoints.isEmpty)

        let scripted = ScriptedMotion()
        scripted.script = [.init(kind: .cycling, isConfident: true, at: Stream.start.addingTimeInterval(1))]
        let second = WorldRideKeeper(motion: scripted)
        second.usesMotion = true
        var changes: [Bool] = []
        second.onCyclingChanged = { changes.append($0) }
        for step in 0...6 {
            second.handle(WorldFix(point: Stream.here.offset(east: Double(step) * 50, north: 0), accuracy: 8,
                                   at: Stream.start.addingTimeInterval(Double(step) * 10), isPrecise: true))
            await second.motionQuery?.value
        }
        #expect(second.isCycling && second.ridePoints.count == 6 && changes == [true])
        second.usesMotion = false
        #expect(!second.isCycling && second.ridePoints.isEmpty && changes == [true, false])
    }
}

/// Bike rides logged as exercise through the store (round 7): the switch, the motion history's checkpoint,
/// catch-up, the decoy and Undo, with a scripted motion source in the store's keeper.
@MainActor
struct WorldBikeRideLoggingTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    private static func at(_ second: Double) -> Date { start.addingTimeInterval(second) }

    /// A store whose ride keeper reads `motion`, and an isolated defaults suite.
    private static func store(_ motion: ScriptedMotion) throws -> (FernletStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "WorldBikeRideLoggingTests.\(UUID().uuidString)"))
        let store = makeTestStore()
        store.worldLocation.rides.replaceMotion(with: motion)
        return (store, defaults)
    }

    /// Turning the switch on asks for Motion: declined, it stays off; allowed, it is on from now, Motion is
    /// read, and a ride logs as a moderate outdoor cycling workout with its minutes and miles. Undo removes it.
    @Test func theSwitchAsksAndARideLogsAndUndoes() async throws {
        let (store, defaults) = try Self.store(ScriptedMotion(permission: .notAsked, grants: false))
        #expect(!(await store.setWorldBikeRides(true, defaults: defaults)))
        #expect(!WorldMapPreferences.logsBikeRides(in: defaults))

        let now = Date()
        store.worldLocation.rides.replaceMotion(with: ScriptedMotion(permission: .notAsked, grants: true))
        #expect(await store.setWorldBikeRides(true, now: now.addingTimeInterval(-3_600), defaults: defaults))
        #expect(WorldMapPreferences.logsBikeRides(in: defaults) && store.worldLocation.rides.usesMotion)
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == now.addingTimeInterval(-3_600))

        let ride = WorldBikeRide(started: now.addingTimeInterval(-1_260), ended: now.addingTimeInterval(-60), metres: 6_437.4)
        let logged = try #require(store.logWorldBikeRide(ride, defaults: defaults))
        #expect(logged.minutes == 20 && logged.isKept && store.worldLocation.rides.loggedRide == logged)
        let workout = try #require(store.loadDay(for: logged.dayKey).workouts.first { $0.id == logged.id })
        #expect(workout.activityType == .cycling && workout.mode == .activity && workout.intensity == .moderate)
        #expect(workout.duration == 20 && abs((workout.distanceMiles ?? 0) - 4) < 0.01)
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == ride.ended)
        #expect(store.logWorldBikeRide(ride, defaults: defaults) == nil, "the same ride twice")
        #expect(store.undoWorldBikeRide(logged))
        #expect(!store.loadDay(for: logged.dayKey).workouts.contains { $0.id == logged.id })
        #expect(!store.undoWorldBikeRide(logged))
    }

    /// Off, nothing logs: the checkpoint is forgotten, Motion isn't read, and a catch-up finds nothing.
    @Test func theSwitchOffLogsNothing() async throws {
        let motion = ScriptedMotion()
        motion.script = [.init(kind: .cycling, isConfident: true, at: Self.at(600)),
                         .init(kind: .walking, isConfident: true, at: Self.at(1_800))]
        let (store, defaults) = try Self.store(motion)
        #expect(await store.setWorldBikeRides(true, now: Self.at(0), defaults: defaults))
        #expect(!(await store.setWorldBikeRides(false, defaults: defaults)))
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == nil && !store.worldLocation.rides.usesMotion)
        #expect(store.logWorldBikeRide(WorldBikeRide(started: Self.at(600), ended: Self.at(1_800), metres: nil), defaults: defaults) == nil)
        await store.catchUpWorldBikeRides(now: Self.at(3_600), defaults: defaults)
        #expect(store.worldLocation.rides.loggedRide == nil && motion.queries.isEmpty)
    }

    /// Catch-up logs a ride from the history once, never one that began before the checkpoint, waits for a
    /// ride still going, and in a decoy logs nothing and leaves the checkpoint alone.
    @Test func catchUpLogsHistoryRidesOnce() async throws {
        let motion = ScriptedMotion()
        motion.lookBehind = 3_600
        motion.script = [.init(kind: .cycling, isConfident: true, at: Self.at(-600)),
                         .init(kind: .walking, isConfident: true, at: Self.at(600)),
                         .init(kind: .cycling, isConfident: true, at: Self.at(3_600)),
                         .init(kind: .stationary, isConfident: true, at: Self.at(3_900)),
                         .init(kind: .cycling, isConfident: true, at: Self.at(4_020)),
                         .init(kind: .walking, isConfident: true, at: Self.at(4_800)),
                         .init(kind: .cycling, isConfident: true, at: Self.at(10_560))]
        let (store, defaults) = try Self.store(motion)
        #expect(await store.setWorldBikeRides(true, now: Self.at(0), defaults: defaults))

        await store.catchUpWorldBikeRides(now: Self.at(10_800), defaults: defaults)
        let first = try #require(store.worldLocation.rides.loggedRide)
        #expect(first.minutes == 20 && first.metres == nil)
        #expect(store.loadDay(for: first.dayKey).workouts.filter { $0.activityType == .cycling }.count == 1)
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == Self.at(10_559), "held before the ride still going")

        await store.catchUpWorldBikeRides(now: Self.at(10_800), defaults: defaults)
        #expect(store.worldLocation.rides.loggedRide == first)
        #expect(store.loadDay(for: first.dayKey).workouts.filter { $0.activityType == .cycling }.count == 1, "logged twice")

        motion.script.append(.init(kind: .walking, isConfident: true, at: Self.at(11_400)))
        store.duressSessionActive = true
        await store.catchUpWorldBikeRides(now: Self.at(14_400), defaults: defaults)
        store.duressSessionActive = false
        #expect(store.worldLocation.rides.loggedRide == first, "a decoy logged a ride")
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == Self.at(10_559), "a decoy moved the checkpoint")

        await store.catchUpWorldBikeRides(now: Self.at(14_400), defaults: defaults)
        let second = try #require(store.worldLocation.rides.loggedRide)
        #expect(second.id != first.id && second.minutes == 14)
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == Self.at(14_400))
        #expect(store.undoWorldBikeRide(first) && store.undoWorldBikeRide(second))
    }

    // MARK: The ride's line and its timeline stop (Refinements group 19)

    /// A ride of `count` points 50 m apart, from `minutesAgo` minutes ago for 18 minutes.
    private static func ride(points count: Int, metres: Double? = 4_200, minutesAgo: Double = 60) -> WorldBikeRide {
        // Whole seconds, so the start reads back exactly from the sealed timeline.
        let started = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - minutesAgo * 60).rounded(.down))
        let here = WorldRidesTests.Stream.here
        return WorldBikeRide(started: started, ended: started.addingTimeInterval(18 * 60), metres: metres,
                             points: (0..<count).map { RoutePoint(here.offset(east: Double($0) * 50, north: 0)) })
    }

    /// A store logging rides, with Private open under a fresh hub key.
    private static func loggingStore() throws -> (FernletStore, UserDefaults) {
        let (store, defaults) = try Self.store(ScriptedMotion())
        WorldMapPreferences.setLogsBikeRides(true, in: defaults)
        let key = SymmetricKey(size: .bits256)
        store.hubContentKeyProvider = { key }
        return (store, defaults)
    }

    /// A logged ride keeps its line with its workout (Save new routes on, as it starts) and joins the
    /// timeline at its start with its distance and workout; its minutes come from the workout. Undo takes the
    /// workout, the line and the stop: the waiting one, and one Private already folded in.
    @Test func aLoggedRideKeepsItsLineAndUndoTakesItAll() throws {
        let (store, defaults) = try Self.loggingStore()
        let ride = Self.ride(points: 40)
        let logged = try #require(store.logWorldBikeRide(ride, defaults: defaults))
        #expect(store.worldRoute(for: logged.id)?.count ?? 0 >= 2, "the line was kept")
        let stop = try #require(store.worldPlaceLog()?.stops.first { $0.workoutID == logged.id })
        #expect(stop.kind == .ride && stop.at == ride.started && stop.metres == 4_200)
        #expect(store.worldRideMinutes(for: stop) == 18)
        #expect(store.undoWorldBikeRide(logged))
        #expect(store.worldRoute(for: logged.id) == nil, "the line went with the workout")
        #expect(store.worldRideMinutes(for: stop) == nil, "the workout is gone")
        #expect(store.worldPlaceLog()?.stops.contains { $0.workoutID == logged.id } == false, "the folded stop went")

        let waiting = try #require(store.logWorldBikeRide(Self.ride(points: 40, minutesAgo: 30), defaults: defaults))
        #expect(try store.worldPlaces.store.deviceState().pending.contains { $0.workoutID == waiting.id })
        #expect(store.undoWorldBikeRide(waiting))
        #expect(try !store.worldPlaces.store.deviceState().pending.contains { $0.workoutID == waiting.id }, "the waiting stop went")
        #expect(store.worldPlaceLog()?.stops.isEmpty == true)
    }

    /// With Save new routes off the ride logs and joins the timeline but keeps no line; a ride the catch-up
    /// found (no readings) keeps none either and shows its minutes only; a decoy logs, draws and keeps nothing.
    @Test func noLineWithoutSaveNewRoutesOrReadingsAndNothingInADecoy() throws {
        let (store, defaults) = try Self.loggingStore()
        WorldMapPreferences.setSaveNewRoutes(false, in: defaults)
        let unsaved = try #require(store.logWorldBikeRide(Self.ride(points: 40, minutesAgo: 120), defaults: defaults))
        #expect(store.worldRoute(for: unsaved.id) == nil)
        WorldMapPreferences.setSaveNewRoutes(true, in: defaults)
        let caughtUp = try #require(store.logWorldBikeRide(Self.ride(points: 0, metres: nil, minutesAgo: 90), defaults: defaults))
        #expect(store.worldRoute(for: caughtUp.id) == nil, "no readings, no line")
        let stops = try #require(store.worldPlaceLog()?.stops)
        #expect(stops.map(\.kind) == [.ride, .ride])
        let later = try #require(stops.first { $0.workoutID == caughtUp.id })
        #expect(later.metres == nil)
        #expect(WorldPlacesCopy.stopDetail(later, name: nil, minutes: store.worldRideMinutes(for: later))
                == WorldPlacesCopy.rideMinutes(18, width: .abbreviated))

        store.duressSessionActive = true
        #expect(store.logWorldBikeRide(Self.ride(points: 40, minutesAgo: 20), defaults: defaults) == nil)
        store.duressSessionActive = false
        #expect(store.worldPlaceLog()?.stops.count == 2, "a decoy put nothing on the timeline")
        #expect(try store.worldPlaces.store.deviceState().pending.isEmpty)
    }

    /// Undo while Private is locked (owner 2026-10-29): a stop Private already folded in can't be reached, so
    /// its removal waits on the device side and the next fold, at the next unlock, takes it off and forgets
    /// it. A decoy queues nothing.
    @Test func undoWhilePrivateIsLockedTakesTheStopAtTheNextUnlock() throws {
        let (store, defaults) = try Self.loggingStore()
        let key = try #require(store.hubContentKeyProvider?())
        let logged = try #require(store.logWorldBikeRide(Self.ride(points: 40), defaults: defaults))
        #expect(store.worldPlaceLog()?.stops.contains { $0.workoutID == logged.id } == true, "folded at an unlock")
        store.hubContentKeyProvider = nil
        #expect(store.undoWorldBikeRide(logged))
        #expect(try store.worldPlaces.store.deviceState().undoneOutings == [logged.id], "queued for the next fold")
        store.hubContentKeyProvider = { key }
        #expect(store.worldPlaceLog()?.stops.contains { $0.workoutID == logged.id } == false, "gone at the next unlock")
        #expect(try store.worldPlaces.store.deviceState().undoneOutings == nil, "and forgotten")

        store.duressSessionActive = true
        #expect(!store.worldPlaces.queueOutingRemoval(workoutID: logged.id))
        store.duressSessionActive = false
        #expect(try store.worldPlaces.store.deviceState().undoneOutings == nil)
    }

    /// Home's saved lines (`b1-home-bike`): the kept walks' and rides' lines, newest first, while Save new
    /// routes is on; a hand-logged ride without a line adds none, Undo takes its line off, and a decoy or
    /// Save new routes off draws none.
    @Test func homeDrawsTheSavedWalkAndRideLines() throws {
        let (store, defaults) = try Self.loggingStore()
        #expect(store.worldHomeSavedLines(defaults: defaults).isEmpty)
        let here = WorldRidesTests.Stream.here
        let walk = Workout(name: "Walk", type: .cardio, mode: .activity, activityType: .walking, exercises: "", rpe: nil,
                           notes: "", duration: 20, distanceMiles: 1, intensity: .moderate,
                           completedAt: Date().addingTimeInterval(-3 * 60 * 60), loggedAt: Date().addingTimeInterval(-3 * 60 * 60))
        store.addWorkout(walk, date: store.todayKey)
        let walkLine = (0..<10).map { RoutePoint(here.offset(east: 0, north: Double($0) * 30)) }
        #expect(try store.worldRoutes.save(walkLine, for: walk.id))
        let ride = try #require(store.logWorldBikeRide(Self.ride(points: 40, minutesAgo: 30), defaults: defaults))
        store.addWorkout(FernletStore.bikeRideWorkout(Self.ride(points: 0, minutesAgo: 120)), date: store.todayKey)
        let lines = store.worldHomeSavedLines(defaults: defaults)
        #expect(lines.count == 2, "the walk's and the followed ride's; the ride without a line adds none")
        #expect(lines.first?.count == store.worldRoute(for: ride.id)?.count, "newest first")
        let keptWalk = try #require(store.worldRoute(for: walk.id)).map(\.point)
        #expect(lines.last == keptWalk)

        store.duressSessionActive = true
        #expect(store.worldHomeSavedLines(defaults: defaults).isEmpty, "none in a decoy")
        store.duressSessionActive = false
        WorldMapPreferences.setSaveNewRoutes(false, in: defaults)
        #expect(store.worldHomeSavedLines(defaults: defaults).isEmpty, "none while Save new routes is off")
        WorldMapPreferences.setSaveNewRoutes(true, in: defaults)
        #expect(store.undoWorldBikeRide(ride))
        #expect(store.worldHomeSavedLines(defaults: defaults) == [keptWalk], "Undo took the ride's line")
    }
}

/// W-14 rule 3 with car detection (round 7): with Motion on, "after a drive" is a reading in a car, and a
/// reading in a car never decides; without Motion (`inCar` nil) the speed rule stays, as
/// `WorldDiscoveryTests` pins.
@MainActor
struct WorldStopWatchInCarTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let burgers = [NearbyPlace(name: "Burger Barn", kind: .allowed(.foodAndDrink), metres: 15, placeID: "I-burger")]

    private static func road(_ east: Double, _ at: Date, speed: Double?, inCar: Bool?) -> WorldFix {
        WorldFix(point: here.offset(east: east, north: 0), accuracy: 10, at: at, isPrecise: true, speed: speed, inCar: inCar)
    }

    private static func keeper(_ lookup: CountingLookup) -> WorldPlacesKeeper {
        WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true }, remembersEatingOut: { true })
    }

    /// Red lights beside fast food, every reading in a car, learn nothing (with CoreLocation's speed or
    /// without it).
    @Test func redLightsInACarLearnNothing() async throws {
        for knowsSpeed in [true, false] {
            let lookup = CountingLookup(answer: Self.burgers)
            let keeper = Self.keeper(lookup)
            var at = Self.now, east = 0.0
            for light in 0..<3 {
                for _ in 0..<8 {
                    east += 150
                    at.addTimeInterval(10)
                    #expect(!(await keeper.handleForeground(Self.road(east, at, speed: knowsSpeed ? 15 : nil, inCar: true), now: at)))
                }
                east += 20
                at.addTimeInterval(4)
                let braking = Self.road(east, at, speed: knowsSpeed ? 0 : nil, inCar: true)
                #expect(!(await keeper.handleForeground(braking, now: at)), "at light \(light)")
                #expect(!(await keeper.handleForeground(braking, now: at.addingTimeInterval(89), recheck: true)))
                east += 10
                at.addTimeInterval(90)
                #expect(!(await keeper.handleForeground(Self.road(east, at, speed: knowsSpeed ? 4.5 : nil, inCar: true), now: at)))
            }
            #expect(lookup.calls == 0 && keeper.eatingVisit == nil)
            #expect(try keeper.store.deviceState() == .empty)
        }
    }

    /// Parked twenty minutes after a drive (the car still said for the arrival), the place is learned at five
    /// minutes, not three.
    @Test func twentyMinutesParkedLearnsIt() async throws {
        let lookup = CountingLookup(answer: Self.burgers)
        let keeper = Self.keeper(lookup)
        var at = Self.now
        for step in 1...8 {
            at.addTimeInterval(10)
            #expect(!(await keeper.handleForeground(Self.road(Double(step) * 150, at, speed: 15, inCar: true), now: at)))
        }
        at.addTimeInterval(8)
        #expect(!(await keeper.handleForeground(Self.road(1_240, at, speed: 1, inCar: true), now: at)), "a reading in a car")
        let parked = Self.road(1_250, at.addingTimeInterval(30), speed: 0, inCar: false)
        #expect(!(await keeper.handleForeground(parked, now: parked.at)))
        #expect(!(await keeper.handleForeground(parked, now: at.addingTimeInterval(WorldStopWatch.stayTime + 1), recheck: true)))
        #expect(await keeper.handleForeground(parked, now: at.addingTimeInterval(WorldStopWatch.dwellTime + 1), recheck: true))
        #expect(lookup.calls == 1)
        let inside = Self.road(1_255, at.addingTimeInterval(20 * 60), speed: 0, inCar: false)
        #expect(!(await keeper.handleForeground(inside, now: inside.at)))
        #expect(try keeper.store.deviceState().newPlaces.map(\.placeID) == ["I-burger"])
    }

    /// A fast bike ride (car speed, not in a car) then a stop counts after three minutes, as any stop does;
    /// without Motion the same speed reads as a drive and needs the five-minute dwell.
    @Test func aFastBikeRideIsNoDrive() {
        for inCar in [false, nil] as [Bool?] {
            var watch = WorldStopWatch()
            for step in 0..<10 {
                let moving = watch.observe(Self.here.offset(east: Double(step) * 90, north: 0), speed: 9, inCar: inCar,
                                           at: Self.now.addingTimeInterval(Double(step) * 10))
                #expect(!moving)
            }
            let cafe = Self.here.offset(east: 920, north: 0)
            let arrived = watch.observe(cafe, speed: 0, inCar: inCar, at: Self.now.addingTimeInterval(100))
            let three = watch.observe(cafe.offset(east: 5, north: 0), speed: 0, inCar: inCar,
                                      at: Self.now.addingTimeInterval(100 + WorldStopWatch.stayTime + 1))
            #expect(!arrived)
            #expect(three == (inCar == false), "inCar \(String(describing: inCar))")
        }
    }
}

/// A motion source that plays back a script, counting its queries (each query's samples: those after its
/// start, less `lookBehind`, through its end).
@MainActor
private final class ScriptedMotion: WorldMotionReading {
    var permission: WorldMotionPermission
    var script: [WorldMotionSample] = []
    var lookBehind: TimeInterval = 0
    private(set) var queries: [(start: Date, end: Date)] = []
    private let grants: Bool

    init(permission: WorldMotionPermission = .allowed, grants: Bool = true) {
        self.permission = permission
        self.grants = grants
    }

    func requestAccess() async -> Bool {
        if permission == .notAsked { permission = grants ? .allowed : .denied }
        return permission == .allowed
    }

    func samples(from start: Date, to end: Date) async -> [WorldMotionSample] {
        queries.append((start, end))
        guard permission == .allowed else { return [] }
        return script.filter { $0.at > start.addingTimeInterval(-lookBehind) && $0.at <= end }
    }
}

/// A place lookup with a fixed answer, counting how often it is asked.
@MainActor
private final class CountingLookup: WorldPlaceLooking {
    let answer: [NearbyPlace]?
    private(set) var calls = 0

    init(answer: [NearbyPlace]?) {
        self.answer = answer
    }

    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? {
        calls += 1
        return answer
    }

    func placeName(for placeID: String) async -> WorldPlaceName? {
        nil
    }

    func forgetNames() {}
}
