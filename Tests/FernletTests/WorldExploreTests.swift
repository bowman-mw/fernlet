import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Home's cities and landmarks (World-Exploration-Spec §2: `ex-zoomed`, `ex-landmark`, `ex-city-card`,
/// `ex-city-view`): the landmark art's colours found and not found in light and dark with its halo, the words
/// (VoiceOver, the cards, the plate), which landmarks and cities are drawn near the view and when the view counts as
/// zoomed out, the city view's city, the size classes, the uncovered share, and the seam for Sprout's landmark line.
@MainActor
struct WorldExploreTests {
    /// The shipped atlas, opened once for the suite's tests that need real cities.
    static func shippedAtlas() throws -> WorldAtlas {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        return try WorldAtlas(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// The shipped landmark list.
    static func shippedLandmarks() throws -> WorldLandmarks {
        let url = try #require(Bundle.main.url(forResource: WorldAtlasKeeper.landmarksResource,
                                               withExtension: WorldAtlasKeeper.landmarksExtension))
        return try WorldLandmarks(data: Data(contentsOf: url))
    }

    static let portland = GeoPoint(45.5152, -122.6784)
    static let laurelhurst = GeoPoint(45.5206, -122.6253)
    static let phone = CGSize(width: 402, height: 874)

    /// Home's viewport at camera height `distance` over `centre` on an iPhone 17.
    static func viewport(_ centre: GeoPoint, distance: Double) -> MapViewport {
        MapViewport.around(centre, heightMetres: distance * PlainBaseMap.heightPerDistance, size: phone)
    }

    /// A passport holding `landmarks` (found at `date`) and `cities`.
    static func book(landmarks: [String] = [], cities: [String] = [], at date: Date = Date()) throws -> PassportBook {
        try PassportBook(discoveries: landmarks.map { AtlasDiscovery(kind: .landmark, token: $0, at: date) }
                         + cities.map { AtlasDiscovery(kind: .city, token: $0, at: date) })
    }

    // MARK: The art's colours

    @Test func foundArtTakesThePaletteAndTheFoundHalo() throws {
        let art = try #require(WorldLandmarkArtLoader.bundled())
        let eiffel = try #require(art.famous["eiffel"])
        for dark in [false, true] {
            let grid = WorldLandmarkPixels.grid(eiffel, art: art, look: WorldLandmarkLook(found: true, dark: dark))
            #expect(grid.width == eiffel.width + 2 && grid.height == eiffel.height + 2)
            let halo: UInt32 = dark ? 0xF3E6C8 : 0xFFF6E2
            let used = Set(eiffel.pixels.flatMap { $0 }.filter { $0 != LandmarkSprite.clear }.map { WorldLandmarkPixels.hex(art.colours[Int($0)]) })
            let drawn = Set(grid.pixels.compactMap { $0 })
            #expect(drawn == used.union([halo]), "found art is its own palette plus the found halo (dark \(dark))")
            #expect(grid.colour(x: 0, y: 0) == nil, "the padded corner touches no art")
        }
    }

    @Test func artNotFoundIsGreyOutlineFillAndHaloInLightAndDark() throws {
        let art = try #require(WorldLandmarkArtLoader.bundled())
        let park = try #require(art.famous["eiffel"])
        let cases: [(dark: Bool, outline: UInt32, fill: UInt32, halo: UInt32)] = [
            (false, 0x7E878C, 0xC3C9CC, 0xF4F1EA), (true, 0xA7AFB4, 0x5E676D, 0x8B9398),
        ]
        for expected in cases {
            let grid = WorldLandmarkPixels.grid(park, art: art, look: WorldLandmarkLook(found: false, dark: expected.dark))
            #expect(Set(grid.pixels.compactMap { $0 }) == [expected.outline, expected.fill, expected.halo])
            for (y, row) in park.pixels.enumerated() {
                for (x, index) in row.enumerated() where index != LandmarkSprite.clear {
                    let want = index == art.outlineIndex ? expected.outline : expected.fill
                    #expect(grid.colour(x: x + 1, y: y + 1) == want)
                }
            }
        }
    }

