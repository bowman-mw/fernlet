// BackgroundRefreshBoundaryTests.swift
// FernletTests
//
// Network migration P10 item 2 (plan §16.4, §17.2): the background-refresh import wall.
//
// §17.2 specifies the companion `BGAppRefreshTask` as a handler with seven steps and a hard list of
// things it must NEVER do: touch the mesh, touch HealthKit, force a CloudKit sync, reach Foundation
// Models, or create a store while protected data is unavailable. §16.4 makes the mechanical half of
// that prohibition a repository gate, and requires it in the FIRST commit that adds any refresh
// code — a wall that lands after the handler is arguing with a fait accompli.
//
// **Why the scan is by DIRECTORY and not by file name.** P9's lesson, paid for once: an anchor
// needle that checked four hand-listed files is a wall over four files, not over a boundary. Item 3
// (the scheduling seam) and item 4 (the handler) add their files AFTER this suite exists, so the
// wall must cover files that do not exist yet. It walks `App/Fernlet/CompanionRefresh/` and holds
// whatever it finds, which is also why item 2 creates that directory with a real file in it: a
// directory that stopped resolving would enumerate nothing and pass vacuously, so the floor and the
// positive needle below exist to make an empty or gutted directory RED.
//
// **This file's own literals are never scanned.** The scan root is the refresh directory; this
// suite lives in `Tests/FernletTests`, so the needle list can name every forbidden spelling in
// plain text without counting itself — the trap `ProximityRunSeamsTests` and `S3BoundaryTests`
// both avoid the same way.
//
// Shape copied from `MessagesExtensionBoundaryTests` (directory walk + module allowlist + floor +
// matcher fixture) and `S3BoundaryTests` (token needles at identifier boundaries, planted-violation
// fixtures, a discovery set that may never collapse to empty). `S3BoundaryTests.importedModules` and
// `.containsAtIdentifierBoundary` are reused rather than re-implemented, so the two walls cannot
// disagree about what an import is or where an identifier ends.
//
// The ten radio verbs are the one thing here that is COPIED rather than reused: nothing in
// `ProximityRunSeamsTests` exposes them as a constant — six are literals at its own call sites and
// four live in a local array inside one function — so `theRadioVerbNeedlesAreStillSpokenByTheSeamsWall`
// checks the copy against that file instead, and a verb renamed out from under this wall reds here.

import Foundation
import Testing

/// The companion background-refresh boundary: what `App/Fernlet/CompanionRefresh/` may import, what
/// it may never name, and the proof that the directory is still there to be scanned.
///
/// ## Why the module allowlist alone is not the wall
///
/// **The umbrella is not porous.** There is no module called `FernletKit`: it is a PRODUCT over 25
/// targets and no target carries that name, so nothing can `import FernletKit`. There is no
/// `@_exported` anywhere in the tree, `FernletDomainModel` depends only on `FernletFoundation`, and
/// the app target builds with `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — so a file
/// that does not import ProximityKit cannot reach a ProximityKit member even through a value it was
/// handed. For everything that lives in a PACKAGE module, the import allowlist is a real wall.
///
/// **The app target is porous, and that is why the call-spelling list exists.** The refresh handler
/// lives in the app target, which is one Swift module, so every app-resident declaration that is
/// `internal` or wider is nameable from the refresh directory with no import line whatsoever:
/// `FernletStore`, `FernletStoreAccess`, `WidgetSnapshotMirror`, `FernletStoreLoader`,
/// `MeshContinuationTaskHost`, and every `FernletStore` extension declared under `App/Fernlet/` —
/// which is where the radio funnel lives. `store.applyProximityRunPolicy(…)` re-runs the radios and
/// imports nothing; `store.meshNetworkManager` hands the caller the radio itself and imports
/// nothing; `store.refreshWorkoutsFromHealth()` reaches the HealthKit path and imports nothing;
/// `FernletStore.load(…)` builds a second store and imports nothing. An import-only wall is green
/// over all four. ``theRefreshDirectoryNamesNoForbiddenSpelling()`` is the wall that
/// holds them, and the module allowlist is the cheap outer fence that catches the naive version
/// first and names it clearly.
///
/// **ACCESS LEVEL is the second gate, and the list has to respect it.** What a `private` member is
/// NOT is speakable from a second file. This wall's first shape named the PRIVATE funnels —
/// `runProximityPolicy`, `applyProximityRunPolicyFromView`, `healthSyncCoordinator` — while their
/// `internal` callers were absent, so a probe file that spoke only the reachable spellings
/// (`store.applyProximityRunPolicy(…)`, `store.refreshWorkoutsFromHealth()`,
/// `store.meshContinuationHost.…`) built and passed the wall green. The private funnels are kept
/// below as BELT — an access level is one keyword away from changing, and
/// ``everyAppDeclaredNeedleIsStillDeclaredUnderTheAppTarget()`` keeps a kept needle from going
/// stale — and the internal doors beside them are the BRACES.
///
/// ## What was surveyed, and the rule the list follows
///
/// The handler can obtain exactly three app-target things: the `FernletStore` it acquires through
/// `FernletStoreAccess.shared.load()`, `FernletStoreAccess.shared` itself, and the widget-bridge
/// types it publishes through. Everything else it might reach has to NAME its type at this site
/// first, and the prohibited TYPES are needles — so the survey is bounded to the `internal`-or-wider
/// members of those three: `App/Fernlet/FernletStore.swift` and every `FernletStore` extension under
/// `App/Fernlet/` (`ProximityRunSeams.swift`, `ProximitySessionPoller.swift`,
/// `ProximityHostAdapter.swift`, `FernletStore+DemoSeed.swift`), plus `FernletStoreAccess.swift` and
/// `WidgetBridge.swift`, read for declarations whose identifier or body names `Proximity`,
/// `Mesh`/`mesh`, `Health`/`health`, `HK`, `CloudKit`/`CK`/`iCloud`, `sync`, `FoundationModels`,
/// `LanguageModel`, `Presence`/`presence`, `RecipeShare`/`recipeShare` or `Continuation`. Re-run
/// that grep when item 3 or item 4 lands, and again whenever a member is added to the store.
///
/// A hit becomes a needle when using it RUNS, HANDS OUT or FEEDS the prohibited machinery. A hit
/// that only reads or writes an INERT record does not, and the excluded set is written down here
/// rather than left unmentioned, so the cut is visible and can be re-argued: `meshSessionStorage`,
/// `meshRoutedStorage`, `heartDropStorage`, `proximityTrustVault`, `proximitySupportRoot`,
/// `proximitySupportDirectory`, `proximityDisplayName`, `presenceEnablePromptRequested`,
/// `proximityRunVerdict` (the funnel's OUTPUT, never its input), `setProximityDisplayName`,
/// `setShowProximityDebugTools`; the trust and moderation roster (`trustedProximityPeers`,
/// `trustedProximityPeer`, `trustProximityPeer`, `keepProximityFriends`,
/// `revokeTrustedProximityPeer`, `blockProximityPeer`, `unblockProximityPeer`,
/// `reportProximityPeer`, `isTrustedProximityPeer`, `isRevokedProximitySigningKey`,
/// `isBlockedProximitySigningKey`, `isBlockedFingerprint`, `isProximitySellerBanned`,
/// `isClothingItemLocallyReported`, `reconcileModerationBans`, `recomputeCloseFriendsIfNeeded`,
/// `recordTrainerAudit`, `trainerAuditEvents`, `fundMediaAtRestWitness`); the recipe-share text
/// helpers (`savedRecipeShareText`, `recipeShareText`, `proximityRecipeSharePayload`,
/// `importProximityRecipeShare`); the read-only health projections (`allowedHealthCapabilities`,
/// `visibleHealthCapabilities`, `dailyHealthScore`, `workoutExists`); and
/// `syncCustomExerciseCatalog`, which registers a catalog and syncs nothing. A review that
/// disagrees adds the row and raises ``measuredSpellingCount`` in the same commit.
///
/// Methods reached only THROUGH another app type are covered by that type's needle rather than one
/// of their own: `HealthSyncCoordinator.removeWorkoutFromHealth(fernletWorkoutID:)` is internal, but
/// the store's handle on it is `private`, so a second file has to spell `HealthSyncCoordinator` to
/// get one — and that is a needle. Enumerating those types' members would be a copy of their APIs
/// held together by nothing.
///
/// ## PERMITTED to the handler (item 4 reads this list)
///
/// `FernletStoreAccess.shared` and its `load(…)` — the one sanctioned acquisition, which already
/// refuses while protected data is unavailable; `todayKey`, the day roll's key; `companionState` and
/// `companionThought`, the companion recompute's reads; `publishWidgetSnapshot()` and
/// `widgetSnapshotMirror`, the publish step; and `WidgetBridge` / `WidgetSnapshot` /
/// `WidgetSnapshotMirror` themselves. None of them is a needle, and none may become one without item
/// 4 losing a step.
///
/// Item 4 adds the five spellings it actually calls, each with the step it serves:
///
/// - `refreshCurrentDayIfNeeded(now:)` — the DAY ROLL. The same internal call the foreground scene
///   makes at `.active`. Traced: it flushes the outgoing day under its old key, re-keys the diary,
///   rebuilds the derived signals, reconciles the coin and milestone ledgers, and publishes through
///   the store's own mirror. Reads and writes the app's OWN repositories and nothing else — no
///   HealthKit call, no radio, no forced CloudKit sync.
/// - `hasUndrainedWidgetActions` — the WIDGET-QUEUE CHECK, a non-destructive read behind one store
///   property so the handler never names the queue type. It claims nothing, so asking cannot lose a
///   row (decision D-10.4.2).
/// - `currentWidgetSnapshot()` — the DIFF's left-hand side, lifted out of `publishWidgetSnapshot()`
///   unchanged. Pure: the live day, the settings, the derived signals.
/// - `ensureWidgetSnapshotMirror()` — the PUBLISH step's precondition. A cold background wake has no
///   scene, so `activateWidgetBridge()` never ran and there is no mirror to publish through.
/// - `publishIfContentChanged(_:)` — the PUBLISH step and the reload decision, on
///   `WidgetSnapshotMirror`, which owns both the file and the `reloadTimelines` closure.
///
/// ## What this suite does NOT claim
///
/// It is a source scan, so it says nothing about what the handler DOES — that it rolls the day
/// once, diffs before publishing, or completes exactly once is item 4's behaviour and item 9's
/// acceptance battery. It cannot police a rename: a forbidden type renamed everywhere in one sweep
/// would satisfy every needle here by accident. And it cannot see a reach that goes through a
/// value the handler was HANDED — an injected closure that starts a radio names no forbidden token
/// at this site. Those are review's job; this is the part a review cannot be relied on to repeat.
///
/// ## Red-once plan (plan §16.4; execute as: disable → REBUILD → run → keep the log → restore → REBUILD)
///
/// | Cell | Plant |
/// | --- | --- |
/// | ``theRefreshDirectoryExistsAndHoldsAtLeastOneSwiftFile()`` | `git mv App/Fernlet/CompanionRefresh App/Fernlet/CompanionRefreshX` — the enumerator finds nothing and the floor reds. Restore with the inverse `git mv`. |
/// | ``theRefreshDirectoryImportsOnlyTheHandlersOwnVocabulary()`` | Add `import ProximityKit` as the first line of `App/Fernlet/CompanionRefresh/CompanionRefreshIdentifier.swift`. |
/// | ``everyFernletKitModuleIsClassifiedForTheRefreshHandler()`` | Delete the `"ProximityKit"` entry from ``forbiddenModuleReasons``; the Package.swift walk finds a module with no disposition. |
/// | ``theRefreshDirectoryNamesNoForbiddenSpelling()`` | One plant per family, each chosen to compile: `import ProximityKit` + `static let probe: MeshNetworkManager? = nil`; the same shape for `HKHealthStore`, `CKContainer` and `LanguageModelSession`; `@MainActor func redOnceProbe() async throws { _ = try await FernletStore.load() }` below the enum — the important one, because it adds NO import and so reds this cell alone; and, for the clock-and-persistence family, `Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }` inside `CompanionRefreshCoordinator`. Per-NEEDLE independence is discharged without 83 rebuilds by ``everyForbiddenSpellingIsMatchableAndTheListIsWhole()``, which plants each needle into a synthetic source in-process and fails if any one of them cannot be matched. |
/// | ``theClockAndPersistenceFamilyIsWholeAndReadingTheClockIsNot()`` | Delete any clock-or-persistence row, or re-word its reason past ``clockAndPersistenceReasonPrefix``; the family pin reds. Buildless. |
/// | ``theTaskIdentifierAppearsExactlyOnceAsCode()`` | Comment out the `taskIdentifier` line in the scaffold file (the count drops to zero), then paste a second copy into a new file under the directory (the count rises to two). Both directions must red. |
/// | ``everyForbiddenSpellingIsMatchableAndTheListIsWhole()`` | Delete any one entry from ``forbiddenSpellings``; the measured count pin reds. |
/// | ``theModuleAllowlistIsARealFilterAndNotARubberStamp()`` | Add `"ProximityKit"` to ``permittedModuleReasons``. |
/// | ``theStripperSeesCodeAndNotProseOrLiterals()`` | Change ``stripped(_:removingStringLiterals:)`` to return its input unchanged. |
/// | ``theStripperIsATableOfInputsAndExpectedOutputs()`` | Blank string interpolations along with the literal around them (the shape this suite shipped first); row 2 reds with its input, expected and actual. Buildless — the whole table is a pure function over strings. |
/// | ``everyAppDeclaredNeedleIsStillDeclaredUnderTheAppTarget()`` | Misspell an app-declared needle (`meshNetworkManagerX`); the declaration set does not hold it. Point ``appTargetRoot`` at an empty directory and the floor reds instead, which is the other half. |
/// | ``theRadioVerbNeedlesAreStillSpokenByTheSeamsWall()`` | Misspell one radio-verb token in ``forbiddenSpellings`` (`.startJoinX(`); the seams wall no longer speaks it. That plant leaves ``everyForbiddenSpellingIsMatchableAndTheListIsWhole()`` green, which is the point — the matcher can see the misspelling; the app cannot. |
struct BackgroundRefreshBoundaryTests {

