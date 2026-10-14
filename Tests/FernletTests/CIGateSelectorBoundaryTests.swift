// CIGateSelectorBoundaryTests.swift
// FernletTests
//
// The STATIC half of the CI non-vacuity guard (P5 close-out review, finding 4). The dynamic half is
// `Scripts/run-gated-suites.sh`: every test step in `.github/workflows/s3-wall.yml` runs through it,
// and it refuses a green run whose result bundle counts fewer tests than the step's floor, or in
// which a named suite ran no test case.
//
// What this file adds is the check that can run WITHOUT a simulator: `-only-testing:` matches suite
// names exactly and matches nothing on a misspelling, so a workflow line can name a suite that no
// longer exists and stay green forever. Here every selector the workflow names must be a declared
// top-level type in its own test target (`Tests/FernletTests` for a bare name,
// `FernletKit/Tests/ProximityKitTests` for `ProximityKitTests/<Suite>`, ProximityKit plan step
// A0.8), every mesh acceptance battery and wire golden declared in either target must be named by the
// workflow (the P3/P4/P5 batteries were ungated for three phases because nothing said they had to
// be), `Tests/suite-inventory.tsv` must be the tree (every suite's target, file and lines) and its
// package rows the package's own inventory, the helpers both targets compile must be twins and the
// package's test bindings a replacement of Fernlet's (ProximityKit plan step A1.1), the strict build
// and every run go through `Fernlet.xcworkspace`, which resolves the CryptoSwift revision the app
// project pins (ProximityKit plan step A0.8.1), the Fernlet scheme's testables hold the package
// test target, which declares ProximityKit as its one dependency (A0.8.2), and this suite gates
// itself. What the package's unhosted bundle cannot serve, its tests' imports and its inventory's
// declared tests are the package's own to hold, in its `PackageTestHygieneTests` (A1.1.13).

import Foundation
import Testing

/// Every gated selector is a declared suite, every declared battery is gated, and every step runs
/// through the floor.
@Suite struct CIGateSelectorBoundaryTests {

    private static let workflowPath = ".github/workflows/s3-wall.yml"
    private static let floorScript = "Scripts/run-gated-suites.sh"

    /// The batteries the workflow must name: any top-level suite matching these shapes, wherever it
    /// is declared. Adding a `MeshP6…AcceptanceTests` suite therefore fails CI until it is gated.
    private static func isMeshBattery(_ name: String) -> Bool {
        if name == "MeshRoutedDrainConvergenceTests" || name == "MeshConvergencePropertyTests"
            || name == "MeshConvergenceScheduleTests" {
            return true
        }
        guard name.hasPrefix("MeshP"), name.hasSuffix("AcceptanceTests") else { return false }
        let afterP = name.dropFirst("MeshP".count)
        return afterP.first.map { $0.isNumber } ?? false
    }

    /// One selector of a workflow line, read into the test target it names and the suite (ProximityKit
    /// plan step A0.8). A bare name is a `FernletTests` suite; `ProximityKitTests/<Suite>` is a suite of
    /// ProximityKit's own package test target. ``selector(_:)`` reads no other shape.
    struct Selector: Hashable {
        /// The test target: ``appTarget`` for a bare name, ``packageTarget`` for a qualified one.
        let target: String
        /// The suite's type name, as its column-0 declaration spells it.
        let suite: String
    }

    /// The app's unit-test target, the one a bare selector names.
    static let appTarget = "FernletTests"

    /// ProximityKit's own package test target (ProximityKit plan step A0.8), named by a
    /// `ProximityKitTests/<Suite>` selector. Unhosted: it runs in the simulator's `xctest` agent, with
    /// no keychain entitlement and no app to install a ProximityAudit sink, so its test support installs
    /// an in-memory keychain store and an audit sink of its own on first touch
    /// (`TestSupport/PackageTestEnvironment.swift`), and its own `PackageTestHygieneTests` refuses what
    /// it still cannot serve.
    static let packageTarget = "ProximityKitTests"

    /// Every test target a selector can name, with its repo-relative folder. A target whose folder
    /// does not exist declares nothing (``declarations(inTarget:)`` returns no name), so the package
    /// target's folder may be absent until a suite moves into it.
    static let testRoots: [(target: String, path: String)] = [
        (target: appTarget, path: "Tests/FernletTests"),
        (target: packageTarget, path: "FernletKit/Tests/ProximityKitTests")
    ]

    /// The folder of a test target, or the target's name itself for a target ``testRoots`` lacks.
    static func rootPath(of target: String) -> String {
        testRoots.first { $0.target == target }?.path ?? target
    }

    /// Reads one workflow token: a bare identifier names a `FernletTests` suite, and
    /// `ProximityKitTests/<identifier>` a suite of the package target. Every other shape is nil,
    /// `FernletTests/<Suite>` among them (one spelling per target, so this wall and
    /// `Scripts/run-gated-suites.sh` read a line alike), as are another target, a second slash and
    /// an empty or non-identifier suite.
    static func selector(_ token: String) -> Selector? {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let suite = parts.last, isIdentifier(suite) else { return nil }
        if parts.count == 1 { return Selector(target: appTarget, suite: suite) }
        guard parts.count == 2, parts[0] == packageTarget else { return nil }
        return Selector(target: packageTarget, suite: suite)
    }

    /// An identifier as a selector spells one: non-empty ASCII letters, digits and `_`.
    private static func isIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// One `run-gated-suites.sh` invocation in the workflow: its label, floor and selectors.
    struct GatedStep: Equatable {
        /// The bundle label.
        let label: String
        /// The test-count floor.
        let floor: Int
        /// The selectors as the workflow writes them, in workflow order: a bare `FernletTests` suite
        /// name or `ProximityKitTests/<Suite>` (ProximityKit plan step A0.8).
        let selectors: [String]
        /// The suite names, in workflow order, each selector's target prefix dropped. A malformed token
        /// is kept whole, so it still names nothing; ``everyGatedSelectorNamesADeclaredSuite()`` reports it.
        var suites: [String] {
            selectors.map { CIGateSelectorBoundaryTests.selector($0)?.suite ?? $0 }
        }
    }

