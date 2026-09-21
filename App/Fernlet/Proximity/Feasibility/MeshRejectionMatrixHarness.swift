//
//  MeshRejectionMatrixHarness.swift
//  Fernlet
//
//  DEBUG-only launch hooks for the P2 migration's rejection-matrix lane (Lane C in
//  Docs/Mesh-Network-Feasibility-Runbook.md): two Simulators on one Mac, both running the
//  PRODUCTION mesh over the QUIC radio (FERNLET_MESH_TRANSPORT=quic), seeded so each named
//  refusal in MeshIntroductionRejection can be produced and read out of a
//  `simctl launch --console-pty` transcript.
//
//  Everything here is wrapped in `#if DEBUG`; in release builds the whole surface is a
//  hard-coded no-op that reads no environment and seeds nothing. Same convention as
//  UITestSupport.swift and NetworkMeshFeasibilityProbe.swift's MeshProbeDebugOptions.
//

import Foundation
import ProximityKit

// MARK: - MeshMatrixDebugOptions

/// DEBUG launch switches for the rejection-matrix lane, read once per process so
/// `xcrun simctl launch` can drive a whole run without touching the app's UI.
///
/// Every switch is off when its variable is absent, and off means *exactly* today's behaviour: no
/// mesh descriptor is invented, the radios are not started, and nothing is echoed anywhere. The
/// variable names are frozen automation tokens, never display strings, and nothing read here is
/// persisted — the seeded descriptor lives in memory for one launch, so this owes no row on the
/// persisted-surface wipe ledger.
enum MeshMatrixDebugOptions {

    #if DEBUG
    /// `FERNLET_MESH_MATRIX=1` — install the harness: print this device's identity, apply any
    /// seeded descriptor, and start the mesh radios.
    static let enabledKey = "FERNLET_MESH_MATRIX"

    /// `FERNLET_MESH_MATRIX_LABEL=<token>` — names the run in the transcript, so seven runs in one
    /// log file can be told apart.
    static let labelKey = "FERNLET_MESH_MATRIX_LABEL"

    /// `FERNLET_MESH_MATRIX_MESH_ID=<uuid>` — the mesh id the seeded descriptor carries. Two
    /// Simulators given the same one are in one mesh; different ones are in two.
    static let meshIDKey = "FERNLET_MESH_MATRIX_MESH_ID"

    /// `FERNLET_MESH_MATRIX_MEMBERS=<base64,base64>` — the Ed25519 signing keys the seeded roster
    /// admits. Absent (or without a mesh id) means no descriptor at all, which is the empty-roster
    /// "every peer is a stranger" state a device with no mesh is really in.
    static let membersKey = "FERNLET_MESH_MATRIX_MEMBERS"

    /// `FERNLET_MESH_FLOWS=<csv>` — the app-layer flows to drive once a peer's slot commits, from
    /// ``MeshFlowVerb``'s frozen tokens. Absent means the harness seeds and joins and drives
    /// nothing, which is exactly what it did before flows existed.
    static let flowsKey = "FERNLET_MESH_FLOWS"

    /// `FERNLET_MESH_ROLE=founder|joiner` — the membership shape this node plays in a Lane C pair
    /// run (P3 item 9). Absent means neither, which is every run before item 9 existed: the node
    /// seeds a descriptor and drives flows, and no ledger is ever armed.
    static let roleKey = "FERNLET_MESH_ROLE"

    /// `FERNLET_MESH_LEAVE_AFTER=<seconds>` — leave the session that many polls in, through
    /// `leaveSessionAfterNotifyingPeers()`, so the signed ending is emitted BEFORE the teardown.
    /// Which ending is `MeshDevelopmentPlan`'s (P4 item 6, plan §10.6): a merged derived roster
    /// larger than two emits `member-departure.v1`, and a run whose roster is exactly **two** emits
    /// `terminated.v1` instead — so a two-node Lane C leave ends the mesh rather than shrinking it.
    /// Absent means the run never leaves (a hard `simctl terminate` emits nothing, which is what
    /// every Lane C run before this one did).
    static let leaveAfterKey = "FERNLET_MESH_LEAVE_AFTER"

