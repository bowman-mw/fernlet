import CryptoKit
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// A made-up calendar (World-Airports-Spec's data rule: a Portland traveller on Cedar Air, never anyone's real
/// calendar): the events handed over per window, which windows were asked for, and which titles passed the first
/// pass. Read-only, like the real one.
private nonisolated final class FakeCalendar: CalendarEventSource, @unchecked Sendable {
    // @unchecked: the tests touch it from one task at a time; the lock keeps the counters whole anyway.
    private let lock = NSLock()
    private var state: CalendarAccess
    private let answer: CalendarAccess
    private let events: [CalendarFlightEvent]
    private var asked: [DateInterval] = []
    private var asks = 0

    init(access: CalendarAccess = .allowed, answer: CalendarAccess = .allowed, events: [CalendarFlightEvent]) {
        state = access
        self.answer = answer
        self.events = events
    }

    var windows: [DateInterval] { lock.withLock { asked } }
    var requests: Int { lock.withLock { asks } }

    func revoke() { lock.withLock { state = .refused } }

    func access() -> CalendarAccess { lock.withLock { state } }

    func requestAccess() async -> CalendarAccess {
        answerAsk()
    }

    /// iOS's answer: the first ask settles a not-yet-asked state.
    private func answerAsk() -> CalendarAccess {
        lock.withLock {
            asks += 1
            if state == .notAsked { state = answer }
            return state
        }
    }

    func events(in interval: DateInterval, limit: Int, mightBeFlight: (String) -> Bool) -> CalendarEventBatch {
        lock.withLock { asked.append(interval) }
        guard access() == .allowed else { return CalendarEventBatch(events: [], looked: 0) }
        let inside = events.filter { $0.end > interval.start && $0.start < interval.end }.prefix(limit)
        return CalendarEventBatch(events: inside.filter { mightBeFlight($0.title) }, looked: inside.count)
    }
}

/// Flights from Calendar and the "Airports and flights" switch (World-Airports-Spec §10, §11): the look's sorting,
/// windows and caps; the import plan with event hashes; the salt; the switch's gate and its delete; today's flight
/// at an airport; the first look, the summary's numbers, its confirm and Undo; keep watching; and the decoy.
@MainActor
struct CalendarFlightsTests {
    nonisolated static let salt = SymmetricKey(data: Data(repeating: 9, count: 32))
    nonisolated static let now = flightUTC("2026-11-10T18:00:00Z")
    nonisolated static let airports = FlightTestAirports()

    /// A codes-in-title Cedar Air event.
    nonisolated static func event(_ title: String, _ start: String, hours: Double = 5.75, id: String? = nil) -> CalendarFlightEvent {
        let begin = flightUTC(start)
        return CalendarFlightEvent(title: title, location: nil, notes: nil, start: begin,
                                   end: begin.addingTimeInterval(hours * 3_600), isAllDay: false,
                                   timeZoneIdentifier: "America/Los_Angeles", locationCoordinate: nil,
                                   externalIdentifier: id ?? title + start)
    }

    /// Two flown (2019, 2024), one repeated, two upcoming, one with no airports and one dinner.
    nonisolated static let calendarEvents: [CalendarFlightEvent] = [
        event("Cedar Air flight 812 PDX → HNL", "2019-03-14T17:05:00Z"),
        event("Cedar Air flight 812 PDX → HNL", "2019-03-14T17:05:00Z", id: "copy"),
        event("Cedar Air flight 64 PDX → LHR", "2024-05-10T20:00:00Z", hours: 9.5),
        event("Cedar Air flight 812 PDX → HNL", "2026-11-14T17:05:00Z"),
        event("Cedar Air flight 813 HNL → PDX", "2026-11-21T23:00:00Z", hours: 5.5),
        event("Flight to Honolulu", "2025-02-01T17:00:00Z"),
        event("Dinner with the Cedar team", "2026-11-09T02:00:00Z", hours: 2),
    ]

    static func look(_ events: [CalendarFlightEvent] = calendarEvents) -> CalendarFlightLook {
        CalendarFlightLook(events: events, airports: airports, salt: salt, now: now,
                           deviceTimeZone: TimeZone(identifier: "America/Los_Angeles") ?? .gmt)
    }

