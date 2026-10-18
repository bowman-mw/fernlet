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
// top-level type in `Tests/FernletTests`, the one test target a line names, every mesh acceptance
// battery and wire golden declared there must be named by the workflow (the P3/P4/P5 batteries were
// ungated for three phases because nothing said they had to be), `Tests/suite-inventory.tsv` must be
// the tree (every suite's file and lines), the strict build and every run go through
// `Fernlet.xcworkspace`, which resolves the same revision of every package the app project pins
// (CryptoSwift since ProximityKit plan step A0.8.1, and ProximityKit itself, from its own repository
// since A1.3, at exactly 0.1.1 since the re-pin of 2026-10-17), the pin's four spellings name one
// released tag at the commit it was cut on, and this suite gates itself. ProximityKit's own tests,
// with the rules that keep them clean and the inventory that counts them, are its repository's since
// plan step A1.3.

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

    /// The app's unit-test target, the one test target a selector names.
    static let appTarget = "FernletTests"

    /// ``appTarget``'s repo-relative folder: every Swift file under it is one the target compiles.
    static let testRoot = "Tests/FernletTests"

    /// Reads one workflow token: a bare identifier names an ``appTarget`` suite, and is that suite's
    /// name. Every other shape is nil, `FernletTests/<Suite>` among them (one spelling, so this wall and
    /// `Scripts/run-gated-suites.sh` read a line alike), as is `ProximityKitTests/<Suite>`, the shape a
    /// line named ProximityKit's package tests with until plan step A1.3 moved them, and their CI, to
    /// its own repository.
    static func selector(_ token: String) -> String? {
        isIdentifier(token) ? token : nil
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
        /// The selectors as the workflow writes them, in workflow order: each a bare `FernletTests`
        /// suite name, or a malformed token kept whole, so it still names nothing
        /// (``everyGatedSelectorNamesADeclaredSuite()`` reports it).
        let selectors: [String]
        /// The suite names, in workflow order: the selectors themselves, since a selector is a bare
        /// name (ProximityKit plan step A1.3 retired the qualified shape).
        var suites: [String] { selectors }
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
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.14 (2026-10-14): `proximitykit` 18 → 19, for
    /// `PackageTestTreeWallTests`, the package tests' tree walls (the one install of an audit sink, the
    /// session and routed stores' scopes and the scratch-root needle, ML5's two holders and the
    /// determinism digests' homes), whose package halves leave Fernlet's walls, which read Fernlet's
    /// trees alone now, named `ProximityKitTests/PackageTestTreeWallTests`. `s3-grep`, `mesh-batteries`
    /// and `memory-lifecycle` keep their names. Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.15 (2026-10-14): `proximitykit` 19 → 20, for
    /// `ProximitySourceWallTests`, the walls over ProximityKit's own code (its launch hooks read only
    /// inside `#if DEBUG`, each family at its floor; no synchronizable keychain row and no
    /// non-`ThisDeviceOnly` class), whose ProximityKit halves leave Fernlet's hook and key-custody walls,
    /// which read Fernlet's shipping roots but ProximityKit's folder now, named
    /// `ProximityKitTests/ProximitySourceWallTests`. `s3-grep` and `key-custody` keep their names (S3's
    /// ProximityKit row left for the platform suite's W1, already on `proximitykit`). Counted off the line.
    ///
    /// RE-MEASURED at ProximityKit plan step A1.1.17 (2026-10-14): `proximitykit` 20 → 21, for
    /// `ProximityMemoryLifecycleTests`, the memory-lifecycle wall's ML1-ML4 over ProximityKit's own code
    /// (its stored tasks cancelled, its observers removed, observation tracking in `ObservationLoop` alone,
    /// every `Task` in a host-holding file pinned or marked), whose ProximityKit half leaves Fernlet's
    /// `MemoryLifecycleBoundaryTests`, which reads Fernlet's shipping roots but ProximityKit's folder now,
    /// named `ProximityKitTests/ProximityMemoryLifecycleTests`. `memory-lifecycle` keeps its one name.
    /// Counted off the line.
    ///
    /// LOWERED, deliberately, at ProximityKit plan step A1.3 (2026-10-15): Fernlet depends on
    /// ProximityKit's tag `0.1.0`, and the package's tests left this repository with it, so its CI runs
    /// them on every lane there. The `proximitykit` line (21) is retired with its entry;
    /// `crypto-goldens` 8 → 7, for `ProximityNamespaceSoundnessTests`; and `mesh-batteries` 155 → 153,
    /// for `PeerHandleIdentityTests`, `FakePeerTransportTests` and `MeshSessionIDClaimTests`, less
    /// the bare `FakePeerTransportTests` that rejoins it: Fernlet's copy of the fake fabric's check,
    /// over the `FakePeerTransport.swift` its acceptance batteries build on, so 155 − 3 + 1. And
    /// `mesh-batteries` 153 → 152 in the same step, for `MeshRoutedCustodyHandoffWallTests`, whose nine
    /// cells all read ProximityKit's sources and are the package's copy of that suite now (no Fernlet
    /// half). This is the retirement argued. Counted off the lines.
    ///
    /// RE-MEASURED at the Open Food Facts deadline fix (2026-10-11, landed after plan step A1.3):
    /// `no-tracking` 1 → 2, for `OpenFoodFactsLookupTests`, which holds the conditions
    /// Docs/No-Tracking-Wall.md §3 attaches to `world.openfoodfacts.org` beyond its host pin: no request
    /// without the web-nutrition-lookup consent, the exact request, the cap, the deadline, no retries
    /// and the audit line at dispatch. Each compiles clean when it breaks, and it ran on no line. The
    /// step's floor stays the shared `1`. Pinned by name in ``wallLines`` too. Counted off the line.
    ///
    /// RE-MEASURED at the de-flake of tracker §2.4 (2026-10-17): `mesh-batteries` 152 → 154, for
    /// `SealedIntroductionTests` and `ProximityCoordinatorTests`, and `mesh-features` 50 → 51, for
    /// `HeartShareTests`. These are the three suites the CI-breadth round (2026-09-24) and plan step
    /// A0.5.0 named as de-flake follow-ups and left on no line, because each waited on the wall clock in
    /// a way no floor can price. Each cell now waits for the state or the inspector record that a
    /// coordinator's hop lands on, and a cell that asserts an absence waits for the record its handler
    /// makes for that input. None is a `MeshP<n>…AcceptanceTests` or a `…GoldenTests`, so this entry
    /// and the two steps' MEASURED floors are what notice one leaving. Counted off the lines.
    private static let measuredSuiteNameCounts: [String: Int] = [
        "s3-grep": 11,
        "no-tracking": 2,
        "power-of-10": 1,
        "localization": 1,
        "key-custody": 4,
        "crypto-goldens": 7,
        "privacy-wipe": 4,
        "accessibility": 1,
        "memory-lifecycle": 1,
        "messages-extension": 1,
        "codeowners": 1,
        "messages-envelope": 5,
        "recipe-wire": 1,
        "food-search": 13,
        "mesh-batteries": 154,
        "mesh-features": 51
    ]

    /// The walls each line exists to run, by label — the names a count cannot tell apart.
    ///
    /// ``measuredSuiteNameCounts`` notices a name LEAVING a line, but not a line whose one name was
    /// swapped for another (the count stays one), and not a line whose last name was deleted: with
    /// no suite left, `gatedSteps` no longer parses it as a step, so nothing counts it at all. Every
    /// suite here is a wall with no compiler half — the `MeshRoutedDrainWallTests` argument — so its
    /// line leaving, or it leaving its line, must red rather than go quiet. `SwiftSourceLexerTests` is
    /// pinned on `s3-grep`: the fixtures of the lexer every Fernlet source wall reads code through, and
    /// `ProximityPlatformBoundaryTests` beside it with Fernlet's half of the platform wall (presence's
    /// heart door and the Mac-ready set's build). The walls over ProximityKit's own code and tests (the
    /// namespace, platform, keychain-door, hygiene, tree, source and memory-lifecycle walls) were pinned
    /// on the `proximitykit` line from plan steps A1.1.7 to A1.1.17, and the soundness rules of its
    /// namespace on `crypto-goldens`; since plan step A1.3 all of them are its repository's, run by its
    /// own CI.
    private static let wallLines: [String: [String]] = [
        "s3-grep": ["S3BoundaryTests", "CompanionEmotionPrivacyTests", "ProximityAuditBridgeTests",
                    "SwiftSourceLexerTests", "ProximityPlatformBoundaryTests"],
        "no-tracking": ["NoTrackingBoundaryTests", "OpenFoodFactsLookupTests"],
        "power-of-10": ["PowerOfTenBoundaryTests"],
        "localization": ["LocalizationBoundaryTests"],
        "key-custody": ["KeyCustodyBoundaryTests", "ColumnCryptoDeviceBindingTests",
                        "SealedBackupFormatPinTests", "IdentityProvisioningReadTests"],
        "crypto-goldens": ["CryptographicPurposeBoundaryTests", "CryptographicDomainSeparationTests",
                           "MeshMembershipEventGoldenTests", "ProximityNamespaceGoldenTests",
                           "ProximityVocabularyGoldenTests", "ProximityNamespaceGateTests",
                           "FernletFeatureGoldenTests"],
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
        "mesh-features": ["LastMemberPhotoReviewSourceWallTests", "PhotoDirectoryIsolationTests"]
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

    /// Every top-level type name ``appTarget`` declares, subdirectories included (the target is a
    /// folder whose every Swift file it compiles, so a suite may live anywhere under it): the names a
    /// selector can reach. ``declarations()``'s keys.
    static func declaredTopLevelTypes() throws -> Set<String> {
        Set(try declarations().keys)
    }

    /// The top-level types ``appTarget`` declares: each name ``topLevelTypeName(_:)`` reads at column
    /// 0 of a file under ``testRoot``, with the repo-relative files declaring it (once each, in path
    /// order).
    static func declarations() throws -> [String: [String]] {
        var names: [String: [String]] = [:]
        // R2: bounded by the file count under the target's folder.
        for file in PowerOfTenBoundaryTests.swiftFiles(under: testRoot, repoRoot: RepoRoot.url) {
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
    /// when no column-0 declaration of a test target carried one, so no name moved. `private` and
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

    /// Every selector the workflow gates is a bare name declared at top level in `Tests/FernletTests`,
    /// so no selector can match nothing, and a suite named in a retired spelling (the
    /// `ProximityKitTests/<Suite>` of ProximityKit's package tests, which left with the package at plan
    /// step A1.3) is refused here before any simulator runs.
    @Test func everyGatedSelectorNamesADeclaredSuite() throws {
        let steps = Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath))
        let declared = try Self.declarations()
        #expect(steps.count >= 16, "the workflow lost test steps — \(steps.count) floor-script invocations found")
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
                guard let suite = Self.selector(token) else {
                    undeclared.append("`\(step.label): \(token)` — malformed (a selector is a bare suite name)")
                    continue
                }
                if declared[suite] == nil {
                    undeclared.append("`\(step.label): \(token)` — declared in no file of \(Self.testRoot)")
                }
            }
        }
        #expect(undeclared.isEmpty, """
            The workflow names selectors that no file of \(Self.testRoot) declares at top level — \
            `-only-testing:` would match nothing and the step would pass having run zero tests of them:
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
        // test targets from ProximityKit plan step A0.8.0, whose `nonisolated`-aware reader added
        // no battery, to A1.3, which left FernletTests the one (the package's held none): still 58.
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
        // (2026-10-03): twelve, with `FernletFeatureGoldenTests`. Read across both test targets from
        // plan step A0.8.0 to A1.3, and over Tests/FernletTests alone since: still twelve, all there.
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
    /// script refuses a named suite that ran no test case, and the workspace and a release archive
    /// resolve one revision of every package both pin, CryptoSwift and, since A1.3, ProximityKit
    /// (``expectTheRunnerHoldsEveryLine(_:workflow:)``, ``expectTheBuildAndTheRunsShareTheWorkspace()``,
    /// ``expectOneRevisionPerSharedPin()``); since A0.8.5 the runner's selector emission is pinned as
    /// code and the enforcement step runs the runner's self-test.
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
        // scope of its own, never the production one (Fernlet's tree; the package's half is its own
        // `PackageTestTreeWallTests` since A1.1.14), and the app's session scope to the seams already
        // walled — uncompiled source counts that ran on no line.
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
        // ProximityKit plan step A0.8.1: a build and a run through different containers land in
        // different derived data, a line's total can hide a named suite that ran nothing, and CI and a
        // release archive resolve from different files. Each pin is a shell or JSON fact with no
        // compiler half, read here so it reds with no simulator.
        Self.expectTheRunnerHoldsEveryLine(script, workflow: workflow)
        try Self.expectTheBuildAndTheRunsShareTheWorkspace()
        try Self.expectOneRevisionPerSharedPin()
    }

    // MARK: - The container, the runner and the resolution (ProximityKit plan steps A0.8.1 and A1.3)

    /// The root workspace the strict build and every run go through: `FernletKit` beside the app
    /// project. It stays (ProximityKit plan step A1.3) for developing across repositories (A1.5): a
    /// sibling checkout of the `proximitykit` package dragged into it overrides the pinned tag on one
    /// machine, never committed, while CI always builds the tag. The strict build and every run share
    /// it because a build and a run through different containers land in different derived data.
    static let workspacePath = "Fernlet.xcworkspace/contents.xcworkspacedata"

    /// The two roots ``workspacePath`` must hold, as its `FileRef` locations.
    static let workspaceRoots = ["group:FernletKit", "group:App/Fernlet.xcodeproj"]

    /// The strict build-for-testing whose derived data every run of ``floorScript`` reads.
    private static let wallCheckScript = "Scripts/spm-wall-check.sh"

    /// The two resolved files that must pin one revision of every package both pin:
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

    /// The packages both of ``resolvedFiles`` must pin, each once and to a released version, and the
    /// only ones either may pin: CryptoSwift, the Scrypt KDF behind FernletLock (ProximityKit plan step
    /// A0.8.1), and ProximityKit, the peer-to-peer subsystem, from its own repository (A1.3), at exactly
    /// 0.1.1 since the re-pin of 2026-10-17 (``theFourPinSpellingsNameOneReleasedProximityKitVersion()``).
    /// The floor that keeps ``expectOneRevisionPerSharedPin()`` from passing on two files that pin
    /// nothing in common, and, since A1.3's review fixes, the ceiling that refuses a third pin: a
    /// package a later ProximityKit tag depended on would reach Fernlet as one more pin in both files
    /// and nowhere else, since neither manifest would name it (`NoTrackingBoundaryTests` reads the
    /// manifests, `Docs/No-Tracking-Wall.md` §2).
    static let sharedPinIdentities = ["cryptoswift", "proximitykit"]

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

    /// ``floorScript`` runs through the workspace and never `-project`; emits every selector in
    /// FernletTests (`-only-testing:FernletTests/$suite`, the code line itself, since A0.8.5); refuses
    /// a suite named twice; reads the result bundle's tests tree, and refuses both a named suite that
    /// ran no test case and a tree whose suites it cannot read (the suite census). And the workflow's
    /// enforcement step runs its self-test, which holds each of those, and the refusal of every other
    /// selector shape, on the script's live branch. Each fact is read into a `Bool` before it is
    /// expected, so a failure never prints the script: its text holds the restart marker, which the
    /// floor script would read back as a restart.
    private static func expectTheRunnerHoldsEveryLine(_ script: String, workflow: String) {
        let code = shellCode(script)
        let pins: [(needle: String, why: String)] = [
            ("-workspace Fernlet.xcworkspace", "runs through the workspace the strict build uses"),
            (#"ARGS+=("-only-testing:FernletTests/$suite")"#, "emits every selector in FernletTests, the one test target"),
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
                (ProximityKit plan step A0.8.1) — a line's total can hide a named suite that ran nothing, \
                and only the suite census cannot
                """)
        }
        let throughProject = code.contains("-project ")
        #expect(!throughProject, """
            \(floorScript) runs through `-project`, and \(wallCheckScript) builds through the workspace, \
            so a run there reads other derived data than the strict build made
            """)
        let enforcement = stepBody(named: enforcementStepName, in: workflow).components(separatedBy: "\n")
        let runsSelfTest = enforcement.contains(runnerSelfTest)
        #expect(runsSelfTest, """
            the workflow's "\(enforcementStepName)" step no longer runs `\(runnerSelfTest)` as a line of \
            its own: the census, the selector shape and the restart guard on the runner's live branch \
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
            alone: \(floorScript) runs through the workspace, so a build through another container \
            leaves every run reading other derived data
            """)
        let workspace = try RepoRoot.source(workspacePath)
        // R2: bounded by the two roots.
        for root in workspaceRoots {
            #expect(workspace.contains("location = \"\(root)\""),
                    "\(workspacePath) no longer holds the `\(root)` root the strict build and every run need")
        }
    }

    /// Both of ``resolvedFiles`` parse (``pins(inResolved:path:)``), and the two agree
    /// (``sharedPinProblems(_:_:)``): each pins every one of ``sharedPinIdentities`` and nothing else,
    /// and every identity both pin is pinned alike in both.
    private static func expectOneRevisionPerSharedPin() throws {
        var tables: [[String: [String]]] = []
        // R2: bounded by the two files.
        for path in resolvedFiles {
            let read = pins(inResolved: try Data(contentsOf: RepoRoot.url(path)), path: path)
            #expect(read.problems.isEmpty, "\(read.problems.joined(separator: "\n"))")
            tables.append(read.pins)
        }
        let problems = tables.count == 2 ? sharedPinProblems(tables[0], tables[1]) : ["read \(tables.count) files"]
        #expect(problems.isEmpty, """
            \(resolvedFiles[0]) and \(resolvedFiles[1]) disagree, or pin a package outside \
            \(sharedPinIdentities). CI builds through the workspace, which resolves from the first; a \
            release archive builds through the project, which resolves from the second. Re-resolve both, \
            in the same commit:
            \(problems.joined(separator: "\n"))
            """)
    }

    /// The ways two resolved files' pins (``pins(inResolved:path:)``, the workspace's first) fall short:
    /// an identity of ``sharedPinIdentities`` either file lacks, an identity outside them either file
    /// pins (the set is exact, so a dependency of a dependency, which no manifest names, cannot arrive
    /// unreviewed), and an identity both pin to different (location, revision, version) triples.
    static func sharedPinProblems(_ workspace: [String: [String]], _ project: [String: [String]]) -> [String] {
        var problems: [String] = []
        // R2: bounded by the required identities.
        for identity in sharedPinIdentities where workspace[identity] == nil || project[identity] == nil {
            problems.append("`\(identity)` is not pinned in both files: each must pin all of \(sharedPinIdentities)")
        }
        // R2: bounded by the two files' pins.
        for identity in Set(workspace.keys).union(project.keys).sorted() where !sharedPinIdentities.contains(identity) {
            problems.append("""
                `\(identity)` is pinned outside \(sharedPinIdentities): every package of the resolved \
                graph, a dependency of a dependency included, needs an entry in NoTrackingBoundaryTests' \
                allowlist and in Docs/No-Tracking-Wall.md, and one here, before it ships
                """)
        }
        // R2: bounded by the first file's pins.
        for (identity, triple) in workspace.sorted(by: { $0.key < $1.key }) {
            guard let other = project[identity], other != triple else { continue }
            problems.append("`\(identity)` is pinned to \(triple) in one file and \(other) in the other")
        }
        return problems
    }

    /// Every pin of one `Package.resolved`'s data, by identity, as (location, revision, version), and
    /// the problems naming `path`: data that is not JSON, no `pins` array, a pin with no identity, a
    /// location or a revision, an identity pinned twice, and a pin of ``sharedPinIdentities`` with no
    /// version (it must be a released one). Another pin with no version (a branch-pinned reference)
    /// reads with an empty one.
    static func pins(inResolved data: Data, path: String) -> (pins: [String: [String]], problems: [String]) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return ([:], ["\(path) is not JSON (\(error)): its pins cannot be read"])
        }
        guard let root = object as? [String: Any], let entries = root["pins"] as? [[String: Any]] else {
            return ([:], ["\(path) has no `pins` array: its pins cannot be read"])
        }
        var pins: [String: [String]] = [:]
        var problems: [String] = []
        // R2: bounded by the file's pin count.
        for entry in entries {
            let state = entry["state"] as? [String: Any]
            guard let identity = entry["identity"] as? String, let location = entry["location"] as? String,
                  let revision = state?["revision"] as? String else {
                problems.append("\(path) holds a pin without an identity, a location and a revision")
                continue
            }
            let version = state?["version"] as? String
            if version == nil && sharedPinIdentities.contains(identity) {
                problems.append("\(path) pins `\(identity)` to no version: it must be a released one")
            }
            if pins[identity] != nil {
                problems.append("\(path) pins `\(identity)` twice")
            }
            pins[identity] = [location, revision, version ?? ""]
        }
        return (pins, problems)
    }

    // MARK: - The pin's four spellings (the re-pin to ProximityKit 0.1.1)

    /// ProximityKit's repository, as the manifest's `.package(url:)` and the app project's remote
    /// reference both spell it.
    static let proximityKitURL = "https://github.com/bowman-mw/proximitykit"

    /// The manifest that names ProximityKit's version for every build through ``workspacePath``.
    private static let manifestPath = "FernletKit/Package.swift"

    /// The app project, whose remote reference names ProximityKit's version for `-project` (a release
    /// archive).
    private static let projectPath = "App/Fernlet.xcodeproj/project.pbxproj"

    /// Every ProximityKit tag Fernlet has pinned, each with the commit its tag names
    /// (`git rev-parse <tag>^{commit}` in the package's repository), as the tag was cut. A tag moved
    /// after the fact, or a version mistyped into all four spellings, resolves to a revision this table
    /// does not hold for that version. Tags never move: a re-pin adds its tag's row in the same commit as
    /// the four spellings, and no row is ever edited.
    static let releasedRevisions = [
        "0.1.0": "6648094f6acf5cb6f37ef0102f182540d83146cd",
        "0.1.1": "e09affe44af0d763478a1f84207bdad7a3d650c1"
    ]

    /// One spelling of the ProximityKit pin: the file that writes it, the version it names (nil when
    /// none can be read as an exact one), and, for a resolved file, the revision it resolves.
    struct PinSpelling: Equatable {
        /// The repo-relative file that writes the spelling.
        let site: String
        /// The exact version it names, or nil.
        let version: String?
        /// The revision a resolved file resolves; nil for a manifest.
        let revision: String?
    }

    /// The four load-bearing spellings of the ProximityKit pin name one version, and both resolved files
    /// resolve it to the commit ``releasedRevisions`` holds for that tag (the ProximityKit remainder
    /// proposal's §2 "move together" check, owner default 9; added at the re-pin to 0.1.1, 2026-10-17).
    /// The spellings: ``manifestPath``'s `exact:`, ``projectPath``'s `exactVersion`, and the `version`
    /// of both of ``resolvedFiles``. ``expectOneRevisionPerSharedPin()`` holds the two resolved files to
    /// each other, never to the manifests or to the tag, so a re-pin that moved one manifest and
    /// re-resolved through one container, or a resolved file edited by hand to agree with the other,
    /// passed it. Each spelling is a manifest or JSON fact with no compiler half (SwiftPM resolves
    /// whatever the files say), read here so it reds with no simulator.
    @Test func theFourPinSpellingsNameOneReleasedProximityKitVersion() throws {
        var spellings = [
            PinSpelling(site: Self.manifestPath, version: Self.manifestExactVersion(
                try RepoRoot.source(Self.manifestPath), url: Self.proximityKitURL), revision: nil),
            PinSpelling(site: Self.projectPath, version: Self.projectExactVersion(
                try RepoRoot.source(Self.projectPath), url: Self.proximityKitURL), revision: nil)
        ]
        // R2: bounded by the two files.
        for path in Self.resolvedFiles {
            // A pin reads as (location, revision, version), its version empty when it names none.
            let pin = Self.pins(inResolved: try Data(contentsOf: RepoRoot.url(path)), path: path).pins["proximitykit"]
            let version = pin.flatMap { $0.count == 3 && !$0[2].isEmpty ? $0[2] : nil }
            spellings.append(PinSpelling(site: path, version: version, revision: pin.flatMap { $0.count == 3 ? $0[1] : nil }))
        }
        let problems = Self.pinAgreementProblems(spellings)
        #expect(problems.isEmpty, """
            The ProximityKit pin is spelled four ways, and they must name one released tag at the commit \
            `releasedRevisions` holds for it. A re-pin moves \(Self.manifestPath)'s `exact:` and \
            \(Self.projectPath)'s `exactVersion` by hand, re-resolves both of \(Self.resolvedFiles) through \
            the workspace and through `-project` (never by hand), and adds the tag's row, in one commit:
            \(problems.joined(separator: "\n"))
            """)
    }

    /// The ways the pin's spellings fall short: a spelling that names no exact version, spellings that
    /// name more than one version, and a resolved spelling whose version ``releasedRevisions`` does not
    /// hold or whose revision is not the one it holds for that version.
    static func pinAgreementProblems(_ spellings: [PinSpelling]) -> [String] {
        var problems: [String] = []
        // R2: bounded by the spellings.
        for spelling in spellings where spelling.version == nil {
            problems.append("\(spelling.site) names no exact version of proximitykit: Fernlet pins it `exact:`, all four ways")
        }
        let versions = Set(spellings.compactMap(\.version))
        if versions.count > 1 {
            let named = spellings.map { "\($0.site) \($0.version ?? "(none)")" }.joined(separator: ", ")
            problems.append("the pin's spellings name \(versions.count) versions, not one: \(named)")
        }
        // R2: bounded by the spellings.
        for spelling in spellings {
            guard let version = spelling.version, let revision = spelling.revision else { continue }
            guard let expected = releasedRevisions[version] else {
                problems.append("""
                    \(spelling.site) resolves proximitykit \(version), which `releasedRevisions` does not hold: \
                    a re-pin adds its tag's row, `git rev-parse \(version)^{commit}`, in the same commit
                    """)
                continue
            }
            if revision != expected {
                problems.append("""
                    \(spelling.site) resolves proximitykit \(version) to \(revision), not the tag's commit \
                    \(expected): the tag moved, the version is mistyped, or the file was edited by hand
                    """)
            }
        }
        return problems
    }

    /// The version a manifest's one `.package(url: "<url>", exact: "<version>")` line names: nil when no
    /// code line names `url`, or more than one does, or its line pins anything but `exact:` (a range
    /// resolves whatever tag is newest inside it). A comment line is not code, and another URL that
    /// starts with `url` is not `url`.
    static func manifestExactVersion(_ manifest: String, url: String) -> String? {
        let lines = manifest.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains(".package(url: \"\(url)\"")
        }
        guard lines.count == 1, let line = lines.first else { return nil }
        return quotedValue(after: "exact: ", in: line)
    }

    /// The non-empty text between the `"` that follows `key` on `line` and the next `"`, or nil.
    private static func quotedValue(after key: String, in line: String) -> String? {
        guard let start = line.range(of: key + "\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// The version an Xcode project's one remote package reference to `url` pins with
    /// `kind = exactVersion;`: nil when no reference names `url`, or more than one does, or its
    /// requirement is any other kind. The requirement is read from the reference's own lines, after its
    /// `repositoryURL` and up to the first `};`, which closes the requirement.
    static func projectExactVersion(_ project: String, url: String) -> String? {
        let lines = project.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "repositoryURL = \"\(url)\";" }
        guard starts.count == 1, let start = starts.first else { return nil }
        var fields: [String: String] = [:]
        var closed = false
        // R2: bounded by the six lines a requirement spans at most.
        for line in lines.dropFirst(start + 1).prefix(6) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "};" {
                closed = true
                break
            }
            let parts = text.components(separatedBy: " = ")
            guard parts.count == 2, parts[1].hasSuffix(";") else { continue }
            fields[parts[0]] = String(parts[1].dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard closed, fields["kind"] == "exactVersion", let version = fields["version"], !version.isEmpty else { return nil }
        return version
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

    /// The checked-in suite inventory. It sits outside the test target's folder: `Tests/FernletTests`
    /// is a synchronized folder group that would bundle it.
    static let inventoryPath = "Tests/suite-inventory.tsv"

    /// The inventory's header, its first line that is not a `#` comment.
    static let inventoryHeader = "suite\tfile\tlines"

    /// One inventory row: a suite, the file declaring it and the lines that run it.
    struct InventoryRow: Equatable {
        /// The suite's type name, as a selector names it.
        let suite: String
        /// The repo-relative file whose column-0 line declares the suite, under ``testRoot``.
        let file: String
        /// The workflow labels whose selectors name the suite, sorted ascending; empty for `-`.
        let lines: [String]
    }

    /// The MEASURED row count (rule I2). MEASURED at ProximityKit plan step A0.8.0 (2026-10-10): the 642
    /// suites of a full run of FernletTests at `ba1675f0` (7034 tests, on an iPhone 17 simulator, iOS
    /// 26.5). From A0.8.2 to A1.1.17 suites moved into ProximityKit's package test target and FernletTests
    /// held 628 rows beside the package's 25. MEASURED at A1.3 (2026-10-15): the package's rows left with
    /// its tests, which its repository holds and counts in its own inventory, and FernletTests 628 → 629
    /// for its copy of `FakePeerTransportTests`, the check of the fake fabric Fernlet's acceptance
    /// batteries build on; and 629 → 628 in the same step for `MeshRoutedCustodyHandoffWallTests`, every
    /// cell of which read ProximityKit's sources (the package holds the suite). A suite deleted with its
    /// row lowers it with the retirement argued, the ``measuredSuiteNameCounts`` rule; a new row raises it
    /// in the same commit. 628 → 630 on 2026-10-15 (App Review guideline 1.2) for the two suites that
    /// joined `mesh-features`, `SessionMessageFilterTests` and `SessionContentReportTests`.
    /// LOWERED, deliberately, 630 → 607 at the re-pin to ProximityKit 0.1.1 (2026-10-17): the 23
    /// pure-logic suites on no line whose copies ProximityKit's package tests hold at that tag, under the
    /// same names and with the same cells (161 tests; owner default 6 of the ProximityKit remainder
    /// proposal), left FernletTests with their rows, and its CI runs them. The other 16 copied suites
    /// stay: the 11 `mesh-batteries` gates, the four store suites and `IdentityServiceTests`.
    /// 607 → 608 on 2026-10-17 for `IntimacyHealthWriteTests` (on no line), the anomaly re-triage's fix
    /// that tells a failed Apple Health sample from a failed link mark after an intimacy save.
    static let measuredInventoryRows = 608

    /// Reads the inventory's text into its rows and its format problems by line (rule I1): `#` lines
    /// are comments; the first other line is exactly ``inventoryHeader``; every data line has three
    /// tab-separated fields; `suite` is an identifier; `file` starts with ``testRoot`` and `/` and ends
    /// `.swift`; `lines` is `-` or labels sorted ascending, unique and non-empty; rows run strictly
    /// ascending by suite; a suite is on one row only. A line with a field problem is reported and left
    /// out of `rows`.
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
            if let previous = rows.last, previous.suite >= row.suite {
                problems.append("line \(offset + 1): `\(row.suite)` does not sort after `\(previous.suite)` — rows sort by suite")
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
        guard fields.count == 3 else { return (nil, "\(fields.count) tab-separated fields, not 3") }
        let (suite, file, lines) = (fields[0], fields[1], fields[2])
        guard isIdentifier(suite) else { return (nil, "`\(suite)` is not a suite name") }
        guard file.hasPrefix(testRoot + "/"), file.hasSuffix(".swift") else {
            return (nil, "`\(file)` is not a Swift file under \(testRoot)")
        }
        let labels = lines == "-" ? [] : lines.components(separatedBy: ",")
        guard lines == "-" || (labels.allSatisfy { !$0.isEmpty } && labels == Array(Set(labels)).sorted()) else {
            return (nil, "lines `\(lines)` are neither `-` nor labels sorted ascending, unique and non-empty")
        }
        return (InventoryRow(suite: suite, file: file, lines: labels), nil)
    }

    /// The suite inventory is the tree: every suite FernletTests held at plan step A0.8.0, and every
    /// suite a line has named since, is a row naming its file and the lines that run it, declared
    /// exactly there, and every selector is a row. It is count conservation's static half: a change
    /// that loses, doubles or mis-lines a suite is red here before any simulator runs. (Rules I3, I5
    /// and I7 to I10 held ProximityKit's package test target and its rows, and left with them at plan
    /// step A1.3.)
    @Test func theSuiteInventoryIsTheTree() throws {
        let read = Self.inventory(in: try RepoRoot.source(Self.inventoryPath))
        #expect(read.problems.isEmpty, """
            I1: \(Self.inventoryPath) is malformed:
            \(read.problems.joined(separator: "\n"))
            """)
        #expect(read.rows.count == Self.measuredInventoryRows, """
            I2: \(Self.inventoryPath) holds \(read.rows.count) rows; \(Self.measuredInventoryRows) were \
            measured. A row deleted is a suite leaving CI's sight; `measuredInventoryRows` changes in the \
            same commit as a row, argued and measured.
            """)
        let declared = try Self.declarations()
        let steps = Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath))
        let rules: [(rule: String, problems: [String])] = [
            ("I4, each suite's home", Self.inventoryHomeProblems(read.rows, declared: declared)),
            ("I6, each suite's lines", Self.inventoryLineProblems(read.rows, steps: steps))
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

    /// I4: each row's suite is declared at column 0 in exactly its file under ``testRoot``.
    private static func inventoryHomeProblems(_ rows: [InventoryRow], declared: [String: [String]]) -> [String] {
        var problems: [String] = []
        // R2: bounded by the row count.
        for row in rows {
            let files = declared[row.suite] ?? []
            if files.isEmpty {
                problems.append("I4: `\(row.suite)` is declared in no file of \(testRoot); its row says \(row.file)")
            } else if files != [row.file] {
                problems.append("I4: `\(row.suite)` is declared in \(files.joined(separator: ", ")), not exactly in its row's \(row.file)")
            }
        }
        return problems
    }

    /// I6: every selector on every line is a row, and every row's `lines` is exactly the sorted labels
    /// whose selectors name its suite. The one check that sees a same-count swap: a suite taken off a
    /// line and another put on keeps every name count, every `wallLines` pin and the floor.
    private static func inventoryLineProblems(_ rows: [InventoryRow], steps: [GatedStep]) -> [String] {
        let rowSuites = Set(rows.map(\.suite))
        var labels: [String: Set<String>] = [:]
        var problems: [String] = []
        // R2: bounded by the step count × the selector count.
        for step in steps {
            for token in step.selectors {
                guard let suite = selector(token), rowSuites.contains(suite) else {
                    problems.append("I6: `\(step.label): \(token)` is no row of \(inventoryPath)")
                    continue
                }
                labels[suite, default: []].insert(step.label)
            }
        }
        // R2: bounded by the row count.
        for row in rows {
            let named = (labels[row.suite] ?? []).sorted()
            guard row.lines != named else { continue }
            let listed = row.lines.isEmpty ? "-" : row.lines.joined(separator: ",")
            let actual = named.isEmpty ? "no line" : named.joined(separator: ",")
            problems.append("I6: `\(row.suite)`'s row lists \(listed); the workflow names it on \(actual)")
        }
        return problems
    }

    /// The parser reads the workflow's real shape: a continuation-joined invocation with a label, a
    /// floor and several selectors, a qualified token among them, read whole, and ignores everything
    /// else; and the selector, declaration, inventory and resolution readers each read their fixtures
    /// (ProximityKit plan step A0.8.0), as do the pin-spelling readers and the pin-agreement check (the
    /// re-pin to 0.1.1).
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
        #expect(steps.last.map { $0.suites.compactMap(Self.selector) } == ["CryptographicPurposeBoundaryTests"],
                "a qualified token is kept whole on its step and read as no selector")
        #expect(Self.isMeshBattery("MeshP5HonestyAcceptanceTests"))
        #expect(Self.isMeshBattery("MeshP12FooAcceptanceTests"))
        #expect(!Self.isMeshBattery("MeshPhotoAcceptanceTests"))
        #expect(!Self.isMeshBattery("MeshP5AcceptanceFailure"))
        Self.expectDeclarationReaderFixtured()
        Self.expectSelectorReaderFixtured()
        Self.expectInventoryReaderFixtured()
        Self.expectResolutionReaderFixtured()
        Self.expectPinSpellingReadersFixtured()
        Self.expectPinAgreementFixtured()
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
    /// read past, and a nested, commented or file-scoped type not a selector.
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
        #expect(topLevelTypeName("extension FakePeerTransport: Sendable {") == nil, "an extension declares no type")
    }

    /// The selector reader: a bare name is a FernletTests suite, read as itself, and every other shape
    /// is refused, the retired `ProximityKitTests/<Suite>` among them.
    private static func expectSelectorReaderFixtured() {
        #expect(selector("S3BoundaryTests") == "S3BoundaryTests")
        // R2: bounded by the fixed list.
        for refused in ["FernletTests/X", "ProximityKitTests/X", "Other/X", "A/B/C", "ProximityKitTests/", "", "A-B", "CaféTests"] {
            #expect(selector(refused) == nil, "`\(refused)` is not a selector")
        }
    }

    /// The inventory reader: comments skipped, the header read, a row kept, and a two-field row and a
    /// row whose file lies outside ``testRoot`` each reported and left out.
    private static func expectInventoryReaderFixtured() {
        let text = [
            "# a comment",
            inventoryHeader,
            "S3BoundaryTests\tTests/FernletTests/S3BoundaryTests.swift\ts3-grep",
            "ShortRow\tTests/FernletTests/ShortRow.swift",
            "ElsewhereTests\tFernletKit/Tests/ProximityKitTests/ElsewhereTests.swift\t-",
            ""
        ].joined(separator: "\n")
        let read = inventory(in: text)
        #expect(read.rows == [
            InventoryRow(suite: "S3BoundaryTests", file: "Tests/FernletTests/S3BoundaryTests.swift", lines: ["s3-grep"])
        ])
        #expect(read.problems.count == 2, "the two-field row and the row outside Tests/FernletTests are the problems: \(read.problems)")
    }

    /// The resolution pin's readers, both ways: a file's pins are read by identity, a released pin as
    /// its triple beside a branch-pinned reference, which reads with an empty version; a file that is
    /// not JSON, one that pins an identity twice and one whose `cryptoswift` pin has no version are each
    /// a named problem; two files that pin alike pass, while an identity of ``sharedPinIdentities`` one
    /// lacks, a pin outside them one holds (since A1.3's review fixes; until then it passed) and a pin
    /// they hold to different revisions are each named; and a shell script's comment
    /// lines, indented or not, are not its code.
    private static func expectResolutionReaderFixtured() {
        let pin = #"{"identity":"cryptoswift","location":"L","state":{"revision":"R","version":"1.10.0"}}"#
        let branch = #"{"identity":"other","location":"P","state":{"branch":"main","revision":"B"}}"#
        let read = pins(inResolved: Data(#"{"pins":[\#(pin),\#(branch)],"version":3}"#.utf8), path: "a")
        #expect(read.pins == ["cryptoswift": ["L", "R", "1.10.0"], "other": ["P", "B", ""]] && read.problems.isEmpty,
                "the resolved-file reader read \(read)")
        let refused = [
            Data("not json".utf8),
            Data(#"{"pins":[\#(pin),\#(pin)]}"#.utf8),
            Data(#"{"pins":[{"identity":"cryptoswift","location":"L","state":{"branch":"main","revision":"R"}}]}"#.utf8)
        ]
        // R2: bounded by the fixed list.
        for data in refused {
            #expect(!pins(inResolved: data, path: "b").problems.isEmpty, "a resolved file the pin cannot read was read")
        }
        let shared = ["cryptoswift": ["L", "R", "1.10.0"], "proximitykit": ["K", "T", "0.1.0"]]
        #expect(sharedPinProblems(shared, shared).isEmpty, "two files that pin alike were refused")
        let extra = sharedPinProblems(shared, shared.merging(["extra": ["E", "X", ""]]) { first, _ in first })
        #expect(extra.contains { $0.contains("`extra` is pinned outside") }, "a pin outside the allowed set was not named: \(extra)")
        let lacking = sharedPinProblems(shared, shared.filter { $0.key != "proximitykit" })
        #expect(lacking.contains { $0.contains("`proximitykit` is not pinned in both") }, "a missing shared pin was not named: \(lacking)")
        let moved = sharedPinProblems(shared, shared.merging(["proximitykit": ["K", "U", "0.1.0"]]) { _, second in second })
        #expect(moved.contains { $0.contains("`proximitykit` is pinned to") }, "two revisions of one pin were not named: \(moved)")
        #expect(shellCode("# a comment\nARGS=(-workspace X)\n    # indented -project\necho done") == "ARGS=(-workspace X)\necho done")
    }

    /// The pin's two manifest readers, both ways: the manifest's one code line naming the URL is read
    /// for its `exact:` version past a commented-out line, another package and a longer URL; a range, no
    /// line and two lines each read as nil. The project's one reference is read for its `exactVersion`
    /// past another reference's range; a range, no reference and two references each read as nil.
    private static func expectPinSpellingReadersFixtured() {
        let url = proximityKitURL
        let cryptoSwift = #"    .package(url: "https://github.com/krzyzanowskim/CryptoSwift", .upToNextMinor(from: "1.10.0")),"#
        let exact = #"    .package(url: "\#(url)", exact: "0.1.1"),"#
        let manifest = [#"    // .package(url: "\#(url)", exact: "9.9.9"),"#, cryptoSwift,
                        #"    .package(url: "\#(url)-fork", exact: "8.8.8"),"#, exact].joined(separator: "\n")
        #expect(manifestExactVersion(manifest, url: url) == "0.1.1", "the manifest's exact pin was not read")
        let refusedManifests = [
            #"    .package(url: "\#(url)", from: "0.1.1"),"#,
            #"    .package(url: "\#(url)", .upToNextMinor(from: "0.1.1")),"#,
            cryptoSwift,
            [exact, exact].joined(separator: "\n")
        ]
        // R2: bounded by the fixed list.
        for refused in refusedManifests {
            #expect(manifestExactVersion(refused, url: url) == nil, "`\(refused)` was read as an exact pin")
        }
        let range = ["\t\t\trepositoryURL = \"https://github.com/krzyzanowskim/CryptoSwift\";", "\t\t\trequirement = {",
                     "\t\t\t\tkind = upToNextMinorVersion;", "\t\t\t\tminimumVersion = 1.10.0;", "\t\t\t};", "\t\t};"]
        let reference = ["\t\t\trepositoryURL = \"\(url)\";", "\t\t\trequirement = {", "\t\t\t\tkind = exactVersion;",
                         "\t\t\t\tversion = 0.1.1;", "\t\t\t};", "\t\t};"]
        #expect(projectExactVersion((range + reference).joined(separator: "\n"), url: url) == "0.1.1",
                "the project's exactVersion reference was not read")
        let ranged = reference.map { $0.replacingOccurrences(of: "kind = exactVersion;", with: "kind = upToNextMinorVersion;") }
        let refusedProjects = [ranged, range, reference + reference]
        // R2: bounded by the fixed list.
        for refused in refusedProjects {
            #expect(projectExactVersion(refused.joined(separator: "\n"), url: url) == nil,
                    "a reference that is not one exact pin was read as one")
        }
    }

    /// The pin's agreement, both ways: four spellings of one tag at its table commit pass; each spelling
    /// moved out of step alone, a resolved revision that is not the tag's, a version the table does not
    /// hold and a spelling with no exact version are each named.
    private static func expectPinAgreementFixtured() {
        let commit = releasedRevisions["0.1.1"] ?? ""
        let sites = ["M", "P", "R1", "R2"]
        func spellings(_ versions: [String?], _ revisions: [String?] = [nil, nil, commit, commit]) -> [PinSpelling] {
            zip(sites, zip(versions, revisions)).map { PinSpelling(site: $0.0, version: $0.1.0, revision: $0.1.1) }
        }
        let agreed: [String?] = ["0.1.1", "0.1.1", "0.1.1", "0.1.1"]
        #expect(pinAgreementProblems(spellings(agreed)).isEmpty, "four spellings of one tag at its commit were refused")
        // R2: bounded by the four sites.
        for index in sites.indices {
            var moved = agreed
            moved[index] = "0.1.0"
            let problems = pinAgreementProblems(spellings(moved))
            #expect(problems.contains { $0.contains("name 2 versions") && $0.contains("\(sites[index]) 0.1.0") },
                    "\(sites[index]) out of step was not named: \(problems)")
        }
        let wrong = pinAgreementProblems(spellings(agreed, [nil, nil, commit, "0000000"]))
        #expect(wrong.count == 1 && wrong.contains { $0.contains("R2 resolves proximitykit 0.1.1 to 0000000") },
                "a revision that is not the tag's commit was not named: \(wrong)")
        let unknown = pinAgreementProblems(spellings(["9.9.9", "9.9.9", "9.9.9", "9.9.9"]))
        #expect(unknown.count == 2 && unknown.allSatisfy { $0.contains("does not hold") },
                "a version the table does not hold was not named for both resolved files: \(unknown)")
        let unpinned = pinAgreementProblems(spellings([nil, "0.1.1", "0.1.1", "0.1.1"]))
        #expect(unpinned.contains { $0.contains("M names no exact version") },
                "a spelling with no exact version was not named: \(unpinned)")
    }
}
