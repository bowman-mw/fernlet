// PrivacyWipeCoverageTests.swift
// FernletTests
//
// Mechanical enforcement of Docs/PrivacyWipeCoverage.md (bitchat adoptions Increment 1): the
// "Delete everything" path must keep clearing every persistence surface in the manifest below.
// Grep-style source scan in the S3BoundaryTests house pattern — removing a wipe call, or landing
// a new store without wiring + documenting it, fails here. To add a store: add its wipe call in
// `FernletStore.deleteAllData`, a row in the doc, and its token here — same commit.
//
// The scan is bounded to the BODIES of `deleteAllData` and `resetAll` (its one delegated leg), with
// comments stripped. It used to scan the whole 4,000-line `FernletStore.swift`, which meant a row
// could be satisfied by the same call spelled in an unrelated function — deleting
// `clothingShop.clearAll()` from the wipe kept the suite green because
// `setAllowNearbyClothingShares` also calls it. Bounded, that deletion fails.

import Foundation
import Testing
import FernletPersistence
import LocalPersistence
import PrivateMediaStore
import CryptoKit
@testable import Fernlet

@Suite
struct PrivacyWipeCoverageTests {

    /// One token per row of the doc's "Cleared by Delete everything" table. Tokens are call-site
    /// spellings inside the bodies of `FernletStore.deleteAllData` and `resetAll`.
    private static let wipeManifest: [String] = [
        // Pending work & cloud
        "snapshotSaveCoordinator.cancelPending",
        "setSealedBackupEnabled",
        "cloudCopyDeleteHook",
        // Sealed narratives + buffers
        "periodDataDeleteHook",
        "intimacyDataDeleteHook",
        "journalDataDeleteHook",
        "pendingNarrativeBufferPurgeHook",
        "deleteHealthSamples",
        // Media
        "mealPhotoStore.deleteAll",
        "progressPhotoStore.deleteAll",
        "recipePhotoStore.deleteAll",
        "sharedRecipeImportQueue.clear",
        "purgeDataExports",
        // Social / proximity
        "clothingShop.clearAll",
        "sessionMessages.clear",
        "presenceManager.stop",
        "proximityTrustVault.apply",
        "heartLedger.clearAll",
        "moderationLedger.clearAll",
        "friendStateCache.clearAll",
        "closenessLedger.clearAll",
        "activities.clearAll",
        // Per-row + local stores
        "resetDiary",
        "savedRecipeService.reset",
        "customItemService.reset",
        "coinLedgerService.reset",
        "aiRetryQueueService.reset",
        "scrubStressLocalState",
        "worryBoxResetHook",
        "BarcodeServingMemory.clearAll",
        "RecipeWebImageAttemptMemory.clearAll",
        "guidedRunStateStore.clear",
        "cookingRunStateStore.clear",
        "clearSensitiveVisibilityResolution",
        "ageAssurance.clear",
        "repository.purgeAllPersistedData",
        // Widget / AI runtime
        "widgetSnapshotMirror",
        "pendingWidgetActionQueue.clear",
        "aiCallQuotaStore.reset",
        "aiAuditLogStore.clear",
        // Keychain identity + at-rest keys (the Increment 1 gap fixes)
        "wipeIdentityForDeleteAll",
        "deviceJournalKey",
        "deviceWorryKey",
        "invalidateEncryptionKeyCache",
        // Away-hearts dead-drop state (Increment 3): prekeys, peer bundles, outbox, dedup + the
        // service's own identity cache. The remote purge is a SEPARATE row because it must run
        // first — it needs the record names the local wipe destroys.
        "heartDropService.purgeDeadDrop",
        "heartDropService.wipeForDeleteAll",
        // Settings
        "storagePreferencesResetHook",
    ]

    /// Calls the wipe path must NEVER make, with the reason it is banned. The inverse of the
    /// manifest: some deletions are bugs, and a green manifest says nothing about them.
    ///
    /// `deleteKeychainRowForWipe` deletes the ONE shared `com.fernlet.private-media` keychain row
    /// that encrypts every `PrivateMediaStore` — including `MeshNetworkManager.photoCacheStore`,
    /// the friend photo wall this funnel keeps BY DESIGN. Deleting it doesn't orphan a key, it
    /// shreds the wall: the next `mediaKey()` mints a fresh random key and every retained photo
    /// decrypts to garbage, permanently and with no failure signal. See the deliberate-exceptions
    /// table in Docs/PrivacyWipeCoverage.md.
    private static let bannedFromWipePath: [(token: String, why: String)] = [
        (
            "deleteKeychainRowForWipe",
            "deletes the shared media key that the deliberately-kept friend photo wall is encrypted with — every retained photo would decrypt to garbage after the next launch"
        )
    ]

