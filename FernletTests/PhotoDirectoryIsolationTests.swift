import Foundation
import Testing
@testable import Fernlet

/// Grep-wall keeping every test `FernletStore` on its OWN own-photo root.
///
/// The own-photo corpora (meal, recipe, progress) are shared *on-disk* state: `resetAll`,
/// `deleteAllData` and the duress wipe all call `deleteAll()` on all three. XCTest and Swift Testing
/// suites run in parallel inside a single test process, so a store built on the process-wide
/// container root has its photos deleted out from under it the moment ANY concurrently-running test
/// wipes. That is not theoretical: `RecipeReimportTests.failedReimportLeavesTheRecipeUntouched`
/// failed three full-suite runs in a row (`store.recipePhotoData(for:)` came back nil) while passing
/// in isolation every time.
///
/// `FernletStore.photoDocumentsDirectory` is the per-instance seam that fixes it, and the test
/// helpers default it to `uniquePhotoDirectory()`. This wall covers the other half — a test that
/// constructs `FernletStore` DIRECTLY and forgets the argument silently rejoins the race, and the
/// symptom lands in somebody else's suite. Source-scanning is the only way to catch that: the
/// omission compiles, and the resulting flake is by definition not reproducible in isolation.
struct PhotoDirectoryIsolationTests {
    /// This file names the constructor in its own scanner literals, so exclude it from the sweep.
    private static let excludedFiles: Set<String> = ["PhotoDirectoryIsolationTests.swift"]

    /// Anything that can reach state rooted at `proximitySupportDirectory` — the properties
    /// themselves, the managers whose builders touch them, the derived reads, and the two wipe
    /// funnels that clear the lot.
    ///
    /// Deliberately over-broad. A missing trigger is a silent false NEGATIVE that lands in another
    /// suite; a spurious one only asks a file for an argument it could pass anyway.
    private static let proximityRootedTriggers = [
        // Managers — build the photo wall, the activity ledger, and (via their builders) the ledger.
        "meshNetworkManager", "MeshNetworkManager(", "presenceManager",
        // Heart state on the same root.
        "heartLedger", "heartDropService", "heartGlow", "pendingHeartBubble", "queueHeart", "heartsAway",
        // The three JSONSidecarFile stores.
        "moderationLedger", "friendStateCache", "closenessLedger",
        // The funnels that clear every one of the above.
        "deleteAllData", "resetAll(",
    ]

    /// The subset of the above that reaches the SEALED heart-drop sidecars, i.e. the only state on
    /// this root whose isolation also needs a keychain service. The ledger is deliberately absent:
    /// it is unsealed, so the directory alone is its whole fix.
    private static let sealedHeartTriggers = [
        "heartDropService", "queueHeart", "heartsAway", "deleteAllData",
    ]

    /// Anything reaching the shared app-group directory `<group.MBO.Fernlet>/FernletWidgets/` — the
    /// guided-run and cooking-run state files, the inbound widget-action queue, the widget snapshot.
    ///
    /// Case matters (`String.contains`): "guidedRun" alone does NOT match `startGuidedRun`, hence the
    /// explicit spellings.
    private static let appGroupRootedTriggers = [
        // Guided run — GuidedWorkoutRunState.json
        "guidedRunState", "startGuidedRun", "clearGuidedRun", "abandonGuidedRun",
        "reconcileGuidedRunFromAppGroup", "guidedMarkSetDone", "guidedSkipRest",
        "guidedSessionForResume", "activeGuidedRunBlockingStart", "GuidedWorkoutRunState",
        // Cooking run — CookingRunState.json
        "cookingRunState", "startCookingRun", "endCookingRun", "cookingAdvanceStep",
        "cookingGoBack", "cookingStartTimer", "cookingClearTimer",
        "reconcileCookingRunFromAppGroup", "CookingRunStateStore", "cookingRunAdvancedByIntent",
        // Widget bridge — PendingWidgetActions.json + WidgetSnapshot.json
        "pendingWidgetActionQueue", "PendingWidgetActionQueue(", "processPendingWidgetActions",
        "activateWidgetBridge", "PendingWidgetAction(", "widgetSnapshotMirror",
        "WidgetSnapshotMirror(", "WidgetSnapshotFileStore(", "WidgetBridgeFiles",
        // The funnels: `resetAll` clears both run files, `deleteAllData` also clears the queue.
        "deleteAllData", "resetAll(",
    ]

    /// Anything reaching the device-local AI-call counter. Its identity is a defaults SUITE, and
    /// `deleteAllData` is its ONLY wipe — `resetAll()` does not touch it, which is why this list is
    /// not simply the app-group one.
    private static let aiQuotaTriggers = [
        "aiCallQuotaStore", "effectiveAIStatus", "aiGate",
        "AICallQuota", "currentQuota", "recordCall",
        "deleteAllData",
    ]

