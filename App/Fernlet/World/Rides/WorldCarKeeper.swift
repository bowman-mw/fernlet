import CryptoKit
import FernletFoundation
import Foundation
import UIKit
import WorldMapStore

/// Car detection's connected devices (owner 2026-11-09, car signals): what the phone's audio is connected to now, and
/// the ``WorldCarBook`` of which Bluetooth devices are the person's cars. Owned by ``WorldLocationSource`` (`cars`),
/// which reads the route with every reading and tells car detection when a car connects or goes (``onLinkChanged``).
///
/// - **Linked** (``isLinked``): CarPlay, or a car in the book, is connected. Car detection then starts a drive after a
///   short run above walking pace and never ends it on foot (`WorldRideWatch.carLinked`).
/// - **Learning** (``noteReading(_:mode:)``): each reading during a drive counts the Bluetooth devices connected for that
///   drive; one on foot that has carried the person ``walkDistance`` beyond its accuracy over at least ``walkTime``, no
///   reading above walking pace on the way, with a Bluetooth device connected all along, marks that device as
///   headphones.
/// - **Home's question** (``askable``): the book's question, only while its device is connected and never in a decoy;
///   Home asks it only while the person is stopped. **Settings** reads ``visibleCars`` and ``offerable``, which a decoy
///   empties, and changes the book through ``answer(isCar:)``, ``mark(_:)`` and ``forget(tag:)``.
/// - **Kept on this iPhone only** (the car file, ``WorldCarFile``, removed by Delete everything): a device's own
///   identifier never leaves this type; it is scrambled with the per-install salt into a tag first, and a name is kept
///   only for a car or the one device waiting to be asked about. Nothing is learned in a decoy.
/// - **The salt is never replaced** (release review 2026-11-18, F15; the car file, 2026-11-19): the salt and the book
///   are one file, and a new salt is made only when that file is truly not there, the phone's protected data can be
///   read, and this keeper never saw the phone locked. A file that is there but can't be read (a launch before the
///   phone's first unlock) is an error, never an empty answer: a Bluetooth device then gets no tag (``untagged``),
///   matches no car, is never learned and nothing is written, until ``reload()`` or the next ``refresh()`` reads the
///   file. A new salt lives in memory until the book is first saved with it.
/// - **Moved once from `UserDefaults`** (``adoptLegacy(over:)``): builds before the car file kept the book and the
///   salt under two keys. They are moved only when the file is not there (or holds no car yet), the protected data
///   can be read and a salt is actually present in the defaults (an empty read proves nothing), and the keys are
///   removed only once the file is written.
@MainActor
@Observable
final class WorldCarKeeper {
    /// The cars, sightings and question, as last saved.
    private(set) var book: WorldCarBook
    /// The devices connected now (CarPlay and Bluetooth audio).
    private(set) var connected: [WorldAudioDevice] = []
    /// Whether a decoy session is showing (the store sets it): nothing is learned, shown or asked.
    var isDecoy = false

    /// Called when a car connects (true) or goes (false).
    @ObservationIgnored var onLinkChanged: ((Bool) -> Void)?
    @ObservationIgnored private let audio: any WorldAudioReading
    /// Where builds before the car file kept the book and the salt: read once to move them, then cleared.
    @ObservationIgnored private let defaults: UserDefaults
    /// The salt and the book on disk.
    @ObservationIgnored private let file: WorldCarFile
    /// The salt tags are made with now: the file's, or one made in memory that the book's first save writes. Nil
    /// while none reads and none may be made.
    @ObservationIgnored private var salt: String?
    /// Whether the file's answer is known (read, or truly not there). False while it is there but unreadable: then
    /// no salt is made and nothing is written.
    @ObservationIgnored private var fileAnswered = false
    /// Whether the phone's protected data can be read now (the app's own answer by default; tests answer for it).
    @ObservationIgnored private let protectedData: @MainActor () -> Bool
    /// Whether this keeper ever found the protected data unreadable: from then on it makes no salt (a process that
    /// started before the first unlock is reported to go on reading empty defaults after it).
    @ObservationIgnored private var sawLocked = false
    /// The reading a walk with Bluetooth connected is measured from, and the tags connected then.
    @ObservationIgnored private var walkFrom: (fix: WorldFix, tags: [String])?
    /// Whether a car was connected when ``onLinkChanged`` was last told (or at init): every change of the route or the
    /// book is measured against it, so a car the book just learned on a drive links at once.
    @ObservationIgnored private var toldLinked = false

    /// How far beyond both readings' accuracy a walk with a device connected must go to mark it as headphones, in metres
    /// (a car's Bluetooth reaches a few metres from the car).
    static let walkDistance = 150.0
    /// The shortest time that walk may take: a car pulling away covers the distance far sooner.
    static let walkTime: TimeInterval = 2 * 60
    /// The worst accuracy a reading may have to measure a walk, in metres.
    static let walkAccuracy = 65.0

