import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Airport stamps in Sprout's passport (World-Airports-Spec §4): the ticket's ink, tilt and wear seeded per code
/// the mockup's way, the famous airports' own art, the store's stamps mapped with their layovers, airports mixed
/// in by date, the index's Airports and Flights rows with every trip's page, the new-stamp hook, the banner's
/// "found on the ground" line, and Your world's haloed tower. Every airport trip here is the made-up Portland
/// traveller's.
@MainActor
struct PassportAirportStampsTests {
    nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    nonisolated static func day(_ month: Int, _ day: Int, hour: Int = 10, minute: Int = 0) -> Date {
        DateComponents(calendar: utc, year: 2026, month: month, day: day, hour: hour, minute: minute).date
            ?? .distantPast
    }

    // MARK: The ticket

    /// The ink is one of the four stamp inks by `seed("ap:" + code) mod 4`, the tilt −6…+6 from the same seed (a
    /// layover's from "ap:…t"), and both are the same every time (the values the mockup's `PP.seedOf` gives).
    @Test func inkAndTiltAreSeededPerCode() {
        #expect(PassportAirportStamp.ink(for: "PDX") == 0xB3343A)
        #expect(PassportAirportStamp.ink(for: "LHR") == 0x7B4BA8)
        #expect(PassportAirportStamp.ink(for: "HEL") == 0x2F6FA3)
        #expect(PassportAirportStamp.ink(for: "DEN") == 0x2E8B57)
        #expect(PassportAirportStamp.tilt("PDX", transit: false) == -1)
        #expect(PassportAirportStamp.tilt("LHR", transit: false) == 4)
        #expect(PassportAirportStamp.tilt("PDX", transit: true) == -6, "a layover's ticket lands at its own tilt")
        let nudge = PassportStampSeed.nudge(PassportAirportStamp.seedKey("PDX", transit: false))
        #expect(nudge.across == 7 && nudge.down == -5)
        for code in ["PDX", "LHR", "HEL", "CDG", "MEX", "NRT", "SFO", "YVR"] {
            #expect(PassportAirportStamp.inks.contains(PassportAirportStamp.ink(for: code)))
            #expect((-6 ... 6).contains(PassportAirportStamp.tilt(code, transit: false)))
            #expect(PassportAirportStamp.ink(for: code) == PassportAirportStamp.ink(for: code))
        }
        #expect(PassportStampKind.airport("HEL", transit: true).seedKey == "ap:HELt")
        #expect(PassportStampKind.airport("HEL", transit: false).shape == .ticket)
    }

    /// About 7 % of the art's pixels wear away, seeded by the code alone: the same code always loses the same
    /// pixels, another code others, and wear only ever removes ink.
    @Test func wearIsStablePerCode() {
        let jet = PassportAirportStamp.art(for: "LHR")
        let inked = jet.joined().filter { $0 }.count
        let worn = PassportAirportStamp.worn(jet, wearKey: "LHR")
        #expect(worn == PassportAirportStamp.worn(jet, wearKey: "LHR"))
        #expect(worn != PassportAirportStamp.worn(jet, wearKey: "SEA"))
        let kept = worn.joined().filter { $0 }.count
        #expect(inked == 40 && kept == 37, "Heathrow's jet loses 3 of its 40 pixels, every time")
        for (row, line) in worn.enumerated() {
            for (col, ink) in line.enumerated() where ink {
                #expect(jet[row][col], "wear never adds ink")
            }
        }
        let big = (0 ..< 40).map { _ in Array(repeating: true, count: 40) }
        let share = Double(PassportAirportStamp.worn(big, wearKey: "LHR").joined().filter { !$0 }.count) / 1_600
        #expect(share > 0.04 && share < 0.1)
    }

    /// The jet for every airport, the four approved pictures for Denver, LAX, Changi and JFK.
    @Test func famousAirportsGetTheirOwnPicture() {
        #expect(PassportAirportStamp.art(for: "PDX") == PassportStampArt.pixels(PassportAirportStamp.jetSide))
        #expect(PassportAirportStamp.jetSide.count == 7 && PassportAirportStamp.jetSide.allSatisfy { $0.count == 15 })
        for code in ["DEN", "LAX", "SIN", "JFK"] {
            #expect(PassportAirportStamp.hasOwnArt(code))
            let rows = PassportAirportStamp.famous[code] ?? []
            #expect(!rows.isEmpty && Set(rows.map(\.count)).count == 1, "\(code)'s rows are one width")
            #expect(PassportAirportStamp.art(for: code) != PassportAirportStamp.art(for: "PDX"))
        }
        #expect(!PassportAirportStamp.hasOwnArt("HEL"))
    }

