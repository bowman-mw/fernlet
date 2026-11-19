//
//  LiveAircraftTests.swift
//  FernletTests
//
//  Live planes nearby (owner 2026-11-19, the live-planes build): what may leave the phone (one 0.5° cell, one fixed
//  host, nothing when the switch is off), how often (30 s, 400 a day, a rest after a 429), how the feed is read
//  (planes on the ground and stale positions dropped), and how planes are drawn, matched to the person's own flights
//  and stamped. Every fixture plane is made up.
//

import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// A transport that answers every request with one canned response and counts the requests.
nonisolated final class CannedLiveAircraftTransport: LiveAircraftTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    let answer: LiveAircraftHTTPResponse

    init(status: Int = 200, retryAfter: TimeInterval? = nil, body: Data = Data()) {
        answer = LiveAircraftHTTPResponse(statusCode: status, retryAfter: retryAfter, body: body)
    }

    var requests: [URLRequest] { lock.withLock { seen } }

    func response(for request: URLRequest, maxBytes: Int) async throws -> LiveAircraftHTTPResponse {
        lock.withLock { seen.append(request) }
        return answer
    }
}

@MainActor
struct LiveAircraftTests {
    /// A made-up readsb answer: two planes in the air, one on the ground, one stale, one with no position.
    static let feed = Data("""
    {"ac":[
     {"hex":"A1B2C3","flight":"UAL1704 ","r":"N12345","t":"B738","category":"A3","alt_baro":25250,"gs":384.3,"track":246.7,"lat":39.56,"lon":-105.59,"seen_pos":0.4},
     {"hex":"abc001","flight":"N50XY","r":"N50XY","t":"C172","category":"A1","alt_baro":5600,"gs":95,"true_heading":10,"lat":39.9,"lon":-104.9,"seen_pos":2},
     {"hex":"abc002","flight":"SWA12","t":"B737","alt_baro":"ground","gs":3,"lat":39.85,"lon":-104.67,"seen_pos":1},
     {"hex":"abc003","flight":"DAL9","t":"A321","alt_baro":30000,"lat":39.7,"lon":-104.6,"seen_pos":120},
     {"hex":"abc004","flight":"FFT33","t":"A20N","alt_baro":12000}
    ],"now":1763500000000,"total":5}
    """.utf8)

    // MARK: The cell

    @Test func theMapCentreSnapsToTheHalfDegreeCell() throws {
        let denver = try #require(LiveAircraftCell(containing: GeoPoint(39.8617, -104.6731)))
        #expect(denver.centreLatitude == 39.75)
        #expect(denver.centreLongitude == -104.75)
        let sameCell = try #require(LiveAircraftCell(containing: GeoPoint(39.51, -104.99)))
        #expect(sameCell == denver, "everyone in a cell sends the identical request")
        let london = try #require(LiveAircraftCell(containing: GeoPoint(51.47, -0.4543)))
        #expect(london.centreLatitude == 51.25 && london.centreLongitude == -0.25)
        let pole = try #require(LiveAircraftCell(containing: GeoPoint(90, 179.99)))
        #expect(pole.centreLatitude == 89.75 && pole.centreLongitude == 179.75)
        #expect(LiveAircraftCell(containing: GeoPoint(.nan, 0)) == nil)
    }

    // MARK: The request

    @Test func theRequestCarriesTheCellCentreAndAFixedRadiusOnly() throws {
        let cell = try #require(LiveAircraftCell(containing: GeoPoint(39.8617, -104.6731)))
        let request = try #require(LiveAircraftClient.pointRequest(for: cell, appVersion: "2.3"))
        #expect(request.url?.absoluteString == "https://api.adsb.lol/v2/point/39.75/-104.75/50")
        #expect(request.url?.query == nil)
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Fernlet/2.3")
        #expect(Set(request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []) == ["accept", "user-agent"])
        #expect(LiveAircraftClient.coordinate(-0.25) == "-0.25")
        #expect(LiveAircraftClient.coordinate(5.75) == "5.75")
    }

