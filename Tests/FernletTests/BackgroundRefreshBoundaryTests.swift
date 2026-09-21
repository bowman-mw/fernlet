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
/// lives in the app target, which is one Swift module, so every app-resident declaration is
/// nameable from the refresh directory with no import line whatsoever: `FernletStore`,
/// `FernletStoreAccess`, `WidgetSnapshotMirror`, `FernletStoreLoader`, `MeshContinuationTaskHost`,
/// and every `FernletStore` extension declared under `App/Fernlet/` — which is where the radio
/// funnel lives. `store.reapplyProximityRunPolicy()` re-runs the radios and imports nothing;
/// `store.healthSyncCoordinator` reaches the HealthKit path and imports nothing;
/// `FernletStore.load(…)` builds a second store and imports nothing. An import-only wall is green
/// over all three. ``theRefreshDirectoryNamesNoMeshHealthCloudOrModelSpelling()`` is the wall that
/// holds them, and the module allowlist is the cheap outer fence that catches the naive version
/// first and names it clearly.
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
/// | ``theRefreshDirectoryNamesNoMeshHealthCloudOrModelSpelling()`` | One plant per family, each chosen to compile: `import ProximityKit` + `static let probe: MeshNetworkManager? = nil`; the same shape for `HKHealthStore`, `CKContainer` and `LanguageModelSession`; and — the important one, because it adds NO import and so reds this cell alone — `@MainActor func redOnceProbe() async throws { _ = try await FernletStore.load() }` below the enum. Per-NEEDLE independence is discharged without 41 rebuilds by ``everyForbiddenSpellingIsMatchableAndTheListIsWhole()``, which plants each needle into a synthetic source in-process and fails if any one of them cannot be matched. |
/// | ``theTaskIdentifierAppearsExactlyOnceAsCode()`` | Comment out the `taskIdentifier` line in the scaffold file (the count drops to zero), then paste a second copy into a new file under the directory (the count rises to two). Both directions must red. |
/// | ``everyForbiddenSpellingIsMatchableAndTheListIsWhole()`` | Delete any one entry from ``forbiddenSpellings``; the measured count pin reds. |
/// | ``theModuleAllowlistIsARealFilterAndNotARubberStamp()`` | Add `"ProximityKit"` to ``permittedModuleReasons``. |
/// | ``theStripperSeesCodeAndNotProseOrLiterals()`` | Change ``stripped(_:removingStringLiterals:)`` to return its input unchanged. |
/// | ``theRadioVerbNeedlesAreStillSpokenByTheSeamsWall()`` | Misspell one radio-verb token in ``forbiddenSpellings`` (`.startJoinX(`); the seams wall no longer speaks it. That plant leaves ``everyForbiddenSpellingIsMatchableAndTheListIsWhole()`` green, which is the point — the matcher can see the misspelling; the app cannot. |
struct BackgroundRefreshBoundaryTests {

    // MARK: - The scan root

    /// The directory that is the boundary. Every `.swift` file under it, at any depth, is refresh
    /// code and is held to everything below.
    static let refreshRoot = "App/Fernlet/CompanionRefresh"

