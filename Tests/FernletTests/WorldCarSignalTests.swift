import AppIntents
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Car signals (owner 2026-11-09): the car book learns cars from drives and asks once, never takes headphones for a
/// car and keeps several; the keeper scrambles device identifiers, saves the book and tells car detection when a car
/// connects; a connected car or a hint (Driving Focus, Start a drive) shortens a drive's start, a connected car holds
/// it, and the car going or the hint ending ends a quiet one.
@MainActor
struct WorldCarSignalTests {
    typealias Stream = WorldRidesTests.Stream
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    private static func device(_ tag: String, _ name: String = "Camry") -> WorldAudioDevice {
        WorldAudioDevice(tag: tag, name: name, kind: .bluetooth)
    }

    private static func drive(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * 86_400) }

    // MARK: The car book

    /// A device seen on three different drives is a car; a drive counts once however many readings it has, and the
    /// first sighting is the one question.
    @Test func threeDrivesMakeACarAndTheFirstAsks() {
        var book = WorldCarBook()
        let camry = Self.device("a")
        book.sawDuringDrive(camry, driveStart: Self.drive(0))
        book.sawDuringDrive(camry, driveStart: Self.drive(0))
        #expect(book.question == .init(tag: "a", name: "Camry") && !book.isCar(camry))
        book.sawDuringDrive(camry, driveStart: Self.drive(1))
        #expect(!book.isCar(camry))
        book.sawDuringDrive(camry, driveStart: Self.drive(2))
        #expect(book.isCar(camry) && book.cars.first?.learned == true && book.question == nil)
        #expect(book.isCar(WorldAudioDevice(tag: "carplay", name: "CarPlay", kind: .carPlay)), "CarPlay is always a car")
    }

    /// Headphones are never cars: by name at once, or after a walk with them, which also unmarks a car the book
    /// learned but never one the person confirmed. Not my car keeps a device out for good.
    @Test func headphonesAndNotMyCarAreNeverCars() {
        var book = WorldCarBook()
        let airPods = Self.device("p", "Mike's AirPods Pro")
        for day in 0..<5 { book.sawDuringDrive(airPods, driveStart: Self.drive(day)) }
        #expect(!book.isCar(airPods) && book.question == nil && book.isHeadphones(airPods))

        let speaker = Self.device("s", "Boombox")
        for day in 0..<3 { book.sawDuringDrive(speaker, driveStart: Self.drive(day)) }
        #expect(book.isCar(speaker))
        book.walkedWith(speaker)
        #expect(!book.isCar(speaker) && book.isHeadphones(speaker), "a learned car walked with is headphones")

        let truck = Self.device("t", "Work truck")
        book.mark(truck, learned: false)
        book.walkedWith(truck)
        #expect(book.isCar(truck), "a car the person confirmed stays")

        let rental = Self.device("r", "Rental")
        book.sawDuringDrive(rental, driveStart: Self.drive(0))
        #expect(book.question?.tag == "r")
        book.answer(isCar: false)
        for day in 1..<6 { book.sawDuringDrive(rental, driveStart: Self.drive(day)) }
        #expect(!book.isCar(rental) && book.question == nil)
    }

    /// Yes marks the question's device; several cars are kept, the newest when the book is full; a forgotten car can
    /// be learned again; the book survives a save and a load.
    @Test func yesMarksAndSeveralCarsAreKept() throws {
        var book = WorldCarBook()
        book.sawDuringDrive(Self.device("a"), driveStart: Self.drive(0))
        book.answer(isCar: true)
        #expect(book.cars == [.init(tag: "a", name: "Camry", learned: false)])
        for index in 0..<WorldCarBook.maxCars { book.mark(Self.device("c\(index)", "Car \(index)"), learned: false) }
        #expect(book.cars.count == WorldCarBook.maxCars && !book.cars.contains { $0.tag == "a" }, "the oldest went")
        book.forget(tag: "c0")
        #expect(!book.isCar(Self.device("c0")))
        let copy = try JSONDecoder().decode(WorldCarBook.self, from: JSONEncoder().encode(book))
        #expect(copy == book)
        #expect(WorldCarBook.soundsLikeHeadphones("Galaxy Buds2") && !WorldCarBook.soundsLikeHeadphones("Honda HFL"))
    }

    // MARK: The keeper

    /// A keeper over scripted outputs and its own defaults.
    private static func keeper(_ audio: ScriptedAudio) throws -> (WorldCarKeeper, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "WorldCarSignalTests.\(UUID().uuidString)"))
        return (WorldCarKeeper(audio: audio, defaults: defaults), defaults)
    }

    /// The device's identifier never reaches the book: its tag is a salted hash, steady on this iPhone, new after a
    /// wipe's new salt. CarPlay links at once; a Bluetooth car links once the book holds it; each change is told.
    @Test func tagsAreScrambledAndALinkIsTold() throws {
        let audio = ScriptedAudio()
        audio.list = [WorldAudioOutput(identifier: "00:11:22:33:44:55-tacl", name: "Camry", kind: .bluetooth)]
        let (keeper, defaults) = try Self.keeper(audio)
        let tag = try #require(keeper.connected.first?.tag)
        #expect(!tag.contains("00:11") && tag.count == 32)
        // A second reader for the second keeper: a reader tells one keeper of its changes, as the app's one does.
        let again = ScriptedAudio()
        again.list = audio.list
        #expect(WorldCarKeeper(audio: again, defaults: defaults).connected.first?.tag == tag, "steady on this iPhone")
        var links: [Bool] = []
        keeper.onLinkChanged = { links.append($0) }
        #expect(!keeper.isLinked && keeper.offerable?.name == "Camry")
        keeper.mark(try #require(keeper.offerable))
        #expect(keeper.isLinked && links == [true] && keeper.offerable == nil)
        audio.change(to: [])
        #expect(!keeper.isLinked && links == [true, false])
        audio.change(to: [WorldAudioOutput(identifier: "carplay", name: "CarPlay", kind: .carPlay)])
        #expect(keeper.isLinked && links == [true, false, true])
        WorldMapPreferences.clearAll(in: defaults)
        #expect(WorldCarKeeper(audio: again, defaults: defaults).connected.first?.tag != tag, "a new salt after a wipe")
    }

    /// Readings during three drives learn the connected device, saved for the next launch; Home asks only while it is
    /// connected; a decoy learns, shows and asks nothing.
    @Test func drivesTeachTheKeeperAndADecoyLearnsNothing() throws {
        let audio = ScriptedAudio()
        audio.list = [WorldAudioOutput(identifier: "camry", name: "Camry", kind: .bluetooth)]
        let (keeper, defaults) = try Self.keeper(audio)
        let fix = WorldFix(point: Stream.here, accuracy: 8, at: Self.start, isPrecise: true, speed: 15)
        keeper.isDecoy = true
        keeper.noteReading(fix, mode: .driving(since: Self.drive(0)))
        #expect(keeper.book == WorldCarBook() && keeper.askable == nil)
        keeper.isDecoy = false
        keeper.noteReading(fix, mode: .driving(since: Self.drive(0)))
        #expect(keeper.askable?.name == "Camry")
        audio.change(to: [])
        #expect(keeper.askable == nil, "asked only while connected")
        audio.change(to: [WorldAudioOutput(identifier: "camry", name: "Camry", kind: .bluetooth)])
        var links: [Bool] = []
        keeper.onLinkChanged = { links.append($0) }
        keeper.noteReading(fix, mode: .driving(since: Self.drive(1)))
        keeper.noteReading(fix, mode: .driving(since: Self.drive(2)))
        #expect(keeper.isLinked && keeper.visibleCars.map(\.name) == ["Camry"])
        #expect(links == [true], "a car learned on a drive links at once")
        keeper.isDecoy = true
        #expect(keeper.visibleCars.isEmpty && keeper.offerable == nil, "a decoy shows no car")
        let reopened = WorldCarKeeper(audio: audio, defaults: defaults)
        #expect(reopened.isLinked, "the book was saved")
        reopened.forgetAll()
        #expect(reopened.book == WorldCarBook())
    }

    /// Two minutes and 150 m on foot with a device connected, never faster than walking, mark it as headphones; a
    /// shorter or faster stretch doesn't.
    @Test func aWalkWithADeviceMarksHeadphones() throws {
        let audio = ScriptedAudio()
        audio.list = [WorldAudioOutput(identifier: "sony", name: "Sony", kind: .bluetooth)]
        let (keeper, _) = try Self.keeper(audio)
        let walk = { (east: Double, second: Double, speed: Double) in
            WorldFix(point: Stream.here.offset(east: east, north: 0), accuracy: 8, at: Self.start.addingTimeInterval(second),
                     isPrecise: true, speed: speed)
        }
        keeper.noteReading(walk(0, 0, 1.4), mode: .onFoot)
        keeper.noteReading(walk(100, 70, 1.4), mode: .onFoot)
        keeper.noteReading(walk(140, 100, 6), mode: .onFoot)
        keeper.noteReading(walk(320, 230, 1.4), mode: .onFoot)
        #expect(keeper.book.headphones.isEmpty, "a fast reading starts the walk again")
        keeper.noteReading(walk(500, 360, 1.4), mode: .onFoot)
        #expect(keeper.book.headphones.count == 1 && keeper.offerable == nil)
    }

    // MARK: Drive detection

    /// With a car connected, ten seconds above walking pace start the drive (no car's speed needed, whatever Motion
    /// said), a minute of walking-pace readings or Motion's walking never end it, and parking takes fifteen minutes.
    @Test func aConnectedCarStartsAndHoldsADrive() {
        var stream = Stream(usesMotion: true)
        stream.motion(.walking, 0)
        stream.watch.carLinked = true
        stream.read(0, 0, speed: 3)
        stream.read(30, 10, speed: 3.2)
        #expect(stream.watch.isDriving && stream.drivesStarted == 1)
        for step in 1...8 { stream.read(30 + Double(step) * 14, 10 + Double(step) * 10, speed: 1.4) }
        stream.motion(.walking, 100)
        #expect(stream.watch.isDriving, "walking pace with the car connected is still the drive")
        stream.tick(10 + 80 + WorldRideWatch.parkTime + 5)
        #expect(stream.watch.isDriving, "five minutes standing with the car connected")
        stream.tick(10 + 80 + WorldRideWatch.linkedParkTime + 5)
        #expect(!stream.watch.isDriving && stream.watch.lastDriveEnd == .parked)
    }

    /// The car going ends a drive whose readings have been quiet twenty seconds; going at speed (Bluetooth dropping)
    /// keeps it.
    @Test func theCarGoingEndsAQuietDrive() {
        var stream = Stream()
        stream.watch.carLinked = true
        stream.read(0, 0, speed: 12)
        stream.read(120, 10, speed: 12)
        #expect(stream.watch.isDriving)
        stream.watch.carLinked = false
        stream.events += stream.watch.carUnlinked(at: Stream.start.addingTimeInterval(12))
        #expect(stream.watch.isDriving, "the Bluetooth dropped at speed")
        stream.read(125, 20, speed: 0.2)
        stream.watch.carLinked = true
        stream.watch.carLinked = false
        stream.events += stream.watch.carUnlinked(at: Stream.start.addingTimeInterval(45))
        #expect(!stream.watch.isDriving && stream.watch.lastDriveEnd == .parked)
    }

    /// A hint shortens the start to ten seconds at a car's speed, never at a jog; it runs out; its end ends a quiet
    /// drive.
    @Test func aHintShortensTheStartAndItsEndEndsAQuietDrive() {
        var jog = Stream()
        jog.watch.hint(until: Stream.start.addingTimeInterval(1_800))
        jog.read(0, 0, speed: 3.5)
        jog.read(40, 12, speed: 3.5)
        #expect(!jog.watch.isDriving, "a jog after a hint is no drive")

        var hinted = Stream()
        hinted.watch.hint(until: Stream.start.addingTimeInterval(1_800))
        hinted.read(0, 0, speed: 12)
        hinted.read(130, 11, speed: 12)
        #expect(hinted.watch.isDriving)
        hinted.read(140, 15, speed: 0.1)
        hinted.events += hinted.watch.endHint(at: Stream.start.addingTimeInterval(40))
        #expect(!hinted.watch.isDriving && hinted.watch.lastDriveEnd == .parked)

        var expired = Stream()
        expired.watch.hint(until: Stream.start.addingTimeInterval(5))
        expired.read(0, 10, speed: 12)
        expired.read(130, 21, speed: 12)
        #expect(!expired.watch.isDriving, "a run-out hint is the usual half minute")
    }

    // MARK: The location source and the actions

    /// Without Always (the test host has none) a hint primes the start but starts no listen, and an action says
    /// background mapping is off.
    @Test func aHintWithoutAlwaysOnlyPrimesTheStart() async {
        let source = WorldLocationSource()
        source.hintDrive(true, now: Stream.start)
        #expect(!source.isListening)
        for step in 0...2 {
            source.deliver(WorldFix(point: Stream.here.offset(east: Double(step) * 60, north: 0), accuracy: 8,
                                    at: Stream.start.addingTimeInterval(Double(step) * 5), isPrecise: true, speed: 12))
        }
        #expect(source.rides.isDriving, "ten seconds at a car's speed after a hint")
        #expect(WorldLocationSource.hintLife == 30 * 60 && WorldLocationSource.hintListenTime == 5 * 60)
        if !WorldMapPreferences.alwaysLowPower() {
            #expect(await WorldDriveSignal.post(true) == .backgroundMappingOff)
        }
    }

    /// The Shortcuts actions run in the background and are not Siri shortcuts (the ten-slot wall stays as it is); the
    /// Focus filter's switch is on by default, so adding the filter is all it takes.
    @Test func theActionsAndTheFilterAreDeclared() {
        #expect(StartDriveIntent.supportedModes == [.background] && EndDriveIntent.supportedModes == [.background])
        #expect(MapMyDriveFocusFilter().mapsDrive)
        #expect(WorldDriveIntentError.backgroundMappingOff.localizedStringResource.key == "worldDrive.intent.backgroundMappingOff")
    }
}

/// Audio outputs a test sets, telling the keeper when they change.
@MainActor
private final class ScriptedAudio: WorldAudioReading {
    var list: [WorldAudioOutput] = []
    var onChange: (@MainActor () -> Void)?

    func outputs() -> [WorldAudioOutput] { list }

    /// The route changes to `outputs`.
    func change(to outputs: [WorldAudioOutput]) {
        list = outputs
        onChange?()
    }
}
