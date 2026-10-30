import Foundation
import Testing

/// Holds Xcode's Enhanced Security capability on for every process Fernlet ships
/// (`Docs/Enhanced-Security.md`, owner decision 2026-10-17).
///
/// The capability is configuration only — one project-level build setting plus seven
/// `com.apple.security.hardened-process` entitlements per process — so nothing in the compiler
/// notices when a target loses it: a new extension added without the keys, an entitlements file
/// rewritten by a tool, or a re-save that drops the setting all still build clean. This suite is the
/// whole enforcement, in the same spirit as the no-tracking wall.
///
/// What it pins is the SHAPE, not the rollout stage: soft-mode memory tagging is the first stage and
/// is expected to come out once device testing is clean, so the suite only requires that every
/// process is in the SAME tagging mode — turning soft mode off is one decision, made for all four.
@Suite
struct EnhancedSecurityConfigurationTests {
    /// Required `true` in every process target's entitlements. Xcode's capability editor enforces
    /// the dependencies between these; a hand edit (or a tool that rewrites the plist) does not.
    private static let requiredBooleans = [
        "com.apple.security.hardened-process",
        "com.apple.security.hardened-process.checked-allocations",
        "com.apple.security.hardened-process.dyld-ro",
        "com.apple.security.hardened-process.hardened-heap"
    ]

    /// Required as STRINGS. App Store validation has twice rejected these demanding Boolean `true`
    /// (October 2025, April 2026); Apple DTS confirmed both were validator bugs. A `true` here stops
    /// the app launching, so the type is pinned, not just the presence.
    private static let requiredStrings = [
        "com.apple.security.hardened-process.enhanced-security-version-string",
        "com.apple.security.hardened-process.platform-restrictions-string"
    ]

    /// The integer forms Xcode 26.4 deprecated (release note 168185600); they crash the app on OS
    /// versions before 26. Never written alongside, or instead of, the `-string` forms.
    private static let retiredKeys = [
        "com.apple.security.hardened-process.enhanced-security-version",
        "com.apple.security.hardened-process.platform-restrictions"
    ]

    private static let softModeKey = "com.apple.security.hardened-process.checked-allocations.soft-mode"

    /// Product types that run as their own process and so sign their own entitlements.
    private static let processProductTypes = [
        "com.apple.product-type.application",
        "com.apple.product-type.app-extension"
    ]

    @Test func everyProcessTargetCarriesTheHardenedProcessEntitlements() throws {
        let files = try Self.entitlementsFiles()
        // Non-vacuous: the app and its three extensions.
        #expect(files.count >= 4, "only \(files.count) entitlements files were found in the project")
        for file in files {
            let plist = try Self.entitlements(file)
            for key in Self.requiredBooleans {
                #expect(plist[key] as? Bool == true, "\(file) must set \(key) to true")
            }
            for key in Self.requiredStrings {
                let value = plist[key] as? String
                #expect(value?.isEmpty == false, "\(file) must set \(key) as a non-empty String, never a Bool or a number")
            }
            for key in Self.retiredKeys {
                #expect(plist[key] == nil, "\(file) carries the retired integer key \(key)")
            }
        }
    }

    /// A new app or extension target with no entitlements file of its own would ship unhardened and
    /// escape the check above, so the two counts must agree.
    @Test func noProcessTargetIsMissingAnEntitlementsFile() throws {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let processTargets = project.components(separatedBy: "\n").filter { line in
            Self.processProductTypes.contains { line.contains("productType = \"\($0)") }
        }
        #expect(processTargets.count == (try Self.entitlementsFiles()).count,
                "\(processTargets.count) app/extension targets but a different number of entitlements files")
    }

    @Test func everyProcessIsInTheSameTaggingMode() throws {
        let modes = try Set(Self.entitlementsFiles().map { try Self.entitlements($0)[Self.softModeKey] as? Bool ?? false })
        #expect(modes.count == 1, "some targets tag in soft mode and some do not; flip soft mode for all of them together")
    }

    /// The project-level setting is what every target inherits — the app, the extensions and the
    /// hosted test bundles — so the `arm64e` slice is consistent across everything linked into one
    /// process. A target-level override would split it, which App Store validation rejects.
    @Test func theProjectTurnsEnhancedSecurityOnForEveryTarget() throws {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let configurations = project.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst()
        let enabled = configurations.filter { $0.contains("ENABLE_ENHANCED_SECURITY = YES;") }
        // Exactly the project's own Debug, Release and Demo (the App Review build, a copy of Release):
        // those carry no PRODUCT_NAME, every target's do.
        #expect(enabled.count == 3, "ENABLE_ENHANCED_SECURITY = YES appears in \(enabled.count) configurations, expected the project's three")
        #expect(enabled.allSatisfy { !$0.contains("PRODUCT_NAME") }, "ENABLE_ENHANCED_SECURITY belongs at the project level, not on one target")
        for override in ["ENABLE_ENHANCED_SECURITY = NO;", "ENABLE_POINTER_AUTHENTICATION = NO;", "\tARCHS = "] {
            #expect(!project.contains(override), "a configuration overrides the inherited hardening with `\(override)`")
        }
    }

    /// A project-level build setting never reaches Swift package targets, so without this workspace
    /// setting FernletKit, CryptoSwift and ProximityKit build `arm64` only and the device build fails
    /// at the first `arm64e` import ("Unable to resolve module dependency", measured 2026-10-17). It is
    /// Apple's documented switch (BrowserEngineKit, "Build for pointer authentication"), and it lives
    /// in BOTH workspaces the project is opened through. CI builds only for the simulator, which has
    /// no `arm64e`, so losing it would surface first at archive time; this catches it on every run.
    @Test func bothWorkspacesBuildSwiftPackagesForArm64e() throws {
        for workspace in ["App/Fernlet.xcodeproj/project.xcworkspace", "Fernlet.xcworkspace"] {
            let data = try Data(contentsOf: RepoRoot.url("\(workspace)/xcshareddata/WorkspaceSettings.xcsettings"))
            let settings = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(settings["iOSPackagesShouldBuildARM64e"] as? Bool == true,
                    "\(workspace) does not build Swift packages for arm64e; the device build cannot link them")
        }
    }

    // MARK: - Readers

    /// Every distinct `CODE_SIGN_ENTITLEMENTS` path in the project, relative to `App/`.
    private static func entitlementsFiles() throws -> [String] {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        var files: Set<String> = []
        for line in project.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("CODE_SIGN_ENTITLEMENTS = "), trimmed.hasSuffix(";") else { continue }
            files.insert(String(trimmed.dropFirst("CODE_SIGN_ENTITLEMENTS = ".count).dropLast()))
        }
        return files.sorted()
    }

    private static func entitlements(_ file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url("App/\(file)"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