    @Test func theHaloRingsEveryDrawnPixelAndNothingElse() throws {
        let art = try #require(WorldLandmarkArtLoader.bundled())
        let tower = try #require(art.generic[.tower])
        let grid = WorldLandmarkPixels.grid(tower, art: art, look: WorldLandmarkLook(found: true, dark: false))
        let drawn = { (x: Int, y: Int) -> Bool in
            tower.pixels.indices.contains(y) && tower.pixels[y].indices.contains(x) && tower.pixels[y][x] != LandmarkSprite.clear
        }
        for y in 0..<grid.height {
            for x in 0..<grid.width where !drawn(x - 1, y - 1) {
                let touches = (-1...1).contains { dy in (-1...1).contains { dx in drawn(x - 1 + dx, y - 1 + dy) } }
                #expect((grid.colour(x: x, y: y) == 0xFFF6E2) == touches, "halo at (\(x), \(y))")
            }
        }
        let bare = WorldLandmarkPixels.grid(tower, art: art, look: WorldLandmarkLook(found: true, dark: false, halo: false))
        #expect(bare.width == tower.width && !bare.pixels.contains(0xFFF6E2))
    }

    @Test func imagesAreMadeOncePerLookAtTheMapScales() throws {
        let landmarks = try Self.shippedLandmarks()
        let images = WorldLandmarkImages()
        let eiffel = try #require(landmarks.landmark(token: "eiffelTower"))
        let park = try #require(landmarks.landmark(token: "laurelhurstPark"))
        let first = try #require(images.image(for: eiffel, look: WorldLandmarkLook(found: false, dark: false)))
        #expect(first === images.image(for: eiffel, look: WorldLandmarkLook(found: false, dark: false)))
        #expect(first !== images.image(for: eiffel, look: WorldLandmarkLook(found: true, dark: false)))
        #expect(first.width == 19 && first.height == 28)
        #expect(images.mapScale(for: eiffel) == 3 && images.mapScale(for: park) == 3.5)
    }

    // MARK: The words

    @Test func voiceOverNamesOnlyFoundLandmarks() throws {
        let eiffel = try #require(try Self.shippedLandmarks().landmark(token: "eiffelTower"))
        #expect(WorldExploreCopy.spoken(eiffel, found: true, spanish: false) == "Eiffel Tower, landmark, found")
        #expect(WorldExploreCopy.spoken(eiffel, found: false, spanish: false) == "Landmark, not found yet")
        #expect(WorldExploreCopy.name(of: eiffel, spanish: true) == "Torre Eiffel")
    }