    /// `FERNLET_MESH_REMOVE_AFTER=<seconds>` — file a signed removal record against the first
    /// seeded member that is not this device, that many polls in. Founder role only. Absent means
    /// no removal is ever filed.
    static let removeAfterKey = "FERNLET_MESH_REMOVE_AFTER"

    /// `FERNLET_MESH_FLOWS_AFTER=<polls>` — hold every flow until this poll, so a run can fire
    /// text, photos and hearts AFTER the founding window instead of inside it (P6 item 10).
    ///
    /// Without it a flow fires on the first tick that has a committed slot, which on a `founder`
    /// run is the tick the founder collapses the seeded descriptor to itself — the derived roster
    /// is 1, every routed mint has zero destinations, and `.noDestinations` is the only outcome the
    /// lane can produce. Absent means 0, which is that behaviour exactly.
    static let flowsAfterKey = "FERNLET_MESH_FLOWS_AFTER"

    /// `FERNLET_MESH_ALLOW_HEARTS=1` — turn the in-person hearts opt-in ON for this launch, BEFORE
    /// `startJoin()`, so `.hearts` reaches the handshake's capability list (P6 item 10).
    ///
    /// The setting ships **off** and `localCapabilities()` advertises `.hearts` only when it is on,
    /// and a peer's capability list is snapshotted when its coordinator is built — so this is an
    /// ordering constraint, not a convenience. Absent leaves the user's own setting untouched.
    static let allowHeartsKey = "FERNLET_MESH_ALLOW_HEARTS"

    /// `FERNLET_MESH_AUTO_KEEP_FRIENDS=1` — stand in for the user tapping "keep" on every candidate
    /// of a promoted `pendingFriendReview` batch, then consume the batch (P6 item 10).
    ///
    /// Stands in for ONE tap and nothing else: `keepProximityFriends(from:keptFingerprints:)` and
    /// `completeFriendReview(_:)` are the shipping doors `ConnectView.finalizeFriendKeeps()` calls,
    /// unchanged. It exists because the trust-vault row those doors write is the only thing that
    /// makes a peer heart-eligible, and a fresh pair of Simulators has none. Absent means no batch
    /// is ever kept, which is today's behaviour.
    static let autoKeepFriendsKey = "FERNLET_MESH_AUTO_KEEP_FRIENDS"

    /// Ed25519 public-key length. Anything else in the member list is not a key and is dropped.
    static let signingKeyByteCount = 32

    /// Cap on seeded members — the mesh roster cap, so a malformed variable cannot grow the list.
    static let maxSeededMembers = 8

    /// Granularity, in seconds, of the seeded descriptor's creation instant (P6 item 10).
    ///
    /// **This is load-bearing and the lane found out the hard way.** Every node seeds its OWN
    /// descriptor, and `MeshNetworkManager` derives the session's hard deadline from
    /// `descriptor.createdAt + MeshSessionCeiling.ceilingSeconds`. Every routed manifest and chunk
    /// carries `MeshRoutedManifest.expiry(afterHardDeadline:)`, and the receiving verifier refuses
    /// anything whose expiry is not ITS OWN deadline plus grace (`MeshChunkVerifier`'s
    /// `expiryMismatch`). With a per-device `Date()` the three nodes' deadlines differed by the
    /// launch stagger, and **two thirds of every routed frame in run C-P6-TEXT-2 was refused**.
    /// Flooring to a shared grid makes the seeded descriptors agree without a new environment
    /// variable and without touching shipping code — on the app path the founder mints one
    /// descriptor and gossips it, so the disagreement is an artefact of seeding, not a defect.
    static let seededCreationGridSeconds: TimeInterval = 600

    /// Whether this launch installs the harness.
    static let isEnabled = ProcessInfo.processInfo.environment[enabledKey] == "1"