    /// The three managers whose live in-memory identity caches must die with the keychain rows.
    private static let identitySeamFiles = [
        "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift",
        "FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift",
        "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift",
    ]

    /// The two functions that together ARE the wipe path, keyed by a unique substring of their
    /// declaration line.
    private static let wipeFunctionSignatures = [
        "func deleteAllData(includingHealthKitSamples",
        "func resetAll() -> [String]"
    ]

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Fernlet/FernletStore.swift").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fernletStoreSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("Fernlet/FernletStore.swift"), encoding: .utf8)
    }

    /// The comment-stripped bodies of the wipe functions, concatenated. Throws if either function
    /// cannot be located, so a rename fails loudly instead of scanning an empty string.
    private static func wipePathSource() throws -> String {
        let source = try fernletStoreSource()
        return try wipeFunctionSignatures.map { try functionBody(matching: $0, in: source) }.joined(separator: "\n")
    }

    /// Extracts one method body from `source`: from the declaration line down to the first line that
    /// is exactly the method-level closing brace. Every `FernletStore` method sits at one level of
    /// class indentation, so `"    }"` is an exact, unambiguous terminator — no brace counting, and
    /// nothing to get wrong on a nested closure. Comments are stripped line by line.
    static func functionBody(matching signature: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            throw BoundingError.functionNotFound(signature)
        }
        guard let end = lines[(start + 1)...].firstIndex(of: "    }") else {
            throw BoundingError.closingBraceNotFound(signature)
        }
        return lines[start...end].map(strippingComments).joined(separator: "\n")
    }

    enum BoundingError: Error, CustomStringConvertible {
        case functionNotFound(String)
        case closingBraceNotFound(String)

        var description: String {
            switch self {
            case .functionNotFound(let signature):
                return "Could not find '\(signature)' in FernletStore.swift — renamed? The wipe-coverage scan is bounded to it."
            case .closingBraceNotFound(let signature):
                return "Could not find the method-level closing brace after '\(signature)' — indentation changed?"
            }
        }
    }

    /// Drops a `//` comment tail so a token surviving only in prose (or in commented-out code) can't
    /// satisfy the manifest. `://` is left alone — that is a URL inside a string literal, not a
    /// comment.
    static func strippingComments(_ line: String) -> String {
        let characters = Array(line)
        var index = 0
        while index + 1 < characters.count {
            if characters[index] == "/", characters[index + 1] == "/" {
                if index > 0, characters[index - 1] == ":" {
                    index += 2
                    continue
                }
                return String(characters[0..<index])
            }
            index += 1
        }
        return line
    }

    @Test func deleteAllCoversEveryManifestSurface() throws {
        let wipePath = try Self.wipePathSource()
        let missing = Self.wipeManifest.filter { !wipePath.contains($0) }
        #expect(missing.isEmpty, "Wipe calls missing from the deleteAllData/resetAll bodies for: \(missing) — either restore the call or move the surface to the doc's deliberate-exceptions table AND remove its token here.")
    }

    /// The scan really is bounded, and really does ignore comments — otherwise the test above is the
    /// whole-file scan it replaced, and a deleted wipe call keeps passing.
    @Test func theScanIsBoundedToTheWipePathAndIgnoresComments() throws {
        let wipePath = try Self.wipePathSource()
        let wholeFile = try Self.fernletStoreSource()

        // Bounded: `setAllowNearbyClothingShares` also calls `clothingShop.clearAll()`, which is how
        // the old whole-file scan stayed green with the wipe's own call deleted.
        #expect(wholeFile.contains("func setAllowNearbyClothingShares"))
        #expect(!wipePath.contains("setAllowNearbyClothingShares"), "the scan reaches outside the wipe path — manifest rows can be satisfied by unrelated functions")
        #expect(wipePath.count < wholeFile.count / 3, "the extracted wipe path is implausibly large — the bounding is not bounding")

        // Comment-stripped: prose about a wipe call is not a wipe call.
        #expect(Self.strippingComments("        // heartLedger.clearAll()").trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(Self.strippingComments("        heartLedger.clearAll()  // takes the sidecar").contains("heartLedger.clearAll()"))
        #expect(Self.strippingComments(#"let u = "https://example.com""#).contains("example.com"))
    }

    /// The extractor, on a synthetic source — so a failure above points at the wipe path, not at the
    /// bounding logic.
    @Test func functionBodyExtractionStopsAtTheMethodBrace() throws {
        let source = """
        final class Thing {
            func wipe() {
                if flag {
                    inside()
                }
            }

            func other() {
                outside()
            }
        }
        """
        let body = try Self.functionBody(matching: "func wipe()", in: source)
        #expect(body.contains("inside()"))
        #expect(!body.contains("outside()"))
        #expect(throws: (any Error).self) { try Self.functionBody(matching: "func missing()", in: source) }
    }

    /// The banned-call check: a wipe call that DESTROYS a deliberately-kept surface must not come
    /// back. The manifest can't express this — it only ever asserts presence.
    @Test func wipePathMakesNoBannedCall() throws {
        let wipePath = try Self.wipePathSource()
        for banned in Self.bannedFromWipePath {
            #expect(!wipePath.contains(banned.token), "\(banned.token) is back in the wipe path: it \(banned.why).")
        }
    }

    @Test func everyLiveIdentityCacheHasAWipeSeam() throws {
        let root = try Self.repoRoot()
        for file in Self.identitySeamFiles {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("func wipeIdentityForDeleteAll"), "\(file) owns a live IdentityService but lost its wipe seam.")
        }
    }

    /// The in-memory seam still has to exist: the emptied meal/progress/recipe stores drop their
    /// cached key at the wipe. (The keychain ROW is a documented survivor — see
    /// `wipePathMakesNoBannedCall` and the deliberate-exceptions table.)
    @Test func mediaKeyCacheWipeSeamExists() throws {
        let root = try Self.repoRoot()
        let keyStore = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift"),
            encoding: .utf8
        )
        #expect(keyStore.contains("func invalidateCachedKey"))
    }

    @Test func coverageDocExistsWithExceptionsTable() throws {
        let root = try Self.repoRoot()
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)
        #expect(doc.contains("Deliberate exceptions"), "The wipe-coverage doc lost its deliberate-exceptions section.")
        // Every manifest token should be findable in the doc so the two stay in sync.
        let undocumented = Self.wipeManifest.filter { !doc.contains($0) }
        #expect(undocumented.isEmpty, "Tokens enforced here but not documented in PrivacyWipeCoverage.md: \(undocumented)")
    }

    /// Every `com.fernlet.*` keychain service the app uses must be named in one of the two tables —
    /// that is the doc's stated contract, and two services (the HealthKit anchors and the
    /// locked-note buffer key) used to be in neither.
    @Test func everyKeychainServiceIsDocumented() throws {
        let root = try Self.repoRoot()
        let doc = try String(contentsOf: root.appendingPathComponent("Docs/PrivacyWipeCoverage.md"), encoding: .utf8)

        var services: Set<String> = []
        for sourceRoot in ["Fernlet", "FernletKit/Sources"] {
            let rootURL = root.appendingPathComponent(sourceRoot)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                services.formUnion(Self.keychainServiceLiterals(in: source))
            }
        }

        // Discovery is name-anchored, so a service declared without "service" in its binding would be
        // missed silently. The floor makes that a loud failure instead (S3BoundaryTests house pattern).
        let missingFromDiscovery = Self.knownKeychainServices.subtracting(services).sorted()
        #expect(missingFromDiscovery.isEmpty, "Keychain-service discovery lost: \(missingFromDiscovery) — renamed, moved, or bound to something that isn't spelled '…service'.")

        let undocumented = services.filter { !doc.contains($0) }.sorted()
        #expect(undocumented.isEmpty, "Keychain services in neither wipe-coverage table: \(undocumented) — add each to the cleared table (with its wipe call) or to the deliberate-exceptions table (with why it survives).")
    }

    /// The services that exist today. A floor, not a whitelist: discovery still reports anything NEW,
    /// and that new service must be documented before this suite goes green.
    private static let knownKeychainServices: Set<String> = [
        "com.fernlet.lock", "com.fernlet.storage-preferences", "com.fernlet.journal",
        "com.fernlet.healthkit-anchors", "com.fernlet.private-media", "com.fernlet.narrative-buffer",
        "com.fernlet.heartdrop", "com.fernlet.identity", "com.fernlet.moderation",
        "com.fernlet.device-binding"
    ]

    /// `com.fernlet.*` keychain SERVICE literals in `source`, found by anchoring on the binding that
    /// consumes them — a `…service`-named constant or a `service:`/`keychainService:` parameter. That
    /// anchor is what separates a service from the per-item ACCOUNT names sharing its prefix
    /// (`com.fernlet.lock.salt`, `com.fernlet.private-media.contentKey`), from UserDefaults keys, and
    /// from the `com.fernlet.sealed-backup` HKDF label — none of which are keychain services.
    /// Literal-based because the constants are private/internal to their modules: nothing to import.
    static func keychainServiceLiterals(in source: String) -> Set<String> {
        let pattern = try? NSRegularExpression(pattern: #"ervice[^"\n]{0,24}"(com\.fernlet\.[^"]*)""#)
        guard let pattern else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: Set<String> = []
        for match in pattern.matches(in: source, range: range) {
            guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
            let literal = String(source[literalRange])
            // Suites scope their fixtures as "com.fernlet.identity.test.<uuid>".
            if !literal.contains(".test.") { found.insert(literal) }
        }
        return found
    }
}

