import Foundation
import Testing
import FernletExchange
@testable import Fernlet

/// The World build carries Fernlet's REAL identity (world-ui only; owner's call of 2026-10-25, which
/// replaced step 0's separate "Fernlet World" identity, `57b5392b`): the shipping bundle IDs, app group,
/// iCloud container, `fernlet://` scheme, exported file types and the name "Fernlet". A run from Xcode
/// therefore installs over the TestFlight app as an update and opens the owner's existing data — the
/// same data container, the same app-group files, the same keychain items and the same CloudKit
/// container. CloudKit's environment is left to the signing, as on main: a TestFlight or App Store
/// build uses Production and a run from Xcode uses Development (owner, 2026-10-26, ready for main).
///
/// **Why a wall.** Two silent failures, both of which compile clean:
/// - Step 0's World identity coming back (a cherry-pick or a merge from an older World branch). The
///   build would then install BESIDE Fernlet and start empty, or worse, point one target's app group
///   away from the others', so the widget, the share sheet and the Messages inbox read nothing.
/// - The real data becoming unreachable without any identity string changing: a keychain access group
///   (items would move out of the default group, team ID plus bundle ID, that the TestFlight app's
///   lock, journal, media and preferences keys live in), or a CloudKit environment pin coming back (a
///   World-only `Production` pin would ship to main, and the Simulator and a schema push work only with
///   Development).
///
/// What is NOT checked here: the mesh namespace (Bonjour types, ALPN, the `fernlet://verify` and
/// duress-ceremony QR codes), which never changed; background-task identifiers; the test bundles' IDs;
/// and the icon's pixels.
struct WorldIdentityBoundaryTests {

    /// Fernlet's shipping identity strings.
    static let appGroup = "group.MBO.Fernlet"
    static let iCloudContainer = "iCloud.MBO.Fernlet"
    static let urlScheme = "fernlet"
    static let displayName = "Fernlet"

    /// The four installable targets' bundle IDs, each set in all three build configurations (Debug,
    /// Release, and Demo — the App Review build, which ships under the same identity), exactly as main
    /// has them.
    static let installableBundleIDs: Set<String> = [
        "MBO.Fernlet",
        "MBO.Fernlet.FernletWidgets",
        "MBO.Fernlet.ShareExtension",
        "MBO.Fernlet.MessagesExtension",
    ]

    /// The four entitlements files, the app's first.
    static let entitlementsPaths = [
        "App/Fernlet/Fernlet.entitlements",
        "App/FernletWidgets/FernletWidgets.entitlements",
        "App/FernletShareExtension/FernletShareExtension.entitlements",
        "App/FernletMessagesExtension/FernletMessagesExtension.entitlements",
    ]

    /// The shipping Swift roots (the same five every code wall scans).
    static let shippingRoots = [
        "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension", "FernletKit/Sources",
    ]