    @Test func nothingIsBuiltOrSentWhileTheSwitchIsOff() async throws {
        let transport = CannedLiveAircraftTransport(body: Self.feed)
        let cell = try #require(LiveAircraftCell(containing: GeoPoint(39.86, -104.67)))
        let outcome = await LiveAircraftClient.fetch(cell, enabled: false, appVersion: "1", transport: transport)
        #expect(outcome == .notPermitted)
        #expect(transport.requests.isEmpty)
        let on = await LiveAircraftClient.fetch(cell, enabled: true, appVersion: "1", transport: transport)
        #expect(transport.requests.count == 1)
        guard case .planes(let planes) = on else {
            Issue.record("expected planes, got \(on)")
            return
        }
        #expect(planes.count == 2)
    }

    /// The client is the only file that names the host, and it can't be handed an exact place: it never names a
    /// `GeoPoint`, a location or a viewport, only the cell.
    @Test func theClientTakesOnlyACell() throws {
        let source = try RepoRoot.source("App/Fernlet/World/Map/LiveAircraft/LiveAircraftClient.swift")
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for banned in ["GeoPoint", "CLLocation", "MapViewport", "latitude:", "longitude:", "URLSession.shared", "routeset"] {
            #expect(!code.contains(banned), "LiveAircraftClient.swift names \(banned)")
        }
        #expect(code.contains("EphemeralWebSession.shared"))
    }

    // MARK: The feed

    @Test func theFeedDropsPlanesOnTheGroundStalePositionsAndNoPosition() throws {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let planes = try #require(LiveAircraftFeed.aircraft(in: Self.feed, now: now))
        #expect(planes.map(\.id) == ["a1b2c3", "abc001"])
        let united = planes[0]
        #expect(united.callsign == "UAL1704")
        #expect(united.registration == "N12345")
        #expect(united.typeCode == "B738")
        #expect(united.altitudeFeet == 25_250)
        #expect(united.trackDegrees == 246.7)
        #expect(abs(united.seenAt.timeIntervalSince(now) + 0.4) < 0.001)
        #expect(planes[1].trackDegrees == 10, "the heading stands in when there's no track")
        #expect(LiveAircraftFeed.aircraft(in: Data("<html>".utf8), now: now) == nil)
    }

    @Test func aTooManyRequestsAnswerRests() {
        #expect(LiveAircraftFeed.outcome(statusCode: 429, retryAfter: 120, body: Data()) == .rateLimited(retryAfter: 120))
        #expect(LiveAircraftFeed.outcome(statusCode: 503, retryAfter: nil, body: Self.feed) == .failed)
        #expect(LiveAircraftFeed.outcome(statusCode: 302, retryAfter: nil, body: Data()) == .failed)
    }

    // MARK: The budget

