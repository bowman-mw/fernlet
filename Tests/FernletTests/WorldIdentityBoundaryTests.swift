import Foundation
import Testing
import FernletExchange
@testable import Fernlet

/// The World build's own identity (world-ui only, step 0 of the live-map Home plan, owner-approved
/// 2026-10-23): its bundle IDs, app group, iCloud container and URL scheme are all distinct from the
/// shipping Fernlet app's, so installing it on the owner's phone can never replace the real app or share
/// its data, app-group files or iCloud copy.
///
/// **Why a wall.** `world-ui` takes merges FROM main from time to time. A main commit that adds a new
/// `"group.MBO.Fernlet"` literal (a new widget file, a new extension) would compile clean and quietly
/// point the World build back at the real app's container. These checks fail that merge instead.
///
/// What stays shared on purpose and is NOT checked here: the mesh namespace (Bonjour types, ALPN, the
/// `fernlet://verify` QR and the duress-ceremony QR, all scanned in-app), so the World build still meets
/// friends' real Fernlet; background-task identifiers, which the system scopes per app; and the test
/// bundles' own IDs.
struct WorldIdentityBoundaryTests {

    /// The World build's identity strings.
    static let bundlePrefix = "MBO.Fernlet.World"
    static let appGroup = "group.MBO.Fernlet.World"
    static let iCloudContainer = "iCloud.MBO.Fernlet.World"
    static let urlScheme = "fernlet-world"

    /// The four installable targets' bundle IDs, each set in both build configurations.
    static let installableBundleIDs: Set<String> = [
        "MBO.Fernlet.World",
        "MBO.Fernlet.World.FernletWidgets",
        "MBO.Fernlet.World.ShareExtension",
        "MBO.Fernlet.World.MessagesExtension",
    ]

    /// The shipping Swift roots (the same five every code wall scans).
    static let shippingRoots = [
        "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension", "FernletKit/Sources",
    ]

    /// Every installable target carries a World bundle ID, in both configurations, and nothing else
    /// does except the two test bundles.
    @Test func everyInstallableTargetHasAWorldBundleID() throws {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let ids = Self.values(of: "PRODUCT_BUNDLE_IDENTIFIER", in: project)
        guard !ids.isEmpty else {
            Issue.record("found no PRODUCT_BUNDLE_IDENTIFIER in the project file")
            return
        }
        let installable = ids.filter { !$0.hasPrefix("MBO.FernletTests") && !$0.hasPrefix("MBO.FernletUITests") }
        #expect(Set(installable) == Self.installableBundleIDs, "installable bundle IDs drifted: \(Set(installable))")
        #expect(installable.count == 2 * Self.installableBundleIDs.count, "each installable target needs a World ID in Debug and Release")
        #expect(project.contains("INFOPLIST_KEY_CFBundleDisplayName = \"Fernlet World\";"), "the app lost its Fernlet World name")
    }

    /// Every entitlements file names only the World app group and the World iCloud container.
    @Test func entitlementsNameOnlyTheWorldGroupAndContainer() throws {
        let paths = [
            "App/Fernlet/Fernlet.entitlements",
            "App/FernletWidgets/FernletWidgets.entitlements",
            "App/FernletShareExtension/FernletShareExtension.entitlements",
            "App/FernletMessagesExtension/FernletMessagesExtension.entitlements",
        ]
        for path in paths {
            let text = try RepoRoot.source(path)
            #expect(text.contains("<string>\(Self.appGroup)</string>"), "\(path) lost the World app group")
            #expect(!Self.containsRealIdentity(text), "\(path) names the shipping app's group or container")
        }
        let app = try RepoRoot.source(paths[0])
        #expect(app.components(separatedBy: "<string>\(Self.iCloudContainer)</string>").count - 1 == 2,
                "the app needs the World container under both iCloud keys")
    }

    /// No shipping Swift file spells the shipping app's group or container as a literal.
    @Test func shippingSourceNamesNoRealGroupOrContainer() throws {
        var scanned = 0
        var offenders: [String] = []
        for root in Self.shippingRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("cannot walk \(root)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                if Self.containsRealIdentity(text) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(scanned > 500, "scanned only \(scanned) shipping Swift files; a root moved")
        #expect(offenders.isEmpty, "these files name group.MBO.Fernlet or iCloud.MBO.Fernlet: \(offenders)")
    }

    /// The app answers only its own URL scheme, and the links it hands the system use it.
    @Test func urlSchemeAndLinksAreTheWorldScheme() throws {
        let plist = try RepoRoot.source("App/Fernlet/Info.plist")
        #expect(plist.contains("<string>\(Self.urlScheme)</string>"), "Info.plist lost the fernlet-world scheme")
        #expect(!plist.contains("<string>fernlet</string>"), "Info.plist still claims the shipping app's fernlet scheme")
        #expect(!plist.contains("UTExportedTypeDeclarations"), "the World build must import, not export, Fernlet's file types")
        #expect(FernletMessagesInboxLink.scheme == Self.urlScheme)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet-world://widget/home"))) == .home)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet://widget/home"))) == nil)
    }

    /// The planted-token fixture for ``containsRealIdentity(_:)``: a wall whose matcher never fires
    /// passes vacuously.
    @Test func realIdentityMatcherFiresOnlyOnTheShippingStrings() {
        #expect(Self.containsRealIdentity(#"let id = "group.MBO.Fernlet""#))
        #expect(Self.containsRealIdentity("<string>iCloud.MBO.Fernlet</string>"))
        #expect(!Self.containsRealIdentity(#"let id = "group.MBO.Fernlet.World""#))
        #expect(!Self.containsRealIdentity("<string>iCloud.MBO.Fernlet.World</string>"))
    }

    // MARK: - Helpers

    /// Whether `text` names the shipping app's group or container as a whole string (closed by a quote
    /// or a plist tag), as opposed to the World build's.
    static func containsRealIdentity(_ text: String) -> Bool {
        let real = ["group.MBO.Fernlet", "iCloud.MBO.Fernlet"]
        return real.contains { name in text.contains(name + "\"") || text.contains(name + "</string>") }
    }

    /// Every value assigned to `key` in a pbxproj (`key = value;`), quotes removed.
    static func values(of key: String, in project: String) -> [String] {
        project.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + " = "), trimmed.hasSuffix(";") else { return nil }
            let value = trimmed.dropFirst(key.count + 3).dropLast()
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
}
