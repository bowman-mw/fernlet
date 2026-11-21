import FernletFoundation
import Foundation
import WorldMapStore

/// What a tracker diary line is about. Frozen tokens: the rawValue is written to the diary's file.
nonisolated enum WorldDiaryEventKind: String, Codable, CaseIterable, Sendable {
    /// iOS woke Fernlet because the person left the leaving fence.
    case fenceExit
    /// A leaving fence was armed; the line's value is its radius in metres.
    case fenceArmed
    /// A listen started; the detail is a ``WorldListenReason``.
    case listenStarted
    /// A listen ended; the detail is a ``WorldListenEnd``.
    case listenEnded
    /// A trace started or ended; the detail is its kind (``WorldTrackerDiary/token(for:)``).
    case traceStarted
    case traceEnded
    /// The readings of one minute, counted by accuracy (``WorldDiaryLog/bucket(for:)``).
    case readings
    /// Car and bike detection's mode changed; the detail is `onFoot`, `driving` or `cycling`.
    case mode
    /// Motion's activity changed; the detail is a `WorldMotionKind` rawValue.
    case motion
}

/// Why a listen started. Frozen tokens.
nonisolated enum WorldListenReason: String, Sendable {
    case fenceExit, carLinked, hint, fastReading, visitDeparture
}

/// Why a listen ended. Frozen tokens.
nonisolated enum WorldListenEnd: String, Sendable {
    /// Its time ran out with nothing found.
    case timeUp
    /// A drive, a ride or a walk was found and its trace took the updates over.
    case traceTookOver
    /// A road trip's passenger turned out to be driving.
    case passengerDriving
    /// Background mapping went off, or Always was withdrawn.
    case mappingOff
}

/// One line of the tracker diary: when, what, and a token or a count. **No coordinate can be written**: there is no
/// field for one (owner 2026-11-21, "events only, no places").
nonisolated struct WorldDiaryEvent: Codable, Equatable, Sendable {
    /// When it happened.
    let at: Date
    /// What happened.
    let kind: WorldDiaryEventKind
    /// Why, or which (a frozen token); empty when the kind says it all.
    var detail = ""
    /// A fence's radius in metres; 0 for any other kind.
    var value = 0
    /// A minute's readings by accuracy bucket (``WorldDiaryLog/bucketLimits``); empty for any other kind.
    var counts: [Int] = []
}

