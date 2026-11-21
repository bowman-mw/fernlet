import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The tracker diary (owner 2026-11-21: "events only, no places", a Settings switch off by default): what it may
/// hold, that it is bounded to 48 hours, sealed in the map's vault, silent in a decoy, gone with every wipe and with
/// its switch, and how its lines read.
@MainActor
struct WorldTrackerDiaryTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000_040)

    /// A diary over `vault`, on, with a clock the test moves.
    private static func diary(_ vault: WorldMapVault, on: Bool = true, clock given: Clock? = nil) -> WorldTrackerDiary {
        let clock = given ?? Clock()
        let diary = WorldTrackerDiary()
        diary.isOn = { on }
        diary.now = { clock.now }
        diary.attach(vault: vault)
        return diary
    }

    /// Whether the diary's file is in `vault`.
    private static func hasFile(_ vault: WorldMapVault) throws -> Bool {
        try vault.read(WorldTrackerDiary.file) != nil
    }

    /// A clock a test sets.
    @MainActor
    final class Clock {
        var now = WorldTrackerDiaryTests.start
        var isDecoy = false
    }

    // MARK: No places

    /// A line has a time, a kind, a token, a number and counts, and nothing else: no field could hold a coordinate,
    /// and the file's keys are exactly those five.
    @Test func aLineCannotHoldAPlace() throws {
        let event = WorldDiaryEvent(at: Self.start, kind: .fenceArmed, detail: "", value: 158, counts: [])
        let fields = Mirror(reflecting: event).children.compactMap(\.label).sorted()
        #expect(fields == ["at", "counts", "detail", "kind", "value"])
        let data = try WorldTrackerDiary.encode([event, WorldDiaryEvent(at: Self.start, kind: .readings, counts: [3, 2, 1, 0])])
        let json = try JSONSerialization.jsonObject(with: data)
        let rows = try #require(json as? [[String: Any]])
        #expect(rows.allSatisfy { Set($0.keys) == ["at", "counts", "detail", "kind", "value"] })
        let text = try #require(String(data: data, encoding: .utf8)).lowercased()
        for word in ["lat", "lon", "point", "coordinate", "accuracy"] {
            #expect(!text.contains(word), "\(word)")
        }
        let decoded = try WorldTrackerDiary.decode(data)
        #expect(decoded.count == 2)
    }

    /// The kinds are frozen tokens: the file is read back by them.
    @Test func theKindsAreFrozenTokens() {
        #expect(WorldDiaryEventKind.allCases.map(\.rawValue) == ["fenceExit", "fenceArmed", "listenStarted", "listenEnded",
                                                                 "traceStarted", "traceEnded", "readings", "mode", "motion"])
        #expect(WorldListenReason.fenceExit.rawValue == "fenceExit" && WorldListenEnd.timeUp.rawValue == "timeUp")
        #expect(WorldTrackerDiary.token(for: .walk) == "walk" && WorldTrackerDiary.token(for: .drive) == "drive")
        #expect(WorldTrackerDiary.token(for: .onFoot) == "onFoot" && WorldTrackerDiary.token(for: .driving(since: Self.start)) == "driving")
    }

    // MARK: Bounded

    /// Readings are counted a minute at a time by accuracy: 10 m, 30 m, 65 m, rougher.
    @Test func aMinutesReadingsAreCountedByAccuracy() {
        #expect([5.0, 10, 11, 30, 64, 65, 66, 900, -1, .nan].map(WorldDiaryLog.bucket) == [0, 0, 1, 1, 2, 2, 3, 3, 3, 3])
        var log = WorldDiaryLog()
        for (second, accuracy) in [(0.0, 6.0), (5, 8), (12, 25), (18, 300)] {
            let closed = log.count(accuracy: accuracy, at: Self.start.addingTimeInterval(second))
            #expect(!closed)
        }
        #expect(log.events.isEmpty, "the minute is still open")
        let closed = log.count(accuracy: 8, at: Self.start.addingTimeInterval(70))
        #expect(closed, "the next minute closes it")
        #expect(log.events.count == 1 && log.events.first?.kind == .readings)
        #expect(log.events.first?.counts == [2, 1, 0, 1])
        let last = log.closeMinute()
        let again = log.closeMinute()
        #expect(last && !again)
        #expect(log.events.last?.counts == [1, 0, 0, 0])
    }

    /// Nothing older than 48 hours is kept, nor more than the cap.
    @Test func theDiaryIsBoundedToFortyEightHours() {
        var log = WorldDiaryLog()
        log.add(WorldDiaryEvent(at: Self.start, kind: .fenceExit))
        log.add(WorldDiaryEvent(at: Self.start.addingTimeInterval(47 * 3_600), kind: .fenceExit))
        #expect(log.events.count == 2)
        log.add(WorldDiaryEvent(at: Self.start.addingTimeInterval(48 * 3_600 + 1), kind: .fenceExit))
        #expect(log.events.count == 2 && log.events.first?.at == Self.start.addingTimeInterval(47 * 3_600))
        var full = WorldDiaryLog()
        for index in 0..<(WorldDiaryLog.maxEvents + 50) {
            full.add(WorldDiaryEvent(at: Self.start.addingTimeInterval(Double(index)), kind: .mode, detail: "onFoot"))
        }
        #expect(full.events.count == WorldDiaryLog.maxEvents && full.events.first?.at == Self.start.addingTimeInterval(50))
        #expect(WorldDiaryLog.keepTime == 48 * 3_600 && WorldDiaryLog.maxEvents <= 10_000)
        let oversized = (0..<(WorldDiaryLog.maxEvents + 9)).map { WorldDiaryEvent(at: Self.start.addingTimeInterval(Double($0)), kind: .fenceExit) }
        #expect(WorldDiaryLog(events: oversized).events.count == WorldDiaryLog.maxEvents)
    }

    // MARK: The switch, the vault, the decoy, the wipe

    /// Off (the default) nothing is kept and no file is written; on, each line is sealed in the map's vault at once
    /// and a relaunch reads it back.
    @Test func offKeepsNothingAndOnSealsEachLine() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldTrackerDiaryTests.\(UUID().uuidString)"))
        #expect(!WorldMapPreferences.trackerDiary(in: defaults), "off by default")
        WorldMapPreferences.setTrackerDiary(true, in: defaults)
        #expect(WorldMapPreferences.trackerDiary(in: defaults))
        WorldMapPreferences.clearAll(in: defaults)
        #expect(!WorldMapPreferences.trackerDiary(in: defaults), "the delete funnel turns it off")

        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let off = Self.diary(vault, on: false)
        off.note(.fenceExit)
        off.countReading(accuracy: 8, at: Self.start)
        off.flush()
        let offFile = try Self.hasFile(vault)
        #expect(off.events.isEmpty && !offFile)

        let diary = Self.diary(vault)
        diary.note(.fenceExit)
        diary.note(.listenStarted, detail: WorldListenReason.fenceExit.rawValue)
        diary.note(.fenceArmed, value: 158)
        #expect(diary.events.map(\.kind) == [.fenceExit, .listenStarted, .fenceArmed])
        let read = try vault.read(WorldTrackerDiary.file)
        let sealed = try #require(read)
        let kept = try WorldTrackerDiary.decode(sealed)
        #expect(kept.count == 3)
        #expect(WorldTrackerDiary.file.name == "tracker-diary.bin")

        let relaunched = Self.diary(vault)
        relaunched.note(.traceStarted, detail: "walk")
        #expect(relaunched.events.map(\.kind) == [.fenceExit, .listenStarted, .fenceArmed, .traceStarted], "the file's lines first")
    }

    /// A minute's readings wait for the fifth closed minute, or for a flush, before they are written.
    @Test func readingsAreSavedEveryFewMinutesOrOnAFlush() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let diary = Self.diary(vault)
        diary.countReading(accuracy: 8, at: Self.start)
        diary.countReading(accuracy: 8, at: Self.start.addingTimeInterval(61))
        let early = try Self.hasFile(vault)
        #expect(diary.events.count == 1 && !early, "one closed minute waits")
        diary.flush()
        let read = try vault.read(WorldTrackerDiary.file)
        let sealed = try #require(read)
        let kept = try WorldTrackerDiary.decode(sealed)
        #expect(kept.map(\.counts) == [[1, 0, 0, 0], [1, 0, 0, 0]])
    }

    /// A decoy session writes nothing and shows nothing; the real diary is untouched by it.
    @Test func aDecoyWritesAndShowsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let clock = Clock()
        let diary = Self.diary(vault, clock: clock)
        diary.note(.fenceExit)
        diary.mayWrite = { !clock.isDecoy }
        clock.isDecoy = true
        diary.note(.traceStarted, detail: "drive")
        diary.countReading(accuracy: 8, at: Self.start)
        diary.refresh()
        #expect(diary.events.isEmpty && !diary.isKeeping)
        clock.isDecoy = false
        diary.refresh()
        #expect(diary.events.map(\.kind) == [.fenceExit], "the decoy's doings never reached it")
    }

    /// Turning the switch off forgets the diary, and the map's wipe (every wipe path ends in the fog keeper's
    /// `clearAll`) removes the file and the lines in memory.
    @Test func theSwitchAndEveryWipeForgetIt() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let diary = Self.diary(vault)
        diary.note(.fenceExit)
        let forgot = diary.forget()
        let afterSwitch = try Self.hasFile(vault)
        #expect(forgot && diary.events.isEmpty && !afterSwitch)

        diary.note(.fenceExit)
        let written = try Self.hasFile(vault)
        #expect(written)
        let defaults = try #require(UserDefaults(suiteName: "WorldTrackerDiaryTests.\(UUID().uuidString)"))
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        keeper.onCleared = { diary.forget() }
        _ = keeper.clearAll()
        let afterWipe = try Self.hasFile(vault)
        #expect(diary.events.isEmpty && !afterWipe)
        diary.note(.listenStarted, detail: "hint")
        #expect(diary.events.count == 1, "nothing from before the wipe comes back")
    }

    // MARK: The location source tells it

    /// The source counts each reading it hands on and notes a mode change, with no place in any line.
    @Test func theSourceCountsReadingsAndNotesTheMode() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let source = WorldLocationSource(backgroundMapping: { true })
        source.diary.isOn = { true }
        source.diary.now = { Self.start.addingTimeInterval(30) }
        source.diary.attach(vault: vault)
        let here = GeoPoint(45.5205, -122.6255)
        for step in 0..<14 {
            source.deliver(WorldFix(point: here.offset(east: Double(step) * 75, north: 0), accuracy: 8,
                                    at: Self.start.addingTimeInterval(Double(step) * 5), isPrecise: true, speed: 15))
        }
        #expect(source.rides.isDriving)
        source.diary.flush()
        let kinds = source.diary.events.map(\.kind)
        #expect(kinds.contains(.mode) && kinds.contains(.readings))
        #expect(source.diary.events.first { $0.kind == .mode }?.detail == "driving")
        let counted = source.diary.events.filter { $0.kind == .readings }.flatMap(\.counts).reduce(0, +)
        #expect(counted == 14)
    }

    // MARK: The screen's rows

    /// The page lists the lines newest first, each in words; a token this build does not know still reads.
    @Test func theRowsAreNewestFirstAndInWords() {
        let events = [WorldDiaryEvent(at: Self.start, kind: .fenceExit),
                      WorldDiaryEvent(at: Self.start.addingTimeInterval(1), kind: .listenStarted, detail: "fenceExit"),
                      WorldDiaryEvent(at: Self.start.addingTimeInterval(60), kind: .readings, counts: [4, 1, 0, 2]),
                      WorldDiaryEvent(at: Self.start.addingTimeInterval(70), kind: .traceStarted, detail: "walk"),
                      WorldDiaryEvent(at: Self.start.addingTimeInterval(80), kind: .traceStarted, detail: "hovercraft")]
        let rows = TrackerDiaryRow.rows(from: events)
        let ids: [Int] = rows.map(\.id)
        #expect(ids == [0, 1, 2, 3, 4])
        #expect(rows.first?.at == Self.start.addingTimeInterval(80))
        let keys: [String] = rows.map(\.title.key)
        let expected = ["trackerDiary.other", "trackerDiary.trace.walk", "trackerDiary.readings",
                        "trackerDiary.listen.fenceExit", "trackerDiary.fenceExit"]
        #expect(keys == expected)
        #expect(rows[2].detail?.key == "trackerDiary.readings.detail")
        #expect(rows[0].detail == nil)
        #expect(TrackerDiaryRow.rows(from: []).isEmpty)
        // Every kind and token has words.
        for reason in ["fenceExit", "carLinked", "hint", "fastReading", "visitDeparture"] {
            #expect(TrackerDiaryCopy.title(WorldDiaryEvent(at: Self.start, kind: .listenStarted, detail: reason)).key != "trackerDiary.other")
        }
        for end in ["timeUp", "traceTookOver", "passengerDriving", "mappingOff"] {
            #expect(TrackerDiaryCopy.title(WorldDiaryEvent(at: Self.start, kind: .listenEnded, detail: end)).key != "trackerDiary.other")
        }
        for kind in ["stationary", "walking", "running", "cycling", "automotive", "unknown"] {
            #expect(TrackerDiaryCopy.title(WorldDiaryEvent(at: Self.start, kind: .motion, detail: kind)).key != "trackerDiary.other")
        }
        for token in ["drive", "ride", "walk"] {
            #expect(TrackerDiaryCopy.title(WorldDiaryEvent(at: Self.start, kind: .traceEnded, detail: token)).key != "trackerDiary.other")
        }
    }
}
