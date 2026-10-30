import Foundation
import Testing

/// What the app declares to iOS and App Review, held to the owner's 2026-10-15 decisions (upload
/// blockers): the permission texts, the photo-library and location keys, the entitlements, and the
/// settings link.
///
/// A permission text lives in two places that must agree — the app target's `INFOPLIST_KEY_*` build
/// settings (Debug, Release and Demo) and `App/Fernlet/InfoPlist.xcstrings`, whose `en` value is what users
/// see — and the Local Network one in a third, `App/Fernlet/Info.plist`. Nothing else compares them,
/// so a reworded copy in one place shipped beside the old copy in another.
@Suite
struct AppPermissionDeclarationsTests {
    /// The owner-approved texts (2026-10-15). Changing one is a copy decision: edit it here, in both
    /// build configurations and in the catalog, in one commit.
    private static let approvedTexts: [String: String] = [
        "NSLocalNetworkUsageDescription": "Fernlet connects directly with nearby friends to share recipes and, during a session you start, photos, short-lived messages and hearts. A session may continue in the background.",
        "NSNearbyInteractionUsageDescription": "Fernlet uses Ultra Wideband to measure the distance to a nearby friend while you connect.",
        "NSCameraUsageDescription": "Fernlet uses your camera to scan barcodes and nutrition labels, photograph meals, take progress photos, and take photos during sessions with friends.",
        // The World map's location (owner, 2026-10-24; World build step 5c): `b1-loc-prompt`'s purpose
        // line, approved. The background-mapping text is the car round's (owner, 2026-10-26: a detected
        // drive is traced in full, so "using little battery" went).
        "NSLocationWhenInUseUsageDescription": "Your companion lives on a map of where you are. The map uncovers as you go, and the history stays on this iPhone.",
        "NSLocationAlwaysAndWhenInUseUsageDescription": "With background mapping on, Fernlet uncovers the map from the places you visit and the roads you drive. It stays on this iPhone.",
        // Car and bike detection (owner, 2026-10-25: "Approve both"; round 7): asked only when "Log my bike
        // rides" is turned on.
        "NSMotionUsageDescription": "Fernlet uses motion to tell when you're riding a bike or in a car, only while \"Log my bike rides\" is on. It stays on this iPhone."
    ]

    /// The walk's temporary full-accuracy purpose (owner-approved 2026-10-24; "or run" added with the
    /// owner's round-5 answer, since runs record their line too), under the frozen purpose key
    /// `WorldLocationSource.walkAccuracyPurposeKey` asks with.
    private static let walkPurposeKey = "WorldWalk"
    private static let walkPurposeText = "Precise location draws the line of this walk or run. The line stays on this iPhone."

    /// Photo-library READ APIs. The app reads the library only through the system pickers
    /// (`PhotosPicker`, `UIImagePickerController`), which need no permission, so it declares no
    /// `NSPhotoLibraryUsageDescription`; any of these would crash at its first call without one.
    private static let photoLibraryReadSpellings = [
        "PHAsset.fetch", "PHImageManager", "PHCachingImageManager", "PHFetchOptions", "PHFetchResult",
        "requestAuthorization(for: .readWrite)", "authorizationStatus(for: .readWrite)", "photoLibrary: .shared()"
    ]

    /// The shipping source roots the API scans walk.
    private static let shippingRoots = ["App", "FernletKit/Sources"]

    // MARK: - Permission texts

    @Test func bothConfigurationsDeclareTheSamePermissionTexts() throws {
        let configurations = try Self.appTargetInfoPlistKeys()
        #expect(configurations.count == 3, "expected the app target's Debug, Release and Demo configurations")
        let usage = configurations.map { $0.filter { $0.key.hasSuffix("UsageDescription") } }
        #expect(usage.first?.isEmpty == false)
        #expect(usage.dropFirst().allSatisfy { $0 == usage.first })
    }

