import CryptoKit
import FernletFoundation
import Foundation
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
/// - **Kept on this iPhone only** (``WorldMapPreferences``' car book, cleared by Delete everything): a device's own
///   identifier never leaves this type; it is scrambled with the per-install salt into a tag first, and a name is kept
///   only for a car or the one device waiting to be asked about. Nothing is learned in a decoy.
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
    @ObservationIgnored private let defaults: UserDefaults
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

    /// A keeper reading `audio` (the phone's route by default; tests pass a scripted one) and saving in `defaults`.
    init(audio: (any WorldAudioReading)? = nil, defaults: UserDefaults = .standard) {
        self.audio = audio ?? WorldCarAudio()
        self.defaults = defaults
        book = Self.loadBook(from: defaults)
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
        return connected.first { $0.kind == .bluetooth && !book.isCar($0) && !book.isHeadphones($0) }
    }

    /// Reads the route again, telling ``onLinkChanged`` when a car connected or went.
    func refresh() {
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
    /// foot a long enough walk with one connected marks it as headphones. Nothing in a decoy.
    func noteReading(_ fix: WorldFix, mode: WorldRideMode) {
        guard !isDecoy else { return }
        switch mode {
        case .driving(let since):
            walkFrom = nil
            var next = book
            for device in connected { next.sawDuringDrive(device, driveStart: since) }
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

    /// Reads the book from disk again (the store adopting the source a locked launch started, which learned nothing
    /// and may have read nothing while the phone was locked).
    func reload() {
        book = Self.loadBook(from: defaults)
        tellLink()
    }

    /// Delete everything: the book goes from memory (the funnel's `WorldMapPreferences.clearAll` removes it and the
    /// salt from disk).
    func forgetAll() {
        book = WorldCarBook()
        walkFrom = nil
        connected = audio.outputs().map(device(for:))
        tellLink()
    }

    /// Measures a walk on foot with Bluetooth connected, marking those devices as headphones once it is long enough.
    private func noteWalk(_ fix: WorldFix) {
        let tags = connected.filter { $0.kind == .bluetooth }.map(\.tag)
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
        for device in connected where device.kind == .bluetooth { next.walkedWith(device) }
        save(next)
        self.walkFrom = nil
    }

    /// Keeps `next` as the book, writing it when it changed, and tells ``onLinkChanged`` when that linked or unlinked
    /// the car connected now.
    private func save(_ next: WorldCarBook) {
        guard next != book else { return }
        book = next
        do {
            WorldMapPreferences.setCarBookData(try JSONEncoder().encode(next), in: defaults)
        } catch {
            FernletAuditLog.log("worldMap.cars.saveFailed")
        }
        tellLink()
    }

    /// The book saved in `defaults`, or an empty one (nothing saved, or bytes from another version).
    private static func loadBook(from defaults: UserDefaults) -> WorldCarBook {
        guard let data = WorldMapPreferences.carBookData(in: defaults) else { return WorldCarBook() }
        do {
            return try JSONDecoder().decode(WorldCarBook.self, from: data)
        } catch {
            FernletAuditLog.log("worldMap.cars.loadFailed")
            return WorldCarBook()
        }
    }

    /// `output` as car detection keeps it: its identifier scrambled with this iPhone's salt into a tag.
    private func device(for output: WorldAudioOutput) -> WorldAudioDevice {
        let salted = Data((WorldMapPreferences.carTagSalt(in: defaults) + "|" + output.identifier).utf8)
        let tag = SHA256.hash(data: salted).prefix(16).map { String(format: "%02x", $0) }.joined()
        return WorldAudioDevice(tag: tag, name: output.name, kind: output.kind)
    }
}
