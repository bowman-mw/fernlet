import Foundation
import SwiftUI
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// The map widget on the tinted and clear Home Screens (phone test W-11, `ref-tint-map` draft 2 and
/// `ref-tint-map-light`, approved): the app's one-colour drawing rides in the picture file as an optional
/// third PNG, its faint scene keeps streets, parks and water and nothing of blocks, buildings or names, the
/// unexplored ring is outlines with no fill, Sprout's clear ring is the 8-neighbour dilation of its cells,
/// and the widget draws the drawing instead of greying out the colour picture.
@MainActor
struct WidgetMapMonoTests {
    nonisolated private static let here = GeoPoint(45.5205, -122.6255)
    nonisolated private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A picture the size rules accept, with or without the one-colour drawing.
    static func picture(mono: Data? = nil) -> WorldWidgetMapPicture {
        WorldWidgetMapPicture(version: WorldWidgetMapPicture.currentVersion, takenAt: now,
                              light: Data(repeating: 1, count: 64), dark: Data(repeating: 2, count: 64), mono: mono)
    }

    /// The property list's top-level keys for `picture`.
    static func keys(_ picture: WorldWidgetMapPicture) throws -> Set<String> {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try PropertyListSerialization.propertyList(from: encoder.encode(picture), format: nil)
        return Set((plist as? [String: Any])?.keys.map { $0 } ?? [])
    }

    // MARK: The file

    /// The drawing travels under its own key and comes back whole; a file written before it (no key)
    /// still decodes, with none; the widget's twin declares it optional.
    @Test func theMonoKeyRoundTripsAndAnOldFileStillDecodes() throws {
        let mono = Data(repeating: 3, count: 32)
        #expect(try Self.keys(Self.picture(mono: mono)) == ["version", "takenAt", "light", "dark", "mono"])
        #expect(try Self.keys(Self.picture()) == ["version", "takenAt", "light", "dark"], "no drawing, no key")
        let file = WorldWidgetMapFile(directory: uniqueAppGroupDirectory())
        #expect(file.write(Self.picture(mono: mono)))
        #expect(file.read()?.mono == mono)
        let old: [String: Any] = ["version": 1, "takenAt": Self.now, "light": Data([1]), "dark": Data([2])]
        let oldData = try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(WorldWidgetMapPicture.self, from: oldData)
        #expect(decoded.mono == nil && decoded.light == Data([1]))
        let widget = try RepoRoot.source("App/FernletWidgets/WidgetMapPicture.swift")
        #expect(widget.contains("var mono: Data?"), "the widget's twin lost the optional drawing")
    }

    /// An empty drawing isn't written, and the three pictures together stay under the file's cap.
    @Test func theDrawingCountsTowardTheCap() {
        let file = WorldWidgetMapFile(directory: uniqueAppGroupDirectory())
        #expect(!file.write(Self.picture(mono: Data())))
        #expect(!file.write(Self.picture(mono: Data(count: WorldWidgetMap.maxBytes - 100))))
        #expect(!file.exists)
    }

    // MARK: The scene

    /// Colours sampled from real snapshots of Apple's light muted map: a road, a park's path, a park and
    /// water keep their shares; a block, a building and label text keep nothing.
    @Test func theColourClassesKeepStreetsParksAndWaterOnly() {
        let alpha = { (red: Int, green: Int, blue: Int) in WorldWidgetMonoInk.alpha(red: red, green: green, blue: blue) }
        #expect(alpha(255, 255, 255) == WorldWidgetMonoInk.street, "a road")
        #expect(alpha(239, 238, 230) == WorldWidgetMonoInk.street, "a park's path")
        #expect(alpha(228, 239, 220) == WorldWidgetMonoInk.park, "a park")
        #expect(alpha(189, 232, 249) == WorldWidgetMonoInk.water, "water")
        #expect(alpha(179, 223, 244) == WorldWidgetMonoInk.water, "a lake's name melts into the lake")
        #expect(alpha(248, 248, 242) == 0, "a block")
        #expect(alpha(242, 241, 239) == 0, "a building")
        #expect(alpha(153, 150, 148) == 0, "a street's name")
        #expect(WorldWidgetMonoInk.creditAlpha(red: 99, green: 99, blue: 97) == 1, "Apple's logo keeps its shape")
        #expect(WorldWidgetMonoInk.creditAlpha(red: 248, green: 248, blue: 242) == 0)
        #expect((0.25...0.26).contains(WorldWidgetMonoInk.street) && (0.06...0.10).contains(WorldWidgetMonoInk.park))
        #expect((0.15...0.17).contains(WorldWidgetMonoInk.hexOutline))
    }

    /// A street's name (a gap in the road narrower than the closing square) fills, and the road's straight
    /// edge stays where it was.
    @Test func aStreetClosesOverItsName() {
        let width = 20, height = 14
        var mask = [Bool](repeating: false, count: width * height)
        for y in 4..<9 { for x in 0..<width { mask[y * width + x] = true } }
        for x in 8..<11 { mask[6 * width + x] = false }
        let closed = WorldWidgetMonoInk.closed(mask, width: width, height: height, radius: 2)
        #expect(closed[6 * width + 9], "the letters take the street's share")
        #expect(!closed[3 * width + 9] && !closed[9 * width + 9], "the edges don't grow")
        #expect(closed[4 * width + 0] && closed[8 * width + 19], "nor wear away at the picture's sides")
        #expect(closed.filter { $0 }.count == 5 * width, "the road, whole, and nothing else")
    }

