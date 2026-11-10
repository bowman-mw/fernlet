import Foundation

/// What kind of audio output the phone is connected to, as car detection reads it (owner 2026-11-09, car signals).
nonisolated enum WorldAudioKind: String, Codable, Equatable, Sendable {
    /// CarPlay: always a car, nothing to learn or mark.
    case carPlay
    /// A Bluetooth audio device: a car, headphones or a speaker, which the car book learns to tell apart.
    case bluetooth
}

/// One connected audio output, in plain values: no AVFAudio type leaves `WorldCarAudio.swift`, and the device's own
/// identifier never leaves ``WorldCarKeeper``, which scrambles it into ``tag`` first.
nonisolated struct WorldAudioDevice: Equatable, Sendable {
    /// A scrambled tag for the device (a salted hash of its identifier): all the car book keeps of most devices.
    let tag: String
    /// Its name as iOS shows it ("Camry"): kept only for a car, or for the one device waiting to be asked about.
    let name: String
    let kind: WorldAudioKind
}

/// Which Bluetooth devices are the person's cars (owner 2026-11-09: "Ask during drive and automatically. Keep track
/// of connected devices while in drive mode. If a device comes up multiple times and is clearly not a headphone, mark
/// it. Should allow for multiple devices … for different cars."). Plain values, kept on this iPhone only by
/// ``WorldCarKeeper``; never synced, backed up or exported, and gone with Delete everything.
///
/// - **CarPlay is always a car** and is never kept here.
/// - **Learning:** a Bluetooth device connected during a drive counts once for that drive (``sawDuringDrive(_:driveStart:)``).
///   After ``learnAfterDrives`` drives it is a car, unless it is headphones or the person said it isn't.
/// - **Asking:** the first drive a new device is seen on, it becomes the one ``question`` ("Is "Camry" your car?"),
///   which Home asks while the person is stopped; Yes marks it, Not my car keeps it out for good (``answer(isCar:)``).
/// - **Headphones** are never cars: a device whose name sounds like headphones (``soundsLikeHeadphones(_:)``), or one
///   the person walked a good way with (``walkedWith(_:)``), which also unmarks a car the book learned by itself (never
///   one the person confirmed).
/// - **Several cars:** up to ``maxCars``; ``forget(tag:)`` removes one (Settings).
///
/// **Bounded** (Power of 10): at most ``maxCars`` cars, ``maxSightings`` devices being counted (the oldest drive goes
/// first) and ``maxTags`` tags in each of the two "never a car" sets (the oldest go first).
nonisolated struct WorldCarBook: Codable, Equatable, Sendable {
    /// A car: its tag, the name to show, and whether the book learned it by itself (headphones evidence can unmark it).
    nonisolated struct Car: Codable, Equatable, Identifiable, Sendable {
        let tag: String
        var name: String
        var learned: Bool
        var id: String { tag }
    }

    /// How many drives a device has been seen on, and the start of the last one (a drive counts once).
    nonisolated struct Sighting: Codable, Equatable, Sendable {
        var drives: Int
        var lastDrive: Date
    }

    /// The device waiting to be asked about.
    nonisolated struct Question: Codable, Equatable, Sendable {
        let tag: String
        let name: String
    }

    /// Drives a device must be seen on before the book marks it as a car by itself.
    static let learnAfterDrives = 3
    /// The most cars kept.
    static let maxCars = 8
    /// The most devices being counted.
    static let maxSightings = 32
    /// The most tags kept as "not my car", and as headphones.
    static let maxTags = 64
    /// Words in a device name that mean headphones or earbuds (lower case; a frozen matching input, never shown).
    static let headphoneWords = ["airpods", "beats", "buds", "headphone", "headset", "earbud", "earphone", "earpod",
                                 "powerbeats", "wh-1000", "wf-1000", "quietcomfort", "jabra", "shokz", "aftershokz"]

    private(set) var cars: [Car] = []
    private(set) var notCars: [String] = []
    private(set) var headphones: [String] = []
    private(set) var sightings: [String: Sighting] = [:]
    private(set) var question: Question?

    /// Whether `device` is a car: CarPlay, or one the book holds.
    func isCar(_ device: WorldAudioDevice) -> Bool {
        device.kind == .carPlay || cars.contains { $0.tag == device.tag }
    }

    /// Whether `device` is headphones: by its name, or because the person walked with it.
    func isHeadphones(_ device: WorldAudioDevice) -> Bool {
        device.kind == .bluetooth && (headphones.contains(device.tag) || Self.soundsLikeHeadphones(device.name))
    }

    /// Whether `name` sounds like headphones or earbuds (``headphoneWords``, ignoring case).
    static func soundsLikeHeadphones(_ name: String) -> Bool {
        let lower = name.lowercased()
        return headphoneWords.contains { lower.contains($0) }
    }

    /// A drive that started at `driveStart` with `device` connected: the device counts once for that drive, becomes the
    /// question the first time, and is a car after ``learnAfterDrives`` drives. Nothing for CarPlay, a car, headphones
    /// or a device the person said isn't their car.
    mutating func sawDuringDrive(_ device: WorldAudioDevice, driveStart: Date) {
        guard device.kind == .bluetooth, !isCar(device), !isHeadphones(device), !notCars.contains(device.tag) else { return }
        var sighting = sightings[device.tag] ?? Sighting(drives: 0, lastDrive: .distantPast)
        guard sighting.lastDrive != driveStart else { return }
        sighting.drives += 1
        sighting.lastDrive = driveStart
        guard sighting.drives < Self.learnAfterDrives else {
            mark(device, learned: true)
            return
        }
        sightings[device.tag] = sighting
        trimSightings()
        if question == nil { question = Question(tag: device.tag, name: device.name) }
    }

    /// The person walked a good way with `device` connected: it travels with them, so it is headphones from now on. A
    /// car the book learned by itself is unmarked; one the person confirmed stays.
    mutating func walkedWith(_ device: WorldAudioDevice) {
        guard device.kind == .bluetooth else { return }
        cars.removeAll { $0.tag == device.tag && $0.learned }
        guard !cars.contains(where: { $0.tag == device.tag }) else { return }
        sightings[device.tag] = nil
        if question?.tag == device.tag { question = nil }
        guard !headphones.contains(device.tag) else { return }
        headphones.append(device.tag)
        if headphones.count > Self.maxTags { headphones.removeFirst(headphones.count - Self.maxTags) }
    }

    /// The person answered the question: Yes marks the device as their car, Not my car keeps it out for good.
    mutating func answer(isCar yes: Bool) {
        guard let question else { return }
        let device = WorldAudioDevice(tag: question.tag, name: question.name, kind: .bluetooth)
        guard yes else {
            self.question = nil
            sightings[question.tag] = nil
            if !notCars.contains(question.tag) { notCars.append(question.tag) }
            if notCars.count > Self.maxTags { notCars.removeFirst(notCars.count - Self.maxTags) }
            return
        }
        mark(device, learned: false)
    }

    /// Marks `device` as a car (the person's Yes or Settings' "Use … as my car", or learned): the newest is kept when
    /// the book is full, and the device leaves the counted, "not my car" and headphones lists.
    mutating func mark(_ device: WorldAudioDevice, learned: Bool) {
        guard device.kind == .bluetooth else { return }
        sightings[device.tag] = nil
        notCars.removeAll { $0 == device.tag }
        headphones.removeAll { $0 == device.tag }
        if question?.tag == device.tag { question = nil }
        if let index = cars.firstIndex(where: { $0.tag == device.tag }) {
            cars[index].name = device.name
            cars[index].learned = cars[index].learned && learned
            return
        }
        cars.append(Car(tag: device.tag, name: device.name, learned: learned))
        if cars.count > Self.maxCars { cars.removeFirst(cars.count - Self.maxCars) }
    }

    /// Forgets the car with `tag` (Settings): it can be learned again later.
    mutating func forget(tag: String) {
        cars.removeAll { $0.tag == tag }
    }

    /// Drops the devices counted on the oldest drives while more than ``maxSightings`` are counted.
    private mutating func trimSightings() {
        let excess = sightings.count - Self.maxSightings
        guard excess > 0 else { return }
        // Bounded: at most maxSightings + 1 entries are sorted.
        let oldest = sightings.sorted { $0.value.lastDrive < $1.value.lastDrive }.prefix(excess).map(\.key)
        for tag in oldest { sightings[tag] = nil }
    }
}