    @Test func theDailyCapIsFourHundredAndANewDayStartsAgain() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver") ?? .gmt
        let morning = Date(timeIntervalSince1970: 1_763_470_800)   // 2025-11-18 06:00 Denver
        var budget = LiveAircraftBudget(day: LiveAircraftBudget.dayStamp(morning, calendar: calendar), used: 0)
        // Bounded: 400 fetches.
        for _ in 0..<LiveAircraftBudget.dailyCap {
            #expect(budget.allows(at: morning, calendar: calendar))
            budget = budget.spending(at: morning, calendar: calendar)
        }
        #expect(!budget.allows(at: morning, calendar: calendar))
        #expect(budget.isSpent(at: morning, calendar: calendar))
        let tomorrow = morning.addingTimeInterval(24 * 3_600)
        #expect(budget.allows(at: tomorrow, calendar: calendar))
        #expect(budget.rolled(to: tomorrow, calendar: calendar).used == 0)
    }

    @Test func a429RestsAndRepeatedOnesRestLonger() {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let budget = LiveAircraftBudget(day: LiveAircraftBudget.dayStamp(now), used: 3)
        let first = budget.answered(.rateLimited(retryAfter: nil), at: now)
        #expect(first.restUntil == now.addingTimeInterval(300))
        #expect(!first.allows(at: now.addingTimeInterval(299)))
        let second = first.answered(.rateLimited(retryAfter: nil), at: now)
        #expect(second.restUntil == now.addingTimeInterval(600))
        let told = budget.answered(.rateLimited(retryAfter: 5), at: now)
        #expect(told.restUntil == now.addingTimeInterval(LiveAircraftBudget.interval), "never sooner than the 30 s beat")
        #expect(second.answered(.planes([]), at: now).strikes == 0)
    }

    @Test func theSwitchIsOffByDefaultAndTheWipeClearsEverything() throws {
        let defaults = try #require(UserDefaults(suiteName: "LiveAircraftTests.\(UUID().uuidString)"))
        #expect(!WorldMapPreferences.showsLivePlanes(in: defaults))
        #expect(!WorldMapPreferences.livePlanesDisclosed(in: defaults))
        WorldMapPreferences.setShowsLivePlanes(true, in: defaults)
        #expect(WorldMapPreferences.livePlanesDisclosed(in: defaults), "turning it on means the disclosure was seen")
        WorldMapPreferences.setLivePlanesBudget(LiveAircraftBudget(day: "2025-11-18", used: 7, restUntil: Date(), strikes: 2), in: defaults)
        WorldMapPreferences.clearAll(in: defaults)
        #expect(!WorldMapPreferences.showsLivePlanes(in: defaults))
        #expect(!WorldMapPreferences.livePlanesDisclosed(in: defaults))
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fernlet.worldMap.livePlanes") }
        #expect(keys.isEmpty, "left behind: \(keys.sorted())")
    }

    // MARK: Names and designs

    @Test func theCallsignNamesTheAirlineAndFlight() throws {
        let united = try #require(LiveAircraftAirlines.flight("UAL1704"))
        #expect(united.airline.name == "United" && united.number == "1704")
        #expect(LiveAircraftAirlines.flight("N50XY") == nil, "a registration isn't an airline flight")
        #expect(LiveAircraftAirlines.flight("ZZZ123") == nil, "an unlisted designator")
        #expect(LiveAircraftAirlines.split("SWA12A")?.number == "12A")
        #expect(LiveAircraftAirlines.byCode.count >= 100)
        #expect(LiveAircraftAirlines.byCode.values.allSatisfy { !$0.name.isEmpty })
    }

    @Test func typesHaveAFamilyAndWords() {
        #expect(LiveAircraftTypes.type("B738")?.name == "Boeing 737-800")
        #expect(LiveAircraftTypes.family(code: "A388", category: nil) == .jumbo)
        #expect(LiveAircraftTypes.family(code: "R44", category: nil) == .helicopter)
        #expect(LiveAircraftTypes.family(code: "ZZZZ", category: "A7") == .helicopter, "an unlisted type falls back to its category")
        #expect(LiveAircraftTypes.family(code: nil, category: nil) == .narrowbody)
        #expect(LiveAircraftTypes.byCode.count >= 200)
        #expect(Set(LiveAircraftTypes.byCode.values.map(\.family)) == Set(LiveAircraftFamily.allCases), "every design is used")
    }

    @Test func aFlightRecordsWordsFindTheirTypeCodes() {
        #expect(LiveAircraftTypes.codes(forName: "Boeing 737-800") == ["B738"])
        #expect(LiveAircraftTypes.codes(forName: "Airbus A321neo") == ["A21N"])
        #expect(LiveAircraftTypes.codes(forName: "Boeing 787-9") == ["B789"])
        #expect(LiveAircraftTypes.codes(forName: "Embraer E175") == ["E75L", "E75S"])
        #expect(LiveAircraftTypes.codes(forName: "b39m") == ["B39M"])
        #expect(LiveAircraftTypes.codes(forName: "Hot air balloon").isEmpty)
        #expect(LiveAircraftTypes.codes(forName: nil).isEmpty)
    }

    @Test func everyDesignIsRectangularAndTurnsToEightHeadings() {
        // Bounded: ten families, eight headings each.
        for family in LiveAircraftFamily.allCases {
            let rows = LiveAircraftSprites.rows(family)
            #expect(Set(rows.map(\.count)).count == 1, "\(family)'s rows differ in width")
            let headings = LiveAircraftSprites.turnedRows[family] ?? []
            #expect(headings.count == 8)
            for turned in headings {
                #expect(!turned.isEmpty && Set(turned.map(\.count)).count == 1, "\(family) turns ragged")
                #expect(turned.joined().contains("k"), "\(family) loses its outline when turned")
            }
            #expect(headings[2] == WorldAirportSprites.turnedRight(rows), "a quarter turn is exact")
        }
        #expect(LiveAircraftSprites.eighths(for: nil) == 0)
        #expect(LiveAircraftSprites.eighths(for: 44) == 1)
        #expect(LiveAircraftSprites.eighths(for: 359) == 0)
        #expect(LiveAircraftSprites.eighths(for: 180) == 4)
        #expect(LiveAircraftSprites.eighths(for: -90) == 6)
    }

    // MARK: The sky

    @Test func planesGlideAlongTheirTrackAndStayPutWithReduceMotion() {
        let read = Date(timeIntervalSince1970: 1_763_500_000)
        let plane = LiveAircraft(id: "a", callsign: nil, registration: nil, typeCode: nil, category: nil,
                                 position: GeoPoint(40, -105), altitudeFeet: 10_000, groundSpeedKnots: 100,
                                 trackDegrees: 0, seenAt: read)
        let later = read.addingTimeInterval(36)
        let glided = LiveAircraftSky.position(of: plane, at: later, glides: true)
        #expect(abs(glided.distance(to: plane.position) - 1_852) < 5, "100 kn for 36 s is a nautical mile")
        #expect(glided.latitude > plane.position.latitude)
        #expect(LiveAircraftSky.position(of: plane, at: later, glides: false) == plane.position)
        let farLater = LiveAircraftSky.position(of: plane, at: read.addingTimeInterval(600), glides: true)
        #expect(farLater.distance(to: plane.position) < 100 * 1_852 / 3_600 * (LiveAircraftSky.longestGlide + 1))
    }

    @Test func aPlaneNoAnswerHasSeenFadesOutAfterAMinute() {
        let start = Date(timeIntervalSince1970: 1_763_500_000)
        func plane(_ id: String, at date: Date) -> LiveAircraft {
            LiveAircraft(id: id, callsign: nil, registration: nil, typeCode: nil, category: nil, position: GeoPoint(40, -105),
                         altitudeFeet: 9_000, groundSpeedKnots: nil, trackDegrees: nil, seenAt: date)
        }
        var sky = LiveAircraftSky().merging([plane("a", at: start), plane("b", at: start)], at: start)
        sky = sky.merging([plane("a", at: start.addingTimeInterval(30))], at: start.addingTimeInterval(30))
        #expect(Set(sky.showing(at: start.addingTimeInterval(30)).map(\.id)) == ["a", "b"], "b is kept for a while")
        #expect(sky.opacity(of: plane("b", at: start), at: start.addingTimeInterval(52)) < 1, "b fades")
        #expect(sky.showing(at: start.addingTimeInterval(61)).map(\.id) == ["a"], "b is gone after a minute")
    }

    @Test func aLivePlaneMatchesTheFlightsFlownByTailThenType() throws {
        let departure = Date(timeIntervalSince1970: 1_700_000_000)
        let flown = try #require(PassportFlight(from: "PDX", to: "DEN", departure: departure, arrival: nil, sources: .flighty,
                                                aircraftType: "Boeing 737-800", tailNumber: "N-12345"))
        let matcher = LiveAircraftFlown(flights: [flown])
        func plane(_ registration: String?, _ type: String?) -> LiveAircraft {
            LiveAircraft(id: "x", callsign: nil, registration: registration, typeCode: type, category: nil,
                         position: GeoPoint(40, -105), altitudeFeet: 9_000, groundSpeedKnots: nil, trackDegrees: nil, seenAt: departure)
        }
        #expect(matcher.match(plane("N12345", "B738")) == .samePlane)
        #expect(matcher.match(plane("N99999", "B738")) == .sameType)
        #expect(matcher.match(plane("N99999", "A320")) == .none)
        #expect(LiveAircraftFlown().match(plane("N12345", "B738")) == .none)
    }

    @Test func theHangarHoldsEachTypeFlownFromTheFlightsOwnRecords() throws {
        let day = 86_400.0, start = Date(timeIntervalSince1970: 1_700_000_000)
        func flight(_ days: Double, _ type: String?) throws -> PassportFlight {
            try #require(PassportFlight(from: "PDX", to: "SEA", departure: start.addingTimeInterval(days * day), arrival: nil,
                                        sources: .flighty, aircraftType: type, tailNumber: nil))
        }
        let flights = [try flight(3, "Boeing 737-800"), try flight(1, "Embraer E175"), try flight(5, "Boeing 737-800"),
                       try flight(2, nil), try flight(400, "Airbus A321neo")]
        let planes = PassportHangarPlane.planes(from: flights, now: start.addingTimeInterval(10 * day))
        #expect(planes.map(\.fullName) == ["Embraer 175", "Boeing 737-800"], "first flown first; a planned flight gives none")
        #expect(planes.map(\.name) == ["175", "737-800"])
        #expect(planes.last?.count == 2)
        #expect(planes.first?.family == .regionalJet)
        #expect(PassportHangarPlane.shortName("McDonnell Douglas MD-11") == "MD-11")
        #expect(PassportHangarPlane.shortName("HondaJet") == "HondaJet")
    }

    @Test func theHangarFollowsFlightsAndOnlyWithIt() {
        let book = PassportBookModel(entries: [], showsFlights: true, showsHangar: true, showsRoadTrips: true)
        #expect(book.pageCount == 7)
        #expect(book.flightsPage == 4 && book.hangarPage == 5 && book.roadTripsPage == 6 && book.indexPage == 7)
        #expect(book.page(at: 5) == .hangar)
        let noFlights = PassportBookModel(entries: [], showsHangar: true)
        #expect(noFlights.hangarPage == nil && noFlights.pageCount == 4, "no Flights page, no Hangar")
        let without = PassportBookModel(entries: [], showsFlights: true, showsRoadTrips: true)
        #expect(without.hangarPage == nil && without.roadTripsPage == 5)
    }

    @Test func aTapNearADrawnPlaneOpensItsCardAndOtherTapsFallThrough() {
        let home = LiveAircraftHome()
        let plane = LiveAircraft(id: "a", callsign: "UAL1704", registration: "N27260", typeCode: "B38M", category: nil,
                                 position: GeoPoint(40, -105), altitudeFeet: 9_500, groundSpeedKnots: 210, trackDegrees: 45,
                                 seenAt: Date())
        let key = LiveAircraftSpriteKey(family: .narrowbody, livery: .plain(.narrowbody), eighths: 1)
        home.drawn = [LiveAircraftPlaced(aircraft: plane, point: CGPoint(x: 100, y: 200), rect: .zero, sprite: key, opacity: 1,
                                         shadowOffset: 2, match: .samePlane)]
        #expect(!home.open(at: CGPoint(x: 160, y: 200)), "a tap away from every plane is the map's")
        #expect(home.opened == nil)
        #expect(home.open(at: CGPoint(x: 110, y: 212)))
        #expect(home.opened?.flight == "United 1704")
        #expect(home.opened?.type == "Boeing 737 MAX 8")
        #expect(home.opened?.match == .samePlane)
    }

    @Test func planesDrawAtWholeDevicePixels() {
        #expect(LiveAircraftLayer.scale(displayScale: 3) * 3 == 5)
        #expect(LiveAircraftLayer.scale(displayScale: 2) * 2 == 3)
        #expect(LiveAircraftLayer.scale(displayScale: 1) == 2)
    }

    @Test func theCardSaysAltitudeAndSpeedInThePersonsUnits() {
        let us = Locale(identifier: "en_US"), france = Locale(identifier: "fr_FR")
        #expect(LiveAircraftCopy.altitude(feet: 25_260, locale: us).contains("25,250") || LiveAircraftCopy.altitude(feet: 25_260, locale: us).contains("25,300"))
        #expect(LiveAircraftCopy.altitude(feet: 25_260, locale: us).contains("ft"))
        #expect(LiveAircraftCopy.altitude(feet: 25_260, locale: france).contains("m"))
        #expect(LiveAircraftCopy.speed(knots: 384, locale: us).contains("mph"))
        #expect(LiveAircraftCopy.speed(knots: 384, locale: france).contains("km/h"))
    }
}
