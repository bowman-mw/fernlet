import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The landmark art (World-Exploration-Spec §2, the design session's `World-Landmark-Art.json`): the bundled
/// file loads, every sprite matches its size with palette indices in range, every art id the landmark list
/// names and every generic kind has a sprite, and a broken file is refused.
@MainActor
struct WorldLandmarkArtTests {
    /// The bundled art file's bytes.
    static func bundledArt() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: WorldLandmarkArtLoader.resource,
                                               withExtension: WorldLandmarkArtLoader.fileExtension))
        return try Data(contentsOf: url)
    }

    /// The sizes the design session drew (famous art at 3 points a pixel, generic icons at 3.5).
    static let sizes: [String: (Int, Int)] = [
        "eiffel": (17, 26), "empire": (13, 28), "opera": (27, 13), "colosseum": (30, 17),
        "park": (16, 11), "bridge": (16, 12), "lighthouse": (12, 16), "stadium": (16, 9), "castle": (17, 9),
        "tower": (13, 14),
    ]

    @Test func theBundledArtLoadsWithItsSizesAndPaletteInRange() throws {
        let art = try #require(WorldLandmarkArtLoader.bundled())
        #expect(art.famousScale == 3 && art.genericScale == 3.5)
        #expect(art.letters[Int(art.outlineIndex)] == WorldLandmarkArt.outlineLetter)
        let all = art.famous.map { ($0.key, $0.value) } + art.generic.map { ($0.key.rawValue, $0.value) }
        #expect(art.famous.count == 28 && art.generic.count == 6)
        for (id, sprite) in all {
            if let size = Self.sizes[id] {
                #expect(sprite.width == size.0 && sprite.height == size.1, "\(id) is \(size.0) × \(size.1)")
            }
            #expect((1...WorldLandmarkArt.maxSide).contains(sprite.width) && (1...WorldLandmarkArt.maxSide).contains(sprite.height))
            #expect(sprite.pixels.count == sprite.height && sprite.pixels.allSatisfy { $0.count == sprite.width })
            let used = sprite.pixels.flatMap { $0 }.filter { $0 != LandmarkSprite.clear }
            #expect(!used.isEmpty && used.allSatisfy { Int($0) < art.colours.count }, "\(id)'s pixels are in the palette")
        }
    }

    @Test func everyArtIDAndEveryKindHasASprite() throws {
        let art = try #require(WorldLandmarkArtLoader.bundled())
        for artID in WorldLandmarks.drawnArtIDs {
            #expect(art.famous[artID] != nil, "drawn art id \(artID) has a sprite")
        }
        for kind in AtlasLandmarkKind.allCases {
            #expect(art.generic[kind] != nil, "\(kind.rawValue) has an icon")
        }
        let list = try WorldLandmarks(data: Self.bundledList())
        for landmark in list.all {
            #expect(art.sprite(for: landmark) != nil, "\(landmark.token) draws")
        }
        let colosseum = try #require(list.landmark(token: "colosseum"))
        // The Colosseum's art and the 24 more are approved (2026-10-29): each famous landmark draws its own.
        #expect(art.sprite(for: colosseum) == art.famous["colosseum"])
        let bigBen = try #require(list.landmark(token: "bigBen"))
        #expect(art.sprite(for: bigBen) == art.famous["bigben"])
        for landmark in list.all {
            if case .famous(let artID) = landmark.tier {
                #expect(art.sprite(for: landmark) == art.famous[artID], "\(landmark.token) draws its own art")
            }
        }
        let eiffel = try #require(list.landmark(token: "eiffelTower"))
        #expect(art.sprite(for: eiffel) == art.famous["eiffel"])
    }

    @Test func theNotFoundGreysAndHalosAreTheSpecs() throws {
        let art = try #require(WorldLandmarkArtLoader.bundled())
        #expect(art.notFoundOutline.light == LandmarkArtColour(hex: "#7E878C"))
        #expect(art.notFoundFill.light == LandmarkArtColour(hex: "#C3C9CC"))
        #expect(art.notFoundOutline.dark == LandmarkArtColour(hex: "#A7AFB4"))
        #expect(art.notFoundFill.dark == LandmarkArtColour(hex: "#5E676D"))
        #expect(art.notFoundHalo.light == LandmarkArtColour(hex: "#F4F1EA"))
        #expect(art.notFoundHalo.dark == LandmarkArtColour(hex: "#8B9398"))
        #expect(art.foundHalo.light == LandmarkArtColour(hex: "#FFF6E2"))
        #expect(art.foundHalo.dark == LandmarkArtColour(hex: "#F3E6C8"))
    }

    @Test func aBrokenFileIsRefused() throws {
        let good = try Self.bundledArt()
        let object = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        func refused(_ change: (inout [String: Any]) -> Void) throws -> WorldLandmarkArt.ArtError? {
            var copy = object
            change(&copy)
            do {
                _ = try WorldLandmarkArt(data: JSONSerialization.data(withJSONObject: copy))
                return nil
            } catch let error as WorldLandmarkArt.ArtError {
                return error
            }
        }
        #expect(try refused { $0["version"] = 2 } == .unsupportedVersion(2))
        #expect(try refused { file in
            var palette = file["palette"] as? [String: String] ?? [:]
            palette["k"] = "brown"
            file["palette"] = palette
        } == .badPalette("k"))
        #expect(try refused { file in
            var generic = file["generic"] as? [String: Any] ?? [:]
            var park = generic["park"] as? [String: Any] ?? [:]
            park["size"] = [15, 11]
            generic["park"] = park
            file["generic"] = generic
        } == .badSprite("park"))
        #expect(try refused { file in
            var generic = file["generic"] as? [String: Any] ?? [:]
            generic["fountain"] = generic["park"]
            file["generic"] = generic
        } == .unknownKind("fountain"))
        #expect((try? WorldLandmarkArt(data: Data("{}".utf8))) == nil)
        #expect(LandmarkArtColour(hex: "#12345") == nil && LandmarkArtColour(hex: "#12345G") == nil)
        #expect(LandmarkArtColour(hex: "#4A2E1C") != nil)
    }

    /// The bundled landmark list's bytes.
    static func bundledList() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldLandmarks", withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