    /// Every installable target carries its shipping bundle ID, in every configuration, and the app
    /// keeps its product name as its display name.
    @Test func everyInstallableTargetHasTheShippingBundleID() throws {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let ids = Self.values(of: "PRODUCT_BUNDLE_IDENTIFIER", in: project)
        guard !ids.isEmpty else {
            Issue.record("found no PRODUCT_BUNDLE_IDENTIFIER in the project file")
            return
        }
        let installable = ids.filter { !$0.hasPrefix("MBO.FernletTests") && !$0.hasPrefix("MBO.FernletUITests") }
        #expect(Set(installable) == Self.installableBundleIDs, "installable bundle IDs drifted: \(Set(installable))")
        #expect(installable.count == 3 * Self.installableBundleIDs.count, "each installable target needs its ID in Debug, Release and Demo")
        #expect(!project.contains("Fernlet World"), "the project still names the app Fernlet World")
        #expect(Self.values(of: "INFOPLIST_KEY_CFBundleDisplayName", in: project).isEmpty,
                "the app's name comes from its product name, Fernlet, as on main")
    }

    /// Each extension shows the app's own name in the share sheet, Messages and the widget gallery.
    @Test func extensionsAreNamedFernlet() throws {
        for path in ["App/FernletWidgets/Info.plist", "App/FernletShareExtension/Info.plist", "App/FernletMessagesExtension/Info.plist"] {
            let plist = try Self.plist(path)
            #expect(plist["CFBundleDisplayName"] as? String == Self.displayName, "\(path) is not named Fernlet")
        }
    }

    /// Every entitlements file names exactly the shipping app group; the app names the shipping
    /// container under both iCloud keys, with no CloudKit environment pin and no keychain access
    /// group.
    @Test func entitlementsReachTheRealData() throws {
        for path in Self.entitlementsPaths {
            let plist = try Self.plist(path)
            #expect(plist["com.apple.security.application-groups"] as? [String] == [Self.appGroup], "\(path) lost the shipping app group")
            #expect(plist["keychain-access-groups"] == nil, "\(path) adds a keychain access group: items would leave the TestFlight app's default group")
            #expect(!Self.containsWorldIdentity(try RepoRoot.source(path)), "\(path) names step 0's World identity")
        }
        let app = try Self.plist(Self.entitlementsPaths[0])
        #expect(app["com.apple.developer.icloud-container-identifiers"] as? [String] == [Self.iCloudContainer])
        #expect(app["com.apple.developer.ubiquity-container-identifiers"] as? [String] == [Self.iCloudContainer])
        #expect(app["com.apple.developer.icloud-container-environment"] == nil,
                "the CloudKit environment is the signing's: TestFlight and the App Store use Production, an Xcode run Development")
    }

    /// No shipping Swift file spells step 0's identity or picks a keychain access group, so every
    /// keychain item stays in the app's default group.
    @Test func shippingSourceNamesNoWorldIdentityOrAccessGroup() throws {
        var scanned = 0
        var offenders: [String] = []
        var accessGroups: [String] = []
        for root in Self.shippingRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("cannot walk \(root)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                if Self.containsWorldIdentity(text) { offenders.append(url.lastPathComponent) }
                if text.contains("kSecAttrAccessGroup") { accessGroups.append(url.lastPathComponent) }
            }
        }
        #expect(scanned > 500, "scanned only \(scanned) shipping Swift files; a root moved")
        #expect(offenders.isEmpty, "these files name step 0's World identity: \(offenders)")
        #expect(accessGroups.isEmpty, "these files set a keychain access group: \(accessGroups)")
    }

    /// The app answers the shipping scheme and owns (exports) its file types again, and the links it
    /// hands the system use the scheme.
    @Test func urlSchemeLinksAndFileTypesAreTheShippingOnes() throws {
        let plist = try RepoRoot.source("App/Fernlet/Info.plist")
        #expect(plist.contains("<string>\(Self.urlScheme)</string>"), "Info.plist lost the fernlet scheme")
        #expect(plist.contains("UTExportedTypeDeclarations"), "Fernlet exports its recipe and workout-plan file types")
        #expect(!plist.contains("UTImportedTypeDeclarations"), "Fernlet must not merely import its own file types")
        let packets = try RepoRoot.source("App/Fernlet/FernletExchangePackets.swift")
        #expect(packets.contains("UTType(exportedAs: \"com.mbo.fernlet.recipe\""))
        #expect(packets.contains("UTType(exportedAs: \"com.mbo.fernlet.workout-plan\""))
        #expect(FernletMessagesInboxLink.scheme == Self.urlScheme)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet://widget/home"))) == .home)
        #expect(FernletWidgetLinkRouter.target(of: try #require(URL(string: "fernlet-world://widget/home"))) == nil)
    }

    /// The planted-token fixture for ``containsWorldIdentity(_:)``: a wall whose matcher never fires
    /// passes vacuously.
    @Test func worldIdentityMatcherFiresOnlyOnStepZeroStrings() {
        #expect(Self.containsWorldIdentity(#"let id = "group.MBO.Fernlet.World""#))
        #expect(Self.containsWorldIdentity("<string>iCloud.MBO.Fernlet.World</string>"))
        #expect(Self.containsWorldIdentity("PRODUCT_BUNDLE_IDENTIFIER = MBO.Fernlet.World.FernletWidgets;"))
        #expect(Self.containsWorldIdentity(#"URL(string: "fernlet-world://widget/home")"#))
        #expect(!Self.containsWorldIdentity(#"let id = "group.MBO.Fernlet""#))
        #expect(!Self.containsWorldIdentity("<string>iCloud.MBO.Fernlet</string>"))
        #expect(!Self.containsWorldIdentity(#"static let worldMapFogV1 = "fernlet.world-map.fog.aead.v1""#))
    }

    // MARK: - Helpers

    /// Whether `text` names step 0's identity: its bundle-ID stem (which also covers its app group and
    /// container) or its URL scheme. World-only stores' own tokens (`fernlet.world-map…`) don't match.
    static func containsWorldIdentity(_ text: String) -> Bool {
        text.contains("MBO.Fernlet.World") || text.contains("fernlet-world")
    }

    /// A property list file in the repository, as a dictionary.
    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url(path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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