/// The diary's lines and its rules, as plain values: at most ``keepTime`` back and ``maxEvents`` long, oldest first,
/// with one minute of readings being counted.
nonisolated struct WorldDiaryLog: Equatable, Sendable {
    /// How far back the diary reaches (owner 2026-11-21: the last 48 hours).
    static let keepTime: TimeInterval = 48 * 60 * 60
    /// The most lines kept (a bound: a line a minute for 48 hours is 2,880).
    static let maxEvents = 5_000
    /// The accuracy, in metres, each bucket but the last reaches up to: 10 m, 30 m, the fog's 65 m, and worse.
    static let bucketLimits = [10.0, 30.0, 65.0]

    /// The lines, oldest first.
    private(set) var events: [WorldDiaryEvent] = []
    /// The minute being counted and its readings by bucket; nil between readings' minutes.
    private(set) var minute: (start: Date, counts: [Int])?

    static func == (lhs: WorldDiaryLog, rhs: WorldDiaryLog) -> Bool {
        lhs.events == rhs.events && lhs.minute?.start == rhs.minute?.start && lhs.minute?.counts == rhs.minute?.counts
    }

    /// A log holding `events` (those a file gave back), bounded and in order.
    init(events: [WorldDiaryEvent] = []) {
        self.events = Array(events.sorted { $0.at < $1.at }.suffix(Self.maxEvents))
    }

    /// The bucket a reading of `accuracy` metres counts in: 0 for 10 m or better, then 30 m, 65 m, and 3 for worse
    /// (or no accuracy at all).
    static func bucket(for accuracy: Double) -> Int {
        guard accuracy.isFinite, accuracy >= 0 else { return bucketLimits.count }
        return bucketLimits.firstIndex { accuracy <= $0 } ?? bucketLimits.count
    }

    /// Adds a line and drops what is older than ``keepTime`` before it or beyond ``maxEvents``.
    mutating func add(_ event: WorldDiaryEvent) {
        events.append(event)
        prune(now: event.at)
    }

    /// Drops the lines older than ``keepTime`` before `now` and, beyond ``maxEvents``, the oldest.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keepTime)
        events.removeAll { $0.at < cutoff }
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    /// Counts a reading of `accuracy` taken `at`; whether an earlier minute closed (and became a line).
    @discardableResult
    mutating func count(accuracy: Double, at: Date) -> Bool {
        let start = Date(timeIntervalSince1970: (at.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var closed = false
        if let minute, minute.start != start { closed = closeMinute() }
        var counts = minute?.counts ?? Array(repeating: 0, count: Self.bucketLimits.count + 1)
        counts[Self.bucket(for: accuracy)] += 1
        minute = (start, counts)
        return closed
    }

    /// Turns the minute being counted into a line; whether there was one.
    @discardableResult
    mutating func closeMinute() -> Bool {
        guard let minute else { return false }
        self.minute = nil
        add(WorldDiaryEvent(at: minute.start, kind: .readings, counts: minute.counts))
        return true
    }

    /// Forgets everything.
    mutating func clear() {
        events = []
        minute = nil
    }
}

/// The tracker diary (owner 2026-11-21, picked after a city walk the map missed left no record to read): while its
/// Settings switch is on (Home map, off by default), the last 48 hours of what background mapping did and when.
/// Events and counts only, never a place.
///
/// - **What it holds:** ``WorldDiaryEvent`` lines from ``WorldLocationSource``: a fence exit, a fence armed and its
///   radius, a listen started or ended and why, a trace started or ended and its kind, each minute's readings by
///   accuracy, mode changes and Motion's changes.
/// - **Where:** one file in the World map vault (``file``, the device side's purpose under the buffer key, so a line
///   written with the phone locked is kept), on this iPhone only: never synced, backed up, exported or sent
///   anywhere. The vault's wipe removes it with the map's history, on every wipe path; ``forget()`` clears the lines
///   in memory with it (the fog keeper calls it from its own `clearAll`), and turning the switch off forgets it too.
/// - **A decoy session** writes nothing and shows nothing (``mayWrite``).
/// - **Bounded:** ``WorldDiaryLog/keepTime`` and ``WorldDiaryLog/maxEvents``. A file that can't be read yet (before
///   the first unlock) is left alone, and the lines wait in memory.
@MainActor
@Observable
final class WorldTrackerDiary {
    /// The diary's file: its own name and context, so it never opens as another of the vault's files.
    static let file = WorldMapVault.File(name: "tracker-diary.bin", purpose: WorldMapVault.File.placesDevice.purpose,
                                         role: .buffer, context: Data("trackerDiary".utf8))
    /// How many closed minutes of readings may wait unsaved (any other line saves at once).
    static let minutesPerSave = 5

    /// The lines, oldest first, as the screen reads them.
    private(set) var events: [WorldDiaryEvent] = []

    /// Whether the switch is on (``WorldMapPreferences/trackerDiary(in:)``; tests inject one).
    @ObservationIgnored var isOn: @MainActor () -> Bool = { WorldMapPreferences.trackerDiary() }
    /// Whether lines may be kept now: false in a decoy session (the store sets it).
    @ObservationIgnored var mayWrite: @MainActor () -> Bool = { true }
    /// The clock (tests set it).
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    @ObservationIgnored private var log = WorldDiaryLog()
    @ObservationIgnored private var vault: WorldMapVault?
    /// Whether the file has been read (or found absent) since the diary was attached or forgotten.
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var unsavedMinutes = 0

    /// Gives the diary the map's vault; the file is read with the first line.
    func attach(vault: WorldMapVault) {
        self.vault = vault
        isLoaded = false
    }

    /// Whether lines are being kept now: the switch on, no decoy.
    var isKeeping: Bool { isOn() && mayWrite() }

    /// Keeps a line of `kind` with its token and value, and saves.
    func note(_ kind: WorldDiaryEventKind, detail: String = "", value: Int = 0) {
        guard isKeeping else { return }
        load()
        log.add(WorldDiaryEvent(at: now(), kind: kind, detail: detail, value: value))
        save()
    }

    /// Counts a reading of `accuracy` metres taken `at`; a minute that closed becomes a line, saved every
    /// ``minutesPerSave``.
    func countReading(accuracy: Double, at: Date) {
        guard isKeeping else { return }
        guard log.count(accuracy: accuracy, at: at) else { return }
        unsavedMinutes += 1
        if unsavedMinutes >= Self.minutesPerSave {
            load()
            save()
        } else {
            events = log.events
        }
    }

    /// Closes the minute being counted and saves (a listen or a trace ended, or Fernlet left the front).
    func flush() {
        guard isKeeping, log.closeMinute() || unsavedMinutes > 0 else { return }
        load()
        save()
    }

    /// Reads the file for the screen (the switch on, no decoy); nothing otherwise.
    func refresh() {
        guard isKeeping else {
            if !events.isEmpty { events = [] }
            return
        }
        load()
        log.prune(now: now())
        events = log.events
    }

    /// Forgets every line, in memory and on disk (the switch turned off; the fog keeper's wipe, whose vault wipe has
    /// already removed the file). Whether the file is gone.
    @discardableResult
    func forget() -> Bool {
        log.clear()
        events = []
        unsavedMinutes = 0
        isLoaded = false
        return vault?.remove(Self.file) ?? true
    }

    /// Reads the file once: its lines go before the ones noted since. A file that can't be read yet is left for the
    /// next try; one that can't be opened at all is removed.
    private func load() {
        guard !isLoaded, let vault else { return }
        do {
            let kept = try vault.read(Self.file).map(Self.decode) ?? []
            let pending = log.minute
            var merged = WorldDiaryLog(events: kept + log.events)
            if let pending { merged.restore(minute: pending) }
            log = merged
            isLoaded = true
        } catch where WorldMapVault.isTryAgainLater(error) {
            FernletAuditLog.log("worldMap.diary.loadDeferred")
        } catch {
            FernletAuditLog.log("worldMap.diary.unopenable")
            _ = vault.remove(Self.file)
            isLoaded = true
        }
    }

    /// Writes the lines when the file has been read; until then they wait in memory.
    private func save() {
        log.prune(now: now())
        events = log.events
        guard isLoaded, let vault else { return }
        do {
            try vault.write(Self.encode(log.events), to: Self.file)
            unsavedMinutes = 0
        } catch {
            FernletAuditLog.log("worldMap.diary.saveDeferred")
        }
    }

    /// The file's bytes for `events`: JSON, dates as whole seconds.
    nonisolated static func encode(_ events: [WorldDiaryEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(Array(events.suffix(WorldDiaryLog.maxEvents)))
    }

    /// The lines in a file's bytes (at most ``WorldDiaryLog/maxEvents``, the newest); throws on bytes that are not a
    /// diary.
    nonisolated static func decode(_ data: Data) throws -> [WorldDiaryEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return Array(try decoder.decode([WorldDiaryEvent].self, from: data).suffix(WorldDiaryLog.maxEvents))
    }

    /// A trace kind's token in the diary (frozen).
    nonisolated static func token(for trace: WorldTrace) -> String {
        switch trace {
        case .drive: "drive"
        case .ride: "ride"
        case .walk: "walk"
        }
    }

    /// A mode's token in the diary (frozen).
    nonisolated static func token(for mode: WorldRideMode) -> String {
        switch mode {
        case .onFoot: "onFoot"
        case .driving: "driving"
        case .cycling: "cycling"
        }
    }
}

extension WorldDiaryLog {
    /// Puts back the minute that was being counted when a file's lines were merged in.
    mutating func restore(minute: (start: Date, counts: [Int])) {
        self.minute = minute
    }
}
