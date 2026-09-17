// ProximityRunState.swift
// ProximityKit/Mesh
//
// Network migration P7 item 3, pass A (plan §13): the ONE run-state vocabulary, plus the frozen
// English tokens and the single directive resolver the three `applyRunState` seams share.
//
// **Why the enum lives HERE and not in the app.** `ProximityRunPolicy` is an app-target pure value
// (§13 option A — ProximityKit imports no UIKit and cannot import `FernletLock`), but the seams the
// policy drives are `MeshNetworkManager`, `PresenceManager` and `ProximityRecipeShareManager`, and a
// package target cannot name an app type. So the DIRECTIVE moved down and the POLICY stayed up: the
// app still decides, ProximityKit still observes nothing, and there is exactly one spelling of
// `run` / `foregroundOnly` / `stop` in the build. Duplicating the enum on both sides of the module
// boundary and mapping between them was the alternative, and it is the shape that lets two
// vocabularies drift — the same argument `FriendsDiscoveryEntry` was pulled down here on.
//
// **What a seam receives.** The host calls a seam with the directive already RESOLVED against the
// one foreground fact (`ProximityRunDecision.isUp(_:)`), so a seam sees `run` or `stop`.
// `foregroundOnly` is a policy/UI concept — it is an answer about two scene phases, and a manager
// knows about neither — so a seam that is handed one treats it as `run` and says so in an audit
// line. That is a testable claim rather than a comment: see ``ProximityRunStateSeam/isUp(_:radio:)``.
//
// **And `stop` is "stand down", never "end the session".** Tearing a session down is `tearsDownSession`'s
// job (delete-all, below-age, duress), and pass B maps it onto the paths `FernletStore` already runs.
// No door here ends a mesh.

import FernletFoundation
import Foundation

/// What one proximity radio is directed to do, in plan §13's vocabulary.
///
/// A directive is not yet an answer about right now: ``foregroundOnly`` resolves against the one
/// foreground fact through ``isUp(inForeground:)``, which is what lets §13's rows be read literally
/// — "discovery/admission is `foregroundOnly`" is true in both scene phases, and it is the
/// RESOLUTION that puts the radio down in the background.
///
/// The `rawValue`s are **frozen English tokens**, never display copy: they are what
/// ``ProximityRunStateSeam/applied`` and ``ProximityRunStateSeam/unresolved`` log as `state=…`, so
/// renaming one renames a log line other people's saved traces are read against.
public nonisolated enum ProximityRunState: String, CaseIterable, Hashable, Sendable {

    /// Up in both scene phases. Only a granted continuation task ever earns this (plan §13).
    case run = "run"

    /// Up while the app is foreground, down once it is backgrounded.
    ///
    /// A **policy** answer. A seam never acts on it as a third behaviour — see the file header.
    case foregroundOnly = "foregroundOnly"

    /// Down, unconditionally. "Stand down", never "end the session".
    case stop = "stop"

    /// The directive resolved against the one foreground fact.
    ///
    /// - Parameter isForeground: `FernletApp.routedGateForeground(for:)`'s answer for this scene.
    /// - Returns: whether the radio is up right now.
    public func isUp(inForeground isForeground: Bool) -> Bool {
        switch self {
        case .run: return true
        case .foregroundOnly: return isForeground
        case .stop: return false
        }
    }
}