    // MARK: The drawing

    /// The unexplored ring is outlines alone: on a map with nothing to keep, the corners (all ring) are
    /// mostly clear with faint lines, and the middle is clear.
    @Test func theHexOutlinesHaveNoFill() throws {
        let size = WorldWidgetMap.pictureSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = WorldWidgetMap.pictureScale
        let base = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let viewport = MapViewport.around(Self.here, heightMetres: Double(size.height) * WorldWidgetMap.metresPerPoint, size: size)
        let png = try #require(WorldWidgetMonoCanvas.png(base: base, viewport: viewport, content: .empty, size: size,
                                                          scale: WorldWidgetMap.pictureScale))
        let image = try #require(UIImage(data: png)?.cgImage)
        let bytes = try #require(Self.rgba(image))
        let alphaAt = { (x: Int, y: Int) -> UInt8 in bytes[(y * image.width + x) * 4 + 3] }
        var lit = 0, brightest: UInt8 = 0
        for y in 0..<150 {
            for x in 0..<150 where alphaAt(x, y) > 0 {
                lit += 1
                brightest = max(brightest, alphaAt(x, y))
            }
        }
        #expect(lit > 0, "the ring's outlines are drawn")
        #expect(lit < 150 * 150 / 2, "and never filled")
        #expect(brightest <= 60, "faint: about 16% white")
        #expect(alphaAt(image.width / 2, image.height / 2) == 0, "the middle is clear")
    }

    /// `image`'s pixels as 8-bit premultiplied RGBA rows with no padding.
    static func rgba(_ image: CGImage) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let drawn = context.makeImage(), let data = drawn.dataProvider?.data as Data? else { return nil }
        return [UInt8](data)
    }

    /// Sprout's clear ring is its cells dilated by one in all eight directions, on a grid one larger on
    /// every side; the app's and the widget's copies are one text.
    @Test func theClearRingIsTheEightNeighbourDilation() throws {
        // A 4 × 3 grid: one cell at (1, 1), one at the corner (3, 0).
        let painted = [false, false, false, true,
                       false, true, false, false,
                       false, false, false, false]
        let ring = MapClearRing.ring(painted: painted, width: 4, height: 3)
        #expect(ring.count == 6 * 5)
        var expected = [Bool](repeating: false, count: 6 * 5)
        for (cx, cy) in [(1, 1), (3, 0)] {
            for dy in -1...1 { for dx in -1...1 { expected[(cy + 1 + dy) * 6 + cx + 1 + dx] = true } }
        }
        #expect(ring == expected)
        #expect(MapClearRing.ring(painted: [true], width: 2, height: 1).isEmpty, "a grid of the wrong size")
        let app = try RepoRoot.source("App/Fernlet/World/Widget/WorldWidgetMonoMap.swift")
        let widget = try RepoRoot.source("App/FernletWidgets/MapWidgetMono.swift")
        let appTwin = try #require(Self.twin(in: app)), widgetTwin = try #require(Self.twin(in: widget))
        #expect(appTwin == widgetTwin, "the widget's clear ring drifted from the app's: copy the twin region over")
        #expect(widget.contains("grid.frameColor(x: x, y: y) != nil"), "the ring is of every painted cell, the face's too")
    }

    /// The source between the clear ring's twin markers, or nil.
    static func twin(in source: String) -> String? {
        guard let start = source.range(of: "// MARK: - Clear ring twin: begin"),
              let end = source.range(of: "// MARK: - Clear ring twin: end"), start.upperBound <= end.lowerBound else { return nil }
        return String(source[start.upperBound..<end.lowerBound])
    }

    // MARK: The widget

    /// In one colour the ground draws the drawing, never the colour picture greyed out, and the map is
    /// punched out under Sprout, the plate and the tag; the app draws the drawing from the light map it
    /// already has.
    @Test func theMonoGroundDrawsTheDrawingNotADesaturatedPicture() throws {
        let views = try RepoRoot.source("App/FernletWidgets/MapWidgetViews.swift")
        #expect(!views.contains(".widgetAccentedRenderingMode(.desaturated)"))
        #expect(views.contains("if mono { return map.mono }"))
        #expect(views.contains("MapWidgetHoleMask(holes: mono ?"))
        for hole in [".mapWidgetHole(.companion)", ".mapWidgetHole(.rounded(cornerRadius: MapWidgetPlate.cornerRadius))",
                     ".mapWidgetHole(.rounded(cornerRadius: MapWidgetTag.cornerRadius))"] {
            #expect(views.contains(hole), "no hole: \(hole)")
        }
        let writer = try RepoRoot.source("App/Fernlet/World/Widget/WorldWidgetMapWriter.swift")
        #expect(writer.contains("WorldWidgetMonoCanvas.png(base: lightBase"))
        #expect(writer.components(separatedBy: "AppleMapSnapshot.image(").count == 3, "still two requests to Apple, no third")
    }
}