    /// The city line in capitals, at 3.5 pt past 11 characters; the index's names without "International".
    @Test func theLetteringAndTheIndexNames() {
        #expect(PassportAirportStamp.cityLine("Portland", language: .english) == "PORTLAND")
        #expect(PassportAirportStamp.cityLine("Ciudad de México", language: .spanish) == "CIUDAD DE MÉXICO")
        #expect(PassportAirportStamp.citySize(for: "PORTLAND") == 4.2)
        #expect(PassportAirportStamp.citySize(for: "SAN FRANCISCO") == 3.5)
        #expect(PassportAirportStamp.citySize(for: "MEXICO CITY") == 4.2, "eleven letters still fit")
        #expect(PassportAirportStamp.shortName("Portland International", spanish: false) == "Portland")
        #expect(PassportAirportStamp.shortName("Helsinki Airport", spanish: false) == "Helsinki")
        #expect(PassportAirportStamp.shortName("Heathrow", spanish: false) == "Heathrow")
        #expect(PassportAirportStamp.shortName("Internacional de Portland", spanish: true) == "Portland")
        #expect(PassportAirportStamp.shortName("Aeropuerto de Helsinki", spanish: true) == "Helsinki")
        #expect(PassportAirportStamp.shortName("Airport", spanish: false) == "Airport", "never an empty name")
    }

    /// With no airport list a ticket still draws: its token as the code, no city, TRANSIT for a layover, seeded
    /// by "ap:" and worn by the token.
    @Test func theLibraryDrawsATicketWithoutTheList() {
        let library = PassportLibrary(openAtlas: { nil })
        let plain = library.airportDrawing("PDX", transit: false)
        #expect(plain.label == ["PDX"] && plain.key == "ap:PDX" && plain.wearKey == "PDX" && plain.ink == 0xB3343A)
        let transit = library.airportDrawing("HEL", transit: true)
        #expect(transit.label == ["HEL", String(localized: PassportAirportCopy.transit)] && transit.key == "ap:HELt")
        #expect(library.name(of: .airport("PDX", transit: false)) == "PDX")
        #expect(library.ink(of: .airport("HEL", transit: true)) == PassportAirportStamp.ink(for: "HEL"))
    }

    // MARK: Entries and pages

    /// The store's airport stamps map to page entries with their trip and layover; only an airport is ever transit;
    /// at the same moment an airport lands before the country.
    @Test func airportStampsMapAndMixInByDate() {
        let date = Self.day(10, 21)
        let stamp = PassportStamp(kind: .airport, token: "HEL", date: date, trip: 2, isTransit: true)
        let entry = PassportStampEntry(stamp: stamp)
        #expect(entry?.kind == .airport && entry?.trip == 2 && entry?.isTransit == true)
        #expect(entry?.stampKind == .airport("HEL", transit: true))
        #expect(!PassportStampEntry(kind: .country, token: "FI", date: date, isTransit: true).isTransit)
        let entries = [PassportStampEntry(kind: .country, token: "GB", date: Self.day(10, 3)),
                       PassportStampEntry(kind: .airport, token: "LHR", date: Self.day(10, 3)),
                       PassportStampEntry(kind: .ocean, token: "atlantic", date: Self.day(10, 5)),
                       PassportStampEntry(kind: .airport, token: "PDX", date: Self.day(8, 14))]
        let ordered = PassportStampEntry.ordered(entries, calendar: Self.utc)
        #expect(ordered.map(\.token) == ["PDX", "LHR", "GB", "atlantic"])
        var book = PassportBook()
        _ = book.recordAirport(token: "PDX", at: Self.day(8, 14), by: .dwell)
        _ = book.recordAirport(token: "PDX", at: Self.day(9, 28), by: .landing)
        #expect(PassportStampEntry.entries(of: book).map(\.trip) == [1, 2], "a ticket each trip home")
        #expect(PassportProgress(entries: PassportStampEntry.entries(of: book), table: .empty).airportCount == 1)
    }

    // MARK: The index