    @Test func theLandmarkCardSaysWhenAndWhere() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(DateComponents(calendar: calendar, year: 2026, month: 10, day: 29, hour: 15).date)
        let earlier = try #require(DateComponents(calendar: calendar, year: 2026, month: 10, day: 12, hour: 9).date)
        #expect(WorldExploreCopy.cardKind(city: "Portland") == "Landmark · Portland")
        #expect(WorldExploreCopy.cardKind(city: nil) == "Landmark")
        #expect(WorldExploreCopy.cardFound(on: now.addingTimeInterval(-3_600), city: "Portland", now: now, calendar: calendar)
                == "Found on your walk today. Your passport keeps it with Portland.")
        let other = WorldExploreCopy.cardFound(on: earlier, city: "Portland", now: now, calendar: calendar)
        #expect(other.hasPrefix("Found on your walk on ") && other.contains("12") && other.hasSuffix("Your passport keeps it with Portland."))
    }

    @Test func theCityCardRowsAndTheCityViewPlate() {
        #expect(WorldExploreCopy.landmarksFound(2, of: 6) == "2 of 6 found")
        #expect(WorldExploreCopy.uncovered(0.03) == "3% of the city")
        #expect(WorldExploreCopy.uncovered(0.004) == "Under 1% of the city")
        #expect(WorldExploreCopy.uncovered(0) == "0% of the city")
        #expect(WorldExploreCopy.uncovered(3) == "100% of the city")
        #expect(WorldExploreCopy.cityKind(sizeName: "City", country: "United States") == "City · United States")
        #expect(WorldExploreCopy.cityPlate(city: "Portland", found: 2, total: 6) == "Portland · 2 of 6 landmarks")
        #expect(WorldExploreCopy.cityPlate(city: "Astoria", found: 0, total: 0) == "Astoria")
        #expect(WorldExploreCopy.moreNotFound(4) == "4 more not found yet")
        #expect(WorldExploreCopy.cityMarkerSpoken(name: "Portland", sizeName: "City") == "Portland, City")
    }

    // MARK: What is drawn near the view

    @Test func homeZoomedOutAStepShowsTheCityMarkersAndHomeItselfDoesNot() {
        #expect(!WorldExploreSelection.isZoomedOut(Self.viewport(Self.portland, distance: 1_700)))
        #expect(WorldExploreSelection.isZoomedOut(Self.viewport(Self.portland, distance: 3_400)))
        #expect(!WorldExploreSelection.isZoomedOut(Self.viewport(Self.portland, distance: 600)))
        let distance = WorldExploreSelection.cameraDistance(of: Self.viewport(Self.portland, distance: 3_400))
        #expect(abs(distance - 3_400) < 1)
    }

    @Test func onlyLandmarksNearTheViewAreDrawn() throws {
        let list = try Self.shippedLandmarks()
        let near = WorldExploreSelection.landmarks(in: list, near: Self.viewport(Self.laurelhurst, distance: 1_700), size: Self.phone)
        let tokens = Set(near.map(\.token))
        #expect(tokens.contains("laurelhurstPark") && !tokens.contains("eiffelTower") && !tokens.contains("stJohnsBridge"))
        let wide = WorldExploreSelection.landmarks(in: list, near: Self.viewport(Self.portland, distance: 7_000), size: Self.phone)
        #expect(wide.count <= WorldExploreSelection.maxLandmarks && wide.contains { $0.token == "tilikumCrossing" })
        #expect(WorldExploreSelection.landmarks(in: .empty, near: Self.viewport(Self.portland, distance: 1_700), size: Self.phone).isEmpty)
    }

    @Test func aDecoysEmptyBookDrawsEveryLandmarkGrey() throws {
        let list = try Self.shippedLandmarks()
        let decoy = PassportBook()
        let found = try Self.book(landmarks: ["laurelhurstPark"])
        let park = try #require(list.landmark(token: "laurelhurstPark"))
        #expect(!decoy.isFound(park) && found.isFound(park))
        #expect(list.all.allSatisfy { !decoy.isFound($0) })
    }

    @Test func cityMarkersAreThePassportsCitiesNearTheView() throws {
        let atlas = try Self.shippedAtlas()
        let portland = try #require(atlas.city(at: Self.portland))
        let book = try Self.book(cities: [portland.token])
        let here = WorldExploreSelection.cities(in: book, atlas: atlas, near: Self.portland, withinMetres: 5_000)
        #expect(here.map(\.token) == [portland.token])
        #expect(WorldExploreSelection.cities(in: book, atlas: atlas, near: GeoPoint(48.8566, 2.3522), withinMetres: 5_000).isEmpty)
        #expect(WorldExploreSelection.cities(in: PassportBook(), atlas: atlas, near: Self.portland, withinMetres: 5_000).isEmpty)
    }

    @Test func everyLandmarksCityIsAnAtlasCity() throws {
        let atlas = try Self.shippedAtlas()
        let list = try Self.shippedLandmarks()
        let missing = Set(list.all.map(\.cityToken)).filter { atlas.city(token: $0) == nil }
        #expect(missing.isEmpty, "landmark cities the atlas lacks: \(missing.sorted())")
        let portland = try #require(atlas.city(token: "Q6106"))
        #expect(portland.names.english == "Portland")
    }

    @Test func homeZoomedOutDowntownSelectsPortlandsMarker() throws {
        let atlas = try Self.shippedAtlas()
        let portland = try #require(atlas.city(token: "Q6106"))
        let fix = Self.portland
        let viewport = Self.viewport(WorldMapHome.lookAt(fix, distance: 3_400), distance: 3_400)
        let reach = WorldExploreSelection.searchMetres(viewport, size: Self.phone)
        let cities = WorldExploreSelection.cities(in: try Self.book(cities: [portland.token]), atlas: atlas,
                                                  near: viewport.center, withinMetres: reach)
        #expect(cities.map(\.token) == [portland.token],
                "Portland's point \(portland.point) is \(Int(viewport.center.distance(to: portland.point))) m from the view's centre; reach \(Int(reach)) m")
    }

    @Test func theCityViewIsTheFoundCityUnderTheView() throws {
        let atlas = try Self.shippedAtlas()
        let portland = try #require(atlas.city(at: Self.portland))
        #expect(portland.names.english == "Portland")
        let book = try Self.book(cities: [portland.token])
        #expect(WorldExploreSelection.foundCity(at: Self.portland, atlas: atlas, book: book)?.token == portland.token)
        #expect(WorldExploreSelection.foundCity(at: Self.portland, atlas: atlas, book: PassportBook()) == nil)
        let memo = WorldExploreMemo()
        #expect(memo.foundCity(at: Self.portland, atlas: atlas, book: book)?.token == portland.token)
        #expect(memo.foundCity(at: Self.portland.offset(east: 40, north: 0), atlas: atlas, book: book)?.token == portland.token)
    }

    @Test func theMemoAnswersFromMemoryWhileTheViewStaysNear() throws {
        let list = try Self.shippedLandmarks()
        let memo = WorldExploreMemo()
        let first = memo.landmarks(in: list, near: Self.viewport(Self.laurelhurst, distance: 1_700), size: Self.phone)
        let nudged = memo.landmarks(in: list, near: Self.viewport(Self.laurelhurst.offset(east: 30, north: 0), distance: 1_700), size: Self.phone)
        #expect(first.map(\.token) == nudged.map(\.token))
        let paris = memo.landmarks(in: list, near: Self.viewport(GeoPoint(48.8584, 2.2945), distance: 1_700), size: Self.phone)
        #expect(paris.contains { $0.token == "eiffelTower" })
    }

    // MARK: Size classes

    @Test func fiveSizeClassesFromThePacksFour() throws {
        #expect(WorldCitySizeClass(size: .town, population: 15_000) == .village)
        #expect(WorldCitySizeClass(size: .town, population: 45_000) == .town)
        let atlas = try Self.shippedAtlas()
        let portland = try #require(atlas.city(at: Self.portland))
        // Natural Earth counts Portland's metro (over a million), so the pack sizes it large: a big city.
        #expect(WorldCitySizeClass(city: portland) == .bigCity)
        let tokyo = try #require(atlas.city(at: GeoPoint(35.6812, 139.7671)))
        #expect(WorldCitySizeClass(city: tokyo) == .megacity)
    }

    // MARK: Uncovered

    @Test func theUncoveredShareCountsLiftedCellsInsideTheCity() throws {
        let centre = GeoPoint(45.0, -122.0)
        let area = WorldCityUncovered.Area.core(centre: centre, metres: 2_000)
        #expect(WorldCityUncovered.share(of: area, lifted: []) == 0)
        let lifted = Set(MercatorHexGrid.disc(around: centre, radius: 500))
        let share = WorldCityUncovered.share(of: area, lifted: lifted)
        #expect(share > 0.04 && share < 0.09, "a 500 m disc is about 6% of a 2 km one: \(share)")
        let outside = Set(MercatorHexGrid.disc(around: centre.offset(east: 10_000, north: 0), radius: 500))
        #expect(WorldCityUncovered.share(of: area, lifted: outside) == 0)
        let atlas = try Self.shippedAtlas()
        let portland = try #require(atlas.city(at: Self.portland))
        let real = WorldCityUncovered.share(of: WorldCityUncovered.area(of: portland, in: atlas),
                                            lifted: Set(MercatorHexGrid.disc(around: Self.portland, radius: 500)))
        #expect(real > 0 && real < 0.05, "a downtown walk is a small part of Portland: \(real)")
    }

    // MARK: The seam for Sprout's landmark line

    @Test func aNewFindReachesTheSeamOnceAndOnlyWhenFresh() throws {
        let list = try Self.shippedLandmarks()
        let explore = WorldExploreState()
        var heard: [String] = []
        explore.onLandmarkFound = { heard.append($0.token) }
        let now = Date()
        explore.noteFinds(in: try Self.book(landmarks: ["laurelhurstPark"], at: now), list: list, isDecoy: false, now: now)
        #expect(heard.isEmpty, "the first look only remembers")
        explore.noteFinds(in: try Self.book(landmarks: ["laurelhurstPark", "tilikumCrossing"], at: now), list: list,
                          isDecoy: false, now: now)
        #expect(heard == ["tilikumCrossing"])
        let old = now.addingTimeInterval(-86_400)
        explore.noteFinds(in: try Self.book(landmarks: ["laurelhurstPark", "tilikumCrossing", "eiffelTower"], at: old),
                          list: list, isDecoy: false, now: now)
        #expect(heard == ["tilikumCrossing"], "a restored find from yesterday says nothing")
        explore.noteFinds(in: try Self.book(landmarks: ["laurelhurstPark", "tilikumCrossing", "eiffelTower", "colosseum"], at: now),
                          list: list, isDecoy: true, now: now)
        #expect(heard == ["tilikumCrossing"], "a decoy says nothing")
    }
}