/// The behavioral half of FIX 1: the shared at-rest media key must SURVIVE "delete everything", or
/// the friend photo wall the dialog promises to keep becomes unreadable noise on the next launch.
///
/// Separate suite because it drives a real `FernletStore` through the real funnel (the source scans
/// above are pure). Serialized for the same reason `DeleteAllDataTests` is: a live wipe touches
/// process-wide keychain + preferences state.
@MainActor
@Suite(.serialized)
struct PrivacyWipeMediaKeySurvivalTests {

    private func keyBytes(_ key: SymmetricKey?) -> Data? {
        key.map { $0.withUnsafeBytes { Data($0) } }
    }

    @Test func deleteAllKeepsTheSharedMediaKeySoTheKeptPhotoWallStaysReadable() async {
        // Mint (or read) the one shared row every PrivateMediaStore encrypts under.
        let before = keyBytes(KeychainPrivateMediaKeyProvider().mediaKey())
        #expect(before != nil, "precondition: could not read or mint the shared media key")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-media-key-\(UUID().uuidString).json")
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url))
        await store.deleteAllData(includingHealthKitSamples: false)

        // A FRESH provider holds no cached key, so this is the next launch reading the keychain —
        // exactly the path that used to mint a brand-new key and strand every retained photo.
        let after = keyBytes(KeychainPrivateMediaKeyProvider().mediaKey())
        #expect(
            after == before,
            "the wipe destroyed the shared media key: every photo on the deliberately-kept friend photo wall now decrypts to garbage"
        )
    }
}