    @Test func everyPermissionTextMatchesTheCatalogUsersSee() throws {
        let settings = try #require(try Self.appTargetInfoPlistKeys().first)
        let catalog = try Self.catalogEnglishValues()
        let settingsUsage = settings.filter { $0.key.hasSuffix("UsageDescription") }
        let catalogUsage = catalog.filter { $0.key.hasSuffix("UsageDescription") }
        #expect(Set(settingsUsage.keys) == Set(catalogUsage.keys))
        for (key, text) in settingsUsage {
            #expect(catalogUsage[key] == text, "\(key): the build setting and InfoPlist.xcstrings disagree")
        }
        let plistCopy = try Self.appInfoPlist()["NSLocalNetworkUsageDescription"] as? String
        #expect(plistCopy == catalogUsage["NSLocalNetworkUsageDescription"])
    }

    @Test func theApprovedTextsAreTheOnesShipped() throws {
        let catalog = try Self.catalogEnglishValues()
        for configuration in try Self.appTargetInfoPlistKeys() {
            for (key, text) in Self.approvedTexts {
                #expect(configuration[key] == text, "\(key) build setting")
                #expect(catalog[key] == text, "\(key) catalog")
            }
        }
    }

    // MARK: - Photo library and location

    @Test func thePhotoLibraryReadKeyIsGoneAndNothingNeedsIt() throws {
        for configuration in try Self.appTargetInfoPlistKeys() {
            #expect(configuration["NSPhotoLibraryUsageDescription"] == nil)
            #expect(configuration["NSPhotoLibraryAddUsageDescription"] != nil)   // Save to Photos stays
        }
        #expect(try Self.catalogEnglishValues()["NSPhotoLibraryUsageDescription"] == nil)
        #expect(try Self.appInfoPlist()["NSPhotoLibraryUsageDescription"] == nil)

        let code = try Self.shippingCode()
        #expect(code.count > 300, "the shipping-source scan read only \(code.count) files")
        for (file, text) in code {
            for spelling in Self.photoLibraryReadSpellings {
                #expect(!text.contains(spelling), "\(file) uses \(spelling), which needs NSPhotoLibraryUsageDescription")
            }
        }
        // Non-vacuous: the add-only save path is still found by the same scan.
        #expect(code.values.contains { $0.contains("requestAuthorization(for: .addOnly)") })
    }

    /// The World build's location (step 5c; owner's answer of 2026-10-23: the prompt starts on Precise).
    /// `NSLocationDefaultAccuracyReduced` is gone, so iOS's prompt opens with Precise on; weather still
    /// asks for reduced accuracy in its own code, so it never reads more than the area.
    @Test func locationStartsOnPreciseAndWeatherStaysReduced() throws {
        for configuration in try Self.appTargetInfoPlistKeys() {
            #expect(configuration["NSLocationDefaultAccuracyReduced"] == nil)
        }
        #expect(try Self.appInfoPlist()["NSLocationDefaultAccuracyReduced"] == nil)
        let weather = try RepoRoot.source("FernletKit/Sources/AppServices/WeatherKitService.swift")
        #expect(weather.contains("desiredAccuracy = kCLLocationAccuracyReduced"))
    }

    /// The walk's precise-location purpose sits in Info.plist (a dictionary cannot be a build setting)
    /// and in the catalog under its purpose key, word for word, and the source asks under that key.
    @Test func theWalkPurposeIsDeclaredAndLocalized() throws {
        let purposes = try #require(try Self.appInfoPlist()["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: String])
        #expect(purposes == [Self.walkPurposeKey: Self.walkPurposeText])
        #expect(try Self.catalogEnglishValues()[Self.walkPurposeKey] == Self.walkPurposeText)
        let source = try RepoRoot.source("App/Fernlet/World/WorldLocationSource.swift")
        #expect(source.contains("walkAccuracyPurposeKey = \"\(Self.walkPurposeKey)\""))
    }

