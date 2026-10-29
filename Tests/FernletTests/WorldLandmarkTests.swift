import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The World's landmarks (round 7, World-Exploration-Spec §2 "Landmarks"): the hand-written bundled list and
/// its rules (every city in the shipped pack, radii in range, the famous art ids), the find rule, the
/// passport keeping each one once in the fixed order, the decoy keeping nothing, and every malformed file
/// refused whole.
@MainActor
struct WorldLandmarkTests {
    nonisolated static let t1 = Date(timeIntervalSince1970: 1_792_800_000)
    nonisolated static let t2 = Date(timeIntervalSince1970: 1_792_886_400)

    nonisolated static let laurelhurst = GeoPoint(45.5206, -122.6253)
    nonisolated static let portlandCity = AtlasCity(token: "Q6106", countryCode: "US", size: .large,
                                                    population: 2_000_000, point: GeoPoint(45.52197, -122.68194),
                                                    names: AtlasCityNames(english: "Portland"))

    /// A stand-in atlas: Portland everywhere.
    nonisolated struct PortlandAtlas: AtlasVisitResolving {
        func visit(at point: GeoPoint) -> AtlasVisit {
            AtlasVisit(countryCode: "US", sovereignCode: "US", continent: .northAmerica,
                       city: WorldLandmarkTests.portlandCity, terrain: .temperateForest)
        }
    }

    /// A small hand-built list: Laurelhurst Park (250 m) and a tower 2 km east.
    static func smallList() throws -> WorldLandmarks {
        try WorldLandmarks(landmarks: [
            AtlasLandmark(token: "laurelhurstPark", englishName: "Laurelhurst Park", spanishName: "Parque Laurelhurst",
                          cityToken: "Q6106", point: laurelhurst, findRadiusMetres: 250, tier: .generic(.park)),
            AtlasLandmark(token: "testTower", englishName: "Test Tower", spanishName: "Torre de prueba",
                          cityToken: "Q6106", point: laurelhurst.offset(east: 2_000, north: 0), findRadiusMetres: 100,
                          tier: .generic(.tower))
        ])
    }

    // MARK: The bundled list

