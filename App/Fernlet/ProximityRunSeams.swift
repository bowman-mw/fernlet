// ProximityRunSeams.swift
// Fernlet
//
// Network migration P7 item 3: the radios' `apply(_:)` seams, and the ONE place in the app that
// speaks a radio verb.
//
// Before this file `ContentView` owned the radios: `startFriendsDiscovery()` /
// `stopFriendsDiscovery()` resolved `FriendsDiscoveryEntry` and called `startJoin()` /
// `resumeSearchingForPartitionedMesh()` / `stopJoin()`, guarded on `isSearching` and on
// `hasCommittedPeer`; `updateRecipeShareListener()` / `updatePresenceListener()` started and stopped
// the two listeners from their own `scenePhase == .active` / tab / lock guards; and `FernletStore`
// reached around all of it from its two opt-out setters and from delete-all's leg 7b. Item 1 made
// those guards one table (`ProximityRunPolicy`), item 2 made the store's funnel the one place that
// runs it, and this item makes that funnel the only WRITER of the radios — walled by
// `ProximityRunSeamsTests`, which counts every radio verb under `App/` into this file (and, by
// name, the DEBUG Lane C harness's own `startJoin()`).
//
// Two halves, deliberately. `ProximityRunTransition` is PURE: from the last verdict applied and the
// new one, plus the mesh manager's three live predicates, to an ordered list of
// `ProximityRunAction` — so "which verb, and when" is a tier-1 table rather than a condition only a
// scene can reach. The executor below is a `switch` with nothing to decide.
//
// Edge-triggered on purpose. A radio verb runs only when that radio's verdict CHANGED (the first
// application counts every radio as an edge): `stopJoin()` funnels through `stopSearching()`,
// whose three "if the session ended" hooks are meant to fire once per ending, and today's chain
// reached them only from the Friends tab's own exits. Presence and recipe `start()` / `stop()` are
// idempotent (both guard `isRunning`) and lose nothing by the same discipline.
//
// What the seams keep apart. `hasCommittedPeer` guards the radios — a `hold` verdict is its value;
// `isInSession` picks `leaveSession()` over `stopJoin()` on a hard stop; and `isSessionLive` is
// read by nothing here, because projections and ceremonies own it (P6 item 2's pass-B P1).
// `FriendsDiscoveryEntry` is still the three-way, unmoved.
//
// What this phase cannot execute, said out loud: discovery `stop` with mesh `run` — a live
// background process that must stop browsing and admitting while KEEPING its links (invariant 5).
// `stopJoin()` would drop the links. Unreachable while the app feeds `.notRequested`; the executor
// refuses it audibly (`proximityRunPolicy.unsupportedTransition`) rather than doing the wrong
// thing quietly. P8 builds that seam.

import Foundation
import FernletFoundation
import ProximityKit

// MARK: - ProximityRunAction

/// One thing a seam does to a radio — the transition's decision as a value, so the whole "which
/// verb, given the last verdict and this one" table is tier 1 and the executor decides nothing.
nonisolated enum ProximityRunAction: Equatable, Sendable {

    /// `MeshNetworkManager.startJoin()` — a fresh search cycle (`FriendsDiscoveryEntry.fresh`).
    case startJoin

    /// `MeshNetworkManager.resumeSearchingForPartitionedMesh()` — a mesh that outlived its links
    /// (`FriendsDiscoveryEntry.resume`).
    case resumeSearch

    /// `MeshNetworkManager.stopJoin()` — stand the discovery radios down; nothing committed to keep.
    case stopJoin

    /// `MeshNetworkManager.leaveSession()` — the mesh's own teardown. Only a hard stop asks for it.
    case leaveSession

    /// Arm the fresh search's five-minute "found nobody" timeout — the tab's half of door 3, which
    /// `ContentView.armDiscoveryTimeout()` used to own.
    case armDiscoveryTimeout

    /// Cancel that timeout.
    case cancelDiscoveryTimeout

    /// Refuse, audibly, the one transition this phase cannot execute: discovery `stop` while the
    /// mesh keeps `run` (P8's seam).
    case refuseBackgroundDiscoveryStop

    /// `PresenceManager.apply(_:)` with the presence verdict.
    case presence(ProximityRunState)

    /// `ProximityRecipeShareManager.apply(_:)` with the recipe-share verdict.
    case recipeShare(ProximityRunState)
}

