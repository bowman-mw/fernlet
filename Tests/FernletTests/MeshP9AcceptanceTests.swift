// MeshP9AcceptanceTests.swift
// FernletTests
//
// Network migration **P9's acceptance battery** (plan §17.1, launcher item 9): one serialized suite
// per clause, each promoting the named tier-1 claims of the item it speaks for and running its
// clause END TO END on the shipping seams, so CI gating a clause fails on this battery's own
// assertions rather than on a unit suite's. The P8 battery is the template and the rule is the same
// — where an exhaustive space already exists it is RE-WALKED here rather than sampled, and never by
// calling the unit suite's oracle: clause (c) carries its own 60-row expectation of the discovery
// gate, spelled EVENT-outermost with every radio reading a literal row, so a table and a unit
// oracle that drifted together would still redden here.
//
// **Five suites.** The ephemeral posture both radios wear (item 2 pass 1 + item 3's posture
// decision), the presence swap (item 2 pass 2), the recipe swap with pause/resume (item 3), the
// MultipeerConnectivity retirement (item 4), and an honesty suite naming — by ledger row — what no
// CI machine can run. `CIGateSelectorBoundaryTests` therefore moves its battery pin from 48 to 53,
// and the same commit gates the suites items 2, 3 and 4 left on no CI line at all: the seven this
// battery promotes, plus the twenty-one the fix review's own accounting found beside them. Which
// suites those are is DERIVED (`MeshP9HonestyAcceptanceTests.p9TouchedSuites`) rather than
// hand-listed — the first cut listed seven by hand and missed `ProximityRecipeShareCapTests`, 31
// cells holding the very pause/resume behaviour clause (c) leans on.
//
// **Rule 7 — "a row that lands in two passes needs its gate to assert the later pass RAN."** Items
// 2 and 3 are two-pass by shape (a value, then the radio wearing it), and pass 1 changed nothing on
// the air. Every clause below therefore carries at least one needle that is FALSE at the pass-1
// commit and true at the pass-2 one: the manager naming `NetworkPresenceSession` /
// `NetworkRecipeShareSession` and no `serviceType` at all; the QUIC service type declared in
// `Info.plist`; the radio advertising the posture's OWN bytes; `makeSession:` existing to inject a
// fake through. A needle satisfied by a rename alone is named as such in `GATES.md` and is not one.
//
// **What this battery does NOT claim** is in clause (e), by name and not by omission: item 4 was
// SPLIT; the MC->QUIC FLIP landed on 2026-09-21 and the DELETION on 2026-09-22, so clause (d) is
// now the zero-list it was always meant to become (the two MC files absent, the framework imported
// nowhere, the _fernlet-friend pair retired); the two lane rows (9.2.2, 9.3.2) are tier-2
// sim↔sim observations; item 0's rows need phones in the owner's hands; P9-3-A is a product
// decision on P7's run-policy table. The two determinism digests keep their one home in
// `MeshP5AcceptanceTests`, this file spells neither, and the gate that runs it re-runs the
// determinism suites.

import Foundation
import Testing
import FernletFoundation
@testable import ProximityKit

// MARK: - MeshP9Acceptance

/// The thin rig P9's clauses share: the two radio rigs, the battery's own Bonjour partition, and the
/// epoch arithmetic the posture walk needs.
///
/// The source walker and the per-occurrence home list are deliberately **not** re-spelled here — a
/// sixth copy of `MeshP7Acceptance.sources(under:)` / `homes(of:in:)` is what
/// `MeshContinuationRaiseWallTests` already refused to write; both are `nonisolated static`, so a
/// non-isolated cell may call them. Neither radio fake is re-spelled either: `FakePresenceRadioSession`
/// and `FakeRecipeShareRadioSession` are the seam conformers the two pass-2 items built, and a
/// second conformer here would be a second thing to keep in step with the protocol.
enum MeshP9Acceptance {

    // MARK: Paths

    /// The presence posture value (item 2 pass 1).
    static let posturePath = "FernletKit/Sources/ProximityKit/Presence/PresenceEpochPosture.swift"

    /// The presence radio (item 2 pass 2).
    static let presenceSessionPath = "FernletKit/Sources/ProximityKit/Transport/NetworkPresenceSession.swift"

    /// The presence manager — the file whose MultipeerConnectivity names pass 2 removed.
    static let presenceManagerPath = "FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift"

    /// The recipe radio, which also declares ``RecipeSharePosture`` (item 3 pass 2).
    static let recipeSessionPath = "FernletKit/Sources/ProximityKit/Transport/NetworkRecipeShareSession.swift"

    /// The recipe manager.
    static let recipeManagerPath =
        "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift"

    /// The transport factory: the one file that decides which mesh radio a shipping launch builds.
    static let transportSelectionPath =
        "FernletKit/Sources/ProximityKit/Transport/MeshTransportSelection.swift"

    /// The app target's Info.plist — the `NSBonjourServices` declaration.
    static let plistPath = "App/Fernlet/Info.plist"

    /// The workflow that gates this battery.
    static let workflowPath = ".github/workflows/s3-wall.yml"

    /// The two files that owned MultipeerConnectivity until the deletion round (2026-09-22), sorted —
    /// pinned ABSENT now (item 4's `[SPLIT: LATER]` half, taken).
    static let multipeerFiles = [
        "FernletKit/Sources/ProximityKit/Transport/MCPeerIDStore.swift",
        "FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift"
    ]

    // MARK: The posture walk

    /// How many epoch boundaries clause (a) walks. A constant, so the loop that walks them is
    /// bounded by this file rather than by a clock (Power of 10 rule 2).
    static let boundariesWalked = 4

    /// Seconds past a boundary at which the walk rotates — deliberately not zero, so a rotation that
    /// happened to anchor on `now` rather than on the epoch start would be visible.
    static let secondsPastBoundary: TimeInterval = 31