    /// The MEASURED suite-name count of every gated step — the half of the non-vacuity guard that
    /// needs no simulator (P9 item 6's fix review, NOTE-3).
    ///
    /// `-only-testing:` names that go missing are invisible to everything else here: a name leaving
    /// a workflow line still leaves every remaining name declared, and `everyMeshAcceptanceBatteryIsGated`
    /// only asks after `MeshP<n>…AcceptanceTests` / convergence batteries. Thirteen of P9 item 6's
    /// fourteen are behaviour suites under none of those shapes, so the step's TEST-count floor —
    /// which needs a Mac, a simulator and ~3 minutes — was the only thing holding them on the line.
    /// A count of names is the generic rule the tally comment cannot be (the parser drops `#` lines
    /// by design) and a hand-list of 85 names should never be: `gatedSteps` already returns them.
    ///
    /// MEASURED from the workflow, parsed exactly as `gatedSteps` parses it, at P9 item 6's fix
    /// review (2026-09-20) and RE-MEASURED at item 9's (same day): `s3-grep` gains the audit
    /// ratchet's source half, and the mesh line gains the twenty-one names item 9's verify found
    /// ungated — `ProximityRecipeShareCapTests` (the cells clause (c) leans on), the sixteen suites
    /// of `NetworkMeshTransportTests.swift`, and four presence/recipe/selection unit suites. RAISE
    /// an entry in the same commit that adds names; LOWER one only deliberately, with the
    /// retirement argued, which is the whole point of the pin.
    ///
    /// RE-MEASURED again at P10 item 2 (2026-09-20): `s3-grep` 3 → 4, for
    /// `BackgroundRefreshBoundaryTests` — plan §16.4's background-refresh import wall, which has no
    /// compiler half and runs on no other line.
    ///
    /// RE-MEASURED again at P10 item 3 (2026-09-20): `s3-grep` 4 → 5, for
    /// `CompanionRefreshSchedulingTests` — the refresh scheduling seam's tier-1 suite, which is not
    /// a `MeshP<n>…AcceptanceTests` and is therefore demanded by `everyMeshAcceptanceBatteryIsGated`
    /// nowhere. The step's floor stays the shared `1`; only the NAME count moves here.
    ///
    /// RE-MEASURED again at P10 item 4 (2026-09-21): `s3-grep` 5 → 7, for
    /// `CompanionRefreshPipelineTests` (the handler itself — the step order, the completion table
    /// and the acquire path's repair) and `WidgetSnapshotContentEqualityTests` (the content/metadata
    /// split "reload only on change" rests on). Neither is a mesh battery either, so this pin is
    /// again the only thing that would notice a name LEAVING that line — adding one is silent.
    ///
    /// RE-MEASURED again at P10 item 5 (2026-09-21): `mesh-batteries` 118 → 135, for the eleven
    /// sibling suites the mesh step's own comment had named as deliberately left off (83 cells in
    /// six files whose other suite was already on the line), the three suites of
    /// `MeshRoutedBackpressureTests.swift` that `MeshP9HonestyAcceptanceTests.ungatedByDesign` said
    /// were P10's to price (22 cells), and `PeerTransportNeutralityTests.swift`'s three (19 cells,
    /// gated on their own argument — the `isSameEndpoint(as:)` rule and the fake fabric the whole
    /// line rests on). None of the seventeen is a `MeshP<n>…AcceptanceTests`, so
    /// `everyMeshAcceptanceBatteryIsGated` demanded none of them: this count and that step's
    /// MEASURED floor are the only two things that stop a name leaving the line again. The pin is
    /// `>=`, so ADDING a name passes silently — raising it here is what makes it bite.
    ///
    /// RE-MEASURED again at P10 item 9 (2026-09-21): `mesh-batteries` 135 → 140, for the phase's
    /// five acceptance clause suites (the scheduling seam, the handler pipeline, the diff rule,
    /// the import wall, honesty). Unlike the seventeen above, these five ARE demanded —
    /// ``everyMeshAcceptanceBatteryIsGated`` fails any declared `MeshP<n>…AcceptanceTests` the
    /// workflow does not name — so this entry is not what holds THEM on the line; it is what
    /// notices one of the other 135 names leaving beside them. Counted off the line, not added to
    /// the previous number.
    ///
    /// RE-MEASURED again at the cutover round's item 1.2 (2026-09-21): `mesh-batteries` 140 → 141,
    /// for `MeshIntroductionAuthorityRosterTests` — the suite that pins
    /// `MeshNetworkManager.mayAdmitStrangerProvisionally`, the join-door predicate D-4.3's
    /// provisional admission turns on. It is not a `MeshP<n>…AcceptanceTests`, so
    /// ``everyMeshAcceptanceBatteryIsGated`` demands it nowhere and this entry is again the only
    /// thing that would notice it leaving. Counted off the line, not added to the previous number.
    ///
    /// LOWERED, deliberately, at the deletion round (2026-09-22): `mesh-batteries` 141 → 140, for
    /// `MeshMultipeerSessionIdentityTests` — the suite that drove the retired MultipeerConnectivity
    /// radio's real delegate callbacks to pin the §6.5 endpoint→identity map. The radio left the
    /// tree (`MeshMultipeerSession.swift`, `MCPeerIDStore.swift`), so the suite cannot exist; its
    /// invariant — a stable `PeerHandle.id` for the life of a session — is carried on the QUIC
    /// radio by `NetworkMeshSessionTests` and `MeshLinkTableTests`, both still on the line. This is
    /// the retirement argued, which is the one way this number may go down. Counted off the line.
    ///
    /// RE-MEASURED at the owner-calls round (2026-09-22): `mesh-batteries` 140 → 141, for
    /// `MeshNameWithholdingTests` — the pin of stranger-admission Option 1b's MESH half: every mesh
    /// frame is signed at `MeshNetworkManager.sendEnvelopeCore`, and a slot this device has not
    /// committed must receive no display name there, envelope or payload. The first build leaked
    /// exactly there and the round's blind verify found it (BLOCKER); the same verify found a sibling
    /// privacy suite red on no CI line at all. Not a `MeshP<n>…AcceptanceTests`, so this entry is the
    /// only thing that would notice it leaving. Counted off the line.
    ///
    /// RE-MEASURED at the CI-breadth round (2026-09-24): `mesh-batteries` 141 → 154, for the newest
    /// mesh security suites (`MeshSeatTransportProofTests`, `MeshSessionIDClaimTests`,
    /// `MeshReturningMemberReseatTests`), the resume copy and presentation tables, the wipe's
    /// identity effect, the host pin, and the six wire goldens nothing demanded (five routed families
    /// and `PeerHandleWireGoldenTests`). Only the goldens are demanded, by shape, in
    /// ``everyWireGoldenSuiteIsGated()`` — so this entry is what notices any of the other seven
    /// leaving. Five lines are NEW, one per wall that ran on no workflow at all: `privacy-wipe` (4:
    /// the coverage scan, its two behaviour siblings, the persisted-surface discovery wall),
    /// `accessibility`, `memory-lifecycle`, `messages-extension` and `codeowners` (1 each). Each is
    /// also pinned by name in ``wallLines``, since a count of one cannot tell its wall from another.
    /// Counted off the lines.
    ///
    /// RE-MEASURED at the 2026-09-24 round (companion emotions, recipes made in parts, the version-2
    /// Messages card): `s3-grep` 7 → 8, for `CompanionEmotionPrivacyTests` — the wall behind
    /// Docs/Verifiability.md's "your companion's feelings are never saved, synced, exported or sent to
    /// friends"; the step's floor stays the shared `1`. Two lines are NEW, one per exchange wire that
    /// had no compiler half and ran on no line: `messages-envelope` (3: the version-2 envelope, the
    /// multipart packet, and the exchange core with its version-1 goldens) and `recipe-wire` (1: the
    /// multipart `fernlet.recipe` golden and its older-reader mirrors). Each is also pinned by name
    /// in ``wallLines``. Counted off the lines.
    ///
    /// RE-MEASURED at the Messages blank-screen round (2026-09-30): `messages-envelope` 3 → 4, for
    /// `MessagesReceivedItemTests` — what an opened card resolves to (`FernletMessagesReceivedItem`),
    /// the only behavioural pin that no input draws an empty screen; the extension's own wall checks
    /// by source scan only that the controller routes through it. Pinned by name in ``wallLines``
    /// too. Counted off the line.
    ///
    /// RE-MEASURED at the recipe-share round (2026-09-30): `messages-envelope` 4 → 5, for
    /// `MessagesRecipeCardParityTests` — the card the app composes for "Send in Messages" is the
    /// extension's own builder's, its URL the envelope's, opening as the same packet. Pinned by name
    /// in ``wallLines`` too. Counted off the line.
    ///
    /// NEW at the 2026-09-29 ingredient-search round's fix round 1: `food-search` (6: the F10
    /// ingredient corpus and tap-default sweep, the import-line pins, the two catalog-correction
    /// suites, and the dish-template/plan-tier bind audit). The measuring stick every later search fix
    /// is gated on had run on no line. Its corpus and sweep are also pinned by name in ``wallLines``.
    /// Counted off the line.
    ///
    /// RE-MEASURED at the ingredient-search round's F5 (2026-09-30): `food-search` 6 → 7, for
    /// `FoodIngredientIdentityTests` — the recipe surfaces' identity-first ranking rules, which move
    /// only the corpus pins and compile clean when they change. Pinned by name in ``wallLines`` too.
    ///
    /// RE-MEASURED at the ingredient-search round's F4b (2026-09-30): `food-search` 7 → 9, for
    /// `TypicalPortionTableTests` (every typical size at its cited SR Legacy row) and
    /// `RecipePortionPickerTests` (the recipe editor's per-food unit menu). Both pinned by name in
    /// ``wallLines`` too.
    ///
    /// RE-MEASURED at the ingredient-search round's F9b (2026-09-30): `food-search` 9 → 13, for the
    /// four correction-memory suites one file declares (`FoodSearchCorrectionMemoryTests`,
    /// `FoodSearchCorrectionCatalogTests`, `FoodSearchCorrectionWipeTests`,
    /// `FoodSearchCorrectionResolverFirewallTests`) — where recipe picks are pinned: their precedence
    /// under a correction, their reach (the recipe surfaces only), the wipe and the closed list of
    /// writers. All four pinned by name in ``wallLines`` too, since `-only-testing:` would skip a
    /// dropped one silently.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.2.0 (2026-10-02): `crypto-goldens` 3 → 4, for
    /// `ProximityNamespaceGoldenTests` — every byte string `ProximityNamespace.fernlet` will carry,
    /// pinned by literal before any A0.2 commit moves one. Its name ends `GoldenTests`, so
    /// ``everyWireGoldenSuiteIsGated()`` demands it on SOME line; this entry and its ``wallLines``
    /// pin are what hold it on this one. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.2.1 (2026-10-02): `crypto-goldens` 4 → 5, for
    /// `ProximityNamespaceSoundnessTests` — the soundness rules, byte rules and collision checks of
    /// ProximityKit's protocol namespace, the label registry every later A0.2 commit routes reads
    /// through. A rule loosened there compiles clean and changes no other test's outcome. Pinned by
    /// name in ``wallLines`` too. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.2's audit sink (2026-10-02): `s3-grep` 8 → 9, for
    /// `ProximityAuditBridgeTests` — the canary that a ProximityKit audit line reaches
    /// `FernletAuditLog` through the bridge `FernletApp.init` installs. A missing install compiles
    /// clean and turns every "this event was not logged" assertion vacuous. The step's floor stays
    /// the shared `1`. Pinned by name in ``wallLines`` too. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.2.12, walls and cleanup (2026-10-02): `s3-grep`
    /// 9 → 10, for `ProximityNamespaceBoundaryTests` — the ratchet that keeps ProximityKit reading
    /// its host's namespace: no namespace, group or purpose built outside `Namespace/`,
    /// `FernletCryptoPurpose` only on the feature lines that leave in A0.4, and every `fernlet`
    /// literal on an exact allowlist with its exit step. Each thing it refuses compiles clean. The
    /// step's floor stays the shared `1`. Pinned by name in ``wallLines`` too. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.3 (2026-10-02): `crypto-goldens` 5 → 6, for
    /// `ProximityVocabularyGoldenTests` — every token and byte string plan step A0.3 routes through
    /// the host (the payload tokens and the sealing rule, the capabilities, the session enums, the
    /// record kinds, the routed types, the coordinator's session messages, the presentation strings,
    /// the trainer export body, the generic types' bytes, three persisted records and the name
    /// sanitizer), pinned by literal and by behaviour before any of them moves. Its name ends
    /// `GoldenTests`, so ``everyWireGoldenSuiteIsGated()`` demands it on SOME line; this entry and its
    /// ``wallLines`` pin hold it on this one. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.3's runtime gate (2026-10-02): `crypto-goldens` 6 → 7,
    /// for `ProximityNamespaceGateTests` — ProximityKit's run-time refusal of an unsound namespace (the
    /// identity's provisioning and group-key wrap, each radio's start) and each manager's refusal of an
    /// identity of another namespace, each held to its error and its audit line. A door that stopped
    /// refusing compiles clean and moves no other test, and its name is not a `GoldenTests` name, so
    /// this entry and its ``wallLines`` pin are all that hold it on a line. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.4.0 (2026-10-03): `crypto-goldens` 7 → 8, for
    /// `FernletFeatureGoldenTests` — every byte Fernlet's features over the proximity stack put on the
    /// wire, in the keychain or on disk that plan step A0.4 moves or re-derives (the seven feature
    /// labels, the pair secrets, the tags, the sealed drop and sidecar, the prekey bundle, the keychain
    /// and storage names, the persisted shapes, presence's advertisement and the sealed-backup escrow's
    /// provisioning cases), pinned by literal and by behaviour before any of it moves. Its name ends
    /// `GoldenTests`, so ``everyWireGoldenSuiteIsGated()`` demands it on SOME line; this entry and its
    /// ``wallLines`` pin hold it on this one. Counted off the line.
    ///
    /// NEW at ProximityKit plan step A0.5.0 (2026-10-04): `mesh-features` (48), the suites that are the
    /// only cover of the behaviour plan step A0.5 moves out of the routed mesh manager (the activity,
    /// clothing-shop, moderation and friend-state suites, friend minting and the vouch gate, the heart
    /// drop, the content merge, the held photos and their review, the routed acks and the session's
    /// messages), gated before anything moves; each ran on no line. A line of its own rather than more
    /// names on `mesh-batteries`, whose floor carries a dated history these suites would churn at every
    /// A0.5 commit. None is a `MeshP<n>…AcceptanceTests` or a `…GoldenTests`, so nothing else here
    /// demands them: this entry, and that step's floor once a Mac has measured it, are what notice one
    /// leaving. Its two walls with no compiler half are pinned by name in ``wallLines`` too. Counted off
    /// the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A0.6.0 (2026-10-09): `s3-grep` 10 → 11, for
    /// `ProximityPlatformBoundaryTests` — the ratchet that keeps ProximityKit free of platform policy
    /// while plan step A0.6 hands every platform fact to its host: the modules ProximityKit imports
    /// (a neutral baseline, and each platform seam an exact row with its guard and exit step), no
    /// device-name source, no platform directory and no default for a fact only the host may state.
    /// Each thing it refuses compiles clean on iOS. The step's floor stays the shared `1`. Pinned by
    /// name in ``wallLines`` too. Counted off the line.
    ///
    /// At ProximityKit plan step A0.8.0 (2026-10-10) no count moves: a selector may now be
    /// `ProximityKitTests/<Suite>`, a suite of ProximityKit's own package test target, and counts as
    /// one name, as a bare one does. Which line names which suite is held exactly, beyond this `>=`,
    /// by `Tests/suite-inventory.tsv` (``theSuiteInventoryIsTheTree()``).
    ///
    /// At ProximityKit plan step A0.8.2 (2026-10-11) no count moves: two names are re-qualified in
    /// place, `mesh-batteries`' `PeerHandleIdentityTests` and `FakePeerTransportTests`, now
    /// `ProximityKitTests/<Suite>` in ProximityKit's package test target.
    ///
    /// NEW at ProximityKit plan step A0.8.3 (2026-10-11): `proximitykit` (6), the six suites of
    /// ProximityKit's package test target that rode no line before they moved there
    /// (`MeshDerivedRosterTests`, `MeshMembershipMergeTests`, `MeshMembershipBoundsTests`,
    /// `MeshRoutedDrainPlanTests`, `NearbyRangingSessionTests`, `ReplayCacheTests`), each named
    /// `ProximityKitTests/<Suite>`. A line of its own, so CI runs every suite the package holds
    /// (`Tests/suite-inventory.tsv`'s I10) and no existing line's floor or history moves. Counted
    /// off the line.
    ///
    /// At ProximityKit plan step A1.1.2 (2026-10-13) no count moves: one name is re-qualified in
    /// place, `crypto-goldens`' `ProximityNamespaceSoundnessTests`, now
    /// `ProximityKitTests/ProximityNamespaceSoundnessTests` in ProximityKit's package test target.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.4 (2026-10-13): `proximitykit` 6 → 11, for the four
    /// epoch suites that rode no line before they moved into ProximityKit's package test target with
    /// `MeshEpochModelTests.swift` (`MeshEpochRefTests`, `MeshEpochKeyringTests`,
    /// `MeshEpochAcceptanceTests`, `MeshFrameReplayWindowTests`) and the new
    /// `PackageTestSupportTests`, which holds the package tests' namespace sound and their file locator
    /// to the package's own folder, each named `ProximityKitTests/<Suite>`; and one name is re-qualified
    /// in place, `mesh-batteries`' `MeshSessionIDClaimTests`, now
    /// `ProximityKitTests/MeshSessionIDClaimTests`, so that count stays. Counted off the lines.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.5 (2026-10-14): `proximitykit` 11 → 12, for the new
    /// `PackageKeychainStoreTests`, the canary of the package tests' in-memory keychain store (the
    /// funnel resolves it, and ProximityKit's identity and seal keys provision, read back, defer and
    /// wipe through it), named `ProximityKitTests/PackageKeychainStoreTests`. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.6 (2026-10-14): `proximitykit` 12 → 13, for the new
    /// `PackageTestHostTests`, the canary of the package tests' host double and audit sink (the bundle's
    /// sink delivers each line to the captures scoped to it, `PackageTestHost` keeps its root and its
    /// keychain services to itself and states every requirement itself, and a mesh manager built over it
    /// provisions its identity into the in-memory keychain unhosted), named
    /// `ProximityKitTests/PackageTestHostTests`. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.7 (2026-10-14): `proximitykit` 13 → 14, for
    /// `ProximityNamespaceBoundaryTests`, the namespace wall, which joins ProximityKit's package tests and
    /// reads ProximityKit's sources and manifest through `PackageRoot`, named
    /// `ProximityKitTests/ProximityNamespaceBoundaryTests`; and `s3-grep` stays 11: the wall leaves that
    /// line and `SwiftSourceLexerTests`, which holds Fernlet's copy of the walls' lexer to the wall's
    /// lexer fixtures, joins it. Counted off the lines.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.8 (2026-10-14): `proximitykit` 14 → 15, for
    /// `ProximityPlatformNeutralityTests`, the platform wall's rules over ProximityKit's own code (its
    /// imports and platform branches, device-name reads, platform directories and host-fact defaults,
    /// its two channel-ready doors and `NIRangingSession`'s one home), which leave
    /// `ProximityPlatformBoundaryTests` for ProximityKit's package tests and read ProximityKit's sources
    /// through `PackageRoot`, named `ProximityKitTests/ProximityPlatformNeutralityTests`; and `s3-grep`
    /// stays 11: `ProximityPlatformBoundaryTests` keeps its place there with Fernlet's half (presence's
    /// heart door and the Mac build). Counted off the lines.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.10 (2026-10-14): `proximitykit` 15 → 17, for
    /// `ProximityKeychainDoorTests`, the keychain door's wall over ProximityKit's own sources and package
    /// tests (the door declared once, in the funnel's `#if DEBUG` branch, whose text it pins, and named by
    /// the package tests' installer alone), which travels with the package, and
    /// `ProximityPresenceSessionTests`, the presence engine's contract over an in-memory radio, each named
    /// `ProximityKitTests/<Suite>`; and `mesh-batteries` 154 → 155, for `MeshSessionStoreIsolationTests`,
    /// the session store's scope-isolation grep-wall, which rode no line. Counted off the lines.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.13 (2026-10-14): `proximitykit` 17 → 18, for
    /// `PackageTestHygieneTests`, the package tests' own hygiene (what their unhosted bundle cannot serve,
    /// rule I9; their imports, rule I11; their own inventory, `FernletKit/Tests/ProximityKitTests.tsv`,
    /// and its declared tests; and no extension of `ProximityHost`), whose rules leave this suite for the
    /// package so they travel with it, named `ProximityKitTests/PackageTestHygieneTests`. `s3-grep` and
    /// `mesh-batteries` keep their names: this suite keeps its ten cells. Counted off the line.
    private static let measuredSuiteNameCounts: [String: Int] = [
        "s3-grep": 11,
        "no-tracking": 1,
        "power-of-10": 1,
        "localization": 1,
        "key-custody": 4,
        "crypto-goldens": 8,
        "privacy-wipe": 4,
        "accessibility": 1,
        "memory-lifecycle": 1,
        "messages-extension": 1,
        "codeowners": 1,
        "messages-envelope": 5,
        "recipe-wire": 1,
        "food-search": 13,
        "mesh-batteries": 155,
        "mesh-features": 48,
        "proximitykit": 18
    ]

    /// The walls each line exists to run, by label — the names a count cannot tell apart.
    ///
    /// ``measuredSuiteNameCounts`` notices a name LEAVING a line, but not a line whose one name was
    /// swapped for another (the count stays one), and not a line whose last name was deleted: with
    /// no suite left, `gatedSteps` no longer parses it as a step, so nothing counts it at all. Every
    /// suite here is a wall with no compiler half — the `MeshRoutedDrainWallTests` argument — so its
    /// line leaving, or it leaving its line, must red rather than go quiet. Since ProximityKit plan step
    /// A1.1.7 the namespace wall is pinned on `proximitykit`, its line in ProximityKit's package tests,
    /// and `SwiftSourceLexerTests` on `s3-grep` in its place: the fixtures of the lexer every Fernlet
    /// source wall reads code through, which the namespace wall held until it moved. Since A1.1.8 the
    /// platform wall's rules over ProximityKit's own code, `ProximityPlatformNeutralityTests`, are pinned
    /// on `proximitykit` too, and `ProximityPlatformBoundaryTests` stays pinned on `s3-grep` with
    /// Fernlet's half. Since A1.1.10 the keychain door's wall over ProximityKit's own code and tests,
    /// `ProximityKeychainDoorTests`, is pinned on `proximitykit` as well; and since A1.1.13 the package
    /// tests' own hygiene, `PackageTestHygieneTests` (what their unhosted bundle cannot serve, their
    /// imports, their inventory and its declared tests, and no extension of `ProximityHost`).
    private static let wallLines: [String: [String]] = [
        "s3-grep": ["S3BoundaryTests", "CompanionEmotionPrivacyTests", "ProximityAuditBridgeTests",
                    "SwiftSourceLexerTests", "ProximityPlatformBoundaryTests"],
        "no-tracking": ["NoTrackingBoundaryTests"],
        "power-of-10": ["PowerOfTenBoundaryTests"],
        "localization": ["LocalizationBoundaryTests"],
        "key-custody": ["KeyCustodyBoundaryTests", "ColumnCryptoDeviceBindingTests",
                        "SealedBackupFormatPinTests", "IdentityProvisioningReadTests"],
        "crypto-goldens": ["CryptographicPurposeBoundaryTests", "CryptographicDomainSeparationTests",
                           "MeshMembershipEventGoldenTests", "ProximityNamespaceGoldenTests",
                           "ProximityNamespaceSoundnessTests", "ProximityVocabularyGoldenTests",
                           "ProximityNamespaceGateTests", "FernletFeatureGoldenTests"],
        "privacy-wipe": ["PrivacyWipeCoverageTests", "PrivacyWipeMediaKeySurvivalTests",
                         "PrivacyWipeAttemptMemoryRemovalTests", "PersistedSurfaceWipeBoundaryTests"],
        "accessibility": ["AccessibilityBoundaryTests"],
        "memory-lifecycle": ["MemoryLifecycleBoundaryTests"],
        "messages-extension": ["MessagesExtensionBoundaryTests"],
        "codeowners": ["CodeOwnersResolutionTests"],
        "messages-envelope": ["ExchangeMessageEnvelopeV2Tests", "ExchangeMultipartRecipeTests",
                              "FernletExchangeTests", "MessagesReceivedItemTests",
                              "MessagesRecipeCardParityTests"],
        "recipe-wire": ["RecipeMultipartWireTests"],
        "food-search": ["IngredientSearchCorpusTests", "CatalogDefaultUnitSweepTests", "FoodIngredientIdentityTests",
                        "TypicalPortionTableTests", "RecipePortionPickerTests", "FoodSearchCorrectionMemoryTests",
                        "FoodSearchCorrectionCatalogTests", "FoodSearchCorrectionWipeTests",
                        "FoodSearchCorrectionResolverFirewallTests"],
        "mesh-features": ["LastMemberPhotoReviewSourceWallTests", "PhotoDirectoryIsolationTests"],
        "proximitykit": ["ProximityNamespaceBoundaryTests", "ProximityPlatformNeutralityTests",
                         "ProximityKeychainDoorTests", "PackageTestHygieneTests"]
    ]