// MARK: - ProximityRunTransition

/// The pure half of the seams: which actions one verdict change asks for.
nonisolated enum ProximityRunTransition {

    /// The mesh manager's live facts the discovery seam reads — the same three
    /// `ContentView.startFriendsDiscovery()` and `stopFriendsDiscovery()` read.
    nonisolated struct MeshFacts: Equatable, Sendable {

        /// `MeshNetworkManager.isSearching` — the discovery radios are up.
        let isSearching: Bool

        /// `MeshNetworkManager.isInSession` — a mesh is held, or some slot committed.
        let isInSession: Bool

        /// `MeshNetworkManager.hasCommittedPeer` — a slot holds a committed fingerprint now.
        let hasCommittedPeer: Bool

        /// Builds the facts.
        ///
        /// - Parameters:
        ///   - isSearching: Whether the discovery radios are up.
        ///   - isInSession: Whether a mesh is held or a slot committed.
        ///   - hasCommittedPeer: Whether a slot holds a committed fingerprint now.
        init(isSearching: Bool, isInSession: Bool, hasCommittedPeer: Bool) {
            self.isSearching = isSearching
            self.isInSession = isInSession
            self.hasCommittedPeer = hasCommittedPeer
        }
    }

    /// The actions, in the order the executor runs them: the mesh radios first, then presence,
    /// then recipe share. A radio whose verdict did not move asks for nothing.
    ///
    /// - Parameters:
    ///   - previous: The last verdict applied, or nil before the first — when every radio is an edge.
    ///   - verdict: The verdict to apply.
    ///   - mesh: The mesh manager's live facts.
    /// - Returns: The ordered actions; empty when nothing moved.
    static func actions(
        from previous: ProximityRunPolicy.Verdict?,
        to verdict: ProximityRunPolicy.Verdict,
        mesh: MeshFacts
    ) -> [ProximityRunAction] {
        var actions = meshActions(from: previous, to: verdict, mesh: mesh)
        if previous?.presence != verdict.presence {
            actions.append(.presence(verdict.presence))
        }
        if previous?.recipeShare != verdict.recipeShare {
            actions.append(.recipeShare(verdict.recipeShare))
        }
        return actions
    }

    /// The mesh half. A hard stop (mesh `stop`) tears down whatever is up — the session if one is
    /// held, else the search — and cancels the tab's timeout; otherwise only a discovery edge acts.
    private static func meshActions(
        from previous: ProximityRunPolicy.Verdict?,
        to verdict: ProximityRunPolicy.Verdict,
        mesh: MeshFacts
    ) -> [ProximityRunAction] {
        let meshMoved = previous?.mesh != verdict.mesh
        let discoveryMoved = previous?.discovery != verdict.discovery
        switch verdict.mesh {
        case .stop:
            guard meshMoved else { return [] }
            if mesh.isInSession { return [.cancelDiscoveryTimeout, .leaveSession] }
            if mesh.isSearching { return [.cancelDiscoveryTimeout, .stopJoin] }
            return [.cancelDiscoveryTimeout]
        case .run, .foregroundOnly, .hold:
            break
        }
        guard discoveryMoved else { return [] }
        switch verdict.discovery {
        case .foregroundOnly:
            return discoveryStart(mesh)
        case .hold:
            return [.cancelDiscoveryTimeout]
        case .stop:
            return discoveryStop(verdict.mesh, mesh: mesh)
        case .run:
            // Never emitted for discovery (invariant 5); answered rather than trapped.
            return []
        }
    }

    /// A discovery edge INTO `foregroundOnly`: the three-way, guarded on `isSearching` exactly as
    /// the tab's arm was, and arming the timeout for exactly the entries that arm it.
    private static func discoveryStart(_ mesh: MeshFacts) -> [ProximityRunAction] {
        guard !mesh.isSearching else { return [] }
        let entry = FriendsDiscoveryEntry.entry(
            isInSession: mesh.isInSession, hasCommittedPeer: mesh.hasCommittedPeer
        )
        var actions: [ProximityRunAction] = []
        switch entry {
        case .fresh: actions.append(.startJoin)
        case .resume: actions.append(.resumeSearch)
        case .none: break
        }
        if entry.armsDiscoveryTimeout { actions.append(.armDiscoveryTimeout) }
        return actions
    }

    /// A discovery edge INTO `stop`: the stand-down, or the one refusal this phase owes P8.
    private static func discoveryStop(
        _ meshState: ProximityRunState, mesh: MeshFacts
    ) -> [ProximityRunAction] {
        switch meshState {
        case .run:
            return [.refuseBackgroundDiscoveryStop]
        case .foregroundOnly, .hold, .stop:
            return mesh.isSearching ? [.cancelDiscoveryTimeout, .stopJoin] : [.cancelDiscoveryTimeout]
        }
    }
}