    /// The epoch start containing the battery's fixed instant. Every presence cell measures from a
    /// boundary rather than from an arbitrary second, which is the trap pass 1's rotation cell names.
    static var epochAnchor: Date {
        IdentityService.presenceEpochStart(at: Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// `count` consecutive postures, each rotated across one boundary from the one before it,
    /// through the PRODUCTION rotation (system entropy, the module's one certificate path).
    ///
    /// - Throws: whatever the mint throws; a posture that cannot be minted is not a rotation.
    static func postureWalk(count: Int) throws -> [PresenceEpochPosture] {
        var walked = [try PresenceEpochPosture.minted(at: epochAnchor)]
        // R2: bounded by `count`, itself a constant of this file.
        for step in 1...max(1, count) {
            let instant = epochAnchor
                .addingTimeInterval(Double(step) * IdentityService.presenceEpochSeconds + secondsPastBoundary)
            walked.append(try walked[step - 1].rotated(at: instant))
        }
        return walked
    }

    // MARK: The Bonjour partition (clause (d)'s own expectation)

    /// The six MultipeerConnectivity types retired: four by P9 item 4's `[SPLIT: NOW]` half, and the
    /// friend pair by the deletion round (2026-09-22), in the same commit that removed the radio.
    static let retiredBonjour: Set<String> = [
        "_fernlet-near._tcp", "_fernlet-near._udp", "_fernlet-recipe._tcp", "_fernlet-recipe._udp",
        "_fernlet-friend._tcp", "_fernlet-friend._udp"
    ]

    /// The three a shipping radio advertises or browses: the three QUIC radios, and nothing else.
    static let liveBonjour: Set<String> = [
        "_fernlet-mesh2._udp", "_fernlet-near2._udp", "_fernlet-recipe2._udp"
    ]

    /// Declared, backed by no radio, plan §18 decision 4 still the owner's: pinned in neither
    /// direction, classified so the partition can tell a held type from an unreviewed one.
    static let heldBonjour: Set<String> = ["_fernlet-coach._tcp", "_fernlet-coach._udp"]

    // MARK: Rigs

    /// One presence radio under an injected clock: a throwaway keychain service, a throwaway heart
    /// ledger, the seam's in-memory conformer, and the shipping ``PresenceManager`` over both.
    @MainActor
    struct PresenceRig {

        /// The throwaway keychain service this rig provisioned, deleted by ``teardown()``.
        let serviceID: String

        /// The host the manager holds `unowned`; the rig keeps it alive (invariant HP0).
        let host: MockPresenceQUICHost

        /// What the manager was asked to put on the air.
        let radio: FakePresenceRadioSession

        /// The shipping manager.
        let manager: PresenceManager

        /// Drops the provisioned identity. Called from every cell's `defer`.
        func teardown() { KeychainItem.deleteAll(service: serviceID) }
    }

    /// Builds a presence rig whose clock is `now`.
    ///
    /// - Parameters:
    ///   - label: a short, unique-per-cell tag; it reaches only the throwaway keychain service name.
    ///   - now: the injected clock, read on every manager tick.
    @MainActor
    static func presenceRig(_ label: String, now: @escaping () -> Date) throws -> PresenceRig {
        let serviceID = "com.fernlet.meshp9.\(label).\(UUID().uuidString)"
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        let ledger = ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("meshp9-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: now)
        // ML5 (invariant HP0): the host is a `let` the returned rig keeps, so it outlives the
        // manager's `unowned` reference to it.
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: ledger, identity: identity)
        manager.nowProvider = now
        manager.makeSession = { radio }
        return PresenceRig(serviceID: serviceID, host: host, radio: radio, manager: manager)
    }

    /// One recipe-share radio: the seam's in-memory conformer and the shipping manager over it.
    @MainActor
    struct RecipeRig {

        /// The host the manager holds `unowned`; the rig keeps it alive (invariant HP0).
        let host: RecipeTransferTestHost

        /// What the manager was asked to do to discovery.
        let radio: FakeRecipeShareRadioSession

        /// The shipping manager.
        let manager: ProximityRecipeShareManager
    }

    /// Builds a recipe rig with the radio already up by the manager's own account.
    @MainActor
    static func recipeRig() -> RecipeRig {
        // ML5 (invariant HP0): the host is a `let` the returned rig keeps, so it outlives the
        // manager's `unowned` reference to it — an inline host dies at the end of the expression.
        let host = RecipeTransferTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        manager.markRunningForTesting()
        return RecipeRig(host: host, radio: radio, manager: manager)
    }
}

// MARK: - (a) The ephemeral posture

/// **Items 2 (pass 1) and 3: the posture is the product, and the two radios wear different ones on
/// purpose.** The rotation walked as VALUES over four boundaries, the certificate anchored to the
/// epoch start rather than to the asking instant, and the two posture types pinned apart — a
/// silent convergence of the two is the failure nobody would attribute to a transport swap.
@Suite(.serialized)
struct MeshP9EphemeralPostureAcceptanceTests {

    /// **The rotation table, re-walked, plus the half a rotation table cannot see.**
    ///
    /// Four boundaries: no name, no certificate and no epoch repeats, and every name is exactly the
    /// constant length that keeps a name from leaking through its length alone. Then the other
    /// direction — the trap pass 1's verify found: the certificate's validity window is the one part
    /// of the posture that must be IDENTICAL on every device in an epoch, so a raw-`now` anchor
    /// survives any table that only asserts what changes. This battery reaches that claim through
    /// the injected mint seam (which instant the certificate path was handed) rather than through
    /// the DER substring arithmetic the unit suite uses — a second decomposition of one claim.
    @Test func theBoundaryWalkLeavesNothingInCommonAndOneEpochsMintsShareTheirWindow() throws {
        let walked = try MeshP9Acceptance.postureWalk(count: MeshP9Acceptance.boundariesWalked)
        let expected = MeshP9Acceptance.boundariesWalked + 1
        #expect(walked.count == expected, "the walk lost a posture")
        #expect(Set(walked.map(\.instanceName)).count == expected, "a name survived a boundary")
        #expect(Set(walked.map(\.tlsIdentity.certificateDER)).count == expected, "a certificate did")
        #expect(Set(walked.map(\.epoch)).count == expected, "and the epochs must be distinct too")
        let first = try #require(walked.first)
        #expect(walked.map(\.epoch) == (0..<expected).map { first.epoch + UInt64($0) },
                "the walk crossed each boundary exactly once — a skipped epoch proves nothing")
        // R2: bounded by the walked postures.
        for posture in walked {
            #expect(posture.instanceName.count == PresenceEpochPosture.instanceNameLength,
                    "a variable-length name leaks through its length alone")
            #expect(posture.instanceName.hasPrefix(
                PresenceEpochPosture.instanceNamePrefix + PresenceEpochPosture.instanceNameSeparator),
                    "the frozen service token is the only shared part of a name")
        }

        // The window, through the seam: two devices switching presence 27 s and 613 s into ONE
        // epoch hand the certificate path the same instant, and a rotation hands it the NEXT
        // epoch's start — not the 431st second of it.
        var handed: [Date] = []
        let recording: (Date) throws -> EphemeralMeshTLSIdentity.Minted = { instant in
            handed.append(instant)
            return try EphemeralMeshTLSIdentity.mint(now: instant)
        }
        let anchor = MeshP9Acceptance.epochAnchor
        let early = try PresenceEpochPosture.minted(
            at: anchor.addingTimeInterval(27),
            entropy: PresenceEpochPosture.systemEntropy, mintIdentity: recording)
        let late = try PresenceEpochPosture.minted(
            at: anchor.addingTimeInterval(613),
            entropy: PresenceEpochPosture.systemEntropy, mintIdentity: recording)
        #expect(early.epoch == late.epoch, "the two instants really are inside one epoch")
        #expect(early.instanceName != late.instanceName, "and the two devices are otherwise distinct")
        #expect(handed == [anchor, anchor],
                "a certificate anchored to `now` carries the second this device's radio came up")
        _ = try early.rotated(
            at: anchor.addingTimeInterval(IdentityService.presenceEpochSeconds + 431),
            entropy: PresenceEpochPosture.systemEntropy, mintIdentity: recording)
        #expect(handed.last == anchor.addingTimeInterval(IdentityService.presenceEpochSeconds),
                "the boundary mint anchors to the new epoch's start")
    }

    /// **The two radios wear different postures by decision, and neither wears the other's.**
    ///
    /// The ledger's two posture decisions, which no single unit suite spans. Presence is anchored to
    /// a 900 s epoch every device agrees on, with the certificate minted at the epoch START; recipe
    /// share is minted per `start()` and per `resume()` because its lifetime is a Food-tab visit,
    /// and giving it the epoch type would be a silent mismatch plus a second timer on a subsystem
    /// allowed one. The needle is narrow on purpose: the recipe session legitimately reuses
    /// `PresenceEpochPosture.systemEntropy` / `.hexadecimal` as byte helpers, so the ban is on the
    /// posture's own MINT and on the epoch clock, not on the type's name.
    ///
    /// Rule 7: `RecipeSharePosture` and its three mint sites exist only because pass 2 landed.
    @Test func theTwoRadiosWearDifferentPosturesByDecisionAndNeitherWearsTheOthers() throws {
        let posture = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.posturePath))
        #expect(posture.contains("IdentityService.presenceEpochStart(at: now)"),
                "the presence certificate is minted at the epoch start")
        #expect(posture.contains("IdentityService.presenceEpoch(at: now)"),
                "and the epoch comes from the one presence clock")
        #expect(!posture.contains("randomInstanceName"),
                "the presence name is drawn here, not borrowed from the mesh advertisement")

        let session = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.recipeSessionPath))
        #expect(!session.contains("PresenceEpochPosture.minted"),
                "the recipe radio must not wear the 900 s posture — its lifetime is a tab visit")
        #expect(!session.contains("presenceEpoch"), "and it must not read the presence clock")
        // R2: bounded by the three banned clock spellings.
        for banned in ["Timer", "rotateEpochIfNeeded", "presenceEpochSeconds"] {
            #expect(!session.contains(banned),
                    "`\(banned)` is a rotation timer on a radio the ledger allows none")
        }
        let started = try #require(
            MeshRoutedSourceScan.bracedBody(
                after: "func start(advertisement: [String: String]) throws {", in: session),
            "the recipe radio's start door is gone")
        #expect(started.contains("RecipeSharePosture.minted()"), "a fresh posture per start()")
        let resumed = try #require(
            MeshRoutedSourceScan.bracedBody(after: "func resumeDiscovery() {", in: session),
            "the recipe radio's resume door is gone")
        #expect(resumed.contains("RecipeSharePosture.minted()"), "and a fresh one per resume()")

        let one = try RecipeSharePosture.minted(now: MeshP9Acceptance.epochAnchor)
        let two = try RecipeSharePosture.minted(now: MeshP9Acceptance.epochAnchor)
        #expect(one.instanceName != two.instanceName, "two mints at ONE instant share no name")
        #expect(one.sessionID != two.sessionID, "no session id")
        #expect(one.tlsIdentity.certificateDER != two.tlsIdentity.certificateDER,
                "and no certificate — there is no epoch here for two mints to agree inside")
    }

    /// **Neither posture is persisted, and neither file schedules anything.**
    ///
    /// P9's wipe-wall row, inverted: the phase added no persisted surface, so a posture that reached
    /// for the keychain, a file or `UserDefaults` would owe a `Docs/PrivacyWipeCoverage.md` row and
    /// delete-all wiring that do not exist. Widened past the unit suite's presence-only cell to the
    /// recipe posture, which has no cell of its own, and restricted to the value declarations —
    /// `NetworkRecipeShareSession` as a whole legitimately holds tasks.
    @Test func neitherPostureIsPersistedAndTheValuesScheduleNothing() throws {
        let posture = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.posturePath))
        let session = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.recipeSessionPath))
        let recipePosture = try #require(
            MeshRoutedSourceScan.bracedBody(after: "nonisolated struct RecipeSharePosture {", in: session),
            "the recipe posture's declaration is gone")
        // The vendor-identifier symbol is deliberately not spelled: `NoTrackingBoundaryTests` bans
        // it repo-wide including comments, so naming it here would only indict this suite.
        let forbidden = ["UserDefaults", "Keychain", "KeychainItem", "SecItem", "FileManager",
                         "write(to:", "JSONSidecarFile", "UIDevice", "hostName", "bundleIdentifier"]
        // R2: bounded by the forbidden list × the two sources.
        for marker in forbidden {
            #expect(!posture.contains(marker), "PresenceEpochPosture reaches for '\(marker)'")
            #expect(!recipePosture.contains(marker), "RecipeSharePosture reaches for '\(marker)'")
        }
        // R2: bounded by the three scheduling spellings.
        for marker in ["Task", "Timer", "sleep"] {
            #expect(!posture.contains(marker), "a value schedules nothing: PresenceEpochPosture '\(marker)'")
            #expect(!recipePosture.contains(marker), "nor does RecipeSharePosture: '\(marker)'")
        }
        let wipe = try RepoRoot.source("Docs/PrivacyWipeCoverage.md")
        #expect(!wipe.contains("PresenceEpochPosture") && !wipe.contains("RecipeSharePosture"), """
            a posture has gained a wipe row, which means it gained a persisted surface — P9's \
            decision was "no new persisted surface", and a row here without a delete-all writer \
            beside it reads as coverage
            """)
    }
}

// MARK: - (b) The presence swap

/// **Item 2 pass 2: the presence radio on Network.framework/QUIC.** The bind between the posture
/// and what goes on the air, the boundary that replaces all of it and withdraws the old name, the
/// service type's own declaration, the peer label that carries no part of the peer's name, and the
/// MultipeerConnectivity path gone from the manager.
///
/// Rule 7 throughout: pass 1 built a value nothing advertised, so every cell here is false at
/// `d7342f3` and true at `9f78111`.
@MainActor
@Suite(.serialized)
struct MeshP9PresenceSwapAcceptanceTests {

    /// **The whole arc, on the shipping manager over the seam's conformer.**
    ///
    /// A mid-epoch start (the only start the tier-2 runner ever performs), a tick inside the epoch
    /// that re-advertises nothing, and a boundary that re-advertises under an entirely new name AND
    /// a new certificate. Both halves of the boundary matter: re-advertising is the only way the
    /// OLD Bonjour registration is withdrawn, so a boundary that re-derived tags alone would leave
    /// the previous name live beside the new one and an observer who saw both would have linked
    /// them by construction.
    ///
    /// This is pass 2's claim and the one thing no source scan can see: a listener registered under
    /// `MeshLinkAdvertisement.randomInstanceName()` instead would compile, would rotate nothing,
    /// and would look exactly like this from outside.
    @Test func aMidEpochStartWearsThePosturesOwnBytesAndTheBoundaryReplacesAllOfThem() throws {
        let anchor = MeshP9Acceptance.epochAnchor
        var clock = anchor.addingTimeInterval(120)
        let rig = try MeshP9Acceptance.presenceRig("presence-arc", now: { clock })
        defer { rig.teardown() }
        rig.manager.start()

        let posture = try #require(rig.manager.presencePosture, "the manager minted no posture")
        #expect(rig.radio.advertised.count == 1, "the radio comes up exactly once")
        let first = try #require(rig.radio.advertised.first)
        #expect(first.instanceName == posture.instanceName, "the air carries the posture's own name")
        #expect(first.certificateDER == posture.tlsIdentity.certificateDER, "and its own certificate")
        #expect(first.epoch == IdentityService.presenceEpoch(at: clock),
                "a mid-epoch start advertises for the epoch it starts in")
        #expect(rig.manager.isListening, "and the radio is up by the manager's own account")

        clock = anchor.addingTimeInterval(IdentityService.presenceEpochSeconds - 1)
        rig.manager.rotateEpochIfNeeded()
        #expect(rig.radio.republished.isEmpty, "a tick inside the epoch re-advertises nothing")

        clock = anchor.addingTimeInterval(IdentityService.presenceEpochSeconds + 1)
        rig.manager.rotateEpochIfNeeded()
        let second = try #require(rig.radio.republished.last, "the boundary re-advertised nothing")
        #expect(second.epoch == first.epoch + 1, "one boundary, one epoch")
        #expect(second.instanceName != first.instanceName, "the name must rotate with the tags")
        #expect(second.certificateDER != first.certificateDER, "and so must the certificate")
        #expect(rig.radio.allAdvertisements.filter { $0.instanceName == first.instanceName }.count == 1,
                "the old name went on the air once, before the boundary, and never again")
        let held = try #require(rig.manager.presencePosture, "the manager dropped its posture")
        #expect(held.instanceName == second.instanceName,
                "and the manager's own posture is the one the radio is wearing")
    }

    /// **The presence radio is its own service, and its type is declared live while its predecessor
    /// is gone.**
    ///
    /// A service type missing from `NSBonjourServices` fails discovery silently on device — no log,
    /// no observable state — so the declaration is pinned present; a shared ALPN would let a
    /// presence dial complete a TLS handshake with a mesh or recipe listener, so the three are
    /// pinned apart. The retired MultipeerConnectivity pair is pinned ABSENT, which is item 4's
    /// `[SPLIT: NOW]` half seen from this clause.
    @Test func thePresenceRadioIsItsOwnServiceAndItsPredecessorIsOffTheAir() throws {
        #expect(NetworkPresenceSession.serviceType == "_fernlet-near2._udp")
        #expect(NetworkPresenceSession.serviceType != NetworkMeshSession.friendServiceType)
        #expect(NetworkPresenceSession.serviceType != NetworkRecipeShareSession.serviceType)
        #expect(NetworkPresenceSession.alpn != NetworkMeshSession.alpn)
        #expect(NetworkPresenceSession.alpn != NetworkRecipeShareSession.alpn)
        // PARSED, not grepped (item 9's fix review, NOTE 3): `declaredBonjourServiceTypes()` reads
        // `NSBonjourServices` as a plist array, so a type declared under a different key, in a
        // comment, or as a substring of a longer string is not mistaken for a declaration — and
        // clause (d) below already partitions the same parsed set, so the two halves of this
        // battery cannot disagree about what the app declares.
        let declared = try NoTrackingBoundaryTests.declaredBonjourServiceTypes()
        #expect(declared.contains(NetworkPresenceSession.serviceType),
                "the QUIC presence type is declared — without it discovery dies silently on device")
        // R2: bounded by the retired presence pair.
        for retired in ["_fernlet-near._tcp", "_fernlet-near._udp"] {
            #expect(!declared.contains(retired),
                    "`\(retired)` is still declared — no radio has browsed it since pass 2 crossed")
        }
        let session = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.presenceSessionPath))
        #expect(session.contains("alpn: Self.alpn"), "the session must actually bind its own ALPN")
    }

    /// **Every presence audit line names its peer by a salted, per-session label of a fixed shape —
    /// and the cell scopes its own count.**
    ///
    /// The tier-2 finding P9-2-A: these lines named the peer by `MeshLinkKey.rawValue` under a
    /// comment promising an opaque key, and under this radio that key IS the browsed Bonjour
    /// endpoint id — the peer's per-epoch name plus the service type, the one value the whole
    /// rotation exists to keep uncorrelatable.
    ///
    /// Decomposed the other way round from the unit cell, deliberately: that one hunts a blacklist
    /// of fragments, this one asserts the POSITIVE shape (exactly `peerLabelLength` hexadecimal
    /// characters, one label per peer for the session's life), so a future line naming the peer by
    /// some spelling nobody blacklisted still reddens.
    ///
    /// **Which read is scoped, and which is deliberately not** (item 9's fix review, BLOCKER 3).
    /// The COUNT is scoped to this session's label, because `FernletAuditLog`'s capture registry is
    /// process-global and suites run in parallel, so an unscoped `>= 2` would be item 7's defect a
    /// ninth time. The NEEDLE WALK is not, and must not be: `context["peer"] == label` is itself a
    /// blacklist, and the line this cell exists to catch — one naming the peer under some other key,
    /// or by a spelling that never became a label at all — is exactly the line that filter drops.
    /// The cell's peer name is unique to it, so no other suite's line can carry it and the walk
    /// cannot red on somebody else's rig; the serviceType needle is a property
    /// `PresenceOverQUICTests` asserts of its own lines too, so a hit there is a real defect either
    /// way.
    @Test func everyPresenceAuditLineNamesItsPeerOnlyByASaltedPerSessionLabel() throws {
        let radio = NetworkPresenceSession()
        radio.runWithoutRadiosForTesting(posture: try PresenceEpochPosture.minted(at: MeshP9Acceptance.epochAnchor))
        // Deliberately NOT the unit suite's `0123456789abcdef`: both suites are on the mesh line,
        // both produce `presence.quic.*` lines through the process-global capture, and two rigs
        // sharing one peer name is how an interleave turns a scoped read into a cross-suite red.
        let peerName = PresenceEpochPosture.instanceNamePrefix
            + PresenceEpochPosture.instanceNameSeparator + "fedcba9876543210"
        let key = MeshLinkKey("\(peerName).\(NetworkPresenceSession.serviceType).local.")

        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        radio.noteBrowsedForTesting(
            key, instanceName: peerName,
            advertisement: PresenceAdvertisement.publishedFields(tags: ["dGFnLWE", "dGFnLWI"]))
        radio.bookTunnelForTesting(key, role: .initiator)
        _ = radio.admitInboundForTesting(at: key)

        let label = radio.peerLabel(for: key)
        let everyRig = capture.records(withEventPrefix: "presence.quic.")
        let mine = everyRig.filter { $0.context["peer"] == label }
        #expect(mine.count >= 2, "the sighting and the glare collapse are this session's two peer lines")
        #expect(label.count == NetworkPresenceSession.peerLabelLength, "the label has one fixed width")
        #expect(label.allSatisfy { $0.isHexDigit }, "and carries nothing but digest bytes")
        // R2: bounded by the captured presence lines × their context keys. Every presence line,
        // not just the labelled ones — see the note above on which read is scoped and why.
        for record in everyRig {
            for (contextKey, value) in record.context {
                #expect(!value.contains(peerName), "\(record.event).\(contextKey) carries the peer's name")
                #expect(!value.contains(NetworkPresenceSession.serviceType),
                        "\(record.event).\(contextKey) carries the endpoint id it was built from")
            }
        }
        #expect(NetworkPresenceSession().peerLabel(for: key) != label,
                "an unsalted digest is recomputable by anyone who can hash — no fix at all")
    }

    /// **The manager reaches the air through the seam alone, and names no retired radio.**
    ///
    /// Rule 7's mechanical half for item 2: pass 1 changed nothing on the air, so the only proof
    /// that pass 2 ran is that the MultipeerConnectivity path is gone from this file and the QUIC
    /// seam is in it. Pinned in both directions — a file naming neither has been renamed or emptied,
    /// not cleaned — and widened past the unit cell's single file to a walk of the whole package, so
    /// an `extension PresenceManager` in a new file cannot reintroduce a needle silently.
    @Test func theManagerNamesNoRetiredRadioAndReachesTheAirThroughTheSeamAlone() throws {
        let manager = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.presenceManagerPath))
        // R2: bounded by the retired-radio spellings.
        for needle in ["MeshMultipeerSession", "MCPeerID", "MCSession", "MultipeerConnectivity",
                       "PeerChannelTransport", "updateDiscoveryInfo", "serviceType"] {
            #expect(!manager.contains(needle), "PresenceManager still names `\(needle)` in code")
        }
        #expect(manager.contains("PresenceRadioSession"), "and it drives the QUIC presence seam")
        #expect(manager.contains("NetworkPresenceSession"), "whose production conformer it builds")
        #expect(manager.contains("presencePosture"), "wearing the posture pass 1 built")

        let kit = try MeshP7Acceptance.sources(under: "FernletKit/Sources/ProximityKit")
        // Anti-vacuity floors, RE-MEASURED at item 9's fix review (NOTE 4) and set within ~20%
        // of reality rather than at a round 100: 143 files here. A floor a deleted third of the
        // package still clears is a floor that cannot fail.
        #expect(kit.count >= 120, "the ProximityKit scan lost its files (143 when this was measured)")
        #expect(Set(MeshP7Acceptance.homes(of: "PresenceRadioSession", in: kit))
                == ["PresenceManager.swift", "NetworkPresenceSession.swift"], """
                the presence seam has exactly two homes in the package — the manager that drives it \
                and the conformer that is it. A third is a second owner for one radio
                """)
        #expect(MeshP7Acceptance.homes(of: "PresenceEpochPosture.minted", in: kit) == ["PresenceManager.swift"],
                "and the posture is minted from one place: the manager's own epoch tick")
    }
}

// MARK: - (c) The recipe swap, with pause/resume

/// This battery's OWN expectation of item 3's discovery gate, **EVENT-outermost**.
///
/// A second decomposition of the same sixty cells, deliberately. The shipped gate switches on the
/// event and then guards on the radio's three facts; the unit suite walks a cross product and
/// compares against a predicate written the same way round. These are neither: two per-event
/// helpers, each spelling **all twelve radio readings as its own literal row**, no guard chain, no
/// `default` — which is why ``Held`` exists at all, so `(Bool, Bool, Held)` is exhaustive without
/// one. A sweep that rewrites the production guard finds no identically-shaped twin here, and a
/// gate and a unit oracle edited together still redden against these literals.
///
/// Written from the type's documented two rules, never by calling either of the other two:
/// *resume is keyed on manager-level RECORD eviction, never on a transport disconnect event*, and
/// *a stopped radio never resumes*.
enum MeshP9GateExpectation {

    /// How many connection records the radio holds AFTER the event, as three values rather than an
    /// `Int`, so every helper below is exhaustive without a `default` — a `default` is where a
    /// drifted row hides.
    enum Held: CaseIterable {

        /// The radio holds nothing.
        case none

        /// One pairing: the shipped 2-device cap's normal state.
        case one

        /// Two — over the cap, and the reading a re-entrant register produces.
        case two

        /// The `Int` the shipped ``RecipeShareDiscoveryGate/Radio`` takes.
        var count: Int {
            switch self {
            case .none: return 0
            case .one: return 1
            case .two: return 2
            }
        }
    }

    /// `connectionRegistered`, as twelve literal rows.
    ///
    /// Note what is NOT consulted: `isRunning`. A register arrives from `registerConnection`, which
    /// only runs on a radio that is up; refusing it on a dark manager would be a second owner for
    /// the same fact. The asymmetry with ``evicted(_:_:_:)`` below is real and is pinned here.
    static func registered(_ running: Bool, _ paused: Bool, _ held: Held) -> RecipeShareDiscoveryGate.Verdict {
        switch (running, paused, held) {
        case (true, false, .none): return .unchanged
        case (true, false, .one): return .pause
        case (true, false, .two): return .pause
        case (true, true, .none): return .unchanged
        case (true, true, .one): return .unchanged
        case (true, true, .two): return .unchanged
        case (false, false, .none): return .unchanged
        case (false, false, .one): return .pause
        case (false, false, .two): return .pause
        case (false, true, .none): return .unchanged
        case (false, true, .one): return .unchanged
        case (false, true, .two): return .unchanged
        }
    }

    /// `connectionsEvicted`, as twelve literal rows: exactly one reopens the radio.
    ///
    /// `isRunning` IS consulted here, because a resume over a stopped radio would put a Bonjour
    /// registration and a QUIC listener back up behind a manager that believes it is dark.
    static func evicted(_ running: Bool, _ paused: Bool, _ held: Held) -> RecipeShareDiscoveryGate.Verdict {
        switch (running, paused, held) {
        case (true, true, .none): return .resume
        case (true, true, .one): return .unchanged
        case (true, true, .two): return .unchanged
        case (true, false, .none): return .unchanged
        case (true, false, .one): return .unchanged
        case (true, false, .two): return .unchanged
        case (false, true, .none): return .unchanged
        case (false, true, .one): return .unchanged
        case (false, true, .two): return .unchanged
        case (false, false, .none): return .unchanged
        case (false, false, .one): return .unchanged
        case (false, false, .two): return .unchanged
        }
    }

    /// The other three events, whose whole content is that they move discovery at no reading at all:
    /// `refreshRequested`, `transportErrorWhileListening` and `stopped` all resolve through the
    /// radio's own `stop()` / `start()`, which clears the paused flag in the transport. Routing one
    /// through the gate too would give one state two owners.
    static func stationary(_ running: Bool, _ paused: Bool, _ held: Held) -> RecipeShareDiscoveryGate.Verdict {
        .unchanged
    }

    /// This expectation's verdict for one event against one reading.
    static func verdict(
        _ event: RecipeShareDiscoveryGate.Event, _ running: Bool, _ paused: Bool, _ held: Held
    ) -> RecipeShareDiscoveryGate.Verdict {
        switch event {
        case .connectionRegistered: return registered(running, paused, held)
        case .connectionsEvicted: return evicted(running, paused, held)
        case .refreshRequested, .transportErrorWhileListening, .stopped:
            return stationary(running, paused, held)
        }
    }
}

/// **Item 3: the recipe radio on QUIC with the shipped pause/resume behaviour intact.** The whole
/// gate product against this battery's own literal table, a pause that leaves a share in flight
/// alone, the exactly-once completion, the per-`start()`/`resume()` posture, the service type's own
/// declaration, and the one door discovery moves through.
@MainActor
@Suite(.serialized)
struct MeshP9RecipeSwapAcceptanceTests {

    /// **The whole 5 × 12 product, re-walked against this file's own literals.**
    ///
    /// "The radio closes once two devices connect" is a shipped, user-visible behaviour: while a
    /// pairing is held this device can neither be seen nor invited by a third Fernlet. That is
    /// exactly the kind of behaviour a transport swap loses silently — the bytes still flow, the
    /// share still lands, and the only symptom is a third device that can suddenly see a paired one.
    @Test func theWholeDiscoveryGateProductAgreesWithThisBatterysOwnExpectation() {
        let events: [RecipeShareDiscoveryGate.Event] = [
            .connectionRegistered, .connectionsEvicted, .refreshRequested,
            .transportErrorWhileListening, .stopped
        ]
        var walked = 0
        var moved = 0
        // R2: bounded by five events × two × two × three readings.
        for event in events {
            for running in [true, false] {
                for paused in [true, false] {
                    for held in MeshP9GateExpectation.Held.allCases {
                        let radio = RecipeShareDiscoveryGate.Radio(
                            isRunning: running, isPaused: paused, connectionCount: held.count)
                        let shipped = RecipeShareDiscoveryGate.verdict(for: event, radio: radio)
                        let expected = MeshP9GateExpectation.verdict(event, running, paused, held)
                        #expect(shipped == expected, """
                            \(event) on running=\(running) paused=\(paused) held=\(held.count): \
                            the gate says \(shipped), this battery's own table says \(expected)
                            """)
                        walked += 1
                        if shipped != .unchanged { moved += 1 }
                    }
                }
            }
        }
        #expect(walked == 60, "the product walked \(walked) rows, not the whole 5 × 12")
        #expect(moved == 5, """
            discovery moves at exactly five of sixty readings — four registers and one eviction. \
            A sixth is a door that opens or closes somewhere nobody decided it should
            """)
    }

    /// **A share in flight is untouched by the very event that closes the door behind it, a record
    /// minted under a paused radio is born quiet, and a completion is counted exactly once.**
    ///
    /// Three claims that fail three different ways. Under MultipeerConnectivity `pauseDiscovery()`
    /// stopped the advertiser and browser while every live connection kept flowing; a QUIC session
    /// implementing "pause" as standing the connection down would break a send MC keeps alive, and
    /// the regression would look like a flaky share rather than a transport change. The birth seed
    /// is item 3 pass 1's own defect: `radioIsQuiet` mirrored the pause but only the gate's
    /// transitions wrote it, so a transfer minted while the radio was ALREADY paused carried `false`
    /// for its whole life — so this cell mints UNDER the level it claims to mirror.
    @Test func aPauseLeavesAShareInFlightAloneAndACompletionIsCountedOnce() {
        let rig = MeshP9Acceptance.recipeRig()
        rig.radio.pauseDiscovery()
        rig.manager.beginTransferForTesting(recipientID: UUID())
        #expect(rig.manager.transferForTesting?.radioIsQuiet == true,
                "a record minted under a paused radio was born claiming the door was open")

        rig.manager.applyTransferForTesting(.peerVerified)
        rig.manager.applyTransferForTesting(.sendBegan(wireByteCount: 900_000))
        #expect(rig.manager.transferForTesting?.phase == .sending)
        #expect(rig.manager.applyDiscoveryGateForTesting(.connectionsEvicted) == .resume)
        #expect(rig.radio.isDiscoveryPaused == false, "the eviction reopened the door")
        #expect(rig.manager.transferForTesting?.phase == .sending, "a resume moved a share in flight")
        #expect(rig.manager.transferForTesting?.wireByteCount == 900_000, "a resume restarted the share")
        #expect(rig.manager.transferForTesting?.radioIsQuiet == false, "and told it the door moved")

        // And now the PAUSE, over that same in-flight record — the event this cell is named for,
        // and the one the rig could not reach by calling `pauseDiscovery()` by hand (item 9's fix
        // review, FIX 2: the cell used to drive only the eviction, and a `.discoveryPaused` that
        // moved a `.sending` phase would have stayed green). The gate answers `.pause` only for
        // `.connectionRegistered` on a radio already holding a record, and only the production
        // add-path mints one: `makeRetainedConnectionCoordinatorForTesting` IS that path — it
        // calls the private `registerConnection` — so `session.pauseDiscovery()` and
        // `applyTransfer(.discoveryPaused)` run here exactly as a real pairing runs them.
        let peer = PeerHandle(id: UUID(), displayHint: "fernlet-recipe-acceptance",
                              discoveryInfo: nil, advertisedFingerprint: nil)
        _ = rig.manager.makeRetainedConnectionCoordinatorForTesting(
            peer: peer, transport: MockMultipeerTransport(), ranging: MockRangingProvider())
        #expect(rig.manager.connectionCountForTesting == 1, "the add-path held one connection")
        #expect(rig.radio.isDiscoveryPaused, "a registered connection closes the door behind it")
        #expect(rig.radio.pauseCount == 2, "the door shut twice: once by hand, once through the gate")
        #expect(rig.manager.transferForTesting?.phase == .sending,
                "the very event that closes the door moved the share it closed the door behind")
        #expect(rig.manager.transferForTesting?.wireByteCount == 900_000, "a pause restarted the share")
        #expect(rig.manager.transferForTesting?.radioIsQuiet == true, "and told it the door moved")

        // The exactly-once oracle, on the value: `completionCount` can only be 0 or 1, and is 1
        // exactly when the phase is `.sent`. `apply` is mutating, so each call is bound to a `let`
        // first — `#expect` cannot hold a mutating call.
        var transfer = RecipeShareTransfer(recipientID: UUID(), radioIsQuiet: true)
        let verified = transfer.apply(.peerVerified)
        let began = transfer.apply(.sendBegan(wireByteCount: 64))
        let completed = transfer.apply(.sendCompleted)
        #expect(verified && began && completed, "the legal arc must be taken")
        #expect(transfer.phase == .sent)
        #expect(transfer.completionCount == 1)
        let again = transfer.apply(.sendCompleted)
        #expect(!again, "a second completion is refused, not overwritten")
        #expect(transfer.completionCount == 1, "so the count is an oracle, not a counter")
    }

    /// **A resume mints a wholly fresh posture, and a stopped radio keeps none — including the
    /// pause flag.**
    ///
    /// The recipe radio's lifetime is a Food-tab visit, so "resume" is a NEW registration under a
    /// new name, a new session id and a new certificate — not the old one put back. And a `stop()`
    /// that left `isDiscoveryPaused` set would bring the radio back up dark on the next visit, with
    /// nothing in the manager's state to explain it.
    @Test func aResumeMintsAWhollyFreshPostureAndAStopKeepsNoPause() throws {
        let radio = NetworkRecipeShareSession()
        let first = try radio.runWithoutRadiosForTesting()
        radio.pauseDiscovery()
        #expect(radio.isDiscoveryPaused)
        #expect(radio.advertisedInstanceNameForTesting == first.instanceName,
                "a pause stands discovery down and keeps the posture")

        radio.resumeDiscovery()
        let second = try #require(radio.advertisedInstanceNameForTesting)
        #expect(second != first.instanceName, "a resume re-registers under a name nobody has seen")
        #expect(radio.advertisedCertificateForTesting != first.tlsIdentity.certificateDER,
                "and a certificate nobody has seen")
        #expect(radio.isDiscoveryPaused == false)

        radio.stop()
        #expect(radio.isDiscoveryPaused == false, "a stopped radio must not come back up holding a pause")
        #expect(radio.advertisedInstanceNameForTesting == nil, "and it keeps no posture")
        #expect(radio.advertisedSessionID.isEmpty, "nor a session id")
        _ = try radio.runWithoutRadiosForTesting()
        #expect(radio.isDiscoveryPaused == false, "the restart is open")
    }

    /// **The recipe radio is its own service, binds its own ALPN, and its predecessor is off the
    /// air.**
    ///
    /// A shared ALPN would let a recipe dial complete a TLS handshake with a mesh or presence
    /// listener; a missing `NSBonjourServices` entry kills discovery on device with no log and no
    /// observable state.
    @Test func theRecipeRadioIsItsOwnServiceAndItsPredecessorIsOffTheAir() throws {
        #expect(NetworkRecipeShareSession.serviceType == "_fernlet-recipe2._udp")
        #expect(NetworkRecipeShareSession.alpn == "fernlet-recipe-v1")
        #expect(NetworkRecipeShareSession.serviceType != NetworkMeshSession.friendServiceType)
        #expect(NetworkRecipeShareSession.serviceType != NetworkPresenceSession.serviceType)
        #expect(NetworkRecipeShareSession.alpn != NetworkMeshSession.alpn)
        // Parsed, not grepped — the same reader clause (b) and clause (d) use (NOTE 3).
        let declared = try NoTrackingBoundaryTests.declaredBonjourServiceTypes()
        #expect(declared.contains(NetworkRecipeShareSession.serviceType),
                "the QUIC recipe type is declared — without it discovery dies silently on device")
        // R2: bounded by the retired recipe pair.
        for retired in ["_fernlet-recipe._tcp", "_fernlet-recipe._udp"] {
            #expect(!declared.contains(retired),
                    "`\(retired)` is still declared — no radio has advertised it since pass 2 crossed")
        }
        let session = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.recipeSessionPath))
        #expect(session.contains("alpn: Self.alpn"), "the session must actually bind its ALPN")
        #expect(NetworkRecipeShareSession.maxTunnels == 1,
                "the shipped 2-device cap is what the pause/resume contract exists to preserve")
    }

    /// **Discovery moves through the gate alone, and no file of the subtree names the retired
    /// radio.**
    ///
    /// The containment pairing, not text proximity: `occurrences(verb) == 1` alone stayed green when
    /// the call was moved OUT of `applyDiscoveryGate`, so the whole-file count is paired with the
    /// count inside the function's brace-matched body. And the unit is the SUBTREE, not one file —
    /// an `extension ProximityRecipeShareManager` in a new file reintroduces every needle without
    /// reddening a scan of the manager alone.
    ///
    /// Rule 7 for item 3: `RecipeShareRadioSession` / `NetworkRecipeShareSession` in the manager are
    /// false at `79f6b15` and true at `ba34491`.
    @Test func discoveryMovesThroughTheGateAloneAndNoRecipeFileNamesTheRetiredRadio() throws {
        let manager = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(MeshP9Acceptance.recipeManagerPath))
        let gate = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func applyDiscoveryGate(", in: manager),
            "applyDiscoveryGate is gone — the discovery contract has no door")
        // R2: bounded by the two discovery verbs.
        for verb in ["session.pauseDiscovery()", "session.resumeDiscovery()"] {
            let whole = manager.components(separatedBy: verb).count - 1
            let inside = gate.components(separatedBy: verb).count - 1
            #expect(whole == 1, "\(verb) is called \(whole) times; the gate is the one door")
            #expect(inside == whole, "\(verb) is called outside applyDiscoveryGate's own body")
        }
        #expect(manager.contains("RecipeShareRadioSession"), "the manager drives the QUIC seam")
        #expect(manager.contains("NetworkRecipeShareSession"), "whose production conformer it builds")

        // The BIRTH SEED has one mint site (item 9's fix review, FIX 3). `beginTransferForTesting`
        // is what every cell of this battery and of `RecipeShareTransferTests` drives;
        // `sendRecipeShare` is what ships, and nothing at tier 1 executes it — so while the seed
        // was spelled twice, item 3 pass 1's own defect (`radioIsQuiet: false` on the shipping
        // line) could be restored with the whole tree green. Containment, not proximity: the
        // shipping door's brace-matched body must call the helper, and the record may be
        // constructed in exactly one place.
        let send = try #require(
            MeshRoutedSourceScan.bracedBody(after: "public func sendRecipeShare(", in: manager),
            "the recipe share's shipping door is gone")
        #expect(send.contains("mintTransfer(for: recipient.id)"), """
            sendRecipeShare mints its exchange record somewhere other than the one seeded helper — \
            which is how the shipping seed and the seed every test drives came apart before
            """)
        let mints = manager.components(separatedBy: "RecipeShareTransfer(recipientID:").count - 1
        #expect(mints == 1, "the exchange record is constructed in \(mints) places; the helper is the one")

        let subtree = try MeshP7Acceptance.sources(under: "FernletKit/Sources/ProximityKit/RecipeSharing")
        #expect(subtree.count == 3, """
            the RecipeSharing subtree holds \(subtree.count) files, not the three it held when this \
            was measured (the manager, the advertisement and the transfer record). A fourth is a \
            file this cell's retired-radio walk has never been read against; a third gone is a \
            scan that lost its root. EXACT on purpose — `>= 3` was satisfied by the tree it was \
            written against and by every tree that could ever follow it
            """)
        // R2: bounded by the retired-radio spellings × the subtree's files.
        for needle in ["MeshMultipeerSession", "MCPeerID", "MCSession", "MultipeerConnectivity",
                       "PeerChannelTransport", "displayHint"] {
            let homes = Set(MeshP7Acceptance.homes(of: needle, in: subtree)).sorted()
            #expect(homes.isEmpty, "`\(needle)` is back in the recipe subtree, in \(homes)")
        }
    }
}

// MARK: - (d) The MultipeerConnectivity retirement — an HONESTY row, not a zero-list

/// **Item 4 — the zero-list, at last.**
///
/// The launcher's row asked for "the MC retirement as a zero-list". When this battery landed it could
/// not be one: `MeshTransportFactory.shippingDefault` was `.multipeer` and first-meeting stranger
/// admission had no QUIC path, so both facts were pinned as the ARGUMENT for keeping the files. The
/// owner then took **D-4.3 (Option 1)** and the **flip** landed (2026-09-21); the two files, the
/// `_fernlet-friend` plist pair and `TransportNeutralityBoundaryTests.permittedFiles` were held one
/// round longer as a DEBUG bisect path; the unseeded Lane C pair run then observed the provisional
/// path founding a mesh on a real tunnel (2026-09-22, the deletion round's item 0); and the
/// **deletion** landed the same day. Every cell below now asserts the zero it was written to become,
/// in both directions: the files ABSENT, the framework imported NOWHERE, the friend pair RETIRED
/// and the three QUIC types still declared, and the one default left — the initializer's
/// `NetworkMeshSession()` — named in source.
///
/// **Still not a wall that lies.** A zero that is not zero cannot be written, and 9.4-NOW's own
/// verify caught exactly that shape (a cell pinning four strings absent and forgetting the two a
/// shipping radio still needed) — so the presence half of the Bonjour cell is kept, over the three
/// QUIC types, and the record-survival cell keeps the decision trail readable.
@Suite(.serialized)
struct MeshP9McRetirementAcceptanceTests {

    /// **Both MultipeerConnectivity files are gone, and the selection seam went with them.**
    ///
    /// The zero-list half of item 4, in both directions. The two files are pinned ABSENT (a
    /// re-created one reddens here with the deletion checklist in reverse); the selection seam that
    /// existed only to choose between two radios — `MeshTransportKind`, `MeshTransportFactory`, the
    /// `quicSelectionEnvironmentKey` read, the MC conformance — is pinned OUT of
    /// `MeshTransportSelection.swift` by identifier; and the one default the deletion left is pinned
    /// IN by its source text: `MeshNetworkManager.init`'s `transport ?? NetworkMeshSession()`, the
    /// line the survey called "the cutover" (its VALUE is `MeshTransportSelectionTests`'
    /// `theAppsInitializerRunsOnTheQUICRadio`).
    ///
    /// The stranger-admission needle stays, unchanged: D-4.3's refusal-made-CONDITIONAL is what let
    /// the deletion ship without losing first-meeting founding, and the unseeded pair run of
    /// 2026-09-22 is its tier-2 observation. Widening it further is a second decision, and it must
    /// not land silently either.
    @MainActor
    @Test func theMultipeerFilesAreGoneAndTheSelectionSeamWithThem() throws {
        // R2: bounded by the two deleted files.
        for path in MeshP9Acceptance.multipeerFiles {
            #expect(!FileManager.default.fileExists(atPath: RepoRoot.url(path).path), """
                \(path) is back in the tree. MultipeerConnectivity was deleted in the deletion round \
                (2026-09-22) after the flip (2026-09-21) and the unseeded Lane C observation; \
                re-adding the radio is a phase decision that owes the permit list, the plist pair, \
                the CI name count and this cell in the same commit — it is not a fix for a red
                """)
        }
        let manager = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift"))
        #expect(manager.contains("transport ?? NetworkMeshSession()"), """
            MeshNetworkManager.init no longer defaults its radio to `NetworkMeshSession()` directly. \
            There is no selection seam left to route through: a second radio, a factory or a launch \
            variable here is the seam the deletion round removed coming back
            """)
        let seam = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source(MeshP9Acceptance.transportSelectionPath))
        // R2: bounded by the four retired identifiers.
        for retired in ["MeshTransportKind", "MeshTransportFactory", "quicSelectionEnvironmentKey",
                        "MeshMultipeerSession"] {
            #expect(!seam.contains(retired), """
                `\(retired)` is back in MeshTransportSelection.swift. The selection seam retired with \
                the second radio (Variant A of the survey's patch); `MeshTransportSession` and \
                `MeshPeerChannel` are the whole surface now
                """)
        }
        // The second reason, at the line that enforces it rather than in the note that states it.
        //
        // **The needle MOVED on 2026-09-21, deliberately, and this is the argument.** It used to be
        // the unconditional `case .stranger: return .unknownIdentity` — the "stranger admission has
        // no QUIC path" half of the split, kept so loosening it could not land silently. The owner
        // took D-4.3 (Option 1) on the stranger-admission design's recommendation, so it has now
        // landed, and it did not land silently: it landed here. What replaces it is the same
        // refusal with the ONE condition the decision added — a stranger is refused unless the
        // owner's join doors are open — so the needle still fails if the arm is deleted, if it
        // stops naming a refusal, or if the refusal stops being the default. What it no longer
        // claims is that the QUIC radio is members-only before any app frame, because it is not:
        // see `MeshIntroductionRoster.admitsStrangersProvisionally` and the amendment to plan
        // §7.2's "non-roster member" bullet recorded on `MeshIntroductionAuthority`'s scope
        // paragraph. Observed on a real tunnel on 2026-09-22 (the runbook's "Lane C — the deletion
        // round's item 0").
        let introduction = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Transport/MeshChannelIntroduction.swift"))
        #expect(
            introduction.contains("guard roster.admitsStrangersProvisionally else { return .unknownIdentity }"),
            """
            the QUIC channel introduction no longer refuses a peer the roster calls a stranger \
            BY DEFAULT. Since D-4.3 the refusal is conditional on the owner's join doors being \
            open, and `unknownIdentity` must stay the answer when they are shut — widening it \
            further is a second decision, and it must not land silently either
            """
        )
    }

    /// **The framework import has no home, and no framework type is named anywhere in the package or
    /// the app.**
    ///
    /// `TransportNeutralityBoundaryTests` makes the same claim through a permit list it scans
    /// against — empty since the deletion round; this is a second decomposition of it — the *claim*
    /// is re-spelled as a literal empty home list here, the *walker* is
    /// `MeshP7Acceptance.sources(under:)` and is never forked. Both halves are needed: the wall's
    /// list went to `[]` in the same commit as the files, and a battery that called into it would
    /// have gone green the moment the list did whatever the tree held.
    ///
    /// Note the walk is over comment-STRIPPED sources. Prose about MultipeerConnectivity is fine and
    /// deliberately so — "what the retired MC advertiser could not do" is the sentence that explains
    /// why the ephemeral posture exists at all.
    @Test func theFrameworkImportHasNoHomeAndNoFrameworkTypeIsNamed() throws {
        let kit = try MeshP7Acceptance.sources(under: "FernletKit/Sources/ProximityKit")
        let app = try MeshP7Acceptance.sources(under: "App/Fernlet")
        // MEASURED floors (NOTE 4): 141 and 179 files after the deletion. See clause (b) for why not 100.
        #expect(kit.count >= 120, "the ProximityKit scan lost its files (141 when this was measured)")
        #expect(app.count >= 140, "the app-target scan lost its files (179 when this was measured)")
        let homes = Set(MeshP7Acceptance.homes(of: "import MultipeerConnectivity", in: kit + app)).sorted()
        #expect(homes.isEmpty, """
            MultipeerConnectivity is imported in \(homes). The framework left the tree in the \
            deletion round (2026-09-22); a new import is a new dependency on a retired radio, and \
            TransportNeutralityBoundaryTests.permittedFiles (empty) reddens on it in the same run
            """)
        // The type check is deliberately narrower than the import check: these three names have no
        // Fernlet-owned prefix collision anywhere, so a substring walk is sound for them, and the
        // WHOLE-identifier wall (`TransportNeutralityBoundaryTests`) covers the rest.
        // R2: bounded by the three unambiguous framework type names.
        for symbol in ["MCNearbyServiceAdvertiser", "MCNearbyServiceBrowser", "MCSessionState"] {
            let anywhere = Set(MeshP7Acceptance.homes(of: symbol, in: kit + app)).sorted()
            #expect(anywhere.isEmpty, "`\(symbol)` is named in \(anywhere); the framework is gone")
        }
    }

    /// **The six retired Bonjour strings are gone and the three QUIC ones are still declared.**
    ///
    /// Pinned in BOTH directions, because the failure mode that actually ships is a deleted line,
    /// not a surviving one: a missing service type kills discovery silently on device — no log, no
    /// observable state, no other test — and 9.4-NOW's first cut pinned the four dead strings absent
    /// while forgetting the two the shipping mesh still used. `_fernlet-friend._{tcp,udp}` stayed in
    /// ``MeshP9Acceptance/liveBonjour`` through the flip (a DEBUG bisect launch still browsed them)
    /// and moved to ``MeshP9Acceptance/retiredBonjour`` in the deletion round (2026-09-22), in the
    /// same commit that removed the radio and the plist entries — a deliberate act, never a side
    /// effect. `NoTrackingBoundaryTests` carries the same partition, the same way, and moved in the
    /// same commit.
    ///
    /// The three sets are this battery's OWN literals (`MeshP9Acceptance.retiredBonjour` /
    /// `.liveBonjour` / `.heldBonjour`); only the plist READER is shared with
    /// `NoTrackingBoundaryTests`, which is the right seam to share — parsing is mechanics, the
    /// partition is the claim.
    @Test func theSixRetiredBonjourStringsAreGoneAndTheThreeQUICOnesAreDeclared() throws {
        let declared = try NoTrackingBoundaryTests.declaredBonjourServiceTypes()
        #expect(!declared.isEmpty, "the plist declared no NSBonjourServices — the reader is broken, not the plist clean")

        let stale = MeshP9Acceptance.retiredBonjour.intersection(declared).sorted()
        #expect(stale.isEmpty, """
            \(stale) is still declared: a service type no radio has advertised or browsed since P9 \
            items 2 and 3 crossed to QUIC (near, recipe) or since the deletion round removed the \
            MultipeerConnectivity mesh radio (friend). Removing one owes the matching §4c row in \
            Docs/No-Tracking-Wall.md in the same commit
            """)
        let missing = MeshP9Acceptance.liveBonjour.subtracting(declared).sorted()
        #expect(missing.isEmpty, """
            \(missing) is no longer declared — a type a reachable radio advertises or browses. \
            Discovery dies silently on device with no log, no observable state and no other \
            failing test; this is the bug a retirement must not cause
            """)
        let unclassified = declared
            .subtracting(MeshP9Acceptance.liveBonjour)
            .subtracting(MeshP9Acceptance.heldBonjour)
            .subtracting(MeshP9Acceptance.retiredBonjour)
            .sorted()
        #expect(unclassified.isEmpty, """
            \(unclassified) is declared and classified by none of the three sets — a local-network \
            radio nobody reviewed, or a spelling that drifted
            """)
        #expect(declared.count == MeshP9Acceptance.liveBonjour.count + MeshP9Acceptance.heldBonjour.count,
                "the plist declares exactly the live three and the held two: \(declared.sorted())")
    }

    /// **The cutover was the owner's decision, and the record of it — question AND answer — is
    /// still in the tree.**
    ///
    /// The three cells above assert a state; this one asserts that the *reason* for the state
    /// survives. A design note deleted or a ledger row quietly flipped to `done` would leave the
    /// pins above looking like ordinary walls rather than a decision somebody took, and §17.1
    /// would read as fully BUILT when it is not.
    ///
    /// **Widened at the flip (2026-09-21), not narrowed.** The survey's four labels still have to
    /// survive — they are the question — and the cutover ledger's three ANSWERS now have to survive
    /// beside them: D-4.3 taken as Option 1, D-4.4 taken as the pure retire (against the survey's
    /// own recommendation, which is exactly the kind of thing that gets quietly re-written back),
    /// and the series' split that says the two MC files outlive this commit. No cell was added:
    /// widening the one that already reads the record is cheaper than a second reader of the same
    /// two files, and it keeps the count on the mesh line where it was.
    @Test func theCutoverIsAnOwnerDecisionAndTheRecordOfItSurvives() throws {
        let design = try RepoRoot.source("Docs/Mesh-P9-Item4-Design-2026-09-20.md")
        // R2: bounded by the four decision labels.
        for decision in ["D-4.1", "D-4.2", "D-4.3", "D-4.4"] {
            #expect(design.contains(decision), "the item 4 design note lost decision \(decision)")
        }
        #expect(design.contains("stranger admission"), """
            the note's whole argument is that first-meeting stranger admission has no QUIC path — \
            without that sentence the split reads as procrastination
            """)
        let ledger = try RepoRoot.source("Docs/Mesh-Migration-Loop-Ledger-P9.md")
        #expect(ledger.contains("9.4-LATER"), "the ledger no longer carries the deferred half")
        #expect(ledger.contains("blocked (owner)"), "nor that it is the owner's to unblock")
        // The ANSWERS, in the round that took them. Added at the flip.
        let cutover = try RepoRoot.source("Docs/Mesh-Migration-Loop-Ledger-Cutover-2026-09-21.md")
        #expect(cutover.contains("TAKEN — Option 1"), """
            the cutover ledger no longer records D-4.3 as taken. The flip above is only legitimate \
            because the owner answered; an unrecorded answer makes every value pin in this suite \
            look like somebody's preference
            """)
        #expect(cutover.contains("PURE RETIRE"), """
            nor D-4.4. The owner chose the pure retire AGAINST the survey's recommendation — the \
            wipe leg is gone and a pre-flip install's FernletPeerID.archive is left behind by \
            delete-all — and that is the decision most likely to be silently un-made by a later \
            reader who only finds the survey
            """)
        #expect(cutover.contains("Flip, gate, then delete"), """
            nor the series' split, which is why the two MC files above are still here after the \
            flip. Without it this suite reads as a cutover somebody half-finished
            """)
        let plan = try RepoRoot.source("Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md")
        #expect(plan.contains("§17.1") || plan.contains("17.1"), "plan §17.1 is P9's specification")
    }
}

// MARK: - (e) Honesty

/// **What P9's battery cannot run, named rather than implied.**
///
/// Named `…HonestyAcceptanceTests`, not the launcher's `MeshP9CIHonestyTests`:
/// `CIGateSelectorBoundaryTests.isMeshBattery` only auto-demands a gate for a suite whose name has
/// the prefix `MeshP<digit>` AND the suffix `AcceptanceTests`, so the launcher's spelling matches
/// neither half and nothing would ever require this suite to be on a workflow line — exactly the
/// hole P9 item 6's verify found for the fourteen, re-dug by a name.
///
/// Every row below is an assertion over a **documented list**: the doc section, ledger row or
/// design note that records the unrun claim must still be there, so deleting the record reddens.
/// That is the P8 shape and the reason for it — an honesty suite that merely *said* "we did not run
/// X" in a comment would go stale silently, and a phase would look more proven than it is.
///
/// Six things P9 genuinely did not prove, in six different ways:
/// 1. **Two lane rows** (9.2.2, 9.3.2) are tier-2 sim↔sim observations. They PASSED, on Simulators,
///    by hand — CI has no second Simulator and no radio, so nothing here re-runs them.
/// 2. **Item 0's device rows** need two to four phones in the owner's hands and are `blocked
///    (owner)` for the whole phase. Plan §15 is still P8's unpaid gate.
/// 3. **Three rows nothing has ever observed**, Simulator or otherwise: the `.remove` → republish
///    branch, `openTransferCount` returning to 0, and a share in flight DURING a glare collapse.
/// 4. **Two owner decisions**: P9-3-A (a configured Fernlet Lock parks both 1:1 radios permanently —
///    pre-existing, and a run-policy row is a P7 bug fix, not a P9 edit) and 9.4-LATER's D-4.1/D-4.3.
/// 5. **Eight P9-touched suites CI does not run**, each with its reason in ``ungatedByDesign`` —
///    seven timed weak-reference polls and item 1's own wall. It was ELEVEN until P10 item 5: the
///    three routed behaviour suites item 7 only re-scoped are on the mesh line now, and their rows
///    left that map in the same commit. The accounting over them is total, so a ninth cannot
///    appear quietly.
/// 6. **Two coverage holes of this phase's own walls**: item 8's ratchet is checked for staleness
///    on CI and for accuracy nowhere (the UI target never runs there), and TWENTY unscoped
///    `count(of:)` audit reads survive item 7's sweep and P10 item 5's — a ratchet, not a zero.
@Suite(.serialized)
struct MeshP9HonestyAcceptanceTests {

    /// Every suite declared in a test file P9 edited, frozen as STRUCT names.
    ///
    /// DERIVED at item 9's fix review (2026-09-20), never remembered:
    /// `git diff --name-only bb454fe..HEAD -- Tests/FernletTests` (bb454fe is P8's close) gives the
    /// eighteen files the phase edited, and each file's top-level declarations holding at least one
    /// `@Test` are these forty-nine. **Declarations, not files**: `-only-testing:` names a STRUCT,
    /// and `NetworkMeshTransportTests.swift` alone declares sixteen suites and no type of that name
    /// at all — a workflow line naming the file would match nothing and pass having run zero tests,
    /// which is exactly what the first cut of this cell (a hand-list of seven) could not see.
    ///
    /// A literal rather than a walk: re-deriving it would need git at test time, and walking the
    /// whole tree would stop it being about P9. So adding a suite to one of these files reds
    /// nothing by itself — the next phase's battery derives its own list — but renaming, moving or
    /// deleting one of these does, because every name here is asserted to be a declared type.
    static let p9TouchedSuites: [String] = [
        "AuditRatchetBoundaryTests", "CIGateSelectorBoundaryTests", "EphemeralMeshTLSIdentityTests",
        "LocalOnlyPersistentHistoryPruneTests", "MeshChannelIntroductionTests",
        "MeshChannelIntroductionTranscriptTests", "MeshContinuationTaskHostTests",
        "MeshContinuationTaskHostWallTests", "MeshDialPreferenceTests",
        "MeshEvictionReleasesTransportLinkTests", "MeshHeartbeatLivenessTests",
        "MeshHeartbeatScheduleTests", "MeshInboundRankingTests", "MeshIntroductionNonceCacheTests",
        "MeshIntroductionRosterTests", "MeshKeyAdvertisementDeliveryTests",
        "MeshLinkAdvertisementTests", "MeshLinkTableTests",
        "MeshP9EphemeralPostureAcceptanceTests", "MeshP9HonestyAcceptanceTests",
        "MeshP9McRetirementAcceptanceTests", "MeshP9PresenceSwapAcceptanceTests",
        "MeshP9RecipeSwapAcceptanceTests", "MeshRoutedBackpressureTests", "MeshRoutedDrainTests",
        "MeshRoutedDrainWallTests", "MeshRoutedParkedDropDoorTests", "MeshRoutedPhotoDeliveryTests",
        "MeshRoutedPhotoSenderTests", "MeshTransferStreamTableTests", "MeshTunnelConvergenceTests",
        "MeshTunnelEndReasonTests", "NetworkMeshSessionTests", "NetworkMeshWireTests",
        "NoTrackingBoundaryTests", "ObservationLoopLifecycleTests", "PersistenceFailureAuditTests",
        "PhotoWallPreferencePruneTests", "PresenceAdvertisementTests", "PresenceEpochPostureTests",
        "PresenceManagerTests", "PresenceOverQUICTests", "PresenceReleaseTests",
        "ProximityManagerDeallocationTests", "ProximityRecipeShareCapTests",
        "RecipeShareOverQUICTests", "RecipeShareTeardownTests", "RecipeShareTransferTests",
        "RoutedDeliveryHoldCopyTests"
    ]

    /// The P9-touched suites this commit deliberately leaves on no CI line, each with its reason.
    ///
    /// The honesty half of ``everyP9TouchedSuiteIsEitherGatedOrNamedAsUnrun``: a P9-touched suite
    /// in neither this map nor the workflow reds. A row is not an excuse — it is the statement that
    /// CI does not run those cells and that their green is a local one. A row whose suite later
    /// joins a workflow line reds too, so the list cannot go stale in either direction.
    static let ungatedByDesign: [String: String] = [
        "ObservationLoopLifecycleTests":
            "MemoryLifecycleTests.swift: every cell polls a weak reference under a wall-clock "
            + "deadline, the one shape a test-count floor cannot price — a loaded runner turns a "
            + "deallocation that happened into one that has not happened yet.",
        "ProximityManagerDeallocationTests":
            "MemoryLifecycleTests.swift, same poll shape: deallocation is observed by waiting.",
        "MeshEvictionReleasesTransportLinkTests":
            "MemoryLifecycleTests.swift, same poll shape.",
        "PresenceReleaseTests":
            "MemoryLifecycleTests.swift: P9 item 2 pass 2 edited this row when the presence radio "
            + "swapped, and it is the closest of the seven to a P9 claim — still a timed weak-ref "
            + "poll, so it is named here rather than priced onto the mesh line.",
        "RecipeShareTeardownTests":
            "MemoryLifecycleTests.swift: item 3 pass 2's row, same timed weak-ref poll.",
        "PhotoWallPreferencePruneTests":
            "MemoryLifecycleTests.swift, same poll shape, and not a mesh row at all.",
        "LocalOnlyPersistentHistoryPruneTests":
            "MemoryLifecycleTests.swift, same poll shape, and not a mesh row at all.",
        "PersistenceFailureAuditTests":
            "P9 item 1's wall (27 assertionFailure-in-catch traps turned into audited returns). "
            + "It is not a mesh suite, the mesh line is not its home, and it has never been on any "
            + "CI line — the honest statement is that item 1 is proved locally and nowhere else."
    ]

    /// **The two tier-2 lanes and the three unobserved branches, by their own records.**
    ///
    /// The runbook's Lane C sections are the evidence for what P9's acceptance actually ran; Lane D
    /// is where the branches that no Simulator reaches are specified and still not run. Each
    /// unobserved row is paired with the SOURCE fact that stands in for it, so the pairing cannot
    /// drift: `RecipeShareOverQUICTests` holds the `.remove` branch as a source assertion precisely
    /// because no execution reaches it, and this battery names that substitution out loud.
    @Test func everyLaneRowThisBatteryCannotRunIsStillNamedInItsRecord() throws {
        let runbook = try RepoRoot.source("Docs/Mesh-Network-Feasibility-Runbook.md")
        // R2: bounded by the three lane headings.
        for lane in ["Lane C — P9 item 2", "Lane C — P9 item 3", "Lane D"] {
            #expect(runbook.contains(lane), """
                the runbook's `\(lane)` section is gone — it is the only record that P9's \
                acceptance ran at all, and nothing in this battery re-runs it: a presence epoch \
                rotating over real QUIC and a recipe share paused and resumed across it need two \
                Simulators and a radio, neither of which a CI runner has
                """)
        }
        let ledger = try RepoRoot.source("Docs/Mesh-Migration-Loop-Ledger-P9.md")
        #expect(ledger.contains("Unproven"), "the 9.3.2 row lost its Unproven list")
        // R2: bounded by the three unobserved branches.
        for branch in ["openTransferCount", "glare collapse", "never fires on a Simulator"] {
            #expect(ledger.contains(branch), """
                the ledger no longer records `\(branch)` as unobserved. A branch nothing has ever \
                executed is not proved by the suite that greps its source
                """)
        }
        let recipeTests = try RepoRoot.source("Tests/FernletTests/RecipeShareOverQUICTests.swift")
        #expect(recipeTests.contains("theRegistrationRemoveBranchIsNotABareAssignment"), """
            the source-level stand-in for the `.remove` → republish branch is gone. That cell is a \
            SHAPE assertion, not an execution: it exists because the branch never fires on a \
            Simulator, and deleting it leaves the branch covered by nothing at all
            """)
        #expect(ledger.contains("P9-2-B") && ledger.contains("third friend"), """
            the accepted residual is gone: a sole-friend pair never surfaces in presence (layer-3 \
            self-exclusion drops an ad whose token set is a subset of our own), so every presence \
            lane run must seed a third friend. No cell here can see that — it is a lane rule
            """)
        #expect(ledger.contains("P9-2-C"), """
            and the device measure owed: does a real phone's epoch-boundary wake drift like the \
            Simulators' +51 s over a 767 s arm? The 30 s step bounds it either way; a phone number \
            is what decides whether the step can widen
            """)
    }

    /// **Every device row and every owner decision is still recorded as owed.**
    ///
    /// Plan §15 is P8's acceptance and has never been run; P9 is explicitly NOT gated by it, which
    /// is a decision and not an omission. The four section headings are named here so a renamed or
    /// deleted one reddens rather than quietly narrowing what the migration admits it has not
    /// proved, and the device runbook is asserted to still carry the matching rows.
    @Test func everyDeviceRowAndEveryOwnerDecisionIsStillRecordedAsOwed() throws {
        let plan = try RepoRoot.source("Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md")
        let sections = [
            "**15.1 Radio matrix:**",        // background+lock, cached-endpoint re-dial, AWDL, Low Power
            "**15.2 Partition walks:**",     // 2/2 and 3/1 physically, a removal vote, a carried departure
            "**15.3 Progress soak:**",       // 3 h and 6 h of elapsed-based progress under real phone use
            "**15.4 Wi-Fi Aware evaluation"  // the bounded two-day evaluation, and its recommendation
        ]
        // R2: bounded by the four stated sections.
        for section in sections {
            #expect(plan.contains(section), "plan §15's `\(section)` is gone — the gate it named is still unrun")
        }
        let runbook = try RepoRoot.source("Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md")
        // R2: bounded by the four gate labels.
        for gate in ["§15.1", "§15.2", "§15.3", "§15.4"] {
            #expect(runbook.contains(gate), "the device plan's row for \(gate) is gone")
        }
        let ledger = try RepoRoot.source("Docs/Mesh-Migration-Loop-Ledger-P9.md")
        #expect(ledger.contains("blocked (owner)"), "item 0 is no longer recorded as blocked")
        #expect(ledger.contains("P9-3-A"), """
            the lock finding is gone. A configured Fernlet Lock stops the recipe-share and presence \
            radios PERMANENTLY — `FernletLockState.locked` is the RESTING state of a configured \
            lock, and nothing tells the user why. Pre-existing, found by the 9.3.2 lane rather than \
            caused by it, and NOT fixable here: which lock states may run the 1:1 radios is a row \
            of P7's 23 040-row run-policy table, so changing one is a P7 bug fix that re-runs the \
            whole product
            """)
        #expect(ledger.contains("9.4-LATER"), "and the MC→QUIC cutover's deferred half")
    }

    /// Neither determinism digest moved and neither is spelled here: each keeps its ONE home in
    /// `MeshP5AcceptanceTests`, and the gate that runs this battery re-runs the determinism suites,
    /// which is where a moved digest actually reddens.
    @Test func neitherDeterminismDigestMovedNorLeftItsOneHome() throws {
        let tests = try MeshP7Acceptance.sources(under: "Tests/FernletTests")
        #expect(tests.count >= 280, "the test-target scan lost its files (347 when this was measured)")
        #expect(MeshP7Acceptance.homes(of: "ca898" + "bcc", in: tests) == ["MeshP5AcceptanceTests.swift"],
                "the schedule digest has exactly one home, and this file's split spelling is not a second")
        #expect(MeshP7Acceptance.homes(of: "594b6" + "f77", in: tests) == ["MeshP5AcceptanceTests.swift"],
                "and so does the overlay digest — a move is a red, never a re-pin")
        let me = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("Tests/FernletTests/MeshP9AcceptanceTests.swift"))
        let spellsADigest = me.contains("ca898" + "bcc") || me.contains("594b6" + "f77")
        #expect(!spellsADigest, "and P9's battery spells neither contiguously")
    }

    /// **The battery is gated, and so is every suite items 2, 3 and 4 left on no CI line.**
    ///
    /// The five clause suites are auto-demanded by `CIGateSelectorBoundaryTests` (they end
    /// `AcceptanceTests`); nothing demands the rest, and they were in exactly the position the
    /// fourteen of item 6 were in — declared, green, and running nowhere. Which suites those are is
    /// no longer a hand-list here: ``everyP9TouchedSuiteIsEitherGatedOrNamedAsUnrun`` derives them.
    ///
    /// Two names are pinned individually, on the `MeshRoutedDrainWallTests` argument that a wall
    /// with no compiler half must red when it leaves the line rather than go quiet:
    /// `TransportNeutralityBoundaryTests` (also pinned in the selector wall — clause (d) defers to
    /// it for the app target, where a substring walk cannot run) and `MeshTransportSelectionTests`,
    /// whose `theAppsInitializerRunsOnTheQUICRadio` drives the app's own initializer. Clause
    /// (d)'s value pins are taken in a DEBUG test build and therefore cannot execute the Release
    /// arm of `resolvedKind(environment:)` at all; that suite is the other half of the same claim.
    @Test func everySuiteHereAndEveryP9SuiteIsOnTheMeshStep() throws {
        let workflow = try RepoRoot.source(MeshP9Acceptance.workflowPath)
        let clauses = ["MeshP9EphemeralPostureAcceptanceTests", "MeshP9PresenceSwapAcceptanceTests",
                       "MeshP9RecipeSwapAcceptanceTests", "MeshP9McRetirementAcceptanceTests",
                       "MeshP9HonestyAcceptanceTests"]
        let steps = CIGateSelectorBoundaryTests.gatedSteps(in: workflow).filter { $0.label == "mesh-batteries" }
        #expect(steps.count == 1, "one mesh-batteries step")
        let named = Set(try #require(steps.first).suites)
        // R2: bounded by the five clause names.
        for clause in clauses {
            #expect(named.contains(clause), "P9 clause suite `\(clause)` is not on the mesh-batteries step")
        }
        // R2: bounded by the two individually-argued names.
        for wall in ["TransportNeutralityBoundaryTests", "MeshTransportSelectionTests"] {
            #expect(named.contains(wall), """
                `\(wall)` left the mesh-batteries line. Clause (d) leans on it — the app-target
                whole-identifier scan and the shipping radio the app's own initializer builds — and
                neither claim is reachable from this battery's own DEBUG process.
                """)
        }
        let listed = try #require(steps.first).suites
        #expect(listed.count == Set(listed).count,
                "no suite is named twice — a duplicate selector runs its tests twice and inflates the floor")
    }

    /// **Every suite in a file P9 edited is either gated or named here as unrun.**
    ///
    /// Item 9's own verify found the shape this closes: the battery hand-listed seven suites, so
    /// `ProximityRecipeShareCapTests` — 31 cells, rewritten by item 3 pass 2, holding the very
    /// pause/resume behaviour clause (c) asserts — was on no CI line and nothing in the tree said
    /// so. The accounting is now total over ``p9TouchedSuites``: gated, or named in
    /// ``ungatedByDesign`` with a reason. Both directions are pinned, so the map cannot rot into a
    /// list of suites that quietly got gated, or grow a row for a suite P9 never touched.
    @Test func everyP9TouchedSuiteIsEitherGatedOrNamedAsUnrun() throws {
        let workflow = try RepoRoot.source(MeshP9Acceptance.workflowPath)
        let gated = Set(CIGateSelectorBoundaryTests.gatedSteps(in: workflow).flatMap(\.suites))
        let declared = try CIGateSelectorBoundaryTests.declaredTopLevelTypes()
        #expect(Self.p9TouchedSuites.count == Set(Self.p9TouchedSuites).count, "a name is listed twice")
        var unaccounted: [String] = []
        var vanished: [String] = []
        // R2: bounded by the frozen list.
        for suite in Self.p9TouchedSuites {
            if !declared.contains(suite) { vanished.append(suite) }
            if gated.contains(suite) || Self.ungatedByDesign[suite] != nil { continue }
            unaccounted.append(suite)
        }
        #expect(vanished.isEmpty, """
            \(vanished) is named here but declared in no file of Tests/FernletTests. A renamed or \
            deleted suite must move this list in the same commit — otherwise a row that names \
            nothing satisfies the accounting below forever
            """)
        #expect(unaccounted.isEmpty, """
            \(unaccounted) ran on no CI line at any point in P9 and is named in neither the \
            workflow nor MeshP9HonestyAcceptanceTests.ungatedByDesign. Gate it on a \
            Scripts/run-gated-suites.sh line (raising that step's floor and its measured suite-name \
            count in the same commit), or add a row saying why CI does not run it
            """)
        let alreadyGated = Self.ungatedByDesign.keys.filter(gated.contains).sorted()
        #expect(alreadyGated.isEmpty, """
            \(alreadyGated) is named as unrun and IS on a workflow line. A suite that gets gated \
            leaves this map in the same commit — an honesty row for something CI runs is the \
            opposite failure, and it teaches the next reader to distrust the rest
            """)
        let strangers = Self.ungatedByDesign.keys.filter { !Self.p9TouchedSuites.contains($0) }.sorted()
        #expect(strangers.isEmpty, "\(strangers) is excused here but is not a P9-touched suite")
    }

    /// **The two things this phase's own walls do not cover, counted rather than implied.**
    ///
    /// (a) Item 8 re-recorded the runtime accessibility ratchet's baselines. Its STALENESS half,
    /// `AuditRatchetBoundaryTests`, is a pure source scan and this commit puts it on the grep-wall
    /// step — but the ratchet itself lives in `Tests/FernletUITests`, and the workflow runs no UI
    /// target at all. So the baselines are checked for staleness on CI and checked for ACCURACY
    /// nowhere: that is the "more proven than it is" shape, and it is stated here rather than left
    /// to be inferred from a workflow nobody reads.
    ///
    /// (b) Item 7 scoped the routed-inventory family's process-global audit counts to their own
    /// rigs. Forty-two `.count(of:)` reads with no `where:` survived it; P10 item 5 took that to
    /// **twenty** and item 5's own verify review to **seventeen** — nine production doors gained
    /// the `held` key and twenty-five reads were scoped or re-spelled with the `where:` label — and
    /// the seventeen left are the ones with a reason:
    ///   * **six are not this reader at all** — `MilestoneEconomy.count(of:in:)` over a local array
    ///     in `MilestoneLedgerTests` / `MilestoneResetBoundaryTests`. This cell's needle is a
    ///     spelling, not a type, so they sit inside the number permanently. Narrowing the needle to
    ///     exclude them would be editing a wall to make a number look better;
    ///   * **two are the proof cells** — `MeshRoutedDrainTests` and `MeshRoutedPhotoDeliveryTests`
    ///     each read UNSCOPED on purpose, beside the scoped read, to show the two differ;
    ///   * **three reads sit at three emitters that are unscopeable**: the line is written by a
    ///     device holding no mesh, so `heldMeshAuditContext(_:)` omits the key by design rather
    ///     than writing a fallback — the descriptor door's uncommitted-slot drop (it refuses BEFORE
    ///     the mesh guard), the projection after a `leaveMesh()`, and the launch-restore
    ///     key-advertisement refusal, which `restoreSessionContextAtLaunch(now:)` reaches with
    ///     `currentMesh` deliberately nil ("restoring is not reconnecting");
    ///   * **six have an emitter that COULD carry the key** and were not changed: item 5 stopped
    ///     at the routed-access / photo / founding `== N` cluster, which is where the defect
    ///     concentrated. Five of the six are the weaker `> 0` / `== 0` form; one
    ///     (`routedShare.recipientIsSelf`) is still `== 1` over a process-global capture and is the
    ///     next to take. 6 + 2 + 3 + 6 = 17.
    ///
    /// **Item 5's verify review moved two of them, and one had a FALSE reason.**
    /// `mesh.promotion.refusedExistingMesh` was filed in the third bucket as written by a device
    /// holding no mesh — but its `log(` is in the **else** of `guard currentMesh == nil`, so it
    /// fires only when a mesh IS held, and the cell reading it asserts one is held five lines
    /// earlier. Scoping a read is never enough on its own: the EMITTER's branch is what decides
    /// whether the key can be there at all, and the guard's name is not that branch.
    /// `routedDrain.heldBackSetFull` was the one new unscoped `== 1` this item put on the gated
    /// line. Both doors now carry the key and all three reads are scoped.
    /// The number may fall, never rise. Re-derive it, never remember it — this cell's own needle
    /// over comment-stripped source is the only count that means anything.
    @Test func theRatchetsUIHalfAndTheUnscopedAuditCountsAreNamedRatherThanImplied() throws {
        let workflow = try RepoRoot.source(MeshP9Acceptance.workflowPath)
        let gated = Set(CIGateSelectorBoundaryTests.gatedSteps(in: workflow).flatMap(\.suites))
        #expect(gated.contains("AuditRatchetBoundaryTests"), """
            the ratchet's staleness wall left the workflow. It is a pure source scan — every frozen
            baseline still names a probed screen — and it is the only half of item 8's ratchet a CI
            runner can execute at all
            """)
        // The workflow's COMMANDS, not its prose: the step that gates the ratchet's source half
        // explains in a comment where the other half lives, and a claim about what CI runs must
        // not be satisfied or broken by a sentence. Comment lines are dropped exactly as
        // `gatedSteps` drops them.
        let code = workflow.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        #expect(!code.contains("FernletUITests"), """
            the workflow now names the UI target. If a runner really does run UXScreenProbe's
            ratchet, this row is obsolete and the honesty statement above must be rewritten rather
            than left standing — it would be claiming less than the tree proves
            """)
        // R2: bounded by the two probe files.
        for path in ["Tests/FernletUITests/UXScreenProbe.swift",
                     "Tests/FernletUITests/UXScreenProbeIdentityTests.swift"] {
            #expect(FileManager.default.fileExists(atPath: RepoRoot.url(path).path), """
                \(path) is gone. It is the half of item 8's ratchet nothing on CI runs, so its
                deletion would be invisible everywhere else
                """)
        }
        let tests = try MeshP7Acceptance.sources(under: "Tests/FernletTests")
        #expect(tests.count >= 280, "the test-target scan lost its files (347 when this was measured)")
        // Split so this cell's own literal is not one of the reads it counts.
        let read = ".count(" + "of: "
        var unscoped: [String: Int] = [:]
        // R2: bounded by the test files × their lines.
        for source in tests {
            for line in source.code.components(separatedBy: "\n")
            where line.contains(read) && !line.contains("where:") {
                unscoped[source.name, default: 0] += 1
            }
        }
        let total = unscoped.values.reduce(0, +)
        #expect(total <= 17, """
            \(total) unscoped audit-count reads, up from the 17 P10 item 5's fix left behind \
            (\(unscoped.keys.sorted())). Each answers for every rig alive in the process, and a \
            new `== N` among them is item 7's defect again — scope it with `where:` on the rig's \
            own context, the reader that exists for this
            """)
    }
}