    /// The bundled file decodes; ids are unique; radii are in range; the famous tier is the three drawn plus the
    /// Colosseum (owner 2026-10-29), which the map draws as a stadium until its own art lands.
    @Test func theBundledListDecodesAndKeepsItsRules() throws {
        let list = try WorldLandmarks(data: Self.bundled("WorldLandmarks", "json"))
        #expect(list.all.count >= 60 && list.all.count <= WorldLandmarks.maxLandmarks)
        #expect(Set(list.all.map(\.token)).count == list.all.count, "ids are unique")
        #expect(list.all.allSatisfy { WorldLandmarks.radiusRange.contains($0.findRadiusMetres) })
        var arts: [String] = []
        for landmark in list.all {
            if case .famous(let art) = landmark.tier { arts.append(art) }
        }
        #expect(Set(arts) == WorldLandmarks.famousArtIDs, "every famous art id is used, each by one landmark")
        #expect(arts.count == 28 && Set(arts).count == arts.count, "4 drawn and the owner's 24 more")
        let colosseum = try #require(list.landmark(token: "colosseum"))
        #expect(colosseum.tier.drawable == .famous(artID: "colosseum"), "the Colosseum's art is approved")
        let bigBen = try #require(list.landmark(token: "bigBen"))
        #expect(bigBen.tier == .famous(artID: "bigben") && bigBen.tier.drawable == .famous(artID: "bigben"),
                "the 24 more are drawn too")
        #expect(list.landmark(token: "eiffelTower")?.tier.drawable == .famous(artID: "eiffel"))
        #expect(WorldLandmarks.drawnArtIDs.isDisjoint(with: WorldLandmarks.placeholderArtIDs.keys))
        #expect(WorldLandmarks.drawnArtIDs.count == 28 && WorldLandmarks.placeholderArtIDs.isEmpty)
        #expect(list.landmark(token: "eiffelTower")?.cityToken == "Q90")
        #expect(list.landmark(token: "empireStateBuilding")?.cityToken == "Q60")
        #expect(list.landmark(token: "sydneyOperaHouse")?.cityToken == "Q3130")
        let portland = list.landmarks(inCity: "Q6106").map(\.token)
        #expect(portland.count == 6 && portland.contains("laurelhurstPark") && portland.contains("tilikumCrossing"))
    }

    /// Every city token is a city of the SHIPPED pack; every landmark lies within 30 km of its city's point and
    /// in its city's country (the country under it, or, where the pack's 1:10m coast puts it on water, the one
    /// country within 2 km of it).
    @Test func everyLandmarkSitsInItsCityInTheShippedPack() throws {
        let atlas = try WorldAtlas(data: Self.bundled("WorldAtlas", "pack"))
        let list = try WorldLandmarks(data: Self.bundled("WorldLandmarks", "json"))
        for landmark in list.all {
            let city = try #require(atlas.city(token: landmark.cityToken), "\(landmark.token): no city")
            let reach = Self.awaySites.contains(landmark.token) ? 100_000.0 : 30_000.0
            #expect(landmark.point.distance(to: city.point) <= reach, "\(landmark.token) is far from its city")
            #expect(Self.country(near: landmark.point, in: atlas) == city.countryCode, "\(landmark.token)'s country")
            let resolved = atlas.city(at: landmark.point)?.token
            #expect(resolved == landmark.cityToken || Self.citedElsewhere.contains(landmark.token),
                    "\(landmark.token): the city rule names \(resolved ?? "no city")")
        }
        #expect(atlas.city(token: "Q6106")?.names.english == "Portland")
        #expect(atlas.country(code: "VA")?.countsInPassport == true && atlas.country(code: "ZZ") == nil)
        let sea = try #require(atlas.visit(at: GeoPoint(43.6950, 7.2650)).sea)
        #expect(atlas.sea(token: sea.token) == sea && atlas.sea(token: "nowhere") == nil)
    }

    // MARK: The find rule

    /// A fix inside the radius finds it, one outside does not; the distance is measured the short way round the
    /// antimeridian; an invalid fix finds nothing.
    @Test func foundInsideTheRadiusAndNotOutside() throws {
        let list = try Self.smallList()
        #expect(list.found(at: Self.laurelhurst.offset(east: 0, north: 240)).map(\.token) == ["laurelhurstPark"])
        #expect(list.found(at: Self.laurelhurst.offset(east: 0, north: 260)).isEmpty)
        #expect(list.found(at: GeoPoint(.nan, 0)).isEmpty)
        let dateLine = AtlasLandmark(token: "dateLine", englishName: "Date Line", spanishName: "Línea de cambio",
                                     cityToken: "ne:1", point: GeoPoint(0, 179.9995), findRadiusMetres: 200,
                                     tier: .generic(.lighthouse))
        #expect(dateLine.isFound(by: GeoPoint(0, -179.9995)), "about 111 m across the antimeridian")
        let near = list.landmarks(near: Self.laurelhurst, withinMetres: 5_000).map(\.token)
        #expect(near == ["laurelhurstPark", "testTower"])
        #expect(list.landmarks(near: Self.laurelhurst, withinMetres: 1_000).map(\.token) == ["laurelhurstPark"])
        #expect(list.landmarks(near: Self.laurelhurst, withinMetres: -1).isEmpty)
    }

    /// A fix finds a landmark once: the passport records it once, in the fixed order (after the city, before
    /// the terrain); the city card's count follows; a visit naming it twice records it once.
    @Test func aFixFindsItOnceInTheFixedOrder() throws {
        let list = try Self.smallList()
        let resolver = AtlasWithLandmarks(atlas: PortlandAtlas(), landmarks: list)
        var book = PassportBook()
        let first = book.record(resolver.visit(at: Self.laurelhurst), at: Self.t1)
        #expect(first.map(\.kind) == [.country, .continent, .city, .landmark, .terrain])
        #expect(first.first { $0.kind == .landmark }?.token == "laurelhurstPark")
        #expect(book.record(resolver.visit(at: Self.laurelhurst.offset(east: 100, north: 0)), at: Self.t2).isEmpty)
        #expect(book.firstVisit(.landmark, token: "laurelhurstPark") == Self.t1)
        let park = try #require(list.landmark(token: "laurelhurstPark"))
        let tower = try #require(list.landmark(token: "testTower"))
        #expect(book.isFound(park) && !book.isFound(tower))
        #expect(book.foundLandmarkCount(inCity: "Q6106", of: list) == 1 && list.landmarks(inCity: "Q6106").count == 2)
        let twice = AtlasVisit(terrain: .temperateForest, landmarks: ["testTower", "testTower", "Not A Token"])
        #expect(book.record(twice, at: Self.t2).map(\.token) == ["testTower"])
        #expect(try PassportBook(data: book.encoded()) == book, "landmarks round-trip in the passport's bytes")
        #expect(PassportBook.cap(for: .landmark) == 5_000)
    }

    /// Through the keeper: a fix within the radius records the landmark and announces it once with kind
    /// `landmark`; a later fix inside the same radius announces nothing more.
    @Test func theKeeperAnnouncesALandmarkOnce() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let list = try Self.smallList()
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { PortlandAtlas() }, openLandmarks: { list })
        #expect(keeper.landmarks.all.count == 2)
        let stream = keeper.discoveries()
        keeper.observe(point: Self.laurelhurst, at: Self.t1)
        keeper.observe(point: Self.laurelhurst.offset(east: 120, north: 0), at: Self.t2)
        keeper.endDiscoveries()
        var heard: [AtlasDiscovery] = []
        for await discovery in stream.prefix(32) { heard.append(discovery) }
        #expect(heard.filter { $0.kind == .landmark }.map(\.token) == ["laurelhurstPark"])
        let park = try #require(list.landmark(token: "laurelhurstPark"))
        #expect(keeper.isFound(park))
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(reopened.book.discoveries(of: .landmark) == 1, "the landmark is sealed in the passport")
    }

    /// A decoy records nothing and finds nothing; the grey list itself is still there to draw.
    @Test func aDecoyRecordsNoLandmark() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let list = try Self.smallList()
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { PortlandAtlas() }, openLandmarks: { list })
        keeper.setDecoy(true)
        keeper.observe(point: Self.laurelhurst, at: Self.t1)
        let park = try #require(list.landmark(token: "laurelhurstPark"))
        #expect(!keeper.isFound(park) && keeper.book.isEmpty)
        #expect(keeper.landmarks.all.count == 2, "the public list is still drawn grey")
        keeper.setDecoy(false)
        #expect(!keeper.isFound(park))
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(reopened.book.discoveries(of: .landmark) == 0, "the decoy's fix was never written")
    }

    /// A missing landmark file means no landmarks (the atlas still works); a malformed one too.
    @Test func aMissingOrMalformedFileMeansNoLandmarks() throws {
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("NoLandmarks-\(UUID().uuidString)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Landmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: none)
            try? FileManager.default.removeItem(at: folder)
        }
        let empty = try #require(Bundle(url: none))
        #expect(WorldAtlasKeeper.bundledLandmarks(in: empty)().isEmpty, "no file, no landmarks")
        let malformed = Data("{\"version\": 1, \"landmarks\": [{}]}".utf8)
        try malformed.write(to: folder.appendingPathComponent("WorldLandmarks.json"))
        let bundle = try #require(Bundle(url: folder))
        #expect(WorldAtlasKeeper.bundledLandmarks(in: bundle)().isEmpty, "a malformed file, no landmarks")
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { PortlandAtlas() },
                                      openLandmarks: WorldAtlasKeeper.bundledLandmarks(in: bundle))
        keeper.observe(point: Self.laurelhurst, at: Self.t1)
        #expect(keeper.book.discoveries(of: .city) == 1 && keeper.book.discoveries(of: .landmark) == 0)
    }

    // MARK: Refusals

    /// Every malformed file is refused whole.
    @Test func malformedFilesAreRefused() throws {
        let good = Self.entry()
        #expect(Self.refusal([good]) == nil)
        var missing = good
        missing["es"] = nil
        #expect(Self.refusal([missing]) == .malformed)
        var both = good
        both["art"] = "eiffel"
        #expect(Self.refusal([both]) == .badTier("testPark"))
        var neither = good
        neither["kind"] = nil
        #expect(Self.refusal([neither]) == .badTier("testPark"))
        #expect(Self.refusal([Self.entry(["kind": "volcano"])]) == .badTier("testPark"))
        #expect(Self.refusal([Self.entry(["kind": nil, "art": "louvre"])]) == .badTier("testPark"))
        #expect(Self.refusal([Self.entry(["radius": 49])]) == .badRadius("testPark"))
        #expect(Self.refusal([Self.entry(["radius": 601])]) == .badRadius("testPark"))
        #expect(Self.refusal([Self.entry(["lat": 91])]) == .badPoint("testPark"))
        #expect(Self.refusal([Self.entry(["id": "Test Park"])]) == .badToken("Test Park"))
        #expect(Self.refusal([Self.entry(["en": ""])]) == .badName("testPark"))
        #expect(Self.refusal([Self.entry(["city": "Q 1"])]) == .badCity("testPark"))
        #expect(Self.refusal([Self.entry(["knd": "park"])]) == .unknownKey("knd"))
        #expect(Self.refusal([good, good]) == .duplicateToken("testPark"))
        #expect(Self.refusal([good], version: 2) == .unsupportedVersion(2))
        let overCap = (0...WorldLandmarks.maxLandmarks).map { Self.entry(["id": "p\($0)"]) }
        #expect(Self.refusal(overCap) == .overCap)
        #expect(Self.refusal(Array(overCap.dropLast())) == nil, "exactly the cap is kept")
        #expect(Self.error(Data(count: WorldLandmarks.maxFileBytes + 1)) == .tooLarge)
        #expect(Self.error(Data("not json".utf8)) == .malformed)
    }

    // MARK: Helpers

    /// A good entry with `changes` applied (a nil value removes the key).
    static func entry(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var entry: [String: Any] = ["id": "testPark", "en": "Test Park", "es": "Parque de prueba", "city": "Q6106",
                                    "lat": 45.52, "lon": -122.62, "radius": 250, "kind": "park"]
        for (key, value) in changes { entry[key] = value }
        return entry
    }

    /// The refusal a file of `entries` raises, or nil when it is read.
    static func refusal(_ entries: [[String: Any]], version: Int = 1) -> WorldLandmarks.LandmarkError? {
        let object: [String: Any] = ["version": version, "landmarks": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return .malformed }
        return error(data)
    }

    /// The refusal `data` raises, or nil when it is read.
    static func error(_ data: Data) -> WorldLandmarks.LandmarkError? {
        do {
            _ = try WorldLandmarks(data: data)
            return nil
        } catch let error as WorldLandmarks.LandmarkError {
            return error
        } catch {
            return .malformed
        }
    }

    /// The landmarks whose own fix the city rule does not put in their listed city (checked 2026-10-29): Portland
    /// Head Light (Cape Elizabeth, 6 km from Portland, Maine's point), the Tower of Hercules (6 km from A
    /// Coruña's point) and Tsing Ma Bridge (12 km from Hong Kong's) lie outside every urban boundary and past
    /// the core. (Castel Sant'Angelo is Rome's since the city rule counts only the fix's own country's cities.)
    /// Every other landmark resolves to its own city.
    static let citedElsewhere: Set<String> = ["portlandHeadLight", "towerOfHercules", "tsingMaBridge", "angkorWat",
                                              "greatWallBadaling", "machuPicchu", "chichenItza", "petra"]

    /// Famous sites away from any city (spec: "sites away from a city are found the same way"), kept with the
    /// nearest city a traveller would name: Badaling with Beijing (60 km), Machu Picchu with Cusco (75 km),
    /// Chichén Itzá with Valladolid (38 km), Petra with Ma'an (31 km; Wadi Musa is not in the pack). Angkor Wat
    /// sits 5 km from Siem Reap's point, past its core.
    static let awaySites: Set<String> = ["greatWallBadaling", "machuPicchu", "chichenItza", "petra"]

    /// The country under `point`, else the single country found within 2 km of it (nil for none or several).
    static func country(near point: GeoPoint, in atlas: WorldAtlas) -> String? {
        if let code = atlas.country(at: point)?.code { return code }
        var codes = Set<String>()
        for metres in [250.0, 500, 1_000, 2_000] where codes.isEmpty {
            for step in 0..<16 {
                let angle = Double(step) * .pi / 8
                let probe = point.offset(east: metres * cos(angle), north: metres * sin(angle))
                if let code = atlas.country(at: probe)?.code { codes.insert(code) }
            }
        }
        return codes.count == 1 ? codes.first : nil
    }

    /// The app bundle's resource `name`.`ext`.
    static func bundled(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.main.url(forResource: name, withExtension: ext)))
    }
}
