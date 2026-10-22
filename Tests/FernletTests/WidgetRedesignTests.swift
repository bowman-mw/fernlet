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
    static let figurePath = "App/FernletWidgets/WidgetCompanionFigure.swift"
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
                      "var accessoryRaw: String", "var accessoryColorHex: String?"] {
            #expect(widget.contains(field), "the widget twin lost `\(field)`")
        }
    }

    // MARK: - Glasses

    /// The widget's glasses rule is the app's `CompanionAccessory.isWorn`, line for line.
    @Test func theWidgetTakesOffTheGlassesWhenTheAppDoes() throws {
        let widget = try RepoRoot.source(Self.figurePath)
        let app = try RepoRoot.source("FernletKit/Sources/FernletDomainModel/CompanionEmotion.swift")
        for line in ["if emotion == .sleepy || emotion == .asleep { return false }",
                     "if state == .tired || state == .sick { return false }",
                     "return !(emotion == .tired && state != .resting)"] {
            #expect(widget.contains(line) && app.contains(line), "the glasses rule drifted: `\(line)`")
        }
    }

    // MARK: - Kinds and links

    /// The app reloads every surface the extension registers, under the same kind strings.
    @Test func theAppReloadsEveryWidgetKind() throws {
        let bundle = try RepoRoot.source(Self.bundlePath)
        let kinds = [(WidgetSnapshotMirror.widgetKind, "companion"), (WidgetSnapshotMirror.waterWidgetKind, "water"),
                     (WidgetSnapshotMirror.waterControlKind, "waterControl")]
        for (kind, name) in kinds {
            #expect(bundle.contains("static let \(name) = \"\(kind)\""), "FernletWidgetKind.\(name) is no longer \"\(kind)\"")
        }
    }

    /// A widget tap's URL lands where the widget promised: Home, or the Water sheet.
    @Test func widgetLinksLandOnHomeAndWater() throws {
        let bundle = try RepoRoot.source(Self.bundlePath)
        for path in ["home", "water"] {
            let spelling = "fernlet://widget/\(path)"
            #expect(bundle.contains("URL(string: \"\(spelling)\")"), "the widget no longer writes \(spelling)")
            let url = try #require(URL(string: spelling))
            #expect(FernletWidgetLinkRouter.target(of: url)?.rawValue == path)
        }
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet://widget/journal"))) == nil)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "https://widget/home"))) == nil)
    }

    // MARK: - The Lock Screen

    /// The rectangular Lock Screen card is retired (owner, 2026-10-21): the companion widget offers
    /// the small card, the thought card and the Lock Screen face, and nothing else.
    @Test func theLockScreenKeepsOnlyTheFace() throws {
        let bundle = try RepoRoot.source(Self.bundlePath)
        #expect(bundle.contains(".supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])"))
        let views = try RepoRoot.source(Self.viewsPath)
        #expect(!bundle.contains("accessoryRectangular") && !views.contains("accessoryRectangular"))
    }
}
