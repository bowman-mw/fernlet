import CryptoKit
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Airports and flights in the passport (World-Airports-Spec §3, §4.2, §8–§11): an airport found once, stamped
/// once a trip under the 7-day rule (the home airport each time the person flies home), a layover's stamp marked
/// transit, every flight kept once across Fernlet, Flighty and the calendar with the richer record's times, and
/// both the sealed file and the sealed backup carrying a newer Fernlet's data through this build untouched.
///
/// Made-up data only: the sample traveller lives in Portland (PDX); every date is invented.
@MainActor
struct PassportAirportsTests {
    nonisolated static let day: TimeInterval = 86_400
    nonisolated static let hour: TimeInterval = 3_600
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    /// The date `days` after ``t0``.
    nonisolated static func at(_ days: Double) -> Date {
        t0.addingTimeInterval(days * day)
    }

    nonisolated static let us = AtlasVisit(countryCode: "US", continent: .northAmerica, terrain: .temperateForest)
    nonisolated static let finland = AtlasVisit(countryCode: "FI", continent: .europe, terrain: .borealForest)

    /// A flight, or a failed expectation.
    nonisolated static func flight(_ from: String, _ to: String, _ departure: Date, arrives: Date? = nil,
                                   _ sources: PassportFlight.Sources, unsure: Bool = false,
                                   hash: String? = nil) -> PassportFlight {
        guard let flight = PassportFlight(from: from, to: to, departure: departure, arrival: arrives, sources: sources,
                                          timesUnsure: unsure, eventHash: hash) else {
            Issue.record("a test flight broke the rules")
            return PassportFlight(from: "PDX", to: "SFO", departure: t0, sources: .fernlet)!
        }
        return flight
    }

    /// A made-up calendar event hash.
    nonisolated static let hash = String(repeating: "ab12", count: 16)

    /// A passport that flew from home to Helsinki and back: PDX found by a ticket, a landing in Helsinki that
    /// was a layover, a landing at the London end, and home again ten days later.
    static func traveller() -> PassportBook {
        var book = PassportBook()
        _ = book.record(us, at: t0)
        _ = book.recordAirport(token: "PDX", at: t0, by: .ticket)
        _ = book.recordAirport(token: "HEL", at: at(0.5), by: .landing)
        _ = book.setTransit(true, atAirport: "HEL", trip: at(0.5))
        _ = book.recordAirport(token: "LHR", at: at(0.6), by: .landing)
        _ = book.recordAirport(token: "LHR", at: at(10), by: .ticket)
        _ = book.recordAirport(token: "PDX", at: at(10.5), by: .landing)
        _ = book.record(us, at: at(10.5))
        book.addFlights([flight("PDX", "HEL", t0.addingTimeInterval(2 * hour), arrives: at(0.5), .fernlet),
                         flight("HEL", "LHR", at(0.55), arrives: at(0.6), .fernlet),
                         flight("LHR", "PDX", at(10), arrives: at(10.5), [.fernlet, .calendar], hash: hash)])
        book.setUpcomingFlights([flight("PDX", "MEX", at(40), arrives: at(40.2), .calendar, hash: hash)])
        return book
    }

    /// The JSON object `data` holds.
    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Finding an airport

    /// Any find finds a new airport once; after that, just being there (a dwell) adds nothing at all.
    @Test func anAirportIsFoundOnceAndBeingThereAddsNothing() {
        var book = PassportBook()
        let found = book.recordAirport(token: "PDX", at: Self.t0, by: .dwell)
        #expect(found == .firstVisit(AtlasDiscovery(kind: .airport, token: "PDX", at: Self.t0)))
        #expect(book.recordAirport(token: "PDX", at: Self.at(30), by: .dwell) == nil, "working there fills nothing")
        #expect(book.trips(atAirport: "PDX") == [Self.t0] && book.lastSeen(atAirport: "PDX") == Self.t0)
        #expect(book.discoveries(of: .airport) == 1)
        #expect(book.discoveries.contains(AtlasDiscovery(kind: .airport, token: "PDX", at: Self.t0)))
        #expect(book.recordAirport(token: "P DX", at: Self.t0, by: .landing) == nil, "not a token")
        #expect(book.recordAirport(token: String(repeating: "A", count: 17), at: Self.t0, by: .landing) == nil)
        #expect(book.recordAirport(token: "SEA", at: Date(timeIntervalSince1970: .nan), by: .landing) == nil)
        #expect(PassportBook.cap(for: .airport) == 10_000)
        #expect(AtlasDiscoveryKind.airport.rawValue == "airport", "frozen")
    }

