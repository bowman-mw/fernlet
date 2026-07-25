// PrivacyWipeCoverageTests.swift
// FernletTests
//
// Mechanical enforcement of Docs/PrivacyWipeCoverage.md (bitchat adoptions Increment 1): the
// "Delete everything" path must keep clearing every persistence surface in the manifest below.
// Grep-style source scan in the S3BoundaryTests house pattern — removing a wipe call, or landing
// a new store without wiring + documenting it, fails here. To add a store: add its wipe call in
// `FernletStore.deleteAllData`, a row in the doc, and its token here — same commit.

import Foundation
import Testing

@Suite
struct PrivacyWipeCoverageTests {

    /// One token per row of the doc's "Cleared by Delete everything" table. Tokens are call-site
    /// spellings inside Fernlet/FernletStore.swift (deleteAllData + resetAll + their hooks).
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
        "guidedRunStateStore.clear",
        "cookingRunStateStore.clear",
        "clearSensitiveVisibilityResolution",
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
        "deleteKeychainRowForWipe",
        "invalidateEncryptionKeyCache",
        // Settings
        "storagePreferencesResetHook",
    ]

    /// The three managers whose live in-memory identity caches must die with the keychain rows.
    private static let identitySeamFiles = [
        "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift",
        "FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift",
        "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift",
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

    @Test func deleteAllCoversEveryManifestSurface() throws {
        let root = try Self.repoRoot()
        let store = try String(contentsOf: root.appendingPathComponent("Fernlet/FernletStore.swift"), encoding: .utf8)
        let missing = Self.wipeManifest.filter { !store.contains($0) }
        #expect(missing.isEmpty, "Wipe calls missing from FernletStore for: \(missing) — either restore the call or move the surface to the doc's deliberate-exceptions table AND remove its token here.")
    }

    @Test func everyLiveIdentityCacheHasAWipeSeam() throws {
        let root = try Self.repoRoot()
        for file in Self.identitySeamFiles {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("func wipeIdentityForDeleteAll"), "\(file) owns a live IdentityService but lost its wipe seam.")
        }
    }

    @Test func mediaKeyWipeSeamsExist() throws {
        let root = try Self.repoRoot()
        let keyStore = try String(
            contentsOf: root.appendingPathComponent("FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift"),
            encoding: .utf8
        )
        #expect(keyStore.contains("func deleteKeychainRowForWipe"))
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
}