    @Test func everyDirectStoreConstructionInTestsPinsItsOwnPhotoDirectory() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Recursive: subdirectories (Mocks/, and anything added later) are covered too.
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("photoDocumentsDirectory"),
                    """
                    \(file.lastPathComponent) constructs FernletStore without `photoDocumentsDirectory:`, \
                    so it shares the process-wide own-photo root with every other live store — any \
                    concurrent test that wipes will delete its photos. Pass \
                    `photoDocumentsDirectory: uniquePhotoDirectory()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }

        // Never pass vacuously: a moved test root or a broken scanner must fail loudly, not quietly
        // stop covering anything.
        #expect(scanned > 20, "the FernletStore construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The friend photo wall is the same hazard one media key over: `MeshNetworkManager` loads
    /// `MeshPhotoCache.json` at init and re-saves the WHOLE index on `deletePhoto` /
    /// `deleteAllSessionPhotos`, so on a process-wide root one manager silently inherits — and then
    /// overwrites — another suite's album.
    ///
    /// The root now rides `ProximityHost.proximitySupportDirectory`, so a manager built from a
    /// helper-made store is isolated for free. What still needs walling is the other half: a file
    /// that reaches proximity state while building its store DIRECTLY gets the production root back,
    /// and the damage lands in whichever suite happens to be running beside it.
    ///
    /// The wall covers the WHOLE root, not just the photo wall. Everything below hangs off it, and
    /// each one is destroyed by some wipe:
    ///
    /// | sidecar | cleared by |
    /// | --- | --- |
    /// | `MeshPhotoCache.json` + wall prefs | not by the funnel (a documented survivor), but re-saved whole per manager |
    /// | `HeartLedger.json` | `resetAll` |
    /// | `HeartDropOutbox/Dedup/PeerBundles.json` | `deleteAllData` (plus their seal key — see the next wall) |
    /// | `ModerationLedger.json` | `resetAll` |
    /// | `FriendStateCache.json` | `resetAll`, **and** turning fuzzy-state sharing off |
    /// | `ClosenessLedger.json` | `resetAll` |
    /// | `ActivityLedger.json` | `resetAll`, via `meshNetworkManager.activities` |
    @Test func everyProximityTouchingStoreConstructionPinsItsOwnProximityDirectory() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Every store on that root is `lazy`, so a file reaching none of these builds nothing and
            // cannot join the race.
            guard Self.proximityRootedTriggers.contains(where: { source.contains($0) }) else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("proximitySupportDirectory"),
                    """
                    \(file.lastPathComponent) reaches state rooted at the proximity-sidecar directory \
                    but constructs FernletStore without `proximitySupportDirectory:`, so that state \
                    lives on the process-wide root and races every concurrently-live store. Pass \
                    `proximitySupportDirectory: uniqueProximityDirectory()`, or build the store \
                    through makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }

        // A real site floor now that this covers the whole root rather than just mesh-touching files
        // (the old mesh-only scan could only assert the tree resolved). Well under this means the
        // paren-matcher broke or a trigger was dropped, not that the codebase got tidier.
        #expect(scanned > 10, "the proximity-rooted store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The sealed heart-drop sidecars need a SECOND half the rest of the root does not: their key.
    /// `deleteAllData` calls `heartDropService.wipeForDeleteAll()`, which deletes the outbox,
    /// peer-bundle and dedup files AND every row under the heart-drop keychain service — where the
    /// key sealing those files lives.
    ///
    /// This wall checks only that half; the directory half is the wall above, whose trigger list is a
    /// strict superset (every token here appears there), so a file reaching sealed heart state is
    /// asked for both arguments by exactly one wall each. Passing only the directory is worse than
    /// passing neither: files on a private root sealed by a shared key survive another suite's wipe
    /// as ciphertext nothing can open, which the outbox quarantines and latches as sticky data loss.
    @Test func everyHeartTouchingStoreConstructionPinsItsOwnHeartDropScope() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard Self.sealedHeartTriggers.contains(where: { source.contains($0) }) else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("heartDropKeychainService"),
                    """
                    \(file.lastPathComponent) reaches the SEALED heart-drop sidecars but constructs \
                    FernletStore without `heartDropKeychainService:`, so the key sealing its outbox / \
                    dedup / peer-bundle files stays on the process-wide `com.fernlet.heartdrop` \
                    service that every concurrent delete-all deletes by service — leaving this \
                    store's files unopenable and quarantined. Pass `heartDropKeychainService: \
                    uniqueHeartDropKeychainService()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }

        // A real site floor: the wipe suites construct stores directly in bulk. Well under this means
        // the paren-matcher broke or the test root moved, not that the codebase got tidier.
        #expect(scanned > 10, "the sealed-heart store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The app-group container is the same hazard on a different mount point, and it is the one that
    /// was demonstrably LIVE rather than latent: `resetAll` clears `GuidedWorkoutRunState.json` and
    /// `CookingRunState.json`, `deleteAllData` also clears `PendingWidgetActions.json`, while
    /// `GuidedWorkoutRunStoreTests` reads the guided file through a real store — so a wipe in
    /// `DeleteAllDataTests` landed in the middle of it.
    ///
    /// One argument covers all four files because they are genuine co-tenants of one directory: a
    /// relaunch sees the whole container, so isolating them together is what a real relaunch models.
    @Test func everyAppGroupTouchingStoreConstructionPinsItsOwnAppGroupDirectory() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard Self.appGroupRootedTriggers.contains(where: { source.contains($0) }) else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("appGroupDirectory"),
                    """
                    \(file.lastPathComponent) reaches the shared app-group container but constructs \
                    FernletStore without `appGroupDirectory:`, so its guided/cooking run state and \
                    widget queue live in the real container that every concurrent wipe clears. Pass \
                    `appGroupDirectory: uniqueAppGroupDirectory()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }
        #expect(scanned > 10, "the app-group store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The AI-call counter, whose identity is a UserDefaults SUITE rather than a path — the same
    /// lesson the heart-drop seal key taught, one axis over. `deleteAllData` calls
    /// `aiCallQuotaStore.reset()`, so on `.standard` one store's wipe zeroes every other live
    /// store's quota.
    ///
    /// Its trigger set is deliberately NOT the app-group one: `resetAll()` does not touch the
    /// counter, so files that only reset would be asked for an argument they do not need.
    @Test func everyAIQuotaTouchingStoreConstructionPinsItsOwnQuotaDefaults() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard Self.aiQuotaTriggers.contains(where: { source.contains($0) }) else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("aiQuotaDefaults"),
                    """
                    \(file.lastPathComponent) reaches the device-local AI-call counter but constructs \
                    FernletStore without `aiQuotaDefaults:`, so its quota lives in `.standard` — which \
                    every concurrent delete-all resets. Pass `aiQuotaDefaults: \
                    uniqueAIQuotaDefaults()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }
        // Floor set below the measured 11: a `> 10` floor here would go red the first time a wipe
        // test is deleted, for reasons that have nothing to do with isolation.
        #expect(scanned > 8, "the AI-quota store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The comment stripper is what stops all three walls above from being satisfied by prose, so it
    /// gets its own coverage rather than being trusted — including the two cases that would quietly
    /// break it: a `//` inside a string literal (a URL), and an escaped quote.
    @Test func theCommentStripperKeepsCodeAndDropsProse() {
        let strip = Self.strippingComments
        #expect(!strip("a, // photoDocumentsDirectory: x\n b").contains("photoDocumentsDirectory"))
        #expect(!strip("a, /* proximitySupportDirectory: y */ b").contains("proximitySupportDirectory"))
        #expect(strip("photoDocumentsDirectory: x // note").contains("photoDocumentsDirectory: x"))
        // A `//` inside a string must NOT start a comment, or the rest of a real argument list is eaten.
        #expect(strip("url: \"https://e.com\", heartDropKeychainService: s")
            .contains("heartDropKeychainService: s"))
        #expect(strip("a: \"\\\"//\", proximitySupportDirectory: d").contains("proximitySupportDirectory: d"))
        // An unterminated block comment must not run off the end and drop everything after it.
        #expect(strip("a, /* unterminated").contains("a,"))
    }

    /// `text` with `//` and `/* */` comments removed, string literals preserved.
    ///
    /// Applied to every extracted argument list before the walls look for an argument NAME in it.
    /// Without this the scan is satisfied by prose: a construction carrying the comment
    /// "see `photoDocumentsDirectory`" and not the argument passes all three walls, which is
    /// precisely backwards — these files comment their isolation arguments heavily, so the token is
    /// likelier to appear in a comment than anywhere else.
    static func strippingComments(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
            } else if character == "\"" {
                inString = true
                output.append(character)
                index += 1
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index = min(index + 2, characters.count)
            } else {
                output.append(character)
                index += 1
            }
        }
        return output
    }

    /// The argument list of every `FernletStore(...)` construction in `source`, paren-matched so a
    /// nested call (`LocalFernletRepository(fileURL:)`) or a multi-line call is captured whole.
    /// String literals are skipped so a paren inside one can't unbalance the scan. Comments are
    /// stripped from the result — see ``strippingComments(_:)``.
    private static func storeConstructionArguments(in source: String) -> [String] {
        let characters = Array(source)
        let needle = Array("FernletStore(")
        var results: [String] = []
        var index = 0
        while index + needle.count <= characters.count {
            guard Array(characters[index..<(index + needle.count)]) == needle else {
                index += 1
                continue
            }
            // `.FernletStore(` / `MockFernletStore(` are different symbols — require a boundary.
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber
                || characters[index - 1] == "_" || characters[index - 1] == "." {
                index += 1
                continue
            }
            var depth = 0
            var inString = false
            var cursor = index + needle.count - 1
            var argumentStart = cursor + 1
            while cursor < characters.count {
                let character = characters[cursor]
                if inString {
                    if character == "\\" { cursor += 2; continue }
                    if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" {
                    depth += 1
                    if depth == 1 { argumentStart = cursor + 1 }
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        results.append(strippingComments(String(characters[argumentStart..<cursor])))
                        break
                    }
                }
                cursor += 1
            }
            index = cursor + 1
        }
        return results
    }
}