    // MARK: - The scan root

    /// The directory that is the boundary. Every `.swift` file under it, at any depth, is refresh
    /// code and is held to everything below.
    static let refreshRoot = "App/Fernlet/CompanionRefresh"

    /// Floor for the walk, MEASURED: item 2's identifier, item 3's scheduling seam and coordinator,
    /// and item 4's pipeline and wiring. A root that stops resolving reports zero and would
    /// otherwise pass vacuously, which is the failure mode `RepoRoot`'s own doc comment exists to
    /// describe — so the floor tracks the real count rather than staying at one.
    static let minimumFilesScanned = 5

    /// The companion refresh's frozen task identifier, repeated here on purpose.
    ///
    /// Repeated, not imported: this suite does not link the app target, and a wall that read the
    /// value out of the thing it is checking could not notice the value changing. `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers` carries the same literal, and iOS matches it
    /// literally — so the three copies moving apart is exactly the silent failure worth a test.
    static let taskIdentifier = "MBO.Fernlet.companion-refresh"

    // MARK: - The module allowlist

    /// Everything the refresh handler's seven steps need, with the step each name serves.
    ///
    /// Small on purpose. A name added here is a claim that a ≤ 30 s opportunistic task needs a new
    /// framework, and it belongs in a review with that argument, not in a drive-by edit. The
    /// omissions are as deliberate as the entries: `SwiftUI` (a background task draws nothing),
    /// `UIKit` (the protected-data guard is `FernletStoreAccess`'s, and the handler acquires the
    /// store through it rather than re-deciding), `Combine`, `CoreData`.
    static let permittedModuleReasons: [String: String] = [
        "Foundation": "dates, `Codable`, `URL` — the day roll and the snapshot diff.",
        "BackgroundTasks": "`BGAppRefreshTask` / `BGTaskScheduler` — the task itself (items 3 and 4).",
        "WidgetKit": "`WidgetCenter.reloadTimelines` — the publish step's last act, as `WidgetBridge` does it.",
        "FernletFoundation": "`FernletDate` and the App Group directory helpers `WidgetBridge` is written against.",
        "FernletDomainModel": "the pure value types the day roll, the companion recompute and the snapshot diff speak.",
        "os": "`Logger` — a refresh that leaves no trace cannot be read off a device console."
    ]

    /// The permitted set, derived so the reasons and the filter can never drift apart.
    static let permittedModules: Set<String> = Set(permittedModuleReasons.keys)