    /// The tag of a device read while no salt could be: it matches nothing in the book and is never kept.
    static let untagged = ""

    /// A keeper reading `audio` (the phone's route by default; tests pass a scripted one) and saving in `file` (the
    /// app's car file by default); `defaults` is where older builds saved, read once to move it; `protectedData`
    /// says whether the phone's protected data can be read (the app's own answer when nil).
    init(audio: (any WorldAudioReading)? = nil, file: WorldCarFile? = nil, defaults: UserDefaults = .standard,
         protectedData: (@MainActor () -> Bool)? = nil) {
        self.audio = audio ?? WorldCarAudio()
        self.file = file ?? .production()
        self.defaults = defaults
        self.protectedData = protectedData ?? { UIApplication.shared.isProtectedDataAvailable }
        sawLocked = !self.protectedData()
        book = WorldCarBook()
        load()
        self.audio.onChange = { [weak self] in self?.refresh() }
        connected = self.audio.outputs().map(device(for:))
        toldLinked = isLinked
    }

    /// Whether a car is connected now: CarPlay, or a car in the book.
    var isLinked: Bool { connected.contains { book.isCar($0) } }

    /// The cars Settings lists: none in a decoy.
    var visibleCars: [WorldCarBook.Car] { isDecoy ? [] : book.cars }

    /// The question Home may ask now: its device connected, no decoy.
    var askable: WorldCarBook.Question? {
        guard !isDecoy, let question = book.question, connected.contains(where: { $0.tag == question.tag }) else { return nil }
        return question
    }

    /// A connected Bluetooth device Settings can offer as "Use … as my car": not a car, not headphones; none in a decoy.
    var offerable: WorldAudioDevice? {
        guard !isDecoy else { return nil }
        return connected.first {
            $0.kind == .bluetooth && $0.tag != Self.untagged && !book.isCar($0) && !book.isHeadphones($0)
        }
    }

    /// Reads the route again, telling ``onLinkChanged`` when a car connected or went. A file that couldn't be read
    /// before is tried again first.
    func refresh() {
        if !fileAnswered { load() }
        connected = audio.outputs().map(device(for:))
        tellLink()
    }

    /// Tells ``onLinkChanged`` when whether a car is connected differs from what it was last told.
    private func tellLink() {
        let linked = isLinked
        guard linked != toldLinked else { return }
        toldLinked = linked
        onLinkChanged?(linked)
    }

    /// A reading while the person moves as `mode` says: during a drive the connected Bluetooth devices count for it; on
    /// foot a long enough walk with one connected marks it as headphones. Nothing is learned in a decoy.
    func noteReading(_ fix: WorldFix, mode: WorldRideMode) {
        // A file that couldn't be read at a locked launch is read as soon as the phone allows, so a drive that
        // began before the first unlock links its car without waiting for the route to change.
        if !fileAnswered, protectedData() { reload() }
        guard !isDecoy else { return }
        switch mode {
        case .driving(let since):
            walkFrom = nil
            var next = book
            for device in connected where device.tag != Self.untagged { next.sawDuringDrive(device, driveStart: since) }
            save(next)
        case .cycling:
            walkFrom = nil
        case .onFoot:
            noteWalk(fix)
        }
    }

    /// The person answered Home's question.
    func answer(isCar: Bool) {
        var next = book
        next.answer(isCar: isCar)
        save(next)
    }

    /// Settings' "Use … as my car".
    func mark(_ device: WorldAudioDevice) {
        guard device.tag != Self.untagged else { return }
        var next = book
        next.mark(device, learned: false)
        save(next)
    }

    /// Settings' forget: the car with `tag` is no longer one.
    func forget(tag: String) {
        var next = book
        next.forget(tag: tag)
        save(next)
    }

    /// Reads the file again (the store adopting the source a locked launch started, which learned nothing and may
    /// have read nothing while the phone was locked), and the route with it, so devices read without a salt get
    /// their tags.
    func reload() {
        load()
        connected = audio.outputs().map(device(for:))
        tellLink()
    }

    /// Delete everything: the book and the salt go from memory and the car file from disk, with the keys older builds
    /// used (the funnel's `WorldMapPreferences.clearAll` removes the app's own file and keys again). The next salt
    /// is a new one.
    func forgetAll() {
        book = WorldCarBook()
        salt = nil
        fileAnswered = file.remove()
        WorldMapPreferences.removeLegacyCarKeys(in: defaults)
        walkFrom = nil
        connected = audio.outputs().map(device(for:))
        tellLink()
    }