    /// The home airport gets a stamp each time the person flies home after 7 days or more; leaving from an
    /// airport (a ticket) is never a trip to it, and a short trip home is the same trip.
    @Test func theHomeAirportIsStampedEachTimeYouFlyHome() {
        var book = PassportBook()
        _ = book.recordAirport(token: "PDX", at: Self.t0, by: .ticket)
        #expect(book.recordAirport(token: "PDX", at: Self.at(5), by: .landing) == nil, "five days away")
        #expect(book.recordAirport(token: "PDX", at: Self.at(20), by: .ticket) == nil, "a ticket out is no trip")
        #expect(book.lastSeen(atAirport: "PDX") == Self.at(20), "but it moves the clock")
        #expect(book.recordAirport(token: "PDX", at: Self.at(26), by: .landing) == nil, "six days after the ticket")
        let home = book.recordAirport(token: "PDX", at: Self.at(40), by: .landing)
        #expect(home == .newTrip(PassportStamp(kind: .airport, token: "PDX", date: Self.at(40), trip: 2)))
        #expect(book.trips(atAirport: "PDX") == [Self.t0, Self.at(40)] && book.airportReturnCount == 1)
        #expect(book.recordAirport(token: "PDX", at: Self.at(30), by: .landing) == nil, "the clock never goes back")
        #expect(book.lastSeen(atAirport: "PDX") == Self.at(40))
        #expect(book.returnCount == 0, "an airport's trips are never a country's")
    }

    /// A landing's airport stamp comes before the country's on the same moment; a stamp each trip, airports and
    /// countries mixed by date.
    @Test func aLandingStampsTheAirportBeforeTheCountry() {
        var book = PassportBook()
        _ = book.recordAirport(token: "HEL", at: Self.t0, by: .landing)
        _ = book.record(Self.finland, at: Self.t0)
        let stamps = book.stamps
        #expect(stamps.map(\.kind) == [.airport, .country, .continent])
        #expect(stamps.first == PassportStamp(kind: .airport, token: "HEL", date: Self.t0))
        #expect(PassportStamp.Kind.allCases.first == .airport)
        let traveller = Self.traveller()
        #expect(traveller.stamps.filter { $0.kind == .airport }.map(\.token) == ["PDX", "HEL", "LHR", "PDX"])
        #expect(traveller.stamps.filter { $0.token == "PDX" }.map(\.trip) == [1, 2])
        #expect(traveller.stamps.map(\.date) == traveller.stamps.map(\.date).sorted())
    }

    /// A layover's trip is marked transit and its stamp says so; a mark needs a trip the book holds, and clears.
    @Test func aLayoverIsATransitStamp() {
        var book = Self.traveller()
        #expect(book.isTransit(atAirport: "HEL", trip: Self.at(0.5)) && book.transitCount == 1)
        #expect(book.stamps.first { $0.token == "HEL" }?.isTransit == true)
        #expect(book.stamps.filter { $0.token != "HEL" }.allSatisfy { !$0.isTransit })
        #expect(!book.setTransit(true, atAirport: "HEL", trip: Self.at(0.5)), "already marked")
        #expect(!book.setTransit(true, atAirport: "HEL", trip: Self.at(3)), "no trip began then")
        #expect(!book.setTransit(true, atAirport: "SEA", trip: Self.t0), "never found")
        #expect(book.setTransit(false, atAirport: "HEL", trip: Self.at(0.5)), "they left the airport after all")
        #expect(book.transitCount == 0 && book.transitVisits.isEmpty)
    }

    // MARK: Across builds