    /// Every FernletKit target (and the package's one external dependency) that the refresh handler
    /// may NOT import, with the one-line reason. Read against `FernletKit/Package.swift` by
    /// ``everyFernletKitModuleIsClassifiedForTheRefreshHandler()``, so a module added to the package
    /// fails this wall until somebody decides which side of it the refresh handler is on.
    static let forbiddenModuleReasons: [String: String] = [
        "ProximityKit": "the mesh itself — §17.2's first prohibition; a refresh that can reach a radio is a second owner of them.",
        "AIProviders": "the FoundationModels inference module; §17.2 forbids Foundation Models outright.",
        "AIContext": "the de-identified AI payload contract — the handler has no AI step, so naming it would mean one was added.",
        "CloudKitSync": "the CloudKit + Core Data sync stack; §17.2 forbids a force-sync from the handler.",
        "HealthKitGateway": "HealthKit; `FernletStoreAccess.load()` defaults its `healthKitService` to nil, so the handler never names the seam.",
        "PrivateHealthStore": "sealed cycle/intimacy data, and it imports HealthKit besides.",
        "PrivateMemoryStore": "the sealed journal repository.",
        "PrivateMediaStore": "the sealed photo index.",
        "PrivateStoreCore": "the sealed Core Data substrate all three sealed stores ride.",
        "PeriodContextBridge": "raw-cycle egress; it reaches PrivateHealthStore by construction.",
        "FernletLock": "the app lock — an unlock drains the sealed pending-narrative buffer, and a background task must never move the lock.",
        "FernletLockUI": "the lock's SwiftUI surface; a background task presents nothing.",
        "AppServices": "it depends on AIProviders, and carries WeatherKit, CoreLocation and UserNotifications.",
        "WebScrapingKit": "the private-browsing URLSession; the refresh handler makes no network request at all.",
        "FernletExchange": "the Messages / App Group transport edge — none of the seven steps is an exchange.",
        "FernletPersistence": "the repository contract; the handler reads the store it acquired, never a repository.",
        "LocalPersistence": "the local repository and database — store creation under another name.",
        "StoreCore": "the store-side services (snapshot save coordinator, retry queue); the handler must not open a save path of its own.",
        "DiaryStore": "the portable diary slice — reached through the acquired `FernletStore` facade, never constructed here.",
        "FernletScoring": "the scoring engine; §17.2's companion recompute is deterministic over state the store already scored.",
        "FoodCatalog": "the USDA catalog and its bundled sqlite — not something to open inside a ≤ 30 s opportunistic task.",
        "FernletUI": "the design system; a background task draws nothing.",
        "FernletCrypto": "the sealing primitives; the handler seals nothing — the widget snapshot is the benign mirror by design.",
        "CryptoSwift": "FernletLock's Scrypt KDF, the package's one external dependency; nothing here derives a key."
    ]

    /// Apple frameworks named by §17.2 (or adjacent to it) that the allowlist already excludes,
    /// spelled out so the wall's reasons are readable without cross-referencing the specification.
    static let forbiddenAppleFrameworkReasons: [String: String] = [
        "HealthKit": "§17.2: never HealthKit.",
        "CloudKit": "§17.2: never a CloudKit force-sync.",
        "FoundationModels": "§17.2: never Foundation Models.",
        "MultipeerConnectivity": "a mesh transport; §17.2: never the mesh.",
        "Network": "the QUIC transport's framework; same prohibition.",
        "NearbyInteraction": "UWB ranging — a radio.",
        "ActivityKit": "Live Activities; the refresh publishes to the widget, and presents nothing itself.",
        "SwiftUI": "a background task draws nothing.",
        "UIKit": "the protected-data guard belongs to `FernletStoreAccess`, which the handler acquires through."
    ]

    // MARK: - The call-spelling zero-list

    /// One forbidden spelling and why it is forbidden. `token` is matched as written.
    struct Spelling: Sendable {
        /// The code token a real violation would have to contain.
        let token: String
        /// One line on what naming it would mean.
        let why: String
        /// True when `token` is itself a declaration under `App/Fernlet/` — a `FernletStore` member
        /// or an app-resident type — so ``everyAppDeclaredNeedleIsStillDeclaredUnderTheAppTarget()``
        /// can prove the needle still names something that exists. False for package and Apple types
        /// (the import wall is their gate, and this suite does not walk their sources) and for the
        /// verb tokens, which carry a `.` or a `(` and are checked against `ProximityRunSeamsTests`
        /// instead.
        let isAppDeclaration: Bool

        init(token: String, why: String, isAppDeclaration: Bool = false) {
            self.token = token
            self.why = why
            self.isAppDeclaration = isAppDeclaration
        }
    }