// MARK: - The executor

extension FernletStore {

    /// Runs the actions a transition decided, in order — the ONLY place in the app that speaks a
    /// radio verb (`ProximityRunSeamsTests` counts every verb under `App/` into this file).
    ///
    /// - Parameter actions: The ordered actions from
    ///   ``ProximityRunTransition/actions(from:to:mesh:)``.
    func executeProximityRunActions(_ actions: [ProximityRunAction]) {
        // R2: bounded by the transition's own list.
        for action in actions {
            switch action {
            case .startJoin:
                meshNetworkManager.startJoin()
            case .resumeSearch:
                meshNetworkManager.resumeSearchingForPartitionedMesh()
            case .stopJoin:
                meshNetworkManager.stopJoin()
            case .leaveSession:
                meshNetworkManager.leaveSession()
            case .armDiscoveryTimeout:
                armDiscoveryTimeout()
            case .cancelDiscoveryTimeout:
                cancelDiscoveryTimeout()
            case .refuseBackgroundDiscoveryStop:
                FernletAuditLog.log(
                    "proximityRunPolicy.unsupportedTransition",
                    context: ["transition": "discoveryStopWhileMeshRuns"]
                )
            case .presence(let state):
                presenceManager.apply(state)
            case .recipeShare(let state):
                recipeShareManager.apply(state)
            }
        }
    }

    /// The tab's half of door 3 (P6 item 2 fix review, P2-1), moved here from
    /// `ContentView.armDiscoveryTimeout()` with its behaviour intact: five minutes of finding
    /// nobody ends the session through `endSessionAfterDiscoveryTimeout()`, which refuses while a
    /// peer is committed. Cancellation means the arm was superseded and ends nothing. The manager
    /// arms the same interval itself at the slot-loss doors; this arm exists because a search that
    /// never had a peer never loses one, so the manager's edge never fires for it.
    private func armDiscoveryTimeout() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(MeshNetworkManager.discoveryGiveUpInterval))
            } catch {
                // Cancellation means the timeout was superseded (a stand-down, or a new start).
                return
            }
            self?.meshNetworkManager.endSessionAfterDiscoveryTimeout()
        }
    }

    /// Stands the tab's timeout down.
    private func cancelDiscoveryTimeout() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
    }
}

// MARK: - The listeners' seams

extension PresenceManager {

    /// The presence radio's one seam: `run` and `foregroundOnly` start it, `stop` stops it, and
    /// `hold` — which the policy never emits for a listener — keeps what it has. Both verbs are
    /// idempotent inside the manager.
    ///
    /// - Parameter state: The presence radio's verdict.
    func apply(_ state: ProximityRunState) {
        switch state {
        case .run, .foregroundOnly: start()
        case .hold: break
        case .stop: stop()
        }
    }
}

extension ProximityRecipeShareManager {

    /// The recipe-share listener's one seam, on the same terms as ``PresenceManager/apply(_:)``.
    ///
    /// - Parameter state: The recipe-share listener's verdict.
    func apply(_ state: ProximityRunState) {
        switch state {
        case .run, .foregroundOnly: start()
        case .hold: break
        case .stop: stop()
        }
    }
}