    /// Airport trips live in their own keys: `returns` and `lastSeen` hold only countries, so a build from before
    /// airports (which refuses any token there that isn't a country, and would then remove the whole passport)
    /// still reads the book.
    @Test func airportTripsNeverReachTheCountryKeys() throws {
        let book = Self.traveller()
        let data = try book.encoded()
        let json = try Self.object(data)
        let countries = Set((json["country"] as? [String: Any] ?? [:]).keys)
        #expect(countries == ["US"])
        let returns = json["returns"] as? [String: Any] ?? [:], seen = json["lastSeen"] as? [String: Any] ?? [:]
        #expect(Set(returns.keys).isSubset(of: countries) && Set(seen.keys).isSubset(of: countries),
                "an older build's rule: every token in returns and lastSeen is a country")
        #expect(Set((json["airport"] as? [String: Any] ?? [:]).keys) == ["PDX", "HEL", "LHR"])
        #expect(Set((json["airportReturns"] as? [String: Any] ?? [:]).keys) == ["PDX"])
        #expect(Set((json["airportLastSeen"] as? [String: Any] ?? [:]).keys) == ["PDX", "HEL", "LHR"])
        #expect(Set((json["airportTransit"] as? [String: Any] ?? [:]).keys) == ["HEL"])
        #expect(try PassportBook(data: data) == book)
        var old = json
        for key in ["airport", "airportReturns", "airportLastSeen", "airportTransit", "flights", "upcomingFlights"] {
            old[key] = nil
        }
        let olderView = try PassportBook(data: JSONSerialization.data(withJSONObject: old))
        #expect(olderView.trips(inCountry: "US") == book.trips(inCountry: "US"), "the countries read the same")
        let plain = try Self.object(PassportBook().encoded())
        #expect(Set(plain.keys) == ["version"], "a book with no airports or flights writes no new keys")
    }

    /// Airport keys that break the rules are refused like a country's.
    @Test func airportKeysAreChecked() throws {
        func book(_ object: [String: Any]) throws -> PassportBook {
            try PassportBook(data: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: PassportBook.BookError.badToken(.airport)) {
            try book(["version": 1, "airportReturns": ["PDX": [1_792_800_000.0]]])
        }
        #expect(throws: PassportBook.BookError.badToken(.airport)) {
            try book(["version": 1, "airport": ["PDX": 1_792_800_000.0], "airportTransit": ["SEA": [1_792_800_000.0]]])
        }
        #expect(throws: PassportBook.BookError.badToken(.airport)) {
            try book(["version": 1, "airport": ["ABCDEFGHIJKLMNOPQ": 1_792_800_000.0]])
        }
        let stray = try book(["version": 1, "airport": ["PDX": 1_792_800_000.0],
                              "airportTransit": ["PDX": [1_792_900_000.0]]])
        #expect(stray.transitCount == 0, "a layover whose trip doesn't stand is left out")
    }

    /// A key this build does not know is kept as it was read and written back; equality counts it, and a value
    /// nested too deep is left out on its own.
    @Test func aNewerBooksKeysAreKeptVerbatim() throws {
        let future: [String: Any] = ["list": [1, 2.5, "three", NSNull(), true, ["nested": ["deep": [false]]]],
                                     "note": "kept"]
        var deep: Any = 1
        for _ in 0..<30 { deep = [deep] }
        let object: [String: Any] = ["version": 1, "country": ["US": 1_792_800_000.0], "lake": ["Q1": 1_792_800_000.0],
                                     "future": future, "tooDeep": deep]
        let data = try JSONSerialization.data(withJSONObject: object)
        let book = try PassportBook(data: data)
        #expect(book.trips(inCountry: "US") == [Self.t0])
        let written = try Self.object(book.encoded())
        #expect((written["lake"] as? NSDictionary) == (object["lake"] as? NSDictionary))
        #expect((written["future"] as? NSDictionary) == (future as NSDictionary), "kept verbatim")
        #expect(written["tooDeep"] == nil, "nested too deep: left out, the rest kept")
        #expect(try PassportBook(data: book.encoded()) == book, "and again")
        let without = try PassportBook(data: JSONSerialization.data(withJSONObject: ["version": 1, "country": ["US": 1_792_800_000.0]]))
        #expect(without != book, "equality counts a newer Fernlet's keys")
        var merged = without
        _ = merged.merge(book)
        #expect(merged == book, "a merge brings the keys it doesn't have")
    }

    // MARK: Flights

    /// One flight once across sources (spec §9.3): the same airports with departures within 3 hours are one
    /// flight with every source; 3 hours and a minute apart, or another route, are two.
    @Test func oneFlightOnceAcrossSources() {
        var book = PassportBook()
        let seen = Self.flight("PDX", "SFO", Self.t0, arrives: Self.t0.addingTimeInterval(2 * Self.hour), .fernlet)
        #expect(book.addFlights([seen]) == 1)
        let imported = Self.flight("PDX", "SFO", Self.t0.addingTimeInterval(3 * Self.hour), .flighty)
        #expect(book.addFlights([imported]) == 1, "merged")
        #expect(book.flights.count == 1 && book.flights.first?.sources == [.fernlet, .flighty])
        #expect(book.flights.first?.arrival == seen.arrival, "Fernlet's times stay")
        #expect(book.addFlights([imported]) == 0, "the same record twice changes nothing")
        let later = Self.flight("PDX", "SFO", Self.t0.addingTimeInterval(3 * Self.hour + 60), .flighty)
        let back = Self.flight("SFO", "PDX", Self.t0.addingTimeInterval(Self.hour), .flighty)
        #expect(book.addFlights([later, back]) == 2)
        #expect(book.flights.count == 3)
        #expect(book.flight(matching: imported)?.sources == [.fernlet, .flighty])
        #expect(book.discoveries.isEmpty && book.stamps.isEmpty, "flights stamp nothing (spec §9.5)")
    }

    /// The richer record wins: a known arrival over none, sure times over unsure, Fernlet's over imported.
    @Test func theRicherRecordWins() {
        let bare = Self.flight("PDX", "HNL", Self.t0, .flighty)
        let timed = Self.flight("PDX", "HNL", Self.t0.addingTimeInterval(600), arrives: Self.at(0.25), .calendar,
                                unsure: true, hash: Self.hash)
        let sure = Self.flight("PDX", "HNL", Self.t0.addingTimeInterval(-600), arrives: Self.at(0.26), .flighty)
        let fernlet = Self.flight("PDX", "HNL", Self.t0.addingTimeInterval(300), arrives: Self.at(0.27), .fernlet)
        var book = PassportBook()
        book.addFlights([bare])
        book.addFlights([timed])
        #expect(book.flights.first?.arrival == Self.at(0.25), "a known arrival over none")
        #expect(book.flights.first?.eventHash == Self.hash)
        book.addFlights([sure])
        #expect(book.flights.first?.arrival == Self.at(0.26) && book.flights.first?.timesUnsure == false,
                "sure times over unsure")
        book.addFlights([fernlet])
        #expect(book.flights.first?.departure == fernlet.departure, "Fernlet's own times over imported")
        #expect(book.flights.first?.sources == [.fernlet, .flighty, .calendar] && book.flights.count == 1)
        #expect(book.flights.first?.eventHash == Self.hash, "the calendar's hash stays while the calendar does")
        #expect(!bare.isRicher(than: bare), "equal is not richer")
    }

    /// "Remove imported flights" removes a flight only imports had, and keeps one Fernlet also saw.
    @Test func removingImportedFlightsKeepsWhatFernletSaw() {
        var book = Self.traveller()
        book.addFlights([Self.flight("PDX", "SFO", Self.at(60), .flighty)])
        #expect(book.flights.count == 4 && book.upcomingFlights.count == 1)
        #expect(book.removeSource(.imported) == 2, "the Flighty flight and the upcoming calendar one")
        #expect(book.flights.count == 3 && book.upcomingFlights.isEmpty)
        let home = book.flights.first { $0.route == "LHR>PDX" }
        #expect(home?.sources == .fernlet && home?.eventHash == nil, "the hash goes with the calendar")
        #expect(book.removeSource(.calendar) == 0)
    }

    /// Upcoming flights are kept for their day and join the flights once flown, once (spec §10.6).
    @Test func upcomingFlightsJoinOnceTheyveFlown() {
        var book = PassportBook()
        let honolulu = Self.flight("PDX", "HNL", Self.at(1), arrives: Self.at(1.25), .calendar, hash: Self.hash)
        let mexico = Self.flight("PDX", "MEX", Self.at(10), .calendar)
        #expect(book.setUpcomingFlights([mexico, honolulu, honolulu]))
        #expect(book.upcomingFlights == [honolulu, mexico], "one flight once, earliest first")
        #expect(!book.setUpcomingFlights([honolulu, mexico]), "the same list changes nothing")
        book.addFlights([Self.flight("PDX", "HNL", Self.at(1).addingTimeInterval(1_200), arrives: Self.at(1.26), .fernlet)])
        #expect(book.promoteUpcomingFlights(asOf: Self.at(0.5)) == 0)
        #expect(book.promoteUpcomingFlights(asOf: Self.at(2)) == 1)
        #expect(book.flights.count == 1 && book.flights.first?.sources == [.fernlet, .calendar], "Fernlet saw it")
        #expect(book.upcomingFlights == [mexico])
        let many = (0...PassportBook.maxUpcomingFlights).map { Self.flight("PDX", "SFO", Self.at(Double($0)), .calendar) }
        var full = PassportBook()
        full.setUpcomingFlights(many)
        #expect(full.upcomingFlights.count == PassportBook.maxUpcomingFlights && full.refusedCount == 1)
    }

    /// A flight keeps its fields and nothing else, under frozen short keys, and one that breaks a rule is never
    /// made or read.
    @Test func aFlightKeepsOnlyItsFields() throws {
        let full = Self.flight("PDX", "MEX", Self.t0, arrives: Self.at(0.2), .calendar, unsure: true, hash: Self.hash)
        let json = try Self.object(JSONEncoder().encode(full))
        #expect(Set(json.keys) == ["f", "t", "d", "a", "s", "u", "h"], "FROZEN keys")
        #expect(json["d"] as? Double == 1_792_800_000 && json["s"] as? Int == 4)
        let plain = try Self.object(JSONEncoder().encode(Self.flight("PDX", "MEX", Self.t0, .fernlet)))
        #expect(Set(plain.keys) == ["f", "t", "d", "s"])
        #expect(try JSONDecoder().decode(PassportFlight.self, from: JSONEncoder().encode(full)) == full)
        #expect(PassportFlight(from: "pdx", to: "MEX", departure: Self.t0, sources: .fernlet) == nil)
        #expect(PassportFlight(from: "PDX", to: "PDX", departure: Self.t0, sources: .fernlet) == nil)
        #expect(PassportFlight(from: "PDX", to: "MEXI", departure: Self.t0, sources: .fernlet) == nil)
        #expect(PassportFlight(from: "PDX", to: "MEX", departure: Self.t0, sources: []) == nil)
        #expect(PassportFlight(from: "PDX", to: "MEX", departure: Self.t0, arrival: Self.at(-0.1), sources: .fernlet) == nil)
        #expect(PassportFlight(from: "PDX", to: "MEX", departure: Self.t0, arrival: Self.at(3), sources: .fernlet) == nil)
        #expect(PassportFlight(from: "PDX", to: "MEX", departure: Self.t0, sources: .flighty, eventHash: Self.hash) == nil,
                "a hash only on a calendar flight")
        #expect(PassportFlight(from: "PDX", to: "MEX", departure: Self.t0, sources: .calendar,
                               eventHash: Self.hash.uppercased()) == nil)
        #expect(throws: PassportBook.BookError.badFlight) {
            try PassportBook(data: JSONSerialization.data(withJSONObject: [
                "version": 1, "flights": [["f": "PDX", "t": "PDX", "d": 1_792_800_000.0, "s": 1]]
            ]))
        }
    }

    /// Flights and upcoming flights round-trip in the bytes and merge one flight once.
    @Test func flightsRoundTripAndMerge() throws {
        let book = Self.traveller()
        #expect(try PassportBook(data: book.encoded()) == book)
        var other = PassportBook()
        other.addFlights([Self.flight("PDX", "HEL", Self.t0.addingTimeInterval(Self.hour), .flighty),
                          Self.flight("PDX", "SFO", Self.at(90), .flighty)])
        var merged = book
        #expect(merged.merge(other) == 2, "one flight merged, one added")
        #expect(merged.flights.count == 4)
        #expect(merged.flights.first { $0.route == "PDX>HEL" }?.sources == [.fernlet, .flighty])
        #expect(merged.merge(other) == 0, "merging twice adds nothing")
    }

    // MARK: The sealed backup

    /// An adapter over `book` that merges nothing.
    static func adapter(_ book: PassportBook) -> PassportBackupAdapter {
        PassportBackupAdapter(isOpen: { true }, passport: { book }, mergePassport: { _ in 0 })
    }

    /// Every record the adapter exports for `book`, through JSON.
    static func exported(_ book: PassportBook) throws -> [PassportBackupRecord] {
        let adapter = Self.adapter(book)
        let ids = try adapter.snapshotIDs()
        let page = try adapter.classifiedChunk(ids, hubKey: SymmetricKey(size: .bits256))
        #expect(page.records.count == ids.count)
        return try JSONDecoder().decode([PassportBackupRecord].self, from: JSONEncoder().encode(page.records))
    }

    /// The backup carries airports a record per trip, layovers, flights and upcoming flights, in the frozen record
    /// shape with only optional keys added, and reads back the same book.
    @Test func theBackupCarriesAirportsFlightsAndLayovers() throws {
        let book = Self.traveller()
        let records = try Self.exported(book)
        #expect(records.filter { $0.kind == "airport" && $0.token == "PDX" }.count == 2, "a record per trip")
        #expect(records.filter { $0.kind == "airportTransit" }.map(\.token) == ["HEL"])
        #expect(records.filter { $0.kind == "flight" }.count == 3 && records.filter { $0.kind == "upcomingFlight" }.count == 1)
        #expect(try PassportBackupAdapter.book(of: records) == book)
        let home = try #require(records.first { $0.kind == "flight" && $0.token == "LHR>PDX" })
        let homeKeys = Set(try Self.object(JSONEncoder().encode(home)).keys)
        #expect(homeKeys == ["id", "kind", "token", "first", "last", "src", "eh"])
        let transit = try #require(records.first { $0.kind == "airportTransit" })
        #expect(Set(try Self.object(JSONEncoder().encode(transit)).keys) == ["id", "kind", "token", "first"])
        let latest = try #require(records.first { $0.kind == "airport" && $0.token == "PDX" && $0.date == Self.at(10.5) })
        #expect(latest.lastSeen == Self.at(10.5), "the latest trip carries the airport's clock")
        let unsure = PassportBackupRecord(id: UUID(), flight: Self.flight("PDX", "MEX", Self.t0, .calendar, unsure: true),
                                          upcoming: false)
        #expect(unsure.flags == 1 && unsure.flight?.timesUnsure == true)
    }

    /// A record of a kind this build does not know is skipped on restore and kept, and every later export carries
    /// it again with every key it had; a bad token or flight of a kind this build knows still refuses the set.
    @Test func aRecordOfAnUnknownKindIsSkippedAndKept() throws {
        let newer = Data(#"""
        [{"id":"\#(UUID().uuidString)","kind":"country","token":"US","first":1792800000},
         {"id":"\#(UUID().uuidString)","kind":"galaxy","token":"milkyWay","first":1792800000,"last":1792900000,
          "arms":[4,{"bar":true}],"src":9}]
        """#.utf8)
        let records = try JSONDecoder().decode([PassportBackupRecord].self, from: newer)
        let restored = try PassportBackupAdapter.book(of: records)
        #expect(restored.trips(inCountry: "US") == [Self.t0])
        #expect(restored.keptBackupRecords.count == 1, "skipped, and kept")
        let again = try Self.exported(restored)
        let galaxy = try #require(again.first { $0.kind == "galaxy" })
        #expect(galaxy.token == "milkyWay" && galaxy.lastSeen == Date(timeIntervalSince1970: 1_792_900_000))
        #expect(galaxy.sources == 9 && galaxy.extra["arms"] == .array([.integer(4), .object(["bar": .bool(true)])]))
        #expect(galaxy.id != records[1].id, "a fresh id in every set")
        #expect(try PassportBackupAdapter.book(of: again) == restored, "a round trip through this build keeps it")
        var phone = PassportBook()
        #expect(phone.merge(restored) == 2, "the country, and the kept record")
        #expect(phone.merge(restored) == 0)
        #expect(throws: SealedBackupV2FormatError.unreadableRecords) {
            try PassportBackupAdapter.book(of: [PassportBackupRecord(id: UUID(), kind: "country", token: "U S", date: Self.t0)])
        }
        #expect(throws: SealedBackupV2FormatError.unreadableRecords) {
            try PassportBackupAdapter.book(of: [PassportBackupRecord(id: UUID(), kind: "flight", token: "PDX>PDX",
                                                                     date: Self.t0, sources: 1)])
        }
        let crowded = Data(("[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"galaxy\",\"token\":\"x\",\"first\":1"
            + (0...PassportBackupRecord.maxExtraKeys).map { ",\"k\($0)\":0" }.joined() + "}]").utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([PassportBackupRecord].self, from: crowded) }
    }

    /// The store saves an airport find and a flight at once, and a relaunch reads them back.
    @Test func theStoreSavesAirportsAndFlights() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = PassportStore(vault: vault)
        try store.load()
        #expect(try store.recordAirport(token: "PDX", at: Self.t0, by: .ticket)?.discovery?.token == "PDX")
        #expect(try store.recordAirport(token: "PDX", at: Self.at(1), by: .dwell) == nil)
        try store.update { $0.addFlights([Self.flight("PDX", "SFO", Self.t0, .fernlet)]) }
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(reopened.book == store.book && reopened.book.flights.count == 1)
    }
}