    /// Every floor-script invocation in the workflow, with backslash continuations joined and
    /// comment lines ignored — a commented-out step is not a step.
    static func gatedSteps(in workflow: String) -> [GatedStep] {
        var joined: [String] = []
        var carry = ""
        // R2: bounded by the workflow's line count.
        for rawLine in workflow.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") {
                carry += String(line.dropLast()) + " "
                continue
            }
            joined.append(carry + line)
            carry = ""
        }
        var steps: [GatedStep] = []
        // R2: bounded by the joined line count.
        for line in joined where line.contains(floorScript) {
            let words = line.split(separator: " ").map(String.init)
            guard let at = words.firstIndex(of: floorScript), words.count >= at + 4,
                  let floor = Int(words[at + 2]) else { continue }
            steps.append(GatedStep(label: words[at + 1], floor: floor, selectors: Array(words[(at + 3)...])))
        }
        return steps
    }

    /// Every top-level type name declared in either test target (``testRoots``), subdirectories
    /// included (each target is a folder whose every Swift file it compiles, so a suite may live
    /// anywhere under it): the names some selector can reach. The union of
    /// ``declarations(inTarget:)``; which target declares a name is that function's answer.
    static func declaredTopLevelTypes() throws -> Set<String> {
        var names: Set<String> = []
        // R2: bounded by the test-target list.
        for root in testRoots {
            names.formUnion(try declarations(inTarget: root.target).keys)
        }
        return names
    }

    /// The top-level types one test target declares: each name ``topLevelTypeName(_:)`` reads at
    /// column 0, with the repo-relative files declaring it (once each, in path order). A target
    /// absent from ``testRoots``, or whose folder does not exist, declares nothing.
    static func declarations(inTarget target: String) throws -> [String: [String]] {
        guard let root = testRoots.first(where: { $0.target == target }) else { return [:] }
        var names: [String: [String]] = [:]
        // R2: bounded by the file count under the target's folder.
        for file in PowerOfTenBoundaryTests.swiftFiles(under: root.path, repoRoot: RepoRoot.url) {
            let source = try RepoRoot.source(file)
            // R2: bounded by the file's line count.
            for line in source.components(separatedBy: "\n") {
                guard let name = topLevelTypeName(line), names[name]?.contains(file) != true else { continue }
                names[name, default: []].append(file)
            }
        }
        return names
    }

    /// The modifiers a selector-visible declaration may carry before its keyword, each read past at
    /// most once: `nonisolated` (25 column-0 declarations at plan step A0.8.0, one of them a suite,
    /// `FormatMigratorTests`, which the reader missed before), the four access levels that leave it
    /// visible to a selector, and `final` and `indirect`, which may stand before an access level
    /// (`final public class X`). `package`, `open`, `final` and `indirect` joined at plan step A0.8.5,
    /// when no column-0 declaration of either test target carried one, so no name moved; until then a
    /// package suite declared `package struct` counted its tests toward no type. `private` and
    /// `fileprivate` are not here: such a type is file-scoped, no selector can name it, and the test
    /// tree repeats such names (five `private final class AuditCapture`).
    private static let visibleModifiers = [
        "nonisolated ", "public ", "internal ", "package ", "open ", "final ", "indirect "
    ]

    /// The type keywords a suite or a helper type is declared with.
    private static let typeKeywords = ["struct ", "final class ", "class ", "actor ", "enum "]

    /// The type a column-0 declaration line names, or nil for anything else. Leading attributes on
    /// the same line (`@Suite struct X`, `@Suite(.serialized) struct X`, `@MainActor final class X`)
    /// and ``visibleModifiers`` (`nonisolated struct X`) are skipped; a leading space means a nested
    /// type, which no selector can name, and a `private` or `fileprivate` type is file-scoped.
    private static func topLevelTypeName(_ line: String) -> String? {
        guard let rest = afterAttributes(line, readingPast: visibleModifiers) else { return nil }
        return typeName(rest)
    }

    /// A column-0 line with its leading attributes and then the given modifiers read past (each
    /// modifier at most once, in any order), or nil for a line that does not start at column 0 with
    /// an attribute or a letter (a nested declaration, a comment, a blank line).
    private static func afterAttributes(_ line: String, readingPast modifiers: [String]) -> Substring? {
        guard line.hasPrefix("@") || line.first?.isLetter == true else { return nil }
        var rest = Substring(line)
        // R2: bounded by the line's attribute count — each pass consumes at least one character.
        while rest.hasPrefix("@") {
            var depth = 0
            var index = rest.startIndex
            // R2: bounded by the line length.
            while index < rest.endIndex {
                let character = rest[index]
                if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
                if character == " " && depth == 0 { break }
                index = rest.index(after: index)
            }
            rest = rest[index...].drop { $0 == " " }
        }
        var unread = modifiers
        // R2: bounded by the modifier list — each pass removes one entry from `unread`.
        while let index = unread.firstIndex(where: { rest.hasPrefix($0) }) {
            rest = rest.dropFirst(unread[index].count)
            unread.remove(at: index)
        }
        return rest
    }

    /// The name a declaration's remainder gives a type after one of ``typeKeywords``, or nil.
    private static func typeName(_ rest: Substring) -> String? {
        // R2: bounded by the keyword list.
        for keyword in typeKeywords where rest.hasPrefix(keyword) {
            let name = rest.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// The type an `extension` declaration's remainder extends: its name up to a `:`, `{`, `<`, a
    /// space or a `where` clause (`extension ProximityNamespace.MeshMessages {` names
    /// `ProximityNamespace.MeshMessages`), or nil when the remainder is not an extension.
    private static func extendedTypeName(_ rest: Substring) -> String? {
        guard rest.hasPrefix("extension ") else { return nil }
        let name = rest.dropFirst("extension ".count).prefix { !":{< ".contains($0) }
        return name.isEmpty ? nil : String(name)
    }

    /// Every selector the workflow gates is a declared top-level type of its own test target — a
    /// bare name in `Tests/FernletTests`, `ProximityKitTests/<Suite>` in
    /// `FernletKit/Tests/ProximityKitTests` — so no selector can match nothing, and a suite that moved
    /// bundles under its old spelling is refused here before any simulator runs.
    @Test func everyGatedSelectorNamesADeclaredSuite() throws {
        let steps = Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath))
        var declared: [String: [String: [String]]] = [:]
        // R2: bounded by the test-target list.
        for root in Self.testRoots {
            declared[root.target] = try Self.declarations(inTarget: root.target)
        }
        #expect(steps.count >= 17, "the workflow lost test steps — \(steps.count) floor-script invocations found")
        var undeclared: [String] = []
        // R2: bounded by the step count × the selector count.
        for step in steps {
            #expect(!step.suites.isEmpty, "step \(step.label) names no suite")
            #expect(step.floor >= 1, "step \(step.label) has a vacuous floor")
            let measured = Self.measuredSuiteNameCounts[step.label]
            #expect(measured != nil, """
                step \(step.label) has no entry in `measuredSuiteNameCounts` — a new gated step \
                must record its own measured suite-name count, or names can leave it unnoticed
                """)
            #expect(step.suites.count >= (measured ?? 1), """
                step \(step.label) names \(step.suites.count) suites; \(measured ?? 1) were \
                measured on the line. A name that leaves is a silent loss of coverage which only \
                the step's TEST-count floor would catch, and that needs a simulator — lower this \
                number in the same commit that retires the suite, or put the name back.
                """)
            for token in step.selectors {
                guard let parsed = Self.selector(token) else {
                    undeclared.append("`\(step.label): \(token)` — malformed (a bare name or ProximityKitTests/<Suite>)")
                    continue
                }
                if declared[parsed.target]?[parsed.suite] == nil {
                    undeclared.append("`\(step.label): \(token)` — declared in no file of \(Self.rootPath(of: parsed.target))")
                }
            }
        }
        #expect(undeclared.isEmpty, """
            The workflow names selectors that no file of their own test target declares at top level \
            (a bare name in Tests/FernletTests, ProximityKitTests/<Suite> in \
            FernletKit/Tests/ProximityKitTests) — `-only-testing:` would match nothing and the step \
            would pass having run zero tests of them:
            \(undeclared.joined(separator: "\n"))
            """)
    }

    /// Every mesh acceptance battery declared in the tree is gated, so a new phase's suites cannot
    /// sit ungated the way P3, P4 and P5's did.
    @Test func everyMeshAcceptanceBatteryIsGated() throws {
        let gated = Set(Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath)).flatMap(\.suites))
        let batteries = try Self.declaredTopLevelTypes().filter(Self.isMeshBattery)
        // MEASURED at the commit that moved it, never inherited: 28 at P6 item 7 (2 convergence
        // generators + the routed convergence battery + 4×P3 + 9×P4 + 12×P5), plus P6 item 9's
        // eight clause suites = 36, plus P7 item 7's six clause suites (run policy, gate writer,
        // radio seams, poller, resume, honesty) = 42, plus P8 item 10's six (the coordinator's
        // table, the hold verb, the raises and the disagreement, the presentation table, the task
        // wiring, honesty) = 48, plus P9 item 9's five clause suites (the ephemeral posture, the
        // presence swap, the recipe swap, the MC retirement as an honesty row, honesty) = 53,
        // plus P10 item 9's five clause suites (the scheduling seam, the handler pipeline, the
        // diff rule, the import wall, honesty) = 58. A count of DECLARATIONS, taken by reading
        // the tree — 58 is what the filter returned at this commit, not 53 + 5. Read across both
        // test targets since ProximityKit plan step A0.8.0, whose `nonisolated`-aware reader added
        // no battery: still 58.
        #expect(batteries.count >= 58, "the mesh batteries shrank: \(batteries.count) declared")
        let ungated = batteries.subtracting(gated).sorted()
        #expect(ungated.isEmpty, """
            Mesh acceptance batteries declared in a test target but not named in \
            \(Self.workflowPath) — add each to the mesh step's Scripts/run-gated-suites.sh line and \
            raise that step's floor by its test count:
            \(ungated.joined(separator: "\n"))
            """)
    }

    /// Every wire-golden suite declared in the tree runs on some line.
    ///
    /// A golden pins bytes that shipped peers already sign and verify — a failing one is a WIRE
    /// decision, never re-pinned from Swift's output — and no compiler notices one going unrun.
    /// Until 2026-09-24 nothing here demanded them either: five routed goldens and P1's
    /// `PeerHandleWireGoldenTests` ran on no line while three sibling goldens did, and only a hand
    /// survey found it. Any top-level suite whose name ends `GoldenTests` is demanded now, wherever
    /// it is declared — the ``isMeshBattery(_:)`` rule, applied to vectors.
    @Test func everyWireGoldenSuiteIsGated() throws {
        let gated = Set(Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath)).flatMap(\.suites))
        let goldens = try Self.declaredTopLevelTypes().filter { $0.hasSuffix("GoldenTests") }
        // MEASURED at 2026-09-24 by reading the tree: nine declarations. RE-MEASURED at ProximityKit
        // plan step A0.2.0 (2026-10-02): ten, with `ProximityNamespaceGoldenTests`; at plan step
        // A0.3 (2026-10-02): eleven, with `ProximityVocabularyGoldenTests`; and at plan step A0.4.0
        // (2026-10-03): twelve, with `FernletFeatureGoldenTests`. Read across both test targets since
        // plan step A0.8.0: still twelve, all in Tests/FernletTests.
        #expect(goldens.count >= 12, "the golden suites shrank: \(goldens.count) declared")
        let ungated = goldens.subtracting(gated).sorted()
        #expect(ungated.isEmpty, """
            Golden suites declared in a test target but named on no line of \
            \(Self.workflowPath) — add each to its family's line (the mesh step for a mesh wire \
            vector, crypto-goldens for a signature framing) and raise that step's floor by its \
            test count:
            \(ungated.joined(separator: "\n"))
            """)
    }

    /// Every measured line is still a step, and every wall is still on the line that runs it.
    ///
    /// The two holes ``measuredSuiteNameCounts`` leaves: a step deleted whole (the pin iterates the
    /// steps that exist, so a missing one is never compared) and a wall swapped for another suite
    /// (the count does not move). See ``wallLines``.
    @Test func everyMeasuredLineIsAStepAndEveryWallIsOnItsLine() throws {
        let steps = Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath))
        // R2: bounded by the measured labels.
        for label in Self.measuredSuiteNameCounts.keys.sorted() {
            let runs = steps.filter { $0.label == label }.count
            #expect(runs == 1, """
                `\(label)` is measured in `measuredSuiteNameCounts` but the workflow runs it \(runs) \
                time(s). Zero means the whole step left, which no name count can see; two means one \
                label names two steps, and neither its floor nor its count can say which. Retire the \
                entry in the same commit, with the argument, or put the step back.
                """)
        }
        #expect(Set(Self.wallLines.keys).isSubset(of: Set(Self.measuredSuiteNameCounts.keys)),
                "every wall line is also a measured line")
        // R2: bounded by the wall lines × their walls.
        for (label, walls) in Self.wallLines.sorted(by: { $0.key < $1.key }) {
            let named = Set(steps.first { $0.label == label }?.suites ?? [])
            for wall in walls {
                #expect(named.contains(wall), """
                    `\(wall)` is not on the `\(label)` line. It is a wall with no compiler half — \
                    nothing else runs it on a push — so it must be named there, not only counted.
                    """)
            }
        }
    }

    /// No test step bypasses the floor, and this suite gates itself. Since ProximityKit plan step
    /// A0.8.1 the floor script and the strict build both go through `Fernlet.xcworkspace`, the floor
    /// script reads `ProximityKitTests/<Suite>` selectors and refuses a named suite that ran no test
    /// case, and the workspace and a release archive resolve one CryptoSwift
    /// (``expectTheRunnerReadsTwoTargets(_:workflow:)``, ``expectTheBuildAndTheRunsShareTheWorkspace()``,
    /// ``expectOneCryptoSwiftRevision()``); since A0.8.2 the Fernlet scheme's testables hold the
    /// package test target, which depends on ProximityKit alone
    /// (``expectTheSchemeRunsThePackageTests()``); since A0.8.5 the runner's selector emission is
    /// pinned as code and the enforcement step runs the runner's self-test.
    @Test func everyTestStepRunsThroughTheFloorScript() throws {
        let workflow = try RepoRoot.source(Self.workflowPath)
        let code = workflow.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        #expect(!code.contains("xcodebuild test-without-building"),
                "a raw test-without-building step in the workflow has no floor — route it through \(Self.floorScript)")
        #expect(!code.contains("-only-testing:"),
                "a raw -only-testing: selector in the workflow is unchecked — name the suite on the floor script's line")
        let gated = Set(Self.gatedSteps(in: workflow).flatMap(\.suites))
        let selfGates = Self.gatedSteps(in: workflow).filter { $0.suites.contains("CIGateSelectorBoundaryTests") }
        #expect(selfGates.count >= 2, "this suite must gate itself on two independent steps, so editing one cannot silence it")
        #expect(gated.contains("IdentityProvisioningReadTests") && gated.contains("MeshRoutedRefusalBudgetTests"),
                "the two walls the P5 correction pass added are gated")
        // `MeshRoutedDrainWallTests` is a WALL with no compiler half — the retirement and parking
        // zero-lists item 4 and item 6 put there run nowhere else — so removing it from the line
        // must be a failure rather than a silence, exactly as the two above are.
        // `MeshContinuationRaiseWallTests` joins it at P8 item 10 on the same argument: the two
        // session-state raises have exactly one home each in ProximityKit, the app speaks each
        // exactly once and from one file, and the app offers `applySessionEvent(` zero times — three
        // source counts that exist nowhere else and that no compiler checks.
        // `MeshContinuationTaskHostWallTests` (item 6) is that case again: the `BackgroundTasks`
        // names have one app home outside the DEBUG probe, the feed has one call site, the host
        // speaks no radio verb and the funnel never calls it back — all uncompiled source counts.
        // `MeshRoutedLockedDeviceTests` is gated beside them but is deliberately NOT on this pin: it
        // is 26 behaviour cells over five store states (measured at item 9's own gated run, and the
        // number the workflow's floor decomposition uses), not a zero-list, and
        // `MeshP5LockedDeviceAcceptanceTests` is already its acceptance clause. `MeshRoutedDrainTests`
        // (gated at P8 item 1, 2026-09-18) is the same case and is left off this pin for the same
        // reason: 43 behaviour cells, walled by the step's measured floor, not by a name here. So are
        // P8's five behaviour suites, gated by item 10 in the same commit as the two walls above —
        // `MeshContinuationCoordinatorTests`, `MeshContinuationProgressTests`,
        // `MeshContinuationCardPresentationTests`, `MeshContinuationDriverTests` and
        // `MeshContinuationDisagreementTests`: each is a table or a rig walk whose cells the floor
        // counts, and each has an acceptance clause of its own in `MeshP8AcceptanceTests`.
        // P9 item 6 gates FOURTEEN more on the same argument — the three `MeshKeyAgreement*` suites,
        // the three photo / key-advertisement delivery suites and eight routed behaviour suites,
        // 247 cells: behaviour, not zero-lists, so the step's re-measured floor is what holds them
        // on the line. Two of them (`MeshRoutedItemSealTests`, `MeshRoutedStoreIsolationTests`)
        // carry no `@Suite` attribute at all and seven do not share their file's name — this suite
        // reads DECLARATIONS for exactly that reason, and a selector naming a FILE matches nothing.
        #expect(gated.contains("MeshRoutedDrainWallTests"),
                "the routed path's retirement and parking zero-lists are gated")
        #expect(gated.contains("MeshContinuationRaiseWallTests")
                && gated.contains("MeshContinuationTaskHostWallTests"),
                "P8's two source walls with no compiler half are gated")
        // The one wall among P9 item 6's fourteen: `MeshRoutedStoreIsolationTests` source-scans the
        // test tree for a routed store's construction that names no scope of its own (its raw scan
        // reads this file too, so the constructor is not spelled here), pins the production
        // scope unreachable from tests, and pins the one construction site of
        // `MeshCustodyDurabilityWitness` — uncompiled source counts that run nowhere else, the
        // `MeshRoutedDrainWallTests` argument. Without this line the thirteen behaviour suites
        // beside it are held by the step's floor alone, which needs a simulator; this half is the
        // one that reds with no simulator at all when a name leaves the workflow.
        #expect(gated.contains("MeshRoutedStoreIsolationTests"),
                "the routed store's scope-isolation grep-wall is gated")
        // Its session twin joins it on the same argument at ProximityKit plan step A1.1.10:
        // `MeshSessionStoreIsolationTests` holds every test-tree construction of a session store to a
        // scope of its own, never the production one (both test trees since A1.1.6), and the app's
        // session scope to the seams already walled — uncompiled source counts that ran on no line.
        #expect(gated.contains("MeshSessionStoreIsolationTests"),
                "the session store's scope-isolation grep-wall is gated")
        // P9 item 9 adds the one of its seven newly-gated suites that earns a NAME pin on the
        // existing argument: `TransportNeutralityBoundaryTests` is a source grep-wall with no
        // compiler half — `import MultipeerConnectivity` confined to two files, every framework
        // type matched as a WHOLE identifier, and a permit list whose entries must still EXIST —
        // and it is what `MeshP9McRetirementAcceptanceTests` defers to for the app target, where a
        // substring walk cannot run (the connection inspector renders the literal row label
        // "MCSession", and `FileMCPeerIDStore` is Fernlet's own name). It is also the wall the
        // MC->QUIC cutover empties, so it must be impossible to drop from the line silently first.
        // The other six of the seven are behaviour suites held by the step's measured floor, the
        // `MeshRoutedLockedDeviceTests` precedent.
        #expect(gated.contains("TransportNeutralityBoundaryTests"),
                "the MultipeerConnectivity permit wall is gated")
        let script = try RepoRoot.source(Self.floorScript)
        let readsCount = script.contains("totalTestCount") && script.contains("-resultBundlePath")
        #expect(readsCount, "the floor script no longer reads the result bundle's own count")
        // NOTE-4 of P9 item 6's fix review: a restart re-runs suites, so `totalTestCount` counts
        // some cells twice and every floor above it becomes unreadable — 13 of the mesh step's
        // suites are held by that floor alone. The guard is a grep in a shell script with no
        // compiler half, so it is pinned here, beside the bundle-count pin it protects. Read into a
        // `Bool` first (ProximityKit plan step A0.8.5): a failing expectation prints its source, and
        // one that spelled the marker would be read back by the floor script as a restart.
        let guardsRestart = script.contains(Self.restartMarker)
        #expect(guardsRestart, "the floor script no longer refuses a run xcodebuild restarted")
        // ProximityKit plan step A0.8.1: a package test target is visible only through the workspace,
        // a build and a run through different containers land in different derived data, and a
        // mixed line's total can hide a selector of the wrong target. Each pin is a shell or JSON
        // fact with no compiler half, read here so it reds with no simulator.
        Self.expectTheRunnerReadsTwoTargets(script, workflow: workflow)
        try Self.expectTheBuildAndTheRunsShareTheWorkspace()
        try Self.expectOneCryptoSwiftRevision()
        try Self.expectTheSchemeRunsThePackageTests()
    }

    // MARK: - The container, the runner and the resolution (ProximityKit plan step A0.8.1)

    /// The root workspace the strict build and every run go through: `FernletKit` beside the app
    /// project, the one container in which the Fernlet scheme can see a package test target
    /// (`-project App/Fernlet.xcodeproj` leaves a package testable out of the build graph and exits 0).
    static let workspacePath = "Fernlet.xcworkspace/contents.xcworkspacedata"

    /// The two roots ``workspacePath`` must hold, as its `FileRef` locations.
    static let workspaceRoots = ["group:FernletKit", "group:App/Fernlet.xcodeproj"]

    /// The strict build-for-testing whose derived data every run of ``floorScript`` reads.
    private static let wallCheckScript = "Scripts/spm-wall-check.sh"

    /// The two resolved files that must pin one CryptoSwift (the Scrypt KDF behind FernletLock):
    /// `FernletKit/Package.resolved`, which a build through ``workspacePath`` resolves from (measured
    /// on Xcode 26.5: a zero revision planted there fails `-onlyUsePackageVersionsFromResolvedFile`
    /// through the workspace, while the same plant in the project's file does not), and the app
    /// project's, which `-project`, and so `xcodebuild archive` in `Scripts/release-checksum.sh`,
    /// resolves from. Nothing else holds the two equal, so CI and a release could build different
    /// revisions.
    static let resolvedFiles = [
        "FernletKit/Package.resolved",
        "App/Fernlet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    ]

    /// A shell script's code: every line whose trimmed text starts `#` dropped (the script's own
    /// comments and the embedded Python's), so a pinned word in a comment does not count.
    static func shellCode(_ script: String) -> String {
        script.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// The line xcodebuild prints when it restarts a test run, which ``floorScript`` refuses. It is
    /// only ever expected through a `Bool`, so no failure here prints it, and it is joined from two
    /// pieces, so this file's text never spells it whole: a wall that prints a test file's source on a
    /// failure would otherwise trip the floor script's restart guard too.
    private static let restartMarker = ["Restarting after unexpected exit,", "crash, or test timeout"]
        .joined(separator: " ")

    /// The workflow step that runs the enforcement self-tests, by its `- name:`.
    private static let enforcementStepName =
        "Enforcement self-tests (prove the wall AND the test gate are load-bearing) + clean-tree check"

    /// The runner's self-test, which the enforcement step must run as a line of its own.
    private static let runnerSelfTest = "Scripts/run-gated-suites-selftest.sh"

    /// ``floorScript`` runs through the workspace and never `-project`; reads a
    /// `ProximityKitTests/<Suite>` selector into its target and emits every selector in its own
    /// target (`-only-testing:$target/$suite`, the code line itself, since A0.8.5: the bare text
    /// `ProximityKitTests/` also stands in its refusal message); refuses a suite named twice; reads
    /// the result bundle's tests tree, and refuses both a named suite that ran no test case and a tree
    /// whose suites it cannot read (the suite census). And the workflow's enforcement step runs its
    /// self-test, which holds each of those on the script's live branch. Each fact is read into a
    /// `Bool` before it is expected, so a failure never prints the script: its text holds the restart
    /// marker, which the floor script would read back as a restart.
    private static func expectTheRunnerReadsTwoTargets(_ script: String, workflow: String) {
        let code = shellCode(script)
        let pins: [(needle: String, why: String)] = [
            ("-workspace Fernlet.xcworkspace", "runs through the workspace the strict build uses"),
            (#"ProximityKitTests/*) target="ProximityKitTests""#, "reads a ProximityKitTests/<Suite> selector into its target"),
            (#"ARGS+=("-only-testing:$target/$suite")"#, "emits every selector in its own target"),
            ("is named twice on this line", "refuses a suite named twice on one line"),
            ("xcresulttool get test-results tests", "reads the result bundle's tests tree"),
            ("named but ran no test case", "refuses a named suite that ran no test case"),
            ("no parseable nodeIdentifierURL", "refuses a tests tree whose suites it cannot read")
        ]
        // R2: bounded by the fixed list.
        for pin in pins {
            let holds = code.contains(pin.needle)
            #expect(holds, """
                \(floorScript)'s code no longer contains `\(pin.needle)`: it must say it \(pin.why) \
                (ProximityKit plan step A0.8.1) — a mixed line's total can hide a selector of the \
                wrong target, and only the suite census cannot
                """)
        }
        let throughProject = code.contains("-project ")
        #expect(!throughProject, """
            \(floorScript) runs through `-project`: that container cannot see a package test target, \
            and \(wallCheckScript) builds through the workspace, so a run there reads other derived data
            """)
        let enforcement = stepBody(named: enforcementStepName, in: workflow).components(separatedBy: "\n")
        let runsSelfTest = enforcement.contains(runnerSelfTest)
        #expect(runsSelfTest, """
            the workflow's "\(enforcementStepName)" step no longer runs `\(runnerSelfTest)` as a line of \
            its own: the census, the selector shapes and the restart guard on the runner's live branch \
            are held by nothing that runs
            """)
    }

    /// ``wallCheckScript`` holds one `xcodebuild build-for-testing`, through the workspace and not
    /// `-project`, and the workspace holds both of ``workspaceRoots``.
    private static func expectTheBuildAndTheRunsShareTheWorkspace() throws {
        let commands = ProximityPlatformBoundaryTests.xcodebuildBuildCommands(
            in: try RepoRoot.source(wallCheckScript), action: "build-for-testing")
        #expect(commands.count == 1, "\(wallCheckScript) holds \(commands.count) `xcodebuild build-for-testing` commands, not one")
        let command = commands.first ?? ""
        #expect(ProximityPlatformBoundaryTests.carries("-workspace Fernlet.xcworkspace", in: command)
                && !ProximityPlatformBoundaryTests.carries("-project", in: command), """
            \(wallCheckScript)'s strict build no longer goes through `-workspace Fernlet.xcworkspace` \
            alone: under `-project` a package test target is silently left unbuilt, and \(floorScript) \
            runs through the workspace, so the two would read different derived data
            """)
        let workspace = try RepoRoot.source(workspacePath)
        // R2: bounded by the two roots.
        for root in workspaceRoots {
            #expect(workspace.contains("location = \"\(root)\""),
                    "\(workspacePath) no longer holds the `\(root)` root the strict build and every run need")
        }
    }

    /// Both of ``resolvedFiles`` parse, each holds exactly one `cryptoswift` pin with a location, a
    /// revision and a version, and the two pins are equal. Only `cryptoswift` is compared: a pin one
    /// file holds alone (a branch-pinned package reference carries no `version`) is not this pin's.
    private static func expectOneCryptoSwiftRevision() throws {
        var triples: [[String]] = []
        // R2: bounded by the two files.
        for path in resolvedFiles {
            let read = cryptoSwiftPin(inResolved: try Data(contentsOf: RepoRoot.url(path)), path: path)
            #expect(read.problem == nil, "\(read.problem ?? "")")
            triples.append(read.pin)
        }
        #expect(triples.count == 2 && triples.allSatisfy { $0.count == 3 } && triples[0] == triples[1], """
            \(resolvedFiles[0]) and \(resolvedFiles[1]) pin different CryptoSwift revisions \
            (location, revision, version: \(triples)). CI builds through the workspace, which resolves \
            from the first; a release archive builds through the project, which resolves from the \
            second. Re-resolve so both name one revision, in the same commit.
            """)
    }

    /// The `cryptoswift` pin of one `Package.resolved`'s data as (location, revision, version), or a
    /// problem naming `path`: data that is not JSON, no `pins` array, or not exactly one
    /// `cryptoswift` pin carrying all three.
    static func cryptoSwiftPin(inResolved data: Data, path: String) -> (pin: [String], problem: String?) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return ([], "\(path) is not JSON (\(error)): the CryptoSwift pin cannot be read")
        }
        guard let root = object as? [String: Any], let pins = root["pins"] as? [[String: Any]] else {
            return ([], "\(path) has no `pins` array: the CryptoSwift pin cannot be read")
        }
        let matching = pins.filter { ($0["identity"] as? String) == "cryptoswift" }
        guard matching.count == 1, let pin = matching.first, let state = pin["state"] as? [String: Any],
              let location = pin["location"] as? String, let revision = state["revision"] as? String,
              let version = state["version"] as? String else {
            return ([], """
                \(path) holds \(matching.count) `cryptoswift` pin(s), or one without a location, a \
                revision and a version: exactly one, pinned to a released version, is what the \
                workspace build and a release archive must agree on
                """)
        }
        return ([location, revision, version], nil)
    }

    // MARK: - The scheme and the package test target (ProximityKit plan step A0.8.2)

    /// The app project's shared scheme, whose testables the strict build compiles and every run reads.
    static let schemePath = "App/Fernlet.xcodeproj/xcshareddata/xcschemes/Fernlet.xcscheme"

    /// The package manifest that declares ``packageTarget``.
    static let manifestPath = "FernletKit/Package.swift"

    /// The Fernlet scheme's `<Testables>` hold ``packageTarget`` in the FernletKit container, and the
    /// manifest declares ``packageTarget`` once, depending on ProximityKit alone. Without the testable
    /// the strict build compiles none of the package's tests and every `ProximityKitTests/<Suite>`
    /// selector is refused (xcodebuild exits 70); Xcode may drop the reference on save when the project
    /// is opened alone. One dependency added to the test target would re-open the app's modules, and
    /// Fernlet's namespace, to the package's tests: dependency validation refuses only an import outside
    /// the declared dependencies and their closure, and ProximityKit's closure holds no Fernlet module
    /// since plan step A1.0 (the package's own rule I11, in its `PackageTestHygieneTests`, refuses one by
    /// name besides). Since plan step A0.8.5 the list must
    /// be a literal nothing extends: the target's name is spelled once in the manifest's code and no code
    /// line reaches a target's `.dependencies`, so neither `["ProximityKit"] + [...]` nor a mutation
    /// after the declaration adds one unseen. Each fact is read into a `Bool` before it is expected.
    private static func expectTheSchemeRunsThePackageTests() throws {
        let scheme = try RepoRoot.source(schemePath)
        let testables = scheme.components(separatedBy: "<Testables>").dropFirst().first?
            .components(separatedBy: "</Testables>").first ?? ""
        let holdsTestable = testables.contains("BlueprintName = \"\(packageTarget)\"")
            && testables.contains("ReferencedContainer = \"container:../FernletKit\"")
        #expect(holdsTestable, """
            \(schemePath)'s <Testables> no longer hold \(packageTarget) in `container:../FernletKit`: \
            the strict build would compile none of the package's tests, and every \
            ProximityKitTests/<Suite> selector would be refused. Restore the TestableReference.
            """)
        let manifest = try RepoRoot.source(manifestPath)
        let lists = try packageTestTargetDependencies(in: manifest)
        let code = manifest.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let namings = code.components(separatedBy: "\"\(packageTarget)\"").count - 1
        let mutates = code.contains(".dependencies")
        let onlyProximityKit = lists == [["ProximityKit"]] && namings == 1 && !mutates
        #expect(onlyProximityKit, """
            \(manifestPath) declares \(lists.count) `.testTarget(name: "\(packageTarget)"` with a literal \
            dependency list \(lists), spells "\(packageTarget)" \(namings) time(s) in code, and \
            \(mutates ? "reaches" : "does not reach") a target's `.dependencies`: exactly one declaration, \
            depending on ProximityKit alone by a literal nothing extends or mutates, keeps the app's \
            modules and Fernlet's namespace out of the package's tests
            """)
    }

    /// The quoted names of every `.testTarget(name: "ProximityKitTests", dependencies: [...])`
    /// dependency list in a manifest's text, one list per declaration, in order. A list must close
    /// before a `,` or a `)`, so one extended by `+` is not read as a list at all (plan step A0.8.5).
    static func packageTestTargetDependencies(in manifest: String) throws -> [[String]] {
        let declaration = try NSRegularExpression(
            pattern: #"\.testTarget\(\s*name:\s*"ProximityKitTests"\s*,\s*dependencies:\s*\[([^\]]*)\]\s*[,)]"#)
        let quoted = try NSRegularExpression(pattern: #""([^"]*)""#)
        return ProximityPlatformBoundaryTests.captures(of: declaration, in: manifest).map {
            ProximityPlatformBoundaryTests.captures(of: quoted, in: $0)
        }
    }

    /// The one device every test line runs on is named once, is the same device the scripts default
    /// to, and has NO fallback (plan §17.2.3 finding 6; §28.3's "three UI residuals" row).
    ///
    /// Until 2026-09-21 the workflow's "Resolve a simulator destination" step preferred `iPhone 17`
    /// and otherwise took the newest available iPhone with a `::warning::` — a silent device change
    /// on the line whose appearance baselines (`UXScreenProbe.auditBaselines`) are pinned four ways
    /// to an iPhone 17 in portrait: on any other device — the 17 Pro included, identical point
    /// geometry, different safe areas and font metrics — the probe's environment guard refuses to
    /// run the ratchet at all, and without that guard the deltas read as a regression that never
    /// happened (the 2026-08-27 misdiagnosis its doc records). Pinning the device is the
    /// prerequisite under every UI residual that would put that suite on CI, which is why this cell
    /// exists before the suite does. Four facts, each read from source rather than asserted about a
    /// constant: the step is declared ONCE (the parser reads the first of a name, so a duplicate
    /// could re-export the destination unseen); its live code assigns `name` exactly once, to the
    /// literal, and exports it as the destination — a second assignment IS a fallback, whatever it
    /// is called, so no word is matched and the error message's wording is free; it warns nowhere
    /// and exits non-zero; and the two scripts' `FERNLET_DESTINATION` defaults and the UI probe's
    /// source name the same destination string, so local, CI and the baselines cannot drift.
    @Test func theSimulatorDestinationIsPinnedWithNoFallback() throws {
        let workflow = try RepoRoot.source(Self.workflowPath)
        let declarations = workflow.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "- name: \(Self.destinationStepName)" }
        #expect(declarations.count == 1, """
            \(declarations.count) step(s) are declared as "- name: \(Self.destinationStepName)". \
            `stepBody` reads the FIRST, so a second step of that name could re-export \
            FERNLET_DESTINATION unseen — one step. (A step whose first key is `id:`/`uses:`, or a \
            quoted name, reads as missing here: write it with `- name:` first, unquoted.)
            """)
        let step = Self.stepBody(named: Self.destinationStepName, in: workflow)
        #expect(!step.isEmpty, "the workflow lost its destination step — every test line reads FERNLET_DESTINATION from it")
        let nameAssignments = step.components(separatedBy: "\n").filter { $0.hasPrefix("name=") }
        #expect(nameAssignments == ["name=\"\(Self.pinnedSimulatorName)\""], """
            the destination step assigns `name` \(nameAssignments.count) time(s): \(nameAssignments). \
            It must be assigned exactly once, to the literal "\(Self.pinnedSimulatorName)" — a second \
            assignment is a fallback whatever it is called, and a run on any other device is refused \
            by the appearance baselines' environment guard. Fail, name the fix, never fall back \
            (plan §28.3).
            """)
        #expect(step.contains("FERNLET_DESTINATION=platform=iOS Simulator,name=$name"),
                "the step must export the pinned name as the destination every test line reads")
        #expect(!step.contains("::warning::"),
                "the destination step must not warn its way past a missing device — it fails, or it exports the pin")
        #expect(step.contains("exit 1"), "a missing device must fail the job, in seconds, not warn")
        let canonical = "platform=iOS Simulator,name=\(Self.pinnedSimulatorName)"
        // R2: bounded by the list.
        for path in Self.destinationDefaultHolders {
            let source = try RepoRoot.source(path)
            #expect(source.contains(canonical), """
                \(path) no longer names the canonical destination `\(canonical)` — local runs, CI \
                and the appearance baselines must agree on one device, or a green here and a red \
                there are the same code on different phones
                """)
        }
    }

    /// The device every test line is pinned to. One literal, compared against the workflow's and
    /// the scripts' text — never against a constant of theirs, which could not fail.
    private static let pinnedSimulatorName = "iPhone 17"

    /// The workflow step that exports `FERNLET_DESTINATION`, by its `- name:`.
    private static let destinationStepName = "Resolve a simulator destination"

    /// Where the canonical destination string must also appear: the two scripts whose
    /// `FERNLET_DESTINATION` default is what a local run uses, and the UI probe whose baselines
    /// were recorded on it (its source names the destination twice — the doc and the guard's
    /// failure text; this pins that the file names it, not which copy).
    private static let destinationDefaultHolders = [
        "Scripts/run-gated-suites.sh",
        "Scripts/spm-wall-check.sh",
        "Tests/FernletUITests/UXScreenProbe.swift"
    ]

    /// The non-comment lines of one named workflow step: from its `- name:` line to the next one.
    /// Shared with `ProximityPlatformBoundaryTests` (W6, plan step A0.6.5), which reads the macOS
    /// step's body with it, so a step's title naming a script is never mistaken for a line that runs it.
    static func stepBody(named name: String, in workflow: String) -> String {
        var inStep = false
        var body: [String] = []
        // R2: bounded by the workflow's line count.
        for rawLine in workflow.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- name:") {
                if inStep { break }
                inStep = line == "- name: \(name)"
                continue
            }
            guard inStep, !line.hasPrefix("#") else { continue }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    // MARK: - The suite inventory (ProximityKit plan step A0.8.0)

    /// The checked-in suite inventory. It sits outside both test targets' folders: `Tests/FernletTests`
    /// is a synchronized folder group that would bundle it, and a non-source file in a SwiftPM target
    /// folder is an unhandled-file diagnostic.
    static let inventoryPath = "Tests/suite-inventory.tsv"

    /// The inventory's header, its first line that is not a `#` comment.
    static let inventoryHeader = "target\tsuite\tfile\tlines\tcells"

    /// One inventory row: a suite, the target and file declaring it, the lines that run it and, for a
    /// ProximityKitTests row, its declared test count as the package's own inventory records it.
    struct InventoryRow: Equatable {
        /// The test target, one of ``testRoots``.
        let target: String
        /// The suite's type name, as a selector names it.
        let suite: String
        /// The repo-relative file whose column-0 line declares the suite.
        let file: String
        /// The workflow labels whose selectors name the suite, sorted ascending; empty for `-`.
        let lines: [String]
        /// A ProximityKitTests row's declared test count, its row's in the package's own inventory
        /// (``thePackageRowsAreThePackagesOwnInventory()``), which the package's tests hold to the declared
        /// tests; nil (`-`) for a FernletTests row, whose count the lines' floors and the full runs hold.
        let cells: Int?
    }

    /// The MEASURED rows per target (rule I2). MEASURED at ProximityKit plan step A0.8.0 (2026-10-10):
    /// the 642 suites of a full run of FernletTests at `ba1675f0` (7034 tests, on an iPhone 17
    /// simulator, iOS 26.5), before any suite moved; ProximityKit's package test target held none. A
    /// move changes both entries in the same commit, argued and measured; a suite deleted with its row
    /// lowers its target's entry with the retirement argued, the ``measuredSuiteNameCounts`` rule.
    /// MOVED at plan step A0.8.2 (2026-10-11): 642 → 640 and 0 → 2, for `PeerHandleIdentityTests` and
    /// `FakePeerTransportTests` (`PeerTransportNeutralityTests.swift`), measured in the package's
    /// bundle on `mesh-batteries` at their FernletTests counts. MOVED at plan step A0.8.3
    /// (2026-10-11): 640 → 634 and 2 → 8, for the six suites that rode no line
    /// (`MeshMembershipRecordsTests.swift`'s three, `MeshRoutedDrainPlanTests`,
    /// `NearbyRangingSessionTests`, `ReplayCacheTests`), measured in the package's bundle on the new
    /// `proximitykit` line at their FernletTests counts. MOVED at plan step A1.1.2 (2026-10-13):
    /// 634 → 633 and 8 → 9, for `ProximityNamespaceSoundnessTests`, measured in the package's bundle
    /// on `crypto-goldens` at its FernletTests count. MOVED at plan step A1.1.4 (2026-10-13): 633 → 628
    /// and 9 → 15, for the five suites of `MeshEpochModelTests.swift` and `MeshSessionIDClaimTests.swift`
    /// (the four epoch suites onto `proximitykit`, `MeshSessionIDClaimTests` still on `mesh-batteries`),
    /// measured in the package's bundle at their FernletTests counts, and the package's NEW
    /// `PackageTestSupportTests`, measured on `proximitykit`. RAISED at A1.1.5 (2026-10-14): 15 → 16,
    /// for the package's NEW `PackageKeychainStoreTests`, measured on `proximitykit`; FernletTests stays
    /// 628. RAISED at A1.1.6 (2026-10-14): 16 → 17, for the package's NEW `PackageTestHostTests`, measured
    /// on `proximitykit`; FernletTests stays 628. MOVED at A1.1.7 (2026-10-14): 628 → 627 and 17 → 18, for
    /// `ProximityNamespaceBoundaryTests`, measured in the package's bundle on `proximitykit` at its
    /// FernletTests count, and FernletTests 627 → 628 again for its NEW `SwiftSourceLexerTests`, measured
    /// on `s3-grep`: FernletTests stays 628. RAISED at A1.1.8 (2026-10-14): 18 → 19, for the package's NEW
    /// `ProximityPlatformNeutralityTests`, the platform wall's rules over ProximityKit's own code, measured
    /// on `proximitykit`; FernletTests stays 628, since `ProximityPlatformBoundaryTests` keeps its row with
    /// Fernlet's half. RAISED at A1.1.10 (2026-10-14): 19 → 21, for the package's NEW
    /// `ProximityKeychainDoorTests` and `ProximityPresenceSessionTests`, measured on `proximitykit`;
    /// FernletTests stays 628 (`MeshSessionStoreIsolationTests` keeps its row and joins `mesh-batteries`).
    /// RAISED at A1.1.13 (2026-10-14): 21 → 22, for the package's NEW `PackageTestHygieneTests`, measured
    /// on `proximitykit`; FernletTests stays 628.
    static let measuredInventoryRows: [String: Int] = ["FernletTests": 628, "ProximityKitTests": 22]

    /// Reads the inventory's text into its rows and its format problems by line (rule I1): `#` lines
    /// are comments; the first other line is exactly ``inventoryHeader``; every data line has five
    /// tab-separated fields; `target` is one of ``testRoots``; `suite` is an identifier; `file`
    /// starts with its target's folder and `/` and ends `.swift`; `lines` is `-` or labels sorted
    /// ascending, unique and non-empty; `cells` is a positive integer on a ProximityKitTests row and
    /// `-` on a FernletTests row; rows run strictly ascending by target, then suite; a suite is on one
    /// row only. A line with a field problem is reported and left out of `rows`.
    static func inventory(in text: String) -> (rows: [InventoryRow], problems: [String]) {
        var rows: [InventoryRow] = []
        var problems: [String] = []
        var sawHeader = false
        var suites: Set<String> = []
        // R2: bounded by the text's line count.
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard sawHeader else {
                sawHeader = true
                if line != inventoryHeader {
                    problems.append("line \(offset + 1): the first line that is not a comment is not the header")
                }
                continue
            }
            let read = inventoryRow(line)
            guard let row = read.row else {
                problems.append("line \(offset + 1): \(read.problem ?? "unreadable")")
                continue
            }
            if let previous = rows.last, (previous.target, previous.suite) >= (row.target, row.suite) {
                problems.append("line \(offset + 1): `\(row.suite)` does not sort after `\(previous.suite)` — rows sort by target, then suite")
            }
            if !suites.insert(row.suite).inserted {
                problems.append("line \(offset + 1): `\(row.suite)` is on more than one row")
            }
            rows.append(row)
        }
        if !sawHeader { problems.append("no header line") }
        return (rows, problems)
    }

    /// One data line read into a row, or the first field problem that keeps it out (rule I1).
    private static func inventoryRow(_ line: String) -> (row: InventoryRow?, problem: String?) {
        let fields = line.components(separatedBy: "\t")
        guard fields.count == 5 else { return (nil, "\(fields.count) tab-separated fields, not 5") }
        let (target, suite, file, lines, cells) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard let root = testRoots.first(where: { $0.target == target }) else {
            return (nil, "`\(target)` is not a test target")
        }
        guard isIdentifier(suite) else { return (nil, "`\(suite)` is not a suite name") }
        guard file.hasPrefix(root.path + "/"), file.hasSuffix(".swift") else {
            return (nil, "`\(file)` is not a Swift file under \(root.path)")
        }
        let labels = lines == "-" ? [] : lines.components(separatedBy: ",")
        guard lines == "-" || (labels.allSatisfy { !$0.isEmpty } && labels == Array(Set(labels)).sorted()) else {
            return (nil, "lines `\(lines)` are neither `-` nor labels sorted ascending, unique and non-empty")
        }
        guard target == packageTarget else {
            guard cells == "-" else { return (nil, "a \(target) row's cells are `\(cells)`, not `-`") }
            return (InventoryRow(target: target, suite: suite, file: file, lines: labels, cells: nil), nil)
        }
        guard let count = Int(cells), count > 0 else {
            return (nil, "a \(target) row's cells `\(cells)` are not a positive integer")
        }
        return (InventoryRow(target: target, suite: suite, file: file, lines: labels, cells: count), nil)
    }

    /// The suite inventory is the tree: every suite either test target held at plan step A0.8.0 is a
    /// row naming its target, its file and the lines that run it, declared exactly there and in no
    /// other target; every selector is a row; every package row rides a line; and a line naming a
    /// package suite carries a measured floor of at least its package rows' cells. It is count
    /// conservation's static half: a move that loses, doubles, mis-targets or mis-lines a suite is red
    /// here before any simulator runs. A package row's cells are the package's own inventory's
    /// (``thePackageRowsAreThePackagesOwnInventory()``), whose declared tests the package's
    /// `PackageTestHygieneTests` counts, with what its unhosted bundle cannot serve and its imports, since
    /// ProximityKit plan step A1.1.13.
    @Test func theSuiteInventoryIsTheTree() throws {
        let read = Self.inventory(in: try RepoRoot.source(Self.inventoryPath))
        #expect(read.problems.isEmpty, """
            I1: \(Self.inventoryPath) is malformed:
            \(read.problems.joined(separator: "\n"))
            """)
        var declared: [String: [String: [String]]] = [:]
        // R2: bounded by the test-target list.
        for root in Self.testRoots {
            declared[root.target] = try Self.declarations(inTarget: root.target)
            let count = read.rows.filter { $0.target == root.target }.count
            let measured = Self.measuredInventoryRows[root.target]
            let measuredText = measured.map { String($0) } ?? "none"
            #expect(count == measured, """
                I2: \(Self.inventoryPath) holds \(count) \(root.target) rows; \(measuredText) \
                were measured. A row deleted is a suite leaving CI's sight; a move changes both targets' \
                entries in `measuredInventoryRows` in the same commit, argued and measured.
                """)
        }
        let steps = Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath))
        let rules: [(rule: String, problems: [String])] = [
            ("I3-I5, each suite's home", Self.inventoryHomeProblems(read.rows, declared: declared)),
            ("I6, each suite's lines", Self.inventoryLineProblems(read.rows, steps: steps)),
            ("I8 and I10, the package's lines", Self.packageLineProblems(read.rows, steps: steps))
        ]
        // R2: bounded by the rule list.
        for rule in rules {
            #expect(rule.problems.isEmpty, """
                \(rule.rule) — \(Self.inventoryPath) and the tree disagree; edit the row in the same \
                commit as the suite, never the tree to fit the row:
                \(rule.problems.joined(separator: "\n"))
                """)
        }
    }

    /// I3, I4 and I5: every target with rows has its folder; each row's suite is declared at column 0
    /// in exactly its file within its target; and in no other target (a copy instead of a move would
    /// run twice).
    private static func inventoryHomeProblems(_ rows: [InventoryRow],
                                              declared: [String: [String: [String]]]) -> [String] {
        var problems: [String] = []
        // R2: bounded by the test-target list.
        for root in testRoots where rows.contains(where: { $0.target == root.target }) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: RepoRoot.url(root.path).path, isDirectory: &isDirectory)
            if !(exists && isDirectory.boolValue) {
                problems.append("I3: \(root.target) has rows but no folder at \(root.path)")
            }
        }
        // R2: bounded by the row count × the test-target list.
        for row in rows {
            let files = declared[row.target]?[row.suite] ?? []
            if files.isEmpty {
                problems.append("I4: `\(row.suite)` is declared in no file of \(rootPath(of: row.target)); its row says \(row.file)")
            } else if files != [row.file] {
                problems.append("I4: `\(row.suite)` is declared in \(files.joined(separator: ", ")), not exactly in its row's \(row.file)")
            }
            for root in testRoots where root.target != row.target {
                guard let elsewhere = declared[root.target]?[row.suite] else { continue }
                problems.append("I5: `\(row.suite)`, a \(row.target) row, is also declared in \(root.target) (\(elsewhere.joined(separator: ", "))) — a copy instead of a move runs twice")
            }
        }
        return problems
    }

    /// I6: every selector on every line is a row of its own target, and every row's `lines` is exactly
    /// the sorted labels whose selectors name its target and suite. The one check that sees a
    /// same-count swap: a suite taken off a line and another put on keeps every name count, every
    /// `wallLines` pin and the floor.
    private static func inventoryLineProblems(_ rows: [InventoryRow], steps: [GatedStep]) -> [String] {
        let rowKeys = Set(rows.map { Selector(target: $0.target, suite: $0.suite) })
        var labels: [Selector: Set<String>] = [:]
        var problems: [String] = []
        // R2: bounded by the step count × the selector count.
        for step in steps {
            for token in step.selectors {
                guard let parsed = selector(token), rowKeys.contains(parsed) else {
                    problems.append("I6: `\(step.label): \(token)` is no row of its target in \(inventoryPath)")
                    continue
                }
                labels[parsed, default: []].insert(step.label)
            }
        }
        // R2: bounded by the row count.
        for row in rows {
            let named = (labels[Selector(target: row.target, suite: row.suite)] ?? []).sorted()
            guard row.lines != named else { continue }
            let listed = row.lines.isEmpty ? "-" : row.lines.joined(separator: ",")
            let actual = named.isEmpty ? "no line" : named.joined(separator: ",")
            problems.append("I6: \(row.target) `\(row.suite)`'s row lists \(listed); the workflow names it on \(actual)")
        }
        return problems
    }

    /// I8 and I10: a line naming any package selector carries a measured floor (above the shared `1`,
    /// and at least its package rows' cells), and every package row rides a line, so CI runs every
    /// suite the package holds.
    private static func packageLineProblems(_ rows: [InventoryRow], steps: [GatedStep]) -> [String] {
        var cells: [String: Int] = [:]
        // R2: bounded by the row count.
        for row in rows where row.target == packageTarget {
            cells[row.suite] = row.cells ?? 0
        }
        var problems: [String] = []
        // R2: bounded by the step count × the selector count.
        for step in steps {
            let named = step.selectors.compactMap { selector($0) }.filter { $0.target == packageTarget }
            guard !named.isEmpty else { continue }
            let share = named.reduce(0) { $0 + (cells[$1.suite] ?? 0) }
            if step.floor <= 1 || step.floor < share {
                problems.append("I8: `\(step.label)` names \(named.count) \(packageTarget) suite(s) of \(share) cells under a floor of \(step.floor) — a line with a package suite carries a measured floor")
            }
        }
        // R2: bounded by the row count.
        for row in rows where row.target == packageTarget && row.lines.isEmpty {
            problems.append("I10: \(packageTarget) `\(row.suite)` rides no line, so CI would never run it")
        }
        return problems
    }

    // MARK: - The package's own inventory (rule I7, ProximityKit plan step A1.1.13)

    /// The package's own inventory, repo-relative: every suite of ProximityKit's package test target, its
    /// file under the target's folder and its declared tests, which the package's own
    /// `PackageTestHygieneTests` holds to the package's files. It sits in the package's `Tests` folder
    /// beside the target's folder, so it travels with the package.
    static let packageInventoryPath = "FernletKit/Tests/ProximityKitTests.tsv"

    /// The package inventory's header, its first line that is not a `#` comment.
    static let packageInventoryHeader = "suite\tfile\tcells"

    /// One row of the package's own inventory as this wall reads it.
    struct PackageInventoryRow: Equatable {
        /// The suite's type name.
        let suite: String
        /// Its file, by its path under the package test target's folder.
        let file: String
        /// Its declared tests.
        let cells: Int
    }

    /// The package rows are the package's own inventory (rule I7, re-scoped at ProximityKit plan step
    /// A1.1.13): ``inventoryPath``'s ProximityKitTests rows and ``packageInventoryPath``'s rows name the
    /// same suites, each row's file is the package's under the target's folder, and its cells are the
    /// package's. The declared-test count has one reader, the package's `PackageTestHygieneTests`, which
    /// holds its inventory to the declared tests and their sum (its `measuredDeclaredTests`, the count
    /// this suite pinned as `measuredPackageCells` until then); this cell holds this repository's copy of
    /// each row to it, so I8's floors read the package's counts. The reader and the comparison are
    /// fixtured both ways first: a matching pair passes, and a cells mismatch, a suite in one table only
    /// and a short row are each named.
    @Test func thePackageRowsAreThePackagesOwnInventory() throws {
        Self.expectThePackageMirrorFixtured()
        let fernlet = Self.inventory(in: try RepoRoot.source(Self.inventoryPath)).rows
        let package = Self.packageInventory(in: try RepoRoot.source(Self.packageInventoryPath))
        #expect(package.problems.isEmpty, """
            I7: \(Self.packageInventoryPath) is not a header and three-field rows: \
            \(package.problems.joined(separator: "; "))
            """)
        #expect(!package.rows.isEmpty, "I7: \(Self.packageInventoryPath) holds no row: the reader read nothing")
        let problems = Self.packageMirrorProblems(fernlet, package: package.rows)
        #expect(problems.isEmpty, """
            \(Self.inventoryPath)'s ProximityKitTests rows and the package's own inventory disagree:
            \(problems.joined(separator: "\n"))
            """)
    }

    /// Reads the package's own inventory into its rows and its problems: `#` lines are comments, the first
    /// other line is exactly ``packageInventoryHeader``, and every data line is three tab-separated fields
    /// whose third is an integer. Its other rules (order, names, paths, counts) are the package's to hold.
    static func packageInventory(in text: String) -> (rows: [PackageInventoryRow], problems: [String]) {
        var rows: [PackageInventoryRow] = []
        var problems: [String] = []
        var sawHeader = false
        // R2: bounded by the text's line count.
        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard sawHeader else {
                sawHeader = true
                if line != packageInventoryHeader {
                    problems.append("line \(offset + 1), the first that is not a comment, is not the header")
                }
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let cells = Int(fields[2]) else {
                problems.append("line \(offset + 1) is not three tab-separated fields ending in an integer")
                continue
            }
            rows.append(PackageInventoryRow(suite: fields[0], file: fields[1], cells: cells))
        }
        if !sawHeader { problems.append("no header line") }
        return (rows, problems)
    }

    /// The ways this repository's ProximityKitTests rows (`fernlet`, every row of ``inventoryPath``) and
    /// the package's own rows disagree: a suite in one table only, and a suite whose file (the package's,
    /// under ``packageTarget``'s folder) or cells differ.
    static func packageMirrorProblems(_ fernlet: [InventoryRow], package: [PackageInventoryRow]) -> [String] {
        var ours: [String: InventoryRow] = [:]
        var theirs: [String: PackageInventoryRow] = [:]
        // R2: bounded by this repository's rows.
        for row in fernlet where row.target == packageTarget { ours[row.suite] = row }
        // R2: bounded by the package's rows.
        for row in package { theirs[row.suite] = row }
        var problems: [String] = []
        let same = "a package suite has one row in each, edited in the same commit"
        // R2: bounded by the two tables' suites.
        for suite in Set(ours.keys).union(theirs.keys).sorted() {
            guard let mine = ours[suite] else {
                problems.append("I7: `\(suite)` is a row of \(packageInventoryPath) and no \(packageTarget) row of \(inventoryPath): \(same)")
                continue
            }
            guard let own = theirs[suite] else {
                problems.append("I7: `\(suite)` is a \(packageTarget) row of \(inventoryPath) and no row of \(packageInventoryPath): \(same)")
                continue
            }
            guard mine.file != rootPath(of: packageTarget) + "/" + own.file || mine.cells != own.cells else { continue }
            problems.append("I7: `\(suite)`'s rows disagree: \(inventoryPath) says \(mine.file), \(mine.cells.map { String($0) } ?? "-") cells; \(packageInventoryPath) says \(own.file), \(own.cells): the package's inventory is the count, which its PackageTestHygieneTests holds to the declared tests; edit this repository's row to match")
        }
        return problems
    }

    /// The mirror's reader and comparison, both ways: a package table of a comment, its header and a row
    /// is read as that row; a matching pair passes; a cells mismatch, a suite only the package lists, a
    /// suite only this repository lists and a two-field row are each named.
    private static func expectThePackageMirrorFixtured() {
        let ours = [
            InventoryRow(target: packageTarget, suite: "A", file: rootPath(of: packageTarget) + "/A.swift",
                         lines: ["proximitykit"], cells: 2),
            InventoryRow(target: appTarget, suite: "F", file: "Tests/FernletTests/F.swift", lines: [], cells: nil)
        ]
        let read = packageInventory(in: ["# a comment", packageInventoryHeader, "A\tA.swift\t2", ""].joined(separator: "\n"))
        #expect(read.problems.isEmpty && read.rows == [PackageInventoryRow(suite: "A", file: "A.swift", cells: 2)],
                "the package inventory reader read \(read)")
        #expect(packageMirrorProblems(ours, package: read.rows).isEmpty, "a matching pair was refused")
        let mismatch = packageMirrorProblems(ours, package: [PackageInventoryRow(suite: "A", file: "A.swift", cells: 3)])
        #expect(mismatch.contains { $0.contains("`A`'s rows disagree") }, "a cells mismatch was not named: \(mismatch)")
        let theirsOnly = packageMirrorProblems(ours, package: read.rows + [PackageInventoryRow(suite: "B", file: "B.swift", cells: 1)])
        #expect(theirsOnly.contains { $0.contains("`B` is a row of") }, "a suite only the package lists was not named: \(theirsOnly)")
        let oursOnly = packageMirrorProblems(ours, package: [])
        #expect(oursOnly.contains { $0.contains("`A` is a \(packageTarget) row of") },
                "a suite only this repository lists was not named: \(oursOnly)")
        #expect(!packageInventory(in: packageInventoryHeader + "\nA\tA.swift").problems.isEmpty, "a two-field row was read")
    }

    // MARK: - A line's code (the replacement reader's, rule T6)

    /// A line's code: each string literal's contents blanked (its quotes kept), a trailing `//`
    /// comment outside a literal cut, and whether a multi-line literal (`"""`) opens on the line, whose
    /// following lines up to its closing delimiter are not code.
    private static func codePart(of line: String) -> (code: String, opensMultilineString: Bool) {
        let characters = Array(line)
        var code = ""
        var inString = false
        var escaped = false
        var index = 0
        // R2: bounded by the line's length — each pass consumes one character or returns.
        while index < characters.count {
            let character = characters[index]
            index += 1
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    code.append(character)
                }
                continue
            }
            if character == "\"", index + 1 < characters.count, characters[index] == "\"", characters[index + 1] == "\"" {
                return (code, true)
            }
            if character == "/", index < characters.count, characters[index] == "/" { break }
            inString = character == "\""
            code.append(character)
        }
        return (code, false)
    }

    // MARK: - Twins (ProximityKit plan step A0.8)

    /// The helper files both test targets compile, each a whole file present in both and held
    /// identical but for its import lines by ``everyTwinMatchesItsOriginal()``: (the package copy, the
    /// FernletTests copy), repo-relative. A test target cannot import another, so a helper a moved
    /// suite and a staying one both use lives twice: the fake peer transport fabric
    /// (`VirtualClock`, `FakePeerNetwork`, `FakePeerTransport`) since plan step A0.8.2, which
    /// `FakePeerTransportTests` uses in the package and 22 FernletTests files use in the app's target;
    /// and since A0.8.3 the ranging mock (`MockRangingProvider`), which `NearbyRangingSessionTests`
    /// uses in the package and 29 FernletTests files use, and the membership fixtures
    /// (`MeshMembershipFixtures`, extracted from `MeshMembershipRecordsTests.swift`), which its three
    /// suites use in the package and six FernletTests files use; and since A1.1.2 the mesh-message
    /// spelling helper (`extension ProximityNamespace.MeshMessages` in
    /// `ProximityNamespaceMeshMessagesSpelling.swift`, extracted from
    /// `ProximityNamespaceSoundnessTests.swift` at A1.1.1), which `ProximityNamespaceSoundnessTests`
    /// uses in the package and the namespace and vocabulary goldens and the runtime gate
    /// (`ProximityNamespaceGateTests`) use in FernletTests; and since A1.1.4 the package tests'
    /// namespace (`.packageTest`, `TestSupport/PackageTestNamespace.swift` in the package), which the
    /// package's suites compute under and `ProximityNamespaceGoldenTests` holds disjoint from Fernlet's
    /// in FernletTests, and the epoch fixtures (`MeshEpochFixtures`, extracted from
    /// `MeshEpochModelTests.swift`), which its four suites use in the package and three FernletTests
    /// files use, each half minting through its own target's bindings; and since A1.1.7 the source walls'
    /// lexer (`SwiftSourceLexer`, `TestSupport/SwiftSourceLexer.swift` in the package, extracted from
    /// `ProximityNamespaceBoundaryTests.swift`), which the namespace wall (and since A1.1.8 the platform
    /// wall's rules over ProximityKit's code, `ProximityPlatformNeutralityTests`) reads ProximityKit
    /// through in the package and Fernlet's source walls read code through in FernletTests, each half
    /// held to the same fixtures in its own target (the namespace wall's lexer cell,
    /// `SwiftSourceLexerTests`).
    static let twins: [(package: String, fernlet: String)] = [
        (package: "FernletKit/Tests/ProximityKitTests/Mocks/FakePeerTransport.swift",
         fernlet: "Tests/FernletTests/Mocks/FakePeerTransport.swift"),
        (package: "FernletKit/Tests/ProximityKitTests/Mocks/MockRangingProvider.swift",
         fernlet: "Tests/FernletTests/Mocks/MockRangingProvider.swift"),
        (package: "FernletKit/Tests/ProximityKitTests/MeshMembershipFixtures.swift",
         fernlet: "Tests/FernletTests/MeshMembershipFixtures.swift"),
        (package: "FernletKit/Tests/ProximityKitTests/ProximityNamespaceMeshMessagesSpelling.swift",
         fernlet: "Tests/FernletTests/ProximityNamespaceMeshMessagesSpelling.swift"),
        (package: "FernletKit/Tests/ProximityKitTests/TestSupport/PackageTestNamespace.swift",
         fernlet: "Tests/FernletTests/PackageTestNamespace.swift"),
        (package: "FernletKit/Tests/ProximityKitTests/MeshEpochFixtures.swift",
         fernlet: "Tests/FernletTests/MeshEpochFixtures.swift"),
        (package: "FernletKit/Tests/ProximityKitTests/TestSupport/SwiftSourceLexer.swift",
         fernlet: "Tests/FernletTests/SwiftSourceLexer.swift")
    ]

    /// The MEASURED twin count (rule T1): 0 at plan step A0.8.0 (2026-10-10); 1 at A0.8.2
    /// (2026-10-11), the fake peer transport; 3 at A0.8.3 (2026-10-11), with the ranging mock and the
    /// membership fixtures; 4 at A1.1.2 (2026-10-13), with the mesh-message spelling helper; 6 at
    /// A1.1.4 (2026-10-13), with the package tests' namespace and the epoch fixtures; 7 at A1.1.7
    /// (2026-10-14), with the source walls' lexer. Each twin added or retired changes it in the same
    /// commit.
    static let measuredTwinCount = 7

    /// The line prefixes of an import, in every form a test file spells one: `import `, `@testable
    /// import ` and `@preconcurrency import `.
    private static let importPrefixes = ["import ", "@testable import ", "@preconcurrency import "]

    /// A twin's comparable body: its lines, in order, minus every line whose trimmed text starts
    /// with one of ``importPrefixes`` (a package copy cannot import the app, so the two copies'
    /// imports may differ and nothing else may).
    static func twinBody(_ source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !importPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    // MARK: - Replacements (ProximityKit plan step A1.1)

    /// The replacement pairs (rules T5 and T6): (the package file, the FernletTests file, the package's
    /// token, Fernlet's token), the files repo-relative. A replacement is not a twin: the package file
    /// restores the FernletTests file's call shapes over the package tests' namespace where the
    /// FernletTests file restores them over Fernlet's, which the package cannot name, so the two can
    /// never be one file. Each declaration of the package file is a declaration of the FernletTests
    /// file, verbatim once the package's token reads Fernlet's, so no shape the package's suites
    /// compute through can drift from the one the FernletTests suites were written against; and, as
    /// for a twin, the keys the two declare (rule T3) are declared nowhere else in either target. Since
    /// A1.1.4 the package's test bindings (`TestSupport/PackageTestBindings.swift`), which replace
    /// `ProximityNamespaceTestBindings.swift` with `.packageTest` for `.fernlet`.
    static let replacements: [(package: String, fernlet: String, packageToken: String, fernletToken: String)] = [
        (package: "FernletKit/Tests/ProximityKitTests/TestSupport/PackageTestBindings.swift",
         fernlet: "Tests/FernletTests/ProximityNamespaceTestBindings.swift",
         packageToken: ".packageTest", fernletToken: ".fernlet")
    ]

    /// The MEASURED replacement count (rule T5): 1 at plan step A1.1.4 (2026-10-13), the package's
    /// test bindings. Each replacement added or retired changes it in the same commit.
    static let measuredReplacementCount = 1

    /// One declaration a replacement file holds (rule T6).
    struct ReplacementMember: Hashable {
        /// The declaration it sits in: `extension <Type>` for a member of an extension, `""` for a
        /// top-level declaration.
        let container: String
        /// Its code lines, whole and in order: its comment lines and blank lines are not among them.
        let lines: [String]
    }

    /// The declarations a Swift source holds, for the replacement rule (T6), in order: every
    /// top-level declaration but an import and an extension, and every declaration one level inside an
    /// extension, each from its first code line (an attribute on a line of its own included) through
    /// the line on which its braces, parentheses and brackets balance again, counted on each line's
    /// code (``codePart(of:)``: literals blanked, a trailing comment cut), so a brace in a string or a
    /// comment counts for nothing. A comment line and a blank line belong to no declaration; a
    /// multi-line literal's lines belong to the declaration they sit in.
    static func replacementMembers(of source: String) -> [ReplacementMember] {
        var members: [ReplacementMember] = []
        var container = ""
        var depth = 0
        var open: (container: String, base: Int, lines: [String])?
        var nesting = 0
        var inMultilineString = false
        // R2: bounded by the source's line count.
        for line in source.components(separatedBy: "\n") {
            guard !inMultilineString else {
                open?.lines.append(line)
                inMultilineString = !line.contains("\"\"\"")
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            let read = codePart(of: line)
            inMultilineString = read.opensMultilineString
            let braces = read.code.filter { $0 == "{" }.count - read.code.filter { $0 == "}" }.count
            let groups = read.code.filter { "([".contains($0) }.count - read.code.filter { ")]".contains($0) }.count
            if open == nil {
                if depth == 0, importPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
                if depth == 0, let extended = afterAttributes(line, readingPast: visibleModifiers).flatMap(extendedTypeName) {
                    depth = max(0, braces)
                    container = depth == 0 ? "" : "extension " + extended
                    continue
                }
                if depth == 1, read.code.trimmingCharacters(in: .whitespaces) == "}" {
                    depth = 0
                    container = ""
                    continue
                }
                open = (container: depth == 0 ? "" : container, base: depth, lines: [])
                nesting = 0
            }
            guard var member = open else { continue }
            member.lines.append(line)
            depth += braces
            nesting += groups
            let attributeOnly = trimmed.hasPrefix("@") && afterAttributes(trimmed, readingPast: [])?.isEmpty == true
            if depth <= member.base && nesting <= 0 && !attributeOnly {
                members.append(ReplacementMember(container: member.container, lines: member.lines))
                depth = member.base
                open = nil
            } else {
                open = member
            }
        }
        return members
    }

    /// T6: each replacement pair's two files exist, the package file holds at least one declaration
    /// (``replacementMembers(of:)``), and every one of them, with the pair's package token read as
    /// Fernlet's on each line, equals a declaration of the FernletTests file in the same container;
    /// each that equals none is named by its container and first line.
    private static func replacementProblems() throws -> [String] {
        var problems: [String] = []
        // R2: bounded by the replacement list.
        for pair in replacements {
            let missing = [pair.package, pair.fernlet].filter { !FileManager.default.fileExists(atPath: RepoRoot.url($0).path) }
            guard missing.isEmpty else {
                problems.append("T6: the replacement \(pair.package) / \(pair.fernlet) is missing \(missing.joined(separator: ", "))")
                continue
            }
            let package = replacementMembers(of: try RepoRoot.source(pair.package))
            let fernlet = Set(replacementMembers(of: try RepoRoot.source(pair.fernlet)))
            if package.isEmpty {
                problems.append("T6: \(pair.package) holds no declaration the reader can name, so nothing in it is held to \(pair.fernlet)")
            }
            // R2: bounded by the package file's declarations.
            for member in package {
                let read = member.lines.map { $0.replacingOccurrences(of: pair.packageToken, with: pair.fernletToken) }
                guard !fernlet.contains(ReplacementMember(container: member.container, lines: read)) else { continue }
                let place = member.container.isEmpty ? "at the top level" : "in `\(member.container)`"
                let first = member.lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                problems.append("T6: \(pair.package) declares `\(first)` \(place), which equals no declaration of \(pair.fernlet) with `\(pair.packageToken)` read as `\(pair.fernletToken)`: a replacement restores that file's shapes verbatim over the package tests' namespace, and adds none of its own")
            }
        }
        return problems
    }

    /// The non-private top-level declaration keys one test target holds (rule T3), each with the
    /// repo-relative files declaring it: a type ``topLevelTypeName(_:)`` reads, a `protocol` or a
    /// `typealias` by its bare name (it shares a type's name space; plan step A0.8.5),
    /// `extension <Type>`, or a column-0 `func`, `let` or `var` name. `private` and `fileprivate`
    /// declarations are file-scoped and have no key.
    static func declarationKeys(inTarget target: String) throws -> [String: [String]] {
        var keys: [String: [String]] = [:]
        // R2: bounded by the file count under the target's folder.
        for file in PowerOfTenBoundaryTests.swiftFiles(under: rootPath(of: target), repoRoot: RepoRoot.url) {
            // R2: bounded by the file's line count.
            for line in try RepoRoot.source(file).components(separatedBy: "\n") {
                guard let key = declarationKey(line), keys[key]?.contains(file) != true else { continue }
                keys[key, default: []].append(file)
            }
        }
        return keys
    }

    /// The key a column-0, non-private declaration line declares (rule T3), or nil.
    private static func declarationKey(_ line: String) -> String? {
        guard let rest = afterAttributes(line, readingPast: visibleModifiers) else { return nil }
        if let type = typeName(rest) { return type }
        if let extended = extendedTypeName(rest) { return "extension " + extended }
        // R2: bounded by the keyword list.
        for keyword in ["protocol ", "typealias ", "func ", "let ", "var "] where rest.hasPrefix(keyword) {
            let name = rest.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { return nil }
            let namesAType = keyword == "protocol " || keyword == "typealias "
            return namesAType ? String(name) : keyword + String(name)
        }
        return nil
    }

    /// The helpers both test targets compile are twins, the package's test bindings a replacement of
    /// Fernlet's, and nothing else is declared in both: T1 the twin list holds the measured count; T2
    /// each pair's two files exist and their bodies (``twinBody(_:)``) are equal; T3 every non-private
    /// top-level declaration key present in both targets (a type, a protocol or a typealias,
    /// `extension <Type>`, or a column-0 `func`, `let` or `var`) is declared only in the two halves of
    /// one listed twin or replacement pair, so a helper copied outside a pair, by type or by extension,
    /// is red; T4 the comparator itself: an import-only difference is equal, a code difference is not;
    /// T5 the replacement list holds the measured count (ProximityKit plan step A1.1); T6 each
    /// replacement's package file declares only declarations of its FernletTests file, verbatim once
    /// the package's token reads Fernlet's; T7 the declaration reader itself, on a fixture.
    @Test func everyTwinMatchesItsOriginal() throws {
        #expect(Self.twins.count == Self.measuredTwinCount, """
            T1: \(Self.twins.count) twin pairs are listed; \(Self.measuredTwinCount) were measured. A twin \
            added or retired changes `measuredTwinCount` in the same commit.
            """)
        #expect(Self.replacements.count == Self.measuredReplacementCount, """
            T5: \(Self.replacements.count) replacement pairs are listed; \(Self.measuredReplacementCount) \
            were measured. A replacement added or retired changes `measuredReplacementCount` in the same \
            commit.
            """)
        let problems = try Self.twinPairProblems() + Self.replacementProblems() + Self.sharedDeclarationProblems()
        #expect(problems.isEmpty, """
            Helpers both test targets declare are not twins or replacements:
            \(problems.joined(separator: "\n"))
            """)
        let original = "import Foundation\n@testable import Fernlet\n\nlet x = 1\n"
        let copy = "@preconcurrency import ProximityKit\n\nlet x = 1\n"
        #expect(Self.twinBody(original) == Self.twinBody(copy), "T4: an import-only difference is equal")
        #expect(Self.twinBody("let x = 1\n") != Self.twinBody("let x = 2\n"), "T4: a code difference is not")
        Self.expectTheReplacementReaderFixtured()
    }

    /// T7: the replacement rule's declaration reader on a fixture. An import and an extension's
    /// opening and closing lines are no declaration; a one-line member, a member whose signature
    /// spans lines after an attribute on a line of its own, a member whose string and comment hold
    /// braces, and a top-level function are one each, with their comment and blank lines dropped.
    private static func expectTheReplacementReaderFixtured() {
        let fixture = """
            import Foundation
            @testable import ProximityKit

            /// The extension.
            extension Shape {

                /// One line.
                var one: Int { 1 }

                @MainActor
                static func two(
                    first: Int,
                    second: Int
                ) -> Int {
                    // A comment {
                    first + second
                }

                func three() -> String { "}{" } // }
            }

            func four() {
                _ = [1, 2].map { $0 }
            }
            """
        let expected = [
            ReplacementMember(container: "extension Shape", lines: ["    var one: Int { 1 }"]),
            ReplacementMember(container: "extension Shape", lines: [
                "    @MainActor", "    static func two(", "        first: Int,", "        second: Int",
                "    ) -> Int {", "        first + second", "    }"
            ]),
            ReplacementMember(container: "extension Shape",
                              lines: ["    func three() -> String { \"}{\" } // }"]),
            ReplacementMember(container: "", lines: ["func four() {", "    _ = [1, 2].map { $0 }", "}"])
        ]
        let read = replacementMembers(of: fixture)
        #expect(read == expected, "T7: the replacement reader read \(read)")
    }

    /// T2: each listed pair's two files exist and their bodies are equal, the first differing line
    /// named.
    private static func twinPairProblems() throws -> [String] {
        var problems: [String] = []
        // R2: bounded by the twin list.
        for twin in twins {
            let missing = [twin.package, twin.fernlet].filter { !FileManager.default.fileExists(atPath: RepoRoot.url($0).path) }
            guard missing.isEmpty else {
                problems.append("T2: the twin \(twin.package) / \(twin.fernlet) is missing \(missing.joined(separator: ", "))")
                continue
            }
            let package = twinBody(try RepoRoot.source(twin.package))
            let fernlet = twinBody(try RepoRoot.source(twin.fernlet))
            guard package != fernlet else { continue }
            let shared = min(package.count, fernlet.count)
            let first = (0..<shared).first { package[$0] != fernlet[$0] } ?? shared
            let left = first < package.count ? package[first] : "(end of file)"
            let right = first < fernlet.count ? fernlet[first] : "(end of file)"
            problems.append("T2: \(twin.package) and \(twin.fernlet) differ at body line \(first + 1): `\(left)` against `\(right)`")
        }
        return problems
    }

    /// T3: every declaration key present in both targets is declared only in one listed twin or
    /// replacement pair's two halves.
    private static func sharedDeclarationProblems() throws -> [String] {
        let packageKeys = try declarationKeys(inTarget: packageTarget)
        let appKeys = try declarationKeys(inTarget: appTarget)
        let pairs = twins + replacements.map { (package: $0.package, fernlet: $0.fernlet) }
        var problems: [String] = []
        // R2: bounded by the package's key count × the pair list.
        for (key, packageFiles) in packageKeys.sorted(by: { $0.key < $1.key }) {
            guard let appFiles = appKeys[key] else { continue }
            let paired = pairs.contains { packageFiles == [$0.package] && appFiles == [$0.fernlet] }
            guard !paired else { continue }
            problems.append("T3: `\(key)` is declared in both targets (\(packageFiles.joined(separator: ", ")); \(appFiles.joined(separator: ", "))) outside one twin or replacement pair's two halves")
        }
        return problems
    }

    /// The parser reads the workflow's real shape: a continuation-joined invocation with a label, a
    /// floor and several selectors, a package selector among them, and ignores everything else; and
    /// the selector, declaration, inventory, resolution and dependency readers each read their fixtures
    /// (ProximityKit plan step A0.8.0; the declared-test reader's are the package's own since A1.1.13).
    @Test func theParserReadsContinuationJoinedInvocations() throws {
        let sample = """
            run: |
              set -euo pipefail
              # every Scripts/run-gated-suites.sh line must name a declared suite
              Scripts/run-gated-suites.sh mesh-batteries 101 \\
                MeshP3SessionAcceptanceTests \\
                MeshRoutedDrainConvergenceTests
              echo done
              # Scripts/run-gated-suites.sh commented 9 CommentedOutTests
              Scripts/run-gated-suites.sh s3-grep 1 S3BoundaryTests
              Scripts/run-gated-suites.sh crypto-goldens 355 CryptographicPurposeBoundaryTests \\
                ProximityKitTests/ProximityNamespaceSoundnessTests
            """
        let steps = Self.gatedSteps(in: sample)
        #expect(steps == [
            GatedStep(label: "mesh-batteries", floor: 101,
                      selectors: ["MeshP3SessionAcceptanceTests", "MeshRoutedDrainConvergenceTests"]),
            GatedStep(label: "s3-grep", floor: 1, selectors: ["S3BoundaryTests"]),
            GatedStep(label: "crypto-goldens", floor: 355,
                      selectors: ["CryptographicPurposeBoundaryTests", "ProximityKitTests/ProximityNamespaceSoundnessTests"])
        ])
        #expect(steps.last?.suites == ["CryptographicPurposeBoundaryTests", "ProximityNamespaceSoundnessTests"],
                "a step's suites are its selectors with the target prefix dropped")
        #expect(Self.isMeshBattery("MeshP5HonestyAcceptanceTests"))
        #expect(Self.isMeshBattery("MeshP12FooAcceptanceTests"))
        #expect(!Self.isMeshBattery("MeshPhotoAcceptanceTests"))
        #expect(!Self.isMeshBattery("MeshP5AcceptanceFailure"))
        Self.expectDeclarationReaderFixtured()
        Self.expectSelectorReaderFixtured()
        Self.expectInventoryReaderFixtured()
        Self.expectResolutionReaderFixtured()
        try Self.expectTheDependencyReaderFixtured()
        let steps2 = """
              - name: Other step
                run: echo other
              # - name: Resolve a simulator destination
              - name: Resolve a simulator destination
                run: |
                  # a comment inside the step is not code
                  name="iPhone 17"
              - name: After
                run: echo after
            """
        #expect(Self.stepBody(named: "Resolve a simulator destination", in: steps2) == "run: |\nname=\"iPhone 17\"",
                "a step body is its own non-comment lines, and a commented-out `- name:` does not open one")
        #expect(Self.stepBody(named: "Missing", in: steps2).isEmpty)
    }

    /// The column-0 declaration reader: attributes skipped, `nonisolated`, `public` and `internal`
    /// read past, a nested, commented or file-scoped type not a selector, and the T3 keys.
    private static func expectDeclarationReaderFixtured() {
        #expect(topLevelTypeName("@Suite struct CIGateSelectorBoundaryTests {") == "CIGateSelectorBoundaryTests")
        #expect(topLevelTypeName("@Suite(.serialized) struct MeshP5HonestyAcceptanceTests {") == "MeshP5HonestyAcceptanceTests")
        #expect(topLevelTypeName("@MainActor final class Rig: XCTestCase {") == "Rig")
        #expect(topLevelTypeName("final class MeshRoutedBackpressureAuditCapture {") == "MeshRoutedBackpressureAuditCapture")
        #expect(topLevelTypeName("    struct Nested {") == nil, "a nested type is not a selector")
        #expect(topLevelTypeName("// struct InAComment") == nil)
        #expect(topLevelTypeName("nonisolated struct FormatMigratorTests {") == "FormatMigratorTests",
                "a nonisolated suite is a selector (FormatMigratorTests, which the reader missed before plan step A0.8.0)")
        #expect(topLevelTypeName("public final class Visible {") == "Visible")
        #expect(topLevelTypeName("private struct FileScoped {") == nil, "a file-scoped type is no selector's")
        #expect(topLevelTypeName("@Suite package struct PackageScoped {") == "PackageScoped")
        #expect(topLevelTypeName("final public class FinalFirst {") == "FinalFirst")
        #expect(topLevelTypeName("open class Open {") == "Open")
        #expect(declarationKey("protocol Shared {") == "Shared", "a protocol shares a type's name space")
        #expect(declarationKey("public typealias Shared = Int") == "Shared")
        #expect(declarationKey("indirect enum Tree {") == "Tree")
        #expect(declarationKey("extension ProximityNamespace.MeshMessages {") == "extension ProximityNamespace.MeshMessages")
        #expect(declarationKey("extension FakePeerTransport: Sendable {") == "extension FakePeerTransport")
        #expect(declarationKey("@MainActor func makeRig() -> Rig {") == "func makeRig")
        #expect(declarationKey("let sharedValue = 1") == "let sharedValue")
        #expect(declarationKey("private final class AuditCapture {") == nil, "a file-scoped declaration has no T3 key")
        #expect(declarationKey("    func nested() {}") == nil)
    }

    /// The selector reader: a bare name is a FernletTests suite, `ProximityKitTests/<Suite>` a
    /// package suite, and every other shape is refused.
    private static func expectSelectorReaderFixtured() {
        #expect(selector("S3BoundaryTests") == Selector(target: "FernletTests", suite: "S3BoundaryTests"))
        #expect(selector("ProximityKitTests/X") == Selector(target: "ProximityKitTests", suite: "X"))
        // R2: bounded by the fixed list.
        for refused in ["FernletTests/X", "Other/X", "ProximityKitTests/A/B", "ProximityKitTests/", "", "A-B"] {
            #expect(selector(refused) == nil, "`\(refused)` is not a selector")
        }
    }

    /// The inventory reader: comments skipped, the header read, one row per target kept, and a row
    /// with four fields reported and left out.
    private static func expectInventoryReaderFixtured() {
        let text = [
            "# a comment",
            inventoryHeader,
            "FernletTests\tS3BoundaryTests\tTests/FernletTests/S3BoundaryTests.swift\ts3-grep\t-",
            "ProximityKitTests\tReplayCacheTests\tFernletKit/Tests/ProximityKitTests/ReplayCacheTests.swift\tproximitykit\t1",
            "ProximityKitTests\tShortRow\tFernletKit/Tests/ProximityKitTests/ShortRow.swift\t-",
            ""
        ].joined(separator: "\n")
        let read = inventory(in: text)
        #expect(read.rows == [
            InventoryRow(target: "FernletTests", suite: "S3BoundaryTests", file: "Tests/FernletTests/S3BoundaryTests.swift",
                         lines: ["s3-grep"], cells: nil),
            InventoryRow(target: "ProximityKitTests", suite: "ReplayCacheTests",
                         file: "FernletKit/Tests/ProximityKitTests/ReplayCacheTests.swift", lines: ["proximitykit"], cells: 1)
        ])
        #expect(read.problems.count == 1, "the four-field row is the one problem: \(read.problems)")
    }

    /// The resolution pin's readers, both ways: a file's one `cryptoswift` pin is read as its triple
    /// beside a branch-pinned reference that carries no version; a file that is not JSON, one with two
    /// `cryptoswift` pins and one whose pin has no version are each a named problem; and a shell
    /// script's comment lines, indented or not, are not its code.
    private static func expectResolutionReaderFixtured() {
        let pin = #"{"identity":"cryptoswift","location":"L","state":{"revision":"R","version":"1.10.0"}}"#
        let branch = #"{"identity":"proximitykit","location":"P","state":{"branch":"main","revision":"B"}}"#
        let both = Data(#"{"pins":[\#(pin),\#(branch)],"version":3}"#.utf8)
        #expect(cryptoSwiftPin(inResolved: both, path: "a").pin == ["L", "R", "1.10.0"])
        #expect(cryptoSwiftPin(inResolved: both, path: "a").problem == nil)
        let refused = [
            Data("not json".utf8),
            Data(#"{"pins":[\#(pin),\#(pin)]}"#.utf8),
            Data(#"{"pins":[{"identity":"cryptoswift","location":"L","state":{"branch":"main","revision":"R"}}]}"#.utf8)
        ]
        // R2: bounded by the fixed list.
        for data in refused {
            #expect(cryptoSwiftPin(inResolved: data, path: "b").problem != nil, "a resolved file the pin cannot read was read")
        }
        #expect(shellCode("# a comment\nARGS=(-workspace X)\n    # indented -project\necho done") == "ARGS=(-workspace X)\necho done")
    }

    /// The dependency pin's reader (plan step A0.8.5): it reads no list that `+` extends, and reads a
    /// literal list as its names.
    private static func expectTheDependencyReaderFixtured() throws {
        let extended = #".testTarget(name: "ProximityKitTests", dependencies: ["ProximityKit"] + ["FernletConnections"],"#
        let literal = #".testTarget(name: "ProximityKitTests", dependencies: ["ProximityKit"])"#
        let extendedLists = try packageTestTargetDependencies(in: extended)
        #expect(extendedLists.isEmpty, "a list `+` extends is not a list")
        let literalLists = try packageTestTargetDependencies(in: literal)
        #expect(literalLists == [["ProximityKit"]])
    }
}
