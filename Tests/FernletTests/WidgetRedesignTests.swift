import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The widget redesign's contract with the app (design round 2, owner decisions 2026-10-21): the
/// companion's name and look in the snapshot, the widget kinds the app reloads, the deep links a
/// widget tap opens, and the twins the extension hand-copies.
///
/// The extension links no FernletKit product and has no test target, so its half is read off disk
/// (`RepoRoot.source`), in the house style of `WidgetBridgeTests`.
@MainActor
struct WidgetRedesignTests {

    static let sharedModelsPath = "App/FernletWidgets/WidgetSharedModels.swift"
    static let bundlePath = "App/FernletWidgets/FernletWidgetsBundle.swift"
    /// The pixel companion the widgets draw since World Review Batch 4 (2026-10-24).
    static let figurePath = "App/FernletWidgets/WidgetPixelCompanion.swift"
    /// The map's painter, which the widget's is the twin of.
    static let appPainterPath = "App/Fernlet/World/Companion/WorldCompanionPainter.swift"
    static let viewsPath = "App/FernletWidgets/CompanionWidgetViews.swift"

    // MARK: - The look

    /// The plain companion maps to the round body, a state-coloured body and the fern sprout — and the
    /// widget's own fallback before the app publishes is that same look, colour for colour.
    @Test func theStandardAppearanceIsTheWidgetsStandardLook() throws {
        let look = WidgetSnapshot.CompanionLook(appearance: .standard)
        #expect(look.bodyStyleRaw == "circle" && look.bodyColorHex == nil && look.accessoryRaw == "sprout")
        let accessoryHex = try #require(look.accessoryColorHex, "the sprout's fixed fern colour did not resolve")
        let widget = try RepoRoot.source(Self.sharedModelsPath)
        #expect(widget.contains("accessoryRaw: \"sprout\", accessoryColorHex: \"\(accessoryHex)\""),
                "the widget's standard look no longer matches the app's plain companion (\(accessoryHex))")
    }

    /// A slot that follows the state stays nil (the widget colours it by the day); a custom hex is
    /// normalized; anything malformed is dropped rather than drawn.
    @Test func colourSlotsResolveToHexOrStayWithTheState() {
        var appearance = CompanionAppearance.standard
        appearance.bodyColor = .state
        appearance.bodyCustomColorHex = nil
        #expect(WidgetSnapshot.CompanionLook(appearance: appearance).bodyColorHex == nil)
        appearance.bodyCustomColorHex = "abc123"
        #expect(WidgetSnapshot.CompanionLook(appearance: appearance).bodyColorHex == "#ABC123")
        appearance.bodyCustomColorHex = "#12345"
        #expect(WidgetSnapshot.CompanionLook(appearance: appearance).bodyColorHex == nil, "five digits is not a colour")
        appearance.bodyCustomColorHex = nil
        appearance.bodyColor = .terracotta
        let fixed = WidgetSnapshot.CompanionLook(appearance: appearance).bodyColorHex
        #expect(fixed?.count == 7 && fixed?.hasPrefix("#") == true, "a named colour resolves to #RRGGBB, got \(String(describing: fixed))")
        appearance.bodyStyle = .pear
        appearance.accessory = .glasses
        let look = WidgetSnapshot.CompanionLook(appearance: appearance)
        #expect(look.bodyStyleRaw == "pear" && look.accessoryRaw == "glasses", "the tokens are the frozen raw values")
    }

    /// The store publishes the name (trimmed, nil when empty) and the look with every snapshot.
    @Test func theSnapshotCarriesTheNameAndTheLook() {
        let store = makeTestStore()
        store.setCompanionName("  Pip ")
        let named = store.currentWidgetSnapshot()
        #expect(named.companionName == "Pip")
        #expect(named.companionLook == WidgetSnapshot.CompanionLook(appearance: store.settings.companionAppearance))
        store.setCompanionName("   ")
        #expect(store.currentWidgetSnapshot().companionName == nil)
    }

    /// The widget's twin carries both fields under the same JSON keys, so the widget decodes them and
    /// its optimistic water bump's re-encode keeps them.
    @Test func theWidgetTwinCarriesTheSameKeys() throws {
        let widget = try RepoRoot.source(Self.sharedModelsPath)
        for field in ["var companionName: String? = nil", "var companionLook: WidgetCompanionLook? = nil",
                      "var bodyStyleRaw: String", "var bodyColorHex: String?",
                      "var accessoryRaw: String", "var accessoryColorHex: String?",
                      "var scarfColorHex: String? = nil", "var capColorHex: String? = nil",
                      "var sideItemRaw: String? = nil", "var sideItemColorHex: String? = nil",
                      "var items: [ItemArt]? = nil", "struct ItemArt: Codable, Equatable {",
                      "var palette: [String]", "var pixels: [Int]", "var coversHead: Bool"] {
            #expect(widget.contains(field), "the widget twin lost `\(field)`")
        }
    }

    // MARK: - Glasses

    /// The widget's pixel companion wears the glasses as the map's does (World Review Batch 4; in their
    /// colour since W-03): drawn unless the eyes are closed lines, by the very painter the map runs
    /// (`WidgetWorldTests.thePixelCompanionIsTheMaps` holds the twin). A widget draws only asleep or awake
    /// (never the map's wind-down), and its one-colour renderings cut the glasses out with the face.
    @Test func theWidgetWearsTheGlassesAsTheMapDoes() throws {
        let widget = try RepoRoot.source(Self.figurePath)
        let app = try RepoRoot.source(Self.appPainterPath)
        let glasses = "if look.topper == .glasses && !closesEyes(state: state, pose: pose) {"
        #expect(widget.contains(glasses) && app.contains(glasses))
        #expect(widget.contains("pose: WidgetCompanionPose(asleep: asleep)"), "the widget's pose is asleep or awake")
        #expect(widget.contains("case .silhouette(let hex): return grid.isFace(frameX: x, y: y) ? nil : hex"))
        #expect(app.contains("grid.put(gx, eyeRow - 1, color, face: true)"), "the glasses are part of the cut-out face")
    }

    // MARK: - Kinds and links

    /// The app reloads every surface the extension registers, under the same kind strings.
    @Test func theAppReloadsEveryWidgetKind() throws {
        let bundle = try RepoRoot.source(Self.bundlePath)
        let kinds = [(WidgetSnapshotMirror.widgetKind, "companion"), (WidgetSnapshotMirror.waterWidgetKind, "water"),
                     (WidgetSnapshotMirror.waterControlKind, "waterControl"), (WidgetSnapshotMirror.stampWidgetKind, "stamp")]
        for (kind, name) in kinds {
            #expect(bundle.contains("static let \(name) = \"\(kind)\""), "FernletWidgetKind.\(name) is no longer \"\(kind)\"")
        }
    }

    /// A widget tap's URL lands where the widget promised: Home, the Water sheet, or the Stamp book.
    @Test func widgetLinksLandOnHomeAndWater() throws {
        let bundle = try RepoRoot.source(Self.bundlePath)
        for path in ["home", "water"] {
            let spelling = "fernlet://widget/\(path)"
            #expect(bundle.contains("URL(string: \"\(spelling)\")"), "the widget no longer writes \(spelling)")
            let url = try #require(URL(string: spelling))
            #expect(FernletWidgetLinkRouter.target(of: url)?.rawValue == path)
        }
        // The stamp widget's link opens Today and pushes the Stamp book, as the stamp banner's tap does.
        #expect(bundle.contains("URL(string: \"fernlet://widget/stamps\")"), "the stamp widget no longer writes its link")
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet://widget/stamps"))) == .stamps)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet://widget/journal"))) == nil)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "https://widget/home"))) == nil)
    }

    // MARK: - The Lock Screen

    /// The rectangle retired on 2026-10-21 returns as the owner's pick of 2026-10-24
    /// (`b4-new-lock-rect`): the companion widget offers the small card, the medium card, the face and
    /// the hearts-and-water rectangle — and the rectangle hides its name and hearts until the phone is
    /// unlocked, while every other companion family stays wholly private.
    @Test func theLockScreenShowsTheFaceAndTheHeartsAndWater() throws {
        let bundle = try RepoRoot.source(Self.bundlePath)
        #expect(bundle.contains(".supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])"))
        for line in ["CompanionLockView(entry: entry).privacySensitive()",
                     "CompanionThoughtView(entry: entry, mono: mono).privacySensitive()",
                     "CompanionSmallView(entry: entry, mono: mono).privacySensitive()"] {
            #expect(bundle.contains(line), "a companion family lost its privacy: `\(line)`")
        }
        let views = try RepoRoot.source(Self.viewsPath)
        let rect = try #require(views.components(separatedBy: "struct CompanionLockRectView").last?
            .components(separatedBy: "struct WidgetLockWaterLine").first, "the Lock Screen rectangle is gone")
        #expect(rect.components(separatedBy: ".privacySensitive()").count - 1 == 2,
                "the rectangle hides exactly its name and its hearts; its water stays")
    }
}
