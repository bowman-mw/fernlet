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

    /// Ed25519 public-key length. Anything else in the member list is not a key and is dropped.
    static let signingKeyByteCount = 32

    /// Cap on seeded members — the mesh roster cap, so a malformed variable cannot grow the list.
    static let maxSeededMembers = 8

    /// Whether this launch installs the harness.
    static let isEnabled = ProcessInfo.processInfo.environment[enabledKey] == "1"

    /// This run's name in the transcript.
    static let label = ProcessInfo.processInfo.environment[labelKey] ?? "unlabelled"

    /// The mesh id to seed, or nil when the descriptor is left absent.
    static let seededMeshID = UUID(uuidString: ProcessInfo.processInfo.environment[meshIDKey] ?? "")

    /// The signing keys to seed as members.
    static let seededMemberKeys = parseKeys(ProcessInfo.processInfo.environment[membersKey])

    /// Frozen diagnostic English naming what the launch environment asked for, for the transcript.
    static var summary: String {
        let environment = ProcessInfo.processInfo.environment
        return "label=\(label) transport=\(environment["FERNLET_MESH_TRANSPORT"] ?? "default") "
            + "chaos=\(environment["FERNLET_MESH_CHAOS"] ?? "off") "
            + "chaosBarred=\(environment["FERNLET_MESH_CHAOS_BARRED"] == nil ? "none" : "set")"
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
/// It seeds ``MeshNetworkManager/currentMesh`` and calls `startJoin()`. That is all. It does not
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
    static func install(manager: @autoclosure () -> MeshNetworkManager) {
        guard MeshMatrixDebugOptions.isEnabled else { return }
        let manager = manager()
        guard !manager.isSearching else { return }
        echo("run \(MeshMatrixDebugOptions.summary)")
        echo("identity fingerprint=\(manager.localFingerprint) "
            + "signingKey=\(manager.localSigningPublicKey.base64EncodedString())")
        seedDescriptor(manager: manager)
        manager.startJoin()
        echo("radios started; searching=\(manager.isSearching)")
    }

    /// Applies the seeded descriptor, or says out loud that none was asked for.
    private static func seedDescriptor(manager: MeshNetworkManager) {
        let keys = MeshMatrixDebugOptions.seededMemberKeys
        guard let meshID = MeshMatrixDebugOptions.seededMeshID, !keys.isEmpty else {
            echo("no descriptor seeded: roster stays empty, every peer verdicts stranger")
            return
        }
        let now = Date()
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
        echo("descriptor seeded: mesh=\(meshID) members=\(keys.count)")
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
    /// no radio is started, and the lazy mesh manager is not even built.
    static func install(manager: @autoclosure () -> MeshNetworkManager) {}
    #endif
}