    /// Every spelling that must not appear under the refresh directory.
    ///
    /// Each is a CODE token a real violation would have to contain, not a word from the prose about
    /// it: matched over source with comments and string literals removed, so the wall states
    /// something about code rather than about the paragraph explaining why the code does not do the
    /// thing. Identifier-shaped tokens match at identifier boundaries
    /// (`S3BoundaryTests.containsAtIdentifierBoundary`) so a needle never fires on a longer,
    /// unrelated name a later file might legitimately carry (`HealthKitServiceStub`,
    /// `PresenceManagerSpy`). Tokens carrying a `(` or a leading `.` are matched as plain
    /// substrings, because identifier-boundary matching would refuse `FernletStore(healthKit…` on
    /// its right-hand flank and answer a violation with a green.
    ///
    /// **The containment sets the boundary rule earns.** Every needle below was grepped across
    /// `App/Fernlet/` for identifiers that merely contain it; these are all of them, and
    /// ``theMatcherSeparatesLookalikeIdentifiersAndIgnoresProse()`` asserts each reports itself and
    /// only itself:
    ///
    /// - `PersistenceController` inside `PrivatePersistenceController` — both separately forbidden,
    ///   so both are listed.
    /// - `applyProximityRunPolicy` inside BOTH `reapplyProximityRunPolicy` and
    ///   `applyProximityRunPolicyFromView` — a triple, and all three are needles: the funnel's
    ///   internal scene/view edges, its internal store edge, and the view's private helper.
    /// - `removeWorkout` inside `removeWorkoutByHealthKitUUID` (a needle) and inside
    ///   `removeWorkoutFromHealth` (a `HealthSyncCoordinator` method, reached only by naming that
    ///   type, which is its own needle).
    ///
    /// `HealthKitService` and `HealthKitServicing` look like a pair and are not one: "Servicing" is
    /// "Servic" + "ing", so neither string contains the other. They are two separate symbols, both
    /// needles because both are separately reachable.
    ///
    /// The clock family adds one more containment, and one near-miss worth writing down.
    /// `DispatchSource` is inside `DispatchSourceTimer` and both are needles, so a
    /// `DispatchSourceTimer` line must report the longer one and only it. `Timer` is inside
    /// `DispatchSourceTimer` too and must report NOTHING there — its left flank is a letter — which
    /// is precisely why the longer spelling needs a row of its own rather than being assumed
    /// covered. `KeychainItem` is a row and a bare `Keychain` is deliberately not: at identifier
    /// boundaries the bare word matches almost nothing the app can write (`refreshStateFromKeychain`
    /// and `lockKeychainService` are both refused on a flank), so the doors are named instead — the
    /// accessor and the four `SecItem…(` calls under it.
    ///
    /// The radio-verb rows are the same ten spellings `ProximityRunSeamsTests`' retirement wall
    /// counts, reused deliberately: if the app renames a verb, both walls must be edited together
    /// and neither can drift into naming a verb that no longer exists.
    static let forbiddenSpellings: [Spelling] = [
        // The mesh, as TYPES (§17.2: never the mesh). Package and Apple names: the import wall is
        // their first gate and these are the belt behind it.
        Spelling(token: "ProximityKit", why: "the mesh module, qualified or imported"),
        Spelling(token: "MeshNetworkManager", why: "the mesh manager itself"),
        Spelling(token: "ProximityCoordinator", why: "the proximity fan-out"),
        Spelling(token: "PresenceManager", why: "the presence listener"),
        Spelling(token: "ProximityRecipeShareManager", why: "the recipe-share listener"),
        Spelling(token: "MeshContinuationDriver", why: "the continuation claim; a refresh task is not a continuation task", isAppDeclaration: true),
        Spelling(token: "MeshContinuationTaskHost", why: "the continuation's scheduler half", isAppDeclaration: true),
        Spelling(token: "BGContinuedProcessingTask", why: "the mesh's task class — the refresh uses `BGAppRefreshTask`"),
        // The run funnel. The BRACES are the three `internal` edges a second file can speak; the
        // two BELT rows below them are `private` today (`FernletStore.runProximityPolicy`,
        // `ContentView.applyProximityRunPolicyFromView`) and unreachable from the refresh
        // directory — kept because an access level is one keyword away from changing.
        Spelling(token: "applyProximityRunPolicy", why: "the funnel's SCENE and VIEW edges — two internal `@discardableResult` overloads straight into the private core", isAppDeclaration: true),
        Spelling(token: "reapplyProximityRunPolicy", why: "the funnel's STORE edge — internal, reachable with NO import, which is why it is here", isAppDeclaration: true),
        Spelling(token: "executeProximityRunActions", why: "the radio executor — the one place a verb is spoken", isAppDeclaration: true),
        Spelling(token: "runProximityPolicy", why: "belt: the private core the three edges funnel into", isAppDeclaration: true),
        Spelling(token: "applyProximityRunPolicyFromView", why: "belt: the view's private funnel helper", isAppDeclaration: true),
        // The live machinery a `private(set)` hands out whole. The property is internal to READ, so
        // `store.meshNetworkManager.…` needs no import and no funnel.
        Spelling(token: "meshNetworkManager", why: "hands out the radio manager itself", isAppDeclaration: true),
        Spelling(token: "presenceManager", why: "hands out the presence listener", isAppDeclaration: true),
        Spelling(token: "recipeShareManager", why: "hands out the recipe-share listener", isAppDeclaration: true),
        Spelling(token: "meshContinuationHost", why: "hands out the `BGContinuedProcessingTask` host — a refresh task is not a continuation task", isAppDeclaration: true),
        Spelling(token: "heartDropService", why: "hands out the heart dead-drop service — proximity delivery and its CloudKit leg", isAppDeclaration: true),
        // The internal writers that FEED or RE-RUN the funnel.
        Spelling(token: "setMeshContinuation", why: "writes the continuation claim AND re-runs the funnel", isAppDeclaration: true),
        Spelling(token: "meshContinuationState", why: "the claim the policy reads back as an input on its next pass", isAppDeclaration: true),
        Spelling(token: "meshContinuationLastAudit", why: "the claim's audit half, settable beside it", isAppDeclaration: true),
        Spelling(token: "setAllowNearbyPresence", why: "the presence opt-in — its setter re-runs the funnel, which starts or stops the listener", isAppDeclaration: true),
        Spelling(token: "setAllowNearbyRecipeShares", why: "the recipe-share opt-in — same setter shape, same funnel re-run", isAppDeclaration: true),
        Spelling(token: "setAllowNearbyClothingShares", why: "the clothing-share opt-in — reaches the mesh manager directly", isAppDeclaration: true),
        Spelling(token: "syncSessionPoller", why: "starts or stops the mesh session poll timer off `meshNetworkManager.isSessionLive`", isAppDeclaration: true),
        Spelling(token: "deleteAllData", why: "the wipe bracket — it drives the manager, the continuation host and the funnel in one call", isAppDeclaration: true),
        Spelling(token: "resetAll", why: "the reset bracket, which reaches the mesh manager the same way", isAppDeclaration: true),
        // The ten radio verbs, as `ProximityRunSeamsTests` spells them.
        Spelling(token: ".startJoin(", why: "radio verb"),
        Spelling(token: ".stopJoin(", why: "radio verb"),
        Spelling(token: ".resumeSearchingForPartitionedMesh(", why: "radio verb"),
        Spelling(token: ".holdCommittedLinks(", why: "radio verb"),
        Spelling(token: ".leaveSession()", why: "radio verb"),
        Spelling(token: ".endSessionAfterDiscoveryTimeout(", why: "radio verb"),
        Spelling(token: "presenceManager.start(", why: "listener verb"),
        Spelling(token: "presenceManager.stop(", why: "listener verb"),
        Spelling(token: "recipeShareManager.start(", why: "listener verb"),
        Spelling(token: "recipeShareManager.stop(", why: "listener verb"),
        // HealthKit as TYPES (§17.2: never HealthKit).
        Spelling(token: "HKHealthStore", why: "the Health store"),
        Spelling(token: "HealthKitService", why: "the gateway"),
        Spelling(token: "HealthKitServicing", why: "the gateway's seam — `load()` defaults it to nil"),
        Spelling(token: "HealthSyncCoordinator", why: "the store's health sync coordinator — and the only way to reach its own methods, since the store's handle on it is private", isAppDeclaration: true),
        Spelling(token: "healthSyncCoordinator", why: "belt: that coordinator's property, `private` on the store today", isAppDeclaration: true),
        Spelling(token: "attachedHealthKitService", why: "hands out the gateway itself — P10 item 4 added it to the store, and a getter that RETURNS the prohibited thing is reachable with no import and no type name at the call site", isAppDeclaration: true),
        Spelling(token: "attachHealthKitServiceIfMissing", why: "the late-attach door beside it; the handler acquires through `FernletStoreAccess`, which does the attaching, and has no business doing it itself", isAppDeclaration: true),
        // The internal store members that DRIVE the health coordinator.
        Spelling(token: "refreshWorkoutsFromHealth", why: "pulls workouts out of HealthKit — the door the import wall is green over", isAppDeclaration: true),
        Spelling(token: "backfillWorkoutsFromHealthIfNeeded", why: "the same pull, on the launch backfill path", isAppDeclaration: true),
        Spelling(token: "stopHealthKitWorkoutObservation", why: "tears down the HealthKit observer query", isAppDeclaration: true),
        Spelling(token: "updateHealthContext", why: "writes the day's HealthKit-derived context", isAppDeclaration: true),
        Spelling(token: "scrubHiddenHealthContext", why: "rewrites the day's health context behind the sealed-dimension gate", isAppDeclaration: true),
        Spelling(token: "setWorkoutHealthKitUUID", why: "binds a workout to its HealthKit sample", isAppDeclaration: true),
        Spelling(token: "removeWorkoutByHealthKitUUID", why: "the HealthKit-side removal path", isAppDeclaration: true),
        Spelling(token: "healthKitSampleDeleteHook", why: "the authored-sample delete hook — assigning or calling it is a Health write", isAppDeclaration: true),
        Spelling(token: "addWorkout", why: "the workout write path, which drives `HealthSyncCoordinator` — a background write into Health", isAppDeclaration: true),
        Spelling(token: "updateWorkout", why: "the same write path on an edit, coordinator and all", isAppDeclaration: true),
        Spelling(token: "removeWorkout", why: "the same write path on a delete, which asks the coordinator to remove the sample", isAppDeclaration: true),
        // CloudKit (§17.2: never a force-sync).
        Spelling(token: "CKContainer", why: "the CloudKit container"),
        Spelling(token: "CKDatabase", why: "a CloudKit database"),
        Spelling(token: "CloudKitDataService", why: "the app's CloudKit entry point"),
        Spelling(token: "PersistenceController", why: "the CloudKit-backed Core Data stack, including `reload(with:)`"),
        Spelling(token: "PrivatePersistenceController", why: "the sealed Core Data stack"),
        Spelling(token: "CoreDataFernletRepository", why: "the synced repository"),
        Spelling(token: "cloudCopyDeleteHook", why: "the hook that deletes the day-blob copy in the user's private CloudKit zone without a live session", isAppDeclaration: true),
        // Foundation Models (§17.2: never Foundation Models).
        Spelling(token: "LanguageModelSession", why: "an on-device model session"),
        Spelling(token: "SystemLanguageModel", why: "the on-device model"),
        Spelling(token: "FoundationModels", why: "the framework, qualified or imported"),
        Spelling(token: "@Generable", why: "a generated-output schema — an AI call by another spelling"),
        // Store creation (§17.2: never create a store; acquire the existing one).
        Spelling(token: "FernletStore(", why: "constructing a second store over the same repositories"),
        Spelling(token: "FernletStore.load(", why: "the creation path — acquire through `FernletStoreAccess.shared.load()` instead"),
        Spelling(token: "FernletStoreLoader", why: "the scene bootstrap; the handler is not a scene", isAppDeclaration: true),
        Spelling(token: "FernletStoreAccess(", why: "a SECOND acquisition cache — `.shared` is the point of the type"),
        // Clocks and persistence (plan §26.3/§27.3: schedule at handle + background, never on a
        // timer; and no new persisted surface). Every reason carries
        // ``clockAndPersistenceReasonPrefix`` so the family is derivable rather than listed twice.
        Spelling(token: "Timer", why: "clock or persistence: the class the app owns exactly ONE of (`ProximitySessionPoller`'s), and a refresh that polled for its own next submission would be the second"),
        Spelling(token: "DispatchSourceTimer", why: "clock or persistence: a timer that contains neither `Timer` nor `DispatchQueue` at an identifier boundary, which is why it is its own row"),
        Spelling(token: "DispatchSource", why: "clock or persistence: `DispatchSource.makeTimerSource()` is the door that builds one"),
        Spelling(token: "DispatchQueue", why: "clock or persistence: `asyncAfter` is a clock wearing a queue's clothes"),
        Spelling(token: "RunLoop", why: "clock or persistence: a `RunLoop`-scheduled block is the third way to the same place"),
        Spelling(token: "sleep(", why: "clock or persistence: one needle for `Task.sleep(`, `Thread.sleep(`, `usleep(` and the C call — a loop that waits is a clock"),
        Spelling(token: "Task.detached", why: "clock or persistence: an unstructured task outliving the handler is work the completion can no longer account for"),
        Spelling(token: "UserDefaults", why: "clock or persistence: the tree's usual persisted surface, and the one the wipe wall demands a disposition row for"),
        Spelling(token: "FileManager", why: "clock or persistence: anything written to disk from the handler is a surface a wipe has to find"),
        Spelling(token: "NSUbiquitousKeyValueStore", why: "clock or persistence: the same, in iCloud, where a wipe cannot reach it at all"),
        Spelling(token: "KeychainItem", why: "clock or persistence: `FernletFoundation`'s keychain accessor — reachable with a PERMITTED import, which is exactly why the import wall cannot be its gate"),
        Spelling(token: "SecItemAdd(", why: "clock or persistence: the raw keychain write, under the accessor"),
        Spelling(token: "SecItemCopyMatching(", why: "clock or persistence: the raw keychain read"),
        Spelling(token: "SecItemUpdate(", why: "clock or persistence: the raw keychain rewrite"),
        Spelling(token: "SecItemDelete(", why: "clock or persistence: the raw keychain delete — removing a row is still touching the surface")
    ]

    /// The prefix every clock-or-persistence reason carries.
    ///
    /// The family is derived from it rather than listed a second time, for
    /// ``theRadioVerbNeedlesAreStillSpokenByTheSeamsWall()``'s reason: two lists of the same tokens
    /// drift, and `CompanionRefreshSchedulingTests` reads this prefix to pin that the family still
    /// exists at all.
    static let clockAndPersistenceReasonPrefix = "clock or persistence: "