    /// This run's name in the transcript.
    static let label = ProcessInfo.processInfo.environment[labelKey] ?? "unlabelled"

    /// The mesh id to seed, or nil when the descriptor is left absent.
    static let seededMeshID = UUID(uuidString: ProcessInfo.processInfo.environment[meshIDKey] ?? "")

    /// The signing keys to seed as members.
    static let seededMemberKeys = parseKeys(ProcessInfo.processInfo.environment[membersKey])

    /// The app-layer flows this run drives. Empty means none.
    static let flows = parseFlows(ProcessInfo.processInfo.environment[flowsKey])

    /// The membership shape this node plays. ``MeshMatrixRole/none`` when the variable is absent.
    static let role = MeshMatrixRole(rawValue: ProcessInfo.processInfo.environment[roleKey] ?? "")
        ?? MeshMatrixRole.none

    /// Poll at which this run leaves through the clean-departure verb, or nil for never.
    static let leaveAfterSeconds = parseSeconds(ProcessInfo.processInfo.environment[leaveAfterKey])

    /// Poll at which the founder files a removal record, or nil for never.
    static let removeAfterSeconds = parseSeconds(ProcessInfo.processInfo.environment[removeAfterKey])

    /// The seeded descriptor's creation instant, floored to ``seededCreationGridSeconds`` so every
    /// node of one run derives the SAME session hard deadline (P6 item 10).
    static var seededCreatedAt: Date {
        let grid = seededCreationGridSeconds
        return Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / grid).rounded(.down) * grid)
    }

    /// The first poll at which a flow may fire. Zero — today's behaviour — when absent.
    static let flowsAfterPolls = parseSeconds(ProcessInfo.processInfo.environment[flowsAfterKey]) ?? 0

    /// Whether this launch turns the nearby-hearts opt-in on before the radios start.
    static let allowsHearts = ProcessInfo.processInfo.environment[allowHeartsKey] == "1"

    /// Whether this launch keeps every candidate of a promoted friend-review batch.
    static let autoKeepsFriends = ProcessInfo.processInfo.environment[autoKeepFriendsKey] == "1"

    /// Frozen diagnostic English naming what the launch environment asked for, for the transcript.
    static var summary: String {
        let environment = ProcessInfo.processInfo.environment
        return "label=\(label) transport=\(environment["FERNLET_MESH_TRANSPORT"] ?? "default(quic)") "
            + "chaos=\(environment["FERNLET_MESH_CHAOS"] ?? "off") "
            + "chaosBarred=\(environment["FERNLET_MESH_CHAOS_BARRED"] == nil ? "none" : "set") "
            + "flows=\(flows.isEmpty ? "none" : flows.map(\.rawValue).joined(separator: "+")) "
            + "flowsAfter=\(flowsAfterPolls) "
            + "hearts=\(allowsHearts ? "on" : "off") "
            + "autoKeepFriends=\(autoKeepsFriends ? "on" : "off") "
            + "role=\(role.rawValue) "
            + "leaveAfter=\(leaveAfterSeconds.map(String.init) ?? "never") "
            + "removeAfter=\(removeAfterSeconds.map(String.init) ?? "never")"
    }

    /// Parses a whole number of seconds, clamped to the flow driver's own poll budget so a
    /// mistyped variable can never ask for a schedule the run does not reach (Power of 10 rule 2).
    private static func parseSeconds(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value >= 0 else { return nil }
        return min(value, MeshFlowDriver.maxTicks)
    }

    /// Parses the comma-separated flow list, ignoring unrecognized tokens and bounded by the number
    /// of flows that exist (Power of 10 rule 2). Order is the caller's; each flow fires once.
    private static func parseFlows(_ raw: String?) -> [MeshFlowVerb] {
        guard let raw, !raw.isEmpty else { return [] }
        var parsed: [MeshFlowVerb] = []
        for token in raw.split(separator: ",").prefix(MeshFlowVerb.allCases.count) {
            guard let verb = MeshFlowVerb(rawValue: String(token)), !parsed.contains(verb) else { continue }
            parsed.append(verb)
        }
        return parsed
    }

    /// Parses comma-separated base64 signing keys, dropping anything that is not exactly one
    /// Ed25519 public key, and bounded by the roster cap (Power of 10 rule 2).
    private static func parseKeys(_ raw: String?) -> [Data] {
        guard let raw, !raw.isEmpty else { return [] }
        var keys: [Data] = []
        for token in raw.split(separator: ",").prefix(maxSeededMembers) {
            guard let key = Data(base64Encoded: String(token)),
                  key.count == signingKeyByteCount else { continue }
            keys.append(key)
        }
        return keys
    }
    #else
    /// Release: the harness is never installed.
    static let isEnabled = false

    /// Release: there is no run to name.
    static var summary: String { "off" }
    #endif
}