    /// The Airports row lists each found airport A to Z with every page its trips are on (the home airport a page
    /// per trip); the Flights row counts every flight, gives the Flights page and the layovers.
    @Test func theIndexListsAirportsAndFlights() throws {
        let fillers = (0 ..< 6).map { PassportStampEntry(kind: .sea, token: "Q\($0)", date: Self.day(9, 1 + $0)) }
        let entries = fillers + [
            PassportStampEntry(kind: .airport, token: "PDX", date: Self.day(8, 14)),
            PassportStampEntry(kind: .airport, token: "PDX", date: Self.day(9, 28), trip: 2),
            PassportStampEntry(kind: .airport, token: "HEL", date: Self.day(10, 21), isTransit: true),
            PassportStampEntry(kind: .airport, token: "LHR", date: Self.day(10, 3))
        ]
        let flights = [Self.flight("PDX", "LHR", Self.day(10, 2)), Self.flight("CDG", "HEL", Self.day(10, 21, hour: 9)),
                       Self.flight("HEL", "NRT", Self.day(10, 21, hour: 14))].compactMap { $0 }
        let flightsModel = PassportFlightsModel(flights: flights, point: { _ in nil }, calendar: Self.utc)
        let book = PassportBookModel(entries: entries, flightPageCount: flightsModel.pages.count, calendar: Self.utc)
        let names = ["PDX": "Portland", "HEL": "Helsinki", "LHR": "Heathrow"]
        let index = PassportIndexModel(book: book, table: .empty, language: .english, flights: flightsModel) { kind in
            if case .airport(let token, _) = kind { return names[token] ?? token }
            return ""
        }
        #expect(index.airports.map(\.name) == ["Heathrow", "Helsinki", "Portland"])
        #expect(index.airports.last?.pages == [3, 4], "Portland: a page per trip")
        let row = try #require(index.flights)
        #expect(row.count == 3 && row.pages == 5 ... 5 && row.layovers == 1)
        #expect(index.continents.allSatisfy { $0.places.isEmpty }, "airports never count as countries")
        let none = PassportIndexModel(book: PassportBookModel(entries: entries, calendar: Self.utc), table: .empty,
                                      language: .english, flights: nil) { _ in "" }
        #expect(none.flights == nil, "no Flights page, no Flights row (a decoy)")
    }

    /// A made-up flight.
    nonisolated static func flight(_ from: String, _ to: String, _ departure: Date) -> PassportFlight? {
        PassportFlight(from: from, to: to, departure: departure, arrival: departure.addingTimeInterval(7_200),
                       sources: .fernlet)
    }

    // MARK: Announcing

    /// A new airport's first visit earns its ticket for the new-stamp hook; the banner says "Ten minutes at the
    /// airport found it" only for a first trip no flight landed on.
    @Test func aNewAirportIsAnnouncedAndItsBannerKnowsHow() throws {
        let found = AtlasDiscovery(kind: .airport, token: "PDX", at: Self.day(8, 14))
        var book = PassportBook()
        _ = book.recordAirport(token: "PDX", at: found.at, by: .dwell)
        #expect(WorldLinePicker.stamps(for: found, in: book).map(\.kind) == [.airport])
        let landedAt = Self.day(10, 3)
        let landing = try #require(Self.flight("PDX", "LHR", landedAt.addingTimeInterval(-7_200 - 600)))
        #expect(PassportAirportStamp.foundOnTheGround(code: "PDX", at: found.at, trip: 1, flights: [landing]))
        #expect(!PassportAirportStamp.foundOnTheGround(code: "LHR", at: landedAt, trip: 1, flights: [landing]))
        #expect(!PassportAirportStamp.foundOnTheGround(code: "PDX", at: found.at, trip: 2, flights: []))
    }

    // MARK: Your world

    /// The tower keeps every ink pixel and gains a one-pixel cream ring round it.
    @Test func theTowerIsHaloed() {
        let rows = WorldFlightTower.sprite.rows
        #expect(rows.count == WorldFlightTower.rows.count + 2 && rows.allSatisfy { $0.count == 11 })
        let inner = rows.dropFirst().dropLast().map { String($0.dropFirst().dropLast()) }
        #expect(inner.map { $0.replacingOccurrences(of: "O", with: ".") } == WorldFlightTower.rows)
        #expect(rows[0] == "..OOOOOOO..", "the halo runs over the roof and its corners")
        #expect(WorldFlightTower.sprite.palette["O"] == WorldFlightTower.halo)
    }
}