    /// Floor for the walk. Item 2 ships one file; items 3 and 4 add more, and this may be raised
    /// with them. A root that stops resolving reports zero and would otherwise pass vacuously,
    /// which is the failure mode `RepoRoot`'s own doc comment exists to describe.
    static let minimumFilesScanned = 1

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
    }

    /// Every spelling that must not appear under the refresh directory.
    ///
    /// Each is a CODE token a real violation would have to contain, not a word from the prose about
    /// it: matched over source with comments and string literals removed, so the wall states
    /// something about code rather than about the paragraph explaining why the code does not do the
    /// thing. Identifier-shaped tokens match at identifier boundaries
    /// (`S3BoundaryTests.containsAtIdentifierBoundary`) so `PersistenceController` never fires
    /// inside `PrivatePersistenceController` — the one REAL lookalike pair in this list, and listed
    /// twice because both are separately forbidden — and so no needle fires on a longer, unrelated
    /// name a later file might legitimately carry (`HealthKitServiceStub`, `PresenceManagerSpy`).
    /// `HealthKitService` and `HealthKitServicing` are NOT such a pair, despite looking like one:
    /// "Servicing" is "Servic" + "ing", so neither string contains the other. They are two separate
    /// symbols, both needles because both are separately reachable. Tokens carrying a `(` or a leading `.` are matched as plain
    /// substrings, because identifier-boundary matching would refuse `FernletStore(healthKit…` on
    /// its right-hand flank and answer a violation with a green.
    ///
    /// The radio-verb rows are the same ten spellings `ProximityRunSeamsTests`' retirement wall
    /// counts, reused deliberately: if the app renames a verb, both walls must be edited together
    /// and neither can drift into naming a verb that no longer exists.
    static let forbiddenSpellings: [Spelling] = [
        // The mesh (§17.2: never the mesh).
        Spelling(token: "ProximityKit", why: "the mesh module, qualified or imported"),
        Spelling(token: "MeshNetworkManager", why: "the mesh manager itself"),
        Spelling(token: "ProximityCoordinator", why: "the proximity fan-out"),
        Spelling(token: "PresenceManager", why: "the presence listener"),
        Spelling(token: "ProximityRecipeShareManager", why: "the recipe-share listener"),
        Spelling(token: "executeProximityRunActions", why: "the radio executor — the one place a verb is spoken"),
        Spelling(token: "runProximityPolicy", why: "the run funnel"),
        Spelling(token: "reapplyProximityRunPolicy", why: "the store's own funnel edge — reachable with NO import, which is why it is here"),
        Spelling(token: "applyProximityRunPolicyFromView", why: "the view's funnel helper"),
        Spelling(token: "MeshContinuationDriver", why: "the continuation claim; a refresh task is not a continuation task"),
        Spelling(token: "MeshContinuationTaskHost", why: "the continuation's scheduler half"),
        Spelling(token: "BGContinuedProcessingTask", why: "the mesh's task class — the refresh uses `BGAppRefreshTask`"),
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
        // HealthKit (§17.2: never HealthKit).
        Spelling(token: "HKHealthStore", why: "the Health store"),
        Spelling(token: "HealthKitService", why: "the gateway"),
        Spelling(token: "HealthKitServicing", why: "the gateway's seam — `load()` defaults it to nil"),
        Spelling(token: "HealthSyncCoordinator", why: "the store's health sync coordinator"),
        Spelling(token: "healthSyncCoordinator", why: "that coordinator's property, reachable with no import"),
        // CloudKit (§17.2: never a force-sync).
        Spelling(token: "CKContainer", why: "the CloudKit container"),
        Spelling(token: "CKDatabase", why: "a CloudKit database"),
        Spelling(token: "CloudKitDataService", why: "the app's CloudKit entry point"),
        Spelling(token: "PersistenceController", why: "the CloudKit-backed Core Data stack, including `reload(with:)`"),
        Spelling(token: "PrivatePersistenceController", why: "the sealed Core Data stack"),
        Spelling(token: "CoreDataFernletRepository", why: "the synced repository"),
        // Foundation Models (§17.2: never Foundation Models).
        Spelling(token: "LanguageModelSession", why: "an on-device model session"),
        Spelling(token: "SystemLanguageModel", why: "the on-device model"),
        Spelling(token: "FoundationModels", why: "the framework, qualified or imported"),
        Spelling(token: "@Generable", why: "a generated-output schema — an AI call by another spelling"),
        // Store creation (§17.2: never create a store; acquire the existing one).
        Spelling(token: "FernletStore(", why: "constructing a second store over the same repositories"),
        Spelling(token: "FernletStore.load(", why: "the creation path — acquire through `FernletStoreAccess.shared.load()` instead"),
        Spelling(token: "FernletStoreLoader", why: "the scene bootstrap; the handler is not a scene"),
        Spelling(token: "FernletStoreAccess(", why: "a SECOND acquisition cache — `.shared` is the point of the type")
    ]

    /// MEASURED count of ``forbiddenSpellings`` at P10 item 2. Removing a needle is a deliberate
    /// retirement with an argument, never a side effect of an edit; raise this in the same commit
    /// that adds one.
    static let measuredSpellingCount = 41

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
    @Test func theRefreshDirectoryNamesNoMeshHealthCloudOrModelSpelling() throws {
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
    /// This is what makes each negative needle independently reddenable without 41 rebuilds: a
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

        // The one real lookalike pair in the list: `PersistenceController` must not fire inside
        // `PrivatePersistenceController`, which carries its own reason.
        let sealed = Self.violations(in: "let c = PrivatePersistenceController.shared\n", path: "P.swift")
        #expect(sealed.count == 1, "expected one report, got: \(sealed)")
        #expect(sealed.first?.contains("PrivatePersistenceController") == true)

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
    /// string literal removed too.
    ///
    /// The comment cut is literal-aware: a `//` inside `"https://…"` is not a comment, and cutting
    /// there would hide the code after it from every needle.
    static func stripped(_ line: String, removingStringLiterals: Bool) -> String {
        var output = ""
        var inString = false
        var escaped = false
        let characters = Array(line)
        var index = 0
        // R2: bounded by the line's character count; every branch advances `index` or breaks.
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
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
            if character == "/" && index + 1 < characters.count && characters[index + 1] == "/" {
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