// MARK: - MeshRejectionMatrixHarness

/// Puts one Simulator into a known membership state and starts the production mesh, so the QUIC
/// radio's named refusals can be observed over a real radio instead of only at tier 1.
///
/// ## What it does, and what it deliberately does not
///
/// It seeds ``MeshNetworkManager/currentMesh`` and calls `startJoin()`. Since P6 item 10 it also
/// carries the `FernletStore` the flow driver needs for the hearts script — the nearby-hearts
/// opt-in, the trust vault and the heart ledger all live there, and every one of them is reached
/// through a shipping door — and since finding L-4 it selects the Social tab on that store before
/// starting anything, because the run policy, not this harness, decides whether the radios stay up
/// (see ``install(manager:store:)``). That is all. It does not
/// touch the introduction, the roster derivation, the dial policy or the tie-break — the whole
/// point is that the code under observation is the shipping code. The misbehaviours that produce
/// the signature and replay rows live on the other side of the module wall, in ProximityKit's own
/// DEBUG chaos seam, because that is where the introduction is.
///
/// The seeded descriptor is `closed`, so `currentDiscoveryInfo()` publishes only `v` and `sid` and
/// every run in the lane advertises byte-identical TXT records. The only thing that varies between
/// runs is the membership state being tested.
///
/// **Release cannot install it.** The whole body is compiled out; the release ``install(manager:)``
/// is empty, reads no environment, and can seed nothing.
@MainActor
enum MeshRejectionMatrixHarness {

    /// Frozen console tag so a `--console-pty` transcript can be grepped down to the harness's own
    /// lines, distinct from the transport's `[mesh-quic]`. Never shown in the UI.
    static let consolePrefix = "[mesh-matrix]"