    static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "CalendarFlightsTests.\(UUID().uuidString)"))
    }

    // MARK: The look

    /// Flown and upcoming split at now, a repeated event kept once, every flight from the calendar with its salted
    /// hash, the airport-less "flight" counted, the dinner dropped.
    @Test func lookSortsFlights() throws {
        let look = Self.look()
        #expect(look.flown.map(\.route) == ["PDX>HNL", "PDX>LHR"])
        #expect(look.upcoming.map(\.route) == ["PDX>HNL", "HNL>PDX"])
        #expect(look.noAirportCodes == 1)
        #expect(look.airportCount == 3)
        #expect(look.years == 2019...2026)
        for flight in look.flown + look.upcoming {
            #expect(flight.sources == .calendar)
            #expect(flight.eventHash.map(PassportFlight.isValidEventHash) == true)
        }
        let first = try #require(look.flown.first)
        let hashes = ["Cedar Air flight 812 PDX → HNL2019-03-14T17:05:00Z", "copy"].map { CalendarFlightParser.eventHash($0, salt: Self.salt) }
        #expect(first.eventHash.map(hashes.contains) == true)
    }

    /// The first look reads from 1 January 2019 to 60 days ahead, each look from 2 days ago, and every window is cut
    /// into back-to-back pieces EventKit takes (under four years: 2019 to January 2027 is three).
    @Test func windowsAndPieces() throws {
        let first = CalendarFlightLook.firstLookWindow(now: Self.now)
        #expect(first.start == flightUTC("2019-01-01T00:00:00Z"))
        #expect(first.end == Self.now.addingTimeInterval(60 * 86_400))
        let watch = CalendarFlightLook.watchWindow(now: Self.now)
        #expect(watch.start == Self.now.addingTimeInterval(-2 * 86_400) && watch.end == first.end)
        let pieces = CalendarFlightLook.chunks(of: first)
        #expect(pieces.count == 3)
        #expect(pieces.first?.start == first.start && pieces.last?.end == first.end)
        for (index, piece) in pieces.enumerated() {
            #expect(piece.duration <= 4 * 365 * 86_400)
            if index > 0 { #expect(piece.start == pieces[index - 1].end) }
        }
        #expect(CalendarFlightLook.chunks(of: watch).count == 1)
    }

    /// The reader asks for each piece, stops at the event cap, and hands only first-pass titles to the parser.
    @Test func readerAsksPieceByPiece() {
        let calendar = FakeCalendar(events: Self.calendarEvents)
        let look = CalendarFlightReader.look(calendar, window: CalendarFlightLook.firstLookWindow(now: Self.now),
                                             airports: Self.airports, salt: Self.salt, now: Self.now)
        #expect(calendar.windows.count == 3)
        #expect(look.flown.count == 2 && look.upcoming.count == 2)
    }

    /// Already in the passport: a Flighty flight and one Fernlet saw are counted apart, and the plan keeps the
    /// event hashes Undo needs.
    @Test func planCountsWhatsHeld() throws {
        let look = Self.look()
        var book = PassportBook()
        let pdxHnl = try #require(look.flown.first), pdxLhr = try #require(look.flown.last)
        book.addFlights([
            try #require(PassportFlight(from: "PDX", to: "HNL", departure: pdxHnl.departure.addingTimeInterval(3_600), sources: .flighty)),
            try #require(PassportFlight(from: "PDX", to: "LHR", departure: pdxLhr.departure, sources: .fernlet)),
        ])
        let held = look.alreadyHeld(in: book)
        #expect(held.fromFlighty == 1 && held.fernletSaw == 1)
        let plan = look.plan(against: book)
        #expect(plan.source == .calendar && plan.flights.count == 2)
        #expect(plan.alreadySeen == 1 && plan.alreadyImported == 1 && plan.newFlights == 0)
        #expect(plan.undoFlights.count == 2)
        #expect(plan.flights.allSatisfy { $0.eventHash != nil })
    }

    // MARK: The passport

    /// Deleting what's kept takes every airport and flight, flown or upcoming, and nothing else.
    @Test func forgetAirportsAndFlights() throws {
        var book = PassportBook()
        _ = book.recordAirport(token: "PDX", at: Self.now, by: .landing)
        book.addFlights(Self.look().flown)
        book.setUpcomingFlights(Self.look().upcoming)
        #expect(book.holdsAirportsOrFlights)
        #expect(book.forgetAirportsAndFlights() == 5)
        #expect(!book.holdsAirportsOrFlights && book.flights.isEmpty && book.upcomingFlights.isEmpty)
        #expect(book.trips(atAirport: "PDX").isEmpty)
    }

    /// Today's calendar flight at an airport: later today at that airport only.
    @Test func todaysFlight() throws {
        var book = PassportBook()
        book.setUpcomingFlights(Self.look().upcoming)
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let morning = flightUTC("2026-11-14T15:00:00Z")
        let today = try #require(book.calendarFlightToday(from: "PDX", now: morning, in: pacific))
        #expect(today.destination == "HNL" && today.departure == flightUTC("2026-11-14T17:05:00Z"))
        #expect(book.calendarFlightToday(from: "HNL", now: morning, in: pacific) == nil)
        #expect(book.calendarFlightToday(from: "PDX", now: flightUTC("2026-11-13T15:00:00Z"), in: pacific) == nil)
        #expect(book.calendarFlightToday(from: "PDX", now: flightUTC("2026-11-14T18:00:00Z"), in: pacific) == nil)
    }

    // MARK: The salt

    /// Minted once into the map's vault (never UserDefaults), the same after; a damaged file gets a new one.
    @Test func saltLivesInTheVault() throws {
        let vault = WorldMapVault.ephemeral()
        let first = try CalendarFlightSalt.key(in: vault)
        let again = try CalendarFlightSalt.key(in: vault)
        #expect(first == again)
        #expect(try vault.read(CalendarFlightSalt.file)?.count == CalendarFlightSalt.length)
        try vault.write(Data(repeating: 1, count: 3), to: CalendarFlightSalt.file)
        #expect(try CalendarFlightSalt.key(in: vault) != first)
    }

    // MARK: The switches

    /// Both switches persist under the wipe's keys and default as approved (Airports and flights on, Calendar
    /// off); turning Airports and flights off turns Calendar off; the wipe clears both.
    @Test func switchesPersist() throws {
        let defaults = try Self.defaults()
        let store = makeTestStore()
        #expect(store.keepsWorldAirportsAndFlights(defaults: defaults))
        #expect(!WorldMapPreferences.readsCalendarFlights(in: defaults))
        WorldMapPreferences.setReadsCalendarFlights(true, in: defaults)
        #expect(store.mayReadWorldCalendar(defaults: defaults))
        store.setWorldAirportsAndFlights(false, defaults: defaults)
        #expect(!store.keepsWorldAirportsAndFlights(defaults: defaults))
        #expect(!WorldMapPreferences.readsCalendarFlights(in: defaults) && !store.mayReadWorldCalendar(defaults: defaults))
        WorldMapPreferences.clearAll(in: defaults)
        #expect(defaults.object(forKey: WorldMapPreferences.Key.airportsAndFlights) == nil)
        #expect(defaults.object(forKey: WorldMapPreferences.Key.flightsFromCalendar) == nil)
    }

    /// With Airports and flights off, the gate's airports, landings and layovers are taken and dropped.
    @Test func switchOffRecordsNothing() throws {
        let defaults = try Self.defaults()
        let store = makeTestStore()
        store.setWorldAirportsAndFlights(false, defaults: defaults)
        let taken = store.recordWorldFlightEvents([.airportFound(token: "PDX", how: .landing, at: Self.now)], defaults: defaults)
        #expect(taken)
        #expect(store.worldFog.atlas.book.count(of: .airport) == 0)
    }

    // MARK: The first look (screen 28)

    /// A flow over a test store and `calendar`.
    private static func flow(_ store: FernletStore, _ calendar: FakeCalendar, _ defaults: UserDefaults) -> CalendarFlightsFlow {
        CalendarFlightsFlow(atlas: store.worldFog.atlas, makeLooker: { looker(store, calendar, defaults) },
                            currentAccess: { calendar.access() }, isDecoy: { store.duressSessionActive }, defaults: defaults)
    }

    private static func looker(_ store: FernletStore, _ calendar: FakeCalendar, _ defaults: UserDefaults) -> CalendarFlightLooker {
        var looker = store.worldCalendarLooker(source: calendar, defaults: defaults)
        looker = CalendarFlightLooker(source: calendar, atlas: looker.atlas, airports: { Self.airports }, salt: looker.salt,
                                      mayRead: looker.mayRead, deviceTimeZone: TimeZone(identifier: "America/Los_Angeles") ?? .gmt)
        return looker
    }

    /// Allowed: the switch is on, the upcoming flights are kept at once, the summary has the screen's numbers, and
    /// "Add" adds the flown ones from the calendar with their hashes; Undo takes them back.
    @Test func firstLookAddsAndUndoes() async throws {
        let defaults = try Self.defaults(), store = makeTestStore()
        store.worldFog.load()
        let calendar = FakeCalendar(access: .notAsked, events: Self.calendarEvents)
        let flow = Self.flow(store, calendar, defaults)
        await flow.turnOn(now: Self.now)
        #expect(flow.isOn && WorldMapPreferences.readsCalendarFlights(in: defaults))
        let found = try #require(flow.found)
        #expect(found.look.flown.count == 2 && found.plan.flights.count == 2)
        #expect(store.worldFog.atlas.book.upcomingFlights.count == 2)
        #expect(store.worldFog.atlas.book.flights.isEmpty)
        let content = found.content
        #expect(content.count == 2 && content.tiles.map(\.value) == ["2", "3", "2", "2019–26"])
        #expect(content.anchor == "screen.calendarFlights" && !content.showsReadsLink)
        flow.confirm()
        let flights = store.worldFog.atlas.book.flights
        #expect(flights.count == 2 && flights.allSatisfy { $0.sources == .calendar && $0.eventHash != nil })
        #expect(flow.added?.count == 2)
        flow.undo()
        #expect(store.worldFog.atlas.book.flights.isEmpty)
    }

    /// Don't Allow: the switch goes back off with the note, nothing is read, and nothing is kept.
    @Test func dontAllowTurnsItBackOff() async throws {
        let defaults = try Self.defaults(), store = makeTestStore()
        let calendar = FakeCalendar(access: .notAsked, answer: .refused, events: Self.calendarEvents)
        let flow = Self.flow(store, calendar, defaults)
        await flow.turnOn(now: Self.now)
        #expect(!flow.isOn && flow.isRefused && !WorldMapPreferences.readsCalendarFlights(in: defaults))
        #expect(calendar.windows.isEmpty && flow.found == nil)
    }

    /// A decoy never asks iOS, never reads and shows nothing; nor does Airports and flights off.
    @Test func decoyAndSwitchOffNeverRead() async throws {
        let defaults = try Self.defaults(), store = makeTestStore()
        let calendar = FakeCalendar(events: Self.calendarEvents)
        store.duressSessionActive = true
        await Self.flow(store, calendar, defaults).turnOn(now: Self.now)
        store.duressSessionActive = false
        store.setWorldAirportsAndFlights(false, defaults: defaults)
        await Self.flow(store, calendar, defaults).turnOn(now: Self.now)
        #expect(calendar.requests == 0 && calendar.windows.isEmpty)
        #expect(store.worldCalendarFlightToday(atAirport: "PDX", now: Self.now, defaults: defaults) == nil)
    }

    // MARK: Keep watching (screen 30)

    /// Each open reads 2 days ago to 60 days ahead: a passed upcoming flight joins the Flights page, the window's
    /// upcoming flights replace the old ones, and access taken away turns the switch off with flights kept.
    @Test func keepWatching() async throws {
        let defaults = try Self.defaults(), store = makeTestStore()
        store.worldFog.load()
        WorldMapPreferences.setReadsCalendarFlights(true, in: defaults)
        let calendar = FakeCalendar(events: Self.calendarEvents)
        let watcher = CalendarFlightWatcher(mayRead: { store.mayReadWorldCalendar(defaults: defaults) },
                                            makeLooker: { Self.looker(store, calendar, defaults) }, defaults: defaults)
        watcher.look(now: Self.now)
        await watcher.settle()
        #expect(calendar.windows.first == CalendarFlightLook.watchWindow(now: Self.now))
        #expect(store.worldFog.atlas.book.upcomingFlights.map(\.route) == ["PDX>HNL", "HNL>PDX"])
        let later = flightUTC("2026-11-15T18:00:00Z")
        watcher.look(now: later)
        await watcher.settle()
        #expect(store.worldFog.atlas.book.flights.map(\.route) == ["PDX>HNL"])
        #expect(store.worldFog.atlas.book.upcomingFlights.map(\.route) == ["HNL>PDX"])
        calendar.revoke()
        watcher.look(now: later)
        await watcher.settle()
        #expect(!WorldMapPreferences.readsCalendarFlights(in: defaults))
        #expect(store.worldFog.atlas.book.flights.count == 1)
    }

    // MARK: Walls

    /// EventKit is imported in one file only, the read-only source.
    @Test func eventKitIsConfinedToItsSource() throws {
        let importers = try MapAndLocationConfinementBoundaryTests.files(importingAnyOf: ["EventKit", "EventKitUI"])
        #expect(importers == ["App/Fernlet/World/Flights/CalendarEventKitSource.swift"])
    }
}