    /// MEASURED count of the clock-and-persistence family at the P10 item 3 fix.
    ///
    /// The family arrived late: item 3's scheduling suite carried these spellings as a literal list
    /// over three hand-named PATHS, which is a wall over three files — item 4's handler lands in the
    /// same directory and was outside it. Moving them here makes them a property of the DIRECTORY,
    /// the way every other needle already is.
    static let measuredClockAndPersistenceCount = 15

    /// MEASURED count of ``forbiddenSpellings`` at P10 item 2. Removing a needle is a deliberate
    /// retirement with an argument, never a side effect of an edit; raise this in the same commit
    /// that adds one.
    ///
    /// 41 at the first shape, 68 after the verify survey: the first list named the PRIVATE funnels
    /// and none of the `internal` doors beside them, so the 27 rows added are the spellings a second
    /// file in the app target could actually speak. 83 after item 3's verify, which added the
    /// 15-row clock-and-persistence family — see ``measuredClockAndPersistenceCount``. 85 at item 4,
    /// which re-ran the survey this list's own doc comment asks for and found TWO rows it owed: the
    /// handler's acquire fix added `attachedHealthKitService` and `attachHealthKitServiceIfMissing`
    /// to `FernletStore`, and the first of them hands out the gateway to any file that can name the
    /// store — with no import and without naming `HealthKitServicing` at the call site, which is
    /// precisely the shape the import wall is green over.
    static let measuredSpellingCount = 85

    /// MEASURED count of the ``forbiddenSpellings`` rows that name a declaration under
    /// `App/Fernlet/`, pinned for the same reason the verb count is: the drift cell derives its set
    /// from a flag, and a flag dropped in an edit would shrink it without failing anything.
    static let measuredAppDeclarationCount = 38

    /// The app-target root the declaration-drift cell walks.
    static let appTargetRoot = "App/Fernlet"

    /// Floor for that walk — the target held 181 Swift files at P10 item 2, and a walk that stops
    /// resolving would report zero and pass every needle vacuously.
    static let minimumAppFilesScanned = 150

    /// How deep ``stripped(_:removingStringLiterals:)`` follows nested string interpolation before
    /// it gives up and blanks the rest of the literal. Four would do for anything in this tree; the
    /// cap exists because an unbounded nesting counter is an unbounded loop by another name.
    static let maximumInterpolationDepth = 8

    /// The retirement wall the ten radio-verb needles are COPIED from, because there is no shared
    /// constant to read: `ProximityRunSeamsTests` spells its six manager verbs as literals at its
    /// own `homes(of:in:)` call sites and keeps its four listener verbs in a local array inside one
    /// function body. ``theRadioVerbNeedlesAreStillSpokenByTheSeamsWall()`` is what makes the copy
    /// self-checking.
    static let seamsWallPath = "Tests/FernletTests/ProximityRunSeamsTests.swift"

    /// MEASURED count of the verb rows in ``forbiddenSpellings`` at P10 item 2: six manager verbs
    /// and four listener verbs, which is exactly what `ProximityRunSeamsTests` counts. Pinned
    /// because the verb rows are derived by their `why`, and a re-worded reason would otherwise
    /// empty that set without failing anything.
    static let measuredRadioVerbCount = 10

    // MARK: - Cells