    /// The `location` background mode is used only while a walk or run the person started records, or
    /// (round 7) while a drive is traced with background mapping on: the one `CLBackgroundActivitySession`
    /// and the one `allowsBackgroundLocationUpdates = true` live in the World location source, and nowhere
    /// else in shipping code.
    @Test func backgroundLocationIsHeldOnlyForAWalk() throws {
        let modes = try Self.appInfoPlist()["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("location"))
        let holders = try Self.shippingCode().filter { _, text in
            text.contains("CLBackgroundActivitySession(") || text.contains("allowsBackgroundLocationUpdates = true")
        }
        #expect(Set(holders.keys) == ["App/Fernlet/World/WorldLocationSource.swift"])
    }

    // MARK: - Entitlements and the settings link

    @Test func theEntitlementsHoldTheOwnersDecisions() throws {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/Fernlet.entitlements"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.developer.healthkit.background-delivery"] == nil)   // no enableBackgroundDelivery anywhere
        #expect(plist["com.apple.developer.aps-environment"] == nil)                 // macOS-only key
        #expect(plist["aps-environment"] != nil)                                     // CloudKit's silent pushes
        let services = plist["com.apple.developer.icloud-services"] as? [String] ?? []
        #expect(services.contains("CloudKit"))
        // `FileManager.ubiquityIdentityToken`, the iCloud-availability check, needs iCloud Documents.
        #expect(services.contains("CloudDocuments"))
        #expect((plist["com.apple.developer.ubiquity-container-identifiers"] as? [String])?.isEmpty == false)
    }

    /// The entitlement went because nothing enables background delivery — and without it HealthKit
    /// refuses the WHOLE family, `disableBackgroundDelivery` included ("Missing
    /// com.apple.developer.healthkit.background-delivery entitlement", measured on the simulator
    /// 2026-10-15). A call left in shipping code would throw; the one in the HealthKit opt-out would
    /// have failed "Turn Health off" for every user.
    @Test func noBackgroundDeliveryCallOutlivesItsEntitlement() throws {
        let code = try Self.shippingCode()
        for (file, text) in code {
            for spelling in ["enableBackgroundDelivery", "disableBackgroundDelivery", "disableAllBackgroundDelivery"] {
                #expect(!text.contains(spelling), "\(file) calls \(spelling), which HealthKit refuses without the background-delivery entitlement")
            }
        }
        // Non-vacuous: the same scan still finds the HealthKit opt-out it guards.
        #expect(code.values.contains { $0.contains("func disableIntegration()") })
    }

    @Test func noPrivateSettingsURLIsOpened() throws {
        var literalCount = 0
        for (file, source) in try Self.shippingSources() {
            for literal in SwiftSourceLexer.lex(source).literals {
                literalCount += 1
                #expect(!literal.text.contains("App-Prefs:"), "\(file):\(literal.line) names a private settings URL (guideline 2.5.1)")
                #expect(!literal.text.lowercased().contains("prefs:root"), "\(file):\(literal.line) names a private settings URL (guideline 2.5.1)")
            }
        }
        #expect(literalCount > 1_000, "the literal scan read only \(literalCount) literals")
    }

    // MARK: - Readers

    /// Each `INFOPLIST_KEY_*` setting of every build configuration whose `INFOPLIST_FILE` is the app's
    /// Info.plist, keyed without the prefix, values unquoted.
    private static func appTargetInfoPlistKeys() throws -> [[String: String]] {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let blocks = project.components(separatedBy: "isa = XCBuildConfiguration;")
            .filter { $0.contains("INFOPLIST_FILE = Fernlet/Info.plist;") }
        return blocks.map { block in
            var keys: [String: String] = [:]
            for line in block.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("INFOPLIST_KEY_"), trimmed.hasSuffix(";"),
                      let equals = trimmed.range(of: " = ") else { continue }
                let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 14)..<equals.lowerBound])
                var value = String(trimmed[equals.upperBound...].dropLast())
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                }
                keys[key] = value
            }
            return keys
        }
    }

    /// The `en` value of every key in `App/Fernlet/InfoPlist.xcstrings`.
    private static func catalogEnglishValues() throws -> [String: String] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/InfoPlist.xcstrings"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        var values: [String: String] = [:]
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
            let unit = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            if let value = unit?["value"] as? String { values[key] = value }
        }
        return values
    }

    private static func appInfoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Every shipping Swift file's text, keyed by repo-relative path.
    private static func shippingSources() throws -> [String: String] {
        var sources: [String: String] = [:]
        for root in shippingRoots {
            let rootURL = RepoRoot.url(root)
            let files = (FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "swift" }
            for file in files {
                let relative = root + file.path.dropFirst(rootURL.path.count)
                sources[relative] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        return sources
    }

    /// ``shippingSources()`` with comments removed and literals emptied — code only.
    private static func shippingCode() throws -> [String: String] {
        try shippingSources().mapValues { SwiftSourceLexer.lex($0).code }
    }
}
