import Foundation
import Testing
import WorldMapStore

/// The bundled airports pack (World-Airports-Spec §1–§2, Docs/World-Airports-Pack.md): the shipped file is
/// the one `WorldAirports.expectedSHA256` pins and reads as the spec lays out, and a damaged file is refused,
/// never trapped on. The airports named here are well-known examples (the spec's sample traveller lives in
/// Portland); none comes from the owner's own flights.
@MainActor
struct WorldAirportsTests {
    private func shippedData() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldAirports", withExtension: "pack"))
        return try Data(contentsOf: url)
    }

    private func shipped() throws -> WorldAirports {
        try WorldAirports(data: try shippedData())
    }

    /// The shipped pack is the pinned one, under its cap, with every large and medium airport and every IATA
    /// point.
    @Test func theShippedPackIsThePinnedOne() throws {
        let data = try shippedData()
        #expect(data.count <= WorldAirports.maxPackBytes)
        #expect(WorldAtlasPack.sha256Hex(data) == WorldAirports.expectedSHA256)
        let airports = try WorldAirports(data: data)
        #expect(airports.airports.count > 5_000 && airports.airports.count < 6_000)
        #expect(airports.airports.filter { $0.size == .large }.count > 1_000)
        #expect(airports.points.count > 9_000 && airports.points.count < 10_000)
        #expect(airports.airports.map(\.token) == airports.airports.map(\.token).sorted())
        // The owner's approved outlines (batches 1–2 reviewed, 3 on in the owner's blanket approval, 2026-10-31): only large airports, each holding its own point.
        let outlined = airports.airports.filter { $0.grounds.isOurOutline }
        #expect(outlined.count >= 802)
        #expect(outlined.allSatisfy { $0.size == .large && $0.contains($0.point) })
    }

    /// Portland: its names, city, zone and grounds (the runway outline holds the field, not a street 3 km
    /// away).
    @Test func portlandReadsAsTheSpecSays() throws {
        let airports = try shipped()
        let pdx = try #require(airports.airport(code: "PDX"))
        #expect(pdx.token == "PDX" && pdx.iata == "PDX" && pdx.size == .large && pdx.countryCode == "US")
        #expect(pdx.englishName == "Portland International" && pdx.englishCity == "Portland")
        #expect(pdx.name(spanish: true) == "Internacional de Portland")
        #expect(pdx.timeZoneIdentifier == "America/Los_Angeles")
        #expect(airports.timeZone(iata: "pdx")?.identifier == "America/Los_Angeles")
        #expect(pdx.grounds.isOurOutline, "Portland has its own outline since batch 3")
        #expect(pdx.contains(pdx.point))
        #expect(airports.airports(containing: pdx.point).map(\.token) == ["PDX"])
        #expect(airports.airports(containing: pdx.point.offset(east: 0, north: -6_000)).isEmpty,
                "a neighbourhood 6 km south is outside the grounds")
    }

    /// A nickname wins in both languages, and Spanish city names come through.
    @Test func namesAndCities() throws {
        let airports = try shipped()
        let lhr = try #require(airports.airport(code: "LHR"))
        #expect(lhr.name(spanish: false) == "Heathrow" && lhr.name(spanish: true) == "Heathrow")
        #expect(lhr.city(spanish: true) == "Londres" && lhr.timeZoneIdentifier == "Europe/London")
        let mex = try #require(airports.airport(code: "MEX"))
        #expect(mex.city(spanish: true) == "Ciudad de México")
    }

    /// Points cover small airports an imported flight may name, which are never unlockable; an airport
    /// with no IATA code is found by its ident.
    @Test func pointsAndIdents() throws {
        let airports = try shipped()
        let unlockable = try #require(airports.point(iata: "PDX"))
        #expect(unlockable.isUnlockable)
        let small = try #require(airports.points.first { !$0.isUnlockable })
        #expect(airports.airport(code: small.iata) == nil)
        let noIATA = try #require(airports.airports.first { $0.iata == nil })
        #expect(airports.airport(code: noIATA.ident)?.token == noIATA.token && noIATA.code == noIATA.ident)
        #expect(airports.point(iata: "ZZZ") == nil && airports.timeZone(iata: "ZZZ") == nil)
    }

    /// The hand-made airline table answers by ICAO, IATA or name, ignoring case and accents.
    @Test func airlinesMatchByAnyName() throws {
        let airports = try shipped()
        #expect(airports.airline(named: "ACA")?.iata == "AC")
        #expect(airports.airline(named: "ac")?.icao == "ACA")
        #expect(airports.airline(named: "Air Canada")?.icao == "ACA")
        #expect(airports.airline(named: "aeromexico")?.icao == "AMX")
        #expect(airports.airline(named: "Cedar Air") == nil, "the spec's fictional airline is in no table")
    }

    /// Every unlockable's grounds hold its own point, and every zone is one this iPhone knows.
    @Test func everyAirportIsWellFormed() throws {
        let airports = try shipped()
        var zones = Set<String>()
        for airport in airports.airports {
            if !airport.contains(airport.point) {
                Issue.record("\(airport.token)'s grounds don't hold its point")
            }
            zones.insert(airport.timeZoneIdentifier)
        }
        for zone in zones where TimeZone(identifier: zone) == nil {
            Issue.record("unknown zone \(zone)")
        }
    }

    /// A damaged file is refused with the reason, never trapped on.
    @Test func aDamagedFileIsRefused() throws {
        let data = try shippedData()
        func refusal(_ bytes: Data) -> WorldAtlasPackError? {
            do {
                _ = try WorldAirports(data: bytes)
                return nil
            } catch let error as WorldAtlasPackError {
                return error
            } catch {
                return nil
            }
        }
        var magic = data
        magic[0] = 0x58
        #expect(refusal(magic) == .badMagic)
        #expect(refusal(data.prefix(6)) == .badTable)
        var version = data
        version[4] = 9
        #expect(refusal(version) == .badVersion)
        #expect(refusal(data.prefix(data.count - 10)) != nil, "a cut-off file")
        #expect(refusal(Data(count: WorldAirports.maxPackBytes + 1)) == .tooLarge)
        // The atlas's own pack is not an airports pack.
        let atlasURL = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let atlasData = try Data(contentsOf: atlasURL)
        let atlasRefusal = refusal(atlasData)
        #expect(atlasRefusal == .tooLarge || atlasRefusal == .badMagic)
    }
}