/// The frozen English vocabulary of the three `applyRunState` seams: their audit tokens, the radio
/// names those lines carry, the two refusal reasons, and the one directive resolver.
///
/// Held in one type rather than spelled at each seam for the reason every token family in this
/// module is: a token is a promise to whoever reads the log later, and three copies of a promise
/// are three chances to break one. `MeshNetworkManager`, `PresenceManager` and
/// `ProximityRecipeShareManager` all log through these constants, and `ProximityRunStateSeamTests`
/// pins every spelling.
///
/// **Two families, on purpose.** ``applied`` is the CHANGE line — a seam emits it only when the
/// radio it owns actually moved, so calling a door twice with the same value logs once. ``held``
/// and ``unresolved`` are per-CALL lines: they name a directive that did NOT move the radio and why,
/// which is the interesting event precisely because nothing happened. The caller is the policy
/// host, which pushes on a leg change rather than on a timer, so neither can spin.
///
/// Internal, not public: the tokens are this module's own log vocabulary and the app has no reason
/// to spell them. `@testable import ProximityKit` is how the suite reads them.
nonisolated enum ProximityRunStateSeam {

    /// The radio moved. Logged once per CHANGE, with `state=` (and, for the friend radios, both
    /// directives) as context.
    static let applied = "mesh.runState.applied"

    /// A directive was received and deliberately did NOT move the radio, with `reason=`.
    static let held = "mesh.runState.held"

    /// A seam was handed ``ProximityRunState/foregroundOnly``, which the host is supposed to have
    /// resolved already. Treated as ``ProximityRunState/run`` and logged, so the claim is testable.
    static let unresolved = "mesh.runState.unresolved"

    /// The committed peer-to-peer links of a founded mesh. Same spelling as the app's
    /// `ProximityRadio.meshLinks` `rawValue`, which this module may not name.
    static let meshLinks = "meshLinks"

    /// Advertising, browsing and admitting a NEW peer. Same spelling as `ProximityRadio`'s.
    static let discoveryAdmission = "discoveryAdmission"

    /// Both mesh radios at once — what `startJoin()` / `stopJoin()` actually is.
    ///
    /// One door for two radios is the asymmetry the vocabulary exists to name, so the line that
    /// records a move of the friend radios says so rather than picking one of the two.
    static let friendRadios = "meshLinks+discoveryAdmission"

    /// The nearby-friends presence layer. Same spelling as `ProximityRadio`'s.
    static let presence = "presence"

    /// The nearby recipe-share listener. Same spelling as `ProximityRadio`'s.
    static let recipeShare = "recipeShare"

    /// ``held``'s reason when a links `stop` arrived over a COMMITTED peer: standing the radios
    /// down would empty the committed slots and clear the group-key state, which is ending a live
    /// mesh rather than standing one down.
    static let committedPeer = "committedPeer"

    /// ``held``'s reason for the P8-only combination (links `run`, discovery `stop`): no primitive
    /// stops browsing and advertising while KEEPING the committed links, so the safe answer is to
    /// move nothing.
    static let noStandAloneDiscoveryStop = "noStandAloneDiscoveryStop"

    /// ``held``'s reason when a `run` arrived over a mesh that outlived its links but whose SESSION
    /// has already ended.
    ///
    /// `MeshNetworkManager.resumeSearchingForPartitionedMesh()` refuses the terminal states by name
    /// — a departed, terminated or expired session is never re-entered (the rejoin bar) — and it
    /// refuses by returning, not by reporting. Without this token that row of the mesh door's table
    /// was the one "moved nothing" row that said nothing at all, while every other such row logs
    /// ``held``.
    static let resumeRefused = "resumeRefused"

    /// Resolves a directive that arrived at a seam, and names it when it arrived unresolved.
    ///
    /// The host is expected to apply ``ProximityRunState/isUp(inForeground:)`` before it calls,
    /// so a seam sees `run` or `stop`. ``ProximityRunState/foregroundOnly`` reaching one means some
    /// caller pushed a policy answer straight through; the seam treats it as
    /// ``ProximityRunState/run`` — the fail-SAFE direction, because standing a radio down on a
    /// directive nobody resolved could end a live mesh — and logs ``unresolved`` so the claim is a
    /// cell rather than a comment.
    ///
    /// - Parameters:
    ///   - state: The directive as it arrived.
    ///   - radio: Which radio it was for, as a frozen token from this type.
    /// - Returns: whether the radio should be up.
    static func isUp(_ state: ProximityRunState, radio: String) -> Bool {
        guard state == .foregroundOnly else { return state.isUp(inForeground: true) }
        FernletAuditLog.log(unresolved, context: ["radio": radio, "state": state.rawValue])
        return true
    }
}
