import AppIntents
import CryptoKit
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

    /// A keeper over scripted outputs, its own car file and its own (empty) defaults, with the phone unlocked.
    private static func keeper(_ audio: ScriptedAudio) throws -> (WorldCarKeeper, CarDisk) {
        let disk = try CarDisk()
        return (disk.keeper(audio), disk)
    }

    /// The device's identifier never reaches the book: its tag is a salted hash, steady on this iPhone, new after a
    /// wipe's new salt. CarPlay links at once; a Bluetooth car links once the book holds it; each change is told.
    @Test func tagsAreScrambledAndALinkIsTold() throws {
        let audio = ScriptedAudio()
        audio.list = [WorldAudioOutput(identifier: "00:11:22:33:44:55-tacl", name: "Camry", kind: .bluetooth)]
        let (keeper, disk) = try Self.keeper(audio)
        defer { disk.cleanUp() }
        let tag = try #require(keeper.connected.first?.tag)
        #expect(!tag.contains("00:11") && tag.count == 32)
        #expect(disk.raw == nil, "a new salt is written with the book's first save, not before")
        // A second reader for the second keeper: a reader tells one keeper of its changes, as the app's one does.
        let again = ScriptedAudio()
        again.list = audio.list
        var links: [Bool] = []
        keeper.onLinkChanged = { links.append($0) }
        #expect(!keeper.isLinked && keeper.offerable?.name == "Camry")
        keeper.mark(try #require(keeper.offerable))
        #expect(keeper.isLinked && links == [true] && keeper.offerable == nil)
        #expect(disk.keeper(again).connected.first?.tag == tag, "steady on this iPhone")
        audio.change(to: [])
        #expect(!keeper.isLinked && links == [true, false])
        audio.change(to: [WorldAudioOutput(identifier: "carplay", name: "CarPlay", kind: .carPlay)])
        #expect(keeper.isLinked && links == [true, false, true])
        keeper.forgetAll()
        #expect(disk.raw == nil, "the wipe removes the file")
        let after = try #require(disk.keeper(again).connected.first?.tag)
        #expect(after != tag && after != WorldCarKeeper.untagged, "a new salt after a wipe")
    }

    /// Readings during three drives learn the connected device, saved for the next launch; Home asks only while it is
    /// connected; a decoy learns, shows and asks nothing.
    @Test func drivesTeachTheKeeperAndADecoyLearnsNothing() throws {
        let audio = ScriptedAudio()
        audio.list = [WorldAudioOutput(identifier: "camry", name: "Camry", kind: .bluetooth)]
        let (keeper, disk) = try Self.keeper(audio)
        defer { disk.cleanUp() }
        let fix = WorldFix(point: Stream.here, accuracy: 8, at: Self.start, isPrecise: true, speed: 15)
        keeper.isDecoy = true
        keeper.noteReading(fix, mode: .driving(since: Self.drive(0)))
        #expect(keeper.book == WorldCarBook() && keeper.askable == nil && disk.raw == nil, "a decoy learns and writes nothing")
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
        let reopened = disk.keeper(audio)
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

    // MARK: The car file (2026-11-19; the salt on a locked launch, release review F15)

    private static let camry = WorldAudioOutput(identifier: "AA:BB:CC", name: "Camry", kind: .bluetooth)
    private static let driving = WorldFix(point: Stream.here, accuracy: 8, at: Stream.start, isPrecise: true, speed: 12)

    /// The file gives three answers: not there, the record it was given, and unreadable while its bytes can't be
    /// read. An unreadable file is left exactly as it was; bytes that are not a record are removed.
    @Test func theFileTellsAbsentFromUnreadable() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        #expect(disk.file.read() == .absent)
        var book = WorldCarBook()
        book.mark(Self.device("a"), learned: false)
        let record = WorldCarRecord(salt: "salt", book: book)
        #expect(disk.file.write(record) && disk.file.read() == .record(record))
        #expect(disk.file.url.lastPathComponent == "car-book.json" && WorldCarFile.folderName == "WorldCars")
        let folder = URL(fileURLWithPath: disk.folder.path, isDirectory: true)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let saved = try #require(disk.raw)
        disk.box.locked = true
        #expect(disk.file.read() == .unreadable && disk.raw == saved, "a locked file is neither removed nor changed")
        disk.box.locked = false
        try Data("not a record".utf8).write(to: disk.file.url)
        #expect(disk.file.read() == .absent && disk.raw == nil, "bytes that can never be a record are removed")
        #expect(disk.file.write(WorldCarRecord(salt: "", book: book)) && disk.file.read() == .absent, "an empty salt is no salt")
    }

    /// An older build's book and salt move into the file once, with the tags still matching, and the two keys go.
    /// The next launch reads the file alone.
    @Test func theOldKeysMoveIntoTheFileOnce() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        var book = WorldCarBook()
        book.mark(Self.device(Self.tag("old-salt", Self.camry.identifier)), learned: false)
        disk.setLegacy(salt: "old-salt", book: book)
        let audio = ScriptedAudio()
        audio.list = [Self.camry]
        let keeper = disk.keeper(audio)
        #expect(keeper.isLinked && keeper.book == book, "the car learned before the move still links")
        #expect(disk.file.read() == .record(WorldCarRecord(salt: "old-salt", book: book)))
        #expect(disk.legacySalt == nil && disk.legacyBook == nil, "the old keys go once the file is written")
        #expect(disk.keeper(audio).isLinked, "the next launch reads the file")
    }

    /// Nothing moves while the phone's protected data can't be read, and an empty read of the defaults moves
    /// nothing and makes no file: the keys stay for a launch that can trust them.
    @Test func nothingMovesLockedOrFromAnEmptyRead() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        var book = WorldCarBook()
        book.mark(Self.device(Self.tag("old-salt", Self.camry.identifier)), learned: false)
        disk.setLegacy(salt: "old-salt", book: book)
        let audio = ScriptedAudio()
        audio.list = [Self.camry]
        let phone = ScriptedLock()
        let early = disk.keeper(audio, lock: phone)
        #expect(disk.raw == nil && disk.legacySalt == "old-salt" && disk.legacyBook != nil, "nothing moved locked")
        #expect(early.connected.first?.tag == WorldCarKeeper.untagged && !early.isLinked)
        phone.isOpen = true
        early.reload()
        #expect(early.isLinked && disk.legacySalt == nil && disk.raw != nil, "moved once the phone allows")

        let empty = try CarDisk()
        defer { empty.cleanUp() }
        let fresh = empty.keeper(audio)
        #expect(fresh.connected.first?.tag != WorldCarKeeper.untagged && empty.raw == nil, "a first launch makes a salt in memory only")
    }

    /// A file a process made while it read the defaults as empty holds a new salt and no car; the person's cars are
    /// still in the old keys, and they win. A file that holds a car wins over the old keys.
    @Test func oldKeysWithCarsWinOverAFileWithNone() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        var book = WorldCarBook()
        book.mark(Self.device(Self.tag("old-salt", Self.camry.identifier)), learned: false)
        disk.setLegacy(salt: "old-salt", book: book)
        #expect(disk.file.write(WorldCarRecord(salt: "stray", book: WorldCarBook())))
        let audio = ScriptedAudio()
        audio.list = [Self.camry]
        #expect(disk.keeper(audio).isLinked && disk.file.read() == .record(WorldCarRecord(salt: "old-salt", book: book)))
        #expect(disk.legacySalt == nil && disk.legacyBook == nil)

        var other = WorldCarBook()
        other.mark(Self.device("someone-else", "Civic"), learned: false)
        disk.setLegacy(salt: "older", book: other)
        _ = disk.keeper(audio)
        #expect(disk.file.read() == .record(WorldCarRecord(salt: "old-salt", book: book)), "a file with a car is kept")
        #expect(disk.legacySalt == nil && disk.legacyBook == nil)

        let orphan = try CarDisk()
        defer { orphan.cleanUp() }
        orphan.setLegacy(salt: nil, book: other)
        #expect(orphan.keeper(audio).book == WorldCarBook() && orphan.legacyBook == nil && orphan.raw == nil,
                "a book with no salt can match nothing: it goes and nothing is moved")
    }

    /// A launch before the first unlock with the car's Bluetooth connected: the file is there but can't be read.
    /// The keeper makes no salt, gives the device no tag, learns nothing from a drive and writes nothing, so the
    /// file is byte for byte what it was. Once the phone unlocks the same keeper reads it and the learned car links.
    @Test func anUnreadableFileIsNeverReplacedAndTheCarLinksAfterUnlock() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        let audio = ScriptedAudio()
        audio.list = [Self.camry]
        let learner = disk.keeper(audio)
        learner.mark(try #require(learner.offerable))
        let saved = try #require(disk.raw)
        #expect(learner.isLinked)

        let phone = ScriptedLock()
        disk.box.locked = true
        let early = disk.keeper(audio, lock: phone)
        #expect(early.connected.first?.tag == WorldCarKeeper.untagged && !early.isLinked && early.offerable == nil)
        early.noteReading(Self.driving, mode: .driving(since: Stream.start))
        early.mark(try #require(early.connected.first))
        early.answer(isCar: true)
        early.refresh()
        #expect(early.book == WorldCarBook() && disk.raw == saved, "nothing learned, nothing written over")

        // Unlocked, but the file still refuses (a read that fails for any other reason): still no salt, no write.
        phone.isOpen = true
        early.noteReading(Self.driving, mode: .driving(since: Stream.start))
        early.refresh()
        #expect(early.connected.first?.tag == WorldCarKeeper.untagged && disk.raw == saved)

        // The file reads: the next reading of a drive links the car, with no hand-over needed.
        disk.box.locked = false
        var links: [Bool] = []
        early.onLinkChanged = { links.append($0) }
        early.noteReading(Self.driving, mode: .driving(since: Stream.start))
        #expect(early.isLinked && links == [true] && early.visibleCars.map(\.name) == ["Camry"])
        // The store's hand-over reads it again and changes nothing.
        early.reload()
        #expect(early.isLinked && links == [true])
    }

    /// A keeper that saw the phone locked never makes a salt, even with no file (its empty read of the old keys may
    /// be a locked phone's); one that reads a salt uses it whatever the lock.
    @Test func aKeeperThatSawThePhoneLockedMakesNoSalt() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        let audio = ScriptedAudio()
        audio.list = [Self.camry]
        let phone = ScriptedLock()
        let early = disk.keeper(audio, lock: phone)
        phone.isOpen = true
        early.refresh()
        early.mark(try #require(early.connected.first))
        #expect(early.connected.first?.tag == WorldCarKeeper.untagged && disk.raw == nil)

        let learner = disk.keeper(audio)
        learner.mark(try #require(learner.offerable))
        phone.isOpen = false
        #expect(disk.keeper(audio, lock: phone).isLinked, "a salt that reads is used whatever the lock")
    }

    /// Delete everything: the keeper's wipe removes the file, the old keys and the salt in memory, even while the
    /// file can't be read, and the settings' wipe removes the old keys.
    @Test func theWipeRemovesTheFileAndTheOldKeys() throws {
        let disk = try CarDisk()
        defer { disk.cleanUp() }
        let audio = ScriptedAudio()
        audio.list = [Self.camry]
        let keeper = disk.keeper(audio)
        keeper.mark(try #require(keeper.offerable))
        let tag = try #require(keeper.connected.first?.tag)
        disk.setLegacy(salt: "left-over", book: WorldCarBook())
        disk.box.locked = true
        keeper.forgetAll()
        #expect(disk.raw == nil && disk.legacySalt == nil && disk.legacyBook == nil)
        #expect(keeper.book == WorldCarBook() && !keeper.isLinked)
        disk.box.locked = false
        let after = try #require(keeper.connected.first?.tag)
        #expect(after != tag && after != WorldCarKeeper.untagged, "the next salt is a new one")

        disk.setLegacy(salt: "left-over", book: WorldCarBook())
        WorldMapPreferences.clearAll(in: disk.defaults)
        #expect(disk.legacySalt == nil && disk.legacyBook == nil)
    }

    /// The tag the keeper makes for `identifier` under `salt` (its documented recipe: the first 16 bytes of
    /// SHA-256 over "salt|identifier", in hex).
    private static func tag(_ salt: String, _ identifier: String) -> String {
        SHA256.hash(data: Data((salt + "|" + identifier).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A Focus turning off runs the filter with its defaults, which says on: after a drive that ended parked that
    /// starts nothing for ten minutes. The Start a drive action, an off, and an on at any other time pass.
    @Test func aFocusFilterRunJustAfterParkingStartsNothing() {
        let parked = Stream.start, soon = parked.addingTimeInterval(120), later = parked.addingTimeInterval(WorldDriveSignal.focusOffWindow + 1)
        #expect(!WorldDriveSignal.passes(true, fromFocus: true, lastEnd: .parked, endedAt: parked, now: soon))
        #expect(WorldDriveSignal.passes(true, fromFocus: false, lastEnd: .parked, endedAt: parked, now: soon), "Start a drive")
        #expect(WorldDriveSignal.passes(false, fromFocus: true, lastEnd: .parked, endedAt: parked, now: soon))
        #expect(WorldDriveSignal.passes(true, fromFocus: true, lastEnd: .parked, endedAt: parked, now: later))
        #expect(WorldDriveSignal.passes(true, fromFocus: true, lastEnd: .onFoot, endedAt: parked, now: soon))
        #expect(WorldDriveSignal.passes(true, fromFocus: true, lastEnd: nil, endedAt: nil, now: soon))

        var stream = Stream()
        stream.read(0, 0, speed: 15)
        stream.read(600, 40, speed: 15)
        stream.tick(40 + WorldRideWatch.parkTime)
        #expect(stream.watch.lastDriveEnd == .parked && stream.watch.lastDriveEndedAt == Stream.start.addingTimeInterval(40 + WorldRideWatch.parkTime))
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
        if !WorldMapPreferences.alwaysLowPower(), !WorldMapPreferences.backgroundMappingMarked() {
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

/// Whether a test's car file refuses to be read, as a locked phone's does.
private final class CarLockBox: @unchecked Sendable {
    private let guardLock = NSLock()
    private var value = false
    var locked: Bool {
        get { guardLock.withLock { value } }
        set { guardLock.withLock { value = newValue } }
    }
}

/// A car file in its own temporary folder that a test can lock, with its own defaults for the old keys.
@MainActor
private struct CarDisk {
    let folder: URL
    let box = CarLockBox()
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorldCars-\(UUID().uuidString)", isDirectory: true)
        suite = "WorldCarSignalTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    /// The file, failing its reads while the box is locked.
    var file: WorldCarFile {
        WorldCarFile(folder: folder) { [box] url in
            if box.locked { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
    }

    /// The file's bytes on disk, whatever the lock.
    var raw: Data? { FileManager.default.contents(atPath: file.url.path) }
    var legacySalt: String? { WorldMapPreferences.legacyCarTagSalt(in: defaults) }
    var legacyBook: Data? { WorldMapPreferences.legacyCarBookData(in: defaults) }

    /// A keeper over this disk; the phone is unlocked unless `lock` says otherwise.
    func keeper(_ audio: ScriptedAudio, lock: ScriptedLock? = nil) -> WorldCarKeeper {
        WorldCarKeeper(audio: audio, file: file, defaults: defaults, protectedData: { lock?.isOpen ?? true })
    }

    /// Saves a salt and a book the way builds before the car file did.
    func setLegacy(salt: String?, book: WorldCarBook) {
        if let salt { defaults.set(salt, forKey: "fernlet.worldMap.carTagSalt") }
        do {
            defaults.set(try JSONEncoder().encode(book), forKey: "fernlet.worldMap.carBook")
        } catch {
            Issue.record("the book did not encode: \(error)")
        }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("clean-up failed: \(error)") }
        }
    }
}

/// Whether the phone's protected data can be read, as a test says.
@MainActor
private final class ScriptedLock {
    var isOpen = false
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
