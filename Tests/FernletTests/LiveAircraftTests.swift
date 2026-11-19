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

/// A transport that never answers until its task is cancelled, then fails as a dropped connection does.
nonisolated struct StalledLiveAircraftTransport: LiveAircraftTransporting {
    func response(for request: URLRequest, maxBytes: Int) async throws -> LiveAircraftHTTPResponse {
        try await Task.sleep(for: .seconds(30))
        throw LiveAircraftTransportError.network
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

    // MARK: A hostile feed (release review 2026-11-18, F9)

    /// One good plane, for telling "the rest of the answer survived" from "everything was dropped".
    static let goodEntry = #"{"hex":"900d01","flight":"UAL1","alt_baro":31000,"gs":450,"track":90,"lat":39.5,"lon":-105.5,"seen_pos":1}"#

    /// The planes read from `entries` (JSON objects or anything else) followed by ``goodEntry``.
    private func planes(after entries: [String], now: Date = Date(timeIntervalSince1970: 1_763_500_000)) throws -> [LiveAircraft] {
        let body = Data(("{\"ac\":[" + (entries + [Self.goodEntry]).joined(separator: ",") + "]}").utf8)
        return try #require(LiveAircraftFeed.aircraft(in: body, now: now))
    }

    /// The crash itself: a finite altitude no `Int` can hold. The plane is dropped; the one after it is kept.
    @Test func aHugeAltitudeIsDroppedAndNeverTraps() throws {
        for altitude in ["1e30", "-1e30", "1e308", "9223372036854775808", "-9223372036854775809", "1.7976931348623157e308",
                         "150001", "-2001", "4294967296"] {
            let read = try planes(after: [#"{"hex":"bad001","alt_baro":\#(altitude),"lat":39.5,"lon":-105.5}"#])
            #expect(read.map(\.id) == ["900d01"], "alt_baro \(altitude)")
        }
        #expect(LiveAircraftFeed.altitudeFeet(NSNumber(value: 1e30)) == nil)
        #expect(LiveAircraftFeed.altitudeFeet(NSNumber(value: Double.greatestFiniteMagnitude)) == nil)
        #expect(LiveAircraftFeed.altitudeFeet(NSNumber(value: -Double.greatestFiniteMagnitude)) == nil)
        #expect(LiveAircraftFeed.altitudeFeet(NSNumber(value: Double.nan)) == nil)
        #expect(LiveAircraftFeed.altitudeFeet(NSNumber(value: Double.infinity)) == nil)
    }

    @Test func altitudesInRangeAreKeptNegativeOnesIncluded() throws {
        let read = try planes(after: [
            #"{"hex":"low001","alt_baro":-1200,"lat":31.5,"lon":35.4}"#,
            #"{"hex":"hi0001","alt_baro":150000,"lat":31.5,"lon":35.4}"#,
            #"{"hex":"frac01","alt_baro":35000.6,"lat":31.5,"lon":35.4}"#,
        ])
        #expect(read.map(\.id) == ["low001", "hi0001", "frac01", "900d01"])
        #expect(read.map(\.altitudeFeet) == [-1_200, 150_000, 35_001, 31_000])
    }

    @Test func aPlaneOnTheGroundOrWithAWrongTypedAltitudeIsDropped() throws {
        let read = try planes(after: [
            #"{"hex":"gnd001","alt_baro":"ground","lat":39.5,"lon":-105.5}"#,
            #"{"hex":"str001","alt_baro":"31000","lat":39.5,"lon":-105.5}"#,
            #"{"hex":"boo001","alt_baro":true,"lat":39.5,"lon":-105.5}"#,
            #"{"hex":"nul001","alt_baro":null,"lat":39.5,"lon":-105.5}"#,
            #"{"hex":"arr001","alt_baro":[31000],"lat":39.5,"lon":-105.5}"#,
            #"{"hex":"obj001","alt_baro":{"feet":31000},"lat":39.5,"lon":-105.5}"#,
        ])
        #expect(read.map(\.id) == ["900d01"])
    }

    @Test func coordinatesOffTheEarthAreDropped() throws {
        let read = try planes(after: [
            #"{"hex":"lat001","alt_baro":1000,"lat":90.01,"lon":0}"#,
            #"{"hex":"lat002","alt_baro":1000,"lat":-91,"lon":0}"#,
            #"{"hex":"lon001","alt_baro":1000,"lat":0,"lon":180.5}"#,
            #"{"hex":"lon002","alt_baro":1000,"lat":0,"lon":-1e30}"#,
            #"{"hex":"lat003","alt_baro":1000,"lat":1e308,"lon":1e308}"#,
            #"{"hex":"lat004","alt_baro":1000,"lat":"39.5","lon":-105.5}"#,
            #"{"hex":"lat005","alt_baro":1000,"lat":true,"lon":false}"#,
            #"{"hex":"edge01","alt_baro":1000,"lat":-90,"lon":180}"#,
        ])
        #expect(read.map(\.id) == ["edge01", "900d01"], "the poles and the date line are real places")
    }

    /// A speed or a track out of range is left out; the plane stays, and gliding it stays on the Earth.
    @Test func hugeSpeedsAndTracksAreLeftOutAndThePlaneKept() throws {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let read = try planes(after: [
            #"{"hex":"gs0001","alt_baro":1000,"gs":1e300,"track":90,"lat":10,"lon":10}"#,
            #"{"hex":"gs0002","alt_baro":1000,"gs":-5,"track":90,"lat":10,"lon":10}"#,
            #"{"hex":"gs0003","alt_baro":1000,"gs":"fast","track":90,"lat":10,"lon":10}"#,
            #"{"hex":"tr0001","alt_baro":1000,"gs":300,"track":1e300,"lat":10,"lon":10}"#,
            #"{"hex":"tr0002","alt_baro":1000,"gs":300,"track":-90,"true_heading":45,"lat":10,"lon":10}"#,
            #"{"hex":"tr0003","alt_baro":1000,"gs":300,"track":360,"lat":10,"lon":10}"#,
            #"{"hex":"tr0004","alt_baro":1000,"gs":4000,"track":[1],"mag_heading":{"a":1},"lat":10,"lon":10}"#,
        ], now: now)
        #expect(read.map(\.id) == ["gs0001", "gs0002", "gs0003", "tr0001", "tr0002", "tr0003", "tr0004", "900d01"])
        #expect(read.prefix(3).allSatisfy { $0.groundSpeedKnots == nil })
        #expect(read[3].trackDegrees == nil)
        #expect(read[4].trackDegrees == 45, "a track out of range gives way to the heading")
        #expect(read[5].trackDegrees == 0)
        #expect(read[6].trackDegrees == nil)
        #expect(read[6].groundSpeedKnots == 4_000)
        // Bounded: eight planes.
        for plane in read {
            let later = LiveAircraftSky.position(of: plane, at: now.addingTimeInterval(600), glides: true)
            #expect(later.isValid, "\(plane.id) glided off the Earth")
            #expect((0..<8).contains(LiveAircraftSprites.eighths(for: plane.trackDegrees)))
            _ = LiveAircraftPlaced.shadowOffset(feet: plane.altitudeFeet)
            _ = LiveAircraftCopy.altitude(feet: plane.altitudeFeet, locale: Locale(identifier: "en_US"))
            _ = plane.groundSpeedKnots.map { LiveAircraftCopy.speed(knots: $0, locale: Locale(identifier: "fr_FR")) }
            _ = LiveAircraftCardSnapshot(plane, match: .none).spokenName
        }
    }

    @Test func aBadPositionAgeDropsThePlane() throws {
        let read = try planes(after: [
            #"{"hex":"age001","alt_baro":1000,"lat":10,"lon":10,"seen_pos":-1}"#,
            #"{"hex":"age002","alt_baro":1000,"lat":10,"lon":10,"seen_pos":1e300}"#,
            #"{"hex":"age003","alt_baro":1000,"lat":10,"lon":10,"seen_pos":"now"}"#,
            #"{"hex":"age004","alt_baro":1000,"lat":10,"lon":10,"seen_pos":60}"#,
        ])
        #expect(read.map(\.id) == ["age004", "900d01"])
        #expect(read.allSatisfy { abs($0.seenAt.timeIntervalSince1970) < 2_000_000_000 })
    }

    /// Entries that aren't objects, and objects with every field the wrong type, are skipped; the rest is read.
    @Test func wrongTypesNeverPoisonTheRestOfTheAnswer() throws {
        let read = try planes(after: [
            "7", "null", "\"plane\"", "[1,2,3]", "true", "{}",
            #"{"hex":12345,"alt_baro":1000,"lat":10,"lon":10}"#,
            #"{"hex":"","alt_baro":1000,"lat":10,"lon":10}"#,
            #"{"hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","alt_baro":1000,"lat":10,"lon":10}"#,
            #"{"hex":["a"],"flight":{"x":1},"r":7,"t":false,"category":[],"alt_baro":{},"gs":[],"track":"n","lat":[],"lon":{},"seen_pos":[]}"#,
            #"{"hex":"txt001","flight":7,"r":[1],"t":{"a":1},"category":true,"alt_baro":1000,"lat":10,"lon":10}"#,
            #"{"hex":"txt002","flight":"\u0000\u202e\n","r":"ÑÑÑ","t":"                                 ","alt_baro":1000,"lat":10,"lon":10}"#,
            #"{"hex":"900d01","alt_baro":2000,"lat":11,"lon":11,"seen_pos":30}"#,
        ])
        #expect(read.map(\.id) == ["txt001", "txt002", "900d01", "900d01"])
        #expect(read[0].callsign == nil && read[0].registration == nil && read[0].typeCode == nil && read[0].category == nil)
        #expect(read[1].callsign == nil && read[1].registration == nil && read[1].typeCode == nil)
        // The same address twice in one answer: the sky holds one plane, the newer reading.
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let sky = LiveAircraftSky().merging(read, at: now)
        #expect(sky.planes.count == 3)
        #expect(sky.planes["900d01"]?.altitudeFeet == 31_000)
    }

    @Test func answersThatAreNotTheFeedFailWithoutTrapping() {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let deep = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        for body in ["", "null", "[]", "7", "\"ac\"", "{}", #"{"ac":null}"#, #"{"ac":{"hex":"a"}}"#, #"{"ac":"none"}"#, #"{"ac":7}"#,
                     #"{"ac":[{"hex":"a","lat":1,"lon":1,"alt_baro":1e30}"#, deep, "{\"ac\":\(deep)}", "\u{FEFF}\u{0}\u{0}"] {
            let outcome = LiveAircraftFeed.outcome(statusCode: 200, retryAfter: nil, body: Data(body.utf8), now: now)
            #expect(outcome == .failed, "body \(body.prefix(40))")
        }
        #expect(LiveAircraftFeed.outcome(statusCode: 200, retryAfter: nil, body: Data([0xFF, 0xFE, 0x00, 0xD8]), now: now) == .failed)
        #expect(LiveAircraftFeed.outcome(statusCode: 200, retryAfter: nil, body: Data(#"{"ac":[]}"#.utf8), now: now) == .planes([]))
        #expect(LiveAircraftFeed.outcome(statusCode: 200, retryAfter: nil, body: Data(#"{"ac":[7,null,"x"]}"#.utf8), now: now) == .planes([]))
        // Bounded: a handful of statuses.
        for status in [0, -1, 100, 204, 301, 400, 403, 404, 500, 502, 503, Int.max, Int.min] {
            #expect(LiveAircraftFeed.outcome(statusCode: status, retryAfter: nil, body: Self.feed, now: now) == .failed, "status \(status)")
        }
    }

    /// The reviewer's own scenario, through the whole fetch: the answer that crashed Home.
    @Test func theAnswerThatCrashedHomeNowReadsAsAnEmptySky() async throws {
        let body = Data(#"{"ac":[{"hex":"a","lat":1,"lon":1,"alt_baro":1e30}]}"#.utf8)
        let cell = try #require(LiveAircraftCell(containing: GeoPoint(1, 1)))
        let outcome = await LiveAircraftClient.fetch(cell, enabled: true, appVersion: "1", transport: CannedLiveAircraftTransport(body: body))
        #expect(outcome == .planes([]))
    }

    @Test func aListOfThousandsIsCutAtSixHundredAndTheSkyHoldsNoMore() throws {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        // Bounded: 2,500 made-up entries, every fourth one hostile.
        let entries = (0..<2_500).map { index -> String in
            let hex = String(format: "%06x", index)
            if index % 4 == 3 { return #"{"hex":"\#(hex)","alt_baro":1e30,"gs":1e300,"track":-1e300,"lat":1e9,"lon":-1e9}"# }
            return #"{"hex":"\#(hex)","alt_baro":\#(1_000 + index),"gs":300,"track":\#(index % 360),"lat":\#(Double(index % 120) - 60),"lon":\#(Double(index % 300) - 150),"seen_pos":\#(index % 50)}"#
        }
        let body = Data(("{\"ac\":[" + entries.joined(separator: ",") + "]}").utf8)
        let read = try #require(LiveAircraftFeed.aircraft(in: body, now: now))
        #expect(read.count == 450, "the first 600 entries, less their 150 hostile ones")
        #expect(read.allSatisfy { $0.position.isValid && LiveAircraftFeed.altitudeFeetRange.contains(Double($0.altitudeFeet)) })
        var sky = LiveAircraftSky().merging(read, at: now)
        // A second answer of 600 other planes: the sky keeps the newest 600 and no more.
        let others = (0..<600).map { index in
            LiveAircraft(id: "ff" + String(format: "%04x", index), callsign: nil, registration: nil, typeCode: nil, category: nil,
                         position: GeoPoint(10, 10), altitudeFeet: 30_000, groundSpeedKnots: 400, trackDegrees: 10, seenAt: now)
        }
        sky = sky.merging(others, at: now)
        #expect(sky.planes.count == LiveAircraftSky.maxPlanes)
        #expect(sky.showing(at: now).count == LiveAircraftSky.maxPlanes)
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

    // MARK: Backing off on failures (release review 2026-11-18, F9)

    /// A failed fetch (no network, a timeout, a 403 or 5xx, a body that isn't the feed) rests, doubling from the 30 s
    /// beat to 15 minutes; planes clear it.
    @Test func failedFetchesInARowRestLongerUpToFifteenMinutes() {
        let start = Date(timeIntervalSince1970: 1_763_500_000)
        var budget = LiveAircraftBudget(day: LiveAircraftBudget.dayStamp(start), used: 0)
        var now = start
        var rests: [TimeInterval] = []
        // Bounded: twelve failures.
        for _ in 0..<12 {
            budget = budget.answered(.failed, at: now)
            let until = budget.restUntil ?? now
            rests.append(until.timeIntervalSince(now))
            #expect(!budget.allows(at: until.addingTimeInterval(-1)))
            #expect(budget.allows(at: until))
            now = until
        }
        #expect(rests == [30, 60, 120, 240, 480, 900, 900, 900, 900, 900, 900, 900])
        #expect(rests.allSatisfy { $0 >= LiveAircraftBudget.interval && $0 <= LiveAircraftBudget.longestFailureRest })
        #expect(budget.strikes == LiveAircraftBudget.maxStrikes)
        let recovered = budget.answered(.planes([]), at: now)
        #expect(recovered.strikes == 0)
        #expect(recovered.answered(.failed, at: now).restUntil == now.addingTimeInterval(30), "after planes the back-off starts again")
        #expect(budget.answered(.notPermitted, at: now) == budget, "the switch refusing a fetch is no failure")
    }

    /// An outage with the map in front all day: the back-off makes it about a hundred requests, not the 400 cap, and
    /// never one sooner than 30 s after the last.
    @Test func aDayLongOutageSendsFarFewerThanTheCap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let midnight = Date(timeIntervalSince1970: 1_763_510_400)   // 2025-11-19 00:00 UTC
        var budget = LiveAircraftBudget(day: LiveAircraftBudget.dayStamp(midnight, calendar: calendar), used: 0)
        var sent = 0, lastSent: Date?
        // Bounded: one day of 30 s beats.
        for beat in 0..<2_880 {
            let now = midnight.addingTimeInterval(Double(beat) * LiveAircraftBudget.interval)
            guard budget.allows(at: now, calendar: calendar) else { continue }
            if let lastSent { #expect(now.timeIntervalSince(lastSent) >= LiveAircraftBudget.interval) }
            budget = budget.spending(at: now, calendar: calendar).answered(.failed, at: now)
            sent += 1
            lastSent = now
        }
        #expect(sent <= 110, "sent \(sent)")
        #expect(sent < LiveAircraftBudget.dailyCap)
    }

    @Test func a429AfterFailuresAndAHostileRetryAfterStayBounded() {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let budget = LiveAircraftBudget(day: LiveAircraftBudget.dayStamp(now), used: 3)
        let longest = LiveAircraftBudget.longestRest * 6
        // Bounded: a handful of hostile headers.
        for header in [Double.nan, .infinity, -.infinity, -1, 0, 1e300, .greatestFiniteMagnitude] {
            let rested = budget.answered(.rateLimited(retryAfter: header), at: now)
            let rest = (rested.restUntil ?? now).timeIntervalSince(now)
            #expect(rest.isFinite && rest >= LiveAircraftBudget.interval && rest <= longest, "Retry-After \(header) rested \(rest)")
            #expect(!rested.allows(at: now.addingTimeInterval(LiveAircraftBudget.interval - 1)))
        }
        var mixed = budget
        // Bounded: 40 answers, failures and 429s by turns; a stored tally of nonsense strikes too.
        for round in 0..<40 {
            mixed = mixed.answered(round.isMultiple(of: 2) ? .failed : .rateLimited(retryAfter: nil), at: now)
            let rest = (mixed.restUntil ?? now).timeIntervalSince(now)
            #expect(rest >= LiveAircraftBudget.interval && rest <= LiveAircraftBudget.longestRest)
        }
        #expect(mixed.strikes == LiveAircraftBudget.maxStrikes)
        for strikes in [Int.max, Int.min, -1] {
            let stored = LiveAircraftBudget(day: budget.day, used: 0, restUntil: nil, strikes: strikes)
            let rest = (stored.answered(.failed, at: now).restUntil ?? now).timeIntervalSince(now)
            #expect(rest >= LiveAircraftBudget.interval && rest <= LiveAircraftBudget.longestFailureRest, "strikes \(strikes)")
        }
    }

    /// Through the watch: a failing host is asked once, then left alone for the rest; a second look inside the rest
    /// sends nothing.
    @Test func theWatchRestsAfterAFailedFetchAndSendsNothingMeanwhile() async throws {
        let defaults = try #require(UserDefaults(suiteName: "LiveAircraftTests.\(UUID().uuidString)"))
        WorldMapPreferences.setShowsLivePlanes(true, in: defaults)
        let cell = try #require(LiveAircraftCell(containing: GeoPoint(39.86, -104.67)))
        // Bounded: four kinds of failing answer.
        for (status, body) in [(503, Data()), (403, Self.feed), (200, Data("<html>".utf8)), (200, Data(#"{"ac":7}"#.utf8))] {
            WorldMapPreferences.setLivePlanesBudget(LiveAircraftBudget(day: "", used: 0), in: defaults)
            let transport = CannedLiveAircraftTransport(status: status, body: body)
            let watch = LiveAircraftWatch(transport: transport, defaults: defaults)
            await watch.fetchOnce(cell)
            await watch.fetchOnce(cell)
            await watch.fetchOnce(cell, now: Date().addingTimeInterval(LiveAircraftBudget.interval - 2))
            #expect(transport.requests.count == 1, "status \(status): asked \(transport.requests.count) times inside the rest")
            let budget = WorldMapPreferences.livePlanesBudget(in: defaults)
            #expect(budget.strikes == 1 && budget.used == 1)
            await watch.fetchOnce(cell, now: Date().addingTimeInterval(LiveAircraftBudget.interval + 2))
            #expect(transport.requests.count == 2, "after the rest it asks again")
            #expect(watch.sky.planes.isEmpty)
        }
        // A good answer clears the strikes and fills the sky.
        let good = LiveAircraftWatch(transport: CannedLiveAircraftTransport(body: Self.feed), defaults: defaults)
        await good.fetchOnce(cell, now: Date().addingTimeInterval(3_600))
        #expect(WorldMapPreferences.livePlanesBudget(in: defaults).strikes == 0)
    }

    /// A fetch cut short because the map left the front (its task cancelled) is no failure of adsb.lol's: no strike.
    @Test func aFetchCancelledWhenTheMapLeavesEarnsNoRest() async throws {
        let defaults = try #require(UserDefaults(suiteName: "LiveAircraftTests.\(UUID().uuidString)"))
        WorldMapPreferences.setShowsLivePlanes(true, in: defaults)
        let cell = try #require(LiveAircraftCell(containing: GeoPoint(39.86, -104.67)))
        let watch = LiveAircraftWatch(transport: StalledLiveAircraftTransport(), defaults: defaults)
        let task = Task { await watch.fetchOnce(cell) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value
        let budget = WorldMapPreferences.livePlanesBudget(in: defaults)
        #expect(budget.used == 1, "the request was sent and counts toward the day")
        #expect(budget.strikes == 0 && budget.restUntil == nil)
    }

    /// Release review F7: the planes are asked for only while nothing of Home's own covers the map, the tapped
    /// plane's card aside (it lives in the layer, part of the planes).
    @Test func homeAsksForPlanesOnlyWithNothingOfItsOwnOverTheMap() throws {
        let home = try RepoRoot.source("App/Fernlet/World/Home/WorldMapHome.swift")
        #expect(home.contains("isActive: isLivePlanesFront, home: livePlanes"))
        #expect(home.contains("private var isLivePlanesFront: Bool { isTapFrontPage && wornWaySheet == nil }"))
        #expect(!home.contains("LiveAircraftLayer(store: store, viewport: viewport, size: size, isActive: isMapFrontPage"))
        let front = try #require(home.range(of: "private var isTapFrontPage: Bool {"))
        let rule = home[front.upperBound...].prefix(500)
        for cover in ["isMapFrontPage", "scenePhase == .active", "guidedSession == nil", "cameraMode == nil", "!isLocationIntroUp",
                      "openPhotoPlace == nil", "openTripPhotos == nil", "placeSheet == nil", "menuSearch == nil",
                      "explore.openCity == nil", "explore.openLandmark == nil"] {
            #expect(rule.contains(cover), "isTapFrontPage no longer checks \(cover)")
        }
        let layer = try RepoRoot.source("App/Fernlet/World/Map/LiveAircraft/LiveAircraftLayer.swift")
        #expect(layer.contains(".sheet(item: $home.opened)"), "the plane's card is the layer's own sheet")
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
