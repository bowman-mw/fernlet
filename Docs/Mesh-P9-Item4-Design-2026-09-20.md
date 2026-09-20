# Mesh P9 item 4 — design note (survey at `ba34491`, written 2026-09-20; the deletion half is BLOCKED on an owner decision)

> Written by the item 4 drafter before any code landed. The `[SPLIT: NOW]` half (the four dead `_fernlet-near` / `_fernlet-recipe` MC Bonjour strings) lands as 9.4-NOW; every `[SPLIT: LATER]` hunk waits for the owner's cutover decision below. The anchored patches this note describes lived in the session scratchpad (`…/scratchpad/items4-7/item4/`, may not survive a reboot); the appendix carries the rule-7 cell verbatim so the LATER half can be rebuilt from this file alone.

# P9 item 4 — Retire MultipeerConnectivity

Surveyed at `ba34491`. Every patch is anchored by surrounding TEXT; re-read each target at HEAD.

## THE LAUNCHER'S ROW IS WRONG ABOUT HEAD — read this first

**(1) The friend mesh still ships on MC.** `MeshTransportFactory.shippingDefault` is `.multipeer`,
`resolvedKind()` compiles the environment read out of Release, and `MeshNetworkManager.init` does
`transport ?? MeshTransportFactory.makeSession(MeshTransportFactory.resolvedKind())`. So
`MeshMultipeerSession()` **is** constructed on every shipping launch. Deleting the file is the
mesh's MC→QUIC **cutover**, not cleanup — and it is what makes `_fernlet-friend._{tcp,udp}`
droppable at all. Nothing in the launcher, plan §17.1 or §26.3 says the default flips; plan §6
finding 8 still reads "QUIC is not the default, and MC still ships", and §15's hardware acceptance
of the QUIC mesh has **never been run**.

**(2) And the flip removes a shipping capability.** The QUIC mesh is members-only by construction.
Three independent witnesses in `MeshNetworkManager.swift`: the Lane C seam's doc —
`MeshChannelIntroductionExchange.receive` "refuses a foreign mesh id and a stranger key — so two
Simulators cannot meet at all unless each already names the other's mesh and holds the other's key"
(which is why the lane seeds `FERNLET_MESH_MATRIX_MEMBERS` and why `startNewMesh(name:)` is
"unreachable from the harness"); the `MeshIntroductionAuthority` doc — with no mesh yet, "**a first
proximity-join meeting, where the two devices have never met**", the roster is empty, every peer
verdicts `.stranger`, "**and the QUIC radio refuses. … one more reason MultipeerConnectivity remains
the default**"; and `mayKeepVerifiedSlot`'s doc — "**MC has no such stage**", i.e. MC's slot
coordinator is the admission stage QUIC lacks for a stranger. **MC is the only radio on which two
phones that have never met can found a mesh.** Stranger admission is plan §8 and is still an open
owner call from P3. Deleting `MeshMultipeerSession.swift` today ships a build where first-meeting
mesh founding is impossible on hardware.

**(3) The coach radio is type-and-string only.** `ProximityCoordinator` is constructed in exactly
three shipping places (mesh, recipe, presence managers), all `.friend`. There is **no live
`MeshMultipeerSession` instantiation for the trainer transport** — the two `_fernlet-coach` strings
are dead today. The default (hold them) is still drafted; the owner decides.

**(4) The permit list is not "the exact inventory".** Its scan roots are
`FernletKit/Sources/ProximityKit` + `App/Fernlet`, so it never saw `Tests/`, where **32 files** name
an MC type or import the framework — six substantially.

## The decision

- **(D-4.1) Hold item 4** until stranger admission exists on QUIC and §15 has dates. **Recommended.**
- **(D-4.2) Split it.** Land the cleanup half now: the four `_fernlet-recipe` / `_fernlet-near`
  plist strings (dead since items 2 and 3 crossed), the matching `Docs/No-Tracking-Wall.md` §4c row,
  and the stale prose. Leave the two Swift files, `_fernlet-friend._{tcp,udp}`, the wipe row and
  `permittedFiles` for a P10 item gated on stranger admission. **Largest safe subset.**
- **(D-4.3) Cut over anyway**, accepting broken first-meeting founding. Not recommended.

Every patch is written for D-4.3 and marked **[SPLIT: NOW]** / **[SPLIT: LATER]**, so D-4.2 is
"apply only the NOW hunks".

Sub-decisions: **D-4.4** the wipe row — pure retire, or keep the leg as a legacy `FileManager` sweep
(recommended; `FernletPeerID.archive` survives on any pre-P9 install and nothing would delete it
after a pure retire, so delete-all would leave behind the device name the row existed to erase).

## Acceptance criterion

`import MultipeerConnectivity` occurs **zero** times under `FernletKit/Sources` and `App/`; no MC
framework identifier (`MCSession`, `MCPeerID`, `MCNearbyServiceAdvertiser`, `MCNearbyServiceBrowser`,
`MCSessionSendDataMode`, `MCSessionState`, `MCError`) occurs in `FernletKit/Sources/ProximityKit` or
`App/Fernlet`; `App/Fernlet/Info.plist` declares none of the six retired types and all three QUIC
ones; `MeshNetworkManager(store:)` builds a `NetworkMeshSession`; tree builds green with
`permittedFiles` empty.

## Files touched

**Deleted (2 shipping, 3 test):** `Transport/MeshMultipeerSession.swift` (624 lines),
`Transport/MCPeerIDStore.swift` (94); `Tests/…/MultipeerPeerTests.swift`,
`Tests/…/PeerIDArchiveWipeTests.swift`, `Tests/…/MeshTransportErrorSurfacingTests.swift` — **but
2 of that last file's 5 cells are not MC's**: the `maxInboundWireBytes` cap pair must be ported to
`NetworkMeshTransportTests` against `NetworkMeshSession` or the cap loses its cell.

**Edited (shipping):** `MeshTransportSelection.swift` (variant A: delete `MeshTransportKind`,
`MeshTransportFactory`, the `MeshMultipeerSession` conformance; keep `MeshTransportSession`,
`MeshPeerChannel`, `DetachedPeerChannel` — this makes the mesh match items 2/3's
`?? NetworkXSession()` shape), `MeshNetworkManager.swift` (the init default, the wipe leg, five doc
comments), plus ~20 files whose MC mentions are **prose only** (the wall matches whole identifiers
and strips string literals, so prose is not a red — it is doc hygiene).

**Edited (tests):** `TransportNeutralityBoundaryTests.swift` (list empties, **suite kept** — an
empty permit list makes both scans assert zero, the strongest this wall has been),
`PeerTransportNeutralityTests.swift` (1 of 3 structs dies), `MeshTransportSelectionTests.swift`
(4 of 12 cells), bare-import sweep in 15 files, 2 real-but-incidental uses
(`NearbyRangingSessionTests` uses `MCPeerID` as an `NSKeyedArchiver` stand-in — swap it).

