import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The World widgets' contract with the app (World Review Batch 4, approved 2026-10-24): what the
/// snapshot gains (a friend's gold hearts, the stamp book, the scarf), what a decoy keeps out of it,
/// and the art and rules the extension hand-copies from the app.
///
/// The extension links no FernletKit product and has no test target, so its half is read off disk
/// (`RepoRoot.source`), in the house style of `WidgetBridgeTests` and `WidgetRedesignTests`.
@MainActor
struct WidgetWorldTests {

    static let widgetRoot = "App/FernletWidgets/"

    // MARK: - Gold hearts

    /// Each gold heart fades twelve hours after a friend gave it in person; at most two show; an
    /// arrival in the future counts as just arrived; the ends come earliest first.
    @Test func goldHeartsFadeTwelveHoursAfterEachInPersonHeart() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let hour: TimeInterval = 3600
        let arrivals = [now - 1 * hour, now - 13 * hour, now - 2 * hour, now + 1 * hour]
        let ends = FernletStore.goldHeartEnds(arrivals: arrivals, at: now)
        #expect(ends == [now + 11 * hour, now + 12 * hour], "the two newest live hearts, the future one clamped to now")
        #expect(FernletStore.goldHeartEnds(arrivals: [now - 13 * hour], at: now).isEmpty, "a heart older than 12 hours is not gold")
        #expect(FernletStore.goldHeartEnds(arrivals: [], at: now).isEmpty)
    }

    // MARK: - Stamps

    /// The stamp book reaches the snapshot as tokens, days and moments only, oldest first.
    @Test func stampsReachTheSnapshotAsTokensAndDaysOldestFirst() {
        let early = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [
            SillyStampEntry(kind: .bananasForScale, dayKey: "2026-10-19", createdAt: early + 50),
            SillyStampEntry(kind: .bathtubIndex, dayKey: "2026-10-24", createdAt: early + 10),
            SillyStampEntry(kind: .cookiesPerDay, dayKey: "2026-10-19", createdAt: early)
        ]
        let moments = FernletStore.stampMoments(entries)
        #expect(moments.map(\.kindRaw) == ["cookiesPerDay", "bananasForScale", "bathtubIndex"])
        #expect(moments.map(\.dayKey) == ["2026-10-19", "2026-10-19", "2026-10-24"])
        #expect(moments.last?.earnedAt == early + 10)
        #expect(FernletStore.widgetStampLimit >= SillyStatKind.allCases.count, "the cap must hold every stamp there is")
    }

    /// A decoy shows and keeps nothing real: no gold hearts and no stamps reach the widget while one
    /// is open.
    @Test func aDecoyPublishesNoGoldHeartsAndNoStamps() {
        let store = makeTestStore()
        store.duressSessionActive = true
        #expect(store.widgetGoldHeartEnds().isEmpty)
        #expect(store.widgetStamps().isEmpty)
        store.duressSessionActive = false
    }

    /// The store publishes a friend's gold hearts and the stamp book with every snapshot.
    @Test func theStorePublishesTheGoldHeartsAndTheStamps() {
        let store = makeTestStore()
        let snapshot = store.currentWidgetSnapshot()
        #expect(snapshot.goldHeartEnds == store.widgetGoldHeartEnds())
        #expect(snapshot.stamps == store.widgetStamps())
    }

    // MARK: - The snapshot file

    /// The new fields travel under their own keys and come back whole; the widget's twin declares the
    /// same keys, so its decode (and its optimistic water bump's re-encode) keeps them.
    @Test func theNewFieldsRoundTripUnderTheirKeys() throws {
        var snapshot = WidgetSnapshot(companionStateRaw: "Okay", score: 0.6, bottleCount: 2, hydrationTarget: 4,
                                      macroSummary: .init(protein: 1, carbs: 1, fat: 1), dateKey: "2026-10-24",
                                      computedAt: Date(timeIntervalSince1970: 1_790_000_000))
        snapshot.goldHeartEnds = [Date(timeIntervalSince1970: 1_790_040_000)]
        snapshot.stamps = [.init(kindRaw: "bathtubIndex", dayKey: "2026-10-24", earnedAt: Date(timeIntervalSince1970: 1_790_000_100))]
        snapshot.companionLook = .init(bodyStyleRaw: "circle", bodyColorHex: nil, accessoryRaw: "sprout",
                                       accessoryColorHex: "#72A364", scarfColorHex: "#D9532F")
        let data = try WidgetBridgeFiles.makeEncoder().encode(snapshot)
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["\"goldHeartEnds\"", "\"stamps\"", "\"kindRaw\"", "\"dayKey\"", "\"earnedAt\"", "\"scarfColorHex\""] {
            #expect(json.contains(key), "the snapshot file lost \(key)")
        }
        #expect(try WidgetBridgeFiles.makeDecoder().decode(WidgetSnapshot.self, from: data) == snapshot)
        let widget = try RepoRoot.source(Self.widgetRoot + "WidgetSharedModels.swift")
        for field in ["var goldHeartEnds: [Date]? = nil", "var stamps: [StampMoment]? = nil", "var kindRaw: String",
                      "var dayKey: String", "var earnedAt: Date", "var scarfColorHex: String? = nil"] {
            #expect(widget.contains(field), "the widget twin lost `\(field)`")
        }
    }

    /// A file an older app wrote has none of the new keys and still decodes, with none of them.
    @Test func anOlderFileStillDecodes() throws {
        let legacy = """
        {"bottleCount":2,"companionStateRaw":"Okay","computedAt":"2026-09-20T12:00:00Z","dateKey":"2026-09-20",\
        "hydrationTarget":4,"macroSummary":{"carbs":1,"fat":1,"protein":1},"score":0.6,\
        "companionLook":{"accessoryRaw":"sprout","bodyStyleRaw":"circle"}}
        """
        let decoded = try WidgetBridgeFiles.makeDecoder().decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.goldHeartEnds == nil && decoded.stamps == nil && decoded.companionLook?.scarfColorHex == nil)
    }

    /// The scarf follows the map's rule: worn only with the scarf, in its slot's colour, or the
    /// design's red when the slot follows the state.
    @Test func theScarfFollowsTheMapsRule() {
        var appearance = CompanionAppearance()
        #expect(WidgetSnapshot.CompanionLook(appearance: appearance).scarfColorHex == nil)
        appearance.clothing = .scarf
        let map = WorldCompanionLook(appearance: appearance, state: .okay, asleep: false)
        let widget = WidgetSnapshot.CompanionLook(appearance: appearance)
        #expect(widget.scarfColorHex.flatMap { WorldCompanionLook.value($0) } == map.scarf)
        appearance.clothingCustomColorHex = "#123456"
        #expect(WidgetSnapshot.CompanionLook(appearance: appearance).scarfColorHex == "#123456")
    }

    // MARK: - The hand-copied art and rules

    /// Home's heart and drop, the bottle and the plus are copied key for key and colour for colour.
    @Test func theWidgetsSpritesAreTheApps() throws {
        let source = try RepoRoot.source(Self.widgetRoot + "WidgetPixelArt.swift")
        let pairs: [(String, WorldSprite)] = [("heart", WorldSprites.heart), ("drop", WorldSprites.drop),
                                              ("bottle", WorldSprites.bottle), ("plus", WorldSprites.plus)]
        for (name, sprite) in pairs {
            try Self.expect(source, declares: name, as: sprite)
        }
    }

    /// The nineteen stamps: the same frozen tokens in the same order, the app's names, and the app's art.
    @Test func theStampWidgetsKindsNamesAndArtAreTheApps() throws {
        let source = try RepoRoot.source(Self.widgetRoot + "WidgetStampArt.swift")
        let english = Locale(identifier: "en")
        for kind in SillyStatKind.allCases {
            #expect(source.contains("    case \(kind.rawValue)\n"), "the widget lost the \(kind.rawValue) token")
            let name = SillyStampCopy.name(for: kind, locale: english)
            #expect(source.contains("case .\(kind.rawValue): String(localized: \"\(name)\""), "\(kind.rawValue)'s name is not the app's (\(name))")
            let artName = try #require(Self.artName(for: kind, in: source), "\(kind.rawValue) has no art")
            try Self.expect(source, declares: artName, as: WorldStampArt.sprite(for: kind))
        }
        let declared = source.components(separatedBy: "\n").filter { $0.hasPrefix("    case ") && !$0.contains(":") }
        #expect(declared.count == SillyStatKind.allCases.count, "the widget knows \(declared.count) stamps, the app \(SillyStatKind.allCases.count)")
    }

    /// The pixel companion is the map's, word for word (phone test W-02, W-03, W-07): the painter
    /// between the twin markers is the app's with `WorldCompanionLook` spelled `WidgetPixelLook`, every
    /// other `WorldCompanion` spelled `WidgetCompanion` and no `nonisolated`, so every pixel test of
    /// the map's painter (`WorldCompanionWardrobeTests`) holds for the widget's too.
    @Test func thePixelCompanionIsTheMaps() throws {
        let widget = try RepoRoot.source(Self.widgetRoot + "WidgetPixelCompanion.swift")
        let app = try RepoRoot.source("App/Fernlet/World/Companion/WorldCompanionPainter.swift")
        let appTwin = try #require(Self.twin(in: app), "the app painter lost its twin markers")
            .replacingOccurrences(of: "WorldCompanionLook", with: "WidgetPixelLook")
            .replacingOccurrences(of: "WorldCompanion", with: "WidgetCompanion")
            .replacingOccurrences(of: "nonisolated ", with: "")
        let widgetTwin = try #require(Self.twin(in: widget), "the widget painter lost its twin markers")
        #expect(appTwin == widgetTwin, "the widget's painter drifted from the map's: copy the app's twin region over")
        #expect(appTwin.contains("static func paint(state: WidgetCompanionMood"), "the twin region holds the painter")
        #expect(widget.contains("typealias WidgetCompanionMood = WidgetCompanionState"))
        for state in [CompanionState.thriving, .okay, .tired, .resting, .sick] {
            let hex = String(format: "0x%06X", WorldCompanionLook.stateHex(state))
            #expect(widget.contains("case .\(state.rawValue.lowercased()): \(hex)"), "\(state)'s body colour drifted")
        }
        #expect(WidgetSnapshot.CompanionLook.scarfRed == String(format: "#%06X", WorldCompanionLook.scarfRed))
    }

    /// The source between the twin markers, or nil.
    static func twin(in source: String) -> String? {
        guard let start = source.range(of: "// MARK: - Twin: begin"),
              let end = source.range(of: "// MARK: - Twin: end"), start.upperBound <= end.lowerBound else { return nil }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The hearts and the water row follow Home's status plate: the same step math, at most two gold
    /// hearts, and the same eight-drop limit.
    @Test func theHeartsAndDropsAreHomes() throws {
        let widget = try RepoRoot.source(Self.widgetRoot + "WidgetHeartsAndDrops.swift")
        let app = try RepoRoot.source("App/Fernlet/World/WorldStatus.swift")
        #expect(widget.contains("Double(min(perHeart, max(0, steps - perHeart * index))) / Double(perHeart)"))
        #expect(app.contains("Double(min(perHeart, max(0, heartSteps - perHeart * index))) / Double(perHeart)"))
        #expect(widget.contains("static let maxGold = \(GoldHeartRules.maxActive)"))
        #expect(widget.contains("static let maxDrops = \(WorldStatus.maxDrops)"))
    }

    // MARK: - The surfaces

    /// The stamp widget is registered, and the Water control's pixel drop ships in the extension's
    /// asset catalog under the name the control asks for.
    @Test func theStampWidgetAndTheControlsSymbolShip() throws {
        let bundle = try RepoRoot.source(Self.widgetRoot + "FernletWidgetsBundle.swift")
        #expect(bundle.contains("        FernletStampWidget()\n"))
        let water = try RepoRoot.source(Self.widgetRoot + "WaterWidget.swift")
        #expect(water.contains("static let symbolName = \"fernlet.drop.pixel\""))
        let svg = RepoRoot.url(Self.widgetRoot + "Assets.xcassets/fernlet.drop.pixel.symbolset/fernlet.drop.pixel.svg")
        #expect(FileManager.default.fileExists(atPath: svg.path), "the control's custom symbol is missing")
    }

    // MARK: - Helpers

    /// Expects `source` to declare `static let <name> = WidgetSprite(` with `sprite`'s rows and every
    /// colour of its palette.
    static func expect(_ source: String, declares name: String, as sprite: WorldSprite) throws {
        let declaration = try #require(source.components(separatedBy: "static let \(name) = WidgetSprite(").dropFirst().first?
            .components(separatedBy: ")\n").first, "no `\(name)` sprite in the widget")
        let rows = "rows: [" + sprite.rows.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        #expect(declaration.contains(rows), "`\(name)`'s rows drifted from the app's")
        for (key, value) in sprite.palette {
            #expect(declaration.contains("\"\(key)\": " + String(format: "0x%06X", value)), "`\(name)`'s \(key) colour drifted")
        }
        #expect(declaration.components(separatedBy: "\": 0x").count - 1 == sprite.palette.count, "`\(name)` has extra colours")
    }

    /// The art the widget's stamp switch names for `kind`.
    static func artName(for kind: SillyStatKind, in source: String) -> String? {
        let marker = "case .\(kind.rawValue): WidgetStampArt."
        guard let tail = source.components(separatedBy: marker).dropFirst().first else { return nil }
        return tail.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
    }
}