    /// The directory is there, holds Swift files, and the walk found them.
    @Test func theRefreshDirectoryExistsAndHoldsAtLeastOneSwiftFile() throws {
        let files = try Self.swiftFiles()
        #expect(
            files.count >= Self.minimumFilesScanned,
            """
            Walked \(files.count) Swift file(s) under \(Self.refreshRoot) (floor \
            \(Self.minimumFilesScanned)) — the directory moved, was renamed, or was emptied, and \
            the background-refresh import wall is now scanning nothing. Restore the directory or \
            move this wall with it; do NOT lower the floor.
            """
        )
    }

    /// Nothing under the refresh directory imports outside the handler's own vocabulary.
    @Test func theRefreshDirectoryImportsOnlyTheHandlersOwnVocabulary() throws {
        let files = try Self.swiftFiles()
        #expect(files.count >= Self.minimumFilesScanned, "the walk lost the refresh directory (\(files.count) files)")

        var offenders: [String] = []
        // R2: bounded by the file list.
        for file in files {
            // R2: bounded by that file's import count.
            for module in S3BoundaryTests.importedModules(in: file.source).sorted()
            where !Self.permittedModules.contains(module) {
                offenders.append("\(file.path): import \(module)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) disallowed import(s) under \(Self.refreshRoot). The companion \
            refresh handler is a ≤ 30 s opportunistic task limited to: acquire the existing store → \
            roll day → recompute the companion → diff the snapshot → publish via WidgetBridge → \
            reload timelines only on change → complete once (plan §17.2). It may never reach the \
            mesh, HealthKit, CloudKit, Foundation Models, or build a store. Permitted: \
            \(Self.permittedModules.sorted().joined(separator: ", ")).
            \(offenders.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Every module the package declares has a side of this wall recorded against it.
    ///
    /// The point is the module that does not exist yet: a new FernletKit target is invisible to the
    /// allowlist (which only ever says "not permitted") until somebody writes down whether the
    /// refresh handler may have it. This makes that omission a failing test.
    @Test func everyFernletKitModuleIsClassifiedForTheRefreshHandler() throws {
        let manifest = try RepoRoot.source("FernletKit/Package.swift")
        let declared = Self.declaredNames(in: manifest)
        #expect(
            declared.count >= 26,
            "parsed only \(declared.count) `name:` entries out of FernletKit/Package.swift — the manifest's shape changed and this walk now reads almost nothing"
        )

        // `FernletKit` is the package and the umbrella library; no target carries that name, so
        // nothing can import it and it needs no disposition.
        let classified = Self.permittedModules
            .union(Self.forbiddenModuleReasons.keys)
            .union(["FernletKit"])
        let unclassified = declared.subtracting(classified)
        #expect(
            unclassified.isEmpty,
            """
            \(unclassified.count) FernletKit module(s) have no disposition for the companion \
            refresh handler: \(unclassified.sorted().joined(separator: ", ")). Add each to \
            `permittedModuleReasons` (with the refresh step it serves) or to \
            `forbiddenModuleReasons` (with the reason), in this commit.
            """
        )

        // The four §17.2 prohibitions are named explicitly, so a sweep cannot quietly drop one.
        // R2: bounded by the literal list.
        for module in ["ProximityKit", "AIProviders", "HealthKitGateway", "CloudKitSync"] {
            #expect(Self.forbiddenModuleReasons[module] != nil, "\(module) lost its forbidden-module reason")
            #expect(!Self.permittedModules.contains(module), "\(module) is on the permitted list — that is §17.2's prohibition, inverted")
        }
    }

    /// No file under the refresh directory names a mesh, HealthKit, CloudKit, Foundation Models or
    /// store-creation spelling.
    ///
    /// This is the half that actually holds, because the app target is one module: the tokens below
    /// are reachable from a file with no import line at all.
    @Test func theRefreshDirectoryNamesNoForbiddenSpelling() throws {
        let files = try Self.swiftFiles()
        #expect(files.count >= Self.minimumFilesScanned, "the walk lost the refresh directory (\(files.count) files)")

        var offenders: [String] = []
        // R2: bounded by the file list.
        for file in files {
            offenders.append(contentsOf: Self.violations(in: file.source, path: file.path))
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) forbidden spelling(s) under \(Self.refreshRoot), over \(files.count) \
            file(s) scanned. Plan §17.2: the companion refresh may never touch the mesh, HealthKit, \
            a CloudKit force-sync or Foundation Models, and may never create a store — it acquires \
            the existing one through `FernletStoreAccess.shared.load()`, which already refuses when \
            protected data is unavailable. A handler that can reach a radio is a second owner of \
            the radios.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// The identifier is under the directory exactly once, as code.
    ///
    /// Both directions matter. Zero means the directory was emptied or reduced to comments, and
    /// every negative cell above would then pass over nothing. Two means the literal was copied
    /// instead of referenced, which is how `Info.plist` and the code drift apart silently — iOS
    /// matches `BGTaskSchedulerPermittedIdentifiers` literally and simply stops delivering the task.
    @Test func theTaskIdentifierAppearsExactlyOnceAsCode() throws {
        let files = try Self.swiftFiles()
        var sites: [String] = []
        // R2: bounded by the file list.
        for file in files {
            // R2: bounded by that file's line count.
            for (number, line) in Self.codeLines(file.source, removingStringLiterals: false)
            where line.contains(Self.taskIdentifier) {
                sites.append("\(file.path):\(number)")
            }
        }
        #expect(
            sites.count == 1,
            """
            The companion refresh identifier `\(Self.taskIdentifier)` occurs \(sites.count) time(s) \
            as code under \(Self.refreshRoot) (\(files.count) file(s) scanned); it must occur \
            exactly once. Zero means the directory was gutted and every other cell here is passing \
            over nothing. More than one means the literal was copied rather than referenced through \
            `CompanionRefresh.taskIdentifier` — and the copies will drift from `Info.plist`'s \
            `BGTaskSchedulerPermittedIdentifiers`, which iOS matches literally.
            \(sites.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Fixtures: the wall's own machinery

    /// Every needle is individually matchable, and the list is whole.
    ///
    /// This is what makes each negative needle independently reddenable without 83 rebuilds: a
    /// needle whose spelling the matcher cannot see is a cell that can never fail, and this plants
    /// each one into a synthetic source and demands a hit. The count pin is the other half — a
    /// needle silently removed from the list is a prohibition silently retired.
    @Test func everyForbiddenSpellingIsMatchableAndTheListIsWhole() {
        #expect(
            Self.forbiddenSpellings.count == Self.measuredSpellingCount,
            """
            `forbiddenSpellings` holds \(Self.forbiddenSpellings.count) needle(s), measured \
            \(Self.measuredSpellingCount). RAISE the pin in the commit that adds a needle; LOWER it \
            only with the retirement argued, which is the whole point of the pin.
            """
        )

        var tokens: Set<String> = []
        // R2: bounded by the needle list.
        for spelling in Self.forbiddenSpellings {
            let isNew = tokens.insert(spelling.token).inserted
            #expect(isNew, "duplicate needle \(spelling.token)")
            #expect(!spelling.why.isEmpty, "\(spelling.token) carries no reason")
            let planted = "let probe = \(spelling.token)\n"
            #expect(
                !Self.violations(in: planted, path: "Planted.swift").isEmpty,
                "the matcher cannot see a planted `\(spelling.token)` — that cell can never fail"
            )
        }
    }

    /// The ten copied radio verbs are still spellings the app actually speaks.
    ///
    /// A copied needle list has one failure mode that matters, and it is silent: the app renames a
    /// verb, `ProximityRunSeamsTests` reds and is edited with it, and this wall is left holding a
    /// spelling nothing can ever contain — a cell that can never fail, passing green forever. The
    /// needles are therefore checked against the wall they were copied from, as CODE (the comment
    /// cut applies, so a stale mention in that file's prose does not satisfy this).
    ///
    /// The verb rows are derived from ``forbiddenSpellings`` by their `why` rather than listed a
    /// third time, so the two halves here cannot be edited apart; the count pin is what makes a
    /// re-worded reason red instead of quietly emptying the set.
    @Test func theRadioVerbNeedlesAreStillSpokenByTheSeamsWall() throws {
        let verbs = Self.forbiddenSpellings.filter { $0.why.hasSuffix(" verb") }.map(\.token)
        #expect(
            verbs.count == Self.measuredRadioVerbCount,
            """
            \(verbs.count) needle(s) carry a `… verb` reason, measured \
            \(Self.measuredRadioVerbCount). This cell derives the copied list from those reasons, \
            so a re-worded reason would shrink it without failing anything — hence the pin.
            """
        )

        let seams = try RepoRoot.source(Self.seamsWallPath)
        let code = Self.codeLines(seams, removingStringLiterals: false).map(\.1)
        var missing: [String] = []
        // R2: bounded by the verb list.
        for verb in verbs where !code.contains(where: { $0.contains(verb) }) {
            missing.append(verb)
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.count) radio-verb needle(s) no longer appear as code in \
            \(Self.seamsWallPath): \(missing.sorted().joined(separator: ", ")). The verb was \
            renamed and the retirement wall was edited with it, leaving this wall holding a \
            spelling nothing can contain. Rename the needle here in the same commit, so the two \
            walls keep agreeing about what a radio verb is called.
            """
        )
    }

    /// Every needle that names an app-target declaration still names one.
    ///
    /// ``theRadioVerbNeedlesAreStillSpokenByTheSeamsWall()`` generalised: the ten verbs are not the
    /// only rows copied out of the app, and a `FernletStore` member renamed in a sweep leaves this
    /// wall holding a spelling nothing can contain — a cell that can never fail, green forever. The
    /// 38 rows flagged ``Spelling/isAppDeclaration`` are checked against the declarations
    /// `App/Fernlet/` actually makes, as CODE, so a stale mention in a doc comment does not satisfy
    /// it. Package and Apple types are deliberately out of scope: this suite does not walk their
    /// sources, and the import wall is their gate.
    @Test func everyAppDeclaredNeedleIsStillDeclaredUnderTheAppTarget() throws {
        let rows = Self.forbiddenSpellings.filter(\.isAppDeclaration)
        #expect(
            rows.count == Self.measuredAppDeclarationCount,
            """
            \(rows.count) needle(s) are flagged as app declarations, measured \
            \(Self.measuredAppDeclarationCount). This cell derives its set from that flag, so a flag \
            dropped in an edit would shrink it without failing anything — hence the pin.
            """
        )

        let sources = try Self.appTargetCode()
        #expect(
            sources.count >= Self.minimumAppFilesScanned,
            """
            Walked \(sources.count) Swift file(s) under \(Self.appTargetRoot) (floor \
            \(Self.minimumAppFilesScanned)) — the walk lost the app target and every needle below \
            would pass vacuously.
            """
        )

        let declared = Self.declaredIdentifiers(in: sources)
        #expect(
            !declared.contains("noSuchDeclarationExistsInTheAppTarget"),
            "the declaration set matched a name nothing declares — it is not a filter"
        )

        var missing: [String] = []
        // R2: bounded by the app-declared needle list.
        for row in rows where !declared.contains(row.token) {
            missing.append(row.token)
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.count) needle(s) name a declaration \(Self.appTargetRoot) no longer makes: \
            \(missing.sorted().joined(separator: ", ")). The member was renamed or deleted and this \
            wall was left holding a spelling nothing can contain. Rename the needle in the same \
            commit — or, if the door itself is gone, retire the row and LOWER \
            `measuredSpellingCount` with the argument written down.
            """
        )
    }

    /// The clock-and-persistence family is whole, and reading a clock is still allowed.
    ///
    /// Derived from ``clockAndPersistenceReasonPrefix`` rather than listed again, so the family and
    /// its needles cannot be edited apart. The second half is the part a reader needs: `Date()` and
    /// a `now()` closure are NOT clock scheduling, and
    /// ``CompanionRefreshCoordinator/earliestBeginInterval`` has to be added to a `Date` to state a
    /// floor at all — a wall that forbade reading the clock would forbid the policy.
    @Test func theClockAndPersistenceFamilyIsWholeAndReadingTheClockIsNot() {
        let family = Self.forbiddenSpellings.filter { $0.why.hasPrefix(Self.clockAndPersistenceReasonPrefix) }
        #expect(
            family.count == Self.measuredClockAndPersistenceCount,
            """
            \(family.count) needle(s) carry a clock-or-persistence reason, measured \
            \(Self.measuredClockAndPersistenceCount). The family is derived from that prefix, so a \
            re-worded reason would shrink it without failing anything — hence the pin.
            """
        )
        #expect(family.allSatisfy { !$0.isAppDeclaration },
                "every row here names an Apple or package type; none is an `App/Fernlet/` declaration")

        // R2: bounded by the literal list.
        for permitted in ["Date", "Date(", "now(", "addingTimeInterval", "timeIntervalSince1970"] {
            #expect(!Self.forbiddenSpellings.contains { $0.token == permitted },
                    "`\(permitted)` reads a clock rather than scheduling on one, and the policy needs it")
        }
        #expect(Self.violations(in: "let floor = now().addingTimeInterval(15 * 60)\n", path: "P.swift").isEmpty,
                "the seam's own earliest-begin arithmetic is not a violation")
    }

    /// The matcher's boundaries: the pairs that must not fire on each other, and the prose that is
    /// not code.
    @Test func theMatcherSeparatesLookalikeIdentifiersAndIgnoresProse() {
        // A benign longer identifier that merely CONTAINS a needle is not a violation. This is what
        // the boundary rule buys, and it is the only shape that proves it: a plain-substring matcher
        // answers this line with a false red, and a wall that cries wolf over a `…Stub` is a wall
        // somebody quiets by deleting the needle. Written against a name that really does contain
        // one, because `HealthKitService` / `HealthKitServicing` — the obvious-looking pair — is not
        // one at all: "Servicing" is "Servic" + "ing", so neither contains the other and an
        // assertion over that pair reports exactly one under EITHER matcher, proving nothing.
        #expect(Self.violations(in: "struct HealthKitServiceStub {}\n", path: "P.swift").isEmpty)

        // The needle still fires as a whole identifier, so the boundary rule cannot degrade into
        // "answer no to everything".
        let servicing = Self.violations(in: "let seam: (any HealthKitServicing)? = nil\n", path: "P.swift")
        #expect(servicing.count == 1, "expected one report, got: \(servicing)")
        #expect(servicing.first?.contains("HealthKitServicing") == true)

        // The real lookalike pairs in the list. First: `PersistenceController` must not fire inside
        // `PrivatePersistenceController`, which carries its own reason.
        let sealed = Self.violations(in: "let c = PrivatePersistenceController.shared\n", path: "P.swift")
        #expect(sealed.count == 1, "expected one report, got: \(sealed)")
        #expect(sealed.first?.contains("PrivatePersistenceController") == true)

        // The funnel TRIPLE, which is the shape this wall got wrong once: `applyProximityRunPolicy`
        // is contained by both of the others, and all three are separately forbidden. Each line must
        // report exactly one needle, and the right one — a plain-substring matcher answers the first
        // two with two reports each, and a matcher that over-corrects answers them with none.
        let sceneEdge = Self.violations(
            in: "_ = store.applyProximityRunPolicy(appLockEngaged: false, duressSessionActive: false)\n",
            path: "P.swift"
        )
        #expect(sceneEdge.count == 1, "expected one report, got: \(sceneEdge)")
        #expect(sceneEdge.first?.contains(": applyProximityRunPolicy ") == true)

        let storeEdge = Self.violations(in: "_ = store.reapplyProximityRunPolicy()\n", path: "P.swift")
        #expect(storeEdge.count == 1, "expected one report, got: \(storeEdge)")
        #expect(storeEdge.first?.contains(": reapplyProximityRunPolicy ") == true)

        let viewHelper = Self.violations(in: "applyProximityRunPolicyFromView()\n", path: "P.swift")
        #expect(viewHelper.count == 1, "expected one report, got: \(viewHelper)")
        #expect(viewHelper.first?.contains(": applyProximityRunPolicyFromView ") == true)

        // And the second pair: `removeWorkout` inside `removeWorkoutByHealthKitUUID`.
        let byUUID = Self.violations(in: "store.removeWorkoutByHealthKitUUID(uuid)\n", path: "P.swift")
        #expect(byUUID.count == 1, "expected one report, got: \(byUUID)")
        #expect(byUUID.first?.contains(": removeWorkoutByHealthKitUUID ") == true)

        // The clock family's own containment: `DispatchSource` inside `DispatchSourceTimer`, with
        // `Timer` inside it too and refused on its left flank. One line, one report, the longest.
        let sourceTimer = Self.violations(in: "var tick: DispatchSourceTimer?\n", path: "P.swift")
        #expect(sourceTimer.count == 1, "expected one report, got: \(sourceTimer)")
        #expect(sourceTimer.first?.contains(": DispatchSourceTimer ") == true)

        // And the shorter one still fires on its own door.
        let source = Self.violations(in: "let t = DispatchSource.makeTimerSource()\n", path: "P.swift")
        #expect(source.count == 1, "expected one report, got: \(source)")
        #expect(source.first?.contains(": DispatchSource ") == true)

        // One `sleep(` needle covers every spelling of waiting, so none of them double-reports.
        let napping = Self.violations(in: "try await Task.sleep(nanoseconds: 1)\n", path: "P.swift")
        #expect(napping.count == 1, "expected one report, got: \(napping)")
        #expect(napping.first?.contains(": sleep( ") == true)

        // A benign identifier that merely ends in a family needle is not a violation.
        #expect(Self.violations(in: "let key = refreshStateFromKeychainCache\n", path: "P.swift").isEmpty)

        // The sanctioned acquisition path is NOT a violation — a wall that forbade it would forbid
        // the only thing §17.2 allows.
        #expect(Self.violations(in: "let store = try await FernletStoreAccess.shared.load()\n", path: "P.swift").isEmpty)

        // Prose about the prohibition is not the prohibition.
        #expect(Self.violations(in: "// never call MeshNetworkManager.startJoin() from here\n", path: "P.swift").isEmpty)
        #expect(Self.violations(in: "/// The handler must not reach `HKHealthStore`.\n", path: "P.swift").isEmpty)
        #expect(Self.violations(in: "let audit = \"CKContainer\"  // a token in an audit string\n", path: "P.swift").isEmpty)
        #expect(Self.violations(in: "let x = 1  // LanguageModelSession\n", path: "P.swift").isEmpty)

        // And a real use behind a trailing comment still reds.
        #expect(!Self.violations(in: "let m = MeshNetworkManager.self  // needed, honest\n", path: "P.swift").isEmpty)

        // A call inside a string INTERPOLATION is a call. The literal's prose is not code, but
        // `\(…)` is, and blanking it with the rest of the literal is how this wall was first green
        // over the very line its own doc names as the example.
        let interpolated = Self.violations(
            in: "let log = \"policy: \\(store.reapplyProximityRunPolicy())\"\n",
            path: "P.swift"
        )
        #expect(interpolated.count == 1, "expected one report, got: \(interpolated)")
        #expect(interpolated.first?.contains(": reapplyProximityRunPolicy ") == true)
    }

    /// The allowlist is a filter, not a rubber stamp.
    @Test func theModuleAllowlistIsARealFilterAndNotARubberStamp() {
        #expect(!Self.permittedModules.contains("ProximityKit"))
        #expect(!Self.permittedModules.contains("HealthKit"))
        #expect(!Self.permittedModules.contains("CloudKit"))
        #expect(!Self.permittedModules.contains("FoundationModels"))
        #expect(!Self.permittedModules.contains("HealthKitGateway"))
        #expect(!Self.permittedModules.contains("CloudKitSync"))
        #expect(!Self.permittedModules.contains("AIProviders"))

        // The two lists are disjoint, so no name can be both.
        let overlap = Self.permittedModules.intersection(Self.forbiddenModuleReasons.keys)
        #expect(overlap.isEmpty, "classified twice: \(overlap.sorted().joined(separator: ", "))")

        // Every Apple framework named in the reason table is genuinely excluded by the filter.
        // R2: bounded by the table.
        for framework in Self.forbiddenAppleFrameworkReasons.keys {
            #expect(!Self.permittedModules.contains(framework), "\(framework) is permitted but documented as forbidden")
        }

        // The import matcher this wall reuses sees the forms that matter.
        let imports = S3BoundaryTests.importedModules(in: "@preconcurrency import ProximityKit\nimport WidgetKit\n// import HealthKit\n")
        #expect(imports.contains("ProximityKit"))
        #expect(imports.contains("WidgetKit"))
        #expect(!imports.contains("HealthKit"), "a commented import is not one")
    }

    /// The stripper sees code and not prose or literals.
    @Test func theStripperSeesCodeAndNotProseOrLiterals() {
        #expect(Self.stripped("let x = 1 // MeshNetworkManager", removingStringLiterals: true).contains("let x = 1"))
        #expect(!Self.stripped("let x = 1 // MeshNetworkManager", removingStringLiterals: true).contains("MeshNetworkManager"))
        #expect(Self.stripped("  /// HKHealthStore", removingStringLiterals: true).trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(!Self.stripped("let s = \"CKContainer\"", removingStringLiterals: true).contains("CKContainer"))
        // A `//` inside a literal is not a comment, so the code after it survives.
        #expect(Self.stripped("let u = \"https://x\" ; let m = MeshNetworkManager.self", removingStringLiterals: true).contains("MeshNetworkManager"))
        // Literals are kept when the caller asks for them — the positive-needle view.
        #expect(Self.stripped("let id = \"MBO.Fernlet.companion-refresh\"", removingStringLiterals: false)
            .contains("MBO.Fernlet.companion-refresh"))
        // In that view the function is the identity over a line with no comment, interpolation and
        // all — which is what `theTaskIdentifierAppearsExactlyOnceAsCode()` counts against.
        let kept = "let id = \"x\\(y)z\""
        #expect(Self.stripped(kept, removingStringLiterals: false) == kept)
    }

    /// The stripper as a table of inputs and expected outputs.
    ///
    /// Tier 1 and buildless — it is a pure function over strings — and it exists so the stripper is
    /// independently reddenable without planting a file under the refresh directory and rebuilding
    /// the app. The second row is the one that was wrong: the first shape of
    /// ``stripped(_:removingStringLiterals:)`` blanked `\(…)` along with the literal around it, so
    /// `let log = "policy: \(store.reapplyProximityRunPolicy())"` — this suite's own headline
    /// example of a call that runs the radios — was invisible to every needle.
    ///
    /// The last two rows are documented FALSE POSITIVES kept on purpose: a `#if DEBUG` line and the
    /// code under it are read as code, so a needle inside a debug-only branch still reds. That is
    /// the safe direction; the unsafe one is what this table is here to prevent.
    @Test func theStripperIsATableOfInputsAndExpectedOutputs() {
        let rows: [(input: String, expected: String, note: String)] = [
            (
                "let s = \"CKContainer\"",
                "let s = \"\"",
                "a plain literal keeps its quotes and loses its body"
            ),
            (
                "let log = \"policy: \\(store.reapplyProximityRunPolicy())\"",
                "let log = \"(store.reapplyProximityRunPolicy())\"",
                "an interpolation is a call site: the expression survives, the prose around it does not"
            ),
            (
                "let t = \"a\\(f(g(\"z\")))b\"",
                "let t = \"(f(g(\"\")))\"",
                "nested parens close in the right place, and a literal inside the span is blanked in turn"
            ),
            (
                "let u = \"https://x\" ; let m = MeshNetworkManager.self",
                "let u = \"\" ; let m = MeshNetworkManager.self",
                "a `//` inside a literal is not a comment, so the code after the literal survives"
            ),
            (
                "let x = 1 // MeshNetworkManager",
                "let x = 1 ",
                "a trailing comment goes, and the space before it stays"
            ),
            (
                "    /// HKHealthStore",
                "    ",
                "a whole-line doc comment leaves only its indent, which `codeLines` then drops"
            ),
            (
                "#if DEBUG",
                "#if DEBUG",
                "a compiler directive is code — a needle in a debug-only branch still reds"
            )
        ]
        // R2: bounded by the table.
        for row in rows {
            let actual = Self.stripped(row.input, removingStringLiterals: true)
            #expect(
                actual == row.expected,
                """
                \(row.note).
                input:    \(row.input)
                expected: \(row.expected)
                actual:   \(actual)
                """
            )
        }
    }

    // MARK: - Machinery

    /// Every `.swift` file under ``refreshRoot``, recursive and sorted by path, as
    /// (repo-relative path, source).
    ///
    /// Sorted so a failure message is stable between runs, and so a diff of two logs is about the
    /// violations rather than about the enumerator's order.
    static func swiftFiles() throws -> [(path: String, source: String)] {
        let rootURL = RepoRoot.url(refreshRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var urls: [URL] = []
        // R2: bounded by the directory's entry count.
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            urls.append(url)
        }
        var files: [(path: String, source: String)] = []
        let prefix = RepoRoot.url.path + "/"
        // R2: bounded by the file list.
        for url in urls.sorted(by: { $0.path < $1.path }) {
            files.append((url.path.replacingOccurrences(of: prefix, with: ""), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// Every Swift file under ``appTargetRoot``, comment- and literal-stripped, one entry per file.
    ///
    /// The whole target rather than a hand-picked list of files, for the same reason the refresh
    /// scan walks a directory: a member moves between files far more often than it is renamed, and a
    /// list that has to be extended by hand is a list that goes stale.
    static func appTargetCode() throws -> [String] {
        let rootURL = RepoRoot.url(appTargetRoot)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var urls: [URL] = []
        // R2: bounded by the target's entry count.
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            urls.append(url)
        }
        var sources: [String] = []
        // R2: bounded by the file list.
        for url in urls {
            let source = try String(contentsOf: url, encoding: .utf8)
            sources.append(codeLines(source, removingStringLiterals: true).map(\.1).joined(separator: "\n"))
        }
        return sources
    }

    /// The keywords a declaration's name can follow.
    static let declarationKeywords: Set<String> = [
        "func", "var", "let", "class", "struct", "enum", "actor", "protocol", "typealias", "case"
    ]

    /// Every identifier `sources` declares, collected once so the drift cell is a set lookup rather
    /// than a scan per needle.
    ///
    /// Deliberately over-collects — a local `let` and an enum `case` land in the same set as a
    /// `FernletStore` member — because this is a tripwire for a RENAME, and the answer it must never
    /// give is a false "still there" for a name the app has genuinely lost. Over-collection can
    /// produce one, so a needle whose token is also an ordinary local name is weaker here than the
    /// others; none of the 36 is.
    static func declaredIdentifiers(in sources: [String]) -> Set<String> {
        var names: Set<String> = []
        // R2: bounded by the file list.
        for source in sources {
            // R2: bounded by the file's line count.
            for line in source.components(separatedBy: "\n") {
                names.formUnion(declarations(in: line))
            }
        }
        return names
    }

    /// The identifiers one line declares: the word following each declaration keyword.
    static func declarations(in line: String) -> [String] {
        var names: [String] = []
        var previous = ""
        // R2: bounded by the line's word count.
        for word in line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
            if declarationKeywords.contains(previous) { names.append(String(word)) }
            previous = String(word)
        }
        return names
    }

    /// Every forbidden spelling in `source`, as `path:line: token — why`.
    static func violations(in source: String, path: String) -> [String] {
        var found: [String] = []
        // R2: bounded by the line count.
        for (number, line) in codeLines(source, removingStringLiterals: true) {
            // R2: bounded by the needle list.
            for spelling in forbiddenSpellings where matches(line, spelling.token) {
                found.append("\(path):\(number): \(spelling.token) — \(spelling.why)")
            }
        }
        return found
    }

    /// Whether `line` contains `token`.
    ///
    /// Identifier-shaped tokens match at identifier boundaries, so a needle never fires as a
    /// substring of a longer, unrelated name. Anything carrying a `(` or a `.` is matched as a
    /// plain substring, because the boundary rule tests BOTH flanks and would refuse
    /// `FernletStore(healthKitService:` on its right-hand one — answering a real violation with a
    /// green, which is the one answer a wall may never give.
    static func matches(_ line: String, _ token: String) -> Bool {
        let isIdentifier = token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        if isIdentifier { return S3BoundaryTests.containsAtIdentifierBoundary(line, token) }
        return line.contains(token)
    }

    /// `source` as (1-based line number, code) pairs, comments removed.
    ///
    /// Known limits, both of which fail LOUD rather than silent: a `/* … */` block comment is not
    /// recognised, and a multi-line `"""` literal's body is read as code. A needle inside either
    /// would therefore red this wall — the safe direction, and neither shape exists in the refresh
    /// directory. If one ever does, teach this function about it rather than dropping the needle.
    static func codeLines(_ source: String, removingStringLiterals: Bool) -> [(Int, String)] {
        var lines: [(Int, String)] = []
        var number = 0
        // R2: bounded by the source's line count.
        for line in source.components(separatedBy: "\n") {
            number += 1
            let code = stripped(line, removingStringLiterals: removingStringLiterals)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append((number, code))
        }
        return lines
    }

    /// One line with its trailing `//` comment removed, and — when asked — the contents of every
    /// string literal removed too, EXCEPT the code inside its interpolations.
    ///
    /// The comment cut is literal-aware: a `//` inside `"https://…"` is not a comment, and cutting
    /// there would hide the code after it from every needle.
    ///
    /// **Interpolation bodies are code and are kept.** `\(…)` is a call site wearing a literal's
    /// clothes: `let log = "policy: \(store.reapplyProximityRunPolicy())"` runs the funnel exactly
    /// as the bare call does. The first shape of this function blanked the interpolation with the
    /// rest of the literal, so that line — this suite's own headline example — passed the wall
    /// green. Each `\(` opens a code span that closes on its matching `)`, paren-counted so
    /// `\(f(g(x)))` closes in the right place and a `"` inside the span opens a literal of its own.
    /// The prose around the span is still blanked, so only the expression survives; nesting past
    /// ``maximumInterpolationDepth`` falls back to blanking, which can only hide code and so is the
    /// one thing a reader has to know this returns a green for.
    ///
    /// A multi-line `"""` literal is still read as code, interpolations and all — the safe
    /// direction, and unchanged by this.
    static func stripped(_ line: String, removingStringLiterals: Bool) -> String {
        var output = ""
        var inString = false
        var escaped = false
        var interpolation: [Int] = []
        let characters = Array(line)
        var index = 0
        // R2: bounded by the line's character count; every branch advances `index` or breaks.
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" && index + 1 < characters.count
                            && characters[index + 1] == "(" && interpolation.count < maximumInterpolationDepth {
                    if !removingStringLiterals { output.append("\\") }
                    output.append("(")
                    interpolation.append(1)
                    inString = false
                    index += 2
                    continue
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    output.append("\"")
                    index += 1
                    continue
                }
                if !removingStringLiterals { output.append(character) }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            if let depth = interpolation.last {
                if character == "(" {
                    interpolation[interpolation.count - 1] = depth + 1
                } else if character == ")" {
                    if depth == 1 {
                        interpolation.removeLast()
                        inString = true
                    } else {
                        interpolation[interpolation.count - 1] = depth - 1
                    }
                    output.append(")")
                    index += 1
                    continue
                }
            }
            // A `//` inside an interpolation would be a comment inside an expression; treating it
            // as one here would cut the expression short and hide the rest, so only a `//` in
            // ordinary code ends the line.
            if interpolation.isEmpty && character == "/" && index + 1 < characters.count
                && characters[index + 1] == "/" {
                break
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// Every `name: "X"` value in a Package.swift, which is every target, every product and the
    /// package itself. Deliberately over-collects: a name this wall cannot place is a name somebody
    /// must classify, and the only over-collection today is `FernletKit` (the package and the
    /// umbrella library), exempted by name at the one call site.
    static func declaredNames(in manifest: String) -> Set<String> {
        var names: Set<String> = []
        let marker = "name: \""
        // R2: bounded by the manifest's line count.
        for line in manifest.components(separatedBy: "\n") {
            let code = stripped(line, removingStringLiterals: false)
            guard let head = code.range(of: marker) else { continue }
            let rest = code[head.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<close])
            guard !name.isEmpty else { continue }
            names.insert(name)
        }
        return names
    }
}