**Edited (plist/docs):** `Info.plist`, `PrivacyWipeCoverage.md`, `No-Tracking-Wall.md` §4c,
`FileIndex.md`, `ProximityFunctionIndex.md` (**one section is already stale at HEAD** — it lists
`endpointKey(for:)`/`mcPeerID(for:)` under `PeerHandle.swift`; they are `MeshMultipeerSession`'s),
`ProximityKit.md` (5 edits incl. 2 symbol-list bullets — warnings are errors, so an unresolved DocC
link fails the build), the runbook's Lane C preamble, plan §6/§18/§26.3.

**New:** `Tests/FernletTests/MeshP9McRetirementTests.swift`.

## Walls that bite

- **`TransportNeutralityBoundaryTests`** asserts each permitted path **exists** — deletion and
  emptied list are ONE commit (§5(c)). Read `floorFiles` too: if it names either file, those
  entries die in the same commit.
- **Wipe wall, inverted.** `PrivacyWipeCoverageTests` requires the *function*
  `wipeIdentityForDeleteAll` to survive — it does either way; only the archive leg moves.
- **No-tracking.** `permittedLocalLinkFiles` names only the four Network.framework files — **no MC
  entry, nothing to prune there.** Only the `Docs/No-Tracking-Wall.md` §4c row moves.
- **Power of 10.** No new body. But `power-of-10-scan.py`'s **assertion-density floor** moves when
  718 lines of `guard`-bearing shipping code go (item 1 already moved it 0.775 → 0.770 vs 0.68) —
  re-run it, and check `Scripts/power-of-10-allowlist.json` for an entry naming either file.
- **`TestHookBoundaryTests`** per-family floor for `FERNLET_MESH` is **7** against ~18 real lines,
  so deleting `FERNLET_MESH_TRANSPORT` is safe; its `plantedTokenTrips` fixture is a synthetic
  literal and does not depend on the declaration.
- **Localization.** **No string-catalog key dies** — neither deleted file contains
  `String(localized:)`, `LocalizedStringKey`, `LocalizedStringResource` or `NSLocalizedString`.
  Two residuals, both pre-existing: `ConnectionInspectorView` returns a bare `String` naming MC
  (not in the catalog — an existing wall gap, now also factually wrong), and renders a row labelled
  `"MCSession"` backed by `ConnectionSessionLog.transport.mcSessionState` — **rename the label
  only** until it is proven the field is not a persisted token.
- **Memory lifecycle (ML5)** — deletions only, but the new suite's host must not be inline
  (item 3 pass 1's lesson).
- **CI selector wall — verified, and the name matters.** `CIGateSelectorBoundaryTests.isMeshBattery`
  requires `hasPrefix("MeshP")` **and** `hasSuffix("AcceptanceTests")` **and** a digit after
  `MeshP`. `MeshP9McRetirementTests` therefore does **not** match, so it does not auto-trip the
  "every declared battery is named on the mesh step" rule — but it also is not gated. Two options:
  keep this name and name it on the mesh line deliberately (item 6/9's commit), or rename it
  `MeshP9McRetirementAcceptanceTests`, which makes gating **mandatory in this commit** and couples
  item 4 to the workflow edit. **Recommended: keep the name**, gate it in item 9 with the rest of
  the P9 battery. Also confirmed at HEAD: there is **no `MeshP9*AcceptanceTests` anywhere yet**, and
  the two determinism digests live in `MeshP5AcceptanceTests.swift`, not in the selector wall.

## Gate subset (STRUCT names — `@Suite` under-counts)

`TransportNeutralityBoundaryTests`, `PeerHandleIdentityTests`, `FakePeerTransportTests`,
`MeshTransportSelectionTests`, `NetworkMeshTransportTests`, `MeshNetworkManagerTests`,
`MeshDialPolicyTests`, `PresenceOverQUICTests`, `RecipeShareOverQUICTests`,
`PrivacyWipeCoverageTests`, `PersistedSurfaceWipeBoundaryTests`, `DeleteAllDataTests`,
`NoTrackingBoundaryTests`, `TestHookBoundaryTests`, `MemoryLifecycleBoundaryTests`,
`PowerOfTenBoundaryTests`, `LocalizationBoundaryTests`, `CIGateSelectorBoundaryTests`,
`MeshP9McRetirementTests`. **Attribute-less plain structs here** (found by their `@Test`s):
`PeerIDArchiveWipeTests`, `MultipeerPeerTests`, `TestHookBoundaryTests` — the first two are deleted,
so drop them from the run line afterwards.

## Red-once ledger (each independently reddenable — separate needles, separate files)

1. `theAppsMeshManagerBuildsTheQUICRadio` — revert `MeshNetworkManager.init`'s default on a scratch
   copy. 2. `noShippingFileImportsMultipeerConnectivity` — plant the import in
`NetworkMeshSession.swift`. 3. `theAppPlistDeclaresOnlyTheLiveBonjourServiceTypes` — re-add
`_fernlet-friend._tcp`; it asserts the QUIC three are **present** too, so a plist that lost
everything cannot pass. 4. `TransportNeutralityBoundaryTests` — plant `let s: MCSession? = nil` (a
bare `import` only exercises the first scan; the identifier scan strips string literals).
5. The ported cap cells — raise the literal by one byte. 6. (D-4.4 only)
`theLegacyPeerIdentityArchiveIsRemovedByDeleteAll` — point the helper at a path it does not delete.

---

## Appendix A — the rule-7 cell drafted for the LATER half (`MeshP9McRetirementTests.swift`, unbuilt)

```swift
// MeshP9McRetirementTests.swift
// FernletTests
//
// P9 item 4's rule-7 cell: the MultipeerConnectivity retirement as a ZERO-LIST.
//
// `TransportNeutralityBoundaryTests` is the tree-wide grep wall and it keeps its own job — it scans
// ProximityKit + App/Fernlet for the framework's TYPES and now asserts zero. This suite is the
// narrower, independently-reddenable acceptance battery the phase owes: the import count, the plist
// inventory, and the one fact neither of the others can see — which radio the app's own initializer
// builds. Each cell reddens on its own needle, in its own file, so a green here is three
// independent claims rather than one.
//
// Scan roots and the framework name are frozen automation tokens, never display strings.

import Foundation
import Testing
@testable import ProximityKit
@testable import Fernlet

/// Acceptance battery for P9 item 4 — MultipeerConnectivity retired.
///
/// Serialized because `theAppsMeshManagerBuildsTheQUICRadio` constructs a real
/// `MeshNetworkManager` on the main actor; the two scans are pure file reads and would be safe
/// either way.
@Suite(.serialized) @MainActor
struct MeshP9McRetirementTests {

    // MARK: - Inventory

    /// Repo-relative roots the import scan walks. The same two the transport-neutrality wall uses,
    /// restated here so this suite reddens even if that one is edited.
    private static let scanRoots = [
        "FernletKit/Sources",
        "App"
    ]

    /// The MC Bonjour service types that leave the app's plist with the framework.
    ///
    /// The `_fernlet-coach` pair is deliberately **absent**: plan §18 decision 4 holds those two
    /// strings for the Coach app's own decision, and a cell that demanded their removal would be
    /// asserting a product choice nobody has made. If the owner retires the coach radio, add them
    /// here in the same commit that removes them.
    ///
    /// Under decision D-4.2 (the split), narrow this to the four `_fernlet-near` / `_fernlet-recipe`
    /// entries and leave the two `_fernlet-friend` ones out.
    private static let retiredServiceTypes = [
        "_fernlet-friend._tcp",
        "_fernlet-friend._udp",
        "_fernlet-recipe._tcp",
        "_fernlet-recipe._udp",
        "_fernlet-near._tcp",
        "_fernlet-near._udp"
    ]

    /// The QUIC service types that must still be declared. Without this half a plist that lost
    /// every entry would pass the retirement cell — the failure mode that actually ships is a
    /// deleted line, not a surviving one.
    private static let liveServiceTypes = [
        "_fernlet-mesh2._udp",
        "_fernlet-near2._udp",
        "_fernlet-recipe2._udp"
    ]

    // MARK: - Cells

    /// Nothing under the two shipping roots imports the framework.
    ///
    /// Counts rather than reports the first offender: a build that re-adds the import in three
    /// files should say three.
    @Test func noShippingFileImportsMultipeerConnectivity() throws {
        let offenders = try Self.filesImportingMultipeerConnectivity()

        #expect(offenders.isEmpty, """
            \(offenders.count) shipping file(s) still import MultipeerConnectivity: \
            \(offenders.sorted().joined(separator: ", ")).
            P9 item 4 retired the framework. The S3 wall cannot see this — MultipeerConnectivity is \
            an SDK framework, so an added import compiles clean and passes every other test.
            """)
    }

    /// The six retired Bonjour types are gone from the app's plist, and the three QUIC ones remain.
    @Test func theAppPlistDeclaresOnlyTheLiveBonjourServiceTypes() throws {
        let plist = try Self.appInfoPlistSource()

        for retired in Self.retiredServiceTypes {
            #expect(!plist.contains(retired), """
                Info.plist still declares \(retired) — a service type no radio advertises since \
                P9 item 4. A stale declaration is a claim about what this app does on the local \
                network, and the privacy copy is written against the list.
                """)
        }
        for live in Self.liveServiceTypes {
            #expect(plist.contains(live), """
                Info.plist no longer declares \(live) — discovery dies silently on device with no \
                log and no observable state. This is the bug the retirement must not cause.
                """)
        }
    }

    /// The app's own mesh initializer builds the QUIC radio.
    ///
    /// The cell `MeshTransportSelectionTests` used to make in the opposite direction, kept here so
    /// the retirement battery owns the claim that the cutover actually happened rather than
    /// inheriting it from a suite about selection — there is no selection left.
    @Test func theAppsMeshManagerBuildsTheQUICRadio() {
        let manager = MeshNetworkManager(store: MeshP9RetirementHost())

        #expect(manager.transportForTesting as? NetworkMeshSession != nil,
                "the public initializer must build NetworkMeshSession — nothing else ships")
    }

    // MARK: - Scanning

    /// Repo-relative paths of every shipping Swift file that imports the framework.
    ///
    /// Bounded by construction (Power of 10 rule 2): the enumerator walks a finite tree and the
    /// per-file work is one `contains` over its lines.
    private static func filesImportingMultipeerConnectivity() throws -> [String] {
        var offenders: [String] = []
        for root in scanRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil
            ) else {
                Issue.record("scan root did not resolve: \(root) — fix RepoRoot, never the root list")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                guard source.contains("import MultipeerConnectivity") else { continue }
                offenders.append(url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: ""))
            }
        }
        return offenders
    }

    /// The app target's `Info.plist`, read as text so the assertion is about the declared strings
    /// rather than a parsed shape a rewrite could change underneath it.
    private static func appInfoPlistSource() throws -> String {
        let url = RepoRoot.url.appendingPathComponent("App/Fernlet/Info.plist")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// The smallest `ProximityHost` this suite's one manager needs.
///
/// **Do not inline this as an anonymous host.** `MemoryLifecycleBoundaryTests` (ML5) is a tree-wide
/// grep wall that names inline proximity-manager test hosts by file; item 3 pass 1 learned that the
/// hard way — five inline hosts built clean and every cell passed, and only that suite saw them.
/// Run ML5 before believing this file.
private final class MeshP9RetirementHost: ProximityHost {
    // MEASURE: copy the minimal conformance the tree's existing proximity test hosts use —
    // `Tests/FernletTests/Mocks/` has one; do NOT hand-roll a second shape. If the protocol's
    // surface is wide, prefer reusing the existing host type outright and delete this stub.
}
```

## Appendix — `Info.plist` anchored patch (drafted at `ba34491`; re-anchor by text)

# `App/Fernlet/Info.plist`

Drop six MC Bonjour types. Hold the two `_fernlet-coach` (plan §18 decision 4 default). Keep all
three QUIC types.

## SPLIT LINE

`_fernlet-recipe._{tcp,udp}` and `_fernlet-near._{tcp,udp}` are **[SPLIT: NOW]** — items 2 and 3
already moved those radios to `_fernlet-recipe2._udp` / `_fernlet-near2._udp`, so at HEAD nothing
advertises or browses them. `_fernlet-friend._{tcp,udp}` is **[SPLIT: LATER]**: the friend mesh
still runs on MC in Release (see `DESIGN.md`). Under D-4.2 apply the four-line variant at the bottom
of this file instead of the replacement below.

## `<key>NSBonjourServices</key>` — the service-type array

HEAD (verbatim; tabs, not spaces):

```xml
	<key>NSBonjourServices</key>
	<array>
		<string>_fernlet-coach._tcp</string>
		<string>_fernlet-coach._udp</string>
		<string>_fernlet-friend._tcp</string>
		<string>_fernlet-friend._udp</string>
		<string>_fernlet-recipe._tcp</string>
		<string>_fernlet-recipe._udp</string>
		<string>_fernlet-near._tcp</string>
		<string>_fernlet-near._udp</string>
		<string>_fernlet-mesh2._udp</string>
		<string>_fernlet-near2._udp</string>
		<string>_fernlet-recipe2._udp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
```

Replacement:

```xml
	<key>NSBonjourServices</key>
	<array>
		<string>_fernlet-coach._tcp</string>
		<string>_fernlet-coach._udp</string>
		<string>_fernlet-mesh2._udp</string>
		<string>_fernlet-near2._udp</string>
		<string>_fernlet-recipe2._udp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
```

**If the owner takes the other side of decision 4** (retire the coach radio too), delete the two
`_fernlet-coach` lines as well and, in the same commit, delete
`FernletKit/Sources/ProximityKit/Transport/PeerTransport.swift`'s `MultipeerServiceType` enum,
`FernletKit/Sources/ProximityKit/Trust/CoachSessionTrustPolicy.swift`,
`FernletKit/Sources/ProximityKit/Wire/TrainerPayloads.swift`, the `.trainer` arm of
`ProximityCoordinator.serviceType(for:)`, and `ProximityMode.trainer`'s use as the parked-token
default in `ProximityPersistenceRecords.swift` (**that last one is a persisted `rawValue` decode
default — a frozen token; changing it is a data-compat change, not cleanup. Do not fold it in.**).
That is a bigger commit than item 4 and touches `TrainerAuditLog`, `TrainerExportBuilder` and
`TrainerExportView`. The default holds the strings precisely to avoid it.

## Sibling plists — verified clean

`App/FernletMessagesExtension/Info.plist`, `App/FernletShareExtension/Info.plist` and
`App/FernletWidgets/Info.plist` carry **no** `NSBonjourServices` key at HEAD. Nothing to do; re-grep
before applying in case the lane-harness commit added one.

## D-4.2 variant — the [SPLIT: NOW] half only

Same HEAD anchor as above. Replacement:

```xml
	<key>NSBonjourServices</key>
	<array>
		<string>_fernlet-coach._tcp</string>
		<string>_fernlet-coach._udp</string>
		<string>_fernlet-friend._tcp</string>
		<string>_fernlet-friend._udp</string>
		<string>_fernlet-mesh2._udp</string>
		<string>_fernlet-near2._udp</string>
		<string>_fernlet-recipe2._udp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
```

Four strings dropped, both radios that actually crossed in this phase. The acceptance cell in
`MeshP9McRetirementTests.swift` has a `retiredServiceTypes` constant to match — take its D-4.2
spelling (the four) rather than the six.

## Appendix — `MeshNetworkManager.swift` anchored patch (drafted at `ba34491`; re-anchor by text)

# `FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift`

All **[SPLIT: LATER]** except Edit 6 (prose).

## Edit 1 — the radio default stops naming the factory **[SPLIT: LATER]**

HEAD:

```swift
    ) {
        self.store = store
        self.transport = transport ?? MeshTransportFactory.makeSession(MeshTransportFactory.resolvedKind())
        let id = identity ?? IdentityService()
```

Replacement:

```swift
    ) {
        self.store = store
        self.transport = transport ?? NetworkMeshSession()
        let id = identity ?? IdentityService()
```

This line is the cutover. Nothing else in the file selects a radio.

## Edit 2 — the `transport` property doc **[SPLIT: LATER]**

HEAD:

```swift
    /// The shared radio, held through ``MeshTransportSession`` so this manager never names one.
    /// `MeshTransportFactory` picks it: MultipeerConnectivity on every shipping path, the QUIC
    /// conformer only from an internal injection or the DEBUG-only launch variable.
    @ObservationIgnored private let transport: any MeshTransportSession
```

Replacement:

```swift
    /// The shared radio, held through ``MeshTransportSession`` so this manager never names one in
    /// its body. `NetworkMeshSession` is the only conformer a shipping build constructs (P9 item 4
    /// retired the MultipeerConnectivity one); a test injects its own.
    @ObservationIgnored private let transport: any MeshTransportSession
```

## Edit 3 — the public convenience initializer's doc **[SPLIT: LATER]**

HEAD:

```swift
    /// The app's entry point: a manager over the radio this build selected.
    ///
    /// That is MultipeerConnectivity everywhere it matters — ``MeshTransportFactory/shippingDefault``
    /// is the only answer a Release build can produce. A DEBUG build can be launched onto the QUIC
    /// radio with `FERNLET_MESH_TRANSPORT=quic`; nothing about the choice is stored, so it lasts one
    /// launch and owes no row on the persisted-surface wipe ledger.
    public convenience init(store: any ProximityHost) {
```

Replacement:

```swift
    /// The app's entry point: a manager over this build's one radio.
    ///
    /// That is `NetworkMeshSession` — Network.framework/QUIC on `_fernlet-mesh2._udp` — on every
    /// path since P9 item 4 retired MultipeerConnectivity. There is no selection left to make, so
    /// there is no launch variable and nothing stored: this owes no row on the persisted-surface
    /// wipe ledger, exactly as the removed choice did not.
    public convenience init(store: any ProximityHost) {
```

## Edit 4 — `wipeIdentityForDeleteAll` loses the archive leg **[SPLIT: LATER]**

HEAD:

```swift
    public func wipeIdentityForDeleteAll() throws {
        var archiveError: (any Error)?
        do {
            try FileMCPeerIDStore().clearForDeleteAll()
        } catch {
            archiveError = error
        }
        try identity.wipe()
        photoCacheStore.invalidateEncryptionKeyCache()
        guard let archiveError else { return }
        throw archiveError
    }
```

Replacement (**D-4.3 pure-retire form** — the one the launcher's row asks for):

```swift
    public func wipeIdentityForDeleteAll() throws {
        try identity.wipe()
        photoCacheStore.invalidateEncryptionKeyCache()
    }
```

**Optional hunk — the legacy-sweep form (decision D-4.4, recommended).** `FernletPeerID.archive`
still sits in Application Support on any install that ran a pre-P9 build, and after the pure retire
nothing deletes it: a delete-all would leave behind the device name (in practice the user's own
first name) that the retired row existed to erase. This keeps the leg without keeping the MC type —
it is plain `FileManager` over the literal path the archive always had:

```swift
    public func wipeIdentityForDeleteAll() throws {
        var archiveError: (any Error)?
        do {
            try Self.removeLegacyPeerIdentityArchive()
        } catch {
            archiveError = error
        }
        try identity.wipe()
        photoCacheStore.invalidateEncryptionKeyCache()
        guard let archiveError else { return }
        throw archiveError
    }

    /// Removes the retired MultipeerConnectivity peer-identity archive, if a pre-P9 build left one.
    ///
    /// Nothing writes this file since P9 item 4 retired the framework, but an install that ran an
    /// earlier build still holds it, and it carries the device name — in practice the user's own
    /// first name. A delete-all that left it behind would leave exactly the identifier the wipe
    /// row existed to erase, so the leg outlives the store that wrote it.
    ///
    /// - Throws: the `FileManager` error when a file that exists cannot be removed. A file that
    ///   was never written is not an error.
    private static func removeLegacyPeerIdentityArchive() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let directory = support.first else { return }
        let url = directory.appendingPathComponent("FernletPeerID.archive")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
```

Power of 10: both bodies are well under 60 lines, no `!`, no `try!`, no `try?`, every failure named.
If this hunk is taken, `Docs/PrivacyWipeCoverage.md`'s row is **rewritten, not retired** — see
`docs.patch.md` — and it owes its own cell (`theLegacyPeerIdentityArchiveIsRemovedByDeleteAll`,
red-once by pointing the helper at a path it does not delete).

**Verify before applying either form:** re-read the long doc comment directly above
`wipeIdentityForDeleteAll` (it begins "Delete-all seam (bitchat adoptions Increment 1…") — it
describes the archive leg over ~20 lines, naming `MeshMultipeerSession.localPeerID` and the
ordering rule. It must be rewritten to match whichever form is taken; the pure-retire form loses
the whole "Ordering:" paragraph and the `- Throws:` line's second clause.

## Edit 5 — `mayLinkToDiscoveredPeers` / `mayKeepVerifiedSlot` docs **[SPLIT: LATER]**

These two doc comments are the ones that **name MC as the reason the gates exist** (see `DESIGN.md`).
If the cutover is taken they stop describing the build. HEAD:

```swift
    /// The other half of ``mayLinkToDiscoveredPeers``, and the half that keeps "closed" meaning
    /// what it says. Relaxing the three link gates is safe on the QUIC radio because its signed
    /// channel introduction is members-only *before any app frame*; **MC has no such stage** — it
    /// is the shipping default (`MeshTransportFactory.shippingDefault`), its invitation carries no
    /// identity, and the identity introduction one layer up is gated on revoked/blocked keys, not
    /// on the roster. Without this check a stranger seated on a closed mesh would be sent this
```

**Do not paper over this.** The correct replacement depends on the owner's answer to stranger
admission: the check may now be redundant (one radio, members-only before any app frame) or may
still be the only thing standing. Draft it as a question for the applier, not a rewrite:

```swift
    /// The other half of ``mayLinkToDiscoveredPeers``, and the half that keeps "closed" meaning
    /// what it says. With MultipeerConnectivity retired (P9 item 4) the one radio's signed channel
    /// introduction is members-only *before any app frame*, so this check is now belt to that
    /// braces rather than the only stage — it is kept because `setSessionOpen(false)`'s eviction of
    /// uncommitted slots must not be undone by the next discovery, which is a session-state
    /// property and not a transport one. Without it a stranger seated on a closed mesh would be
```

…and keep the rest of the paragraph verbatim. Same treatment for the `mayLinkToDiscoveredPeers`
doc's "MC's slot coordinator refuses at its identity introduction" clause.

## Edit 6 — `MeshIntroductionAuthority`'s scope paragraph **[SPLIT: LATER — and it is the blocker]**

HEAD:

```swift
/// **Scope, stated plainly.** A roster-authenticated transport can only ever admit a member. With no
/// mesh yet — a first proximity-join meeting, where the two devices have never met — the roster is
/// empty, every peer verdicts ``MeshRosterVerdict/stranger``, and the QUIC radio refuses. That is the
/// fail-closed posture plan §7.2 asks for and one more reason MultipeerConnectivity remains the
/// default: admission of a stranger is a membership question (plan §8), not a transport one, and the
/// item that migrates the app's flows is where it gets answered.
```

There is no honest replacement for this paragraph under D-4.3. The sentence is **true at HEAD and
still true after the deletion** — only the "remains the default" clause becomes false, and what
replaces it is "and nothing answers it". Draft:

```swift
/// **Scope, stated plainly.** A roster-authenticated transport can only ever admit a member. With no
/// mesh yet — a first proximity-join meeting, where the two devices have never met — the roster is
/// empty, every peer verdicts ``MeshRosterVerdict/stranger``, and this radio refuses. That is the
/// fail-closed posture plan §7.2 asks for. It is also, since P9 item 4 retired the
/// MultipeerConnectivity radio, the WHOLE answer: admission of a stranger is a membership question
/// (plan §8) and **plan §8 has not landed**, so a first meeting between two devices that have never
/// met cannot found a mesh on this build. Nothing here can fix that — it is the join flow's.
```

**If the applier is writing that sentence, D-4.3 is the wrong decision.** Take D-4.1 or D-4.2.

## Edit 7 — prose-only MC mentions **[SPLIT: NOW]**

Re-tense, no behaviour: the doc at `13222`-ish naming `MeshMultipeerSession.localPeerID` (dies with
Edit 4), `ProximityCoordinator.swift`'s `maxInboundWireBytes` sentence, `MeshSessionTypes.swift:52`,
`PeerHandle.swift:10`, `MeshTransferStreamTable.swift:62`, `MeshHeartbeatSchedule.swift:64`,
`NetworkMeshSession.swift:203`/`:253`/`:282`/`:300`/`:475`/`:536`/`:551`,
`NetworkPresenceSession.swift:84`/`:98`/`:120`, `PresenceAdvertisement.swift:27`/`:130`,
`RecipeShareAdvertisement.swift:104`, `RecipeShareTransfer.swift:18`/`:147`/`:346`,
`ProximityRecipeShareManager.swift:493`/`:857`, `PresenceManager.swift:240`,
`ConnectionSessionLog.swift:193`, `ProximityCoordinatorEnums.swift:11`,
`NotificationService.swift:110`, `ConnectionInspectorView.swift:54`, `ConnectView.swift:587`.
Re-grep each — line numbers are from `ba34491`. The rule: present tense ("MultipeerConnectivity
does not expose RSSI") → past ("the retired MultipeerConnectivity radio did not"). **Watch
`ConnectionInspectorView.swift:139`**: that one is a user-facing `String` returned from a view and
so is a **localization** question, not prose — see `docs.patch.md`'s last section.

## Appendix — `MeshTransportSelection.swift` anchored patch (drafted at `ba34491`; re-anchor by text)

# `FernletKit/Sources/ProximityKit/Transport/MeshTransportSelection.swift`

**Variant A (recommended).** Delete `MeshTransportKind` + `MeshTransportFactory` +
`extension MeshMultipeerSession: MeshTransportSession`. `MeshPeerChannel`, `DetachedPeerChannel`
and `MeshTransportSession` stay. This is the file where item 4 stops being a deletion and becomes
the mesh's MC→QUIC cutover — see `DESIGN.md`'s first section and decision **D-4.1**.

## Edit 1 — `MeshPeerChannel`'s doc and the `PeerChannelTransport` conformance

HEAD:

```swift
/// A ``PeerTransport`` that also knows which peer it carries and can be told to publish
/// `.connected` / `.disconnected`. `PeerChannelTransport` (MultipeerConnectivity) and
/// `NetworkPeerChannel` (QUIC) already had exactly this shape; the protocol only names it, so
/// `MeshNetworkManager` can hold a slot's channel without knowing which radio minted it.
```

Replacement:

```swift
/// A ``PeerTransport`` that also knows which peer it carries and can be told to publish
/// `.connected` / `.disconnected`. The protocol outlived the two-radio period it was introduced
/// for (P2): it named the shape `PeerChannelTransport` (MultipeerConnectivity, retired in P9
/// item 4) and `NetworkPeerChannel` (QUIC) shared, so `MeshNetworkManager` could hold a slot's
/// channel without knowing which radio minted it. It still earns its place — `DetachedPeerChannel`
/// is the second conformer, and the manager's test seams are built on it.
```

HEAD:

```swift
extension PeerChannelTransport: MeshPeerChannel {}

extension NetworkPeerChannel: MeshPeerChannel {}
```

Replacement:

```swift
extension NetworkPeerChannel: MeshPeerChannel {}
```

## Edit 2 — `DetachedPeerChannel`'s doc loses its MC sentence

HEAD:

```swift
/// The manager's `internal` test seams (`addSlotForTesting`, `makeRetainedSlotCoordinatorForTesting`)
/// need a slot channel, and a unit test has no live radio to put behind one. They used to build a
/// `PeerChannelTransport` over the manager's never-started `MeshMultipeerSession`, whose `send`
/// throws ``PeerTransportError/unexpectedState`` for want of an MCSession — this is that same
/// behaviour, said out loud, and it costs the manager one fewer reason to name a specific radio.
```

Replacement:

```swift
/// The manager's `internal` test seams (`addSlotForTesting`, `makeRetainedSlotCoordinatorForTesting`)
/// need a slot channel, and a unit test has no live radio to put behind one. Before P1 they built a
/// channel over a never-started radio, whose `send` threw ``PeerTransportError/unexpectedState``
/// for want of a live session — this is that same behaviour, said out loud, and it costs the
/// manager one fewer reason to name a specific radio.
```

## Edit 3 — `extension MeshMultipeerSession: MeshTransportSession` DELETED whole

HEAD (delete from `// MARK: - Conformances`'s first extension through its closing brace, leaving
the `NetworkMeshSession` extension untouched):

```swift
// MARK: - Conformances

extension MeshMultipeerSession: MeshTransportSession {

    func wire(_ handlers: MeshTransportHandlers) {
```

… through …

```swift
    func startRadios(discoveryInfo: [String: String]) {
        start(serviceType: MeshMultipeerSession.friendServiceType, discoveryInfo: discoveryInfo)
    }
}

extension NetworkMeshSession: MeshTransportSession {
```

Replacement:

```swift
// MARK: - Conformances

extension NetworkMeshSession: MeshTransportSession {
```

**Also inside the surviving `NetworkMeshSession` extension**, three comments reference the MC radio
by behaviour and must be re-tensed. HEAD:

```swift
    /// A failed listener is reported through the owner's transport-error hook rather than thrown:
    /// the owner's start path is the same on both radios, and the MC one cannot throw. The symptom
    /// a user sees — the discovery-failure banner — is identical either way.
```

Replacement:

```swift
    /// A failed listener is reported through the owner's transport-error hook rather than thrown:
    /// that was the shape the retired MultipeerConnectivity radio forced (it could not throw), and
    /// it is kept because the symptom a user sees — the discovery-failure banner — is the owner's
    /// to render either way.
```

HEAD (inside `startRadios`'s `guard !isRunning` arm):

```swift
        // A radio that is already running is, on this path, a PAUSED one: `start(discoveryInfo:)`
        // guards `!isRunning`, so without this arm the hold's inverse would be a silent no-op and
        // this radio would stay dark for the rest of the session. The MC radio self-heals inside
        // its own `start(serviceType:discoveryInfo:)`, which clears the pause and recreates both.
```

Replacement:

```swift
        // A radio that is already running is, on this path, a PAUSED one: `start(discoveryInfo:)`
        // guards `!isRunning`, so without this arm the hold's inverse would be a silent no-op and
        // this radio would stay dark for the rest of the session. (The retired MC radio self-healed
        // inside its own start; this one needs the arm said out loud.)
```

Also re-tense the `invite(_:)` doc's `/// "Invite" is the MC word for it` — keep the sentence, add
"was".

## Edit 4 — `MeshTransportKind` and `MeshTransportFactory` DELETED whole

Delete from `// MARK: - MeshTransportKind` to the end of the file. HEAD's first and last three
lines of that region:

```swift
// MARK: - MeshTransportKind

/// Which radio the friend mesh runs on.
```

```swift
        case .multipeer: return MeshMultipeerSession()
        case .quic:      return NetworkMeshSession()
        }
    }
}
```

Replacement: nothing (the file ends after the `NetworkMeshSession` extension).

**Variant B**, if the owner wants the seam kept: leave `MeshTransportKind` with only `case quic`,
`shippingDefault { .quic }`, `resolvedKind` collapsing to `shippingDefault`, `makeSession` with one
arm, and delete `quicSelectionEnvironmentKey`. This keeps `MeshTransportSelectionTests`'
`everyTransportKindBuildsItsOwnRadio` alive over one case. It is strictly more code for no
behaviour; variant A is drafted as the default.

## Edit 5 — the file's header doc

HEAD:

```swift
/// `.connected` / `.disconnected`. `PeerChannelTransport` (MultipeerConnectivity) and
```

(already covered by Edit 1 — listed here only so the applier does not double-apply.)

## Consequence for `MeshNetworkManager.swift`

See `MeshNetworkManager.swift.patch.md` Edit 1: the `init` default must stop naming the factory.
Applying this file without that one does not compile — same commit, both.

## Appendix — `TransportNeutralityBoundaryTests.swift` anchored patch (drafted at `ba34491`; re-anchor by text)

# `Tests/FernletTests/TransportNeutralityBoundaryTests.swift`

**[SPLIT: LATER]** — this file moves only when the two shipping files are deleted. §5(c) is the
whole point: `everyFloorFileIsStillCovered` asserts each permitted path **exists**, so the deletion
and the emptied list are one commit or the tree is red.

**Keep the suite.** With `permittedFiles == []` both scans still walk
`FernletKit/Sources/ProximityKit` and `App/Fernlet` and now assert **zero** — which is a stronger
wall than it has ever been, not a weaker one. Say that in the doc so a future reader does not prune
an "empty" wall.

## Edit 1 — the permit list empties, and its doc says why it is empty

HEAD:

```swift
    /// The two files allowed to name MultipeerConnectivity types, by repo-relative path.
    ///
    /// `MeshMultipeerSession.swift` owns the framework: the MCSession, the delegates, the one
    /// `MCSessionSendDataMode` mapping, and the private `MCPeerID ↔ PeerEndpointKey` map.
    /// `MCPeerIDStore.swift` persists the MC peer identity itself and is named in the privacy-wipe
    /// ledger, so it retires with MC in P9 rather than being neutralized now.
    private static let permittedFiles = [
        "FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift",
        "FernletKit/Sources/ProximityKit/Transport/MCPeerIDStore.swift"
    ]
```

Replacement:

```swift
    /// The files allowed to name MultipeerConnectivity types, by repo-relative path. **Empty, and
    /// that is the point.**
    ///
    /// P1 narrowed the framework to two files so P9 could delete them; P9 item 4 did. An empty
    /// permit list does not switch this wall off — both scans below still walk every Swift file
    /// under ``scanRoots`` and now assert **zero** occurrences instead of two exceptions, which is
    /// the strongest this wall has ever been. Do not prune the suite for looking vacuous: it is the
    /// only thing standing between the tree and a re-added `import MultipeerConnectivity`, which
    /// would compile clean (the framework is an SDK one, so the S3 wall cannot see it) and pass
    /// every other test.
    ///
    /// Re-adding an entry here is a phase decision, not a fix for a red.
    private static let permittedFiles: [String] = []
```

## Edit 2 — the file header's premise

HEAD:

```swift
/// Grep-wall for P1's whole point: **MultipeerConnectivity stops at two files.**
```

Replacement:

```swift
/// Grep-wall for what P1 set up and P9 item 4 finished: **MultipeerConnectivity is gone.**
```

Re-read lines 5–16 at HEAD and re-tense the rest of that header paragraph in the same edit — it
explains that adding `import MultipeerConnectivity` to a manager compiles clean and passes every
existing test, which is **still true** and is the reason the suite survives its own success. Keep
that sentence; change only "stops at two files" / "tried to delete MultipeerConnectivity and found
it load-bearing somewhere nobody expected".

## Edit 3 — the whole-identifier matcher's doc loses its examples

HEAD:

```swift
    /// Framework type prefixes. Deliberately matched as whole identifiers so `MCPeerIDStoring`,
    /// `FileMCPeerIDStore` and `MeshMultipeerSession` — Fernlet's own names — do not trip the scan.
    private static let frameworkSymbols = [
```

Replacement:

```swift
    /// Framework type prefixes, matched as whole identifiers.
    ///
    /// The whole-identifier rule outlived the names it was written for (`MCPeerIDStoring`,
    /// `FileMCPeerIDStore`, `MeshMultipeerSession` — all deleted in P9 item 4). It stays because
    /// the rule is the correct one: a future `MCSessionFoo` of Fernlet's own would otherwise be
    /// reported under `MCSession`, and `MCSessionSendDataMode` must be reported once, under its own
    /// entry. ``containsIdentifier(_:in:)`` is where it lives; its own cells pin both edges.
    private static let frameworkSymbols = [
```

Leave `frameworkSymbols`' contents alone — the list is what makes the zero assertion mean something.

## Edit 4 — `everyFloorFileIsStillCovered`'s permitted-file loop

HEAD:

```swift
        for path in Self.permittedFiles {
            #expect(
                FileManager.default.fileExists(atPath: RepoRoot.url.appendingPathComponent(path).path),
                "permitted file no longer exists — prune the entry or the wall is scanning nothing: \(path)"
            )
        }
```

**Do not delete this loop.** Over an empty list it is a no-op that costs nothing and is the exact
guard that catches a future re-added-then-deleted permit. Leave it verbatim.

## Edit 5 — check `floorFiles` before applying

`floorFiles` is a separate hard list ("these files were neutralized in P1 and must stay scanned").
Re-read it at HEAD: if it names `MeshMultipeerSession.swift` or `MCPeerIDStore.swift`, those entries
die in this commit too, and `everyFloorFileIsStillCovered`'s first loop reddens if they do not.
At `ba34491` the list was not fully read — **the applier must read it.**

## Red-once

Redden Edit 1 by planting `import MultipeerConnectivity` at the top of
`FernletKit/Sources/ProximityKit/Transport/NetworkMeshSession.swift`, running
`TransportNeutralityBoundaryTests`, and reverting. Both scans (`import` and framework-identifier)
should fire; if only one does, the second scan's literal-stripper is eating the plant — plant a
`let s: MCSession? = nil` instead to exercise the identifier scan on its own.

## Appendix — `docs` anchored patch (drafted at `ba34491`; re-anchor by text)

# Doc rows — same commit as the deletion

## 1. `Docs/PrivacyWipeCoverage.md` — the row retires **[SPLIT: LATER]**

HEAD (one table row, line ~191):

```markdown
| **MC peer-identity archive** — the device name (in practice the user's own first name) plus the stable `MCPeerID` the mesh and recipe-share radios advertise | `Application Support/FernletPeerID.archive` | `wipeIdentityForDeleteAll` (mesh leg, via `FileMCPeerIDStore.clearForDeleteAll()`; the next radio start mints a fresh peer id, and a refusing file system now throws instead of leaving the identifier behind) |
```

**Pure-retire form (D-4.3):** delete the row, and add one line to the section's prose saying the
surface is gone, not merely unlisted — a reader who remembers the row must be able to find out where
it went:

```markdown
*Retired in P9 item 4 with MultipeerConnectivity: no radio mints or archives a peer identity any
more. The three QUIC radios each mint a fresh TLS identity and a random instance name per epoch
(mesh, presence) or per start (recipe share), so there is nothing stable left to wipe.*
```

**Legacy-sweep form (D-4.4, recommended):** keep the row, rewrite it —

```markdown
| **Legacy peer-identity archive** — the device name (in practice the user's own first name) left behind by a pre-P9 build's MultipeerConnectivity radio; nothing writes it any more | `Application Support/FernletPeerID.archive` | `wipeIdentityForDeleteAll` (mesh leg, via `removeLegacyPeerIdentityArchive()`; a file that was never written is not an error, and a refusing file system throws instead of leaving the identifier behind) |
```

`PrivacyWipeCoverageTests` requires the **function** `wipeIdentityForDeleteAll` to survive in every
file holding a live `IdentityService` — it does either way. Re-grep
`PersistedSurfaceWipeBoundaryTests` and `DeleteAllDataTests` for `peerID` before applying: at
`ba34491` neither named it, so there is nothing to prune there.

## 2. `Docs/No-Tracking-Wall.md` §4c — **[SPLIT: NOW for the near/recipe half]**

HEAD (line ~226):

```markdown
| **MultipeerConnectivity** — the shipping radios still on it (friend mesh, coach; presence crossed to QUIC in P9 item 2 and recipe share in P9 item 3) | `ProximityKit/Transport/` | `_fernlet-friend`, `_fernlet-coach`, each `._tcp` and `._udp`; `_fernlet-near` and `_fernlet-recipe` are retired and deleted with the framework in P9 item 4 |
```

**[SPLIT: NOW]** replacement (the two crossed radios' strings leave the plist; the row stays):

```markdown
| **MultipeerConnectivity** — the friend mesh is still on it; the coach channel is a declared service type with no live radio behind it (presence crossed to QUIC in P9 item 2 and recipe share in P9 item 3, and their `_fernlet-near` / `_fernlet-recipe` types left the plist with them) | `ProximityKit/Transport/` | `_fernlet-friend`, `_fernlet-coach`, each `._tcp` and `._udp` |
```

**[SPLIT: LATER]** replacement (the full retirement): delete the row entirely, and add the coach
pair to the "declared but unused" note the section already keeps for reserved keys — a declared
service type with no code behind it is exactly that, and leaving it in a *transport* table would
claim a radio that does not exist. Also check line ~243's `NSBonjourServices` justification
paragraph: it lists the three added QUIC entries and must not now read as if six others are live.

`NoTrackingBoundaryTests.permittedLocalLinkFiles` names only the four Network.framework files —
**no MC entry, nothing to remove.** Verified at `ba34491`.

## 3. `Docs/FileIndex.md` — two rows **[SPLIT: LATER]**

Delete both rows verbatim:

```markdown
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MCPeerIDStore.swift` | Persistent `MCPeerID` storage (`MCPeerIDStoring`, `FileMCPeerIDStore`) — the one deliberately MultipeerConnectivity-shaped seam left on the transport surface; retires with MC in P9. Owns the `FernletPeerID.archive` delete-all row. |
```

```markdown
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift` | Shared `MCSession` host for multi-peer mesh; `PeerChannelTransport` adapts per-peer state and data routing without managing the MC lifecycle directly. |
```

Also check `MeshTransportSelection.swift`'s own row (it exists nearby): its description must stop
saying the file selects between two radios.

## 4. `Docs/ProximityFunctionIndex.md` — three edits **[SPLIT: LATER]**

**(a)** Delete the whole `### \`MeshMultipeerSession.swift\`` section (the `PeerChannelTransport.*`
rows through `stop()` and the delegate rows below them).

**(b)** The section headed `### \`PeerHandle.swift\` / \`MCPeerIDStore.swift\`` is **already stale at
HEAD** — it lists `endpointKey(for:)` and `mcPeerID(for:)` under `PeerHandle.swift`, but at
`ba34491` `PeerHandle.swift` contains neither: `mcPeerID(for:)` is a private method of
`MeshMultipeerSession`. Rename the section to `### \`PeerHandle.swift\`` and delete four rows —
`endpointKey(for:)`, `mcPeerID(for:)`, `FileMCPeerIDStore.init(fileURL:)`, `load()`, `save(_:)` —
keeping `PeerHandle.==`, `isSameEndpoint(as:)` and `hash(into:)`. **Say in the commit that (b) was a
pre-existing index error, not collateral of this change.**

**(c)** Line ~40's "Friend mesh lifecycle" row credits the 2026-08 consolidation to
`MeshMultipeerSession.registerPendingConnection(_:)`. That consolidation is real history; re-word to
name where the idiom lives now (re-grep `registerPendingConnection` — if it has no surviving home,
say the consolidation retired with the radio).

## 5. `FernletKit/Sources/ProximityKit/Documentation.docc/ProximityKit.md` — five edits **[SPLIT: LATER]**

Warnings are errors, so the three symbol-list bullets are not optional: an unresolved DocC link
fails the build.

**(a) The abstract, line 3.** HEAD:

```markdown
Fernlet's self-contained peer-to-peer subsystem: signed identity, MultipeerConnectivity + UWB session formation, trust lifecycle, and every in-person social feature (photos, recipes, the clothing shop, chat, hearts, activities, moderation).
```

Replacement:

```markdown
Fernlet's self-contained peer-to-peer subsystem: signed identity, QUIC + UWB session formation, trust lifecycle, and every in-person social feature (photos, recipes, the clothing shop, chat, hearts, activities, moderation).
```

**(b) Overview, ~line 9.** `radios (MultipeerConnectivity for data, NearbyInteraction/UWB for
distance)` → `radios (Network.framework/QUIC over Bonjour for data, NearbyInteraction/UWB for
distance)`.

**(c) "How a session forms", ~line 31.** HEAD:

```markdown
runs one shared radio multiplexed into per-peer channels — a `MeshMultipeerSession` on every
shipping path (the friend mesh *selects* its radio; see Transport below).
```

Replacement:

```markdown
runs one shared radio multiplexed into per-peer channels — one of the three `Network*Session`
types, one per radio, since P9 retired the MultipeerConnectivity one (see Transport below).
```

**(d) The `### Transport` section, ~lines 308–345.** Three paragraphs move: the "protocol surface
carries no framework peer type" paragraph loses its `MCPeerIDStoring`/`FileMCPeerIDStore` exception
sentence; "**Four sessions, one surface**" becomes **three** and drops `PeerChannelTransport`;
"**Which radio a manager gets is a selection, not a hard-coding**" is now false in its own terms —
rewrite it as "the manager holds its radio through `MeshTransportSession` so the suite can inject a
fake, and `NetworkMeshSession` is the only conformer a shipping build constructs", keeping the
`MeshPeerChannel` / `DetachedPeerChannel` sentences and the "nothing about the choice is persisted"
wipe-ledger clause (still true, and cheaper than re-deriving it).

**(e) The symbol lists, ~lines 643–650.** Delete the bullets ``- ``MCPeerIDStoring``` and
``- ``FileMCPeerIDStore```; delete `MeshTransportKind`, `MeshTransportFactory` from the
"internal … where the transport SELECTION lives" line (under variant A) and add
`NetworkRecipeShareSession` to the QUIC list if item 3 pass 2 did not. Keep ``MultipeerServiceType``
**only if the coach strings are held** — under the full coach retirement it goes too.

## 6. `Docs/Mesh-Network-Feasibility-Runbook.md` — one sentence **[SPLIT: LATER]**

Every lane recipe passes `SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic` (lines ~856, ~1027, ~1189,
~1194, ~1499). Under variant A the variable no longer exists and the lines become **harmless
no-ops** — a Simulator ignores an unknown child env var — so the recipes still work verbatim. Add
one sentence at the runbook's Lane C preamble (~line 845, "running the **shipping** transport —
`NetworkMeshSession` selected by `FERNLET_MESH_TRANSPORT=quic`") saying the selection retired with
MC and the variable is now inert, kept in the recipes only so an older build can still be driven by
the same copy-paste. **Do not delete the variable from the recipes** — it is what makes a bisect
across the P9 boundary work.

## 7. `Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md` **[SPLIT: LATER]**

§17.1 marked BUILT is item 10's job, not this commit's. But three plan statements become false the
moment this lands and should be corrected in the same commit (index-only blobs, per the ledger's
convention): §6 finding 8 ("QUIC is not the default, and MC still ships"), §26.3's deletion-list
paragraph, and §18 decision 4's status. Add the stranger-admission finding from `DESIGN.md` to §14's
findings list — it is the reason this item is not the one-commit cleanup the plan priced.

## 8. The two display strings the deletion strands — **localization, not prose**

`App/Fernlet/Proximity/UI/ConnectionInspectorView.swift`:
- `:139` returns the literal `"RSSI fallback active. MultipeerConnectivity does not expose RSSI, so
  meter estimates are unavailable on this transport."` from `rangingStatusText: String?`. It is
  **not in `Localizable.xcstrings`** (grep returns 0) — so it is an existing localization-wall gap
  (a `String` display value), and after this commit it is also factually wrong. Rewrite the copy to
  name the QUIC radio. **Do not widen the change into a `LocalizedStringKey` fork here** — that is a
  localization-round item and this commit is already large; note it as a residual.
- `:148` renders `inspectorRow("MCSession", log.transport.mcSessionState)` — a user-visible label
  reading "MCSession", backed by `ConnectionSessionLog.transport.mcSessionState`. **The field name
  may be a persisted/Codable token** (`ConnectionSessionLog` is the inspector's record —
  re-check whether it is `Codable` and whether that key is written anywhere). Rename the **label**
  only; leave the field's spelling alone unless the check proves it is memory-only. A renamed
  persisted key is a data-compat change, not cleanup.

**No string-catalog key dies** in this commit: neither deleted Swift file contains
`String(localized:)`, `LocalizedStringKey`, `LocalizedStringResource` or `NSLocalizedString`
(verified by grep at `ba34491`). The close-out's `Scripts/sync-string-catalogs.sh --check` should be
a no-op for item 4.

## Appendix — `tests` anchored patch (drafted at `ba34491`; re-anchor by text)

# Test-side edits — `Tests/FernletTests/`

All **[SPLIT: LATER]**. The wall never saw `Tests/` (scan roots are
`FernletKit/Sources/ProximityKit` + `App/Fernlet`), so this half is invisible in
`permittedFiles` and is the part the launcher's row does not mention at all: **32 test files** name
an MC type or import the framework.

## A. Files DELETED whole (3)

### `Tests/FernletTests/MultipeerPeerTests.swift`
One cell, `filePeerIDStorePersistsPeerID`, a `FileMCPeerIDStore` archive round-trip. Dies with the
store. **Plain struct, no `@Suite` attribute** — do not look for it with a `@Suite` grep when
pruning the CI line.

### `Tests/FernletTests/PeerIDArchiveWipeTests.swift`
86 lines, every cell `FileMCPeerIDStore.clearForDeleteAll()`. Dies with the store. **Plain struct,
no `@Suite` attribute.** If the D-4.4 legacy-sweep hunk is taken instead of the pure retire, do NOT
delete this file — rewrite its four cells against
`MeshNetworkManager.removeLegacyPeerIdentityArchive()`'s observable behaviour (file present →
removed; file absent → no throw; unremovable → throws; the throw does not skip `identity.wipe()`).
That is the cheapest way to keep the wipe leg's coverage, and it is why D-4.4 is recommended.

### `Tests/FernletTests/MeshTransportErrorSurfacingTests.swift` — **DELETE ONLY AFTER PORTING TWO CELLS**
Five cells. Three are MC delegate behaviour and die:
`advertiserStartFailureInvokesTransportErrorCallback`,
`browserStartFailureInvokesTransportErrorCallback`, `missingCallbackIsHarmless`.
**Two are not MC's and must not die silently:**
`oversizedInboundFrameIsDroppedBeforeReachingTheChannel` and
`inboundFrameAtExactlyTheCapIsNotDropped` pin the inbound wire ceiling. `NetworkMeshSession` has the
same ceiling (`static let maxInboundWireBytes = SealedPayloadFraming.maxInflatedByteCount`, guarded
at two sites) and `NetworkPresenceSession` aliases it. Port both into
`Tests/FernletTests/NetworkMeshTransportTests.swift` against `NetworkMeshSession` before deleting
the file, and say so in the commit message. **Check first** whether `NetworkMeshTransportTests`
already carries an equivalent pair — if it does, the port is a no-op and the file just dies.
The private `EphemeralPeerIDStore` fixture at the top dies with it.

## B. `Tests/FernletTests/PeerTransportNeutralityTests.swift` — one of three structs dies

Three suites in one file: `PeerHandleIdentityTests` (stays), `MeshMultipeerSessionIdentityTests`
(**dies whole**), `FakePeerTransportTests` (stays).

HEAD:

```swift
@Suite(.serialized)
struct MeshMultipeerSessionIdentityTests {
```

Delete from that `@Suite(.serialized)` through the struct's closing brace — including the
`makeBrowser(for:)` helper at `:227` and every `MeshMultipeerSession(usesEphemeralPeerID: true)`
construction. Then delete the file's `import MultipeerConnectivity`.

**Before deleting, read the struct's doc at `:112`:** "none of them touches the archived
`FileMCPeerIDStore` the other radios depend on." That sentence is the *ephemeral peer ID* invariant
— presence and recipe share each mint their own identity per start (items 2 and 3) and must not
touch a shared archive. The archive is gone, so the invariant is satisfied by construction; nothing
to port. Record that reasoning in the commit, not a new cell.

Also HEAD `:405`: `/// working, matching `MeshMultipeerSession`, where relying on it is undocumented
behaviour.` — inside `FakePeerTransportTests`, prose only; re-tense.

## C. `Tests/FernletTests/MeshTransportSelectionTests.swift` — 4 of 12 cells

Under **variant A** (`MeshTransportKind`/`MeshTransportFactory` deleted):

| Cell | Disposition |
|---|---|
| `theShippingDefaultIsMultipeerConnectivity` | **delete** |
| `theAppsInitializerRunsOnTheMultipeerRadio` | **rewrite** → `theAppsInitializerRunsOnTheQUICRadio` |
| `theQUICRadioIsSelectableAndOptIn` | **rewrite** → the injection half only |
| `everyTransportKindBuildsItsOwnRadio` | **delete** (no kinds left) |
| `theMultipeerRadioIgnoresTheAuthorityWithoutIncident` | **delete** |
| the other 7 | unchanged — they are about the authority, the wiring and the admission gate |

HEAD:

```swift
    /// A manager built the way the app builds one runs on the MC radio — the assertion that would
    /// fail the moment a default flipped anywhere in the factory or the initializer.
    @Test func theAppsInitializerRunsOnTheMultipeerRadio() {
        let manager = MeshNetworkManager(store: store)

        #expect(manager.transportForTesting as? MeshMultipeerSession != nil,
                "the public initializer must select MultipeerConnectivity")
        #expect(manager.transportForTesting as? NetworkMeshSession == nil,
                "and must never select the QUIC radio")
    }
```

Replacement:

```swift
    /// A manager built the way the app builds one runs on the QUIC radio — the assertion that
    /// would fail the moment the initializer's one default moved (P9 item 4 retired the second
    /// conformer, so there is nothing left for it to move TO except a mistake).
    @Test func theAppsInitializerRunsOnTheQUICRadio() {
        let manager = MeshNetworkManager(store: store)

        #expect(manager.transportForTesting as? NetworkMeshSession != nil,
                "the public initializer must build the QUIC radio")
    }
```

This is **red-once #1** from `DESIGN.md`: revert `MeshNetworkManager.init`'s default on a scratch
copy and watch it fail. Keep the suite's name — renaming it would move it on the CI mesh line and
drag `CIGateSelectorBoundaryTests` in (item 6's problem, not this commit's).

## D. Bare-import sweep — 15 files, one line each

These import the framework and use **no** MC identifier (verified by whole-identifier grep at
`ba34491`). Delete the single `import MultipeerConnectivity` line; nothing else changes. The
compiler will demand it anyway once the module stops being linked.

`ClothingShareCodecTests.swift`, `CoachSessionHardeningTests.swift`, `HeartShareTests.swift`,
`MeshClothingShopTests.swift`, `MemoryLifecycleTests.swift`, `MeshEncryptionTests.swift`,
`MeshNetworkManagerTests.swift`, `PresenceHeartsTests.swift`, `RecipeShareCodecTests.swift`,
`ProximityCoordinatorTests.swift`, `ProximityVerificationTests.swift`, `PresenceManagerTests.swift`,
`SealedIntroductionTests.swift`, `SessionMessageTests.swift`, `TrainerProximityServiceTests.swift`.

## E. Two files with a real MC use that is NOT about MC

### `NearbyRangingSessionTests.swift`
Uses `MCPeerID` as an `NSKeyedArchiver` **stand-in** — its own comment says so:
`// Verify the NSKeyedArchiver round-trip mechanism using MCPeerID as a stand-in`. Swap the
stand-in for any `NSSecureCoding` class the tree already links (`NSString` is the obvious one) and
drop the import. The cell's subject is the archiver, not the peer type, so the swap is faithful.

### `ProximityRecipeShareCapTests.swift`
Two **comment** mentions (`MCSession kept alive`, `without touching MCNearbyService* objects`) plus
an import. Re-tense the comments — they now describe `NetworkRecipeShareSession`'s pause, which
item 3 pass 2 landed — and drop the import.

## F. Prose-only mentions in tests — re-tense, no behaviour

`PresenceEpochPostureTests.swift:338`, `PeerHandleWireGoldenTests.swift:33`,
`MeshDialPolicyTests.swift:513`, `RecipeShareTransferTests.swift:18`/`:185`,
`ProximityRecipeShareCapTests.swift:47`, `PresenceAdvertisementTests.swift:56`,
`NoTrackingBoundaryTests.swift:183`, `MeshTransportSelectionTests.swift:13`,
`PresenceOverQUICTests.swift` (several), `ProximityWireOffMainDecodeTests.swift`.

**Two of these are needle lists, not prose — do not re-tense them, they must keep working:**
- `PresenceOverQUICTests.swift:652` — `for needle in ["MeshMultipeerSession", "MCPeerID",
  "MCSession", "PeerChannelTransport", …]` asserting `PresenceManager` names none of them.
- `RecipeShareOverQUICTests.swift:926` — the same shape for the recipe manager.

After item 4 these needles can never match anything, which makes them **vacuous rather than wrong**.
Leave them: they cost nothing and they are the per-manager half of the tree-wide wall. Say so in a
one-line comment above each, so a later reader does not prune them as dead.