    /// Measures a walk on foot with Bluetooth connected, marking those devices as headphones once it is long enough.
    private func noteWalk(_ fix: WorldFix) {
        let tags = connected.filter { $0.kind == .bluetooth && $0.tag != Self.untagged }.map(\.tag)
        guard !tags.isEmpty, fix.isPrecise, fix.accuracy <= Self.walkAccuracy,
              (fix.speed ?? 0) <= WorldRideWatch.walkingSpeed else {
            walkFrom = nil
            return
        }
        guard let walkFrom, walkFrom.tags == tags else {
            self.walkFrom = (fix, tags)
            return
        }
        let moved = walkFrom.fix.point.distance(to: fix.point) - walkFrom.fix.accuracy - fix.accuracy
        guard moved >= Self.walkDistance, fix.at.timeIntervalSince(walkFrom.fix.at) >= Self.walkTime else { return }
        var next = book
        for device in connected where device.kind == .bluetooth && device.tag != Self.untagged { next.walkedWith(device) }
        save(next)
        self.walkFrom = nil
    }

    /// Keeps `next` as the book, writing it with its salt when it changed, and tells ``onLinkChanged`` when that
    /// linked or unlinked the car connected now. Nothing is written while the file can't be read or no salt is held.
    private func save(_ next: WorldCarBook) {
        guard next != book else { return }
        book = next
        if fileAnswered, let salt { file.write(WorldCarRecord(salt: salt, book: next)) }
        tellLink()
    }

    /// Reads the salt and the book from the car file, moving them from the defaults when an older build left them
    /// there. An unreadable file leaves no salt and an empty book in memory, and nothing on disk is touched.
    private func load() {
        switch file.read() {
        case .unreadable:
            fileAnswered = false
            salt = nil
            book = WorldCarBook()
        case .record(let record):
            fileAnswered = true
            salt = record.salt
            book = record.book
            adoptLegacy(over: record)
        case .absent:
            fileAnswered = true
            salt = nil
            book = WorldCarBook()
            adoptLegacy(over: nil)
        }
    }

    /// The one-time move from `UserDefaults` (builds before the car file). Only with the protected data readable and
    /// a salt actually present there: an empty read may be a locked phone's, and proves nothing.
    ///
    /// - No file yet (`held` nil): the old salt and book become the file, and the keys go once it is written.
    /// - A file with no car in it, and old keys holding cars: the old ones win. That file was made by a process that
    ///   started before the first unlock and read the defaults as empty; the person's cars are in the keys.
    /// - Any other file: the file wins and the old keys go.
    /// - A book with no salt can match nothing, so it goes and nothing is moved.
    private func adoptLegacy(over held: WorldCarRecord?) {
        guard protectedData() else { return }
        let oldBook = WorldMapPreferences.legacyCarBookData(in: defaults)
        guard let oldSalt = WorldMapPreferences.legacyCarTagSalt(in: defaults) else {
            if oldBook != nil { WorldMapPreferences.removeLegacyCarKeys(in: defaults) }
            return
        }
        var moved = WorldCarRecord(salt: oldSalt, book: WorldCarBook())
        if let oldBook {
            do {
                moved.book = try JSONDecoder().decode(WorldCarBook.self, from: oldBook)
            } catch {
                FernletAuditLog.log("worldMap.cars.loadFailed")
            }
        }
        if let held, !held.book.cars.isEmpty || moved.book.cars.isEmpty {
            WorldMapPreferences.removeLegacyCarKeys(in: defaults)
            return
        }
        salt = moved.salt
        book = moved.book
        guard file.write(moved) else { return }
        WorldMapPreferences.removeLegacyCarKeys(in: defaults)
        FernletAuditLog.log("worldMap.cars.movedToFile")
    }

    /// `output` as car detection keeps it: its identifier scrambled with this iPhone's salt into a tag, or
    /// ``untagged`` while no salt reads and none may be made (the phone locked, or the car file unreadable: the
    /// saved one is never replaced). A new salt is made, in memory, only when the file is truly not there, the
    /// protected data can be read and this keeper never saw the phone locked.
    private func device(for output: WorldAudioOutput) -> WorldAudioDevice {
        if !protectedData() { sawLocked = true }
        if salt == nil, fileAnswered, !sawLocked { salt = UUID().uuidString }
        guard let salt else {
            return WorldAudioDevice(tag: Self.untagged, name: output.name, kind: output.kind)
        }
        let salted = Data((salt + "|" + output.identifier).utf8)
        let tag = SHA256.hash(data: salted).prefix(16).map { String(format: "%02x", $0) }.joined()
        return WorldAudioDevice(tag: tag, name: output.name, kind: output.kind)
    }
}