/// The behavioral half of the `RecipeWebImageAttemptMemory.clearAll` manifest row (security-hardening
/// P0c): the device-local "one automatic web-image attempt per recipe" `UserDefaults` sidecar must be
/// REMOVED by "delete everything" — the reverse direction of `PrivacyWipeMediaKeySurvivalTests`, which
/// asserts survival of a deliberately-kept surface.
///
/// Separate suite for the same reason as the media-key one: it drives a real `FernletStore` through the
/// real `deleteAllData` funnel (the source scans above are pure), and a live wipe touches process-wide
/// keychain + preferences state, so it is serialized.
@MainActor
@Suite(.serialized)
struct PrivacyWipeAttemptMemoryRemovalTests {

    @Test func deleteAllClearsTheRecipeWebImageAttemptMemory() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-attempt-memory-\(UUID().uuidString).json")
        let store = FernletStore(repository: LocalFernletRepository(fileURL: url))
        // Isolate the sidecar from the shared `.standard` suite (the injection seam exists for
        // exactly this — see `webImageAttemptDefaults`); record + wipe still share ONE instance,
        // which is the contract the manifest token documents.
        let suiteName = "fernlet-tests-wipe-attempt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.webImageAttemptDefaults = defaults

        let recipeID = UUID()
        RecipeWebImageAttemptMemory.recordAttempt(recipeID, defaults: store.webImageAttemptDefaults)
        #expect(RecipeWebImageAttemptMemory.hasAttempted(recipeID, defaults: store.webImageAttemptDefaults),
                "precondition: the attempt was not recorded")

        await store.deleteAllData(includingHealthKitSamples: false)

        #expect(
            !RecipeWebImageAttemptMemory.hasAttempted(recipeID, defaults: store.webImageAttemptDefaults),
            "delete everything left the web-image attempt bookkeeping behind — the sidecar outlived the recipes it described"
        )
    }
}