    #if DEBUG
    /// Installs the harness when the launch environment asked for it.
    ///
    /// The manager arrives as an `@autoclosure` and is evaluated only after the flag check, so an
    /// ordinary launch does not force `FernletStore`'s lazy `meshNetworkManager` into existence —
    /// building it loads the photo-wall index and the activity sidecar, which no launch should pay
    /// for on account of a diagnostic hook.
    ///
    /// Idempotent through `isSearching`: the SwiftUI `.task` that calls this can re-fire, and a
    /// second `startJoin()` would re-mint the radio's Bonjour name mid-run.
    ///
    /// ## The tab this selects, and why (finding L-4)
    ///
    /// Since P7 item 3 (`df0ce5b`) the run policy is the single writer of every radio verb, and
    /// `ProximityRunPolicy.discoveryState` answers `.stop` for a foregrounded app on any tab but
    /// `.social` with no committed peer. A matrix launch opens on Home, so the funnel's FIRST apply
    /// — `previous == nil`, where every radio is an edge — resolved to `.stopJoin` and tore down
    /// the radios this harness had just started, ~20 ms in and before the QUIC listener could
    /// start (`nw_listener_start … In wrong state for start`). Bonjour was never registered and the
    /// sim↔sim lane discovered nothing from `df0ce5b` until L-4 named it. The product path never
    /// had the defect: a user reaches the mesh through the Social tab, where the same seam STARTS
    /// the radios. Selecting that tab through the store's own mirror — the one
    /// `ContentView.handleTabChange(from:to:)` writes — is what makes this start survive its own
    /// first verdict, and it keeps the fix on the diagnostic's side of the wall rather than widening
    /// the policy product with a harness leg.
    static func install(manager: @autoclosure () -> MeshNetworkManager, store: FernletStore) {
        guard MeshMatrixDebugOptions.isEnabled else { return }
        let manager = manager()
        guard !manager.isSearching else { return }
        echo("run \(MeshMatrixDebugOptions.summary)")
        echo("identity fingerprint=\(manager.localFingerprint) "
            + "signingKey=\(manager.localSigningPublicKey.base64EncodedString())")
        seedDescriptor(manager: manager)
        // Before `startJoin()`, never after (L-4): the funnel's first apply reads this mirror, and
        // on any tab but `.social` it answers `stopJoin()`. A frozen token, never display text.
        store.selectedTab = .social
        // Before `startJoin()`, never after: a peer's capability list is snapshotted when its
        // coordinator is built, so a provider the flow driver sets later would never reach the wire.
        // The hearts opt-in (P6 item 10) is in that same window for the same reason.
        MeshFlowDriver.prepare(manager: manager, store: store)
        manager.startJoin()
        echo("radios started; searching=\(manager.isSearching)")
        MeshFlowDriver.start(manager: manager, store: store)
    }

    /// Applies the seeded descriptor, or says out loud that none was asked for.
    private static func seedDescriptor(manager: MeshNetworkManager) {
        let keys = MeshMatrixDebugOptions.seededMemberKeys
        guard let meshID = MeshMatrixDebugOptions.seededMeshID, !keys.isEmpty else {
            echo("no descriptor seeded: roster stays empty, every peer verdicts stranger")
            return
        }
        // Floored, never `Date()`: see `seededCreationGridSeconds` — the hard deadline every routed
        // frame's expiry is checked against comes from here, so two nodes that disagree by a second
        // refuse each other's manifests and chunks outright.
        let now = MeshMatrixDebugOptions.seededCreatedAt
        manager.currentMesh = MeshDescriptor(
            meshID: meshID,
            name: "matrix",
            mode: .closed,
            members: keys.map { member(for: $0, manager: manager, joinedAt: now) },
            nameSetAt: now,
            nameSetBy: manager.localFingerprint,
            modeSetAt: now,
            modeSetBy: manager.localFingerprint,
            createdAt: now
        )
        echo("descriptor seeded: mesh=\(meshID) members=\(keys.count) createdAt=\(now.timeIntervalSince1970)")
    }

    /// One seeded member row. The key-agreement half is real only for this device — the roster the
    /// introduction consults reads `signingPublicKey` and nothing else, and inventing a peer's
    /// X25519 key would be a lie with no purpose.
    private static func member(
        for signingPublicKey: Data,
        manager: MeshNetworkManager,
        joinedAt: Date
    ) -> MeshMember {
        let fingerprint = IdentityService.fingerprint(of: signingPublicKey)
        let isLocal = signingPublicKey == manager.localSigningPublicKey
        return MeshMember(
            fingerprint: fingerprint,
            displayName: "matrix-\(fingerprint.prefix(4))",
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: isLocal ? manager.localKeyAgreementPublicKey : Data(),
            joinedAt: joinedAt
        )
    }

    /// Mirrors one harness line to stdout, where `simctl launch --console-pty` reads it.
    private static func echo(_ message: String) {
        print("\(consolePrefix) \(message)")
    }
    #else
    /// Release no-op — the autoclosure is never evaluated, so nothing is read, nothing is seeded,
    /// no radio is started, and the lazy mesh manager is not even built. The store arrives by
    /// reference and is not touched either.
    static func install(manager: @autoclosure () -> MeshNetworkManager, store: FernletStore) {}
    #endif
}
