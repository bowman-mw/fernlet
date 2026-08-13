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

    /// Anything reaching the device-local sensitive-surface sidecar: the period/intimacy visibility
    /// RESOLUTION and the age determination, which `FernletStore` deliberately keeps in ONE defaults
    /// suite (see `FernletStore.ageAssurance`), so one argument isolates both.
    ///
    /// Case matters (`String.contains`), hence the doubled spellings: lowercase
    /// `periodTrackingVisible` matches `settings.periodTrackingVisible` but NOT
    /// `isPeriodTrackingVisible` / `setPeriodTrackingVisible`.
    private static let sensitiveVisibilityTriggers = [
        // The sidecar itself.
        "sensitiveVisibilityDefaults", "SensitiveVisibility", "SensitiveSurfaceVisibility",
        // The visibility half — the settings values and the derived reads/setters.
        "periodTrackingVisible", "PeriodTrackingVisible",
        "intimacyTrackingVisible", "IntimacyTrackingVisible",
        // The age half, which shares the suite.
        "ageAssurance", "AgeAssuranceStore", "AgeGate",
        "selfAttest", "applyDetermination", "isIntimateLoggingAllowed",
        // The funnels. `resetAll()` is the one that matters most here: it calls BOTH
        // `clearSensitiveVisibilityResolution()` and `ageAssurance.clear()`, and it is far commoner
        // in these suites than `deleteAllData`.
        "deleteAllData", "resetAll(",
    ]

    /// Anything reaching the share-extension recipe inbox. Its funnel is `deleteAllData` ALONE —
    /// `resetAll()` does not touch the queue — which is why this list is not the app-group one even
    /// though both files live in the same container.
    private static let sharedRecipeInboxTriggers = [
        "sharedRecipeImportQueue", "SharedRecipeImportQueue", "SharedRecipeImportRecord",
        "processSharedRecipeImportQueue", "shared recipe inbox",
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

    /// The device-local sensitive-surface sidecar — the period/intimacy visibility resolution and the
    /// age verdict, which share ONE defaults suite by design.
    ///
    /// The widest blast radius of the family so far, for two reasons. Every `FernletStore.init` WRITES
    /// this sidecar (`reconcileSensitiveSurfaceVisibility` → `storeSensitiveVisibilityResolution`), and
    /// its wipe is `resetAll()` — which clears the resolution AND the age record, and which these
    /// suites call far more often than `deleteAllData`. On `.standard` one store's reset therefore
    /// returned every concurrently-live store to "never resolved" with no verdict, so the next read
    /// re-derived visibility from `sex` and both gates fell back to fail-closed mid-test.
    ///
    /// Neither half is recoverable from the synced blob, which is what makes this worse than a shared
    /// directory rather than merely equivalent: the age record is never synced at all, and the whole
    /// point of the resolution marker is to out-rank a blob whose visibility keys a mixed-version peer
    /// dropped.
    @Test func everySensitiveSurfaceTouchingStoreConstructionPinsItsOwnVisibilityDefaults() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard Self.sensitiveVisibilityTriggers.contains(where: { source.contains($0) }) else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("sensitiveVisibilityDefaults"),
                    """
                    \(file.lastPathComponent) reaches the device-local sensitive-surface sidecar but \
                    constructs FernletStore without `sensitiveVisibilityDefaults:`, so its \
                    period/intimacy visibility resolution and its age verdict live in `.standard` — \
                    which every concurrent `resetAll()` clears. Pass `sensitiveVisibilityDefaults: \
                    uniqueSensitiveVisibilityDefaults()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }
        // Floor well below the measured 34: this trigger set catches every `resetAll(`/`deleteAllData`
        // file, so the count tracks how many wipe tests exist rather than anything about isolation.
        #expect(scanned > 25, "the sensitive-visibility store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The share-extension recipe inbox — the app-group container's OTHER tenant, in
    /// `SharedRecipeImports/` rather than `FernletWidgets/`, so `appGroupDirectory` never covered it.
    /// A file seam rather than a directory one, because the queue owns exactly one file.
    ///
    /// Latent rather than live, unlike the app-group round: `deleteAllData` clears the queue for every
    /// concurrently-live store, but nothing reads the production file today because the two suites
    /// that exercise the drain hand-inject a queue of their own. Those hand-rolled injections are
    /// precisely the tell — writing the test the obvious way, by reaching for
    /// `store.sharedRecipeImportQueue`, is what would have joined the race.
    ///
    /// Nil still means production at every layer, and that rule is load-bearing beyond tests here: the
    /// share extension is a separate process with NO seam and its own hand-copied path resolution, so
    /// an app resolving anywhere else would strand every shared-in recipe in a file nothing drains —
    /// and there is no share-extension test target to notice.
    @Test func everySharedRecipeInboxTouchingStoreConstructionPinsItsOwnQueueFile() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard Self.sharedRecipeInboxTriggers.contains(where: { source.contains($0) }) else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("sharedRecipeImportQueueFileURL"),
                    """
                    \(file.lastPathComponent) reaches the share-extension recipe inbox but constructs \
                    FernletStore without `sharedRecipeImportQueueFileURL:`, so its queue is the real \
                    `<group.MBO.Fernlet>/SharedRecipeImports/PendingRecipeURLs.json` that every \
                    concurrent delete-all empties. Pass `sharedRecipeImportQueueFileURL: \
                    uniqueSharedRecipeImportQueueURL()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }
        // Floor below the measured 11, on the same reasoning as the AI-quota wall: at 11 a `> 10` floor
        // goes red the first time a wipe test is deleted, for reasons unrelated to isolation.
        #expect(scanned > 8, "the shared-recipe-inbox store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// Every isolation seam `FernletStore.init` takes, in the order the initializer declares them.
    ///
    /// Adding a seam means adding it here — this list is what the helper-forwarding wall below walks.
    private static let isolationSeams = [
        "appGroupDirectory", "sharedRecipeImportQueueFileURL", "photoDocumentsDirectory",
        "proximitySupportDirectory", "heartDropKeychainService", "aiQuotaDefaults",
        "sensitiveVisibilityDefaults",
    ]

    /// The blind spot the seven walls above share: they only look at DIRECT `FernletStore(...)`
    /// constructions, and their whole escape hatch is "or build the store through the helpers". A
    /// helper that takes a seam parameter and then forgets to FORWARD it silently un-isolates every
    /// store built through it, and passes all seven walls while doing so — the argument is present at
    /// the construction site, just wired to the helper's own fresh default instead of the caller's.
    ///
    /// Swift never warns about an unused parameter, so nothing else catches it. This is not
    /// hypothetical: `makeTestStore` was landed in exactly that state during this round —
    /// `sharedRecipeImportQueueFileURL` declared, defaulted, and dropped on the floor — and the only
    /// thing that noticed was one behavioral test's third-store assertion. Every other test that asked
    /// two stores to share a file would simply have got two files and quietly proved nothing.
    @Test func everyTestStoreHelperForwardsEveryIsolationSeamItAccepts() throws {
        let helpersURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("FernletTestHelpers.swift")
        let source = Self.strippingComments(try String(contentsOf: helpersURL, encoding: .utf8))

        for helper in ["makeTestStore", "makeTestStoreWithRepositories", "makeStoreSharingStores"] {
            let body = try #require(Self.functionBody(of: helper, in: source),
                                    "\(helper) not found in FernletTestHelpers.swift — has it been renamed?")
            for seam in Self.isolationSeams where body.contains("\(seam):") {
                #expect(
                    body.contains("\(seam): \(seam)"),
                    """
                    \(helper) accepts `\(seam):` but never forwards it, so every store it builds gets \
                    the callee's own fresh default and the caller's value is silently discarded. Two \
                    stores handed the same \(seam) would land on two different ones — which is not a \
                    failure, it is a test that proves nothing. Pass `\(seam): \(seam)` through.
                    """
                )
            }
        }
    }

    /// The source of `func <name>(...)` through its closing brace, or nil when the function is absent.
    ///
    /// The parameter list is skipped by PAREN depth before any brace counting starts, which is
    /// load-bearing rather than fastidious: `makeTestStoreWithRepositories` ends its signature with
    /// `wrapNarrativeStore: ... = { $0 }`, so taking the first `{` after the name would return that
    /// default closure as the entire "body" — and the wall would then fail for every seam, on a
    /// helper that forwards all of them.
    private static func functionBody(of name: String, in source: String) -> String? {
        guard let signature = source.range(of: "func \(name)(") else { return nil }
        var index = source.index(before: signature.upperBound)   // the `(` itself
        var parenDepth = 0
        while index < source.endIndex {
            if source[index] == "(" { parenDepth += 1 }
            if source[index] == ")" {
                parenDepth -= 1
                if parenDepth == 0 { break }
            }
            index = source.index(after: index)
        }
        guard index < source.endIndex else { return nil }
        var braceDepth = 0
        var sawBrace = false
        while index < source.endIndex {
            if source[index] == "{" { braceDepth += 1; sawBrace = true }
            if source[index] == "}" {
                braceDepth -= 1
                if sawBrace, braceDepth == 0 { return String(source[signature.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The comment stripper is what stops every wall above from being satisfied by prose, so it
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
    /// "see `photoDocumentsDirectory`" and not the argument passes every wall here, which is
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
